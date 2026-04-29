// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

import {SimpleEscrow} from "../../contracts/TrustedLiquidator/SimpleEscrow.sol";
import {WindDownTestBase, IJoetroller, IJTokenAdmin} from "./WindDownTestBase.sol";

contract SimpleEscrowTest is WindDownTestBase {
    function setUp() public {
        _fullSetup();
    }

    function _singletonPositions(address user, address token, uint256 amount)
        internal
        pure
        returns (SimpleEscrow.Position[] memory positions)
    {
        positions = new SimpleEscrow.Position[](1);
        positions[0] = SimpleEscrow.Position({user: user, token: token, amount: amount});
    }

    /* --------------------------------------------------------------------- */
    /* Constructor                                                            */
    /* --------------------------------------------------------------------- */

    function test_Constructor_buildsJTokenMap() public view {
        // The setup escrow was built against the live Joetroller, so every
        // listed market's underlying should now resolve back to its jToken.
        address[] memory markets = joetroller.getAllMarkets();
        for (uint256 i = 0; i < markets.length; i++) {
            address underlying = IJTokenAdmin(markets[i]).underlying();
            assertEq(escrow.jTokens(underlying), markets[i]);
        }
    }

    function test_Constructor_setsDeadline() public view {
        assertEq(escrow.deadline(), deadline);
    }

    function test_Constructor_revertsOnPastDeadline() public {
        vm.expectRevert(SimpleEscrow.DeadlineInPast.selector);
        new SimpleEscrow(admin, address(joetroller), block.timestamp);
    }

    function test_Constructor_setsOwner() public view {
        assertEq(escrow.owner(), admin);
    }

    /* --------------------------------------------------------------------- */
    /* set                                                                    */
    /* --------------------------------------------------------------------- */

    function test_Set_populatesClaimable() public {
        SimpleEscrow.Position[] memory positions = new SimpleEscrow.Position[](2);
        positions[0] = SimpleEscrow.Position({user: alice, token: USDC, amount: 100e6});
        positions[1] = SimpleEscrow.Position({user: bob, token: USDC, amount: 50e6});

        vm.prank(admin);
        escrow.set(positions);

        assertEq(escrow.claimable(alice, USDC), 100e6);
        assertEq(escrow.claimable(bob, USDC), 50e6);
    }

    function test_Set_revertsOnDoubleSet() public {
        vm.startPrank(admin);
        escrow.set(_singletonPositions(alice, USDC, 100e6));
        vm.expectRevert(SimpleEscrow.PositionAlreadySet.selector);
        escrow.set(_singletonPositions(alice, USDC, 200e6));
        vm.stopPrank();
    }

    function test_Set_revertsAfterDeadline() public {
        vm.warp(deadline + 1);
        vm.prank(admin);
        vm.expectRevert(SimpleEscrow.DeadlinePassed.selector);
        escrow.set(_singletonPositions(alice, USDC, 1));
    }

    function test_Set_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        escrow.set(_singletonPositions(alice, USDC, 1));
    }

    /* --------------------------------------------------------------------- */
    /* claim                                                                  */
    /* --------------------------------------------------------------------- */

    function _seedAndSetClaim(address user, address token, uint256 amount) internal {
        deal(token, address(escrow), amount);
        vm.prank(admin);
        escrow.set(_singletonPositions(user, token, amount));
    }

    function test_Claim_transfersUnderlyingAndZeroesClaimable() public {
        uint256 amount = 250e6;
        _seedAndSetClaim(alice, USDC, amount);

        uint256 escrowBefore = IERC20(USDC).balanceOf(address(escrow));
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        assertGt(IJTokenAdmin(JUSDC).balanceOf(alice), 0, "precondition: alice has jUSDC");

        vm.prank(alice);
        escrow.claim(USDC);

        assertEq(escrow.claimable(alice, USDC), 0, "claimable not zeroed");
        assertEq(IERC20(USDC).balanceOf(alice), aliceBefore + amount, "underlying not credited");
        assertEq(IERC20(USDC).balanceOf(address(escrow)), escrowBefore - amount, "escrow not debited");
        assertEq(IJTokenAdmin(JUSDC).balanceOf(alice), 0, "jUSDC not burned");
    }

    function test_Claim_emitsClaimed() public {
        uint256 amount = 250e6;
        _seedAndSetClaim(alice, USDC, amount);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit Claimed(alice, USDC, amount);

        vm.prank(alice);
        escrow.claim(USDC);
    }

    function test_Claim_revertsAfterDeadline() public {
        _seedAndSetClaim(alice, USDC, 250e6);
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(SimpleEscrow.DeadlinePassed.selector);
        escrow.claim(USDC);
    }

    function test_Claim_revertsIfNothingToClaim() public {
        vm.prank(alice);
        vm.expectRevert(SimpleEscrow.NothingToClaim.selector);
        escrow.claim(USDC);
    }

    function test_Claim_revertsIfDoubleClaim() public {
        _seedAndSetClaim(alice, USDC, 250e6);
        vm.startPrank(alice);
        escrow.claim(USDC);
        vm.expectRevert(SimpleEscrow.NothingToClaim.selector);
        escrow.claim(USDC);
        vm.stopPrank();
    }

    function test_Claim_revertsForUnknownToken() public {
        // Admin records a position for a token whose underlying isn't in any
        // listed market — the constructor never mapped it to a jToken. The
        // user trips the explicit `InvalidToken` guard before the would-be
        // zero-address burn. (No need to fund the escrow — the revert happens
        // before the underlying transfer.)
        address rogueToken = address(0xC0FFEE);
        vm.prank(admin);
        escrow.set(_singletonPositions(alice, rogueToken, 100e6));

        vm.prank(alice);
        vm.expectRevert(SimpleEscrow.InvalidToken.selector);
        escrow.claim(rogueToken);
    }

    function test_Claim_succeedsAtExactDeadline() public {
        // `claim` reverts only on `block.timestamp > deadline`. At equality the
        // claim window is still open — last second of the auction.
        _seedAndSetClaim(alice, USDC, 250e6);
        vm.warp(deadline);
        vm.prank(alice);
        escrow.claim(USDC);
        assertEq(escrow.claimable(alice, USDC), 0);
    }

    /* --------------------------------------------------------------------- */
    /* sweep                                                                  */
    /* --------------------------------------------------------------------- */

    function test_Sweep_revertsBeforeDeadline() public {
        deal(USDC, address(escrow), 1_000e6);
        vm.prank(admin);
        vm.expectRevert(SimpleEscrow.DeadlineNotReached.selector);
        escrow.sweep(USDC, treasury);
    }

    function test_Sweep_revertsAtExactDeadline() public {
        // `sweep` reverts on `block.timestamp <= deadline`, so the equality
        // boundary is closed: claim is still active, sweep is still blocked.
        // This complements `test_Claim_succeedsAtExactDeadline` to pin the
        // exact "claim wins ties" semantic of the deadline state machine.
        deal(USDC, address(escrow), 1_000e6);
        vm.warp(deadline);
        vm.prank(admin);
        vm.expectRevert(SimpleEscrow.DeadlineNotReached.selector);
        escrow.sweep(USDC, treasury);
    }

    function test_Sweep_transfersFullBalanceAfterDeadline() public {
        deal(USDC, address(escrow), 1_000e6);
        vm.warp(deadline + 1);

        vm.prank(admin);
        escrow.sweep(USDC, treasury);

        assertEq(IERC20(USDC).balanceOf(address(escrow)), 0);
        assertEq(IERC20(USDC).balanceOf(treasury), 1_000e6);
    }

    function test_Sweep_emitsSwept() public {
        deal(USDC, address(escrow), 1_000e6);
        vm.warp(deadline + 1);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit Swept(USDC, treasury, 1_000e6);

        vm.prank(admin);
        escrow.sweep(USDC, treasury);
    }

    function test_Sweep_zeroBalanceAfterDeadline_isNoop() public {
        vm.warp(deadline + 1);
        vm.prank(admin);
        escrow.sweep(USDC, treasury); // doesn't revert, just transfers 0
        assertEq(IERC20(USDC).balanceOf(treasury), 0);
    }

    function test_Sweep_revertsForNonOwner() public {
        vm.warp(deadline + 1);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        escrow.sweep(USDC, treasury);
    }

    /* --------------------------------------------------------------------- */
    /* setDeadline                                                            */
    /* --------------------------------------------------------------------- */

    function test_SetDeadline_extendBeforeExpiry() public {
        uint256 newDeadline = deadline + 30 days;
        vm.prank(admin);
        escrow.setDeadline(newDeadline);
        assertEq(escrow.deadline(), newDeadline);
    }

    function test_SetDeadline_revertsIfNotInFuture() public {
        vm.prank(admin);
        vm.expectRevert(SimpleEscrow.DeadlineInPast.selector);
        escrow.setDeadline(block.timestamp);
    }

    function test_SetDeadline_revertsIfCurrentDeadlineAlreadyPassed() public {
        vm.warp(deadline + 1);
        vm.prank(admin);
        vm.expectRevert(SimpleEscrow.DeadlinePassed.selector);
        escrow.setDeadline(block.timestamp + 30 days);
    }

    function test_SetDeadline_revertsForNonOwner() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        escrow.setDeadline(deadline + 1 days);
    }

    function test_SetDeadline_emitsDeadlineSet() public {
        uint256 newDeadline = deadline + 30 days;
        vm.expectEmit(true, true, true, true, address(escrow));
        emit DeadlineSet(newDeadline);
        vm.prank(admin);
        escrow.setDeadline(newDeadline);
    }

    /* --------------------------------------------------------------------- */
    /* Events                                                                 */
    /* --------------------------------------------------------------------- */

    event Claimed(address indexed user, address indexed token, uint256 amount);
    event Swept(address indexed token, address indexed to, uint256 amount);
    event DeadlineSet(uint256 deadline);
}
