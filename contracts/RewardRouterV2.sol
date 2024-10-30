// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "../libraries/Address.sol";

import "../tokens/interfaces/IERC20.sol";
import "../tokens/libraries/SafeERC20.sol";
import "../tokens/interfaces/IMintable.sol";
import "../tokens/interfaces/IWETH.sol";
import "./interfaces/IRewardTracker.sol";
import "./interfaces/IRewardRouterV2.sol";
import "./interfaces/IVester.sol";

import "../interfaces/IOlpManager.sol";
import "../AuthorityUtil.sol";

import "../proxy/OwnableUpgradeable.sol";
import "../proxy/ReentrancyGuardUpgradeable.sol";

contract RewardRouterV2 is IRewardRouterV2, OwnableUpgradeable, ReentrancyGuardUpgradeable, AuthorityUtil {
    using SafeERC20 for IERC20;
    using Address for address payable;

    address public weth;
    address public olp;

    address public override feeOlpTracker;
    address public olpManager;

    event StakeOlp(address indexed account, uint256 amount);
    event UnstakeOlp(address indexed account, uint256 amount);

    receive() external payable {
        require(msg.sender == weth, "Router: invalid sender");
    }

    function initialize(
        address _weth,
        address _olp,
        address _feeOlpTracker,
        address _olpManager,
        IOptionsAuthority _authority
    ) external initializer {
        require(
            _weth != address(0) &&
            _olp != address(0) &&
            _feeOlpTracker != address(0) &&
            _olpManager != address(0),
            "Router: invalid addresses"
        );

        __Ownable_init();
        __ReentrancyGuard_init();
        __AuthorityUtil_init__(_authority);

        weth = _weth;
        olp = _olp;

        feeOlpTracker = _feeOlpTracker;
        olpManager = _olpManager;
    }

    // to help users who accidentally send their tokens to this contract
    function withdrawToken(address _token, address _account, uint256 _amount) external onlyAdmin {
        IERC20(_token).safeTransfer(_account, _amount);
    }

    // when buying olp with token other than ETH
    function mintAndStakeOlp(address _token, uint256 _amount, uint256 _minUsdg, uint256 _minOlp) external nonReentrant returns (uint256) {
        return _mintAndStakeOlp(msg.sender, msg.sender, _token, _amount, _minUsdg, _minOlp);
    }

    // when buying olp with ETH
    function mintAndStakeOlpETH(uint256 _minUsdg, uint256 _minOlp) external payable nonReentrant returns (uint256) {
        require(msg.value > 0, "RewardRouter: invalid msg.value");

        // convert ETH to WETH
        // get approval from Olp Manager
        IWETH(weth).deposit{value: msg.value}();
        IERC20(weth).approve(olpManager, msg.value);

        return _mintAndStakeOlp(address(this), msg.sender, weth, msg.value, _minUsdg, _minOlp);
    }

    // when selling olp for token other than ETH
    function unstakeAndRedeemOlp(address _tokenOut, uint256 _olpAmount, uint256 _minOut, address _receiver) external nonReentrant returns (uint256) {
        return _unstakeAndRedeemOlp(msg.sender, _tokenOut, _olpAmount, _minOut, _receiver);
    }

    // when selling olp for ETH
    function unstakeAndRedeemOlpETH(uint256 _olpAmount, uint256 _minOut, address payable _receiver) external nonReentrant returns (uint256) {
        uint256 amountOut = _unstakeAndRedeemOlp(msg.sender, weth, _olpAmount, _minOut, address(this));

        // convert WETH to ETH
        // send ETH to receiver
        IWETH(weth).withdraw(amountOut);
        _receiver.sendValue(amountOut);

        return amountOut;
    }

    function claim() external nonReentrant {
        address account = msg.sender;
        IRewardTracker(feeOlpTracker).claimForAccount(account, account);
    }

    // to help users withdraw their rewards to ETH
    function handleRewards(
        bool _shouldClaimWeth, // (will be always true)
        bool _shouldConvertWethToEth
    ) external nonReentrant {
        address account = msg.sender;

        if (_shouldClaimWeth) {
            if (_shouldConvertWethToEth) {
                uint256 wethAmount = IRewardTracker(feeOlpTracker).claimForAccount(account, address(this));
                IWETH(weth).withdraw(wethAmount);
                payable(account).sendValue(wethAmount);
            } else {
                IRewardTracker(feeOlpTracker).claimForAccount(account, account);
            }
        }
    }

    function _mintAndStakeOlp(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdg, uint256 _minOlp) internal returns (uint256) {
        require(_amount > 0, "RewardRouter: invalid _amount");

        // Send token to Olp Manager and OLP to account
        uint256 olpAmount = IOlpManager(olpManager).addLiquidityForAccount(_fundingAccount, _account, _token, _amount, _minUsdg, _minOlp);
        
        // Stake fOLP and sOLP
        IRewardTracker(feeOlpTracker).stakeForAccount(_account, _account, olp, olpAmount);

        emit StakeOlp(_account, olpAmount);

        return olpAmount;
    }

    function _unstakeAndRedeemOlp(address _account, address _tokenOut, uint256 _olpAmount, uint256 _minOut, address _receiver) internal returns (uint256) {
        require(_olpAmount > 0, "RewardRouter: invalid _olpAmount");

        // unstake sOLP and fOLP in order
        // give olp to Olp Manager and get tokenOut from Olp Manager and send it to receiver
        IRewardTracker(feeOlpTracker).unstakeForAccount(_account, olp, _olpAmount, _account); // transfer unstake amount of OLP to account
        uint256 amountOut = IOlpManager(olpManager).removeLiquidityForAccount(_account, _tokenOut, _olpAmount, _minOut, _receiver);

        emit UnstakeOlp(_account, _olpAmount);

        return amountOut;
    }
}
