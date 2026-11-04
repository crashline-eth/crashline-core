// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {console2} from "forge-std/console2.sol";
import {PerpDeskFixture} from "./PerpDeskFixture.t.sol";
import {MockChainlinkFeed} from "./mocks/MockChainlinkFeed.sol";
import {PerpFormulaPricer} from "../src/PerpFormulaPricer.sol";
import {PerpSeries} from "../src/PerpSeries.sol";
import {IPerpDesk} from "../src/interfaces/IPerpDesk.sol";
import {IDeskQueue} from "../src/interfaces/IDeskQueue.sol";

/// Front-running the market keeper (#45): a simulation.
///
/// The world: the fixture's ETH series priced by the launch's formula pricer, 1,000,000 USDC of
/// honest LP money, and a Desk that sold 1,000,000 NOTE (it holds that much COVER, worth about a
/// fifth of the vault: the share price moves about 0.55% per vol point at the start, more than
/// the design note's 0.2%). Minute by minute:
///  - the market's vol (the options market's, public) walks 40 bps an hour and jumps once, at J (2 to 3 hours
///    in): +30 points in UP (the keeper's six capped steps are over before a request made after
///    the jump falls due: DELAY alone holds there), +60 points in UP60 (twelve steps, two hours:
///    requests fall due during the catch-up, and atBound is what holds), -20 points in DOWN;
///  - the true spot walks 0.7% an hour; Chainlink publishes it at a 0.05% deviation or after
///    its 1,755 s heartbeat, a minute late at most;
///  - the market keeper follows the launch's rules: a write on every whole hour and whenever
///    the vol moved 2 points from the mark, at most 5 points at a time, 10 minutes apart; every
///    keeper write tries to settle the due LP requests. In DOWN the operator's Safe also writes
///    the market's vol 5 minutes after the jump (an owner write: unbounded, public in advance,
///    never settles, and no settlement price until the keeper's next write of the feed).
/// The attackers know all of it: the market at every minute, the keeper's rules, the Safe's
/// proposal. At J + o, for request offsets o from 0 to 3,600 s (one attacker each, plus the two
/// whose due time falls 1 s before and exactly on a scheduled write), each makes a round trip
/// of 50,000 USDC: in UP a deposit before the up-steps the keeper still has to make, redeemed as
/// soon as it is filled; in DOWN a redemption of shares held from the start before the
/// down-steps, re-deposited as soon as it is paid. While a request waits, the attacker tries
/// to cancel it after every keeper write (an option on the steps it sees coming): it must
/// revert CancelTooEarly. Once its first request is due, before the keeper's update, it tries
/// to have it settled some other way, at the stale mark: trades that add to and shrink the
/// Desk's position, collect, processQueue (gone): the request must still wait (all of it in a
/// snapshot, so the world isn't changed).
///
/// The edge of a round trip is its gain over doing nothing, in bps: deposit-first, (USDC out -
/// in) / in; redeem-first, (shares after - before) / before. The instant model is what the same
/// attacker gets with ERC-4626 flows at the mark of the moment (the code this replaced): in at the
/// mark at J + o, out right after the first write that isn't at the step limit, both read with
/// convertToAssets. The delayed edges are averaged over two antithetic branches from J: the vol
/// and spot noise after the jump as drawn, and mirrored (the decision at J + o is the same in
/// both), which cancels the noise the attacker can't foresee. The honest LP's value is compared
/// with a run where the attackers stay passive.
///
/// Two deterministic scenarios follow, for the two rules no random one needs: a second held
/// coin written late (cutoff) and the Safe's mistaken write (owner writes never settle, and
/// their values are no settlement price).
contract PerpDeskFrontRunTest is PerpDeskFixture {
    uint256 internal constant STEP = 60;
    int256 internal constant VOL_SIGMA = 5164; // 40 bps an hour, per minute, in 1e-3 bps
    int256 internal constant SPOT_SIGMA = 904; // 0.7% an hour, per minute, in 1e-6
    int256 internal constant DEVIATION = 5; // Chainlink's 0.05%, in bps
    uint256 internal constant HEARTBEAT = 1755;
    int256 internal constant TRIGGER = 200; // the keeper writes when vol moved 2 points
    uint256 internal constant POSITION = 1_000_000e6;
    uint256 internal constant STAKE = 50_000e6;
    uint256 internal constant SEEDS = 8;
    uint256 internal constant HORIZON = 6 hours; // after J: every round trip is done by then

    /// The world's state, minute by minute.
    struct Path {
        uint256 seed;
        bool up;
        int256 jump; // the market's vol jump at J, 1e-3 bps
        uint256 start;
        uint256 j;
        int256 sign; // the noise after J: +1 or -1
        int256 vol; // the market's vol, 1e-3 bps
        int256 spot; // the true spot, 1e18 = INITIAL
        int256 answer; // Chainlink's last answer, 8 decimals
        uint256 roundAt;
        bool attack; // the attackers act (else they stay passive)
    }

    struct Attacker {
        address who;
        uint256 at; // request time
        uint8 phase; // 0 waiting, 1 first request pending, 2 second pending, 3 done
        uint256 id;
        uint256 shares0;
        uint256 pR; // the share price at the request
        bool instantDone;
        int256 instantE8; // the instant model's edge, 1e-8
        int256 edgeE8; // the delayed edge, 1e-8
        uint256 cancelTries;
        bool otherWaysTried;
    }

    Path internal p;
    Attacker[] internal atk;
    uint256 internal cancelsThrough; // cancels that went through: must stay 0
    int256 internal sensE8; // the share price's move per vol point, 1e-8

    // --- the world ----------------------------------------------------------------------------

    function setUp() public override {
        super.setUp();
        desk.listSeries(address(s), new PerpFormulaPricer(pricer.product(), _bands()), type(uint128).max);
        _buy(alice, POSITION, 0); // the Desk holds 1,000,000 COVER
        uint256 p0 = _pps();
        uint256 snap = vm.snapshotState();
        _market(VOL + 100, CARRY);
        uint256 p1 = _pps();
        vm.revertToStateAndDelete(snap);
        sensE8 = _bpsE8(p1, p0);
    }

    /// A normal draw (the sum of four uniforms, scaled), 1e6 = 1.
    function _z(uint256 seed, bytes32 tag, uint256 k) internal pure returns (int256 z) {
        uint256 r = uint256(keccak256(abi.encode(seed, tag, k)));
        int256 sum = 0;
        for (uint256 i = 0; i < 4; i++) {
            sum += int256((r >> (64 * i)) & 0xffffffff);
        }
        // (sum / 2^32 - 2) * sqrt(3), in 1e6
        z = (sum * 1e6 / int256(1 << 32) - 2e6) * 1_732_051 / 1e6;
    }

    function _pps() internal view returns (uint256) {
        return desk.convertToAssets(1e18);
    }

    function _bpsE8(uint256 a, uint256 b) internal pure returns (int256) {
        return (int256(a) - int256(b)) * 1e8 / int256(b);
    }

    /// One minute: the market moves (the noise mirrored after J in the - branch; the jump at
    /// J), Chainlink publishes, the Safe corrects (DOWN), the attackers request, the keeper
    /// writes and settles, the attackers look at their requests.
    function _minute() internal {
        vm.warp(block.timestamp + STEP);
        uint256 k = (block.timestamp - p.start) / STEP;
        int256 sign = block.timestamp >= p.j ? p.sign : int256(1);
        p.vol += sign * _z(p.seed, "vol", k) * VOL_SIGMA / 1e6;
        p.spot += p.spot * sign * _z(p.seed, "spot", k) * SPOT_SIGMA / 1e12;
        if (block.timestamp == p.j) p.vol += p.jump;
        int256 price = p.spot * int256(uint256(INITIAL)) / 1e18;
        int256 moved = price > p.answer ? price - p.answer : p.answer - price;
        if (moved * 10_000 >= DEVIATION * p.answer || block.timestamp >= p.roundAt + HEARTBEAT) {
            feed.pushRoundAt(price, uint40(block.timestamp));
            (p.answer, p.roundAt) = (price, block.timestamp);
        }
        bool safe = false;
        if (!p.up && block.timestamp == p.j + 5 minutes) {
            _market(_target(), CARRY); // the Safe's correction: an owner write
            safe = true;
        }
        if (p.attack) {
            _request();
            _otherWays();
        }
        bool keeperWrote = _keeperJob(); // not in the Safe's minute: minUpdateGap
        if (safe || keeperWrote) _look(safe && !keeperWrote);
    }

    function _target() internal view returns (uint16) {
        return uint16(uint256((p.vol + 500) / 1000));
    }

    /// The keeper's rules: every whole hour, and whenever the vol moved 2 points from the mark;
    /// at most 5 points a write, 10 minutes apart.
    function _keeperJob() internal returns (bool) {
        (uint16 mark,,, uint40 writtenAt,) = desk.market(address(feed));
        if (block.timestamp < uint256(writtenAt) + UPDATE_GAP) return false;
        int256 diff = int256(uint256(_target())) - int256(uint256(mark));
        bool scheduled = (block.timestamp - p.start) % 1 hours == 0;
        if (!scheduled && diff < TRIGGER && diff > -TRIGGER) return false;
        int256 step = diff > int256(uint256(VOL_STEP)) ? int256(uint256(VOL_STEP)) : diff;
        if (step < -int256(uint256(VOL_STEP))) step = -int256(uint256(VOL_STEP));
        vm.prank(keeper);
        desk.setMarkets(
            _upd(address(feed), uint16(uint256(int256(uint256(mark)) + step)), CARRY, uint40(block.timestamp), SOURCE)
        );
        return true;
    }

    function _run(uint256 until) internal {
        while (block.timestamp < until) {
            _minute();
        }
    }

    // --- the attackers ------------------------------------------------------------------------

    function _request() internal {
        for (uint256 i = 0; i < atk.length; i++) {
            Attacker storage a = atk[i];
            if (a.phase != 0 || block.timestamp < a.at) continue;
            a.pR = _pps();
            if (p.up) {
                a.id = _requestDeposit(a.who, STAKE);
            } else {
                a.shares0 = desk.balanceOf(a.who);
                a.id = _requestRedeem(a.who, a.shares0);
            }
            a.phase = 1;
        }
    }

    /// After a write: the instant model's exit, fills, the next leg, and a cancel attempt on
    /// what still waits. The instant model exits after the first write not at the step limit:
    /// an owner write sets atBound too (no settlement price), but it is no capped step.
    function _look(bool byOwner) internal {
        (,,,, bool atBound) = desk.market(address(feed));
        bool atLimit = atBound && !byOwner;
        for (uint256 i = 0; i < atk.length; i++) {
            Attacker storage a = atk[i];
            if (a.phase == 0 || a.phase == 3) continue;
            if (!a.instantDone && !atLimit) {
                uint256 pX = _pps();
                a.instantE8 = p.up ? _bpsE8(pX, a.pR) : _bpsE8(a.pR, pX);
                a.instantDone = true;
            }
            bool isDeposit = p.up == (a.phase == 1);
            uint256 rest;
            if (isDeposit) (,, rest) = desk.depositRequest(a.id);
            else (,, rest) = desk.redeemRequest(a.id);
            if (rest != 0) {
                _tryCancel(a, isDeposit);
                continue;
            }
            if (a.phase == 1 && p.up) {
                a.id = _requestRedeem(a.who, desk.balanceOf(a.who));
                a.phase = 2;
            } else if (a.phase == 1) {
                vm.prank(a.who);
                uint256 cash = desk.claim(a.who);
                vm.startPrank(a.who);
                usdc.approve(address(desk), cash);
                a.id = desk.requestDeposit(cash);
                vm.stopPrank();
                a.phase = 2;
            } else if (p.up) {
                vm.prank(a.who);
                uint256 out = desk.claim(a.who);
                a.edgeE8 = _bpsE8(out, STAKE);
                a.phase = 3;
            } else {
                a.edgeE8 = _bpsE8(desk.balanceOf(a.who), a.shares0);
                a.phase = 3;
            }
        }
    }

    /// A due request, before the keeper's update: no trade, collect or processQueue settles it
    /// at the stale mark. In a snapshot: the world goes on as if nothing was tried.
    function _otherWays() internal {
        for (uint256 i = 0; i < atk.length; i++) {
            Attacker storage a = atk[i];
            if (a.phase != 1 || a.otherWaysTried || block.timestamp < a.at + DELAY) continue;
            a.otherWaysTried = true;
            uint256 snap = vm.snapshotState();
            _buy(a.who, 1_000e6, 0); // adds to the Desk's COVER
            _sell(a.who, 1_000e6, 0); // and back
            _buyCover(a.who, 1_000e6, 0); // from the Desk's COVER: shrinks it
            desk.collect(address(s));
            (bool ok,) = address(desk).call(abi.encodeWithSignature("processQueue(uint256)", 64));
            assertFalse(ok, "processQueue exists");
            uint256 rest;
            if (p.up) (,, rest) = desk.depositRequest(a.id);
            else (,, rest) = desk.redeemRequest(a.id);
            assertGt(rest, 0, "a request settled outside the keeper's update");
            vm.revertToStateAndDelete(snap);
        }
    }

    /// A binding request is no option: cancelling it before STALL past due reverts.
    function _tryCancel(Attacker storage a, bool isDeposit) internal {
        a.cancelTries++;
        vm.prank(a.who);
        if (isDeposit) {
            try desk.cancelDeposit(a.id) {
                cancelsThrough++;
            } catch (bytes memory err) {
                assertEq(bytes4(err), IDeskQueue.CancelTooEarly.selector);
            }
        } else {
            try desk.cancelRedeem(a.id) {
                cancelsThrough++;
            } catch (bytes memory err) {
                assertEq(bytes4(err), IDeskQueue.CancelTooEarly.selector);
            }
        }
    }

    /// The request offsets: every 5 minutes from 0 to 3,600 s, the minute after the jump, the
    /// last minute of the keeper's gap and the first after it, the last before a whole hour,
    /// and the two whose due time is 1 s before (rounded to the minute: the minute before) and
    /// exactly on a scheduled write.
    function _offsets(uint256 jMinute) internal pure returns (uint256[18] memory o) {
        for (uint256 i = 0; i <= 12; i++) {
            o[i] = i * 300;
        }
        o[13] = 60;
        o[14] = 540;
        o[15] = 660;
        o[16] = 3600 - jMinute * 60 - 60; // due a minute before the scheduled write 2 hours after J's hour
        o[17] = 3600 - jMinute * 60; // due on it
    }

    // --- the runs -------------------------------------------------------------------------------

    struct Result {
        int256[] delayed; // per attacker, the antithetic average, 1e-8
        int256[] plus; // the + branch alone
        int256[] instant; // the + branch's instant model
        uint256[] offset;
        int256 honestDiff; // the honest LP's value, attack - passive, summed over the runs (base units)
        int256 zeroSum; // the worst |honest LP's difference + the attackers' gain| of a run: rounding
        uint256 flows; // the attackers' stakes, summed over the runs
        uint256 cancelTries;
    }

    /// What the attackers hold: USDC and the value of their shares.
    function _attackersValue() internal view returns (int256 v) {
        for (uint256 i = 0; i < atk.length; i++) {
            v += int256(usdc.balanceOf(atk[i].who) + desk.convertToAssets(desk.balanceOf(atk[i].who)));
        }
    }

    /// One seed of one scenario: the history to J (shared), then four runs from a snapshot: the
    /// attack and the passive run, in each branch. Only the honest LP and the attackers hold
    /// shares, so what the attackers gain the honest LP loses, to the base unit of rounding.
    function _seed(uint256 seed, bool up, int256 jump, Result memory r, uint256 base) internal {
        uint256 jMinute = uint256(keccak256(abi.encode(seed, "J"))) % 60;
        p = Path({
            seed: seed,
            up: up,
            jump: jump,
            start: block.timestamp,
            j: block.timestamp + 2 hours + jMinute * 60,
            sign: 1,
            vol: int256(uint256(VOL)) * 1000,
            spot: 0.9e18,
            answer: _price(9000),
            roundAt: block.timestamp,
            attack: false
        });
        delete atk;
        uint256[18] memory o = _offsets(jMinute);
        for (uint256 i = 0; i < o.length; i++) {
            address who = makeAddr(string.concat("attacker", vm.toString(i)));
            atk.push(Attacker(who, p.j + o[i], 0, 0, 0, 0, false, 0, 0, 0, false));
            r.offset[base + i] = o[i];
            // DOWN: the attackers hold shares from the start, like any LP
            if (!up) _requestDeposit(who, STAKE);
        }
        _run(p.j - STEP);
        uint256 snap = vm.snapshotState();
        for (uint256 b = 0; b < 2; b++) {
            int256 sign = b == 0 ? int256(1) : int256(-1);
            // the attack
            p.sign = sign;
            p.attack = true;
            _run(p.j + HORIZON);
            int256 honest = int256(desk.convertToAssets(desk.balanceOf(lp)));
            int256 gain = _attackersValue() - (up ? int256(o.length * STAKE) : int256(0)); // UP: minted at J + o
            for (uint256 i = 0; i < o.length; i++) {
                Attacker storage a = atk[i];
                assertEq(a.phase, 3, "a round trip did not finish");
                r.delayed[base + i] += a.edgeE8;
                if (b == 0) {
                    r.plus[base + i] = a.edgeE8;
                    r.instant[base + i] = a.instantE8;
                }
                r.cancelTries += a.cancelTries;
            }
            assertEq(cancelsThrough, 0, "a cancel went through");
            vm.revertToState(snap);
            // passive
            p.sign = sign;
            p.attack = false;
            _run(p.j + HORIZON);
            honest -= int256(desk.convertToAssets(desk.balanceOf(lp)));
            gain -= _attackersValue();
            r.honestDiff += honest;
            r.flows += o.length * STAKE;
            if (_abs(honest + gain) > r.zeroSum) r.zeroSum = _abs(honest + gain);
            vm.revertToState(snap);
        }
        vm.revertToStateAndDelete(snap);
        for (uint256 i = 0; i < o.length; i++) {
            r.delayed[base + i] /= 2;
        }
    }

    function _abs(int256 x) internal pure returns (int256) {
        return x < 0 ? -x : x;
    }

    function _scenario(bool up, int256 jumpBps) internal returns (Result memory r) {
        vm.pauseGasMetering(); // 64 runs of 6 simulated hours: billions of gas, not one transaction
        uint256 n = SEEDS * 18;
        r.delayed = new int256[](n);
        r.plus = new int256[](n);
        r.instant = new int256[](n);
        r.offset = new uint256[](n);
        uint256 world = vm.snapshotState();
        for (uint256 seed = 0; seed < SEEDS; seed++) {
            _seed(seed, up, jumpBps * 1000, r, seed * 18);
            vm.revertToState(world);
        }
        vm.revertToStateAndDelete(world);
        // zero-sum to the rounding of a few hundred fills and conversions
        assertLe(r.zeroSum, 1000, "the attackers' gain is not the honest LP's loss");
        // the honest LP's mean loss: at most 1 bp of the attackers' flows
        assertGe(r.honestDiff * 1e4, -int256(r.flows), "the honest LP lost more than 1 bp of the attackers' flows");
    }

    // --- the report -------------------------------------------------------------------------------

    /// x in 1e-8 as bps with two decimals.
    function _fmt(int256 e8) internal pure returns (string memory) {
        int256 c = e8 / 100; // hundredths of a bp
        string memory sign = c < 0 ? "-" : "";
        uint256 u = uint256(c < 0 ? -c : c);
        string memory frac = vm.toString(u % 100);
        if (u % 100 < 10) frac = string.concat("0", frac);
        return string.concat(sign, vm.toString(u / 100), ".", frac);
    }

    struct Stats {
        int256 mean;
        int256 min;
        int256 max;
        uint256 n;
    }

    function _stats(int256[] memory xs, uint256[] memory offset, uint256 lo, uint256 hi)
        internal
        pure
        returns (Stats memory st)
    {
        st.min = type(int256).max;
        st.max = type(int256).min;
        int256 sum = 0;
        for (uint256 i = 0; i < xs.length; i++) {
            if (offset[i] < lo || offset[i] > hi) continue;
            sum += xs[i];
            st.n++;
            if (xs[i] < st.min) st.min = xs[i];
            if (xs[i] > st.max) st.max = xs[i];
        }
        st.mean = st.n == 0 ? int256(0) : sum / int256(st.n);
    }

    function _row(string memory name, Result memory r, uint256 lo, uint256 hi) internal pure {
        Stats memory i = _stats(r.instant, r.offset, lo, hi);
        Stats memory d = _stats(r.delayed, r.offset, lo, hi);
        Stats memory b = _stats(r.plus, r.offset, lo, hi);
        console2.log(
            string.concat(
                "| ",
                name,
                " | ",
                vm.toString(d.n),
                " | ",
                _fmt(i.mean),
                " (",
                _fmt(i.min),
                " .. ",
                _fmt(i.max),
                ") | ",
                _fmt(d.mean),
                " (",
                _fmt(d.min),
                " .. ",
                _fmt(d.max),
                ") | ",
                _fmt(b.mean),
                " |"
            )
        );
    }

    function _report(string memory scenario, Result memory r) internal view returns (Stats memory all) {
        console2.log(scenario);
        console2.log(string.concat("the share price per vol point at the start: ", _fmt(sensE8), " bps"));
        console2.log(
            "| request offset after J | round trips | instant model: mean (min .. max), bps | delayed, antithetic: mean (min .. max), bps | delayed, + branch alone: mean, bps |"
        );
        _row("0 - 3,600 s (all)", r, 0, 3600);
        _row("0 - 240 s", r, 0, 240);
        _row("0 - 600 s", r, 0, 600);
        _row("660 - 1,800 s", r, 660, 1800);
        _row("2,100 - 3,600 s", r, 2100, 3600);
        all = _stats(r.delayed, r.offset, 0, 3600);
        int256 runs = int256(SEEDS * 2);
        console2.log(
            string.concat(
                "honest LP, attack - passive, mean of ",
                vm.toString(runs),
                " runs: ",
                vm.toString(r.honestDiff / runs),
                " base units = ",
                _fmt(r.honestDiff * 1e8 / int256(r.flows)),
                " bps of the attackers' flows; zero-sum with the attackers' gain to ",
                vm.toString(r.zeroSum),
                " base units"
            )
        );
        console2.log(
            string.concat("cancel attempts while waiting (all reverted CancelTooEarly): ", vm.toString(r.cancelTries))
        );
    }

    // --- the tests --------------------------------------------------------------------------------

    /// UP: vol jumps 30 points; the keeper catches up in six capped writes, 10 minutes apart. An
    /// instant deposit at the stale mark, out after the catch-up, takes the steps still to come
    /// from the honest LPs; a request settles only after the catch-up, at the new mark.
    function test_frontrun_the_keepers_catch_up_after_a_vol_jump() public {
        Result memory r = _scenario(true, 3000);
        Stats memory all = _report("UP: +30 vol points, deposit first, redeem when filled", r);
        Stats memory early = _stats(r.instant, r.offset, 0, 1800);
        assertGt(early.mean, 100e4, "the instant model shows no leak: the simulation detects nothing");
        assertLe(all.mean, 1e4, "the attacker's mean edge is more than 1 bp per round trip");
    }

    /// DOWN: vol falls 20 points; the keeper writes -5 at once, the operator's Safe writes the
    /// rest 5 minutes later (owner writes never settle). An instant redemption before the Safe's
    /// write dodges the step; a request settles after it, at the new mark.
    function test_frontrun_the_owners_correction_after_a_vol_drop() public {
        Result memory r = _scenario(false, -2000);
        Stats memory all =
            _report("DOWN: -20 vol points, the Safe's correction 5 min later, redeem first, re-deposit when paid", r);
        Stats memory early = _stats(r.instant, r.offset, 0, 240);
        assertGt(early.mean, 100e4, "the instant model shows no leak: the simulation detects nothing");
        assertLe(all.mean, 1e4, "the attacker's mean edge is more than 1 bp per round trip");
    }

    /// UP60: vol jumps 60 points; the keeper needs twelve capped writes, about two hours, to catch
    /// up: longer than DELAY, so the requests made in the first hour after the jump fall due while
    /// it is still stepping. Each capped write is fresh and comes after their due time: only
    /// atBound keeps them from settling at its mark, short of the market by the steps to come.
    function test_frontrun_a_catch_up_longer_than_the_delay() public {
        Result memory r = _scenario(true, 6000);
        Stats memory all = _report("UP60: +60 vol points, a catch-up longer than DELAY, deposit first", r);
        Stats memory early = _stats(r.instant, r.offset, 0, 1800);
        assertGt(early.mean, 100e4, "the instant model shows no leak: the simulation detects nothing");
        assertLe(all.mean, 1e4, "the attacker's mean edge is more than 1 bp per round trip");
    }

    // --- two deterministic scenarios: a feed written late, the Safe's mistake --------------------

    /// A second held coin: the Desk sold 1,000,000 BTC NOTE (it holds that much COVER), priced by
    /// the launch's BTC formula pricer at vol 45%, written now by the owner.
    function _btcHeld() internal returns (MockChainlinkFeed btc) {
        btc = new MockChainlinkFeed("BTC / USD");
        PerpSeries s2 = _create(_btcTerms(address(btc), first));
        btc.pushRoundAt(int256(uint256(INITIAL)), first);
        _recorder(s2).recordFixing(first, uint80(btc.latestRound()));
        btc.pushRoundAt(_price(9000), uint40(block.timestamp));
        desk.listSeries(address(s2), new PerpFormulaPricer(_btcProduct(), _btcBands()), type(uint128).max);
        _setMarket(address(btc), 4500, CARRY, uint40(block.timestamp), SOURCE);
        desk.setRiskBudget(address(btc), 10_000);
        (uint256 q,,) = desk.quote(address(s2), IPerpDesk.Side.BuyNote, POSITION, 0);
        usdc.mint(alice, q);
        vm.startPrank(alice);
        usdc.approve(address(desk), q);
        desk.buy(address(s2), POSITION, q, 0, integrator, alice);
        vm.stopPrank();
    }

    /// Time passes; fresh rounds on both feeds, at their levels.
    function _tick(MockChainlinkFeed btc, uint256 at) internal {
        vm.warp(at);
        feed.pushRoundAt(_price(9000), uint40(block.timestamp));
        if (address(btc) != address(0)) btc.pushRoundAt(_price(9000), uint40(block.timestamp));
    }

    function _keeperWrites(address f, uint16 vol) internal {
        vm.prank(keeper);
        desk.setMarkets(_upd(f, vol, CARRY, uint40(block.timestamp), SOURCE));
    }

    /// What a filled deposit is worth now, against what it paid: its edge, 1e-8.
    function _depositEdge(address who, uint256 id) internal view returns (int256) {
        (,, uint256 pending) = desk.depositRequest(id);
        assertEq(pending, 0, "the deposit did not settle");
        return _bpsE8(desk.convertToAssets(desk.balanceOf(who)), STAKE);
    }

    /// A FEED WRITTEN LATE: two held coins; BTC's vol rises 4.9 points just after both were
    /// written, and the keeper then writes ETH on time but BTC late. A deposit requested on
    /// seeing BTC's move falls due before BTC's next write. Here the owner's minUpdateGap is 90
    /// minutes, above DELAY: BTC's data from before the request is still fresh enough when ETH's
    /// write comes, and only cutoff (the oldest held feed's sourceTime) keeps the deposit waiting
    /// for BTC's write. (At the launch's 10 minutes, freshness alone keeps the data newer than any
    /// request it settles; cutoff guarantees it whatever the limits.)
    function test_frontrun_a_feed_written_late() public {
        MockChainlinkFeed btc = _btcHeld();
        desk.setMarketLimits(MARKET_AGE, VOL_STEP, CARRY_STEP, 90 minutes);
        uint256 t0 = block.timestamp; // both feeds written now
        address attacker = makeAddr("attacker");
        _tick(btc, t0 + 5 minutes); // BTC's vol: 45% -> 49.9%
        uint256 p0 = _pps();
        uint256 id = _requestDeposit(attacker, STAKE);
        // ETH on time: the deposit is due, BTC's data is from before it
        _tick(btc, t0 + 90 minutes);
        _keeperWrites(address(feed), VOL);
        (,, uint256 pending) = desk.depositRequest(id);
        assertEq(pending, STAKE, "settled at a feed written before the request");
        // BTC late, with the move
        _tick(btc, t0 + 95 minutes);
        _keeperWrites(address(btc), 4990);
        int256 edge = _depositEdge(attacker, id);
        int256 instant = _bpsE8(_pps(), p0);
        console2.log(
            string.concat("A FEED WRITTEN LATE: instant model ", _fmt(instant), " bps; delayed ", _fmt(edge), " bps")
        );
        assertGt(instant, 100e4, "the instant model shows no leak");
        assertLe(edge, 1e4, "the deposit's edge is more than 1 bp");
    }

    /// THE SAFE'S MISTAKE: a Safe transaction, public an hour before it executes, writes the vol
    /// 30 points too low (owner writes are unbounded); the Safe corrects it 15 minutes later. A
    /// deposit requested on seeing the proposal is due when it executes. If owner writes settled,
    /// it would be filled at the mistaken mark and gain the correction. They don't, an owner
    /// write sets atBound (its values are no settlement price until the keeper's own write of the
    /// feed), and the keeper's write in between steps at the limit (atBound): it settles at the
    /// keeper's write after the correction.
    function test_frontrun_the_safes_mistaken_write() public {
        address attacker = makeAddr("attacker");
        uint256 t0 = block.timestamp;
        uint256 id = _requestDeposit(attacker, STAKE); // the proposal is public
        _tick(MockChainlinkFeed(address(0)), t0 + 60 minutes);
        _market(VOL - 3000, CARRY); // executed: 30 points too low
        uint256 p0 = _pps();
        _tick(MockChainlinkFeed(address(0)), t0 + 70 minutes);
        _keeperWrites(address(feed), VOL - 2500); // toward the market, at the limit
        (,, uint256 pending) = desk.depositRequest(id);
        assertEq(pending, STAKE, "settled at the mistaken mark");
        _tick(MockChainlinkFeed(address(0)), t0 + 75 minutes);
        _market(VOL, CARRY); // the correction
        _tick(MockChainlinkFeed(address(0)), t0 + 85 minutes);
        _keeperWrites(address(feed), VOL);
        int256 edge = _depositEdge(attacker, id);
        int256 instant = _bpsE8(_pps(), p0);
        console2.log(
            string.concat("THE SAFE'S MISTAKE: instant model ", _fmt(instant), " bps; delayed ", _fmt(edge), " bps")
        );
        assertGt(instant, 100e4, "the instant model shows no leak");
        assertLe(edge, 1e4, "the deposit's edge is more than 1 bp");
    }
}
