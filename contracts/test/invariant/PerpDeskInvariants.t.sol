// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Vm} from "forge-std/Vm.sol";
import {MockChainlinkFeed} from "../mocks/MockChainlinkFeed.sol";
import {MockUSDC} from "../mocks/MockUSDC.sol";
import {PerpFactory} from "../../src/PerpFactory.sol";
import {IPerpFactory} from "../../src/interfaces/IPerpFactory.sol";
import {PerpSeries} from "../../src/PerpSeries.sol";
import {PerpQuoter} from "../../src/PerpQuoter.sol";
import {PerpDesk} from "../../src/PerpDesk.sol";
import {PerpFormulaPricer} from "../../src/PerpFormulaPricer.sol";
import {FixingsRecorder} from "../../src/FixingsRecorder.sol";
import {IPerpDesk} from "../../src/interfaces/IPerpDesk.sol";
import {IDeskQueue} from "../../src/interfaces/IDeskQueue.sol";
import {IPerpQuoter} from "../../src/interfaces/IPerpQuoter.sol";
import {IPerpPricer, LineBands, PerpProduct} from "../../src/interfaces/IPerpPricer.sol";
import {PerpTerms, PerpState, PerpPhase} from "../../src/interfaces/IPerpSeries.sol";

/// Drives a perpetual Desk on one listed series (priced by the closed form)
/// with random trades on both legs, fixings (some of them knock the note in or
/// ratchet the reference), spot moves, the feed's market data (vol and carry,
/// inside the pricer's ranges: from the owner, and from the market keeper in
/// steps within its bounds, which also refreshes it as time passes and settles
/// the LP requests), time, LP requests (deposits and redemptions; cancels tried
/// at any time; the ERC-4626 entry points tried too), collects and claims. A
/// call the Desk may refuse for a stated reason is caught; any other revert (a
/// panic, an unexpected error) is recorded and fails the run. Every keeper
/// update is checked against the mark right after its writes (the same writes
/// by the owner, which never settle, in a snapshot): a settlement must run at
/// that mark and leave the price per share no lower. Every other action is
/// checked to leave totalSupply alone.
contract PerpDeskHandler is Test {
    uint256 internal constant INITIAL = 100e8;

    MockUSDC public usdc;
    MockChainlinkFeed public feed;
    PerpSeries public series;
    PerpDesk public desk;
    IPerpPricer public pricer;
    IERC20 public note;
    IERC20 public cover;
    address[] public actors;
    address public lp = makeAddr("lp");
    address public integrator = makeAddr("integrator");

    uint256 public level = 9000; // spot, bps of INITIAL
    uint256 public minted; // every USDC that exists
    bytes4 public unexpected; // the first revert that is not a stated refusal
    uint256 public calls;
    uint256 public trades;
    uint256 public keeperWrites;
    uint256 public nearLineRefusals;
    bool public tradedNearLine; // a trade the near-line rule refuses went through
    uint256 public buyBacksChecked; // buy-back quotes checked against the discount
    uint256 public buyBacksDiscounted; // ... with a discount above 0
    bool public buyBackMispriced; // a buy-back's NOTE ask was not the undiscounted one plus the discount
    // quote's newPosition (#68): every trade is quoted first
    uint256 public tradesWaiting; // trades refused QueuePending, as their quote's newPosition said
    uint256 public tradesInShortfall; // trades that went through in a shortfall: newPosition 0
    bool public newPositionBroken; // a quote's newPosition was not amount - min(amount, the Desk's stock),
    // a trade moved the Desk's legs otherwise, or reverted QueuePending other than exactly when
    // shortfall() and newPosition > 0

    // LP requests (IDeskQueue): every request is filled, cancelled or pending
    uint256 public depositsRequested; // USDC
    uint256 public depositsFilled;
    uint256 public depositsCancelled;
    uint256 public sharesRequested;
    uint256 public sharesFilled;
    uint256 public sharesCancelled;
    uint256 public settlementsRun; // keeper updates that settled (Settled)
    uint256 public settlementsFilling; // ... and filled at least one request
    uint256 public cancels; // cancels that went through
    bool public priceFell; // a settlement left the price per share below the mark it settled at
    bool public settledWithoutMark; // a settlement ran (or filled) where the mark after the writes reverted
    bool public supplyMovedOutsideKeeper; // totalSupply changed outside a keeper update
    bool public instantFlowWorked; // a max* was not 0, or an ERC-4626 entry point did not revert AsyncOnly
    bool public cancelledEarly; // a cancel went through before STALL past due, or returned another amount
    bool public stepAtAdvance; // series.advance() moved totalAssets
    bool public shortfallStuck; // a settlement left the redemption queue empty and shortfall set
    int256 internal _keeperSupplyDelta; // the keeper updates' share of the current action's supply change
    bytes32 internal constant SETTLED = keccak256("Settled(uint40,uint256,uint256)");

    /// totalSupply moves only in the keeper's updates within the action.
    modifier supplyByKeeperOnly() {
        _keeperSupplyDelta = 0;
        uint256 s0 = desk.totalSupply();
        _;
        if (int256(desk.totalSupply()) - int256(s0) != _keeperSupplyDelta) supplyMovedOutsideKeeper = true;
    }

    constructor(MockUSDC usdc_, MockChainlinkFeed feed_, PerpSeries series_, PerpDesk desk_, IPerpPricer pricer_) {
        usdc = usdc_;
        feed = feed_;
        series = series_;
        desk = desk_;
        pricer = pricer_;
        note = IERC20(series_.note());
        cover = IERC20(series_.cover());
        actors.push(makeAddr("actor0"));
        actors.push(makeAddr("actor1"));
        actors.push(makeAddr("actor2"));
        for (uint256 i = 0; i < actors.length; i++) {
            _fund(actors[i], 1_000_000e6);
            vm.startPrank(actors[i]);
            usdc.approve(address(desk), type(uint256).max);
            note.approve(address(desk), type(uint256).max);
            cover.approve(address(desk), type(uint256).max);
            vm.stopPrank();
        }
        // the LP's first deposit: requested now, due an hour later, settled by the keeper's update
        _fund(lp, 2_000_000e6);
        vm.startPrank(lp);
        usdc.approve(address(desk), type(uint256).max);
        desk.requestDeposit(1_000_000e6);
        vm.stopPrank();
        depositsRequested = 1_000_000e6;
        vm.warp(block.timestamp + desk.DELAY());
        _push(uint40(block.timestamp));
        (uint16 vol, int16 carry,,,) = desk.market(address(feed));
        _keeperCall(vol, carry, uint40(block.timestamp), false); // no snapshot inside a constructor
        require(desk.balanceOf(lp) != 0, "the LP's first deposit did not settle");
    }

    /// A feed round at the walk's level (the feed takes rounds from its owner only).
    function _push(uint40 time) internal {
        vm.prank(feed.owner());
        feed.pushRoundAt(int256(INITIAL * level / 10_000), time);
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        minted += amount;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actor(uint256 i) external view returns (address) {
        return actors[i];
    }

    /// A refusal the Desk, the quoter or a token states on purpose.
    function _note(bytes memory err) internal {
        bytes4 sel = bytes4(err);
        if (
            sel == IPerpQuoter.FeedStale.selector || sel == IPerpQuoter.FixingPending.selector
                || sel == IPerpQuoter.NotLive.selector || sel == IPerpDesk.MarketStale.selector
                || sel == IPerpDesk.TooCloseToFixing.selector || sel == IPerpDesk.RiskBudgetExceeded.selector
                || sel == IPerpDesk.CapExceeded.selector || sel == IPerpDesk.Slippage.selector
                || sel == IDeskQueue.QueuePending.selector || sel == IDeskQueue.ReservedForClaims.selector
                || sel == IDeskQueue.RequestTooSmall.selector || sel == IDeskQueue.RestTooSmall.selector
                || sel == IDeskQueue.NothingToClaim.selector || sel == IERC20Errors.ERC20InsufficientBalance.selector
                || sel == IPerpDesk.ZeroAmount.selector || sel == IPerpPricer.Uncertified.selector
        ) return;
        if (unexpected == bytes4(0)) unexpected = sel == bytes4(0) ? bytes4(0xffffffff) : sel;
    }

    /// A trade is also refused near a line (NearLine), and only where the Desk's rule says so.
    function _noteTrade(bytes memory err) internal {
        if (bytes4(err) != IPerpDesk.NearLine.selector) {
            _note(err);
        } else {
            if (!_refusedNearLine() && unexpected == bytes4(0)) unexpected = IPerpDesk.NearLine.selector;
            nearLineRefusals++;
        }
    }

    /// A trade went through: the Desk's rule must not refuse it.
    function _traded() internal {
        trades++;
        if (_refusedNearLine()) tradedNearLine = true;
    }

    /// The spot in bps of the high, as the quoter gives it to the pricer.
    function _spotBps(PerpState memory st) internal view returns (uint256) {
        (, int256 answer,,,) = feed.latestRoundData();
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(answer) * 10_000 / st.referenceFixing; // the walk keeps the answer positive
    }

    /// The Desk's rule (docs/v2-spec.md §8), from the series, the feed and the pricer's bands,
    /// with the spot in bps of the high, edges included: clean, every side in the crash line's
    /// strip (from stripBelowBps under it to stripAboveBps over it); knocked in, every side within
    /// healBandBps of the high. (Above the strip a buy-back trades at a discount: `_checkBuyBack`.)
    function _refusedNearLine() internal view returns (bool) {
        PerpState memory st = series.state();
        uint256 x = _spotBps(st);
        LineBands memory b = pricer.lineBands();
        if (st.knockedIn) return _distance(x, 10_000) <= b.healBandBps;
        uint256 k = series.terms().kiBarrierBps;
        return x + b.stripBelowBps >= k && x <= k + b.stripAboveBps;
    }

    /// A buy-back (`side` 0, `buy`, or 3, `sellCover`) that quotes pays the NOTE ask
    /// min(hi + askBps + d, pairBps), never less: hi the higher NOTE quote at the feed's vol -/+ the
    /// vol band (at least the pricer's minimum) and d the discount, for a clean note from the strip's
    /// upper edge to the reach, ceil(D * (k + reach - x) / (reach - stripAbove)), else 0; so a cover
    /// sold back pays at most the undiscounted bid less d. Rebuilt here from the quoter.
    function _checkBuyBack(uint8 side, uint256 amount, uint16 feeBps) internal {
        try desk.quote(address(series), IPerpDesk.Side(side), amount, feeBps) returns (
            uint256, uint16 priceBps, uint256
        ) {
            uint256 pairBps = (1e6 + uint256(series.terms().couponReserve)) / 100;
            uint256 ask = side == 0 ? priceBps : pairBps - priceBps;
            uint256 want = _discountedAsk(pairBps);
            buyBacksChecked++;
            if (ask != want) buyBackMispriced = true;
        } catch {}
    }

    function _discountedAsk(uint256 pairBps) internal returns (uint256) {
        PerpState memory st = series.state();
        LineBands memory b = pricer.lineBands();
        uint256 d;
        uint256 k = series.terms().kiBarrierBps;
        uint256 x = _spotBps(st);
        if (!st.knockedIn && x > k + b.stripAboveBps && x < k + b.discountReachBps) {
            uint256 span = b.discountReachBps - b.stripAboveBps;
            d = (uint256(b.buyBackDiscountBps) * (k + b.discountReachBps - x) + span - 1) / span;
            buyBacksDiscounted++;
        }
        IPerpDesk.Spread memory sp = desk.spread(address(series));
        uint16 band = sp.volBandBps < b.minVolBandBps ? b.minVolBandBps : sp.volBandBps;
        (uint16 vol, int16 carry,,,) = desk.market(address(feed));
        uint256 a = desk.quoter().quote(series, pricer, vol > band ? vol - band : 0, carry).priceBps;
        uint256 c = desk.quoter().quote(series, pricer, vol + band, carry).priceBps;
        uint256 ask = (a > c ? a : c) + sp.askBps + d;
        return ask < pairBps ? ask : pairBps;
    }

    function _distance(uint256 a, uint256 b) internal pure returns (uint256) {
        return a > b ? a - b : b - a;
    }

    // --- trades -----------------------------------------------------------------------

    function buy(uint256 actorSeed, uint256 amount, uint16 feeBps, bool isCover) external supplyByKeeperOnly {
        calls++;
        _tryBuy(actorSeed, amount, feeBps, isCover);
    }

    function _tryBuy(uint256 actorSeed, uint256 amount, uint16 feeBps, bool isCover) internal {
        address a = actors[actorSeed % actors.length];
        amount = bound(amount, 1, 20_000e6);
        feeBps = uint16(bound(feeBps, 0, 200));
        if (!isCover) _checkBuyBack(0, amount, feeBps);
        Quoted memory q = _quoted(isCover ? 2 : 0, amount, feeBps);
        vm.prank(a);
        if (isCover) {
            try desk.buyCover(address(series), amount, type(uint256).max, feeBps, integrator, a) {
                _tradedAsQuoted(q);
            } catch (bytes memory err) {
                _refusedAsQuoted(q, err);
            }
        } else {
            try desk.buy(address(series), amount, type(uint256).max, feeBps, integrator, a) {
                _tradedAsQuoted(q);
            } catch (bytes memory err) {
                _refusedAsQuoted(q, err);
            }
        }
    }

    function sell(uint256 actorSeed, uint256 amount, uint16 feeBps, bool isCover) external supplyByKeeperOnly {
        calls++;
        _trySell(actorSeed, amount, feeBps, isCover);
    }

    function _trySell(uint256 actorSeed, uint256 amount, uint16 feeBps, bool isCover) internal {
        address a = actors[actorSeed % actors.length];
        uint256 bal = (isCover ? cover : note).balanceOf(a);
        if (bal == 0) return;
        amount = bound(amount, 1, bal);
        feeBps = uint16(bound(feeBps, 0, 200));
        if (isCover) _checkBuyBack(3, amount, feeBps);
        Quoted memory q = _quoted(isCover ? 3 : 1, amount, feeBps);
        vm.prank(a);
        if (isCover) {
            try desk.sellCover(address(series), amount, 0, feeBps, integrator, a) {
                _tradedAsQuoted(q);
            } catch (bytes memory err) {
                _refusedAsQuoted(q, err);
            }
        } else {
            try desk.sell(address(series), amount, 0, feeBps, integrator, a) {
                _tradedAsQuoted(q);
            } catch (bytes memory err) {
                _refusedAsQuoted(q, err);
            }
        }
    }

    /// A trade's quote and the Desk's two legs, read just before it (#68).
    struct Quoted {
        bool ok; // the quote answered
        uint256 amount;
        uint256 newPosition;
        bool waits; // shortfall() and newPosition > 0: the trade must revert QueuePending
        IERC20 draws; // the leg the trade is served from or paired with: NOTE for buy and sellCover
        uint256 stock; // the Desk's balance of it
        IERC20 grows; // the other leg, which a new position adds to
        uint256 held; // the Desk's balance of it
    }

    /// The quote, checked against the expectation rebuilt from the Desk's balances: newPosition is
    /// what its stock of the leg the trade draws on can't serve, amount - min(amount, stock).
    function _quoted(uint8 side, uint256 amount, uint16 feeBps) internal returns (Quoted memory q) {
        try desk.quote(address(series), IPerpDesk.Side(side), amount, feeBps) returns (uint256, uint16, uint256 n) {
            (q.ok, q.newPosition) = (true, n);
        } catch {}
        q.amount = amount;
        (q.draws, q.grows) = side == 0 || side == 3 ? (note, cover) : (cover, note);
        q.stock = q.draws.balanceOf(address(desk));
        q.held = q.grows.balanceOf(address(desk));
        if (q.ok && q.newPosition != amount - (amount < q.stock ? amount : q.stock)) newPositionBroken = true;
        q.waits = q.ok && q.newPosition != 0 && desk.shortfall();
    }

    /// The trade went through: its quote answered and said it doesn't wait; the Desk now holds
    /// exactly newPosition more of the leg it grows, and the rest less of the leg it drew on.
    function _tradedAsQuoted(Quoted memory q) internal {
        if (
            !q.ok || q.waits || q.grows.balanceOf(address(desk)) != q.held + q.newPosition
                || q.draws.balanceOf(address(desk)) + (q.amount - q.newPosition) != q.stock
        ) newPositionBroken = true;
        if (desk.shortfall()) tradesInShortfall++;
        _traded();
    }

    /// The trade reverted: QueuePending exactly when its quote said it waits.
    function _refusedAsQuoted(Quoted memory q, bytes memory err) internal {
        bool queued = bytes4(err) == IDeskQueue.QueuePending.selector;
        if (queued != q.waits) newPositionBroken = true;
        if (queued) tradesWaiting++;
        _noteTrade(err);
    }

    // --- the market ---------------------------------------------------------------------

    /// A fresh round at a level that walks -8% .. +8%.
    function spot(uint256 move) external supplyByKeeperOnly {
        calls++;
        level = bound(level * bound(move, 9200, 10_800) / 10_000, 2500, 20_000);
        vm.warp(block.timestamp + 1);
        _push(uint40(block.timestamp));
    }

    /// One trade where the near-line rule applies, which the walk alone seldom reaches: a fresh
    /// round there, the trade, and a fresh round back at the walk's level a second later. The walk
    /// doesn't move, so neither do the fixings and knock-ins the other invariants see. Clean, the
    /// spot from 11% of the high under the crash line to 1% past the discount's reach: the strip,
    /// the discount's whole taper, its end and every edge. Knocked in (no discount anywhere), half
    /// the time from just above the strip to just short of the reach, where a clean note would
    /// get it, half the time from just above the heal band to 1% past the reach above the high.
    function tradeNearTheLine(uint256 offset, uint256 actorSeed, uint256 amount, uint16 feeBps, uint8 side)
        external
        supplyByKeeperOnly
    {
        calls++;
        PerpState memory st = series.state();
        if (st.phase != PerpPhase.Live) return;
        LineBands memory b = pricer.lineBands();
        uint256 k = series.terms().kiBarrierBps;
        uint256 x; // bps of the high
        if (!st.knockedIn) {
            x = k - 1100 + bound(offset, 0, 1200 + uint256(b.discountReachBps));
        } else if (offset % 2 == 0) {
            x = k + b.stripAboveBps + 1 + bound(offset, 0, b.discountReachBps - b.stripAboveBps - 2);
        } else {
            x = 10_000 + b.healBandBps + 1 + bound(offset, 0, uint256(b.discountReachBps) + 99 - b.healBandBps);
        }
        uint256 walk = level;
        uint256 l = x * st.referenceFixing / INITIAL; // as the walk's level: bps of INITIAL
        level = l < 2500 ? 2500 : l > 20_000 ? 20_000 : l; // clamped, not wrapped
        vm.warp(block.timestamp + 1);
        _push(uint40(block.timestamp));
        if (side % 2 == 0) _tryBuy(actorSeed, amount, feeBps, side % 4 == 2);
        else _trySell(actorSeed, amount, feeBps, side % 4 == 3);
        level = walk;
        vm.warp(block.timestamp + 1);
        _push(uint40(block.timestamp));
    }

    /// Time passes (up to 3/7 of the fixing interval: 3 days at weekly fixings, ~10 hours at daily); a
    /// fresh round and the keeper's refresh follow two times out of three.
    function warp(uint256 secs, uint256 move) external supplyByKeeperOnly {
        calls++;
        vm.warp(block.timestamp + bound(secs, 1, uint256(series.terms().fixingInterval) * 3 / 7));
        if (move % 3 != 0) {
            _push(uint40(block.timestamp));
            _keeperRefresh();
        }
    }

    /// The next fixing: jump to its time, fix at a level that walks -25% .. +15%, record it.
    function fixing(uint256 move) external supplyByKeeperOnly {
        calls++;
        PerpState memory st = series.state();
        if (st.phase != PerpPhase.Live) return;
        uint40 t = st.nextFixing;
        // forge-lint: disable-next-line(unsafe-typecast)
        (,,, uint256 updatedAt,) = feed.latestRoundData();
        if (updatedAt >= t) return; // a later round exists already: this fixing is recorded by `record`
        level = bound(level * bound(move, 7500, 11_500) / 10_000, 2500, 20_000);
        if (block.timestamp <= t) vm.warp(uint256(t) + 1);
        _push(t);
        FixingsRecorder(address(series.recorder())).recordFixing(t, uint80(feed.latestRound()));
        _push(uint40(block.timestamp));
        _keeperRefresh();
    }

    /// Processing a recorded fixing doesn't move totalAssets: the views include it already, so
    /// the daily fixing is no step in the share price to time.
    function advance() external supplyByKeeperOnly {
        calls++;
        (bool p0, uint256 a0) = _nav();
        series.advance();
        (bool p1, uint256 a1) = _nav();
        if (p0 && (!p1 || a1 != a0)) stepAtAdvance = true;
    }

    /// New market data from the owner: a vol and a carry anywhere in the pricer's ranges that keep
    /// the vol band inside them, so the series stays quotable (refusals have their own tests),
    /// sourced now.
    function market(uint256 volSeed, uint256 carrySeed) external supplyByKeeperOnly {
        calls++;
        (int64 volMin, int64 volMax) = pricer.certifiedRange(1);
        (int64 carryMin, int64 carryMax) = pricer.certifiedRange(3);
        uint256 band = desk.spread(address(series)).volBandBps;
        // forge-lint: disable-start(unsafe-typecast)
        uint16 vol = uint16(bound(volSeed, uint256(uint64(volMin)) + band, uint256(uint64(volMax)) - band));
        int16 carry = int16(int256(bound(carrySeed, 0, uint256(int256(carryMax - carryMin)))) + carryMin);
        // forge-lint: disable-end(unsafe-typecast)
        uint256 pending0 = desk.pendingDepositAssets();
        uint256 queued0 = desk.queuedShares();
        vm.prank(desk.owner());
        desk.setMarkets(_update(vol, carry, uint40(block.timestamp), "handler"));
        // an owner write never settles
        if (desk.pendingDepositAssets() != pending0 || desk.queuedShares() != queued0) settledWithoutMark = true;
    }

    /// New market data from the keeper: a step within its bounds (and inside the pricer's ranges
    /// as above), sourced any time after the last sourceTime up to now; it waits out its gap (on
    /// the chain's clock, from the last write) if it must.
    function keeperMarket(int256 volSeed, int256 carrySeed, uint256 timeSeed) external supplyByKeeperOnly {
        calls++;
        (uint16 vol0, int16 carry0, uint40 last, uint40 writtenAt,) = desk.market(address(feed));
        uint256 earliest = uint256(writtenAt) + desk.minUpdateGap();
        if (block.timestamp < earliest) vm.warp(earliest);
        uint16 vol = _keeperVol(volSeed, vol0);
        int16 carry = _keeperCarry(carrySeed, carry0);
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 t = uint40(bound(timeSeed, uint256(last) + 1, block.timestamp));
        _keeperCall(vol, carry, t, true);
    }

    /// A vol within the keeper's step of `vol0` that keeps the vol band in the pricer's range.
    function _keeperVol(int256 seed, uint16 vol0) internal view returns (uint16) {
        (int64 volMin, int64 volMax) = pricer.certifiedRange(1);
        int256 band = int256(uint256(desk.spread(address(series)).volBandBps));
        int256 step = int256(uint256(desk.maxVolStepBps()));
        int256 v = int256(uint256(vol0));
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint16(uint256(bound(seed, _max(v - step, volMin + band), _min(v + step, volMax - band))));
    }

    /// A carry within the keeper's step of `carry0`, in the pricer's range.
    function _keeperCarry(int256 seed, int16 carry0) internal view returns (int16) {
        (int64 carryMin, int64 carryMax) = pricer.certifiedRange(3);
        int256 step = int256(uint256(desk.maxCarryStepBps()));
        // forge-lint: disable-next-line(unsafe-typecast)
        return int16(bound(seed, _max(carry0 - step, carryMin), _min(carry0 + step, carryMax)));
    }

    /// The keeper's hourly job: the same values sourced now, once its gap allows; it settles.
    function _keeperRefresh() internal {
        (uint16 vol, int16 carry,, uint40 writtenAt,) = desk.market(address(feed));
        if (block.timestamp < uint256(writtenAt) + desk.minUpdateGap()) return;
        _keeperCall(vol, carry, uint40(block.timestamp), true);
    }

    function _update(uint16 vol, int16 carry, uint40 sourceTime, bytes32 source)
        internal
        view
        returns (IPerpDesk.MarketUpdate[] memory u)
    {
        u = new IPerpDesk.MarketUpdate[](1);
        u[0] = IPerpDesk.MarketUpdate({
            feed: address(feed), volBpsAnnual: vol, carryBpsAnnual: carry, sourceTime: sourceTime, source: source
        });
    }

    /// The keeper's update (never reverts for the settlement's sake: fail_on_revert). With `check`,
    /// the mark right after the writes is taken first, in a snapshot where the owner makes the same
    /// writes (an owner write never settles): a settlement must run at it, and leave the price per
    /// share, (totalAssets + 1) / (totalSupply + 1e6), no lower.
    function _keeperCall(uint16 vol, int16 carry, uint40 sourceTime, bool check) internal {
        IPerpDesk.MarketUpdate[] memory u = _update(vol, carry, sourceTime, "keeper");
        uint256 supply0 = desk.totalSupply();
        uint256 pending0 = desk.pendingDepositAssets();
        uint256 queued0 = desk.queuedShares();
        bool priced = true;
        uint256 nav0 = 0;
        if (check) {
            uint256 snap = vm.snapshotState();
            vm.prank(desk.owner());
            desk.setMarkets(u);
            (priced, nav0) = _nav();
            vm.revertToStateAndDelete(snap);
        }
        vm.recordLogs();
        vm.prank(desk.keeper());
        desk.setMarkets(u);
        keeperWrites++;
        bool ran = _settled(vm.getRecordedLogs());
        uint256 supply1 = desk.totalSupply();
        _keeperSupplyDelta += int256(supply1) - int256(supply0);
        uint256 filledIn = pending0 - desk.pendingDepositAssets();
        uint256 filledOut = queued0 - desk.queuedShares();
        depositsFilled += filledIn;
        sharesFilled += filledOut;
        bool filled = filledIn != 0 || filledOut != 0 || supply1 != supply0;
        if (!ran) {
            if (filled) settledWithoutMark = true;
            return;
        }
        settlementsRun++;
        (uint256 head, uint256 len) = desk.queue();
        if (head == len && desk.shortfall()) shortfallStuck = true;
        if (filled) settlementsFilling++;
        if (!check) return;
        (bool p1, uint256 nav1) = _nav();
        if (!priced || !p1) {
            settledWithoutMark = true;
            return;
        }
        if ((nav1 + 1) * (supply0 + 1e6) < (nav0 + 1) * (supply1 + 1e6)) priceFell = true;
    }

    function _settled(Vm.Log[] memory logs) internal view returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(desk) && logs[i].topics[0] == SETTLED) return true;
        }
        return false;
    }

    function _nav() internal view returns (bool, uint256) {
        try desk.totalAssets() returns (uint256 a) {
            return (true, a);
        } catch {
            return (false, 0);
        }
    }

    function _max(int256 a, int256 b) internal pure returns (int256) {
        return a > b ? a : b;
    }

    function _min(int256 a, int256 b) internal pure returns (int256) {
        return a < b ? a : b;
    }

    // --- cash -----------------------------------------------------------------------------

    function claim(uint256 actorSeed) external supplyByKeeperOnly {
        calls++;
        address a = actors[actorSeed % actors.length];
        vm.prank(a);
        series.claim(a);
    }

    function collect() external supplyByKeeperOnly {
        calls++;
        desk.collect(address(series));
    }

    // --- LP -------------------------------------------------------------------------------

    function requestDeposit(uint256 amount) external supplyByKeeperOnly {
        calls++;
        amount = bound(amount, 1, 100_000e6);
        if (usdc.balanceOf(lp) < amount) return;
        vm.prank(lp);
        try desk.requestDeposit(amount) {
            depositsRequested += amount;
        } catch (bytes memory err) {
            _note(err);
        }
    }

    function requestRedeem(uint256 shares) external supplyByKeeperOnly {
        calls++;
        uint256 bal = desk.balanceOf(lp);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        vm.prank(lp);
        try desk.requestRedeem(shares) {
            sharesRequested += shares;
        } catch (bytes memory err) {
            _note(err);
        }
    }

    /// One of the LP's requests, at any time: refused (CancelTooEarly) until STALL past due,
    /// then the unfilled rest, exactly.
    function cancel(uint256 idSeed, bool isDeposit) external supplyByKeeperOnly {
        calls++;
        (, uint256 len) = isDeposit ? desk.depositQueue() : desk.queue();
        if (len == 0) return;
        uint256 id = idSeed % len;
        (, uint40 dueAt, uint256 rest) = isDeposit ? desk.depositRequest(id) : desk.redeemRequest(id);
        bool early = block.timestamp < uint256(dueAt) + desk.STALL();
        vm.prank(lp);
        if (isDeposit) {
            try desk.cancelDeposit(id) returns (uint256 got) {
                _cancelled(early, got, rest);
                depositsCancelled += got;
            } catch (bytes memory err) {
                _cancelRefused(err, early);
            }
        } else {
            try desk.cancelRedeem(id) returns (uint256 got) {
                _cancelled(early, got, rest);
                sharesCancelled += got;
            } catch (bytes memory err) {
                _cancelRefused(err, early);
            }
        }
    }

    function _cancelled(bool early, uint256 got, uint256 rest) internal {
        cancels++;
        if (early || got != rest) cancelledEarly = true;
    }

    function _cancelRefused(bytes memory err, bool early) internal {
        if (bytes4(err) == IDeskQueue.CancelTooEarly.selector && early) return;
        _note(err);
    }

    /// The ERC-4626 entry points take no instant flow: the max* are 0 and all four revert AsyncOnly.
    function instantFlow(uint256 amount, uint256 which) external supplyByKeeperOnly {
        calls++;
        if (desk.maxDeposit(lp) != 0 || desk.maxMint(lp) != 0 || desk.maxWithdraw(lp) != 0 || desk.maxRedeem(lp) != 0) {
            instantFlowWorked = true;
        }
        amount = bound(amount, 1, 1e18);
        bytes memory data;
        which %= 4;
        if (which == 0) data = abi.encodeCall(desk.deposit, (amount, lp));
        else if (which == 1) data = abi.encodeCall(desk.mint, (amount, lp));
        else if (which == 2) data = abi.encodeCall(desk.withdraw, (amount, lp, lp));
        else data = abi.encodeCall(desk.redeem, (amount, lp, lp));
        vm.prank(lp);
        (bool ok, bytes memory ret) = address(desk).call(data);
        if (ok || bytes4(ret) != IDeskQueue.AsyncOnly.selector) instantFlowWorked = true;
    }

    function claimRedeemed() external supplyByKeeperOnly {
        calls++;
        vm.prank(lp);
        try desk.claim(lp) {}
        catch (bytes memory err) {
            _note(err);
        }
    }
}

/// The Desk's invariants on one world: its series' terms, the formula pricer's
/// product and bands, the feed's first market data and the Desk's band before a fixing.
abstract contract PerpDeskInvariantsBase is Test {
    uint40 internal constant T0 = 1_789_974_000; // 07:00 UTC: the first fixing, an hour later, is at 08:00
    uint256 internal constant RAY = 1e27;

    PerpDeskHandler handler;
    MockUSDC usdc;
    MockChainlinkFeed feed;
    PerpSeries series;
    PerpDesk desk;

    /// (k, melt share, interval, coupon reserve), the pricer's bands, the feed's first vol, minSecsToFixing.
    function _world()
        internal
        pure
        virtual
        returns (
            uint16 ki,
            uint64 melt,
            uint32 interval,
            uint64 reserve,
            PerpFormulaPricer.Bands memory bands,
            uint16 vol,
            uint32 minSecs
        );

    function setUp() public {
        (
            uint16 ki,
            uint64 melt,
            uint32 interval,
            uint64 reserve,
            PerpFormulaPricer.Bands memory bands,
            uint16 vol,
            uint32 minSecs
        ) = _world();
        vm.warp(T0);
        usdc = new MockUSDC();
        feed = new MockChainlinkFeed("ETH / USD");
        PerpFactory factory = new PerpFactory(
            address(usdc),
            // the launch's limits (DeployPerp.s.sol); the sequencer check has its own tests
            IPerpFactory.RecorderLimits({maxFixAge: 1 hours, priceMax: 1e15, sequencer: address(0), sequencerGrace: 0})
        );
        PerpQuoter quoter = new PerpQuoter(1 hours, address(0), 0);
        // the launch's market data limits (DeployPerp.s.sol) and a market keeper
        desk = new PerpDesk(
            IERC20(address(usdc)),
            factory,
            quoter,
            address(this),
            minSecs,
            IPerpDesk.MarketLimits({
                maxMarketAge: 3 hours, maxVolStepBps: 500, maxCarryStepBps: 300, minUpdateGap: 600
            }),
            makeAddr("keeper")
        );
        PerpProduct memory product =
            PerpProduct({kiBarrierBps: ki, meltShare: melt, fixingInterval: interval, discountBps: 0});
        PerpFormulaPricer pricer = new PerpFormulaPricer(product, bands);
        PerpTerms memory t = PerpTerms({
            feed: address(feed),
            firstFixing: T0 + 1 hours,
            fixingInterval: interval,
            kiBarrierBps: ki,
            meltShare: melt,
            couponReserve: reserve
        });
        series = PerpSeries(factory.createSeries(t));
        vm.warp(uint256(T0) + 1 hours + 1);
        feed.pushRoundAt(100e8, T0 + 1 hours);
        FixingsRecorder(address(series.recorder())).recordFixing(T0 + 1 hours, uint80(feed.latestRound()));
        feed.pushRoundAt(90e8, uint40(block.timestamp));
        desk.listSeries(address(series), pricer, 200_000e6);
        IPerpDesk.MarketUpdate[] memory u = new IPerpDesk.MarketUpdate[](1);
        u[0] = IPerpDesk.MarketUpdate({
            feed: address(feed),
            volBpsAnnual: vol,
            carryBpsAnnual: 400,
            sourceTime: uint40(block.timestamp),
            source: "setUp"
        }); // carry 4%
        desk.setMarkets(u);
        desk.setSpread(address(series), 20, 30, 200);
        desk.setRiskBudget(address(feed), 3000);
        handler = new PerpDeskHandler(usdc, feed, series, desk, pricer);
        targetContract(address(handler));
    }

    /// Nothing reverted for a reason the contracts don't state.
    function invariant_no_unexpected_revert() public view {
        assertEq(handler.unexpected(), bytes4(0), "an action reverted with an unexpected error");
    }

    /// The Desk nets every trade: it never holds NOTE and COVER at once
    /// (beyond the base unit a rounding can leave on one side).
    function invariant_desk_holds_one_leg() public view {
        uint256 n = IERC20(series.note()).balanceOf(address(desk));
        uint256 w = IERC20(series.cover()).balanceOf(address(desk));
        assertTrue(n == 0 || w == 0, "the Desk holds both legs");
    }

    /// The series covers every holder's released USDC and the pair value of the supply.
    function invariant_series_solvent() public view {
        uint256 supply = IERC20(series.note()).totalSupply();
        assertEq(supply, IERC20(series.cover()).totalSupply());
        uint256 owed =
            series.previewRedeemPair(supply) + series.claimable(address(desk)) + series.claimable(address(handler));
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            owed += series.claimable(handler.actor(i));
        }
        assertGe(usdc.balanceOf(address(series)), owed);
    }

    /// Every USDC is somewhere it can be accounted for, and the Desk's own
    /// balance covers what it set aside for filled redemptions.
    function invariant_usdc_accounted_and_reserve_backed() public view {
        uint256 total = usdc.balanceOf(address(desk)) + usdc.balanceOf(address(series)) + usdc.balanceOf(handler.lp())
            + usdc.balanceOf(handler.integrator());
        for (uint256 i = 0; i < handler.actorCount(); i++) {
            total += usdc.balanceOf(handler.actor(i));
        }
        assertEq(total, handler.minted());
        assertEq(desk.reservedAssets(), desk.claimableAssets(handler.lp()));
    }

    /// The Desk's USDC covers what it set aside for claims and the pending deposits.
    function invariant_usdc_covers_claims_and_pending_deposits() public view {
        assertGe(usdc.balanceOf(address(desk)), desk.reservedAssets() + desk.pendingDepositAssets());
    }

    /// Every request is filled, cancelled or still pending: deposits in USDC, redemptions in shares.
    function invariant_requests_are_filled_cancelled_or_pending() public view {
        assertEq(
            handler.depositsRequested(),
            handler.depositsFilled() + handler.depositsCancelled() + desk.pendingDepositAssets(),
            "deposits"
        );
        assertEq(
            handler.sharesRequested(),
            handler.sharesFilled() + handler.sharesCancelled() + desk.queuedShares(),
            "shares"
        );
    }

    /// Shares are minted and burned only in the keeper's updates: no trade, request, cancel,
    /// owner write or anything else settles.
    function invariant_supply_moves_only_in_the_keepers_update() public view {
        assertFalse(handler.supplyMovedOutsideKeeper(), "totalSupply moved outside a keeper update");
    }

    /// A settlement runs only at a mark (the one right after the keeper's writes) and never
    /// leaves the price per share below it: rounding favours the LPs who stay.
    function invariant_a_settlement_never_lowers_the_price_per_share() public view {
        assertFalse(handler.priceFell(), "a settlement lowered the price per share");
        assertFalse(handler.settledWithoutMark(), "a settlement without a mark, or by an owner write");
    }

    /// Requests are binding until STALL past due, and the ERC-4626 entry points take no instant flow.
    function invariant_requests_are_binding_and_flows_are_requests() public view {
        assertFalse(handler.cancelledEarly(), "a cancel before STALL past due, or of another amount");
        assertFalse(handler.instantFlowWorked(), "an instant ERC-4626 flow");
    }

    /// A settlement that empties the redemption queue leaves no shortfall behind.
    function invariant_no_shortfall_without_a_redemption_waiting() public view {
        assertFalse(handler.shortfallStuck(), "shortfall set after a settlement emptied the redemption queue");
    }

    /// series.advance() doesn't move totalAssets (docs/v2-spec.md §6): no step at the daily fixing.
    function invariant_no_step_in_total_assets_at_advance() public view {
        assertFalse(handler.stepAtAdvance(), "advance() moved totalAssets");
    }

    /// The risk view and the LP views never revert, whatever the market does.
    function invariant_views_never_revert() public view {
        desk.risk(address(feed));
        desk.maxDeposit(handler.lp());
        desk.maxWithdraw(handler.lp());
        desk.maxRedeem(handler.lp());
        desk.shortfall();
        desk.depositQueue();
        desk.queue();
        series.state();
    }

    /// In the crash line's strip and near the high of a knocked-in note the Desk doesn't trade
    /// (docs/v2-spec.md §8).
    function invariant_no_trade_the_near_line_rule_refuses() public view {
        assertFalse(handler.tradedNearLine(), "a trade the near-line rule refuses went through");
    }

    /// A buy-back pays the NOTE ask with the discount above the strip (docs/v2-spec.md §8): never
    /// more for the trader than the undiscounted price less d(x), and no discount elsewhere.
    function invariant_a_buy_back_pays_the_discounted_ask() public view {
        assertFalse(handler.buyBackMispriced(), "a buy-back's NOTE ask was not the undiscounted one plus d(x)");
    }

    /// A quote's newPosition is what the Desk's stock of the leg the trade draws on can't serve
    /// (rebuilt from its balances); the trade adds exactly that to the other leg and takes the rest
    /// from the stock, and waits (QueuePending) exactly when shortfall() and newPosition > 0 (#68).
    /// Every trade, the near-line ones too (`tradeNearTheLine` goes through `_tryBuy`/`_trySell`).
    function invariant_quote_newPosition_is_what_the_trade_adds() public view {
        assertFalse(
            handler.newPositionBroken(), "a quote's newPosition, its trade's moves or its QueuePending broke the rule"
        );
    }

    /// The run did trade: the refusals above are the exception, not the rule.
    function afterInvariant() public {
        emit log_named_uint("calls", handler.calls());
        emit log_named_uint("trades that went through", handler.trades());
        emit log_named_uint("trades refused near a line", handler.nearLineRefusals());
        emit log_named_uint("buy-backs checked", handler.buyBacksChecked());
        emit log_named_uint("... with a discount", handler.buyBacksDiscounted());
        emit log_named_uint("keeper writes", handler.keeperWrites());
        emit log_named_uint("settlements run", handler.settlementsRun());
        emit log_named_uint("settlements that filled a request", handler.settlementsFilling());
        emit log_named_uint("cancels that went through", handler.cancels());
        emit log_named_uint("trades refused QueuePending (newPosition > 0)", handler.tradesWaiting());
        emit log_named_uint("trades that went through in a shortfall", handler.tradesInShortfall());
        emit log_named_uint("fixings processed", series.state().fixingsDone);
    }
}

/// The launch: an ETH series (daily, k 40%, R = 0) priced by the launch's ETH pricer
/// (2-hour bands, vol 24-150%, carry -20% to +50%) from vol 70% and carry 4%, the Desk
/// closing 300 s before each fixing.
/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 120
contract PerpDeskInvariantsTest is PerpDeskInvariantsBase {
    function _world()
        internal
        pure
        override
        returns (uint16, uint64, uint32, uint64, PerpFormulaPricer.Bands memory, uint16, uint32)
    {
        return (
            4000,
            2_735_976_403_140_715,
            1 days,
            0,
            PerpFormulaPricer.Bands({
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
                carryMinBps: -2000,
                carryMaxBps: 5000
            }),
            7000,
            300
        );
    }
}

/// A weekly series with a coupon reserve (P1's terms: k 60%, R = 0.235) priced by a
/// weekly formula pricer (6-hour bands, vol 20-90%, carry -20% to +30%) from vol 55% and
/// carry 4%, the Desk closing an hour before each fixing: the coupon path through every
/// Desk flow.
/// forge-config: default.invariant.runs = 96
/// forge-config: default.invariant.depth = 120
contract PerpDeskInvariantsWeeklyCouponTest is PerpDeskInvariantsBase {
    function _world()
        internal
        pure
        override
        returns (uint16, uint64, uint32, uint64, PerpFormulaPricer.Bands memory, uint16, uint32)
    {
        return (
            6000,
            18_995_352_771_274_247,
            604_800,
            235_000,
            PerpFormulaPricer.Bands({
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
            }),
            5500,
            1 hours
        );
    }
}
