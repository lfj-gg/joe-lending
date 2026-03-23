# Market Wind-Down Scripts

Scripts for winding down Banker Joe lending markets. Run in order.

## Prerequisites

```
GRAPH_API_KEY=...                # The Graph API key (for subgraph queries)
DEPLOY_PRIVATE_KEY=...           # Deployer private key (for on-chain execution)
TRUSTED_LIQUIDATION_PREMIUM=...  # e.g. 1.01 (1%)
```

Store these in `.env` at the project root.

## 1. Snapshot positions

Fetches all user positions across every market via multicall. Falls back to existing CSV if the subgraph is unavailable.

```bash
uv run script/snapshot.py jMIM
```

Outputs `mim-user-positions.csv`.

## 2. Classify and generate action plan

Reads the CSV, classifies each user, and generates a batched action plan for the TrustedLiquidator.

```bash
uv run script/classifier.py jMIM
```

Options:

- `--batch-size N` — max actions per batch (default: 40)
- `--rerun` — re-run the snapshot before classifying

Outputs `mim-action-plan.json`.

## 3. Dashboard

Displays market health overview (supply, borrow, utilization, APY).

```bash
npx hardhat dashboard --network mainnet
```

## 4. E2E test (Anvil fork)

Deploys contracts, funds the liquidator, and executes the full action plan on a local Anvil fork.

```bash
./script/e2e-wind-down.sh MIM
```

Options:

- `./script/e2e-wind-down.sh MIM <START_BATCH>` — resume from a specific batch
- `./script/e2e-wind-down.sh MIM <START_BATCH> <RPC_URL>` — custom fork RPC

