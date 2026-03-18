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
4. **Deploy Escrow** — pass the TrustedLiquidator address and a claim deadline (unix timestamp). `script/foundry/DeployUpgrade.s.sol` deploys both (reads `ESCROW_DEADLINE` from env).
5. **Register the TrustedLiquidator** — `Joetroller._setTrustedLiquidator(address)` (admin only).
6. **Upgrade target market** — `JTokenAdmin._setImplementation(jToken, newDelegate, true, "")` to the delegate with the `transferTokens` bypass.

## Step-by-step process

### 0. Set the trusted liquidation incentive

Users being force-liquidated during a wind-down were not at risk of liquidation — charging them the full liquidation penalty (typically 8-10%) would be unfair. The Joetroller supports a separate incentive for the TrustedLiquidator that does not affect regular liquidators:

```
Joetroller._setTrustedLiquidationIncentiveMantissa(1.01e18)  // 1% penalty
```

If unset (zero), the global `liquidationIncentiveMantissa` is used as fallback. Set this before executing the close and leave it in place — it only applies to the TrustedLiquidator.

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
npx hardhat positions --asset <SYMBOL> --network avalanche
```

Fetches all users who have interacted with the target jToken (via subgraph), then multicalls `balanceOf` and `borrowBalanceStored` across all markets for each user.

**Output:** `{symbol}-user-positions.csv` — one row per user, columns for every market (amount + USD), plus a total USD column.

**Sanity check:** The task compares `sum(balanceOf)` against `totalSupply()` and `sum(borrowBalanceStored)` against `totalBorrows()`. Supply must match exactly. Borrows may have small rounding dust (see Known Edge Cases below).

**Env required:** `GRAPH_API_KEY` in `.env`.

### 4. Generate action plan

```bash
npx hardhat actions --asset <SYMBOL> --network avalanche
```

Reads the positions CSV and classifies each user into one of five categories:

| Category | Meaning | TrustedLiquidator action |
|----------|---------|--------------------------|
| **REDEEM** | User only supplies the target (or is healthy without it) | `transferAndRedeem` — jTokens move to Escrow, Escrow redeems, user claims underlying |
| **LIQUIDATE_BORROWS_THEN_REDEEM** | User has borrows in other markets backed by the target; liquidate those borrows to free the target, then redeem | `liquidate` (other borrowed, target collateral) + `transferAndRedeem` |
| **FLAG_CANNOT_FREE** | Borrows exceed collateral even after freeing target — manual intervention needed | Review manually |
| **LIQUIDATE_BORROW** | User borrows the target token; has collateral in other markets | `liquidate` (target borrowed, other collateral) |
| **BAD_DEBT** | User borrows the target with no collateral | `repayBorrowBehalf` |

**Output:**
- Console summary with per-category user counts and USD totals
- Funding summary: per-token amounts needed by the TrustedLiquidator
- `{symbol}-action-plan.json` — Forge-consumable JSON with resolved addresses

**Review the plan** before proceeding, especially any `FLAG_CANNOT_FREE` cases.

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
- **LIQUIDATE_BORROW**: repays the target token borrow to seize collateral.
- **BAD_DEBT**: repays on behalf with no expectation of recovery.
- **LIQUIDATE_BORROWS_THEN_REDEEM**: repays borrows in *other* markets (e.g. USDC) to free the target collateral for redemption. Users are left at a health ratio >= 1.20 to avoid putting them at immediate liquidation risk.

### 6. Execute the close

```bash
forge script script/foundry/CloseMarket.s.sol \
  --rpc-url $AVALANCHE_RPC_URL \
  --broadcast
```

Reads the action plan JSON and executes all operations via the TrustedLiquidator's `multicall`. Actions are batched per user.

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
| `positions` | `npx hardhat positions --asset <SYM> --network avalanche` | Subgraph + on-chain multicall | `{sym}-user-positions.csv` |
| `actions` | `npx hardhat actions --asset <SYM> --network avalanche` | `{sym}-user-positions.csv` | `{sym}-action-plan.json` + console summary |
| `dashboard` | `npx hardhat dashboard --network avalanche` | On-chain multicall | Console tables |
| DeployUpgrade | `forge script script/foundry/DeployUpgrade.s.sol --broadcast` | `ESCROW_DEADLINE` env var | Deploys Joetroller, Delegate, TrustedLiquidator, Escrow |
| CloseMarket | `forge script script/foundry/CloseMarket.s.sol --broadcast` | `{sym}-action-plan.json` | On-chain transactions |

## Known edge cases

### Borrow dust (totalBorrows rounding)

`borrowBalanceStored` does per-user integer division (`principal * borrowIndex / userBorrowIndex`), losing up to 1 wei per user. These rounding errors accumulate: `sum(borrowBalanceStored)` is always slightly less than `totalBorrows`. After all borrowers repay, `totalBorrows` retains phantom dust that belongs to no one.

This dust:
- Does not block supplier redemptions (as long as `reserves >= dust`)
- Does not block `_delistMarket` (it only checks `totalSupply`)
- Can confuse frontends that compute utilization as `totalBorrows / totalSupply` when `totalSupply` is 0

### Reserve ordering

Always withdraw reserves AFTER `totalSupply` reaches 0. If reserves are drained while the last supplier still holds jTokens, the exchange rate math (`getCash >= getCash + totalBorrows - reserves`) may fail by the dust amount, blocking their final redemption.

### Subgraph staleness

The `positions` task fetches users from the subgraph filtered to non-zero `jTokenBalance` or `storedBorrowBalance`. Users who have fully exited are excluded. Users with dust in the subgraph but zero on-chain are filtered out by the on-chain `targetIdx` check. The `totalSupply`/`totalBorrows` sanity check confirms no active users are missed.

### FLAG_CANNOT_FREE users

These users have borrows in other markets that exceed their available collateral even after freeing the target asset. They require manual analysis — options include waiting for them to self-liquidate, using the TrustedLiquidator to partially unwind, or treating residual amounts as bad debt.

### LIQUIDATE_BORROWS_THEN_REDEEM execution failures

The `actions` script classifies a user as LIQUIDATE_BORROWS_THEN_REDEEM when their borrows need to be partially liquidated before the target can be redeemed. The liquidation seizes the target jToken as collateral.

However, the TrustedLiquidator always repays the **full** borrow balance in a given market. If a single borrow exceeds the user's target collateral value, the seize will revert (not enough target jTokens to cover).

Example: user has $100 MIM + $500 USDC deposited, borrowed $501 AVAX. The script generates `liquidate(jAVAX, jMIM, user)` which tries to repay all $501 AVAX and seize $501+ of MIM from a user who only has $100 MIM.

**Manual workaround:** Use the TrustedLiquidator's `call()` function to execute a partial `liquidateBorrow` with a specific repay amount, or liquidate against a different collateral market (e.g. seize USDC instead of MIM to reduce the borrow, then redeem MIM). These cases will show up as revert failures during CloseMarket execution — they are not silent.

### Funding buffer

Interest accrues continuously between the position snapshot and execution. The `funding.total` from the action plan is based on snapshot balances. Add a buffer (e.g. 1-5% depending on time gap and borrow APY) to account for this growth.
