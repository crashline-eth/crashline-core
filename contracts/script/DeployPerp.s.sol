// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PerpFactory} from "../src/PerpFactory.sol";
import {PerpQuoter} from "../src/PerpQuoter.sol";
import {PerpDesk} from "../src/PerpDesk.sol";
import {PerpFormulaPricer} from "../src/PerpFormulaPricer.sol";
import {IPerpFactory} from "../src/interfaces/IPerpFactory.sol";
import {IPerpDesk} from "../src/interfaces/IPerpDesk.sol";
import {PerpProduct} from "../src/interfaces/IPerpPricer.sol";

/// Arbitrum deployment of the v2 perpetual note on the launch terms
/// (docs/v2-spec.md §1): the perpetual factory (with its series and token
/// implementations), the quoter, the Desk on Circle's native USDC (it stops
/// trading a series 300 s before its fixing), and one formula-only pricer per
/// asset: ETH (crash line 40% of the high, vol 24-150%) and BTC (50%, vol
/// 21-120%), both for daily fixings, a release rate of 1/yr and a carry of
/// -20% to +50% a year (each constructor proves the closed form at the four
/// corners of its vol and carry ranges). USDC is pinned
/// per chain (Arbitrum One 42161, Arbitrum Sepolia 421614), never the bridged
/// USDC.e, which also calls itself "USDC"; on any other chain pass USDC. The
/// factory deploys one FixingsRecorder per feed with the limits below; on
/// Arbitrum One it and the quoter check Chainlink's L2 sequencer uptime feed
/// (Arbitrum Sepolia has none; elsewhere pass SEQUENCER). The feeds to list
/// (BTC/USD, not WBTC/USD: the note pays on BTC's dollar price, and a wBTC
/// depeg must not read as a crash) are logged and recorded; on a chain without
/// known feeds pass ETH_USD and BTC_USD (the dev environment's own feeds,
/// for example). USDC, SEQUENCER, ETH_USD and BTC_USD only fill in
/// what the chain has no known address for: where it has one, setting the env var
/// to another address reverts (forge loads contracts/.env by itself, and a stray
/// value there must not rewire a real deployment).
///
///   forge script script/DeployPerp.s.sol --rpc-url https://sepolia-rollup.arbitrum.io/rpc           # simulate
///   DEPLOYER_KEY=0x… forge script script/DeployPerp.s.sol --rpc-url … --broadcast                 # deploy
///
/// The Desk starts with the launch's limits on market data (marketLimits(): stale
/// 3 hours after its source's time; a keeper write moves vol by at most 500 bps
/// and carry by at most 300 bps, at least 10 minutes after the feed's previous
/// write on the chain's clock, `writtenAt`) and
/// the market keeper KEEPER (an address; none if unset, and the curator sets
/// one later with `desk.setKeeper`).
///
/// With --broadcast the addresses go to deployments/<chainid>-perp.json.
/// The curator (the Desk's owner) then writes each feed's first market data,
/// `desk.setMarkets([(feed, volBps, carryBps, sourceTime, source), ...])`: until
/// a feed has it, nothing on that feed is quoted (NoMarketData), and the keeper
/// can't write it. From then on the keeper keeps it fresh: older than 3 hours,
/// it stops the feed's quotes (MarketStale). The keeper's `setMarkets` is also
/// what settles LP requests (`requestDeposit` / `requestRedeem`, due an hour
/// after they are made; the ERC-4626 entry points revert AsyncOnly), so the
/// Desk's first LP capital arrives with the keeper's first update an hour
/// after the first deposit request. The curator creates the series
/// (feed, a day's 08:00 UTC as firstFixing, FIXING_INTERVAL, the asset's crash
/// line, MELT_SHARE, couponReserve 0), lists each with its asset's pricer and a
/// cap, and must call `desk.setRiskBudget(feed, bps)`: until a feed has a
/// budget, no trade may add to the Desk's positions on it.
contract DeployPerp is Script {
    /// Circle's native USDC ("USD Coin", 6 decimals), checked on chain on 2026-10-20.
    address constant USDC_ARBITRUM_ONE = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address constant USDC_ARBITRUM_SEPOLIA = 0x75faf114eafb1BDbe2F0316DF893fd58CE46AA4d;
    /// Chainlink's L2 sequencer uptime feed on Arbitrum One (checked on chain on 2026-10-20).
    address constant SEQUENCER_ARBITRUM_ONE = 0xFdB631F5EE196F0ed6FAa767959853A9F217697D;
    /// Chainlink ETH/USD and BTC/USD, 8 decimals. Arbitrum One: heartbeat 1,755 s,
    /// deviation 0.05% (Chainlink's directory; rounds every ~1.5-3 min on 2026-10-20).
    /// Arbitrum Sepolia: heartbeat 120 s.
    address constant ETH_USD_ARBITRUM_ONE = 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612;
    address constant BTC_USD_ARBITRUM_ONE = 0x6ce185860a4963106506C203335A2910413708e9;
    address constant ETH_USD_ARBITRUM_SEPOLIA = 0xd30e2101a97dcbAeBCBC04F14C3f624E67A35165;
    address constant BTC_USD_ARBITRUM_SEPOLIA = 0x56a43EB56Da12C0dc1D972ACb089c06a5dEF8e69;

    /// About two heartbeats: a feed silent this long is stopped, not calm.
    uint40 constant MAX_FEED_STALENESS = 1 hours;
    /// Recorder limits for 24/7 feeds. A fixing's round is the last one at or before its
    /// time and at most an hour old (on either feed no 08:00 UTC fixing from 2024-01 to
    /// 2026-10 would have been missed: the oldest 08:00 round was 53 minutes old); a round
    /// after the time is never a fixing. A fixing still unrecorded the series'
    /// FALLBACK_GRACE (6 hours) after its time reuses the last one, and missed fixings in a
    /// row that span the series' CLOSE_AFTER_DEAD (14 days: missedInARow * fixingInterval >=
    /// 14 days) close it (at daily fixings the 14th, 13 days and 6 hours after the first
    /// missed fixing's time; docs/v2-spec.md §4).
    uint40 constant MAX_FIX_AGE = 1 hours;
    /// $10M at 8 decimals: ~120 x BTC today, a sanity bound against a mis-scaled answer.
    int256 constant PRICE_MAX = 1e15;
    /// Chainlink's recommendation: no price for an hour after the sequencer is back.
    uint40 constant SEQUENCER_GRACE = 1 hours;

    /// The launch terms (docs/v2-spec.md §1). Daily fixings, at 08:00 UTC (each series'
    /// firstFixing is a day's 08:00 UTC).
    uint32 public constant FIXING_INTERVAL = 1 days;
    /// 1 - e^(-1/365), rounded: a release rate of 1/yr at daily fixings, 0.27% a day.
    uint64 public constant MELT_SHARE = 2_735_976_403_140_715;
    /// The crash lines, bps of the high: ETH a 60% fall, BTC a 50% fall.
    uint16 public constant KI_ETH = 4000;
    uint16 public constant KI_BTC = 5000;
    /// Discount 0: the pot is plain USDC.
    int16 public constant DISCOUNT_BPS = 0;
    /// The pricers' vol ranges. The minimums were raised from 2,000 for the carry corner
    /// (#14, spec §1 and §6): at vol 20% and carry +50% the closed form refuses
    /// (|beta-| > 25), and ETH just above 20% is carried only to ~3e-5 bps. From 24% (ETH) and
    /// 21% (BTC) every vol and carry of the ranges is within 1e-7 bps of a 50-digit reference
    /// (tools/perp_formula.py --check-launch).
    uint16 public constant VOL_MIN_ETH_BPS = 2400;
    uint16 public constant VOL_MIN_BTC_BPS = 2100;
    uint16 public constant VOL_MAX_ETH_BPS = 15_000;
    uint16 public constant VOL_MAX_BTC_BPS = 12_000;
    /// Both pricers' carry range, bps a year: the log basis of the options market's ~1-year future.
    int16 public constant CARRY_MIN_BPS = -2000;
    int16 public constant CARRY_MAX_BPS = 5000;
    /// The Desk's buy-back discount just above the crash line's strip, falling to 0 at 20% of the
    /// high above the line, and the smallest vol band it prices with, 2 points: the discount is
    /// sized for it (#66, spec §6 "Buy-back discount"). ETH 3%, BTC 4.5% of live
    /// notional.
    uint16 public constant BUY_BACK_DISCOUNT_ETH_BPS = 300;
    uint16 public constant BUY_BACK_DISCOUNT_BTC_BPS = 450;
    uint16 public constant DISCOUNT_REACH_BPS = 2000;
    uint16 public constant MIN_VOL_BAND_BPS = 200;
    /// The Desk trades a series until 5 minutes before its fixing. Near a line the
    /// pricers already refuse from 2 hours before (their fixing band, below): those
    /// quotes fail with Uncertified, and LP flows wait while the Desk holds such a series.
    uint32 constant MIN_SECS_TO_FIXING = 300;
    /// Market data (docs/v2-spec.md §8): stale 3 hours after its source's time (the keeper's
    /// job writes every hour, and sooner when vol moves by 2 points); a keeper write moves vol by
    /// at most 5 points and carry by at most 3 points a year, at least 10 minutes after the
    /// feed's previous write on the chain's clock (`writtenAt`, which the owner's writes set
    /// too): 30 vol points an hour at most (#1). The owner's writes are not
    /// bounded.
    uint32 constant MAX_MARKET_AGE = 3 hours;
    uint16 constant MAX_VOL_STEP_BPS = 500;
    uint16 constant MAX_CARRY_STEP_BPS = 300;
    uint32 constant MIN_UPDATE_GAP = 10 minutes;

    /// A launch pricer's product: what its quotes are pinned to (vol and carry are inputs).
    function product(uint16 kiBarrierBps) public pure returns (PerpProduct memory) {
        return PerpProduct({
            kiBarrierBps: kiBarrierBps,
            meltShare: MELT_SHARE,
            fixingInterval: FIXING_INTERVAL,
            discountBps: DISCOUNT_BPS
        });
    }

    function ethProduct() public pure returns (PerpProduct memory) {
        return product(KI_ETH);
    }

    function btcProduct() public pure returns (PerpProduct memory) {
        return product(KI_BTC);
    }

    /// Where a launch pricer answers: everywhere in its vol and carry ranges, except in the
    /// last 2 hours before a fixing for a clean note from 2% of the high below the crash line to
    /// 10% above it, or a knocked-in note within 5% of the high (edges included). The Desk's
    /// lines at any time (lineBands): the high's band, where it doesn't trade a knocked-in note;
    /// the crash line's strip, from 2% of the high below the line to 1% above, where it doesn't
    /// trade a clean note at all (#67: the widest error measured just below the
    /// line before a fixing reached 1.35% below and 0.50% above); above the strip, up to 20% above
    /// the line, `buy` and `sellCover` at the buy-back discount; and a vol band of at least 2
    /// points (#66: with it, below the strip every side is safe, in every measured world).
    function bands(uint16 volMinBps, uint16 volMaxBps, uint16 buyBackDiscountBps)
        public
        pure
        returns (PerpFormulaPricer.Bands memory)
    {
        return PerpFormulaPricer.Bands({
            fixingBandSecs: 2 hours,
            knockInBelowBps: 200,
            knockInAboveBps: 1000,
            healBandBps: 500,
            stripBelowBps: 200,
            stripAboveBps: 100,
            buyBackDiscountBps: buyBackDiscountBps,
            discountReachBps: DISCOUNT_REACH_BPS,
            minVolBandBps: MIN_VOL_BAND_BPS,
            volMinBps: volMinBps,
            volMaxBps: volMaxBps,
            carryMinBps: CARRY_MIN_BPS,
            carryMaxBps: CARRY_MAX_BPS
        });
    }

    function ethBands() public pure returns (PerpFormulaPricer.Bands memory) {
        return bands(VOL_MIN_ETH_BPS, VOL_MAX_ETH_BPS, BUY_BACK_DISCOUNT_ETH_BPS);
    }

    function btcBands() public pure returns (PerpFormulaPricer.Bands memory) {
        return bands(VOL_MIN_BTC_BPS, VOL_MAX_BTC_BPS, BUY_BACK_DISCOUNT_BTC_BPS);
    }

    function minSecsToFixing() public pure returns (uint32) {
        return MIN_SECS_TO_FIXING;
    }

    function marketLimits() public pure returns (IPerpDesk.MarketLimits memory) {
        return IPerpDesk.MarketLimits({
            maxMarketAge: MAX_MARKET_AGE,
            maxVolStepBps: MAX_VOL_STEP_BPS,
            maxCarryStepBps: MAX_CARRY_STEP_BPS,
            minUpdateGap: MIN_UPDATE_GAP
        });
    }

    function usdcOf(uint256 chainId) public pure returns (address) {
        if (chainId == 42_161) return USDC_ARBITRUM_ONE;
        if (chainId == 421_614) return USDC_ARBITRUM_SEPOLIA;
        return address(0);
    }

    function sequencerOf(uint256 chainId) public pure returns (address) {
        return chainId == 42_161 ? SEQUENCER_ARBITRUM_ONE : address(0);
    }

    function feedsOf(uint256 chainId) public pure returns (address ethUsd, address btcUsd) {
        if (chainId == 42_161) return (ETH_USD_ARBITRUM_ONE, BTC_USD_ARBITRUM_ONE);
        if (chainId == 421_614) return (ETH_USD_ARBITRUM_SEPOLIA, BTC_USD_ARBITRUM_SEPOLIA);
        return (address(0), address(0));
    }

    /// The address a run uses for `name`: the chain's own (`known`) where it has one, else the
    /// env var's (`fromEnv`, 0 if unset). Where the chain has one, the env var may only repeat it.
    function choose(string memory name, address known, address fromEnv) public pure returns (address) {
        if (known == address(0)) return fromEnv;
        require(
            fromEnv == known,
            string.concat(name, " names another address than this chain's ", vm.toString(known), ": unset ", name)
        );
        return known;
    }

    function _fromEnv(string memory name, address known) internal view returns (address) {
        return choose(name, known, vm.envOr(name, known));
    }

    /// The USDC this run uses: the chain's native USDC (usdcOf), or USDC on another chain.
    function usdc() public view returns (address) {
        return _fromEnv("USDC", usdcOf(block.chainid));
    }

    /// The L2 sequencer uptime feed this run uses: the chain's (sequencerOf), or SEQUENCER.
    function sequencer() public view returns (address) {
        return _fromEnv("SEQUENCER", sequencerOf(block.chainid));
    }

    /// The feeds this run logs and records: the chain's (feedsOf), or ETH_USD and BTC_USD.
    function feeds() public view returns (address ethUsd, address btcUsd) {
        (ethUsd, btcUsd) = feedsOf(block.chainid);
        ethUsd = _fromEnv("ETH_USD", ethUsd);
        btcUsd = _fromEnv("BTC_USD", btcUsd);
    }

    function recorderLimits(address sequencer) public pure returns (IPerpFactory.RecorderLimits memory) {
        return IPerpFactory.RecorderLimits({
            maxFixAge: MAX_FIX_AGE, priceMax: PRICE_MAX, sequencer: sequencer, sequencerGrace: SEQUENCER_GRACE
        });
    }

    /// Everything the run deploys or reads, kept in one struct (the stack is too small otherwise).
    struct Deployment {
        address usdc;
        address sequencer;
        address ethUsd;
        address btcUsd;
        address deployer;
        address curator;
        address keeper;
        PerpFactory factory;
        PerpQuoter quoter;
        PerpDesk desk;
        PerpFormulaPricer pricerEth;
        PerpFormulaPricer pricerBtc;
    }

    function run() external {
        Deployment memory d;
        d.usdc = usdc();
        require(d.usdc != address(0), "no native USDC known for this chain: pass USDC");
        d.sequencer = sequencer();
        require(block.chainid != 42_161 || d.sequencer != address(0), "Arbitrum One needs the sequencer uptime feed");
        (d.ethUsd, d.btcUsd) = feeds();
        uint256 key = vm.envOr("DEPLOYER_KEY", uint256(0));
        d.deployer = key != 0 ? vm.addr(key) : msg.sender;
        d.curator = vm.envOr("CURATOR", d.deployer);
        d.keeper = vm.envOr("KEEPER", address(0));

        if (key != 0) vm.startBroadcast(key);
        else vm.startBroadcast();
        d.factory = new PerpFactory(d.usdc, recorderLimits(d.sequencer));
        d.quoter = new PerpQuoter(MAX_FEED_STALENESS, d.sequencer, SEQUENCER_GRACE);
        d.desk =
            new PerpDesk(IERC20(d.usdc), d.factory, d.quoter, d.curator, MIN_SECS_TO_FIXING, marketLimits(), d.keeper);
        d.pricerEth = new PerpFormulaPricer(ethProduct(), ethBands());
        d.pricerBtc = new PerpFormulaPricer(btcProduct(), btcBands());
        vm.stopBroadcast();

        _log(d);
        if (vm.isContext(VmSafe.ForgeContext.ScriptBroadcast)) _write(d);
    }

    function _log(Deployment memory d) internal view {
        console2.log("chain id              ", block.chainid);
        console2.log("deployer              ", d.deployer);
        console2.log("curator (owner)       ", d.curator);
        console2.log("USDC                  ", d.usdc);
        console2.log("sequencer uptime      ", d.sequencer);
        console2.log("ETH/USD feed          ", d.ethUsd);
        console2.log("BTC/USD feed          ", d.btcUsd);
        console2.log("PerpFactory           ", address(d.factory));
        console2.log("  series impl         ", d.factory.seriesImplementation());
        console2.log("  token impl          ", d.factory.tokenImplementation());
        console2.log("PerpQuoter            ", address(d.quoter));
        console2.log("PerpDesk              ", address(d.desk));
        console2.log("  minSecsToFixing     ", d.desk.minSecsToFixing());
        console2.log("  market keeper       ", d.desk.keeper());
        console2.log("  maxMarketAge        ", d.desk.maxMarketAge());
        console2.log("  maxVolStepBps       ", d.desk.maxVolStepBps());
        console2.log("  maxCarryStepBps     ", d.desk.maxCarryStepBps());
        console2.log("  minUpdateGap        ", d.desk.minUpdateGap());
        console2.log("PerpFormulaPricer ETH ", address(d.pricerEth));
        console2.logBytes32(d.pricerEth.weightsHash());
        console2.log("PerpFormulaPricer BTC ", address(d.pricerBtc));
        console2.logBytes32(d.pricerBtc.weightsHash());
    }

    function _write(Deployment memory d) internal {
        string memory o = "deployment";
        vm.serializeUint(o, "chainId", block.chainid);
        vm.serializeAddress(o, "usdc", d.usdc);
        vm.serializeAddress(o, "sequencerUptimeFeed", d.sequencer);
        vm.serializeAddress(o, "ethUsdFeed", d.ethUsd);
        vm.serializeAddress(o, "btcUsdFeed", d.btcUsd);
        vm.serializeAddress(o, "perpFactory", address(d.factory));
        vm.serializeAddress(o, "perpSeriesImplementation", d.factory.seriesImplementation());
        vm.serializeAddress(o, "perpTokenImplementation", d.factory.tokenImplementation());
        vm.serializeAddress(o, "perpQuoter", address(d.quoter));
        vm.serializeAddress(o, "perpDesk", address(d.desk));
        vm.serializeAddress(o, "perpFormulaPricerEth", address(d.pricerEth));
        vm.serializeAddress(o, "perpFormulaPricerBtc", address(d.pricerBtc));
        vm.serializeAddress(o, "marketKeeper", d.keeper);
        string memory out = vm.serializeAddress(o, "curator", d.curator);
        vm.writeJson(out, string.concat(vm.projectRoot(), "/../deployments/", vm.toString(block.chainid), "-perp.json"));
    }
}
