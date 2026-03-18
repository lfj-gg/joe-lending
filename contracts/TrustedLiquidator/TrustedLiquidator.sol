// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Multicall} from "lib/openzeppelin-contracts/contracts/utils/Multicall.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

interface JToken {
    function underlying() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function borrowBalanceCurrent(address account) external returns (uint256);
    function liquidateBorrow(address borrower, uint256 repayAmount, JToken jTokenCollateral) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IEscrow {
    function storeRedeem(address jToken, address user, uint256 amount) external;
}

/// @title TrustedLiquidator
/// @notice Admin-operated contract for winding down BankerJoe lending markets.
///
/// Registered as the Joetroller's `trustedLiquidator`, which grants it:
/// - Bypass of shortfall checks (can liquidate healthy users)
/// - Bypass of close factor (can repay 100% of a borrow in one call)
/// - Bypass of jToken transfer approval (can transferFrom without allowance)
/// - Reduced liquidation incentive via `trustedLiquidationIncentiveMantissa`
///
/// All functions are owner-only. Use `multicall` to batch operations per user.
/// This contract holds operational funds (tokens to repay borrows) but never
/// holds user redemption funds — those go to a separate Escrow contract.
contract TrustedLiquidator is Ownable, Multicall {
    using SafeERC20 for IERC20;

    error LiquidateFailed(uint256 error, address jTokenBorrowed, address jTokenCollateral, address borrower);
    error RedeemFailed(uint256 error, address jTokenCollateral, address redeemer);
    error RepayBorrowFailed(uint256 error, address jToken, address borrower);

    constructor(address owner) Ownable(owner) {}

    receive() external payable {}

    /// @notice Liquidates a borrower's full debt and redeems seized collateral.
    /// @dev Repays the entire borrow balance of `borrower` in `jTokenBorrowed`,
    ///      seizes collateral jTokens from `jTokenCollateral`, and immediately
    ///      redeems them for the underlying. The underlying stays in this contract
    ///      (operational funds — can be withdrawn via `transfer`).
    /// @param jTokenBorrowed The jToken market where the borrower has debt.
    /// @param jTokenCollateral The jToken market to seize collateral from.
    /// @param borrower The address of the borrower to liquidate.
    function liquidate(address jTokenBorrowed, address jTokenCollateral, address borrower) external onlyOwner {
        address underlying = JToken(jTokenBorrowed).underlying();
        uint256 borrowBalance = JToken(jTokenBorrowed).borrowBalanceCurrent(borrower);

        IERC20(underlying).forceApprove(jTokenBorrowed, borrowBalance);

        uint256 error = JToken(jTokenBorrowed).liquidateBorrow(borrower, borrowBalance, JToken(jTokenCollateral));
        if (error != 0) revert LiquidateFailed(error, jTokenBorrowed, jTokenCollateral, borrower);

        uint256 redeemTokens = JToken(jTokenCollateral).balanceOf(address(this));
        error = JToken(jTokenCollateral).redeem(redeemTokens);
        if (error != 0) revert RedeemFailed(error, jTokenCollateral, address(this));
    }

    /// @notice Transfers a user's jTokens to the Escrow and redeems them.
    /// @dev Uses the trusted liquidator's transferFrom bypass (no user approval needed).
    ///      The jTokens are sent to the Escrow, which redeems them and records the
    ///      underlying amount as claimable by the user. The underlying never passes
    ///      through this contract.
    /// @param escrow The Escrow contract address.
    /// @param jToken The jToken market to redeem from.
    /// @param redeemer The user whose jTokens will be transferred and redeemed.
    function transferAndRedeem(address escrow, address jToken, address redeemer) external onlyOwner {
        uint256 balance = JToken(jToken).balanceOf(redeemer);
        IERC20(jToken).safeTransferFrom(redeemer, escrow, balance);
        IEscrow(escrow).storeRedeem(jToken, redeemer, balance);
    }

    /// @notice Repays a borrower's full debt on their behalf (for bad debt cases).
    /// @dev This contract must hold enough underlying tokens to cover the borrow.
    ///      The borrower's debt is zeroed out; they keep any collateral they have.
    /// @param jToken The jToken market where the borrower has debt.
    /// @param borrower The address of the borrower whose debt to repay.
    function repayBorrowBehalf(address jToken, address borrower) external onlyOwner {
        address underlying = JToken(jToken).underlying();
        uint256 balance = JToken(jToken).borrowBalanceCurrent(borrower);

        IERC20(underlying).forceApprove(jToken, balance);

        uint256 error = JToken(jToken).repayBorrowBehalf(borrower, balance);
        if (error != 0) revert RepayBorrowFailed(error, jToken, borrower);
    }

    /// @notice Transfers ERC20 tokens out of this contract.
    /// @dev Used to recover operational funds (seized collateral, leftover repay tokens).
    /// @param token The token to transfer.
    /// @param to The recipient address.
    /// @param amount The amount to transfer. Pass 0 to transfer the entire balance.
    function transfer(address token, address to, uint256 amount) external onlyOwner {
        if (amount == 0) amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
    }

    /// @notice Executes an arbitrary call. Escape hatch for edge cases.
    /// @dev Can be used for partial liquidations (calling `liquidateBorrow` directly
    ///      with a specific repay amount) or any other operation not covered by
    ///      the dedicated functions.
    /// @param to The target contract address.
    /// @param value Native token value to send with the call.
    /// @param data The calldata to execute.
    function call(address to, uint256 value, bytes calldata data) external onlyOwner {
        Address.functionCallWithValue(to, data, value);
    }
}
