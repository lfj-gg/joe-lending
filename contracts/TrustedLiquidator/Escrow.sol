// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface JToken {
    function underlying() external view returns (address);
    function redeem(uint256 redeemTokens) external returns (uint256);
}

/// @title Escrow
/// @notice Pull-based claim contract for market wind-down redemptions.
///
/// During a market wind-down, the TrustedLiquidator transfers users' jTokens here
/// via `storeRedeem`. This contract redeems them for the underlying token and records
/// the amount as claimable by the original user.
///
/// Users call `claim` to withdraw their underlying before the deadline.
/// After the deadline, the TrustedLiquidator's owner can `sweep` unclaimed funds.
///
/// The deadline can be extended by the admin before it passes, but once passed
/// it is permanently locked — no further deposits or extensions are possible.
contract Escrow {
    using SafeERC20 for IERC20;

    error NotTrustedLiquidatorOwner();
    error NotTrustedLiquidator();
    error DeadlineNotReached();
    error DeadlinePassed();
    error DeadlineInPast();
    error NothingToClaim();
    error ClaimDeadlinePassed();
    error RedeemFailed(uint256 error, address jToken);

    event Deposited(address indexed user, address indexed token, uint256 amount);
    event Claimed(address indexed user, address indexed token, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event DeadlineSet(uint256 deadline);

    /// @notice The TrustedLiquidator that can deposit jTokens into this escrow.
    address public immutable TRUSTED_LIQUIDATOR;

    /// @notice Claimable underlying token balances per user per token.
    mapping(address user => mapping(address token => uint256)) public claimable;

    /// @notice Unix timestamp after which claims are blocked and sweep is enabled.
    uint256 public deadline;

    /// @param trustedLiquidator Address of the TrustedLiquidator contract.
    /// @param deadline_ Unix timestamp for the claim deadline. Must be in the future.
    constructor(address trustedLiquidator, uint256 deadline_) {
        TRUSTED_LIQUIDATOR = trustedLiquidator;
        _setDeadline(deadline_);
    }

    modifier onlyTrustedLiquidatorOwner() {
        _onlyTrustedLiquidatorOwner();
        _;
    }

    function _onlyTrustedLiquidatorOwner() internal view {
        if (msg.sender != Ownable(TRUSTED_LIQUIDATOR).owner()) revert NotTrustedLiquidatorOwner();
    }

    /// @notice Redeems jTokens for underlying and records the amount as claimable by the user.
    /// @dev Only callable by the TrustedLiquidator. The jTokens must already be transferred
    ///      to this contract before calling. Uses a balance snapshot to determine the exact
    ///      amount of underlying received (handles rounding from exchange rate math).
    /// @param jToken The jToken market to redeem from.
    /// @param user The user who will be able to claim the underlying.
    /// @param amount The number of jTokens to redeem.
    function storeRedeem(address jToken, address user, uint256 amount) external {
        if (block.timestamp > deadline) revert ClaimDeadlinePassed();
        if (msg.sender != TRUSTED_LIQUIDATOR) revert NotTrustedLiquidator();
        address underlying = JToken(jToken).underlying();

        uint256 balance = IERC20(underlying).balanceOf(address(this));
        uint256 err = JToken(jToken).redeem(amount);
        if (err != 0) revert RedeemFailed(err, jToken);
        uint256 redeemed = IERC20(underlying).balanceOf(address(this)) - balance;

        claimable[user][underlying] += redeemed;
        emit Deposited(user, underlying, redeemed);
    }

    /// @notice Allows a user to withdraw their claimable underlying tokens.
    /// @dev Reverts if the deadline has passed or if the caller has nothing to claim.
    /// @param token The underlying token address to claim.
    function claim(address token) external {
        if (block.timestamp > deadline) revert DeadlinePassed();

        uint256 amount = claimable[msg.sender][token];
        if (amount == 0) revert NothingToClaim();

        claimable[msg.sender][token] = 0;
        IERC20(token).safeTransfer(msg.sender, amount);

        emit Claimed(msg.sender, token, amount);
    }

    /// @notice Transfers all unclaimed tokens to a recipient after the deadline.
    /// @dev Only callable by the TrustedLiquidator's owner. Transfers the entire
    ///      token balance — does not zero out individual claimable entries.
    /// @param token The token to sweep.
    /// @param to The recipient address (e.g. protocol treasury).
    function sweep(address token, address to) external onlyTrustedLiquidatorOwner {
        if (block.timestamp <= deadline) revert DeadlineNotReached();

        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);

        emit Swept(token, to, balance);
    }

    /// @notice Extends the claim deadline. Can only be called before the current deadline passes.
    /// @param deadline_ New deadline, must be in the future.
    function setDeadline(uint256 deadline_) external onlyTrustedLiquidatorOwner {
        _setDeadline(deadline_);
    }

    function _setDeadline(uint256 deadline_) internal {
        if (deadline_ <= block.timestamp) revert DeadlineInPast();
        if (deadline != 0 && deadline <= block.timestamp) revert ClaimDeadlinePassed();
        deadline = deadline_;
        emit DeadlineSet(deadline_);
    }
}
