#!/bin/bash
set -euo pipefail

# Load .env if present
if [ -f .env ]; then
  set -a; source .env; set +a
fi

# Execute market wind-down batches.
# Usage: ./script/execute-wind-down.sh <ASSET> <RPC_URL> [START_BATCH]
# Example: ./script/execute-wind-down.sh MIM https://api.avax.network/ext/bc/C/rpc
# Retry from batch 5: ./script/execute-wind-down.sh MIM https://api.avax.network/ext/bc/C/rpc 5
#
# Requires:
# - Action plan JSON: {asset}-action-plan.json
# - DEPLOY_PRIVATE_KEY in .env
# - TRUSTED_LIQUIDATOR and ESCROW env vars

ASSET=${1:?"Usage: $0 <ASSET> <RPC_URL> [START_BATCH]"}
RPC_URL=${2:?"Usage: $0 <ASSET> <RPC_URL> [START_BATCH]"}
START_BATCH=${3:-0}

ASSET_LOWER=$(echo "$ASSET" | tr '[:upper:]' '[:lower:]')
ACTION_PLAN="${ASSET_LOWER}-action-plan.json"

DEPLOY_KEY="${DEPLOY_PRIVATE_KEY:?DEPLOY_PRIVATE_KEY not set in .env}"
LIQUIDATOR="${TRUSTED_LIQUIDATOR:?TRUSTED_LIQUIDATOR not set}"
ESCROW="${ESCROW:?ESCROW not set}"

log() { echo -e "\n=== $1 ===\n"; }

# ---------------------------------------------------------------------------
# Step 6: Execute CloseMarket
# ---------------------------------------------------------------------------

log "Execute CloseMarket"

BATCH_COUNT=$(jq -r '.batchCount' "$ACTION_PLAN")

if [ "$START_BATCH" -gt 0 ]; then
  echo "Resuming from batch $((START_BATCH + 1))/$BATCH_COUNT..."
else
  echo "Executing $BATCH_COUNT batches..."
fi

TOTAL_OK=0
TOTAL_FAIL=0

for i in $(seq "$START_BATCH" $((BATCH_COUNT - 1))); do
  SECONDS=0
  BATCH_KEY=".batches[$i]"

  # Count actions in this batch
  N_LIQ=$(jq "$BATCH_KEY.liquidate | length" "$ACTION_PLAN")
  N_REPAY=$(jq "$BATCH_KEY.repayBorrowBehalf | length" "$ACTION_PLAN")
  N_REDEEM=$(jq "$BATCH_KEY.transferAndRedeem | length" "$ACTION_PLAN")
  echo "  Batch $((i + 1))/$BATCH_COUNT ($N_LIQ liq, $N_REPAY repay, $N_REDEEM redeem)..."

  # Helper: send a tx, check for revert in the receipt
  send_tx() {
    local label=$1; shift
    local output
    output=$(cast send --gas-limit 20000000 "$@" --rpc-url "$RPC_URL" --private-key "$DEPLOY_KEY" --json 2>&1 || true)
    local status
    status=$(echo "$output" | jq -r '.status // "0x0"' 2>/dev/null || echo "0x0")
    if [ "$status" = "0x1" ]; then
      TOTAL_OK=$((TOTAL_OK + 1))
    else
      TOTAL_FAIL=$((TOTAL_FAIL + 1))
      echo "    FAIL: $label"
    fi
  }

  # Build multicall data array
  calls=()

  for j in $([ "$N_LIQ" -gt 0 ] && seq 0 $((N_LIQ - 1)) || true); do
    BORROWED=$(jq -r "$BATCH_KEY.liquidate[$j].jTokenBorrowed" "$ACTION_PLAN")
    COLLATERAL=$(jq -r "$BATCH_KEY.liquidate[$j].jTokenCollateral" "$ACTION_PLAN")
    USER=$(jq -r "$BATCH_KEY.liquidate[$j].user" "$ACTION_PLAN")
    calls+=("$(cast calldata "liquidate(address,address,address)" "$BORROWED" "$COLLATERAL" "$USER")")
  done

  for j in $([ "$N_REPAY" -gt 0 ] && seq 0 $((N_REPAY - 1)) || true); do
    JTOKEN=$(jq -r "$BATCH_KEY.repayBorrowBehalf[$j].jToken" "$ACTION_PLAN")
    USER=$(jq -r "$BATCH_KEY.repayBorrowBehalf[$j].user" "$ACTION_PLAN")
    MAX_REPAY=$(jq -r "$BATCH_KEY.repayBorrowBehalf[$j].maxRepay" "$ACTION_PLAN")
    calls+=("$(cast calldata "repayBorrowBehalf(address,address,uint256)" "$JTOKEN" "$USER" "$MAX_REPAY")")
  done

  for j in $([ "$N_REDEEM" -gt 0 ] && seq 0 $((N_REDEEM - 1)) || true); do
    JTOKEN=$(jq -r "$BATCH_KEY.transferAndRedeem[$j].jToken" "$ACTION_PLAN")
    USER=$(jq -r "$BATCH_KEY.transferAndRedeem[$j].user" "$ACTION_PLAN")
    calls+=("$(cast calldata "transferAndRedeem(address,address,address)" "$ESCROW" "$JTOKEN" "$USER")")
  done

  # Send as single multicall transaction
  joined=$(IFS=,; echo "[${calls[*]}]")
  send_tx "batch $((i + 1))" "$LIQUIDATOR" "multicall(bytes[])" "$joined"

  echo "  Batch $((i + 1)) done in ${SECONDS}s"
done

echo ""
echo "Results: $TOTAL_OK OK, $TOTAL_FAIL FAILED"

# ---------------------------------------------------------------------------
# Step 7: Verify with dashboard
# ---------------------------------------------------------------------------

log "Dashboard verification"
npx hardhat dashboard --network localhost

echo ""
echo "Wind-down execution complete for $ASSET."
echo "Escrow address: $ESCROW"
echo "Users can claim at: Escrow.claim(underlyingTokenAddress)"
