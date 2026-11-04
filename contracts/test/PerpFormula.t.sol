// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {PerpMath} from "../src/PerpMath.sol";
import {PerpFormula} from "../src/PerpFormula.sol";

/// External entry points for the two libraries (reverts become catchable, gas measurable).
contract FormulaHarness {
    function expWad(int256 x) external pure returns (int256) {
        return PerpMath.expWad(x);
    }

    function lnWad(int256 x) external pure returns (int256) {
        return PerpMath.lnWad(x);
    }

    function principal(PerpFormula.World memory w, uint256 x, bool knockedIn) external pure returns (uint256) {
        return PerpFormula.principal(w, x, knockedIn);
    }

    function coefficients(PerpFormula.World memory w) external pure returns (PerpFormula.Coefficients memory) {
        return PerpFormula.coefficients(w);
    }

    function meltRate(uint256 a, uint256 dt) external pure returns (uint256) {
        return PerpFormula.meltRate(a, dt);
    }

    function coupon(uint256 a, int256 rho, uint256 dt, uint256 tau) external pure returns (uint256) {
        return PerpFormula.coupon(a, rho, dt, tau);
    }

    function gasOfPrincipal(PerpFormula.World memory w, uint256 x, bool knockedIn) external view returns (uint256) {
        uint256 g = gasleft();
        PerpFormula.principal(w, x, knockedIn);
        return g - gasleft();
    }
}

/// The closed form in fixed point: bit-exact against the integer twin
/// (tools/perp_formula.py), which is itself measured against a 50-digit
/// reference; plus the shape the formula must have, and its gas. The worlds:
/// the launch's (daily fixings, phi = 1/yr, discount 0, carry -20% to +50%; ETH
/// k 40%, BTC k 50%) and P1's weekly one (k 60%, drift 4%).
contract PerpFormulaTest is Test {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant DAILY_DT = uint256(86_400) * WAD / 31_536_000;
    FormulaHarness internal h;

    function setUp() public {
        h = new FormulaHarness();
    }

    function _json() internal view returns (string memory) {
        return vm.readFile(string.concat(vm.projectRoot(), "/test/vectors/perp_formula_vectors.json"));
    }

    /// A launch world at carry 4% (the reference points of docs/v2-spec.md §1).
    function _launch(uint256 k, uint256 sigma) internal pure returns (PerpFormula.World memory) {
        return _launch(k, sigma, 0.04e18);
    }

    /// A launch world: carry `r`, discount 0, phi = 1/yr at daily fixings, crash line `k`.
    function _launch(uint256 k, uint256 sigma, int256 r) internal pure returns (PerpFormula.World memory) {
        return PerpFormula.World({
            sigma: sigma, r: r, rho: 0, phi: PerpFormula.meltRate(2_735_976_403_140_715, DAILY_DT), k: k, dt: DAILY_DT
        });
    }

    /// The P1 world: drift 4%, discount 0, phi = 1/yr at weekly fixings, k 60%.
    function _p1(uint256 sigma) internal pure returns (PerpFormula.World memory) {
        return PerpFormula.World({
            sigma: sigma,
            r: 0.04e18,
            rho: 0,
            phi: PerpFormula.meltRate(18_995_352_771_274_247, uint256(604_800) * WAD / 31_536_000),
            k: 0.6e18,
            dt: uint256(604_800) * WAD / 31_536_000
        });
    }

    // --- vectors ------------------------------------------------------------------

    function test_math_vectors_exact() public view {
        string memory json = _json();
        int256[] memory x = vm.parseJsonIntArray(json, ".exp.x");
        int256[] memory y = vm.parseJsonIntArray(json, ".exp.y");
        assertGe(x.length, 16);
        for (uint256 i = 0; i < x.length; i++) {
            assertEq(h.expWad(x[i]), y[i], "exp");
        }
        x = vm.parseJsonIntArray(json, ".ln.x");
        y = vm.parseJsonIntArray(json, ".ln.y");
        assertGe(x.length, 14);
        for (uint256 i = 0; i < x.length; i++) {
            assertEq(h.lnWad(x[i]), y[i], "ln");
        }
    }

    struct Columns {
        uint256[] sigma;
        int256[] r;
        int256[] rho;
        uint256[] phi;
        uint256[] k;
        uint256[] dt;
    }

    function _worlds(string memory json, string memory key) internal pure returns (Columns memory c) {
        c.sigma = vm.parseJsonUintArray(json, string.concat(key, ".sigma"));
        c.r = vm.parseJsonIntArray(json, string.concat(key, ".r"));
        c.rho = vm.parseJsonIntArray(json, string.concat(key, ".rho"));
        c.phi = vm.parseJsonUintArray(json, string.concat(key, ".phi"));
        c.k = vm.parseJsonUintArray(json, string.concat(key, ".k"));
        c.dt = vm.parseJsonUintArray(json, string.concat(key, ".dt"));
    }

    function _world(Columns memory c, uint256 i) internal pure returns (PerpFormula.World memory) {
        return PerpFormula.World({sigma: c.sigma[i], r: c.r[i], rho: c.rho[i], phi: c.phi[i], k: c.k[i], dt: c.dt[i]});
    }

    /// Every vector, both states, bit for bit.
    function test_formula_vectors_exact() public view {
        string memory json = _json();
        Columns memory c = _worlds(json, ".formula");
        uint256[] memory x = vm.parseJsonUintArray(json, ".formula.x");
        uint256[] memory clean = vm.parseJsonUintArray(json, ".formula.clean");
        uint256[] memory knockedIn = vm.parseJsonUintArray(json, ".formula.knockedIn");
        assertEq(x.length, vm.parseJsonUint(json, ".count"));
        assertGe(x.length, 3000); // 1,764 in five weekly, monthly and daily worlds; 1,312 in the two launch worlds
        for (uint256 i = 0; i < x.length; i++) {
            PerpFormula.World memory w = _world(c, i);
            assertEq(h.principal(w, x[i], false), clean[i], vm.toString(i));
            assertEq(h.principal(w, x[i], true), knockedIn[i], vm.toString(i));
        }
    }

    function test_refused_worlds_revert() public {
        Columns memory c = _worlds(_json(), ".refused");
        assertGe(c.sigma.length, 5);
        for (uint256 i = 0; i < c.sigma.length; i++) {
            PerpFormula.World memory w = _world(c, i);
            vm.expectRevert(abi.encodeWithSelector(PerpFormula.VolOutOfRange.selector, w.sigma));
            h.principal(w, 0.9e18, false);
        }
    }

    function test_coupon_and_melt_rate_vectors() public view {
        string memory json = _json();
        uint256[] memory a = vm.parseJsonUintArray(json, ".coupon.a");
        int256[] memory rho = vm.parseJsonIntArray(json, ".coupon.rho");
        uint256[] memory dt = vm.parseJsonUintArray(json, ".coupon.dt");
        uint256[] memory tau = vm.parseJsonUintArray(json, ".coupon.tau");
        uint256[] memory value = vm.parseJsonUintArray(json, ".coupon.value");
        assertGe(a.length, 8);
        for (uint256 i = 0; i < a.length; i++) {
            assertEq(h.coupon(a[i], rho[i], dt[i], tau[i]), value[i], "coupon");
        }
        a = vm.parseJsonUintArray(json, ".meltRate.a");
        dt = vm.parseJsonUintArray(json, ".meltRate.dt");
        value = vm.parseJsonUintArray(json, ".meltRate.phi");
        assertGe(a.length, 6);
        for (uint256 i = 0; i < a.length; i++) {
            assertEq(h.meltRate(a[i], dt[i]), value[i], "melt rate");
        }
    }

    // --- the numbers a reader can check by hand -----------------------------------

    function test_p1_world_reference_values() public view {
        // phi of the P1 melt share at weekly fixings is 1 per year
        assertApproxEqAbs(_p1(0.55e18).phi, 1e18, 1000);
        PerpFormula.Coefficients memory c = h.coefficients(_p1(0.55e18));
        assertApproxEqRel(uint256(c.betaPlus), 2.9652e18, 1e14);
        assertApproxEqRel(uint256(-c.betaMinus), 2.2297e18, 1e14);
        assertApproxEqRel(uint256(c.top), 1.04537e18, 1e14); // e^(0.5826 * 0.55 * sqrt(7/365))
        assertEq(c.p0, 1e18); // discount 0: "pays 1" is worth 1
        assertApproxEqRel(uint256(c.alpha), uint256(1e18) * 100 / 96, 1e12); // phi / (phi - r)
        // the coupon reserve is worth its face at discount 0
        assertEq(h.coupon(18_995_352_771_274_247, 0, 0.019e18, 0.01e18), 1e18);
    }

    /// docs/v2-spec.md §1: at the high, carry 4%, ETH at 70% vol about 7,900 bps, BTC at 45% about 8,840.
    function test_launch_world_reference_values() public view {
        // phi of the launch melt share at daily fixings is 1 per year
        assertApproxEqAbs(_launch(0.4e18, 0.7e18).phi, 1e18, 10_000);
        PerpFormula.Coefficients memory c = h.coefficients(_launch(0.4e18, 0.7e18));
        assertApproxEqRel(uint256(c.betaPlus), 2.4815e18, 1e14);
        assertApproxEqRel(uint256(-c.betaMinus), 1.6448e18, 1e14);
        assertApproxEqRel(uint256(c.top), 1.021576e18, 1e14); // e^(0.5826 * 0.7 * sqrt(1/365))
        assertApproxEqRel(uint256(c.kPrime), 0.391552e18, 1e14); // k / top
        assertEq(c.p0, 1e18);
        assertApproxEqRel(uint256(c.alpha), uint256(1e18) * 100 / 96, 1e12);
        assertEq(_bps(h.principal(_launch(0.4e18, 0.7e18), 1e18, false)), 7904);
        assertEq(_bps(h.principal(_launch(0.5e18, 0.45e18), 1e18, false)), 8841);
        // a knocked-in note at the crash line: a little under the line itself
        assertEq(_bps(h.principal(_launch(0.4e18, 0.7e18), 0.4e18, true)), 3900);
        assertEq(_bps(h.principal(_launch(0.5e18, 0.45e18), 0.5e18, true)), 5059);
        // the coupon reserve is worth its face at discount 0 (0 at launch)
        assertEq(h.coupon(2_735_976_403_140_715, 0, DAILY_DT, DAILY_DT / 2), 1e18);
    }

    function _bps(uint256 wad) internal pure returns (uint256) {
        return (wad * 1e4 + WAD / 2) / WAD;
    }

    function test_regions() public view {
        _regions(_p1(0.55e18), 1e6);
        _regions(_launch(0.4e18, 0.2e18), 1e6);
        _regions(_launch(0.4e18, 0.7e18), 1e6);
        _regions(_launch(0.4e18, 1.5e18), 1e6);
        _regions(_launch(0.5e18, 0.45e18), 1e6);
        _regions(_launch(0.5e18, 1.2e18), 1e6);
        // the corners of the launch pricers' vol and carry ranges; at the lowest vol and the highest
        // carry (|beta-| about 18.3 for ETH at vol 24%, carry +50%) the branches meet to 4e-12, inside the 1e-6 bps the
        // formula is certified to (tools/perp_formula.py --check-launch)
        _regions(_launch(0.4e18, 0.24e18, -0.2e18), 1e6);
        _regions(_launch(0.4e18, 0.24e18, 0.5e18), 1e8);
        _regions(_launch(0.4e18, 1.5e18, -0.2e18), 1e6);
        _regions(_launch(0.4e18, 1.5e18, 0.5e18), 1e6);
        _regions(_launch(0.5e18, 0.21e18, -0.2e18), 1e6);
        _regions(_launch(0.5e18, 0.21e18, 0.5e18), 1e8);
        _regions(_launch(0.5e18, 1.2e18, -0.2e18), 1e6);
        _regions(_launch(0.5e18, 1.2e18, 0.5e18), 1e6);
    }

    /// `tol`: how far apart (1e-18 units) the two branches may be where they meet.
    function _regions(PerpFormula.World memory w, uint256 tol) internal view {
        PerpFormula.Coefficients memory c = h.coefficients(w);
        uint256 top = uint256(c.top);
        uint256 kPrime = uint256(c.kPrime);
        // at and above the ratchet both states are worth F0(top)
        uint256 atTop = h.principal(w, top, false);
        assertEq(h.principal(w, top, true), atTop);
        assertEq(h.principal(w, 3e18, false), atTop);
        assertEq(h.principal(w, 3e18, true), atTop);
        // a clean note below k' is priced as knocked in
        assertEq(h.principal(w, kPrime - 1, false), h.principal(w, kPrime - 1, true));
        assertEq(h.principal(w, 0.3e18, false), h.principal(w, 0.3e18, true));
        // the two branches meet at k' and at top (the boundary conditions), to rounding
        assertApproxEqAbs(h.principal(w, kPrime, false), h.principal(w, kPrime, true), tol);
        assertApproxEqAbs(h.principal(w, top - 1, true), atTop, tol);
        assertApproxEqAbs(h.principal(w, top - 1, false), atTop, tol);
        // x = 0: a knocked-in note on a worthless stock pays nothing
        assertEq(h.principal(w, 0, true), 0);
        assertEq(h.principal(w, 0, false), 0);
    }

    function test_bad_worlds_revert() public {
        PerpFormula.World memory w = _p1(0.55e18);
        w.sigma = 0.01e18 - 1;
        vm.expectRevert(abi.encodeWithSelector(PerpFormula.VolOutOfRange.selector, w.sigma));
        h.principal(w, 1e18, false);
        w.sigma = 3e18 + 1;
        vm.expectRevert(abi.encodeWithSelector(PerpFormula.VolOutOfRange.selector, w.sigma));
        h.principal(w, 1e18, false);

        w = _p1(0.55e18);
        w.k = 0;
        vm.expectRevert(PerpFormula.BadWorld.selector);
        h.principal(w, 1e18, false);
        w.k = 1e18 + 1;
        vm.expectRevert(PerpFormula.BadWorld.selector);
        h.principal(w, 1e18, false);
        w = _p1(0.55e18);
        w.dt = 0;
        vm.expectRevert(PerpFormula.BadWorld.selector);
        h.principal(w, 1e18, false);
        w = _p1(0.55e18);
        w.r = int256(w.phi); // drift at the melt rate: "pays x" has no finite value
        vm.expectRevert(PerpFormula.BadWorld.selector);
        h.principal(w, 1e18, false);
        w = _p1(0.55e18);
        w.rho = -int256(w.phi);
        vm.expectRevert(PerpFormula.BadWorld.selector);
        h.principal(w, 1e18, false);

        vm.expectRevert(PerpMath.LnNonPositive.selector);
        h.lnWad(0);
        vm.expectRevert(abi.encodeWithSelector(PerpMath.ExpOverflow.selector, int256(80e18 + 1)));
        h.expWad(80e18 + 1);
    }

    // --- shape (fuzz: the launch worlds and the P1 world at any certified vol) ---------------------------

    function testFuzz_exp_ln_roundtrip(uint256 x) public view {
        x = bound(x, 1e12, 100e18);
        int256 back = h.expWad(h.lnWad(int256(x)));
        assertApproxEqRel(uint256(back), x, 1e6); // 1e-12 relative
    }

    /// ETH (k 40%, vol 24-150%) or BTC (k 50%, vol 21-120%) on the launch terms, at any carry of
    /// the pricers' range (-20% to +50%).
    function _launchWorld(uint256 vol, int256 carry, bool btc) internal pure returns (PerpFormula.World memory) {
        int256 r = bound(carry, -0.2e18, 0.5e18);
        return btc ? _launch(0.5e18, bound(vol, 0.21e18, 1.2e18), r) : _launch(0.4e18, bound(vol, 0.24e18, 1.5e18), r);
    }

    function testFuzz_value_rises_with_spot(uint256 vol, int256 carry, uint256 x1, uint256 x2, bool knockedIn, bool btc)
        public
        view
    {
        _risesWithSpot(_launchWorld(vol, carry, btc), x1, x2, knockedIn);
    }

    function testFuzz_value_rises_with_spot_weekly(uint256 vol, uint256 x1, uint256 x2, bool knockedIn) public view {
        _risesWithSpot(_p1(bound(vol, 0.2e18, 0.9e18)), x1, x2, knockedIn);
    }

    function _risesWithSpot(PerpFormula.World memory w, uint256 x1, uint256 x2, bool knockedIn) internal view {
        x1 = bound(x1, 0.01e18, 1.3e18);
        x2 = bound(x2, x1, 1.3e18);
        // rounding can reverse the order by a few units of 1e-18
        assertGe(h.principal(w, x2, knockedIn) + 1e5, h.principal(w, x1, knockedIn));
    }

    function testFuzz_clean_is_worth_at_least_knocked_in(uint256 vol, int256 carry, uint256 x, bool btc) public view {
        _cleanAtLeastKnockedIn(_launchWorld(vol, carry, btc), x);
    }

    /// A higher carry is worth more to the NOTE: the spot drifts away from the crash line, and a
    /// knocked-in note's "pays x" is worth more.
    function testFuzz_value_rises_with_carry(uint256 vol, int256 c1, int256 c2, uint256 x, bool knockedIn, bool btc)
        public
        view
    {
        c1 = bound(c1, -0.2e18, 0.5e18);
        c2 = bound(c2, c1, 0.5e18);
        x = bound(x, 0.01e18, 1.3e18);
        PerpFormula.World memory w1 = _launchWorld(vol, c1, btc);
        PerpFormula.World memory w2 = _launchWorld(vol, c2, btc);
        assertGe(h.principal(w2, x, knockedIn) + 1e5, h.principal(w1, x, knockedIn));
    }

    function testFuzz_clean_is_worth_at_least_knocked_in_weekly(uint256 vol, uint256 x) public view {
        _cleanAtLeastKnockedIn(_p1(bound(vol, 0.2e18, 0.9e18)), x);
    }

    function _cleanAtLeastKnockedIn(PerpFormula.World memory w, uint256 x) internal view {
        x = bound(x, 0.01e18, 1.3e18);
        uint256 clean = h.principal(w, x, false);
        assertGe(clean + 1e5, h.principal(w, x, true));
        // the principal never exceeds "pays 1", its value at discount 0
        assertLe(clean, 1e18);
    }

    // --- gas ---------------------------------------------------------------------------

    function test_gas_of_one_price() public {
        PerpFormula.World memory w = _launch(0.4e18, 0.7e18);
        uint256 clean = h.gasOfPrincipal(w, 0.8e18, false);
        uint256 knockedIn = h.gasOfPrincipal(w, 0.8e18, true);
        uint256 aboveTop = h.gasOfPrincipal(w, 1.2e18, false);
        emit log_named_uint("gas, clean note (coefficients + 2 powers)", clean);
        emit log_named_uint("gas, knocked-in note (coefficients + 1 power)", knockedIn);
        emit log_named_uint("gas, at or above the ratchet (coefficients only)", aboveTop);
        assertLt(clean, 60_000);
        assertLt(h.gasOfPrincipal(_p1(0.55e18), 0.8e18, false), 60_000);
    }
}
