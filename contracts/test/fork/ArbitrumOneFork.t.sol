// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {PerpFactory} from "../../src/PerpFactory.sol";
import {PerpSeries} from "../../src/PerpSeries.sol";
import {PerpQuoter} from "../../src/PerpQuoter.sol";
import {PerpFormulaPricer} from "../../src/PerpFormulaPricer.sol";
import {FixingsRecorder} from "../../src/FixingsRecorder.sol";
import {IAggregatorV3} from "../../src/interfaces/IAggregatorV3.sol";
import {IFixingsRecorder} from "../../src/interfaces/IFixingsRecorder.sol";
import {PerpTerms, PerpPhase} from "../../src/interfaces/IPerpSeries.sol";
import {PerpQuote} from "../../src/interfaces/IPerpQuoter.sol";
import {DeployPerp} from "../../script/DeployPerp.s.sol";

/// The launch setup against the real Arbitrum One: native USDC, Chainlink
/// ETH/USD and BTC/USD, the L2 sequencer uptime feed, DeployPerp's limits and
/// launch pricers. A series on the launch terms struck at the feed's latest
/// round is recorded and quoted at its high, and the last 08:00 UTC fixing of
/// each feed is recorded as the fixing keeper finds it.
/// Skipped unless ARBITRUM_ONE_RPC is set:
///   ARBITRUM_ONE_RPC=https://arb1.arbitrum.io/rpc forge test --match-path test/fork/ArbitrumOneFork.t.sol
contract ArbitrumOneForkTest is Test {
    DeployPerp internal cfg;
    PerpFactory internal factory;
    PerpQuoter internal quoter;
    PerpFormulaPricer internal pricerEth;
    PerpFormulaPricer internal pricerBtc;

    function setUp() public {
        string memory rpc = vm.envOr("ARBITRUM_ONE_RPC", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 42_161);
        cfg = new DeployPerp();
        address sequencer = cfg.sequencerOf(block.chainid);
        factory = new PerpFactory(cfg.usdcOf(block.chainid), cfg.recorderLimits(sequencer));
        quoter = new PerpQuoter(1 hours, sequencer, 1 hours);
        pricerEth = new PerpFormulaPricer(cfg.ethProduct(), cfg.ethBands());
        pricerBtc = new PerpFormulaPricer(cfg.btcProduct(), cfg.btcBands());
    }

    function test_native_usdc_and_the_sequencer_is_up() public view {
        IERC20Metadata usdc = IERC20Metadata(factory.collateral());
        assertEq(usdc.symbol(), "USDC");
        assertEq(usdc.name(), "USD Coin"); // the bridged USDC.e is "USD Coin (Arb1)"
        assertEq(usdc.decimals(), 6);
        // forge-lint: disable-next-line(unused-return)
        (, int256 status, uint256 since,,) = IAggregatorV3(cfg.sequencerOf(block.chainid)).latestRoundData();
        assertEq(status, 0);
        assertLt(since + 1 hours, block.timestamp);
    }

    /// BTC at 45% vol and carry 4%, at its high: the closed form's 8,841 bps (docs/v2-spec.md §1: about 8,840).
    function test_btc_usd_records_and_quotes() public {
        (, address btcUsd) = cfg.feedsOf(block.chainid);
        _strikeAndQuote(btcUsd, "BTC / USD", cfg.KI_BTC(), pricerBtc, 4500, 8841);
    }

    /// ETH at 70% vol and carry 4%, at its high: 7,904 bps (about 7,900).
    function test_eth_usd_records_and_quotes() public {
        (address ethUsd,) = cfg.feedsOf(block.chainid);
        _strikeAndQuote(ethUsd, "ETH / USD", cfg.KI_ETH(), pricerEth, 7000, 7904);
    }

    /// ETH/USD's aggregator upgrade (#25). Phase 2 ran from 2026-03-19 next to
    /// phase 1, whose last round is 2026-04-10. Round 0 of a phase answers zeros.
    function test_eth_usd_phase_change() public {
        (address ethUsd,) = cfg.feedsOf(block.chainid);
        IAggregatorV3 f = IAggregatorV3(ethUsd);
        FixingsRecorder r = FixingsRecorder(factory.deployRecorder(ethUsd));
        uint80 p1Last = uint80(1) << 64 | 1_205_398;
        uint80 p2First = uint80(2) << 64 | 1;
        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 lastAt,) = f.getRoundData(p1Last);
        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 firstAt,) = f.getRoundData(p2First);
        assertEq(lastAt, 1_775_846_264);
        assertEq(firstAt, 1_773_938_236);
        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 nextAt,) = f.getRoundData(p1Last + 1);
        assertEq(nextAt, 0); // zeros, not a revert
        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 prevAt,) = f.getRoundData(p2First - 1);
        assertEq(prevAt, 0);

        // the bug: phase 2's first round as the fixing for a time before it, though phase 1 has a
        // round 30 s before that time. A round after the time is never a fixing.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 before = uint40(firstAt) - 1;
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, p2First, before));
        r.recordFixing(before, p2First);
        // phase 1's last round has no next round in its phase: refused
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 atLast = uint40(lastAt) + 1;
        vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.NotLastRoundBefore.selector, p1Last, atLast));
        r.recordFixing(atLast, p1Last);
        // in the overlap, a fixing records from either phase as a normal fixing
        r.recordFixing(atLast - 31, p1Last - 1); // the round 30 s before phase 1's last
        r.recordFixing(before, uint80(1) << 64 | _p1RoundAt(f, before));
    }

    /// The fixing keeper's job on the real feeds (docs/v2-spec.md §10): the last 08:00 UTC at or
    /// before the latest round, its round found by bisection in the current phase. The round after
    /// it is after the time and the round before it is not the last one; the round found records.
    function test_eth_usd_records_the_last_0800_fixing() public {
        (address ethUsd,) = cfg.feedsOf(block.chainid);
        _recordLast0800(ethUsd);
    }

    function test_btc_usd_records_the_last_0800_fixing() public {
        (, address btcUsd) = cfg.feedsOf(block.chainid);
        _recordLast0800(btcUsd);
    }

    function _recordLast0800(address feed) internal {
        IAggregatorV3 f = IAggregatorV3(feed);
        FixingsRecorder r = FixingsRecorder(factory.deployRecorder(feed));
        // forge-lint: disable-next-line(unused-return)
        (uint80 latest,,, uint256 latestAt,) = f.latestRoundData();
        // forge-lint: disable-next-line(unsafe-typecast)
        uint40 t = uint40(latestAt - (latestAt + 16 hours) % 1 days); // 08:00 UTC is 16 hours before 00:00
        assertEq(t % 1 days, 8 hours);
        uint80 phase = latest >> 64 << 64;
        uint64 lo = 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        uint64 hi = uint64(latest);
        while (lo < hi) {
            uint64 mid = (lo + hi + 1) / 2;
            // forge-lint: disable-next-line(unused-return)
            (,,, uint256 at,) = f.getRoundData(phase | mid);
            if (at <= t) lo = mid;
            else hi = mid - 1;
        }
        uint80 round = phase | lo;
        // forge-lint: disable-next-line(unused-return)
        (,,, uint256 roundAt,) = f.getRoundData(round);
        assertLe(roundAt, t);
        assertLe(t - roundAt, r.MAX_FIX_AGE()); // rounds every few minutes: well inside the hour
        if (block.timestamp <= t) vm.warp(uint256(t) + 1);
        if (round != latest) {
            vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.RoundAfterObservation.selector, round + 1, t));
            r.recordFixing(t, round + 1);
        }
        if (lo > 1) {
            // forge-lint: disable-next-line(unused-return)
            (,,, uint256 prevAt,) = f.getRoundData(round - 1);
            // forge-lint: disable-next-line(unsafe-typecast)
            if (t - prevAt > r.MAX_FIX_AGE()) {
                vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.FixingTooStale.selector, uint40(prevAt), t));
            } else {
                vm.expectRevert(abi.encodeWithSelector(IFixingsRecorder.NotLastRoundBefore.selector, round - 1, t));
            }
            r.recordFixing(t, round - 1);
        }
        r.recordFixing(t, round);
        IFixingsRecorder.Fixing memory fx = r.fixingOf(t);
        assertEq(fx.roundId, round);
        assertEq(fx.timestamp, roundAt);
        assertGt(fx.price, 0);
    }

    /// Phase 1's last round at or before t, by bisection over its rounds.
    function _p1RoundAt(IAggregatorV3 f, uint256 t) internal view returns (uint64 lo) {
        lo = 1;
        uint64 hi = 1_205_398;
        while (lo < hi) {
            uint64 mid = (lo + hi + 1) / 2;
            // forge-lint: disable-next-line(unused-return)
            (,,, uint256 at,) = f.getRoundData(uint80(1) << 64 | mid);
            if (at <= t) lo = mid;
            else hi = mid - 1;
        }
    }

    function _strikeAndQuote(
        address feed,
        string memory description,
        uint16 kiBarrierBps,
        PerpFormulaPricer pricer,
        uint16 vol,
        uint256 formulaBps
    ) internal {
        IAggregatorV3 f = IAggregatorV3(feed);
        assertEq(f.description(), description);
        // forge-lint: disable-next-line(unused-return)
        (uint80 round, int256 price,, uint256 updatedAt,) = f.latestRoundData();
        PerpTerms memory t = PerpTerms({
            feed: feed,
            // forge-lint: disable-next-line(unsafe-typecast)
            firstFixing: uint40(updatedAt), // struck at the latest round
            fixingInterval: cfg.FIXING_INTERVAL(),
            kiBarrierBps: kiBarrierBps,
            meltShare: cfg.MELT_SHARE(),
            couponReserve: 0
        });
        PerpSeries s = PerpSeries(factory.createSeries(t));
        FixingsRecorder r = FixingsRecorder(address(s.recorder()));
        if (block.timestamp == updatedAt) vm.warp(block.timestamp + 1); // a fixing time must be in the past
        r.recordFixing(t.firstFixing, round);
        assertEq(uint8(s.state().phase), uint8(PerpPhase.Live));
        // forge-lint: disable-next-line(unsafe-typecast)
        assertEq(s.state().referenceFixing, uint96(uint256(price)));
        // at the high: the closed form, and an accrual of under a bps this early in the day
        PerpQuote memory q = quoter.quote(s, pricer, vol, 400); // carry 4%, the reference points' (§1)
        assertEq(q.formulaBps, formulaBps);
        assertEq(q.couponBps, 0);
        assertApproxEqAbs(q.priceBps, formulaBps, 1);
    }
}
