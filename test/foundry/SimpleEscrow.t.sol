// SPDX-License-Identifier: UNLICENSED

pragma solidity ^0.8.20;

import {IERC20} from "lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "lib/openzeppelin-contracts/contracts/access/Ownable.sol";

import {SimpleEscrow} from "../../contracts/TrustedLiquidator/SimpleEscrow.sol";
import {WindDownTestBase, IJoetroller, IJTokenAdmin} from "./WindDownTestBase.sol";

contract SimpleEscrowTest is WindDownTestBase {
    address public constant MIM = 0x130966628846BFd36ff31a822705796e8cb8C18D;
    address public constant JMIM = 0xcE095A9657A02025081E0607c8D8b081c76A75ea;

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

    function test_Constructor_skipsDelistedMarket() public view {
        // jMIM was already removed from `getAllMarkets()` at the fork block,
        // so MIM must not be mapped — claims for it take the no-burn branch.
        assertEq(escrow.jTokens(MIM), address(0));
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

    function test_Set_acceptsDelistedToken() public {
        // Underlying for a market that's no longer listed must still be
        // recordable — otherwise users of already-wound-down markets like
        // jMIM couldn't be paid out through this escrow.
        vm.prank(admin);
        escrow.set(_singletonPositions(alice, MIM, 100e18));
        assertEq(escrow.claimable(alice, MIM), 100e18);
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
        emit Claimed(alice, USDC, alice, alice, amount);

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

    function test_Claim_succeedsForDelistedToken_skipsBurn() public {
        // MIM has no entry in `jTokens` (jMIM was delisted before the fork
        // block), so `claim` must take the no-burn branch: transfer the
        // underlying without touching any jToken. We assert against a real
        // ERC20 to catch any accidental call to address(0).
        uint256 amount = 100e18;
        _seedAndSetClaim(alice, MIM, amount);

        // Sanity: claim on a non-existent jMIM would revert with "no contract
        // at address". jMIM does still exist on-chain at the fork block, but
        // the wind-down delegate isn't installed there, so a successful claim
        // proves the escrow never tried to burn on it.
        uint256 jmimBefore = IERC20(JMIM).balanceOf(alice);

        vm.prank(alice);
        escrow.claim(MIM);

        assertEq(escrow.claimable(alice, MIM), 0, "claimable not zeroed");
        assertEq(IERC20(MIM).balanceOf(alice), amount, "MIM not credited");
        assertEq(IERC20(JMIM).balanceOf(alice), jmimBefore, "jMIM should be untouched");
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
    /* claimFor                                                               */
    /* --------------------------------------------------------------------- */

    function test_ClaimFor_creditsRecipient() public {
        // Owner-initiated claim with recipient == user: underlying must
        // land in the user's wallet, not the admin's. This is the whole
        // point of `claimFor` — operator can drain claimables without ever
        // holding the funds.
        uint256 amount = 250e6;
        _seedAndSetClaim(alice, USDC, amount);

        uint256 adminBefore = IERC20(USDC).balanceOf(admin);
        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);

        vm.prank(admin);
        escrow.claimFor(alice, alice, USDC);

        assertEq(escrow.claimable(alice, USDC), 0, "claimable not zeroed");
        assertEq(IERC20(USDC).balanceOf(alice), aliceBefore + amount, "alice not credited");
        assertEq(IERC20(USDC).balanceOf(admin), adminBefore, "admin should not receive funds");
        assertEq(IJTokenAdmin(JUSDC).balanceOf(alice), 0, "jUSDC not burned");
    }

    function test_ClaimFor_redirectsToDifferentRecipient() public {
        // Bricked-contract scenario: the user's address can't move ERC20s
        // (e.g. an old multisig with no admin). The operator redirects the
        // payout to a working address (treasury) but still consumes the
        // user's claim and burns their jToken — the position is closed for
        // the user, the funds just land elsewhere.
        uint256 amount = 250e6;
        _seedAndSetClaim(alice, USDC, amount);

        uint256 aliceBefore = IERC20(USDC).balanceOf(alice);
        uint256 treasuryBefore = IERC20(USDC).balanceOf(treasury);
        assertGt(IJTokenAdmin(JUSDC).balanceOf(alice), 0, "precondition: alice has jUSDC");

        vm.prank(admin);
        escrow.claimFor(alice, treasury, USDC);

        assertEq(escrow.claimable(alice, USDC), 0, "alice's claim not consumed");
        assertEq(IERC20(USDC).balanceOf(alice), aliceBefore, "alice should not be paid");
        assertEq(IERC20(USDC).balanceOf(treasury), treasuryBefore + amount, "treasury not credited");
        assertEq(IJTokenAdmin(JUSDC).balanceOf(alice), 0, "alice's jUSDC must still burn");
    }

    function test_ClaimFor_emitsClaimedWithAdminAsCaller() public {
        // Caller in the event is the *executor* (admin), not the recipient.
        // Off-chain indexers rely on this distinction to tell self-claim
        // (caller == user) from operator-initiated claim (caller == admin).
        uint256 amount = 250e6;
        _seedAndSetClaim(alice, USDC, amount);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit Claimed(admin, USDC, alice, alice, amount);

        vm.prank(admin);
        escrow.claimFor(alice, alice, USDC);
    }

    function test_ClaimFor_emitsClaimedWithRedirectedRecipient() public {
        // When recipient differs from user, the event must record both so
        // indexers can attribute who lost the claim vs. who got the funds.
        uint256 amount = 250e6;
        _seedAndSetClaim(alice, USDC, amount);

        vm.expectEmit(true, true, true, true, address(escrow));
        emit Claimed(admin, USDC, alice, treasury, amount);

        vm.prank(admin);
        escrow.claimFor(alice, treasury, USDC);
    }

    function test_ClaimFor_revertsForNonOwner() public {
        _seedAndSetClaim(alice, USDC, 250e6);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, bob));
        escrow.claimFor(alice, alice, USDC);
    }

    function test_ClaimFor_revertsAfterDeadline() public {
        _seedAndSetClaim(alice, USDC, 250e6);
        vm.warp(deadline + 1);
        vm.prank(admin);
        vm.expectRevert(SimpleEscrow.DeadlinePassed.selector);
        escrow.claimFor(alice, alice, USDC);
    }

    function test_ClaimFor_revertsIfNothingToClaim() public {
        vm.prank(admin);
        vm.expectRevert(SimpleEscrow.NothingToClaim.selector);
        escrow.claimFor(alice, alice, USDC);
    }

    function test_ClaimFor_succeedsForDelistedToken() public {
        // Same skip-burn semantics as `claim`: an admin-driven payout for a
        // delisted-market underlying must succeed without touching the
        // (possibly stale) jToken.
        uint256 amount = 100e18;
        _seedAndSetClaim(alice, MIM, amount);

        vm.prank(admin);
        escrow.claimFor(alice, alice, MIM);

        assertEq(escrow.claimable(alice, MIM), 0);
        assertEq(IERC20(MIM).balanceOf(alice), amount);
    }

    function test_ClaimFor_redirectsDelistedTokenToRecipient() public {
        // The redirect path also has to work when the underlying has no
        // jToken in the map (e.g. MIM): no burn, recipient gets the funds.
        uint256 amount = 100e18;
        _seedAndSetClaim(alice, MIM, amount);

        vm.prank(admin);
        escrow.claimFor(alice, treasury, MIM);

        assertEq(escrow.claimable(alice, MIM), 0);
        assertEq(IERC20(MIM).balanceOf(alice), 0);
        assertEq(IERC20(MIM).balanceOf(treasury), amount);
    }

    function test_ClaimFor_doesNotBlockSelfClaim() public {
        // `claim` and `claimFor` write to the same `claimable` slot; once
        // the admin pays a user out (here: redirected to treasury), the
        // user's own `claim` must hit `NothingToClaim` rather than
        // double-paying — no second payout regardless of recipient.
        _seedAndSetClaim(alice, USDC, 250e6);

        vm.prank(admin);
        escrow.claimFor(alice, treasury, USDC);

        vm.prank(alice);
        vm.expectRevert(SimpleEscrow.NothingToClaim.selector);
        escrow.claim(USDC);
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

    event Claimed(
        address indexed caller,
        address indexed token,
        address indexed user,
        address recipient,
        uint256 amount
    );
    event Swept(address indexed token, address indexed to, uint256 amount);
    event DeadlineSet(uint256 deadline);
}
