// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {Ownable} from "@solady/auth/Ownable.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";

import {IStrategy} from "./interfaces/IStrategy.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswapV3Pool.sol";
import {TickMath} from "./libraries/TickMath.sol";
import {LiquidityAmounts} from "./libraries/LiquidityAmounts.sol";

/// @title Strategy
/// @author @deadrosesxyz
contract Strategy is Ownable, IStrategy {
    using SafeTransferLib for address;
    using TickMath for int24;

    event NewMainTicks(int24, int24);
    event NewSecondaryTicks(int24, int24);

    /// @notice Address of the vault utilizing this Strategy
    address immutable public vault;

    /// @notice The TWAP interval based on which we get the underlying pool's price
    uint32 public twap;

    /// @notice The tickspacing of the underlying pool
    int24 immutable public tickSpacing;

    /// @notice The maximum deviation allowed between TWAP price and spot price
    int24 public tickTwapDeviation;

    /// @notice The maximum deviation allowed between two consecutive observations
    int24 public maxObservationDeviation;

    /// @notice the width of the main position
    uint24 public positionWidth;

    /// @notice the address which receives the accrued protocol fees
    address public feeRecipient;

    /// @notice the address of the rebalancer
    address public rebalancer;

    /// @notice The main position.
    /// @dev Upon rebalancing this position should be 50:50 (or as close as it can get, due to pool's tickspacing)
    Position public mainPosition;

    /// @notice The Secondary position
    /// @dev Upon rebalancing, this position is always Out-Of-Range and is entirely filled by one of the assets.
    Position public secondaryPosition;

    /// @notice The vesting position.
    /// @dev In order to incentivize LPs, owners can add a vesting position which is distributed to users over time.
    VestingPosition public vestPosition;

    /// @notice The address of the first token in the pool
    address immutable public token0;

    /// @notice The address of the second token in the pool
    address immutable public token1;

    /// @notice the address of the underlying pool
    address immutable public pool;

    /// @notice The precision used when calculating the pool's price
    uint256 constant PRECISION = 1e30;

    /// @notice The minimum time interval that needs to have passed since last rebalance, in order to trigger a new one.
    uint256 public rebalanceInterval;

    /// @notice The timestamp of the last rebalance
    uint256 public lastRebalance;

    /// @notice The current protocol fee, in basis points (10_000 = 100%)
    uint256 public protocolFee;

    /// @notice Whether there's a position being vested currently.
    bool public ongoingVestingPosition;

    /**
     * @param uniPool The underlying Uniswap pool.
     * @param _vault The vault utilizing this strategy
     * @param _rebalancer The rebalancer which will perform rebalancing and compounds
     * @param _feeRecipient The address which will receive protocol fees
     */
    constructor(address uniPool, address _vault, address _rebalancer, address _feeRecipient) {
        _initializeOwner(msg.sender);

        token0 = IUniswapV3Pool(uniPool).token0();
        token1 = IUniswapV3Pool(uniPool).token1();
        pool = uniPool;
        vault = _vault;
        token0.safeApproveWithRetry(_vault, type(uint256).max);
        token1.safeApproveWithRetry(_vault, type(uint256).max);
        rebalancer = _rebalancer;
        tickSpacing = IUniswapV3Pool(pool).tickSpacing();
        twap = 300; // 5 minutes
        tickTwapDeviation = 200; // ~2%
        positionWidth = uint24(4 * tickSpacing);
        (, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();
        _setMainTicks(tick);
        _setSecondaryPositionsTicks(tick);
        lastRebalance = block.timestamp;
        rebalanceInterval = 360;
        feeRecipient = _feeRecipient;
        maxObservationDeviation = 100;
        protocolFee = 900;
    }

    /// @notice Allows only the vault to call certain functions
    modifier onlyVault() {
        require(msg.sender == vault, "only callable by Vault");
        _;
    }

    /// @notice Allows only rebalancer to call certain functions
    modifier onlyRebalancer() {
        require(msg.sender == rebalancer, "only callable by rebalancer");
        _;
    }

    /// @notice Returns the token0/token1 spot price in 1e30 precision
    function price() public view returns (uint256 _price) {
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();
        _price = FixedPointMathLib.fullMulDiv(sqrtPriceX96, 1e15, 2 ** 96) ** 2;
    }

    /// @notice Withdraws a user's portion of the assets
    /// @dev Withdraws the portion evenly from the main position, secondary position and idle balances
    /// @dev Assumes collectFees has been called right before this call
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
    }

    /// @notice internal function to save reading ticks multiple times from storage
    function _collectFees(int24 mainTickLower, int24 mainTickUpper, uint128 mainLiquidity,
                          int24 secTickLower , int24 secTickUpper,  uint128 secLiquidity) internal {
        (uint256 preBal0, uint256 preBal1) = idleBalances();

        if (mainLiquidity != 0) collectPositionFees(mainTickLower, mainTickUpper);
        if (secLiquidity  != 0) collectPositionFees(secTickLower , secTickUpper);

        bool ongoingVestingPositionCache = ongoingVestingPosition;
        if (ongoingVestingPositionCache) {
            collectPositionFees(vestPosition.tickLower, vestPosition.tickUpper);
        }

        (uint256 afterBal0, uint256 afterBal1) = idleBalances();

        (uint256 protocolFeeCache, address feeRecipientCache) = (protocolFee, feeRecipient);

        uint256 protocolFees0 = (afterBal0 - preBal0) * protocolFeeCache / 10_000;
        uint256 protocolFees1 = (afterBal1 - preBal1) * protocolFeeCache / 10_000;

        if (protocolFees0 > 0) token0.safeTransfer(feeRecipientCache, protocolFees0);
        if (protocolFees1 > 0) token1.safeTransfer(feeRecipientCache, protocolFees1);

        if (ongoingVestingPositionCache) {
            _withdrawPartOfVestingPosition(); // doing that now, otherwise we'd charge protocol fee for the vested position
        }
    }

    /// @notice Collects all outstanding position fees
    /// @notice In case there's ongoing vested position, collects the already vested part of it.
    function collectFees() public {
        _collectFees(mainPosition.tickLower, mainPosition.tickUpper, mainPosition.liquidity,
                     secondaryPosition.tickLower, secondaryPosition.tickUpper, secondaryPosition.liquidity);
    }

    /// @notice Collects the accumulated fees for a certain position
    /// @dev Does not check the actually collected values for simplicity.
    function collectPositionFees(int24 tickLower, int24 tickUpper) internal {
        IUniswapV3Pool(pool).burn(tickLower, tickUpper, 0);
        IUniswapV3Pool(pool).collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
    }

    /// @notice The funds within the contract which are not currently added as liquidity
    function idleBalances() public view returns (uint256 amount0, uint256 amount1) {
        amount0 = IERC20(token0).balanceOf(address(this));
        amount1 = IERC20(token1).balanceOf(address(this));
    }

    /// @notice Removes liquidity from old positions, calculates new ones and adds liquidity to them
    /// @dev Only callable by Rebalancer. Even though it is trusted, some precautions are still taken within the contract itself.
    function rebalance() public onlyRebalancer {
        require(block.timestamp - lastRebalance >= rebalanceInterval, "too soon since last rebalance");

        _requirePriceWithinRange(); // we verify that the pool's price is currently not manipulated

        {
            // cache current main & secondary position fields
            (int24 mainTickLower, int24 mainTickUpper, uint128 mainLiquidity)
                = (mainPosition.tickLower, mainPosition.tickUpper, mainPosition.liquidity);
            (int24 secTickLower , int24 secTickUpper,  uint128 secLiquidity)
                = (secondaryPosition.tickLower, secondaryPosition.tickUpper, secondaryPosition.liquidity);

            // pass cached fields to collect fees
            _collectFees(mainTickLower, mainTickUpper, mainLiquidity,
                         secTickLower , secTickUpper,  secLiquidity);

            // remove all liquidity from both the Main Position and the Secondary position
            _removeFromPosition(mainLiquidity, mainTickLower, mainTickUpper);
            _removeFromPosition(secLiquidity, secTickLower, secTickUpper);
            mainPosition.liquidity = 0;
            secondaryPosition.liquidity = 0;

            // cached ticks & liquidity no longer valid past this point
        }
    
        (uint256 amount0, uint256 amount1) = idleBalances();

        (uint160 sqrtPriceX96, int24 tick,,,,,) = IUniswapV3Pool(pool).slot0();

        (int24 newTickLower, int24 newTickUpper) = _setMainTicks(tick);
        (amount0, amount1) = _addLiquidityToMainPosition(sqrtPriceX96, amount0, amount1, newTickLower, newTickUpper);

        (newTickLower, newTickUpper) = _setSecondaryPositionsTicks(tick);
        _addLiquidityToSecondaryPosition(sqrtPriceX96, amount0, amount1, newTickLower, newTickUpper);

        lastRebalance = block.timestamp;
    }

    /// @notice Adds as much as possible of the idle funds within the positions
    /// @dev Depending on the positions/ pool's price, it might still not use the entirety of the idle funds
    function compound() public onlyRebalancer {
        _requirePriceWithinRange();
        collectFees();

        (uint256 bal0, uint256 bal1) = idleBalances();
        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        (bal0, bal1) = _addLiquidityToMainPosition(sqrtPriceX96, bal0, bal1, mainPosition.tickLower, mainPosition.tickUpper);
        _addLiquidityToSecondaryPosition(sqrtPriceX96, bal0, bal1, secondaryPosition.tickLower, secondaryPosition.tickUpper);
    }

    /// @notice Calculates and sets the ticks of the main position
    /// @dev Checks if the nearest initializable tick is lower or higher than the current tick
    function _setMainTicks(int24 tick) internal returns (int24 newTickLower, int24 newTickUpper) {
        int24 halfWidth = int24(positionWidth / 2);
        int24 modulo = tick % tickSpacing;
        if (modulo < 0) modulo += tickSpacing; // if tick is negative, modulo is also negative
        bool isLowerSided = modulo < (tickSpacing / 2);

        int24 tickBorder = tick - modulo;
        if (!isLowerSided) tickBorder += tickSpacing;

        newTickLower = tickBorder - halfWidth;
        newTickUpper = tickBorder + halfWidth;

        mainPosition.tickLower = newTickLower;
        mainPosition.tickUpper = newTickUpper;

        emit NewMainTicks(newTickLower, newTickUpper);
    }

    /// @param amount0 Max amount of token0 to add as liquidity to the main position
    /// @param amount1 Max amount of token1 to add as liquidity to the main position
    /// @param sqrtPriceX96 The current sqrtPriceX96 of the underlying Uniswap pool
    /// @notice Adds as much liquidity to the main position, as possible (based on amount0 and amount1)
    /// @dev Returns the unused amounts of token0 and token1.
    function _addLiquidityToMainPosition(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper)
        internal
        returns (uint256 remaining0, uint256 remaining1)
    {
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
        remaining0 = amount0 - used0;
        remaining1 = amount1 - used1;

        mainPosition.liquidity += liquidity;
    }

    /// @param amount0 Max amount of token0 to add as liquidity to the secondary position
    /// @param amount1 Max amount of token1 to add as liquidity to the secondary position
    /// @param sqrtPriceX96 The current sqrtPriceX96 of the underlying Uniswap pool
    function _addLiquidityToSecondaryPosition(uint160 sqrtPriceX96, uint256 amount0, uint256 amount1, int24 tickLower, int24 tickUpper) internal {
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

    /// @notice Returns whether price is within range
    /// @dev Makes sure difference between TWAP and spot price is within acceptable deviation
    /// @dev Makes sure there hasn't been big price swings between consecutive observations
    function _priceWithinRange() internal view returns (bool) {
        uint32 twapCache = twap;

        int24 _twapTickOut = _twapTick(twapCache);
        (, int24 currentTick,,,,,) = IUniswapV3Pool(pool).slot0();

        int24 tickTwapDeviationCache = tickTwapDeviation;

        int24 minTick = _twapTickOut - tickTwapDeviationCache;
        int24 maxTick = _twapTickOut + tickTwapDeviationCache;
        if (currentTick < minTick || currentTick > maxTick) return false;
        return _checkPoolActivity(twapCache);
    }


    /// @notice internal function to save reading `twap` multiple times from storage
    function _checkPoolActivity(uint32 twapCache) internal view returns(bool) {
        (, int24 tick, uint16 currentIndex, uint16 observationCardinality,,,) = IUniswapV3Pool(pool).slot0();

        uint32 lookAgo = uint32(block.timestamp) - twapCache;

        (uint32 nextTimestamp, int56 nextCumulativeTick,,) = IUniswapV3Pool(pool).observations(currentIndex);

        int24 nextTick = tick;

        int24 maxObservationDeviationCache = maxObservationDeviation;

        for (uint16 i = 1; i <= observationCardinality; i++) {
            uint256 index = (observationCardinality + currentIndex - i) % observationCardinality;
            (uint32 timestamp, int56 tickCumulative,,) = IUniswapV3Pool(pool).observations(index);
            if (timestamp == 0) {
                revert("timestamp 0");
            }

            tick = int24((nextCumulativeTick - tickCumulative) / int56(uint56(nextTimestamp - timestamp)));

            (nextTimestamp, nextCumulativeTick) = (timestamp, tickCumulative);
            int24 delta = nextTick - tick;

            if (delta > maxObservationDeviationCache || delta < -maxObservationDeviationCache) {
                return false;
            }

            if (timestamp < lookAgo) {
                return true;
            }
            nextTick = tick;
        }

        return false;
    }

    /// @notice Checks the pool prices in consecutive observations, up to TWAP ago.
    /// @dev If there aren't enough observations to reach TWAP ago, returns false
    function checkPoolActivity() public view returns (bool) {
        return _checkPoolActivity(twap);
    }

    /// @notice internal function to save reading `twap` multiple times from storage
    function _twapTick(uint32 twapCache) internal view returns(int24 tick) {
        uint32[] memory secondsAgos = new uint32[](2);
        secondsAgos[0] = twapCache;
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(pool).observe(secondsAgos);
        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int32 signedTwapCache = int32(secondsAgos[0]);

        tick = int24(tickCumulativesDelta / signedTwapCache);
        if (tickCumulativesDelta < 0 && (tickCumulativesDelta % signedTwapCache != 0)) tick--;
    }

    /// @notice Returns the TWAP tick
    function twapTick() public view returns (int24 tick) {
        tick = _twapTick(twap);
    }

    /// @notice Returns the TWAP price.
    function twapPrice() public view returns (uint256) {
        uint160 sqrtPrice = TickMath.getSqrtRatioAtTick(_twapTick(twap));
        return (FixedPointMathLib.fullMulDiv(sqrtPrice, 1e15, 2 ** 96) ** 2);
    }

    /// @notice Sets the secondary position ticks.
    /// @dev This position should always be created consisting of just one of the tokens
    /// @dev Should initially be Out-Of-Range
    function _setSecondaryPositionsTicks(int24 tick) internal returns (int24 newTickLower, int24 newTickUpper) {
        int24 modulo = tick % tickSpacing;
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        uint256 _price = price();
        uint256 bal0in1 = bal0 * _price / PRECISION; // usually either of them should be 0, but might be non-zero due to rounding when minting

        if (bal0in1 < bal1) {
            newTickLower = mainPosition.tickLower;
            newTickUpper = tick - modulo;
        } else {
            newTickLower = tick - modulo + tickSpacing;
            newTickUpper = mainPosition.tickUpper; // TODO check if these need to be reversed.
        }

        secondaryPosition.tickLower = newTickLower;
        secondaryPosition.tickUpper = newTickUpper;

        emit NewSecondaryTicks(newTickLower, newTickUpper);
    }

    /// @notice Changes the Main position's width and triggers a rebalance
    /// @dev Access control is performed within rebalance
    function changePositionWidth(uint24 _newWidth) external {
        require((_newWidth / 2) % uint24(tickSpacing) == 0, "half width should be divisible by tickSpacing");
        positionWidth = _newWidth;
        rebalance();
    }

    /// @notice Changes the rebalancer to new address
    function changeRebalancer(address newRebalancer) external onlyOwner {
        rebalancer = newRebalancer;
    }

    /// @notice Reverts if price is not within range
    function _requirePriceWithinRange() private view {
        require(_priceWithinRange(), "price out of range");
    }

    /// @notice Callback function of the underlying Uniswap pool
    /// @param amount0 Amount of token0 contract needs to send
    /// @param amount1 Amount of token1 contracts needs to send
    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes memory) external {
        require(msg.sender == pool, "only callable by pool");

        if (amount0 > 0) token0.safeTransfer(pool, amount0);
        if (amount1 > 0) token1.safeTransfer(pool, amount1);
    }

    /// @notice Creates a new position which is vested over time to the Vault depositors
    /// @param amount0 Amount of token0 to use when creating the position
    /// @param amount1 Amount of token1 to use when creating the position
    /// @param _vestDuration The duration over which the position will be vested
    /// @dev Any unused amounts of token0/ token1 are treated as a direct donation to the Vault
    function addVestingPosition(uint256 amount0, uint256 amount1, uint256 _vestDuration) external onlyVault {
        collectFees(); // we collect fees first, in case there hasn't been a call since previous vested position ended
        require(!ongoingVestingPosition, "there's a currently ongoing VestingPosition");

        _requirePriceWithinRange();
        VestingPosition memory vp;

        vp.tickLower = mainPosition.tickLower;
        vp.tickUpper = mainPosition.tickUpper;

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
        ongoingVestingPosition = true;
        vp.endTs = block.timestamp + _vestDuration;

        vestPosition = vp;
    }

    /// @notice Withdraw the already vested part of the VestingPosition
    function _withdrawPartOfVestingPosition() internal {
        if (vestPosition.lastUpdate == block.timestamp) return;
        VestingPosition memory vp = vestPosition;

        uint256 lastValid = block.timestamp < vp.endTs ? block.timestamp : vp.endTs;

        uint128 liquidityToRemove = lastValid == vp.endTs
            ? vp.remainingLiquidity
            : uint128(vp.initialLiquidity * (lastValid - vp.lastUpdate) / (vp.endTs - vp.startTs));

        _removeFromPosition(liquidityToRemove, vp.tickLower, vp.tickUpper);

        vp.remainingLiquidity -= liquidityToRemove;
        vp.lastUpdate = lastValid;

        vestPosition = vp;

        if (lastValid == vp.endTs) ongoingVestingPosition = false;
    }

    /// @notice Removes liquidity from a position and collects all funds
    /// @dev Expects fees to have been collect prior. If not, protocol will not receive protocol fee for them.
    /// @param liquidity Liquidity to remove from the posiiton
    /// @param tickLower The lower tick of the position
    /// @param tickUpper The upper tick of the position
    /// @return bal0 The amount of token0 received
    /// @return bal1 The amount of token1 received
    function _removeFromPosition(uint128 liquidity, int24 tickLower, int24 tickUpper)
        internal
        returns (uint256 bal0, uint256 bal1)
    {
        if (liquidity != 0) {
            (bal0, bal1) = IUniswapV3Pool(pool).burn(tickLower, tickUpper, liquidity);
            IUniswapV3Pool(pool).collect(address(this), tickLower, tickUpper, type(uint128).max, type(uint128).max);
        }
    }

    /// @notice Returns the current balances of the Strategy
    /// @dev Results will only be 100% accurate if collect fees has been called right before this
    /// @dev Otherwise, this will not include outstanding fees and the vested, but not yet claimed, part of VestingPosition
    /// @return amount0 The amount of token0 the strategy has
    /// @return amount1 The amount of token1 the strategy has
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

    /// @notice View function to get the main position
    function getMainPosition() external view returns (Position memory pos) {
        pos = mainPosition;
    }

    /// @notice View function to get the secondary position
    function getSecondaryPosition() external view returns (Position memory pos) {
        pos = secondaryPosition;
    }

    /// @notice View function to get the Vesting position
    function getVestingPosition() external view returns (VestingPosition memory pos) {
        pos = vestPosition;
    }

    /// @notice Changes the fee recipient to new address
    /// @param _newRecipient The address of the new fee recipient
    function changeFeeRecipient(address _newRecipient) external onlyOwner {
        require(_newRecipient != address(0), "can't be address(0)");
        feeRecipient = _newRecipient;
    }

    /// @notice Sets the new TWAP interval
    /// @param _twap The new TWAP interval
    function setTwap(uint32 _twap) external onlyOwner {
        require(_twap > 30, "twap has to be at least 30 seconds");
        twap = _twap;
    }

    /// @notice Sets the max accepted deviation between pool's spot price and TWAP price
    /// @param _tickTwapDeviation The new max accepted deviation
    function setTickTwapDeviation(uint24 _tickTwapDeviation) external onlyOwner {
        require(_tickTwapDeviation > 1, "new deviation must be above 1");
        tickTwapDeviation = int24(_tickTwapDeviation);
    }

    /// @notice Sets the new max accepted deviation between two consecutive observations
    /// @param _maxObservationDeviation The new max accepted deviation
    function setMaxObservationDeviation(uint24 _maxObservationDeviation) external onlyOwner {
        require(_maxObservationDeviation > 1, "new deviation must be above 1");
        maxObservationDeviation = int24(_maxObservationDeviation);
    }

    /// @notice Sets the new minimum interval that needs to have passed since last rebalance, in order to rebalance again
    /// @param _rebalanceInterval New interval
    function setRebalanceInterval(uint256 _rebalanceInterval) external onlyOwner {
        require(_rebalanceInterval > 30 && _rebalanceInterval < 7200, "new interval not within bounds");
        rebalanceInterval = _rebalanceInterval;
    }

    /// @notice Sets new protocol fee. Capped at 15%.
    /// @dev Collects fees first in order to not apply new protocol fee to previously accrued fees.
    function setProtocolFee(uint256 _protocolFee) external onlyOwner {
        require(_protocolFee <= 1500, "protocol fee can't be higher than 15%");
        collectFees();
        protocolFee = _protocolFee;
    }
}
