// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {FixingsRecorder} from "../src/FixingsRecorder.sol";
import {L2Sequencer} from "../src/L2Sequencer.sol";
import {IFixingsRecorder} from "../src/interfaces/IFixingsRecorder.sol";

/// The recorder's rule (docs/v2-spec.md §5) on a mock feed with the launch's limits
/// (DeployPerp.s.sol): the fixing for a time is the last round at or before it, at most
/// MAX_FIX_AGE old. A round after the time is never a fixing.
contract FeedScenariosTest is Test {
    uint80 constant R1 = uint80(1) << 64 | 1; // 2^64 + 1
    int256 constant PRICE = 3872_45_000_000; // $3,872.45 @ 8dec
    uint40 constant T0 = 1_790_699_124; // 2026-09-29 16:25 UTC
    uint40 constant MAX_FIX_AGE = 1 hours;
    int256 constant PRICE_MAX = 1e15;

    MockChainlinkFeed feed;
    FixingsRecorder recorder;

    function setUp() public {
        vm.warp(T0);
        feed = new MockChainlinkFeed("ETH / USD");
        // the launch's limits; no sequencer check (it has its own test below)
        recorder = new FixingsRecorder(address(feed), MAX_FIX_AGE, PRICE_MAX, address(0), 0);
    }

    function test_the_limits_must_be_sound() public {
        vm.expectRevert(FixingsRecorder.BadLimits.selector);
        new FixingsRecorder(address(feed), 0, PRICE_MAX, address(0), 0);
        vm.expectRevert(FixingsRecorder.BadLimits.selector);
        new FixingsRecorder(address(feed), MAX_FIX_AGE, 0, address(0), 0);
        int256 cap = int256(uint256(type(uint96).max)); // a price is stored as uint96
        vm.expectRevert(FixingsRecorder.BadLimits.selector);
        new FixingsRecorder(address(feed), MAX_FIX_AGE, cap + 1, address(0), 0);
        FixingsRecorder r = new FixingsRecorder(address(feed), MAX_FIX_AGE, cap, address(0), 0);
        assertEq(address(r.feed()), address(feed));
        assertEq(r.MAX_FIX_AGE(), MAX_FIX_AGE);
        assertEq(r.PRICE_MAX(), cap);
        assertEq(address(r.sequencer()), address(0));
    }

    // --- the fixing: the last round at or before the time -------------------------

    function test_the_last_round_before_the_time_is_the_fixing() public {
        feed.pushRound(PRICE); // R1 at T0
        vm.warp(block.timestamp + 30 minutes);
        feed.pushRound(PRICE + 1e8); // R2
        uint40 obsTime = uint40(block.timestamp) - 10 minutes; // between R1 and R2

        vm.expectEmit(address(recorder));
        emit IFixingsRecorder.FixingRecorded(obsTime, R1, uint96(uint256(PRICE)), T0);
        recorder.recordFixing(obsTime, R1);
        (uint40 ts, uint96 price, uint80 rid) = recorder.fixings(obsTime);
        assertEq(ts, T0);
        assertEq(price, uint96(uint256(PRICE)));
        assertEq(rid, R1);
        assertTrue(recorder.isRecorded(obsTime));
        assertEq(keccak256(abi.encode(recorder.fixingOf(obsTime))), keccak256(abi.encode(ts, price, rid)));
    }

    /// updatedAt == obsTime is at the time, not after it; a round a second later is after it.
    function test_a_round_at_the_time_itself_is_the_fixing() public {
        feed.pushRound(PRICE); // R1 at T0
        vm.warp(T0 + 1);
        feed.pushRound(PRICE + 1e8); // R2, a second later
        vm.warp(T0 + 2);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, R1 + 1, T0));
        recorder.recordFixing(T0, R1 + 1);
        recorder.recordFixing(T0, R1);
        assertEq(recorder.fixingOf(T0).price, uint96(uint256(PRICE)));
    }

    function test_an_older_round_is_not_the_fixing() public {
        feed.pushRound(PRICE); // R1
        vm.warp(block.timestamp + 30 minutes);
        feed.pushRound(PRICE); // R2
        uint40 obsTime = uint40(block.timestamp); // at/after R2
        vm.warp(obsTime + 1);
        // R1 is not the last round at-or-before obsTime — R2 is
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.NotLastRoundBefore.selector, R1, obsTime));
        recorder.recordFixing(obsTime, R1);
    }

    function test_already_recorded() public {
        feed.pushRound(PRICE);
        uint40 obsTime = uint40(block.timestamp);
        vm.warp(obsTime + 1);
        recorder.recordFixing(obsTime, R1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.AlreadyRecorded.selector, obsTime));
        recorder.recordFixing(obsTime, R1);
    }

    function test_bad_price_anomaly_guard() public {
        feed.pushRound(int256(3.96e18)); // a stock feed's round-1 scale artifact, seen on mainnet
        uint40 obsTime = uint40(block.timestamp);
        vm.warp(obsTime + 1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.BadPrice.selector, int256(3.96e18)));
        recorder.recordFixing(obsTime, R1);
    }

    function test_bad_price_non_positive() public {
        feed.pushRound(0);
        uint40 obsTime = uint40(block.timestamp);
        vm.warp(obsTime + 1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.BadPrice.selector, int256(0)));
        recorder.recordFixing(obsTime, R1);
    }

    function test_the_price_cap_is_inclusive() public {
        feed.pushRound(PRICE_MAX);
        vm.warp(T0 + 1);
        feed.pushRound(PRICE_MAX + 1);
        uint40 obsTime = T0 + 1;
        vm.warp(obsTime + 1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.BadPrice.selector, PRICE_MAX + 1));
        recorder.recordFixing(obsTime, R1 + 1);
        recorder.recordFixing(T0, R1);
        assertEq(recorder.fixingOf(T0).price, uint96(uint256(PRICE_MAX)));
    }

    function test_future_observation_rejected() public {
        feed.pushRound(PRICE);
        uint40 obsTime = uint40(block.timestamp);
        // obsTime == now is still "future": a later block in the same second
        // could add a round with updatedAt == obsTime.
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.FutureObservation.selector, obsTime));
        recorder.recordFixing(obsTime, R1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.FutureObservation.selector, obsTime + 1));
        recorder.recordFixing(obsTime + 1, R1);
    }

    // --- staleness: at most MAX_FIX_AGE, the edge included ---------------------------

    function test_a_round_exactly_MAX_FIX_AGE_old_is_the_fixing() public {
        feed.pushRound(PRICE);
        uint40 obsTime = T0 + MAX_FIX_AGE;
        vm.warp(obsTime + 1);
        recorder.recordFixing(obsTime, R1);
        assertEq(recorder.fixingOf(obsTime).timestamp, T0);
    }

    function test_a_round_older_than_MAX_FIX_AGE_is_too_stale() public {
        feed.pushRound(PRICE);
        uint40 obsTime = T0 + MAX_FIX_AGE + 1;
        vm.warp(obsTime + 1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.FixingTooStale.selector, T0, obsTime));
        recorder.recordFixing(obsTime, R1);
        assertFalse(recorder.isRecorded(obsTime));
    }

    // --- no rolled fixing: a round after the time is never the fixing ---------------

    /// The feed was silent across the fixing time: the stale round before it is refused, and so is
    /// the first round after it. The fixing is never recorded, and the series falls back.
    function test_after_a_silent_feed_the_fixing_is_never_recorded() public {
        feed.pushRound(PRICE); // R1
        uint40 obsTime = T0 + 1 days;
        vm.warp(obsTime + 2 hours); // silent for 26 hours across the fixing time
        feed.pushRound(PRICE + 2e8); // R2: the first round after the silence
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.FixingTooStale.selector, T0, obsTime));
        recorder.recordFixing(obsTime, R1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, R1 + 1, obsTime));
        recorder.recordFixing(obsTime, R1 + 1);
        assertFalse(recorder.isRecorded(obsTime));
    }

    /// Every round after the time is refused: the first one after it, a later one, and the feed's
    /// very first round, which has nothing before it.
    function test_rounds_after_the_time_are_refused() public {
        uint40 obsTime = T0 - 1 hours;
        feed.pushRound(PRICE); // R1, the feed's first round
        vm.warp(block.timestamp + 1 hours);
        feed.pushRound(PRICE); // R2
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, R1, obsTime));
        recorder.recordFixing(obsTime, R1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, R1 + 1, obsTime));
        recorder.recordFixing(obsTime, R1 + 1);
        assertFalse(recorder.isRecorded(obsTime));
    }

    /// Two rounds `gap` seconds apart and a fixing time `offset` after the first: a round records
    /// only as the last round at or before the time and at most MAX_FIX_AGE old, and otherwise
    /// reverts with the error of the first rule it breaks.
    function testFuzz_only_the_last_fresh_round_before_the_time_records(uint256 gap, uint256 offset, bool second)
        public
    {
        gap = bound(gap, 1, 3 days);
        offset = bound(offset, 0, 4 days);
        feed.pushRound(PRICE); // R1 at T0
        feed.pushRoundAt(PRICE + 1e8, uint40(T0 + gap)); // R2, the latest
        uint40 obsTime = uint40(T0 + offset);
        vm.warp(uint256(T0) + 5 days);
        uint80 round = second ? R1 + 1 : R1;
        uint40 at = second ? uint40(T0 + gap) : T0;
        if (at > obsTime) {
            vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, round, obsTime));
        } else if (obsTime - at > MAX_FIX_AGE) {
            vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.FixingTooStale.selector, at, obsTime));
        } else if (!second && offset >= gap) {
            vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.NotLastRoundBefore.selector, round, obsTime));
        }
        bool ok = at <= obsTime && obsTime - at <= MAX_FIX_AGE && (second || offset < gap);
        recorder.recordFixing(obsTime, round);
        assertEq(recorder.isRecorded(obsTime), ok);
    }

    // --- recorder reads a backdated staged round correctly -----------------

    function test_staged_backdated_round() public {
        feed.pushRoundAt(PRICE, uint40(1_790_600_000)); // staged "yesterday"
        recorder.recordFixing(uint40(1_790_600_000), R1);
        assertTrue(recorder.isRecorded(uint40(1_790_600_000)));
    }

    // --- phases: an aggregator upgrade behind the proxy (#25) ---------------------

    uint80 constant P2R1 = uint80(2) << 64 | 1; // the first round of phase 2

    /// The first round of a later phase has no round before it in its phase. It is never the
    /// fixing for a time before it, on a feed that reverts or answers zeros for a missing round,
    /// across a gap or not; from its own time on it is a normal fixing.
    function test_the_first_round_of_a_later_phase_is_never_a_fixing_before_its_time() public {
        _phaseChangeWithoutOverlap();
        uint40 obsTime = T0 + 10 minutes; // old phase fresh, new phase starts after
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, P2R1, obsTime));
        recorder.recordFixing(obsTime, P2R1);
        feed.setZerosForUnknownRounds(true);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, P2R1, obsTime));
        recorder.recordFixing(obsTime, P2R1);
        uint40 late = T0 + 100 hours - 1; // across the gap, a second before P2R1
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, P2R1, late));
        recorder.recordFixing(late, P2R1);
        assertFalse(recorder.isRecorded(obsTime));
        assertFalse(recorder.isRecorded(late));
        uint40 own = T0 + 100 hours;
        recorder.recordFixing(own, P2R1);
        assertEq(recorder.fixingOf(own).price, uint96(uint256(PRICE / 2)));
    }

    function test_the_last_round_of_an_earlier_phase_is_not_recorded() public {
        _phaseChangeWithoutOverlap();
        uint40 obsTime = T0 + 10 minutes;
        // R1 has no next round in phase 1 and isn't the latest: refused, on either kind of feed
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.NotLastRoundBefore.selector, R1, obsTime));
        recorder.recordFixing(obsTime, R1);
        feed.setZerosForUnknownRounds(true);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.NotLastRoundBefore.selector, R1, obsTime));
        recorder.recordFixing(obsTime, R1);
        assertFalse(recorder.isRecorded(obsTime)); // no round records it: the series falls back
    }

    /// The Chainlink way (ETH/USD on Arbitrum One): the new aggregator runs for weeks next to the
    /// old one, so a fixing in the overlap is a normal fixing in the new phase.
    function test_overlapping_phases_record_normally() public {
        uint40 t0 = uint40(block.timestamp);
        feed.pushRoundAt(PRICE, t0); // R1, the old aggregator's last round
        feed.startPhase();
        feed.pushRoundAt(PRICE + 1e8, t0 - 5 minutes); // P2R1: the new aggregator was already running
        feed.pushRoundAt(PRICE + 2e8, t0 + 20 minutes); // after the switch
        vm.warp(t0 + 30 minutes);
        assertEq(feed.latestRound(), uint256(P2R1) + 1);
        uint40 obsTime = t0 + 10 minutes;
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.NotLastRoundBefore.selector, R1, obsTime));
        recorder.recordFixing(obsTime, R1);
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, P2R1 + 1, obsTime));
        recorder.recordFixing(obsTime, P2R1 + 1);
        recorder.recordFixing(obsTime, P2R1);
        assertEq(recorder.fixingOf(obsTime).price, uint96(uint256(PRICE + 1e8)));
    }

    function _phaseChangeWithoutOverlap() internal {
        feed.pushRound(PRICE); // R1, the old aggregator's last round
        feed.startPhase();
        vm.warp(block.timestamp + 100 hours);
        feed.pushRound(PRICE / 2); // P2R1: a crash, after the fixing time
        vm.warp(block.timestamp + 1);
    }

    // --- the L2 sequencer -----------------------------------------------------------

    /// Nothing is recorded while the uptime feed is not initialized or says down, nor during the
    /// grace after it came back up, up to its last second.
    function test_nothing_is_recorded_while_the_sequencer_is_down_or_just_back() public {
        MockChainlinkFeed uptime = new MockChainlinkFeed("L2 Sequencer Uptime Status Feed");
        FixingsRecorder r = new FixingsRecorder(address(feed), MAX_FIX_AGE, PRICE_MAX, address(uptime), 1 hours);
        assertEq(address(r.sequencer()), address(uptime));
        assertEq(r.SEQUENCER_GRACE(), 1 hours);
        feed.pushRound(PRICE);
        vm.warp(T0 + 1);
        uptime.pushRoundAt(0, 0); // "up", but startedAt 0: not initialized
        vm.expectRevert(L2Sequencer.SequencerDown.selector);
        r.recordFixing(T0, R1);
        uptime.pushRoundAt(1, T0 - 1 days); // down
        vm.expectRevert(L2Sequencer.SequencerDown.selector);
        r.recordFixing(T0, R1);
        uptime.pushRoundAt(0, T0 + 1); // back up now
        vm.expectRevert(abi.encodeWithSelector(L2Sequencer.SequencerGracePeriod.selector, T0 + 1 + 1 hours));
        r.recordFixing(T0, R1);
        vm.warp(T0 + 1 hours);
        vm.expectRevert(abi.encodeWithSelector(L2Sequencer.SequencerGracePeriod.selector, T0 + 1 + 1 hours));
        r.recordFixing(T0, R1);
        vm.warp(T0 + 1 + 1 hours);
        r.recordFixing(T0, R1);
        assertTrue(r.isRecorded(T0));
    }

    // --- mock feed guards -------------------------------------------------------

    function test_mock_feed_guards() public {
        vm.expectRevert(MockChainlinkFeed.NoRounds.selector);
        feed.latestRound();
        vm.expectRevert(abi.encodeWithSelector(MockChainlinkFeed.UnknownRound.selector, R1));
        feed.getRoundData(R1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(MockChainlinkFeed.NotOwner.selector);
        feed.pushRound(PRICE);
        feed.pushRound(PRICE);
        vm.expectRevert(
            abi.encodeWithSelector(
                MockChainlinkFeed.NonMonotonic.selector, uint40(block.timestamp), uint40(block.timestamp)
            )
        );
        feed.pushRoundAt(PRICE, uint40(block.timestamp));
        assertEq(feed.decimals(), 8);
        (uint80 id, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(id, R1);
        assertEq(answer, PRICE);
        assertEq(updatedAt, block.timestamp);
        // phases: round IDs restart in the new phase, the old rounds stay readable
        vm.prank(address(0xBEEF));
        vm.expectRevert(MockChainlinkFeed.NotOwner.selector);
        feed.startPhase();
        feed.startPhase();
        assertEq(feed.phaseId(), 2);
        vm.expectRevert(MockChainlinkFeed.NoRounds.selector);
        feed.latestRound();
        feed.pushRoundAt(PRICE, uint40(block.timestamp) - 1 days); // may predate the old phase's rounds
        assertEq(feed.latestRound(), uint256(P2R1));
        (, answer,, updatedAt,) = feed.getRoundData(R1);
        assertEq(answer, PRICE);
        vm.expectRevert(abi.encodeWithSelector(MockChainlinkFeed.UnknownRound.selector, P2R1 + 1));
        feed.getRoundData(P2R1 + 1);
        vm.expectRevert(abi.encodeWithSelector(MockChainlinkFeed.UnknownRound.selector, uint80(3) << 64 | 1));
        feed.getRoundData(uint80(3) << 64 | 1);
    }
}
