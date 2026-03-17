// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {Test, StdChains} from "lib/forge-std/src/Test.sol";
import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {TrustedLiquidator} from "../../contracts/TrustedLiquidator/TrustedLiquidator.sol";

interface IJoetroller {
    function admin() external view returns (address);
    function trustedLiquidator() external view returns (address);
    function _setTrustedLiquidator(address newTrustedLiquidator) external returns (uint256);
    function _setPendingImplementation(address newPendingImplementation) external returns (uint256);
    function _become(address joetroller) external;
    function liquidateBorrowAllowed(
        address jTokenBorrowed,
        address jTokenCollateral,
        address liquidator,
        address borrower,
        uint256 repayAmount
    ) external returns (uint256);
}

interface IJToken {
    function _setImplementation(address implementation_, bool allowResign, bytes memory becomeImplementationData)
        external;
    function balanceOf(address account) external view returns (uint256);
    function balanceOfUnderlying(address account) external returns (uint256);
    function borrowBalanceCurrent(address account) external returns (uint256);
    function mint(uint256 mintAmount) external returns (uint256);
    function redeem(uint256 redeemTokens) external returns (uint256);
    function redeemOnBehalf(address redeemer, uint256 redeemTokens) external returns (uint256);
    function repayBorrow(uint256 repayAmount) external returns (uint256);
}

contract TrustedLiquidatorTest is Test {
    address public admin;
    TrustedLiquidator public liquidator;
    IJoetroller public joetroller = IJoetroller(0xdc13687554205E5b89Ac783db14bb5bba4A1eDaC);

    address public constant MIM = 0x130966628846BFd36ff31a822705796e8cb8C18D;
    address public constant JMIM = 0xcE095A9657A02025081E0607c8D8b081c76A75ea;

    address public constant BTC = 0x50b7545627a5162F82A992c33b87aDc75187B218;
    address public constant JBTC = 0x3fE38b7b610C0ACD10296fEf69d9b18eB7a9eB1F;

    address public constant USDC = 0xA7D7079b0FEaD91F3e65f86E8915Cb59c1a4C664;
    address public constant JUSDC = 0xEd6AaF91a2B084bd594DBd1245be3691F9f637aC;

    address public constant USDT = 0xc7198437980c041c805A1EDcbA50c1Ce5db95118;
    address public constant JUSDT = 0x8b650e26404AC6837539ca96812f0123601E4448;

    address public constant USER_DEPOSITED_MIM = 0x796BE5344E7076f363c7B6cb76Df11C9b1e91156;
    address public constant USER_BORROWED_MIM = 0xc3Fd4Acb7efFD92FC7a88c62b05776Fb6C4d0cDd;
    address public constant USER_MIM_BAD_DEBT = 0xa75D8527939adc9c370774b456727FD43a2272D9;
    address public constant USER_BORROWED_AGAINST_MIM = 0x3aa5F6e2Eb0F70699Ea9E72A90A0D8dA495FE53C;

    function setUp() public {
        vm.createSelectFork(StdChains.getChain("avalanche").rpcUrl, 80524427);

        admin = joetroller.admin();

        address newJoetroller = deployCode("Joetroller.sol");
        address newJmim = deployCode("JCollateralCapErc20Delegate.sol");
        liquidator = new TrustedLiquidator(admin);

        vm.startPrank(admin);
        joetroller._setPendingImplementation(newJoetroller);
        IJoetroller(newJoetroller)._become(address(joetroller));
        IJToken(JMIM)._setImplementation(newJmim, false, "");
        joetroller._setTrustedLiquidator(address(liquidator));
        vm.stopPrank();
    }

    // -- TrustedLiquidator functional tests --

    function test_RedeemOnBehalf() public {
        uint256 mimBalance = IERC20(MIM).balanceOf(USER_DEPOSITED_MIM);
        uint256 underlyingBalance = IJToken(JMIM).balanceOfUnderlying(USER_DEPOSITED_MIM);
        uint256 jmimBalance = IERC20(JMIM).balanceOf(USER_DEPOSITED_MIM);
        assertGt(jmimBalance, 0, "test_RedeemOnBehalf::1");

        vm.prank(admin);
        liquidator.redeemOnBehalf(JMIM, USER_DEPOSITED_MIM);

        assertEq(IERC20(JMIM).balanceOf(USER_DEPOSITED_MIM), 0, "test_RedeemOnBehalf::2");
        assertEq(IERC20(MIM).balanceOf(USER_DEPOSITED_MIM), mimBalance + underlyingBalance, "test_RedeemOnBehalf::3");
    }

    function test_Liquidate() public {
        uint256 jbtcBalance = IERC20(JBTC).balanceOf(USER_BORROWED_MIM);

        uint256 snapshot = vm.snapshotState();
        uint256 borrowed = IJToken(JMIM).borrowBalanceCurrent(USER_BORROWED_MIM);
        vm.revertToState(snapshot);
        assertGt(borrowed, 0, "test_Liquidate::1");

        deal(MIM, address(liquidator), borrowed);

        vm.prank(admin);
        liquidator.liquidate(JMIM, JBTC, USER_BORROWED_MIM);

        assertLt(IERC20(JBTC).balanceOf(USER_BORROWED_MIM), jbtcBalance, "test_Liquidate::2");
        assertEq(IJToken(JMIM).borrowBalanceCurrent(USER_BORROWED_MIM), 0, "test_Liquidate::3");
        assertGt(IERC20(BTC).balanceOf(address(liquidator)), 0, "test_Liquidate::4");
    }

    function test_RepayBorrowBehalf() public {
        uint256 mimBalance = IERC20(MIM).balanceOf(USER_MIM_BAD_DEBT);

        uint256 snapshot = vm.snapshotState();
        uint256 borrowed = IJToken(JMIM).borrowBalanceCurrent(USER_MIM_BAD_DEBT);
        vm.revertToState(snapshot);
        assertGt(borrowed, 0, "test_RepayBorrowBehalf::1");

        deal(MIM, address(liquidator), borrowed);

        vm.prank(admin);
        liquidator.repayBorrowBehalf(JMIM, USER_MIM_BAD_DEBT);

        assertEq(IJToken(JMIM).borrowBalanceCurrent(USER_MIM_BAD_DEBT), 0, "test_RepayBorrowBehalf::3");
        assertEq(IERC20(MIM).balanceOf(USER_MIM_BAD_DEBT), mimBalance, "test_RepayBorrowBehalf::4");
    }

    function test_LiquidateOtherTokens() public {
        uint256 mimBalance = IERC20(MIM).balanceOf(USER_BORROWED_AGAINST_MIM);

        uint256 snapshot = vm.snapshotState();
        uint256 borrowedUsdc = IJToken(JUSDC).borrowBalanceCurrent(USER_BORROWED_AGAINST_MIM);
        vm.revertToState(snapshot);
        assertGt(borrowedUsdc, 0, "test_LiquidateOtherTokens::1");

        deal(USDC, address(liquidator), borrowedUsdc);

        vm.startPrank(admin);
        liquidator.liquidate(JUSDC, JMIM, USER_BORROWED_AGAINST_MIM);
        liquidator.redeemOnBehalf(JMIM, USER_BORROWED_AGAINST_MIM);
        vm.stopPrank();

        assertEq(IJToken(JUSDC).borrowBalanceCurrent(USER_BORROWED_AGAINST_MIM), 0, "test_LiquidateOtherTokens::3");
        assertGt(IERC20(MIM).balanceOf(address(liquidator)), 0, "test_LiquidateOtherTokens::4");
        assertGt(IERC20(MIM).balanceOf(USER_BORROWED_AGAINST_MIM), mimBalance, "test_LiquidateOtherTokens::5");
    }

    function test_TransferWorks() public {
        uint256 amount = 1000e18;
        deal(MIM, address(liquidator), amount);
        address recipient = makeAddr("recipient");

        vm.prank(admin);
        liquidator.transfer(MIM, recipient, amount);

        assertEq(IERC20(MIM).balanceOf(recipient), amount, "test_TransferWorks::1");
        assertEq(IERC20(MIM).balanceOf(address(liquidator)), 0, "test_TransferWorks::2");
    }

    function test_TransferZeroMeansAll() public {
        uint256 amount = 1000e18;
        deal(MIM, address(liquidator), amount);
        address recipient = makeAddr("recipient");

        vm.prank(admin);
        liquidator.transfer(MIM, recipient, 0);

        assertEq(IERC20(MIM).balanceOf(recipient), amount, "test_TransferZeroMeansAll::1");
    }

    function test_MulticallBatchWorks() public {
        uint256 snapshot = vm.snapshotState();
        uint256 borrowed = IJToken(JMIM).borrowBalanceCurrent(USER_BORROWED_MIM);
        vm.revertToState(snapshot);

        deal(MIM, address(liquidator), borrowed);

        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(TrustedLiquidator.liquidate, (JMIM, JBTC, USER_BORROWED_MIM));

        vm.prank(admin);
        liquidator.multicall(calls);

        assertEq(IJToken(JMIM).borrowBalanceCurrent(USER_BORROWED_MIM), 0, "test_MulticallBatchWorks::1");
        assertGt(IERC20(BTC).balanceOf(address(liquidator)), 0, "test_MulticallBatchWorks::2");
    }

    // -- TrustedLiquidator access control --

    function test_LiquidateOnlyOwner() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        liquidator.liquidate(JMIM, JBTC, USER_BORROWED_MIM);
    }

    function test_RedeemOnBehalfOnlyOwner() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        liquidator.redeemOnBehalf(JMIM, USER_DEPOSITED_MIM);
    }

    function test_RepayBorrowBehalfOnlyOwner() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        liquidator.repayBorrowBehalf(JMIM, USER_MIM_BAD_DEBT);
    }

    function test_TransferOnlyOwner() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        liquidator.transfer(MIM, makeAddr("random"), 0);
    }

    function test_CallOnlyOwner() public {
        vm.prank(makeAddr("random"));
        vm.expectRevert();
        liquidator.call(JMIM, 0, "");
    }

    function test_MulticallOnlyOwner() public {
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(TrustedLiquidator.redeemOnBehalf, (JMIM, USER_DEPOSITED_MIM));

        vm.prank(makeAddr("random"));
        vm.expectRevert();
        liquidator.multicall(calls);
    }

    // -- Joetroller: _setTrustedLiquidator access control --

    function test_SetTrustedLiquidator_OnlyAdmin() public {
        address random = makeAddr("random");

        vm.prank(random);
        uint256 err = joetroller._setTrustedLiquidator(random);
        assertNotEq(err, 0, "non-admin should fail");
        assertEq(joetroller.trustedLiquidator(), address(liquidator), "state should not change");
    }

    function test_SetTrustedLiquidator_AdminSucceeds() public {
        address newLiq = makeAddr("newLiq");

        vm.prank(admin);
        uint256 err = joetroller._setTrustedLiquidator(newLiq);
        assertEq(err, 0, "admin call should succeed");
        assertEq(joetroller.trustedLiquidator(), newLiq, "trustedLiquidator not updated");
    }

    function test_SetTrustedLiquidator_CanSetToZero() public {
        vm.prank(admin);
        uint256 err = joetroller._setTrustedLiquidator(address(0));
        assertEq(err, 0, "should succeed");
        assertEq(joetroller.trustedLiquidator(), address(0), "should be zero");
    }

    // -- JToken: redeemOnBehalf access control --

    function test_RedeemOnBehalf_OnlyTrustedLiquidator() public {
        uint256 balance = IJToken(JMIM).balanceOf(USER_DEPOSITED_MIM);
        assertGt(balance, 0, "user should have jMIM");

        vm.prank(makeAddr("random"));
        uint256 err = IJToken(JMIM).redeemOnBehalf(USER_DEPOSITED_MIM, balance);
        assertNotEq(err, 0, "non-trusted should fail");
        assertEq(IJToken(JMIM).balanceOf(USER_DEPOSITED_MIM), balance, "balance should not change");
    }

    function test_RedeemOnBehalf_AdminCannotCallDirectly() public {
        uint256 balance = IJToken(JMIM).balanceOf(USER_DEPOSITED_MIM);

        vm.prank(admin);
        uint256 err = IJToken(JMIM).redeemOnBehalf(USER_DEPOSITED_MIM, balance);
        assertNotEq(err, 0, "admin direct call should fail");
    }

    // -- Trusted liquidator bypasses --

    function test_TrustedLiquidator_BypassesShortfallCheck() public {
        uint256 snapshot = vm.snapshotState();
        uint256 borrowed = IJToken(JMIM).borrowBalanceCurrent(USER_BORROWED_MIM);
        vm.revertToState(snapshot);
        assertGt(borrowed, 0, "user should have borrow");

        uint256 err = joetroller.liquidateBorrowAllowed(JMIM, JBTC, address(liquidator), USER_BORROWED_MIM, borrowed);
        assertEq(err, 0, "trusted liquidator should be allowed");
    }

    function test_TrustedLiquidator_BypassesCloseFactorLimit() public {
        uint256 snapshot = vm.snapshotState();
        uint256 borrowed = IJToken(JMIM).borrowBalanceCurrent(USER_BORROWED_MIM);
        vm.revertToState(snapshot);
        assertGt(borrowed, 0, "user should have borrow");

        uint256 err = joetroller.liquidateBorrowAllowed(JMIM, JBTC, address(liquidator), USER_BORROWED_MIM, borrowed);
        assertEq(err, 0, "full repay as trusted should succeed");
    }

    function test_RegularLiquidator_StillHasShortfallCheck() public {
        uint256 err = joetroller.liquidateBorrowAllowed(JMIM, JUSDC, makeAddr("random"), USER_DEPOSITED_MIM, 1);
        assertNotEq(err, 0, "regular should not bypass shortfall");
    }

    function test_RegularLiquidator_StillHasCloseFactorLimit() public {
        uint256 snapshot = vm.snapshotState();
        uint256 borrowed = IJToken(JMIM).borrowBalanceCurrent(USER_BORROWED_MIM);
        vm.revertToState(snapshot);

        uint256 err = joetroller.liquidateBorrowAllowed(JMIM, JBTC, makeAddr("random"), USER_BORROWED_MIM, borrowed);
        assertNotEq(err, 0, "regular should not bypass close factor");
    }

    // -- Market operations post-upgrade --

    function test_SupplyAndRedeem_WorksAfterUpgrade() public {
        address supplier = makeAddr("supplier");
        uint256 mintAmount = 100e6;

        deal(USDC, supplier, mintAmount);

        vm.startPrank(supplier);
        IERC20(USDC).approve(JUSDC, mintAmount);
        uint256 mintErr = IJToken(JUSDC).mint(mintAmount);
        vm.stopPrank();
        assertEq(mintErr, 0, "mint should succeed");

        uint256 jTokenBalance = IJToken(JUSDC).balanceOf(supplier);
        assertGt(jTokenBalance, 0, "should have jTokens");

        vm.prank(supplier);
        uint256 redeemErr = IJToken(JUSDC).redeem(jTokenBalance);
        assertEq(redeemErr, 0, "redeem should succeed");
        assertEq(IJToken(JUSDC).balanceOf(supplier), 0, "should have 0 jTokens");
        assertGt(IERC20(USDC).balanceOf(supplier), 0, "should have USDC back");
    }

    function test_BorrowAndRepay_WorksAfterUpgrade() public {
        uint256 snapshot = vm.snapshotState();
        uint256 borrowed = IJToken(JMIM).borrowBalanceCurrent(USER_BORROWED_MIM);
        vm.revertToState(snapshot);
        assertGt(borrowed, 0, "should have borrow");

        deal(MIM, USER_BORROWED_MIM, borrowed);

        vm.startPrank(USER_BORROWED_MIM);
        IERC20(MIM).approve(JMIM, borrowed);
        uint256 repayErr = IJToken(JMIM).repayBorrow(borrowed);
        vm.stopPrank();
        assertEq(repayErr, 0, "repay should succeed");
        assertEq(IJToken(JMIM).borrowBalanceCurrent(USER_BORROWED_MIM), 0, "borrow should be zero");
    }

    // -- Edge cases: trusted liquidator removed --

    function test_RemovedTrustedLiquidator_CannotAct() public {
        vm.prank(admin);
        joetroller._setTrustedLiquidator(address(0));

        vm.prank(admin);
        vm.expectRevert();
        liquidator.redeemOnBehalf(JMIM, USER_DEPOSITED_MIM);
    }

    function test_RemovedTrustedLiquidator_RegularLiquidationUnchanged() public {
        vm.prank(admin);
        joetroller._setTrustedLiquidator(address(0));

        uint256 err = joetroller.liquidateBorrowAllowed(JMIM, JUSDC, makeAddr("random"), USER_DEPOSITED_MIM, 1);
        assertNotEq(err, 0, "should still enforce shortfall");
    }
}
