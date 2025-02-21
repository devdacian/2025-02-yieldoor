// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {FullMath} from "./libraries/FullMath.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import "forge-std/Test.sol";

/*
ToDo list: 
- add nonReentrant guards
- set admin restricted roles (rebalancer)
- fee beacon 
- add totalBalances function
- fix Vesting position logic
- fix missing implementation functions
*/

contract Strategy is Ownable, IStrategy {
    using SafeERC20 for IERC20;
    using TickMath for int24;

    event NewMainTicks(int24, int24);
    event NewSecondaryTicks(int24, int24);

    address public vault;
    bool public checkActivity;
    uint32 twap;
    int24 tickSpacing;
    int24 tickTwapDeviation;
    int24 maxObservationDeviation;
    int24 lastCenterTick;
    uint24 public positionWidth;
    address public feeRecipient;
    address public rebalancer;
    Position mainPosition;
    Position secondaryPosition;
    VestingPosition vestPosition;
    address public token0;
    address public token1;
    address public pool;
    uint256 constant PRECISION = 1e30;
    uint256 rebalanceInterval;
    uint256 lastRebalance;
    bool ongoingVestedPosition;

    constructor(
        address _token0,
        address _token1,
        address uniPool,
        address _vault,
        address _rebalancer,
        address _feeRecipient
    ) Ownable(msg.sender) {
        token0 = _token0;
        token1 = _token1;
        pool = uniPool;
        vault = _vault;
        IERC20(token0).forceApprove(_vault, type(uint256).max);
        IERC20(token1).forceApprove(_vault, type(uint256).max);
        rebalancer = _rebalancer;
        tickSpacing = IUniswapV3Pool(pool).tickSpacing();
        twap = 300; // 5 minutes
        tickTwapDeviation = 200; // ~2%
        positionWidth = uint24(4 * tickSpacing);
        (, lastCenterTick,,,,,) = IUniswapV3Pool(pool).slot0();
        _setMainTicks(lastCenterTick);
        _setSecondaryPositionsTicks(lastCenterTick);
        lastRebalance = block.timestamp;
        rebalanceInterval = 360;
        checkActivity = true;
        feeRecipient = _feeRecipient;
    }

    modifier onlyVault() {
        require(msg.sender == vault);
        _;
    }

    modifier onlyRebalancer() {
        require(msg.sender == rebalancer);
        _;
    }

    function price() public view returns (uint256 price) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        price = FullMath.mulDiv(sqrtPriceX96, 1e15, 2 ** 96) ** 2;
    }

    function withdrawPartial(uint256 shares, uint256 totalSupply)
        external
        onlyVault
        returns (uint256 amount0Out, uint256 amount1Out)
    {
        (uint256 bal0, uint256 bal1) = idleBalances(); // before withdrawing any liquidity, but after collecting fees.

        uint256 liqToRemove = mainPosition.liquidity * shares / totalSupply;
        (uint256 m0, uint256 m1) =
            _removeFromPosition(uint128(liqToRemove), mainPosition.tickLower, mainPosition.tickUpper);
        mainPosition.liquidity -= uint128(liqToRemove);

        liqToRemove = secondaryPosition.liquidity * shares / totalSupply;
        (uint256 s0, uint256 s1) =
            _removeFromPosition(uint128(liqToRemove), secondaryPosition.tickLower, secondaryPosition.tickUpper);
        secondaryPosition.liquidity -= uint128(liqToRemove);

        amount0Out = m0 + s0 + (bal0 * shares / totalSupply);
        amount1Out = m1 + s1 + (bal1 * shares / totalSupply);

        return (amount0Out, amount1Out);
    }

    function collectFees() public {
        (uint256 preBal0, uint256 preBal1) = idleBalances();

        if (mainPosition.liquidity != 0) collectPositionFees(mainPosition.tickLower, mainPosition.tickUpper);
        if (secondaryPosition.liquidity != 0) {
            collectPositionFees(secondaryPosition.tickLower, secondaryPosition.tickUpper);
        }
        if (ongoingVestedPosition) {
            collectPositionFees(vestPosition.tickLower, mainPosition.tickUpper);
        }

        (uint256 afterBal0, uint256 afterBal1) = idleBalances();

        uint256 protocolFee = _getProtocolFee();
        uint256 protocolFees0 = (afterBal0 - preBal0) * protocolFee / 10_000;
        uint256 protocolFees1 = (afterBal1 - preBal1) * protocolFee / 10_000;

        if (protocolFees0 > 0) IERC20(token0).safeTransfer(feeRecipient, protocolFees0);
        if (protocolFees1 > 0) IERC20(token1).safeTransfer(feeRecipient, protocolFees1);

        if (ongoingVestedPosition) {
            _withdrawPartOfVestingPosition(); // doing that now, otherwise we'd charge protocol fee for the vested position
        }
    }

    function collectPositionFees(int24 tickLower, int24 tickUpper) internal {
        IUniswapV3Pool(pool).burn(tickLower, tickUpper, 0);
        IUniswapV3Pool(pool).collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
    }

    function idleBalances() public view returns (uint256 amount0, uint256 amount1) {
        amount0 = IERC20(token0).balanceOf(address(this));
        amount1 = IERC20(token1).balanceOf(address(this));
    }

    function rebalance() public onlyRebalancer {
        require(block.timestamp - lastRebalance >= rebalanceInterval, "too soon since last rebalance");

        _requirePriceWithinRange();
        collectFees();

        _removeLiquidity();
        (uint256 amount0, uint256 amount1) = idleBalances();

        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        lastCenterTick = tick;

        _setMainTicks(tick);
        (amount0, amount1) = _addLiquidityToMainPosition(sqrtPriceX96, amount0, amount1);

        _setSecondaryPositionsTicks(tick);
        _addLiquidityToSecondaryPosition(sqrtPriceX96, amount0, amount1);
        lastRebalance = block.timestamp;
    }

    function compound() public onlyRebalancer {
        _requirePriceWithinRange();
        collectFees();

        (uint256 bal0, uint256 bal1) = idleBalances();
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        (bal0, bal1) = _addLiquidityToMainPosition(sqrtPriceX96, bal0, bal1);
        _addLiquidityToSecondaryPosition(sqrtPriceX96, bal0, bal1);
    }

    function _setMainTicks(int24 tick) internal {
        int24 halfWidth = int24(positionWidth / 2);
        int24 modulo = tick % tickSpacing;
        if (modulo < 0) modulo += tickSpacing;
        bool isLowerSided = modulo < halfWidth;

        int24 tickBorder = tick - modulo;
        if (!isLowerSided) tickBorder += tickSpacing;
        mainPosition.tickLower = tickBorder - halfWidth;
        mainPosition.tickUpper = tickBorder + halfWidth;

        emit NewMainTicks(tickBorder - halfWidth, tickBorder + halfWidth);
    }

    function _addLiquidityToMainPosition(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1)
        internal
        returns (uint256, uint256)
    {
        int24 tickLower = mainPosition.tickLower;
        int24 tickUpper = mainPosition.tickUpper;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );

        if (liquidity == 0) return (amount0, amount1);

        (uint256 used0, uint256 used1) =
            IUniswapV3Pool(pool).mint(address(this), tickLower, tickUpper, liquidity, "test");
        uint256 remaining0 = amount0 - used0;
        uint256 remaining1 = amount1 - used1;

        mainPosition.liquidity += liquidity;

        return (remaining0, remaining1);
    }

    function _addLiquidityToSecondaryPosition(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1) internal {
        int24 tickLower = secondaryPosition.tickLower;
        int24 tickUpper = secondaryPosition.tickUpper;
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(tickLower),
            TickMath.getSqrtRatioAtTick(tickUpper),
            amount0,
            amount1
        );

        if (liquidity > 0) IUniswapV3Pool(pool).mint(address(this), tickLower, tickUpper, liquidity, "test");
        secondaryPosition.liquidity += liquidity;
    }

    function _priceWithinRange() internal returns (bool) {
        int24 twapTick = twapTick();
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        int24 minTick = twapTick - tickTwapDeviation;
        int24 maxTick = twapTick + tickTwapDeviation;
        if (currentTick < minTick || currentTick > maxTick) return false;
        if (checkActivity) return checkPoolActivity();
        return true;
    }

    function checkPoolActivity() public view returns (bool) {
        (, int24 tick, uint16 currentIndex, uint16 observationCardinality,,,) = IUniswapV3Pool(pool).slot0();

        uint32 lookAgo = uint32(block.timestamp) - twap;

        (uint32 nextTimestamp, int56 nextCumulativeTick,,) = IUniswapV3Pool(pool).observations(currentIndex);

        int24 nextTick = tick;

        for (uint16 i = 1; i <= observationCardinality; i++) {
            uint256 index = (observationCardinality + currentIndex - i) % observationCardinality;
            (uint32 timestamp, int56 tickCumulative,,) = IUniswapV3Pool(pool).observations(index);
            if (timestamp == 0) {
                revert("timestamp 0");
            }

            tick = int24((nextCumulativeTick - tickCumulative) / int56(uint56(nextTimestamp - timestamp)));

            (nextTimestamp, nextCumulativeTick) = (timestamp, tickCumulative);
            int24 delta = nextTick - tick;

            if (delta > maxObservationDeviation || delta < -maxObservationDeviation) {
                return false;
            }

            if (timestamp < lookAgo) {
                return true;
            }
            nextTick = tick;
        }

        return false;
    }

    function twapTick() public view returns (int24) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twap;
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int24 tick = int24(tickCumulativesDelta / int32(twap));
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % int32(twap) != 0)) tick--;
        return tick;
    }

    function twapPrice() public view returns (uint256) {
        int24 tick = twapTick();
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(tick);
        return (FullMath.mulDiv(sqrtPrice, 1e15, 2 ** 96) ** 2);
    }

    function _setSecondaryPositionsTicks(int24 tick) internal {
        int24 modulo = tick % tickSpacing;
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 _price = price();
        uint256 bal0in1 = bal0 * _price / PRECISION; // usually either of them should be 0, but might be non-zero due to rounding when minting

        if (bal0in1 < bal1) {
            secondaryPosition.tickLower = mainPosition.tickLower;
            secondaryPosition.tickUpper = tick - modulo;
        } else {
            secondaryPosition.tickLower = tick - modulo + tickSpacing;
            secondaryPosition.tickUpper = mainPosition.tickUpper; // TODO check if these need to be reversed.
        }

        emit NewSecondaryTicks(secondaryPosition.tickLower, secondaryPosition.tickUpper);
    }

    function _removeLiquidity() internal {
        _removeFromPosition(mainPosition.liquidity, mainPosition.tickLower, mainPosition.tickUpper);
        _removeFromPosition(secondaryPosition.liquidity, secondaryPosition.tickLower, secondaryPosition.tickUpper);

        mainPosition.liquidity = 0;
        secondaryPosition.liquidity = 0;
    }

    // ToDo fix logic here
    function _getProtocolFee() internal view returns (uint256) {
        return 1;
    }

    // access control checked within rebalance
    function changePositionWidth(uint24 newWidth) external {
        positionWidth = newWidth;
        rebalance();
    }

    function changeRebalancer(address newRebalancer) external onlyOwner {
        rebalancer = newRebalancer;
    }

    function _requirePriceWithinRange() private {
        require(_priceWithinRange(), "price out of range");
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes memory) external {
        require(msg.sender == pool, "Error");

        if (amount0 > 0) IERC20(token0).safeTransfer(pool, amount0);
        if (amount1 > 0) IERC20(token1).safeTransfer(pool, amount1);
    }

    function addVestedPosition(uint256 amount0, uint256 amount1, uint256 _vestDuration) external onlyVault {
        require(!ongoingVestedPosition);
        _requirePriceWithinRange(); // add comment
        VestingPosition memory vp;

        vp.tickLower = mainPosition.tickLower;
        vp.tickUpper = mainPosition.tickUpper; // add comments

        (uint160 sqrtPrice,,,,,,) = IUniswapV3Pool(pool).slot0();
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPrice,
            TickMath.getSqrtRatioAtTick(vp.tickLower),
            TickMath.getSqrtRatioAtTick(vp.tickUpper),
            amount0,
            amount1
        );

        vp.initialLiquidity = liquidity;
        vp.remainingLiquidity = liquidity;

        IUniswapV3Pool(pool).mint(address(this), vp.tickLower, vp.tickUpper, liquidity, "");

        vp.startTs = block.timestamp;
        vp.lastUpdate = block.timestamp;
        ongoingVestedPosition = true;
        vp.endTs = block.timestamp + _vestDuration;

        vestPosition = vp;
    }

    function _withdrawPartOfVestingPosition() internal {
        if (vestPosition.lastUpdate == block.timestamp) return;
        VestingPosition memory vp = vestPosition;

        uint256 lastValid = block.timestamp < vp.endTs ? block.timestamp : vp.endTs; // ToDo: store everything in memory

        uint128 liquidityToRemove = lastValid == vp.endTs
            ? vp.remainingLiquidity
            : uint128(vp.initialLiquidity * (lastValid - vp.lastUpdate) / (vp.endTs - vp.startTs));

        _removeFromPosition(liquidityToRemove, vp.tickLower, vp.tickUpper);

        vp.remainingLiquidity -= liquidityToRemove;
        vp.lastUpdate = lastValid;

        vestPosition = vp;

        if (lastValid == vestPosition.endTs) ongoingVestedPosition = false;
    }

    function _removeFromPosition(uint128 liquidity, int24 tickLower, int24 tickUpper)
        internal
        returns (uint256, uint256)
    {
        if (liquidity != 0) {
            (uint256 bal0, uint256 bal1) = IUniswapV3Pool(pool).burn(tickLower, tickUpper, liquidity);
            IUniswapV3Pool(pool).collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
            return (bal0, bal1);
        }
    }

    // note: will only return correct amounts if fees have been collected. Otherwise, it will exclude unclaimed fees.
    function balances() public view returns (uint256 amount0, uint256 amount1) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        (uint256 idle0, uint256 idle1) = idleBalances();
        (uint256 m0, uint256 m1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(mainPosition.tickLower),
            TickMath.getSqrtRatioAtTick(mainPosition.tickUpper),
            mainPosition.liquidity
        );
        (uint256 s0, uint256 s1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96,
            TickMath.getSqrtRatioAtTick(secondaryPosition.tickLower),
            TickMath.getSqrtRatioAtTick(secondaryPosition.tickUpper),
            secondaryPosition.liquidity
        );

        amount0 = idle0 + m0 + s0;
        amount1 = idle1 + m1 + s1;
    }

    function changeFeeRecipient(address newRecipient) external onlyOwner {
        require(newRecipient != address(0));
        feeRecipient = newRecipient;
    }
}
