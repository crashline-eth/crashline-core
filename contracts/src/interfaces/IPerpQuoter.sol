// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPerpSeries} from "./IPerpSeries.sol";
import {IPerpPricer, PerpPricerInputs} from "./IPerpPricer.sol";
import {IAggregatorV3} from "./IAggregatorV3.sol";

/// One quote, with its parts, so anyone can see how the price is built.
/// All in bps of live notional; a token is worth notionalPerToken / 1e27 of it.
struct PerpQuote {
    uint16 priceBps; // NOTE fair value = max(0, formulaBps + correctionBps) + couponBps
    uint16 formulaBps; // the closed form's principal (PerpFormula), rounded to the nearest bps
    int16 correctionBps; // the model's correction (0 from a formula-only pricer)
    uint16 couponBps; // value of the coupon reserve R: exactly R when the model discounts at 0
    bytes32 weightsHash; // the model version
}

/// L2 of the v2 perpetual note: view-only glue between a series, the closed
/// form and a model. Reads every note-state input from the series (which
/// replays its recorder), never from the caller. The caller picks the model
/// and the market: the implied vol and the carry (the Desk's market data for
/// the series' feed); the model refuses what lies outside its certified
/// domain. One stateless quoter serves every model.
/// Refuses (reverts) instead of guessing.
///
/// COVER fair value = pairBps - NOTE fair value, pairBps = (1e6 + couponReserve) / 100:
/// a pair redeems for that at any time.
interface IPerpQuoter {
    error NotLive(); // Pending or Closed
    error FixingPending(uint40 fixingTime); // a fixing time passed, its fixing can't be processed yet
    error FeedStale(uint40 updatedAt); // older than MAX_FEED_STALENESS
    error BadFeedAnswer();
    /// The series is not the product the model is pinned to: 0 = knock-in, 1 = melt share, 2 = interval.
    error ProductMismatch(uint8 field);
    // plus L2Sequencer.SequencerDown / SequencerGracePeriod (every read of the feed), IPerpPricer.OutOfRange / Uncertified from the model, PerpFormula.VolOutOfRange / BadWorld

    function MAX_FEED_STALENESS() external view returns (uint40);
    function sequencer() external view returns (IAggregatorV3); // L2 sequencer uptime feed; 0: no check
    function SEQUENCER_GRACE() external view returns (uint40);

    /// Exactly what the model sees, with the spot read from the series' feed. `volBpsAnnual` and
    /// `carryBpsAnnual` (the futures premium over spot per year, the closed form's r) are the caller's.
    function inputs(IPerpSeries series, uint16 volBpsAnnual, int16 carryBpsAnnual)
        external
        view
        returns (PerpPricerInputs memory);

    /// Fair value of NOTE per unit of live notional, with the feed's spot.
    function quote(IPerpSeries series, IPerpPricer pricer, uint16 volBpsAnnual, int16 carryBpsAnnual)
        external
        view
        returns (PerpQuote memory);

    /// The same at a spot the caller supplies (feed decimals) and vouches for:
    /// the feed is not read, so no staleness check. For a Desk that reads the
    /// feed once for several quotes; a fixing never uses it.
    function quoteAtSpot(
        IPerpSeries series,
        IPerpPricer pricer,
        uint16 volBpsAnnual,
        int16 carryBpsAnnual,
        uint256 spot
    ) external view returns (PerpQuote memory);

    /// `quote` without its parts.
    function notePriceBps(IPerpSeries series, IPerpPricer pricer, uint16 volBpsAnnual, int16 carryBpsAnnual)
        external
        view
        returns (uint16 priceBps, bytes32 weightsHash);

    /// The series' feed price, fresh, or FeedStale / BadFeedAnswer.
    function spot(IPerpSeries series) external view returns (uint256);
}
