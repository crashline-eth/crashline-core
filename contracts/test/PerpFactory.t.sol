// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Clones} from "@openzeppelin/contracts/proxy/Clones.sol";
import {PerpBase} from "./PerpBase.t.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {PerpFactory} from "../src/PerpFactory.sol";
import {PerpSeries} from "../src/PerpSeries.sol";
import {PerpToken} from "../src/PerpToken.sol";
import {FixingsRecorder} from "../src/FixingsRecorder.sol";
import {ISeriesToken} from "../src/interfaces/ISeriesToken.sol";
import {IPerpFactory} from "../src/interfaces/IPerpFactory.sol";
import {PerpTerms} from "../src/interfaces/IPerpSeries.sol";

contract PerpSixDecimalFeed {
    function decimals() external pure returns (uint8) {
        return 6;
    }
}

contract PerpEighteenDecimalToken {
    function decimals() external pure returns (uint8) {
        return 18;
    }
}

contract PerpFactoryTest is PerpBase {
    function test_createSeries_matches_prediction_and_registers() public {
        PerpTerms memory t = _terms(T0 + 1 days);
        (address ps, address pn, address pw) = factory.predictSeries(t);
        bytes32 id = factory.seriesId(t);
        assertEq(id, keccak256(abi.encode(t)));

        vm.expectEmit(true, true, false, true, address(factory));
        emit IPerpFactory.PerpSeriesCreated(id, address(feed), ps, pn, pw, t);
        PerpSeries s = _create(t);

        assertEq(address(s), ps);
        assertEq(s.note(), pn);
        assertEq(s.cover(), pw);
        assertEq(s.id(), id);
        assertEq(s.factory(), address(factory));
        assertEq(s.collateral(), address(usdc));
        assertEq(address(s.recorder()), factory.recorderOf(address(feed)));
        assertEq(factory.seriesOf(id), ps);
        assertTrue(factory.isSeries(ps));
        assertEq(factory.allSeries().length, 1);
        assertEq(keccak256(abi.encode(s.terms())), keccak256(abi.encode(t)));
        assertEq(s.pairValuePerNotional(), 1e6); // no coupon reserve at launch
        assertEq(s.FALLBACK_GRACE(), 6 hours);
        assertEq(s.FALLBACK_GRACE(), FALLBACK); // the fixtures' fallback
        assertEq(s.CLOSE_AFTER_DEAD(), 14 days);
        assertEq(s.CLOSE_AFTER_DEAD(), DEAD); // the fixtures' dead-feed duration
    }

    function test_createSeries_idempotent_and_vintages_differ() public {
        PerpTerms memory t = _terms(T0 + 1 days);
        address a = factory.createSeries(t);
        vm.recordLogs();
        address b = factory.createSeries(t);
        assertEq(a, b);
        assertEq(vm.getRecordedLogs().length, 0, "no second deployment");
        assertEq(factory.allSeries().length, 1);

        // the same terms from a later first fixing (the next day's): a fresh vintage on the same recorder
        address c = factory.createSeries(_terms(T0 + 1 days + DAY));
        assertTrue(c != a);
        assertEq(address(PerpSeries(c).recorder()), address(PerpSeries(a).recorder()));
        assertEq(factory.allSeries().length, 2);
    }

    function test_recorders_are_the_factorys_own() public {
        PerpSeries s = _create(_terms(T0 + 1 days));
        // another factory on the same feed: its own recorder, and neither takes the other's series
        PerpFactory other = new PerpFactory(address(usdc), _limits());
        address otherSeries = other.createSeries(_terms(T0 + 1 days));
        FixingsRecorder r = FixingsRecorder(address(s.recorder()));
        assertEq(address(r), factory.recorderOf(address(feed)));
        assertTrue(address(r) != other.recorderOf(address(feed)));
        assertFalse(factory.isSeries(otherSeries));
        assertFalse(other.isSeries(address(s)));
        // the launch's limits
        assertEq(r.MAX_FIX_AGE(), MAX_FIX_AGE);
        assertEq(r.PRICE_MAX(), PRICE_MAX);
        assertEq(address(r.sequencer()), address(sequencer));
        assertEq(r.SEQUENCER_GRACE(), GRACE);
        assertEq(address(r.feed()), address(feed));
        IPerpFactory.RecorderLimits memory l = factory.recorderLimits();
        assertEq(l.maxFixAge, MAX_FIX_AGE);
        assertEq(l.priceMax, PRICE_MAX);
        assertEq(l.sequencer, address(sequencer));
        assertEq(l.sequencerGrace, GRACE);
        // one recorder per feed, idempotent
        assertEq(factory.deployRecorder(address(feed)), address(r));
        assertEq(address(_create(_terms(T0 + 2 days)).recorder()), address(r));
    }

    function test_recorder_needs_an_8_decimal_feed() public {
        vm.expectRevert(IPerpFactory.BadFeed.selector);
        factory.deployRecorder(address(usdc)); // 6 decimals
        vm.expectRevert(IPerpFactory.BadFeed.selector);
        factory.deployRecorder(alice); // no code
    }

    function test_recorder_limits_must_be_sound() public {
        IPerpFactory.RecorderLimits memory l = _limits();
        l.maxFixAge = 0;
        vm.expectRevert(IPerpFactory.BadRecorderLimits.selector);
        new PerpFactory(address(usdc), l);
        l = _limits();
        l.priceMax = 0;
        vm.expectRevert(IPerpFactory.BadRecorderLimits.selector);
        new PerpFactory(address(usdc), l);
        l.priceMax = int256(uint256(type(uint96).max)) + 1; // a price must fit uint96
        vm.expectRevert(IPerpFactory.BadRecorderLimits.selector);
        new PerpFactory(address(usdc), l);
        l.priceMax = int256(uint256(type(uint96).max));
        new PerpFactory(address(usdc), l);
    }

    function test_tokens_metadata() public {
        PerpSeries s = _create(_terms(T0 + 1 days));
        PerpToken n = _note(s);
        PerpToken w = _cover(s);
        assertEq(n.decimals(), 6);
        assertEq(w.decimals(), 6);
        assertTrue(n.isNote());
        assertFalse(w.isNote());
        assertEq(n.series(), address(s));
        assertEq(w.series(), address(s));
        assertEq(bytes(n.symbol()).length, bytes("pNOTE-0x00000000").length);
        assertEq(bytes(w.symbol()).length, bytes("pCOVER-0x00000000").length);
        assertEq(bytes(n.name()).length, bytes("Perpetual NOTE 0x00000000").length);
    }

    function test_bad_terms_revert() public {
        PerpTerms memory t = _terms(T0 + 1 days);

        t.firstFixing = 0;
        vm.expectRevert(IPerpFactory.BadSchedule.selector);
        factory.createSeries(t);
        t = _terms(T0 + 1 days);
        t.fixingInterval = 1 hours - 1;
        vm.expectRevert(IPerpFactory.BadSchedule.selector);
        factory.createSeries(t);

        t = _terms(T0 + 1 days);
        t.kiBarrierBps = 0;
        vm.expectRevert(IPerpFactory.BadBarrier.selector);
        factory.createSeries(t);
        t.kiBarrierBps = 10_001;
        vm.expectRevert(IPerpFactory.BadBarrier.selector);
        factory.createSeries(t);

        t = _terms(T0 + 1 days);
        t.meltShare = 0;
        vm.expectRevert(IPerpFactory.BadMeltShare.selector);
        factory.createSeries(t);
        t.meltShare = 1e18;
        vm.expectRevert(IPerpFactory.BadMeltShare.selector);
        factory.createSeries(t);

        t = _terms(T0 + 1 days);
        t.couponReserve = 5e6 + 100;
        vm.expectRevert(IPerpFactory.BadCouponReserve.selector);
        factory.createSeries(t);
        // a whole number of bps only: the pair's value must be exact in the bps prices are quoted in,
        // or buying both legs at the Desk would cost less than the pair redeems for
        t.couponReserve = 235_099;
        vm.expectRevert(IPerpFactory.BadCouponReserve.selector);
        factory.createSeries(t);

        t = _terms(T0 + 1 days);
        t.feed = address(new PerpSixDecimalFeed());
        vm.expectRevert(IPerpFactory.BadFeed.selector);
        factory.createSeries(t);
        t.feed = address(0xdead);
        vm.expectRevert(IPerpFactory.BadFeed.selector);
        factory.createSeries(t);
        assertEq(factory.allSeries().length, 0);
    }

    function test_edge_terms_are_accepted() public {
        PerpTerms memory t = _terms(T0 + 1 days);
        t.fixingInterval = 1 hours;
        t.kiBarrierBps = 10_000;
        t.meltShare = 1e18 - 1;
        t.couponReserve = 5e6;
        PerpSeries s = _create(t);
        assertEq(s.pairValuePerNotional(), 6e6);
        t.kiBarrierBps = 1;
        t.meltShare = 1;
        t.couponReserve = 0;
        assertTrue(address(_create(t)) != address(s));
        // not launch terms, but terms the factory accepts: weekly fixings with a coupon reserve
        PerpSeries w = _create(_weeklyCouponTerms(T0 + 1 days));
        assertEq(w.terms().fixingInterval, WEEK);
        assertEq(w.pairValuePerNotional(), 1_235_000);
    }

    function test_collateral_must_match() public {
        address bad = address(new PerpEighteenDecimalToken());
        vm.expectRevert(PerpFactory.BadCollateral.selector);
        new PerpFactory(bad, _limits());
    }

    function test_foreign_clones_are_inert() public {
        PerpSeries s = _create(_terms(T0 + 1 days));
        address fake = Clones.clone(factory.seriesImplementation());
        PerpTerms memory t = s.terms();
        (address n, address w) = (s.note(), s.cover());
        vm.expectRevert(PerpSeries.OnlyFactory.selector);
        PerpSeries(fake).initialize(bytes32(uint256(1)), t, n, w, address(1), address(usdc));
        assertFalse(factory.isSeries(fake));
        address fakeToken = Clones.clone(factory.tokenImplementation());
        vm.expectRevert(ISeriesToken.OnlyFactory.selector);
        PerpToken(fakeToken).initialize(address(this), true, 6, "x", "x");
    }
}
