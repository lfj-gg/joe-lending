// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";

import {WindDownTestBase, IJoetroller, IJTokenAdmin} from "./WindDownTestBase.sol";

interface IJTokenWindDown is IJTokenAdmin {
    function mint(uint256) external returns (uint256);
    function redeem(uint256) external returns (uint256);
    function redeemUnderlying(uint256) external returns (uint256);
    function borrow(uint256) external returns (uint256);
    function repayBorrow(uint256) external returns (uint256);
    function repayBorrowBehalf(address, uint256) external returns (uint256);
    function liquidateBorrow(address, uint256, address) external returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function seize(address, address, uint256) external returns (uint256);
    function gulp() external;
    function flashLoan(address, address, uint256, bytes calldata) external returns (bool);
    function registerCollateral(address) external returns (uint256);
    function unregisterCollateral(address) external;
    function _addReserves(uint256) external returns (uint256);
    function _setCollateralCap(uint256) external;
    function _setProtocolSeizeShare(uint256) external returns (uint256);
    function mintNative() external payable returns (uint256);
    function redeemNative(uint256) external returns (uint256);
    function redeemUnderlyingNative(uint256) external returns (uint256);
    function borrowNative(uint256) external returns (uint256);
    function repayBorrowNative() external payable returns (uint256);
    function repayBorrowBehalfNative(address) external payable returns (uint256);
    function liquidateBorrowNative(address, address) external payable returns (uint256);
    function _addReservesNative() external payable returns (uint256);
    function burn(address) external;
    function sweep(address, uint256) external;
    function getAccountSnapshot(address) external view returns (uint256, uint256, uint256, uint256);
}

contract WindDownUpgradeTest is WindDownTestBase {
    function setUp() public {
        _fullSetup();
    }

    /* --------------------------------------------------------------------- */
    /* Reverts on user-facing externals                                       */
    /* --------------------------------------------------------------------- */

    function test_RevertWindDown_mint() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).mint(1);
    }

    function test_RevertWindDown_redeem() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).redeem(1);
    }

    function test_RevertWindDown_redeemUnderlying() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).redeemUnderlying(1);
    }

    function test_RevertWindDown_borrow() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).borrow(1);
    }

    function test_RevertWindDown_repayBorrow() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).repayBorrow(1);
    }

    function test_RevertWindDown_repayBorrowBehalf() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).repayBorrowBehalf(alice, 1);
    }

    function test_RevertWindDown_liquidateBorrow() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).liquidateBorrow(alice, 1, JUSDC);
    }

    function test_RevertWindDown_transfer() public {
        vm.prank(alice);
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).transfer(bob, 1);
    }

    function test_RevertWindDown_transferFrom() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).transferFrom(alice, bob, 1);
    }

    function test_RevertWindDown_seize() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).seize(bob, alice, 1);
    }

    function test_RevertWindDown_gulp() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).gulp();
    }

    function test_RevertWindDown_flashLoan() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).flashLoan(address(0), address(0), 0, "");
    }

    function test_RevertWindDown_registerCollateral() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).registerCollateral(alice);
    }

    function test_RevertWindDown_unregisterCollateral() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC).unregisterCollateral(alice);
    }

    function test_RevertWindDown_addReserves() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC)._addReserves(1);
    }

    function test_RevertWindDown_setCollateralCap() public {
        vm.prank(admin);
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC)._setCollateralCap(1);
    }

    function test_RevertWindDown_setProtocolSeizeShare() public {
        vm.prank(admin);
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JUSDC)._setProtocolSeizeShare(1);
    }

    /* --------------------------------------------------------------------- */
    /* JWrappedNative — extra native variants                                 */
    /* --------------------------------------------------------------------- */

    function test_RevertWindDown_native_mint() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).mint(1);
    }

    function test_RevertWindDown_native_mintNative() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).mintNative{value: 1 ether}();
    }

    function test_RevertWindDown_native_redeem() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).redeem(1);
    }

    function test_RevertWindDown_native_redeemNative() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).redeemNative(1);
    }

    function test_RevertWindDown_native_redeemUnderlying() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).redeemUnderlying(1);
    }

    function test_RevertWindDown_native_redeemUnderlyingNative() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).redeemUnderlyingNative(1);
    }

    function test_RevertWindDown_native_borrow() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).borrow(1);
    }

    function test_RevertWindDown_native_borrowNative() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).borrowNative(1);
    }

    function test_RevertWindDown_native_repayBorrow() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).repayBorrow(1);
    }

    function test_RevertWindDown_native_repayBorrowNative() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).repayBorrowNative{value: 1 ether}();
    }

    function test_RevertWindDown_native_repayBorrowBehalf() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).repayBorrowBehalf(alice, 1);
    }

    function test_RevertWindDown_native_repayBorrowBehalfNative() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).repayBorrowBehalfNative{value: 1 ether}(bob);
    }

    function test_RevertWindDown_native_liquidateBorrow() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).liquidateBorrow(alice, 1, JAVAX);
    }

    function test_RevertWindDown_native_liquidateBorrowNative() public {
        vm.deal(alice, 1 ether);
        vm.prank(alice);
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX).liquidateBorrowNative{value: 1 ether}(bob, JAVAX);
    }

    function test_RevertWindDown_native_addReserves() public {
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX)._addReserves(1);
    }

    function test_RevertWindDown_native_addReservesNative() public {
        vm.deal(admin, 1 ether);
        vm.prank(admin);
        vm.expectRevert(bytes("wind down"));
        IJTokenWindDown(JAVAX)._addReservesNative{value: 1 ether}();
    }

    /* --------------------------------------------------------------------- */
    /* Reads still work                                                       */
    /* --------------------------------------------------------------------- */

    function test_Reads_balanceOf_returnsAlicePosition() public view {
        assertGt(IJTokenWindDown(JUSDC).balanceOf(alice), 0, "alice has jUSDC");
    }

    function test_Reads_borrowBalanceStored_returnsZero() public view {
        assertEq(IJTokenWindDown(JUSDC).borrowBalanceStored(alice), 0);
    }

    function test_Reads_exchangeRateStored_nonZero() public view {
        assertGt(IJTokenWindDown(JUSDC).exchangeRateStored(), 0);
    }

    function test_Reads_getCash_nonZero() public view {
        assertGt(IJTokenWindDown(JUSDC).getCash(), 0);
    }

    function test_Reads_getAccountSnapshot_returnsLiveValues() public view {
        (uint256 err, uint256 jBal, uint256 borrowBal, uint256 exch) =
            IJTokenWindDown(JUSDC).getAccountSnapshot(alice);
        assertEq(err, 0);
        assertGt(jBal, 0);
        assertEq(borrowBal, 0);
        assertGt(exch, 0);
    }

    function test_Reads_accrueInterest_returnsNoError() public {
        assertEq(IJTokenWindDown(JUSDC).accrueInterest(), 0);
    }

    /* --------------------------------------------------------------------- */
    /* Admin functions still work                                             */
    /* --------------------------------------------------------------------- */

    function test_Admin_setInterestRateModel_works() public {
        // Re-pointing the IRM to the existing one is the simplest way to verify
        // the admin path still functions (any non-zero address would do).
        address currentIRM = IJTokenWindDown(JUSDC).interestRateModel();
        vm.prank(admin);
        assertEq(IJTokenWindDown(JUSDC)._setInterestRateModel(currentIRM), 0);
    }

    function test_Admin_setReserveFactor_works() public {
        vm.prank(admin);
        assertEq(IJTokenWindDown(JUSDC)._setReserveFactor(0.05e18), 0);
        assertEq(IJTokenWindDown(JUSDC).reserveFactorMantissa(), 0.05e18);
    }

    function test_Admin_setPendingAdmin_works() public {
        vm.prank(admin);
        assertEq(IJTokenWindDown(JUSDC)._setPendingAdmin(payable(alice)), 0);
    }

    /* --------------------------------------------------------------------- */
    /* Burn — JCollateralCapErc20 (collateral-capable)                        */
    /* --------------------------------------------------------------------- */

    function test_Burn_zeroesEverything() public {
        uint256 jBalBefore = IJTokenWindDown(JUSDC).balanceOf(alice);
        uint256 collBefore = IJTokenWindDown(JUSDC).accountCollateralTokens(alice);
        uint256 totalSupplyBefore = IJTokenWindDown(JUSDC).totalSupply();
        uint256 totalCollateralBefore = IJTokenWindDown(JUSDC).totalCollateralTokens();

        assertGt(jBalBefore, 0, "precondition: balance > 0");
        assertGt(collBefore, 0, "precondition: collateral > 0");

        vm.prank(address(escrow));
        IJTokenWindDown(JUSDC).burn(alice);

        assertEq(IJTokenWindDown(JUSDC).balanceOf(alice), 0, "accountTokens not zeroed");
        assertEq(IJTokenWindDown(JUSDC).accountCollateralTokens(alice), 0, "accountCollateralTokens not zeroed");
        assertEq(
            IJTokenWindDown(JUSDC).totalSupply(),
            totalSupplyBefore - jBalBefore,
            "totalSupply not decremented"
        );
        assertEq(
            IJTokenWindDown(JUSDC).totalCollateralTokens(),
            totalCollateralBefore - collBefore,
            "totalCollateralTokens not decremented"
        );
    }

    function test_Burn_idempotent_onZeroBalance() public {
        uint256 totalSupplyBefore = IJTokenWindDown(JUSDC).totalSupply();
        uint256 totalCollateralBefore = IJTokenWindDown(JUSDC).totalCollateralTokens();

        vm.prank(address(escrow));
        IJTokenWindDown(JUSDC).burn(bob); // bob has no jUSDC

        assertEq(IJTokenWindDown(JUSDC).balanceOf(bob), 0);
        assertEq(IJTokenWindDown(JUSDC).totalSupply(), totalSupplyBefore, "totalSupply must not change");
        assertEq(IJTokenWindDown(JUSDC).totalCollateralTokens(), totalCollateralBefore);
    }

    function test_Burn_revertsIfNotTrustedLiquidator() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_TL"));
        IJTokenWindDown(JUSDC).burn(alice);

        vm.prank(admin);
        vm.expectRevert(bytes("ONLY_TL"));
        IJTokenWindDown(JUSDC).burn(alice);
    }

    function test_Burn_emitsTransfer() public {
        uint256 amount = IJTokenWindDown(JUSDC).balanceOf(alice);

        vm.expectEmit(true, true, true, true, JUSDC);
        emit Transfer(alice, address(0), amount);

        vm.prank(address(escrow));
        IJTokenWindDown(JUSDC).burn(alice);
    }

    /* --------------------------------------------------------------------- */
    /* Burn — JWrappedNative                                                  */
    /* --------------------------------------------------------------------- */

    function test_BurnNative_zeroesAccountTokens() public {
        uint256 jBalBefore = IJTokenWindDown(JAVAX).balanceOf(bob);
        uint256 totalSupplyBefore = IJTokenWindDown(JAVAX).totalSupply();
        assertGt(jBalBefore, 0, "precondition");

        vm.prank(address(escrow));
        IJTokenWindDown(JAVAX).burn(bob);

        assertEq(IJTokenWindDown(JAVAX).balanceOf(bob), 0);
        assertEq(IJTokenWindDown(JAVAX).totalSupply(), totalSupplyBefore - jBalBefore);
    }

    function test_BurnNative_idempotent_onZero() public {
        uint256 totalSupplyBefore = IJTokenWindDown(JAVAX).totalSupply();
        vm.prank(address(escrow));
        IJTokenWindDown(JAVAX).burn(alice); // alice has no jAVAX
        assertEq(IJTokenWindDown(JAVAX).totalSupply(), totalSupplyBefore);
    }

    function test_BurnNative_revertsIfNotTL() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_TL"));
        IJTokenWindDown(JAVAX).burn(bob);
    }

    /* --------------------------------------------------------------------- */
    /* Sweep                                                                  */
    /* --------------------------------------------------------------------- */

    function test_Sweep_byAdmin_fullBalance_whenAmountZero() public {
        // Top up the contract beyond the cash currently backing supply so sweep
        // has visible work to do. The full-balance branch (`amount == 0`) should
        // drain the entire underlying balance, including any donated dust.
        deal(USDC, JUSDC, 100e6);
        uint256 before = IERC20(USDC).balanceOf(JUSDC);
        assertGt(before, 0);

        vm.prank(admin);
        IJTokenWindDown(JUSDC).sweep(treasury, 0);

        assertEq(IERC20(USDC).balanceOf(JUSDC), 0, "JUSDC not drained");
        assertEq(IERC20(USDC).balanceOf(treasury), before, "treasury not credited");
    }

    function test_Sweep_byAdmin_partialAmount() public {
        deal(USDC, JUSDC, 100e6);
        uint256 sweepAmount = 25e6;
        uint256 before = IERC20(USDC).balanceOf(JUSDC);

        vm.prank(admin);
        IJTokenWindDown(JUSDC).sweep(treasury, sweepAmount);

        assertEq(IERC20(USDC).balanceOf(JUSDC), before - sweepAmount);
        assertEq(IERC20(USDC).balanceOf(treasury), sweepAmount);
    }

    function test_Sweep_drainsDustAboveInternalCash() public {
        // Ensure on-chain balance exceeds the contract's `internalCash` (dust
        // donated post-mint, fee-on-transfer residue, accidental sends, etc.).
        // Pre-fix, `sweep` with `amount == 0` would underflow when subtracting
        // the on-chain balance from a smaller `internalCash`. The fix resets
        // `internalCash = balance` before `doTransferOut` decrements it back
        // to zero.
        uint256 internalCash = IJTokenWindDown(JUSDC).getCash();
        uint256 dust = 7e6;
        deal(USDC, JUSDC, internalCash + dust);
        assertGt(IERC20(USDC).balanceOf(JUSDC), internalCash, "precondition: dust above internalCash");

        vm.prank(admin);
        IJTokenWindDown(JUSDC).sweep(treasury, 0);

        assertEq(IERC20(USDC).balanceOf(JUSDC), 0, "JUSDC not fully drained");
        assertEq(IJTokenWindDown(JUSDC).getCash(), 0, "internalCash not zeroed");
        assertEq(IERC20(USDC).balanceOf(treasury), internalCash + dust, "treasury short");
    }

    function test_Sweep_revertsForNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_ADMIN"));
        IJTokenWindDown(JUSDC).sweep(treasury, 0);
    }

    function test_SweepNative_byAdmin() public {
        deal(WAVAX, JAVAX, 5 ether);
        uint256 before = IERC20(WAVAX).balanceOf(JAVAX);

        vm.prank(admin);
        IJTokenWindDown(JAVAX).sweep(treasury, 0);

        assertEq(IERC20(WAVAX).balanceOf(JAVAX), 0);
        assertEq(IERC20(WAVAX).balanceOf(treasury), before);
    }

    function test_SweepNative_revertsForNonAdmin() public {
        vm.prank(alice);
        vm.expectRevert(bytes("ONLY_ADMIN"));
        IJTokenWindDown(JAVAX).sweep(treasury, 0);
    }

    /* --------------------------------------------------------------------- */
    /* Storage layout preservation through upgrade                            */
    /* --------------------------------------------------------------------- */

    function test_StorageLayout_preservedThroughUpgrade() public view {
        // We mint pre-upgrade and the constructor already upgraded; we confirm
        // accountTokens, totalSupply, totalCollateralTokens etc. are coherent.
        uint256 jBal = IJTokenWindDown(JUSDC).balanceOf(alice);
        uint256 coll = IJTokenWindDown(JUSDC).accountCollateralTokens(alice);
        uint256 ts = IJTokenWindDown(JUSDC).totalSupply();
        uint256 tCol = IJTokenWindDown(JUSDC).totalCollateralTokens();
        assertGt(jBal, 0);
        assertEq(coll, jBal, "alice collateral should equal her token balance after enterMarkets");
        assertGe(ts, jBal);
        assertGe(tCol, coll);
    }

    /* --------------------------------------------------------------------- */
    /* Events                                                                 */
    /* --------------------------------------------------------------------- */

    event Transfer(address indexed from, address indexed to, uint256 amount);
}
