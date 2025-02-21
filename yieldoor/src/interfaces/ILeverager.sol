// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.4;

interface ILeverager {
    struct Position {
        address denomination; // should be doable in any asset?
        uint256 borrowedAmount;
        uint256 borrowedIndex;
        uint256 initCollateralValue; // always in Denom
        uint256 initCollateralUsd;
        uint256 initBorrowedUsd;
        uint256 shares;
        address vault;
        address token0;
        address token1;
    }

    struct LeverageParams {
        uint256 amount0In;
        uint256 amount1In;
        uint256 vault0In;
        uint256 vault1In;
        uint256 min0in;
        uint256 min1in;
        address vault;
        address denomination;
        uint256 maxBorrowAmount;
        bytes swapParams1;
        bytes swapParams2;
    }

    struct LiquidateParams {
        uint256 id;
        uint256 minAmount0;
        uint256 minAmount1;
        bytes swapParams1;
        bytes swapParams2;
        bool hasToSwap;
    }

    struct WithdrawParams {
        uint256 id;
        uint256 pctWithdraw;
        uint256 minAmount0;
        uint256 minAmount1;
        bytes swapParams1;
        bytes swapParams2;
        bool hasToSwap;
    }

    struct VaultParams {
        bool leverageEnabled;
        uint256 maxUsdLeverage;
        uint256 maxTimesLeverage;
        uint256 minCollateralPct;
        uint256 maxBorrowedUSD;
        uint256 currBorrowedUSD; // this is accounted based on pricing upon opening a position
    }

    function changeVaultMaxBorrow(address vault, uint256 maxBorrow) external;
    function changeVaultMaxLeverage(address vault, uint256 maxLeverage) external;
    function changeVaultMinCollateralPct(address vault, uint256 minColateral) external;
    function decreaseCollateral(uint256 id, uint256 _shares, uint256 minAmount0, uint256 minAmount1) external;
    function enableTokenAsBorrowed(address asset) external;
    function feeRecipient() external view returns (address);
    function initVault(
        address vault,
        uint256 _maxUsdLeverage,
        uint256 _maxTimesLeverage,
        uint256 collatPct,
        uint256 _maxBorrowUSD
    ) external;
    function isLiquidateable(uint256 id) external view returns (bool liquidateable);
    function liquidatePosition(LiquidateParams memory liqParams) external;
    function openLeveragedPosition(LeverageParams memory lp) external;
    function pricefeed() external view returns (address);
    function repayOwed(uint256 repayAmount, uint256 id) external;
    function setLiquidationFee(uint256 newFee) external;
    function swapRouter() external view returns (address);
    function toggleVaultLeverage(address vault) external;
    function withdraw(WithdrawParams memory cpp) external;
    function setPriceFeed(address) external;
    function getPosition(uint256 id) external view returns (Position memory);
}
