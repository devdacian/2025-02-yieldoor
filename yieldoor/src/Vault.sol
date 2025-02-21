// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {IVault} from "./interfaces/IVault.sol";
import "forge-std/Test.sol";

contract Vault is ERC20, Ownable {
    using SafeERC20 for IERC20;

    address public token0;
    address public token1;
    address strategy;
    uint256 constant PRECISION = 1e30;
    address constant BURN = address(1337);
    uint256 maxDepositRate = 0.7e30;
    address public deployer;
    uint256 rewards0;
    uint256 rewards1;
    uint256 rewardsStartTimestamp;
    uint256 rewardsFinish;
    uint256 lastUpdated;
    bool incentivesActive;
    uint256 depositFee; // this will usually be 0. Will only be set to 0.01% in case griefers spam deposit/ withdraws to remove all liquidity from the positions.

    constructor(address _token0, address _token1) ERC20("", "") Ownable(msg.sender) {
        if (_token0 > _token1) (_token0, _token1) = (_token1, _token0);

        token0 = _token0;
        token1 = _token1;
    }

    function deposit(uint256 amount0, uint256 amount1, uint256 amount0Min, uint256 amount1Min)
        external
        returns (uint256 shares, uint256 depositAmount0, uint256 depositAmount1)
    {
        IStrategy(strategy).collectFees();

        (uint256 totalBalance0, uint256 totalBalance1) = IStrategy(strategy).balances();

        (shares, depositAmount0, depositAmount1) = _calcDeposit(totalBalance0, totalBalance1, amount0, amount1);

        IERC20(token0).safeTransferFrom(msg.sender, strategy, depositAmount0);
        IERC20(token1).safeTransferFrom(msg.sender, strategy, depositAmount1); // after deposit, funds remain idle, until compound is called
        // IStrategy(strategy).deposit(depositAmount0, depositAmount1);

        require(shares > 0);
        require(depositAmount0 > amount0Min);
        require(depositAmount1 > amount1Min);

        _mint(msg.sender, shares);

        // TODO - emit event
    }

    function withdraw(uint256 shares, uint256 minAmount0, uint256 minAmount1)
        public
        returns (uint256 amount0, uint256 amount1)
    {
        IStrategy(strategy).collectFees();

        (uint256 totalBalance0, uint256 totalBalance1) = IStrategy(strategy).balances();

        uint256 totalSupply = totalSupply();
        _burn(msg.sender, shares);

        uint256 withdrawAmount0 = totalBalance0 * shares / totalSupply;
        uint256 withdrawAmount1 = totalBalance1 * shares / totalSupply;

        (uint256 idle0, uint256 idle1) = IStrategy(strategy).idleBalances();

        require(withdrawAmount0 >= minAmount0 && withdrawAmount1 >= minAmount1, "slippage protection");

        if (idle0 < withdrawAmount0 || idle1 < withdrawAmount1) {
            (withdrawAmount0, withdrawAmount1) = IStrategy(strategy).withdrawPartial(shares, totalSupply);
            require(withdrawAmount0 >= minAmount0 && withdrawAmount1 >= minAmount1, "slippage protection");
        }

        IERC20(token0).safeTransferFrom(strategy, msg.sender, withdrawAmount0);
        IERC20(token1).safeTransferFrom(strategy, msg.sender, withdrawAmount1);

        return (withdrawAmount0, withdrawAmount1);

        // TODO emit event
    }

    function _calcDeposit(uint256 bal0, uint256 bal1, uint256 depositAmount0, uint256 depositAmount1)
        internal
        view
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        uint256 totalSupply = totalSupply();

        // If total supply > 0, vault can't be empty
        assert(totalSupply == 0 || bal0 > 0 || bal1 > 0);

        if (totalSupply == 0) {
            // For first deposit, just use the amounts desired
            amount0 = depositAmount0;
            amount1 = depositAmount1;
            shares = (amount0 > amount1 ? amount0 : amount1) - (1000);
        } else if (bal0 == 0) {
            amount1 = depositAmount1;
            shares = amount1 * totalSupply / bal1;
        } else if (bal1 == 0) {
            amount0 = depositAmount0;
            shares = amount0 * totalSupply / bal0;
        } else {
            uint256 cross0 = depositAmount0 * bal1;
            uint256 cross1 = depositAmount1 * bal0;
            uint256 cross = cross0 > cross1 ? cross1 : cross0;
            require(cross > 0, "cross");

            // Round up amounts
            amount0 = (cross - 1) / bal1 + 1;
            amount1 = (cross - 1) / (bal0) + (1);
            shares = cross * totalSupply / (bal0) / (bal1);
        }
    }

    // any extra funds will be immediately received as rewards in the strat. Cannot realistically be sandwiched on L2s.
    function addVestedPosition(uint256 amount0, uint256 amount1, uint256 _duration) external onlyOwner {
        IERC20(token0).safeTransferFrom(msg.sender, strategy, amount0);
        IERC20(token1).safeTransferFrom(msg.sender, strategy, amount1);

        IStrategy(strategy).addVestedPosition(amount0, amount1, _duration); // all necessary checks are performed here.
    }

    function setStrategy(address _strategy) external onlyOwner {
        require(strategy == address(0), "strat cant be address(0)");
        strategy = _strategy;
    }

    function balances() external view returns (uint256 bal0, uint256 bal1) {
        return IStrategy(strategy).balances();
    }

    function price() public returns (uint256) {
        return IStrategy(strategy).price();
    }

    function twapPrice() public view returns (uint256) {
        return IStrategy(strategy).twapPrice();
    }

    function checkPoolActivity() public returns (bool) {
        return IStrategy(strategy).checkPoolActivity();
    }
}
