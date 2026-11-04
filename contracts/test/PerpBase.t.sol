// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {PerpFactory} from "../src/PerpFactory.sol";
import {PerpSeries} from "../src/PerpSeries.sol";
import {PerpToken} from "../src/PerpToken.sol";
import {FixingsRecorder} from "../src/FixingsRecorder.sol";
import {PerpTerms} from "../src/interfaces/IPerpSeries.sol";
import {IPerpFactory} from "../src/interfaces/IPerpFactory.sol";
import {IPerpDesk} from "../src/interfaces/IPerpDesk.sol";
import {PerpProduct} from "../src/interfaces/IPerpPricer.sol";
import {PerpFormulaPricer} from "../src/PerpFormulaPricer.sol";

/// Shared fixture for the v2 perpetual note: a feed, USDC, an L2 sequencer
/// uptime feed (up since long before T0), the perpetual factory with the
/// launch's recorder limits (DeployPerp.s.sol) and the launch terms
/// (docs/v2-spec.md §1) of an ETH series: daily fixings at 08:00 UTC, release
/// rate 1/yr, the crash line at 40% of the high (BTC's: 50%), no coupon
/// reserve. The factory accepts more than the launch uses: `_weeklyCouponTerms`
/// is a weekly series with a coupon reserve of 23.5% (the terms of P1, the
/// stock product), for the tests of that generality.
abstract contract PerpBase is Test {
    uint32 internal constant DAY = 86_400;
    uint32 internal constant WEEK = 604_800;
    uint96 internal constant INITIAL = 100e8; // $100, feed decimals
    uint40 internal constant T0 = 1_789_974_000; // 2026-09-21 07:00 UTC: a first fixing an hour later is at 08:00
    // the launch terms (docs/v2-spec.md §1)
    uint64 internal constant MELT = 2_735_976_403_140_715; // 1 - e^(-1/365): release rate 1/yr at daily fixings
    uint16 internal constant KI = 4000; // ETH's crash line, bps of the high
    uint16 internal constant KI_BTC = 5000; // BTC's
    uint64 internal constant RESERVE = 0; // no coupon reserve at launch
    uint32 internal constant MIN_SECS = 300; // the Desk's minSecsToFixing
    int16 internal constant CARRY = 400; // carry 4% a year: the market data the tests quote at
    int16 internal constant CARRY_MIN = -2000; // the launch pricers' carry range, bps a year
    int16 internal constant CARRY_MAX = 5000;
    // a weekly series with a coupon reserve (P1's terms)
    uint64 internal constant MELT_WEEKLY = 18_995_352_771_274_247; // 1 - e^(-7/365)
    uint16 internal constant KI_WEEKLY = 6000;
    uint64 internal constant COUPON = 235_000; // R = 0.235 per unit of notional
    uint256 internal constant UNIT = 1e6;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant RAY = 1e27;
    // the launch's limits (DeployPerp.s.sol)
    uint40 internal constant MAX_FIX_AGE = 1 hours;
    int256 internal constant PRICE_MAX = 1e15;
    uint40 internal constant STALENESS = 1 hours;
    uint40 internal constant GRACE = 1 hours;
    /// A fixing unrecorded this long after its time is missed: PerpSeries.FALLBACK_GRACE.
    uint256 internal constant FALLBACK = 6 hours;
    /// Missed fixings in a row spanning this long close a series: PerpSeries.CLOSE_AFTER_DEAD.
    uint256 internal constant DEAD = 14 days;
    // the launch's market data limits (DeployPerp.s.sol): stale 3 h after its sourceTime; a
    // keeper write moves vol by at most 5 points and carry by 3 points a year, 10 minutes apart
    uint32 internal constant MARKET_AGE = 3 hours;
    uint16 internal constant VOL_STEP = 500;
    uint16 internal constant CARRY_STEP = 300;
    uint32 internal constant UPDATE_GAP = 10 minutes;

    MockChainlinkFeed internal feed;
    MockUSDC internal usdc;
    MockChainlinkFeed internal sequencer;
    PerpFactory internal factory;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        vm.warp(T0);
        feed = new MockChainlinkFeed("ETH / USD");
        usdc = new MockUSDC();
        sequencer = new MockChainlinkFeed("L2 Sequencer Uptime Status Feed");
        sequencer.pushRoundAt(0, T0 - 30 days); // up
        factory = new PerpFactory(address(usdc), _limits());
    }

    function _limits() internal view returns (IPerpFactory.RecorderLimits memory) {
        return IPerpFactory.RecorderLimits({
            maxFixAge: MAX_FIX_AGE, priceMax: PRICE_MAX, sequencer: address(sequencer), sequencerGrace: GRACE
        });
    }

    /// The launch's market data limits, as the Desk's constructor takes them.
    function _marketLimits() internal pure returns (IPerpDesk.MarketLimits memory) {
        return IPerpDesk.MarketLimits({
            maxMarketAge: MARKET_AGE, maxVolStepBps: VOL_STEP, maxCarryStepBps: CARRY_STEP, minUpdateGap: UPDATE_GAP
        });
    }

    /// An ETH series on the launch terms.
    function _terms(uint40 firstFixing) internal view returns (PerpTerms memory) {
        return PerpTerms({
            feed: address(feed),
            firstFixing: firstFixing,
            fixingInterval: DAY,
            kiBarrierBps: KI,
            meltShare: MELT,
            couponReserve: RESERVE
        });
    }

    /// A BTC series on the launch terms, on its own feed.
    function _btcTerms(address btcFeed, uint40 firstFixing) internal pure returns (PerpTerms memory) {
        return PerpTerms({
            feed: btcFeed,
            firstFixing: firstFixing,
            fixingInterval: DAY,
            kiBarrierBps: KI_BTC,
            meltShare: MELT,
            couponReserve: RESERVE
        });
    }

    /// A weekly series with a coupon reserve (P1's terms, k 60%): not a launch series, but
    /// one the factory, the series and the Desk must handle like any other.
    function _weeklyCouponTerms(uint40 firstFixing) internal view returns (PerpTerms memory) {
        return PerpTerms({
            feed: address(feed),
            firstFixing: firstFixing,
            fixingInterval: WEEK,
            kiBarrierBps: KI_WEEKLY,
            meltShare: MELT_WEEKLY,
            couponReserve: COUPON
        });
    }

    /// The launch's ETH product (DeployPerp.s.sol): what its pricer is pinned to.
    function _product() internal pure returns (PerpProduct memory) {
        return PerpProduct({kiBarrierBps: KI, meltShare: MELT, fixingInterval: DAY, discountBps: 0});
    }

    /// The launch's BTC product.
    function _btcProduct() internal pure returns (PerpProduct memory) {
        return PerpProduct({kiBarrierBps: KI_BTC, meltShare: MELT, fixingInterval: DAY, discountBps: 0});
    }

    /// The product of `_weeklyCouponTerms` (P1's, discount 0; P1's drift, 4%, is now the carry input).
    function _weeklyCouponProduct() internal pure returns (PerpProduct memory) {
        return PerpProduct({kiBarrierBps: KI_WEEKLY, meltShare: MELT_WEEKLY, fixingInterval: WEEK, discountBps: 0});
    }

    /// Where the launch's ETH pricer answers (DeployPerp.s.sol): the 2 hours before a fixing
    /// except from 2% below the crash line to 10% above it (clean) or within 5% of the high
    /// (knocked in), vol 24-150%, carry -20% to +50%; the Desk's strip from 2% below the crash
    /// line to 1% above, the buy-back discount 3% falling to 0 at 20% above the line, a vol band
    /// of at least 2 points.
    function _bands() internal pure returns (PerpFormulaPricer.Bands memory) {
        return PerpFormulaPricer.Bands({
            fixingBandSecs: 2 hours,
            knockInBelowBps: 200,
            knockInAboveBps: 1000,
            healBandBps: 500,
            stripBelowBps: 200,
            stripAboveBps: 100,
            buyBackDiscountBps: 300,
            discountReachBps: 2000,
            minVolBandBps: 200,
            volMinBps: 2400,
            volMaxBps: 15_000,
            carryMinBps: CARRY_MIN,
            carryMaxBps: CARRY_MAX
        });
    }

    /// BTC's: the same bands, vol 21-120%, the buy-back discount 4.5%.
    function _btcBands() internal pure returns (PerpFormulaPricer.Bands memory) {
        PerpFormulaPricer.Bands memory b = _bands();
        b.volMinBps = 2100;
        b.volMaxBps = 12_000;
        b.buyBackDiscountBps = 450;
        return b;
    }

    /// P1's bands, for a weekly pricer: 6 hours before a fixing, vol 20-90%, carry -20% to +30%
    /// (around P1's 4%; at vol 20% the closed form carries +30%, not +50%); P1's crash line
    /// band, 10% on each side; a strip from 5% below the line (the formula's knock-in level at vol
    /// 90% and weekly fixings is 4.21% below it) to 1% above; ETH's discount and minimum vol band.
    function _weeklyBands() internal pure returns (PerpFormulaPricer.Bands memory) {
        return PerpFormulaPricer.Bands({
            fixingBandSecs: 6 hours,
            knockInBelowBps: 1000,
            knockInAboveBps: 1000,
            healBandBps: 500,
            stripBelowBps: 500,
            stripAboveBps: 100,
            buyBackDiscountBps: 300,
            discountReachBps: 2000,
            minVolBandBps: 200,
            volMinBps: 2000,
            volMaxBps: 9000,
            carryMinBps: -2000,
            carryMaxBps: 3000
        });
    }

    function _create(PerpTerms memory t) internal returns (PerpSeries s) {
        s = PerpSeries(factory.createSeries(t));
    }

    function _recorder(PerpSeries s) internal view returns (FixingsRecorder) {
        return FixingsRecorder(address(s.recorder()));
    }

    function _fixingTime(PerpSeries s, uint256 n) internal view returns (uint40) {
        return uint40(s.terms().firstFixing + n * s.terms().fixingInterval);
    }

    function _price(uint256 bps) internal pure returns (int256) {
        return int256(uint256(INITIAL) * bps / 10_000);
    }

    /// Stage a feed round exactly at `fixingTime` and record it (warps past it if needed).
    function _fixAt(PerpSeries s, uint40 fixingTime, int256 price) internal {
        if (block.timestamp <= fixingTime) vm.warp(uint256(fixingTime) + 1);
        feed.pushRoundAt(price, fixingTime);
        _recorder(s).recordFixing(fixingTime, uint80(feed.latestRound()));
    }

    /// Fixing n (0 = the first) at `bps` of INITIAL.
    function _fix(PerpSeries s, uint256 n, uint256 bps) internal {
        _fixAt(s, _fixingTime(s, n), _price(bps));
    }

    /// Mints `amount` pairs to `to`, funding `to` with USDC.
    function _mintPairs(PerpSeries s, address to, uint256 amount) internal returns (uint256 collateralIn) {
        uint256 need = s.previewMint(amount);
        usdc.mint(to, need);
        vm.startPrank(to);
        usdc.approve(address(s), need);
        collateralIn = s.mint(amount, to);
        vm.stopPrank();
    }

    function _note(PerpSeries s) internal view returns (PerpToken) {
        return PerpToken(s.note());
    }

    function _cover(PerpSeries s) internal view returns (PerpToken) {
        return PerpToken(s.cover());
    }
}
