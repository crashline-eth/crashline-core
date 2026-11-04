// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPerpQuoter, PerpQuote} from "./interfaces/IPerpQuoter.sol";
import {IPerpSeries, PerpState, PerpTerms, PerpPhase} from "./interfaces/IPerpSeries.sol";
import {IPerpPricer, PerpPricerInputs, PerpProduct} from "./interfaces/IPerpPricer.sol";
import {IAggregatorV3} from "./interfaces/IAggregatorV3.sol";
import {PerpFormula} from "./PerpFormula.sol";
import {L2Sequencer} from "./L2Sequencer.sol";

/// L2 of the v2 perpetual note (IPerpQuoter): on-chain price = closed form +
/// model correction + the coupon reserve's value. Every note-state input
/// comes from the series, the spot from the series' feed (or, in
/// `quoteAtSpot`, from the caller); the caller picks the model, the vol and
/// the carry.
/// Refuses instead of guessing: NotLive, FixingPending, FeedStale,
/// BadFeedAnswer, ProductMismatch, and the model's and the formula's own
/// errors bubble up.
///
/// Feature derivation (featureSpecVersion 3; a Python twin's vectors,
/// test/vectors/perp_quoter_vectors*.json, are checked by PerpQuoter.t.sol):
///   spotBpsOfReference     = floor(spot * 10_000 / reference)
///   volBpsAnnual           = the caller's vol
///   timeToNextFixingSecs   = nextFixing - now
///   carryBpsAnnual         = the caller's carry
///   flags                  = knockedIn ? 1 : 0
/// Price assembly, per unit of live notional:
///   formulaBps = round(PerpFormula.principal(x = spotBpsOfReference / 1e4) * 1e4)
///   couponBps  = floor(couponReserve * PerpFormula.coupon / 100)
///   priceBps   = max(0, formulaBps + correctionBps) + couponBps
/// The formula's world is the series' terms (k, melt share, interval), the
/// model's discount rate (`discountBps`, the closed form's rho) and the
/// caller's vol and carry (r); the model answers only for a series whose terms
/// are its product, and only inside its certified vol and carry ranges.
contract PerpQuoter is IPerpQuoter {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant WAD_PER_BPS = WAD / BPS;
    int256 internal constant SIGNED_WAD_PER_BPS = 1e14;
    uint256 internal constant YEAR = 31_536_000; // 365 days, the teacher's year
    uint256 internal constant UNIT_PER_BPS = 100; // couponReserve is per 1e6 of notional

    /// A feed older than this refuses quotes: the feed's heartbeat plus a margin
    /// (ETH/USD and BTC/USD on Arbitrum One: 1,755 s heartbeat, 0.05% deviation),
    /// so a stopped feed turns into FeedStale within about two heartbeats.
    uint40 public immutable MAX_FEED_STALENESS;
    /// The L2 sequencer uptime feed (L2Sequencer); 0: no check.
    IAggregatorV3 public immutable sequencer;
    uint40 public immutable SEQUENCER_GRACE;

    constructor(uint40 maxFeedStaleness, address sequencer_, uint40 sequencerGrace) {
        MAX_FEED_STALENESS = maxFeedStaleness;
        sequencer = IAggregatorV3(sequencer_);
        SEQUENCER_GRACE = sequencerGrace;
    }

    /// @inheritdoc IPerpQuoter
    function spot(IPerpSeries series) external view returns (uint256) {
        return _spot(series.terms().feed);
    }

    /// @inheritdoc IPerpQuoter
    function inputs(IPerpSeries series, uint16 volBpsAnnual, int16 carryBpsAnnual)
        external
        view
        returns (PerpPricerInputs memory)
    {
        return _inputs(_liveState(series), volBpsAnnual, carryBpsAnnual, _spot(series.terms().feed));
    }

    /// @inheritdoc IPerpQuoter
    function quote(IPerpSeries series, IPerpPricer pricer, uint16 volBpsAnnual, int16 carryBpsAnnual)
        public
        view
        returns (PerpQuote memory)
    {
        PerpState memory st = _liveState(series);
        PerpTerms memory t = series.terms();
        return _quote(t, pricer, _inputs(st, volBpsAnnual, carryBpsAnnual, _spot(t.feed)));
    }

    /// @inheritdoc IPerpQuoter
    function quoteAtSpot(
        IPerpSeries series,
        IPerpPricer pricer,
        uint16 volBpsAnnual,
        int16 carryBpsAnnual,
        uint256 spot_
    ) external view returns (PerpQuote memory) {
        if (spot_ == 0) revert BadFeedAnswer();
        PerpState memory st = _liveState(series);
        return _quote(series.terms(), pricer, _inputs(st, volBpsAnnual, carryBpsAnnual, spot_));
    }

    /// @inheritdoc IPerpQuoter
    function notePriceBps(IPerpSeries series, IPerpPricer pricer, uint16 volBpsAnnual, int16 carryBpsAnnual)
        external
        view
        returns (uint16 priceBps, bytes32 weightsHash)
    {
        PerpQuote memory q = quote(series, pricer, volBpsAnnual, carryBpsAnnual);
        return (q.priceBps, q.weightsHash);
    }

    // --- internals --------------------------------------------------------------

    function _spot(address feed) internal view returns (uint256) {
        L2Sequencer.check(sequencer, SEQUENCER_GRACE);
        // forge-lint: disable-next-line(unused-return)
        (, int256 answer,, uint256 updatedAt,) = IAggregatorV3(feed).latestRoundData();
        if (answer <= 0) revert BadFeedAnswer();
        // forge-lint: disable-next-line(unsafe-typecast)
        if (updatedAt + MAX_FEED_STALENESS < block.timestamp) revert FeedStale(uint40(updatedAt));
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer); // > 0, checked above
    }

    /// The series' state, which must be Live with no fixing pending. `state()` has
    /// processed everything that can be processed, so a next fixing time in the past
    /// means that fixing is missing (IPerpSeries.pendingFixing).
    function _liveState(IPerpSeries series) internal view returns (PerpState memory st) {
        st = series.state();
        if (st.phase != PerpPhase.Live) revert NotLive();
        if (st.nextFixing < block.timestamp) revert FixingPending(st.nextFixing);
    }

    function _inputs(PerpState memory st, uint16 volBpsAnnual, int16 carryBpsAnnual, uint256 spot_)
        internal
        view
        returns (PerpPricerInputs memory in_)
    {
        // Every cast below is range-checked first (or exact by construction).
        // forge-lint: disable-start(unsafe-typecast)
        uint256 spotBps = spot_ * BPS / st.referenceFixing;
        if (spotBps > type(uint16).max) {
            revert IPerpPricer.OutOfRange(
                0, spotBps > uint64(type(int64).max) ? type(int64).max : int64(uint64(spotBps))
            );
        }
        // not pending, so the next fixing time is now or later
        uint256 tNext = uint256(st.nextFixing) - block.timestamp;
        if (tNext > type(uint32).max) revert IPerpPricer.OutOfRange(2, int64(uint64(tNext)));

        in_.spotBpsOfReference = uint16(spotBps);
        in_.volBpsAnnual = volBpsAnnual;
        in_.timeToNextFixingSecs = uint32(tNext);
        in_.carryBpsAnnual = carryBpsAnnual;
        in_.flags = st.knockedIn ? 1 : 0;
        // forge-lint: disable-end(unsafe-typecast)
    }

    function _quote(PerpTerms memory t, IPerpPricer pricer, PerpPricerInputs memory in_)
        internal
        view
        returns (PerpQuote memory q)
    {
        // one call into the model: its refusals come first, then the product check
        PerpProduct memory p;
        (q.correctionBps, p, q.weightsHash) = pricer.answer(in_);
        if (p.kiBarrierBps != t.kiBarrierBps) revert ProductMismatch(0);
        if (p.meltShare != t.meltShare) revert ProductMismatch(1);
        if (p.fixingInterval != t.fixingInterval) revert ProductMismatch(2);
        (uint256 formulaBps, uint256 couponBps) = _closedForm(t, p, in_);

        // formulaBps fits int256 by far
        // forge-lint: disable-next-line(unsafe-typecast)
        int256 corrected = int256(formulaBps) + q.correctionBps;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint256 principalBps = corrected > 0 ? uint256(corrected) : 0;
        q.formulaBps = SafeCast.toUint16(formulaBps);
        q.couponBps = SafeCast.toUint16(couponBps);
        q.priceBps = SafeCast.toUint16(principalBps + couponBps);
    }

    /// The closed form's principal and the coupon reserve's value, in bps of live notional:
    /// the series' terms, the model's discount rate, the inputs the model saw (vol, carry).
    function _closedForm(PerpTerms memory t, PerpProduct memory p, PerpPricerInputs memory in_)
        internal
        pure
        returns (uint256 formulaBps, uint256 couponBps)
    {
        uint256 dt = uint256(t.fixingInterval) * WAD / YEAR;
        int256 rho = int256(p.discountBps) * SIGNED_WAD_PER_BPS;
        uint256 principal = PerpFormula.principal(
            PerpFormula.World({
                sigma: uint256(in_.volBpsAnnual) * WAD_PER_BPS,
                r: int256(in_.carryBpsAnnual) * SIGNED_WAD_PER_BPS,
                rho: rho,
                phi: PerpFormula.meltRate(t.meltShare, dt),
                k: uint256(t.kiBarrierBps) * WAD_PER_BPS,
                dt: dt
            }),
            uint256(in_.spotBpsOfReference) * WAD_PER_BPS,
            in_.flags != 0
        );
        formulaBps = (principal * BPS + WAD / 2) / WAD;
        uint256 tau = uint256(in_.timeToNextFixingSecs) * WAD / YEAR;
        couponBps = uint256(t.couponReserve) * PerpFormula.coupon(t.meltShare, rho, dt, tau) / (WAD * UNIT_PER_BPS);
    }
}
