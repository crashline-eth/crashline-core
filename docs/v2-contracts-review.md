# v2 contracts review (perpetual note, 2026-10-02)

Scope: the v2 contracts in `contracts/src/`: PerpFactory, PerpSeries, PerpToken,
PerpPayout, PerpMath, PerpFormula, PerpQuoter, PerpFormulaPricer, PerpDesk, PerpWrapper,
and their interfaces. v1 (the autocallable note, reviewed separately and since removed in
#40) was unchanged: no v1 source file was edited, and the v1 tests passed as before.
Sections 1–9 are a self-review; section 10 is what a second, adversarial review (a
separate agent, given the code and told to break the self-review's claims) found, and what
was done about each finding. Neither is an audit.

Since then (#6, ETH/BTC launch scope) the weekend price and the earnings date are gone from
the Desk and the quoter. The collateral is Circle's native USDC (USDG below), the second
token is COVER (WRITER below), `PerpWrapper` is removed (#40), and PerpFactory deploys the
recorders itself (§5). The Desk changed most: LP deposits and redemptions are binding
requests that settle only in the market keeper's update (#45; `processQueue` and
`QUEUE_BATCH` are gone), its market data is per feed, it doesn't trade near the crash line
or the high, and it is 24,015 bytes. Where this review describes the Desk's queue, size,
weekend or earnings date, it describes the code at the time; `docs/v2-spec.md` §8 has
today's Desk. Each item states what the code does, what was checked, and the decision.

```sh
cd contracts
forge fmt --check && forge build          # no compiler or lint findings in src/
forge test                                # unit, fuzz (1,000 runs), invariants
forge build --sizes                       # PerpDesk is the largest contract
python3 ../tools/perp_vectors.py          # fixing rule -> test/vectors/perp_vectors.json
python3 ../tools/perp_formula.py          # closed form -> test/vectors/perp_formula_vectors.json
python3 ../tools/perp_formula.py --check  # fixed point vs a 50-digit reference (needs mpmath)
```

The quoter's vectors (`test/vectors/perp_quoter_vectors*.json`) and the lifecycle run on a
Nitro dev node with the Stylus pricer come from development tooling that is not part of the
public repository.

## 1. What is new compared with v1, and so where the new risk is

| Change | New risk | Section |
|---|---|---|
| A fixing pays every holder (cumulative index) instead of one settlement | accounting per holder; a transfer must settle both sides first | 2, 3 |
| Tokens call their series before a transfer | a hook in the token path (v1 tokens had none) | 2 |
| No end date | unbounded number of fixings; a dead feed must end the series | 4 |
| The price is computed in Solidity fixed point | precision and overflow of `exp` / `ln` | 6 |
| A wrapper buys at the Desk on behalf of holders | who can trigger it, at which price | 8 |
| The Desk can price off a pool over the weekend | manipulation of that pool | 7 |

## 2. Reentrancy and the token hook

| Where | External calls | Protection | Decision |
|---|---|---|---|
| `PerpSeries.mint / redeemPair / claim / advance / advanceBy / checkpoint` | USDG, own NOTE/WRITER clones, own recorder (view), the L2 sequencer uptime feed (staticcall, for an overdue fixing; #44) | `nonReentrant` on all six | Keep. A test re-enters `claim` from a malicious collateral's `transferFrom` and gets `ReentrancyGuardReentrantCall`. |
| `PerpToken._update` → `series.checkpoint` | the token's own series, before balances change | The series is the only contract called; receivers get no hook (the Siren lesson stands). `checkpoint` accepts only its two tokens (`OnlyToken`) and takes the balances from the token, which is a factory clone. | Keep |
| Mint and burn | called by the series inside its own guarded functions | The token skips the hook for mint and burn; the series settles the holder itself before it calls. So the series never re-enters itself. | Keep |
| Order inside the series | `mint` settles, pulls USDG, then mints; `redeemPair` settles, burns, then pays; `claim` zeroes `accrued` before it pays | checks-effects-interactions, plus the guard | Keep |
| `PerpDesk` trades, `collect`, queue, ERC-4626 | USDG, series (`mint`, `redeemPair`, `claim`), tokens, quoter → pricer, feed, weekend source | `nonReentrant` on all of them. `midPriceBps` is called by the Desk on itself inside a `try` (the risk mark must not revert): it is a view. | Keep |
| `PerpWrapper.wrap / unwrap / compound` | series, Desk, tokens, USDG | `nonReentrant`. `spendCash` is callable only by the wrapper itself, so `wrap` can catch a refusal of the Desk; USDG approval to the Desk is set and cleared inside it. | Keep |
| `PerpFactory.createSeries` | the v1 factory's `deployRecorder` (which calls `feed.decimals()`, untrusted) and the clones' `initialize` | `feed.decimals()` is a static call: it cannot re-enter. The series is registered before the external calls all the same. | Keep |

**Lints excluded in `foundry.toml`.** `src/` is linted on every build; tests and scripts are
not. These lints are excluded, each for a reason that holds across `src/`:

- `block-timestamp`: the product is a schedule of timestamps (fixings, staleness, bands).
- `calls-loop`: the loops are bounded (the fixings an `advance` processes, §4;
  `MAX_HELD_SERIES` in the Desk) and call only factory clones, their recorder, the L2
  sequencer uptime feed (a staticcall) and the quoter.
- `reentrancy-events`: every state-changing entry point is `nonReentrant` (the table above);
  events follow calls to trusted clones or the collateral.
- `boolean-cst`: a false positive on tuple returns such as `(false, 0)`.
- `missing-zero-check`: the initializers are factory-only and get non-zero arguments.
- `missing-events-arithmetic`, `missing-events-access-control`: writes in initializers only;
  the factory emits `PerpSeriesCreated`.

## 3. Rounding directions and solvency

Every rounding goes against the party that asks and in favor of the escrow, then the LPs.

| Quantity | Rounding | Where |
|---|---|---|
| Collateral locked by `mint(n)` | `ceil(n × s × (1 + R))` | PerpSeries |
| `redeemPair(n)` pays | `floor` of the same | PerpSeries |
| Melted notional per token at a fixing | `m = floor(s × a / 1e18)` | PerpPayout |
| Pair release per token | `floor(m × (1 + R))` | PerpPayout |
| NOTE release when knocked in | `floor(m × (f × 1e6 + R × H) / (H × 1e6))`; WRITER = pair release − NOTE | PerpPayout |
| Barriers | exact cross-multiplication: `f ≥ H`, `f × 1e4 < k × H` | PerpPayout |
| A holder's claim | `floor(balance × (index − checkpoint) / 1e27)` per leg, per settlement | PerpSeries |
| Spot input | `floor(spot × 1e4 / H)` | PerpQuoter |
| Closed form | truncating fixed point; rounded to the nearest bps | PerpFormula, PerpQuoter |
| Coupon reserve in the quote | `floor(R × coupon / 100)` bps | PerpQuoter |
| Desk buy cost | `ceil(n × s × price) + ceil(fee)` | PerpDesk |
| Desk sell proceeds | `floor(n × s × price) − fee`, fee capped at the gross | PerpDesk |
| Desk marks | floor per position; WRITER = pair − NOTE, NOTE capped at the pair | PerpDesk |
| Wrapper | shares and tokens both round down (virtual shares, 1e6 per base unit) | PerpWrapper |

What the tests prove:

- **`invariant_escrow_covers_claims_and_pairs`** (256 runs × 100 calls, four series with
  different intervals, barriers, melt shares and reserves; random mint, redeemPair,
  transfer, claim, recordFixing, warp, advance, with fixings left unrecorded so that missed
  fixings and closed series occur): a series' USDG always covers every holder's `claimable`
  plus the pair value of the supply; NOTE and WRITER supplies are equal; the escrow equals
  what came in minus what went out; `claim` pays exactly what `claimable` promised.
- **`invariant_indexes_bounded_by_melted_pair_value`**: the two indexes together never
  exceed the pair value of the notional that melted.
- **`afterInvariant`**: after every holder claims and all pairs are redeemed, the escrow
  holds less than one base unit per rounding operation, and no claim is left unpaid.
- **172 payout vectors** (3,807 fixings, `tools/perp_vectors.py`): the library and a live
  series reproduce the Python reference exactly at every fixing, including ten years of
  weekly fixings (notional per token down to 0.005%), every edge of the barrier
  (`f = k × H` does not knock in, one unit below does; `f = H` heals), missed fixings and
  closure. A holder's claim equals index × balance, and the escrow holds at most 3 base
  units more than what it owes.
- **`testFuzz_path_conserves_collateral`**: two holders, up to 40 fixings, random mints,
  claims and unrecorded fixings; everything paid out ≤ everything locked, the rest is dust.

## 4. No end date

- **Fixing backlog.** `advance()` processes every fixing that can be processed, in a loop,
  and so does every state-changing entry point (a transfer included). A fixing is
  processable only when somebody recorded it, or `FALLBACK_GRACE` (6 h) after
  its time (later after a sequencer outage, #44). Each recorded fixing cost its recorder a transaction, so a backlog can't be
  made cheaply; `advanceBy(n)` catches up a long one in several transactions.
  `foundry.toml` already excludes `calls-loop`; the loop calls only the series' own recorder
  and, once per call for an overdue fixing, the L2 sequencer uptime feed (a staticcall that
  copies at most five words of its answer; #44).
- **Dead feed.** An unrecorded fixing reuses the last one and counts as missed; a run of
  missed fixings spanning 14 days (`missedInARow × fixingInterval ≥ CLOSE_AFTER_DEAD`: the
  14th daily, the 2nd weekly, the 336th hourly) closes the series with a full release at the
  last good fixing. A dead feed therefore leaves at most 14 days ÷ interval fixings to
  replay: 14 at launch (64 held series × 14 ≈ 9.9M gas for the Desk's `_advanceHeld`), 336
  for an hourly series (about 3.7M gas per series; `advanceBy` catches up in parts).
  A recorded fixing resets the count and always wins over the fallback. The first fixing has
  no fallback: an unstruck series never holds collateral. Tested in `PerpSeries.t.sol`,
  `PerpVectors.t.sol` (101 of 296 vectors close) and the invariants.
- **Decaying notional.** `notionalPerToken` falls towards 0 and stops when `floor(s × a)`
  is 0 (after ~60 years of weekly fixings); from there fixings release nothing. Amounts are
  in tokens, so a mint late in a series' life mints many tokens per USDG. No overflow:
  `m ≤ 1e27`, `R ≤ 5e6`, prices ≤ 1e13 (the recorder's bound).
- **Stock splits are not handled.** A 3:1 split would read as `x = 0.33` and knock every
  holder in. Whether the feed adjusts for splits is unverified. Not solved
  here; v1 has the same exposure until maturity, a perpetual has it forever.

## 5. USDG freeze and pause, clone provenance, staleness

The rules the v1 review set for these carry over; here they are with v2's additions.

**Freeze and pause.** The collateral's issuer can freeze an account, wipe it, and pause all
transfers.

- `claim(to)` and `redeemPair(amount, to)` pay any address, so a holder frozen by the issuer
  can still direct its cash elsewhere (tested). A fixing moves no tokens, so a frozen holder
  or a paused USDG can't block a fixing.
- A transfer of NOTE or WRITER never touches USDG: a USDG pause doesn't freeze the tokens.
- Accepted, stated risks: if the issuer freezes or wipes a series' escrow, that series'
  holders are stuck or lose their collateral; nothing in the protocol can prevent it, and
  only that series is hit (each series has its own escrow). A frozen Desk stops LP flows and
  trading; its series positions stay redeemable once it is unfrozen.
- The factory accepts only a 6-decimal collateral and does not check for transfer fees or
  rebasing. USDG (and USDC) have neither; don't reuse the factory with a token that does. The
  test collateral has an open `mint`: never deploy it where value is at stake.

**Clone provenance.**

- PerpFactory deploys its own implementations in its constructor, and a clone's `initialize`
  accepts only the factory (`OnlyFactory`; an implementation can't be initialized again), so
  a clone anyone else makes stays inert and `isSeries` is true only for the factory's own.
  A second PerpFactory on the same feed and terms has its own recorder, and neither factory
  accepts the other's series (tested both ways); the Desk refuses another factory's series
  at listing.
- Same terms, same series: the CREATE2 salt is `seriesId = keccak256(abi.encode(terms))`,
  the two token salts derive from it, and `createSeries` is idempotent.
- One recorder per feed, at a CREATE2 address with the feed in its init code: a series can't
  be pointed at another one. (At the time of this review the recorder was the v1 factory's;
  PerpFactory now deploys it the same way.)
- Tokens mint and burn only for their series (`OnlySeries`); the Desk lists and collects only
  the factory's series (`NotFactorySeries`).

**Staleness and fixings.**

- The quoter refuses a stale feed (`FeedStale`), a non-positive answer (`BadFeedAnswer`), a
  pending fixing, and a Pending or Closed series.
- `oraclePaused()` is not used: the real feeds don't have it, and a pause shows up as
  staleness.
- `recordFixing` needs `obsTime < block.timestamp`, strictly: several Arbitrum blocks share a
  timestamp, so at `obsTime == now` a round with `updatedAt == obsTime` could still land after
  the fixing is recorded, and the recorded round would not be the last one.
- The first fixing has no fallback (§4): an unstruck series never holds collateral.

## 6. The closed form in fixed point

- `PerpMath.expWad` / `lnWad`: range reduction by powers of two, then 16 series terms each.
  Against a 50-digit reference: max error 7e-18 (exp, relative above 1) and 2e-17 (ln) over
  the ranges the formula uses. The series loops are `unchecked`; every operand is bounded by
  the range reduction (products below 2^125), and the reduction itself is checked.
- `PerpFormula.principal`: **1,764 vectors bit-exact** against the integer twin, which is
  measured against the 50-digit reference over 410,688 states (five worlds, k 50–100%,
  every vol 1–150% the contract accepts): max **1.3e-7 bps**, and **7e-11 bps** from 20%
  vol up (`tools/perp_formula.py --check`).
- Why some worlds are refused. `κ^β₋` grows and `κ^β₊` vanishes as the exponents grow (low
  vol, fast melt); at |β| ≈ 48 the error reached 1 bps and worse beyond. Worlds with
  |β±| > 25 revert `VolOutOfRange` (P1's world: below 8% vol). The certified vol range of
  the P1 model starts at 20%.
- Shape (fuzz, P1's world, vol 20–90%): the value rises with the spot, a clean note is
  worth at least a knocked-in one, the principal never exceeds 1. Outside that world the
  shape can fail by a little: with the barrier at 100% of the reference a knocked-in note
  is worth 0.1–2 bps more than a clean one between the reference and `top`. And terms the
  factory accepts but nobody would list (a barrier of 1 bps, a 59-day interval) can make
  the formula revert `ExpOverflow` instead of `VolOutOfRange`: a refusal either way.
- Gas: one price is 27,476 (clean), 24,659 (knocked in), 19,031 (at or above the ratchet).
  The quoter enters the model contract once per quote (`answer`: correction, product and
  hash together); with three separate calls a Desk buy with a vol band cost 939,739 L2 gas
  on the dev node, with one it cost 741,733 (synthetic model). With the P1 model: 787,363;
  with the formula-only pricer, which evaluates the formula again for its accrual: 753,381.

## 7. Desk

What carried over from v1 unchanged in substance: the two prices and the vol band, the
caps, the risk budget per feed, the fee split, the ERC-4626 deviations, the queue. What is
new:

- **Units.** Trades are in tokens, prices per unit of notional; `capNotional` and the risk
  budget are in USDG of live notional, so a cap frees up as the notional melts (tested).
- **Released cash** counts in `totalAssets` at once (`series.claimable(desk)`); `collect`
  pulls it. A series stays in the held set until a `collect` finds the Desk flat, so
  released cash is never dropped from the share price.
- **A closed series** needs no quote: its tokens are worth nothing and the position is its
  released cash. LP flows don't pause on it (tested).
- **Earnings date.** A passed date makes the series unquotable (fail closed) until the
  curator sets the next one. This is a liveness dependency on the curator, as vol is.
- **Weekend.** From Saturday 01:00 to Monday 00:00 UTC (inside the feeds' blind window in
  summer and winter time) a feed that has not updated since the window began is blind,
  however recent its last round: the Desk neither trades nor marks its share price at
  Friday's close (v1 does, for the quoter's 26 hours). A feed that does update in the
  window is used as on any other day.
- **Weekend price.** Used only for trades and for the risk mark, never for `totalAssets`
  (LP flows stay paused while the Desk holds a position on a blind feed) and never for
  fixings. Conditions, all tested: the feed is blind; a source is set; the feed's last
  round is at most 4 hours older than the window's start (a feed halted all Friday is not
  revived); the source's price is clamped to ± `capBps` (≤ 10%) around the feed's last
  price; `spreadBps` widens both sides. A manipulated pool therefore moves the Desk's
  price by at most the cap, and only for trades. **Not done:** an adapter over a real
  pool; the interface and a mock existed.
- **Fixings past their deadline.** Every LP entry point and `processQueue` first called
  `advance()` on the held series, so a fallback fixing is stored before the share price is
  used and a recording made afterwards can't move it. (Today the keeper's settlement
  advances the held series first: `docs/v2-spec.md` §8.)
- **Size.** 23,439 bytes of 24,576 then (1,137 to spare; 24,015 today). One `Traded` event
  and one `quote` view for all four sides, instead of v1's four each, bought the room.

## 8. Wrapper

- `compound()` is permissionless and spends only the wrapper's own USDG, at the Desk's ask,
  on the wrapped leg, to the wrapper. The caller can't choose a price, a recipient or a fee
  receiver. It never buys at the weekend price.
- USDG that is claimed but not reinvested belongs to the current shares. `wrap` compounds
  first and refuses while more than 1 bps of the holding's notional (and more than 10 base
  units) is still USDG; without that, a depositor arriving right after a fixing would take
  a share of ~2.3% of the notional from the existing holders. `unwrap` pays the leaver its
  part and works whenever USDG moves; `exitTokens` returns the tokens alone and touches no
  USDG, so a USDG pause or a freeze of the wrapper's address can't lock them.
- Inflation: virtual shares, 1e6 per token base unit. Tested: an attacker who wraps one
  base unit and donates 500 tokens costs a 100-token depositor under 300 base units and
  gets back half of its own donation.
- Equivalence test: over eight fixings, the wrapper leaves a passive holder with the same
  number of tokens (± 20 base units) as an active holder who claims after every fixing and
  buys at the Desk by hand.

## 9. The formula-only pricer

`PerpFormulaPricer` is what a listing uses when no student is certified for its product.
It is the closed form plus the fixing accrual, `a × elapsed / interval × (p − formula)`:
the release of the coming fixing builds up in the price over the week and leaves it at the
fixing, so the price doesn't step there when the spot is unchanged (tested for a clean and
a knocked-in note, to 1 bps). It refuses a vol outside the range it was built for (the
constructor proves the closed form carries both ends) and, in the last hours before a
fixing, spots next to the knock-in barrier (clean notes) and next to the reference
(knocked-in notes): the two places the value jumps at a fixing. It still cannot know what
the formula gets wrong elsewhere (up to ~270 bps, 13.5 on average, in the teacher's world).

## 10. Second review: findings and what was done (2026-10-02)

A separate reviewer was given the code and the spec and asked for concrete defects with
proof-of-concept tests. The core (PerpSeries, PerpPayout, PerpToken, PerpFactory) held:
solvency under a 1,500-run fuzz over extreme terms, checkpoint ordering, the token hook,
missed fixings and closure, `advanceBy`. Eight defects were confirmed elsewhere:

| # | Finding | Severity | Done | Regression test |
|---|---|---|---|---|
| 1 | On a formula-priced listing the share price stepped at every fixing (the formula had no time to the fixing): an LP could deposit a minute before and withdraw a minute after and take the step from the other LPs (204 USDG on 100,000 NOTE held; 670 USDG when a knock-in was certain) | medium | the formula-only pricer carries the fixing accrual and refuses in the two bands (§9), so the price is continuous where it answers and LP flows pause where it doesn't | `test_no_lp_gain_from_depositing_around_a_clean_fixing`, `test_lp_flows_pause_in_the_formula_pricers_band_before_a_knock_in`, `test_formula_pricer_accrual_makes_the_price_continuous_across_a_fixing` |
| 2 | With a coupon reserve that is not a whole number of bps, NOTE ask + cover ask was below what the pair redeems for (prices are whole bps): 198 USDG taken from LPs in 20 loops at R = 235,099 | medium | the factory accepts only reserves that are multiples of 100 (1 bps) | `test_bad_terms_revert` |
| 3 | For the quoter's 26 hours after Friday's close the Desk traded and let LPs in and out at that close, ignoring the weekend source; a feed halted all Friday still counted as alive | medium-low | the weekend rule of §7: blind from the start of the window; alive means a round in the last 4 hours before it | `test_fridays_close_is_blind_from_the_start_of_the_window`, `test_weekend_window_and_a_feed_that_was_alive` |
| 4 | A fixing recorded after its fallback deadline changed what the views had already shown: deposit at the fallback share price, record, redeem (235 USDG) | low-medium | LP flows settle the held series first (§7). What is left is v1's rule: after the deadline, whoever acts first decides between the fallback and a late recording | `test_a_late_recording_cannot_move_the_share_price_under_an_lp` |
| 5 | Nine small redemption requests (or eight cancelled ones and one real one) block every position-adding trade until someone calls `processQueue` | low | not changed then: it was the v1 queue (`IDeskQueue`, `QUEUE_BATCH` = 8), which needed a keeper for the same reason; the trades that shrink positions kept working. Since #45 there is no `processQueue`: requests settle only in the keeper's update, and only a `shortfall` blocks position-adding trades | (v1: `test_dust_requests_beyond_the_batch_need_a_keeper`) |
| 6 | A USDG pause, or a freeze of the wrapper's address, locked every wrapped token (`unwrap` claims and pays USDG) | low | `exitTokens`: the tokens alone, no USDG touched | `test_exitTokens_works_while_usdg_is_frozen_or_paused` |
| 7 | One base unit of USDG sent to a small wrapper blocked `wrap` (it buys no token, and 1 bps of a tiny holding is 0) | low | an absolute floor of 10 base units under the threshold | `test_a_base_unit_of_usdg_does_not_block_a_small_wrapper` |
| 8 | The Desk accepted a listing vol the closed form refuses (the formula-only pricer certified every vol): `totalAssets` then reverted until relisted | low | the formula-only pricer has a certified vol range, checked at listing as for any model | `test_listing_refuses_a_vol_the_formula_pricer_is_not_built_for`, `test_formula_pricer_is_built_only_for_vols_the_formula_carries` |

Finding 1 in numbers (the Python twins, 21 states at vol 30 / 55 / 80%): the price step at
a fixing with the spot unchanged was 13–73 bps of notional with the bare formula; it is at
most 1.0 bps with the formula-only pricer's accrual and at most 3.7 bps with the P1 model,
which learned the time to the fixing from the teacher.

Also from that review: the shape caveats now in §6; a fuzz test of this suite that minted
into a series it had just closed (fixed); and three statements of this document and of
the interface comments that were wrong (the pair value in bps, "LP flows stay paused" over
the weekend, "`unwrap` always works"), corrected by the changes above.

Not covered by either review: the Stylus contract beyond its golden vectors, and the
teacher.

## 11. Out of scope / not done

- No audit. No formal verification of `PerpMath`.
- No merge of series that have reached the same state (the roadmap's "could").
- No split handling, no pool adapter for the weekend price (both above).
- The backend indexed v1 only.
- Not deployed at the time: `DeployPerp.s.sol` simulated cleanly against a testnet, with no
  deployer key set.
