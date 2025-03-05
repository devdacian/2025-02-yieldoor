// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@solady/tokens/ERC20.sol";
import {SafeTransferLib} from "@solady/utils/SafeTransferLib.sol";
import {ReentrancyGuardTransient} from "@solady/utils/ReentrancyGuardTransient.sol";

/// @title yToken
/// Forked from ExtraFinance
contract yToken is ReentrancyGuardTransient, ERC20 {
    using SafeTransferLib for address;

    address public immutable lendingPool;
    address public immutable underlyingAsset;

    uint8 private immutable _decimals;
    string private _name;
    string private _symbol;

    modifier onlyLendingPool() {
        require(msg.sender == lendingPool, "unauthorized");
        _;
    }

    constructor(string memory name_, string memory symbol_, uint8 decimals_, address underlyingAsset_) {
        _decimals = decimals_;
        _name = name_;
        _symbol = symbol_;

        require(underlyingAsset_ != address(0), "underlyingAsset can't be address(0)");
        underlyingAsset = underlyingAsset_;
        lendingPool = msg.sender;
    }

    /// @dev Returns the name of the token.
    function name() public view override returns (string memory out) {
        out = _name;
    }

    /// @dev Returns the symbol of the token.
    function symbol() public view override returns (string memory out) {
        out = _symbol;
    }

    /// @notice Mints an amount of yToken to `user`
    /// @param user The address receiving the minted tokens
    /// @param amount The amount of tokens getting minted
    function mint(address user, uint256 amount) external onlyLendingPool nonReentrant {
        _mint(user, amount);
    }

    /// @param receiverOfUnderlying The address that will receive the underlying tokens
    /// @param yTokenAmount The amount of eTokens being burned
    /// @param underlyingTokenAmount The amount of underlying tokens being transferred to user
    function burn(address receiverOfUnderlying, uint256 yTokenAmount, uint256 underlyingTokenAmount)
        external
        onlyLendingPool
        nonReentrant
    {
        _burn(msg.sender, yTokenAmount);

        underlyingAsset.safeTransfer(receiverOfUnderlying, underlyingTokenAmount);
    }

    /// @notice Transfers underlying tokens to `target`
    /// @param target The recipient of the eTokens
    /// @param amount The amount getting transferred
    function transferUnderlyingTo(address target, uint256 amount)
        external
        onlyLendingPool
        nonReentrant
        returns (uint256)
    {
        underlyingAsset.safeTransfer(target, amount);
        return amount;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }
}
