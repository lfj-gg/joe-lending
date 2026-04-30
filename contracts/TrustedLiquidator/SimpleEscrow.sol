// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface JToken {
    function underlying() external view returns (address);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function burn(address account) external;
}

interface JoeTroller {
    function getAllMarkets() external view returns (address[] memory);
}

/// @title SimpleEscrow
/// @notice Pull-based claim contract for the market wind-down.
///
/// The flow is split between off-chain payout calculation and on-chain claim:
///
///   1. After all liquidations and the cash sweep are done off-chain, the owner
///      funds this contract with the underlying tokens needed to back every
///      computed claim, then calls `set(positions)` once per batch to record
///      the per-user/per-token amounts in `claimable`.
///   2. Users call `claim(underlying)` before `deadline` to withdraw their
///      share. As part of the claim, the Escrow calls `jToken.burn(user)` on
///      the corresponding jToken, which zeroes the user's `accountTokens` so
///      the dead market state matches the off-chain payout.
///   3. After `deadline` passes, the owner can `sweep(token, to)` any
///      unclaimed underlying to a treasury or other recipient.
///
/// For the `claim` → `jToken.burn` hop to be authorised, this contract must
/// be registered as the `trustedLiquidator` on the Joetroller (the wind-down
/// jToken implementations gate `burn` on `msg.sender == trustedLiquidator`).
///
/// The deadline can only be extended while it is still in the future. Once
/// `block.timestamp` passes the current deadline, no further `set` or
/// `setDeadline` calls are accepted — only `sweep`.
contract SimpleEscrow is Ownable {
    using SafeERC20 for IERC20;

    error PositionAlreadySet();
    error DeadlinePassed();
    error NothingToClaim();
    error DeadlineNotReached();
    error DeadlineInPast();

    event Claimed(address indexed caller, address indexed user, address indexed token, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event DeadlineSet(uint256 deadline);

    /// @notice Claimable underlying token balances per user per token.
    mapping(address user => mapping(address token => uint256)) public claimable;

    /// @notice Map of underlying token addresses to their corresponding jToken addresses.
    mapping(address underlying => address jToken) public jTokens;

    /// @notice Unix timestamp after which claims are blocked and sweep is enabled.
    uint256 public deadline;

    /// @notice Builds the underlying→jToken map by enumerating every market on
    ///         the Joetroller, then locks in the initial claim deadline.
    /// @param admin Owner of this contract (sets/sweeps/extends deadline).
    /// @param joetroller Address of the Joetroller — must list every market the
    ///                   classifier may pay out from. New markets listed after
    ///                   deployment are not auto-discovered.
    /// @param deadline_ Unix timestamp for the claim deadline. Must be strictly
    ///                  in the future at deployment.
    constructor(address admin, address joetroller, uint256 deadline_) Ownable(admin) {
        address[] memory markets = JoeTroller(joetroller).getAllMarkets();
        for (uint256 i = 0; i < markets.length; i++) {
            address jToken = markets[i];
            address underlying = JToken(jToken).underlying();
            jTokens[underlying] = jToken;
        }

        _setDeadline(deadline_);
    }

    struct Position {
        address user;
        address token;
        uint256 amount;
    }

    /// @notice Records per-user claimable underlying amounts. Each entry is
    ///         one-shot: a user/token pair already populated cannot be overwritten.
    /// @dev Only callable by the owner, only while the deadline has not passed.
    ///      Reverts with `DeadlinePassed` after deadline, `PositionAlreadySet`
    ///      on a duplicate (user, token). Does not transfer any underlying — the
    ///      contract must be funded separately for `claim` to succeed.
    /// @param positions Array of `(user, token, amount)` tuples. `token` is the
    ///                  underlying token address; `amount` is in raw token units.
    function set(Position[] calldata positions) external onlyOwner {
        if (block.timestamp > deadline) revert DeadlinePassed();
        for (uint256 i = 0; i < positions.length; i++) {
            Position calldata position = positions[i];
            if (claimable[position.user][position.token] != 0) revert PositionAlreadySet();
            claimable[position.user][position.token] = position.amount;
        }
    }

    /// @notice Withdraws the caller's claimable amount of `token` and zeroes
    ///         their corresponding jToken balance via `jToken.burn`.
    /// @dev This contract must be the registered `trustedLiquidator` on the
    ///      Joetroller for the burn call to succeed. Reverts with
    ///      `DeadlinePassed` after the deadline and `NothingToClaim` if the
    ///      caller has no recorded claim for `token`.
    /// @param token The underlying token address to claim.
    function claim(address token) external {
        _claim(msg.sender, token);
    }

    /// @notice Withdraws the claimable amount of `token` for `user` and zeroes
    ///         their corresponding jToken balance via `jToken.burn`.
    /// @dev Only callable by the owner. Same requirements as `claim` apply.
    /// @param user The user to claim for.
    /// @param token The underlying token address to claim.
    function claimFor(address user, address token) external onlyOwner {
        _claim(user, token);
    }

    /// @dev Internal function to claim for a user and token.
    /// @param user The user to claim for.
    /// @param token The underlying token address to claim.
    function _claim(address user, address token) internal {
        if (block.timestamp > deadline) revert DeadlinePassed();

        uint256 amount = claimable[user][token];
        if (amount == 0) revert NothingToClaim();
        claimable[user][token] = 0;

        address jToken = jTokens[token];
        if (jToken != address(0)) {
            JToken(jToken).burn(user);
        }

        IERC20(token).safeTransfer(user, amount);

        emit Claimed(msg.sender, user, token, amount);
    }

    /// @notice Transfers the entire contract balance of `token` to `to`. Only
    ///         callable by the owner once the claim deadline has passed.
    /// @dev Does not clear any `claimable[user][token]` entries — those
    ///      become unredeemable simply because `claim` reverts post-deadline.
    /// @param token The token to sweep (typically an underlying ERC20).
    /// @param to The recipient address (e.g. protocol treasury).
    function sweep(address token, address to) external onlyOwner {
        if (block.timestamp <= deadline) revert DeadlineNotReached();

        uint256 balance = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, balance);

        emit Swept(token, to, balance);
    }

    /// @notice Sets a new claim deadline. Can only be called while the current
    ///         deadline has not yet passed.
    /// @dev Reverts with `DeadlineInPast` if `deadline_` is not strictly in the
    ///      future and with `DeadlinePassed` if the current deadline has
    ///      already lapsed (the contract is then permanently frozen for set/claim).
    /// @param deadline_ New unix timestamp for the claim deadline.
    function setDeadline(uint256 deadline_) external onlyOwner {
        _setDeadline(deadline_);
    }

    function _setDeadline(uint256 deadline_) internal {
        if (deadline_ <= block.timestamp) revert DeadlineInPast();
        if (deadline != 0 && deadline <= block.timestamp) revert DeadlinePassed();
        deadline = deadline_;
        emit DeadlineSet(deadline_);
    }
}
