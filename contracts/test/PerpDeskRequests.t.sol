// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Vm.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {PerpDeskFixture} from "./PerpDeskFixture.t.sol";
import {MockPerpPricer} from "./mocks/MockPerpPricer.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {MockUSDC} from "./mocks/MockUSDC.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PerpSeries} from "../src/PerpSeries.sol";
import {PerpDesk} from "../src/PerpDesk.sol";
import {IPerpSeries} from "../src/interfaces/IPerpSeries.sol";
import {PerpFormulaPricer} from "../src/PerpFormulaPricer.sol";
import {IPerpDesk} from "../src/interfaces/IPerpDesk.sol";
import {IDeskQueue} from "../src/interfaces/IDeskQueue.sol";
import {PerpTerms} from "../src/interfaces/IPerpSeries.sol";

/// Delayed LP flows (#45, docs/v2-spec.md §8): deposits and redemptions are binding
/// requests, due an hour after they are made, settled only in the market keeper's `setMarkets`,
/// after its writes, at the mark they give; never after a write at the step limit, never at an
/// owner write's values before the keeper's own write of the feed, never on stale data, never
/// by the owner, a trade or anyone else.
contract PerpDeskRequestsTest is PerpDeskFixture {
    address internal hedger = makeAddr("hedger");
    address internal carol = makeAddr("carol");
    bytes32 internal constant SETTLED = keccak256("Settled(uint40,uint256,uint256)");

    // --- helpers -------------------------------------------------------------------------------

    /// The keeper's write of the fixture's feed, sourced now (its gap must have passed).
    function _keeper(uint16 vol, int16 carry) internal {
        vm.prank(keeper);
        desk.setMarkets(_upd(address(feed), vol, carry, uint40(block.timestamp), SOURCE));
    }

    /// minUpdateGap later, a fresh round, and the keeper's write of `vol` and `carry`.
    function _keeperAfterGap(uint16 vol, int16 carry) internal {
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        _keeper(vol, carry);
    }

    /// Time passes (the keeper's gap at least), a fresh round, and the keeper's write of the same
    /// values: the keeper's routine update.
    function _keeperLater(uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        (uint16 vol, int16 carry,,,) = desk.market(address(feed));
        _keeper(vol, carry);
    }

    function _pendingDeposit(uint256 id) internal view returns (uint256 assets) {
        (,, assets) = desk.depositRequest(id);
    }

    function _pendingRedeem(uint256 id) internal view returns (uint256 shares) {
        (,, shares) = desk.redeemRequest(id);
    }

    function _settledIn(Vm.Log[] memory logs) internal view returns (bool) {
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(desk) && logs[i].topics[0] == SETTLED) return true;
        }
        return false;
    }

    function _atBound() internal view returns (bool atBound) {
        (,,,, atBound) = desk.market(address(feed));
    }

    // --- requests ---------------------------------------------------------------------------------

    /// A deposit request pulls the USDC (pending: outside totalAssets), a redemption request the
    /// shares; both are due DELAY later. The constants.
    function test_requests_and_their_views() public {
        assertEq(desk.DELAY(), DELAY);
        assertEq(desk.STALL(), STALL);
        assertEq(desk.MAX_SETTLE(), 64);
        assertEq(desk.MIN_DEPOSIT_ASSETS(), 100e6);
        assertEq(desk.MIN_REQUEST_SHARES(), 10e12);
        usdc.mint(bob, 5_000e6);
        vm.startPrank(bob);
        usdc.approve(address(desk), 5_000e6);
        vm.expectEmit(address(desk));
        emit IDeskQueue.DepositRequested(1, bob, 5_000e6);
        assertEq(desk.requestDeposit(5_000e6), 1); // the fixture's deposit was 0
        vm.stopPrank();
        (address owner_, uint40 dueAt, uint256 assets) = desk.depositRequest(1);
        assertEq(owner_, bob);
        assertEq(dueAt, block.timestamp + DELAY);
        assertEq(assets, 5_000e6);
        assertEq(usdc.balanceOf(bob), 0);
        assertEq(desk.pendingDepositAssets(), 5_000e6);
        assertEq(desk.totalAssets(), LP_CAPITAL); // pending: not the LPs' money yet
        (uint256 head, uint256 length) = desk.depositQueue();
        assertEq(head, 1);
        assertEq(length, 2);

        vm.expectEmit(address(desk));
        emit IDeskQueue.RedeemRequested(0, lp, 1e17);
        assertEq(_requestRedeem(lp, 1e17), 0);
        (owner_, dueAt, assets) = desk.redeemRequest(0);
        assertEq(owner_, lp);
        assertEq(dueAt, block.timestamp + DELAY);
        assertEq(assets, 1e17);
        assertEq(desk.balanceOf(lp), 9e17);
        assertEq(desk.balanceOf(address(desk)), 1e17);
        assertEq(desk.queuedShares(), 1e17);
        assertEq(desk.totalSupply(), 1e18); // queued shares keep their share until filled
    }

    /// LP flows are requests only: the four ERC-4626 entry points revert AsyncOnly and the four
    /// max* return 0, for anyone, at any time; convertTo* and the previews are views of the mark.
    function test_the_erc4626_entry_points_revert_and_max_is_zero() public {
        _buy(alice, 1_000e6, 0);
        usdc.mint(lp, 1_000e6);
        vm.startPrank(lp);
        usdc.approve(address(desk), 1_000e6);
        vm.expectRevert(IDeskQueue.AsyncOnly.selector);
        desk.deposit(1_000e6, lp);
        vm.expectRevert(IDeskQueue.AsyncOnly.selector);
        desk.mint(1e15, lp);
        vm.expectRevert(IDeskQueue.AsyncOnly.selector);
        desk.withdraw(1e6, lp, lp);
        vm.expectRevert(IDeskQueue.AsyncOnly.selector);
        desk.redeem(1e12, lp, lp);
        vm.stopPrank();
        assertEq(desk.maxDeposit(lp), 0);
        assertEq(desk.maxMint(lp), 0);
        assertEq(desk.maxWithdraw(lp), 0);
        assertEq(desk.maxRedeem(lp), 0);
        assertEq(desk.maxDeposit(address(0)), 0);
        // views of the current mark
        uint256 nav = desk.totalAssets();
        uint256 supply = desk.totalSupply();
        assertEq(desk.convertToShares(1_000e6), 1_000e6 * (supply + 1e6) / (nav + 1));
        assertEq(desk.previewDeposit(1_000e6), desk.convertToShares(1_000e6));
        assertEq(desk.previewRedeem(1e12), 1e12 * (nav + 1) / (supply + 1e6));
        assertEq(desk.convertToAssets(1e12), desk.previewRedeem(1e12));
    }

    // --- who and when settles ------------------------------------------------------------------

    /// Only the keeper's update settles, and only requests due by then: not before they are due,
    /// not by an owner write, a trade, a request, a claim or a collect (there is no processQueue).
    /// Deposits first, then redemptions, at one mark (Settled).
    function test_only_the_keepers_update_settles() public {
        _buy(alice, 1_000e6, 0); // the Desk holds COVER: the mark needs the feed's market data
        uint256 dep = _requestDeposit(bob, 10_000e6);
        uint256 red = _requestRedeem(lp, 1e17);
        uint256 due = block.timestamp + DELAY;
        // not due: the keeper's update settles nothing (nor marks: nothing to settle)
        vm.recordLogs();
        _keeperLater(UPDATE_GAP);
        assertFalse(_settledIn(vm.getRecordedLogs()));
        assertEq(_pendingDeposit(dep), 10_000e6);
        // due: the owner's write, trades, a request, collect don't settle
        vm.warp(due);
        _spot(9000);
        _market(VOL + 300, CARRY); // the owner's write
        _buy(alice, 1_000e6, 0); // adds to the Desk's COVER
        _sell(alice, 500e6, 0);
        _requestDeposit(carol, 100e6);
        desk.collect(address(s));
        assertEq(_pendingDeposit(dep), 10_000e6);
        assertEq(_pendingRedeem(red), 1e17);
        assertEq(desk.balanceOf(bob), 0);
        // there is no processQueue any more, nor QUEUE_BATCH
        (bool ok,) = address(desk).call(abi.encodeWithSignature("processQueue(uint256)", 64));
        assertFalse(ok);
        (ok,) = address(desk).call(abi.encodeWithSignature("QUEUE_BATCH()"));
        assertFalse(ok);
        // anyone but the owner and the keeper: refused
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, alice));
        desk.setMarkets(new IPerpDesk.MarketUpdate[](0));

        // the keeper's update: at the mark after its write, the deposit first, then the redemption
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        uint256 snap = vm.snapshotState();
        _market(VOL + 400, CARRY); // the same write by the owner: the mark the keeper's settles at
        uint256 nav = desk.totalAssets();
        uint256 supply = desk.totalSupply();
        vm.revertToStateAndDelete(snap);
        uint256 shares = 10_000e6 * (supply + 1e6) / (nav + 1);
        uint256 assets = 1e17 * (nav + 1 + 10_000e6) / (supply + 1e6 + shares);
        vm.expectEmit(address(desk));
        emit IDeskQueue.Settled(uint40(block.timestamp), nav, supply);
        vm.expectEmit(address(desk));
        emit IDeskQueue.DepositFilled(dep, bob, 10_000e6, shares);
        vm.expectEmit(address(desk));
        emit IDeskQueue.RedeemFilled(red, lp, 1e17, assets);
        _keeper(VOL + 400, CARRY);
        assertEq(desk.balanceOf(bob), shares);
        assertEq(desk.claimableAssets(lp), assets);
        assertEq(desk.reservedAssets(), assets);
        assertEq(desk.pendingDepositAssets(), 100e6); // carol's: not due yet
        assertEq(desk.queuedShares(), 0);
        vm.prank(lp);
        assertEq(desk.claim(lp), assets);
    }

    /// One keeper call writes every feed, then settles the requests due at or before the oldest
    /// sourceTime of the feeds the Desk holds a position on (cutoff): a coin written before a
    /// request was due is no price for it. (The data must also be at most minUpdateGap old, and
    /// the steps below that are blocked by cutoff are by that too; freshness on its own:
    /// test_a_keeper_update_without_a_write_needs_fresh_data.)
    function test_settles_requests_due_by_the_oldest_held_feeds_data() public {
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
        _buy(alice, 1_000e6, 0);
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(desk), type(uint256).max);
        desk.buy(address(s2), 1_000e6, type(uint256).max, 0, integrator, alice);
        vm.stopPrank();
        uint256 r0 = block.timestamp;
        uint256 a = _requestDeposit(bob, 1_000e6); // due r0 + 1 h
        vm.warp(r0 + 20 minutes);
        uint256 b = _requestDeposit(carol, 1_000e6); // due r0 + 1 h 20 min

        // r0 + 1 h 16 min: BTC's keeper write
        vm.warp(r0 + 76 minutes);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        vm.prank(keeper);
        desk.setMarkets(_upd(address(btc), 4500, CARRY, uint40(block.timestamp), SOURCE));
        // ETH's data is from r0, before a was due (cutoff; and 76 minutes old): nothing settles
        assertEq(_pendingDeposit(a), 1_000e6);
        // r0 + 1 h 25 min: the keeper writes ETH; BTC's data, 9 minutes old, is the cutoff: a
        // (due at r0 + 1 h) settles, b (due at r0 + 1 h 20 min) waits: cutoff alone
        vm.warp(r0 + 85 minutes);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        vm.expectEmit(address(desk));
        emit IDeskQueue.Settled(uint40(r0 + 76 minutes), desk.totalAssets(), desk.totalSupply());
        _keeper(VOL, CARRY);
        assertEq(_pendingDeposit(a), 0);
        assertEq(_pendingDeposit(b), 1_000e6);
        // r0 + 1 h 27 min: the owner refreshes ETH; BTC's data is still from before b was due
        // (cutoff; and 11 minutes old): b waits
        vm.warp(r0 + 87 minutes);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        _market(VOL, CARRY); // the owner refreshes ETH (and never settles)
        vm.prank(keeper);
        desk.setMarkets(new IPerpDesk.MarketUpdate[](0));
        assertEq(_pendingDeposit(b), 1_000e6);
        // the keeper's job writes both feeds in one call: b settles
        vm.warp(r0 + 97 minutes);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        IPerpDesk.MarketUpdate[] memory u = new IPerpDesk.MarketUpdate[](2);
        u[0] = _upd(address(feed), VOL, CARRY, uint40(block.timestamp), SOURCE)[0];
        u[1] = _upd(address(btc), 4500, CARRY, uint40(block.timestamp - 30), SOURCE)[0];
        vm.expectEmit(address(desk));
        emit IDeskQueue.Settled(uint40(block.timestamp - 30), desk.totalAssets(), desk.totalSupply());
        vm.prank(keeper);
        desk.setMarkets(u);
        assertEq(_pendingDeposit(b), 0);
        // one write per feed per call: the same feed twice is the keeper's gap
        vm.warp(block.timestamp + UPDATE_GAP);
        u[1] = u[0];
        u[0].sourceTime = uint40(block.timestamp);
        u[1].sourceTime = uint40(block.timestamp);
        vm.prank(keeper);
        vm.expectRevert(IPerpDesk.MarketUpdateTooSoon.selector);
        desk.setMarkets(u);
    }

    /// Nothing settles while a feed the Desk holds a position on had its last write at the step
    /// limit (atBound: the keeper is still catching up, and its next step is known). A smaller
    /// step clears it; an owner write sets it (its values are no settlement price), and only the
    /// keeper's own write of the feed clears it again. A feed the Desk holds nothing on doesn't
    /// count.
    function test_nothing_settles_after_a_write_at_the_step_limit() public {
        _buy(alice, 100_000e6, 0); // the Desk holds COVER
        uint256 dep = _requestDeposit(bob, 1_000e6);
        vm.warp(block.timestamp + DELAY);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        // vol +5 points, exactly the limit: at the bound, nothing settles
        _keeper(VOL + VOL_STEP, CARRY);
        assertTrue(_atBound());
        assertEq(_pendingDeposit(dep), 1_000e6);
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        _keeper(VOL, CARRY); // -5 points: at the bound again
        assertTrue(_atBound());
        assertEq(_pendingDeposit(dep), 1_000e6);
        // a smaller step: settled at the mark it gives
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        _keeper(VOL - VOL_STEP + 1, CARRY);
        assertFalse(_atBound());
        assertEq(_pendingDeposit(dep), 0);
        // the carry at its limit counts too; the owner's write keeps the bit set (and settles
        // nothing), and the keeper's update without a write settles nothing at its values
        uint256 dep2 = _requestDeposit(bob, 1_000e6);
        vm.warp(block.timestamp + DELAY);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        _keeper(VOL - VOL_STEP + 1, CARRY + int16(CARRY_STEP));
        assertTrue(_atBound());
        assertEq(_pendingDeposit(dep2), 1_000e6);
        _market(VOL, CARRY);
        assertTrue(_atBound());
        assertEq(_pendingDeposit(dep2), 1_000e6);
        vm.prank(keeper);
        desk.setMarkets(new IPerpDesk.MarketUpdate[](0)); // the keeper's update without a write
        assertTrue(_atBound());
        assertEq(_pendingDeposit(dep2), 1_000e6);
        // the keeper's own write of the feed, minUpdateGap after the owner's, below the limits
        // (the owner's values, sourced now): cleared, settled
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        _keeper(VOL, CARRY);
        assertFalse(_atBound());
        assertEq(_pendingDeposit(dep2), 0);
        // with a limit of 0 every keeper write is at it: nothing settles until the owner raises it
        desk.setMarketLimits(MARKET_AGE, 0, CARRY_STEP, UPDATE_GAP);
        uint256 dep3 = _requestDeposit(bob, 1_000e6);
        vm.warp(block.timestamp + DELAY);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        _keeper(VOL, CARRY);
        assertTrue(_atBound());
        assertEq(_pendingDeposit(dep3), 1_000e6);

        // a feed at its bound the Desk holds no position on: no matter
        desk.setMarketLimits(MARKET_AGE, VOL_STEP, CARRY_STEP, UPDATE_GAP);
        address btc = address(new MockChainlinkFeed("BTC / USD"));
        _setMarket(btc, 4500, CARRY, uint40(block.timestamp), SOURCE);
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        IPerpDesk.MarketUpdate[] memory u = new IPerpDesk.MarketUpdate[](2);
        u[0] = _upd(address(feed), VOL + 1, CARRY, uint40(block.timestamp), SOURCE)[0];
        u[1] = _upd(btc, 4500 + VOL_STEP, CARRY, uint40(block.timestamp), SOURCE)[0];
        vm.prank(keeper);
        desk.setMarkets(u);
        (,,,, bool btcAtBound) = desk.market(btc);
        assertTrue(btcAtBound);
        assertEq(_pendingDeposit(dep3), 0);
    }

    // --- an owner write holds settlement until the keeper's own write of the feed ---------------

    /// A BTC series next to the ETH one, the Desk holding COVER of both (50,000 ETH, 1,000 BTC);
    /// BTC's market data (vol 45%) is the owner's first write, sourced now.
    function _btcHeld() internal returns (MockChainlinkFeed btc) {
        btc = new MockChainlinkFeed("BTC / USD");
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
        _buy(alice, 50_000e6, 0);
        usdc.mint(alice, 1_000e6);
        vm.startPrank(alice);
        usdc.approve(address(desk), type(uint256).max);
        desk.buy(address(s2), 1_000e6, type(uint256).max, 0, integrator, alice);
        vm.stopPrank();
    }

    /// `secs` later, fresh rounds on both feeds; no market data written.
    function _tick(MockChainlinkFeed btc, uint256 secs) internal {
        vm.warp(block.timestamp + secs);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
    }

    /// totalAssets and totalSupply with `f`'s vol at `vol` (sourced now), the rest as it stands:
    /// the mark a keeper write of it settles at (the same write by the owner, undone).
    function _markWith(address f, uint16 vol) internal returns (uint256 nav, uint256 supply) {
        uint256 snap = vm.snapshotState();
        _setMarket(f, vol, CARRY, uint40(block.timestamp), SOURCE);
        nav = desk.totalAssets();
        supply = desk.totalSupply();
        vm.revertToStateAndDelete(snap);
    }

    /// An owner write is no settlement price: its step is unbounded, and a Safe proposal is public
    /// before it executes. After the owner writes a held feed, the keeper's update without a write
    /// settles nothing, nor does its write of another feed, and for minUpdateGap it can't write
    /// that feed (MarketUpdateTooSoon). Then its own write of the feed, below the step limits,
    /// settles, at the mark that write gives, not the owner's.
    function test_an_owner_write_holds_settlement_until_the_keepers_write_of_the_feed() public {
        MockChainlinkFeed btc = _btcHeld();
        uint256 dep = _requestDeposit(bob, 10_000e6);
        uint256 red = _requestRedeem(lp, 1e17);
        // due: the Safe writes ETH's vol 30 points down
        _tick(btc, DELAY);
        uint40 t = uint40(block.timestamp);
        _market(VOL - 3000, CARRY);
        assertTrue(_atBound());
        // the keeper's update without a write: nothing settles
        vm.recordLogs();
        _settleWithoutWrite();
        assertFalse(_settledIn(vm.getRecordedLogs()));
        // its write of BTC alone: written, nothing settles
        vm.recordLogs();
        vm.prank(keeper);
        desk.setMarkets(_upd(address(btc), 4500, CARRY, t, SOURCE));
        assertFalse(_settledIn(vm.getRecordedLogs()));
        (,, uint40 btcTime,,) = desk.market(address(btc));
        assertEq(btcTime, t);
        // ETH not until minUpdateGap after the owner's write; the update without a write, on data
        // still fresh, settles nothing
        _tick(btc, UPDATE_GAP - 1);
        vm.prank(keeper);
        vm.expectRevert(IPerpDesk.MarketUpdateTooSoon.selector);
        desk.setMarkets(_upd(address(feed), VOL - 2600, CARRY, uint40(block.timestamp), SOURCE));
        _settleWithoutWrite();
        assertTrue(_atBound());
        assertEq(_pendingDeposit(dep), 10_000e6);
        assertEq(_pendingRedeem(red), 1e17);
        // then: the keeper's write of ETH, 4 points toward the market (below the limit), settles
        // at the mark it gives (cutoff: BTC's data, from t), the deposit first
        _tick(btc, 1);
        uint256 navOwner = desk.totalAssets(); // at the owner's vol
        (uint256 nav, uint256 supply) = _markWith(address(feed), VOL - 2600);
        assertNotEq(nav, navOwner);
        uint256 shares = 10_000e6 * (supply + 1e6) / (nav + 1);
        uint256 assets = 1e17 * (nav + 1 + 10_000e6) / (supply + 1e6 + shares);
        vm.expectEmit(address(desk));
        emit IDeskQueue.Settled(t, nav, supply);
        vm.expectEmit(address(desk));
        emit IDeskQueue.DepositFilled(dep, bob, 10_000e6, shares);
        vm.expectEmit(address(desk));
        emit IDeskQueue.RedeemFilled(red, lp, 1e17, assets);
        _keeper(VOL - 2600, CARRY);
        assertFalse(_atBound());
        assertEq(desk.balanceOf(bob), shares);
        assertEq(desk.claimableAssets(lp), assets);
    }

    /// After an owner write, a keeper write of the feed at a step limit, the carry's or the vol's,
    /// settles nothing (atBound: the keeper is catching up with the owner's move); its next
    /// write below both limits does.
    function test_after_an_owner_write_a_keeper_write_at_the_limit_settles_nothing() public {
        _buy(alice, 50_000e6, 0);
        uint256 dep = _requestDeposit(bob, 1_000e6);
        vm.warp(block.timestamp + DELAY);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        _market(VOL - 3000, CARRY); // the Safe's write, the request due
        // the carry by its full limit (the vol by less)
        _keeperAfterGap(VOL - 2900, CARRY + int16(CARRY_STEP));
        assertTrue(_atBound());
        assertEq(_pendingDeposit(dep), 1_000e6);
        // the vol by its full limit
        _keeperAfterGap(VOL - 2900 + VOL_STEP, CARRY + int16(CARRY_STEP));
        assertTrue(_atBound());
        assertEq(_pendingDeposit(dep), 1_000e6);
        // both below: settled
        _keeperAfterGap(VOL - 2900 + 2 * VOL_STEP - 1, CARRY + 1);
        assertFalse(_atBound());
        assertEq(_pendingDeposit(dep), 0);
    }

    /// The owner's write of a feed the Desk holds nothing on (a listed BTC series, no position)
    /// sets that feed's atBound and holds nothing: the keeper's update writing ETH settles.
    function test_an_owner_write_of_a_feed_the_desk_holds_nothing_on_holds_nothing() public {
        _buy(alice, 1_000e6, 0); // the Desk holds ETH COVER
        MockChainlinkFeed btc = new MockChainlinkFeed("BTC / USD");
        MockPerpPricer btcPricer = new MockPerpPricer();
        btcPricer.setProduct(_btcProduct());
        desk.listSeries(address(_create(_btcTerms(address(btc), first))), btcPricer, CAP);
        uint256 dep = _requestDeposit(bob, 1_000e6);
        _later(DELAY, 9000);
        _setMarket(address(btc), 4500, CARRY, uint40(block.timestamp), SOURCE);
        (,,,, bool btcAtBound) = desk.market(address(btc));
        assertTrue(btcAtBound);
        _settle(); // the keeper's routine update: ETH written, the deposit filled
        assertEq(_pendingDeposit(dep), 0);
        (,,,, btcAtBound) = desk.market(address(btc));
        assertTrue(btcAtBound);
    }

    /// The owner's recovery (docs/v2-spec.md §10), the keeper writing wrong values or its key lost:
    /// the owner removes it (setKeeper(address(0))), writes the right values on each held feed,
    /// and sets a new keeper (not itself: KeeperIsOwner, its writes never settle). Nothing settles
    /// at the owner's values; the new keeper's first write of each held feed, at least
    /// minUpdateGap after the owner's, does, at the mark it gives.
    function test_the_owners_recovery_runbook() public {
        MockChainlinkFeed btc = _btcHeld();
        address next = makeAddr("next keeper");
        // the keeper writes ETH 4 points off the market (nothing is due)
        _tick(btc, UPDATE_GAP);
        _keeper(VOL - 400, CARRY);
        uint256 dep = _requestDeposit(bob, 10_000e6);
        uint256 red = _requestRedeem(lp, 1e17);
        // due: the owner removes the keeper and writes both held feeds
        _tick(btc, DELAY);
        desk.setKeeper(address(0));
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, keeper));
        desk.setMarkets(new IPerpDesk.MarketUpdate[](0));
        IPerpDesk.MarketUpdate[] memory u = new IPerpDesk.MarketUpdate[](2);
        u[0] = _upd(address(feed), VOL, CARRY, uint40(block.timestamp), "recovery")[0];
        u[1] = _upd(address(btc), 4500, CARRY, uint40(block.timestamp), "recovery")[0];
        desk.setMarkets(u);
        vm.expectRevert(IPerpDesk.KeeperIsOwner.selector);
        desk.setKeeper(address(this));
        desk.setKeeper(next);
        // the new keeper: no write before minUpdateGap, no settlement at the owner's values
        vm.prank(next);
        vm.expectRevert(IPerpDesk.MarketUpdateTooSoon.selector);
        desk.setMarkets(_upd(address(btc), 4500, CARRY, uint40(block.timestamp), SOURCE));
        vm.prank(next);
        desk.setMarkets(new IPerpDesk.MarketUpdate[](0));
        assertEq(_pendingDeposit(dep), 10_000e6);
        // minUpdateGap on: its write of ETH alone settles nothing, BTC's last write is the owner's
        _tick(btc, UPDATE_GAP);
        vm.prank(next);
        desk.setMarkets(_upd(address(feed), VOL, CARRY, uint40(block.timestamp), SOURCE));
        assertEq(_pendingDeposit(dep), 10_000e6);
        assertEq(_pendingRedeem(red), 1e17);
        // its write of BTC, a point up: every held feed is the keeper's again, settled at that mark
        (uint256 nav, uint256 supply) = _markWith(address(btc), 4600);
        uint256 shares = 10_000e6 * (supply + 1e6) / (nav + 1);
        uint256 assets = 1e17 * (nav + 1 + 10_000e6) / (supply + 1e6 + shares);
        vm.expectEmit(address(desk));
        emit IDeskQueue.Settled(uint40(block.timestamp), nav, supply);
        vm.expectEmit(address(desk));
        emit IDeskQueue.DepositFilled(dep, bob, 10_000e6, shares);
        vm.expectEmit(address(desk));
        emit IDeskQueue.RedeemFilled(red, lp, 1e17, assets);
        vm.prank(next);
        desk.setMarkets(_upd(address(btc), 4600, CARRY, uint40(block.timestamp), SOURCE));
        assertEq(desk.balanceOf(bob), shares);
        assertEq(desk.claimableAssets(lp), assets);
    }

    /// When the mark can't be computed (a pending fixing, a pricer's refusal), the keeper's write
    /// still goes through (MarketSet), and nothing settles (no Settled): a failed settlement
    /// never takes the vol write with it.
    function test_a_failing_mark_skips_settlement_and_keeps_the_write() public {
        _buy(alice, 1_000e6, 0);
        uint256 dep = _requestDeposit(bob, 1_000e6);
        // the fixing time passes, nobody records it: FixingPending
        feed.pushRoundAt(_price(9000), first + DAY);
        vm.warp(uint256(first) + DAY + 1);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        vm.recordLogs();
        _keeper(VOL + 200, CARRY);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertFalse(_settledIn(logs));
        assertEq(logs.length, 1); // MarketSet
        (uint16 vol,, uint40 sourceTime,,) = desk.market(address(feed));
        assertEq(vol, VOL + 200);
        assertEq(sourceTime, block.timestamp);
        assertEq(_pendingDeposit(dep), 1_000e6);
        _recorder(s).recordFixing(first + DAY, uint80(feed.latestRound() - 1));
        // the pricer refuses the vol: still no mark
        pricer.setRange(1, 2400, int64(uint64(VOL + 200)));
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        _keeper(VOL + 201, CARRY);
        (vol,,,,) = desk.market(address(feed));
        assertEq(vol, VOL + 201);
        assertEq(_pendingDeposit(dep), 1_000e6);
        // back in range: settled
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        _keeper(VOL + 100, CARRY);
        assertEq(_pendingDeposit(dep), 0);
        assertGt(desk.balanceOf(bob), 0);
    }

    // --- accounting ---------------------------------------------------------------------------------

    /// Pending deposits are not the LPs' money yet: outside totalAssets and the risk budget, and a
    /// trade can't spend them (ReservedForClaims). Once filled they are.
    function test_pending_deposits_are_not_assets_risk_or_spendable() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        (, uint256 limit) = desk.risk(address(feed));
        uint256 dep = _requestDeposit(bob, 2_000_000e6);
        assertEq(desk.totalAssets(), LP_CAPITAL);
        (, uint256 limitAfter) = desk.risk(address(feed));
        assertEq(limitAfter, limit);
        // 5,000,000 NOTE need 1,080,000 USDC of the vault for the pairs: more than its idle 1,000,000
        uint256 quoted = _quoteOf(IPerpDesk.Side.BuyNote, 5_000_000e6, 0);
        usdc.mint(alice, quoted);
        vm.startPrank(alice);
        usdc.approve(address(desk), quoted);
        vm.expectRevert(IDeskQueue.ReservedForClaims.selector);
        desk.buy(address(s), 5_000_000e6, quoted, 0, integrator, alice);
        vm.stopPrank();
        // filled, it is
        _later(DELAY, 9000);
        _settle();
        assertEq(_pendingDeposit(dep), 0);
        assertEq(desk.totalAssets(), LP_CAPITAL + 2_000_000e6);
        _buy(alice, 5_000_000e6, 0);
    }

    /// FIFO: deposits are filled in the order made, all of each; redemptions in the order made,
    /// out of idle USDC, the last one reached partly when it runs out (shortfall), and the next
    /// settlement goes on from there.
    function test_fifo_and_partial_fills() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buyCover(hedger, 1_000_000e6, 0); // idle: 216,000 USDC
        uint256 r1 = _requestRedeem(lp, 1e17); // ~100,000 USDC
        uint256 r2 = _requestRedeem(lp, 2e17); // ~200,000
        uint256 r3 = _requestRedeem(lp, 1e17);
        _later(DELAY, 9000);
        uint256 idle = usdc.balanceOf(address(desk));
        _settle();
        assertEq(_pendingRedeem(r1), 0);
        uint256 rest2 = _pendingRedeem(r2);
        assertGt(rest2, 0);
        assertLt(rest2, 2e17);
        assertEq(_pendingRedeem(r3), 1e17);
        (uint256 head,) = desk.queue();
        assertEq(head, r2);
        assertTrue(desk.shortfall());
        assertApproxEqAbs(desk.claimableAssets(lp), idle, 1);
        // a deposit due later pays the rest, in order: r2, then r3
        _requestDeposit(bob, 300_000e6);
        _later(DELAY, 9000);
        _settle();
        assertEq(_pendingRedeem(r2), 0);
        assertEq(_pendingRedeem(r3), 0);
        assertFalse(desk.shortfall());
        (head,) = desk.queue();
        assertEq(head, 3);
    }

    /// A settlement visits at most MAX_SETTLE requests of each queue: the rest waits for the
    /// keeper's next update (not a shortfall), and deposits can't crowd redemptions out. An owner
    /// write in between settles none of it, though without a position no market data is needed.
    function test_a_settlement_visits_at_most_max_settle_requests() public {
        for (uint256 i = 0; i < 70; i++) {
            _requestDeposit(address(uint160(0x1000 + i)), 100e6);
        }
        uint256 red = _requestRedeem(lp, 1e17);
        _later(DELAY, 9000);
        _settle();
        (uint256 head,) = desk.depositQueue();
        assertEq(head, 65); // the fixture's request was 0
        assertEq(desk.pendingDepositAssets(), 6 * 100e6);
        assertEq(_pendingRedeem(red), 0); // its own budget
        assertFalse(desk.shortfall());
        _market(VOL, CARRY); // owner writes never settle
        (head,) = desk.depositQueue();
        assertEq(head, 65);
        _keeperLater(UPDATE_GAP);
        (head,) = desk.depositQueue();
        assertEq(head, 71);
    }

    /// A stream of 64 small deposits every 10 minutes (the most one settlement visits) doesn't
    /// hold a due redemption back: it settles at the first update after it is due.
    function test_deposits_cannot_crowd_redemptions_out() public {
        uint256 red = _requestRedeem(lp, 1e17);
        uint256 t0 = block.timestamp;
        for (uint256 i = 0; i < 64; i++) {
            _requestDeposit(address(uint160(0x9000 + i)), 100e6);
        }
        for (uint256 k = 0; k < 7; k++) {
            vm.warp(block.timestamp + UPDATE_GAP);
            _spot(9000);
            for (uint256 i = 0; i < 64; i++) {
                _requestDeposit(address(uint160(0x9000 + i)), 100e6);
            }
            if (block.timestamp >= t0 + DELAY) _settle();
        }
        assertEq(_pendingRedeem(red), 0);
        assertGt(desk.pendingDepositAssets(), 64 * 100e6); // the stream still waits its turn
    }

    /// Only a real shortfall blocks trades, and only those that add to the Desk's position: due
    /// requests waiting for the keeper's update block nothing.
    function test_only_a_shortfall_blocks_trades_that_add_to_a_position() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buyCover(hedger, 900_000e6, 0); // the Desk holds 900,000 NOTE; idle ~294,400 USDC
        _requestRedeem(lp, desk.balanceOf(lp) / 2);
        _later(DELAY, 9000);
        // due, not settled: every trade goes on
        _buyCover(hedger, 1_000e6, 0); // adds NOTE
        _buy(alice, 1_000e6, 0); // from inventory
        assertFalse(desk.shortfall());
        _settle(); // ~500,000 USDC due, ~290,000 idle: a shortfall
        assertTrue(desk.shortfall());
        uint256 queued = desk.queuedShares();
        bytes memory err = abi.encodeWithSelector(IDeskQueue.QueuePending.selector, queued);
        // adding: buyCover (the Desk mints pairs, keeps NOTE) and sell (the Desk buys NOTE it can't pair)
        uint256 quoted = _quoteOf(IPerpDesk.Side.BuyCover, 1_000_000e6, 0);
        usdc.mint(hedger, quoted);
        vm.startPrank(hedger);
        usdc.approve(address(desk), quoted);
        vm.expectRevert(err);
        desk.buyCover(address(s), 1_000_000e6, quoted, 0, integrator, hedger);
        vm.stopPrank();
        _buy(alice, 10_000e6, 0); // NOTE from the Desk's inventory: shrinks it
        vm.startPrank(alice);
        noteT.approve(address(desk), type(uint256).max);
        vm.expectRevert(err);
        desk.sell(address(s), 5_000e6, 0, 0, integrator, alice); // the Desk holds NOTE: no pair, adds
        vm.stopPrank();
        // shrinking: the hedger's cover back, paired with the Desk's NOTE
        _sellCover(hedger, 500_000e6, 0);
        assertTrue(desk.shortfall()); // until the keeper's next update
        _keeperLater(UPDATE_GAP);
        assertFalse(desk.shortfall());
        _buyCover(hedger, 1_000e6, 0);
    }

    /// The shortfall clears when a settlement gets past every due redemption, even with its
    /// last visit: here the partly filled request and 63 more fill the 64 visits exactly and
    /// drain the queue. (It used to stay set, and with nothing due no later update cleared it:
    /// trades that add to a position were refused, QueuePending(0), until a new request.)
    function test_the_shortfall_clears_when_the_last_visit_drains_the_queue() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buyCover(hedger, 1_000_000e6, 0); // idle: 216,000 USDC
        uint256 r = _requestRedeem(lp, 3e17); // ~300,000 USDC
        _later(DELAY, 9000);
        _settle();
        assertTrue(desk.shortfall());
        assertGt(_pendingRedeem(r), 0);
        // 63 more redemptions and a deposit that pays them all, due an hour later
        for (uint256 i = 0; i < 63; i++) {
            _requestRedeem(lp, 1e15);
        }
        _requestDeposit(bob, 200_000e6);
        _later(DELAY, 9000);
        _settle();
        assertEq(_pendingRedeem(r), 0);
        (uint256 head, uint256 len) = desk.queue();
        assertEq(head, 64);
        assertEq(len, 64);
        assertFalse(desk.shortfall());
        // nothing due any more: later updates leave it so, and trades that add go through
        for (uint256 k = 0; k < 3; k++) {
            _keeperLater(UPDATE_GAP);
        }
        assertFalse(desk.shortfall());
        _buyCover(hedger, 1_000e6, 0);
    }

    /// When the 64 redemption visits run out before a due redemption, the settlement can't tell
    /// whether the rest lacks USDC: the flag stays as it was, and the next update decides.
    function test_the_shortfall_stays_while_due_redemptions_wait_for_visits() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buyCover(hedger, 1_000_000e6, 0);
        _requestRedeem(lp, 3e17);
        _later(DELAY, 9000);
        _settle();
        assertTrue(desk.shortfall());
        for (uint256 i = 0; i < 64; i++) {
            _requestRedeem(lp, 1e15);
        }
        _requestDeposit(bob, 200_000e6);
        _later(DELAY, 9000);
        _settle(); // the partly filled one and 63 more: the 64th waits
        (uint256 head, uint256 len) = desk.queue();
        assertEq(head, 64);
        assertEq(len, 65);
        assertTrue(desk.shortfall());
        _keeperLater(UPDATE_GAP);
        assertFalse(desk.shortfall());
        (head,) = desk.queue();
        assertEq(head, 65);
    }

    /// The short redemption cancelled STALL past due (the keeper was away): the request stays at
    /// the head with nothing left, so the next keeper update visits it and clears the flag.
    function test_cancelling_the_short_redemption_clears_the_shortfall_at_the_next_update() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buyCover(hedger, 1_000_000e6, 0);
        uint256 r = _requestRedeem(lp, 3e17);
        uint40 due = uint40(block.timestamp) + DELAY;
        _later(DELAY, 9000);
        _settle();
        assertTrue(desk.shortfall());
        vm.warp(uint256(due) + STALL);
        _spot(9000);
        vm.prank(lp);
        assertGt(desk.cancelRedeem(r), 0);
        assertTrue(desk.shortfall()); // until the keeper's next update
        assertEq(desk.queuedShares(), 0);
        uint256 quoted = _quoteOf(IPerpDesk.Side.BuyCover, 1_000e6, 0);
        usdc.mint(hedger, quoted);
        vm.startPrank(hedger);
        usdc.approve(address(desk), quoted);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.QueuePending.selector, 0));
        desk.buyCover(address(s), 1_000e6, quoted, 0, integrator, hedger);
        vm.stopPrank();
        _settle();
        assertFalse(desk.shortfall());
        (uint256 head,) = desk.queue();
        assertEq(head, 1);
        _sellCover(hedger, 100_000e6, 0); // frees USDC (the rest is set aside for the LP's claim)
        _buyCover(hedger, 1_000e6, 0);
    }

    /// Freshness on its own: the keeper's write at C settles nothing (the pricer refuses the
    /// vol); 15 minutes later the cause is gone, and the keeper's update without a write would
    /// settle the request (due before C) at C's data, now older than minUpdateGap: it doesn't.
    /// The keeper's next write, fresh, does.
    function test_a_keeper_update_without_a_write_needs_fresh_data() public {
        _buy(alice, 100_000e6, 0);
        uint256 dep = _requestDeposit(bob, 1_000e6);
        vm.warp(block.timestamp + DELAY);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        pricer.setRange(1, 2400, int64(uint64(VOL - 1)));
        _keeper(VOL, CARRY); // C: written, not settled
        assertEq(_pendingDeposit(dep), 1_000e6);
        pricer.setRange(1, 2400, 15_000);
        vm.warp(block.timestamp + 15 minutes);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        assertTrue(_markable());
        vm.recordLogs();
        vm.prank(keeper);
        desk.setMarkets(new IPerpDesk.MarketUpdate[](0));
        assertFalse(_settledIn(vm.getRecordedLogs()));
        assertEq(_pendingDeposit(dep), 1_000e6);
        _keeper(VOL, CARRY);
        assertEq(_pendingDeposit(dep), 0);
    }

    /// A held series whose advance() fails (here: it reverts; a fixing backlog too long for the
    /// gas given does the same): the keeper's write still lands, nothing settles, and the next
    /// update settles once it works again.
    function test_a_failing_advance_skips_settlement_and_keeps_the_write() public {
        _buy(alice, 1_000e6, 0);
        uint256 dep = _requestDeposit(bob, 1_000e6);
        vm.warp(block.timestamp + DELAY);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        vm.mockCallRevert(address(s), abi.encodeWithSelector(IPerpSeries.advance.selector), "no advance");
        vm.recordLogs();
        _keeper(VOL + 100, CARRY);
        assertFalse(_settledIn(vm.getRecordedLogs()));
        (uint16 vol,,,,) = desk.market(address(feed));
        assertEq(vol, VOL + 100);
        assertEq(_pendingDeposit(dep), 1_000e6);
        vm.clearMockedCalls();
        _keeperLater(UPDATE_GAP);
        assertEq(_pendingDeposit(dep), 0);
    }

    /// The same with a real backlog: 120 recorded fixings the held series hasn't processed,
    /// and a keeper call given gas for its write but not for them. The write lands.
    function test_an_advance_out_of_gas_skips_settlement_and_keeps_the_write() public {
        _buy(alice, 1_000e6, 0);
        uint256 dep = _requestDeposit(bob, 1_000e6);
        for (uint256 n = 1; n <= 120; n++) {
            _fixAt(s, _fixingTime(s, n), _price(9000));
        }
        vm.warp(uint256(_fixingTime(s, 120)) + 60);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        IPerpDesk.MarketUpdate[] memory u = _upd(address(feed), VOL + 100, CARRY, uint40(block.timestamp), SOURCE);
        vm.prank(keeper);
        desk.setMarkets{gas: 1_000_000}(u);
        (uint16 vol,,,,) = desk.market(address(feed));
        assertEq(vol, VOL + 100);
        assertEq(_pendingDeposit(dep), 1_000e6);
        assertEq(s.state().fixingsDone, 120); // the views see them all
        // with the gas for the backlog: settled
        _keeperLater(UPDATE_GAP);
        assertEq(_pendingDeposit(dep), 0);
    }

    /// The owner can't be the keeper: its writes never settle, so as the keeper too it would leave
    /// every request unsettled (KeeperIsOwner, in setKeeper and in the constructor).
    function test_the_owner_cannot_be_the_keeper() public {
        vm.expectRevert(IPerpDesk.KeeperIsOwner.selector);
        desk.setKeeper(address(this));
        vm.expectRevert(IPerpDesk.KeeperIsOwner.selector);
        new PerpDesk(IERC20(address(usdc)), factory, quoter, alice, MIN_SECS, _marketLimits(), alice);
        desk.setKeeper(address(0)); // none is fine
        assertEq(desk.keeper(), address(0));
    }

    // --- binding requests -------------------------------------------------------------------------

    /// A partly filled redemption, a keeper outage: STALL past due its owner takes the unfilled
    /// rest back, exactly; before that it can't (CancelTooEarly), so a request is no option.
    function test_cancel_after_stall_returns_the_unfilled_rest() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buyCover(hedger, 900_000e6, 0);
        uint256 id = _requestRedeem(lp, desk.balanceOf(lp));
        uint40 due = uint40(block.timestamp) + DELAY;
        _later(DELAY, 9000);
        _settle();
        uint256 rest = _pendingRedeem(id);
        assertGt(rest, 0);
        uint256 balance = desk.balanceOf(lp);
        // the keeper stops; the LP waits out STALL
        vm.warp(uint256(due) + STALL - 1);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.CancelTooEarly.selector, due + STALL));
        desk.cancelRedeem(id);
        vm.warp(uint256(due) + STALL);
        vm.expectEmit(address(desk));
        emit IDeskQueue.RedeemCancelled(id, lp, rest);
        vm.prank(lp);
        assertEq(desk.cancelRedeem(id), rest);
        assertEq(desk.balanceOf(lp), balance + rest);
        assertEq(desk.queuedShares(), 0);
        assertEq(_pendingRedeem(id), 0);
        // what was filled stays claimable
        assertGt(desk.claimableAssets(lp), 0);
    }

    /// A redemption request leaves its owner none or at least MIN_REQUEST_SHARES (RestTooSmall):
    /// a smaller rest couldn't be requested in turn. Dust can still come from a transfer or from
    /// cancelling a partly filled request; its holder tops it up with a deposit (or transfers it).
    function test_a_redemption_request_leaves_no_dust() public {
        uint256 bal = desk.balanceOf(lp);
        uint256 min = desk.MIN_REQUEST_SHARES();
        vm.startPrank(lp);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.RestTooSmall.selector, uint256(1), min));
        desk.requestRedeem(bal - 1);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.RestTooSmall.selector, min - 1, min));
        desk.requestRedeem(bal - min + 1);
        desk.requestRedeem(bal - min); // the minimum left: in
        desk.requestRedeem(min); // all of the rest: in
        vm.stopPrank();
        assertEq(desk.balanceOf(lp), 0);
    }

    /// Dust from cancelling a partly filled request STALL past due: it can't be requested
    /// (RequestTooSmall); a deposit tops it up, and then all of it can.
    function test_dust_from_a_cancel_is_topped_up_with_a_deposit() public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buyCover(hedger, 1_000_000e6, 0); // idle: 216,000 USDC
        uint256 idle = usdc.balanceOf(address(desk));
        uint256 ask = desk.convertToShares(idle) + 5e12; // a hair above what idle pays
        uint256 lpBal = desk.balanceOf(lp);
        vm.prank(lp);
        assertTrue(desk.transfer(carol, lpBal - ask)); // the LP keeps exactly `ask`
        uint256 id = _requestRedeem(lp, ask);
        uint40 due = uint40(block.timestamp) + DELAY;
        _later(DELAY, 9000);
        _settle();
        uint256 rest = _pendingRedeem(id);
        assertGt(rest, 0);
        assertLt(rest, desk.MIN_REQUEST_SHARES());
        vm.warp(uint256(due) + STALL);
        _spot(9000);
        vm.prank(lp);
        assertEq(desk.cancelRedeem(id), rest);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(IDeskQueue.RequestTooSmall.selector, rest, desk.MIN_REQUEST_SHARES()));
        desk.requestRedeem(rest);
        // a deposit tops it up
        _sellCover(hedger, 1_000_000e6, 0); // (and the Desk is liquid again)
        _requestDeposit(lp, 100e6);
        _later(DELAY, 9000);
        _settle();
        uint256 all = desk.balanceOf(lp);
        assertGt(all, desk.MIN_REQUEST_SHARES());
        _requestRedeem(lp, all);
    }

    /// Cancelling a request that was filled already: no revert, 0 back, the event with 0.
    function test_cancelling_a_filled_request_returns_nothing() public {
        uint256 dep = _requestDeposit(bob, 1_000e6);
        _later(DELAY, 9000);
        _settle();
        assertEq(_pendingDeposit(dep), 0);
        vm.warp(block.timestamp + STALL);
        vm.expectEmit(address(desk));
        emit IDeskQueue.DepositCancelled(dep, bob, 0);
        vm.prank(bob);
        assertEq(desk.cancelDeposit(dep), 0);
    }

    /// Settlement never calls out to a request's owner: shares are minted and USDC is set aside.
    /// So an owner USDC froze can't hold the queue up; it claims to another address.
    function test_a_frozen_owner_cannot_block_settlement() public {
        uint256 dep = _requestDeposit(bob, 1_000e6);
        uint256 red = _requestRedeem(lp, 1e17);
        uint256 dep2 = _requestDeposit(carol, 1_000e6);
        MockUSDC(address(usdc)).setFrozen(bob, true);
        MockUSDC(address(usdc)).setFrozen(lp, true);
        _later(DELAY, 9000);
        _settle();
        assertEq(_pendingDeposit(dep), 0);
        assertEq(_pendingRedeem(red), 0);
        assertEq(_pendingDeposit(dep2), 0);
        assertGt(desk.balanceOf(bob), 0);
        uint256 claimable = desk.claimableAssets(lp);
        assertGt(claimable, 0);
        vm.prank(lp);
        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Frozen.selector, lp));
        desk.claim(lp);
        vm.prank(lp);
        assertEq(desk.claim(alice), claimable);
    }

    // --- the price -----------------------------------------------------------------------------------

    /// The settlement price is the share price right after the keeper's writes: a deposit gets
    /// convertToShares and a redemption convertToAssets of the state the same writes by the owner
    /// (which never settle) leave, whatever the step, and the price per share doesn't fall.
    function testFuzz_the_settlement_price_is_the_mark_right_after_the_write(
        uint256 assets,
        uint256 shares,
        int256 volStep,
        int256 carryStep,
        bool redeem
    ) public {
        desk.listSeries(address(s), pricer, type(uint128).max);
        _buy(alice, 300_000e6, 0); // the Desk holds 300,000 COVER: the share price moves with vol
        assets = bound(assets, 100e6, 10_000_000e6);
        shares = bound(shares, 10e12, 9e17);
        if (redeem) _requestRedeem(lp, shares);
        else _requestDeposit(bob, assets);
        vm.warp(block.timestamp + DELAY);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        uint16 vol =
            uint16(int16(VOL) + int16(bound(volStep, -int256(uint256(VOL_STEP)) + 1, int256(uint256(VOL_STEP)) - 1)));
        int16 carry = CARRY + int16(bound(carryStep, -int256(uint256(CARRY_STEP)) + 1, int256(uint256(CARRY_STEP)) - 1));
        uint256 snap = vm.snapshotState();
        _market(vol, carry);
        uint256 want = redeem ? desk.convertToAssets(shares) : desk.convertToShares(assets);
        uint256 nav = desk.totalAssets();
        uint256 supply = desk.totalSupply();
        vm.revertToStateAndDelete(snap);
        _keeper(vol, carry);
        if (redeem) assertEq(desk.claimableAssets(lp), want);
        else assertEq(desk.balanceOf(bob), want);
        // (nav + 1) / (supply + 1e6) after >= before
        assertGe((desk.totalAssets() + 1) * (supply + 1e6), (nav + 1) * (desk.totalSupply() + 1e6));
    }

    // --- gas --------------------------------------------------------------------------------------------

    /// The gas of the keeper's `setMarkets` alone: one write of the fixture's feed, sourced now.
    function _keeperGas(uint16 vol, int16 carry) internal returns (uint256 used) {
        IPerpDesk.MarketUpdate[] memory u = _upd(address(feed), vol, carry, uint40(block.timestamp), SOURCE);
        vm.prank(keeper);
        used = gasleft();
        desk.setMarkets(u);
        used -= gasleft();
    }

    /// An hour on, a fresh round, and the keeper's update, measured.
    function _dueAndSettle() internal returns (uint256) {
        vm.warp(block.timestamp + DELAY);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        return _keeperGas(VOL, CARRY);
    }

    /// The keeper's update with the fixture's one held series (the mock model: the Desk's own
    /// cost): a write with nothing due, then settling 1, 8 and 64 deposits and 64 redemptions,
    /// each for an account seen for the first time; and the two requests.
    function test_gas_of_the_keepers_update() public {
        _buy(alice, 1_000e6, 0);
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        emit log_named_uint("gas, keeper update (1 feed), nothing due", _keeperGas(VOL + 100, CARRY));
        uint256[3] memory ns = [uint256(1), 8, 64];
        for (uint256 k = 0; k < 3; k++) {
            for (uint256 i = 0; i < ns[k]; i++) {
                _requestDeposit(address(uint160(0x10000 * (k + 1) + i)), 100e6);
            }
            emit log_named_uint(
                string.concat("gas, keeper update (1 feed), settling deposits: ", vm.toString(ns[k])), _dueAndSettle()
            );
        }
        for (uint256 i = 0; i < 64; i++) {
            address a = address(uint160(0x30000 + i));
            _requestRedeem(a, desk.balanceOf(a));
        }
        emit log_named_uint("gas, keeper update (1 feed), settling redemptions: 64", _dueAndSettle());
        assertEq(desk.queuedShares(), 0);
        // the requests themselves
        usdc.mint(bob, 1_000e6);
        vm.prank(bob);
        usdc.approve(address(desk), 1_000e6);
        vm.prank(bob);
        uint256 g = gasleft();
        desk.requestDeposit(1_000e6);
        emit log_named_uint("gas, requestDeposit", g - gasleft());
        vm.prank(lp);
        g = gasleft();
        desk.requestRedeem(1e15);
        emit log_named_uint("gas, requestRedeem", g - gasleft());
    }

    /// The worst case: 64 held series (MAX_HELD_SERIES), each priced by the launch's formula
    /// pricer, and both queues' MAX_SETTLE: 64 deposits and 64 redemptions due in one update,
    /// each for an account seen for the first time (a new balance, a new claim). The marking
    /// pass is most of it: 64 quotes of the closed form, about 156,000 gas each (PerpQuoter.t.sol,
    /// test_gas_of_one_quote); each request adds about 35,000. Under half of Arbitrum's 32
    /// million block gas limit. (The design note's ~10 million did not count the quotes; at
    /// launch the Desk holds a few series: about 0.3 million per held series.)
    function test_gas_of_the_worst_case_settlement() public {
        PerpFormulaPricer fp = new PerpFormulaPricer(pricer.product(), _bands());
        desk.listSeries(address(s), fp, type(uint128).max);
        _buy(alice, 1_000e6, 0);
        for (uint256 i = 1; i < 64; i++) {
            PerpTerms memory t = _terms(first);
            t.couponReserve = uint64(100 * i); // another series on the same feed
            PerpSeries si = _create(t);
            desk.listSeries(address(si), fp, type(uint128).max);
            uint256 q;
            (q,,) = desk.quote(address(si), IPerpDesk.Side.BuyNote, 1_000e6, 0);
            usdc.mint(alice, q);
            vm.startPrank(alice);
            usdc.approve(address(desk), q);
            desk.buy(address(si), 1_000e6, q, 0, integrator, alice);
            vm.stopPrank();
        }
        assertEq(desk.heldSeries().length, 64);
        // 64 holders to redeem later
        for (uint256 i = 0; i < 64; i++) {
            _requestDeposit(address(uint160(0x50000 + i)), 100e6);
        }
        uint256 deposits = _dueAndSettle();
        emit log_named_uint("gas, keeper update: 64 held series, 64 deposits", deposits);
        assertEq(desk.pendingDepositAssets(), 0);
        // both queues full: 64 new depositors, 64 redemptions
        for (uint256 i = 0; i < 64; i++) {
            address a = address(uint160(0x50000 + i));
            _requestRedeem(a, desk.balanceOf(a));
            _requestDeposit(address(uint160(0x60000 + i)), 100e6);
        }
        uint256 both = _dueAndSettle();
        emit log_named_uint("gas, keeper update: 64 held series, 64 deposits and 64 redemptions", both);
        assertEq(desk.queuedShares(), 0);
        assertEq(desk.pendingDepositAssets(), 0);
        vm.warp(block.timestamp + UPDATE_GAP);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        emit log_named_uint("gas, keeper update: 64 held series, nothing due", _keeperGas(VOL, CARRY));
        assertLt(both, WORST_CASE_GAS);
    }

    uint256 internal constant WORST_CASE_GAS = 16_000_000; // half of Arbitrum's block gas limit
}
