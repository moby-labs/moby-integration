// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "./interfaces/ISettleManager.sol";
import "./tokens/erc1155/interfaces/IERC1155Base.sol";
import "./tokens/erc1155/interfaces/IERC1155Receiver.sol";

import "./BasePositionManager.sol";

import "./proxy/OwnableUpgradeable.sol";

contract SettleManager is BasePositionManager, ISettleManager, IERC1155Receiver, OwnableUpgradeable {
    using SafeERC20 for IERC20;
    using Address for address;

    /* =============== EVENTS ================= */

    event SettlePosition(
        address indexed account,
        uint16 indexed underlyingAssetIndex,
        uint40 indexed expiry,
        uint256 optionTokenId,
        uint256 size,
        address[] path,
        uint256 amountOut,
        uint256 settlePrice
    );

    //////////////////////////////////////////////
    //              INITIALIZATION              //
    //////////////////////////////////////////////

    /* =============== INITIALIZE ============= */
    function initialize(
        address _optionsMarket,
        address _controller,
        address _weth,
        IOptionsAuthority _authority
    ) public initializer {
        __Ownable_init();
        __BasePositionManager_init__(_optionsMarket, _controller, _weth, _authority);

    }

    /* =============== FUNCTIONS ============== */

    //////////////////////////////////////////////
    //             SETTLE POSITIONS             //
    //////////////////////////////////////////////

    /*
     * path
     * - the length of path is either 1 or 2
     * - path[0] signifies the address of the token to be received
     * - path[length-1] signifies the address of the final token to be received
     * 
     * - conclusion,
     *   - if the length of path is 1, then the address of the token to be received and the final token to be received are the same.
     *   - if the length of path is 2, then the address of the token to be received and the final token to be received are different, and a swap occurs.
     * 
     *  when the length of path is 1,
     * - Buy Call: [UnderlyingAsset] => intrinsic value to receive
     * - Buy Put, Buy Call Spread, Buy Put Spread: [USDC] => intrinsic value to receive
     * - Sell Call: [UnderlyingAsset] => collateral to receive
     * - Sell Put, Sell Call Spread, Sell Put Spread: [USDC] => collateral to receive
     * 
     * when the length of path is 2,
     * - Buy Call: [UnderlyingAsset, Token]
     * - Buy Put, Buy Call Spread, Buy Put Spread: [USDC, Token]
     * - Sell Call: [UnderlyingAsset, Token]
     * - Sell Put, Sell Call Spread, Sell Put Spread: [USDC, Token]
     */
    function settlePosition(
        address[] memory _path,
        uint16 _underlyingAssetIndex,
        uint256 _optionTokenId,
        uint256 _minOutWhenSwap,
        bool _withdrawETH
    ) public nonReentrant returns (uint256) {
        require(_path.length == 1 || _path.length == 2, "SettleManager: Invalid path length");

        if (_withdrawETH) {
            require(_path[_path.length - 1] == weth, "SettleManager: Invalid path for ETH withdrawal");
        }

        uint40 blockTime = uint40(block.timestamp);

        address sourceVault = IController(controller).getVaultAddressByOptionTokenId(_optionTokenId);

        address optionsToken = IOptionsMarket(optionsMarket).getOptionsTokenByIndex(_underlyingAssetIndex);
        
        uint256 size = IERC1155Base(optionsToken).balanceOf(msg.sender, _optionTokenId);
        require(size > 0, "SettleManager: No position to settle");
        
        uint40 expiry = Utils.getExpiryByOptionTokenId(_optionTokenId);
        require(expiry <= blockTime, "SettleManager: Option not expired");

        IController(controller).pluginERC1155Transfer(optionsToken, msg.sender, sourceVault, _optionTokenId, size);
        
        (uint256 amountOut, uint256 settlePrice) = IController(controller).pluginSettlePosition(
            msg.sender,
            _path[0],
            _optionTokenId,
            size,
            address(this)
        );

        if (amountOut > 0) {
            if (_path.length > 1) {
                amountOut = _swap(sourceVault, _path, amountOut, _minOutWhenSwap, address(this));
            }

            if (_withdrawETH) {
                _transferOutETHWithGasLimitFallbackToWeth(amountOut, payable(msg.sender));
            } else {
                IERC20(_path[_path.length - 1]).safeTransfer(msg.sender, amountOut);
            }
        }

        emit SettlePosition(
            msg.sender,
            _underlyingAssetIndex,
            expiry,
            _optionTokenId,
            size,
            _path,
            amountOut,
            settlePrice
        );

        return amountOut;
    }

    function settlePositions(
        address[][] memory _paths,
        uint16 _underlyingAssetIndex,
        uint256[] memory _optionTokenIds,
        uint256[] memory _minOutWhenSwaps,
        bool _withdrawETH
    ) external nonReentrant {
        uint256 length = _paths.length;

        require(length == _optionTokenIds.length, "SettleManager: Invalid input length");
        require(length == _minOutWhenSwaps.length, "SettleManager: Invalid input length");

        for (uint256 i = 0; i < length;) {
            settlePosition(_paths[i], _underlyingAssetIndex, _optionTokenIds[i], _minOutWhenSwaps[i], _withdrawETH);
            unchecked { i++; }
        }
    }


    function onERC1155Received(address operator, address from, uint256 id, uint256 value, bytes calldata data) public virtual override returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address operator, address from, uint256[] calldata ids, uint256[] calldata values, bytes calldata data) public virtual override returns (bytes4) {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 interfaceId) public view virtual override returns (bool) {
        return interfaceId == type(IERC1155Receiver).interfaceId;
    }
}
