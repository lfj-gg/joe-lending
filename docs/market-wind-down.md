# Market Wind-Down Runbook

Procedure for fully closing a BankerJoe lending market: clear all borrows, redeem all supplies, and delist the market from the Joetroller.

## Contracts

| Contract | Role |
|----------|------|
| **TrustedLiquidator** | Orchestrates liquidations and repayments. Transfers user jTokens to the Escrow for redemption. Owner-only. Uses `multicall` to batch operations per user. |
| **Escrow** | Holds underlying tokens redeemed during wind-down. Users claim before a deadline; unclaimed funds go to the protocol after. Deployed separately, linked to the TrustedLiquidator. |
| **Joetroller** (upgraded) | `trustedLiquidator` state variable. `liquidateBorrowAllowed` bypasses shortfall and close factor checks for the trusted liquidator. `trustedLiquidationIncentiveMantissa` allows a reduced liquidation penalty (falls back to global incentive if unset). `_delistMarket` removes a fully emptied market. |
| **JCollateralCapErc20Delegate** (upgraded) | `transferTokens` grants the trusted liquidator infinite allowance — enables `transferFrom` without user approval. |
| **JWrappedNativeDelegate** (upgraded) | Same `transferTokens` bypass for native-wrapped markets (jAVAX). |

Source paths:
- `contracts/TrustedLiquidator/TrustedLiquidator.sol`
- `contracts/TrustedLiquidator/Escrow.sol`
- `contracts/Joetroller.sol` (search `trustedLiquidator`)
- `contracts/JCollateralCapErc20.sol` (search `trustedLiquidator` in `transferTokens`)
- `contracts/JWrappedNative.sol` (same)

## Prerequisites (one-time setup)

These steps were completed for the jMIM wind-down and only need repeating if contracts are redeployed.

1. **Deploy upgraded Joetroller** — adds `trustedLiquidator` bypass logic in `liquidateBorrowAllowed` and `trustedLiquidationIncentiveMantissa` for a reduced liquidation penalty.
2. **Deploy upgraded JCollateralCapErc20Delegate** — adds `transferFrom` bypass for trusted liquidator in `transferTokens`.
3. **Deploy TrustedLiquidator** — owner-only contract that orchestrates the wind-down.
4. **Deploy Escrow** — pass the TrustedLiquidator address and a claim deadline (unix timestamp). `script/foundry/DeployTrustedLiquidator.s.sol` deploys both (reads `ESCROW_DEADLINE` from env).
5. **Register the TrustedLiquidator** — `Joetroller._setTrustedLiquidator(address)` (admin only).
6. **Upgrade target market** — `JTokenAdmin._setImplementation(jToken, newDelegate, true, "")` to the delegate with the `transferTokens` bypass.

## Step-by-step process

### 0. Set the trusted liquidation incentive

Users being force-liquidated during a wind-down were not at risk of liquidation — charging them the full liquidation penalty (typically 8-10%) would be unfair. The Joetroller supports a separate incentive for the TrustedLiquidator that does not affect regular liquidators:

```
Joetroller._setTrustedLiquidationIncentiveMantissa(1.01e18)  // 1% penalty
```

If unset (zero), the global `liquidationIncentiveMantissa` is used as fallback. Set this before executing the close and leave it in place — it only applies to the TrustedLiquidator.

Phantom debt and bad debt are handled off-chain — see `classifier.ipynb` for the per-user redemption haircut calculation.

### 1. Pause the market

Prevent new positions from being opened:

```
Joetroller._setMintPaused(jToken, true)
Joetroller._setBorrowPaused(jToken, true)
```

### 2. Set collateral factor to 0

Ensure the deprecated asset can no longer back any borrows:

```
Joetroller._setCollateralFactor(jToken, 0)
```

### 3. Snapshot positions

```bash
uv run script/snapshot.py jMIM
```

Fetches all users who have interacted with the target jToken (via subgraph), then multicalls `balanceOf` and `borrowBalanceStored` across all markets for each user. Falls back to refreshing from the existing CSV if the subgraph is unavailable.

**Output:** `{symbol}-user-positions.csv` — one row per user, columns for every market (amount + USD), plus a total USD column.

**Sanity check:** The script compares `sum(balanceOf)` against `totalSupply()` and `sum(borrowBalanceStored)` against `totalBorrows()`. Supply must match exactly. Borrows may have small rounding dust (see Known Edge Cases below).

**Env required:** `GRAPH_API_KEY` in `.env`.

### 4. Generate action plan

```bash
uv run script/classifier.py jMIM
```

Options:
- `--batch-size N` — max actions per batch (default: 40)
- `--rerun` — re-run the snapshot before classifying

Reads the positions CSV and iteratively classifies each user into a sequence of actions:

| Action | When | What happens |
|--------|------|--------------|
| **transferAndRedeem** | User only supplies the target (or is healthy without it) | jTokens move to Escrow, Escrow redeems, user claims underlying |
| **liquidate** | User borrows the target and has collateral, or user supplies the target and has borrows | Repay borrow (capped by collateral value), seize and redeem collateral |
| **repayBorrowBehalf** | User has bad debt (borrow with no collateral) or residual borrow after liquidation | Repay borrow from TrustedLiquidator funds, no recovery |

The classifier runs iteratively per user — a single user may generate multiple actions (e.g. liquidate then repay residual then redeem).

**Output:**
- Console summary with funding needed and bad debt per asset
- `{symbol}-action-plan.json` — JSON consumed by `e2e-wind-down-testnet.sh` and `execute-wind-down.sh` with resolved addresses and batched actions

**Review the plan** before proceeding, especially any `unknown` action errors.

### 5. Fund the TrustedLiquidator

The action plan JSON includes a `funding` section listing every token the TrustedLiquidator needs:

```json
"funding": {
  "tokens": [
    { "token": "0x...", "symbol": "MIM", "amount": "456.78", "amountUsd": "456.78" },
    { "token": "0x...", "symbol": "USDC", "amount": "123.45", "amountUsd": "123.45" }
  ],
  "totalUsd": "580.23"
}
```

Transfer each token amount (+ buffer for interest accrual between snapshot and execution) to the TrustedLiquidator contract address.

The liquidator needs these tokens because:
- **liquidate**: repays borrow tokens to seize collateral (the liquidator pays the borrowed token, receives the collateral token).
- **repayBorrowBehalf**: repays bad debt on behalf with no expectation of recovery.

### 6. Execute the close

```bash
./script/e2e-wind-down-testnet.sh MIM
```

Deploys contracts, funds the TrustedLiquidator, and executes the full action plan on a local Anvil fork. Each batch is sent as a single `multicall(bytes[])` transaction.

Options:
- `./script/e2e-wind-down-testnet.sh MIM <START_BATCH>` — resume from a specific batch
- `./script/e2e-wind-down-testnet.sh MIM <START_BATCH> <FORK_RPC>` — custom fork RPC

For production runs against a live RPC (contracts already deployed and funded):

```bash
./script/execute-wind-down.sh MIM <RPC_URL>
```

Requires `TRUSTED_LIQUIDATOR` and `ESCROW` env vars set to the deployed addresses.

For REDEEM and LIQUIDATE_BORROWS_THEN_REDEEM users, `transferAndRedeem` moves their jTokens to the Escrow, which redeems them for the underlying. The underlying stays in the Escrow — users must claim it (see next step). The TrustedLiquidator never holds user funds.

### 7. User claims

After execution, users with redeemed positions have claimable balances in the Escrow. They call:

```
Escrow.claim(underlyingTokenAddress)
```

This must happen before the Escrow deadline. Communicate the Escrow address and deadline to affected users.

### 8. Monitor progress

```bash
npx hardhat dashboard --network avalanche
```

Shows per-market: supply, borrows, reserves, utilization, APY, caps, and pause status. Verify the target market is draining.

### 9. Post-execution: reserves and dust

**Reserve ordering is critical: withdraw reserves AFTER all suppliers exit, never before.**

After all borrowers repay and all suppliers redeem:
- `totalSupply` should be 0
- `totalBorrows` may retain sub-token dust (see Known Edge Cases)
- `reserves` should be untouched

If `reserves >= totalBorrows` (almost always true), the last supplier can redeem without issues. If reserves were drained first, the last supplier could be blocked by dust — the exchange rate math requires `reserves >= totalBorrows_dust` for a full redemption.

### 10. Delist the market

```
Joetroller._delistMarket(jToken)
```

Requires `totalSupply == 0`. Does NOT check `totalBorrows`, so rounding dust is tolerated.

After delisting, withdraw any remaining reserves if desired.

### 11. Sweep unclaimed funds

After the Escrow deadline passes, the admin can sweep unclaimed tokens:

```
Escrow.sweep(tokenAddress, treasuryAddress)
```

This transfers the entire token balance of the Escrow to the specified address. Only callable by the TrustedLiquidator's owner, and only after the deadline. The deadline cannot be extended once it has passed.

## Script reference

| Task | Command | Input | Output |
|------|---------|-------|--------|
| Snapshot | `uv run script/snapshot.py jMIM` | Subgraph + on-chain multicall | `mim-user-positions.csv` |
| Classify | `uv run script/classifier.py jMIM` | `mim-user-positions.csv` | `mim-action-plan.json` + console summary |
| Dashboard | `npx hardhat dashboard --network avalanche` | On-chain multicall | Console tables |
| Deploy | `forge script script/foundry/DeployTrustedLiquidator.s.sol --broadcast` | `ESCROW_DEADLINE` env var | Deploys TrustedLiquidator, Escrow, delegates |
| E2E test | `./script/e2e-wind-down-testnet.sh MIM` | `mim-action-plan.json` | Anvil fork execution |
| Mainnet execute | `./script/execute-wind-down.sh MIM <RPC_URL>` | `mim-action-plan.json`, `TRUSTED_LIQUIDATOR`, `ESCROW` | Live batch execution |

## Known edge cases

### Borrow dust (totalBorrows rounding)

`borrowBalanceStored` does per-user integer division (`principal * borrowIndex / userBorrowIndex`), losing up to 1 wei per user. These rounding errors accumulate: `sum(borrowBalanceStored)` is always slightly less than `totalBorrows`. After all borrowers repay, `totalBorrows` retains phantom dust that belongs to no one.

This dust:
- Does not block supplier redemptions (as long as `reserves >= dust`)
- Does not block `_delistMarket` (it only checks `totalSupply`)
- Can confuse frontends that compute utilization as `totalBorrows / totalSupply` when `totalSupply` is 0

### Reserve ordering

Always withdraw reserves AFTER `totalSupply` reaches 0. Reserves are held in the market's underlying cash balance. If reserves are withdrawn while a supplier still holds jTokens, the remaining cash may be insufficient for their final redemption — the market would lack the liquidity to pay them out.

### Subgraph staleness

The snapshot script fetches users from the subgraph filtered to non-zero `jTokenBalance` or `storedBorrowBalance`. Users who have fully exited are excluded. Users with dust in the subgraph but zero on-chain are filtered out by the on-chain `targetIdx` check. The `totalSupply`/`totalBorrows` sanity check confirms no active users are missed.

### Partial liquidations

The TrustedLiquidator's `liquidate` function caps the repay amount via `_maxRepayForCollateral`, which computes the maximum repay that won't exceed the borrower's collateral value. If a borrow exceeds the available collateral, only a partial liquidation occurs — the remainder must be handled by subsequent actions (e.g. liquidating against a different collateral market, or repaying as bad debt).

The classifier handles this iteratively: after each liquidation it updates the simulated positions and generates the next action until the user's target position is fully unwound.

### Funding buffer

Interest accrues continuously between the position snapshot and execution. The `funding.total` from the action plan is based on snapshot balances. Add a buffer (e.g. 1-5% depending on time gap and borrow APY) to account for this growth.
