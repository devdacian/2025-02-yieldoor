// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {ReserveLogic} from "./libraries/ReserveLogic.sol";
import {DataTypes} from "./types/DataTypes.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {IyToken} from "./interfaces/IyToken.sol";
import {ITokenDeployer} from "./interfaces/ITokenDeployer.sol";
import {yToken} from "./yToken.sol";

contract LendingPool is ILendingPool, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using ReserveLogic for DataTypes.ReserveData;

    uint256 constant MINIMUM_ETOKEN_AMOUNT = 1000;
    address constant DEAD_ADDRESS = 0x000000000000000000000000000000000000dEaD;

    mapping(address => DataTypes.ReserveData) public reserves;

    mapping(address => bool) public borrowingWhiteList;

    bool public paused = false;

    ITokenDeployer tokenDeployer;
    uint256 constant PRECISION = 1e27;

    modifier notPaused() {
        require(!paused);
        _;
    }

    constructor() Ownable(msg.sender) {}

    /// @notice initialize a reserve pool for an asset
    function initReserve(address asset) external onlyOwner notPaused {
        require(reserves[asset].lastUpdateTimestamp == 0);

        // new a eToken contract
        string memory name = string(abi.encodePacked(ERC20(asset).name(), "Yieldoor yAsset"));
        string memory symbol = string(abi.encodePacked("y", ERC20(asset).symbol()));
        uint8 decimals = ERC20(asset).decimals();

        address _yToken = address(new yToken(name, symbol, decimals, asset));

        DataTypes.ReserveData storage reserveData = reserves[asset];
        reserveData.setActive(true);
        reserveData.setBorrowingEnabled(true);

        initReserve(reserveData, _yToken, type(uint256).max);
    }

    function deposit(address asset, uint256 amount, address onBehalfOf)
        public
        notPaused
        nonReentrant
        returns (uint256 eTokenAmount)
    {
        eTokenAmount = _deposit(asset, amount, onBehalfOf);
    }

    function redeem(address underlyingAsset, uint256 yAssetAmount, address to)
        public
        notPaused
        nonReentrant
        returns (uint256)
    {
        DataTypes.ReserveData storage reserve = getReserve(underlyingAsset);

        if (yAssetAmount == type(uint256).max) {
            yAssetAmount = IyToken(reserve.yTokenAddress).balanceOf(_msgSender());
        }
        // transfer eTokens to this contract
        IERC20(reserve.yTokenAddress).safeTransferFrom(msg.sender, address(this), yAssetAmount);

        // calculate underlying tokens using eTokens
        uint256 underlyingTokenAmount = _redeem(underlyingAsset, yAssetAmount, to);

        return (underlyingTokenAmount);
    }

    function _deposit(address asset, uint256 amount, address onBehalfOf) internal returns (uint256 eTokenAmount) {
        DataTypes.ReserveData storage reserve = getReserve(asset);
        require(!reserve.getFrozen());
        // update states
        reserve.updateState();

        // validate
        reserve.checkCapacity(amount);

        uint256 exchangeRate = reserve.reserveToETokenExchangeRate();

        IERC20(asset).safeTransferFrom(msg.sender, reserve.yTokenAddress, amount);

        // Mint eTokens for the user
        eTokenAmount = amount * exchangeRate / (PRECISION);

        require(eTokenAmount > MINIMUM_ETOKEN_AMOUNT);
        if (IyToken(reserve.yTokenAddress).totalSupply() == 0) {
            // Burn the first 1000 etoken, to defend against lp inflation attacks
            IyToken(reserve.yTokenAddress).mint(DEAD_ADDRESS, MINIMUM_ETOKEN_AMOUNT);

            eTokenAmount -= MINIMUM_ETOKEN_AMOUNT;
        }

        IyToken(reserve.yTokenAddress).mint(onBehalfOf, eTokenAmount);
        reserve.underlyingBalance += amount;
        // update the interest rate after the deposit
        reserve.updateInterestRates();
    }

    function _redeem(address underlying, uint256 yAssetAmount, address to) internal returns (uint256) {
        DataTypes.ReserveData storage reserve = getReserve(underlying);
        // update states
        reserve.updateState();

        // calculate underlying tokens using eTokens
        uint256 underlyingTokenAmount = reserve.eTokenToReserveExchangeRate() * yAssetAmount / PRECISION;

        require(underlyingTokenAmount <= reserve.availableLiquidity());

        // burn eTokens and transfer the underlying tokens to receiver
        IyToken(reserve.yTokenAddress).burn(to, yAssetAmount, underlyingTokenAmount);

        // update the interest rate after the redeem

        reserve.underlyingBalance -= underlyingTokenAmount;
        reserve.updateInterestRates();

        return (underlyingTokenAmount);
    }

    function borrow(address asset, uint256 amount) external notPaused nonReentrant {
        require(borrowingWhiteList[_msgSender()]);

        DataTypes.ReserveData storage reserve = getReserve(asset);

        require(!reserve.getFrozen());
        require(reserve.getBorrowingEnabled());

        // update states
        reserve.updateState();

        require(amount <= reserve.availableLiquidity());

        reserve.totalBorrows += amount;
        reserve.underlyingBalance -= amount;

        // The receiver of the underlying tokens must be the farming contract (_msgSender())
        IyToken(reserve.yTokenAddress).transferUnderlyingTo(_msgSender(), amount);

        reserve.updateInterestRates();
    }

    function repay(address asset, uint256 amount) external notPaused nonReentrant returns (uint256) {
        require(borrowingWhiteList[_msgSender()]);
        DataTypes.ReserveData storage reserve = getReserve(asset);
        // update states
        reserve.updateState();

        if (amount > reserve.totalBorrows) {
            amount = reserve.totalBorrows;
        }

        reserve.totalBorrows -= amount;
        reserve.underlyingBalance += amount;

        // Transfer the underlying tokens from the vaultPosition to the eToken contract
        IERC20(asset).safeTransferFrom(_msgSender(), reserve.yTokenAddress, amount);

        reserve.updateInterestRates();

        return amount;
    }

    function pullFunds(address asset, uint256 amount) external {
        require(borrowingWhiteList[_msgSender()]);
        DataTypes.ReserveData memory reserve = getReserve(asset);

        IyToken(reserve.yTokenAddress).transferUnderlyingTo(_msgSender(), amount);
    }

    function pushFunds(address asset, uint256 amount) external {
        require(borrowingWhiteList[_msgSender()], "not whitelisted");
        DataTypes.ReserveData memory reserve = getReserve(asset);

        IERC20(asset).safeTransferFrom(msg.sender, reserve.yTokenAddress, amount);
    }

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

    // input in basis points
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

    function getReserve(address asset) internal view returns (DataTypes.ReserveData storage reserve) {
        reserve = reserves[asset];
        require(reserve.getActive(), "reserve is not active");
    }

    function getCurrentBorrowingIndex(address asset) public view returns (uint256) {
        DataTypes.ReserveData storage reserve = reserves[asset];

        return reserve.latestBorrowingIndex();
    }

    function getyTokenAddress(address asset) public view returns (address) {
        DataTypes.ReserveData storage reserve = reserves[asset];
        return reserve.yTokenAddress;
    }

    function exchangeRateOfReserve(address asset) public view returns (uint256) {
        DataTypes.ReserveData storage reserve = reserves[asset];
        return reserve.eTokenToReserveExchangeRate();
    }

    function utilizationRateOfReserve(address asset) public view returns (uint256) {
        DataTypes.ReserveData storage reserve = reserves[asset];
        return reserve.utilizationRate();
    }

    function borrowingRateOfReserve(address asset) public view returns (uint256) {
        DataTypes.ReserveData storage reserve = reserves[asset];
        return uint256(reserve.borrowingRate());
    }

    function totalLiquidityOfReserve(address asset) public view returns (uint256 totalLiquidity) {
        DataTypes.ReserveData storage reserve = reserves[asset];
        (totalLiquidity,) = reserve.totalLiquidityAndBorrows();
    }

    function totalBorrowsOfReserve(address asset) public view returns (uint256 totalBorrows) {
        DataTypes.ReserveData storage reserve = reserves[asset];
        (, totalBorrows) = reserve.totalLiquidityAndBorrows();
    }

    //----------------->>>>>  Set with Admin <<<<<-----------------
    function emergencyPauseAll() external onlyOwner {
        paused = true;
    }

    function unPauseAll() external onlyOwner {
        paused = false;
    }

    function activateReserve(address asset) public onlyOwner notPaused {
        DataTypes.ReserveData storage reserve = reserves[asset];
        reserve.setActive(true);
    }

    function deActivateReserve(address asset) public onlyOwner notPaused {
        DataTypes.ReserveData storage reserve = reserves[asset];
        reserve.setActive(false);
    }

    function freezeReserve(address asset) public onlyOwner notPaused {
        DataTypes.ReserveData storage reserve = reserves[asset];
        reserve.setFrozen(true);
    }

    function unFreezeReserve(address asset) public onlyOwner notPaused {
        DataTypes.ReserveData storage reserve = reserves[asset];
        reserve.setFrozen(false);
    }

    function enableBorrowing(address asset) public onlyOwner notPaused {
        DataTypes.ReserveData storage reserve = reserves[asset];
        reserve.setBorrowingEnabled(true);
    }

    function disableBorrowing(address asset) public onlyOwner notPaused {
        DataTypes.ReserveData storage reserve = reserves[asset];
        reserve.setBorrowingEnabled(false);
    }

    // function setReserveFeeRate(address asset, uint16 _rate) public onlyOwner notPaused {
    //     require(_rate <= 10_000, "invalid percent");
    //     DataTypes.ReserveData storage reserve = reserves[asset];
    //     reserve.reserveFeeRate = _rate;
    // }

    function setBorrowingRateConfig(
        address asset,
        uint16 utilizationA,
        uint16 borrowingRateA,
        uint16 utilizationB,
        uint16 borrowingRateB,
        uint16 maxBorrowingRate
    ) public onlyOwner notPaused {
        DataTypes.ReserveData storage reserve = reserves[asset];
        setBorrowingRateConfig(reserve, utilizationA, borrowingRateA, utilizationB, borrowingRateB, maxBorrowingRate);
    }

    function setReserveCapacity(address asset, uint256 cap) public onlyOwner notPaused {
        DataTypes.ReserveData storage reserve = reserves[asset];

        reserve.reserveCapacity = cap;
    }

    function setLeverageParams(address asset, uint256 _maxBorrow, uint256 _maxLeverage) external onlyOwner {
        DataTypes.ReserveData storage reserve = reserves[asset];

        reserve.leverageParams.maxIndividualBorrow = _maxBorrow;
        reserve.leverageParams.maxLeverage = _maxLeverage;
    }

    function addToWhitelist(address addr) external onlyOwner {
        borrowingWhiteList[addr] = true;
    }

    function getLeverageParams(address asset) public view returns (uint256, uint256) {
        DataTypes.ReserveData memory reserve = getReserve(asset);
        return (reserve.leverageParams.maxIndividualBorrow, reserve.leverageParams.maxLeverage);
    }
}
