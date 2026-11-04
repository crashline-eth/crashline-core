// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {PerpBase} from "./PerpBase.t.sol";
import {MockPerpPricer} from "./mocks/MockPerpPricer.sol";
import {PerpQuoter} from "../src/PerpQuoter.sol";
import {PerpSeries} from "../src/PerpSeries.sol";
import {PerpFormula} from "../src/PerpFormula.sol";
import {PerpFormulaPricer} from "../src/PerpFormulaPricer.sol";
import {L2Sequencer} from "../src/L2Sequencer.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {IPerpQuoter, PerpQuote} from "../src/interfaces/IPerpQuoter.sol";
import {PerpTerms} from "../src/interfaces/IPerpSeries.sol";
import {IPerpPricer, LineBands, PerpPricerInputs, PerpProduct} from "../src/interfaces/IPerpPricer.sol";

/// The quoter on the launch terms (an ETH series and the launch's ETH pricer), its
/// conformity vectors for both launch pricers (across their vol and carry ranges) and for
/// the weekly P1 world, and the coupon path on a weekly series with a coupon reserve. The
/// caller's carry is CARRY (4%) unless a test says otherwise.
contract PerpQuoterTest is PerpBase {
    uint16 constant VOL = 7000;
    PerpQuoter quoter;
    MockPerpPricer pricer;
    PerpFormulaPricer formulaPricer;
    PerpSeries s;
    uint40 first;

    function setUp() public override {
        super.setUp();
        quoter = new PerpQuoter(STALENESS, address(sequencer), GRACE);
        pricer = new MockPerpPricer();
        formulaPricer = new PerpFormulaPricer(_product(), _bands());
        first = T0 + 1 hours;
        s = _create(_terms(first));
    }

    struct Vector {
        string label;
        uint96 first;
        uint256 referenceFixing;
        uint256 spot;
        uint256 fixingsDone;
        bool knockedIn;
        uint256 secsSinceFixing;
        uint16 vol;
        int16 carry;
        uint64 couponReserve;
        uint256 result;
        uint256 a;
        int256 b;
    }

    /// First fixing at `first`; then `done` fixings: the reference (when it is above the
    /// first fixing, the ratchet) at fixing 1, 30% of it at fixing 2 when knocked in (below
    /// every crash line the vectors use), 80% of it otherwise; then `now` = last fixing +
    /// secsSinceFixing with a fresh round at `spot`.
    function _stage(PerpSeries series, Vector memory v) internal {
        uint40 t0 = series.terms().firstFixing;
        uint256 interval = series.terms().fixingInterval;
        _fixAt(series, t0, int256(uint256(v.first)));
        bool ratchet = v.referenceFixing > v.first;
        for (uint256 n = 1; n <= v.fixingsDone; n++) {
            uint256 price = v.referenceFixing * 8000 / 10_000;
            if (ratchet && n == 1) price = v.referenceFixing;
            else if (v.knockedIn && n == 2) price = v.referenceFixing * 3000 / 10_000;
            _fixAt(series, uint40(t0 + n * interval), int256(price));
        }
        vm.warp(uint256(t0) + v.fixingsDone * interval + v.secsSinceFixing);
        feed.pushRoundAt(int256(v.spot), uint40(block.timestamp));
        assertEq(series.state().knockedIn, v.knockedIn, v.label);
        assertEq(series.state().referenceFixing, v.referenceFixing, v.label);
    }

    function _inputs(int256[] memory v) internal pure returns (PerpPricerInputs memory in_) {
        in_.spotBpsOfReference = uint16(uint256(v[0]));
        in_.volBpsAnnual = uint16(uint256(v[1]));
        in_.timeToNextFixingSecs = uint32(uint256(v[2]));
        in_.carryBpsAnnual = int16(v[3]);
        in_.flags = uint8(uint256(v[4]));
    }

    // --- conformity with the quoter's Python twin (test/vectors/perp_quoter_vectors*.json) ---

    /// The launch's ETH pricer: PerpFormulaPricer itself (the fixing accrual, its vol and carry
    /// ranges and its two bands), daily fixings, k 40%, over spots, vols, carries, times of day and
    /// both states. In eighths (each test has a gas budget of 2^30, and coverage runs unoptimized).
    function test_quoter_vectors_eth_part1() public {
        _quoterVectors("perp_quoter_vectors_eth.json", true, 0, 8);
    }

    function test_quoter_vectors_eth_part2() public {
        _quoterVectors("perp_quoter_vectors_eth.json", true, 1, 8);
    }

    function test_quoter_vectors_eth_part3() public {
        _quoterVectors("perp_quoter_vectors_eth.json", true, 2, 8);
    }

    function test_quoter_vectors_eth_part4() public {
        _quoterVectors("perp_quoter_vectors_eth.json", true, 3, 8);
    }

    function test_quoter_vectors_eth_part5() public {
        _quoterVectors("perp_quoter_vectors_eth.json", true, 4, 8);
    }

    function test_quoter_vectors_eth_part6() public {
        _quoterVectors("perp_quoter_vectors_eth.json", true, 5, 8);
    }

    function test_quoter_vectors_eth_part7() public {
        _quoterVectors("perp_quoter_vectors_eth.json", true, 6, 8);
    }

    function test_quoter_vectors_eth_part8() public {
        _quoterVectors("perp_quoter_vectors_eth.json", true, 7, 8);
    }

    /// The launch's BTC pricer: k 50%, vol 21-120%, carry -20% to +50%.
    function test_quoter_vectors_btc_part1() public {
        _quoterVectors("perp_quoter_vectors_btc.json", true, 0, 8);
    }

    function test_quoter_vectors_btc_part2() public {
        _quoterVectors("perp_quoter_vectors_btc.json", true, 1, 8);
    }

    function test_quoter_vectors_btc_part3() public {
        _quoterVectors("perp_quoter_vectors_btc.json", true, 2, 8);
    }

    function test_quoter_vectors_btc_part4() public {
        _quoterVectors("perp_quoter_vectors_btc.json", true, 3, 8);
    }

    function test_quoter_vectors_btc_part5() public {
        _quoterVectors("perp_quoter_vectors_btc.json", true, 4, 8);
    }

    function test_quoter_vectors_btc_part6() public {
        _quoterVectors("perp_quoter_vectors_btc.json", true, 5, 8);
    }

    function test_quoter_vectors_btc_part7() public {
        _quoterVectors("perp_quoter_vectors_btc.json", true, 6, 8);
    }

    function test_quoter_vectors_btc_part8() public {
        _quoterVectors("perp_quoter_vectors_btc.json", true, 7, 8);
    }

    /// A formula-only pricer for P1's weekly world with a coupon reserve, at P1's carry (4%).
    function test_quoter_vectors_formula_weekly() public {
        _quoterVectors("perp_quoter_vectors.json", true, 0, 1);
    }

    /// The synthetic model (synthetic-p, vectors from its export), on P1's product: a
    /// featureSpecVersion 2 student kept as a fixture of the quoter's assembly (its correction is
    /// replayed by the mock; the quoter's inputs are featureSpecVersion 3's, carry 4%).
    function test_quoter_vectors_synthetic() public {
        _quoterVectors("perp_quoter_vectors_synthetic.json", false, 0, 1);
    }

    /// P1, the stock student (after the audit a crypto student replaces it); skipped until its vectors exist.
    function test_quoter_vectors_p1() public {
        if (!vm.exists(string.concat(vm.projectRoot(), "/test/vectors/perp_quoter_vectors_p1.json"))) {
            vm.skip(true);
            return;
        }
        _quoterVectors("perp_quoter_vectors_p1.json", false, 0, 1);
    }

    /// The vector files of the launch pricers are for exactly the launch's products and bands.
    function test_quoter_vector_files_are_the_launch_pricers() public view {
        string memory json = _read("perp_quoter_vectors_eth.json");
        assertEq(keccak256(abi.encode(_jsonProduct(json))), keccak256(abi.encode(_product())));
        assertEq(keccak256(abi.encode(_jsonBands(json))), keccak256(abi.encode(_bands())));
        json = _read("perp_quoter_vectors_btc.json");
        assertEq(keccak256(abi.encode(_jsonProduct(json))), keccak256(abi.encode(_btcProduct())));
        assertEq(keccak256(abi.encode(_jsonBands(json))), keccak256(abi.encode(_btcBands())));
        json = _read("perp_quoter_vectors.json");
        assertEq(keccak256(abi.encode(_jsonProduct(json))), keccak256(abi.encode(_weeklyCouponProduct())));
        assertEq(keccak256(abi.encode(_jsonBands(json))), keccak256(abi.encode(_weeklyBands())));
    }

    function _read(string memory file) internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/", file));
    }

    function _jsonProduct(string memory json) internal pure returns (PerpProduct memory p) {
        p.kiBarrierBps = uint16(vm.parseJsonUint(json, ".product.kiBarrierBps"));
        p.meltShare = uint64(vm.parseJsonUint(json, ".product.meltShareWad"));
        p.fixingInterval = uint32(vm.parseJsonUint(json, ".product.fixingIntervalSecs"));
        p.discountBps = int16(vm.parseJsonInt(json, ".product.discountBps"));
    }

    function _jsonBands(string memory json) internal pure returns (PerpFormulaPricer.Bands memory b) {
        b.fixingBandSecs = uint32(vm.parseJsonUint(json, ".bands.fixingBandSecs"));
        b.knockInBelowBps = uint16(vm.parseJsonUint(json, ".bands.knockInBelowBps"));
        b.knockInAboveBps = uint16(vm.parseJsonUint(json, ".bands.knockInAboveBps"));
        b.healBandBps = uint16(vm.parseJsonUint(json, ".bands.healBandBps"));
        b.stripBelowBps = uint16(vm.parseJsonUint(json, ".bands.stripBelowBps"));
        b.stripAboveBps = uint16(vm.parseJsonUint(json, ".bands.stripAboveBps"));
        b.buyBackDiscountBps = uint16(vm.parseJsonUint(json, ".bands.buyBackDiscountBps"));
        b.discountReachBps = uint16(vm.parseJsonUint(json, ".bands.discountReachBps"));
        b.minVolBandBps = uint16(vm.parseJsonUint(json, ".bands.minVolBandBps"));
        b.volMinBps = uint16(vm.parseJsonUint(json, ".bands.volMinBps"));
        b.volMaxBps = uint16(vm.parseJsonUint(json, ".bands.volMaxBps"));
        b.carryMinBps = int16(vm.parseJsonInt(json, ".bands.carryMinBps"));
        b.carryMaxBps = int16(vm.parseJsonInt(json, ".bands.carryMaxBps"));
    }

    /// Part `part` of `parts` of a vector file (each test has a gas budget).
    function _quoterVectors(string memory file, bool formulaOnly, uint256 part, uint256 parts) internal {
        string memory json = _read(file);
        uint256 count = vm.parseJsonUint(json, ".count");
        assertGe(count, 50);
        PerpProduct memory product = _jsonProduct(json);
        IPerpPricer p;
        if (formulaOnly) {
            p = new PerpFormulaPricer(product, _jsonBands(json));
        } else {
            pricer.setProduct(product);
            pricer.setWeightsHash(vm.parseJsonBytes32(json, ".weightsHash"));
            // the mock replays the student's answers (its refusals included): its own ranges are open
            pricer.setRange(1, 0, type(int64).max);
            pricer.setRange(3, type(int64).min, type(int64).max);
            p = pricer;
        }
        uint256 to = part + 1 == parts ? count : count * (part + 1) / parts;
        for (uint256 i = count * part / parts; i < to; i++) {
            uint256 snap = vm.snapshotState();
            _quoterVector(json, string.concat(".vectors[", vm.toString(i), "]"), p, formulaOnly, product);
            vm.revertToState(snap);
        }
    }

    function _load(string memory json, string memory k) internal pure returns (Vector memory v) {
        v.label = vm.parseJsonString(json, string.concat(k, ".label"));
        v.first = uint96(vm.parseJsonUint(json, string.concat(k, ".first")));
        v.referenceFixing = vm.parseJsonUint(json, string.concat(k, ".reference"));
        v.spot = vm.parseJsonUint(json, string.concat(k, ".spot"));
        v.fixingsDone = vm.parseJsonUint(json, string.concat(k, ".fixingsDone"));
        v.knockedIn = vm.parseJsonUint(json, string.concat(k, ".knockedIn")) == 1;
        v.secsSinceFixing = vm.parseJsonUint(json, string.concat(k, ".secsSinceFixing"));
        v.vol = uint16(vm.parseJsonUint(json, string.concat(k, ".vol")));
        v.carry = int16(vm.parseJsonInt(json, string.concat(k, ".carry")));
        v.couponReserve = uint64(vm.parseJsonUint(json, string.concat(k, ".couponReserve")));
        v.result = vm.parseJsonUint(json, string.concat(k, ".result"));
        v.a = vm.parseJsonUint(json, string.concat(k, ".a"));
        v.b = vm.parseJsonInt(json, string.concat(k, ".b"));
    }

    function _quoterVector(
        string memory json,
        string memory k,
        IPerpPricer p,
        bool formulaOnly,
        PerpProduct memory product
    ) internal {
        Vector memory v = _load(json, k);
        PerpSeries series = _create(
            PerpTerms({
                feed: address(feed),
                firstFixing: first,
                fixingInterval: product.fixingInterval,
                kiBarrierBps: product.kiBarrierBps,
                meltShare: product.meltShare,
                couponReserve: v.couponReserve
            })
        );
        _stage(series, v);

        int256[] memory raw = vm.parseJsonIntArray(json, string.concat(k, ".inputs"));
        if (raw.length == 0) {
            // the spot doesn't fit the struct: the quoter refuses before any model is asked
            vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(0), int64(v.b)));
            quoter.quote(series, p, v.vol, v.carry);
            return;
        }
        PerpPricerInputs memory want = _inputs(raw);
        PerpPricerInputs memory got = quoter.inputs(series, v.vol, v.carry);
        assertEq(keccak256(abi.encode(got)), keccak256(abi.encode(want)), v.label);

        if (formulaOnly) {
            // the real PerpFormulaPricer refuses by itself
            if (v.result == 1) {
                vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(v.a), int64(v.b)));
                quoter.quote(series, p, v.vol, v.carry);
                return;
            }
            if (v.result == 3) {
                vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(v.a)));
                quoter.quote(series, p, v.vol, v.carry);
                return;
            }
        } else {
            pricer.expect(keccak256(abi.encode(want)));
            if (v.result == 0) {
                pricer.setCorrection(int16(vm.parseJsonInt(json, string.concat(k, ".correctionBps"))));
            } else if (v.result == 1) {
                pricer.setRefusal(MockPerpPricer.Mode.OutOfRangeErr, uint8(v.a), int64(v.b));
                vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(v.a), int64(v.b)));
                quoter.quote(series, p, v.vol, v.carry);
                return;
            } else {
                pricer.setRefusal(MockPerpPricer.Mode.UncertifiedErr, uint8(v.a), 0);
                vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(v.a)));
                quoter.quote(series, p, v.vol, v.carry);
                return;
            }
        }
        assertEq(v.result, 0, v.label);
        _checkQuote(json, k, series, p, v);
    }

    function _checkQuote(string memory json, string memory k, PerpSeries series, IPerpPricer p, Vector memory v)
        internal
        view
    {
        PerpQuote memory q = quoter.quote(series, p, v.vol, v.carry);
        assertEq(q.formulaBps, vm.parseJsonUint(json, string.concat(k, ".formulaBps")), v.label);
        assertEq(q.correctionBps, vm.parseJsonInt(json, string.concat(k, ".correctionBps")), v.label);
        assertEq(q.couponBps, vm.parseJsonUint(json, string.concat(k, ".couponBps")), v.label);
        assertEq(q.priceBps, vm.parseJsonUint(json, string.concat(k, ".priceBps")), v.label);
        assertEq(q.weightsHash, p.weightsHash(), v.label);
        (uint16 priceBps, bytes32 hash) = quoter.notePriceBps(series, p, v.vol, v.carry);
        assertEq(priceBps, q.priceBps, v.label);
        assertEq(hash, q.weightsHash, v.label);
        // the same quote from a spot the caller supplies
        PerpQuote memory atSpot = quoter.quoteAtSpot(series, p, v.vol, v.carry, v.spot);
        assertEq(keccak256(abi.encode(atSpot)), keccak256(abi.encode(q)), v.label);
    }

    // --- refusals ---------------------------------------------------------------------

    /// Live a quarter of a day after fixing 1 (90%), spot at `spotBps`.
    function _live(uint256 spotBps) internal {
        _fix(s, 0, 10000);
        _fix(s, 1, 9000);
        vm.warp(uint256(first) + DAY + 6 hours);
        feed.pushRound(_price(spotBps));
    }

    /// A fresh round one second later.
    function _spotLater(uint256 spotBps) internal {
        vm.warp(block.timestamp + 1);
        feed.pushRound(_price(spotBps));
    }

    function test_not_live_while_pending_and_after_close() public {
        vm.expectRevert(IPerpQuoter.NotLive.selector);
        quoter.quote(s, pricer, VOL, CARRY);
        _fix(s, 0, 10000);
        // fixings 1..14 missed, 14 days of a dead feed: closed
        vm.warp(uint256(first) + 14 * DAY + FALLBACK);
        feed.pushRound(_price(9000));
        vm.expectRevert(IPerpQuoter.NotLive.selector);
        quoter.quote(s, pricer, VOL, CARRY);
    }

    function test_fixing_pending_refuses() public {
        _live(9000);
        vm.warp(uint256(first) + 2 * DAY); // exactly at fixing 2: still quotable, tNext = 0
        feed.pushRound(_price(9000));
        assertEq(quoter.inputs(s, VOL, CARRY).timeToNextFixingSecs, 0);
        vm.warp(uint256(first) + 2 * DAY + 1);
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.FixingPending.selector, first + 2 * DAY));
        quoter.quote(s, pricer, VOL, CARRY);
        // recorded (the round pushed at the fixing time is the fixing): quotable again, one fixing later
        _recorder(s).recordFixing(first + 2 * DAY, uint80(feed.latestRound()));
        assertEq(quoter.inputs(s, VOL, CARRY).timeToNextFixingSecs, DAY - 1);
        assertEq(s.state().fixingsDone, 2);
    }

    /// Arbitrum down from 08:00:30 to 13:30 and nobody recorded fixing 2: the recorder takes it
    /// from 14:30 and the series falls back at 20:30 (#44). In between the quoter's sequencer check
    /// passes, but the fixing is pending, so nothing is quoted.
    function test_fixing_pending_while_the_fallback_waits_for_the_sequencer() public {
        _live(9000);
        uint40 t2 = first + 2 * DAY;
        vm.warp(uint256(t2) + 30 seconds);
        sequencer.pushRound(1);
        vm.warp(uint256(t2) + 5 hours + 30 minutes);
        sequencer.pushRound(0);
        uint256 fallsBack = uint256(t2) + 12 hours + 30 minutes;
        vm.warp(uint256(t2) + 6 hours + 30 minutes); // the grace is over, the plain deadline past
        feed.pushRound(_price(9000));
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.FixingPending.selector, t2));
        quoter.quote(s, pricer, VOL, CARRY);
        vm.warp(fallsBack - 1);
        feed.pushRound(_price(9000));
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.FixingPending.selector, t2));
        quoter.quote(s, pricer, VOL, CARRY);
        // the fallback: quotable again, one fixing later
        vm.warp(fallsBack);
        feed.pushRound(_price(9000));
        assertEq(quoter.inputs(s, VOL, CARRY).timeToNextFixingSecs, DAY - 12 hours - 30 minutes);
        assertEq(s.state().missedInARow, 1);
    }

    function test_sequencer_down_or_just_back_refuses_quotes() public {
        _live(9000);
        quoter.quote(s, pricer, VOL, CARRY);
        // the sequencer goes down: the feed's last price still looks fresh, but nothing is quoted
        sequencer.pushRound(1);
        vm.expectRevert(L2Sequencer.SequencerDown.selector);
        quoter.quote(s, pricer, VOL, CARRY);
        vm.expectRevert(L2Sequencer.SequencerDown.selector);
        quoter.spot(s);
        // back up: nothing for the grace period, while the queued transactions land
        vm.warp(block.timestamp + 10 minutes);
        sequencer.pushRound(0);
        feed.pushRound(_price(9000));
        uint256 until = block.timestamp + GRACE;
        vm.expectRevert(abi.encodeWithSelector(L2Sequencer.SequencerGracePeriod.selector, until));
        quoter.quote(s, pricer, VOL, CARRY);
        vm.warp(until - 1);
        feed.pushRound(_price(9000));
        vm.expectRevert(abi.encodeWithSelector(L2Sequencer.SequencerGracePeriod.selector, until));
        quoter.quote(s, pricer, VOL, CARRY);
        vm.warp(until);
        quoter.quote(s, pricer, VOL, CARRY);
        assertEq(address(quoter.sequencer()), address(sequencer));
        assertEq(quoter.SEQUENCER_GRACE(), GRACE);
    }

    function test_uninitialized_sequencer_feed_counts_as_down_and_none_means_no_check() public {
        _live(9000);
        MockChainlinkFeed blank = new MockChainlinkFeed("uptime");
        blank.pushRoundAt(0, 0); // startedAt 0: not initialized (Chainlink's docs)
        PerpQuoter q = new PerpQuoter(STALENESS, address(blank), GRACE);
        vm.expectRevert(L2Sequencer.SequencerDown.selector);
        q.quote(s, pricer, VOL, CARRY);
        // no uptime feed (Arbitrum Sepolia, a dev node): no check
        sequencer.pushRound(1);
        new PerpQuoter(STALENESS, address(0), 0).quote(s, pricer, VOL, CARRY);
    }

    function test_stale_feed_refuses_but_a_supplied_spot_quotes() public {
        _live(9000);
        uint256 updatedAt = block.timestamp;
        vm.warp(block.timestamp + STALENESS); // exactly at the limit: fresh
        quoter.quote(s, pricer, VOL, CARRY);
        vm.warp(block.timestamp + 1);
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.FeedStale.selector, uint40(updatedAt)));
        quoter.quote(s, pricer, VOL, CARRY);
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.FeedStale.selector, uint40(updatedAt)));
        quoter.spot(s);
        // the feed is not read here: the caller vouches for the spot
        PerpQuote memory q = quoter.quoteAtSpot(s, pricer, VOL, CARRY, uint256(_price(9000)));
        assertGt(q.priceBps, 0);
        vm.expectRevert(IPerpQuoter.BadFeedAnswer.selector);
        quoter.quoteAtSpot(s, pricer, VOL, CARRY, 0);
    }

    function test_bad_feed_answer_refuses() public {
        _live(9000);
        vm.warp(block.timestamp + 1);
        feed.pushRound(0);
        vm.expectRevert(IPerpQuoter.BadFeedAnswer.selector);
        quoter.quote(s, pricer, VOL, CARRY);
    }

    /// featureSpecVersion 3: field 3 is the caller's carry, passed as it is (any int16), and the
    /// closed form's r; the other fields keep their indexes.
    function test_carry_is_an_input() public {
        _live(9000);
        PerpPricerInputs memory in_ = quoter.inputs(s, VOL, -2000);
        assertEq(in_.carryBpsAnnual, -2000);
        assertEq(in_.volBpsAnnual, VOL);
        assertEq(in_.spotBpsOfReference, 9000);
        assertEq(in_.timeToNextFixingSecs, 18 hours);
        assertEq(quoter.inputs(s, VOL, type(int16).min).carryBpsAnnual, type(int16).min);
        assertEq(quoter.inputs(s, VOL, type(int16).max).carryBpsAnnual, type(int16).max);
        // a model refuses a carry outside its certified range, by itself
        assertEq(pricer.featureSpecVersion(), 3);
        (int64 lo, int64 hi) = pricer.certifiedRange(3);
        assertEq(lo, CARRY_MIN);
        assertEq(hi, CARRY_MAX);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(3), int64(CARRY_MAX + 1)));
        quoter.quote(s, pricer, VOL, CARRY_MAX + 1);
        // the model sees exactly that carry
        pricer.setRange(3, type(int16).min, type(int16).max);
        pricer.expect(keccak256(abi.encode(quoter.inputs(s, VOL, 2000))));
        quoter.quote(s, pricer, VOL, 2000);
        pricer.expect(bytes32(0));
        // a higher carry: the spot drifts up, away from the crash line, and "pays x" is worth more
        uint256 low = quoter.quote(s, formulaPricer, VOL, -2000).formulaBps;
        uint256 mid = quoter.quote(s, formulaPricer, VOL, 0).formulaBps;
        uint256 high = quoter.quote(s, formulaPricer, VOL, 5000).formulaBps;
        assertLt(low, mid);
        assertLt(mid, high);
        // the same carry through every entry point
        PerpQuote memory q = quoter.quote(s, formulaPricer, VOL, 2000);
        (uint16 priceBps,) = quoter.notePriceBps(s, formulaPricer, VOL, 2000);
        assertEq(priceBps, q.priceBps);
        PerpQuote memory atSpot = quoter.quoteAtSpot(s, formulaPricer, VOL, 2000, uint256(_price(9000)));
        assertEq(keccak256(abi.encode(atSpot)), keccak256(abi.encode(q)));
        assertTrue(q.priceBps != quoter.quote(s, formulaPricer, VOL, CARRY).priceBps);
    }

    function test_series_must_be_the_models_product() public {
        _live(9000);
        PerpProduct memory p = pricer.product();
        p.kiBarrierBps = KI_BTC;
        pricer.setProduct(p);
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.ProductMismatch.selector, uint8(0)));
        quoter.quote(s, pricer, VOL, CARRY);
        p.kiBarrierBps = KI;
        p.meltShare += 1;
        pricer.setProduct(p);
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.ProductMismatch.selector, uint8(1)));
        quoter.quote(s, pricer, VOL, CARRY);
        p.meltShare -= 1;
        p.fixingInterval = WEEK;
        pricer.setProduct(p);
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.ProductMismatch.selector, uint8(2)));
        quoter.quote(s, pricer, VOL, CARRY);
        // the launch's BTC pricer does not price an ETH series
        PerpFormulaPricer btc = new PerpFormulaPricer(_btcProduct(), _btcBands());
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.ProductMismatch.selector, uint8(0)));
        quoter.quote(s, btc, 4500, CARRY);
    }

    function test_model_refusals_and_formula_refusals_bubble_up() public {
        _live(9000);
        pricer.setRefusal(MockPerpPricer.Mode.UncertifiedErr, 1, 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(1)));
        quoter.quote(s, pricer, VOL, CARRY);
        pricer.setRefusal(MockPerpPricer.Mode.OutOfRangeErr, 1, 99);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(1), int64(99)));
        quoter.quote(s, pricer, VOL, CARRY);
        // a model that accepts a vol the closed form can't carry: the formula refuses
        pricer.setCorrection(0);
        pricer.setRange(1, 0, 15_000);
        vm.expectRevert(abi.encodeWithSelector(PerpFormula.VolOutOfRange.selector, uint256(0.05e18)));
        quoter.quote(s, pricer, 500, CARRY);
        // the formula-only pricer is built for a vol range the formula carries, and refuses outside it
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(1), int64(500)));
        quoter.quote(s, formulaPricer, 500, CARRY);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(1), int64(15_001)));
        quoter.quote(s, formulaPricer, 15_001, CARRY);
    }

    // --- assembly ---------------------------------------------------------------------

    function test_quote_parts_add_up_and_floor_at_zero() public {
        _live(9000);
        PerpQuote memory base = quoter.quote(s, formulaPricer, VOL, CARRY);
        // a quarter of the day since the fixing: the accrual is a * 1/4 * (1 - formula), a clean note
        int256 accrual =
            int256(uint256(MELT) * 6 hours) * (10_000 - int256(uint256(base.formulaBps))) / int256(WAD * uint256(DAY));
        assertGt(accrual, 0);
        assertEq(base.correctionBps, accrual);
        assertEq(base.couponBps, 0); // no coupon reserve
        assertEq(base.priceBps, uint256(int256(uint256(base.formulaBps)) + accrual));
        assertEq(base.weightsHash, formulaPricer.weightsHash());

        pricer.setCorrection(-37);
        PerpQuote memory q = quoter.quote(s, pricer, VOL, CARRY);
        assertEq(q.formulaBps, base.formulaBps);
        assertEq(q.correctionBps, -37);
        assertEq(q.priceBps, base.formulaBps - 37);

        // a correction below minus the formula: the price floors at 0
        pricer.setCorrection(-30000);
        q = quoter.quote(s, pricer, VOL, CARRY);
        assertEq(q.priceBps, 0);
    }

    /// The launch's reference points (docs/v2-spec.md §1): at the high, carry 4% (CARRY), the closed
    /// form is about 7,900 bps for ETH at 70% vol and about 8,840 for BTC at 45%.
    function test_launch_prices_at_the_high() public {
        _fix(s, 0, 10000);
        vm.warp(uint256(first) + 1);
        feed.pushRound(_price(10000));
        assertEq(quoter.quote(s, formulaPricer, 7000, CARRY).formulaBps, 7904);
        MockChainlinkFeed btc = new MockChainlinkFeed("BTC / USD");
        PerpSeries b = _create(_btcTerms(address(btc), first));
        btc.pushRoundAt(81_439_17_000_000, first);
        _recorder(b).recordFixing(first, uint80(btc.latestRound()));
        btc.pushRound(81_439_17_000_000);
        assertEq(quoter.quote(b, new PerpFormulaPricer(_btcProduct(), _btcBands()), 4500, CARRY).formulaBps, 8841);
    }

    function test_formula_pricer_views() public view {
        assertEq(formulaPricer.featureSpecVersion(), 3);
        (int64 lo, int64 hi) = formulaPricer.certifiedRange(1);
        assertEq(lo, 2400);
        assertEq(hi, 15_000);
        (lo, hi) = formulaPricer.certifiedRange(0);
        assertEq(hi, 65535);
        (lo, hi) = formulaPricer.certifiedRange(2);
        assertEq(hi, int64(uint64(DAY)));
        (lo, hi) = formulaPricer.certifiedRange(3); // the carry range
        assertEq(lo, -2000);
        assertEq(hi, 5000);
        (lo, hi) = formulaPricer.certifiedRange(4);
        assertEq(hi, 1);
        PerpProduct memory p = formulaPricer.product();
        assertEq(p.kiBarrierBps, KI);
        assertEq(p.meltShare, MELT);
        assertEq(p.fixingInterval, DAY);
        assertEq(p.discountBps, 0);
        assertEq(formulaPricer.weightsHash(), keccak256(abi.encode("PerpFormulaPricer", p, _bands())));
        assertEq(formulaPricer.bands().fixingBandSecs, 2 hours);
        assertEq(formulaPricer.bands().carryMinBps, -2000);
        assertEq(formulaPricer.bands().carryMaxBps, 5000);
        assertEq(formulaPricer.bands().knockInBelowBps, 200);
        assertEq(formulaPricer.bands().knockInAboveBps, 1000);
        // the Desk's lines (IPerpPricer.lineBands): the heal band, the strip, the discount, the vol band
        LineBands memory lb = formulaPricer.lineBands();
        assertEq(lb.healBandBps, 500);
        assertEq(lb.stripBelowBps, 200);
        assertEq(lb.stripAboveBps, 100);
        assertEq(lb.buyBackDiscountBps, 300);
        assertEq(lb.discountReachBps, 2000);
        assertEq(lb.minVolBandBps, 200);
    }

    /// The strip lies inside the crash line's band on each side (BadBands otherwise): below the
    /// line at most knockInBelowBps (200 at launch, the strip's own), above it at most
    /// knockInAboveBps (1,000); its edges may reach the band's. The hash covers the strip and both
    /// widths of the band.
    function test_formula_pricer_strip_inside_the_knock_in_band() public {
        PerpFormulaPricer.Bands memory b = _bands();
        b.stripBelowBps = 201;
        vm.expectRevert(PerpFormulaPricer.BadBands.selector);
        new PerpFormulaPricer(_product(), b);
        b.knockInBelowBps = 201;
        new PerpFormulaPricer(_product(), b);
        b = _bands();
        b.stripAboveBps = 1001;
        vm.expectRevert(PerpFormulaPricer.BadBands.selector);
        new PerpFormulaPricer(_product(), b);
        b.knockInAboveBps = 1001;
        new PerpFormulaPricer(_product(), b);
        // per side: the strip may reach the band's edges, 200 below and 1,000 above, not the mirror
        b = _bands();
        b.stripAboveBps = 1000;
        LineBands memory lb = new PerpFormulaPricer(_product(), b).lineBands();
        assertEq(lb.stripBelowBps, 200);
        assertEq(lb.stripAboveBps, 1000);
        (b.knockInBelowBps, b.knockInAboveBps) = (1000, 200);
        vm.expectRevert(PerpFormulaPricer.BadBands.selector);
        new PerpFormulaPricer(_product(), b);
        b = _bands();
        b.stripAboveBps = 99;
        assertTrue(new PerpFormulaPricer(_product(), b).weightsHash() != formulaPricer.weightsHash());
        b = _bands();
        b.knockInBelowBps = 201;
        assertTrue(new PerpFormulaPricer(_product(), b).weightsHash() != formulaPricer.weightsHash());
        b = _bands();
        b.knockInAboveBps = 999;
        assertTrue(new PerpFormulaPricer(_product(), b).weightsHash() != formulaPricer.weightsHash());
    }

    /// The buy-back discount's numbers (BadBands otherwise): the discount at most
    /// MAX_BUY_BACK_DISCOUNT_BPS (1,000), and with a discount its reach beyond the strip (2,000 > 100
    /// at launch; 101 is the least) and a minimum vol band of at least 1 (without a discount, any
    /// reach and any minimum). All three are in the hash.
    function test_formula_pricer_checks_the_discount() public {
        assertEq(formulaPricer.MAX_BUY_BACK_DISCOUNT_BPS(), 1000);
        PerpFormulaPricer.Bands memory b = _bands();
        b.discountReachBps = 100;
        vm.expectRevert(PerpFormulaPricer.BadBands.selector);
        new PerpFormulaPricer(_product(), b);
        b.discountReachBps = 101;
        assertEq(new PerpFormulaPricer(_product(), b).lineBands().discountReachBps, 101);
        (b.buyBackDiscountBps, b.discountReachBps, b.minVolBandBps) = (0, 0, 0); // no discount: any reach
        assertEq(new PerpFormulaPricer(_product(), b).lineBands().discountReachBps, 0);
        b = _bands();
        b.buyBackDiscountBps = 1001;
        vm.expectRevert(PerpFormulaPricer.BadBands.selector);
        new PerpFormulaPricer(_product(), b);
        b.buyBackDiscountBps = 1000;
        assertEq(new PerpFormulaPricer(_product(), b).lineBands().buyBackDiscountBps, 1000);
        b = _bands();
        b.minVolBandBps = 0;
        vm.expectRevert(PerpFormulaPricer.BadBands.selector);
        new PerpFormulaPricer(_product(), b);
        b.minVolBandBps = 1;
        new PerpFormulaPricer(_product(), b);
        (b.buyBackDiscountBps, b.minVolBandBps) = (0, 0);
        LineBands memory lb = new PerpFormulaPricer(_product(), b).lineBands();
        assertEq(lb.buyBackDiscountBps, 0);
        assertEq(lb.minVolBandBps, 0);
        b = _bands();
        b.buyBackDiscountBps = 299;
        assertTrue(new PerpFormulaPricer(_product(), b).weightsHash() != formulaPricer.weightsHash());
        b = _bands();
        b.discountReachBps = 1999;
        assertTrue(new PerpFormulaPricer(_product(), b).weightsHash() != formulaPricer.weightsHash());
        b = _bands();
        b.minVolBandBps = 201;
        assertTrue(new PerpFormulaPricer(_product(), b).weightsHash() != formulaPricer.weightsHash());
    }

    /// The weightsHash covers both ranges: another carry range is another pricer.
    function test_formula_pricer_hash_covers_the_carry_range() public {
        PerpFormulaPricer.Bands memory b = _bands();
        b.carryMaxBps = 4999;
        assertTrue(new PerpFormulaPricer(_product(), b).weightsHash() != formulaPricer.weightsHash());
        b = _bands();
        b.carryMinBps = -1999;
        assertTrue(new PerpFormulaPricer(_product(), b).weightsHash() != formulaPricer.weightsHash());
    }

    /// The carry range, both ends included (like the vol range): -20% and +50% quote, one bps beyond
    /// is OutOfRange(3, carry). The ranges are checked by field (vol, time, carry, flags), then the
    /// bands: a carry outside its range is refused before a band, a vol outside its range before
    /// the carry.
    function test_formula_pricer_refuses_a_carry_outside_its_range() public {
        _live(9000);
        quoter.quote(s, formulaPricer, VOL, CARRY_MIN);
        quoter.quote(s, formulaPricer, VOL, CARRY_MAX);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(3), int64(-2001)));
        quoter.quote(s, formulaPricer, VOL, CARRY_MIN - 1);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(3), int64(5001)));
        quoter.quote(s, formulaPricer, VOL, CARRY_MAX + 1);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(3), int64(type(int16).min)));
        quoter.quote(s, formulaPricer, VOL, type(int16).min);
        // the four corners of the vol and carry ranges quote
        quoter.quote(s, formulaPricer, 2400, CARRY_MIN);
        quoter.quote(s, formulaPricer, 2400, CARRY_MAX);
        quoter.quote(s, formulaPricer, 15_000, CARRY_MIN);
        quoter.quote(s, formulaPricer, 15_000, CARRY_MAX);
        // the vol before the carry
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(1), int64(2399)));
        quoter.quote(s, formulaPricer, 2399, CARRY_MAX + 1);
        // the carry before the bands: at the crash line in the last 2 hours
        vm.warp(uint256(first) + 2 * DAY - 1 hours);
        feed.pushRound(_price(4000));
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(0)));
        quoter.quote(s, formulaPricer, VOL, CARRY);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(3), int64(5001)));
        quoter.quote(s, formulaPricer, VOL, CARRY_MAX + 1);
    }

    /// The formula-only pricer's price does not step at a fixing when the spot is unchanged:
    /// just before it, the accrual is the release a * p; just after, it starts again from 0.
    function test_formula_pricer_accrual_makes_the_price_continuous_across_a_fixing() public {
        _accrualIsContinuous(s, formulaPricer, 3000, 0);
    }

    /// The same at weekly fixings with a coupon reserve: the release is a * (p + R).
    function test_formula_pricer_accrual_is_continuous_at_weekly_fixings_with_a_coupon() public {
        PerpSeries w = _create(_weeklyCouponTerms(first));
        _accrualIsContinuous(w, new PerpFormulaPricer(_weeklyCouponProduct(), _weeklyBands()), 5000, 2350);
    }

    function _accrualIsContinuous(PerpSeries series, PerpFormulaPricer fp, uint256 kiFixBps, uint256 reserveBps)
        internal
    {
        _fix(series, 0, 10000);
        uint256 interval = series.terms().fixingInterval;
        uint64 melt = series.terms().meltShare;
        uint40 t1 = first + uint40(interval);
        for (uint256 i = 0; i < 2; i++) {
            uint256 snap = vm.snapshotState();
            bool knockedIn = i == 1;
            if (knockedIn) _fix(series, 1, kiFixBps); // knocked in from here on
            uint40 t = knockedIn ? t1 + uint40(interval) : t1;
            // one second before the fixing, spot 80% of the reference: outside both bands
            vm.warp(uint256(t) - 1);
            feed.pushRound(_price(8000));
            PerpQuote memory before_ = quoter.quote(series, fp, VOL, CARRY);
            _fixAt(series, t, _price(8000));
            vm.warp(uint256(t) + 1);
            feed.pushRound(_price(8000));
            PerpQuote memory after_ = quoter.quote(series, fp, VOL, CARRY);
            assertEq(after_.formulaBps, before_.formulaBps);
            assertEq(after_.correctionBps, 0);
            assertEq(after_.couponBps, reserveBps);
            // per unit of notional before the fixing: the release a * (p + R), and 1 - a of the price after
            uint256 payBps = knockedIn ? 8000 : 10_000;
            uint256 wantWad = uint256(melt) * (payBps + reserveBps) + (WAD - uint256(melt)) * after_.priceBps;
            assertApproxEqAbs(uint256(before_.priceBps) * WAD, wantWad, WAD); // within 1 bps of rounding
            vm.revertToState(snap);
        }
    }

    /// docs/v2-spec.md §6: in the last 2 hours before a fixing (7,200 s, edge included) the pricer
    /// refuses a clean note from 2% of the high below the crash line to 10% above it and a
    /// knocked-in note within 5% of the high, edges included.
    function test_formula_pricer_refuses_next_to_the_lines_before_a_fixing() public {
        _fix(s, 0, 10000);
        uint40 t1 = first + DAY;
        // clean, spot 45% of the reference: inside the crash line's band (40% -2% / +10%)
        vm.warp(uint256(t1) - 2 hours - 1);
        feed.pushRound(_price(4500));
        assertEq(quoter.inputs(s, VOL, CARRY).timeToNextFixingSecs, 7201);
        quoter.quote(s, formulaPricer, VOL, CARRY); // one second before the band: fine
        vm.warp(uint256(t1) - 2 hours);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(0)));
        quoter.quote(s, formulaPricer, VOL, CARRY);
        // the band's edges are in it, one bps beyond them is not
        _spotLater(5000);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(0)));
        quoter.quote(s, formulaPricer, VOL, CARRY);
        _spotLater(5001);
        quoter.quote(s, formulaPricer, VOL, CARRY);
        _spotLater(3800);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(0)));
        quoter.quote(s, formulaPricer, VOL, CARRY);
        _spotLater(3799);
        quoter.quote(s, formulaPricer, VOL, CARRY);
        _spotLater(3000); // in #32's band, below the line: priced now
        quoter.quote(s, formulaPricer, VOL, CARRY);
        // and so up to the fixing
        vm.warp(uint256(t1) - 1);
        feed.pushRound(_price(4000));
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(0)));
        quoter.quote(s, formulaPricer, VOL, CARRY);

        // knocked in, spot 97% of the reference: inside the heal band (100% +- 5%)
        _fix(s, 1, 3000);
        vm.warp(uint256(t1) + DAY - 2 hours - 1);
        feed.pushRound(_price(9700));
        quoter.quote(s, formulaPricer, VOL, CARRY); // one second before the band: fine
        vm.warp(uint256(t1) + DAY - 2 hours);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(1)));
        quoter.quote(s, formulaPricer, VOL, CARRY);
        _spotLater(9500);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(1)));
        quoter.quote(s, formulaPricer, VOL, CARRY);
        _spotLater(9499);
        quoter.quote(s, formulaPricer, VOL, CARRY);
        _spotLater(10_500);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(1)));
        quoter.quote(s, formulaPricer, VOL, CARRY);
        _spotLater(10_501);
        quoter.quote(s, formulaPricer, VOL, CARRY);
        _spotLater(4500); // the crash line's band is for clean notes only
        quoter.quote(s, formulaPricer, VOL, CARRY);
    }

    /// The strip below the crash line (and so the band, which holds it) reaches the closed form's
    /// knock-in level k' = k / top at the top of the vol range, rounded up (BadBands otherwise): the
    /// Desk trades a clean note below the strip at any time, and only below k' does it price like a
    /// knocked-in one. k - k' is 179 bps of the high for the launch's ETH pricer (vol 150%, daily),
    /// 180 for BTC (vol 120%), both inside their 200; 421 for P1's weekly pricer (vol 90%), inside
    /// its 500 but not 200. A strip of exactly that passes, one bps less fails, whatever the band;
    /// a lower top of the vol range needs less.
    function test_formula_pricer_strip_below_reaches_the_knock_in_level() public {
        _expectStripBelowEdge(_product(), _bands(), 179);
        _expectStripBelowEdge(_btcProduct(), _btcBands(), 180);
        _expectStripBelowEdge(_weeklyCouponProduct(), _weeklyBands(), 421);
        PerpFormulaPricer.Bands memory b = _weeklyBands();
        b.stripBelowBps = 200; // the launch's strip below, on P1's weekly product
        vm.expectRevert(PerpFormulaPricer.BadBands.selector);
        new PerpFormulaPricer(_weeklyCouponProduct(), b);
        b = _bands();
        b.volMaxBps = 7000; // ETH up to vol 70%: k - k' is 84.5 bps, 85 rounded up
        _expectStripBelowEdge(_product(), b, 85);
    }

    /// A pricer whose strip reaches `need` bps below the line is built, one whose strip reaches
    /// `need - 1` is refused, its band below 1,000 either way.
    function _expectStripBelowEdge(PerpProduct memory p, PerpFormulaPricer.Bands memory b, uint16 need) internal {
        (b.knockInBelowBps, b.stripBelowBps) = (1000, need);
        assertEq(new PerpFormulaPricer(p, b).lineBands().stripBelowBps, need);
        b.stripBelowBps = need - 1;
        vm.expectRevert(PerpFormulaPricer.BadBands.selector);
        new PerpFormulaPricer(p, b);
    }

    /// The crash line's band in the fixing band, asked directly, for both launch pricers: from
    /// k - 200 to k + 1,000, edges included; one bps beyond either edge is priced, and so is the band
    /// one second before the fixing band. A pricer whose band is wider below than above (1,000 /
    /// 300) refuses the mirror image: below and above are not swapped. Knocked in, the crash
    /// line's band doesn't apply.
    function test_formula_pricer_crash_line_band_below_and_above() public {
        _expectCrashLineBand(new PerpFormulaPricer(_product(), _bands()), KI, 200, 1000, VOL);
        _expectCrashLineBand(new PerpFormulaPricer(_btcProduct(), _btcBands()), KI_BTC, 200, 1000, 4500);
        PerpFormulaPricer.Bands memory b = _bands();
        (b.knockInBelowBps, b.knockInAboveBps) = (1000, 300);
        _expectCrashLineBand(new PerpFormulaPricer(_product(), b), KI, 1000, 300, VOL);
    }

    function _expectCrashLineBand(PerpFormulaPricer fp, uint256 k, uint256 below, uint256 above, uint16 vol)
        internal
        view
    {
        bytes memory refused = abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(0));
        uint32 band = fp.bands().fixingBandSecs;
        uint256[4] memory inside = [k - below, k - below + 1, k + above - 1, k + above];
        for (uint256 i = 0; i < 4; i++) {
            _expectPricerRevert(fp, _in(inside[i], vol, band, 0), refused);
            fp.correctionBps(_in(inside[i], vol, band + 1, 0)); // before the fixing band
            fp.correctionBps(_in(inside[i], vol, band, 1)); // knocked in
        }
        fp.correctionBps(_in(k - below - 1, vol, band, 0));
        fp.correctionBps(_in(k + above + 1, vol, band, 0));
        fp.correctionBps(_in(k - below - 1, vol, 0, 0)); // at the fixing itself
        _expectPricerRevert(fp, _in(k - below, vol, 0, 0), refused);
    }

    function _in(uint256 spotBps, uint16 vol, uint32 timeToNext, uint8 flags)
        internal
        pure
        returns (PerpPricerInputs memory)
    {
        return PerpPricerInputs({
            // forge-lint: disable-next-line(unsafe-typecast)
            spotBpsOfReference: uint16(spotBps),
            volBpsAnnual: vol,
            timeToNextFixingSecs: timeToNext,
            carryBpsAnnual: CARRY,
            flags: flags
        });
    }

    /// `fp.correctionBps(in_)` reverts with exactly `err` (a view: no vm.expectRevert needed).
    function _expectPricerRevert(PerpFormulaPricer fp, PerpPricerInputs memory in_, bytes memory err) internal view {
        try fp.correctionBps(in_) returns (int16) {
            revert("the pricer answered");
        } catch (bytes memory got) {
            assertEq(keccak256(got), keccak256(err));
        }
    }

    /// Asked directly, the pricer refuses the fields the quoter never sends out of range (the time,
    /// the flags) too, in field order: time, carry, flags.
    function test_formula_pricer_refuses_direct_inputs_outside_its_domain() public {
        PerpPricerInputs memory in_ = PerpPricerInputs({
            spotBpsOfReference: 9000,
            volBpsAnnual: VOL,
            timeToNextFixingSecs: DAY + 1,
            carryBpsAnnual: CARRY_MAX + 1,
            flags: 2
        });
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(2), int64(uint64(DAY) + 1)));
        formulaPricer.correctionBps(in_);
        in_.timeToNextFixingSecs = DAY;
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(3), int64(CARRY_MAX + 1)));
        formulaPricer.correctionBps(in_);
        in_.carryBpsAnnual = CARRY;
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(4), int64(2)));
        formulaPricer.correctionBps(in_);
        in_.flags = 0;
        // just after a fixing nothing has accrued; answer() is the correction with the product and the hash
        assertEq(formulaPricer.correctionBps(in_), 0);
        (int16 c, PerpProduct memory p, bytes32 h) = formulaPricer.answer(in_);
        assertEq(c, 0);
        assertEq(keccak256(abi.encode(p)), keccak256(abi.encode(_product())));
        assertEq(h, formulaPricer.weightsHash());
    }

    function test_formula_pricer_is_built_only_for_vols_the_formula_carries() public {
        PerpProduct memory p = _product();
        PerpFormulaPricer.Bands memory b = _bands();
        b.volMinBps = 600; // the closed form refuses 6% vol in this world
        vm.expectRevert(abi.encodeWithSelector(PerpFormula.VolOutOfRange.selector, uint256(0.06e18)));
        new PerpFormulaPricer(p, b);
        b = _bands();
        b.volMinBps = 15_001;
        vm.expectRevert(PerpFormulaPricer.BadBands.selector);
        new PerpFormulaPricer(p, b);
        b = _bands();
        b.carryMinBps = 5001;
        vm.expectRevert(PerpFormulaPricer.BadBands.selector);
        new PerpFormulaPricer(p, b);
        b.carryMinBps = 5000; // a single carry is a range
        new PerpFormulaPricer(p, b);
        b = _bands();
        b.fixingBandSecs = DAY + 1;
        vm.expectRevert(PerpFormulaPricer.BadBands.selector);
        new PerpFormulaPricer(p, b);
        // the band may be the whole interval
        b.fixingBandSecs = DAY;
        new PerpFormulaPricer(p, b);
    }

    /// The constructor proves the closed form at the four corners of the vol and carry ranges:
    /// the lowest vol with the highest carry is where |beta-| grows (the launch's vol minimums were
    /// raised for it), the lowest vol with the lowest carry where beta+ grows, and a carry at the
    /// melt rate (1/yr at launch) leaves "pays x" without a value.
    function test_formula_pricer_is_built_only_for_corners_the_formula_carries() public {
        PerpProduct memory p = _product();
        PerpFormulaPricer.Bands memory b = _bands();
        // vol 20% (the old minimum) with carry +50%: refused; up to +45% it is carried
        b.volMinBps = 2000;
        vm.expectRevert(abi.encodeWithSelector(PerpFormula.VolOutOfRange.selector, uint256(0.2e18)));
        new PerpFormulaPricer(p, b);
        b.carryMaxBps = 4500;
        new PerpFormulaPricer(p, b);
        // vol 24% with carry -100%: beta+ above 25
        b = _bands();
        b.carryMinBps = -10_000;
        vm.expectRevert(abi.encodeWithSelector(PerpFormula.VolOutOfRange.selector, uint256(0.24e18)));
        new PerpFormulaPricer(p, b);
        // carry at the melt rate, at either end of the vol range
        b = _bands();
        b.carryMaxBps = 10_000;
        vm.expectRevert(PerpFormula.BadWorld.selector);
        new PerpFormulaPricer(p, b);
        // a vol range the formula can't reach at its top
        b = _bands();
        b.volMaxBps = 30_001;
        vm.expectRevert(abi.encodeWithSelector(PerpFormula.VolOutOfRange.selector, uint256(3.0001e18)));
        new PerpFormulaPricer(p, b);
        // both launch pricers hold all four corners (their constructors ran in setUp and here)
        new PerpFormulaPricer(_btcProduct(), _btcBands());
        b = _btcBands();
        b.volMinBps = 2000;
        vm.expectRevert(abi.encodeWithSelector(PerpFormula.VolOutOfRange.selector, uint256(0.2e18)));
        new PerpFormulaPricer(_btcProduct(), b);
    }

    function test_formula_pricer_unknown_field_reverts() public {
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(5), int64(5)));
        formulaPricer.certifiedRange(5);
    }

    // --- the coupon path: a weekly series with a coupon reserve (R = 0.235) -------------------------

    /// A weekly series with R = 0.235 on the same feed, live two days after its fixing 1 (90%).
    function _liveWeekly() internal returns (PerpSeries w, PerpFormulaPricer fp) {
        w = _create(_weeklyCouponTerms(first));
        fp = new PerpFormulaPricer(_weeklyCouponProduct(), _weeklyBands());
        pricer.setProduct(_weeklyCouponProduct());
        _fix(w, 0, 10000);
        _fix(w, 1, 9000);
        vm.warp(uint256(first) + WEEK + 2 days);
        feed.pushRound(_price(9000));
    }

    function test_coupon_series_quote_parts_add_up_and_floor_at_the_coupon() public {
        (PerpSeries w, PerpFormulaPricer fp) = _liveWeekly();
        PerpQuote memory base = quoter.quote(w, fp, 5500, CARRY);
        // two of seven days into the week: the accrual is a * 2/7 * (1 - formula), a clean note
        int256 accrual = int256(uint256(MELT_WEEKLY) * 2 days) * (10_000 - int256(uint256(base.formulaBps)))
            / int256(WAD * uint256(WEEK));
        assertGt(accrual, 0);
        assertEq(base.correctionBps, accrual);
        assertEq(base.couponBps, 2350); // R = 0.235 at discount 0
        assertEq(base.priceBps, uint256(int256(uint256(base.formulaBps)) + accrual) + 2350);

        pricer.setCorrection(-37);
        PerpQuote memory q = quoter.quote(w, pricer, 5500, CARRY);
        assertEq(q.formulaBps, base.formulaBps);
        assertEq(q.priceBps, base.formulaBps + 2350 - 37);

        // a correction below minus the formula: the principal floors at 0, the coupon stays
        pricer.setCorrection(-30000);
        q = quoter.quote(w, pricer, 5500, CARRY);
        assertEq(q.priceBps, 2350);
    }

    function test_coupon_series_discount_rate_shrinks_the_coupon_value() public {
        (PerpSeries w, PerpFormulaPricer fp) = _liveWeekly();
        PerpProduct memory p = pricer.product();
        p.discountBps = 400; // the doc's world: rho = r = 4%
        pricer.setProduct(p);
        PerpQuote memory q = quoter.quote(w, pricer, 5500, CARRY);
        // R * a e^(-rho tau) / (1 - (1 - a) e^(-rho dt)): about R / 1.04, a little more mid-week
        assertGt(q.couponBps, 2255);
        assertLt(q.couponBps, 2265);
        PerpQuote memory undiscounted = quoter.quote(w, fp, 5500, CARRY);
        assertLt(q.formulaBps, undiscounted.formulaBps);
    }

    /// One quote through the formula-only pricer: what the Desk pays per price (gas report).
    function test_gas_of_one_quote() public {
        _live(9000);
        uint256 g = gasleft();
        quoter.quote(s, formulaPricer, VOL, CARRY);
        emit log_named_uint("gas, quote with the formula-only pricer (cold)", g - gasleft());
        g = gasleft();
        quoter.quote(s, formulaPricer, VOL, CARRY);
        emit log_named_uint("gas, the same quote again (warm)", g - gasleft());
    }
}
