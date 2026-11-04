// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// Raw feature vector, featureSpecVersion 3 (docs/v2-spec.md §7). Field order =
/// model input order. Five positions in a repeating cycle: nothing counts
/// down to an end. The model accepts only its certified domain (per-field
/// ranges and excluded regions) and reverts outside it; it never clamps.
struct PerpPricerInputs {
    uint16 spotBpsOfReference; // floor(spot * 10_000 / reference)
    uint16 volBpsAnnual; // total implied vol: the caller's (the Desk's market data for the series' feed)
    uint32 timeToNextFixingSecs;
    // The futures premium over spot per year, the closed form's risk-neutral drift r: the
    // caller's, like the vol. Replaces featureSpecVersion 2's earnings count (stocks only),
    // so the other fields keep their indexes.
    int16 carryBpsAnnual;
    uint8 flags; // bit0: knocked in
}

/// What a model is pinned to (inside its weightsHash). A series can be priced
/// by a model only if its barrier, melt share and interval are these. The
/// coupon reserve is not pinned: the note's price is linear in it, and the
/// model prices the principal only. Vol and carry are not pinned either: they
/// are inputs (PerpPricerInputs), inside the model's certified ranges.
struct PerpProduct {
    uint16 kiBarrierBps;
    uint64 meltShare; // 1e18 fixed point
    uint32 fixingInterval; // seconds
    int16 discountBps; // discount rate of the payouts per year (the closed form's rho; 0: the escrow earns nothing)
}

/// Where and how the Desk restricts trading near a line (docs/v2-spec.md §8), at any time of day:
/// distances from the line in bps of the reference, edges included (0: only exactly at the line).
/// With x = spotBpsOfReference and k = kiBarrierBps:
///  - healBandBps: a knocked-in note with |x - 10,000| <= it: no trade at all (the closed form's
///    error changes sign with the vol there);
///  - stripBelowBps, stripAboveBps: a clean note with k - stripBelowBps <= x <= k + stripAboveBps:
///    no trade at all (there, in the hours before a fixing, the closed form prices NOTE too high
///    and cover too low: just under the line it prices a clean note that the next fixing will
///    very likely knock in);
///  - buyBackDiscountBps (D), discountReachBps (R): a clean note with
///    k + stripAboveBps < x < k + R: the two sides priced at the NOTE ask, `buy` and `sellCover`,
///    trade at an ask raised by ceil(D * (k + R - x) / (R - stripAboveBps)) bps of live notional
///    (the ask at most the pair's value), D just above the strip falling evenly to 0 at k + R:
///    there the closed form prices NOTE too low and cover too high, and the discount keeps a
///    buy-back near the line from costing more than one far from it;
///  - minVolBandBps: the Desk never prices with a vol band below it (the discount assumes it): a
///    discount needs one of at least 1 (PerpDesk.listSeries refuses a pricer without, and
///    PerpFormulaPricer's constructor too).
/// Everywhere else every side trades.
struct LineBands {
    uint16 healBandBps;
    uint16 stripBelowBps;
    uint16 stripAboveBps;
    uint16 buyBackDiscountBps;
    uint16 discountReachBps;
    uint16 minVolBandBps;
}

/// L0: a student (a Stylus contract built from a featureSpecVersion 3
/// export; after the audit), or PerpFormulaPricer (no student, one per asset at
/// launch: its correction is the fixing accrual). Pure: no storage,
/// no external calls, no block.timestamp. On-chain price = closed form
/// (PerpFormula, computed by PerpQuoter from the inputs' vol and carry and
/// `product()`'s discount rate) + this model's correction: the student learns
/// only what the formula gets wrong.
interface IPerpPricer {
    /// `field` (PerpPricerInputs index) is outside the certified range.
    error OutOfRange(uint8 field, int64 value);
    /// Inside excluded region `region` (e.g. next to the crash line just before a fixing).
    error Uncertified(uint8 region);

    /// Correction to the closed form's principal, in bps of live notional.
    function correctionBps(PerpPricerInputs calldata inputs) external view returns (int16);

    /// The same correction together with `product()` and `weightsHash()`: everything
    /// PerpQuoter needs for one quote in one call (entering a Stylus contract costs gas
    /// each time).
    function answer(PerpPricerInputs calldata inputs)
        external
        view
        returns (int16 correctionBps_, PerpProduct memory product_, bytes32 weightsHash_);

    /// Certified range of one input field.
    function certifiedRange(uint8 field) external view returns (int64 min, int64 max);

    /// Where the price is least sure, in bps of the reference, and what the Desk does there at
    /// any time of day (`LineBands`, docs/v2-spec.md §8): in the crash line's strip and near the
    /// high of a knocked-in note no trade at all (PerpDesk's NearLine; near the high until a
    /// fixing at or above it makes the note clean), above the strip a buy-back at a discount,
    /// and the smallest vol band it prices with. Every model gives its bands, a student too: the
    /// Desk lists no pricer without them.
    function lineBands() external view returns (LineBands memory);

    function product() external view returns (PerpProduct memory);

    /// keccak256 of the canonical student_export.json (recomputed at build);
    /// pins the weights, the certified domain and the product.
    function weightsHash() external view returns (bytes32);

    function featureSpecVersion() external view returns (uint16);
}
