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
import {IPriceFeed} from "../src/interfaces/IPriceFeed.sol";
import {ILendingPool} from "../src/interfaces/ILendingPool.sol";
import {ILeverager} from "../src/interfaces/ILeverager.sol";
import {LiquidityAmounts} from "../src/libraries/LiquidityAmounts.sol";
import {TickMath} from "../src/libraries/TickMath.sol";
import {BaseTest} from "./BaseTest.sol";
import {Leverager} from "../src/Leverager.sol";
import {PriceFeed} from "../src/PriceFeed.sol";
import {LendingPool} from "../src/LendingPool.sol";
import {MockOracle} from "./utils/MockOracle.sol";
import {DataTypes} from "../src/types/DataTypes.sol";

contract LeveragerTest is BaseTest {
    address leverager;
    address lendingPool;
    address priceFeed;
    address wbtcOracle;
    address usdcOracle;

    address lender = address(123456);
    address liquidator = address(21873781);

    function setUp() public override {
        super.setUp();
        vm.startPrank(owner);

        priceFeed = address(new PriceFeed());
        wbtcOracle = address(new MockOracle());
        usdcOracle = address(new MockOracle());

        IPriceFeed(priceFeed).setChainlinkPriceFeed(address(wbtc), wbtcOracle, 604800);
        IPriceFeed(priceFeed).setChainlinkPriceFeed(address(usdc), usdcOracle, 604800);

        lendingPool = address(new LendingPool());

        ILendingPool(lendingPool).initReserve(address(wbtc));

        leverager = address(new Leverager("", "", lendingPool));
        ILeverager(leverager).initVault(address(vault), 1_000_000e18, 5e18, 0.1e18, 1e27);

        ILendingPool(lendingPool).addToWhitelist(leverager);
        ILendingPool(lendingPool).setLeverageParams(address(wbtc), type(uint256).max, type(uint256).max);
        ILeverager(leverager).setPriceFeed(priceFeed);
        MockOracle(wbtcOracle).setPrice(100_000e18);
        MockOracle(usdcOracle).setPrice(1e18);
    }

    function test_LendingPool() external {
        vm.startPrank(lender);
        wbtc.approve(lendingPool, 10e8);
        deal(address(wbtc), lender, 10e8);

        ILendingPool(lendingPool).deposit(address(wbtc), 10e8, lender);

        uint256 borrowingRate = ILendingPool(lendingPool).borrowingRateOfReserve(address(wbtc));
        assertEq(borrowingRate, 0);

        skip(6 minutes);

        vm.startPrank(depositor);
        ILeverager.LeverageParams memory lp;
        lp.amount0In = 0.5e8;
        lp.amount1In = 100_000e6;
        lp.vault0In = 1e8;
        lp.vault1In = 100_000e6;
        lp.vault = vault;
        lp.maxBorrowAmount = 0.6e8;
        lp.denomination = address(wbtc);

        deal(address(wbtc), depositor, 0.5e8);
        deal(address(usdc), depositor, 100_000e6);
        wbtc.approve(leverager, type(uint256).max);
        usdc.approve(leverager, type(uint256).max);

        ILeverager(leverager).openLeveragedPosition(lp);

        vm.startPrank(rebalancer);
        IStrategy(strategy).compound();
        vm.stopPrank();

        borrowingRate = ILendingPool(lendingPool).borrowingRateOfReserve(address(wbtc));
        console.log("%e", borrowingRate);

        uint256 exchangeRate = ILendingPool(lendingPool).exchangeRateOfReserve(address(wbtc));
        console.log(exchangeRate);

        skip(1 weeks);
        exchangeRate = ILendingPool(lendingPool).exchangeRateOfReserve(address(wbtc));
        console.log(exchangeRate);

        swapUsdc(10_000_000e6); // should be enough to make position usdc only
        MockOracle(usdcOracle).setPrice(0.1e18);
        assertEq(ILeverager(leverager).isLiquidateable(1), true);

        vm.startPrank(liquidator);
        deal(address(wbtc), liquidator, 0.51e8);
        wbtc.approve(leverager, 0.51e8);

        ILeverager.LiquidateParams memory liqParams;
        liqParams.id = 1;

        ILeverager(leverager).liquidatePosition(liqParams);

        borrowingRate = ILendingPool(lendingPool).borrowingRateOfReserve(address(wbtc));
        assertEq(borrowingRate, 0);
    }

    function test_partialWithdraw() external {
        vm.startPrank(lender);
        wbtc.approve(lendingPool, 10e8);
        deal(address(wbtc), lender, 10e8);

        ILendingPool(lendingPool).deposit(address(wbtc), 10e8, lender);

        uint256 borrowingRate = ILendingPool(lendingPool).borrowingRateOfReserve(address(wbtc));
        assertEq(borrowingRate, 0);

        skip(6 minutes);

        vm.startPrank(depositor);
        ILeverager.LeverageParams memory lp;
        lp.amount0In = 0.5e8;
        lp.amount1In = 100_000e6;
        lp.vault0In = 1e8;
        lp.vault1In = 100_000e6;
        lp.vault = vault;
        lp.maxBorrowAmount = 0.6e8;
        lp.denomination = address(wbtc);

        deal(address(wbtc), depositor, 0.5e8);
        deal(address(usdc), depositor, 100_000e6);
        wbtc.approve(leverager, type(uint256).max);
        usdc.approve(leverager, type(uint256).max);

        ILeverager(leverager).openLeveragedPosition(lp);

        vm.startPrank(rebalancer);
        IStrategy(strategy).compound();
        vm.stopPrank();

        deal(address(wbtc), depositor, 0.6e8);

        ILeverager.WithdrawParams memory wp;
        wp.id = 1;
        wp.pctWithdraw = 0.001e18;

        // this should fail
        vm.startPrank(depositor);

        vm.expectRevert();
        ILeverager(leverager).withdraw(wp);

        wp.pctWithdraw = 0.1e18;
        ILeverager(leverager).withdraw(wp);

        wp.pctWithdraw = 1e18;
        ILeverager(leverager).withdraw(wp);

        assertEq(IERC20(vault).balanceOf(leverager), 0);
    }
}
