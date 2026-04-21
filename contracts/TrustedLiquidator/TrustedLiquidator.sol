// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Address} from "lib/openzeppelin-contracts/contracts/utils/Address.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Math} from "lib/openzeppelin-contracts/contracts/utils/math/Math.sol";
import {Multicall} from "lib/openzeppelin-contracts/contracts/utils/Multicall.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {SafeERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

interface JToken {
    function underlying() external view returns (address);
    function joetroller() external view returns (address);
    function balanceOf(address account) external view returns (uint256);
    function borrowBalanceCurrent(address account) external returns (uint256);
    function exchangeRateCurrent() external returns (uint256);
    function liquidateBorrow(address borrower, uint256 repayAmount, JToken jTokenCollateral) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external returns (uint256);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IJoetroller {
    function oracle() external view returns (IPriceOracle);
    function liquidationIncentiveMantissa() external view returns (uint256);
    function trustedLiquidator() external view returns (address);
    function trustedLiquidationIncentiveMantissa() external view returns (uint256);
}

interface IPriceOracle {
    function getUnderlyingPrice(address jToken) external view returns (uint256);
}

interface IEscrow {
    function storeRedeem(address token, address user) external;
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
/// This contract holds operational funds (tokens to repay borrows) and retains
/// the configured redeem fee portion of each `transferAndRedeem` call. User
/// redemption funds (net of fee) are forwarded to a separate Escrow contract.
contract TrustedLiquidator is Ownable, Multicall, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error LiquidateFailed(uint256 err, address jTokenBorrowed, address jTokenCollateral, address borrower);
    error RedeemFailed(uint256 err, address jToken, address redeemer);
    error RepayBorrowFailed(uint256 err, address jToken, address borrower);
    error RepayExceedsMax(uint256 balance, uint256 maxRepay, address jToken, address borrower);
    error InvalidRedeemFee(uint256 redeemFee);

    uint256 internal constant BPS_BASE = 10000;

    uint256 internal _redeemFee;

    event RedeemFeeSet(uint256 redeemFee);

    /// @param owner The initial owner with privileged access to all functions.
    /// @param redeemFee Initial redeem fee in basis points (0-10000). Reverts if above 10000.
    constructor(address owner, uint256 redeemFee) Ownable(owner) {
        _setRedeemFee(redeemFee);
    }

    receive() external payable {}

    /// @notice Returns the redeem fee in basis points (0-10000).
    function getRedeemFee() external view returns (uint256) {
        return _redeemFee;
    }

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

        uint256 repay = JToken(jTokenBorrowed).borrowBalanceCurrent(borrower);
        uint256 maxRepay = _maxRepayForCollateral(jTokenBorrowed, jTokenCollateral, borrower);
        if (maxRepay == 0) return;

        if (repay > maxRepay) repay = maxRepay;

        IERC20(underlying).forceApprove(jTokenBorrowed, repay);

        uint256 err = JToken(jTokenBorrowed).liquidateBorrow(borrower, repay, JToken(jTokenCollateral));
        if (err != 0) revert LiquidateFailed(err, jTokenBorrowed, jTokenCollateral, borrower);

        uint256 redeemTokens = JToken(jTokenCollateral).balanceOf(address(this));
        err = JToken(jTokenCollateral).redeem(redeemTokens);
        if (err != 0) revert RedeemFailed(err, jTokenCollateral, address(this));
    }

    /// @notice Computes the maximum repay amount that won't exceed the borrower's collateral.
    /// @param jTokenBorrowed The jToken market with the borrow.
    /// @param jTokenCollateral The jToken market to seize from.
    /// @param borrower The borrower whose collateral to check.
    /// @return maxRepay The maximum safe repay amount in underlying units of the borrowed token.
    function _maxRepayForCollateral(address jTokenBorrowed, address jTokenCollateral, address borrower)
        internal
        returns (uint256 maxRepay)
    {
        IJoetroller joetroller = IJoetroller(JToken(jTokenBorrowed).joetroller());
        IPriceOracle oracle = joetroller.oracle();

        uint256 priceBorrowed = oracle.getUnderlyingPrice(jTokenBorrowed);
        uint256 priceCollateral = oracle.getUnderlyingPrice(jTokenCollateral);
        uint256 exchangeRate = JToken(jTokenCollateral).exchangeRateCurrent();
        uint256 collateralBalance = JToken(jTokenCollateral).balanceOf(borrower);

        // Get the liquidation incentive for this contract (trusted liquidator rate)
        uint256 incentive = joetroller.trustedLiquidationIncentiveMantissa();
        if (incentive == 0) incentive = joetroller.liquidationIncentiveMantissa();

        // Inverse of the seize formula with conservative rounding.
        // Goal: maximize ratio so maxRepay is as small as possible.
        // num UP, denom DOWN → larger ratio. maxRepay DOWN → smaller result.
        uint256 num = Math.ceilDiv(incentive * priceBorrowed, 1e18);
        uint256 denom = priceCollateral * exchangeRate / 1e18;
        uint256 ratio = Math.ceilDiv(num * 1e18, denom);
        maxRepay = collateralBalance * 1e18 / ratio;
    }

    /// @notice Pulls a user's jTokens, redeems them, deducts the redeem fee, and
    ///         forwards the net underlying to the Escrow for later claim.
    /// @dev Uses the trusted liquidator's transferFrom bypass (no user approval needed).
    ///      The jTokens are pulled into this contract and redeemed here; the redeem
    ///      fee stays with this contract (recoverable via `transfer`) and the remainder
    ///      is sent to the Escrow, which records it as claimable by the user.
    /// @param escrow The Escrow contract address.
    /// @param jToken The jToken market to redeem from.
    /// @param redeemer The user whose jTokens will be transferred and redeemed.
    function transferAndRedeem(address escrow, address jToken, address redeemer) external onlyOwner nonReentrant {
        address underlying = JToken(jToken).underlying();
        uint256 underlyingBalance = IERC20(underlying).balanceOf(address(this));

        uint256 jTokenBalance = JToken(jToken).balanceOf(redeemer);
        if (jTokenBalance == 0) return;
        IERC20(jToken).safeTransferFrom(redeemer, address(this), jTokenBalance);
        uint256 err = JToken(jToken).redeem(jTokenBalance);
        if (err != 0) revert RedeemFailed(err, jToken, redeemer);

        uint256 redeemed = IERC20(underlying).balanceOf(address(this)) - underlyingBalance;

        uint256 fee = redeemed * _redeemFee / BPS_BASE;
        uint256 amount = redeemed - fee;
        if (amount == 0) return;
        IERC20(underlying).safeTransfer(escrow, amount);
        IEscrow(escrow).storeRedeem(underlying, redeemer);
    }

    /// @notice Repays a borrower's full debt on their behalf (for bad debt cases).
    /// @dev This contract must hold enough underlying tokens to cover the borrow.
    ///      The borrower's debt is zeroed out; they keep any collateral they have.
    /// @param jToken The jToken market where the borrower has debt.
    /// @param borrower The address of the borrower whose debt to repay.
    /// @param maxRepay Maximum repay amount (in underlying). Reverts if the actual
    ///        borrow exceeds this — protects against frontrunning between snapshot
    ///        and execution. Pass type(uint256).max to skip the check.
    function repayBorrowBehalf(address jToken, address borrower, uint256 maxRepay) external onlyOwner {
        uint256 balance = JToken(jToken).borrowBalanceCurrent(borrower);
        if (balance == 0) return;

        if (balance > maxRepay) revert RepayExceedsMax(balance, maxRepay, jToken, borrower);

        address underlying = JToken(jToken).underlying();
        IERC20(underlying).forceApprove(jToken, balance);

        uint256 err = JToken(jToken).repayBorrowBehalf(borrower, balance);
        if (err != 0) revert RepayBorrowFailed(err, jToken, borrower);
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

    /// @notice Executes an arbitrary call.
    /// @param to The target contract address.
    /// @param value Native token value to send with the call.
    /// @param data The calldata to execute.
    function call(address to, uint256 value, bytes calldata data) external onlyOwner {
        Address.functionCallWithValue(to, data, value);
    }

    /// @notice Sets the redeem fee in basis points. Reverts if above 10000 (100%).
    /// @param redeemFee The redeem fee to set (0-10000).
    function setRedeemFee(uint256 redeemFee) external onlyOwner {
        _setRedeemFee(redeemFee);
    }

    function _setRedeemFee(uint256 redeemFee) internal {
        if (redeemFee > BPS_BASE) revert InvalidRedeemFee(redeemFee);
        _redeemFee = redeemFee;
        emit RedeemFeeSet(redeemFee);
    }
}
