"""Integer twin of contracts/src/PerpMath.sol and PerpFormula.sol, and its vectors.

The closed-form price of the v2 perpetual note's principal (docs/v2-spec.md
section 6), computed exactly as the contract computes it: 1e18 fixed point,
every division truncating towards zero, the same series lengths. Plain Python
integers, so the result is bit-identical; contracts/test/PerpFormula.t.sol
replays the vectors and requires equality.

`--check` compares the integer result with a 50-digit reference (mpmath) over
a grid of worlds and states and prints the largest difference: this is the
"rounding of x^beta in fixed point" measurement of docs/v2-spec.md section 6.
It ends with the launch worlds (docs/v2-spec.md section 1: daily fixings, release
rate 1/yr, rho 0; ETH k 40% at vol 24-150%, BTC k 50% at vol 21-120%, both at
carry -20% to +50%): the whole rectangle of each pricer's certified vol and
carry ranges in 1% steps, both states, spots across the domain. `--check-launch`
runs only that part (on every core).

Usage: python tools/perp_formula.py [--out contracts/test/vectors/perp_formula_vectors.json]
                                    [--check | --check-launch]
"""

from __future__ import annotations

import argparse
import json
import math
from pathlib import Path

WAD = 10**18
BPS = 10_000
YEAR = 31_536_000
LN2 = 693_147_180_559_945_309
EXP_MIN = -41_446_531_673_892_822_312
EXP_MAX = 80 * WAD
BGK = 582_600_000_000_000_000
SIGMA_MIN = 10**16
SIGMA_MAX = 3 * WAD
BETA_MAX = 25 * WAD

MELT_WEEKLY = 18_995_352_771_274_247  # 1 - exp(-7/365)
MELT_DAILY = 2_735_976_403_140_715  # 1 - exp(-1/365), rounded: the launch's release rate 1/yr at daily fixings
WEEK = 604_800
DAY = 86_400


class Refused(ValueError):
    """The contract reverts (VolOutOfRange, BadWorld, ExpOverflow, LnNonPositive)."""


def sdiv(a: int, b: int) -> int:
    """Solidity's signed division: truncates towards zero."""
    q = abs(a) // abs(b)
    return q if (a < 0) == (b < 0) else -q


# --- PerpMath ----------------------------------------------------------------

def exp_wad(x: int) -> int:
    if x <= EXP_MIN:
        return 0
    if x > EXP_MAX:
        raise Refused("ExpOverflow")
    k = sdiv(x + LN2 // 2 if x >= 0 else x - LN2 // 2, LN2)
    r = x - k * LN2
    term = total = WAD
    for n in range(1, 17):
        term = sdiv(term * r, n * WAD)
        total += term
    return total << k if k >= 0 else total >> -k


def ln_wad(x: int) -> int:
    if x <= 0:
        raise Refused("LnNonPositive")
    k = x.bit_length() - 1 - 59
    y = x >> k if k >= 0 else x << -k
    z = sdiv((y - WAD) * WAD, y + WAD)
    z2 = z * z // WAD
    power = total = z
    for n in range(3, 34, 2):
        power = sdiv(power * z2, WAD)
        total += sdiv(power, n)
    return 2 * total + k * LN2


def sqrt_wad(x: int) -> int:
    return math.isqrt(x * WAD)


def pow_wad(ln_x: int, y: int) -> int:
    return exp_wad(sdiv(y * ln_x, WAD))


# --- PerpFormula ---------------------------------------------------------------

def coefficients(sigma: int, r: int, rho: int, phi: int, k: int, dt: int) -> dict:
    if not (SIGMA_MIN <= sigma <= SIGMA_MAX):
        raise Refused("VolOutOfRange")
    if phi > 100 * WAD or dt == 0 or dt > WAD:
        raise Refused("BadWorld")
    melt = rho + phi
    if melt <= 0 or melt <= r or k == 0 or k > WAD:
        raise Refused("BadWorld")
    s2 = sigma * sigma // WAD
    b = r - s2 // 2
    root = sqrt_wad(b * b // WAD + 2 * s2 * melt // WAD)
    c = {"betaPlus": sdiv((root - b) * WAD, s2), "betaMinus": sdiv(-(root + b) * WAD, s2)}
    if c["betaPlus"] > BETA_MAX or c["betaMinus"] < -BETA_MAX:
        raise Refused("VolOutOfRange")
    c["alpha"] = sdiv(phi * WAD, melt - r)
    c["p0"] = sdiv(phi * WAD, melt)
    c["lnTop"] = BGK * sigma // WAD * sqrt_wad(dt) // WAD
    c["top"] = exp_wad(c["lnTop"])
    c["kPrime"] = k * WAD // c["top"]
    ln_kappa = ln_wad(c["kPrime"]) - c["lnTop"]
    kappa_plus = pow_wad(ln_kappa, c["betaPlus"])
    kappa_minus = pow_wad(ln_kappa, c["betaMinus"])
    g_top = sdiv(c["alpha"] * c["top"], WAD) - c["p0"]
    g_k = sdiv(c["alpha"] * c["kPrime"], WAD) - c["p0"]
    c["b"] = sdiv((g_k - sdiv(g_top * kappa_plus, WAD)) * WAD, kappa_minus - kappa_plus)
    c["a"] = sdiv(-c["b"] * c["betaMinus"], c["betaPlus"])
    c["c"] = c["a"] - (g_top - c["b"])
    return c


def principal(c: dict, x: int, knocked_in: bool) -> int:
    if x >= c["top"]:
        v = c["p0"] + c["a"] + c["b"]
    elif x == 0:
        v = 0
    else:
        ln_u = ln_wad(x) - c["lnTop"]
        if knocked_in or x < c["kPrime"]:
            v = sdiv(c["alpha"] * x, WAD) + sdiv(c["c"] * pow_wad(ln_u, c["betaPlus"]), WAD)
        else:
            v = (c["p0"] + sdiv(c["a"] * pow_wad(ln_u, c["betaPlus"]), WAD)
                 + sdiv(c["b"] * pow_wad(ln_u, c["betaMinus"]), WAD))
    return max(v, 0)


def melt_rate(a: int, dt: int) -> int:
    return -ln_wad(WAD - a) * WAD // dt


def coupon(a: int, rho: int, dt: int, tau: int) -> int:
    if rho == 0:
        return WAD
    keep = sdiv((WAD - a) * exp_wad(sdiv(-rho * dt, WAD)), WAD)
    return sdiv(a * exp_wad(sdiv(-rho * tau, WAD)), WAD - keep)


# --- the quoter's assembly (PerpQuoter.sol; used by the quoter vectors' generator, not published) ---

def world_of(ki_bps: int, melt_share: int, interval: int, carry_bps: int, discount_bps: int, vol_bps: int):
    """(sigma, r, rho, phi, k, dt) in WAD from the series terms, the caller's carry (r) and vol,
    and the model's discount rate (rho)."""
    dt = interval * WAD // YEAR
    return (vol_bps * WAD // BPS, carry_bps * WAD // BPS, discount_bps * WAD // BPS,
            melt_rate(melt_share, dt), ki_bps * WAD // BPS, dt)


def round_bps(wad: int) -> int:
    """A non-negative WAD value in bps, rounded half up."""
    return (wad * BPS + WAD // 2) // WAD


# --- 50-digit reference ----------------------------------------------------------

def reference(sigma, r, rho, phi, k, dt, x, knocked_in):
    """The same formula in mpmath at 50 digits; arguments and result are mp numbers / floats."""
    return reference_at(reference_coefficients(sigma, r, rho, phi, k, dt), x, knocked_in)


def reference_coefficients(sigma, r, rho, phi, k, dt) -> dict:
    """The 50-digit world (mp numbers), computed once per world."""
    import mpmath as mp
    mp.mp.dps = 50
    sigma, r, rho, phi, k, dt = (mp.mpf(v) for v in (sigma, r, rho, phi, k, dt))
    s2 = sigma * sigma
    b = r - s2 / 2
    root = mp.sqrt(b * b + 2 * s2 * (rho + phi))
    bp, bm = (root - b) / s2, -(root + b) / s2
    alpha, p0 = phi / (rho + phi - r), phi / (rho + phi)
    top = mp.e ** (mp.mpf(BGK) / WAD * sigma * mp.sqrt(dt))
    kp = k / top
    kappa = kp / top
    g = lambda y: alpha * y - p0  # noqa: E731
    bq = (g(kp) - g(top) * kappa**bp) / (kappa**bm - kappa**bp)
    aq = -bq * bm / bp
    cq = aq - (g(top) - bq)
    return {"bp": bp, "bm": bm, "alpha": alpha, "p0": p0, "top": top, "kp": kp, "a": aq, "b": bq, "c": cq}


def reference_at(q: dict, x, knocked_in):
    import mpmath as mp
    mp.mp.dps = 50
    x = mp.mpf(x)
    if x >= q["top"]:
        v = q["p0"] + q["a"] + q["b"]
    elif x == 0:
        v = mp.mpf(0)
    else:
        u = x / q["top"]
        if knocked_in or x < q["kp"]:
            v = q["alpha"] * x + q["c"] * u ** q["bp"]
        else:
            v = q["p0"] + q["a"] * u ** q["bp"] + q["b"] * u ** q["bm"]
    return max(v, mp.mpf(0))


def check() -> None:
    import mpmath as mp
    mp.mp.dps = 50
    worst = (0, None)
    worst_fn = {"exp": 0, "ln": 0}
    for i in range(-4000, 801):
        x = i * WAD // 100
        err = abs(mp.mpf(exp_wad(x)) / WAD - mp.e ** (mp.mpf(x) / WAD)) / max(mp.e ** (mp.mpf(x) / WAD), 1)
        worst_fn["exp"] = max(worst_fn["exp"], float(err))
    for i in range(1, 3001):
        x = i * WAD // 1000
        err = abs(mp.mpf(ln_wad(x)) / WAD - mp.log(mp.mpf(x) / WAD))
        worst_fn["ln"] = max(worst_fn["ln"], float(err))
    print(f"exp_wad: max error {worst_fn['exp']:.2e} (relative above 1, absolute below), x in [-40, 8]")
    print(f"ln_wad:  max absolute error {worst_fn['ln']:.2e}, x in [0.001, 3]")
    n = refused = 0
    worst20 = 0
    lowest = {}
    for name, (r, rho, phi, dt) in WORLDS.items():
        for k_bps in (5000, 6000, 8000, 10_000):
            for vol in range(100, 15_001, 100):
                w = (vol * WAD // BPS, r, rho, phi, k_bps * WAD // BPS, dt)
                try:
                    c = coefficients(*w)
                except Refused:
                    refused += 1
                    continue
                lowest[name] = min(lowest.get(name, vol), vol)
                for x_bps in list(range(100, 13_001, 200)) + [1, k_bps - 1, k_bps, k_bps + 1, 9999, 10_000, 10_001]:
                    for ki in (False, True):
                        x = x_bps * WAD // BPS
                        got = principal(c, x, ki)
                        want = reference(*(mp.mpf(v) / WAD for v in w), mp.mpf(x) / WAD, ki)
                        err = abs(mp.mpf(got) / WAD - want)
                        n += 1
                        if err > worst[0]:
                            worst = (err, (name, k_bps, vol, x_bps, ki))
                        if vol >= 2000:
                            worst20 = max(worst20, err)
    print(f"principal: {n} states in {len(WORLDS)} worlds, k 50-100%, x 0.01%-130%, every vol 1-150% the "
          f"contract accepts ({refused} world/vol pairs refused; lowest accepted vol per world: "
          + ", ".join(f"{k} {v / 100:.0f}%" for k, v in lowest.items()) + ")")
    print(f"  max |fixed point - 50-digit| = {float(worst[0]) * 1e4:.2e} bps at {worst[1]}")
    print(f"  from 20% vol up: {float(worst20) * 1e4:.2e} bps")
    check_launch()


def _launch_worst(job):
    """The largest difference over one launch world (one asset, vol and carry): spots 0.5%-130%
    of the high in 0.5% steps plus the edges, both states. Returns (err in bps, where, states)."""
    import mpmath as mp
    mp.mp.dps = 50
    name, vol, carry = job
    k_bps = LAUNCH[name][0]
    rho, phi, dt = LAUNCH_WORLD
    w = (vol * WAD // BPS, carry * WAD // BPS, rho, phi, k_bps * WAD // BPS, dt)
    c = coefficients(*w)  # every point of the rectangle must be carried, not only the corners
    q = reference_coefficients(*(mp.mpf(v) / WAD for v in w))
    edges = [1, k_bps - 1001, k_bps - 1000, k_bps - 1, k_bps, k_bps + 1, k_bps + 1000, k_bps + 1001, 9499, 9500,
             9999, 10_000, 10_001, 10_500, 10_501, 15_000, 20_000, 65_535]
    xs = [b * WAD // BPS for b in list(range(50, 13_001, 50)) + edges]
    xs += [c["kPrime"] - 1, c["kPrime"], c["kPrime"] + 1, c["top"] - 1, c["top"], c["top"] + 1]
    worst = (0, (0.0, "-"))
    for x in xs:
        for ki in (False, True):
            err = abs(mp.mpf(principal(c, x, ki)) / WAD - reference_at(q, mp.mpf(x) / WAD, ki))
            if err > worst[0]:
                worst = (err, (x * BPS / WAD, "knocked in" if ki else "clean"))
    return float(worst[0]) * 1e4, (name, vol, carry) + worst[1], 2 * len(xs)


def check_launch() -> float:
    """The launch worlds: the whole rectangle of each pricer's vol and carry ranges in 1% steps
    (corners included), both states, spots 0.5%-130% of the high in 0.5% steps plus the edges
    (the crash line and its band, the high and its band, the formula's k' and top, spots far
    above the high). Returns the largest difference in bps."""
    from multiprocessing import Pool
    carry_min, carry_max = LAUNCH_CARRY
    worst_all = 0.0
    for name, (k_bps, vol_min, vol_max) in LAUNCH.items():
        jobs = [(name, vol, carry) for vol in range(vol_min, vol_max + 1, 100)
                for carry in range(carry_min, carry_max + 1, 100)]
        with Pool() as pool:
            results = pool.map(_launch_worst, jobs, chunksize=4)
        bps, where, _ = max(results, key=lambda r: r[0])
        n = sum(r[2] for r in results)
        worst_all = max(worst_all, bps)
        print(f"launch {name}: k {k_bps / 100:.0f}%, vol {vol_min / 100:.0f}-{vol_max / 100:.0f}% x carry "
              f"{carry_min / 100:+.0f}% to {carry_max / 100:+.0f}%, every 1% ({len(jobs)} worlds), daily, rho 0, "
              f"{n} states: max |fixed point - 50-digit| = {bps:.2e} bps at vol {where[1] / 100:.0f}%, carry "
              f"{where[2] / 100:+.0f}%, spot {where[3]:.4f} bps of the high, {where[4]}")
        # where the error grows: the worst world of each vol and of each carry
        by_vol, by_carry = {}, {}
        for b, (_, vol, carry, *_rest), _ in results:
            by_vol[vol] = max(by_vol.get(vol, 0.0), b)
            by_carry[carry] = max(by_carry.get(carry, 0.0), b)
        print("  worst per vol:   " + ", ".join(f"{v / 100:.0f}% {e:.1e}" for v, e in sorted(by_vol.items())
                                                 if v < vol_min + 500 or v % 1000 == 0))
        print("  worst per carry: " + ", ".join(f"{c / 100:+.0f}% {e:.1e}" for c, e in sorted(by_carry.items())
                                                 if c % 500 == 0 or c == 400 or c > carry_max - 500))
    return worst_all


# --- vectors -----------------------------------------------------------------------

WORLDS = {
    # name: (r, rho, phi, dt) in WAD
    "p1": (4 * WAD // 100, 0, None, WEEK * WAD // YEAR),  # phi from MELT_WEEKLY: model P1's world
    "doc": (4 * WAD // 100, 4 * WAD // 100, WAD, WAD // 52),  # the v2 design note's check table
    "zero_rates": (0, 0, WAD, WEEK * WAD // YEAR),
    "daily": (4 * WAD // 100, 0, WAD, 86_400 * WAD // YEAR),
    "fast_melt": (2 * WAD // 100, WAD // 100, 4 * WAD, WEEK * WAD // YEAR),
}
WORLDS["p1"] = (WORLDS["p1"][0], 0, melt_rate(MELT_WEEKLY, WEEK * WAD // YEAR), WORLDS["p1"][3])

# The launch (docs/v2-spec.md section 1): daily fixings, release rate 1/yr, rho 0; one PerpFormulaPricer
# per asset. (rho, phi, dt) in WAD; the carry r is an input, inside the pricers' carry range.
LAUNCH_WORLD = (0, melt_rate(MELT_DAILY, DAY * WAD // YEAR), DAY * WAD // YEAR)
LAUNCH = {
    # name: (k bps, vol min bps, vol max bps): the crash line and the pricer's vol range. The vol
    # minimums are raised from 2,000 for the carry corner: at vol 20% and carry +50% the closed form
    # refuses (|beta-| > 25), and ETH just above it is carried only to ~3e-5 bps.
    "eth": (4000, 2400, 15_000),
    "btc": (5000, 2100, 12_000),
}
LAUNCH_CARRY = (-2000, 5000)  # both pricers' carry range, bps a year
LAUNCH_CARRY_BPS = 400  # the carry of the reference points (docs/v2-spec.md section 1) and of the vectors' main grid


def make_vectors() -> dict:
    """Columns, not rows: forge reads each column with one parse call."""
    exp_x = [EXP_MIN, EXP_MIN + 1, -40 * WAD, -10 * WAD, -WAD, -1, 0, 1, WAD // 3, WAD, LN2 // 2, LN2 // 2 + 1,
             -LN2 // 2, 5 * WAD, 12_345_678_901_234_567_890, EXP_MAX]
    ln_x = [1, 1000, WAD // 1000, WAD // 2, 6 * WAD // 10, WAD - 1, WAD, WAD + 1, 2**59, 2**60 - 1, 2**60,
            13 * WAD // 10, 2 * WAD, 10**24]
    cols = {key: [] for key in ("sigma", "r", "rho", "phi", "k", "dt", "x", "clean", "knockedIn")}
    refused = {key: [] for key in ("sigma", "r", "rho", "phi", "k", "dt")}
    xs = [0, 1, 100, 2000, 4000, 5000, 5500, 5800, 5999, 6000, 6001, 6500, 7000, 8000, 9000, 9500, 9999, 10_000,
          10_001, 10_200, 10_500, 11_000, 13_000, 15_000]
    for name, (r, rho, phi, dt) in WORLDS.items():
        for k_bps in ((6000,) if name != "doc" else (5000, 6000, 8000, 10_000)):
            for vol in (500, 900, 2000, 3000, 5500, 8000, 9000, 15_000, 30_000):
                w = dict(sigma=vol * WAD // BPS, r=r, rho=rho, phi=phi, k=k_bps * WAD // BPS, dt=dt)
                try:
                    c = coefficients(**w)
                except Refused:
                    for key, v in w.items():
                        refused[key].append(str(v))
                    continue
                edge = [c["kPrime"] - 1, c["kPrime"], c["top"] - 1, c["top"]]
                for x in [b * WAD // BPS for b in xs] + edge:
                    for key, v in w.items():
                        cols[key].append(str(v))
                    cols["x"].append(str(x))
                    cols["clean"].append(str(principal(c, x, False)))
                    cols["knockedIn"].append(str(principal(c, x, True)))
    # the launch worlds: each asset's crash line, vols across its range and below it (where the
    # formula refuses), spots across the domain with the edges of the two bands, at carry 4%; then
    # both ends of the carry range and points inside it at both ends of the vol range and at 70%;
    # and the world the old vol minimum would have needed: vol 20% at carry +50%, refused (|beta-| > 25)
    rho, phi, dt = LAUNCH_WORLD
    carry_min, carry_max = LAUNCH_CARRY
    for k_bps, vol_min, vol_max in LAUNCH.values():
        lxs = sorted({0, 1, 100, 1000, 2000, k_bps - 1001, k_bps - 1000, k_bps - 1, k_bps, k_bps + 1, k_bps + 1000,
                      k_bps + 1001, 6000, 7000, 8000, 9000, 9499, 9500, 9999, 10_000, 10_001, 10_500, 10_501, 11_000,
                      13_000, 15_000, 65_535})
        worlds = [(vol, LAUNCH_CARRY_BPS) for vol in (500, 700, 800, 2000, vol_min, 3000, 4500, 5500, 7000, 9000,
                                                      12_000, vol_max) if vol <= vol_max]
        worlds += [(vol, carry) for carry in (carry_min, 0, 2000, carry_max) for vol in (vol_min, 7000, vol_max)]
        worlds.append((2000, carry_max))
        for vol, carry in dict.fromkeys(worlds):
            w = dict(sigma=vol * WAD // BPS, r=carry * WAD // BPS, rho=rho, phi=phi, k=k_bps * WAD // BPS, dt=dt)
            try:
                c = coefficients(**w)
            except Refused:
                for key, v in w.items():
                    refused[key].append(str(v))
                continue
            edge = [c["kPrime"] - 1, c["kPrime"], c["top"] - 1, c["top"]]
            for x in [b * WAD // BPS for b in lxs] + edge:
                for key, v in w.items():
                    cols[key].append(str(v))
                cols["x"].append(str(x))
                cols["clean"].append(str(principal(c, x, False)))
                cols["knockedIn"].append(str(principal(c, x, True)))
    coupons = [(MELT_WEEKLY, 0, WEEK * WAD // YEAR, 0),
               (MELT_WEEKLY, 4 * WAD // 100, WEEK * WAD // YEAR, 0),
               (MELT_WEEKLY, 4 * WAD // 100, WEEK * WAD // YEAR, WEEK * WAD // YEAR),
               (MELT_WEEKLY, 4 * WAD // 100, WEEK * WAD // YEAR, 3 * 86_400 * WAD // YEAR),
               (WAD // 2, 10 * WAD // 100, WAD // 12, WAD // 24),
               (1, 4 * WAD // 100, WAD // 52, 0),
               (MELT_DAILY, 0, DAY * WAD // YEAR, DAY * WAD // YEAR),
               (MELT_DAILY, 4 * WAD // 100, DAY * WAD // YEAR, DAY * WAD // YEAR // 2)]
    melts = [(MELT_WEEKLY, WEEK * WAD // YEAR), (114_148_735_678_798, 3600 * WAD // YEAR), (WAD // 2, WAD // 12),
             (1, WAD), (WAD - 1, WAD), (MELT_DAILY, DAY * WAD // YEAR)]
    strs = lambda values: [str(v) for v in values]  # noqa: E731
    return {
        "exp": {"x": strs(exp_x), "y": strs(exp_wad(x) for x in exp_x)},
        "ln": {"x": strs(ln_x), "y": strs(ln_wad(x) for x in ln_x)},
        "count": len(cols["x"]),
        "formula": cols,
        "refused": refused,
        "coupon": {"a": strs(c[0] for c in coupons), "rho": strs(c[1] for c in coupons),
                   "dt": strs(c[2] for c in coupons), "tau": strs(c[3] for c in coupons),
                   "value": strs(coupon(*c) for c in coupons)},
        "meltRate": {"a": strs(m[0] for m in melts), "dt": strs(m[1] for m in melts),
                     "phi": strs(melt_rate(*m) for m in melts)},
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    root = Path(__file__).resolve().parent.parent
    ap.add_argument("--out", default=str(root / "contracts/test/vectors/perp_formula_vectors.json"))
    ap.add_argument("--check", action="store_true", help="compare with a 50-digit reference (needs mpmath)")
    ap.add_argument("--check-launch", action="store_true", help="only the launch worlds of --check")
    args = ap.parse_args()
    if args.check:
        check()
        return
    if args.check_launch:
        check_launch()
        return
    out = make_vectors()
    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    Path(args.out).write_text(json.dumps(out, indent=1) + "\n")
    print(f"wrote {len(out['exp']['x'])} exp and {len(out['ln']['x'])} ln vectors, {out['count']} formula vectors, "
          f"{len(out['refused']['sigma'])} refused worlds, {len(out['coupon']['a'])} coupon vectors and "
          f"{len(out['meltRate']['a'])} melt rates to {args.out}")
    # the P1 world at the doc's reference state, for the eye
    r, rho, phi, dt = WORLDS["p1"]
    c = coefficients(55 * WAD // 100, r, rho, phi, 6 * WAD // 10, dt)
    print(f"P1 world, vol 55%: beta+ {c['betaPlus'] / WAD:.4f}, beta- {c['betaMinus'] / WAD:.4f}, top "
          f"{c['top'] / WAD:.5f}, k' {c['kPrime'] / WAD:.5f}; principal at x = 1 clean "
          f"{principal(c, WAD, False) / WAD:.6f}, at x = 0.8 knocked in {principal(c, 8 * WAD // 10, True) / WAD:.6f}")
    # the launch at the high (docs/v2-spec.md section 1: carry 4%, ETH at 70% vol about 7,900 bps, BTC at
    # 45% about 8,840)
    rho, phi, dt = LAUNCH_WORLD
    for name, vol in (("eth", 7000), ("btc", 4500)):
        k_bps = LAUNCH[name][0]
        c = coefficients(vol * WAD // BPS, LAUNCH_CARRY_BPS * WAD // BPS, rho, phi, k_bps * WAD // BPS, dt)
        print(f"launch {name}, vol {vol / 100:.0f}%: principal at the high {round_bps(principal(c, WAD, False))} bps, "
              f"knocked in at the crash line {round_bps(principal(c, k_bps * WAD // BPS, True))} bps")


if __name__ == "__main__":
    main()
