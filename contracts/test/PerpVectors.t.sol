// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PerpBase} from "./PerpBase.t.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {PerpSeries} from "../src/PerpSeries.sol";
import {FixingsRecorder} from "../src/FixingsRecorder.sol";
import {PerpPayout} from "../src/PerpPayout.sol";
import {Vm} from "forge-std/Vm.sol";
import {IPerpSeries, PerpState, PerpTerms, PerpPhase} from "../src/interfaces/IPerpSeries.sol";

/// Payout conformity for the perpetual note: every vector from
/// tools/perp_vectors.py (the scalar Python reference of the normative rule)
/// must match exactly at every fixing, both through the PerpPayout library
/// and through a live series fed by a recorder on the vector's fixing
/// interval, where a holder's claim must equal the indexes times its balance.
/// The vectors: the launch's ETH and BTC terms (daily, k 40% and 50%, R = 0),
/// the weekly product P1 with a coupon reserve, other terms the factory
/// accepts (hourly and daily intervals, R from 0 to its maximum), and the
/// dead-feed close at intervals from an hour to 30 days.
contract PerpVectorsTest is PerpBase {
    using PerpPayout for PerpPayout.Progress;

    uint256 internal constant HELD = 1_234_567_891; // tokens the test holder mints at the first fixing
    uint256 internal constant PARTS = 16;

    struct Vector {
        string tag;
        uint16 ki;
        uint64 meltShare;
        uint64 couponReserve;
        uint32 interval;
        uint96 first;
        uint256[] fixings; // fixing 1, 2, ...; 0 = never recorded
        uint8 phase;
        uint96 referenceFixing;
        uint96 lastFixing;
        bool knockedIn;
        uint16 missedInARow;
        uint32 fixingsDone;
        uint256 notionalPerToken;
        uint256 noteIndex;
        uint256 coverIndex;
        uint256[] noteRelease;
        uint256[] coverRelease;
    }

    function _load() internal view returns (string memory json, uint256 count) {
        json = vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/perp_vectors.json"));
        count = vm.parseJsonUint(json, ".count");
        // the twin closes on the series' dead-feed duration
        assertEq(
            vm.parseJsonUint(json, ".closeAfterDead"), PerpSeries(factory.seriesImplementation()).CLOSE_AFTER_DEAD()
        );
        assertEq(vm.parseJsonUint(json, ".closeAfterDead"), DEAD);
    }

    function _vector(string memory json, uint256 i) internal pure returns (Vector memory v) {
        string memory k = string.concat(".vectors[", vm.toString(i), "]");
        v.tag = vm.parseJsonString(json, string.concat(k, ".tag"));
        v.ki = uint16(vm.parseJsonUint(json, string.concat(k, ".ki")));
        v.meltShare = uint64(vm.parseJsonUint(json, string.concat(k, ".meltShare")));
        v.couponReserve = uint64(vm.parseJsonUint(json, string.concat(k, ".couponReserve")));
        v.interval = uint32(vm.parseJsonUint(json, string.concat(k, ".interval")));
        v.first = uint96(vm.parseJsonUint(json, string.concat(k, ".first")));
        v.fixings = vm.parseJsonUintArray(json, string.concat(k, ".fixings"));
        v.phase = uint8(vm.parseJsonUint(json, string.concat(k, ".phase")));
        v.referenceFixing = uint96(vm.parseJsonUint(json, string.concat(k, ".reference")));
        v.lastFixing = uint96(vm.parseJsonUint(json, string.concat(k, ".lastFixing")));
        v.knockedIn = vm.parseJsonBool(json, string.concat(k, ".knockedIn"));
        v.missedInARow = uint16(vm.parseJsonUint(json, string.concat(k, ".missedInARow")));
        v.fixingsDone = uint32(vm.parseJsonUint(json, string.concat(k, ".fixingsDone")));
        v.notionalPerToken = vm.parseJsonUint(json, string.concat(k, ".notionalPerToken"));
        v.noteIndex = vm.parseJsonUint(json, string.concat(k, ".noteIndex"));
        v.coverIndex = vm.parseJsonUint(json, string.concat(k, ".coverIndex"));
        v.noteRelease = vm.parseJsonUintArray(json, string.concat(k, ".noteRelease"));
        v.coverRelease = vm.parseJsonUintArray(json, string.concat(k, ".coverRelease"));
    }

    function test_vector_file_coverage() public view {
        (string memory json, uint256 count) = _load();
        assertGe(count, 280);
        uint256 closed;
        uint256[3] memory closedAt; // hourly, daily, weekly
        uint256 knockIns;
        uint256[2] memory launch; // ETH and BTC on the launch terms
        uint256 coupon; // a coupon reserve
        uint256 weekly;
        // one column per call (a call per vector and field copies the whole file each time)
        uint256[] memory phase = abi.decode(vm.parseJson(json, ".vectors[*].phase"), (uint256[]));
        bool[] memory knockedIn = abi.decode(vm.parseJson(json, ".vectors[*].knockedIn"), (bool[]));
        uint256[] memory reserve = abi.decode(vm.parseJson(json, ".vectors[*].couponReserve"), (uint256[]));
        uint256[] memory interval = abi.decode(vm.parseJson(json, ".vectors[*].interval"), (uint256[]));
        uint256[] memory melt = abi.decode(vm.parseJson(json, ".vectors[*].meltShare"), (uint256[]));
        uint256[] memory ki = abi.decode(vm.parseJson(json, ".vectors[*].ki"), (uint256[]));
        assertEq(phase.length, count);
        assertEq(ki.length, count);
        for (uint256 i = 0; i < count; i++) {
            if (phase[i] == uint8(PerpPhase.Closed)) {
                closed++;
                if (interval[i] == 1 hours) closedAt[0]++;
                if (interval[i] == DAY) closedAt[1]++;
                if (interval[i] == WEEK) closedAt[2]++;
            }
            if (knockedIn[i]) knockIns++;
            if (reserve[i] != 0) coupon++;
            if (interval[i] == WEEK) weekly++;
            if (interval[i] == DAY && reserve[i] == 0 && melt[i] == MELT) {
                if (ki[i] == KI) launch[0]++;
                if (ki[i] == KI_BTC) launch[1]++;
            }
        }
        assertGt(closed, 0);
        assertGt(closedAt[0], 0);
        assertGt(closedAt[1], 0);
        assertGt(closedAt[2], 0);
        assertGt(knockIns, 0);
        assertGe(launch[0], 50);
        assertGe(launch[1], 50);
        assertGe(coupon, 100);
        assertGe(weekly, 100);
    }

    /// Vectors run in sixteen parts (each test has a gas budget, and reading a vector copies the whole
    /// file once per field; the two ten-year weekly paths are in the tenth, a year of daily fixings for
    /// ETH in the thirteenth, and for BTC in the last with the hourly dead-feed closes).
    function test_vectors_part01() public {
        _replay(0, PARTS);
    }

    function test_vectors_part02() public {
        _replay(1, PARTS);
    }

    function test_vectors_part03() public {
        _replay(2, PARTS);
    }

    function test_vectors_part04() public {
        _replay(3, PARTS);
    }

    function test_vectors_part05() public {
        _replay(4, PARTS);
    }

    function test_vectors_part06() public {
        _replay(5, PARTS);
    }

    function test_vectors_part07() public {
        _replay(6, PARTS);
    }

    function test_vectors_part08() public {
        _replay(7, PARTS);
    }

    function test_vectors_part09() public {
        _replay(8, PARTS);
    }

    function test_vectors_part10() public {
        _replay(9, PARTS);
    }

    function test_vectors_part11() public {
        _replay(10, PARTS);
    }

    function test_vectors_part12() public {
        _replay(11, PARTS);
    }

    function test_vectors_part13() public {
        _replay(12, PARTS);
    }

    function test_vectors_part14() public {
        _replay(13, PARTS);
    }

    function test_vectors_part15() public {
        _replay(14, PARTS);
    }

    function test_vectors_part16() public {
        _replay(15, PARTS);
    }

    function _replay(uint256 part, uint256 parts) internal {
        (string memory json, uint256 count) = _load();
        uint256 to = part + 1 == parts ? count : count * (part + 1) / parts;
        for (uint256 i = count * part / parts; i < to; i++) {
            Vector memory v = _vector(json, i);
            _checkLibrary(v);
            uint256 snap = vm.snapshotState();
            _checkSeries(v);
            vm.revertToState(snap);
        }
    }

    /// Library path: fold the fixings (with the series' missed-fixing rule) through PerpPayout.
    function _checkLibrary(Vector memory v) internal pure {
        PerpPayout.Progress memory p;
        p.strike(v.first);
        uint256 done;
        for (uint256 j = 0; j < v.fixings.length && p.phase != PerpPhase.Closed; j++) {
            bool missed = v.fixings[j] == 0;
            uint96 f = missed ? p.lastFixing : uint96(v.fixings[j]);
            (uint256 n, uint256 w) = p.fix(v.ki, v.meltShare, v.couponReserve, v.interval, uint40(DEAD), f, missed);
            assertEq(n, v.noteRelease[j], v.tag);
            assertEq(w, v.coverRelease[j], v.tag);
            done++;
        }
        assertEq(done, v.fixingsDone, v.tag);
        assertEq(uint8(p.phase), v.phase, v.tag);
        assertEq(p.referenceFixing, v.referenceFixing, v.tag);
        assertEq(p.lastFixing, v.lastFixing, v.tag);
        assertEq(p.knockedIn, v.knockedIn, v.tag);
        assertEq(p.missedInARow, v.missedInARow, v.tag);
        assertEq(p.fixingsDone, v.fixingsDone, v.tag);
        assertEq(p.notionalPerToken, v.notionalPerToken, v.tag);
        assertEq(p.noteIndex, v.noteIndex, v.tag);
        assertEq(p.coverIndex, v.coverIndex, v.tag);
    }

    /// Series path: stage the path on a feed, strike, mint, record the rest, advance.
    function _checkSeries(Vector memory v) internal {
        MockChainlinkFeed f = new MockChainlinkFeed("vector");
        PerpTerms memory t = PerpTerms({
            feed: address(f),
            firstFixing: T0 + 1 hours,
            fixingInterval: v.interval,
            kiBarrierBps: v.ki,
            meltShare: v.meltShare,
            couponReserve: v.couponReserve
        });
        PerpSeries s = PerpSeries(factory.createSeries(t));
        FixingsRecorder r = FixingsRecorder(address(s.recorder()));

        // the first fixing, then a holder mints before anything else happens
        vm.warp(uint256(t.firstFixing) + 1);
        f.pushRoundAt(int256(uint256(v.first)), t.firstFixing);
        r.recordFixing(t.firstFixing, uint80(f.latestRound()));
        uint256 locked = s.previewMint(HELD);
        usdc.mint(alice, locked);
        vm.startPrank(alice);
        usdc.approve(address(s), locked);
        s.mint(HELD, alice);
        vm.stopPrank();

        // stage the rest of the path, then record it after every fallback deadline
        uint80[] memory rounds = new uint80[](v.fixings.length);
        for (uint256 j = 0; j < v.fixings.length; j++) {
            if (v.fixings[j] == 0) continue;
            f.pushRoundAt(int256(v.fixings[j]), _at(t, j + 1));
            rounds[j] = uint80(f.latestRound());
        }
        // at the last fixing's fallback deadline: every fixing of the path is processable, the next one not yet
        vm.warp(uint256(_at(t, v.fixings.length)) + s.FALLBACK_GRACE());
        for (uint256 j = 0; j < v.fixings.length; j++) {
            if (rounds[j] != 0) r.recordFixing(_at(t, j + 1), rounds[j]);
        }

        PerpState memory viewState = s.state(); // replayed, not yet stored
        uint256 claimableBefore = s.claimable(alice);
        vm.recordLogs();
        PerpState memory st = s.advance();
        _checkEvents(v, address(s));
        assertEq(keccak256(abi.encode(viewState)), keccak256(abi.encode(st)), v.tag);
        assertEq(uint8(st.phase), v.phase, v.tag);
        assertEq(st.referenceFixing, v.referenceFixing, v.tag);
        assertEq(st.lastFixing, v.lastFixing, v.tag);
        assertEq(st.knockedIn, v.knockedIn, v.tag);
        assertEq(st.missedInARow, v.missedInARow, v.tag);
        assertEq(st.fixingsDone, v.fixingsDone, v.tag);
        assertEq(st.notionalPerToken, v.notionalPerToken, v.tag);
        assertEq(st.noteIndex, v.noteIndex, v.tag);
        assertEq(st.coverIndex, v.coverIndex, v.tag);

        // the holder's claim is the indexes times its balance, and the escrow covers it
        // together with the pair value still locked
        uint256 owed = HELD * v.noteIndex / RAY + HELD * v.coverIndex / RAY;
        assertEq(claimableBefore, owed, v.tag);
        assertEq(s.claimable(alice), owed, v.tag);
        assertGe(usdc.balanceOf(address(s)), owed + s.previewRedeemPair(HELD), v.tag);
        // the rounding left behind is below one base unit per rounding step (mint, two legs, pair)
        assertLe(usdc.balanceOf(address(s)) - owed - s.previewRedeemPair(HELD), 3, v.tag);

        vm.startPrank(alice);
        assertEq(s.claim(bob), owed, v.tag);
        uint256 pair = s.redeemPair(HELD, bob);
        vm.stopPrank();
        assertEq(usdc.balanceOf(bob), owed + pair, v.tag);
        if (v.phase == uint8(PerpPhase.Closed)) assertEq(pair, 0, v.tag);
    }

    function _checkEvents(Vector memory v, address series) internal view {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 found;
        uint256 closed;
        for (uint256 k = 0; k < logs.length; k++) {
            if (logs[k].emitter != series) continue;
            if (logs[k].topics[0] == IPerpSeries.Closed.selector) closed++;
            if (logs[k].topics[0] != IPerpSeries.FixingProcessed.selector) continue;
            (,,,, bool missed,, uint256 noteRelease, uint256 coverRelease) =
                abi.decode(logs[k].data, (uint40, uint96, uint96, bool, bool, uint256, uint256, uint256));
            assertEq(uint256(logs[k].topics[1]), found + 1, v.tag);
            assertEq(missed, v.fixings[found] == 0, v.tag);
            assertEq(noteRelease, v.noteRelease[found], v.tag);
            assertEq(coverRelease, v.coverRelease[found], v.tag);
            found++;
        }
        assertEq(found, v.fixingsDone, v.tag);
        assertEq(closed, v.phase == uint8(PerpPhase.Closed) ? 1 : 0, v.tag);
    }

    function _at(PerpTerms memory t, uint256 n) internal pure returns (uint40) {
        return uint40(uint256(t.firstFixing) + n * t.fixingInterval);
    }
}
