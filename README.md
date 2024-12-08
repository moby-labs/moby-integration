# Moby Smart Contracts

This repository contains the core smart contracts for the Moby. Moby enables users to trade options with OLP acting as the counterparty for all positions.

# Overview

Moby consists of four main contracts that handle different aspects of the options trading system:

- `PositionManager`: Manages opening and closing of option positions
- `SettleManager`: Handles settlement of expired options
- `RewardRouterV2`: Manages OLP token operations (minting, staking, unstaking) and rewards
- `OlpManager`: Provides information about OLP pricing and manages OLP liquidity

## Contract Details

### PositionManager.sol

The PositionManager contract is responsible for:

- Opening new option positions
- Closing existing positions before expiry
- Managing the request queue for position operations
- Supporting both token and native asset transactions

Key functions:
```solidity
function createOpenPosition(
    uint16 _underlyingAssetIndex,           // underlying asset index
    uint8 _length,                          // number of types of options
    bool[4] memory _isBuys,                 // trade type for each option
    bytes32[4] memory _optionIds,           // ID of each option
    bool[4] memory _isCalls,                // exercise method for each option
    uint256 _minSize,                       // minimum quantity of option tokens (variable value)
    address[] memory _path,                 // swap path
    uint256 _amountIn,                      // amount of payment token (fixed value)
    uint256 _minOutWhenSwap,                // minimum quantity of tokens desired when swapping
    address _leadTrader
) external returns (bytes32)
function createClosePosition(
    uint16 _underlyingAssetIndex,
    uint256 _optionTokenId,
    uint256 _size,
    address[] memory _path,
    uint256 _minAmountOut,
    uint256 _minOutWhenSwap,
    bool _withdrawNAT
) external returns (bytes32)
```

### SettleManager.sol

The SettleManager contract handles:

- Settlement of expired option positions
- Distribution of settlement proceeds
- Support for both token and native asset settlements

Key functions:
```solidity
function settlePosition(
    address[] memory _path,
    uint16 _underlyingAssetIndex,
    uint256 _optionTokenId,
    uint256 _minOutWhenSwap,
    bool _withdrawNAT
) external returns (uint256)
```

### RewardRouterV2.sol

The RewardRouterV2 contract manages:

- Minting and staking of OLP tokens
- Unstaking and redeeming of OLP tokens
- Distribution of rewards to OLP holders
- Handling of both token and native asset transactions

Key functions:
```solidity
function mintAndStakeOlp(
  address _token,
  uint256 _amount,
  uint256 _minUsdg,
  uint256 _minOlp
) external returns (uint256)
function unstakeAndRedeemOlp(
  address _tokenOut,
  uint256 _olpAmount,
  uint256 _minOut,
  address _receiver
) external returns (uint256)
function handleRewards(
    bool _shouldClaimReward,
    bool _shouldConvertRewardToNAT
) external
```

### OlpManager.sol

The OlpManager contract provides:

- OLP token pricing information
- AUM (Assets Under Management) calculations

Key functions:
```solidity
function getPrice(bool _maximise) external view returns (uint256)
function getAums() public view returns (uint256[] memory)
```

## Directory Structure

```
contracts/
├── abis/
│   ├── OlpManager.json
│   ├── PositionManager.json
│   ├── RewardRouterV2.json
│   └── SettleManager.json
├── OlpManager.sol
├── PositionManager.sol
├── RewardRouterV2.sol
└── SettleManager.sol
```

## Integration Flow

1. Users interact with Moby primarily through the PositionManager to open and close positions
2. OLP provides the counterparty liquidity for all positions
3. Users can participate as liquidity providers by:
- Minting and staking OLP tokens through RewardRouterV2
- Earning rewards from trading fees
4. When options expire, users can settle their positions through the SettleManager

## Interfaces
The contract ABIs are provided in the `abis/` directory for integration purposes. These files contain the complete interface definitions required for interacting with the smart contracts.

For detailed technical documentation and integration guides, please refer to our official documentation.
