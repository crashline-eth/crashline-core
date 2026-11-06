# v2 perpetual note: launch spec

Status: 2026-10-30. Binding for the build before the audit (#43). The product, the user
flows and the reasons live in the team's product spec; this file is the implementation side:
rules, formulas, parameters and names, for the people and agents who build the contracts and
for the auditors.

- If the contracts, the Python twins (`tools/perp_*.py`) and this file disagree, fidelity is
  void: fix the disagreement, not the test.
- A PR that changes a rule here changes this file in the same PR.
- **[#n]** marks a rule or value the code doesn't have yet; issue #n builds it. Everything
  else is in `main` today.
- Numbers like #16 are issues in the team's tracker (not public).
- Where older design docs (not part of the public repository) disagree with this file, this
  file wins; #12 brings them in line.
- The interface comments in `contracts/src/interfaces/` are normative for every detail this
  file doesn't restate.

## 1. Launch terms

Decided on 2026-10-29 in #16, #17 and #24.

| | ETH | BTC |
|---|---|---|
| Feed: Chainlink on Arbitrum One, 8 decimals | ETH/USD `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` | BTC/USD `0x6ce185860a4963106506C203335A2910413708e9` |
| `fixingInterval` | 86,400 s (daily) | 86,400 s |
| `firstFixing` | a day's 08:00 UTC | a day's 08:00 UTC |
| `meltShare` (a) | 2,735,976,403,140,715 (1 − e^(−1/365): release rate 1/yr) | the same |
| `kiBarrierBps` (k): the crash line | 4,000 (a 60% fall from the high) | 5,000 (a 50% fall) |
| `couponReserve` (R) | 0 | 0 |
| Pricer | `PerpFormulaPricer`, vol 2,400–15,000 bps (minimum raised from 2,000 for the carry corner, §6) | `PerpFormulaPricer`, vol 2,100–12,000 bps (minimum raised from 2,000 for the carry corner, §6) |
| Carry range | −2,000 to +5,000 bps a year (log basis of the options market's ~1-year future) | the same |
| Market data | vol and carry per coin, written by the market keeper, at most 3 h old (§8) | the same |
| Pricer bands | `fixingBandSecs` 7,200 (2 h), `knockInBelowBps` 200, `knockInAboveBps` 1,000, `healBandBps` 500; the Desk's strip `stripBelowBps` 200, `stripAboveBps` 100; buy-back discount `buyBackDiscountBps` 300 to `discountReachBps` 2,000; `minVolBandBps` 200 | the same, but `buyBackDiscountBps` 450 |
| Desk `minSecsToFixing` | 300 s | the same |

Collateral: Circle's native USDC on Arbitrum One (`0xaf88d065e77c8cC2239327C5EDb3A432268e5831`,
6 decimals), never the bridged USDC.e. Chain: Arbitrum One only.

At the high, at carry 4% (closed form, before the Desk's spread): ETH at 70% vol, NOTE about
7,900 bps and cover about 2,100 bps of notional; BTC at 45% vol, about 8,840 and 1,160.

## 2. Glossary

One thing, one word per audience. App copy uses only the first column; team docs and issues
the second; code the third.

| App and product docs | Team and specs | Code |
|---|---|---|
| Protect; "your cover" for what you hold | cover, the Protect side | COVER token (`cover()`); Desk `buyCover`, `sellCover` |
| Earn | NOTE, the Earn side | NOTE token (`note()`); Desk `buy`, `sell` |
| series (product docs only, not in the app) | series: one set of terms, one USDC pot, one NOTE and one COVER token | `PerpSeries`, `PerpTerms`, `seriesId` |
| new series | vintage: the same terms with a later `firstFixing` | `createSeries` (#37) |
| pot | pot (escrow) | the series' USDC balance |
| — | pair: 1 NOTE + 1 COVER, worth 1 + R per unit of live notional | `mint`, `redeemPair`, `pairValuePerNotional` |
| amount, protected amount | live notional | `notionalPerToken` (RAY), `notionalOf(amount)` |
| melts 0.27% a day | release; release rate φ = 1/yr | `meltShare` (a) |
| daily payout | a release paid to a token | `noteIndex`, `coverIndex`, `claimable`, `claim(to)` |
| highest price, high | reference (H) | `referenceFixing` |
| crash line, line | crash line (knock-in barrier, k) | `kiBarrierBps` |
| daily price at 08:00 UTC | fixing | `firstFixing`, `fixingInterval`, `recordFixing`, `FixingProcessed` |
| paying out (Protect), pay cut (Earn) | knocked in | `knockedIn` = true |
| covered (Protect), full pay (Earn) | clean | `knockedIn` = false |
| — | missed fixing | `missedInARow`; fallback after `FALLBACK_GRACE` |
| — | dead feed: the series closes | `CLOSE_AFTER_DEAD` |
| price | price per unit of live notional | `priceBps`; a token is worth `notionalPerToken / RAY` × it |
| Desk | Desk | `PerpDesk` |
| LPs, fund the Desk | LP, LP shares; deposit and redemption requests | `requestDeposit` / `requestRedeem`, settled by the keeper's update (`IDeskQueue`) |
| spread (not "margin") | spread, vol band (at least the pricer's minimum, 2 points) | `Spread{bidBps, askBps, volBandBps}`, `minVolBandBps` |
| app fee | integrator fee | `feeBps`, `feeReceiver`; half stays with the LPs (`BACKSTOP_SHARE_BPS`) |
| cover available | risk budget, the Desk's spare USDC, the LP queue | `riskBudgetBps`, `risk(feed)` (#38), `shortfall` |
| — | cap: the most COVER the Desk may hold in a series (limits Earn purchases and cover buybacks) | `capNotional` (#38) |
| no price right now | refusal | `TooCloseToFixing`, `FixingPending`, `FeedStale`, `OutOfRange`, `Uncertified`, `NearLine` |
| close to a line | near a line: the crash line's strip, clean, from `stripBelowBps` under k to `stripAboveBps` over it; knocked in, within `healBandBps` of H; edges included | `Bands.stripBelowBps`, `Bands.stripAboveBps`, `Bands.healBandBps`; `lineBands()` (`IPerpPricer`, a `LineBands`) |
| selling Protect back (and buying Earn) near the crash line costs up to 3% (ETH) or 4.5% (BTC) | buy-back discount: above the strip, falling to 0 at 20 points above the line | `buyBackDiscountBps`, `discountReachBps` (`LineBands`) |
| pause around 08:00 UTC | fixing band | `fixingBandSecs` (pricer, near a line), `minSecsToFixing` (Desk, each series before its own next fixing) |
| volatility | vol: 1-year at-the-money implied, from the options market, one per coin | `volBpsAnnual` (per feed, §8) |
| carry | carry: the futures premium over spot, per year, one per coin | `carryBpsAnnual` (per feed, §8) |
| — | closed form; formula pricer | `PerpFormula`; `PerpFormulaPricer` |
| — | model, student (after the audit) | `IPerpPricer`, `correctionBps`, `weightsHash` |
| bot | keeper: the fixing keeper (anyone) and the market keeper (a role) | `recordFixing`, `advance`; `keeper`, `setMarkets` |
| curator | curator: the Desk's owner | `owner`, `listSeries`, `setSpread`, `setRiskBudget` |
| — | coupon reserve (R), 0 at launch | `couponReserve` |

The spread is never called "margin": the word also means collateral.

## 3. Units and constants

| Quantity | Unit |
|---|---|
| NOTE, COVER, USDC amounts | base units, 6 decimals |
| `notionalPerToken` (the melt scale), indexes | 1e27 fixed point (`RAY`) |
| `meltShare` (a) | 1e18 fixed point (`WAD`), 0 < a < 1e18 |
| `couponReserve` (R) | USDC base units per 1e6 base units of live notional |
| barriers, vol, carry, prices, spreads, rates | bps |
| feed prices, `referenceFixing` (H), fixings | feed decimals (8) |
| times | unix seconds |

`YEAR` = 31,536,000 s (365 days), `DAY` = 86,400 s, `UNIT` = 1e6, `BGK` = 0.5826.

## 4. The note (normative; `IPerpSeries.sol`, `PerpPayout.sol`, `tools/perp_vectors.py`)

```solidity
struct PerpTerms {
    address feed;           // AggregatorV3, 8 decimals
    uint40 firstFixing;     // the fixing that sets H; fixing n is at firstFixing + n * fixingInterval
    uint32 fixingInterval;  // >= 1 hour; 86,400 at launch
    uint16 kiBarrierBps;    // k, bps of H; 0 < k <= 10_000
    uint64 meltShare;       // a, WAD
    uint64 couponReserve;   // R; 0 at launch
}
```

`firstFixing` anchors the fixing grid and tells vintages apart (a fresh series has the same
terms and a new `firstFixing`). `seriesId = keccak256(abi.encode(terms))`. The factory accepts
`firstFixing > 0`, `fixingInterval ≥ 1 h`, `0 < k ≤ 10,000`, `0 < a < 1e18`, `R ≤ 5e6` and a
multiple of 100 (a whole number of bps), and a feed with 8 decimals.

State: `phase` (Pending, Live, Closed), `referenceFixing` H, `lastFixing`, `knockedIn`,
`fixingsDone`, `missedInARow`, `notionalPerToken` s (starts at RAY), `noteIndex`,
`coverIndex`.

**First fixing** (n = 0): `H = lastFixing = fixing`, Pending → Live. No fallback: an unstruck
series never holds collateral, and one whose first fixing can never be recorded (§5) stays
Pending; the curator creates the next day's series instead.

**Fixing n ≥ 1**, with fixing price `f` (integers, exact comparisons):

1. `f >= H` → `H = f`, `knockedIn = false`
2. else `f * 10_000 < k * H` → `knockedIn = true`
3. melt and release, per token base unit, RAY:
   ```
   m       = floor(s * a / WAD)                    melted notional
   total   = floor(m * (UNIT + R) / UNIT)          released to the pair
   note    = total                                  if clean (after steps 1-2)
           = floor(m * (f * UNIT + R * H) / (H * UNIT))   if knocked in (then f < H)
   cover   = total - note
   s          -= m
   noteIndex  += note
   coverIndex += cover
   ```

At R = 0 a clean slice pays NOTE 1 per unit of melted notional and COVER 0; a knocked-in slice
pays NOTE f / H and COVER 1 − f / H.

**Missed fixing.** A fixing still unrecorded `FALLBACK_GRACE` (6 h) after its time
is processed with `f = lastFixing` (steps 1–3 unchanged) and counts as missed. A series closes
when its missed fixings in a row span the dead-feed duration:
`missedInARow × fixingInterval ≥ CLOSE_AFTER_DEAD` (14 days). That fixing is processed with
`m = s` (a = 1), so everything is released at the last good fixing under the normal rule,
`s = 0`, phase Closed. A recorded fixing resets the count. A fixing recorded before the series
processes it always wins over the fallback.

The wait doesn't run while the sequencer blocks recording (§5, #44): while the sequencer is
down nothing falls back, and with it up since `startedAt` the fallback comes at
`max(fixingTime, startedAt + SEQUENCER_GRACE) + FALLBACK_GRACE`. So the keeper always has 6 h to
record a fixing, counted from the later of its time and the end of the last outage's grace. The
series uses the recorder's uptime feed and grace and reads the feed when it processes the fixing
(a fixing past its deadline that nobody processed also waits out a new outage). No uptime feed,
or one that reverts, answers short, answers neither up (0) nor down (1), or gives a `startedAt`
of 0 or in the future: the plain rule, so a broken uptime feed never freezes the series. A
feed stuck on down counts as broken once it has read down for `CLOSE_AFTER_DEAD` (14 days), so
the missed fixings fall back then and the dead-feed close still comes.

**Collateral.** `mint(amount)` locks `ceil(amount * s * (UNIT + R) / (RAY * UNIT))` and mints
`amount` NOTE and COVER (Live only). `redeemPair(amount)` burns both and pays the floor of the
same expression (Live or Closed). NOTE and COVER supplies are always equal.

**Holders.** `claimable(holder) = accrued + floor(balance * (index − checkpoint) / RAY)` per
token; the checkpoint moves on every transfer, mint, burn and claim (the token calls the
series before balances change). `claim(to)` pays the caller's accrued USDC to any address.

**Solvency (invariant).** The series' USDC balance ≥ Σ claimable + the pair value of the
supply: mint rounds up, every payment rounds down, and step 3 never releases more than the
pair value it removes.

**Processing.** Every state-changing entry point, token transfers included, first processes
all processable fixings in order; `advance()` and `advanceBy(n)` do only that.

## 5. Fixings (`FixingsRecorder`)

One recorder per feed, deployed by the factory with its limits. Anyone records the fixing for
an observation time `obsTime` by naming a feed round; the recorder checks on chain that it is
the right one:

- the round's `updatedAt ≤ obsTime` and `obsTime − updatedAt ≤ MAX_FIX_AGE`;
- it is the last such round: round `roundId + 1` has `updatedAt > obsTime`, or doesn't exist
  and `roundId` is the feed's latest round (this also refuses an earlier aggregator phase's last
  round, #25);
- the answer is in (0, `PRICE_MAX`];
- `obsTime < block.timestamp`, and not recorded yet;
- the L2 sequencer is up and has been for `SEQUENCER_GRACE`.

**No rolled fixing.** A round with `updatedAt > obsTime` is refused (`RoundAfterObservation`),
so a fixing with no round inside `MAX_FIX_AGE` before its time can never be recorded, and the
series' fallback (§4) handles it.

| Limit | Value |
|---|---|
| `MAX_FIX_AGE` | 1 h (#31: it would have missed no 08:00 fixing on either feed, 2024-01 to 2026-10; the oldest 08:00 round was 53 min) |
| `PRICE_MAX` | 1e15 ($10M at 8 decimals) |
| `SEQUENCER_GRACE` | 1 h (Chainlink's recommendation) |
| sequencer uptime feed (Arbitrum One) | `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` |

## 6. Price per unit of live notional

A token is worth `s / RAY` × the price below. The coupon part is exact; only the principal part
needs a model.

World: `r` = carry (the risk-neutral drift: an input, `carryBpsAnnual`), `ρ` = discount rate
of the payouts (`PerpProduct.discountBps`; what the pot earns: 0, the pot is
plain USDC), `φ = −ln(1 − a) · YEAR / fixingInterval`, `Δ = fixingInterval / YEAR`, `σ` =
total vol.

```
NOTE   = coupon + principal
coupon = R · a · e^(−ρτ) / (1 − (1 − a) · e^(−ρΔ))        τ = time to the next fixing; = R at ρ = 0
COVER  = (1 + R) − NOTE                                    at ρ = 0 (a pair redeems for 1 + R)
```

**Formula** (the principal part in continuous time, with the discrete-fixing shift):

```
β±       = (−b ± sqrt(b² + 2σ²(ρ + φ))) / σ²,   b = r − σ²/2
α        = φ / (ρ + φ − r)                 value of "pays x": 1 at ρ = r
P0       = φ / (ρ + φ)                     value of "pays 1"
top      = e^(BGK · σ · sqrt(Δ)),  k' = k / top,  u = x / top,  κ = k' / top
g(y)     = α·y − P0
B'       = (g(k') − g(top)·κ^β₊) / (κ^β₋ − κ^β₊)
D'       = g(top) − B'
A'       = −B'·β₋ / β₊
C'       = A' − D'
clean       F0(x) = P0 + A'·u^β₊ + B'·u^β₋        for k' <= x < top
knocked in  F1(x) = α·x + C'·u^β₊                 for x < top
x >= top (either state):  F0(top)        clean and x < k':  F1(x)
```

`tools/perp_formula.py` is the bit-exact integer twin of `contracts/src/PerpFormula.sol` (WAD
arithmetic).

Refused: σ outside 1%–300%, or a world whose exponents exceed |β±| = 25, where 18 digits no
longer carry `κ^β` (`VolOutOfRange`); and `r ≥ ρ + φ`, where α has no finite value
(`BadWorld`). At launch ρ + φ = 1/yr, so the carry range (#14) must stay below 10,000 bps.
Measured against a 50-digit reference (`tools/perp_formula.py --check-launch`, 2026-10-30) on
the launch worlds (daily, ρ 0; ETH k 40% at every vol from 24% to 150%, BTC k 50% from 21% to
120%, each at every carry from −20% to +50%, in 1% steps; both states; spots 0.5–130% of the
high in 0.5% steps and the edges): within 7.7e-8 bps (ETH, at vol 24% and carry +49%) and
6.0e-8 bps (BTC, at vol 21% and carry +47%); from 30% vol up, within 1e-9 bps. The error grows
where a low vol meets a high carry (|β₋| up to 24 there): at vol 20% and carry +50% the closed
form refuses (|β₋| > 25), and ETH at 21–22% is carried only to ~3e-5 bps, hence the vol
minimums of §1. Over the wider grid (five weekly and daily worlds, k 50–100%, every vol from
1%): within 1.3e-7 bps, 7e-11 bps from 20% vol up.

**On-chain price** (bps of live notional):

```
formulaBps = round(F(x) · 1e4)                 x = spotBpsOfReference / 1e4, half up
couponBps  = floor(R · coupon / 100)           0 at launch (R = 0)
priceBps   = max(0, formulaBps + correctionBps) + couponBps
```

A quote is a function of `PerpPricerInputs` (§7), the series' terms and the pricer's
`product()` and nothing else (a Python twin of `PerpQuoter.sol` generates its test vectors,
`contracts/test/vectors/perp_quoter_vectors*.json`).

**Formula-only pricer** (`PerpFormulaPricer.sol`; one per asset at launch). Its
correction is the fixing accrual:

```
correctionBps = trunc( a · (interval − timeToNextFixing) / interval · (payBps − formulaBps) )
payBps        = spotBps  if (knocked in or spotBps < k) and spotBps < 10,000,  else 10,000
```

`payBps` is what the melting slice would pay if the fixing were now, so the price doesn't step
when a fixing is processed with the spot unchanged, and the Desk's share price doesn't either.
The pricer refuses:

- a vol outside its range, or a carry outside its range, both ends included (`OutOfRange`);
- in the last `fixingBandSecs` before a fixing, a clean note from `knockInBelowBps` under the
  crash line to `knockInAboveBps` over it (`k − knockInBelowBps ≤ spotBps ≤ k + knockInAboveBps`)
  or a knocked-in note within `healBandBps` of the high (`|spotBps − 10,000| ≤ healBandBps`),
  edges included, in bps of the high (`Uncertified`).

Its constructor checks that the closed form holds at the four corners of its vol and carry
ranges; that the Desk's strip (§8) lies inside the crash line's band on each side
(`stripBelowBps` at most `knockInBelowBps`, `stripAboveBps` at most `knockInAboveBps`) and
reaches below the line to the closed form's knock-in level at the top of the vol range:
`k − k′ ≤ stripBelowBps`, with k′ = k / top at `volMaxBps` (the lowest k′; the carry doesn't
move it), in bps of the high rounded up; and the buy-back discount's numbers: the discount at
most `MAX_BUY_BACK_DISCOUNT_BPS` (1,000) and, with a discount, its reach beyond the strip
(`discountReachBps` > `stripAboveBps`) and a minimum vol band of at least 1 (all `BadBands`;
the Desk's `listSeries` refuses any pricer whose discount comes with no minimum vol band,
`VolBandTooNarrow(0)`). Between k′ and k the formula prices a clean note that a fixing will very likely
knock in; below k′ it prices it on the knocked-in branch, which is what lets the Desk trade a
clean note below the strip at any time. k − k′ at launch: 179 bps (ETH, vol 150%), 180 (BTC,
120%), inside the 200; P1's weekly product at vol 90% needs 421 (its strip in the tests: 500).

**Accuracy** (#2, 2026-10-29). Against a jump-diffusion teacher at the same total vol, the
formula's error is 5 bps typical and 48 worst (ETH; BTC 4 / 41) in a world fitted to five
years of daily prices. In a world with a big crash every two years it is 100–167 bps typical
and up to 667–1,024 bps, near the crash line, always pricing cover too high there; hence §8's
near-line rule. By line (#2's data, rechecked by vol in the review of #32): a clean note within
10 points above k is priced too low at every vol (NOTE 39–1,024 bps low); a knocked-in note
within `healBandBps` of the high is priced too high at typical vols (ETH +21 to +301 bps, BTC
+110 to +342) and too low only at higher vols, so there the error changes sign with the vol.

**Below the crash line** (#66, 2026-11-02; the teacher checked against Monte Carlo at clean
points below the line within 2.2 bps). #2's grid had no clean points below k. More than 2 points
of the high below the line, at every hour up to 300 s before the fixing, both of the Desk's
sides are safe in the world fitted to history and in the one with fewer jumps (the Desk gains at
least 19 bps of live notional against the teacher, with the dev spread); in the crash-heavy
world buying cover back loses an amount comparable to a knocked-in note at the same spot, which
the Desk trades freely (the LPs' worst loss, ETH +51 bps against +25 knocked in, BTC +160
against +141). With a vol band of 0 the buy-back side in the history world loses down to 2.6
points below the line (part 1 took a band of 3 points below for it); with the vol band at least
2 points (§8's minimum) it loses only within 1.25 points under the line to 0.10 over it, inside
the strip, in every measured world and at every hour, the last 2 hours included. So below the
line the Desk's band is the strip's 2 points, and so is the pricer's refusal in its fixing band
(`knockInBelowBps` 200). A clean note well below the line prices like a knocked-in one (the
formula's knocked-in branch, below k′: the constructor's check above), and the next fixing will
very likely knock it in. Above the line the pricer's fixing-band refusal stays 10 points
(`knockInAboveBps` 1,000).

**Above the crash line** (#66, 2026-11-02, the same teacher; decided 2026-11-03). In the
crash-heavy world with a vol band of 2 points, the Desk's worst buy-back loss far from the line
(20 points above it or more) is ETH +239 and BTC +505 bps of live notional; the Desk accepts
that already. Just above the line it reaches ETH +490 and BTC +896. The buy-back discount (§8)
is the smallest linear taper, from the strip's upper edge to 0 at 20 points above the line, that
keeps every point at or below that far reference: ETH 281, taken as 300, and BTC 437, taken as
450; it binds about 2.5 points above the line. The ask spread moves both sides alike and cancels
out: D is the same with `askBps` 0. In the history-fit world the buy-back loss above the strip is
at most 0, so there the discount is the price of the exit. With a vol band of 0 it would need
ETH 415 and BTC 532, hence the 2-point minimum vol band (§8).

## 7. Pricer inputs: featureSpecVersion 3 (`PerpPricerInputs`)

| # | Field | Type | Source |
|---|---|---|---|
| 0 | `spotBpsOfReference` = floor(spot · 1e4 / H) | uint16 | the feed and the series |
| 1 | `volBpsAnnual` | uint16 | the Desk, per feed |
| 2 | `timeToNextFixingSecs` = nextFixing − now | uint32 | the series |
| 3 | `carryBpsAnnual` | int16 | the Desk, per feed |
| 4 | `flags` (bit0 knockedIn) | uint8 | the series |

Field 3 replaces featureSpecVersion 2's `fixingsBeforeEarnings` (stocks only), so the other
fields keep their indexes. Carry is not in the model's pinned product: `PerpProduct` is
`{kiBarrierBps, meltShare, fixingInterval, discountBps}`, and the quoter builds the closed form's
world from the series' terms, the product's `discountBps`, and the caller's vol and carry (the
Desk's market data for the series' feed).

The formula pricer's certified domain: field 0 any value, 1 its vol range, 2 at most the
interval, 3 its carry range, 4 0 or 1; excluded: the two fixing-band regions of §6.

## 8. The Desk (`PerpDesk`)

An ERC-4626 vault on USDC; its shares are "Crashline Desk" (clDESK). Its LPs fund a desk
that sells and buys back NOTE and COVER around the quoter's price. What carries over
unchanged is in the `IPerpDesk` and `IDeskQueue` comments: two prices from the vol band,
fees, released cash, the risk budget, the LP queue.

**Prices.** NOTE fair value from the quoter at the feed's vol −/+ `volBandBps` and the feed's
carry; lo and hi
are the lower and higher, capped at `pairBps = (1e6 + R) / 100`:

```
NOTE ask  = min(hi + askBps, pairBps)    NOTE bid  = lo − bidBps, floored at 0
cover ask = pairBps − NOTE bid           cover bid = pairBps − NOTE ask
```

Trades are in tokens, prices per unit of live notional (#22).

**Market data, per feed.** `{volBpsAnnual, carryBpsAnnual, sourceTime, writtenAt, atBound}` per
feed (one slot), not per listing: every series on a coin has the same terms, and an old held
series with its own stale value would freeze LP flows. A feed with no market data yet is not
quoted (`NoMarketData`).
- `setMarkets(MarketUpdate[] {feed, vol, carry, sourceTime, source})` by the market keeper or the
  owner: one call writes any number of feeds, in order, each with the checks below. It stores
  the values with the source's timestamp and the block time of the write (`writtenAt`), and
  emits them with the source (`MarketSet`, one per feed), so anyone can recompute them. The
  keeper's call then settles the due LP requests (below); the owner's never does. Every write
  needs 0 < `sourceTime` ≤
  now (`BadSourceTime`). The keeper's must also be after the stored one; the owner's may be the
  same or older, so a keeper write that lands between a Safe proposal and its execution can't
  make the owner's recovery revert.
- The keeper's writes are bounded: vol moves at most ±500 bps and carry ±300 bps per update
  (`MarketStepTooLarge`), at least 10 minutes after the feed's previous write on the chain's
  clock (`writtenAt`, `MarketUpdateTooSoon`), and only on a feed that has data (`NoMarketData`).
  So one step per 10 minutes however the writes are dated, 30 vol points an hour at most: a
  stolen keeper key can't stack back-dated steps in one block (nor in one call: the same feed
  twice is `MarketUpdateTooSoon`). The owner's writes are not bounded (the first write,
  recovery), but set `writtenAt` too.
- `atBound`: set by a keeper write that moves vol or carry by exactly its limit (the keeper is
  still catching up with the market, and its next step is known) and by any owner write (its
  values are no settlement price); cleared by a keeper write that moves both by less than their
  limits. With a limit of 0 every keeper write is at it.
- Any value inside those bounds is accepted, including one outside a pricer's ranges: in a crash
  the vol must be able to rise past the top. A series whose vol ± band or carry lies outside its
  pricer's ranges is simply not quoted (the pricer's `OutOfRange`), in both directions; cover
  already sold stays fully backed.
- Market data older than 3 h, measured from its `sourceTime` (not from the write; exactly 3 h is
  fresh), stops quotes on that feed in both directions, like a stale feed (`MarketStale`), and
  the settlement of LP requests while the Desk holds any of the feed's series.
- The limits (3 h, the two bounds, 10 minutes) are owner settings: `maxMarketAge`,
  `maxVolStepBps`, `maxCarryStepBps`, `minUpdateGap`, set in the constructor (DeployPerp: the
  values above) and by `setMarketLimits`, which needs 0 < gap < age ≤ 1 day (`BadMarketLimits`)
  and takes any steps. They apply at once, to the data already written too: raising
  `maxMarketAge` reopens quotes on data that was stale, lowering it stops them. The keeper is
  set by `setKeeper` (DeployPerp: `KEEPER`, none by default). The owner is a Safe multisig;
  there is no timelock code in the Desk (a timelock can sit in front of the Safe later).

**Listing.** `{active, pricer, capNotional}`. The curator lists a series (`listSeries`) with
a pricer whose product matches the series' terms and that answers `lineBands()` (a pricer
without it, like today's Stylus student, reverts at listing, not in a later trade); vol and
carry come from the feed's market data.

**When the Desk doesn't trade.**

| Condition | Refused | Error |
|---|---|---|
| less than `minSecsToFixing` (300 s) before the series' next fixing (at launch every series fixes at 08:00 UTC) | everything on that series | `TooCloseToFixing` |
| a fixing time passed and the fixing isn't processed yet | everything on that series | `FixingPending` |
| the series' feed is older than `MAX_FEED_STALENESS` (1 h) | everything on that feed | `FeedStale` |
| the sequencer is down or in its grace (1 h) | everything | `SequencerDown`, `SequencerGracePeriod` |
| the pricer refuses (§6) | everything on that series | `OutOfRange`, `Uncertified` |
| the feed has no market data yet | everything on that feed | `NoMarketData` |
| the feed's market data is older than 3 h (from its `sourceTime`) | everything on that feed | `MarketStale` |
| in the crash line's strip (clean), at any time | everything on that series, quotes too | `NearLine` |
| near the high (knocked in), at any time | everything on that series, quotes too | `NearLine` |
| a cap would be exceeded | trades that add to the Desk's position beyond it, quotes too | `CapExceeded` |
| the risk budget would be exceeded | trades that add to the Desk's position (`newPosition` > 0, below), not their quotes | `RiskBudgetExceeded` |
| the last settlement reached a due redemption it couldn't pay out of idle USDC (`shortfall`) | trades that add to the Desk's position (`newPosition` > 0), not their quotes | `QueuePending` |
| the Desk's idle USDC (less what is set aside for claims and pending deposits) can't fund the new part | trades that add to the Desk's position, not their quotes | `ReservedForClaims`, or the USDC transfer fails |
| the Desk holds `MAX_HELD_SERIES` (64) series already | trades that would hold another, not their quotes | `HeldSeriesLimit` |

**What `quote` refuses** (#68, decided on 2026-11-03). `quote(series, side, amount,
feeBps)` returns `(paid, priceBps, newPosition)`. `newPosition`, in tokens like `amount`, is the
part of the trade the Desk can't serve from or pair with what it holds, and so puts new USDC
into (`growth` in the code): `buy` (BuyNote) and `sellCover` draw on the Desk's NOTE and leave
it that many more COVER, `sell` (SellNote) and `buyCover` draw on its COVER and leave it that
many more NOTE. 0 is a trade all from stock, `amount` one all new. With the slippage bound met
(`Slippage` is checked first), the trade reverts `QueuePending` exactly when `shortfall` is set
and `newPosition` > 0. Outside a shortfall the new part is not held by the queue, but it still
needs what any new position needs, and the trade can still be refused for it: the risk budget
(`RiskBudgetExceeded`; the feed's whole risk after the trade is checked, and only when
`newPosition` > 0, so a feed already over budget refuses even a tiny new part), the Desk's idle
USDC (`ReservedForClaims`, or the USDC transfer fails) and the held-series limit
(`HeldSeriesLimit`); the trade's revert says which. A trade with `newPosition` 0 needs none of
these: it pairs with or hands over the Desk's stock, and its USDC comes from the trader or from
the pairs it redeems.
- `quote` refuses where there is no valid price: the quoter's and the pricer's refusals
  (`NotLive`, `FixingPending`, `FeedStale`, the sequencer, `OutOfRange`, `Uncertified`),
  `NoMarketData`, `MarketStale`, `NearLine`, `TooCloseToFixing`. And where the amount can never
  trade as asked: `CapExceeded`, which carries the largest amount that would (the stock plus the
  cap's room), `NotListed`, `FeeTooHigh`, `ZeroAmount`.
- It does not refuse for the Desk's cash (`QueuePending`) or the risk budget
  (`RiskBudgetExceeded`; the backend's `room` covers it): a price answers "what is this worth,
  and what would I get", from the market; a `shortfall` answers "can the Desk put new USDC into
  a position now", from the LPs' cash flows, and ends when the cash comes in.
- So during a shortfall trades from stock still go through, and bring cash in, which helps clear
  the queue: while the Desk holds COVER (as it usually does), buying cover and selling NOTE; while
  it holds NOTE, buying NOTE and selling cover. A silent quote would hide exactly those. Holders
  keep their sell value too: the backend's `bid` comes from `quote`.
- And the app gets the exact part that waits: nothing, "up to `amount − newPosition` can trade
  now", or all of it ("the Desk is paying out LPs; this trade waits until it has").

**LP flows.** `totalAssets` marks every held series at the mid. While any held series can't be
quoted at the mid (`FixingPending`, `FeedStale`, `SequencerDown` or `SequencerGracePeriod`, the
pricer's refusals at the feed's vol and carry, `NoMarketData`, `MarketStale`; the other rows,
`TooCloseToFixing`, `NearLine`, the cap, the risk budget, `QueuePending`, the idle USDC and the
held-series limit, refuse trades only,
and so does a vol ± band outside the pricer's range), `totalAssets` and the previews revert,
and the keeper's update settles nothing: due requests wait for the next one that can
(`IPerpDesk` header). So on a day a held series sits near a line, settlement stops for the
2-hour fixing band, and briefly at every fixing until it is processed.

**Delayed LP flows** (#45). Keeper writes step the LP share price, and the options market
shows them coming: with instant ERC-4626 flows anyone could deposit before a known up-step
and redeem after it. So LP flows are binding requests that
settle later, at a mark the requester could not see or time (`IDeskQueue`, which the Desk
extends with a deposit queue; not ERC-7540):
- `deposit`, `mint`, `withdraw` and `redeem` revert (`AsyncOnly`), and the four `max*` return 0.
  `convertToShares` / `convertToAssets` and the previews stay views of the current mark.
- `requestDeposit(assets)` (at least `MIN_DEPOSIT_ASSETS`, 100 USDC) pulls the USDC; it is
  pending: outside `totalAssets`, the risk budget and what a trade may spend
  (`ReservedForClaims`), and earns nothing. `requestRedeem(shares)` (at least
  `MIN_REQUEST_SHARES`, and leaving its owner none or at least that much: `RestTooSmall`) moves
  the shares into the Desk; they keep their gains and losses until filled. Both are due `DELAY`
  (1 h) after they are made, one FIFO queue each. Dust below `MIN_REQUEST_SHARES` can still
  come from a transfer or from cancelling a partly filled request; its holder tops it up with a
  deposit or transfers it.
- Binding: `cancelDeposit` / `cancelRedeem` only once the request is `STALL` (6 h) past due and
  still unsettled (a keeper outage), for the unfilled rest; before that `CancelTooEarly`. A
  request that could be withdrawn up to its due time would be an option on the steps the
  requester sees coming. Cancelling a request already filled or cancelled returns 0.
- Settlement happens only in the keeper's `setMarkets`, after all its writes: never in an owner
  write (the owner's step is unbounded and a Safe proposal is public), a trade, or anything
  else (`processQueue`, the queue filling inside trades and `QUEUE_BATCH` are gone). Nor is an
  owner write's data a settlement price until the keeper's own write of that feed (`atBound`):
  the keeper can't write the feed for `minUpdateGap` after the owner, and its call without a
  write, or writing other feeds, would otherwise settle at the owner's values. When a
  request at the head of either queue is due, the call advances the held series (each
  `advance()` caught: a failure, say a fixing backlog too long for the gas, skips settlement),
  then marks them in one pass that doesn't revert, giving `nav` (totalAssets) and `cutoff`, the
  oldest `sourceTime` of the feeds the Desk holds a position on (now when there is none). It
  skips settlement, and never reverts the writes, when a held series can't be advanced or
  marked, when one of those feeds is `atBound`, or when `now − cutoff > minUpdateGap`
  (freshness). Otherwise it fixes one
  price, OpenZeppelin's `(nav + 1) / (supply + 1e6)`, emits `Settled(cutoff, nav, supply)`,
  fills the deposits due at or before `cutoff` first (shares rounded down, the price updated
  after each), then the due redemptions out of idle USDC (USDC rounded down and set aside for
  `claim`, the last one partly when the USDC runs out), visiting at most `MAX_SETTLE` (64)
  requests of each queue per call, so deposits can't crowd redemptions out. Every fill leaves
  the price per share where it was or higher.
- So a request settles at the mark after the write it was waiting for: knowing the keeper's
  next value gives nothing. Freshness keeps data older than `minUpdateGap` (a stale coin, a
  failed write) from being a price; at the launch's 10 minutes that also keeps the data newer
  than any request it settles, and `cutoff` (data from at or after the due time) guarantees it
  whatever the owner sets `minUpdateGap` to. `atBound` keeps the capped writes of a catch-up
  from being a price: a 30-point jump takes six writes and is over before a request made after
  it falls due, but a 60-point one takes about two hours, longer than `DELAY`, and then only
  `atBound` holds. It keeps an owner write from being one too: settlement on its feed waits for
  the keeper's first write of it below the limits, at least `minUpdateGap` later.
- `shortfall`: set when a settlement reaches a due redemption it can't pay in full out of idle
  USDC. The next settlement that gets past every due redemption (pays them, or finds the short
  one cancelled) clears it; one whose 64 redemption visits run out before a due one leaves it as
  it was. Only it blocks trades that add to the Desk's position (`QueuePending`, the part a
  quote returns as `newPosition`; the quote itself still answers); a due request waiting for the
  keeper blocks nothing.
- Accepted risk (launch): an LP can request a redemption larger than the idle USDC. That sets
  `shortfall`, which halts trades that add to a position until shrinking trades free the USDC.
  STALL past due it can cancel the rest and deposit again, and repeat: its cost is gas and about
  7 hours with its shares escrowed. Monitored (a `shortfall` lasting past one settlement, from
  one owner's requests), not prevented.
- Settlement never calls out to a request's owner (shares are minted, USDC is set aside): a
  USDC-frozen owner can't hold the queue up; it claims to another address.
- Gas (`PerpDeskRequests.t.sol`): a keeper write with nothing due about 53k; settling with one
  held series 0.30M for one request, 2.5M for 64 (first-time accounts). The worst case, 64 held
  series on the formula pricer and both queues' 64 requests in one call, is 15.3M (64 quotes of
  the closed form, about 156k each, then about 35k a request), under half of Arbitrum's 32M
  block gas limit.
- The simulation (`PerpDeskFrontRun.t.sol`). Three random scenarios, each 8 seeds × 18
  request offsets × 2 antithetic branches, spot with Chainlink's lag, a position that moves the
  share price 0.55 % per vol point, attackers requesting 0–3,600 s after a vol jump (due times
  a minute before and on scheduled writes included): UP, +30 points the keeper catches up in
  six capped steps; UP60, +60 points, a catch-up longer than `DELAY`; DOWN, −20 points the Safe
  corrects 5 minutes after the keeper's first step. And two deterministic ones: a second held
  coin written late (with a `minUpdateGap` above `DELAY`, where only `cutoff` holds), and the
  Safe's mistaken write corrected 15 minutes later (where the owner-write rules hold: owner
  writes never settle, and set `atBound`). With instant flows (a model: in and out at the mark
  of the moment) the round trips take 7.1 % (UP), 18.0 % (UP60) and 5.6 % (DOWN, before the
  Safe's write) of the stake on average, 3.0 % (the late coin) and 19.3 % (the Safe's mistake);
  delayed, the mean edge is −0.30, −0.10 and −0.12 bps per round trip and 0.00 and 0.00 bps;
  every cancel reverts, no trade settles a request, and the honest LP's value differs from the
  run without the attack by exactly the attackers' loss. UP holds with `DELAY` alone (it passes
  without `atBound`, so it is no evidence for it); UP60 and the Safe's mistake fail without
  `atBound`, the late coin without `cutoff`, and the Safe's mistake if owner writes both settle
  and leave `atBound` clear (either rule alone holds it; the mutation runs of #45's reviews).
  "Owner writes never settle" on its own is caught where no held feed is `atBound`: on a Desk
  without a position (`PerpDeskRequests.t.sol`).

**Near a line:** in bps of the high, edges included (a band of 0 is the line alone), with
spotBps = floor(spot · 1e4 / H) as the trade's quote gave it to the pricer (input 0), and the
lines of the listing's pricer: `IPerpPricer.lineBands()` returns them (a `LineBands`), so the
Desk reads them for any pricer, a student too (`PerpFormulaPricer` at launch: the heal band 500,
the strip 200 and 100, the buy-back discount 300 for ETH and 450 for BTC to 2,000, the minimum
vol band 200):
- in the crash line's strip: clean and `k − stripBelowBps ≤ spotBps ≤ k + stripAboveBps`;
- above the strip: clean and `k + stripAboveBps < spotBps < k + discountReachBps`;
- near the high: knocked in and `|spotBps − 10,000| ≤ healBandBps`.

At any time of day:
- Above the strip (clean) the formula prices NOTE too low and cover too high (§6): the two sides
  priced at the NOTE ask, `buy` (the Desk sells NOTE) and `sellCover` (it buys cover back), trade
  at the ask raised by the buy-back discount (below); `sell` and `buyCover` at their usual prices.
- Below the strip (clean) every side trades at its usual price (#66, §6): with the vol band at
  least 2 points, a buy-back there costs the LPs no more than one on a knocked-in note at the
  same spot, which the Desk trades freely. In the last 2 hours before 08:00 the pricer refuses a
  clean note from the strip's lower edge to 10 points above the line (`Uncertified`); below that,
  cover can be sold back and the mark, and with it LP settlement, goes on.
- In the strip (clean) the Desk doesn't trade at all: all four sides revert
  `NearLine(spotBps)`. Just under the line, in the hours before a fixing, the formula still
  prices a clean note the fixing will very likely knock in, so there it sells cover too cheaply
  and buys NOTE too dearly (#67: the Desk's NOTE bid up to 168 bps of live notional above #2's
  teacher, ETH, from 9 hours before the fixing, between 0.60 points under the line and 0.05 over;
  in other settings up to 1.15 under and 0.50 over, 1.35 under in the 2-hour band; the launch's
  2 under and 1 over cover them all).
- Near the high (knocked in) the formula's error changes sign with the vol (§6), so the Desk
  doesn't trade there at all: all four sides revert `NearLine(spotBps)`. That lasts until the
  spot leaves the band or a fixing at or above the high makes the note clean again.

`quote` reverts the same way for a refused side (a quote tells a frontend that the trade would
revert) and gives the discounted price where a trade pays it. The pricer's refusals come first
(in its fixing band near a line, `Uncertified` on all four sides), then `NearLine`, then
`TooCloseToFixing` and the cap. LP requests and their settlement, the mark (`midPriceBps`,
`totalAssets`) and `risk` are not trades and are unaffected: the discount is only in the ask.

**Accepted residual: the mark near the crash line** (decided on 2026-11-03).
`totalAssets` and `risk` mark every held series at the mid, and near the line the mid is off:
- in the strip, hours before a fixing, it marks NOTE about 0.5–1.1% of live notional too high
  (up to 1.5–2.3% in the crash-heavy world), and LP requests still settle there;
- above the strip it marks cover too high: up to about 5% (ETH) and 9% (BTC) of that cover's
  notional in the crash-heavy world, tens of bps in the history-fit world. While the Desk holds
  such cover its NAV is overstated, and redemptions settling then are overpaid. This was so
  already for cover the Desk holds when the spot falls toward the line; #66's buy-backs above
  the strip add a way to build it up there. The discount is sized for the trade's loss, not for
  the mark.

Considered and not done: a more conservative mark near the line, and holding settlement while a
held series is near the line.

The rule uses the spot, the reference and the state the trade was quoted at, plus one call to
the pricer on every trade. Measured on `quote` of 1 token, each in its own transaction (`forge
test --isolate`, cold accesses), a clean ETH note at 90% of the high, the launch pricer, vol 70%,
carry 4%, the dev spread (20, 30, 200): 277,000 to 288,000 gas per quote; against #32's check
3,048 more on `sell` and `buyCover` and 1,979 more on `buy` and `sellCover` (#67
+1,922 / +994; #66's band below +302 each; its discount and minimum vol band +824 / +682).

**Buy-back discount** (#66, decided 2026-11-03). For a clean note above the strip and short of
the reach, `k + stripAboveBps < x < k + discountReachBps`, the NOTE ask of `buy` and `sellCover`
rises by

    d(x) = ceil(D · (k + discountReachBps − x) / (discountReachBps − stripAboveBps))

bps of live notional, D = `buyBackDiscountBps`: D just above the strip, falling evenly to 0 at
the reach, so the price has no jump there (at launch D is 300 for ETH and 450 for BTC and the
reach 20 points: 1 bps above the strip, k + 101 bps, 300 / 450; at k + 10 points, 158 / 237; 1 bps
short of the reach, 1; at the reach and beyond, 0). The ask is at most a
pair's value, so the cover bid is at least 0. Sized from #66's measurement (§6): it keeps a
buy-back near the line from costing the LPs more than one 20 points above it already does, in the
crash-heavy world with the 2-point vol band. Example: ETH at 45% of the high (k + 5 points), vol
54%: the discount is ceil(300 · 1,500 / 1,900) = 237 bps; cover is worth about 44% of the amount
by the formula, less about 1 point for the spread and the vol band, so the Desk pays about 40.6%
for it back (part 1 refused).

**Minimum vol band.** The Desk never prices with a vol band below the listing pricer's
`minVolBandBps` (200 at launch): the discount is sized for it (§6). A series whose spread was
never set (a new listing: vol band 0) prices with the minimum, as does one relisted to a pricer
whose minimum is above its stored band; `setSpread` refuses a lower vol band
(`VolBandTooNarrow(minVolBandBps)`), and the lister raises a copied band to the minimum.
Flooring at pricing time, rather than refusing to trade until a valid spread is set, lets a new
listing trade at once at the safe minimum and keeps a relisting from stopping a series.

**Limits and fees.**

| Constant | Value |
|---|---|
| `MAX_FEE_BPS` | 200, of notional (NOTE trades) |
| `MAX_COVER_FEE_BPS` | 1,000, of the premium (cover trades) |
| `BACKSTOP_SHARE_BPS` | 5,000: half of every fee stays with the LPs |
| `MAX_SPREAD_BPS` | 1,000 |
| `MAX_HELD_SERIES` | 64 |
| `DELAY` | 1 h: a request is due this long after it is made |
| `STALL` | 6 h: it can be cancelled this long after it is due, if unsettled |
| `MAX_SETTLE` | 64 requests visited per settlement |
| `MIN_DEPOSIT_ASSETS` | 100 USDC |
| `MIN_REQUEST_SHARES` | 10e12 shares (10 USDC at the first deposit's price) |
| risk budget per feed | 0 until the curator sets it: nothing may add to a position (#38) |

Spare USDC stays plain USDC in the Desk (#18; the LP vault over Aave is #9, after the audit).

**Byte budget.** `PerpDesk` is 24,015 bytes of runtime, 561 under the 24,576 limit
(2026-11-03, after `quote`'s `newPosition` (#68): +19; after listSeries' check that a discount
comes with a minimum vol band, 23,996, +65; after
#66's buy-back discount and minimum vol band, 23,931, +206, of which the discount 100, the floor
at the minimum vol band 39 and setSpread's check 103, the rest −36; after #66's
band below the line it was 23,725, +32; after #67's strip, 23,693, +104; after owner writes
began to hold settlement, 23,589, −6; after #45 and its review, 23,595, +1,084; after #32,
22,511). The design note's fallback, moving the pricing into an external library
(`DeskPricing`), is not used. Every Desk PR reports the new size.

## 9. Tokens (`PerpToken`)

EIP-1167 clones of one implementation, two per series, at CREATE2 addresses from `seriesId`;
6 decimals. Names: `Perpetual NOTE <tag>` / `pNOTE-<tag>` and `Perpetual COVER <tag>` /
`pCOVER-<tag>`, `tag` = the first 4 bytes of `seriesId` as `0x` and 8 hex digits.
Mint and burn are the series' alone, and the series settles the holder itself; every transfer
calls `series.checkpoint` before balances change.

**Permit.** EIP-2612 `permit`, `nonces` and `DOMAIN_SEPARATOR()`, plus ERC-5267
`eip712Domain()`. The EIP-712 domain comes from the clone's own state, never from a
constructor (a clone never runs one) or from immutables (a clone shares the implementation's):
name = the token's `name()`, which `initialize` stores, version `"1"`, the current chain id and
the clone's own address. It is rebuilt on every call, not cached, so a chain id change applies
at once. So a wallet that builds the domain from `name()` signs the right one, and a signature
for one token is invalid on every other, two series whose tags collide included. The
implementation's own domain (empty name, its address) can only set allowances on the
implementation, which never holds a balance.

## 10. Keepers and operations

- **Fixing keeper** (anyone may do it). Each day after 08:00 UTC, per feed: find the last round
  at or before 08:00 (a binary search over `getRoundData`), call
  `recordFixing(obsTime, roundId)`, then `advance()` every series on the feed that isn't Closed,
  Pending ones too (a Pending series is struck by its first fixing). A fixing nobody records
  falls back after `FALLBACK_GRACE`, 6 h, counted from the end of the sequencer's grace hour
  when an outage kept the recorder from recording (§4).
- **Market keeper.** A role (`keeper`, set by the owner) that can only write each feed's vol and
  carry, within its bounds (§8): no withdrawals, no listing changes. Each write carries the
  source's time, from which the data's age counts. Vol and carry per coin: the options
  market's ~1-year at-the-money implied vol, and the log basis of its ~1-year future,
  ln(F / S) × 365 / days to expiry. The job writes every hour, and sooner when vol moves by 2
  points. Its call, `setMarkets`, is also the only thing that settles LP requests (§8). Keeper
  job rules:
  - After a stale period, when the market moved more than a step: write the in-between steps
    with an old sourceTime (each a second after the stored one), so the feed stays stale and
    unquoted at values that are not the market's, and only the last step with the current time.
  - Never send a sourceTime later than the latest block's time (`BadSourceTime`).
  - Write every feed that has a listed series, delisted ones included, in one `setMarkets`
    call (current values, 0-step writes for the quiet ones): settlement uses the oldest exposed
    feed's data, one stale held feed freezes every LP request, and a feed written only when
    held lets a small trade on it hold settlement back until its next write.
  - Leave out any feed written within the last `minUpdateGap` (`writtenAt`), by the owner or by
    the keeper's own earlier call: the contract refuses both (`MarketUpdateTooSoon`), and with
    it the whole call.
  - After an owner write, write that feed as soon as `minUpdateGap` allows: settlement waits
    for the keeper's own write of it (`atBound`, §8).
  - Write current values at least once per `DELAY`, even when the change is inside the 2-point
    dead band: `cutoff` is on `sourceTime`, so a request waits for data sourced at or after its
    due time.
  - Drain the queues: while a request is due (`depositQueue()` / `queue()` heads,
    `depositRequest` / `redeemRequest` due times), keep calling; `MAX_SETTLE` bounds each queue
    per call, and calls without writes (`setMarkets([])`) may run back to back once the data is
    fresh and no held feed is `atBound`. After a write at the step limit (`atBound`), keep
    stepping every 10 minutes: nothing settles until a smaller step.
  - Use an estimated gas limit, never a fixed one: with one held series, between about 200k and
    250k gas the write lands but the settlement runs out of gas in its caught quote and silently
    skips (each held series moves the window up by its quote).
  - `Settled` is emitted whenever a settlement runs, also when no request is due by `cutoff`
    or the idle USDC is short. After a call made while requests were due, check that the queue
    heads moved, not only for `Settled`; when they didn't, find out why (`atBound` after a
    write at the limit or the owner's, `cutoff`, a stale or unmarkable held series,
    `shortfall`, gas).
  - The owner's recovery runbook (a wrong or stolen keeper): `setKeeper(address(0))`, then
    `setMarkets` with the right values, then `setKeeper(new)`. Owner writes never settle and hold
    settlement on their feeds; the new keeper's first write of each held feed, at least
    `minUpdateGap` after the owner's, settles. The owner can't be the keeper (`KeeperIsOwner`).
    Execute a mark-changing Safe transaction as soon as it is proposed.
- **Curator** (the Desk's owner). Creates and lists series (when a new series starts: #37),
  sets spreads, caps and risk budgets (#38), delists.

## 11. Audit scope

After #40, `contracts/src` holds exactly the audit scope:

- core: `PerpFactory`, `PerpSeries`, `PerpPayout`, `PerpToken`;
- fixings: `FixingsRecorder`, `L2Sequencer`;
- pricing: `PerpQuoter`, `PerpFormula`, `PerpMath`, `PerpFormulaPricer`;
- the market: `PerpDesk`;
- their interfaces, and `script/DeployPerp.s.sol`.

Out: the v1 contracts and `PerpWrapper` (removed; the Earn vaults, #33, start from the
wrapper's rules), the Stylus student (#2, #8), and the add-ons
(#28, #33, #35, #9). The audit itself: #13.

## 12. Open points

| Point | Issue | Until decided, the build uses |
|---|---|---|
| when a new series starts | #37 | by hand; 20% below the open series' high agreed, the rest open |
| automated listing (a roller with a lister role) and merging series from the start | #37, #10 | on hold until the team has discussed them |
| risk budget and caps | #38 | 0: the Desk adds to no position (proposal: 30% per coin, cover cap 50% of LP money per series) |

Decided on 2026-10-30 and written into the sections above: the carry range (#14), `MAX_FIX_AGE`
1 h and `FALLBACK_GRACE` 6 h (#31), the dead-feed duration of 14 days (#29), refusing near a
line (#32), the market keeper's limits (#1), the fallback waiting for the sequencer (#44) and
delayed LP flows (#45). The vol band and `discountBps` stay as they are.

## 13. After the audit

- **A trained student** (#2, #8): `correctionBps` learned from a teacher. The stock model P1
  and its teacher came first, on featureSpecVersion 2; a crypto student takes featureSpecVersion
  3 (§7).
- **Add-ons on the core's public functions**, each with its own review: the subscription
  (#28), the Earn vaults (#33), lending against vault shares (#35), the LP vault (#9). Merging
  series: #10.
