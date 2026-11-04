# Contracts

Foundry project (Solidity 0.8.24, OpenZeppelin) for the v2 perpetual note: a
note with no expiry on a Chainlink price feed (at launch ETH/USD and BTC/USD on
Arbitrum One), settled in Circle's native USDC. Each series escrows USDC and
issues two plain ERC-20s: NOTE, the note itself, and COVER, the other side,
which receives what the NOTE loses once it is knocked in, so it works as crash
cover. A NOTE and a COVER together always redeem for the pair value. The first
fixing sets the reference. Each later fixing, recorded on-chain against the
feed's rounds or, if missed, reusing the last one, releases a share of the
escrow: to NOTE, and to COVER what NOTE loses once knocked in. Settlement never
calls a model. A view-only quoter prices a
series from its state and its feed, and an ERC-4626 Desk funded by LPs in USDC
buys and sells both legs around that price.

`src/` holds exactly the audit scope ([../docs/v2-spec.md](../docs/v2-spec.md) §11).
The v1 autocallable note (SeriesFactory, NoteSeries, SeriesToken, AutocallPayout,
NoteQuoter, Desk) and PerpWrapper were removed in #40.

| Layer | Contracts | What it does |
|---|---|---|
| L0 | `FixingsRecorder`, `L2Sequencer` | The recorder lets anyone name the feed round for a fixing time and verifies it on-chain. No price is used while Arbitrum's sequencer is down, nor for a grace period after. |
| L1 | `PerpFactory`, `PerpSeries`, `PerpToken`, `PerpPayout` | Deterministic clones per series: the USDC escrow, the two tokens, and the pure fixing rule. No admin, no pause, no model. |
| L2 | `PerpQuoter`, `PerpFormula`, `PerpMath`, `PerpFormulaPricer` | Reads the note state from the series and recorder, never from the caller, and refuses a stale feed or a pending fixing. Price = closed form (`PerpFormula`, 1e18 fixed point) + the pricer's correction + the coupon reserve; `PerpFormulaPricer` is the pricer without a student. |
| L3 | `PerpDesk` | ERC-4626 on USDC; deposits and redemptions are both requests in a queue, settled at the market keeper's update. Trades NOTE and COVER at two prices within a risk budget per feed; the owner curates listings, spreads and risk budgets but cannot touch series collateral. |

Where to start: read `src/interfaces/` first. The interfaces carry the
normative comments (the fixing rule in `IPerpSeries`, the recording rule in
`IFixingsRecorder`, the pricer inputs in `IPerpPricer`, the Desk's prices in
`IPerpDesk` and its queue in `IDeskQueue`). Then read each layer's
implementation from the bottom up. `script/DeployPerp.s.sol` deploys it.
`test/mocks/` holds test stand-ins (`MockUSDC` with freeze and pause,
`MockChainlinkFeed`); never deploy them where value is at stake.

Public repository: https://github.com/crashline-eth/crashline-core. The implementations in
`src/` are under the Business Source License 1.1 ([LICENSE](LICENSE)); `src/interfaces/`,
the tests and the scripts are MIT.

Commands, from this directory:

```sh
forge fmt --check          # formatting
forge build                # compiles src/, test/ and script/
forge test                 # unit, fuzz, invariant and vector tests (the fork test needs ARBITRUM_ONE_RPC)
python3 ../tools/perp_vectors.py  # rewrites test/vectors/perp_vectors.json (the fixing rule)
python3 ../tools/perp_formula.py  # rewrites test/vectors/perp_formula_vectors.json (the closed form)
```

The team's development repository has more around the contracts: a dev environment with its
own test USDC and price feeds (outside the audit scope), the ABI export for the app and an
end-to-end run on a local dev node. None of it is needed to build or test the contracts.

What was checked and what was not: [../docs/v2-contracts-review.md](../docs/v2-contracts-review.md).
