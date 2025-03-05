// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {ReserveLogic} from "./libraries/ReserveLogic.sol";
import {DataTypes} from "./types/DataTypes.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IyToken} from "./interfaces/IyToken.sol";
import {yToken} from "./yToken.sol";

/// @title LendingPool
/// Forked and adjusted from Extra Finances

contract LendingPool is ILendingPool, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ReserveLogic for DataTypes.ReserveData;

    /// @notice The amount of tokens which is transferred to the burn address, upon first deposit in a reserve.
    uint256 constant MINIMUM_YTOKEN_AMOUNT = 1000;

    /// @notice The burn address.
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    /// @notice Returns the ReserveData of a certain reserve
    mapping(address => DataTypes.ReserveData) public reserves;

    /// @notice The address of the leverager.
    address public leverager;

    /// @notice Pause mechanism
    bool public paused;

    /// @notice Precision when dealing with ReserveData
    uint256 constant PRECISION = 1e27;

    /// @notice Checks whether the contract is paused or not.
    modifier notPaused() {
        require(!paused, "contract paused");
        _;
    }

    constructor() Ownable(msg.sender) {}

    /// @notice initialize a reserve pool for an asset
    function initReserve(address asset) external onlyOwner notPaused {
        require(reserves[asset].lastUpdateTimestamp == 0, "asset already initialized");

        // new a yToken contract
        string memory name = string(abi.encodePacked(ERC20(asset).name(), "Yieldoor yAsset"));
        string memory symbol = string(abi.encodePacked("y", ERC20(asset).symbol()));
        uint8 decimals = ERC20(asset).decimals();

        address _yToken = address(new yToken(name, symbol, decimals, asset));

        DataTypes.ReserveData storage reserveData = reserves[asset];
        reserveData.setActive(true);
        reserveData.setBorrowingEnabled(true);

        initReserve(reserveData, _yToken, type(uint256).max);
    }

    /// @notice Deposits a lender's asset into yAsset.
    /// @param asset Asset to deposit
    /// @param amount The amount of asset to deposit
    /// @param onBehalfOf The address which should receive the minted yAsset
    function deposit(address asset, uint256 amount, address onBehalfOf)
        public
        notPaused
        nonReentrant
        returns (uint256 yTokenAmount)
    {
        yTokenAmount = _deposit(asset, amount, onBehalfOf);
    }

    /// @notice Redeems a lender's yAsset into underlying asset
    /// @param underlyingAsset The underlying asset's address
    /// @param yAssetAmount The amount of yAsset the lender wishes to redeem
    /// @param to The address which should receive the underlying tokens.
    function redeem(address underlyingAsset, uint256 yAssetAmount, address to)
        public
        notPaused
        nonReentrant
        returns (uint256 underlyingTokenAmount)
    {
        DataTypes.ReserveData storage reserve = getReserve(underlyingAsset);

        IyToken yTokenAddress = IyToken(reserve.yTokenAddress);

        if (yAssetAmount == type(uint256).max) {
            yAssetAmount = yTokenAddress.balanceOf(_msgSender());
        }
        // transfer yTokens to this contract
        IERC20(yTokenAddress).safeTransferFrom(msg.sender, address(this), yAssetAmount);

        // calculate underlying tokens using yTokens
        underlyingTokenAmount = _redeem(underlyingAsset, yTokenAddress, yAssetAmount, to);
    }

    /// @notice Internal function which performs the deposit and updates Reserve's state
    function _deposit(address asset, uint256 amount, address onBehalfOf) internal returns (uint256 yTokenAmount) {
        DataTypes.ReserveData storage reserve = getReserve(asset);
        require(!reserve.getFrozen(), "reserve frozen");
        // update states
        reserve.updateState();

        // validate
        reserve.checkCapacity(amount);

        uint256 exchangeRate = reserve.reserveToYTokenExchangeRate();

        IyToken yTokenAddress = IyToken(reserve.yTokenAddress);
        IERC20(asset).safeTransferFrom(msg.sender, address(yTokenAddress), amount);

        // Mint yTokens for the user
        yTokenAmount = amount * exchangeRate / (PRECISION);

        require(yTokenAmount > MINIMUM_YTOKEN_AMOUNT, "deposit is dust amount");
        if (yTokenAddress.totalSupply() == 0) {
            // Burn the first 1000 yToken, to defend against lp inflation attacks
            yTokenAddress.mint(DEAD_ADDRESS, MINIMUM_YTOKEN_AMOUNT);

            yTokenAmount -= MINIMUM_YTOKEN_AMOUNT;
        }

        yTokenAddress.mint(onBehalfOf, yTokenAmount);
        reserve.underlyingBalance += amount;
        // update the interest rate after the deposit
        reserve.updateInterestRates();
    }

    /// @notice Internal function which performs the redeem of yAsset into underlying
    function _redeem(address underlying, IyToken yTokenAddress, uint256 yAssetAmount, address to) internal returns (uint256 underlyingTokenAmount) {
        DataTypes.ReserveData storage reserve = getReserve(underlying);
        // update states
        reserve.updateState();

        // calculate underlying tokens using yTokens
        underlyingTokenAmount = reserve.yTokenToReserveExchangeRate() * yAssetAmount / PRECISION;

        require(underlyingTokenAmount <= reserve.availableLiquidity(), "not enough available liquidity");

        // burn yTokens and transfer the underlying tokens to receiver
        yTokenAddress.burn(to, yAssetAmount, underlyingTokenAmount);

        // update the interest rate after the redeem

        reserve.underlyingBalance -= underlyingTokenAmount;
        reserve.updateInterestRates();
    }

    /// @notice Allows a whitelisted borrower to borrow funds
    /// @param asset Asset to borrow
    /// @param amount Amount to borrow
    function borrow(address asset, uint256 amount) external notPaused nonReentrant {
        require(msg.sender == leverager, "borrower not leverager");

        DataTypes.ReserveData storage reserve = getReserve(asset);

        require(!reserve.getFrozen(), "reserve frozen");
        require(reserve.getBorrowingEnabled(), "borrowing disabled");

        // update states
        reserve.updateState();

        require(amount <= reserve.availableLiquidity(), "not enough available liquidity");

        reserve.totalBorrows += amount;
        reserve.underlyingBalance -= amount;

        // The receiver of the underlying tokens must be the farming contract (_msgSender())
        IyToken(reserve.yTokenAddress).transferUnderlyingTo(_msgSender(), amount);

        reserve.updateInterestRates();
    }

    /// @notice Modified from original version to accept repayments even when contract is paused
    /// @notice Repay function which allows whitelisted borrowers to repay their loan
    /// @dev Due to rounding down, totalBorrows might be a few wei less than what the Leverager tries to repay.
    /// @param asset Asset to repay
    /// @param amount Amount to repay
    function repay(address asset, uint256 amount) external nonReentrant returns (uint256) {
        require(msg.sender == leverager, "borrower not leverager");
        DataTypes.ReserveData storage reserve = getReserve(asset);
        // update states
        reserve.updateState();

        uint256 totalBorrowsCache = reserve.totalBorrows;
        if (amount > totalBorrowsCache) {
            amount = totalBorrowsCache;
        }

        reserve.totalBorrows -= amount;
        reserve.underlyingBalance += amount;

        // Transfer the underlying tokens from the vaultPosition to the yToken contract
        IERC20(asset).safeTransferFrom(_msgSender(), reserve.yTokenAddress, amount);

        reserve.updateInterestRates();

        return amount;
    }

    /// @notice Allows leverager to pull tokens.
    /// @dev Should always push the same amount of tokens back, at the end of the transaction
    function pullFunds(address asset, uint256 amount) external nonReentrant {
        require(msg.sender == leverager, "borrower not leverager");

        IyToken(getReserve(asset).yTokenAddress).transferUnderlyingTo(_msgSender(), amount);
    }

    /// @notice Allows leverager to push back funds to yAsset
    function pushFunds(address asset, uint256 amount) external nonReentrant {
        require(msg.sender == leverager, "borrower not leverager");

        IERC20(asset).safeTransferFrom(msg.sender, getReserve(asset).yTokenAddress, amount);
    }

    /// @notice Internal function which initializes a reserve
    function initReserve(DataTypes.ReserveData storage reserveData, address yTokenAddress, uint256 reserveCapacity)
        internal
    {
        reserveData.yTokenAddress = yTokenAddress;
        reserveData.reserveCapacity = reserveCapacity;

        reserveData.lastUpdateTimestamp = uint128(block.timestamp);
        reserveData.borrowingIndex = PRECISION;

        // set initial borrowing rate
        // (0%, 0%) -> (80%, 20%) -> (90%, 50%) -> (100%, 150%)
        setBorrowingRateConfig(reserveData, 8000, 2000, 9000, 5000, 15000);
    }

    /// @notice Internal function which sets the BorrowingRateConfig
    /// @dev input in basis points
    function setBorrowingRateConfig(
        DataTypes.ReserveData storage reserve,
        uint16 utilizationA,
        uint16 borrowingRateA,
        uint16 utilizationB,
        uint16 borrowingRateB,
        uint16 maxBorrowingRate
    ) internal {
        // (0%, 0%) -> (utilizationA, borrowingRateA) -> (utilizationB, borrowingRateB) -> (100%, maxBorrowingRate)
        reserve.borrowingRateConfig.utilizationA = PRECISION * utilizationA / 10_000;

        reserve.borrowingRateConfig.borrowingRateA = PRECISION * borrowingRateA / 10_000;

        reserve.borrowingRateConfig.utilizationB = PRECISION * utilizationB / 10_000;

        reserve.borrowingRateConfig.borrowingRateB = PRECISION * borrowingRateB / 10_000;

        reserve.borrowingRateConfig.maxBorrowingRate = PRECISION * maxBorrowingRate / 10_000;
    }

    /// @notice internal function which gets the ReserveData for an asset
    /// @dev Reverts if the Reserve is not active
    function getReserve(address asset) internal view returns (DataTypes.ReserveData storage reserve) {
        reserve = reserves[asset];
        require(reserve.getActive(), "reserve is not active");
    }

    /// @notice View function to get a Reserve's current borrowing index.
    function getCurrentBorrowingIndex(address asset) public view returns (uint256) {
        return reserves[asset].latestBorrowingIndex();
    }

    /// @notice View function to get an Reserve's yAsset address
    function getYTokenAddress(address asset) public view returns (address) {
        return reserves[asset].yTokenAddress;
    }

    /// @notice View function which returns the yAsset/asset exchange rate
    function exchangeRateOfReserve(address asset) public view returns (uint256) {
        return reserves[asset].yTokenToReserveExchangeRate();
    }

    /// @notice View function which returns the utilization rate of a reserve
    function utilizationRateOfReserve(address asset) public view returns (uint256) {
        return reserves[asset].utilizationRate();
    }

    /// @notice View function which returns the current borrowing rate of a reserve
    function borrowingRateOfReserve(address asset) public view returns (uint256) {
        return uint256(reserves[asset].borrowingRate());
    }

    /// @notice View function which returns the current total liquidity of a yAsset
    function totalLiquidityOfReserve(address asset) public view returns (uint256 totalLiquidity) {
        (totalLiquidity,) = reserves[asset].totalLiquidityAndBorrows();
    }

    /// @notice View Function which returns the current total borrows.
    function totalBorrowsOfReserve(address asset) public view returns (uint256 totalBorrows) {
        (, totalBorrows) = reserves[asset].totalLiquidityAndBorrows();
    }

    //----------------->>>>>  Set with Admin <<<<<-----------------
    function emergencyPauseAll() external onlyOwner {
        paused = true;
    }

    function unPauseAll() external onlyOwner {
        paused = false;
    }

    // Here, activate and deactive reserve functions were removed, as they do not bring any upside
    // But can result in users being unable to withdraw their assets out.

    /// @notice Freezing a reserve prevents new deposits and borrows, but allows redeems and repayments
    function freezeReserve(address asset) public onlyOwner notPaused {
        reserves[asset].setFrozen(true);
    }

    /// @notice unFreezes a reserve
    function unFreezeReserve(address asset) public onlyOwner notPaused {
        reserves[asset].setFrozen(false);
    }

    /// @notice Enables borrowing a certain asset
    function enableBorrowing(address asset) public onlyOwner notPaused {
        reserves[asset].setBorrowingEnabled(true);
    }

    /// @notice Disables borrowing a certain asset
    function disableBorrowing(address asset) public onlyOwner notPaused {
        reserves[asset].setBorrowingEnabled(false);
    }

    /// @notice Sets the BorrowingRateConfig for an asset
    function setBorrowingRateConfig(
        address asset,
        uint16 utilizationA,
        uint16 borrowingRateA,
        uint16 utilizationB,
        uint16 borrowingRateB,
        uint16 maxBorrowingRate
    ) public onlyOwner notPaused {
        setBorrowingRateConfig(reserves[asset], utilizationA, borrowingRateA, utilizationB, borrowingRateB, maxBorrowingRate);
    }

    /// @notice Sets the reserve capacity for an asset
    function setReserveCapacity(address asset, uint256 cap) public onlyOwner notPaused {
        reserves[asset].reserveCapacity = cap;
    }

    /// @notice Sets the Leverage params for a reserve
    /// @dev Checks against it are performed within the Leverager
    function setLeverageParams(address asset, uint256 _maxBorrow, uint256 _maxLeverage) external onlyOwner {
        DataTypes.ReserveData storage reserve = reserves[asset];

        reserve.leverageParams.maxIndividualBorrow = _maxBorrow;
        reserve.leverageParams.maxLeverage = _maxLeverage;
    }

    /// @notice Sets the leverager contract
    /// @dev Can only be set once
    function setLeverager(address _leverager) external onlyOwner {
        require(leverager == address(0), "leverager can only be set once");
        require(_leverager != address(0), "leverager can't be address(0)");
        leverager = _leverager;
    }

    /// @notice View function which returns the Leverage Params for an asset
    function getLeverageParams(address asset) public view returns (uint256, uint256) {
        DataTypes.ReserveData storage reserve = getReserve(asset);
        return (reserve.leverageParams.maxIndividualBorrow, reserve.leverageParams.maxLeverage);
    }
}
