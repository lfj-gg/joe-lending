#!/bin/bash
set -euo pipefail

# Load .env if present
if [ -f .env ]; then
  set -a; source .env; set +a
fi

# E2E market wind-down test on an Anvil fork.
# Usage: ./script/e2e-wind-down.sh <ASSET> [FORK_RPC] [START_BATCH]
# Example: ./script/e2e-wind-down.sh MIM
# Restart from batch 5: ./script/e2e-wind-down.sh MIM https://api.avax.network/ext/bc/C/rpc 5
#
# If Anvil is already running on the port, the script reuses it (no restart).
# This lets you fix issues and re-run from the failed batch without losing state.

ASSET=${1:?"Usage: $0 <ASSET> [FORK_RPC] [START_BATCH]"}
START_BATCH=${2:-0}
FORK_RPC=${3:-"https://api.avax.network/ext/bc/C/rpc"}

ANVIL_PORT=8545
ANVIL_RPC="http://127.0.0.1:$ANVIL_PORT"

JOETROLLER="0xdc13687554205E5b89Ac783db14bb5bba4A1eDaC"
ASSET_LOWER=$(echo "$ASSET" | tr '[:upper:]' '[:lower:]')
ACTION_PLAN="${ASSET_LOWER}-action-plan.json"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() { echo -e "\n=== $1 ===\n"; }

# Sets an ERC20 balance on Anvil.
# Traces balanceOf to find the storage slot, then writes via anvil_setStorageAt.
# Usage: deal_erc20 <token> <account> <amount_wei>
deal_erc20() {
  local token=$1 account=$2 amount=$3

  # Trace balanceOf(account) to find which storage slot is read
  local calldata
  calldata=$(cast calldata "balanceOf(address)" "$account")
  local trace
  trace=$(cast rpc debug_traceCall \
    "{\"to\":\"$token\",\"data\":\"$calldata\"}" \
    "latest" \
    '{"disableMemory":true,"disableStack":false,"disableStorage":false}' \
    --rpc-url "$ANVIL_RPC")

  local initial_balance
  initial_balance=$(echo "$trace" | jq -r '.returnValue')

  # Extract the last SLOAD key from the trace (the balance slot)
  local slot
  slot=$(echo "$trace" | jq -r '
    [.structLogs[] | select(.op == "SLOAD") | .stack[-1]] | last // empty
  ')

  if [ -z "$slot" ]; then
    echo "  ERROR: no SLOAD found in balanceOf trace for $token" >&2
    return 1
  fi

  # Pad slot to 32 bytes
  slot=$(printf "0x%064s" "${slot#0x}" | tr ' ' '0')

  # Encode amount as 32-byte hex
  local amount_hex
  amount_hex=$(cast abi-encode "x(uint256)" "$amount")

  # Write to Anvil
  cast rpc anvil_setStorageAt "$token" "$slot" "$amount_hex" --rpc-url "$ANVIL_RPC" > /dev/null

  # Verify
  local new_balance
  new_balance=$(cast call "$token" "balanceOf(address)(uint256)" "$account" --rpc-url "$ANVIL_RPC")
  if [ "$new_balance" = "$initial_balance" ]; then
    echo "  ERROR: balance still $initial_balance after write" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# Start Anvil
# ---------------------------------------------------------------------------

# Check if Anvil is already running on the port
if cast chain-id --rpc-url "$ANVIL_RPC" > /dev/null 2>&1; then
  echo "Anvil already running on port $ANVIL_PORT — reusing existing instance"
else
  log "Starting Anvil fork"
  anvil --fork-url "$FORK_RPC" --port "$ANVIL_PORT" --silent &
  ANVIL_PID=$!
  trap 'kill $ANVIL_PID 2>/dev/null; wait $ANVIL_PID 2>/dev/null' EXIT
  sleep 3
fi

ADMIN=$(cast call "$JOETROLLER" "admin()(address)" --rpc-url "$ANVIL_RPC")
echo "Joetroller admin: $ADMIN"

# Impersonate admin and fund with AVAX for gas
cast rpc anvil_impersonateAccount "$ADMIN" --rpc-url "$ANVIL_RPC" > /dev/null
cast rpc anvil_setBalance "$ADMIN" "$(cast to-hex "$(cast to-wei 100)")" --rpc-url "$ANVIL_RPC" > /dev/null

# ---------------------------------------------------------------------------
# Step 1 & 2: Snapshot positions + generate action plan
# ---------------------------------------------------------------------------

# log "Step 1: Snapshot positions"
# npx hardhat positions --asset "$ASSET" --network localhost

# log "Step 2: Generate action plan"
# npx hardhat actions --asset "$ASSET" --network localhost

TARGET_JTOKEN=$(jq -r '.targetJToken' "$ACTION_PLAN")
echo "Target jToken: $TARGET_JTOKEN"

# ---------------------------------------------------------------------------
# Step 3: Deploy contracts
# ---------------------------------------------------------------------------

log "Step 3: Deploy contracts"

DEPLOY_OUTPUT=$(JOETROLLER="$JOETROLLER" \
  forge script script/foundry/DeployTrustedLiquidator.s.sol:DeployTrustedLiquidatorScript \
  --rpc-url "$ANVIL_RPC" --broadcast 2>/dev/null)

# Parse addresses from the "== Return ==" section
parse_addr() { echo "$DEPLOY_OUTPUT" | sed -n "s/.*$1: address \(0x[0-9a-fA-F]*\).*/\1/p" | head -1; }
NEW_JOETROLLER=$(parse_addr "newJoetrollerDelegate")
ERC20_DELEGATE=$(parse_addr "erc20Delegate")
NATIVE_DELEGATE=$(parse_addr "nativeDelegate")
LIQUIDATOR=$(parse_addr "liquidator")
ESCROW=$(parse_addr "escrow")

if [ -z "$LIQUIDATOR" ]; then
  echo "Deploy failed — could not parse addresses from output" >&2
  exit 1
fi

echo "New Joetroller impl: $NEW_JOETROLLER"
echo "ERC20 delegate:      $ERC20_DELEGATE"
echo "Native delegate:     $NATIVE_DELEGATE"
echo "TrustedLiquidator:   $LIQUIDATOR"
echo "Escrow:              $ESCROW"

# Extract jToken -> newImplementation pairs from the markets struct array
MARKET_PAIRS=$(echo "$DEPLOY_OUTPUT" | grep -o 'jToken: 0x[0-9a-fA-F]*, newImplementation: 0x[0-9a-fA-F]*' \
  | sed 's/jToken: //;s/, newImplementation: / /')

echo ""
echo "Market upgrades:"
echo "$MARKET_PAIRS" | while read -r JTOKEN IMPL; do
  if [ "$IMPL" = "$NATIVE_DELEGATE" ]; then
    echo "  $JTOKEN -> native"
  else
    echo "  $JTOKEN -> erc20"
  fi
done

# ---------------------------------------------------------------------------
# Step 4: Admin setup
# ---------------------------------------------------------------------------

log "Step 4: Admin setup"

echo "Upgrading Joetroller..."
cast send "$JOETROLLER" "_setPendingImplementation(address)" "$NEW_JOETROLLER" \
  --from "$ADMIN" --unlocked --rpc-url "$ANVIL_RPC" > /dev/null
cast send "$NEW_JOETROLLER" "_become(address)" "$JOETROLLER" \
  --from "$ADMIN" --unlocked --rpc-url "$ANVIL_RPC" > /dev/null

echo "Upgrading all market delegates..."
echo "$MARKET_PAIRS" | while read -r JTOKEN IMPL; do
  cast send "$JTOKEN" "_setImplementation(address,bool,bytes)" "$IMPL" false 0x \
    --from "$ADMIN" --unlocked --rpc-url "$ANVIL_RPC" > /dev/null
done

echo "Registering TrustedLiquidator..."
cast send "$JOETROLLER" "_setTrustedLiquidator(address)" "$LIQUIDATOR" \
  --from "$ADMIN" --unlocked --rpc-url "$ANVIL_RPC" > /dev/null

echo "Setting trusted liquidation incentive $TRUSTED_LIQUIDATION_PREMIUM%..."
cast send "$JOETROLLER" "_setTrustedLiquidationIncentiveMantissa(uint256)" "$(cast to-wei "$TRUSTED_LIQUIDATION_PREMIUM")" \
  --from "$ADMIN" --unlocked --rpc-url "$ANVIL_RPC" > /dev/null

echo "Pausing market..."
cast send "$JOETROLLER" "_setMintPaused(address,bool)" "$TARGET_JTOKEN" true \
  --from "$ADMIN" --unlocked --rpc-url "$ANVIL_RPC" > /dev/null
cast send "$JOETROLLER" "_setBorrowPaused(address,bool)" "$TARGET_JTOKEN" true \
  --from "$ADMIN" --unlocked --rpc-url "$ANVIL_RPC" > /dev/null

echo "Setting collateral factor to 0..."
cast send "$JOETROLLER" "_setCollateralFactor(address,uint256)" "$TARGET_JTOKEN" 0 \
  --from "$ADMIN" --unlocked --rpc-url "$ANVIL_RPC" > /dev/null

echo "Admin setup complete."

# ---------------------------------------------------------------------------
# Step 5: Fund TrustedLiquidator
# ---------------------------------------------------------------------------

log "Step 5: Fund TrustedLiquidator"

jq -c '.totalFunding.tokens[]' "$ACTION_PLAN" | while read -r entry; do
  TOKEN_ADDR=$(echo "$entry" | jq -r '.token')
  TOKEN_SYM=$(echo "$entry" | jq -r '.symbol')
  TOKEN_AMOUNT=$(echo "$entry" | jq -r '.amount')
  DECIMALS=$(echo "$entry" | jq -r '.decimals')
  AMOUNT_WEI=$(echo "$TOKEN_AMOUNT * 10^$DECIMALS" / 1 | bc)

  echo "Funding $TOKEN_SYM: $TOKEN_AMOUNT"
  deal_erc20 "$TOKEN_ADDR" "$LIQUIDATOR" "$AMOUNT_WEI"
done

# ---------------------------------------------------------------------------
# Step 6+7: Execute wind-down and verify
# ---------------------------------------------------------------------------

export TRUSTED_LIQUIDATOR="$LIQUIDATOR"
export ESCROW="$ESCROW"

exec ./script/execute-wind-down.sh "$ASSET" "$ANVIL_RPC" "$START_BATCH"
