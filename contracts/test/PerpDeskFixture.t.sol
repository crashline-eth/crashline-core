// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PerpBase} from "./PerpBase.t.sol";
import {MockPerpPricer} from "./mocks/MockPerpPricer.sol";
import {PerpDesk} from "../src/PerpDesk.sol";
import {PerpQuoter} from "../src/PerpQuoter.sol";
import {PerpSeries} from "../src/PerpSeries.sol";
import {IPerpDesk} from "../src/interfaces/IPerpDesk.sol";
import {PerpQuote} from "../src/interfaces/IPerpQuoter.sol";

/// Shared Desk fixture: the launch's Desk (minSecsToFixing 300 s) with one
/// listed ETH series on the launch terms, a second after its first fixing
/// (08:00 UTC), spot 90% of the high, the feed's market data at vol 70% and
/// carry 4% (the launch's limits on it, and a market keeper), the mock model
/// at correction 0 (so the price is the closed form:
/// 7840 bps per unit of notional), 1,000,000 USDC of LP capital (requested an
/// hour before, at T0, and filled by the keeper's update at the end of setUp)
/// and a risk budget of the whole vault. `_useWeeklyCouponSeries` switches the fixture to
/// a weekly series with a coupon reserve (P1's terms) for the tests of the
/// coupon path.
abstract contract PerpDeskFixture is PerpBase {
    uint16 internal constant VOL = 7000;
    uint128 internal constant CAP = 100_000e6;
    uint256 internal constant LP_CAPITAL = 1_000_000e6;
    uint256 internal constant PAIR_BPS = 10_000; // (1e6 + RESERVE) / 100: no coupon reserve
    uint256 internal constant NOTE_BPS = 7840; // the closed form at spot 90%, vol 70%, carry 4%
    uint256 internal constant COVER_BPS = PAIR_BPS - NOTE_BPS; // 2160
    // the weekly series with a coupon reserve (`_useWeeklyCouponSeries`)
    uint16 internal constant COUPON_VOL = 5500;
    uint256 internal constant COUPON_PAIR_BPS = 12_350; // (1e6 + COUPON) / 100
    uint256 internal constant COUPON_NOTE_BPS = 10_196; // the closed form at spot 90%, vol 55%, carry 4%, plus the reserve
    bytes32 internal constant SOURCE = "options"; // the market data's source tag
    uint40 internal constant DELAY = 1 hours; // an LP request is due this long after it is made
    uint40 internal constant STALL = 6 hours; // and can be cancelled this long after it is due

    PerpQuoter internal quoter;
    MockPerpPricer internal pricer;
    PerpDesk internal desk;
    PerpSeries internal s;
    IERC20 internal noteT;
    IERC20 internal coverT;
    uint40 internal first;
    address internal lp = makeAddr("lp");
    address internal integrator = makeAddr("integrator");
    address internal keeper = makeAddr("keeper");

    function setUp() public virtual override {
        super.setUp();
        quoter = new PerpQuoter(STALENESS, address(sequencer), GRACE);
        pricer = new MockPerpPricer();
        desk = new PerpDesk(IERC20(address(usdc)), factory, quoter, address(this), MIN_SECS, _marketLimits(), keeper);
        first = T0 + 1 hours;
        s = _create(_terms(first));
        noteT = IERC20(s.note());
        coverT = IERC20(s.cover());
        _market(VOL, CARRY); // the curator's first write, at T0
        _requestDeposit(lp, LP_CAPITAL); // at T0: due at the first fixing's time
        _fixAt(s, first, int256(uint256(INITIAL)));
        _spot(9000); // a fresh round, one second into day 1 (the market data is an hour old)
        desk.listSeries(address(s), pricer, CAP);
        desk.setRiskBudget(address(feed), 10_000); // the whole vault may be at risk on this feed
        _settle(); // the keeper's update fills the LP's deposit
    }

    /// From here on the fixture's series is a weekly one with a coupon reserve of 23.5% (P1's
    /// terms) on the same feed, struck by the same first fixing, listed with a mock model pinned
    /// to its product, and the feed's vol is 55%: its NOTE is worth COUPON_NOTE_BPS, a pair
    /// COUPON_PAIR_BPS.
    function _useWeeklyCouponSeries() internal {
        s = _create(_weeklyCouponTerms(first)); // the recorder has its first fixing already
        noteT = IERC20(s.note());
        coverT = IERC20(s.cover());
        pricer = new MockPerpPricer();
        pricer.setProduct(_weeklyCouponProduct());
        pricer.setRange(1, 2000, 9000);
        _market(COUPON_VOL, CARRY);
        desk.listSeries(address(s), pricer, CAP);
        assertEq(_mid(), COUPON_NOTE_BPS);
    }

    // --- helpers ------------------------------------------------------------------

    /// A fresh round. The feed's market data is refreshed only once it is no longer quotable
    /// (older than maxMarketAge), so moving time by less with `_spot`, `_later` or `_fixing`
    /// settles no LP request: `_settle` does. The refresh (the same values, sourced now) is the
    /// keeper's write once minUpdateGap allows it, which settles what is due as the keeper's job
    /// would have by then; else the owner's. The keeper's own tests push rounds without it.
    function _spot(uint256 bps) internal {
        feed.pushRoundAt(_price(bps), uint40(block.timestamp));
        (uint16 vol, int16 carry, uint40 sourceTime, uint40 writtenAt,) = desk.market(address(feed));
        if (sourceTime == 0 || uint256(sourceTime) + desk.maxMarketAge() >= block.timestamp) return;
        IPerpDesk.MarketUpdate[] memory u = _upd(address(feed), vol, carry, uint40(block.timestamp), SOURCE);
        address k = desk.keeper();
        if (k != address(0) && block.timestamp >= uint256(writtenAt) + desk.minUpdateGap()) vm.prank(k);
        desk.setMarkets(u);
    }

    /// Move time forward and push a fresh round.
    function _later(uint256 secs, uint256 bps) internal {
        vm.warp(block.timestamp + secs);
        _spot(bps);
    }

    /// Record fixing n at `bps` of INITIAL, one minute after its time, with a fresh round at the same level.
    function _fixing(uint256 n, uint256 bps) internal {
        _fixAt(s, _fixingTime(s, n), _price(bps));
        vm.warp(uint256(_fixingTime(s, n)) + 60);
        _spot(bps);
    }

    /// The quoter's NOTE price at the feed's vol and carry.
    function _mid() internal view returns (uint256) {
        (uint16 vol, int16 carry,,,) = desk.market(address(feed));
        return quoter.quote(s, pricer, vol, carry).priceBps;
    }

    /// New market data for the fixture's feed from the owner, sourced now.
    function _market(uint16 vol, int16 carry) internal {
        _setMarket(address(feed), vol, carry, uint40(block.timestamp), SOURCE);
    }

    /// A `setMarkets` argument with one write.
    function _upd(address f, uint16 vol, int16 carry, uint40 sourceTime, bytes32 source)
        internal
        pure
        returns (IPerpDesk.MarketUpdate[] memory u)
    {
        u = new IPerpDesk.MarketUpdate[](1);
        u[0] = IPerpDesk.MarketUpdate({
            feed: f, volBpsAnnual: vol, carryBpsAnnual: carry, sourceTime: sourceTime, source: source
        });
    }

    /// The owner's write of `f`'s market data. It never settles LP requests, and its values are
    /// no settlement price (atBound) until the keeper's own write of the feed.
    function _setMarket(address f, uint16 vol, int16 carry, uint40 sourceTime, bytes32 source) internal {
        desk.setMarkets(_upd(f, vol, carry, sourceTime, source));
    }

    /// The keeper's routine update: its write of the fixture's feed (the same values, sourced
    /// now) when minUpdateGap since the feed's last write allows it, then the settlement of the
    /// requests due by the market data. After an owner write within minUpdateGap there is no
    /// write, and nothing settles while the Desk holds a position on the feed (atBound).
    function _settle() internal {
        (uint16 vol, int16 carry, uint40 t, uint40 writtenAt,) = desk.market(address(feed));
        IPerpDesk.MarketUpdate[] memory u = new IPerpDesk.MarketUpdate[](0);
        if (t != 0 && t < block.timestamp && block.timestamp >= uint256(writtenAt) + desk.minUpdateGap()) {
            u = _upd(address(feed), vol, carry, uint40(block.timestamp), SOURCE);
        }
        vm.prank(keeper);
        desk.setMarkets(u);
    }

    /// The keeper's update without a write: it settles at the market data as it stands.
    function _settleWithoutWrite() internal {
        vm.prank(keeper);
        desk.setMarkets(new IPerpDesk.MarketUpdate[](0));
    }

    /// `who` requests a deposit of `amount` fresh USDC.
    function _requestDeposit(address who, uint256 amount) internal returns (uint256 id) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(desk), amount);
        id = desk.requestDeposit(amount);
        vm.stopPrank();
    }

    /// The share price is known (totalAssets doesn't revert): due LP requests can settle.
    function _markable() internal view returns (bool) {
        try desk.totalAssets() returns (uint256) {
            return true;
        } catch {
            return false;
        }
    }

    /// `who` requests a redemption of `shares`.
    function _requestRedeem(address who, uint256 shares) internal returns (uint256 id) {
        vm.prank(who);
        id = desk.requestRedeem(shares);
    }

    function _quoteOf(IPerpDesk.Side side, uint256 n, uint16 feeBps) internal view returns (uint256 paid) {
        (paid,,) = desk.quote(address(s), side, n, feeBps);
    }

    function _buy(address who, uint256 n, uint16 feeBps) internal returns (uint256 cost) {
        uint256 quoted = _quoteOf(IPerpDesk.Side.BuyNote, n, feeBps);
        usdc.mint(who, quoted);
        vm.startPrank(who);
        usdc.approve(address(desk), quoted);
        cost = desk.buy(address(s), n, quoted, feeBps, integrator, who);
        vm.stopPrank();
    }

    function _sell(address who, uint256 n, uint16 feeBps) internal returns (uint256 proceeds) {
        vm.startPrank(who);
        noteT.approve(address(desk), n);
        proceeds = desk.sell(address(s), n, 0, feeBps, integrator, who);
        vm.stopPrank();
    }

    function _buyCover(address who, uint256 n, uint16 feeBps) internal returns (uint256 cost) {
        uint256 quoted = _quoteOf(IPerpDesk.Side.BuyCover, n, feeBps);
        usdc.mint(who, quoted);
        vm.startPrank(who);
        usdc.approve(address(desk), quoted);
        cost = desk.buyCover(address(s), n, quoted, feeBps, integrator, who);
        vm.stopPrank();
    }

    function _sellCover(address who, uint256 n, uint16 feeBps) internal returns (uint256 proceeds) {
        vm.startPrank(who);
        coverT.approve(address(desk), n);
        proceeds = desk.sellCover(address(s), n, 0, feeBps, integrator, who);
        vm.stopPrank();
    }
}
