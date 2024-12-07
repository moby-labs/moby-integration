// SPDX-License-Identifier: MIT
pragma solidity 0.8.16;

import "./tokens/interfaces/IERC20.sol";
import "./tokens/libraries/SafeERC20.sol";
import "./tokens/interfaces/IUSDG.sol";
import "./tokens/interfaces/IMintable.sol";
import "./interfaces/IVault.sol";
import "./interfaces/IVaultUtils.sol";
import "./interfaces/IOptionsAuthority.sol";
import "./interfaces/IOlpManager.sol";
import "./AuthorityUtil.sol";
import "./proxy/OwnableUpgradeable.sol";
import "./proxy/ReentrancyGuardUpgradeable.sol";

contract OlpManager is IOlpManager, OwnableUpgradeable, ReentrancyGuardUpgradeable, AuthorityUtil {
    using SafeERC20 for IERC20;

    uint256 public constant PRICE_PRECISION = 10 ** 30;
    uint256 public constant USDG_DECIMALS = 18;
    uint256 public constant OLP_PRECISION = 10 ** 18;
    uint256 public constant MAX_COOLDOWN_DURATION = 7 days;
    uint256 public constant BASIS_POINTS_DIVISOR = 100_00;

    IVault public override vault;
    IVaultUtils public override vaultUtils;
    IVaultPriceFeed public override vaultPriceFeed;

    address public override usdg;
    address public override olp;

    uint256 public override cooldownDuration;
    mapping (address => uint256) public override lastAddedAt;

    uint256 public aumAddition;
    uint256 public aumDeduction;

    bool public inPrivateMode;

    // handler = RewardRouterV2
    mapping (address => bool) public isHandler;

    event AddLiquidity(
        address indexed account,
        address indexed token,
        uint256 amount,
        uint256 aumInUsdg,
        uint256 olpSupply,
        uint256 usdgAmount,
        uint256 mintAmount
    );

    event RemoveLiquidity(
        address indexed account,
        address indexed token,
        uint256 olpAmount,
        uint256 aumInUsdg,
        uint256 olpSupply,
        uint256 usdgAmount,
        uint256 amountOut
    );

    event SetVault(address indexed vault);
    event SetVaultUtils(address indexed vaultUtils);
    event SetVaultPriceFeed(address indexed vaultPriceFeed);
    event SetInPrivateMode(bool inPrivateMode);
    event SetHandler(address indexed handler, bool isActive);
    event SetCooldownDuration(uint256 cooldownDuration);
    event SetAumAdjustment(uint256 aumAddition, uint256 aumDeduction);

    error ActionNotEnabled();

    function initialize(
        address _vault,
        address _vaultUtils,
        address _vaultPriceFeed,
        address _usdg,
        address _olp,
        uint256 _cooldownDuration,
        IOptionsAuthority _authority
    ) external initializer {
        require(
            _vault != address(0) &&
            _vaultUtils != address(0) &&
            _vaultPriceFeed != address(0) &&
            _usdg != address(0) &&
            _olp != address(0),
            "OlpManager: invalid address (zero address)"
        );

        __Ownable_init();
        __ReentrancyGuard_init();
        __AuthorityUtil_init__(_authority);

        vault = IVault(_vault);
        vaultUtils = IVaultUtils(_vaultUtils);
        vaultPriceFeed = IVaultPriceFeed(_vaultPriceFeed);

        usdg = _usdg;
        olp = _olp;
        
        cooldownDuration = _cooldownDuration;

        inPrivateMode = true;
    }

    function setVault(address _vault) external onlyAdmin {
        require(_vault != address(0), "OlpManager: invalid vault");
        vault = IVault(_vault);
        emit SetVault(_vault);
    }

    function setVaultUtils(address _vaultUtils) external onlyAdmin {
        require(_vaultUtils != address(0), "OlpManager: invalid vaultUtils");
        vaultUtils = IVaultUtils(_vaultUtils);
        emit SetVaultUtils(_vaultUtils);
    }

    function setVaultPriceFeed(address _vaultPriceFeed) external onlyAdmin {
        require(_vaultPriceFeed != address(0), "OlpManager: invalid vaultPriceFeed");
        vaultPriceFeed = IVaultPriceFeed(_vaultPriceFeed);
        emit SetVaultPriceFeed(_vaultPriceFeed);
    }

    function setInPrivateMode(bool _inPrivateMode) external onlyAdmin {
        inPrivateMode = _inPrivateMode;
        emit SetInPrivateMode(_inPrivateMode);
    }

    function setHandler(address _handler, bool _isActive) external onlyAdmin {
        require(_handler != address(0), "OlpManager: invalid handler");
        isHandler[_handler] = _isActive;
        emit SetHandler(_handler, _isActive);
    }

    function setCooldownDuration(uint256 _cooldownDuration) external override onlyAdmin {
        require(_cooldownDuration <= MAX_COOLDOWN_DURATION, "OlpManager: invalid _cooldownDuration");
        cooldownDuration = _cooldownDuration;
        emit SetCooldownDuration(_cooldownDuration);
    }

    function setAumAdjustment(uint256 _aumAddition, uint256 _aumDeduction) external onlyAdmin {
        aumAddition = _aumAddition;
        aumDeduction = _aumDeduction;
        emit SetAumAdjustment(_aumAddition, _aumDeduction);
    }

    function addLiquidity(address _token, uint256 _amount, uint256 _minUsdg, uint256 _minOlp) external override nonReentrant returns (uint256) {
        if (inPrivateMode) { revert ActionNotEnabled(); }
        return _addLiquidity(msg.sender, msg.sender, _token, _amount, _minUsdg, _minOlp);
    }

    function addLiquidityForAccount(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdg, uint256 _minOlp) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _addLiquidity(_fundingAccount, _account, _token, _amount, _minUsdg, _minOlp);
    }

    function removeLiquidity(address _tokenOut, uint256 _olpAmount, uint256 _minOut, address _receiver) external override nonReentrant returns (uint256) {
        if (inPrivateMode) { revert ActionNotEnabled(); }
        return _removeLiquidity(msg.sender, _tokenOut, _olpAmount, _minOut, _receiver);
    }

    function removeLiquidityForAccount(address _account, address _tokenOut, uint256 _olpAmount, uint256 _minOut, address _receiver) external override nonReentrant returns (uint256) {
        _validateHandler();
        return _removeLiquidity(_account, _tokenOut, _olpAmount, _minOut, _receiver);
    }

    // get price of olp
    function getPrice(bool _maximise) external override view returns (uint256) {
        uint256 aum = getAum(_maximise);
        uint256 supply = IERC20(olp).totalSupply();

        if (supply == 0) return PRICE_PRECISION;

        return ((aum * OLP_PRECISION) / supply);
    }

    function getAums() public view returns (uint256[] memory) {
        uint256[] memory amounts = new uint256[](2);
        amounts[0] = getAum(true);
        amounts[1] = getAum(false);
        return amounts;
    }

    function getAumInUsdg(bool _maximise) public override view returns (uint256) {
        uint256 aum = getAum(_maximise);
        return ((aum * (10 ** USDG_DECIMALS)) / PRICE_PRECISION);
    }

    // getAum is composed of OLPDV and OLPPV
    function getAum(bool _maximise) public override view returns (uint256) {
        uint256 aum = aumAddition; // setted as 0

        // add OLPDV (OLP Deposited Value)
        (,,,,,, uint256 olpDepositedValue) = getTotalOlpAssetUsd(_maximise);
        aum = aum + olpDepositedValue;

        // add OLPPV (OLP Position Value)
        (uint256 positionValue, bool isNegative) = vaultPriceFeed.getPVAndSign(address(vault));

        if (isNegative) {
            if (positionValue > aum) {
                aum = 0;
            } else {
                unchecked {
                    aum = aum - positionValue;
                }
            }
        } else {
            aum = aum + positionValue;
        }
        
        return aumDeduction > aum ? 0 : aum - aumDeduction; // GMX에서는 aumDeduction이 0으로 설정되어 있음
    }

    // get total pool, pending mp, pending rp, reserved, utilized, available, deposited amounts of olp asset (regardless of token)
    function getTotalOlpAssetUsd(bool _maximise) public override view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        uint256 totalPoolUsd = 0;
        uint256 totalPendingMpUsd = 0;
        uint256 totalPendingRpUsd = 0;
        uint256 totalReservedUsd = 0;
        uint256 totalUtilizedUsd = 0;
        
        address[] memory whitelistedTokens = vaultUtils.getWhitelistedTokens();

        for (uint256 i = 0; i < whitelistedTokens.length;) {
            address token = whitelistedTokens[i];

            (
                uint256 poolUsd,
                uint256 pendingMpUsd,
                uint256 pendingRpUsd,
                uint256 reservedUsd,
                uint256 utilizedUsd,
                ,
            ) = _getOlpAssetUsd(token, _maximise);

            totalPoolUsd += poolUsd;
            totalPendingMpUsd += pendingMpUsd;
            totalPendingRpUsd += pendingRpUsd;
            totalReservedUsd += reservedUsd;
            totalUtilizedUsd += utilizedUsd;

            unchecked { i++; }
        }

        uint256 totalAvailableUsd = totalPoolUsd - totalPendingMpUsd - totalPendingRpUsd - totalReservedUsd;
        uint256 totalDepositedUsd = totalAvailableUsd + totalUtilizedUsd;

        return (totalPoolUsd, totalPendingMpUsd, totalPendingRpUsd, totalReservedUsd, totalUtilizedUsd, totalAvailableUsd, totalDepositedUsd);
    }

    // get pool, pending mp, pending rp, reserved, utilized, available, deposited usd of token in olp
    function getOlpAssetUsd(address _token, bool _maximise) public override view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        return _getOlpAssetUsd(_token, _maximise);
    }

    // get pool, pending mp, pending rp, reserved, utilized, available, deposited amounts of token in olp
    function getOlpAssetAmounts(address _token) public override view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        return _getOlpAssetAmounts(_token);
    }

    // get total MP, RP release usd of olp (per second)
    function getOlpMpRpReleaseUsd(bool _maximise) public override view returns (uint256, uint256) {
        uint256 totalMpReleaseUsd = 0;
        uint256 totalRpReleaseUsd = 0;

        address[] memory whitelistedTokens = vaultUtils.getWhitelistedTokens();

        for (uint256 i = 0; i < whitelistedTokens.length;) {
            uint256 price = vaultPriceFeed.getSpotPrice(whitelistedTokens[i], _maximise);
            uint256 decimals = vault.tokenDecimals(whitelistedTokens[i]);

            (uint256 mpReleaseRate, uint256 rpReleaseRate) = getOlpMpRpReleaseRate(whitelistedTokens[i]);

            totalMpReleaseUsd = totalMpReleaseUsd + ((mpReleaseRate * price) / (10 ** decimals));
            totalRpReleaseUsd = totalRpReleaseUsd + ((rpReleaseRate * price) / (10 ** decimals));

            unchecked { i++; }
        }
        
        return (totalMpReleaseUsd, totalRpReleaseUsd);
    }

    // get MP, RP release rate of token in olp (per second)
    function getOlpMpRpReleaseRate(address _token) public view returns (uint256, uint256) {
        uint256 mpReleaseRate = vaultUtils.releaseRate(IVaultUtils.PriceType.MP, _token);
        uint256 rpReleaseRate = vaultUtils.releaseRate(IVaultUtils.PriceType.RP, _token);

        return (mpReleaseRate, rpReleaseRate);
    }

    function _getOlpAssetUsd(address _token, bool _maximise) internal view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        (
            uint256 poolAmounts,
            uint256 pendingMpAmounts,
            uint256 pendingRpAmounts,
            uint256 reservedAmounts,
            uint256 utilizedAmounts,,
        ) = _getOlpAssetAmounts(_token);

        uint256 price = vaultPriceFeed.getSpotPrice(_token, _maximise);
        uint256 decimal = vault.tokenDecimals(_token);
        
        uint256 poolUsd = (poolAmounts * price) / (10 ** decimal);
        uint256 pendingMpUsd = (pendingMpAmounts * price) / (10 ** decimal);
        uint256 pendingRpUsd = (pendingRpAmounts * price) / (10 ** decimal);
        uint256 reservedUsd = (reservedAmounts * price) / (10 ** decimal);
        uint256 utilizedUsd = (utilizedAmounts * price) / (10 ** decimal);

        uint256 availableUsd = poolUsd - pendingMpUsd - pendingRpUsd - reservedUsd;
        uint256 depositedUsd = availableUsd + utilizedUsd;
        
        return (poolUsd, pendingMpUsd, pendingRpUsd, reservedUsd, utilizedUsd, availableUsd, depositedUsd);
    }

    function _getOlpAssetAmounts(address _token) internal view returns (uint256, uint256, uint256, uint256, uint256, uint256, uint256) {
        bool isWhitelisted = vault.isWhitelistedToken(_token);
        require(isWhitelisted, "OlpManager: invalid token");

        uint256 poolAmounts = vault.poolAmounts(_token);
        uint256 pendingMpAmounts = vault.pendingMpAmounts(_token);
        uint256 pendingRpAmounts = vault.pendingRpAmounts(_token);
        uint256 reservedAmounts = vault.reservedAmounts(_token);
        uint256 utilizedAmounts = vault.utilizedAmounts(_token);

        uint256 availableAmounts = poolAmounts - pendingMpAmounts - pendingRpAmounts - reservedAmounts;
        uint256 depositedAmounts = availableAmounts + utilizedAmounts;

        return (poolAmounts, pendingMpAmounts, pendingRpAmounts, reservedAmounts, utilizedAmounts, availableAmounts, depositedAmounts);
    }

    function _addLiquidity(address _fundingAccount, address _account, address _token, uint256 _amount, uint256 _minUsdg, uint256 _minOlp) private returns (uint256) {
        require(!vaultUtils.isInSettlementProgress(), "OlpManager: settlement in progress");

        // amount should be greater than 0
        require(_amount > 0, "OlpManager: invalid _amount");

        // calculate aum before buyUSDG
        uint256 aumInUsdg = getAumInUsdg(true);
        uint256 olpSupply = IERC20(olp).totalSupply();

        // send token received from trader to vault
        // - so far, the receiver is OlpManager
        IERC20(_token).safeTransferFrom(_fundingAccount, address(vault), _amount);
        uint256 usdgAmount = vault.buyUSDG(_token, address(this)); 
        require(usdgAmount >= _minUsdg, "OlpManager: insufficient USDG output");

        // calculate mint amount
        // - if aum in usdg is 0, mint amount is usdg amount
        // - if aum in usdg is not 0, multiply usdg amount by total olp supply and divide by aum in usdg
        uint256 mintAmount = aumInUsdg == 0 ? usdgAmount : ((usdgAmount * olpSupply) / aumInUsdg);
        require(mintAmount >= _minOlp, "OlpManager: insufficient OLP output");

        IMintable(olp).mint(_account, mintAmount);

        lastAddedAt[_account] = block.timestamp;

        emit AddLiquidity(_account, _token, _amount, aumInUsdg, olpSupply, usdgAmount, mintAmount);

        return mintAmount;
    }

    function _removeLiquidity(address _account, address _tokenOut, uint256 _olpAmount, uint256 _minOut, address _receiver) private returns (uint256) {
        require(!vaultUtils.isInSettlementProgress(), "OlpManager: settlement in progress");

        // amount should be greater than 0 and cooldown duration should be passed
        require(_olpAmount > 0, "OlpManager: invalid _olpAmount");
        require(lastAddedAt[_account] + cooldownDuration <= block.timestamp, "OlpManager: cooldown duration not yet passed");

        // calculate aum before sellUSDG
        uint256 aumInUsdg = getAumInUsdg(false);
        uint256 olpSupply = IERC20(olp).totalSupply();

        // calculate usdg amount by multiplying aum in usdg by the ratio of olp amount
        // - if usdg amount is greater than usdg balance of olp manager, mint usdg amount
        uint256 usdgAmount = (_olpAmount * aumInUsdg) / olpSupply;
        uint256 usdgBalance = IERC20(usdg).balanceOf(address(this));
        if (usdgAmount > usdgBalance) {
            uint256 mintAmount;
            unchecked {
                mintAmount = usdgAmount - usdgBalance;
            }
            IUSDG(usdg).mint(address(this), mintAmount);
        }

        IMintable(olp).burn(_account, _olpAmount);

        // send usdg amount to vault and get amount out
        IERC20(usdg).transfer(address(vault), usdgAmount);
        uint256 amountOut = vault.sellUSDG(_tokenOut, _receiver);
        require(amountOut >= _minOut, "OlpManager: insufficient output");

        emit RemoveLiquidity(_account, _tokenOut, _olpAmount, aumInUsdg, olpSupply, usdgAmount, amountOut);

        return amountOut;
    }

    function _validateHandler() private view {
        require(isHandler[msg.sender], "OlpManager: forbidden");
    }
}
