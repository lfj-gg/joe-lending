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
    function redeemOnBehalf(address redeemer, uint256 redeemTokens) external returns (uint256);
    function repayBorrowBehalf(address borrower, uint256 repayAmount) external returns (uint256);
}

contract TrustedLiquidator is Ownable, Multicall {
    using SafeERC20 for IERC20;

    error LiquidateFailed(uint256 error, address jTokenBorrowed, address jTokenCollateral, address borrower);
    error RedeemFailed(uint256 error, address jTokenCollateral, address redeemer);
    error RepayBorrowFailed(uint256 error, address jToken, address borrower);

    constructor(address owner) Ownable(owner) {}

    receive() external payable {}

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

    function redeemOnBehalf(address jToken, address redeemer) external onlyOwner {
        uint256 balance = JToken(jToken).balanceOf(redeemer);
        uint256 error = JToken(jToken).redeemOnBehalf(redeemer, balance);
        if (error != 0) revert RedeemFailed(error, jToken, redeemer);
    }

    function repayBorrowBehalf(address jToken, address borrower) external onlyOwner {
        address underlying = JToken(jToken).underlying();
        uint256 balance = JToken(jToken).borrowBalanceCurrent(borrower);

        IERC20(underlying).forceApprove(jToken, balance);

        uint256 error = JToken(jToken).repayBorrowBehalf(borrower, balance);
        if (error != 0) revert RepayBorrowFailed(error, jToken, borrower);
    }

    function transfer(address token, address to, uint256 amount) external onlyOwner {
        if (amount == 0) amount = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransfer(to, amount);
    }

    function call(address to, uint256 value, bytes calldata data) external onlyOwner {
        Address.functionCallWithValue(to, data, value);
    }
}
