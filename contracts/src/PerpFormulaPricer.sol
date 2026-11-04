// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {IPerpPricer, LineBands, PerpPricerInputs, PerpProduct} from "./interfaces/IPerpPricer.sol";
import {PerpFormula} from "./PerpFormula.sol";

/// The pricer with no student: PerpQuoter's price is the closed form
/// (PerpFormula) at the caller's vol and carry and this contract's discount
/// rate, plus the two things about discrete fixings (daily at launch) the
/// formula leaves out and no model is needed for:
///
/// Accrual. The formula melts the notional continuously; the note releases a
/// share `a` in one step at each fixing. The release builds up in the price
/// between fixings and leaves it at the fixing, so this pricer's "correction" is
///
///   correctionBps = a * elapsed / interval * (p - formula)
///
/// with elapsed = interval - timeToNextFixing and p = what the melting slice
/// would pay if the fixing were now (1 if clean and at or above the crash line,
/// else the spot over the reference, at most 1). At the fixing itself that is
/// the release, a * p, plus (1 - a) of the formula: with an unchanged spot the
/// price does not step when the fixing is processed, so nobody gains by
/// trading, depositing or withdrawing around it.
///
/// Refusals. In the last `fixingBandSecs` before a fixing the value steps at
/// the crash line (a clean note) and at the reference (a knocked-in note). No
/// formula follows a step, so near those levels, edges included, this pricer
/// refuses: a clean note from `knockInBelowBps` under the crash line to
/// `knockInAboveBps` over it (`Uncertified(0)`; narrower below, where a clean
/// note prices like the knocked-in one the fixing will very likely make it), a
/// knocked-in note within `healBandBps` of the reference (`Uncertified(1)`). It
/// also refuses a vol or a carry outside the ranges it was built for (both
/// ends included); the constructor proves the closed form can carry the four
/// corners of those ranges.
///
/// The Desk's lines (`lineBands`, IPerpPricer), at any time of day: the heal
/// band, where it doesn't trade a knocked-in note; the crash line's strip
/// (`stripBelowBps`, `stripAboveBps`), where it doesn't trade a clean note,
/// inside the band above on each side and reaching below the line to the
/// formula's knock-in level k / top at the top of the vol range (the
/// constructor checks both: below k / top a clean note prices like a knocked-in
/// one); above the strip the buy-back discount, `buyBackDiscountBps` falling to
/// 0 at `discountReachBps`; and `minVolBandBps`, the smallest vol band the Desk
/// may price with (the discount is sized for it).
///
/// What it cannot know is what the formula gets wrong elsewhere, jumps above
/// all (docs/v2-spec.md §6: a few bps typical in a world fitted to five years
/// of daily prices, far more near the crash line in a world of big crashes); a
/// Desk listing that uses it should carry a wider spread.
contract PerpFormulaPricer is IPerpPricer {
    uint256 internal constant BPS = 10_000;
    uint256 internal constant WAD = 1e18;
    uint256 internal constant WAD_PER_BPS = WAD / BPS;
    int256 internal constant SIGNED_WAD_PER_BPS = 1e14;
    uint256 internal constant YEAR = 31_536_000;
    uint8 internal constant NUM_FIELDS = 5;

    /// Where this pricer answers, and the Desk's lines.
    struct Bands {
        uint32 fixingBandSecs; // the two refusals apply this long before a fixing (0: never)
        uint16 knockInBelowBps; // spot from this far below the knock-in barrier, note not knocked in,
        uint16 knockInAboveBps; // to this far above it
        uint16 healBandBps; // spot within this of the reference, note knocked in (lineBands)
        uint16 stripBelowBps; // the Desk's strip around the knock-in barrier, note not knocked in: from this far
        uint16 stripAboveBps; // below the barrier to this far above it, inside the knock-in band (lineBands)
        uint16 buyBackDiscountBps; // the Desk's buy-back discount just above the strip, at most 1,000 (lineBands)
        uint16 discountReachBps; // falling to 0 this far above the barrier, past the strip with a discount (lineBands)
        uint16 minVolBandBps; // the smallest vol band the Desk prices with, at least 1 with a discount (lineBands)
        uint16 volMinBps; // certified vol range
        uint16 volMaxBps;
        int16 carryMinBps; // certified carry range, bps a year (the closed form carries all four corners)
        int16 carryMaxBps;
    }

    PerpProduct internal _product;
    Bands internal _bands;
    /// keccak256("PerpFormulaPricer", product, bands): there are no weights; the hash names
    /// the product, the discount rate and where the pricer answers (both ranges, the bands).
    bytes32 public immutable weightsHash;

    /// The buy-back discount's bound: 10% of live notional.
    uint16 public constant MAX_BUY_BACK_DISCOUNT_BPS = 1000;

    /// A vol or carry range upside down, a fixing band longer than the interval, a strip reaching
    /// beyond the crash line's band on either side or not below the line to the closed form's
    /// knock-in level at the top of the vol range, a discount above MAX_BUY_BACK_DISCOUNT_BPS, or a
    /// discount with no minimum vol band or with its reach inside the strip.
    error BadBands();

    constructor(PerpProduct memory product_, Bands memory bands_) {
        if (
            bands_.volMinBps > bands_.volMaxBps || bands_.carryMinBps > bands_.carryMaxBps
                || bands_.fixingBandSecs > product_.fixingInterval || bands_.stripBelowBps > bands_.knockInBelowBps
                || bands_.stripAboveBps > bands_.knockInAboveBps
                || bands_.buyBackDiscountBps > MAX_BUY_BACK_DISCOUNT_BPS
                || (bands_.buyBackDiscountBps != 0
                    && (bands_.minVolBandBps == 0 || bands_.discountReachBps <= bands_.stripAboveBps))
        ) revert BadBands();
        _product = product_;
        _bands = bands_;
        weightsHash = keccak256(abi.encode("PerpFormulaPricer", product_, bands_));
        // the closed form refuses low vols (PerpFormula.BETA_MAX, which a high carry reaches sooner) and bad
        // worlds (a carry at or above the melt rate): fail here, not in a quote
        PerpFormula.coefficients(_world(product_, bands_.volMinBps, bands_.carryMinBps));
        PerpFormula.coefficients(_world(product_, bands_.volMinBps, bands_.carryMaxBps));
        PerpFormula.coefficients(_world(product_, bands_.volMaxBps, bands_.carryMinBps));
        // A clean note prices on the knocked-in branch only below k' = k / top (the discrete-fixing
        // shift), lowest at the top of the vol range (the carry doesn't move it). Between k' and k
        // it prices a clean note that a fixing will very likely knock in: the strip below the line
        // (and so the band, which holds it) must reach k' (rounded up to whole bps), for the Desk
        // to trade a clean note below the strip at any time of day.
        int256 kPrime = PerpFormula.coefficients(_world(product_, bands_.volMaxBps, bands_.carryMaxBps)).kPrime;
        // 0 < k' = k / top < k (top > 1): the cast is safe and k - k' positive
        // forge-lint: disable-start(unsafe-typecast)
        uint256 shiftBps =
            (uint256(product_.kiBarrierBps) * WAD_PER_BPS - uint256(kPrime) + WAD_PER_BPS - 1) / WAD_PER_BPS;
        // forge-lint: disable-end(unsafe-typecast)
        if (shiftBps > bands_.stripBelowBps) revert BadBands();
    }

    function correctionBps(PerpPricerInputs calldata inputs) public view returns (int16) {
        PerpProduct memory p = _product;
        Bands memory b = _bands;
        uint256 x = inputs.spotBpsOfReference;
        bool knockedIn = inputs.flags != 0;
        // certified domain, in the order every model checks it: ranges by field, then exclusions
        if (inputs.volBpsAnnual < b.volMinBps || inputs.volBpsAnnual > b.volMaxBps) {
            revert OutOfRange(1, int64(uint64(inputs.volBpsAnnual)));
        }
        if (inputs.timeToNextFixingSecs > p.fixingInterval) {
            revert OutOfRange(2, int64(uint64(inputs.timeToNextFixingSecs)));
        }
        if (inputs.carryBpsAnnual < b.carryMinBps || inputs.carryBpsAnnual > b.carryMaxBps) {
            revert OutOfRange(3, inputs.carryBpsAnnual);
        }
        if (inputs.flags > 1) revert OutOfRange(4, int64(uint64(inputs.flags)));
        if (inputs.timeToNextFixingSecs <= b.fixingBandSecs && b.fixingBandSecs != 0) {
            if (!knockedIn && _within(x, p.kiBarrierBps, b.knockInBelowBps, b.knockInAboveBps)) revert Uncertified(0);
            if (knockedIn && _within(x, BPS, b.healBandBps, b.healBandBps)) revert Uncertified(1);
        }

        PerpFormula.World memory w = _world(p, inputs.volBpsAnnual, inputs.carryBpsAnnual);
        uint256 formulaBps = (PerpFormula.principal(w, x * WAD_PER_BPS, knockedIn) * BPS + WAD / 2) / WAD;
        // what the melting slice would pay if the fixing were now
        uint256 payBps = (knockedIn || x < p.kiBarrierBps) && x < BPS ? x : BPS;
        uint256 elapsed = uint256(p.fixingInterval) - inputs.timeToNextFixingSecs;
        // every factor is far below 2^64: no overflow; |result| <= 10_000
        // forge-lint: disable-start(unsafe-typecast)
        int256 accrual = int256(uint256(p.meltShare) * elapsed) * (int256(payBps) - int256(formulaBps))
            / int256(WAD * uint256(p.fixingInterval));
        return int16(accrual);
        // forge-lint: disable-end(unsafe-typecast)
    }

    function answer(PerpPricerInputs calldata inputs) external view returns (int16, PerpProduct memory, bytes32) {
        return (correctionBps(inputs), _product, weightsHash);
    }

    /// Spot: the whole range of its type.
    function certifiedRange(uint8 field) external view returns (int64 min, int64 max) {
        if (field >= NUM_FIELDS) revert OutOfRange(field, int64(uint64(field)));
        if (field == 0) return (0, int64(uint64(type(uint16).max)));
        if (field == 1) return (int64(uint64(_bands.volMinBps)), int64(uint64(_bands.volMaxBps)));
        if (field == 2) return (0, int64(uint64(_product.fixingInterval)));
        if (field == 3) return (_bands.carryMinBps, _bands.carryMaxBps);
        return (0, 1);
    }

    /// The Desk's lines (IPerpPricer): the heal band, the strip, the buy-back discount and the
    /// minimum vol band.
    function lineBands() external view returns (LineBands memory) {
        Bands storage b = _bands;
        return LineBands(
            b.healBandBps, b.stripBelowBps, b.stripAboveBps, b.buyBackDiscountBps, b.discountReachBps, b.minVolBandBps
        );
    }

    function product() external view returns (PerpProduct memory) {
        return _product;
    }

    function bands() external view returns (Bands memory) {
        return _bands;
    }

    function featureSpecVersion() external pure returns (uint16) {
        return 3;
    }

    /// From `below` under `level` to `above` over it, edges included.
    function _within(uint256 x, uint256 level, uint256 below, uint256 above) internal pure returns (bool) {
        return x + below >= level && x <= level + above;
    }

    /// The closed form's world for product `p` at `volBps` and `carryBps`, exactly as PerpQuoter builds it.
    function _world(PerpProduct memory p, uint256 volBps, int256 carryBps)
        internal
        pure
        returns (PerpFormula.World memory)
    {
        uint256 dt = uint256(p.fixingInterval) * WAD / YEAR;
        return PerpFormula.World({
            sigma: volBps * WAD_PER_BPS,
            r: carryBps * SIGNED_WAD_PER_BPS,
            rho: int256(p.discountBps) * SIGNED_WAD_PER_BPS,
            phi: PerpFormula.meltRate(p.meltShare, dt),
            k: uint256(p.kiBarrierBps) * WAD_PER_BPS,
            dt: dt
        });
    }
}
