// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {Vault} from "../src/Vault.sol";
import {IVault} from "../src/interfaces/IVault.sol";
import {IStrategy} from "../src/interfaces/IStrategy.sol";
import {IUniswapV3Pool} from "../src/interfaces/IUniswapV3Pool.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {Strategy} from "../src/Strategy.sol";
import {IMainnetRouter} from "../src/interfaces/IMainnetRouter.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {TickMath} from "../src/libraries/TickMath.sol";

contract BaseTest is Test {
    IUniswapV3Pool pool = IUniswapV3Pool(0x99ac8cA7087fA4A2A1FB6357269965A2014ABc35);
    IERC20 wbtc = IERC20(0x2260FAC5E5542a773Aa44fBCfeDf7C193bc2C599); // token0
    IERC20 usdc = IERC20(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48); // token1
    address uniRouter = address(0xE592427A0AEce92De3Edee1F18E0157C05861564);
    address vault;
    address strategy;
    address rebalancer = address(1001);
    address feeRecipient = address(9999);
    address user = address(1);
    address depositor = address(100000000001);
    address owner = address(222);

    function setUp() public virtual {
        vm.startPrank(owner);
        vault = address(new Vault(address(wbtc), address(usdc)));
        strategy =
            address(new Strategy(address(wbtc), address(usdc), address(pool), address(vault), rebalancer, feeRecipient));
        IVault(vault).setStrategy(strategy);

        // make initial deposit
        deal(address(wbtc), user, 1e8);
        deal(address(usdc), user, 100_000e6);

        vm.startPrank(user);
        wbtc.approve(vault, type(uint256).max);
        usdc.approve(vault, type(uint256).max);

        IVault(vault).deposit(1e8, 100_000e6, 0, 0);
        assertEq(wbtc.balanceOf(user), 0);
        assertEq(usdc.balanceOf(user), 0);

        vm.startPrank(rebalancer);
        skip(10 minutes);
        IStrategy(strategy).rebalance();

        vm.startPrank(depositor);
        wbtc.approve(vault, type(uint256).max);
        usdc.approve(vault, type(uint256).max);

        vm.stopPrank();
    }

    function testDeposit() public {
        vm.startPrank(depositor);
        deal(address(wbtc), depositor, 2e8);
        deal(address(usdc), depositor, 100_000e6);

        wbtc.approve(vault, type(uint256).max);
        usdc.approve(vault, type(uint256).max);

        (, uint256 amount0In, uint256 amount1In) = IVault(vault).deposit(2e8, 100_000e6, 0.5e8, 50_000e6);
        assertEq(amount0In, wbtc.balanceOf(strategy));
        assertEq(amount1In, usdc.balanceOf(strategy));

        vm.startPrank(rebalancer);
        vm.expectRevert(); // due to < 5 mins since lastRebalance timestamp
        IStrategy(strategy).rebalance();

        skip(10 minutes);
        IStrategy(strategy).rebalance();

        require(wbtc.balanceOf(strategy) < 5 || usdc.balanceOf(strategy) < 5);
    }

    function test_fuzzWithdraw(uint256 pctWithdraw) public {
        uint256 pctWithdraw = pctWithdraw % (1e18 - 1e11 + 1) + 1e11;
        vm.startPrank(user);
        uint256 userBalance = IERC20(vault).balanceOf(user);

        uint256 amountToWithdraw = userBalance * pctWithdraw / 1e18;
        IVault(vault).withdraw(amountToWithdraw, 0, 0);
    }

    /// forge-config: default.fuzz.runs = 10000
    function test_fuzzDepositAndWithdraw(uint256 amount0, uint256 amount1) public {
        amount0 = amount0 % 10e8 + 1000;
        amount1 = amount1 % 1_000_000e6 + 1000;

        deal(address(wbtc), depositor, amount0);
        deal(address(usdc), depositor, amount1);
        vm.startPrank(depositor);

        (uint256 shares,,) = IVault(vault).deposit(amount0, amount1, 0, 0);

        IVault(vault).withdraw(shares, 0, 0);

        assertApproxEqAbs(wbtc.balanceOf(depositor), amount0, 10);
        assertApproxEqAbs(usdc.balanceOf(depositor), amount1, 10);
    }

    /// forge-config: default.fuzz.runs = 10000
    function test_canDepositAtAnyPrice(uint256 amount0, uint256 amount1, uint256 wbtcToSwap) public {
        vm.startPrank(depositor);
        amount0 = amount0 % 10e8 + 1000;
        amount1 = amount1 % 1_000_000e6 + 1000;

        wbtcToSwap = wbtcToSwap % 10e8 + 1000;
        swapWbtc(wbtcToSwap);

        deal(address(wbtc), depositor, amount0);
        deal(address(usdc), depositor, amount1);

        (uint256 shares,,) = IVault(vault).deposit(amount0, amount1, 0, 0);
    }

    function test_addVestingPosition() public {
        vm.startPrank(owner);

        deal(address(wbtc), owner, 2e8);
        deal(address(usdc), owner, 100_000e6);

        wbtc.approve(vault, type(uint256).max);
        usdc.approve(vault, type(uint256).max);

        (uint160 sqrtPriceX96,,,,,,) = IUniswapV3Pool(pool).slot0();

        uint128 liquidity = LiquidityAmounts.getLiquidityForAmounts(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(68460), TickMath.getSqrtRatioAtTick(68700), 2e8, 100_000e6
        );
        (uint256 amount0, uint256 amount1) = LiquidityAmounts.getAmountsForLiquidity(
            sqrtPriceX96, TickMath.getSqrtRatioAtTick(68460), TickMath.getSqrtRatioAtTick(68700), liquidity
        );

        (uint256 bal0, uint256 bal1) = IStrategy(strategy).balances();
        IVault(vault).addVestedPosition(amount0, amount1, 1 days);

        IStrategy(strategy).collectFees();
        (uint256 afterbal0, uint256 afterbal1) = IStrategy(strategy).balances();

        assertApproxEqAbs(bal0, afterbal0, 1);
        assertApproxEqAbs(bal1, afterbal1, 10000); // 1 wei wbtc = ~1000 wei USDC.

        skip(1 days / 2);

        IStrategy(strategy).collectFees();
        (afterbal0, afterbal1) = IStrategy(strategy).balances();

        assertApproxEqAbs(bal0 + amount0 / 2, afterbal0, 10);
        assertApproxEqAbs(bal1 + amount1 / 2, afterbal1, 10000);

        skip(1 days / 2);

        IStrategy(strategy).collectFees();
        (afterbal0, afterbal1) = IStrategy(strategy).balances();

        assertApproxEqAbs(bal0 + amount0, afterbal0, 10); // slightly lower as each pool.burn rounds amounts down.
        assertApproxEqAbs(bal1 + amount1, afterbal1, 10);
    }

    function test_compound() public {
        vm.startPrank(depositor);
        swapWbtc(10e8);

        vm.startPrank(rebalancer);
        vm.expectRevert("price out of range");
        IStrategy(strategy).compound();

        skip(6 minutes);
        IStrategy(strategy).compound();
        IStrategy(strategy).rebalance();
    }

    function swapWbtc(uint256 amountIn) public {
        deal(address(wbtc), depositor, amountIn);
        vm.startPrank(depositor);

        IMainnetRouter.ExactInputSingleParams memory swapParams;
        swapParams.tokenIn = address(wbtc);
        swapParams.tokenOut = address(usdc);
        swapParams.deadline = block.timestamp;
        swapParams.recipient = depositor;
        swapParams.fee = 3000;
        swapParams.amountIn = amountIn;

        wbtc.approve(uniRouter, amountIn);
        IMainnetRouter(uniRouter).exactInputSingle(swapParams);
    }

    function swapUsdc(uint256 amountIn) public {
        deal(address(usdc), depositor, amountIn);
        vm.startPrank(depositor);

        IMainnetRouter.ExactInputSingleParams memory swapParams;
        swapParams.tokenIn = address(usdc);
        swapParams.tokenOut = address(wbtc);
        swapParams.deadline = block.timestamp;
        swapParams.recipient = depositor;
        swapParams.fee = 3000;
        swapParams.amountIn = amountIn;

        usdc.approve(uniRouter, amountIn);
        IMainnetRouter(uniRouter).exactInputSingle(swapParams);
    }
}
