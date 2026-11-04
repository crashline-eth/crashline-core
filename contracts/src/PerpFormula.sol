// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.24;

import {PerpMath} from "./PerpMath.sol";

/// Closed-form price of the v2 perpetual note's principal, per unit of live
/// notional (docs/v2-spec.md §6). The
/// coupon part of the note is exact and separate (`coupon`). World: constant
/// total vol sigma, risk-neutral drift r, payouts discounted at rho, the
/// notional melting at rate phi; continuous monitoring, shifted for fixings
/// every dt years (Broadie, Glasserman and Kou):
///
///   beta+-  = (-b +- sqrt(b^2 + 2 sigma^2 (rho + phi))) / sigma^2,   b = r - sigma^2 / 2
///   alpha   = phi / (rho + phi - r)       value of "pays x"
///   P0      = phi / (rho + phi)           value of "pays 1"
///   top     = e^(BGK sigma sqrt(dt)),  k' = k / top,  u = x / top,  kappa = k' / top
///   g(y)    = alpha y - P0
///   B'      = (g(k') - g(top) kappa^beta+) / (kappa^beta- - kappa^beta+)
///   D'      = g(top) - B',   A' = -B' beta- / beta+,   C' = A' - D'
///   clean        F0(x) = P0 + A' u^beta+ + B' u^beta-     k' <= x < top
///   knocked in   F1(x) = alpha x + C' u^beta+             x < top
///   x >= top:  F0(top) in either state;   clean and x < k':  F1(x)
///
/// The boundary conditions are F0'(top) = 0 (the ratchet reflects),
/// F0(k') = F1(k') (knock-in) and F0(top) = F1(top) (heal).
/// All values are 1e18 fixed point (WAD). tools/perp_formula.py is the
/// bit-exact integer twin; its --check compares it with a 50-digit reference.
///
/// Precision: kappa^beta- grows and kappa^beta+ vanishes as the exponents
/// grow (low vol, fast melt), and 18 digits run out. Worlds whose exponents
/// exceed BETA_MAX are refused; inside, the result is within 1e-6 bps of a
/// 50-digit reference (1e-11 bps from 20% vol up; `tools/perp_formula.py --check`).
library PerpFormula {
    int256 internal constant WAD = 1e18;
    int256 internal constant BGK = 582_600_000_000_000_000; // 0.5826 = -zeta(1/2) / sqrt(2 pi)
    uint256 internal constant SIGMA_MIN = 0.01e18;
    uint256 internal constant SIGMA_MAX = 3e18;
    int256 internal constant BETA_MAX = 25e18; // |beta+-| above it: 18 digits no longer carry the price

    struct World {
        uint256 sigma; // total annualized vol
        int256 r; // risk-neutral drift per year
        int256 rho; // discount rate of the payouts per year
        uint256 phi; // melt rate per year: -ln(1 - a) / dt
        uint256 k; // knock-in barrier as a fraction of the reference, 0 < k <= 1
        uint256 dt; // fixing interval in years
    }

    /// Everything that doesn't depend on x.
    struct Coefficients {
        int256 betaPlus;
        int256 betaMinus;
        int256 alpha;
        int256 p0;
        int256 lnTop;
        int256 top;
        int256 kPrime;
        int256 a; // A'
        int256 b; // B'
        int256 c; // C'
    }

    error VolOutOfRange(uint256 sigma); // outside SIGMA_MIN..SIGMA_MAX, or too low for this world (BETA_MAX)
    error BadWorld(); // rho + phi <= max(r, 0), k outside (0, 1], or dt == 0

    function coefficients(World memory w) internal pure returns (Coefficients memory c) {
        if (w.sigma < SIGMA_MIN || w.sigma > SIGMA_MAX) revert VolOutOfRange(w.sigma);
        // every cast below is of a value bounded by the checks around it
        // forge-lint: disable-start(unsafe-typecast)
        if (w.phi > uint256(100 * WAD) || w.dt == 0 || w.dt > uint256(WAD)) revert BadWorld();
        int256 phi = int256(w.phi);
        int256 melt = w.rho + phi; // discounting plus melting
        if (melt <= 0 || melt <= w.r || w.k == 0 || w.k > uint256(WAD)) revert BadWorld();
        int256 sigma = int256(w.sigma);
        // chained WAD products: each is divided by WAD before the next multiplication
        // forge-lint: disable-start(divide-before-multiply)
        int256 s2 = sigma * sigma / WAD;
        int256 b = w.r - s2 / 2;
        int256 root = int256(PerpMath.sqrtWad(uint256(b * b / WAD + 2 * s2 * melt / WAD)));
        c.betaPlus = (root - b) * WAD / s2;
        c.betaMinus = -(root + b) * WAD / s2;
        if (c.betaPlus > BETA_MAX || c.betaMinus < -BETA_MAX) revert VolOutOfRange(w.sigma);
        c.alpha = phi * WAD / (melt - w.r);
        c.p0 = phi * WAD / melt;
        c.lnTop = BGK * sigma / WAD * int256(PerpMath.sqrtWad(w.dt)) / WAD;
        // forge-lint: disable-end(divide-before-multiply)
        c.top = PerpMath.expWad(c.lnTop);
        c.kPrime = int256(w.k) * WAD / c.top;
        // forge-lint: disable-end(unsafe-typecast)

        int256 lnKappa = PerpMath.lnWad(c.kPrime) - c.lnTop;
        int256 kappaPlus = PerpMath.powWad(lnKappa, c.betaPlus);
        int256 kappaMinus = PerpMath.powWad(lnKappa, c.betaMinus);
        int256 gTop = c.alpha * c.top / WAD - c.p0;
        int256 gK = c.alpha * c.kPrime / WAD - c.p0;
        c.b = (gK - gTop * kappaPlus / WAD) * WAD / (kappaMinus - kappaPlus);
        c.a = -c.b * c.betaMinus / c.betaPlus;
        c.c = c.a - (gTop - c.b);
    }

    /// Value of the principal at x = spot / reference (WAD), floored at 0.
    function principal(Coefficients memory c, uint256 x, bool knockedIn) internal pure returns (uint256) {
        // forge-lint: disable-start(unsafe-typecast)
        int256 v;
        if (x >= uint256(c.top)) {
            v = c.p0 + c.a + c.b; // at or above the ratchet: F0(top)
        } else if (x == 0) {
            v = 0;
        } else {
            int256 lnU = PerpMath.lnWad(int256(x)) - c.lnTop;
            if (knockedIn || x < uint256(c.kPrime)) {
                v = c.alpha * int256(x) / WAD + c.c * PerpMath.powWad(lnU, c.betaPlus) / WAD;
            } else {
                v = c.p0 + c.a * PerpMath.powWad(lnU, c.betaPlus) / WAD + c.b * PerpMath.powWad(lnU, c.betaMinus) / WAD;
            }
        }
        return v > 0 ? uint256(v) : 0;
        // forge-lint: disable-end(unsafe-typecast)
    }

    function principal(World memory w, uint256 x, bool knockedIn) internal pure returns (uint256) {
        return principal(coefficients(w), x, knockedIn);
    }

    /// Melt rate per year of a melt share `a` (WAD) per fixing interval of `dt` years: -ln(1 - a) / dt.
    function meltRate(uint256 a, uint256 dt) internal pure returns (uint256) {
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint256(-PerpMath.lnWad(WAD - int256(a))) * 1e18 / dt; // 0 < a < 1e18: the log is negative
    }

    /// Value of the coupon stream per unit of reserve R: every fixing pays a * R of what is
    /// left, the next one in `tau` years:  a e^(-rho tau) / (1 - (1 - a) e^(-rho dt)).
    /// Exactly 1 at rho = 0: the reserve is worth its face.
    function coupon(uint256 a, int256 rho, uint256 dt, uint256 tau) internal pure returns (uint256) {
        if (rho == 0) return 1e18;
        // forge-lint: disable-start(unsafe-typecast)
        int256 keep = (WAD - int256(a)) * PerpMath.expWad(-rho * int256(dt) / WAD) / WAD;
        return uint256(int256(a) * PerpMath.expWad(-rho * int256(tau) / WAD) / (WAD - keep));
        // forge-lint: disable-end(unsafe-typecast)
    }
}
