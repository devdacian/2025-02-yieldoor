// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import {ERC20} from "@openzeppelin/token/ERC20/ERC20.sol";
import {ERC721} from "@openzeppelin/token/ERC721/ERC721.sol";
import {IERC20} from "@openzeppelin/token/ERC20/IERC20.sol";
import {IStrategy} from "./interfaces/IStrategy.sol";
import {SafeERC20} from "@openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/access/Ownable.sol";
import {IVault} from "./interfaces/IVault.sol";
import {IPriceFeed} from "./interfaces/IPriceFeed.sol";
import {ILendingPool} from "./interfaces/ILendingPool.sol";
import {ISwapRouter} from "./interfaces/ISwapRouter.sol";
import {IMainnetRouter} from "./interfaces/IMainnetRouter.sol";
import {ReentrancyGuard} from "@openzeppelin/utils/ReentrancyGuard.sol";
import {Path} from "./libraries/Path.sol";
import {ILeverager} from "./interfaces/ILeverager.sol";

import "forge-std/Test.sol";

/*  
    ToDo:
        - add require statements where needed 
        - set individual asset restrictions such as max leverage [done]
        - consider doing positions as ERC721s? [done]
        - check for approvals  [done]
        - access control [done]
        - check decimals everywhere 
*/

contract Leverager is ReentrancyGuard, Ownable, ERC721, ILeverager {
    using SafeERC20 for IERC20;
    using Path for bytes;

    address immutable lendingPool;
    uint256 constant PRECISION = 1e30;
    uint256 id;
    mapping(uint256 => Position) public positions;
    mapping(address => VaultParams) public vaultParams;

    address public pricefeed;
    address public swapRouter;
    address public feeRecipient;
    uint256 liquidationFee;
    uint256 minBorrow = 10e18;

    constructor(string memory name_, string memory symbol_, address _lendingPool)
        Ownable(msg.sender)
        ERC721(name_, symbol_)
    {
        lendingPool = _lendingPool;
    }

    function initVault(
        address vault,
        uint256 _maxUsdLeverage,
        uint256 _maxTimesLeverage,
        uint256 collatPct,
        uint256 _maxBorrowUSD
    ) external {
        require(!vaultParams[vault].leverageEnabled, "already enabled");
        vaultParams[vault].leverageEnabled = true;
        vaultParams[vault].maxUsdLeverage = _maxUsdLeverage;
        vaultParams[vault].maxTimesLeverage = _maxTimesLeverage;
        vaultParams[vault].minCollateralPct = collatPct;
        vaultParams[vault].maxBorrowedUSD = _maxBorrowUSD;

        address token0 = IVault(vault).token0();
        address token1 = IVault(vault).token1();

        IERC20(token0).forceApprove(vault, type(uint256).max);
        IERC20(token1).forceApprove(vault, type(uint256).max);
        IERC20(token0).forceApprove(lendingPool, type(uint256).max); // these approvals might be unnecessary?
        IERC20(token1).forceApprove(lendingPool, type(uint256).max);
    }

    // params need: Vault (there you'd get the 2 assets), amount0In, amount1In, leverage
    function openLeveragedPosition(LeverageParams calldata lp) external nonReentrant {
        require(vaultParams[lp.vault].leverageEnabled);
        Position memory up;
        up.token0 = IVault(lp.vault).token0();
        up.token1 = IVault(lp.vault).token1();
        up.vault = lp.vault;

        uint256 price = IVault(lp.vault).twapPrice();
        require(IVault(lp.vault).checkPoolActivity(), "market too volatile");

        IERC20(up.token0).safeTransferFrom(msg.sender, address(this), lp.amount0In);
        IERC20(up.token1).safeTransferFrom(msg.sender, address(this), lp.amount1In);

        uint256 delta0 = lp.vault0In - lp.amount0In;
        uint256 delta1 = lp.vault1In - lp.amount1In;
        if (delta0 > 0) ILendingPool(lendingPool).pullFunds(up.token0, delta0);
        if (delta1 > 0) ILendingPool(lendingPool).pullFunds(up.token1, delta1);

        (uint256 shares, uint256 a0, uint256 a1) =
            IVault(lp.vault).deposit(lp.vault0In, lp.vault1In, lp.min0in, lp.min1in);

        up.initCollateralUsd = _calculateTokenValues(up.token0, up.token1, a0, a1, price); // in 1e18
        uint256 bPrice = IPriceFeed(pricefeed).getPrice(lp.denomination);
        up.initCollateralValue = up.initCollateralUsd * (10 ** ERC20(lp.denomination).decimals()) / bPrice;

        {
            ILendingPool(lendingPool).borrow(lp.denomination, lp.maxBorrowAmount);
            IMainnetRouter.ExactOutputParams memory swapParams;

            // we do not verify any of the swap params. Biggest impact users should be able to do is sweep any tokens which are randomly within the contract.
            if (a0 > lp.amount0In && up.token0 != lp.denomination) {
                swapParams = abi.decode(lp.swapParams1, (IMainnetRouter.ExactOutputParams));
                address tokenIn = _getTokenIn(swapParams.path);
                require(tokenIn == lp.denomination, "token should be denomination");

                IERC20(tokenIn).forceApprove(swapRouter, swapParams.amountInMaximum);

                swapParams.amountOut = a0 - lp.amount0In;
                IMainnetRouter(swapRouter).exactOutput(swapParams);
                IERC20(tokenIn).forceApprove(swapRouter, 0);
            }

            if (a1 > lp.amount1In && up.token1 != lp.denomination) {
                swapParams = abi.decode(lp.swapParams1, (IMainnetRouter.ExactOutputParams));
                address tokenIn = _getTokenIn(swapParams.path);
                require(tokenIn == lp.denomination, "token should be denomination 2 ");
                IERC20(tokenIn).forceApprove(swapRouter, swapParams.amountInMaximum);

                swapParams.amountOut = a1 - lp.amount1In;
                IMainnetRouter(swapRouter).exactOutput(swapParams);
                IERC20(tokenIn).forceApprove(swapRouter, 0);
            }
        }

        if (delta0 > 0) ILendingPool(lendingPool).pushFunds(up.token0, delta0);
        if (delta1 > 0) ILendingPool(lendingPool).pushFunds(up.token1, delta1); // this will not work if both tokens are not enabled within the LendingPool

        uint256 denomBalance = IERC20(lp.denomination).balanceOf(address(this)); // if due to price movement, borrowed token was not used
        ILendingPool(lendingPool).repay(lp.denomination, denomBalance);

        up.borrowedAmount = lp.maxBorrowAmount - denomBalance;
        up.initBorrowedUsd = up.borrowedAmount * bPrice / (10 ** ERC20(lp.denomination).decimals());

        up.borrowedIndex = ILendingPool(lendingPool).getCurrentBorrowingIndex(lp.denomination);
        up.denomination = lp.denomination;
        up.shares = shares;
        up.vault = lp.vault;

        _checkWithinlimits(up);

        vaultParams[lp.vault].currBorrowedUSD += up.initBorrowedUsd;
        require(
            vaultParams[lp.vault].currBorrowedUSD < vaultParams[lp.vault].maxBorrowedUSD, "vault exceeded borrow limit"
        );

        uint256 tokenId = ++id;
        _mint(msg.sender, tokenId);

        positions[tokenId] = up;
    }

    function withdraw(WithdrawParams memory cpp) external nonReentrant {
        Position memory up = positions[cpp.id];
        require(_isApprovedOrOwner(msg.sender, cpp.id));
        require(cpp.pctWithdraw <= 1e18 && cpp.pctWithdraw > 0.01e18);

        address borrowed = up.denomination;
        uint256 sharesToWithdraw = up.shares * cpp.pctWithdraw / 1e18;

        (uint256 amountOut0, uint256 amountOut1) =
            IVault(up.vault).withdraw(sharesToWithdraw, cpp.minAmount0, cpp.minAmount1); // slippage?

        uint256 bIndex = ILendingPool(lendingPool).getCurrentBorrowingIndex(borrowed);
        uint256 totalOwedAmount = up.borrowedAmount * bIndex / up.borrowedIndex;
        uint256 owedAmount = totalOwedAmount * cpp.pctWithdraw / 1e18;

        uint256 amountToRepay = owedAmount; // this should be transferred to yAsset

        if (borrowed == up.token0) {
            uint256 repayFromWithdraw = amountOut0 < owedAmount ? amountOut0 : owedAmount;
            owedAmount -= repayFromWithdraw;
            amountOut0 -= repayFromWithdraw;
        } else if (borrowed == up.token1) {
            uint256 repayFromWithdraw = amountOut1 < owedAmount ? amountOut0 : owedAmount;
            owedAmount -= repayFromWithdraw;
            amountOut1 -= repayFromWithdraw;
        }

        if (cpp.hasToSwap) {
            // ideally, these swaps should have the user as a recipient. Then, we'll just pull the necessary part from them.

            IMainnetRouter.ExactInputParams memory swapParams =
                abi.decode(cpp.swapParams1, (IMainnetRouter.ExactInputParams));
            if (swapParams.amountIn > 0) {
                (address tokenIn,,) = swapParams.path.decodeFirstPool();
                require(tokenIn == up.token0);
                IERC20(tokenIn).forceApprove(swapRouter, swapParams.amountIn);

                IMainnetRouter(swapRouter).exactInput(swapParams); // does not support sqrtPriceLimit
                amountOut0 -= swapParams.amountIn;
            }

            swapParams = abi.decode(cpp.swapParams2, (IMainnetRouter.ExactInputParams));
            if (swapParams.amountIn > 0) {
                (address tokenIn,,) = swapParams.path.decodeFirstPool();
                require(tokenIn == up.token0);
                IERC20(tokenIn).forceApprove(swapRouter, swapParams.amountIn);

                IMainnetRouter(swapRouter).exactInput(swapParams); // does not support sqrtPriceLimit
                amountOut1 -= swapParams.amountIn;
            }
        }

        IERC20(up.denomination).safeTransferFrom(msg.sender, address(this), owedAmount); // maybe transfer to yAsset directly?

        ILendingPool(lendingPool).repay(borrowed, amountToRepay);

        if (amountOut0 > 0) IERC20(up.token0).safeTransfer(msg.sender, amountOut0);
        if (amountOut1 > 0) IERC20(up.token1).safeTransfer(msg.sender, amountOut1); // might have to be changed here.

        if (cpp.pctWithdraw == 1e18) {
            vaultParams[up.vault].currBorrowedUSD -= up.initBorrowedUsd;
            delete positions[cpp.id];
            _burn(cpp.id);
        } else {
            vaultParams[up.vault].currBorrowedUSD -= up.initBorrowedUsd * cpp.pctWithdraw / 1e18;
            positions[cpp.id].initBorrowedUsd -= up.initBorrowedUsd * cpp.pctWithdraw / 1e18;
            positions[cpp.id].borrowedAmount = totalOwedAmount - amountToRepay;
            positions[cpp.id].borrowedIndex = bIndex;
            positions[cpp.id].shares -= sharesToWithdraw;
        }
    }

    // need: id, whether direct repayment or swap, swap params
    function liquidatePosition(LiquidateParams memory liqParams) external nonReentrant {
        Position memory up = positions[liqParams.id];
        {
            address strategy = IVault(up.vault).strategy();
            IStrategy(strategy).collectFees();
        }

        require(isLiquidateable(liqParams.id), "isnt liquidateable");

        uint256 currBIndex = ILendingPool(lendingPool).getCurrentBorrowingIndex(up.denomination);
        uint256 owedAmount = up.borrowedAmount * currBIndex / up.borrowedIndex;
        uint256 repayAmount = owedAmount;

        uint256 price = IVault(up.vault).twapPrice();
        // we do not check here for pool activity, in order to be able to liquidate during very volatile markets
        // otherwise, we'd risk accruing bad debt.

        (uint256 amount0, uint256 amount1) =
            IVault(up.vault).withdraw(up.shares, liqParams.minAmount0, liqParams.minAmount1);

        uint256 totalValueUSD = _calculateTokenValues(up.token0, up.token1, amount0, amount1, price);

        uint256 bPrice = IPriceFeed(pricefeed).getPrice(up.denomination);
        uint256 borrowedValue = owedAmount * bPrice / ERC20(up.denomination).decimals();

        if (totalValueUSD > borrowedValue) {
            uint256 protocolFeePct = 1e18 * liquidationFee * (totalValueUSD - borrowedValue) / (totalValueUSD * 10_000);
            uint256 pf0 = protocolFeePct * amount0 / 1e18;
            uint256 pf1 = protocolFeePct * amount1 / 1e18;

            if (pf0 > 0) IERC20(up.token0).safeTransfer(feeRecipient, pf0);
            if (pf1 > 0) IERC20(up.token1).safeTransfer(feeRecipient, pf1);
            amount0 -= pf0;
            amount1 -= pf1;
        }

        if (up.denomination == up.token0) {
            uint256 repayFromWithdraw = amount0 < owedAmount ? amount0 : owedAmount;
            owedAmount -= repayFromWithdraw;
            amount0 -= repayFromWithdraw;
        }

        if (up.denomination == up.token1) {
            uint256 repayFromWithdraw = amount1 < owedAmount ? amount1 : owedAmount;
            owedAmount -= repayFromWithdraw;
            amount1 -= repayFromWithdraw;
        }

        if (liqParams.hasToSwap) {
            // ideally, these swaps should have the user as a recipient. Then, we'll just pull the necessary part from them.

            IMainnetRouter.ExactInputSingleParams memory swapParams =
                abi.decode(liqParams.swapParams1, (IMainnetRouter.ExactInputSingleParams));
            if (swapParams.amountIn > 0) {
                // should make an approval here
                require(swapParams.tokenIn == up.token0);
                IMainnetRouter(swapRouter).exactInputSingle(swapParams); // does not support sqrtPriceLimit
                amount0 -= swapParams.amountIn;
            }

            swapParams = abi.decode(liqParams.swapParams2, (IMainnetRouter.ExactInputSingleParams));
            if (swapParams.amountIn > 0) {
                // should make an approval here
                require(swapParams.tokenIn == up.token1);
                IMainnetRouter(swapRouter).exactInputSingle(swapParams); // does not support sqrtPriceLimit
                amount1 -= swapParams.amountIn;
            }
        }

        IERC20(up.denomination).safeTransferFrom(msg.sender, address(this), owedAmount);

        ILendingPool(lendingPool).repay(up.denomination, repayAmount);

        if (amount0 > 0) IERC20(up.token0).safeTransfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(up.token1).safeTransfer(msg.sender, amount1);

        vaultParams[up.vault].currBorrowedUSD -= up.initBorrowedUsd;

        _burn(liqParams.id);
        delete positions[liqParams.id];
    }

    // vault must have called collect fees beforehand
    function isLiquidateable(uint256 _id) public view returns (bool liquidateable) {
        Position memory pos = positions[_id];
        VaultParams memory vp = vaultParams[pos.vault];

        uint256 vaultSupply = IVault(pos.vault).totalSupply();

        (uint256 vaultBal0, uint256 vaultBal1) = IVault(pos.vault).balances();
        uint256 userBal0 = pos.shares * vaultBal0 / vaultSupply;
        uint256 userBal1 = pos.shares * vaultBal1 / vaultSupply;
        uint256 price = IVault(pos.vault).twapPrice();

        uint256 totalValueUSD = _calculateTokenValues(pos.token0, pos.token1, userBal0, userBal1, price);
        uint256 bPrice = IPriceFeed(pricefeed).getPrice(pos.denomination);
        uint256 totalDenom = totalValueUSD * (10 ** ERC20(pos.denomination).decimals()) / bPrice;

        uint256 bIndex = ILendingPool(lendingPool).getCurrentBorrowingIndex(pos.denomination);
        uint256 owedAmount = pos.borrowedAmount * bIndex / pos.borrowedIndex;

        uint256 base = owedAmount * 1e18 / (vp.maxTimesLeverage - 1e18);
        base = base < pos.initCollateralValue ? base : pos.initCollateralValue;

        // console.log("%e", owedAmount);
        // console.log("%e", totalDenom);

        if (owedAmount > totalDenom || totalDenom - owedAmount < vp.minCollateralPct * base / 1e18) return true;
        else return false;
    }

    function _calculateTokenValues(address token0, address token1, uint256 amount0, uint256 amount1, uint256 price)
        internal
        view
        returns (uint256 usdValue)
    {
        uint256 chPrice0;
        uint256 chPrice1;
        uint256 decimals0 = 10 ** ERC20(token0).decimals();
        uint256 decimals1 = 10 ** ERC20(token1).decimals();
        if (IPriceFeed(pricefeed).hasPriceFeed(token0)) {
            chPrice0 = IPriceFeed(pricefeed).getPrice(token0); // should never return 0?, should adjust for decimals :/
            usdValue += amount0 * chPrice0 / decimals0;
        }
        if (IPriceFeed(pricefeed).hasPriceFeed(token1)) {
            chPrice1 = IPriceFeed(pricefeed).getPrice(token1);
            usdValue += amount1 * chPrice1 / decimals1;
        }

        if (chPrice0 == 0) {
            usdValue += (amount0 * price / PRECISION) * chPrice1 / decimals1;
        } else if (chPrice1 == 0) {
            usdValue += amount1 * PRECISION / price * chPrice0 / decimals0;
        }

        return usdValue;
    }

    // if debt is entirely repaid, transfer vault shares to the user.
    function repayOwed(uint256 repayAmount, uint256 _id) external {
        Position memory up = positions[_id];
        require(_isApprovedOrOwner(msg.sender, _id));

        uint256 currentIndex = ILendingPool(lendingPool).getCurrentBorrowingIndex(up.denomination);
        uint256 owedAmount = up.borrowedAmount * currentIndex / up.borrowedIndex;
        bool shouldSend;

        if (repayAmount >= owedAmount) {
            repayAmount = owedAmount;
            shouldSend = true;
        }

        IERC20(up.denomination).safeTransferFrom(msg.sender, address(this), repayAmount);
        ILendingPool(lendingPool).repay(up.denomination, repayAmount);

        if (shouldSend) {
            IERC20(up.vault).safeTransfer(msg.sender, up.shares);
            vaultParams[up.vault].currBorrowedUSD -= up.initBorrowedUsd;
            delete positions[_id];
        } else {
            up.borrowedAmount = owedAmount - repayAmount;
            up.borrowedIndex = currentIndex;

            vaultParams[up.vault].currBorrowedUSD -= up.initBorrowedUsd * repayAmount / owedAmount;
            up.initBorrowedUsd -= up.initBorrowedUsd * repayAmount / owedAmount;

            positions[_id] = up;
        }
    }

    function decreaseCollateral(uint256 _id, uint256 _shares, uint256 minAmount0, uint256 minAmount1)
        external
        nonReentrant
    {
        Position memory up = positions[_id];
        require(_isApprovedOrOwner(msg.sender, _id));
        require(vaultParams[up.vault].leverageEnabled);

        (uint256 amount0, uint256 amount1) = IVault(up.vault).withdraw(_shares, minAmount0, minAmount1);
        uint256 price = IVault(up.vault).twapPrice();

        uint256 remaining0 = (up.shares - _shares) * amount0 / _shares;
        uint256 remaining1 = (up.shares - _shares) * amount1 / _shares;

        up.initCollateralUsd = _calculateTokenValues(up.token0, up.token1, remaining0, remaining1, price); // need to calculate it on the actually in amount
        uint256 bPrice = IPriceFeed(pricefeed).getPrice(up.denomination);
        up.initCollateralValue = up.initCollateralUsd * 1e18 / bPrice;

        uint256 bIndex = ILendingPool(lendingPool).getCurrentBorrowingIndex(up.denomination);
        up.borrowedAmount = up.borrowedAmount * bIndex / up.borrowedIndex;
        up.borrowedIndex = bIndex;
        up.initBorrowedUsd = up.borrowedAmount * bPrice / 1e18; // shall I adjust it here?

        _checkWithinlimits(up);
        if (amount0 > 0) IERC20(up.token0).safeTransfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(up.token1).safeTransfer(msg.sender, amount1);

        positions[_id] = up;
    }

    function _checkWithinlimits(Position memory up) internal {
        VaultParams memory vp = vaultParams[up.vault];
        (uint256 maxIndividualBorrow, uint256 maxLevTimes) =
            ILendingPool(lendingPool).getLeverageParams(up.denomination);

        uint256 positionLeverage = up.initCollateralValue * 1e18 / (up.initCollateralValue + up.borrowedAmount);

        require(positionLeverage <= vp.maxTimesLeverage && positionLeverage <= maxLevTimes, "too high x leverage");
        require(up.initBorrowedUsd <= vp.maxUsdLeverage, "too high borrow usd amount");
        require(up.borrowedAmount <= maxIndividualBorrow, "too high borrow for the vault");
    }

    // --- Owner only functions

    function enableTokenAsBorrowed(address asset) external onlyOwner {
        IERC20(asset).forceApprove(lendingPool, type(uint256).max);
    }

    function setLiquidationFee(uint256 newFee) external onlyOwner {
        require(newFee <= 10_000);
        liquidationFee = newFee;
    }

    function changeVaultMaxBorrow(address vault, uint256 maxBorrow) external onlyOwner {
        VaultParams storage vp = vaultParams[vault];
        vp.maxUsdLeverage = maxBorrow;
    }

    function changeVaultMaxLeverage(address vault, uint256 maxLeverage) external onlyOwner {
        VaultParams storage vp = vaultParams[vault];
        vp.maxTimesLeverage = maxLeverage;
    }

    function changeVaultMinCollateralPct(address vault, uint256 minColateral) external onlyOwner {
        VaultParams storage vp = vaultParams[vault];
        vp.minCollateralPct = minColateral;
    }

    function toggleVaultLeverage(address vault) external onlyOwner {
        VaultParams storage vp = vaultParams[vault];
        vp.leverageEnabled = !vp.leverageEnabled;
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view virtual returns (bool) {
        address owner = ERC721.ownerOf(tokenId);
        return (spender == owner || isApprovedForAll(owner, spender) || getApproved(tokenId) == spender);
    }

    function _getTokenIn(bytes memory path) internal pure returns (address) {
        while (path.hasMultiplePools()) {
            path.skipToken();
        }

        (, address tokenIn,) = path.decodeFirstPool();
        return tokenIn;
    }

    function getPosition(uint256 _id) external view returns (Position memory) {
        Position memory pos = positions[_id];
        return pos;
    }

    function setPriceFeed(address _priceFeed) external onlyOwner {
        pricefeed = _priceFeed;
    }

}
