// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Vm} from "forge-std/Vm.sol";
import {PerpBase} from "./PerpBase.t.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {PerpFactory} from "../src/PerpFactory.sol";
import {IPerpFactory} from "../src/interfaces/IPerpFactory.sol";
import {PerpSeries} from "../src/PerpSeries.sol";
import {PerpToken} from "../src/PerpToken.sol";
import {FixingsRecorder} from "../src/FixingsRecorder.sol";
import {L2Sequencer} from "../src/L2Sequencer.sol";
import {IFixingsRecorder} from "../src/interfaces/IFixingsRecorder.sol";
import {IAggregatorV3} from "../src/interfaces/IAggregatorV3.sol";
import {IPerpSeries, PerpState, PerpTerms, PerpPhase} from "../src/interfaces/IPerpSeries.sol";
import {ISeriesToken} from "../src/interfaces/ISeriesToken.sol";

/// 6-decimal collateral that re-enters the series from inside transferFrom.
contract ReentrantPerpUSDC is ERC20 {
    PerpSeries public target;

    constructor() ERC20("Reentrant", "RE") {}

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function setTarget(PerpSeries t) external {
        target = t;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function transferFrom(address from, address to, uint256 value) public override returns (bool) {
        if (address(target) != address(0)) target.claim(from); // must hit the guard
        return super.transferFrom(from, to, value);
    }
}

/// An uptime feed that answers, or reverts, with as much (zeroed) data as 90% of its gas pays
/// for in memory: a caller that copies all of it runs out of gas at any gas limit.
contract HugeDataFeed {
    bool internal immutable REVERTS; // in the code, so vm.etch keeps it

    constructor(bool reverts) {
        REVERTS = reverts;
    }

    fallback() external {
        bool reverts = REVERTS;
        assembly {
            let budget := div(mul(gas(), 9), 10)
            let words := 32
            for {} 1 {} {
                let more := add(words, div(words, 8))
                if gt(add(mul(more, 3), div(mul(more, more), 512)), budget) { break }
                words := more
            }
            if reverts { revert(0, mul(words, 32)) }
            return(0, mul(words, 32))
        }
    }
}

/// The series on the launch terms (an ETH series: daily, k 40%, R = 0), and at the end
/// the coupon path on a weekly series with R = 23.5%.
contract PerpSeriesTest is PerpBase {
    PerpSeries s;
    PerpToken noteT; // read once: a getter call inside vm.prank would use up the prank
    PerpToken coverT;
    uint40 first;

    // one fixing melts m of a token's notional; clean, NOTE gets all of the pair's release
    uint256 constant M1 = RAY * uint256(MELT) / WAD;
    uint256 constant S1 = RAY - M1;
    // the same on the weekly series
    uint256 constant M1_WEEKLY = RAY * uint256(MELT_WEEKLY) / WAD;

    function setUp() public override {
        super.setUp();
        first = T0 + 1 hours;
        s = _create(_terms(first));
        noteT = _note(s);
        coverT = _cover(s);
    }

    // --- phases and pending fixings -----------------------------------------------

    function test_pending_until_first_fixing_recorded() public {
        PerpState memory st = s.state();
        assertEq(uint8(st.phase), uint8(PerpPhase.Pending));
        assertEq(st.nextFixing, first);
        assertEq(st.notionalPerToken, 0);
        (bool pending, uint40 t) = s.pendingFixing();
        assertFalse(pending);
        assertEq(t, first);

        vm.warp(first + 1);
        (pending, t) = s.pendingFixing();
        assertTrue(pending);
        assertEq(t, first);

        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(s), type(uint256).max);
        vm.expectRevert(IPerpSeries.NotStruck.selector);
        s.mint(1e6, alice);
        vm.expectRevert(IPerpSeries.NotStruck.selector);
        s.redeemPair(1e6, alice);
        vm.stopPrank();
    }

    function test_first_fixing_never_falls_back() public {
        vm.warp(first + 60 days);
        assertEq(uint8(s.state().phase), uint8(PerpPhase.Pending));
        (bool pending,) = s.pendingFixing();
        assertTrue(pending);
        assertEq(uint8(s.advance().phase), uint8(PerpPhase.Pending));
    }

    function test_first_fixing_then_live() public {
        _fix(s, 0, 10000);
        // state() includes the recorded but unprocessed first fixing
        PerpState memory st = s.state();
        assertEq(uint8(st.phase), uint8(PerpPhase.Live));
        assertEq(st.referenceFixing, INITIAL);
        assertEq(st.lastFixing, INITIAL);
        assertEq(st.nextFixing, first + DAY);
        assertEq(st.notionalPerToken, RAY);
        assertEq(st.fixingsDone, 0);

        vm.expectEmit(address(s));
        emit IPerpSeries.Struck(INITIAL);
        s.advance();
        (bool pending, uint40 t) = s.pendingFixing();
        assertFalse(pending);
        assertEq(t, first + DAY);
    }

    function test_fixing_pending_is_reported_from_one_second_after() public {
        _fix(s, 0, 10000);
        vm.warp(first + DAY); // exactly at fixing 1: not passed yet
        (bool pending,) = s.pendingFixing();
        assertFalse(pending);
        vm.warp(first + DAY + 1);
        (pending,) = s.pendingFixing();
        assertTrue(pending);
    }

    // --- the fixing rule ----------------------------------------------------------

    function test_clean_fixing_releases_everything_to_note() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 9000);

        vm.expectEmit(address(s));
        emit IPerpSeries.FixingProcessed(
            1, first + DAY, uint96(uint256(_price(9000))), INITIAL, false, false, S1, M1, 0
        );
        PerpState memory st = s.advance();
        assertEq(st.notionalPerToken, S1);
        assertEq(st.noteIndex, M1); // R = 0: the pair releases its melted notional, all to NOTE
        assertEq(st.coverIndex, 0);
        assertEq(st.referenceFixing, INITIAL); // below the reference: it stays
        assertFalse(st.knockedIn);
        // 100 NOTE: a = 0.2736% of 100 USDC
        assertEq(s.claimable(alice), 100e6 * M1 / RAY);
        assertEq(s.claimable(alice), 273_597);
    }

    function test_ratchet_moves_the_reference_and_redeems_nothing() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 12000);
        PerpState memory st = s.advance();
        assertEq(st.referenceFixing, uint96(uint256(_price(12000))));
        assertEq(st.noteIndex, M1); // the same release as any clean fixing
        assertEq(noteT.totalSupply(), 100e6);
        // the crash line follows: 40% of the new reference is 48
        _fix(s, 2, 4900);
        assertFalse(s.advance().knockedIn);
        _fix(s, 3, 4700);
        assertTrue(s.advance().knockedIn);
    }

    function test_knocked_in_fixing_splits_the_release() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 3000); // below 40%: knocked in at this fixing, which already pays x = 0.3
        PerpState memory st = s.advance();
        assertTrue(st.knockedIn);
        uint256 noteRelease = M1 * uint256(_price(3000)) / uint256(INITIAL);
        assertEq(st.noteIndex, noteRelease);
        assertEq(st.coverIndex, M1 - noteRelease);
        // NOTE: a * 0.3, COVER: a * 0.7, of 100 USDC
        assertEq(100e6 * st.noteIndex / RAY, 82_079);
        assertEq(100e6 * st.coverIndex / RAY, 191_518);

        // stays knocked in above the crash line, pays x
        _fix(s, 2, 9000);
        st = s.advance();
        assertTrue(st.knockedIn);
        // heals at the reference: clean again, the reference stays
        _fix(s, 3, 10000);
        st = s.advance();
        assertFalse(st.knockedIn);
        assertEq(st.referenceFixing, INITIAL);
    }

    function test_fixing_at_the_crash_line_does_not_knock_in() public {
        _fix(s, 0, 10000);
        _fix(s, 1, 4000);
        assertFalse(s.advance().knockedIn);
        _fixAt(s, _fixingTime(s, 2), _price(4000) - 1);
        assertTrue(s.advance().knockedIn);
    }

    // --- mint / redeemPair --------------------------------------------------------

    function test_mint_and_redeemPair_at_the_pair_value() public {
        _fix(s, 0, 10000);
        assertEq(s.pairValuePerNotional(), 1e6); // no coupon reserve: a pair is worth 1
        assertEq(s.previewMint(1e6), 1e6);
        assertEq(s.previewMint(3), 3);
        assertEq(s.previewRedeemPair(3), 3);
        assertEq(s.notionalOf(1e6), 1e6);

        uint256 inAmt = _mintPairs(s, alice, 3);
        assertEq(inAmt, 3);
        assertEq(noteT.balanceOf(alice), 3);
        assertEq(coverT.balanceOf(alice), 3);

        vm.prank(alice);
        uint256 outAmt = s.redeemPair(3, bob);
        assertEq(outAmt, 3);
        assertEq(usdc.balanceOf(bob), 3);
        assertEq(noteT.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(s)), 0);
    }

    function test_mint_after_fixings_costs_the_melted_pair_value() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 9000);
        s.advance();
        // a token now stands for (1 - a) of a USDC of notional
        assertEq(s.notionalOf(1e6), 997_264);
        assertEq(s.previewMint(100e6), 99_726_403); // 100 * 0.99726402, rounded up
        uint256 inAmt = _mintPairs(s, bob, 100e6);
        assertEq(inAmt, 99_726_403);
        // the new tokens earned nothing from fixing 1
        assertEq(s.claimable(bob), 0);
        assertEq(s.claimable(alice), 273_597);
        // a pair bought and redeemed returns its cost, rounded down
        vm.prank(bob);
        assertEq(s.redeemPair(100e6, bob), 99_726_402);
    }

    function test_zero_amounts_revert() public {
        _fix(s, 0, 10000);
        vm.expectRevert(IPerpSeries.ZeroAmount.selector);
        s.mint(0, alice);
        vm.expectRevert(IPerpSeries.ZeroAmount.selector);
        s.redeemPair(0, alice);
    }

    function test_redeemPair_needs_both_legs() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 10e6);
        vm.startPrank(alice);
        noteT.transfer(bob, 4e6);
        vm.expectRevert(); // ERC20InsufficientBalance on NOTE
        s.redeemPair(7e6, alice);
        assertEq(s.redeemPair(6e6, alice), 6_000_000);
        vm.stopPrank();
    }

    // --- holders: the index is checkpointed on every balance change ----------------

    function test_transfer_settles_both_holders() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 9000);
        s.advance();
        uint256 rel1 = s.state().noteIndex;

        vm.prank(alice);
        noteT.transfer(bob, 40e6);
        assertEq(s.claimable(alice), 100e6 * rel1 / RAY);
        assertEq(s.claimable(bob), 0);

        _fix(s, 2, 9500);
        s.advance();
        uint256 rel2 = s.state().noteIndex - rel1;
        assertEq(s.claimable(alice), 100e6 * rel1 / RAY + 60e6 * rel2 / RAY);
        assertEq(s.claimable(bob), 40e6 * rel2 / RAY);

        vm.prank(bob);
        assertEq(s.claim(bob), 40e6 * rel2 / RAY);
        assertEq(s.claimable(bob), 0);
        assertEq(usdc.balanceOf(bob), 40e6 * rel2 / RAY);
    }

    function test_transfer_processes_a_recorded_fixing_first() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 9000); // recorded, not advanced
        vm.expectEmit(true, false, false, false, address(s));
        emit IPerpSeries.FixingProcessed(1, 0, 0, 0, false, false, 0, 0, 0);
        vm.prank(alice);
        noteT.transfer(bob, 100e6);
        // the release of fixing 1 belongs to the holder at the fixing
        assertEq(s.claimable(alice), 273_597);
        assertEq(s.claimable(bob), 0);
        assertEq(s.state().fixingsDone, 1);
    }

    function test_cover_leg_is_settled_separately() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        vm.prank(alice);
        coverT.transfer(bob, 100e6); // bob is the hedger, alice keeps NOTE
        _fix(s, 1, 3000);
        PerpState memory st = s.advance();
        assertEq(s.claimable(alice), 82_079);
        assertEq(s.claimable(bob), 191_518);
        // transferFrom goes through the same hook
        uint256 w1 = st.coverIndex;
        vm.prank(bob);
        coverT.approve(address(this), 50e6);
        coverT.transferFrom(bob, alice, 50e6);
        _fix(s, 2, 3000);
        st = s.advance();
        uint256 w2 = st.coverIndex - w1;
        assertEq(s.claimable(bob), 191_518 + 50e6 * w2 / RAY);
        // alice's NOTE was not touched since the mint: one rounding over both fixings
        assertEq(s.claimable(alice), 100e6 * st.noteIndex / RAY + 50e6 * w2 / RAY);
    }

    function test_self_transfer_and_zero_transfer_change_nothing() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 9000);
        vm.startPrank(alice);
        noteT.transfer(alice, 100e6);
        noteT.transfer(bob, 0);
        vm.stopPrank();
        assertEq(s.claimable(alice), 273_597);
        assertEq(s.claimable(bob), 0);
    }

    function test_mint_to_a_holder_settles_it_first() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 9000);
        // bob mints more to alice after the fixing: her old tokens' release is kept, the new ones get none
        uint256 need = s.previewMint(50e6);
        usdc.mint(bob, need);
        vm.startPrank(bob);
        usdc.approve(address(s), need);
        s.mint(50e6, alice);
        vm.stopPrank();
        assertEq(s.claimable(alice), 273_597);
    }

    function test_claim_pays_any_address_and_survives_a_frozen_holder() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 9000);
        usdc.setFrozen(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Frozen.selector, alice));
        s.claim(alice);
        vm.expectEmit(address(s));
        emit IPerpSeries.Claimed(alice, bob, 273_597);
        vm.prank(alice);
        assertEq(s.claim(bob), 273_597);
        assertEq(usdc.balanceOf(bob), 273_597);
        // nothing left: a second claim pays 0
        vm.prank(alice);
        assertEq(s.claim(bob), 0);
    }

    function test_checkpoint_is_only_for_the_tokens() public {
        _fix(s, 0, 10000);
        vm.expectRevert(IPerpSeries.OnlyToken.selector);
        s.checkpoint(alice, 1e6, bob, 0);
    }

    function test_tokens_mint_and_burn_only_through_the_series() public {
        PerpToken n = _note(s);
        vm.expectRevert(ISeriesToken.OnlySeries.selector);
        n.mint(alice, 1);
        vm.expectRevert(ISeriesToken.OnlySeries.selector);
        n.burn(alice, 1);
        assertEq(n.decimals(), 6);
        assertTrue(n.isNote());
        assertFalse(coverT.isNote());
        assertEq(n.series(), address(s));
    }

    // --- missed fixings and the end -------------------------------------------------

    /// A missed fixing falls back exactly FALLBACK_GRACE (6 hours) after its time, not a second
    /// earlier, and under the normal rule at the last fixing; each fixing waits for its own deadline.
    function test_missed_fixing_reuses_the_last_one_after_the_deadline() public {
        assertEq(s.FALLBACK_GRACE(), 6 hours);
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 3000); // knocked in at 30
        s.advance();
        uint40 t2 = _fixingTime(s, 2);
        uint256 deadline = uint256(t2) + 6 hours;
        vm.warp(deadline - 1);
        (bool pending, uint40 t) = s.pendingFixing();
        assertTrue(pending);
        assertEq(t, t2);
        assertEq(s.state().fixingsDone, 1);
        assertEq(s.advance().fixingsDone, 1); // nothing to process yet

        vm.warp(deadline);
        PerpState memory st = s.state();
        assertEq(st.fixingsDone, 2);
        assertEq(st.missedInARow, 1);
        assertEq(st.lastFixing, uint96(uint256(_price(3000))));
        assertTrue(st.knockedIn);
        assertEq(st.nextFixing, _fixingTime(s, 3));
        (pending,) = s.pendingFixing();
        assertFalse(pending); // fixing 3 is 18 hours away
        // knocked in at 30: the melted notional pays NOTE 0.3 and COVER 0.7
        uint256 m2 = S1 * uint256(MELT) / WAD;
        uint256 note2 = m2 * uint256(_price(3000)) / INITIAL;
        vm.expectEmit(address(s));
        emit IPerpSeries.FixingProcessed(
            2, t2, uint96(uint256(_price(3000))), INITIAL, true, true, S1 - m2, note2, m2 - note2
        );
        s.advance();
        // fixing 3 waits for its own deadline, 6 hours after its time
        vm.warp(uint256(_fixingTime(s, 3)) + FALLBACK - 1);
        assertEq(s.state().fixingsDone, 2);
        (pending,) = s.pendingFixing();
        assertTrue(pending);
        vm.warp(uint256(_fixingTime(s, 3)) + FALLBACK);
        assertEq(s.state().fixingsDone, 3);
        assertEq(s.state().missedInARow, 2);
    }

    /// At weekly fixings the fallback comes as soon: 6 hours after the fixing's time, not a week.
    function test_weekly_missed_fixing_falls_back_six_hours_after_its_time() public {
        PerpSeries w = _weekly();
        _fix(w, 0, 10000);
        _fix(w, 1, 5000); // knocked in
        uint40 t2 = _fixingTime(w, 2);
        vm.warp(uint256(t2) + FALLBACK - 1);
        (bool pending,) = w.pendingFixing();
        assertTrue(pending);
        assertEq(w.advance().fixingsDone, 1);
        vm.warp(uint256(t2) + FALLBACK);
        PerpState memory st = w.advance();
        assertEq(st.fixingsDone, 2);
        assertEq(st.missedInARow, 1);
        assertEq(st.lastFixing, uint96(uint256(_price(5000))));
        assertTrue(st.knockedIn);
        assertEq(st.nextFixing, _fixingTime(w, 3));
        (pending,) = w.pendingFixing();
        assertFalse(pending);
        // a recorded fixing resets the count
        _fix(w, 3, 9000);
        st = w.advance();
        assertEq(st.fixingsDone, 3);
        assertEq(st.missedInARow, 0);
    }

    function test_no_fixing_is_recorded_while_the_sequencer_is_down_or_just_back() public {
        _fix(s, 0, 10000);
        FixingsRecorder r = _recorder(s);
        uint40 t1 = _fixingTime(s, 1);
        feed.pushRoundAt(_price(9000), t1 - 10 minutes); // the last round before the fixing time
        uint80 round = uint80(feed.latestRound());
        vm.warp(uint256(t1) + 5 minutes);
        sequencer.pushRound(1); // down: no round can land, the round above may not be the last one
        vm.expectRevert(L2Sequencer.SequencerDown.selector);
        r.recordFixing(t1, round);
        vm.warp(block.timestamp + 20 minutes);
        sequencer.pushRound(0); // back up; queued rounds may still be on their way
        vm.expectRevert(abi.encodeWithSelector(L2Sequencer.SequencerGracePeriod.selector, block.timestamp + GRACE));
        r.recordFixing(t1, round);
        vm.warp(block.timestamp + GRACE);
        r.recordFixing(t1, round);
        assertEq(s.state().lastFixing, uint96(uint256(_price(9000))));
    }

    /// Chainlink's OCR aggregators answer zeros for a round they don't have: the latest round is
    /// still recordable (found on an Arbitrum One fork), a missing one is not.
    function test_a_feed_that_answers_zeros_for_unknown_rounds() public {
        feed.setZerosForUnknownRounds(true);
        _fix(s, 0, 10000); // the latest round, its next answers zeros
        assertEq(uint8(s.state().phase), uint8(PerpPhase.Live));
        FixingsRecorder r = _recorder(s);
        uint40 t1 = _fixingTime(s, 1);
        feed.pushRoundAt(_price(9000), t1 - 10 minutes);
        uint80 before = uint80(feed.latestRound());
        feed.pushRoundAt(_price(9100), t1 - 5 minutes);
        vm.warp(uint256(t1) + 1);
        // not the last round before the fixing time: its next round exists and is earlier
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.NotLastRoundBefore.selector, before, t1));
        r.recordFixing(t1, before);
        // a round that doesn't exist reads as a zero price
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.BadPrice.selector, int256(0)));
        r.recordFixing(t1, before + 5);
        r.recordFixing(t1, before + 1);
        assertEq(s.state().lastFixing, uint96(uint256(_price(9100))));
    }

    function test_the_launch_limits_hold_for_a_24_7_feed() public {
        _fix(s, 0, 10000);
        FixingsRecorder r = _recorder(s);
        uint40 t1 = _fixingTime(s, 1);
        // a fixing's round is at most MAX_FIX_AGE old
        feed.pushRoundAt(_price(9000), t1 - MAX_FIX_AGE - 1);
        uint80 old = uint80(feed.latestRound());
        vm.warp(uint256(t1) + 1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.FixingTooStale.selector, t1 - MAX_FIX_AGE - 1, t1));
        r.recordFixing(t1, old);
        // and never after the fixing time, however soon: nothing records fixing 1
        feed.pushRoundAt(_price(8000), t1 + 1);
        uint80 late = uint80(feed.latestRound());
        vm.warp(uint256(t1) + 2);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, late, t1));
        r.recordFixing(t1, late);
        // so the series falls back to the last fixing, 6 hours after the fixing time
        vm.warp(uint256(t1) + FALLBACK);
        PerpState memory st = s.advance();
        assertEq(st.fixingsDone, 1);
        assertEq(st.missedInARow, 1);
        assertEq(st.lastFixing, INITIAL);
        // BTC-sized prices are fine up to the $10M cap; above it is a mis-scaled answer
        uint40 t2 = _fixingTime(s, 2);
        _fixAt(s, t2, PRICE_MAX);
        assertEq(s.advance().referenceFixing, uint96(uint256(PRICE_MAX)));
        uint40 t3 = _fixingTime(s, 3);
        feed.pushRoundAt(PRICE_MAX + 1, t3);
        uint80 huge = uint80(feed.latestRound());
        vm.warp(uint256(t3) + 1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.BadPrice.selector, PRICE_MAX + 1));
        r.recordFixing(t3, huge);
    }

    /// A BTC series (k 50%) with BTC-sized prices.
    function test_btc_prices_record_and_pay() public {
        PerpTerms memory t = _btcTerms(address(feed), T0 + 1 days);
        PerpSeries b = _create(t);
        _fixAt(b, t.firstFixing, 81_439_17_000_000); // $81,439.17
        _mintPairs(b, alice, 100e6);
        _fixAt(b, _fixingTime(b, 1), 40_000_00_000_000); // -51%: knocked in at x = 0.4911
        PerpState memory st = b.advance();
        assertTrue(st.knockedIn);
        assertEq(st.referenceFixing, 81_439_17_000_000);
        _fixAt(b, _fixingTime(b, 2), 60_000_00_000_000); // above the crash line: knocked in it stays
        st = b.advance();
        assertTrue(st.knockedIn);
        _fixAt(b, _fixingTime(b, 3), 150_000_00_000_000); // a new high: the reference resets
        st = b.advance();
        assertFalse(st.knockedIn);
        assertEq(st.referenceFixing, 150_000_00_000_000);
        assertGt(b.claimable(alice), 0);
        // a clean BTC note at its crash line is not knocked in, one unit below it is
        _fixAt(b, _fixingTime(b, 4), 75_000_00_000_000);
        assertFalse(b.advance().knockedIn);
        _fixAt(b, _fixingTime(b, 5), 75_000_00_000_000 - 1);
        assertTrue(b.advance().knockedIn);
    }

    /// Recorded after its deadline, but before the series processed the fallback: the recorded
    /// fixing wins.
    function test_recorded_fixing_wins_over_the_fallback() public {
        _fix(s, 0, 10000);
        uint40 t1 = _fixingTime(s, 1);
        feed.pushRoundAt(_price(3000), t1);
        uint80 round = uint80(feed.latestRound());
        vm.warp(uint256(t1) + FALLBACK + 1 hours); // past the deadline, nobody advanced
        assertFalse(s.state().knockedIn); // the fallback would reuse 100
        assertEq(s.state().missedInARow, 1);
        _recorder(s).recordFixing(t1, round);
        PerpState memory st = s.state();
        assertTrue(st.knockedIn);
        assertEq(st.missedInARow, 0);
        assertEq(st.lastFixing, uint96(uint256(_price(3000))));
        vm.expectEmit(true, false, false, false, address(s));
        emit IPerpSeries.FixingProcessed(1, 0, 0, 0, false, false, 0, 0, 0);
        assertEq(keccak256(abi.encode(s.advance())), keccak256(abi.encode(st)));
    }

    /// Recorded in the last second of the grace: once the deadline passes, the series processes
    /// the recorded fixing, not the fallback.
    function test_a_fixing_recorded_within_the_grace_wins() public {
        _fix(s, 0, 10000);
        uint40 t1 = _fixingTime(s, 1);
        feed.pushRoundAt(_price(3000), t1 - 10 minutes);
        uint80 round = uint80(feed.latestRound());
        vm.warp(uint256(t1) + FALLBACK - 1);
        (bool pending,) = s.pendingFixing();
        assertTrue(pending);
        _recorder(s).recordFixing(t1, round);
        (pending,) = s.pendingFixing();
        assertFalse(pending);
        vm.warp(uint256(t1) + FALLBACK);
        PerpState memory st = s.advance();
        assertEq(st.fixingsDone, 1);
        assertEq(st.missedInARow, 0);
        assertTrue(st.knockedIn);
        assertEq(st.lastFixing, uint96(uint256(_price(3000))));
    }

    /// Once the series has processed the fallback, a late recording changes nothing.
    function test_a_fixing_recorded_after_the_fallback_is_processed_changes_nothing() public {
        _fix(s, 0, 10000);
        uint40 t1 = _fixingTime(s, 1);
        feed.pushRoundAt(_price(3000), t1);
        uint80 round = uint80(feed.latestRound());
        vm.warp(uint256(t1) + FALLBACK);
        PerpState memory st = s.advance(); // the fallback is stored
        assertEq(st.missedInARow, 1);
        assertFalse(st.knockedIn);
        _recorder(s).recordFixing(t1, round); // the recorder still takes it
        assertTrue(_recorder(s).isRecorded(t1));
        assertEq(keccak256(abi.encode(s.state())), keccak256(abi.encode(st)));
        assertEq(keccak256(abi.encode(s.advance())), keccak256(abi.encode(st)));
    }

    // --- a dead feed closes the series: missed fixings in a row spanning CLOSE_AFTER_DEAD (14 days) ---

    /// Daily: the feed dies after fixing 1 (knocked in at 30), so fixings 2.. are never recorded. The
    /// 13th missed fixing in a row leaves the series live; the 14th (fixing 15, 14 days after the last
    /// good fixing, processed at its fallback deadline) releases everything at 30 and closes it.
    function test_daily_dead_feed_closes_at_the_14th_missed_fixing() public {
        assertEq(s.CLOSE_AFTER_DEAD(), 14 days);
        _fix(s, 0, 10000);
        uint256 locked = _mintPairs(s, alice, 100e6);
        vm.prank(alice);
        coverT.transfer(bob, 100e6); // alice holds NOTE, bob COVER
        _fix(s, 1, 3000);
        s.advance();
        uint96 last = uint96(uint256(_price(3000)));

        uint40 tClose = _fixingTime(s, 15);
        assertEq(tClose - _fixingTime(s, 1), DEAD);
        // one second before its deadline: fixings 2..14 missed, still live
        vm.warp(uint256(tClose) + FALLBACK - 1);
        vm.recordLogs();
        PerpState memory st = s.advance();
        assertEq(_fixingsWithoutClose(address(s)), 13);
        assertEq(uint8(st.phase), uint8(PerpPhase.Live));
        assertEq(st.missedInARow, 13);
        assertEq(st.fixingsDone, 14);
        assertEq(st.nextFixing, tClose);
        assertGt(st.notionalPerToken, 0);
        (bool pending, uint40 t) = s.pendingFixing();
        assertTrue(pending);
        assertEq(t, tClose);

        // the 14th missed fixing: m = s, everything released at the last good fixing, x = 0.3
        vm.warp(uint256(tClose) + FALLBACK);
        uint256 m = st.notionalPerToken;
        uint256 noteRelease = m * uint256(last) / INITIAL;
        vm.expectEmit(address(s));
        emit IPerpSeries.FixingProcessed(15, tClose, last, INITIAL, true, true, 0, noteRelease, m - noteRelease);
        vm.expectEmit(address(s));
        emit IPerpSeries.Closed(15, last);
        PerpState memory closed = s.advance();
        assertEq(uint8(closed.phase), uint8(PerpPhase.Closed));
        assertEq(closed.missedInARow, 14);
        assertEq(closed.fixingsDone, 15);
        assertEq(closed.notionalPerToken, 0);
        assertEq(closed.nextFixing, 0);
        assertEq(closed.lastFixing, last);
        assertEq(closed.noteIndex, st.noteIndex + noteRelease);
        assertEq(closed.coverIndex, st.coverIndex + m - noteRelease);
        (pending, t) = s.pendingFixing();
        assertFalse(pending);
        assertEq(t, 0);

        // NOTE 0.3 and COVER 0.7 per unit of notional, all of the escrow but rounding
        _closedSeriesPaysOut(s, locked, 30_000_000, 70_000_000);
    }

    /// Weekly: two missed fixings span 14 days, so the 2nd in a row closes (one week after the
    /// 1st missed fixing's deadline), releasing x + R to NOTE and 1 - x to COVER.
    function test_weekly_dead_feed_closes_at_the_2nd_missed_fixing() public {
        PerpSeries w = _weekly();
        _fix(w, 0, 10000);
        uint256 locked = _mintPairs(w, alice, 100e6);
        vm.prank(alice);
        coverT.transfer(bob, 100e6);
        _fix(w, 1, 5000); // below 60%: knocked in, x = 0.5
        w.advance();
        uint96 last = uint96(uint256(_price(5000)));

        uint40 tClose = _fixingTime(w, 3);
        assertEq(tClose - _fixingTime(w, 1), DEAD);
        vm.warp(uint256(tClose) + FALLBACK - 1);
        vm.recordLogs();
        PerpState memory st = w.advance();
        assertEq(_fixingsWithoutClose(address(w)), 1);
        assertEq(uint8(st.phase), uint8(PerpPhase.Live));
        assertEq(st.missedInARow, 1);
        assertEq(st.fixingsDone, 2);

        vm.warp(uint256(tClose) + FALLBACK);
        uint256 m = st.notionalPerToken;
        uint256 total = m * (UNIT + COUPON) / UNIT;
        uint256 noteRelease = m * (uint256(last) * UNIT + uint256(COUPON) * INITIAL) / (uint256(INITIAL) * UNIT);
        vm.expectEmit(address(w));
        emit IPerpSeries.FixingProcessed(3, tClose, last, INITIAL, true, true, 0, noteRelease, total - noteRelease);
        vm.expectEmit(address(w));
        emit IPerpSeries.Closed(3, last);
        PerpState memory closed = w.advance();
        assertEq(uint8(closed.phase), uint8(PerpPhase.Closed));
        assertEq(closed.missedInARow, 2);
        assertEq(closed.fixingsDone, 3);
        assertEq(closed.notionalPerToken, 0);

        // NOTE 0.5 + R, COVER 0.5 per unit of notional
        _closedSeriesPaysOut(w, locked, 73_500_000, 50_000_000);
    }

    /// Hourly: the 336th missed fixing in a row closes (336 hours = 14 days); the 335th doesn't.
    /// Clean at the last good fixing, so NOTE gets everything.
    function test_hourly_dead_feed_closes_at_the_336th_missed_fixing() public {
        PerpTerms memory t = _terms(first);
        t.fixingInterval = 1 hours;
        t.meltShare = 114_148_735_678_798; // 1 - e^(-1/8760): release rate 1/yr at hourly fixings
        PerpSeries h = _create(t);
        noteT = _note(h);
        coverT = _cover(h);
        _fix(h, 0, 10000);
        uint256 locked = _mintPairs(h, alice, 100e6);
        vm.prank(alice);
        coverT.transfer(bob, 100e6);
        _fix(h, 1, 9000);
        h.advance();
        uint96 last = uint96(uint256(_price(9000)));

        uint40 tClose = _fixingTime(h, 337);
        assertEq(tClose - _fixingTime(h, 1), DEAD);
        vm.warp(uint256(tClose) + FALLBACK - 1);
        vm.recordLogs();
        PerpState memory st = h.advance();
        assertEq(_fixingsWithoutClose(address(h)), 335);
        assertEq(uint8(st.phase), uint8(PerpPhase.Live));
        assertEq(st.missedInARow, 335);
        assertEq(st.fixingsDone, 336);

        vm.warp(uint256(tClose) + FALLBACK);
        uint256 m = st.notionalPerToken;
        vm.expectEmit(address(h));
        emit IPerpSeries.FixingProcessed(337, tClose, last, INITIAL, false, true, 0, m, 0);
        vm.expectEmit(address(h));
        emit IPerpSeries.Closed(337, last);
        PerpState memory closed = h.advance();
        assertEq(uint8(closed.phase), uint8(PerpPhase.Closed));
        assertEq(closed.missedInARow, 336);
        assertEq(closed.fixingsDone, 337);
        assertEq(closed.notionalPerToken, 0);
        assertEq(closed.coverIndex, 0);

        _closedSeriesPaysOut(h, locked, 100_000_000, 0);
    }

    /// A recorded fixing resets the count: 13 missed, one recorded, 13 missed again (26 days of
    /// missed fixings in all) leave the series live; the 14th in a row after the recorded one closes.
    function test_a_recorded_fixing_resets_the_dead_feed_count() public {
        _fix(s, 0, 10000);
        vm.warp(uint256(_fixingTime(s, 13)) + FALLBACK);
        assertEq(s.state().missedInARow, 13);
        _fix(s, 14, 9000);
        PerpState memory st = s.advance();
        assertEq(st.missedInARow, 0);
        assertEq(st.fixingsDone, 14);
        assertEq(uint8(st.phase), uint8(PerpPhase.Live));

        vm.warp(uint256(_fixingTime(s, 27)) + FALLBACK);
        st = s.advance();
        assertEq(uint8(st.phase), uint8(PerpPhase.Live));
        assertEq(st.missedInARow, 13);
        assertEq(st.fixingsDone, 27);

        vm.warp(uint256(_fixingTime(s, 28)) + FALLBACK);
        vm.expectEmit(address(s));
        emit IPerpSeries.Closed(28, uint96(uint256(_price(9000))));
        st = s.advance();
        assertEq(uint8(st.phase), uint8(PerpPhase.Closed));
        assertEq(st.missedInARow, 14);
        assertEq(st.fixingsDone, 28);
        assertEq(st.notionalPerToken, 0);
    }

    /// Any interval the factory accepts: the series closes at the first missed fixing n in a row
    /// with n * interval >= 14 days, at that fixing's deadline and not a second earlier.
    function testFuzz_dead_feed_closes_once_the_missed_fixings_span_14_days(uint32 interval) public {
        interval = uint32(bound(interval, 1 hours, 30 days));
        PerpTerms memory t = _terms(first);
        t.fixingInterval = interval;
        PerpSeries x = _create(t);
        _fix(x, 0, 10000);
        uint256 locked = _mintPairs(x, alice, 100e6);
        uint256 n = (DEAD + interval - 1) / interval;
        assertLt((n - 1) * interval, DEAD);
        assertGe(n * interval, DEAD);

        uint40 tClose = _fixingTime(x, n);
        vm.warp(uint256(tClose) + FALLBACK - 1);
        PerpState memory st = x.advance();
        assertEq(uint8(st.phase), uint8(PerpPhase.Live));
        assertEq(st.missedInARow, n - 1);
        assertEq(st.fixingsDone, n - 1);

        vm.warp(uint256(tClose) + FALLBACK);
        st = x.advance();
        assertEq(uint8(st.phase), uint8(PerpPhase.Closed));
        assertEq(st.missedInARow, n);
        assertEq(st.fixingsDone, n);
        assertEq(st.notionalPerToken, 0);
        // clean at the reference: NOTE got everything; the pair redeems for nothing
        assertApproxEqAbs(x.claimable(alice), locked, 2);
        assertLe(x.claimable(alice), locked);
        vm.prank(alice);
        assertEq(x.redeemPair(100e6, alice), 0);
    }

    /// After the close: no mint, claims pay what was released (NOTE `noteCash`, COVER `coverCash`
    /// of 100 tokens, within rounding), a pair redeems for nothing, and later fixings change nothing.
    function _closedSeriesPaysOut(PerpSeries series, uint256 locked, uint256 noteCash, uint256 coverCash) internal {
        PerpState memory st = series.state();
        uint256 aliceCash = series.claimable(alice); // NOTE
        uint256 bobCash = series.claimable(bob); // COVER
        assertApproxEqAbs(aliceCash, noteCash, 10);
        assertApproxEqAbs(bobCash, coverCash, 10);
        assertLe(aliceCash + bobCash, locked);
        assertGe(aliceCash + bobCash + 10, locked);

        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(series), 10e6);
        vm.expectRevert(IPerpSeries.SeriesClosed.selector);
        series.mint(1e6, alice);
        assertEq(series.claim(alice), aliceCash);
        vm.stopPrank();
        vm.prank(bob);
        assertEq(series.claim(bob), bobCash);

        // the legs pair up again and redeem for nothing
        vm.prank(bob);
        coverT.transfer(alice, 100e6);
        assertEq(series.claimable(alice), 0);
        assertEq(series.previewRedeemPair(100e6), 0);
        vm.prank(alice);
        assertEq(series.redeemPair(100e6, alice), 0);
        assertEq(noteT.totalSupply(), 0);
        assertEq(coverT.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(series)), locked - aliceCash - bobCash);

        vm.warp(block.timestamp + 365 days);
        assertEq(keccak256(abi.encode(series.advance())), keccak256(abi.encode(st)));
    }

    /// The FixingProcessed events `series` emitted since vm.recordLogs; it must have emitted no Closed.
    function _fixingsWithoutClose(address series) internal returns (uint256 fixings) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 k = 0; k < logs.length; k++) {
            if (logs[k].emitter != series) continue;
            assertTrue(logs[k].topics[0] != IPerpSeries.Closed.selector, "closed early");
            if (logs[k].topics[0] == IPerpSeries.FixingProcessed.selector) fixings++;
        }
    }

    // --- the fallback clock pauses while the sequencer keeps the recorder from recording (#44) ---

    /// The review's case: Arbitrum goes down 30 seconds after 08:00, before the keeper recorded a
    /// crash fixing, and is back at 13:30. The recorder takes nothing before 14:30, so the fallback
    /// waits until 14:30 + 6 hours = 20:30: the fixing recorded from 14:30 on wins, and with nothing
    /// recorded the fallback comes at 20:30 to the second.
    function test_the_fallback_waits_six_hours_after_the_sequencer_grace() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        FixingsRecorder r = _recorder(s);
        uint40 t1 = _fixingTime(s, 1); // 08:00
        feed.pushRoundAt(_price(3000), t1 - 5 minutes); // the fixing: a crash, knocked in
        uint80 round = uint80(feed.latestRound());
        vm.warp(uint256(t1) + 30 seconds);
        sequencer.pushRound(1); // down
        vm.warp(uint256(t1) + 5 hours + 30 minutes);
        sequencer.pushRound(0); // back up at 13:30
        uint256 recordable = uint256(t1) + 6 hours + 30 minutes; // 14:30
        uint256 fallsBack = recordable + FALLBACK; // 20:30

        // 14:00, the plain deadline: the keeper can't record, and nothing falls back
        vm.warp(uint256(t1) + FALLBACK);
        vm.expectRevert(abi.encodeWithSelector(L2Sequencer.SequencerGracePeriod.selector, recordable));
        r.recordFixing(t1, round);
        (bool pending, uint40 t) = s.pendingFixing();
        assertTrue(pending);
        assertEq(t, t1);
        assertEq(s.advance().fixingsDone, 0);
        assertEq(s.state().nextFixing, t1);

        uint256 snap = vm.snapshotState();
        // nobody records: nothing a second before 20:30, the fallback at 20:30
        vm.warp(fallsBack - 1);
        assertEq(s.advance().fixingsDone, 0);
        (pending,) = s.pendingFixing();
        assertTrue(pending);
        vm.warp(fallsBack);
        PerpState memory st = s.advance();
        assertEq(st.fixingsDone, 1);
        assertEq(st.missedInARow, 1);
        assertFalse(st.knockedIn);
        (pending,) = s.pendingFixing();
        assertFalse(pending);

        // the keeper records as soon as the recorder takes it: the crash fixing wins, at 20:30 and after
        vm.revertToState(snap);
        vm.warp(recordable - 1);
        vm.expectRevert(abi.encodeWithSelector(L2Sequencer.SequencerGracePeriod.selector, recordable));
        r.recordFixing(t1, round);
        vm.warp(recordable);
        r.recordFixing(t1, round);
        vm.warp(fallsBack + 1 hours);
        st = s.advance();
        assertEq(st.fixingsDone, 1);
        assertEq(st.missedInARow, 0);
        assertTrue(st.knockedIn);
        assertEq(st.lastFixing, uint96(uint256(_price(3000))));
    }

    /// An outage that ends half an hour before the fixing: its grace runs past the fixing time, so
    /// the recorder takes the fixing from 08:30 and the fallback comes at 14:30, not 14:00. The
    /// next day the outage is long over: 14:00 sharp.
    function test_an_outage_whose_grace_overlaps_the_fixing_time() public {
        _fix(s, 0, 10000);
        uint40 t1 = _fixingTime(s, 1);
        vm.warp(uint256(t1) - 2 hours);
        sequencer.pushRound(1); // down at 06:00
        vm.warp(uint256(t1) - 30 minutes);
        sequencer.pushRound(0); // back up at 07:30
        feed.pushRoundAt(_price(9000), t1 - 1 minutes);
        uint80 round = uint80(feed.latestRound());
        FixingsRecorder r = _recorder(s);
        uint256 recordable = uint256(t1) + 30 minutes; // 08:30
        vm.warp(recordable - 1);
        vm.expectRevert(abi.encodeWithSelector(L2Sequencer.SequencerGracePeriod.selector, recordable));
        r.recordFixing(t1, round);

        vm.warp(uint256(t1) + FALLBACK);
        assertEq(s.advance().fixingsDone, 0);
        vm.warp(recordable + FALLBACK - 1);
        assertEq(s.advance().fixingsDone, 0);
        vm.warp(recordable + FALLBACK);
        PerpState memory st = s.advance();
        assertEq(st.fixingsDone, 1);
        assertEq(st.missedInARow, 1);

        uint40 t2 = _fixingTime(s, 2);
        vm.warp(uint256(t2) + FALLBACK - 1);
        assertEq(s.state().fixingsDone, 1);
        vm.warp(uint256(t2) + FALLBACK);
        assertEq(s.state().fixingsDone, 2);
        assertEq(s.state().missedInARow, 2);
    }

    /// While the sequencer is down nothing falls back, however old the fixing, and nothing else
    /// waits: claims, transfers and redeemPair work on the state before it. Back up, the fixings
    /// due by then fall back together an hour plus six later.
    function test_no_fallback_while_the_sequencer_is_down() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 9000);
        uint40 t2 = _fixingTime(s, 2);
        vm.warp(uint256(t2) + 1 hours);
        sequencer.pushRound(1);
        vm.warp(uint256(t2) + 10 days); // fixing 12's time
        PerpState memory st = s.state();
        assertEq(st.fixingsDone, 1);
        assertEq(st.nextFixing, t2);
        (bool pending, uint40 t) = s.pendingFixing();
        assertTrue(pending);
        assertEq(t, t2);
        assertEq(s.advance().fixingsDone, 1);

        uint256 owed = s.claimable(alice);
        assertEq(owed, 100e6 * M1 / RAY);
        uint256 redeemValue = s.previewRedeemPair(50e6);
        vm.startPrank(alice);
        assertEq(s.claim(alice), owed);
        noteT.transfer(bob, 10e6);
        assertEq(s.redeemPair(50e6, alice), redeemValue);
        vm.stopPrank();
        assertEq(redeemValue, 50e6 * S1 / RAY);
        assertEq(s.advance().fixingsDone, 1);

        sequencer.pushRound(0);
        uint256 opens = block.timestamp + GRACE + FALLBACK;
        vm.warp(opens - 1);
        assertEq(s.advance().fixingsDone, 1);
        vm.warp(opens);
        st = s.advance();
        assertEq(st.fixingsDone, 12); // fixings 2 to 12
        assertEq(st.missedInARow, 11);
        assertEq(uint8(st.phase), uint8(PerpPhase.Live));
        assertEq(st.nextFixing, _fixingTime(s, 13));
    }

    /// A dead feed and a five-day outage: the missed fixings wait for the sequencer and its grace,
    /// then fall back together. The series still closes at the 14th missed fixing in a row (14 days
    /// after the last good one) at its own deadline, and an outage across that deadline delays it.
    function test_a_long_outage_and_the_dead_feed_close() public {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
        _fix(s, 1, 9000);
        s.advance();
        vm.warp(uint256(_fixingTime(s, 2)) + 1 hours);
        sequencer.pushRound(1); // down at 09:00 on fixing 2's day
        vm.warp(uint256(_fixingTime(s, 7)) + 2 hours);
        sequencer.pushRound(0); // back up at 10:00 five days later
        uint256 opens = block.timestamp + GRACE + FALLBACK;
        vm.warp(opens - 1);
        PerpState memory st = s.advance();
        assertEq(st.fixingsDone, 1);
        assertEq(st.missedInARow, 0);
        vm.warp(opens);
        st = s.advance();
        assertEq(st.fixingsDone, 7); // fixings 2 to 7 at once
        assertEq(st.missedInARow, 6);
        assertEq(st.nextFixing, _fixingTime(s, 8));

        uint40 tClose = _fixingTime(s, 15);
        assertEq(tClose - _fixingTime(s, 1), DEAD);
        uint256 snap = vm.snapshotState();
        vm.warp(uint256(tClose) + FALLBACK - 1);
        st = s.advance();
        assertEq(uint8(st.phase), uint8(PerpPhase.Live));
        assertEq(st.missedInARow, 13);
        vm.warp(uint256(tClose) + FALLBACK);
        vm.expectEmit(address(s));
        emit IPerpSeries.Closed(15, uint96(uint256(_price(9000))));
        st = s.advance();
        assertEq(uint8(st.phase), uint8(PerpPhase.Closed));
        assertEq(st.missedInARow, 14);
        assertEq(st.fixingsDone, 15);
        assertEq(st.notionalPerToken, 0);

        // down from 13:00 to 18:00 on the closing day: the close waits for 01:00 the next day
        vm.revertToState(snap);
        vm.warp(uint256(tClose) + 5 hours);
        assertEq(s.advance().missedInARow, 13);
        sequencer.pushRound(1);
        vm.warp(uint256(tClose) + 10 hours);
        sequencer.pushRound(0);
        vm.warp(uint256(tClose) + 10 hours + GRACE + FALLBACK - 1);
        st = s.advance();
        assertEq(uint8(st.phase), uint8(PerpPhase.Live));
        assertEq(st.missedInARow, 13);
        vm.warp(uint256(tClose) + 10 hours + GRACE + FALLBACK);
        st = s.advance();
        assertEq(uint8(st.phase), uint8(PerpPhase.Closed));
        assertEq(st.missedInARow, 14);
    }

    /// The series uses its recorder's uptime feed and grace. Without one (a factory with no uptime
    /// feed) the plain rule holds to the second, whatever the sequencer does.
    function test_without_an_uptime_feed_the_plain_rule() public {
        FixingsRecorder r = _recorder(s);
        assertEq(address(s.sequencer()), address(r.sequencer()));
        assertEq(address(s.sequencer()), address(sequencer));
        assertEq(s.SEQUENCER_GRACE(), r.SEQUENCER_GRACE());
        assertEq(s.SEQUENCER_GRACE(), GRACE);
        PerpSeries n = _seriesWithoutSequencer();
        assertEq(address(n.sequencer()), address(0));
        assertEq(address(_recorder(n).sequencer()), address(0));

        _fix(s, 0, 10000);
        _recordLatest(n, first);
        uint40 t1 = _fixingTime(s, 1);
        vm.warp(uint256(t1) + 1 hours);
        sequencer.pushRound(1); // down: it holds `s` back, not `n`
        vm.warp(uint256(t1) + FALLBACK - 1);
        assertEq(n.advance().fixingsDone, 0);
        vm.warp(uint256(t1) + FALLBACK);
        PerpState memory st = n.advance();
        assertEq(st.fixingsDone, 1);
        assertEq(st.missedInARow, 1);
        assertEq(s.advance().fixingsDone, 0);
    }

    /// Live with alice holding 100 pairs; fixing 1 will go unrecorded.
    function _liveWithPairs() internal {
        _fix(s, 0, 10000);
        _mintPairs(s, alice, 100e6);
    }

    /// The plain rule for fixing 1, and every entry point works: a transfer processes the fallback,
    /// claim and redeemPair pay on it.
    function _plainRuleAndNothingWaits() internal {
        uint40 t1 = _fixingTime(s, 1);
        vm.warp(uint256(t1) + FALLBACK - 1);
        assertEq(s.state().fixingsDone, 0);
        (bool pending,) = s.pendingFixing();
        assertTrue(pending);
        vm.warp(uint256(t1) + FALLBACK);
        PerpState memory st = s.state();
        assertEq(st.fixingsDone, 1);
        assertEq(st.missedInARow, 1);
        (pending,) = s.pendingFixing();
        assertFalse(pending);

        uint256 owed = 100e6 * M1 / RAY; // clean at the last fixing: NOTE gets the melted notional
        vm.startPrank(alice);
        noteT.transfer(bob, 10e6);
        assertEq(keccak256(abi.encode(s.advanceBy(0))), keccak256(abi.encode(st))); // stored
        assertEq(s.claim(alice), owed);
        assertEq(s.redeemPair(50e6, alice), 50e6 * S1 / RAY);
        vm.stopPrank();
    }

    function test_an_uptime_feed_that_reverts_counts_as_none() public {
        _liveWithPairs();
        vm.mockCallRevert(address(sequencer), IAggregatorV3.latestRoundData.selector, "broken");
        _plainRuleAndNothingWaits();
    }

    function test_an_uptime_feed_without_code_counts_as_none() public {
        _liveWithPairs();
        vm.etch(address(sequencer), "");
        _plainRuleAndNothingWaits();
    }

    /// Too short to hold startedAt: "down" in it means nothing.
    function test_an_uptime_feed_that_answers_short_counts_as_none() public {
        _liveWithPairs();
        vm.mockCall(
            address(sequencer),
            IAggregatorV3.latestRoundData.selector,
            abi.encode(uint256(1), int256(1), block.timestamp, block.timestamp)
        );
        _plainRuleAndNothingWaits();
    }

    /// Neither up (0) nor down (1).
    function test_an_uptime_feed_that_answers_nonsense_counts_as_none() public {
        _liveWithPairs();
        vm.mockCall(
            address(sequencer),
            IAggregatorV3.latestRoundData.selector,
            abi.encode(uint80(1), int256(2), block.timestamp, block.timestamp, uint80(1))
        );
        _plainRuleAndNothingWaits();
    }

    /// Down, but since a time to come.
    function test_an_uptime_feed_with_startedAt_in_the_future_counts_as_none() public {
        _liveWithPairs();
        vm.mockCall(
            address(sequencer),
            IAggregatorV3.latestRoundData.selector,
            abi.encode(uint80(1), int256(1), block.timestamp + 30 days, block.timestamp, uint80(1))
        );
        _plainRuleAndNothingWaits();
    }

    /// Down, with startedAt 0 (not initialized, Chainlink's docs): the recorder refuses, the series
    /// keeps the plain rule.
    function test_an_uptime_feed_with_startedAt_zero_counts_as_none() public {
        _liveWithPairs();
        sequencer.pushRound(1);
        vm.mockCall(
            address(sequencer),
            IAggregatorV3.latestRoundData.selector,
            abi.encode(uint80(1), int256(1), uint256(0), block.timestamp, uint80(1))
        );
        _plainRuleAndNothingWaits();
    }

    /// Garbage in the words the series doesn't read (round ids beyond uint80, data past the fifth
    /// word) reverts nothing: the status still counts, here down for 10 days (under
    /// CLOSE_AFTER_DEAD), so nothing falls back while every entry point works.
    function test_garbage_beside_the_status_is_ignored() public {
        _liveWithPairs();
        vm.mockCall(
            address(sequencer),
            IAggregatorV3.latestRoundData.selector,
            abi.encode(type(uint256).max, int256(1), block.timestamp, type(uint256).max, type(uint256).max, "extra")
        );
        vm.warp(block.timestamp + 10 days);
        assertEq(s.state().fixingsDone, 0);
        vm.startPrank(alice);
        noteT.transfer(bob, 10e6);
        assertEq(s.claim(alice), 0);
        assertEq(s.redeemPair(50e6, alice), 50e6);
        vm.stopPrank();
        assertEq(s.advance().fixingsDone, 0);
    }

    /// A feed stuck on "down" (an "up" message never delivered, a feed retired while it reads 1)
    /// counts as broken once it has read down for CLOSE_AFTER_DEAD: the missed fixings fall back
    /// together, and the 14th in a row closes the series. A second earlier, nothing falls back.
    function test_a_feed_stuck_down_for_14_days_counts_as_none() public {
        _fix(s, 0, 10000);
        uint256 locked = _mintPairs(s, alice, 100e6);
        vm.prank(alice);
        coverT.transfer(bob, 100e6);
        _fix(s, 1, 9000);
        s.advance();
        vm.warp(uint256(_fixingTime(s, 2)) + 1 hours);
        sequencer.pushRound(1); // down, and never back
        uint256 stuck = block.timestamp + DEAD;
        vm.warp(stuck - 1);
        PerpState memory st = s.advance();
        assertEq(st.fixingsDone, 1);
        assertEq(st.missedInARow, 0);
        (bool pending, uint40 t) = s.pendingFixing();
        assertTrue(pending);
        assertEq(t, _fixingTime(s, 2));

        // fixings 2 to 15 (15's deadline was at 14:00 yesterday): 14 missed in a row, closed
        vm.warp(stuck);
        vm.expectEmit(address(s));
        emit IPerpSeries.Closed(15, uint96(uint256(_price(9000))));
        st = s.advance();
        assertEq(uint8(st.phase), uint8(PerpPhase.Closed));
        assertEq(st.missedInARow, 14);
        assertEq(st.fixingsDone, 15);
        assertEq(st.notionalPerToken, 0);
        // clean at 90: NOTE gets everything
        _closedSeriesPaysOut(s, locked, 100_000_000, 0);
    }

    function test_an_uptime_feed_that_returns_huge_data_counts_as_none() public {
        _hugeDataLeavesThePlainRule(false);
    }

    function test_an_uptime_feed_that_reverts_with_huge_data_counts_as_none() public {
        _hugeDataLeavesThePlainRule(true);
    }

    /// The series copies at most five words of the answer: with 1M gas as with 30M, advance and
    /// claim go through under the plain rule.
    function _hugeDataLeavesThePlainRule(bool reverts) internal {
        _liveWithPairs();
        vm.etch(address(sequencer), address(new HugeDataFeed(reverts)).code);
        vm.warp(uint256(_fixingTime(s, 1)) + FALLBACK);
        uint256[2] memory limits = [uint256(1_000_000), 30_000_000];
        for (uint256 i = 0; i < limits.length; i++) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(s).call{gas: limits[i]}(abi.encodeCall(PerpSeries.advance, ()));
            assertTrue(ok, "advance");
            assertEq(s.advanceBy(0).missedInARow, 1);
            vm.revertToState(snap);
            vm.prank(alice);
            (ok,) = address(s).call{gas: limits[i]}(abi.encodeCall(PerpSeries.claim, (alice)));
            assertTrue(ok, "claim");
            assertEq(usdc.balanceOf(alice), 100e6 * M1 / RAY);
            assertEq(s.advanceBy(0).missedInARow, 1);
            vm.revertToState(snap);
        }
    }

    /// An uptime feed that burns all the gas it gets: 63/64 of it goes, the rest finishes the
    /// transaction within Arbitrum's block gas limit, under the plain rule.
    function test_an_uptime_feed_that_burns_its_gas_counts_as_none() public {
        _liveWithPairs();
        vm.etch(address(sequencer), hex"5b600056"); // JUMPDEST PUSH1 0 JUMP: loops until out of gas
        vm.warp(uint256(_fixingTime(s, 1)) + FALLBACK);
        vm.prank(alice);
        noteT.transfer{gas: 30_000_000}(bob, 10e6);
        PerpState memory st = s.advanceBy(0);
        assertEq(st.fixingsDone, 1);
        assertEq(st.missedInARow, 1);
    }

    /// Starving the uptime call can't force the fallback while the sequencer is down: when the call
    /// runs out of gas, the 1/64 it leaves can't process and store a fixing, so advance reverts.
    /// Below the least gas advance runs on, every call reverts; from it on, the call reads "down".
    function test_starving_the_uptime_call_never_forces_the_fallback() public {
        _liveWithPairs();
        uint40 t1 = _fixingTime(s, 1);
        vm.warp(uint256(t1) + 1 minutes);
        sequencer.pushRound(1);
        vm.warp(uint256(t1) + FALLBACK);
        // the least gas advance runs on (more never hurts): a binary search
        uint256 lo = 0;
        uint256 hi = 1_000_000;
        while (hi - lo > 1) {
            uint256 mid = (lo + hi) / 2;
            if (_advanceWith(mid)) hi = mid;
            else lo = mid;
        }
        // a few thousand below it the call to the uptime feed itself runs out of gas (with this
        // mock, about 4,500 below); the more gas, the more the call leaves, yet never enough
        for (uint256 gas = hi - 8000; gas < hi; gas++) {
            assertFalse(_advanceWith(gas));
        }
        assertTrue(_advanceWith(hi));
        assertEq(s.advance().fixingsDone, 0);
    }

    /// advance() with `gas`; whenever it succeeds, nothing fell back.
    function _advanceWith(uint256 gas) internal returns (bool ok) {
        (ok,) = address(s).call{gas: gas}(abi.encodeCall(PerpSeries.advance, ()));
        if (ok) assertEq(s.advanceBy(0).fixingsDone, 0);
    }

    // --- gas -------------------------------------------------------------------------

    /// What advance() costs as its own transaction (every account cold; the 21,000 base and the
    /// calldata aside): a recorded fixing, which never reads the uptime feed, and missed fixings on
    /// a factory without an uptime feed and on one with it, one at a time and 12 in one call.
    function test_gas_of_advance() public {
        PerpSeries n = _seriesWithoutSequencer();
        _fix(s, 0, 10000);
        _recordLatest(n, first);
        _mintPairs(s, alice, 100e6);
        _mintPairs(n, alice, 100e6);

        _fix(s, 1, 9000);
        _recordLatest(n, _fixingTime(s, 1));
        emit log_named_uint("gas, advance: a recorded fixing", _gasOfAdvance(s));
        n.advance();

        vm.warp(uint256(_fixingTime(s, 2)) + FALLBACK);
        emit log_named_uint("gas, advance: a missed fixing, no uptime feed", _gasOfAdvance(n));
        emit log_named_uint("gas, advance: a missed fixing, the uptime feed up", _gasOfAdvance(s));
        assertEq(n.state().missedInARow, 1);
        assertEq(s.state().missedInARow, 1);

        vm.warp(uint256(_fixingTime(s, 14)) + FALLBACK);
        emit log_named_uint("gas, advance: 12 missed fixings, no uptime feed", _gasOfAdvance(n));
        emit log_named_uint("gas, advance: 12 missed fixings, the uptime feed up", _gasOfAdvance(s));
        assertEq(n.state().missedInARow, 13);
        assertEq(s.state().missedInARow, 13);
        assertEq(uint8(s.state().phase), uint8(PerpPhase.Live));
    }

    /// The same series as `s`, on a factory whose recorders have no uptime feed.
    function _seriesWithoutSequencer() internal returns (PerpSeries) {
        IPerpFactory.RecorderLimits memory l = _limits();
        l.sequencer = address(0);
        l.sequencerGrace = 0;
        return PerpSeries(new PerpFactory(address(usdc), l).createSeries(_terms(first)));
    }

    /// Records the feed's latest round as `x`'s fixing at `t`.
    function _recordLatest(PerpSeries x, uint40 t) internal {
        _recorder(x).recordFixing(t, uint80(feed.latestRound()));
    }

    /// The execution gas of `x.advance()` with every account it may touch cold.
    function _gasOfAdvance(PerpSeries x) internal returns (uint256 g) {
        address impl = PerpFactory(x.factory()).seriesImplementation();
        address r = address(x.recorder());
        vm.cool(address(x));
        vm.cool(impl);
        vm.cool(r);
        vm.cool(address(feed));
        vm.cool(address(sequencer));
        g = gasleft();
        x.advance();
        g -= gasleft();
    }

    // --- advance in chunks ----------------------------------------------------------

    function test_advanceBy_catches_up_in_steps() public {
        for (uint256 n = 0; n <= 6; n++) {
            _fix(s, n, 9000 + n * 50);
        }
        PerpState memory want = s.state(); // the view replays everything
        assertEq(want.fixingsDone, 6);
        // advanceBy returns what is stored after its steps
        assertEq(uint8(s.advanceBy(0).phase), uint8(PerpPhase.Pending));
        PerpState memory st = s.advanceBy(1); // the first fixing is one step
        assertEq(uint8(st.phase), uint8(PerpPhase.Live));
        assertEq(st.fixingsDone, 0);
        assertEq(s.advanceBy(2).fixingsDone, 2);
        assertEq(s.advanceBy(3).fixingsDone, 5);
        assertEq(keccak256(abi.encode(s.state())), keccak256(abi.encode(want)));
        PerpState memory got = s.advanceBy(100);
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(want)));
    }

    // --- guards -----------------------------------------------------------------------

    function test_reentrant_collateral_is_blocked() public {
        ReentrantPerpUSDC re = new ReentrantPerpUSDC();
        PerpFactory f2 = new PerpFactory(address(re), _limits());
        PerpSeries s2 = PerpSeries(f2.createSeries(_terms(first)));
        _fixAt(s2, first, _price(10000));
        re.mint(alice, 10e6);
        vm.startPrank(alice);
        re.approve(address(s2), type(uint256).max);
        re.setTarget(s2);
        vm.expectRevert(ReentrancyGuard.ReentrancyGuardReentrantCall.selector);
        s2.mint(1e6, alice);
        vm.stopPrank();
    }

    function test_implementation_and_clones_cannot_be_reinitialized() public {
        PerpSeries impl = PerpSeries(factory.seriesImplementation());
        vm.expectRevert(PerpSeries.OnlyFactory.selector);
        impl.initialize(bytes32(uint256(2)), _terms(first), address(1), address(2), address(3), address(usdc));
        vm.prank(address(factory));
        vm.expectRevert(PerpSeries.AlreadyInitialized.selector);
        impl.initialize(bytes32(uint256(2)), _terms(first), address(1), address(2), address(3), address(usdc));
        vm.prank(address(factory));
        vm.expectRevert(PerpSeries.AlreadyInitialized.selector);
        s.initialize(bytes32(uint256(2)), _terms(first), address(1), address(2), address(3), address(usdc));

        PerpToken tokenImpl = PerpToken(factory.tokenImplementation());
        vm.expectRevert(ISeriesToken.OnlyFactory.selector);
        tokenImpl.initialize(address(this), true, 6, "x", "x");
        vm.prank(address(factory));
        vm.expectRevert(ISeriesToken.AlreadyInitialized.selector);
        tokenImpl.initialize(address(this), true, 6, "x", "x");
    }

    // --- the coupon path and weekly fixings: a weekly series with R = 0.235 --------------------

    /// The weekly series with a coupon reserve, on the same feed and first fixing.
    function _weekly() internal returns (PerpSeries w) {
        w = _create(_weeklyCouponTerms(first));
        noteT = _note(w);
        coverT = _cover(w);
    }

    function test_coupon_series_clean_fixing_releases_a_times_one_plus_R() public {
        PerpSeries w = _weekly();
        _fix(w, 0, 10000);
        assertEq(w.state().nextFixing, first + WEEK);
        _mintPairs(w, alice, 100e6);
        _fix(w, 1, 9000);

        uint256 release = M1_WEEKLY * (UNIT + COUPON) / UNIT;
        vm.expectEmit(address(w));
        emit IPerpSeries.FixingProcessed(
            1, first + WEEK, uint96(uint256(_price(9000))), INITIAL, false, false, RAY - M1_WEEKLY, release, 0
        );
        PerpState memory st = w.advance();
        assertEq(st.noteIndex, release);
        assertEq(st.coverIndex, 0);
        // 100 NOTE: a * (1 + R) = 1.8995% * 1.235 of 100 USDC
        assertEq(w.claimable(alice), 2_345_926);
    }

    function test_coupon_series_knocked_in_fixing_pays_note_x_plus_R() public {
        PerpSeries w = _weekly();
        _fix(w, 0, 10000);
        _mintPairs(w, alice, 100e6);
        vm.prank(alice);
        coverT.transfer(bob, 100e6);
        _fix(w, 1, 5000); // below 60%: knocked in, x = 0.5
        PerpState memory st = w.advance();
        assertTrue(st.knockedIn);
        uint256 total = M1_WEEKLY * (UNIT + COUPON) / UNIT;
        uint256 noteRelease =
            M1_WEEKLY * (uint256(_price(5000)) * UNIT + uint256(COUPON) * INITIAL) / (uint256(INITIAL) * UNIT);
        assertEq(st.noteIndex, noteRelease);
        assertEq(st.coverIndex, total - noteRelease);
        // NOTE: a * (0.5 + 0.235), COVER: a * 0.5, of 100 USDC
        assertEq(w.claimable(alice), 1_396_158);
        assertEq(w.claimable(bob), 949_767);
    }

    function test_coupon_series_mint_locks_ceil_and_redeemPair_pays_floor() public {
        PerpSeries w = _weekly();
        _fix(w, 0, 10000);
        assertEq(w.pairValuePerNotional(), 1_235_000);
        assertEq(w.previewMint(1e6), 1_235_000);
        assertEq(w.previewMint(3), 4); // 3 * 1.235 = 3.705 -> 4
        assertEq(w.previewRedeemPair(3), 3);

        assertEq(_mintPairs(w, alice, 3), 4);
        vm.prank(alice);
        assertEq(w.redeemPair(3, bob), 3);
        assertEq(usdc.balanceOf(address(w)), 1); // the rounding stays in the escrow

        _mintPairs(w, alice, 100e6);
        _fix(w, 1, 9000);
        w.advance();
        assertEq(w.notionalOf(1e6), 981_004);
        assertEq(w.previewMint(100e6), 121_154_074); // 100 * 0.98100465 * 1.235, rounded up
        assertEq(_mintPairs(w, bob, 100e6), 121_154_074);
        vm.prank(bob);
        assertEq(w.redeemPair(100e6, bob), 121_154_073);
        vm.startPrank(alice);
        noteT.transfer(bob, 4e6);
        vm.expectRevert(); // ERC20InsufficientBalance on NOTE
        w.redeemPair(97e6, alice);
        vm.stopPrank();
    }

    // --- fuzz: nobody is paid more than was locked, and almost all of it is paid ----

    function testFuzz_path_conserves_collateral(uint256 seed, uint8 fixings, uint64 amountA, uint64 amountB) public {
        _pathConservesCollateral(s, seed, fixings, amountA, amountB);
    }

    function testFuzz_path_conserves_collateral_weekly_with_a_coupon(
        uint256 seed,
        uint8 fixings,
        uint64 amountA,
        uint64 amountB
    ) public {
        _pathConservesCollateral(_weekly(), seed, fixings, amountA, amountB);
    }

    function _pathConservesCollateral(PerpSeries series, uint256 seed, uint8 fixings, uint64 amountA, uint64 amountB)
        internal
    {
        fixings = uint8(bound(fixings, 1, 40));
        uint256 a = bound(amountA, 1, 1e12);
        uint256 b = bound(amountB, 1, 1e12);
        _fix(series, 0, 10000);
        uint256 lockedIn = _mintPairs(series, alice, a);
        vm.prank(alice);
        coverT.transfer(bob, a); // alice is long NOTE, bob long COVER

        uint256 paidOut;
        uint256 price = 10000;
        for (uint256 n = 1; n <= fixings; n++) {
            seed = uint256(keccak256(abi.encode(seed)));
            price = bound(price * (7000 + seed % 6500) / 10000, 100, 60000);
            if (seed % 11 != 0) _fix(series, n, price); // sometimes nobody records: the deadline decides later
            else vm.warp(uint256(_fixingTime(series, n)) + FALLBACK);
            // a dead feed can close the series (at weekly fixings, two missed in a row): nothing mints after that
            if (seed % 5 == 0 && series.state().phase == PerpPhase.Live) lockedIn += _mintPairs(series, bob, b);
            if (seed % 7 == 0) {
                vm.prank(alice);
                paidOut += series.claim(alice);
            }
        }
        vm.warp(block.timestamp + series.terms().fixingInterval + FALLBACK);
        series.advance();

        // everybody claims, then whoever can pair up redeems
        vm.prank(alice);
        paidOut += series.claim(alice);
        vm.prank(bob);
        paidOut += series.claim(bob);
        uint256 bobNote = noteT.balanceOf(bob);
        if (bobNote != 0) {
            vm.prank(bob);
            paidOut += series.redeemPair(bobNote, bob);
        }
        vm.prank(bob);
        coverT.transfer(alice, a);
        vm.prank(alice);
        paidOut += series.redeemPair(a, alice);

        assertEq(noteT.totalSupply(), 0);
        assertEq(coverT.totalSupply(), 0);
        assertEq(usdc.balanceOf(address(series)), lockedIn - paidOut);
        // what stays behind is rounding: under one base unit per mint, claim, leg and fixing
        assertLe(lockedIn - paidOut, 6 + 3 * uint256(series.state().fixingsDone));
        assertEq(series.claimable(alice), 0);
        assertEq(series.claimable(bob), 0);
    }
}
