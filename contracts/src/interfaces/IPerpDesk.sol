// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";
import {IPerpQuoter} from "./IPerpQuoter.sol";
import {IPerpPricer} from "./IPerpPricer.sol";
import {IPerpFactory} from "./IPerpFactory.sol";

/// L3 of the v2 perpetual note: the market for both legs of a perpetual
/// series, and the pricer's only in-path use. The v1 Desk (removed in #40)
/// carried over: an ERC-4626 vault on USDC whose LPs fund a desk that sells
/// and buys back NOTE and COVER around the model's quote at two
/// prices, within a risk budget per feed. LP deposits and redemptions are
/// requests that settle at the market keeper's update (IDeskQueue). What is
/// different from v1:
///
/// Units. Trades are in tokens; prices are per unit of live notional, and a
/// token stands for `notionalPerToken / 1e27` of it (IPerpSeries), less after
/// each fixing. With notional = amount * notionalPerToken / 1e27:
///   buy, buyCover:   cost     = ceil(notional * priceBps / 1e4)  + fee
///   sell, sellCover: proceeds = floor(notional * priceBps / 1e4) - fee
///   fee: NOTE  ceil(floor(notional) * feeBps / 1e4), feeBps <= MAX_FEE_BPS
///        cover ceil(premium * feeBps / 1e4),         feeBps <= MAX_COVER_FEE_BPS
/// `capNotional` and the risk budget are in USDC of live notional too.
///
/// Price. NOTE = the quoter's price (closed form + model correction + coupon
/// reserve); cover = pairBps - NOTE, pairBps = (1e6 + couponReserve) / 100: a
/// pair redeems for that at any time. The two prices are the v1 rule: the
/// quoter is asked at the feed's vol -/+ the band (the spread's vol band, at
/// least the listing pricer's `minVolBandBps`: a series whose spread was never
/// set prices with that minimum) and the feed's carry (market data, below), lo
/// and hi are the lower and higher NOTE quote capped at pairBps, and
///   NOTE ask  = min(hi + askBps + discount, pairBps)   NOTE bid = lo - bidBps, floored at 0
///   cover ask = pairBps - NOTE bid                     cover bid = pairBps - NOTE ask
/// with discount the buy-back discount near the crash line (below), else 0.
///
/// Near a line (docs/v2-spec.md §8): the pricer's lines (IPerpPricer.lineBands)
/// around the crash line for a clean note and around the reference for a
/// knocked-in one, in bps of the reference as the quoter gives the spot to the
/// pricer (x), edges included; k the crash line. At any time of day (and in
/// `quote` too):
///  - in the crash line's strip (from `stripBelowBps` under it to
///    `stripAboveBps` over it), where a spot just under the line will likely
///    knock the note in at the next fixing and the closed form, pricing a clean
///    note, sells cover too cheaply: no side trades (`NearLine`);
///  - above the strip, short of `discountReachBps` above the line, where the
///    closed form prices NOTE too low and cover too high: the two sides priced
///    at the NOTE ask, `buy` (the Desk sells NOTE) and `sellCover` (it buys cover
///    back), at the discount ceil(D * (k + reach - x) / (reach - stripAboveBps)),
///    D = `buyBackDiscountBps`: D just above the strip, 0 at the reach; `sell`
///    and `buyCover` at their usual prices;
///  - near the high of a knocked-in note (within `healBandBps`), where the
///    closed form's error changes sign with the vol, no side trades
///    (`NearLine`), until the spot leaves the band or a fixing at or above the
///    high makes the note clean.
/// LP requests, the mark (`midPriceBps`, `totalAssets`, with no discount) and
/// `risk` go on. The pricer's refusals come first (in its fixing band near a
/// line: `Uncertified`, on all four sides), then `NearLine`, then
/// `TooCloseToFixing`.
///
/// Released cash. The Desk's NOTE and COVER earn USDC at every fixing
/// (IPerpSeries.claimable). It counts as an asset at once; `collect` pulls it.
/// Nothing settles: a position ends when it is sold, paired and redeemed, or
/// when the series closes and everything has been released.
///
/// Spot. Every price uses the live feed (the quoter's staleness limit): a
/// stale feed stops trades on its series and, while the Desk holds them, the
/// settlement of LP requests (totalAssets needs a price).
///
/// Market data, per feed (one coin): the vol and the carry every series on the
/// feed is quoted, marked and risk-checked at (`setMarkets`), and the time of the
/// source they come from (`sourceTime`). A feed without market data is not
/// quoted (`NoMarketData`), nor one whose data is older than `maxMarketAge`,
/// measured from its `sourceTime` (`MarketStale`): like a stale feed, that stops
/// trades on the feed's series and, while the Desk holds any of them, the
/// settlement of LP requests.
/// Every write needs 0 < sourceTime <= now. The owner writes anything, the
/// first value too, with any such sourceTime (older than the stored one too, so
/// a keeper write landing first can't block a recovery); the market keeper
/// (`keeper`, a role that can do nothing else) only writes a sourceTime after
/// the stored one, and only moves a feed that has data, by at most
/// `maxVolStepBps` and `maxCarryStepBps`, and at least `minUpdateGap` after the
/// feed's previous write on the chain's clock (`writtenAt`, which every write
/// sets, the owner's too): one step per gap however its writes are dated, so a
/// keeper back from a silence can't replay back-dated steps in one block. Any
/// value inside those bounds is accepted: a series whose vol -/+ band or carry lies
/// outside its pricer's ranges is simply not quoted (the pricer's `OutOfRange`;
/// a vol - band below 0 is asked at 0, a vol + band above 65,535 at 65,535, and
/// refused there). A keeper write that moves the vol or the carry by exactly its
/// step limit sets the feed's `atBound` (the keeper is still catching up with
/// the market), and so does an owner write (its values are no settlement
/// price); a keeper write by a smaller step clears it. Only the keeper's
/// call settles LP requests (IDeskQueue), after all its writes, and not while
/// a feed the Desk holds a position on is `atBound`.
///
/// Risk budget, per feed, in bps of vault assets, 0 until set:
///   atRisk = what the Desk's positions on that feed can still lose:
///            NOTE mark - its coupon reserve, COVER mark
/// While a series can't be quoted its positions count 1 USDC per unit of
/// notional at risk and its NOTE only its coupon reserve as an asset.
/// Settling LP requests needs every held series quoted at the mid: relisting a
/// held series to a pricer whose ranges exclude the feed's market data pauses
/// settlement until the listing or the market data is changed back.
///
/// FRONTENDS: as in v1, quotes do NOT apply the risk budget or look at the
/// queue: a quote gives the price during a `shortfall` too. Its `newPosition`
/// is the part of the trade that adds to the Desk's position. With the
/// slippage bound met (Slippage is checked first), the trade reverts
/// QueuePending exactly when `shortfall()` and `newPosition > 0`; and only
/// when `newPosition > 0` is the feed's risk after the trade (all its
/// positions) checked against `risk(feed)`'s limit. A trade with
/// `newPosition` 0 needs neither. Quotes do apply the near-line refusal: a
/// `quote` that reverts `NearLine` is a trade that would.
interface IPerpDesk is IERC4626 {
    /// Which leg the trader buys or sells.
    enum Side {
        BuyNote, // buy: the Desk sells NOTE
        SellNote, // sell: the Desk buys NOTE
        BuyCover, // buyCover: the Desk sells COVER and ends up with NOTE
        SellCover // sellCover: the Desk buys COVER
    }

    struct Listing {
        bool active;
        IPerpPricer pricer; // the model for this series' product (or a formula-only pricer)
        uint128 capNotional; // max COVER the Desk may hold in this series, USDC of live notional
    }

    struct Spread {
        uint16 bidBps; // below the model's lower NOTE quote when the Desk buys NOTE / sells cover
        uint16 askBps; // above its higher one when the Desk sells NOTE / buys cover back
        uint16 volBandBps; // as set (0: never set); the quotes are taken at the feed's vol -/+ the larger of
        // this and the listing pricer's minimum (LineBands.minVolBandBps), which a relisting may raise above it
    }

    /// One feed's market data (docs/v2-spec.md §8).
    struct Market {
        uint16 volBpsAnnual; // 1-year at-the-money implied vol
        int16 carryBpsAnnual; // the futures premium over spot per year: the closed form's r
        uint40 sourceTime; // the source's time for these values; 0: none yet, and the feed's series are not quoted
        uint40 writtenAt; // the block time of the last write: the keeper's gap counts from it
        bool atBound; // the last write was the owner's, or the keeper's by its full step limit
    }

    /// One feed's write in `setMarkets`.
    struct MarketUpdate {
        address feed;
        uint16 volBpsAnnual;
        int16 carryBpsAnnual;
        uint40 sourceTime; // the source's time for these values
        bytes32 source; // the source's name (the event only), e.g. "options"
    }

    /// The owner's limits on market data (docs/v2-spec.md §8): its age, and the keeper's writes.
    struct MarketLimits {
        uint32 maxMarketAge; // older than this, from its sourceTime, it is stale
        uint16 maxVolStepBps; // a keeper write moves the vol by at most this
        uint16 maxCarryStepBps; // and the carry by at most this
        uint32 minUpdateGap; // and comes at least this long after the feed's previous write (writtenAt)
    }

    /// Emitted on listing and on every update (new model or cap).
    event SeriesListed(address indexed series, address indexed pricer, bytes32 weightsHash, uint128 capNotional);
    /// New market data for `feed`: the values, and the source's own time and name (e.g. "options"),
    /// so anyone can recompute them.
    event MarketSet(address indexed feed, uint16 volBpsAnnual, int16 carryBpsAnnual, uint40 sourceTime, bytes32 source);
    event KeeperSet(address indexed keeper);
    event MarketLimitsSet(uint32 maxMarketAge, uint16 maxVolStepBps, uint16 maxCarryStepBps, uint32 minUpdateGap);
    event SeriesDelisted(address indexed series);
    event SpreadSet(address indexed series, uint16 bidBps, uint16 askBps, uint16 volBandBps);
    event RiskBudgetSet(address indexed feed, uint16 budgetBps);
    event MinSecsToFixingSet(uint32 secs);
    /// One event for all four trades. `amount` tokens = `notional` USDC of live notional;
    /// `priceBps` is the price applied to that leg, spread included; `paid` is the cost of a
    /// buy or the proceeds of a sell, fee included; `weightsHash` is the model that priced it.
    event Traded(
        address indexed series,
        address indexed trader,
        Side indexed side,
        address to,
        uint256 amount,
        uint256 notional,
        uint16 priceBps,
        uint256 paid,
        uint16 feeBps,
        address feeReceiver,
        bytes32 weightsHash
    );
    /// USDC pulled from the series: released cash, plus pairs the Desk held and redeemed.
    event Collected(address indexed series, uint256 collateralOut);

    error NotListed(address series);
    error NotFactorySeries(address series);
    /// The series is not the pricer's product (0 knock-in, 1 melt share, 2 interval).
    error ModelMismatch(uint8 field);
    /// The series' feed has no market data yet: nothing on it is quoted (and the keeper can't write it).
    error NoMarketData(address feed);
    /// The feed's market data is older than maxMarketAge: nothing on it is quoted.
    error MarketStale(address feed, uint40 sourceTime);
    /// A market data write with a sourceTime in the future or 0, or a keeper's not after the stored one.
    error BadSourceTime(uint40 sourceTime);
    /// A keeper write less than minUpdateGap after the feed's previous write (block time).
    error MarketUpdateTooSoon();
    /// A keeper write that moves the vol or the carry by more than its step.
    error MarketStepTooLarge();
    /// minUpdateGap 0, or not below maxMarketAge, or maxMarketAge above a day.
    error BadMarketLimits();
    error CapExceeded(uint256 requested, uint256 available); // in tokens
    error FeeTooHigh(uint16 feeBps);
    error Slippage(uint256 actual, uint256 limit);
    error TooCloseToFixing(uint40 fixingTime); // the band before each fixing
    /// A trade (or its quote) near a line: any side in the crash line's strip (clean) or near the
    /// reference (knocked in). `spotBps` is the spot in bps of the reference.
    error NearLine(uint256 spotBps);
    error SpreadTooWide(uint16 spreadBps);
    /// setSpread with a vol band below the listing pricer's minimum (LineBands.minVolBandBps); or
    /// listSeries with a pricer whose buy-back discount comes with no minimum vol band (argument 0).
    error VolBandTooNarrow(uint16 minVolBandBps);
    error BudgetTooHigh(uint16 budgetBps);
    error RiskBudgetExceeded(uint256 atRisk, uint256 limit);
    error ZeroAmount();
    /// setKeeper (or the constructor) with the owner as the keeper: the owner's writes never
    /// settle LP requests, so as the keeper too it would leave them unsettled.
    error KeeperIsOwner();
    // plus IPerpQuoter errors and the model's OutOfRange / Uncertified, bubbled up

    function factory() external view returns (IPerpFactory);
    function quoter() external view returns (IPerpQuoter);
    function MAX_FEE_BPS() external view returns (uint16);
    function MAX_COVER_FEE_BPS() external view returns (uint16);
    function BACKSTOP_SHARE_BPS() external view returns (uint16);
    function MAX_SPREAD_BPS() external view returns (uint16);
    function minSecsToFixing() external view returns (uint32);
    /// The market keeper: it can only write market data, within the limits below (address(0): none).
    function keeper() external view returns (address);
    /// The limits (a `MarketLimits`).
    function maxMarketAge() external view returns (uint32);
    function maxVolStepBps() external view returns (uint16);
    function maxCarryStepBps() external view returns (uint16);
    function minUpdateGap() external view returns (uint32);

    function listing(address series) external view returns (Listing memory);
    function listedSeries() external view returns (address[] memory); // delisted ones included
    function heldSeries() external view returns (address[] memory);
    function spread(address series) external view returns (Spread memory);
    function riskBudgetBps(address feed) external view returns (uint16);
    /// The feed's market data (a `Market`); sourceTime 0: none yet. It may be stale (maxMarketAge).
    function market(address feed)
        external
        view
        returns (uint16 volBpsAnnual, int16 carryBpsAnnual, uint40 sourceTime, uint40 writtenAt, bool atBound);

    /// The NOTE mid per unit of live notional at the feed's vol and carry and the live feed's
    /// spot: what `totalAssets` and the risk budget mark positions at. Reverts where a quote would.
    function midPriceBps(address series) external view returns (uint16);

    /// What the Desk's positions on `feed` can lose, and the budget's limit, in USDC base units.
    function risk(address feed) external view returns (uint256 atRisk, uint256 limit);

    /// What a trade of `amount` tokens on `side` pays now: the cost of a buy or the proceeds
    /// of a sell, fee included, and the price applied to that leg; and `newPosition`, in
    /// tokens like `amount`, the part of it the Desk can't serve from or pair with what it
    /// holds and so puts new USDC into: BuyNote and SellCover leave the Desk `newPosition` more
    /// COVER (they draw on its NOTE), SellNote and BuyCover `newPosition` more NOTE (they draw
    /// on its COVER); 0: all from stock, `amount`: all new. Reverts where the trade would for
    /// its price (the pricer, a line: NearLine, TooCloseToFixing, stale data, ...), fee or cap
    /// (CapExceeded). It does not apply the queue or the risk budget, which only a trade with
    /// `newPosition > 0` meets: with the slippage bound met (Slippage is checked first), the
    /// trade reverts QueuePending exactly when `shortfall()` and `newPosition > 0`, and only
    /// when `newPosition > 0` is the feed's risk after the trade checked against the budget
    /// (RiskBudgetExceeded: a feed already over budget refuses even a tiny new part). Such a
    /// trade also needs the Desk's idle USDC (ReservedForClaims, or the USDC transfer fails)
    /// and a place among its held series (HeldSeriesLimit, 64 at most). So during a shortfall
    /// a quote still gives the price, and a trade from stock still goes through.
    function quote(address series, Side side, uint256 amount, uint16 feeBps)
        external
        view
        returns (uint256 paid, uint16 priceBps, uint256 newPosition);

    /// Buyer pays `cost` USDC (approve the Desk) and receives `amount` NOTE at `to`. Needs an active
    /// listing; refused near either line (NearLine); above the crash line's strip at the buy-back
    /// discount.
    function buy(address series, uint256 amount, uint256 maxCost, uint16 feeBps, address feeReceiver, address to)
        external
        returns (uint256 cost);

    /// Seller hands in `amount` NOTE (approve the Desk) and receives `proceeds` USDC at `to`.
    /// Refused in the crash line's strip and near the high of a knocked-in note (NearLine).
    function sell(address series, uint256 amount, uint256 minProceeds, uint16 feeBps, address feeReceiver, address to)
        external
        returns (uint256 proceeds);

    /// Buyer pays the premium (approve the Desk) and receives `amount` COVER at `to`; the Desk keeps the NOTE.
    /// Refused in the crash line's strip and near the high of a knocked-in note (NearLine).
    function buyCover(address series, uint256 amount, uint256 maxCost, uint16 feeBps, address feeReceiver, address to)
        external
        returns (uint256 cost);

    /// Seller hands in `amount` COVER (approve the Desk) and receives `proceeds` USDC at `to`.
    /// Refused near either line (NearLine); above the crash line's strip at the buy-back discount.
    function sellCover(
        address series,
        uint256 amount,
        uint256 minProceeds,
        uint16 feeBps,
        address feeReceiver,
        address to
    ) external returns (uint256 proceeds);

    /// Permissionless: pull the USDC released to the Desk's NOTE and COVER, and redeem any pairs it holds.
    function collect(address series) external returns (uint256 collateralOut);

    // --- market data (the owner or the keeper) -------------------------------
    /// Writes each update's feed: its vol and carry, as of `sourceTime` (stored: the data's age
    /// counts from it) from `source` (the event only), and the block time as `writtenAt`, in
    /// order (MarketSet each). sourceTime must be > 0 and <= now (BadSourceTime). The owner's
    /// write is not bounded otherwise: any values, any gap, a sourceTime older than the stored
    /// one too; it sets `atBound` (no settlement at its values until the keeper's own write of
    /// the feed). The keeper's needs data on the feed already (NoMarketData), a block time at
    /// least minUpdateGap after the feed's previous write (MarketUpdateTooSoon, so one write per
    /// feed per call), moves of at most maxVolStepBps and maxCarryStepBps (MarketStepTooLarge),
    /// and a sourceTime after the stored one (BadSourceTime); it sets `atBound` when a move is
    /// exactly its limit and clears it otherwise. Anyone else: OwnableUnauthorizedAccount. Then,
    /// on the keeper's call only, the due LP requests settle (IDeskQueue); a settlement that
    /// can't run is skipped, never reverting the writes.
    function setMarkets(MarketUpdate[] calldata updates) external;

    // --- curator (owner) -----------------------------------------------------
    /// Lists a series or updates its listing. The series comes from `factory`, and its knock-in,
    /// melt share and interval are the pricer's product. Vol and carry are the feed's market data.
    /// The pricer must answer `lineBands()` (a pricer without it reverts here, not in a trade), and
    /// a buy-back discount needs a minimum vol band (VolBandTooNarrow(0)).
    function listSeries(address series, IPerpPricer pricer, uint128 capNotional) external;
    function delistSeries(address series) external; // stops new buys; sells still allowed
    /// The spread of a listed series: bid and ask at most MAX_SPREAD_BPS (SpreadTooWide), the vol
    /// band at least the listing pricer's minVolBandBps (VolBandTooNarrow).
    function setSpread(address series, uint16 bidBps, uint16 askBps, uint16 volBandBps) external;
    function setRiskBudget(address feed, uint16 budgetBps) external;
    function setMinSecsToFixing(uint32 secs) external;
    /// address(0) removes the keeper.
    function setKeeper(address keeper) external;
    /// Sets maxMarketAge, maxVolStepBps, maxCarryStepBps and minUpdateGap (MarketLimitsSet):
    /// 0 < gap < maxAge <= 1 day (BadMarketLimits), any steps (0: the keeper can only refresh
    /// the time; 65,535: no bound). They apply at once, to data already written too: a longer
    /// maxAge reopens quotes on data that was stale.
    function setMarketLimits(uint32 maxAge, uint16 volStepBps, uint16 carryStepBps, uint32 gap) external;
}
