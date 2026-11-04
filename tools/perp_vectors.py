"""Scalar reference of the v2 perpetual note's fixing rule, and its conformity vectors.

The rule (contracts/src/interfaces/IPerpSeries.sol, docs/v2-spec.md section 4):
  first fixing:  H = f
  fixing f:      1. f >= H          ->  H = f, knockedIn = False
                 2. else f < k * H  ->  knockedIn = True
                 3. m = floor(s * a / 1e18) of the live notional s melts and pays
                    NOTE   floor(m * (1 + R))       if clean
                           floor(m * (f / H + R))   if knocked in
                    COVER  the rest of floor(m * (1 + R))
  missed:        a fixing that was never recorded reuses the last one; the one that makes
                 the missed fixings in a row span the dead-feed duration
                 (missedInARow * interval >= CLOSE_AFTER_DEAD, 14 days) melts everything
                 (m = s) and closes: the 14th in a row at daily fixings, the 2nd at weekly,
                 the 336th at hourly

Plain integers only: barriers are exact cross-multiplications in bps, a is
1e18 fixed point, R is USDC base units per 1e6 of notional, s and the releases
are per token base unit in 1e27 fixed point. contracts/test/PerpVectors.t.sol
replays every vector through the PerpPayout library and through a live
PerpSeries (fixing every `interval` seconds) and requires exact equality at
every fixing.

The vectors: the weekly product P1 with a coupon reserve and a range of other
terms the factory accepts (weekly, hourly, daily; R from 0 to its maximum), then
the two launch worlds (docs/v2-spec.md section 1): ETH and BTC, daily fixings,
release rate 1/yr, crash line k 40% and 50%, R = 0, and last the dead-feed close
at intervals from an hour to 30 days (exactly at the missed fixing that spans
14 days, not one earlier, and a recorded fixing resets the count).

Usage: python tools/perp_vectors.py [--out contracts/test/vectors/perp_vectors.json]
"""

from __future__ import annotations

import argparse
import json
import random
from pathlib import Path

UNIT = 10**6
BPS = 10_000
WAD = 10**18
RAY = 10**27
MISSING = 0  # a fixing that was never recorded (the feed never answers 0)
HOUR = 3_600
DAY = 86_400
WEEK = 604_800
CLOSE_AFTER_DEAD = 14 * DAY  # PerpSeries.CLOSE_AFTER_DEAD: missed fixings in a row spanning this long close
PRICE_MAX = 10**15  # the v2 recorders' cap (DeployPerp.s.sol): $10M at 8 decimals

MELT_WEEKLY = 18_995_352_771_274_247  # 1 - exp(-7/365): phi = 1/yr, weekly fixings
MELT_DAILY = 2_735_976_403_140_715  # 1 - exp(-1/365), rounded: phi = 1/yr at daily fixings (the launch)
MELT_HOURLY = 114_148_735_678_798  # 1 - exp(-1/8760): phi = 1/yr at hourly fixings
PENDING, LIVE, CLOSED = 0, 1, 2

# the launch (docs/v2-spec.md section 1): name -> (k bps, annual vol of the random walks, first fixings)
LAUNCH = {
    "eth": (4000, 0.70, [387_245_000_000, 100 * 10**8]),  # $3,872.45, $100
    "btc": (5000, 0.45, [8_143_917_000_000, 1 * 10**8]),  # $81,439.17, $1
}


def misses_to_close(interval: int) -> int:
    """The missed fixing in a row that closes a series fixing every `interval` seconds:
    the first n with n * interval >= CLOSE_AFTER_DEAD."""
    return -(-CLOSE_AFTER_DEAD // interval)


def run(ki: int, a: int, coupon_reserve: int, first: int, fixings: list[int], interval: int) -> dict:
    """`first` is the fixing that sets H; fixings[n - 1] is fixing n = 1, 2, ...
    (MISSING = unrecorded past its fallback deadline), one every `interval`
    seconds. Fixings after the note closes are ignored. Returns the final
    state and the release of every processed fixing."""
    h = last = first
    knocked_in = False
    missed_in_a_row = 0
    s = RAY
    note_index = cover_index = 0
    phase = LIVE
    note_release, cover_release = [], []
    for fixing in fixings:
        if phase == CLOSED:
            break
        missed = fixing == MISSING
        if missed:
            fixing = last
        if fixing >= h:  # the ratchet, checked first
            h = fixing
            knocked_in = False
        elif fixing * BPS < ki * h:
            knocked_in = True
        last = fixing
        missed_in_a_row = missed_in_a_row + 1 if missed else 0
        close = missed_in_a_row * interval >= CLOSE_AFTER_DEAD
        m = s if close else s * a // WAD
        total = m * (UNIT + coupon_reserve) // UNIT
        note = m * (fixing * UNIT + coupon_reserve * h) // (h * UNIT) if knocked_in else total
        assert 0 <= note <= total
        s -= m
        note_index += note
        cover_index += total - note
        note_release.append(note)
        cover_release.append(total - note)
        if close:
            phase = CLOSED
    return {
        "phase": phase,
        "reference": h,
        "lastFixing": last,
        "knockedIn": knocked_in,
        "missedInARow": missed_in_a_row,
        "fixingsDone": len(note_release),
        "notionalPerToken": s,
        "noteIndex": note_index,
        "coverIndex": cover_index,
        "noteRelease": note_release,
        "coverRelease": cover_release,
    }


# ---------------------------------------------------------------------------
# vector generation
# ---------------------------------------------------------------------------

def at_bps(price: int, bps: int) -> int:
    """`bps` of `price` (prices are multiples of 1e4, so this is exact)."""
    assert price % BPS == 0
    return price * bps // BPS


def make_vectors(seed: int) -> list[dict]:
    rng = random.Random(seed)
    out: list[dict] = []

    def add(tag, ki, a, r, first, fixings, interval=WEEK):
        fixings = list(fixings)
        res = run(ki, a, r, first, fixings, interval)
        # the pair's release never exceeds the pair value it melts
        melted = RAY - res["notionalPerToken"]
        assert res["noteIndex"] + res["coverIndex"] <= melted * (UNIT + r) // UNIT, tag
        v = {"tag": tag, "ki": ki, "meltShare": a, "couponReserve": r, "interval": interval, "first": first,
             "fixings": fixings}
        v.update(res)
        out.append(v)

    p1 = (6000, MELT_WEEKLY, 235_000)  # k 60%, phi 1/yr weekly, R = 23.5%
    firsts = [100 * 10**8, 354_28_490_000, 1 * 10**8, 99_990_000]  # 8 decimals, multiples of 1e4

    # weekly: the 2nd missed fixing in a row closes (2 * 7 days), so every run of two or more below closes
    for first in firsts:
        ki, a, r = p1
        f = lambda bps, base=first: at_bps(base, bps)  # noqa: E731
        add("flat_at_reference", ki, a, r, first, [first] * 5)
        add("ratchet_up", ki, a, r, first, [f(10100), f(10500), f(10500), f(12000)])
        add("drift_down_clean", ki, a, r, first, [f(9000), f(8000), f(7000), f(6001)])
        add("at_ki_not_knocked_in", ki, a, r, first, [f(8000), f(6000), f(7000)])
        add("one_below_ki_knocked_in", ki, a, r, first, [f(8000), f(6000) - 1, f(7000)])
        add("knocked_in_pays_x", ki, a, r, first, [f(5000), f(5500), f(3000), f(9999)])
        add("knocked_in_deep", ki, a, r, first, [f(5999), 1, 1, f(100)])
        add("heal_at_reference", ki, a, r, first, [f(4000), first, f(9000)])
        add("heal_one_below_reference_stays", ki, a, r, first, [f(4000), first - 1, f(9000)])
        add("heal_above_then_new_barrier", ki, a, r, first, [f(4000), f(12000), f(7300), f(7100)])
        add("ratchet_then_knockin_on_new_reference", ki, a, r, first, [f(20000), f(11999), f(13000)])
        add("missed_single_reuses_last", ki, a, r, first, [f(9000), MISSING, f(9500)])
        add("missed_first_reuses_reference", ki, a, r, first, [MISSING, f(9000)])
        add("missed_while_knocked_in", ki, a, r, first, [f(5000), MISSING, MISSING, f(5500)])
        add("missed_three_then_recorded", ki, a, r, first, [f(9000), MISSING, MISSING, MISSING, f(9100), MISSING])
        add("close_clean", ki, a, r, first, [f(9000), MISSING, MISSING, MISSING, MISSING])
        add("close_knocked_in", ki, a, r, first, [f(5000), f(5200), MISSING, MISSING, MISSING, MISSING])
        add("close_from_first", ki, a, r, first, [MISSING] * 4)
        add("close_ignores_later_fixings", ki, a, r, first, [f(7000)] + [MISSING] * 4 + [f(3000), f(20000)])
        add("close_at_reference_heals", ki, a, r, first, [f(5000), f(11000)] + [MISSING] * 4)

    first = 250 * 10**8
    f = lambda bps: at_bps(first, bps)  # noqa: E731
    path = [f(9000), f(5000), f(4000), MISSING, f(10000), f(11000), f(6500), f(6700)]
    products = [
        (10_000, MELT_WEEKLY, 235_000, WEEK),  # any fixing below the reference knocks in
        (1, MELT_WEEKLY, 235_000, WEEK),  # ki at the minimum
        (6000, MELT_WEEKLY, 0, WEEK),  # no coupon reserve
        (6000, MELT_WEEKLY, 5 * UNIT, WEEK),  # the factory's maximum
        (6000, 1, 235_000, WEEK),  # the smallest melt
        (6000, WAD - 1, 235_000, WEEK),  # nearly everything melts at once
        (6000, WAD // 2, 95_000, WEEK),  # half per fixing
        (8000, 114_148_735_678_798, 357_000, 3600),  # hourly fixings at phi = 1/yr
        (6500, 2_735_976_403_140_714, 120_000, DAY),  # daily fixings at phi = 1/yr, with a coupon reserve
    ]
    for ki, a, r, interval in products:
        add(f"product_{ki}_{a}_{r}_path", ki, a, r, first, path, interval)
        dead = [MISSING] * misses_to_close(interval)
        add(f"product_{ki}_{a}_{r}_close", ki, a, r, first, [f(5999)] + dead, interval)
    add("price_bounds", 6000, MELT_WEEKLY, 235_000, 1, [PRICE_MAX, 1, PRICE_MAX - 1, PRICE_MAX])
    add("reference_at_price_max", 6000, MELT_WEEKLY, 5 * UNIT, PRICE_MAX, [PRICE_MAX - 1, 5 * 10**12, 1])

    # random walks: weekly log-returns at 55% vol, some unrecorded fixings (single and in runs)
    while len(out) < 170:
        ki, a, r = rng.choice([p1, p1, p1, (7000, MELT_WEEKLY, 95_000), (5000, 2 * MELT_WEEKLY, 357_000),
                               (8000, WAD // 10, 500_000)])
        n = rng.choice([8, 26, 26, 52, 104])
        first = rng.randrange(1, 10**7) * 10**4  # $0.0001 .. $1000 at 8 decimals
        s = float(first)
        fixings = []
        gap = 0
        for _ in range(n):
            s *= 2.718281828459045 ** rng.gauss(-0.5 * 0.55**2 / 52, 0.55 / 52**0.5)
            if gap == 0 and rng.random() < 0.04:
                gap = rng.choice([1, 1, 2, 3, 4])
            if gap:
                gap -= 1
                fixings.append(MISSING)
            else:
                fixings.append(min(max(int(s), 1), PRICE_MAX))
        add("random_walk", ki, a, r, first, fixings)
    # ten years of weekly fixings: the notional per token falls to ~0.005%
    for i in range(2):
        s = float(firsts[i])
        fixings = []
        for _ in range(520):
            s *= 2.718281828459045 ** rng.gauss(-0.5 * 0.55**2 / 52, 0.55 / 52**0.5)
            fixings.append(min(max(int(s), 1), PRICE_MAX))
        add("ten_years_weekly", *p1, firsts[i], fixings)

    # the launch worlds: daily fixings, R = 0, each asset's crash line; their own random stream, so
    # the vectors above stay as they were
    rng = random.Random(seed + 1)
    for name, (ki, vol, launch_firsts) in LAUNCH.items():
        for first in launch_firsts:
            for tag, fixings in launch_paths(ki, first):
                add(f"{name}_daily_{tag}", ki, MELT_DAILY, 0, first, fixings, DAY)
        # random walks: daily log-returns at the asset's vol, some unrecorded fixings (single and in runs)
        for _ in range(12):
            first = rng.choice(launch_firsts)
            n = rng.choice([30, 60, 90, 180])
            s = float(first)
            fixings = []
            gap = 0
            for _ in range(n):
                s *= 2.718281828459045 ** rng.gauss(-0.5 * vol**2 / 365, vol / 365**0.5)
                if gap == 0 and rng.random() < 0.03:
                    gap = rng.choice([1, 1, 2, 3, 4])
                if gap:
                    gap -= 1
                    fixings.append(MISSING)
                else:
                    fixings.append(min(max(int(s), 1), PRICE_MAX))
            add(f"{name}_daily_random_walk", ki, MELT_DAILY, 0, first, fixings, DAY)
        # a year of daily fixings: the notional per token falls to 1/e
        s = float(launch_firsts[0])
        fixings = []
        for _ in range(365):
            s *= 2.718281828459045 ** rng.gauss(-0.5 * vol**2 / 365, vol / 365**0.5)
            fixings.append(min(max(int(s), 1), PRICE_MAX))
        add(f"{name}_daily_one_year", ki, MELT_DAILY, 0, launch_firsts[0], fixings, DAY)

    # the dead-feed close at each interval (the launch's ETH terms; the melt share doesn't change when a
    # series closes): n - 1 missed fixings in a row and a recorded one leave the series live, then n close it
    first = 100 * 10**8
    f = lambda bps: at_bps(first, bps)  # noqa: E731
    for interval, a in ((HOUR, MELT_HOURLY), (DAY, MELT_DAILY), (2 * DAY, MELT_DAILY), (5 * DAY, MELT_WEEKLY),
                        (WEEK, MELT_WEEKLY), (14 * DAY, MELT_WEEKLY), (30 * DAY, MELT_WEEKLY)):
        n = misses_to_close(interval)
        short = [MISSING] * (n - 1)
        add(f"dead_feed_{interval}s_one_short_resets", 4000, a, 0, first,
            [f(9000)] + short + [f(9100)] + short + [f(9200)], interval)
        # reset, knocked in at 30%, then dead: everything is released at 30%; the last fixing is ignored
        add(f"dead_feed_{interval}s_close", 4000, a, 0, first,
            [f(9000)] + short + [f(3000)] + [MISSING] * n + [f(20_000)], interval)
    return out


def launch_paths(ki: int, first: int) -> list[tuple[str, list[int]]]:
    """The fixed scenarios at daily fixings for a crash line at `ki` bps of the high
    (0 < ki <= 5000): the ratchet, the line itself and one below it, knock-ins, heals
    and their cycles, missed fixings and the close (the 14th missed fixing in a row)."""
    f = lambda bps: at_bps(first, bps)  # noqa: E731
    k = ki
    dead = [MISSING] * misses_to_close(DAY)
    new_line = k * 12_000 // BPS  # the crash line after a ratchet to 120% of the first fixing
    return [
        ("flat_at_reference", [first] * 5),
        ("ratchet_up", [f(10_100), f(10_500), f(10_500), f(12_000)]),
        ("drift_down_clean", [f(9000), f(7000), f(k + 1000), f(k + 1)]),
        ("at_ki_not_knocked_in", [f(8000), f(k), f(7000)]),
        ("one_below_ki_knocked_in", [f(8000), f(k) - 1, f(7000)]),
        ("knocked_in_pays_x", [f(k - 1000), f(k + 500), f(k // 2), f(9999)]),
        ("knocked_in_deep", [f(k - 1), 1, 1, f(100)]),
        ("heal_at_reference", [f(k - 1000), first, f(9000)]),
        ("heal_one_below_reference_stays", [f(k - 1000), first - 1, f(9000)]),
        ("heal_above_then_new_line", [f(k - 1000), f(12_000), f(new_line + 100), f(new_line), f(new_line - 100)]),
        ("ratchet_then_knockin_on_new_reference", [f(20_000), f(2 * k) - 1, f(13_000)]),
        # knock in, stay knocked in up to one below the high, heal at it, knock in again from the
        # line's other side, heal above the high (a new high), and the line moves with it
        ("knock_in_heal_cycles", [f(k - 1), f(k), f(9999), first, f(k), f(k) - 1, MISSING, f(9000), f(10_000),
                                  f(11_000), f(k * 11_000 // BPS), f(k * 11_000 // BPS) - 1, f(11_000)]),
        ("missed_single_reuses_last", [f(9000), MISSING, f(9500)]),
        ("missed_first_reuses_reference", [MISSING, f(9000)]),
        ("missed_while_knocked_in", [f(k - 1000), MISSING, MISSING, f(k + 500)]),
        ("missed_three_then_recorded", [f(9000), MISSING, MISSING, MISSING, f(9100), MISSING]),
        ("close_clean", [f(9000)] + dead),
        ("close_knocked_in", [f(k - 1000), f(k - 800)] + dead),
        ("close_from_first", dead),
        ("close_ignores_later_fixings", [f(7000)] + dead + [f(k // 2), f(20_000)]),
        ("close_at_reference_heals", [f(k - 1000), f(11_000)] + dead),
    ]


def main() -> None:
    ap = argparse.ArgumentParser()
    root = Path(__file__).resolve().parent.parent
    ap.add_argument("--out", default=str(root / "contracts/test/vectors/perp_vectors.json"))
    ap.add_argument("--seed", type=int, default=20261001)
    args = ap.parse_args()

    vectors = make_vectors(args.seed)
    tags = {v["tag"] for v in vectors}
    for required in ("ratchet_up", "at_ki_not_knocked_in", "one_below_ki_knocked_in", "heal_at_reference",
                     "missed_single_reuses_last", "close_clean", "close_knocked_in", "ten_years_weekly"):
        assert required in tags, required
        if required != "ten_years_weekly":
            for name in LAUNCH:
                assert f"{name}_daily_{required}" in tags, (name, required)
    for name in LAUNCH:
        assert f"{name}_daily_knock_in_heal_cycles" in tags and f"{name}_daily_one_year" in tags, name
    for v in vectors:
        assert all(0 <= x <= PRICE_MAX for x in v["fixings"])
        assert 0 < v["first"] <= PRICE_MAX
        if "close" in v["tag"]:
            assert v["phase"] == CLOSED, v["tag"]
        if v["tag"].startswith("dead_feed_"):
            n = misses_to_close(v["interval"])
            assert (n - 1) * v["interval"] < CLOSE_AFTER_DEAD <= n * v["interval"], v["tag"]
            if v["tag"].endswith("_one_short_resets"):
                assert (v["phase"], v["missedInARow"], v["fixingsDone"]) == (LIVE, 0, 2 * n + 1), v["tag"]
            else:
                assert (v["missedInARow"], v["fixingsDone"]) == (n, 2 * n + 1), v["tag"]

    # 1e27-scale values exceed what a JSON number holds exactly: write them as decimal strings
    big = ("notionalPerToken", "noteIndex", "coverIndex")
    rows = []
    for v in vectors:
        row = dict(v)
        for key in big:
            row[key] = str(v[key])
        row["noteRelease"] = [str(x) for x in v["noteRelease"]]
        row["coverRelease"] = [str(x) for x in v["coverRelease"]]
        rows.append(row)

    Path(args.out).parent.mkdir(parents=True, exist_ok=True)
    with open(args.out, "w") as fh:
        json.dump({"seed": args.seed, "closeAfterDead": CLOSE_AFTER_DEAD, "count": len(rows), "vectors": rows},
                  fh, indent=1)
        fh.write("\n")
    n_closed = sum(v["phase"] == CLOSED for v in vectors)
    n_ki = sum(v["knockedIn"] for v in vectors)
    n_missed = sum(MISSING in v["fixings"] for v in vectors)
    n_fix = sum(v["fixingsDone"] for v in vectors)
    print(f"wrote {len(rows)} vectors ({n_fix} fixings) to {args.out}: {n_closed} closed, {n_ki} end knocked in, "
          f"{n_missed} with a missed fixing, {len(tags)} tags")


if __name__ == "__main__":
    main()
