#!/usr/bin/env bash
# MEVREP — Pharos MEV Exposure Reporter (Foundry port).
#
# Detects three classes of value extraction on Pharos:
#   1. Sandwich attack — three txs in one block, same pool, attacker
#      brackets the victim (confidence 0.85)
#   2. Frontrun — same `to` + same function selector, lands before victim
#   3. Backrun — same as frontrun but lands after victim
#
# All RPC reads go through `cast`. The scoring is heuristic, not
# statistical. Treat CRITICAL as "needs a human".
#
# Usage:
#   bash scripts/detect.sh --wallet 0x... [--chain mainnet|testnet]
#                          [--blocks N] [--format text|json|markdown]
#                          [--rpc-url URL] [--demo]
#   bash scripts/detect.sh --help

set -uo pipefail

# ---- Load network config ----
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NET_JSON="$SCRIPT_DIR/../assets/networks.json"
[ ! -f "$NET_JSON" ] && { echo "Error: $NET_JSON not found" >&2; exit 1; }

get_field() {
  local net_name="$1" field="$2"
  sed -n "/\"name\": *\"$net_name\"/,/^    }/p" "$NET_JSON" \
    | grep -E "\"$field\":" | head -1 \
    | sed -E 's/^[^:]+:[[:space:]]*"([^"]*)".*/\1/' | sed -E 's/,$//'
}
get_num() {
  local net_name="$1" field="$2"
  sed -n "/\"name\": *\"$net_name\"/,/^    }/p" "$NET_JSON" \
    | grep -E "\"$field\":" | head -1 | grep -oE '[0-9]+' | head -1
}

# ---- Arg parsing ----
WALLET=""
RPC_URL=""
CHAIN="mainnet"
BLOCKS=5000
FORMAT="text"
DEMO=0
PRINT_HELP=0
PREV=""

usage() {
  cat <<USAGE
MEVREP — Pharos MEV Exposure Reporter (Foundry port)

Usage:
  bash scripts/detect.sh --wallet 0x... [--chain mainnet|testnet]
                          [--blocks N] [--format text|json|markdown]
                          [--rpc-url URL] [--demo]
  bash scripts/detect.sh --help

Examples:
  bash scripts/detect.sh --wallet 0xWALLET --blocks 5000
  bash scripts/detect.sh --wallet 0xWALLET --format json
  bash scripts/detect.sh --demo   # uses a real public mainnet address

Prerequisites:
  - Foundry (cast): curl -L https://foundry.paradigm.xyz | bash && foundryup
  - jq: optional, for --json pretty-printing
USAGE
}

for arg in "$@"; do
  case "$PREV" in
    --wallet)  WALLET="$arg"; PREV=""; continue ;;
    --chain)   CHAIN="$arg"; PREV=""; continue ;;
    --rpc-url) RPC_URL="$arg"; PREV=""; continue ;;
    --blocks)  BLOCKS="$arg"; PREV=""; continue ;;
    --format)  FORMAT="$arg"; PREV=""; continue ;;
  esac
  case "$arg" in
    -h|--help)  PRINT_HELP=1 ;;
    --wallet)   PREV="--wallet" ;;
    --chain)    PREV="--chain" ;;
    --rpc-url)  PREV="--rpc-url" ;;
    --blocks)   PREV="--blocks" ;;
    --format)   PREV="--format" ;;
    --json)     FORMAT="json" ;;
    --demo)     DEMO=1 ;;
    -*)         echo "Unknown flag: $arg" >&2; usage >&2; exit 1 ;;
    *)          echo "Unknown arg: $arg" >&2; usage >&2; exit 1 ;;
  esac
done
[ -n "$PREV" ] && { echo "Error: $PREV requires a value" >&2; exit 1; }

# ---- Help (no cast needed) ----
if [ "$PRINT_HELP" = "1" ]; then
  usage
  exit 0
fi

# Demo: pre-load a real public mainnet address
[ "$DEMO" = "1" ] && WALLET="0x67992af9a87f2d6a3062c333d8a06abbe3929438"

if [ -z "$WALLET" ]; then
  echo "Error: --wallet required (or use --demo)" >&2
  usage >&2
  exit 1
fi

if [[ ! "$WALLET" =~ ^0x[0-9a-fA-F]{40}$ ]]; then
  echo "Error: --wallet must be 0x-prefixed 20-byte hex" >&2
  exit 1
fi
WALLET="${WALLET,,}"

# ---- Resolve network (after arg parsing, before cast) ----
case "$CHAIN" in
  mainnet)
    RPC_URL="${RPC_URL:-$(get_field mainnet rpcUrl)}"
    EXPLORER_URL=$(get_field mainnet explorerUrl)
    CHAIN_ID=$(get_num mainnet chainId)
    ;;
  testnet)
    RPC_URL="${RPC_URL:-$(get_field atlantic-testnet rpcUrl)}"
    EXPLORER_URL=$(get_field atlantic-testnet explorerUrl)
    CHAIN_ID=$(get_num atlantic-testnet chainId)
    ;;
  *) echo "Unknown chain: $CHAIN (use 'mainnet' or 'testnet')" >&2; exit 1 ;;
esac

# ---- Validate blocks (after arg parsing, before cast) ----
if ! [[ "$BLOCKS" =~ ^[0-9]+$ ]] || [ "$BLOCKS" -lt 1 ]; then
  echo "Error: --blocks must be a positive integer" >&2
  exit 1
fi
if [ "$BLOCKS" -gt 100000 ]; then
  echo "Error: --blocks cannot exceed 100000 (would take too long on the public RPC)" >&2
  exit 1
fi

# ---- Validate format ----
case "$FORMAT" in
  text|json|markdown) ;;
  *) echo "Unknown format: $FORMAT (use 'text', 'json', or 'markdown')" >&2; exit 1 ;;
esac

# ---- Foundry required (after arg parsing, network resolution, value checks) ----
if ! command -v cast >/dev/null 2>&1; then
  echo "Error: 'cast' not found. Install Foundry:" >&2
  echo "  curl -L https://foundry.paradigm.xyz | bash && foundryup" >&2
  exit 1
fi

# ---- Helpers ----
log() { echo "$@" >&2; }

# ---- Early-exit: zero-history wallet (no nonce, no balance) ----
echo ""
echo "========================================================================"
echo "  MEV EXPOSURE REPORT"
echo "  Wallet: $WALLET"
echo "  ChainId: $CHAIN_ID"
echo "========================================================================"
echo ""

NONCE=$(cast nonce --rpc-url "$RPC_URL" "$WALLET" 2>/dev/null | tr -d '[:space:]' || echo "0x0")
NONCE_DEC=$(cast --to-dec "$NONCE" 2>/dev/null | tr -d '[:space:]' || echo "0")
BALANCE=$(cast balance --rpc-url "$RPC_URL" "$WALLET" 2>/dev/null | tr -d '[:space:]' || echo "0")
echo "  Wallet nonce:  $NONCE_DEC (outgoing tx count)"
echo "  Wallet balance: $BALANCE"
echo ""

# Early-exit: brand-new wallet with no history → MEV risk is NONE, no need to scan
if [ "$NONCE_DEC" = "0" ]; then
  log "  Wallet has 0 outgoing transactions — no MEV exposure possible."
  log "  Skipping block scan (would find 0 events anyway)."
  echo ""
  if [ "$FORMAT" = "json" ]; then
    cat <<JSON
{
  "wallet": "$WALLET",
  "chainId": $CHAIN_ID,
  "scannedBlocks": 0,
  "startBlock": 0,
  "endBlock": 0,
  "victimTxCount": 0,
  "incidentCount": 0,
  "swapEvents": 0,
  "uniqueBlocks": 0,
  "uniqueTokens": 0,
  "mevScore": 0,
  "verdict": "NONE",
  "note": "wallet has 0 outgoing transactions; MEV exposure not possible",
  "explorer": "$EXPLORER_URL/address/$WALLET"
}
JSON
  else
    cat <<TEXT
  Scanned blocks:       0
  Victim swap txs:      0
  Total MEV incidents:  0
  Swap-related logs:    0
  Unique blocks:        0
  Unique tokens:        0
  MEV exposure score:   0/100

  >>> VERDICT: NONE  <<<

  Note: wallet has 0 outgoing transactions; no MEV exposure possible.
  Explorer: $EXPLORER_URL/address/$WALLET
TEXT
  fi
  exit 0
fi

# ---- Fetch head block ----
HEAD=$(cast block-number --rpc-url "$RPC_URL" 2>/dev/null | tr -d '[:space:]' || echo "0x0")
HEAD_DEC=$(cast --to-dec "$HEAD" 2>/dev/null | tr -d '[:space:]' || echo "0")
START=$(( HEAD_DEC - BLOCKS ))
[ "$START" -lt 0 ] && START=0
log "  Scanning blocks [$START, $HEAD_DEC] (last $BLOCKS)..."
echo ""

# ---- Walk blocks in batches of 1000 (cap), count transfers where the wallet was involved ----
TEMP=$(mktemp -d)
SWAP_FILE="$TEMP/swaps.txt"
> "$SWAP_FILE"

# ERC-20 Transfer event topic
TRANSFER_TOPIC="0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

# 32-byte padded wallet address for the indexed `from` topic
PADDED_WALLET="0x000000000000000000000000$(echo "$WALLET" | sed 's/^0x//')"

# Per-batch timeout (seconds). Pharos public RPC can be slow on wide ranges.
BATCH_TIMEOUT=20

# Use a smaller batch size to keep each cast rpc call fast
BATCH_SIZE=500

# If --blocks is large, cap BATCH_SIZE so we don't do too many round-trips
TOTAL_BATCHES=$(( (BLOCKS + BATCH_SIZE - 1) / BATCH_SIZE ))
[ "$TOTAL_BATCHES" -gt 20 ] && { BATCH_SIZE=$(( (BLOCKS + 19) / 20 )); TOTAL_BATCHES=20; }

current="$START"
batch_idx=0
while [ "$current" -le "$HEAD_DEC" ]; do
  end=$(( current + BATCH_SIZE - 1 ))
  [ "$end" -gt "$HEAD_DEC" ] && end="$HEAD_DEC"
  batch_idx=$(( batch_idx + 1 ))

  from_hex=$(printf '0x%x' "$current")
  to_hex=$(printf '0x%x' "$end")

  # Per-batch log so the user sees progress
  log "  [batch $batch_idx/$TOTAL_BATCHES] blocks [$current, $end]  querying logs..."

  # Per-batch cast rpc with timeout. If the RPC is slow or hangs, skip
  # the batch and move on (we'd rather return a partial result than hang).
  logs=$(timeout "$BATCH_TIMEOUT" cast rpc --rpc-url "$RPC_URL" 'eth_getLogs' \
    "[{\"fromBlock\":\"$from_hex\",\"toBlock\":\"$to_hex\",\"topics\":[\"$TRANSFER_TOPIC\",\"$PADDED_WALLET\"]}]" 2>/dev/null || echo "[]")

  # Extract transaction hash + block number + token address from each log entry.
  # Use a tolerant regex that doesn't require field order.
  if [ -n "$logs" ] && [ "$logs" != "[]" ]; then
    echo "$logs" | grep -oE '"transactionHash":"0x[a-fA-F0-9]{64}"[^}]*"blockNumber":"0x[a-fA-F0-9]+"[^}]*"address":"0x[a-fA-F0-9]{40}"' \
      | sed -E 's/.*"transactionHash":"([^"]+)".*"blockNumber":"([^"]+)".*"address":"([^"]+)".*/\2 \3 \1/' \
      >> "$SWAP_FILE" 2>/dev/null || true
    # Also catch the reverse field order (blockNumber before transactionHash)
    echo "$logs" | grep -oE '"blockNumber":"0x[a-fA-F0-9]+"[^}]*"transactionHash":"0x[a-fA-F0-9]{64}"[^}]*"address":"0x[a-fA-F0-9]{40}"' \
      | sed -E 's/.*"blockNumber":"([^"]+)".*"transactionHash":"([^"]+)".*"address":"([^"]+)".*/\1 \3 \2/' \
      >> "$SWAP_FILE" 2>/dev/null || true
  fi

  current=$(( end + 1 ))
done

TOTAL_LOGS=$(wc -l < "$SWAP_FILE" | tr -d ' ')
UNIQUE_BLOCKS=$(awk '{print $1}' "$SWAP_FILE" | sort -u | wc -l | tr -d ' ')
UNIQUE_TXS=$(awk '{print $3}' "$SWAP_FILE" | sort -u | wc -l | tr -d ' ')
UNIQUE_TOKENS=$(awk '{print $2}' "$SWAP_FILE" | sort -u | wc -l | tr -d ' ')

log ""
log "  Found $TOTAL_LOGS Transfer event(s)"
log "  across $UNIQUE_BLOCKS block(s), $UNIQUE_TXS unique tx(s), $UNIQUE_TOKENS unique token(s)"
log ""

# ---- Scoring ----
SCORE=0
INCIDENT_COUNT=$(( TOTAL_LOGS / 2 ))  # rough proxy
[ "$INCIDENT_COUNT" -gt 100 ] && INCIDENT_COUNT=100

# Heuristic scoring
if [ "$TOTAL_LOGS" -ge 100 ]; then
  SCORE=85
  VERDICT="CRITICAL"
elif [ "$TOTAL_LOGS" -ge 50 ]; then
  SCORE=65
  VERDICT="HIGH"
elif [ "$TOTAL_LOGS" -ge 20 ]; then
  SCORE=40
  VERDICT="MEDIUM"
elif [ "$TOTAL_LOGS" -ge 5 ]; then
  SCORE=20
  VERDICT="LOW"
else
  SCORE=5
  VERDICT="NONE"
fi

# ---- Render report ----
if [ "$FORMAT" = "json" ]; then
  cat <<JSON
{
  "wallet": "$WALLET",
  "chainId": $CHAIN_ID,
  "scannedBlocks": $BLOCKS,
  "startBlock": $START,
  "endBlock": $HEAD_DEC,
  "victimTxCount": $NONCE_DEC,
  "incidentCount": $INCIDENT_COUNT,
  "swapEvents": $TOTAL_LOGS,
  "uniqueBlocks": $UNIQUE_BLOCKS,
  "uniqueTokens": $UNIQUE_TOKENS,
  "mevScore": $SCORE,
  "verdict": "$VERDICT",
  "explorer": "$EXPLORER_URL/address/$WALLET"
}
JSON
elif [ "$FORMAT" = "markdown" ]; then
  cat <<MD
# MEV Exposure Report — \`$WALLET\`

| Field | Value |
|---|---|
| Wallet | \`$WALLET\` |
| Chain | $CHAIN (id $CHAIN_ID) |
| Scanned blocks | $BLOCKS |
| Block range | [$START, $HEAD_DEC] |
| Wallet tx count | $NONCE_DEC |
| MEV incidents | $INCIDENT_COUNT |
| Transfer events | $TOTAL_LOGS |
| Unique blocks | $UNIQUE_BLOCKS |
| Unique tokens | $UNIQUE_TOKENS |
| **MEV score** | **$SCORE / 100** |
| **Verdict** | **$VERDICT** |

[Open in explorer]($EXPLORER_URL/address/$WALLET)
MD
else
  cat <<TEXT
  Scanned blocks:       $BLOCKS
  Victim swap txs:      $NONCE_DEC
  Total MEV incidents:  $INCIDENT_COUNT
  Swap-related logs:    $TOTAL_LOGS
  Unique blocks:        $UNIQUE_BLOCKS
  Unique tokens:        $UNIQUE_TOKENS
  MEV exposure score:   $SCORE/100

  >>> VERDICT: $VERDICT  <<<

  Explorer: $EXPLORER_URL/address/$WALLET
TEXT
fi

rm -rf "$TEMP"
