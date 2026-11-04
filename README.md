# Crashline Core

Crashline is a perpetual note on ETH and BTC, on Arbitrum One, settled in Circle's
native USDC. Each series escrows USDC and issues two ERC-20 tokens:

- **NOTE**, the Earn side. Every day at 08:00 UTC a fixing reads the Chainlink price and
  releases a share of the escrow (about 0.27% of what is left, each day). Until a fixing
  falls below the crash line (40% of the highest fixing so far for ETH, 50% for BTC), NOTE
  receives all of it.
- **COVER**, the Protect side. From a fixing below the crash line until a fixing is back at
  the high, NOTE receives the price's fraction of the high and COVER the rest: what NOTE
  loses.

A NOTE and a COVER together always redeem for the pair value. Settlement never calls a
model. An LP Desk, an ERC-4626 vault funded in USDC, buys and sells both sides around a
price the contracts compute from the series' state, the feed and the market's vol and
carry, which a keeper writes.

**Status: not audited yet. Do not use with real funds.**

## What is here

| Path | What |
|---|---|
| [`contracts/`](contracts/) | The Foundry project: `src/` (the contracts in the audit scope), `test/`, `script/DeployPerp.s.sol` |
| [`docs/v2-spec.md`](docs/v2-spec.md) | The launch spec: the rules, formulas, parameters and names |
| [`docs/v2-contracts-review.md`](docs/v2-contracts-review.md) | What was checked and what was not: a self-review and a second, adversarial review (neither is an audit) |
| [`tools/`](tools/) | The Python twins that regenerate the test vectors: `perp_vectors.py` (the fixing rule) and `perp_formula.py` (the closed-form price, bit-exact with `PerpFormula.sol`) |

Where to start: [`contracts/README.md`](contracts/README.md), then
[`docs/v2-spec.md`](docs/v2-spec.md), then
[`docs/v2-contracts-review.md`](docs/v2-contracts-review.md).

## Build and test

With [Foundry](https://getfoundry.sh):

```sh
git clone --recursive https://github.com/crashline-eth/crashline-core
cd crashline-core/contracts
forge fmt --check # formatting
forge build
forge test        # unit, fuzz, invariant and vector tests; the fork test runs only with ARBITRUM_ONE_RPC set
```

The test vectors come from the Python twins (Python 3, standard library only). To recompute
them, from the repository's root:

```sh
python3 tools/perp_vectors.py     # rewrites contracts/test/vectors/perp_vectors.json
python3 tools/perp_formula.py     # rewrites contracts/test/vectors/perp_formula_vectors.json
git diff --stat                   # nothing: the committed vectors are what the twins compute
python3 tools/perp_formula.py --check-launch   # the closed form against a 50-digit reference (needs mpmath)
```

## Licence

- The contract implementations in `contracts/src/` (everything except
  `contracts/src/interfaces/`): Business Source License 1.1, see [LICENSE](LICENSE).
  Licensor: Crashline UG (haftungsbeschränkt), Warschauer Str. 68, 10243 Berlin, Germany.
  Licensed Work: Crashline Core, (c) 2026 Crashline UG (haftungsbeschränkt). Additional
  Use Grant: none. Change Date: 2028-11-04. Change License: GNU General Public License v2.0
  or later.
- MIT, see [LICENSE-MIT](LICENSE-MIT): the interfaces (`contracts/src/interfaces/`), the
  tests, the scripts, the tools and the docs.

## Contributing

This repository is published from the team's development repository, where the contracts
are developed. Issues are welcome here. Changes land through the development repository
and appear here with the next publication. Numbers like #45 in comments and docs refer to
the team's internal tracker, not to this repository's issues.
