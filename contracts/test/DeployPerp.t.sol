// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {VmSafe} from "forge-std/Vm.sol";
import {PerpBase} from "./PerpBase.t.sol";
import {PerpDesk} from "../src/PerpDesk.sol";
import {PerpSeries} from "../src/PerpSeries.sol";
import {PerpFormulaPricer} from "../src/PerpFormulaPricer.sol";
import {IPerpFactory} from "../src/interfaces/IPerpFactory.sol";
import {IPerpDesk} from "../src/interfaces/IPerpDesk.sol";
import {LineBands, PerpProduct} from "../src/interfaces/IPerpPricer.sol";
import {DeployPerp} from "../script/DeployPerp.s.sol";

/// DeployPerp.s.sol deploys the launch terms of docs/v2-spec.md §1, which are also the
/// tests' fixtures (PerpBase), and its run wires them up.
contract DeployPerpTest is PerpBase {
    DeployPerp internal cfg;

    function setUp() public override {
        super.setUp();
        cfg = new DeployPerp();
    }

    function test_the_launch_terms() public view {
        assertEq(cfg.FIXING_INTERVAL(), 86_400);
        assertEq(cfg.MELT_SHARE(), 2_735_976_403_140_715);
        assertEq(cfg.KI_ETH(), 4000);
        assertEq(cfg.KI_BTC(), 5000);
        assertEq(cfg.minSecsToFixing(), 300);
        // the pricers: daily, release 1/yr, discount 0; the carry is an input
        PerpProduct memory p = cfg.ethProduct();
        assertEq(p.kiBarrierBps, 4000);
        assertEq(p.meltShare, 2_735_976_403_140_715);
        assertEq(p.fixingInterval, 86_400);
        assertEq(p.discountBps, 0);
        assertEq(cfg.btcProduct().kiBarrierBps, 5000);
        // bands: 2 hours, the crash line -2% / +10%, the high +-5%, the strip from 2% below the crash
        // line to 1% above, the buy-back discount (ETH 3%, BTC 4.5%) to 20% above the line, a vol
        // band of at least 2 points; vol 24-150% (ETH), 21-120% (BTC), the minimums raised from 20%
        // for the carry corner; carry -20% to +50% for both
        PerpFormulaPricer.Bands memory b = cfg.ethBands();
        assertEq(b.fixingBandSecs, 7200);
        assertEq(b.knockInBelowBps, 200);
        assertEq(b.knockInAboveBps, 1000);
        assertEq(b.healBandBps, 500);
        assertEq(b.stripBelowBps, 200);
        assertEq(b.stripAboveBps, 100);
        assertEq(b.buyBackDiscountBps, 300);
        assertEq(b.discountReachBps, 2000);
        assertEq(b.minVolBandBps, 200);
        assertEq(cfg.btcBands().buyBackDiscountBps, 450);
        assertEq(b.volMinBps, 2400);
        assertEq(b.volMaxBps, 15_000);
        assertEq(b.carryMinBps, -2000);
        assertEq(b.carryMaxBps, 5000);
        b = cfg.btcBands();
        assertEq(b.volMinBps, 2100);
        assertEq(b.volMaxBps, 12_000);
        assertEq(b.carryMinBps, -2000);
        assertEq(b.carryMaxBps, 5000);
        // the same as the fixtures
        assertEq(keccak256(abi.encode(cfg.ethProduct())), keccak256(abi.encode(_product())));
        assertEq(keccak256(abi.encode(cfg.btcProduct())), keccak256(abi.encode(_btcProduct())));
        assertEq(keccak256(abi.encode(cfg.ethBands())), keccak256(abi.encode(_bands())));
        assertEq(keccak256(abi.encode(cfg.btcBands())), keccak256(abi.encode(_btcBands())));
        assertEq(cfg.minSecsToFixing(), MIN_SECS);
        assertEq(cfg.MELT_SHARE(), MELT);
        // market data: stale after 3 h; the keeper's steps 5 vol points and 3 carry points, 10 minutes apart
        IPerpDesk.MarketLimits memory m = cfg.marketLimits();
        assertEq(m.maxMarketAge, 10_800);
        assertEq(m.maxVolStepBps, 500);
        assertEq(m.maxCarryStepBps, 300);
        assertEq(m.minUpdateGap, 600);
        assertEq(keccak256(abi.encode(m)), keccak256(abi.encode(_marketLimits())));
        // Arbitrum One: native USDC, Chainlink ETH/USD and BTC/USD, the sequencer uptime feed
        assertEq(cfg.usdcOf(42_161), 0xaf88d065e77c8cC2239327C5EDb3A432268e5831);
        (address ethUsd, address btcUsd) = cfg.feedsOf(42_161);
        assertEq(ethUsd, 0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612);
        assertEq(btcUsd, 0x6ce185860a4963106506C203335A2910413708e9);
        assertEq(cfg.sequencerOf(42_161), 0xFdB631F5EE196F0ed6FAa767959853A9F217697D);
        IPerpFactory.RecorderLimits memory l = cfg.recorderLimits(address(1));
        assertEq(l.maxFixAge, MAX_FIX_AGE);
        assertEq(l.priceMax, PRICE_MAX);
        assertEq(l.sequencer, address(1));
        assertEq(l.sequencerGrace, GRACE);
        assertEq(keccak256(abi.encode(cfg.recorderLimits(address(sequencer)))), keccak256(abi.encode(_limits())));
    }

    /// USDC, SEQUENCER, ETH_USD and BTC_USD only fill in what the chain has no address for: forge
    /// loads contracts/.env by itself, and a stray value must not rewire an Arbitrum deployment.
    /// (Through `choose`: env vars are shared by the tests running in parallel.)
    function test_env_vars_only_fill_in_unknown_addresses() public {
        (address eth, address btc) = cfg.feedsOf(42_161);
        address[4] memory known = [cfg.usdcOf(42_161), cfg.sequencerOf(42_161), eth, btc];
        string[4] memory names = ["USDC", "SEQUENCER", "ETH_USD", "BTC_USD"];
        for (uint256 i = 0; i < 4; i++) {
            assertTrue(known[i] != address(0));
            // unset (vm.envOr gives the known address back), or repeating it
            assertEq(cfg.choose(names[i], known[i], known[i]), known[i]);
            vm.expectRevert(
                bytes(
                    string.concat(
                        names[i],
                        " names another address than this chain's ",
                        vm.toString(known[i]),
                        ": unset ",
                        names[i]
                    )
                )
            );
            cfg.choose(names[i], known[i], address(0xdEaD));
            // on a chain without one: the env var, or nothing
            assertEq(cfg.choose(names[i], address(0), address(0xdEaD)), address(0xdEaD));
            assertEq(cfg.choose(names[i], address(0), address(0)), address(0));
        }
        // Arbitrum Sepolia has USDC and feeds but no uptime feed: SEQUENCER fills that in
        assertEq(cfg.sequencerOf(421_614), address(0));
        assertTrue(cfg.usdcOf(421_614) != address(0));
    }

    /// On the test chain (31337, no known addresses) the run takes them from the env vars.
    function test_feeds_from_env() public {
        vm.setEnv("ETH_USD", vm.toString(address(feed)));
        vm.setEnv("BTC_USD", vm.toString(address(sequencer)));
        (address ethUsd, address btcUsd) = cfg.feeds();
        assertEq(ethUsd, address(feed));
        assertEq(btcUsd, address(sequencer));
    }

    /// The run (here on a chain with USDC and the keeper passed in): a Desk that closes 300 s before
    /// a fixing, with the launch's market data limits and that keeper, and two pricers, one per
    /// asset, that each price only their own asset's launch series.
    function test_run_deploys_the_launch_setup() public {
        address keeper = makeAddr("keeper");
        vm.setEnv("USDC", vm.toString(address(usdc)));
        vm.setEnv("KEEPER", vm.toString(keeper));
        vm.startStateDiffRecording();
        cfg.run();
        VmSafe.AccountAccess[] memory accesses = vm.stopAndReturnStateDiff();
        PerpDesk desk;
        PerpFormulaPricer[] memory pricers = new PerpFormulaPricer[](2);
        uint256 found;
        for (uint256 i = 0; i < accesses.length; i++) {
            if (accesses[i].kind != VmSafe.AccountAccessKind.Create) continue;
            address a = accesses[i].account;
            try PerpDesk(a).minSecsToFixing() returns (uint32) {
                desk = PerpDesk(a);
                continue;
            } catch {}
            try PerpFormulaPricer(a).bands() returns (PerpFormulaPricer.Bands memory) {
                pricers[found++] = PerpFormulaPricer(a);
            } catch {}
        }
        assertEq(found, 2);
        assertEq(desk.minSecsToFixing(), 300);
        assertEq(desk.asset(), address(usdc));
        assertEq(desk.maxMarketAge(), MARKET_AGE);
        assertEq(desk.maxVolStepBps(), VOL_STEP);
        assertEq(desk.maxCarryStepBps(), CARRY_STEP);
        assertEq(desk.minUpdateGap(), UPDATE_GAP);
        assertEq(desk.keeper(), keeper);
        PerpFormulaPricer eth = pricers[0];
        PerpFormulaPricer btc = pricers[1];
        assertEq(keccak256(abi.encode(eth.product())), keccak256(abi.encode(cfg.ethProduct())));
        assertEq(keccak256(abi.encode(eth.bands())), keccak256(abi.encode(cfg.ethBands())));
        assertEq(keccak256(abi.encode(btc.product())), keccak256(abi.encode(cfg.btcProduct())));
        assertEq(keccak256(abi.encode(btc.bands())), keccak256(abi.encode(cfg.btcBands())));
        // the Desk's lines: the high +-5%, the strip -2% to +1%, the discount (ETH 300, BTC 450) to
        // +20%, the vol band 2 points
        PerpFormulaPricer[2] memory both = [eth, btc];
        for (uint256 i = 0; i < 2; i++) {
            LineBands memory lb = both[i].lineBands();
            assertEq(lb.healBandBps, 500);
            assertEq(lb.stripBelowBps, 200);
            assertEq(lb.stripAboveBps, 100);
            assertEq(lb.buyBackDiscountBps, i == 0 ? 300 : 450);
            assertEq(lb.discountReachBps, 2000);
            assertEq(lb.minVolBandBps, 200);
        }
        // the four corners of each pricer's ranges are carried (its constructor ran), and quote
        assertEq(eth.featureSpecVersion(), 3);
        (int64 lo, int64 hi) = eth.certifiedRange(3);
        assertEq(lo, -2000);
        assertEq(hi, 5000);

        // no market data until the owner writes it; the curator lists an ETH series with the ETH
        // pricer (no vol in the listing), and the BTC pricer is refused for it
        (address ethUsd,) = cfg.feedsOf(block.chainid);
        (,, uint40 sourceTime,,) = desk.market(ethUsd);
        assertEq(sourceTime, 0);
        PerpSeries s = PerpSeries(desk.factory().createSeries(_terms(T0 + 1 hours)));
        vm.prank(desk.owner());
        desk.listSeries(address(s), eth, 1e12);
        vm.prank(desk.owner());
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.ModelMismatch.selector, uint8(0)));
        desk.listSeries(address(s), btc, 1e12);
        _keeperAndRequests(desk, keeper);
    }

    /// The keeper can't write a feed's first market data; the owner does, and the keeper moves it.
    /// LP flows are requests, due an hour later and settled by the keeper's update.
    function _keeperAndRequests(PerpDesk desk, address keeper) internal {
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(IPerpDesk.NoMarketData.selector, address(feed)));
        desk.setMarkets(_update(address(feed), 7000, 400));
        vm.prank(desk.owner());
        desk.setMarkets(_update(address(feed), 7000, 400));
        vm.warp(block.timestamp + 10 minutes);
        vm.prank(keeper);
        desk.setMarkets(_update(address(feed), 7100, 450));
        (uint16 vol,,,,) = desk.market(address(feed));
        assertEq(vol, 7100);
        // LP flows are requests: due an hour later, settled by the keeper's update
        assertEq(desk.DELAY(), 1 hours);
        assertEq(desk.STALL(), 6 hours);
        assertEq(desk.MAX_SETTLE(), 64);
        assertEq(desk.MIN_DEPOSIT_ASSETS(), 100e6);
        assertEq(desk.maxDeposit(keeper), 0);
    }

    function _update(address f, uint16 vol, int16 carry) internal view returns (IPerpDesk.MarketUpdate[] memory u) {
        u = new IPerpDesk.MarketUpdate[](1);
        u[0] = IPerpDesk.MarketUpdate({
            feed: f, volBpsAnnual: vol, carryBpsAnnual: carry, sourceTime: uint40(block.timestamp), source: "options"
        });
    }
}
