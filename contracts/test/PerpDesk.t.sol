// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PerpDeskFixture} from "./PerpDeskFixture.t.sol";
import {MockPerpPricer, MockPricerWithoutLineBands, MockPricerWithTwoLineBands} from "./mocks/MockPerpPricer.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {PerpFactory} from "../src/PerpFactory.sol";
import {PerpDesk} from "../src/PerpDesk.sol";
import {PerpFormulaPricer} from "../src/PerpFormulaPricer.sol";
import {PerpFormula} from "../src/PerpFormula.sol";
import {PerpSeries} from "../src/PerpSeries.sol";
import {IPerpDesk} from "../src/interfaces/IPerpDesk.sol";
import {IDeskQueue} from "../src/interfaces/IDeskQueue.sol";
import {IPerpQuoter} from "../src/interfaces/IPerpQuoter.sol";
import {IPerpPricer, LineBands} from "../src/interfaces/IPerpPricer.sol";
import {PerpTerms, PerpPhase} from "../src/interfaces/IPerpSeries.sol";

contract PerpDeskTest is PerpDeskFixture {
    address hedger = makeAddr("hedger");

    // --- configuration ---------------------------------------------------------------

    function test_constructor_wrong_asset() public {
        MockUSDC other = new MockUSDC();
        vm.expectRevert(PerpDesk.WrongAsset.selector);
        new PerpDesk(IERC20(address(other)), factory, quoter, address(this), MIN_SECS, _marketLimits(), keeper);
    }

    /// The constructor sets the launch's market data limits and the keeper (events for both), and
    /// refuses limits the setter refuses.
    function test_constructor_sets_the_market_limits_and_the_keeper() public {
        assertEq(desk.maxMarketAge(), MARKET_AGE);
        assertEq(desk.maxVolStepBps(), VOL_STEP);
        assertEq(desk.maxCarryStepBps(), CARRY_STEP);
        assertEq(desk.minUpdateGap(), UPDATE_GAP);
        assertEq(desk.keeper(), keeper);
        vm.expectEmit();
        emit IPerpDesk.MarketLimitsSet(MARKET_AGE, VOL_STEP, CARRY_STEP, UPDATE_GAP);
        vm.expectEmit();
        emit IPerpDesk.KeeperSet(address(0));
        PerpDesk noKeeper =
            new PerpDesk(IERC20(address(usdc)), factory, quoter, alice, MIN_SECS, _marketLimits(), address(0));
        assertEq(noKeeper.keeper(), address(0));
        IPerpDesk.MarketLimits memory l = _marketLimits();
        l.minUpdateGap = 0;
        vm.expectRevert(IPerpDesk.BadMarketLimits.selector);
        new PerpDesk(IERC20(address(usdc)), factory, quoter, alice, MIN_SECS, l, address(0));
    }

    function test_config_and_the_fixtures_price() public view {
        assertEq(address(desk.factory()), address(factory));
        assertEq(address(desk.quoter()), address(quoter));
        assertEq(desk.name(), "Crashline Desk"); // fixed in the bytecode (#107)
        assertEq(desk.symbol(), "clDESK");
        assertEq(desk.asset(), address(usdc));
        assertEq(desk.decimals(), 12); // 6 + the inflation offset
        assertEq(desk.MAX_FEE_BPS(), 200);
        assertEq(desk.MAX_COVER_FEE_BPS(), 1000);
        assertEq(desk.BACKSTOP_SHARE_BPS(), 5000);
        assertEq(desk.MAX_SPREAD_BPS(), 1000);
        assertEq(desk.minSecsToFixing(), 300);
        assertEq(desk.keeper(), keeper);
        assertEq(desk.totalAssets(), LP_CAPITAL);
        // the closed form at spot 90%, vol 70%; no coupon reserve
        assertEq(_mid(), NOTE_BPS);
        assertEq(desk.midPriceBps(address(s)), NOTE_BPS);
    }

    function test_listSeries_emits_and_updates_in_place() public {
        IPerpDesk.Listing memory l = desk.listing(address(s));
        assertTrue(l.active);
        assertEq(address(l.pricer), address(pricer));
        assertEq(l.capNotional, CAP);

        MockPerpPricer other = new MockPerpPricer();
        other.setWeightsHash(keccak256("another model"));
        vm.expectEmit(address(desk));
        emit IPerpDesk.SeriesListed(address(s), address(other), other.weightsHash(), 5e6);
        desk.listSeries(address(s), other, 5e6);
        assertEq(desk.listedSeries().length, 1);
        assertEq(address(desk.listing(address(s)).pricer), address(other));
        assertEq(desk.listing(address(s)).capNotional, 5e6);
    }

    // --- market data, per feed --------------------------------------------------------

    function test_setMarket_stores_the_values_and_the_source_time() public {
        (uint16 vol, int16 carry, uint40 sourceTime,,) = desk.market(address(feed));
        assertEq(vol, VOL);
        assertEq(carry, CARRY);
        assertEq(sourceTime, block.timestamp);
        vm.warp(block.timestamp + 1 hours);
        uint40 t = uint40(block.timestamp - 90); // the source's own time, before the write
        vm.expectEmit(address(desk));
        emit IPerpDesk.MarketSet(address(feed), 8500, -1500, t, "options 1y");
        desk.setMarkets(_upd(address(feed), 8500, -1500, t, "options 1y"));
        (vol, carry, sourceTime,,) = desk.market(address(feed));
        assertEq(vol, 8500);
        assertEq(carry, -1500);
        assertEq(sourceTime, t); // stored: the data's age counts from it
        // the owner's write is not bounded: any value, outside every range too, a second later
        desk.setMarkets(_upd(address(feed), type(uint16).max, type(int16).min, t + 1, bytes32(0)));
        (vol, carry, sourceTime,,) = desk.market(address(feed));
        assertEq(vol, type(uint16).max);
        assertEq(carry, type(int16).min);
        assertEq(sourceTime, t + 1);
    }

    /// Every quote, mark and trade reads the feed's market data: vol and carry.
    function test_quotes_and_marks_use_the_feeds_vol_and_carry() public {
        _buy(alice, 100e6, 0); // the Desk holds COVER
        uint256 before = desk.totalAssets();
        _market(VOL, 2000);
        uint256 mid = quoter.quote(s, pricer, VOL, 2000).priceBps;
        assertTrue(mid != NOTE_BPS);
        assertEq(desk.midPriceBps(address(s)), mid);
        assertEq(_mid(), mid);
        (, uint16 ask,) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        assertEq(ask, mid);
        // marks too: the Desk's COVER at the new carry
        assertEq(desk.totalAssets(), before - 21_600_000 + 100e6 * (PAIR_BPS - mid) / 10_000);
        (uint256 atRisk,) = desk.risk(address(feed));
        assertEq(atRisk, 100e6 * (PAIR_BPS - mid) / 10_000);
        _market(6000, CARRY);
        assertEq(desk.midPriceBps(address(s)), quoter.quote(s, pricer, 6000, CARRY).priceBps);
    }

    /// A feed with no market data yet: its series list, but nothing on it is quoted.
    function test_a_feed_without_market_data_is_not_quoted() public {
        MockChainlinkFeed btc = new MockChainlinkFeed("BTC / USD");
        PerpSeries s2 = _create(_btcTerms(address(btc), first));
        btc.pushRoundAt(int256(uint256(INITIAL)), first);
        _recorder(s2).recordFixing(first, uint80(btc.latestRound()));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        MockPerpPricer btcPricer = new MockPerpPricer();
        btcPricer.setProduct(_btcProduct());
        desk.listSeries(address(s2), btcPricer, CAP); // listing needs no market data
        (,, uint40 sourceTime,,) = desk.market(address(btc));
        assertEq(sourceTime, 0);
        bytes memory err = abi.encodeWithSelector(IPerpDesk.NoMarketData.selector, address(btc));
        for (uint8 side = 0; side < 4; side++) {
            vm.expectRevert(err);
            desk.quote(address(s2), IPerpDesk.Side(side), 1e6, 0);
        }
        vm.expectRevert(err);
        desk.midPriceBps(address(s2));
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(desk), 10e6);
        vm.expectRevert(err);
        desk.buy(address(s2), 1e6, 10e6, 0, integrator, alice);
        vm.stopPrank();
        // the ETH feed's series still trade, and LP flows go on: the Desk holds nothing on BTC
        _buy(alice, 1e6, 0);
        assertTrue(_markable());
        // the curator writes BTC's market data: quoted
        desk.setMarkets(_upd(address(btc), 4500, CARRY, uint40(block.timestamp), SOURCE));
        assertEq(desk.midPriceBps(address(s2)), quoter.quote(s2, btcPricer, 4500, CARRY).priceBps);
    }

    /// One coin's market data moves only that coin's series.
    function test_market_data_is_per_feed() public {
        MockChainlinkFeed btc = new MockChainlinkFeed("BTC / USD");
        PerpSeries s2 = _create(_btcTerms(address(btc), first));
        btc.pushRoundAt(int256(uint256(INITIAL)), first);
        _recorder(s2).recordFixing(first, uint80(btc.latestRound()));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        MockPerpPricer btcPricer = new MockPerpPricer();
        btcPricer.setProduct(_btcProduct());
        btcPricer.setRange(1, 2100, 12_000);
        desk.listSeries(address(s2), btcPricer, CAP);
        desk.setMarkets(_upd(address(btc), 4500, 300, uint40(block.timestamp), SOURCE));
        uint256 btcMid = desk.midPriceBps(address(s2));
        assertEq(btcMid, quoter.quote(s2, btcPricer, 4500, 300).priceBps);
        _market(9000, 1000); // ETH's
        assertEq(desk.midPriceBps(address(s2)), btcMid);
        assertEq(desk.midPriceBps(address(s)), quoter.quote(s, pricer, 9000, 1000).priceBps);
        // a second ETH series on the same feed is quoted at the same market data
        PerpTerms memory t = _terms(first);
        t.couponReserve = 95_000;
        PerpSeries s3 = PerpSeries(factory.createSeries(t));
        desk.listSeries(address(s3), pricer, CAP);
        assertEq(desk.midPriceBps(address(s3)), quoter.quote(s3, pricer, 9000, 1000).priceBps);
    }

    /// Market data outside the pricer's ranges is accepted; the series is simply not quoted, in
    /// both directions, and LP flows wait while the Desk holds it. Back inside, it quotes again.
    function test_market_data_outside_the_pricers_ranges_is_not_quoted() public {
        desk.listSeries(address(s), _formulaPricer(), CAP);
        _buy(alice, 1_000e6, 0); // the Desk holds COVER
        // a carry above the pricer's +50%
        _market(VOL, CARRY_MAX + 1);
        _expectOutOfRange(3, CARRY_MAX + 1);
        assertFalse(_markable());
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(3), int64(CARRY_MAX + 1)));
        desk.totalAssets();
        (uint256 atRisk,) = desk.risk(address(feed));
        assertEq(atRisk, 1_000e6); // an unquotable series counts the most at risk
        // a carry below -20%
        _market(VOL, CARRY_MIN - 1);
        _expectOutOfRange(3, CARRY_MIN - 1);
        // a vol above the pricer's 150% (in a crash vol may rise past the top): the band's top end
        // (the pricer's minimum, 2 points: no spread is set) refuses, and so does the mark
        _market(15_001, CARRY);
        _expectOutOfRange(1, 15_201);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(1), int64(15_001)));
        desk.totalAssets();
        // the band's ends at the ends of the ranges are in, 1 bps beyond them not
        _market(14_800, CARRY_MAX);
        _expectQuotes();
        _market(14_801, CARRY_MAX);
        _expectOutOfRange(1, 15_001);
        _market(2600, CARRY_MIN);
        _expectQuotes();
        // with a wider band, its ends must be in the range too
        desk.setSpread(address(s), 0, 0, 300);
        _expectOutOfRange(1, 2300);
        _market(2700, CARRY);
        _expectQuotes();
        assertTrue(_markable());
    }

    /// A band wider than the vol, or one that takes the vol past 65,535: no arithmetic panic, a
    /// refusal. The low end is asked at 0 (or vol - band), where every pricer refuses: the closed
    /// form takes no vol below 1% or above 300%, so the high end, capped at 65,535, never prices.
    function test_a_vol_band_past_zero_or_uint16_is_refused() public {
        pricer.setRange(1, 0, type(int64).max); // a model that takes any vol: the closed form refuses
        desk.setSpread(address(s), 0, 0, 7001); // 70% - 70.01%: asked at 0
        vm.expectRevert(abi.encodeWithSelector(PerpFormula.VolOutOfRange.selector, uint256(0)));
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        _market(type(uint16).max, CARRY); // 655.35% + 70.01% is past uint16: the low end refuses first
        vm.expectRevert(abi.encodeWithSelector(PerpFormula.VolOutOfRange.selector, uint256(58_534) * 1e14));
        desk.quote(address(s), IPerpDesk.Side.SellCover, 1e6, 0);
        // a pricer's own range refuses before the closed form: OutOfRange at 0
        pricer.setRange(1, 2400, 15_000);
        _market(VOL, CARRY);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(1), int64(0)));
        desk.quote(address(s), IPerpDesk.Side.SellNote, 1e6, 0);
    }

    // --- the market keeper and the age of market data ------------------------------------------

    /// A keeper write to the fixture's feed.
    function _keeper(uint16 vol, int16 carry, uint40 sourceTime) internal {
        vm.prank(keeper);
        desk.setMarkets(_upd(address(feed), vol, carry, sourceTime, SOURCE));
    }

    /// A keeper write to the fixture's feed, refused with `err`.
    function _keeperRefused(uint16 vol, int16 carry, uint40 sourceTime, bytes memory err) internal {
        vm.prank(keeper);
        vm.expectRevert(err);
        desk.setMarkets(_upd(address(feed), vol, carry, sourceTime, SOURCE));
    }

    /// The owner sets the keeper (KeeperSet), who writes market data (and nothing else:
    /// test_curator_functions_are_owner_only). A replaced or removed keeper is anyone.
    function test_the_keeper_role() public {
        vm.warp(block.timestamp + 1 hours);
        uint40 t = uint40(block.timestamp);
        vm.expectEmit(address(desk));
        emit IPerpDesk.MarketSet(address(feed), VOL + 100, CARRY + 100, t, SOURCE);
        _keeper(VOL + 100, CARRY + 100, t);
        (uint16 vol, int16 carry, uint40 sourceTime,,) = desk.market(address(feed));
        assertEq(vol, VOL + 100);
        assertEq(carry, CARRY + 100);
        assertEq(sourceTime, t);
        // a new keeper: the old one is refused like anyone else
        address next = makeAddr("next keeper");
        vm.expectEmit(address(desk));
        emit IPerpDesk.KeeperSet(next);
        desk.setKeeper(next);
        assertEq(desk.keeper(), next);
        vm.warp(block.timestamp + 1 hours);
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper);
        _keeperRefused(VOL, CARRY, uint40(block.timestamp), err);
        vm.prank(next);
        desk.setMarkets(_upd(address(feed), VOL, CARRY, uint40(block.timestamp), SOURCE));
        // no keeper: only the owner writes
        vm.expectEmit(address(desk));
        emit IPerpDesk.KeeperSet(address(0));
        desk.setKeeper(address(0));
        vm.warp(block.timestamp + 1 hours);
        vm.prank(next);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, next));
        desk.setMarkets(_upd(address(feed), VOL, CARRY, uint40(block.timestamp), SOURCE));
        _market(VOL, CARRY);
    }

    /// The owner writes a feed's first market data; the keeper can't (NoMarketData).
    function test_the_keeper_cannot_write_a_feeds_first_market_data() public {
        address btc = address(new MockChainlinkFeed("BTC / USD"));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.NoMarketData.selector, btc));
        desk.setMarkets(_upd(btc, 4500, CARRY, uint40(block.timestamp), SOURCE));
        desk.setMarkets(_upd(btc, 4500, CARRY, uint40(block.timestamp), SOURCE));
        vm.warp(block.timestamp + UPDATE_GAP);
        vm.prank(keeper);
        desk.setMarkets(_upd(btc, 4500 + VOL_STEP, CARRY, uint40(block.timestamp), SOURCE));
        (uint16 vol,,,,) = desk.market(btc);
        assertEq(vol, 4500 + VOL_STEP);
    }

    /// The keeper's gap passes on the chain's clock: the time of its next write, sourced then.
    function _gapOn() internal returns (uint40) {
        vm.warp(block.timestamp + UPDATE_GAP);
        return uint40(block.timestamp);
    }

    /// A keeper write moves the vol by at most 500 bps either way: exactly 500 is in, 501 out.
    function test_the_keepers_vol_step() public {
        bytes memory err = abi.encodeWithSelector(IPerpDesk.MarketStepTooLarge.selector);
        uint40 t = _gapOn();
        _keeperRefused(VOL + VOL_STEP + 1, CARRY, t, err);
        _keeper(VOL + VOL_STEP, CARRY, t); // 70% -> 75%
        t = _gapOn();
        _keeperRefused(VOL - 1, CARRY, t, err);
        _keeper(VOL, CARRY, t); // 75% -> 70%
        t = _gapOn();
        _keeperRefused(VOL - VOL_STEP - 1, CARRY, t, err);
        _keeper(VOL - VOL_STEP, CARRY, t); // 70% -> 65%
        (uint16 vol,,,,) = desk.market(address(feed));
        assertEq(vol, VOL - VOL_STEP);
    }

    /// And the carry by at most 300 bps a year either way (across zero too): exactly 300 is in,
    /// 301 out; both may move at once.
    function test_the_keepers_carry_step() public {
        bytes memory err = abi.encodeWithSelector(IPerpDesk.MarketStepTooLarge.selector);
        int16 step = int16(CARRY_STEP);
        uint40 t = _gapOn();
        _keeperRefused(VOL, CARRY + step + 1, t, err);
        _keeper(VOL, CARRY + step, t); // 4% -> 7%
        t = _gapOn();
        _keeperRefused(VOL, CARRY - 1, t, err);
        _keeper(VOL, CARRY, t); // 7% -> 4%
        t = _gapOn();
        _keeperRefused(VOL, CARRY - step - 1, t, err);
        _keeper(VOL, CARRY - step, t); // 4% -> 1%
        t = _gapOn();
        _keeperRefused(VOL, CARRY - 2 * step - 1, t, err);
        _keeper(VOL, CARRY - 2 * step, t); // 1% -> -2%: across zero
        t = _gapOn();
        _keeperRefused(VOL + VOL_STEP + 1, CARRY - step, t, err);
        _keeperRefused(VOL + VOL_STEP, CARRY - step + 1, t, err);
        _keeper(VOL + VOL_STEP, CARRY - step, t); // both at their edge, the carry back across zero
        (uint16 vol, int16 carry,,,) = desk.market(address(feed));
        assertEq(vol, VOL + VOL_STEP);
        assertEq(carry, CARRY - step);
    }

    /// Keeper writes are at least 10 minutes apart on the chain's clock, from the block time of
    /// the feed's previous write (writtenAt), whatever their sourceTimes: 599 s after it is
    /// refused, 600 s in.
    function test_the_keepers_update_gap() public {
        bytes memory err = abi.encodeWithSelector(IPerpDesk.MarketUpdateTooSoon.selector);
        (,, uint40 t, uint40 written,) = desk.market(address(feed));
        assertEq(written, block.timestamp); // the owner's write in setUp
        vm.warp(uint256(written) + UPDATE_GAP - 1);
        _keeperRefused(VOL + 100, CARRY, t + 1, err);
        _keeperRefused(VOL + 100, CARRY, uint40(block.timestamp), err); // sourced 599 s later: still too soon
        vm.warp(uint256(written) + UPDATE_GAP);
        _keeper(VOL + 100, CARRY, t + 1); // 600 s on the chain's clock, though sourced a second later
        (,, uint40 sourceTime, uint40 writtenAt,) = desk.market(address(feed));
        assertEq(sourceTime, t + 1);
        assertEq(writtenAt, block.timestamp);
        // and from this write on
        vm.warp(block.timestamp + UPDATE_GAP - 1);
        _keeperRefused(VOL + 200, CARRY, uint40(block.timestamp), err);
        vm.warp(block.timestamp + 1);
        _keeper(VOL + 200, CARRY, uint40(block.timestamp));
        (uint16 vol,,,,) = desk.market(address(feed));
        assertEq(vol, VOL + 200);
    }

    /// No bursts: a keeper back after an hour's silence writes one step, back-dated or not; every
    /// further write in that block is refused, however far apart their sourceTimes. (A stolen key
    /// could otherwise stack six back-dated steps, 30 vol points, in the block it trades in.)
    function test_the_keeper_cannot_burst_back_dated_steps() public {
        bytes memory err = abi.encodeWithSelector(IPerpDesk.MarketUpdateTooSoon.selector);
        (,, uint40 t,,) = desk.market(address(feed));
        vm.warp(block.timestamp + 1 hours);
        t += UPDATE_GAP;
        _keeper(VOL - VOL_STEP, CARRY, t); // sourced 50 minutes ago: in
        for (uint256 i = 2; i <= 6; i++) {
            t += UPDATE_GAP;
            _keeperRefused(VOL - 2 * VOL_STEP, CARRY, t, err); // each a single step on: refused
        }
        (uint16 vol,, uint40 sourceTime, uint40 writtenAt,) = desk.market(address(feed));
        assertEq(vol, VOL - VOL_STEP);
        assertEq(sourceTime, t - 5 * UPDATE_GAP);
        assertEq(writtenAt, block.timestamp);
        // the next step waits 10 minutes on the chain's clock
        vm.warp(block.timestamp + UPDATE_GAP - 1);
        _keeperRefused(VOL - 2 * VOL_STEP, CARRY, uint40(block.timestamp), err);
        vm.warp(block.timestamp + 1);
        _keeper(VOL - 2 * VOL_STEP, CARRY, uint40(block.timestamp));
    }

    /// The owner's writes are not bounded: any step a second after the previous one. They set
    /// writtenAt too, so the keeper's gap and its next step count from the owner's write.
    function test_the_owners_writes_are_not_bounded() public {
        uint40 t = uint40(block.timestamp);
        vm.warp(block.timestamp + 1);
        desk.setMarkets(_upd(address(feed), VOL + 8000, CARRY_MIN, t + 1, SOURCE)); // +80 points, -24 points
        (uint16 vol, int16 carry, uint40 sourceTime, uint40 writtenAt,) = desk.market(address(feed));
        assertEq(vol, VOL + 8000);
        assertEq(carry, CARRY_MIN);
        assertEq(sourceTime, t + 1);
        assertEq(writtenAt, t + 1);
        vm.warp(block.timestamp + UPDATE_GAP - 1);
        _keeperRefused(
            VOL + 8000,
            CARRY_MIN,
            uint40(block.timestamp),
            abi.encodeWithSelector(IPerpDesk.MarketUpdateTooSoon.selector)
        );
        vm.warp(block.timestamp + 1);
        _keeper(VOL + 8000 + VOL_STEP, CARRY_MIN - int16(CARRY_STEP), uint40(block.timestamp));
        (vol, carry,,,) = desk.market(address(feed));
        assertEq(vol, VOL + 8000 + VOL_STEP);
        assertEq(carry, CARRY_MIN - int16(CARRY_STEP));
    }

    /// No write's sourceTime is in the future or 0 (never market data); the keeper's is after the
    /// stored one, while the owner's may be the same or older.
    function test_the_source_time_is_not_in_the_future_and_the_keepers_moves_forward() public {
        bytes4 bad = IPerpDesk.BadSourceTime.selector;
        uint40 t = uint40(block.timestamp);
        vm.warp(block.timestamp + 1 hours);
        uint40 nowT = uint40(block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(bad, nowT + 1));
        desk.setMarkets(_upd(address(feed), VOL, CARRY, nowT + 1, SOURCE)); // in the future
        vm.expectRevert(abi.encodeWithSelector(bad, uint40(0)));
        desk.setMarkets(_upd(address(feed), VOL, CARRY, 0, SOURCE));
        _keeperRefused(VOL, CARRY, nowT + 1, abi.encodeWithSelector(bad, nowT + 1));
        _keeperRefused(VOL, CARRY, t, abi.encodeWithSelector(bad, t)); // the stored one
        _keeperRefused(VOL, CARRY, t - 1, abi.encodeWithSelector(bad, t - 1)); // older
        _keeper(VOL, CARRY, t + 1);
        // the owner: the same sourceTime, an older one, now
        desk.setMarkets(_upd(address(feed), VOL + 1, CARRY, t + 1, SOURCE));
        desk.setMarkets(_upd(address(feed), VOL + 2, CARRY, t - 1, SOURCE));
        (uint16 vol,, uint40 sourceTime,,) = desk.market(address(feed));
        assertEq(vol, VOL + 2);
        assertEq(sourceTime, t - 1);
        desk.setMarkets(_upd(address(feed), VOL, CARRY, nowT, SOURCE));
        address btc = address(new MockChainlinkFeed("BTC / USD"));
        vm.expectRevert(abi.encodeWithSelector(bad, uint40(0)));
        desk.setMarkets(_upd(btc, 4500, CARRY, 0, SOURCE));
    }

    /// The owner's recovery can't be blocked by the keeper: a keeper write that lands first in the
    /// same block, with a later sourceTime than the one the Safe proposal carries, doesn't make
    /// the owner's write revert. The owner's older sourceTime is stored (and ages the data from
    /// it), and the keeper's next write must be newer than the owner's, 10 minutes later.
    function test_the_owner_writes_an_older_source_time_than_the_keepers() public {
        vm.warp(block.timestamp + 1 hours);
        uint40 proposed = uint40(block.timestamp - 30 minutes); // when the Safe proposal was made
        uint40 nowT = uint40(block.timestamp);
        _keeper(VOL + VOL_STEP, CARRY, nowT); // lands first, sourced now
        desk.setMarkets(_upd(address(feed), VOL, CARRY, proposed, "recovery")); // older: in
        (uint16 vol, int16 carry, uint40 sourceTime, uint40 writtenAt,) = desk.market(address(feed));
        assertEq(vol, VOL);
        assertEq(carry, CARRY);
        assertEq(sourceTime, proposed);
        assertEq(writtenAt, nowT);
        // the age counts from the owner's sourceTime
        vm.warp(uint256(proposed) + MARKET_AGE + 1);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.MarketStale.selector, address(feed), proposed));
        desk.midPriceBps(address(s));
        // the keeper: newer than the owner's sourceTime, not merely newer than its own last one
        _keeperRefused(VOL, CARRY, proposed, abi.encodeWithSelector(IPerpDesk.BadSourceTime.selector, proposed));
        _keeper(VOL, CARRY, proposed + 1);
        (,, sourceTime,,) = desk.market(address(feed));
        assertEq(sourceTime, proposed + 1);
    }

    /// Market data exactly 3 hours old (from its sourceTime) is quoted; a second older it is stale,
    /// like a stale feed: every side of the feed's series and every trade refused, and while the
    /// Desk holds one, totalAssets and the previews (LP requests wait: the keeper's update can't
    /// settle them); the risk view counts the most.
    function test_market_data_older_than_3_hours_is_not_quoted() public {
        _buy(alice, 100e6, 0); // the Desk holds COVER
        uint256 id = _requestRedeem(lp, 1e17); // a tenth of the LP, due an hour from now
        (,, uint40 t,,) = desk.market(address(feed));
        vm.warp(uint256(t) + MARKET_AGE);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp)); // the feed itself stays fresh
        _expectQuotes();
        assertTrue(_markable());

        vm.warp(block.timestamp + 1);
        bytes memory err = abi.encodeWithSelector(IPerpDesk.MarketStale.selector, address(feed), t);
        for (uint8 side = 0; side < 4; side++) {
            vm.expectRevert(err);
            desk.quote(address(s), IPerpDesk.Side(side), 1e6, 0);
        }
        vm.expectRevert(err);
        desk.midPriceBps(address(s));
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(desk), 100e6);
        vm.expectRevert(err);
        desk.buy(address(s), 1e6, 100e6, 0, integrator, alice);
        vm.expectRevert(err);
        desk.buyCover(address(s), 1e6, 100e6, 0, integrator, alice);
        noteT.approve(address(desk), 1e6);
        vm.expectRevert(err);
        desk.sell(address(s), 1e6, 0, 0, integrator, alice);
        vm.stopPrank();
        // no share price: LP requests wait
        vm.expectRevert(err);
        desk.totalAssets();
        vm.expectRevert(err);
        desk.previewDeposit(1e6);
        vm.expectRevert(err);
        desk.previewRedeem(1e12);
        _settleWithoutWrite(); // nothing to settle at
        (,, uint256 rest) = desk.redeemRequest(id);
        assertEq(rest, 1e17);
        // the risk view: an unquotable series counts the most
        (uint256 atRisk,) = desk.risk(address(feed));
        assertEq(atRisk, 100e6);
        // the keeper's next write: quoted again, and the due redemption settles
        _keeper(VOL, CARRY, uint40(block.timestamp));
        _expectQuotes();
        (,, rest) = desk.redeemRequest(id);
        assertEq(rest, 0);
        assertGt(desk.claimableAssets(lp), 0);
    }

    /// The age counts from the source's time, not the write's: data written an hour after its
    /// source's time is stale 2 hours and a second after the write.
    function test_the_age_counts_from_the_source_time() public {
        vm.warp(block.timestamp + 1 hours);
        uint40 t = uint40(block.timestamp - 1 hours + 1);
        desk.setMarkets(_upd(address(feed), VOL, CARRY, t, SOURCE));
        (,, uint40 sourceTime, uint40 writtenAt,) = desk.market(address(feed));
        assertEq(sourceTime, t);
        assertEq(writtenAt, t + 1 hours - 1); // the write's own time counts only for the keeper's gap
        vm.warp(uint256(t) + MARKET_AGE);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        desk.midPriceBps(address(s));
        vm.warp(block.timestamp + 1);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.MarketStale.selector, address(feed), t));
        desk.midPriceBps(address(s));
    }

    /// The owner sets the four limits in one call (MarketLimitsSet): 0 < gap < age <= a day, any
    /// steps. They apply at once, to the data already written too.
    function test_setMarketLimits_and_its_bounds() public {
        bytes4 bad = IPerpDesk.BadMarketLimits.selector;
        vm.expectRevert(bad);
        desk.setMarketLimits(MARKET_AGE, VOL_STEP, CARRY_STEP, 0); // no gap
        vm.expectRevert(bad);
        desk.setMarketLimits(MARKET_AGE, VOL_STEP, CARRY_STEP, MARKET_AGE); // a gap as long as the age
        vm.expectRevert(bad);
        desk.setMarketLimits(1 days + 1, VOL_STEP, CARRY_STEP, UPDATE_GAP); // older than a day
        vm.expectRevert(bad);
        desk.setMarketLimits(0, VOL_STEP, CARRY_STEP, 0);
        // the edges are in
        vm.expectEmit(address(desk));
        emit IPerpDesk.MarketLimitsSet(1 days, 0, type(uint16).max, 1 days - 1);
        desk.setMarketLimits(1 days, 0, type(uint16).max, 1 days - 1);
        assertEq(desk.maxMarketAge(), 1 days);
        assertEq(desk.maxVolStepBps(), 0);
        assertEq(desk.maxCarryStepBps(), type(uint16).max);
        assertEq(desk.minUpdateGap(), 1 days - 1);
        desk.setMarketLimits(2, VOL_STEP, CARRY_STEP, 1);
        assertEq(desk.maxMarketAge(), 2);

        // at once: with an hour's age, the fixture's data is stale an hour and a second on
        desk.setMarketLimits(1 hours, 0, 10, 1 minutes);
        (,, uint40 t,,) = desk.market(address(feed));
        vm.warp(uint256(t) + 1 hours + 1);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.MarketStale.selector, address(feed), t));
        desk.midPriceBps(address(s));
        // and a longer age reopens quotes on the same data; back to an hour
        desk.setMarketLimits(MARKET_AGE, 0, 10, 1 minutes);
        desk.midPriceBps(address(s));
        desk.setMarketLimits(1 hours, 0, 10, 1 minutes);
        // a vol step of 0: the keeper keeps the vol and refreshes the time; the carry within 10 bps
        bytes memory step = abi.encodeWithSelector(IPerpDesk.MarketStepTooLarge.selector);
        uint40 nowT = uint40(block.timestamp);
        _keeperRefused(VOL + 1, CARRY, nowT, step);
        _keeperRefused(VOL, CARRY + 11, nowT, step);
        _keeper(VOL, CARRY - 10, nowT);
        desk.midPriceBps(address(s));
        // a minute's gap
        vm.warp(block.timestamp + 1 minutes);
        _keeper(VOL, CARRY - 20, nowT + 1 minutes);
    }

    /// Any keeper write within both steps and the gap is accepted, and every other refused.
    function testFuzz_the_keeper_writes_within_its_bounds_only(
        uint256 volSeed,
        int256 carrySeed,
        uint256 elapsedSeed,
        uint256 timeSeed
    ) public {
        (,, uint40 t0, uint40 written,) = desk.market(address(feed));
        uint256 elapsed = bound(elapsedSeed, 1, 2 * UPDATE_GAP); // on the chain's clock
        vm.warp(uint256(written) + elapsed);
        uint16 vol = uint16(bound(volSeed, VOL - 2 * VOL_STEP, VOL + 2 * VOL_STEP));
        int16 carry = int16(bound(carrySeed, CARRY - 2 * int16(CARRY_STEP), CARRY + 2 * int16(CARRY_STEP)));
        uint40 t = uint40(bound(timeSeed, uint256(t0) + 1, block.timestamp)); // any sourceTime that may be
        bool inside = vol + VOL_STEP >= VOL && vol <= VOL + VOL_STEP && carry + int16(CARRY_STEP) >= CARRY
            && carry <= CARRY + int16(CARRY_STEP) && elapsed >= UPDATE_GAP;
        vm.prank(keeper);
        if (!inside) vm.expectRevert();
        desk.setMarkets(_upd(address(feed), vol, carry, t, SOURCE));
        (uint16 v, int16 c, uint40 st,,) = desk.market(address(feed));
        assertEq(v, inside ? vol : VOL);
        assertEq(c, inside ? carry : CARRY);
        assertEq(st, inside ? t : t0);
    }

    /// Everything but setMarkets is the owner's alone: the keeper is refused like anyone else.
    function test_curator_functions_are_owner_only() public {
        _expectCuratorOnly(alice);
        _expectCuratorOnly(keeper);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        desk.setMarkets(_upd(address(feed), VOL, CARRY, uint40(block.timestamp), SOURCE));
    }

    function _expectCuratorOnly(address who) internal {
        bytes memory err = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, who);
        vm.startPrank(who);
        vm.expectRevert(err);
        desk.listSeries(address(s), pricer, CAP);
        vm.expectRevert(err);
        desk.delistSeries(address(s));
        vm.expectRevert(err);
        desk.setSpread(address(s), 1, 1, 0);
        vm.expectRevert(err);
        desk.setRiskBudget(address(feed), 1);
        vm.expectRevert(err);
        desk.setMinSecsToFixing(0);
        vm.expectRevert(err);
        desk.setKeeper(who);
        vm.expectRevert(err);
        desk.setMarketLimits(1 days, type(uint16).max, type(uint16).max, 1);
        vm.expectRevert(err);
        desk.transferOwnership(who);
        vm.stopPrank();
    }

    function test_listSeries_refuses_foreign_series_and_other_products() public {
        // a series of another factory, same feed and terms, is not the Desk's
        address foreign = new PerpFactory(address(usdc), _limits()).createSeries(_terms(first));
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.NotFactorySeries.selector, foreign));
        desk.listSeries(foreign, pricer, CAP);

        // a series the model is not pinned to: knock-in, melt share, interval
        PerpTerms memory t = _terms(first);
        t.kiBarrierBps = KI_BTC;
        address other = factory.createSeries(t);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.ModelMismatch.selector, uint8(0)));
        desk.listSeries(other, pricer, CAP);
        t = _terms(first);
        t.meltShare = MELT + 1;
        other = factory.createSeries(t);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.ModelMismatch.selector, uint8(1)));
        desk.listSeries(other, pricer, CAP);
        t = _terms(first);
        t.fixingInterval = WEEK;
        other = factory.createSeries(t);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.ModelMismatch.selector, uint8(2)));
        desk.listSeries(other, pricer, CAP);
        // any coupon reserve is the same product: the price is linear in it
        t = _terms(first);
        t.couponReserve = 95_000;
        desk.listSeries(factory.createSeries(t), pricer, CAP);
        assertEq(desk.listedSeries().length, 2);
    }

    function test_curator_setters_and_their_limits() public {
        vm.expectEmit(address(desk));
        emit IPerpDesk.SpreadSet(address(s), 30, 40, 200);
        desk.setSpread(address(s), 30, 40, 200);
        IPerpDesk.Spread memory sp = desk.spread(address(s));
        assertEq(sp.bidBps, 30);
        assertEq(sp.askBps, 40);
        assertEq(sp.volBandBps, 200);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.SpreadTooWide.selector, uint16(1001)));
        desk.setSpread(address(s), 1001, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.SpreadTooWide.selector, uint16(1001)));
        desk.setSpread(address(s), 0, 1001, 0);
        // any band is accepted: where vol -/+ band leaves the pricer's range, the series isn't quoted
        desk.setSpread(address(s), 0, 0, 5001);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(1), int64(1999)));
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.NotListed.selector, address(1)));
        desk.setSpread(address(1), 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.NotListed.selector, address(1)));
        desk.delistSeries(address(1));

        vm.expectEmit(address(desk));
        emit IPerpDesk.RiskBudgetSet(address(feed), 2500);
        desk.setRiskBudget(address(feed), 2500);
        assertEq(desk.riskBudgetBps(address(feed)), 2500);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.BudgetTooHigh.selector, uint16(10_001)));
        desk.setRiskBudget(address(feed), 10_001);

        vm.expectEmit(address(desk));
        emit IPerpDesk.MinSecsToFixingSet(2 hours);
        desk.setMinSecsToFixing(2 hours);
        assertEq(desk.minSecsToFixing(), 2 hours);
    }

    // --- NOTE: buy and sell -------------------------------------------------------------

    function test_buy_pays_quote_plus_fee_and_keeps_cover() public {
        (uint256 quoted, uint16 priceBps,) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 100e6, 50);
        assertEq(priceBps, NOTE_BPS);
        assertEq(quoted, 78_400_000 + 500_000); // 100 * 0.784 + 0.5% of the notional

        usdc.mint(alice, quoted);
        vm.startPrank(alice);
        usdc.approve(address(desk), quoted);
        vm.expectEmit(address(desk));
        emit IPerpDesk.Traded(
            address(s),
            alice,
            IPerpDesk.Side.BuyNote,
            alice,
            100e6,
            100e6,
            uint16(NOTE_BPS),
            quoted,
            50,
            integrator,
            pricer.weightsHash()
        );
        assertEq(desk.buy(address(s), 100e6, quoted, 50, integrator, alice), quoted);
        vm.stopPrank();

        assertEq(noteT.balanceOf(alice), 100e6);
        assertEq(coverT.balanceOf(address(desk)), 100e6); // the Desk minted pairs and kept the other leg
        assertEq(noteT.balanceOf(address(desk)), 0);
        assertEq(usdc.balanceOf(integrator), 250_000); // half the fee; the other half stays in the vault
        assertEq(usdc.balanceOf(address(s)), 100_000_000); // 100 pairs at 1
        assertEq(desk.heldSeries().length, 1);
        // the vault paid 100 for the pairs and holds COVER worth 100 * (1 - 0.784)
        assertEq(desk.totalAssets(), LP_CAPITAL + quoted - 250_000 - 100_000_000 + 21_600_000);
        assertEq(desk.totalAssets(), LP_CAPITAL + 250_000);
    }

    function test_buy_errors() public {
        vm.expectRevert(IPerpDesk.ZeroAmount.selector);
        desk.buy(address(s), 0, 0, 0, integrator, alice);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.FeeTooHigh.selector, uint16(201)));
        desk.buy(address(s), 1e6, type(uint256).max, 201, integrator, alice);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.NotListed.selector, address(1)));
        desk.buy(address(1), 1e6, type(uint256).max, 0, integrator, alice);
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(desk), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.Slippage.selector, uint256(784_000), uint256(783_999)));
        desk.buy(address(s), 1e6, 783_999, 0, integrator, alice);
        vm.stopPrank();
    }

    function test_delist_stops_buys_not_sells() public {
        _buy(alice, 10e6, 0);
        vm.expectEmit(address(desk));
        emit IPerpDesk.SeriesDelisted(address(s));
        desk.delistSeries(address(s));
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.NotListed.selector, address(s)));
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.NotListed.selector, address(s)));
        desk.quote(address(s), IPerpDesk.Side.BuyCover, 1e6, 0);
        assertEq(_sell(alice, 10e6, 0), 7_840_000);
        assertEq(desk.totalAssets(), LP_CAPITAL);
    }

    function test_cap_is_in_notional_of_cover_held() public {
        desk.listSeries(address(s), pricer, 50e6);
        _buy(alice, 50e6, 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.CapExceeded.selector, uint256(1), uint256(0)));
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1, 0);
        // selling back frees the cap
        _sell(alice, 20e6, 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.CapExceeded.selector, uint256(21e6), uint256(20e6)));
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 21e6, 0);
        _buy(alice, 20e6, 0);
        // after a fixing every token stands for less notional: the same cap is more tokens
        _fixing(1, 9000);
        uint256 perToken = s.state().notionalPerToken;
        uint256 capTokens = uint256(50e6) * RAY / perToken;
        assertGt(capTokens, 50e6);
        _buy(alice, capTokens - 50e6, 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.CapExceeded.selector, uint256(1), uint256(0)));
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1, 0);
    }

    /// The Desk's own band: no trade in the last 300 s before a series' fixing; at exactly 300 s it trades.
    function test_too_close_to_a_fixing() public {
        vm.warp(uint256(first) + DAY - MIN_SECS + 1);
        _spot(9000);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.TooCloseToFixing.selector, first + DAY));
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.TooCloseToFixing.selector, first + DAY));
        desk.quote(address(s), IPerpDesk.Side.SellCover, 1e6, 0);
        vm.warp(uint256(first) + DAY - MIN_SECS);
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
    }

    function test_quote_refusals_bubble() public {
        // the model refuses
        pricer.setRefusal(MockPerpPricer.Mode.UncertifiedErr, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(0)));
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        pricer.setCorrection(0);
        // four days on, every fixing recorded
        vm.warp(uint256(_fixingTime(s, 4)) + 1 hours);
        _fixAt(s, _fixingTime(s, 1), _price(9000));
        _fixAt(s, _fixingTime(s, 2), _price(9000));
        _fixAt(s, _fixingTime(s, 3), _price(9000));
        _fixAt(s, _fixingTime(s, 4), _price(9000));
        _spot(9000);
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        // a fixing is pending
        vm.warp(uint256(_fixingTime(s, 5)) + 1);
        _spot(9000);
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.FixingPending.selector, _fixingTime(s, 5)));
        desk.quote(address(s), IPerpDesk.Side.SellNote, 1e6, 0);
    }

    function test_sell_unwinds_pairs_and_pays_the_bid() public {
        _buy(alice, 100e6, 0);
        (uint256 quoted, uint16 priceBps,) = desk.quote(address(s), IPerpDesk.Side.SellNote, 40e6, 50);
        assertEq(priceBps, NOTE_BPS);
        assertEq(quoted, 31_360_000 - 200_000);
        assertEq(_sell(alice, 40e6, 50), quoted);
        assertEq(coverT.balanceOf(address(desk)), 60e6); // 40 pairs redeemed
        assertEq(noteT.balanceOf(address(desk)), 0);
        assertEq(usdc.balanceOf(address(s)), 60_000_000);
        assertEq(usdc.balanceOf(integrator), 100_000);
    }

    function test_sell_slippage_and_fee_capped_at_gross() public {
        _buy(alice, 10e6, 0);
        vm.startPrank(alice);
        noteT.approve(address(desk), 10e6);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.Slippage.selector, uint256(7_840_000), uint256(7_840_001)));
        desk.sell(address(s), 10e6, 7_840_001, 0, integrator, alice);
        // one base unit of NOTE: gross floor(0.784) = 0, fee ceil(1 * 2%) = 1: the fee takes the gross and no more
        assertEq(desk.sell(address(s), 1, 0, 200, integrator, alice), 0);
        vm.stopPrank();
    }

    function test_selling_note_the_desk_cannot_pair_becomes_its_position() public {
        _mintPairs(s, alice, 30e6); // alice mints pairs herself and sells the NOTE
        uint256 proceeds = _sell(alice, 30e6, 0);
        assertEq(proceeds, 23_520_000);
        assertEq(noteT.balanceOf(address(desk)), 30e6);
        assertEq(desk.totalAssets(), LP_CAPITAL); // paid 23.52 for NOTE worth 23.52
        // the next NOTE buyer takes it out of the inventory: no mint
        uint256 escrow = usdc.balanceOf(address(s));
        _buy(bob, 30e6, 0);
        assertEq(usdc.balanceOf(address(s)), escrow);
        assertEq(noteT.balanceOf(address(desk)), 0);
    }

    // --- cover: buy and sell --------------------------------------------------------------

    function test_buyCover_pays_the_premium_and_the_desk_keeps_note() public {
        (uint256 quoted, uint16 priceBps,) = desk.quote(address(s), IPerpDesk.Side.BuyCover, 100e6, 1000);
        assertEq(priceBps, COVER_BPS); // 2160
        assertEq(quoted, 21_600_000 + 2_160_000); // the premium + 10% of it
        assertEq(_buyCover(hedger, 100e6, 1000), quoted);
        assertEq(coverT.balanceOf(hedger), 100e6);
        assertEq(noteT.balanceOf(address(desk)), 100e6);
        assertEq(usdc.balanceOf(integrator), 1_080_000);
        // LP funds put up the rest of the pair: 100 - the premium
        assertEq(desk.totalAssets(), LP_CAPITAL + 1_080_000);
    }

    function test_sellCover_unwinds_pairs() public {
        _buyCover(hedger, 100e6, 0);
        uint256 proceeds = _sellCover(hedger, 100e6, 0);
        assertEq(proceeds, 21_600_000);
        assertEq(noteT.balanceOf(address(desk)), 0);
        assertEq(usdc.balanceOf(address(s)), 0);
        assertEq(desk.totalAssets(), LP_CAPITAL);
    }

    function test_sellCover_unpaired_counts_against_the_cap() public {
        _mintPairs(s, hedger, 200e6);
        desk.listSeries(address(s), pricer, 150e6);
        _sellCover(hedger, 150e6, 0);
        assertEq(coverT.balanceOf(address(desk)), 150e6);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.CapExceeded.selector, uint256(50e6), uint256(0)));
        desk.quote(address(s), IPerpDesk.Side.SellCover, 50e6, 0);
    }

    function test_matched_legs_leave_the_desk_flat_with_both_spreads() public {
        desk.setSpread(address(s), 30, 40, 0);
        uint256 coverCost = _buyCover(hedger, 100e6, 0); // the Desk holds 100 NOTE
        uint256 noteCost = _buy(alice, 100e6, 0); // and sells them on: no mint
        assertEq(noteT.balanceOf(address(desk)), 0);
        assertEq(coverT.balanceOf(address(desk)), 0);
        // cover at pair - (mid - 30), NOTE at mid + 40: the pair cost 100, the legs paid 100.7
        assertEq(coverCost, 21_900_000);
        assertEq(noteCost, 78_800_000);
        assertEq(desk.totalAssets(), LP_CAPITAL + 700_000);
        (uint256 atRisk,) = desk.risk(address(feed));
        assertEq(atRisk, 0);
    }

    // --- the two prices ---------------------------------------------------------------------

    function test_two_prices_per_leg() public {
        desk.setSpread(address(s), 30, 40, 0);
        (, uint16 noteAsk,) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        (, uint16 noteBid,) = desk.quote(address(s), IPerpDesk.Side.SellNote, 1e6, 0);
        (, uint16 coverAsk,) = desk.quote(address(s), IPerpDesk.Side.BuyCover, 1e6, 0);
        (, uint16 coverBid,) = desk.quote(address(s), IPerpDesk.Side.SellCover, 1e6, 0);
        assertEq(noteAsk, NOTE_BPS + 40);
        assertEq(noteBid, NOTE_BPS - 30);
        assertEq(coverAsk, PAIR_BPS - noteBid);
        assertEq(coverBid, PAIR_BPS - noteAsk);
        // minting a pair to sell both legs, or buying both to redeem, never pays
        assertLe(uint256(noteBid) + coverBid, PAIR_BPS);
        assertGe(uint256(noteAsk) + coverAsk, PAIR_BPS);
    }

    function test_vol_band_prices_each_side_at_its_end() public {
        desk.setSpread(address(s), 0, 0, 500);
        uint256 lo = quoter.quote(s, pricer, VOL + 500, CARRY).priceBps; // the note is worth less at a higher vol
        uint256 hi = quoter.quote(s, pricer, VOL - 500, CARRY).priceBps;
        assertLt(lo, hi);
        (, uint16 noteAsk,) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        (, uint16 noteBid,) = desk.quote(address(s), IPerpDesk.Side.SellNote, 1e6, 0);
        assertEq(noteAsk, hi);
        assertEq(noteBid, lo);
        // marks stay at the feed's vol
        assertEq(desk.midPriceBps(address(s)), NOTE_BPS);
        // a refusal at one end of the band refuses the quote
        pricer.setRange(1, 2000, int64(uint64(VOL)) + 499);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(1), int64(uint64(VOL) + 500)));
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
    }

    function test_vol_band_takes_the_lower_and_the_higher_quote() public {
        // a model whose correction rises steeply with vol: the note is worth more at the higher vol
        pricer.setVolSlope(300);
        desk.setSpread(address(s), 0, 0, 500);
        uint256 atLow = quoter.quote(s, pricer, VOL - 500, CARRY).priceBps;
        uint256 atHigh = quoter.quote(s, pricer, VOL + 500, CARRY).priceBps;
        assertGt(atHigh, atLow);
        (, uint16 noteAsk,) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        (, uint16 noteBid,) = desk.quote(address(s), IPerpDesk.Side.SellNote, 1e6, 0);
        assertEq(noteAsk, atHigh);
        assertEq(noteBid, atLow);
    }

    function test_prices_stay_between_zero_and_the_pair() public {
        desk.setSpread(address(s), 1000, 1000, 0);
        pricer.setCorrection(3000); // model says the principal is worth more than 1
        (, uint16 noteAsk,) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        (, uint16 coverBid,) = desk.quote(address(s), IPerpDesk.Side.SellCover, 1e6, 0);
        assertEq(noteAsk, PAIR_BPS);
        assertEq(coverBid, 0);
        pricer.setCorrection(-30000); // the principal is worth nothing, and there is no coupon reserve
        (, uint16 noteBid,) = desk.quote(address(s), IPerpDesk.Side.SellNote, 1e6, 0);
        (, uint16 coverAsk,) = desk.quote(address(s), IPerpDesk.Side.BuyCover, 1e6, 0);
        assertEq(noteBid, 0); // floored at 0
        assertEq(coverAsk, PAIR_BPS);
    }

    // --- after fixings: less notional per token, and released cash ------------------------------

    function test_trades_scale_with_the_notional_per_token() public {
        _fixing(1, 9000);
        uint256 perToken = s.state().notionalPerToken;
        uint256 mid = _mid();
        (uint256 cost, uint16 priceBps,) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 100e6, 50);
        assertEq(priceBps, mid);
        uint256 notional = 100e6 * perToken / RAY; // 99.7264
        assertEq(notional, 99_726_402);
        // ceil(notional * price) + ceil(floor(notional) * 0.5%)
        uint256 gross = (100e6 * perToken * mid + RAY * 1e4 - 1) / (RAY * 1e4);
        assertEq(cost, gross + (notional * 50 + 9999) / 10_000);

        usdc.mint(alice, cost);
        vm.startPrank(alice);
        usdc.approve(address(desk), cost);
        vm.expectEmit(address(desk));
        emit IPerpDesk.Traded(
            address(s),
            alice,
            IPerpDesk.Side.BuyNote,
            alice,
            100e6,
            notional,
            uint16(mid),
            cost,
            50,
            integrator,
            pricer.weightsHash()
        );
        desk.buy(address(s), 100e6, cost, 50, integrator, alice);
        vm.stopPrank();
        // the pairs cost their melted value
        assertEq(usdc.balanceOf(address(s)), s.previewMint(100e6));
    }

    function test_released_cash_counts_at_once_and_collect_pulls_it() public {
        _buy(alice, 100e6, 0); // the Desk holds 100 COVER
        uint256 before = desk.totalAssets();
        _fixing(1, 3000); // knocked in: this fixing pays COVER a * (1 - 0.3)
        (uint256 n, uint256 w, uint256 released) =
            (noteT.balanceOf(address(desk)), coverT.balanceOf(address(desk)), s.claimable(address(desk)));
        assertEq(n, 0);
        assertEq(w, 100e6);
        assertEq(released, 191_518);
        // the knock-in is the Desk's gain: its COVER is worth more, and part of it is cash already
        uint256 coverValue = (100e6 * s.state().notionalPerToken / RAY) * (PAIR_BPS - _mid()) / 10_000;
        assertEq(desk.totalAssets(), before - 21_600_000 + coverValue + released);
        assertGt(desk.totalAssets(), before);

        uint256 idle = usdc.balanceOf(address(desk));
        vm.expectEmit(address(desk));
        emit IPerpDesk.Collected(address(s), released);
        assertEq(desk.collect(address(s)), released);
        assertEq(usdc.balanceOf(address(desk)), idle + released);
        assertEq(desk.totalAssets(), before - 21_600_000 + coverValue + released); // unchanged by the collect
        assertEq(desk.heldSeries().length, 1); // still holds COVER
    }

    function test_collect_redeems_pairs_and_forgets_a_flat_series() public {
        _buy(alice, 100e6, 0);
        vm.prank(alice);
        noteT.transfer(address(desk), 100e6); // a donation makes the Desk hold both legs
        uint256 out = desk.collect(address(s));
        assertEq(out, 100_000_000);
        assertEq(desk.heldSeries().length, 0);
        assertEq(noteT.totalSupply(), 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.NotFactorySeries.selector, address(1)));
        desk.collect(address(1));
    }

    function test_a_closed_series_is_worth_its_released_cash() public {
        _buy(alice, 100e6, 0);
        _fixing(1, 3000);
        // the feed dies; the 14th missed fixing (14 days later) closes the series at the last good fixing, x = 0.3
        vm.warp(uint256(_fixingTime(s, 15)) + FALLBACK);
        assertEq(uint8(s.state().phase), uint8(PerpPhase.Closed));
        // nothing to quote any more: the position is cash, and LP flows work without the feed
        uint256 released = s.claimable(address(desk));
        assertApproxEqAbs(released, 70_000_000, 10); // COVER: 1 - x per unit of notional
        assertEq(desk.totalAssets(), usdc.balanceOf(address(desk)) + released);
        assertTrue(_markable());
        (uint256 atRisk,) = desk.risk(address(feed));
        assertEq(atRisk, 0);
        assertEq(desk.collect(address(s)), released);
        assertEq(desk.heldSeries().length, 0);
        assertEq(desk.totalAssets(), usdc.balanceOf(address(desk)));
        // alice's NOTE: x per unit of notional
        assertApproxEqAbs(s.claimable(alice), 30_000_000, 10);
    }

    // --- risk budget ----------------------------------------------------------------------------

    function test_risk_budget_is_closed_until_set_and_limits_new_positions() public {
        desk.setRiskBudget(address(feed), 0);
        uint256 quoted = _quoteOf(IPerpDesk.Side.BuyNote, 100e6, 0);
        usdc.mint(alice, quoted);
        vm.startPrank(alice);
        usdc.approve(address(desk), quoted);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.RiskBudgetExceeded.selector, uint256(21_600_000), uint256(0)));
        desk.buy(address(s), 100e6, quoted, 0, integrator, alice);
        vm.stopPrank();

        // 1% of ~1,000,000: room for COVER marked at 0.216 per unit, i.e. 46,296 NOTE sold
        desk.setRiskBudget(address(feed), 100);
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buy(alice, 46_000e6, 0);
        (uint256 atRisk, uint256 limit) = desk.risk(address(feed));
        assertEq(atRisk, 46_000e6 * COVER_BPS / 10_000);
        assertEq(limit, desk.totalAssets() / 100);
        quoted = _quoteOf(IPerpDesk.Side.BuyNote, 1_000e6, 0);
        usdc.mint(alice, quoted);
        vm.startPrank(alice);
        usdc.approve(address(desk), quoted);
        vm.expectRevert(); // RiskBudgetExceeded(atRisk after the trade, limit)
        desk.buy(address(s), 1_000e6, quoted, 0, integrator, alice);
        vm.stopPrank();
        // a trade that shrinks the position always works
        _sell(alice, 46_000e6, 0);
        (atRisk,) = desk.risk(address(feed));
        assertEq(atRisk, 0);
    }

    function test_risk_counts_all_of_note_without_a_reserve() public {
        _buyCover(hedger, 100e6, 0); // the Desk holds 100 NOTE at 0.784 and no coupon reserve
        (uint256 atRisk,) = desk.risk(address(feed));
        assertEq(atRisk, 78_400_000);
    }

    /// One budget per feed: an ETH and a BTC series.
    function test_risk_budget_is_per_feed() public {
        MockChainlinkFeed btc = new MockChainlinkFeed("BTC / USD");
        PerpSeries s2 = _create(_btcTerms(address(btc), first));
        btc.pushRoundAt(int256(uint256(INITIAL)), first);
        _recorder(s2).recordFixing(first, uint80(btc.latestRound()));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        MockPerpPricer btcPricer = new MockPerpPricer();
        btcPricer.setProduct(_btcProduct());
        btcPricer.setRange(1, 2100, 12_000);
        desk.listSeries(address(s2), btcPricer, CAP);
        desk.setMarkets(_upd(address(btc), 4500, CARRY, uint40(block.timestamp), SOURCE)); // cover at 90%, vol 45%: 1 - 0.8762
        // no budget for BTC yet
        usdc.mint(alice, 200e6);
        vm.startPrank(alice);
        usdc.approve(address(desk), 200e6);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.RiskBudgetExceeded.selector, uint256(1_238_000), uint256(0)));
        desk.buy(address(s2), 10e6, 200e6, 0, integrator, alice);
        desk.buy(address(s), 10e6, 200e6, 0, integrator, alice); // ETH has its own
        vm.stopPrank();
        (uint256 atRisk1,) = desk.risk(address(feed));
        (uint256 atRisk2, uint256 limit2) = desk.risk(address(btc));
        assertEq(atRisk1, 2_160_000);
        assertEq(atRisk2, 0);
        assertEq(limit2, 0);
    }

    function test_risk_with_an_unquotable_series_counts_the_most() public {
        _buy(alice, 100e6, 0); // 100 COVER
        _buyCover(hedger, 150e6, 0); // paired: the Desk now holds 50 NOTE
        assertEq(noteT.balanceOf(address(desk)), 50e6);
        uint256 updatedAt = block.timestamp;
        vm.warp(block.timestamp + STALENESS + 1); // the feed goes stale
        (uint256 atRisk, uint256 limit) = desk.risk(address(feed));
        assertEq(atRisk, 50e6); // 1 USDC per unit of notional
        // its NOTE counts only its coupon reserve as an asset: nothing at launch
        assertEq(limit, usdc.balanceOf(address(desk)));
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.FeedStale.selector, uint40(updatedAt)));
        desk.totalAssets();
    }

    // --- LP flows: requests, settled by the keeper's update (IDeskQueue) --------------------------
    // --- (each rule on its own: PerpDeskRequests.t.sol) -----------------------------------------

    /// While a held series can't be quoted there is no share price (a pending fixing, a stale
    /// feed): the keeper's update settles nothing (its write still goes through), and a due
    /// request waits for an update that can.
    function test_lp_flows_pause_while_a_held_series_cannot_be_quoted() public {
        _buy(alice, 100e6, 0);
        uint256 id = _requestDeposit(bob, 1_000e6);
        assertTrue(_markable());
        // a pending fixing: the feed has a round at the fixing time, nobody recorded it
        feed.pushRoundAt(_price(9000), first + DAY);
        vm.warp(uint256(first) + DAY + 1);
        _spot(9000);
        assertFalse(_markable());
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.FixingPending.selector, first + DAY));
        desk.totalAssets();
        _settle();
        (,, uint256 pending) = desk.depositRequest(id);
        assertEq(pending, 1_000e6);
        _recorder(s).recordFixing(first + DAY, uint80(feed.latestRound() - 1));
        assertTrue(_markable());
        // the feed goes stale
        uint256 updatedAt = block.timestamp;
        vm.warp(block.timestamp + STALENESS + 1);
        assertFalse(_markable());
        vm.expectRevert(abi.encodeWithSelector(IPerpQuoter.FeedStale.selector, uint40(updatedAt)));
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        _keeper(VOL, CARRY, uint40(block.timestamp)); // the write goes through, the settlement waits
        (,, pending) = desk.depositRequest(id);
        assertEq(pending, 1_000e6);
        // a fresh round: the keeper's next update fills it at the share price of that moment
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        uint256 shares = desk.previewDeposit(1_000e6);
        _keeper(VOL, CARRY, uint40(block.timestamp));
        assertEq(desk.balanceOf(bob), shares);
        (,, pending) = desk.depositRequest(id);
        assertEq(pending, 0);
    }

    /// Without a position the share price needs no feed: requests settle with the feed and its
    /// market data long stale (the cutoff is the update's own time).
    function test_without_positions_lp_flows_never_pause() public {
        _requestRedeem(lp, desk.balanceOf(lp));
        vm.warp(block.timestamp + 30 days); // the feed and its market data are long stale
        assertEq(desk.totalAssets(), LP_CAPITAL);
        _settleWithoutWrite();
        vm.prank(lp);
        assertEq(desk.claim(lp), LP_CAPITAL);
        assertEq(usdc.balanceOf(lp), LP_CAPITAL);
        assertEq(desk.totalSupply(), 0);
    }

    function test_fees_and_spreads_accrue_to_lps() public {
        desk.setSpread(address(s), 30, 40, 0);
        _buy(alice, 100e6, 100);
        _sell(alice, 100e6, 100);
        // spread: 100 * (0.0040 + 0.0030); fees: 2 * 1% of 100, half of each kept
        assertEq(desk.totalAssets(), LP_CAPITAL + 700_000 + 1_000_000);
        assertEq(usdc.balanceOf(integrator), 1_000_000);
        _requestRedeem(lp, desk.balanceOf(lp));
        _later(DELAY, 9000);
        _settle();
        vm.prank(lp);
        desk.claim(lp);
        assertApproxEqAbs(usdc.balanceOf(lp), LP_CAPITAL + 1_700_000, 2);
    }

    // --- the redemption queue ---------------------------------------------------------------------

    /// A due redemption is filled out of idle USDC only: the rest waits, and while it does
    /// (`shortfall`) no trade may add to the Desk's position. Trades that shrink it free USDC;
    /// the keeper's next update pays the queue and clears the flag.
    function test_queue_request_fill_claim() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buyCover(hedger, 900_000e6, 0); // idle is short
        uint256 shares = desk.balanceOf(lp);
        uint256 id = _requestRedeem(lp, shares);
        uint40 due = uint40(block.timestamp) + DELAY;
        assertEq(desk.queuedShares(), shares);
        assertFalse(desk.shortfall()); // a request is not a shortfall

        // due an hour later: the keeper's update fills part of it out of the idle USDC
        _later(DELAY, 9000);
        uint256 idle = usdc.balanceOf(address(desk));
        _settle();
        (address owner_, uint40 dueAt, uint256 rest) = desk.redeemRequest(id);
        assertEq(owner_, lp);
        assertEq(dueAt, due);
        assertGt(rest, 0);
        assertLt(rest, shares);
        assertTrue(desk.shortfall());
        uint256 setAside = desk.claimableAssets(lp);
        assertApproxEqAbs(setAside, idle, 1); // the idle USDC, rounded down
        assertEq(desk.reservedAssets(), setAside);
        // a trade that would add to the Desk's position can't jump the queue
        uint256 quoted = _quoteOf(IPerpDesk.Side.BuyCover, 10e6, 0);
        usdc.mint(hedger, quoted);
        vm.startPrank(hedger);
        usdc.approve(address(desk), quoted);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.QueuePending.selector, rest));
        desk.buyCover(address(s), 10e6, quoted, 0, integrator, hedger);
        vm.stopPrank();
        // the hedger sells the cover back: the pairs unwind and USDC is free; the flag stays
        // until the keeper's next update, which pays the queue
        _sellCover(hedger, 900_000e6, 0);
        assertTrue(desk.shortfall());
        _later(UPDATE_GAP, 9000);
        _settle();
        assertFalse(desk.shortfall());
        assertEq(desk.queuedShares(), 0);
        (,, rest) = desk.redeemRequest(id);
        assertEq(rest, 0);
        assertEq(desk.totalSupply(), 0);
        uint256 claimable = desk.claimableAssets(lp);
        assertLe(usdc.balanceOf(address(desk)) - claimable, 2); // the only LP gets everything
        vm.prank(lp);
        assertEq(desk.claim(lp), claimable);
        assertEq(usdc.balanceOf(lp), claimable);
    }

    // --- quote's newPosition (#68) ----------------------------------------------------------------

    /// `quote`'s newPosition is what the trade then adds as a new position of the Desk, on every
    /// side, all from stock, partly from stock and all new: after the trade the Desk holds that
    /// many more COVER (it sold NOTE or bought cover back) or NOTE (it bought NOTE or sold cover),
    /// the other leg shrinks by the rest, and the series minted that many pairs (a buy) or
    /// redeemed the rest (a sale). From an empty Desk, step by step; the Desk's NOTE and COVER
    /// after each trade in the comments, in whole tokens.
    function test_quote_newPosition_is_what_the_trade_adds() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _mintPairs(s, hedger, 1_000e6); // NOTE and COVER to sell
        (IPerpDesk.Side bn, IPerpDesk.Side sn, IPerpDesk.Side bc, IPerpDesk.Side sc) =
            (IPerpDesk.Side.BuyNote, IPerpDesk.Side.SellNote, IPerpDesk.Side.BuyCover, IPerpDesk.Side.SellCover);
        _expectNewPosition(bn, 100e6, 100e6); // all new: 0, 100
        _expectNewPosition(bc, 20e6, 0); // from stock: 0, 80
        _expectNewPosition(sn, 30e6, 0); // paired with stock: 0, 50
        _expectNewPosition(sc, 10e6, 10e6); // no NOTE to pair it with: 0, 60
        _expectNewPosition(bc, 80e6, 20e6); // 60 from stock: 20, 0
        _expectNewPosition(sn, 30e6, 30e6); // no COVER to pair it with: 50, 0
        _expectNewPosition(bn, 20e6, 0); // from stock: 30, 0
        _expectNewPosition(sc, 10e6, 0); // paired with stock: 20, 0
        _expectNewPosition(bn, 50e6, 30e6); // 20 from stock: 0, 30
        _expectNewPosition(sn, 50e6, 20e6); // 30 paired: 20, 0
        _expectNewPosition(bc, 10e6, 10e6); // no COVER in stock: 30, 0
        _expectNewPosition(sc, 50e6, 20e6); // 30 paired: 0, 20
        assertEq(noteT.balanceOf(address(desk)), 0);
        assertEq(coverT.balanceOf(address(desk)), 20e6);
    }

    /// In a shortfall `quote` still gives the price, and its newPosition is the part that waits
    /// (#68). The Desk holds NOTE: a cover buy and a NOTE sale (all new) quote at the usual prices
    /// with newPosition = amount, and revert QueuePending; a NOTE buy and a cover sale served from
    /// its NOTE quote newPosition 0 and go through at the quote; a NOTE buy beyond the stock quotes
    /// the excess, waits, and cut to `amount - newPosition` goes through. The quote still refuses
    /// what can never trade as asked (CapExceeded, with the stock counted in what is available).
    function test_in_a_shortfall_quote_prices_and_newPosition_is_what_waits() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buyCover(hedger, 900_000e6, 0); // the Desk holds 900,000 NOTE; idle ~294,400 USDC
        _requestRedeem(lp, desk.balanceOf(lp));
        _later(DELAY, 9000);
        _settle();
        assertTrue(desk.shortfall());
        bytes memory waits = abi.encodeWithSelector(IDeskQueue.QueuePending.selector, desk.queuedShares());
        uint256 mid = _mid(); // no spread: every side trades at the mid

        // from stock: a NOTE buy, at its quote
        (uint256 paid, uint16 priceBps, uint256 newPosition) =
            desk.quote(address(s), IPerpDesk.Side.BuyNote, 10_000e6, 0);
        assertEq(priceBps, mid);
        assertEq(newPosition, 0);
        assertEq(_buy(alice, 10_000e6, 0), paid);
        assertEq(noteT.balanceOf(address(desk)), 890_000e6);

        // all new: alice's NOTE back (no COVER to pair it with), a cover buy (none in stock)
        (paid, priceBps, newPosition) = desk.quote(address(s), IPerpDesk.Side.SellNote, 5_000e6, 0);
        assertEq(priceBps, mid);
        assertEq(paid, 5_000e6 * mid / 10_000);
        assertEq(newPosition, 5_000e6);
        vm.startPrank(alice);
        noteT.approve(address(desk), 5_000e6);
        vm.expectRevert(waits);
        desk.sell(address(s), 5_000e6, paid, 0, integrator, alice);
        vm.stopPrank();
        (paid, priceBps, newPosition) = desk.quote(address(s), IPerpDesk.Side.BuyCover, 1_000e6, 0);
        assertEq(priceBps, PAIR_BPS - mid);
        assertEq(newPosition, 1_000e6);
        usdc.mint(hedger, paid);
        vm.startPrank(hedger);
        usdc.approve(address(desk), paid);
        vm.expectRevert(waits);
        desk.buyCover(address(s), 1_000e6, paid, 0, integrator, hedger);
        vm.stopPrank();

        // from stock: the hedger's cover back, paired with the Desk's NOTE
        (paid, priceBps, newPosition) = desk.quote(address(s), IPerpDesk.Side.SellCover, 100_000e6, 0);
        assertEq(priceBps, PAIR_BPS - mid);
        assertEq(newPosition, 0);
        assertEq(_sellCover(hedger, 100_000e6, 0), paid);
        assertEq(noteT.balanceOf(address(desk)), 790_000e6);

        // the cap still refuses in the quote: 50,000 of new COVER at most, besides the stock
        desk.listSeries(address(s), pricer, 50_000e6);
        vm.expectRevert(
            abi.encodeWithSelector(IPerpDesk.CapExceeded.selector, uint256(1_000_000e6), uint256(840_000e6))
        );
        desk.quote(address(s), IPerpDesk.Side.BuyNote, 1_000_000e6, 0);
        desk.listSeries(address(s), pricer, type(uint128).max);

        // partly from stock: the excess waits, the rest goes through
        (paid,, newPosition) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 1_000_000e6, 0);
        assertEq(newPosition, 210_000e6);
        usdc.mint(alice, paid);
        vm.startPrank(alice);
        usdc.approve(address(desk), paid);
        vm.expectRevert(waits);
        desk.buy(address(s), 1_000_000e6, paid, 0, integrator, alice);
        vm.stopPrank();
        (,, newPosition) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 1_000_000e6 - 210_000e6, 0);
        assertEq(newPosition, 0);
        _buy(alice, 790_000e6, 0);
        assertEq(noteT.balanceOf(address(desk)), 0);
        assertEq(coverT.balanceOf(address(desk)), 0);
        assertTrue(desk.shortfall()); // until the keeper's next update
    }

    /// The risk budget, like the queue, applies only to the part of a trade that adds to the
    /// Desk's position (#68), and `quote` doesn't apply it: with a budget of 0 a cover buy (all
    /// new) is priced with newPosition = amount and reverts RiskBudgetExceeded; a NOTE buy from
    /// the Desk's NOTE goes through; one beyond it is priced, and its excess is refused.
    function test_quote_leaves_the_risk_budget_to_newPosition() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buyCover(hedger, 100_000e6, 0); // the Desk holds 100,000 NOTE
        desk.setRiskBudget(address(feed), 0);

        (uint256 paid, uint16 priceBps, uint256 newPosition) =
            desk.quote(address(s), IPerpDesk.Side.BuyCover, 1_000e6, 0);
        assertEq(priceBps, COVER_BPS);
        assertEq(newPosition, 1_000e6);
        usdc.mint(hedger, paid);
        vm.startPrank(hedger);
        usdc.approve(address(desk), paid);
        vm.expectRevert(
            abi.encodeWithSelector(IPerpDesk.RiskBudgetExceeded.selector, uint256(101_000e6) * NOTE_BPS / 10_000, 0)
        );
        desk.buyCover(address(s), 1_000e6, paid, 0, integrator, hedger);
        vm.stopPrank();

        (paid,, newPosition) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 60_000e6, 0);
        assertEq(newPosition, 0);
        assertEq(_buy(alice, 60_000e6, 0), paid);

        (paid, priceBps, newPosition) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 50_000e6, 0);
        assertEq(priceBps, NOTE_BPS);
        assertEq(newPosition, 10_000e6);
        usdc.mint(alice, paid);
        vm.startPrank(alice);
        usdc.approve(address(desk), paid);
        vm.expectRevert(
            abi.encodeWithSelector(IPerpDesk.RiskBudgetExceeded.selector, uint256(10_000e6) * COVER_BPS / 10_000, 0)
        );
        desk.buy(address(s), 50_000e6, paid, 0, integrator, alice);
        vm.stopPrank();
    }

    /// The same for sales (#68): with a budget of 0 and the Desk holding 100,000 NOTE, a cover sale
    /// that pairs entirely with that NOTE (newPosition 0) goes through although the Desk stays over
    /// budget; one with a new part is refused RiskBudgetExceeded, the feed's whole risk after it.
    function test_a_sale_from_stock_leaves_the_risk_budget_alone() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buyCover(hedger, 100_000e6, 0); // the Desk holds 100,000 NOTE, the hedger the cover
        desk.setRiskBudget(address(feed), 0);

        (uint256 paid,, uint256 newPosition) = desk.quote(address(s), IPerpDesk.Side.SellCover, 60_000e6, 0);
        assertEq(newPosition, 0);
        assertEq(_sellCover(hedger, 60_000e6, 0), paid);
        (uint256 atRisk, uint256 limit) = desk.risk(address(feed));
        assertEq(atRisk, uint256(40_000e6) * NOTE_BPS / 10_000); // still over budget
        assertEq(limit, 0);

        (,, newPosition) = desk.quote(address(s), IPerpDesk.Side.SellCover, 40_001e6, 0);
        assertEq(newPosition, 1e6);
        _mintPairs(s, hedger, 1e6);
        vm.startPrank(hedger);
        coverT.approve(address(desk), 40_001e6);
        vm.expectRevert(
            abi.encodeWithSelector(IPerpDesk.RiskBudgetExceeded.selector, uint256(1e6) * COVER_BPS / 10_000, 0)
        );
        desk.sellCover(address(s), 40_001e6, 0, 0, integrator, hedger);
        vm.stopPrank();
    }

    /// Quotes `amount` on `side`, expects `expected` as its newPosition, trades it as the hedger,
    /// and checks newPosition against what the trade did to the Desk's NOTE and COVER and to the
    /// supply.
    function _expectNewPosition(IPerpDesk.Side side, uint256 amount, uint256 expected) internal {
        (uint256 paid,, uint256 newPosition) = desk.quote(address(s), side, amount, 0);
        assertEq(newPosition, expected, "newPosition");
        bool isBuy = side == IPerpDesk.Side.BuyNote || side == IPerpDesk.Side.BuyCover;
        (IERC20 grows, IERC20 shrinks) =
            side == IPerpDesk.Side.BuyNote || side == IPerpDesk.Side.SellCover ? (coverT, noteT) : (noteT, coverT);
        uint256 grew = grows.balanceOf(address(desk));
        uint256 shrank = shrinks.balanceOf(address(desk));
        uint256 supply = noteT.totalSupply();
        uint256 done;
        if (side == IPerpDesk.Side.BuyNote) done = _buy(hedger, amount, 0);
        else if (side == IPerpDesk.Side.SellNote) done = _sell(hedger, amount, 0);
        else if (side == IPerpDesk.Side.BuyCover) done = _buyCover(hedger, amount, 0);
        else done = _sellCover(hedger, amount, 0);
        assertEq(done, paid, "paid");
        assertEq(grows.balanceOf(address(desk)), grew + newPosition, "the new position");
        assertEq(shrinks.balanceOf(address(desk)), shrank - (amount - newPosition), "the rest, from stock");
        assertEq(noteT.totalSupply(), isBuy ? supply + newPosition : supply - (amount - newPosition), "pairs");
    }

    /// Requests below the minimums are refused. Requests are binding: only the owner cancels, and
    /// only once its request is STALL (6 hours) past due and still unsettled; it then gets the
    /// unfilled rest back exactly, and the next settlement skips the request.
    function test_queue_request_errors_and_cancel() public {
        vm.startPrank(lp);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.RequestTooSmall.selector, uint256(1), uint256(10e12)));
        desk.requestRedeem(1);
        uint256 id = desk.requestRedeem(20e12);
        vm.stopPrank();
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(desk), 1_000e6);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.RequestTooSmall.selector, uint256(100e6 - 1), uint256(100e6)));
        desk.requestDeposit(100e6 - 1);
        uint256 dep = desk.requestDeposit(100e6);
        vm.stopPrank();
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.NotRequestOwner.selector, id));
        desk.cancelRedeem(id);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.NotRequestOwner.selector, dep));
        desk.cancelDeposit(dep);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.NotRequestOwner.selector, uint256(9)));
        desk.cancelDeposit(9); // no such request
        vm.expectRevert(IDeskQueue.NothingToClaim.selector);
        desk.claim(alice);
        // binding until 6 hours past due
        uint40 from = uint40(block.timestamp) + DELAY + STALL;
        vm.warp(from - 1);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.CancelTooEarly.selector, from));
        desk.cancelRedeem(id);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.CancelTooEarly.selector, from));
        desk.cancelDeposit(dep);
        vm.warp(from);
        vm.prank(lp);
        assertEq(desk.cancelRedeem(id), 20e12);
        vm.prank(bob);
        assertEq(desk.cancelDeposit(dep), 100e6);
        assertEq(usdc.balanceOf(bob), 1_000e6);
        assertEq(desk.balanceOf(lp), LP_CAPITAL * 1e6);
        assertEq(desk.queuedShares(), 0);
        assertEq(desk.pendingDepositAssets(), 0);
        // the next settlement skips both
        (uint256 head, uint256 length) = desk.queue();
        assertEq(head, 0);
        assertEq(length, 1);
        _settleWithoutWrite(); // no position: no market data needed
        (head,) = desk.queue();
        assertEq(head, 1);
        (head, length) = desk.depositQueue();
        assertEq(head, 2); // the fixture's deposit and bob's
        assertEq(length, 2);
        assertEq(desk.balanceOf(bob), 0);
        // cancelling again returns nothing
        vm.prank(lp);
        assertEq(desk.cancelRedeem(id), 0);
    }

    /// While a held feed's market data is stale there is no share price: the keeper's update
    /// still writes the other feed and settles nothing. A request waiting for a price is not a
    /// shortfall: trades go on on the fresh feed, both ways, and requests, claim and collect go
    /// on. The keeper's next update of both feeds settles it.
    function test_the_queue_while_a_held_feeds_market_data_is_stale() public {
        // a BTC series next to the ETH one, the Desk holding COVER of both
        MockChainlinkFeed btc = new MockChainlinkFeed("BTC / USD");
        PerpSeries s2 = _create(_btcTerms(address(btc), first));
        btc.pushRoundAt(int256(uint256(INITIAL)), first);
        _recorder(s2).recordFixing(first, uint80(btc.latestRound()));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        MockPerpPricer btcPricer = new MockPerpPricer();
        btcPricer.setProduct(_btcProduct());
        btcPricer.setRange(1, 2100, 12_000);
        desk.listSeries(address(s2), btcPricer, CAP);
        _setMarket(address(btc), 4500, CARRY, uint40(block.timestamp), SOURCE);
        desk.setRiskBudget(address(btc), 10_000);
        _buy(alice, 100e6, 0);
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(desk), type(uint256).max);
        desk.buy(address(s2), 100e6, type(uint256).max, 0, integrator, alice);
        IERC20(s2.note()).approve(address(desk), type(uint256).max);
        IERC20(s2.cover()).approve(address(desk), type(uint256).max);
        vm.stopPrank();
        // a redemption filled while all is fresh (the keeper writes both feeds; BTC's last write
        // was the owner's, no settlement price before it): the LP claims it later
        _requestRedeem(lp, 1e17);
        _later(DELAY, 9000);
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        IPerpDesk.MarketUpdate[] memory u = new IPerpDesk.MarketUpdate[](2);
        u[0] = _upd(address(feed), VOL, CARRY, uint40(block.timestamp), SOURCE)[0];
        u[1] = _upd(address(btc), 4500, CARRY, uint40(block.timestamp), SOURCE)[0];
        vm.prank(keeper);
        desk.setMarkets(u);
        uint256 claimable = desk.claimableAssets(lp);
        assertGt(claimable, 0);

        // ETH's market data goes stale; both feeds stay fresh
        (,, uint40 t,,) = desk.market(address(feed));
        vm.warp(uint256(t) + MARKET_AGE + 1);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        bytes memory stale = abi.encodeWithSelector(IPerpDesk.MarketStale.selector, address(feed), t);
        uint256 id = _requestRedeem(lp, 1e17); // a request still goes in
        vm.warp(block.timestamp + DELAY);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        // the keeper writes BTC: the write goes through, nothing settles
        vm.prank(keeper);
        desk.setMarkets(_upd(address(btc), 4500, CARRY, uint40(block.timestamp), SOURCE));
        (,, uint40 btcTime,,) = desk.market(address(btc));
        assertEq(btcTime, block.timestamp);
        (,, uint256 rest) = desk.redeemRequest(id);
        assertEq(rest, 1e17);
        assertFalse(desk.shortfall());
        vm.expectRevert(stale);
        desk.totalAssets();
        vm.startPrank(alice);
        // BTC trades on, adding to the Desk's position (buy) too; ETH's are refused for its data
        desk.buy(address(s2), 1e6, type(uint256).max, 0, integrator, alice);
        desk.sell(address(s2), 1e6, 0, 0, integrator, alice);
        desk.buyCover(address(s2), 1e6, type(uint256).max, 0, integrator, alice);
        vm.expectRevert(stale);
        desk.buy(address(s), 1e6, type(uint256).max, 0, integrator, alice);
        vm.stopPrank();
        // claim, collect
        uint256 before = usdc.balanceOf(lp);
        vm.prank(lp);
        assertEq(desk.claim(lp), claimable);
        assertEq(usdc.balanceOf(lp), before + claimable);
        desk.collect(address(s));
        desk.collect(address(s2));
        // the keeper's next update writes both feeds: the request settles
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        u[0] = _upd(address(feed), VOL, CARRY, uint40(block.timestamp), SOURCE)[0];
        u[1] = _upd(address(btc), 4500, CARRY, uint40(block.timestamp), SOURCE)[0];
        vm.prank(keeper);
        desk.setMarkets(u);
        (,, rest) = desk.redeemRequest(id);
        assertEq(rest, 0);
        assertGt(desk.claimableAssets(lp), 0);
    }

    // --- around a fixing: nothing to gain by timing it (regressions from the review) --------------

    function _formulaPricer() internal returns (PerpFormulaPricer) {
        return new PerpFormulaPricer(pricer.product(), _bands());
    }

    /// A formula-priced listing: the share price doesn't step at a clean fixing (the pricer's
    /// accrual carries the release in the price before it), so a request has nothing to time
    /// around it. (Before the accrual, an LP in for a minute around the fixing left with 204
    /// USDC of the others' money.)
    function test_no_step_in_the_share_price_at_a_clean_fixing() public {
        desk.listSeries(address(s), _formulaPricer(), CAP);
        _buyCover(alice, 100_000e6, 0); // the Desk holds 100,000 NOTE
        uint40 t1 = _fixingTime(s, 1);
        vm.warp(uint256(t1) - 60);
        _spot(9000);
        uint256 navBefore = desk.totalAssets();
        _fixing(1, 9000); // the spot does not move
        uint256 navAfter = desk.totalAssets();
        assertApproxEqAbs(navAfter, navBefore, 15e6); // within rounding to whole bps of 100,000 notional
        desk.collect(address(s));
        assertEq(desk.totalAssets(), navAfter);
    }

    /// A clean note below the crash line just before a fixing is about to knock in: the formula
    /// pricer refuses there (its knock-in band), so the keeper's update settles nothing instead
    /// of settling at a price that is about to step.
    function test_lp_flows_pause_in_the_formula_pricers_band_before_a_knock_in() public {
        desk.listSeries(address(s), _formulaPricer(), CAP);
        desk.setSpread(address(s), 20, 30, 200);
        _buy(alice, 90_000e6, 0); // the Desk holds 90,000 COVER
        uint256 id = _requestDeposit(bob, 100e6); // due long before the fixing
        uint40 t1 = _fixingTime(s, 1);
        vm.warp(uint256(t1) - 60);
        _spot(3950);
        assertFalse(_markable());
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(0)));
        desk.totalAssets();
        _settle();
        (,, uint256 pending) = desk.depositRequest(id);
        assertEq(pending, 100e6);
        assertEq(desk.balanceOf(bob), 0);
    }

    /// A fixing left unrecorded past its fallback deadline: the keeper's settling update stores
    /// the held series' fallback first, so a recording made afterwards can no longer move the
    /// share price an LP got in or out at.
    function test_a_late_recording_cannot_move_the_share_price_under_an_lp() public {
        _buy(alice, 50_000e6, 0);
        uint40 t1 = _fixingTime(s, 1);
        vm.warp(uint256(t1) + 1);
        feed.pushRoundAt(_price(3000), t1); // the round exists, nobody records it
        uint80 round1 = uint80(feed.latestRound());
        address attacker = makeAddr("attacker");
        uint256 id = _requestDeposit(attacker, 1_000_000e6);
        // an hour before the deadline the keeper's job refreshes the market data (stale by
        // then): the deposit is due, the fixing pending, nothing settles
        vm.warp(uint256(t1) + FALLBACK - 1 hours);
        _spot(3000);
        assertFalse(_markable());
        (,, uint256 pending) = desk.depositRequest(id);
        assertEq(pending, 1_000_000e6);
        // fixing 1's deadline: FALLBACK_GRACE after it, long before fixing 2
        vm.warp(uint256(t1) + FALLBACK);
        _spot(3000);
        assertEq(s.state().fixingsDone, 1); // the views fell back for fixing 1
        assertFalse(s.state().knockedIn); // the fallback reused 100; the round says 30

        uint256 shares = desk.previewDeposit(1_000_000e6);
        _settle(); // stores the fallback, then fills the deposit at that price
        assertEq(desk.balanceOf(attacker), shares);
        uint256 nav = desk.totalAssets();
        _recorder(s).recordFixing(t1, round1); // too late to matter
        assertEq(desk.totalAssets(), nav);
        assertFalse(s.state().knockedIn);
    }

    /// A vol the formula pricer is not built for (one the closed form can't carry) is accepted as
    /// market data and simply not quoted: OutOfRange(1, vol) for the mark, and at the band's low
    /// end (the pricer's minimum, 2 points) for a trade, never a price.
    function test_a_vol_the_formula_pricer_is_not_built_for_is_not_quoted() public {
        PerpFormulaPricer fp = _formulaPricer();
        desk.listSeries(address(s), fp, CAP);
        _buy(alice, 1_000e6, 0);
        _market(600, CARRY);
        _expectOutOfRange(1, 400);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, uint8(1), int64(600)));
        desk.totalAssets();
        _market(VOL, CARRY);
        desk.setSpread(address(s), 0, 0, 4601); // 70% - 46.01% is below its 24%
        _expectOutOfRange(1, 2399);
        desk.setSpread(address(s), 0, 0, 4600);
        _expectQuotes();
        assertGt(desk.totalAssets(), 0);
    }

    // --- the launch's bands: the pricer's 2 hours near a line, the Desk's 300 s ---------------------

    /// Every side of the listing refuses with the pricer's Uncertified(region).
    function _expectUncertified(uint8 region) internal {
        for (uint8 side = 0; side < 4; side++) {
            vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, region));
            desk.quote(address(s), IPerpDesk.Side(side), 1e6, 0);
        }
    }

    /// Every side of the listing quotes.
    function _expectQuotes() internal view {
        for (uint8 side = 0; side < 4; side++) {
            desk.quote(address(s), IPerpDesk.Side(side), 1e6, 0);
        }
    }

    /// In the crash line's strip (clean) or near the high (knocked in): every side refuses with
    /// NearLine(spotBps), quotes too.
    function _expectNoSide(uint256 spotBps) internal {
        for (uint8 side = 0; side < 4; side++) {
            vm.expectRevert(abi.encodeWithSelector(IPerpDesk.NearLine.selector, spotBps));
            desk.quote(address(s), IPerpDesk.Side(side), 1e6, 0);
        }
    }

    /// Every side of the listing refuses with the pricer's OutOfRange(field, value).
    function _expectOutOfRange(uint8 field, int64 value) internal {
        for (uint8 side = 0; side < 4; side++) {
            vm.expectRevert(abi.encodeWithSelector(IPerpPricer.OutOfRange.selector, field, value));
            desk.quote(address(s), IPerpDesk.Side(side), 1e6, 0);
        }
    }

    function _priceOf(IPerpDesk.Side side) internal view returns (uint256 priceBps) {
        (, priceBps,) = desk.quote(address(s), side, 1e6, 0);
    }

    /// The buy-back discount of a clean note at `x` bps of the high, with the launch's strip (100
    /// above the line) and reach (2,000): ceil(d * (k + 2,000 - x) / 1,900) above the strip and
    /// short of the reach, else 0 (docs/v2-spec.md §8), computed here independently of the Desk.
    function _discountBps(uint256 x, uint256 k, uint256 d) internal pure returns (uint256) {
        if (x <= k + 100 || x >= k + 2000) return 0;
        return (d * (k + 2000 - x) + 1899) / 1900;
    }

    /// The Desk's four prices on the fixture's listing, priced by `pr`, rebuilt from the quoter: the
    /// NOTE quotes at the feed's vol -/+ the band (the spread's, at least the pricer's minimum), the
    /// spread, and `d` bps added to the NOTE ask. `buy` and `sellCover` pay the raised ask, `sell`
    /// and `buyCover` are as without it. The series has no coupon reserve.
    function _expectPrices(IPerpPricer pr, uint256 d) internal view {
        (uint16 vol, int16 carry,,,) = desk.market(address(feed));
        IPerpDesk.Spread memory sp = desk.spread(address(s));
        uint16 band = sp.volBandBps;
        if (band < pr.lineBands().minVolBandBps) band = pr.lineBands().minVolBandBps;
        uint256 a = quoter.quote(s, pr, vol - band, carry).priceBps;
        uint256 c = quoter.quote(s, pr, vol + band, carry).priceBps;
        (uint256 lo, uint256 hi) = a < c ? (a, c) : (c, a);
        uint256 ask = hi + sp.askBps + d;
        if (ask > PAIR_BPS) ask = PAIR_BPS;
        if (lo > PAIR_BPS) lo = PAIR_BPS;
        uint256 bid = lo > sp.bidBps ? lo - sp.bidBps : 0;
        assertEq(_priceOf(IPerpDesk.Side.BuyNote), ask, "buy");
        assertEq(_priceOf(IPerpDesk.Side.SellCover), PAIR_BPS - ask, "sellCover");
        assertEq(_priceOf(IPerpDesk.Side.SellNote), bid, "sell");
        assertEq(_priceOf(IPerpDesk.Side.BuyCover), PAIR_BPS - bid, "buyCover");
    }

    /// docs/v2-spec.md §6 and §8: in the last 2 hours before a fixing (edge included) the formula
    /// pricer refuses a clean note from 2% of the high below the crash line `k` (the strip's lower
    /// edge) to 10% above it, edges included; trades and LP flows wait. Before the 2 hours the
    /// strip refuses at its edge. Outside the pricer's band every side trades down to the Desk's
    /// own 300 s: 2.01% below the line too, where the Desk buys cover back in its last minutes
    /// and the mark goes on; 10.01% above, at the buy-back discount.
    function _pricersBand(uint256 k) internal {
        _buy(alice, 2_000e6, 0);
        _buyCover(hedger, 1_000e6, 0); // the hedger holds cover to sell back
        // the Desk holds 1,000 COVER more than NOTE: LP flows need the quote too
        uint40 t1 = _fixingTime(s, 1);
        // 7,201 s before the fixing, just below the strip: every side trades
        vm.warp(uint256(t1) - 2 hours - 1);
        _spot(k - 201);
        _expectTradesOpen();
        assertTrue(_markable());
        // 7,200 s: at the band's lower edge, the pricer refuses first (before the strip's NearLine)
        vm.warp(uint256(t1) - 2 hours);
        _spot(k - 200);
        _expectUncertified(0);
        assertFalse(_markable());
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(0)));
        desk.totalAssets();
        // the edges of the spot band: k - 2% and k + 10% refused, 1 bps beyond them every side trades
        _later(1, k - 201);
        _expectTradesOpen();
        assertTrue(_markable());
        _later(1, k + 1000);
        _expectUncertified(0);
        _later(1, k + 1001);
        _expectTradesOpen();
        _later(1, k);
        _expectUncertified(0);
        // below the band the Desk trades down to 300 s before the fixing, and not after
        vm.warp(uint256(t1) - MIN_SECS - 1);
        _spot(k - 201);
        vm.warp(uint256(t1) - MIN_SECS);
        _expectQuotes();
        uint256 quoted = _quoteOf(IPerpDesk.Side.SellCover, 10e6, 0);
        assertEq(_sellCover(hedger, 10e6, 0), quoted); // cover bought back 300 s before 08:00
        vm.warp(uint256(t1) - MIN_SECS + 1);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.TooCloseToFixing.selector, t1));
        desk.quote(address(s), IPerpDesk.Side.SellCover, 1e6, 0);
        // LP flows don't stop for the Desk's band
        assertTrue(_markable());
        // in the band the pricer refuses first
        _spot(k - 200);
        _expectUncertified(0);
    }

    function test_the_pricers_band_near_the_crash_line_eth() public {
        desk.listSeries(address(s), _formulaPricer(), CAP);
        _pricersBand(KI);
    }

    function test_the_pricers_band_near_the_crash_line_btc() public {
        _useBtcSeries();
        _pricersBand(KI_BTC);
    }

    /// In the fixing band, 2.01% of the high below the crash line (just below the strip), the mark
    /// goes on: LP requests made 2 hours before the fixing settle at the keeper's update an hour
    /// later, still in the band, and every side quotes. (At 2% below, the pricer's band, the mark
    /// stops: `_pricersBand`.)
    function test_below_the_strip_lp_flows_settle_in_the_fixing_band() public {
        PerpFormulaPricer fp = _formulaPricer();
        desk.listSeries(address(s), fp, CAP);
        _buy(alice, 10_000e6, 0); // the Desk holds COVER
        uint40 t1 = _fixingTime(s, 1);
        vm.warp(uint256(t1) - 2 hours);
        _spot(KI - 201);
        _expectQuotes();
        _lpFlowsGoOn(fp, KI - 201);
        assertEq(block.timestamp, uint256(t1) - 1 hours);
        _expectPrices(fp, 0);
    }

    /// The same for a knocked-in note within 5% of the high (edges included): Uncertified(1).
    /// The crash line's band is for clean notes only.
    function test_the_pricers_band_near_the_high_when_knocked_in() public {
        desk.listSeries(address(s), _formulaPricer(), CAP);
        _fixing(1, 3000); // knocked in
        assertTrue(s.state().knockedIn);
        _buyCover(hedger, 1_000e6, 0); // the Desk holds NOTE
        uint40 t2 = _fixingTime(s, 2);
        vm.warp(uint256(t2) - 2 hours - 1);
        _spot(10_000);
        _expectNoSide(10_000);
        vm.warp(uint256(t2) - 2 hours);
        _expectUncertified(1);
        vm.expectRevert(abi.encodeWithSelector(IPerpPricer.Uncertified.selector, uint8(1)));
        desk.totalAssets();
        _later(1, 9500);
        _expectUncertified(1);
        _later(1, 9499);
        _expectQuotes();
        _later(1, 10_500);
        _expectUncertified(1);
        _later(1, 10_501);
        _expectQuotes();
        _later(1, 4000); // at the crash line, but knocked in
        _expectQuotes();
        assertTrue(_markable());
    }

    // --- near a line (docs/v2-spec.md §8): clean, no trade in the strip and buy-backs at a ---------
    // --- discount above it; knocked in near the high, no trade -------------------------------------

    /// From here on the fixture's series is a BTC one (k 50%) on its own feed, struck at INITIAL,
    /// listed with the launch's BTC formula pricer at BTC's market data (vol 45%, carry 4%), with a
    /// risk budget of the whole vault; spot 90% of the high, a day before the next fixing.
    function _useBtcSeries() internal {
        feed = new MockChainlinkFeed("BTC / USD");
        s = _create(_btcTerms(address(feed), first));
        noteT = IERC20(s.note());
        coverT = IERC20(s.cover());
        feed.pushRoundAt(int256(uint256(INITIAL)), first);
        _recorder(s).recordFixing(first, uint80(feed.latestRound()));
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        _market(4500, CARRY);
        desk.listSeries(address(s), new PerpFormulaPricer(_btcProduct(), _btcBands()), CAP);
        desk.setRiskBudget(address(feed), 10_000);
    }

    /// Every side of the listing refuses with the Desk's TooCloseToFixing.
    function _expectTooClose(uint40 fixingTime) internal {
        for (uint8 side = 0; side < 4; side++) {
            vm.expectRevert(abi.encodeWithSelector(IPerpDesk.TooCloseToFixing.selector, fixingTime));
            desk.quote(address(s), IPerpDesk.Side(side), 1e6, 0);
        }
    }

    /// The trades in the crash line's strip (clean) or near the high (knocked in): all four revert
    /// with the error their quotes give.
    function _expectNoTrades(uint256 spotBps) internal {
        bytes memory err = abi.encodeWithSelector(IPerpDesk.NearLine.selector, spotBps);
        usdc.mint(bob, 1_000e6);
        vm.startPrank(bob);
        usdc.approve(address(desk), 1_000e6);
        vm.expectRevert(err);
        desk.buy(address(s), 1e6, type(uint256).max, 0, integrator, bob);
        vm.expectRevert(err);
        desk.buyCover(address(s), 1e6, type(uint256).max, 0, integrator, bob);
        vm.stopPrank();
        vm.startPrank(alice);
        noteT.approve(address(desk), 1e6);
        vm.expectRevert(err);
        desk.sell(address(s), 1e6, 0, 0, integrator, alice);
        vm.stopPrank();
        vm.startPrank(hedger);
        coverT.approve(address(desk), 1e6);
        vm.expectRevert(err);
        desk.sellCover(address(s), 1e6, 0, 0, integrator, hedger);
        vm.stopPrank();
    }

    /// All four trades go through, each at its quote: bob buys NOTE and cover, alice sells NOTE,
    /// the hedger sells cover back.
    function _expectTradesOpen() internal {
        uint256 quoted = _quoteOf(IPerpDesk.Side.BuyNote, 10e6, 0);
        assertEq(_buy(bob, 10e6, 0), quoted);
        quoted = _quoteOf(IPerpDesk.Side.SellNote, 10e6, 0);
        assertEq(_sell(alice, 10e6, 0), quoted);
        quoted = _quoteOf(IPerpDesk.Side.BuyCover, 10e6, 0);
        assertEq(_buyCover(bob, 10e6, 0), quoted);
        quoted = _quoteOf(IPerpDesk.Side.SellCover, 10e6, 0);
        assertEq(_sellCover(hedger, 10e6, 0), quoted);
    }

    /// Clean, a day before the next fixing (far outside the pricer's 2-hour band), with the
    /// launch's pricer for the coin (discount `d0`): below the strip, 10% and 3% of the high under
    /// the crash line `k` and 1 bps under the strip, every side trades at its usual price. In the
    /// strip, from 2% of the high below `k` to 1% above, edges included, every side refuses,
    /// quotes and trades. Above it `buy` and `sellCover` trade at the NOTE ask plus the discount,
    /// `d0` 1 bps above the strip (ceil(d0 * 1,899 / 1,900)), `atK1000` at 10% above the line, 1 bps
    /// at 19.99%, 0 at 20% and beyond; `sell` and `buyCover` at their usual prices. Every trade
    /// pays its quote. At the high all four trade at their usual prices.
    function _crashLine(uint256 k, uint256 d0, uint256 atK1000) internal {
        IPerpPricer fp = desk.listing(address(s)).pricer;
        _buy(alice, 1_000e6, 0); // alice holds NOTE to sell
        _buyCover(hedger, 1_000e6, 0); // the hedger holds cover to sell back
        _later(1, 10_000);
        _expectPrices(fp, 0);
        uint256[3] memory below = [k - 1000, k - 300, k - 201];
        for (uint256 i = 0; i < 3; i++) {
            _later(1, below[i]);
            _expectPrices(fp, 0);
            _expectTradesOpen();
        }
        for (uint256 x = k - 200; x <= k + 100; x += 50) {
            _later(1, x);
            _expectNoSide(x);
        }
        _later(1, k - 200);
        _expectNoTrades(k - 200);
        _later(1, k);
        _expectNoTrades(k);
        _later(1, k + 100);
        _expectNoTrades(k + 100);
        uint256[6] memory above = [k + 101, k + 1000, k + 1999, k + 2000, k + 2001, k + 3000];
        uint256[6] memory discount = [d0, atK1000, 1, 0, 0, 0];
        for (uint256 i = 0; i < 6; i++) {
            assertEq(_discountBps(above[i], k, d0), discount[i]);
            _later(1, above[i]);
            _expectPrices(fp, discount[i]);
            _expectTradesOpen();
        }
    }

    /// Knocked in, a day before the next fixing: within 5% of the high, edges included, every side
    /// refuses with NearLine, quotes and trades; 1 bps farther out all four trade, and at the crash
    /// line `k`, its strip's edges and above the strip all four quote and trade at their usual
    /// prices (the strip and the discount are for a clean note). A fixing at the high makes the
    /// note clean, and the high is no line any more.
    function _healLine(uint256 k) internal {
        IPerpPricer fp = desk.listing(address(s)).pricer;
        _buy(alice, 1_000e6, 0);
        _buyCover(hedger, 1_000e6, 0);
        _fixing(1, 3000); // below both coins' crash lines
        assertTrue(s.state().knockedIn);
        _later(1, k - 200);
        _expectQuotes();
        _later(1, k + 100);
        _expectQuotes();
        _later(1, k + 101);
        _expectPrices(fp, 0);
        _later(1, k + 1000);
        _expectPrices(fp, 0);
        _later(1, k);
        _expectTradesOpen();
        _later(1, 9499);
        _expectTradesOpen();
        for (uint256 x = 9500; x <= 10_500; x += 250) {
            _later(1, x);
            _expectNoSide(x);
        }
        _later(1, 11_000); // above the heal band: no discount there either
        _expectPrices(fp, 0);
        _later(1, 10_501);
        _expectPrices(fp, 0);
        _expectTradesOpen();
        _later(1, 10_000);
        _expectNoTrades(10_000);
        _fixing(2, 10_000);
        assertFalse(s.state().knockedIn);
        _expectTradesOpen();
    }

    /// ETH: 300 bps of discount just above the strip, 158 at 10% above the line (300 * 1,000 /
    /// 1,900 = 157.9, rounded up).
    function test_near_the_crash_line_eth() public {
        desk.listSeries(address(s), _formulaPricer(), CAP);
        _crashLine(KI, 300, 158);
    }

    /// BTC: 450 just above the strip, 237 at 10% above the line (450 * 1,000 / 1,900 = 236.8).
    function test_near_the_crash_line_btc() public {
        _useBtcSeries();
        _crashLine(KI_BTC, 450, 237);
    }

    function test_near_the_high_when_knocked_in_eth() public {
        desk.listSeries(address(s), _formulaPricer(), CAP);
        _healLine(KI);
    }

    function test_near_the_high_when_knocked_in_btc() public {
        _useBtcSeries();
        _healLine(KI_BTC);
    }

    /// The discount at any time of day, not only in the pricer's band before a fixing: a minute
    /// after a fixing, mid-day, a second before the band, at 45% of the high (k + 500: 300 * 1,500
    /// / 1,900 = 236.8, so 237 bps). In the band (edge included) the pricer refuses first, on all
    /// four sides (Uncertified(0)), in the Desk's last 300 s too; far from the line there, the
    /// Desk's TooCloseToFixing. After the next fixing the discount is back.
    function test_the_discount_at_any_time_and_the_pricer_first_in_its_band() public {
        PerpFormulaPricer fp = _formulaPricer();
        desk.listSeries(address(s), fp, CAP);
        _fixing(1, 4500); // clean: above the line
        _expectPrices(fp, 237);
        uint40 t2 = _fixingTime(s, 2);
        vm.warp(uint256(t2) - 12 hours);
        _spot(4500);
        _expectPrices(fp, 237);
        vm.warp(uint256(t2) - 2 hours - 1);
        _spot(4500);
        _expectPrices(fp, 237);
        vm.warp(uint256(t2) - 2 hours);
        _spot(4500);
        _expectUncertified(0);
        vm.warp(uint256(t2) - MIN_SECS + 1);
        _spot(4500);
        _expectUncertified(0);
        _later(1, 7000);
        _expectTooClose(t2);
        _fixing(2, 4500);
        assertFalse(s.state().knockedIn);
        _expectPrices(fp, 237);
    }

    /// The strip at any time of day too (#67: the formula's error there was measured
    /// from 9 hours before the fixing): a minute after a fixing, mid-day, a second before the
    /// pricer's band, every side refuses with NearLine; in the band (edge included) the pricer
    /// refuses first, on all four sides (Uncertified(0)), in the Desk's last 300 s too. After the
    /// next fixing (above the line: still clean) the strip is back.
    function test_the_strip_at_any_time_and_the_pricer_first_in_its_band() public {
        desk.listSeries(address(s), _formulaPricer(), CAP);
        _fixing(1, KI + 50); // clean: above the line, in its strip
        assertFalse(s.state().knockedIn);
        _expectNoSide(KI + 50);
        uint40 t2 = _fixingTime(s, 2);
        vm.warp(uint256(t2) - 12 hours);
        _spot(KI - 150);
        _expectNoSide(KI - 150);
        vm.warp(uint256(t2) - 2 hours - 1);
        _spot(KI - 150);
        _expectNoSide(KI - 150);
        vm.warp(uint256(t2) - 2 hours);
        _spot(KI - 150);
        _expectUncertified(0);
        vm.warp(uint256(t2) - MIN_SECS + 1);
        _spot(KI + 50);
        _expectUncertified(0);
        _fixing(2, KI + 50);
        assertFalse(s.state().knockedIn);
        _expectNoSide(KI + 50);
    }

    /// The same near the high for a knocked-in BTC note: NearLine on all four sides at any time of
    /// day, the pricer's Uncertified(1) on all four sides in its band.
    function test_near_the_high_at_any_time_and_the_pricer_first_in_its_band() public {
        _useBtcSeries();
        _fixing(1, 4000); // below BTC's line
        assertTrue(s.state().knockedIn);
        uint40 t2 = _fixingTime(s, 2);
        _later(1, 9600);
        _expectNoSide(9600);
        vm.warp(uint256(t2) - 12 hours);
        _spot(9600);
        _expectNoSide(9600);
        vm.warp(uint256(t2) - 2 hours - 1);
        _spot(9600);
        _expectNoSide(9600);
        vm.warp(uint256(t2) - 2 hours);
        _spot(9600);
        _expectUncertified(1);
        vm.warp(uint256(t2) - MIN_SECS + 1);
        _spot(9600);
        _expectUncertified(1);
    }

    /// The order of the refusals, with a pricer that has no fixing band (fixingBandSecs 0), in the
    /// Desk's last 300 s: above the strip the discount refuses nothing, so all four get
    /// TooCloseToFixing (before the cap: there is no room under it); in the strip and knocked in
    /// at the high, all four get NearLine (before TooCloseToFixing).
    function test_near_line_comes_before_the_desks_band_and_the_cap() public {
        PerpFormulaPricer.Bands memory b = _bands();
        b.fixingBandSecs = 0;
        desk.listSeries(address(s), new PerpFormulaPricer(_product(), b), 0); // no room under the cap
        uint40 t1 = _fixingTime(s, 1);
        vm.warp(uint256(t1) - MIN_SECS + 1);
        _spot(KI + 500);
        _expectTooClose(t1);
        _later(1, KI);
        _expectNoSide(KI);
        _fixing(1, 3000); // knocked in
        uint40 t2 = _fixingTime(s, 2);
        vm.warp(uint256(t2) - MIN_SECS + 1);
        _spot(10_000);
        _expectNoSide(10_000);
    }

    /// LP flows, the mark and the risk view are not trades: near a line (outside the pricer's
    /// band) they go on, clean in the crash line's strip and above it at the discount (the mark
    /// has none: the mid), and knocked in near the high. Requests made there settle an hour later
    /// at the keeper's update, still near the line.
    function test_near_a_line_lp_flows_the_mark_and_risk_go_on() public {
        PerpFormulaPricer fp = _formulaPricer();
        desk.listSeries(address(s), fp, CAP);
        _buy(alice, 10_000e6, 0); // the Desk holds COVER
        _later(1, KI);
        _expectNoSide(KI);
        _lpFlowsGoOn(fp, KI);
        _expectNoSide(KI);
        _later(1, KI + 500);
        _expectPrices(fp, 237);
        _lpFlowsGoOn(fp, KI + 500);
        _expectPrices(fp, 237);
        _fixing(1, 3000); // knocked in
        _later(1, 10_000);
        _expectNoSide(10_000);
        _lpFlowsGoOn(fp, 10_000);
        _expectNoSide(10_000);
    }

    function _lpFlowsGoOn(PerpFormulaPricer fp, uint256 spotBps) internal {
        assertEq(desk.midPriceBps(address(s)), quoter.quote(s, fp, VOL, CARRY).priceBps);
        (uint256 atRisk,) = desk.risk(address(feed));
        assertGt(atRisk, 0);
        assertTrue(_markable());
        uint256 sharesBefore = desk.balanceOf(bob);
        _requestDeposit(bob, 100_000e6);
        uint256 red = _requestRedeem(lp, desk.MIN_REQUEST_SHARES());
        _later(DELAY, spotBps);
        uint256 shares = desk.previewDeposit(100_000e6);
        _settle();
        assertEq(desk.balanceOf(bob) - sharesBefore, shares);
        (,, uint256 rest) = desk.redeemRequest(red);
        assertEq(rest, 0);
        vm.prank(lp);
        assertGt(desk.claim(lp), 0);
    }

    function _lines(uint16 heal, uint16 below, uint16 above, uint16 d, uint16 reach, uint16 minBand)
        internal
        pure
        returns (LineBands memory)
    {
        return LineBands({
            healBandBps: heal,
            stripBelowBps: below,
            stripAboveBps: above,
            buyBackDiscountBps: d,
            discountReachBps: reach,
            minVolBandBps: minBand
        });
    }

    /// The lines are the listing pricer's (IPerpPricer.lineBands), whatever the pricer. The mock's
    /// default (the launch's strip, no discount, no minimum vol band) trades just above the strip
    /// at its usual prices. A strip of 0 is the line alone. A strip from 3% below to 0.5% above
    /// with a discount of 600 to 10.5% above the line: 600 just above the strip, 300 halfway, 1
    /// bps short of the reach, 0 at it. A reach inside the strip gives no discount (and divides by
    /// nothing). Relisting with the launch's pricer brings its strip and its 300 back.
    function test_the_lines_are_the_listing_pricers() public {
        _later(1, KI + 101);
        _expectPrices(pricer, 0);
        pricer.setLineBands(_lines(0, 0, 0, 0, 1, 0));
        _later(1, KI - 1);
        _expectQuotes();
        _later(1, KI);
        _expectNoSide(KI);
        _later(1, KI + 1);
        _expectQuotes();
        pricer.setLineBands(_lines(500, 300, 50, 600, 1050, 0));
        _later(1, KI - 301);
        _expectPrices(pricer, 0);
        _later(1, KI - 300);
        _expectNoSide(KI - 300);
        _later(1, KI + 50);
        _expectNoSide(KI + 50);
        uint256[5] memory x = [uint256(KI + 51), KI + 550, KI + 1049, KI + 1050, KI + 1051];
        uint256[5] memory d = [uint256(600), 300, 1, 0, 0]; // ceil(600 * (1,050 + k - x) / 1,000)
        for (uint256 i = 0; i < 5; i++) {
            _later(1, x[i]);
            _expectPrices(pricer, d[i]);
        }
        pricer.setLineBands(_lines(500, 200, 100, 500, 50, 0)); // the reach inside the strip
        _later(1, KI + 101);
        _expectPrices(pricer, 0);
        desk.listSeries(address(s), _formulaPricer(), CAP);
        _later(1, KI + 101);
        _expectPrices(desk.listing(address(s)).pricer, 300);
        _later(1, KI - 201);
        _expectPrices(desk.listing(address(s)).pricer, 0);
        _later(1, KI - 200);
        _expectNoSide(KI - 200);
    }

    /// The discount can't push the NOTE ask past a pair's value: the cover bid floors at 0. The
    /// mock's lines take any discount (PerpFormulaPricer allows at most 1,000): 9,000 just above the
    /// strip, on a NOTE quote of about 41% of notional, would ask 135%; the Desk asks 100%.
    function test_the_discount_stops_at_the_pairs_value() public {
        pricer.setLineBands(_lines(500, 200, 100, 9000, 2000, 0));
        _later(1, KI + 101);
        assertEq(_priceOf(IPerpDesk.Side.BuyNote), PAIR_BPS);
        assertEq(_priceOf(IPerpDesk.Side.SellCover), 0);
        _expectPrices(pricer, 8996); // ceil(9,000 * 1,899 / 1,900)
    }

    // --- the minimum vol band (docs/v2-spec.md §8): the pricer's, never less ---------------------------

    /// setSpread refuses a vol band below the listing pricer's minimum (VolBandTooNarrow), 0 too
    /// (what a spread never set holds), and lowering a valid one below it; it takes one at it or
    /// above. With a pricer without a minimum, 0 too. Bid and ask are checked first.
    function test_setSpread_refuses_a_vol_band_below_the_pricers_minimum() public {
        desk.setSpread(address(s), 0, 0, 0); // the mock: no minimum
        desk.listSeries(address(s), _formulaPricer(), CAP);
        bytes memory narrow = abi.encodeWithSelector(IPerpDesk.VolBandTooNarrow.selector, uint16(200));
        vm.expectRevert(narrow);
        desk.setSpread(address(s), 20, 30, 199);
        vm.expectRevert(narrow);
        desk.setSpread(address(s), 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.SpreadTooWide.selector, uint16(1001)));
        desk.setSpread(address(s), 1001, 30, 199);
        desk.setSpread(address(s), 20, 30, 200);
        assertEq(desk.spread(address(s)).volBandBps, 200);
        desk.setSpread(address(s), 20, 30, 450);
        assertEq(desk.spread(address(s)).volBandBps, 450);
        // lowering a valid band below the minimum: refused, the band stays
        vm.expectRevert(narrow);
        desk.setSpread(address(s), 20, 30, 150);
        vm.expectRevert(narrow);
        desk.setSpread(address(s), 20, 30, 0);
        assertEq(desk.spread(address(s)).volBandBps, 450);
    }

    /// The Desk lists no pricer whose buy-back discount comes without a minimum vol band (the
    /// discount is sized for one): VolBandTooNarrow(0). With a minimum of 1 it lists, and so does a
    /// pricer without a discount and without a minimum.
    function test_listSeries_refuses_a_discount_without_a_minimum_vol_band() public {
        MockPerpPricer p2 = new MockPerpPricer();
        p2.setLineBands(_lines(500, 200, 100, 300, 2000, 0));
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.VolBandTooNarrow.selector, uint16(0)));
        desk.listSeries(address(s), p2, CAP);
        assertEq(address(desk.listing(address(s)).pricer), address(pricer));
        p2.setLineBands(_lines(500, 200, 100, 300, 2000, 1));
        desk.listSeries(address(s), p2, CAP);
        assertEq(address(desk.listing(address(s)).pricer), address(p2));
        p2.setLineBands(_lines(500, 200, 100, 0, 2000, 0));
        desk.listSeries(address(s), p2, CAP);
    }

    /// A new listing whose spread was never set (vol band 0) prices at the pricer's minimum, as one
    /// whose spread is set to it does; a wider band set later is used as set. Relisting with a pricer
    /// whose minimum is above the stored band prices at that minimum. The mark has no band.
    function test_a_series_never_prices_below_the_minimum_vol_band() public {
        PerpFormulaPricer fp = _formulaPricer();
        desk.listSeries(address(s), fp, CAP);
        assertEq(desk.spread(address(s)).volBandBps, 0);
        uint256[4] memory unset;
        for (uint8 i = 0; i < 4; i++) {
            unset[i] = _priceOf(IPerpDesk.Side(i));
        }
        uint256 a = quoter.quote(s, fp, VOL - 200, CARRY).priceBps;
        uint256 c = quoter.quote(s, fp, VOL + 200, CARRY).priceBps;
        assertEq(unset[0], a > c ? a : c); // the NOTE ask: the higher of the two quotes 2 points apart
        assertEq(unset[1], a < c ? a : c);
        assertTrue(a != c);
        desk.setSpread(address(s), 0, 0, 200);
        for (uint8 i = 0; i < 4; i++) {
            assertEq(_priceOf(IPerpDesk.Side(i)), unset[i]);
        }
        desk.setSpread(address(s), 0, 0, 400);
        assertGt(_priceOf(IPerpDesk.Side.BuyNote), unset[0]);
        _expectPrices(fp, 0);
        // relisted with a pricer whose minimum is above the stored 400
        pricer.setLineBands(_lines(500, 200, 100, 0, 2000, 600));
        desk.listSeries(address(s), pricer, CAP);
        uint256 askAt600 = _priceOf(IPerpDesk.Side.BuyNote);
        _expectPrices(pricer, 0);
        assertEq(desk.spread(address(s)).volBandBps, 400);
        a = quoter.quote(s, pricer, VOL - 600, CARRY).priceBps;
        c = quoter.quote(s, pricer, VOL + 600, CARRY).priceBps;
        assertEq(askAt600, a > c ? a : c);
        assertEq(desk.midPriceBps(address(s)), quoter.quote(s, pricer, VOL, CARRY).priceBps);
    }

    /// A pricer without lineBands (a model built before #32, like today's Stylus student) is
    /// refused at listing, not later in a trade: the series keeps its pricer, and a new series
    /// isn't listed. So is one with #32's two bands only. The same pricer with the view lists.
    function test_listSeries_refuses_a_pricer_without_line_bands() public {
        IPerpPricer old = IPerpPricer(address(new MockPricerWithoutLineBands()));
        vm.expectRevert(bytes(""));
        desk.listSeries(address(s), old, CAP);
        assertEq(address(desk.listing(address(s)).pricer), address(pricer));
        IPerpPricer twoBands = IPerpPricer(address(new MockPricerWithTwoLineBands()));
        vm.expectRevert(bytes(""));
        desk.listSeries(address(s), twoBands, CAP);
        assertEq(address(desk.listing(address(s)).pricer), address(pricer));
        PerpTerms memory t = _terms(first);
        t.couponReserve = 100; // another series on the same terms
        address s2 = factory.createSeries(t);
        vm.expectRevert(bytes(""));
        desk.listSeries(s2, old, CAP);
        assertEq(address(desk.listing(s2).pricer), address(0));
        desk.listSeries(s2, pricer, CAP);
        assertTrue(desk.listing(s2).active);
    }

    /// A fresh round a second later at `tenths` tenths of a bps of INITIAL (between whole bps),
    /// and the feed's market data refreshed.
    function _laterTenths(uint256 tenths) internal {
        vm.warp(block.timestamp + 1);
        feed.pushRoundAt(int256(uint256(INITIAL) * tenths / 100_000), uint40(block.timestamp));
        _market(VOL, CARRY);
    }

    /// The spot in bps of the high is floored, as the quoter gives it to the pricer. Clean: 4,100.9
    /// (k + 100.9) floors to the strip's upper edge, every side refused; 4,101.1 to 4,101, at the
    /// full discount; 3,799.9 floors to 3,799, below the strip, and trades at the usual prices,
    /// 3,800.1 to the strip's lower edge; 5,999.9 floors to 5,999, 1 bps of discount, 6,000.9 to
    /// the reach, none. Knocked in: 10,500.9 is refused on every side, 9,499.9 trades.
    function test_near_a_line_the_spot_is_floored_to_whole_bps() public {
        PerpFormulaPricer fp = _formulaPricer();
        desk.listSeries(address(s), fp, CAP);
        _buy(alice, 1_000e6, 0);
        _buyCover(hedger, 1_000e6, 0);
        _laterTenths(41_009);
        assertEq(quoter.inputs(s, VOL, CARRY).spotBpsOfReference, 4100);
        _expectNoSide(4100);
        _expectNoTrades(4100);
        _laterTenths(41_011);
        assertEq(quoter.inputs(s, VOL, CARRY).spotBpsOfReference, 4101);
        _expectPrices(fp, 300);
        _expectTradesOpen();
        _laterTenths(37_999);
        assertEq(quoter.inputs(s, VOL, CARRY).spotBpsOfReference, 3799);
        _expectPrices(fp, 0);
        _expectTradesOpen();
        _laterTenths(38_001);
        _expectNoSide(3800);
        _laterTenths(59_999);
        assertEq(quoter.inputs(s, VOL, CARRY).spotBpsOfReference, 5999);
        _expectPrices(fp, 1);
        _laterTenths(60_009);
        assertEq(quoter.inputs(s, VOL, CARRY).spotBpsOfReference, 6000);
        _expectPrices(fp, 0);
        _fixing(1, 3000); // knocked in
        _laterTenths(105_009);
        assertEq(quoter.inputs(s, VOL, CARRY).spotBpsOfReference, 10_500);
        _expectNoSide(10_500);
        _expectNoTrades(10_500);
        _laterTenths(94_999);
        _expectTradesOpen();
    }

    /// Any spot, either state, either coin: clean, every side refuses exactly where
    /// k - 200 <= spotBps <= k + 100, and elsewhere the four prices are the usual ones with the
    /// discount ceil(D * (k + 2,000 - x) / 1,900) on `buy` and `sellCover` where
    /// k + 100 < x < k + 2,000 (D: ETH 300, BTC 450); knocked in, every side refuses exactly where
    /// |spotBps - 10,000| <= 500, and elsewhere the usual prices. Half the runs put the spot from 3%
    /// of the high below the crash line to 21% above it.
    /// forge-config: default.fuzz.runs = 256
    function testFuzz_near_a_line_is_exactly_the_rule(uint256 x, bool knockedIn, bool btc, bool nearK) public {
        uint256 k = KI;
        uint256 d0 = 300;
        if (btc) {
            _useBtcSeries();
            (k, d0) = (KI_BTC, 450);
        } else {
            desk.listSeries(address(s), _formulaPricer(), CAP);
        }
        IPerpPricer fp = desk.listing(address(s)).pricer;
        if (knockedIn) _fixing(1, 3000);
        x = nearK ? bound(x, k - 300, k + 2100) : bound(x, 2000, 12_000);
        _later(1, x);
        if (knockedIn) {
            if ((x > 10_000 ? x - 10_000 : 10_000 - x) <= 500) _expectNoSide(x);
            else _expectPrices(fp, 0);
        } else if (x + 200 >= k && x <= k + 100) {
            _expectNoSide(x);
        } else {
            _expectPrices(fp, _discountBps(x, k, d0));
        }
    }

    // --- limits and guards ---------------------------------------------------------------------------

    function test_held_series_limit() public {
        desk.setRiskBudget(address(feed), 10_000);
        uint256 max = desk.MAX_HELD_SERIES();
        usdc.mint(alice, 1_000e6);
        vm.prank(alice);
        usdc.approve(address(desk), type(uint256).max);
        for (uint256 i = 0; i <= max; i++) {
            PerpTerms memory t = _terms(first);
            t.couponReserve = uint64(100_000 + 100 * i);
            address other = factory.createSeries(t);
            desk.listSeries(other, pricer, CAP);
            if (i == max) vm.expectRevert(PerpDesk.HeldSeriesLimit.selector);
            vm.prank(alice);
            desk.buy(other, 1e6, type(uint256).max, 0, integrator, alice);
        }
        assertEq(desk.heldSeries().length, max);
    }

    function test_usdc_pause_blocks_trading_not_views() public {
        _buy(alice, 10e6, 0);
        usdc.setPaused(true);
        assertGt(desk.totalAssets(), 0);
        desk.quote(address(s), IPerpDesk.Side.SellNote, 1e6, 0);
        vm.startPrank(alice);
        noteT.approve(address(desk), 1e6);
        vm.expectRevert(MockUSDC.Paused.selector);
        desk.sell(address(s), 1e6, 0, 0, integrator, alice);
        vm.stopPrank();
    }

    function test_selling_without_tokens_reverts() public {
        _buy(alice, 10e6, 0);
        vm.startPrank(bob);
        noteT.approve(address(desk), 1e6);
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, bob, 0, 1e6));
        desk.sell(address(s), 1e6, 0, 0, integrator, bob);
        vm.stopPrank();
    }

    // --- the coupon path: a weekly series with a coupon reserve (R = 0.235) -----------------------------

    function test_coupon_series_buy_locks_the_pair_value() public {
        _useWeeklyCouponSeries();
        (uint256 quoted, uint16 priceBps,) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 100e6, 50);
        assertEq(priceBps, COUPON_NOTE_BPS);
        assertEq(quoted, 101_960_000 + 500_000); // 100 * 1.0196 + 0.5% of the notional
        assertEq(_buy(alice, 100e6, 50), quoted);
        assertEq(coverT.balanceOf(address(desk)), 100e6);
        assertEq(usdc.balanceOf(integrator), 250_000);
        assertEq(usdc.balanceOf(address(s)), 123_500_000); // 100 pairs at 1.235
        // the vault paid 123.5 for the pairs and holds COVER worth 100 * (1.235 - 1.0196)
        assertEq(desk.totalAssets(), LP_CAPITAL + quoted - 250_000 - 123_500_000 + 21_540_000);
        assertEq(desk.totalAssets(), LP_CAPITAL + 250_000);
        // and back: the pairs unwind at the same mid
        assertEq(_sell(alice, 100e6, 0), 101_960_000);
        assertEq(usdc.balanceOf(address(s)), 0);
    }

    function test_coupon_series_cover_is_the_pair_minus_note() public {
        _useWeeklyCouponSeries();
        (uint256 quoted, uint16 priceBps,) = desk.quote(address(s), IPerpDesk.Side.BuyCover, 100e6, 1000);
        assertEq(priceBps, COUPON_PAIR_BPS - COUPON_NOTE_BPS); // 2154
        assertEq(quoted, 21_540_000 + 2_154_000);
        assertEq(_buyCover(hedger, 100e6, 1000), quoted);
        assertEq(desk.totalAssets(), LP_CAPITAL + 1_077_000);
    }

    function test_coupon_series_prices_floor_at_the_reserve() public {
        _useWeeklyCouponSeries();
        desk.setSpread(address(s), 1000, 1000, 0);
        pricer.setCorrection(3000); // model says the principal is worth more than 1
        (, uint16 noteAsk,) = desk.quote(address(s), IPerpDesk.Side.BuyNote, 1e6, 0);
        (, uint16 coverBid,) = desk.quote(address(s), IPerpDesk.Side.SellCover, 1e6, 0);
        assertEq(noteAsk, COUPON_PAIR_BPS);
        assertEq(coverBid, 0);
        pricer.setCorrection(-30000); // the principal is worth nothing: NOTE = the reserve, bid floored at reserve - spread
        (, uint16 noteBid,) = desk.quote(address(s), IPerpDesk.Side.SellNote, 1e6, 0);
        (, uint16 coverAsk,) = desk.quote(address(s), IPerpDesk.Side.BuyCover, 1e6, 0);
        assertEq(noteBid, 2350 - 1000);
        assertEq(coverAsk, COUPON_PAIR_BPS - 1350);
    }

    function test_coupon_series_risk_counts_note_above_its_reserve() public {
        _useWeeklyCouponSeries();
        _buyCover(hedger, 100e6, 0); // the Desk holds 100 NOTE at 1.0196, of which 0.235 is the reserve
        (uint256 atRisk,) = desk.risk(address(feed));
        assertEq(atRisk, 101_960_000 - 23_500_000);
    }

    function test_coupon_series_unquotable_note_counts_its_reserve() public {
        _useWeeklyCouponSeries();
        _buy(alice, 100e6, 0); // 100 COVER
        _buyCover(hedger, 150e6, 0); // paired: the Desk now holds 50 NOTE
        vm.warp(block.timestamp + 27 hours); // the feed and its market data go stale
        (uint256 atRisk, uint256 limit) = desk.risk(address(feed));
        assertEq(atRisk, 50e6); // 1 USDC per unit of notional
        // its NOTE counts only its reserve as an asset
        assertEq(limit, usdc.balanceOf(address(desk)) + 50e6 * 235 / 1000);
        vm.expectRevert(); // MarketStale, checked before the feed's FeedStale
        desk.totalAssets();
    }

    function test_coupon_series_released_cash_and_close() public {
        _useWeeklyCouponSeries();
        _buy(alice, 100e6, 0); // the Desk holds 100 COVER
        uint256 before = desk.totalAssets();
        _fixing(1, 5000); // a week later, knocked in below 60%: this fixing pays COVER a * (1 - 0.5)
        uint256 released = s.claimable(address(desk));
        assertEq(released, 949_767);
        uint256 coverValue = (100e6 * s.state().notionalPerToken / RAY) * (COUPON_PAIR_BPS - _mid()) / 10_000;
        assertEq(desk.totalAssets(), before - 21_540_000 + coverValue + released);
        // the feed dies; the 2nd missed weekly fixing (14 days later) closes the series at the last good fixing, x = 0.5
        vm.warp(uint256(_fixingTime(s, 3)) + FALLBACK);
        assertEq(uint8(s.state().phase), uint8(PerpPhase.Closed));
        released = s.claimable(address(desk));
        assertApproxEqAbs(released, 50_000_000, 10); // COVER: 1 - x per unit of notional
        assertEq(desk.totalAssets(), usdc.balanceOf(address(desk)) + released);
        assertEq(desk.collect(address(s)), released);
        assertEq(desk.heldSeries().length, 0);
        // alice's NOTE: x + R per unit of notional
        assertApproxEqAbs(s.claimable(alice), 73_500_000, 10);
    }

    // --- fuzz ---------------------------------------------------------------------------------------------

    /// Buying and selling straight back costs the trader the spread and the rounding, never the LPs.
    function testFuzz_round_trip_never_costs_lps(uint256 amount, uint16 bid, uint16 ask, uint256 fixings, bool cover)
        public
    {
        fixings = bound(fixings, 0, 3);
        for (uint256 n = 1; n <= fixings; n++) {
            _fixing(n, 9000);
        }
        _roundTrip(amount, bid, ask, cover);
    }

    /// The same on the weekly series with a coupon reserve.
    function testFuzz_round_trip_never_costs_lps_with_a_coupon(uint256 amount, uint16 bid, uint16 ask, bool cover)
        public
    {
        _useWeeklyCouponSeries();
        _fixing(1, 9000);
        _roundTrip(amount, bid, ask, cover);
    }

    function _roundTrip(uint256 amount, uint16 bid, uint16 ask, bool cover) internal {
        amount = bound(amount, 1, 50_000e6);
        desk.setSpread(address(s), uint16(bound(bid, 0, 1000)), uint16(bound(ask, 0, 1000)), 0);
        uint256 before = desk.totalAssets();
        uint256 cost = cover ? _buyCover(alice, amount, 0) : _buy(alice, amount, 0);
        uint256 proceeds = cover ? _sellCover(alice, amount, 0) : _sell(alice, amount, 0);
        assertLe(proceeds, cost);
        assertGe(desk.totalAssets(), before);
        assertEq(noteT.balanceOf(address(desk)), 0);
        assertEq(coverT.balanceOf(address(desk)), 0);
    }

    /// Minting a pair to sell both legs, or buying both legs to redeem the pair, never pays.
    function testFuzz_no_pair_arbitrage(uint256 amount, uint16 bid, uint16 ask, uint16 band, int16 correction) public {
        _noPairArbitrage(amount, bid, ask, band, correction);
    }

    /// The same on the weekly series with a coupon reserve.
    function testFuzz_no_pair_arbitrage_with_a_coupon(
        uint256 amount,
        uint16 bid,
        uint16 ask,
        uint16 band,
        int16 correction
    ) public {
        _useWeeklyCouponSeries();
        _noPairArbitrage(amount, bid, ask, band, correction);
    }

    function _noPairArbitrage(uint256 amount, uint16 bid, uint16 ask, uint16 band, int16 correction) internal {
        amount = bound(amount, 1e6, 10_000e6);
        pricer.setCorrection(int16(bound(correction, -3000, 3000)));
        desk.setSpread(
            address(s), uint16(bound(bid, 0, 1000)), uint16(bound(ask, 0, 1000)), uint16(bound(band, 0, 1500))
        );
        desk.listSeries(address(s), pricer, type(uint128).max);

        // mint and sell both legs
        uint256 pairCost = _mintPairs(s, alice, amount);
        uint256 got = _sell(alice, amount, 0) + _sellCover(alice, amount, 0);
        assertLe(got, pairCost);
        // buy both legs and redeem
        uint256 paid = _buy(bob, amount, 0) + _buyCover(bob, amount, 0);
        vm.prank(bob);
        uint256 redeemed = s.redeemPair(amount, bob);
        assertGe(paid, redeemed);
    }
}
