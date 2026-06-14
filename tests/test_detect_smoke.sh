#!/bin/bash
# Smoke test for MEVREP / MEV Exposure Reporter (Foundry/bash port, v2.0.0).
# Verifies the CLI parses, help text works offline, and error paths are clear.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(dirname "$SCRIPT_DIR")"
SCRIPT="$SKILL_DIR/scripts/detect.sh"

PASS=0
FAIL=0

# run <name> <expected-substring> <args...>
run() {
  local name="$1"
  local expected="$2"
  shift 2
  local out
  out=$(bash "$SCRIPT" "$@" 2>&1 || true)
  if echo "$out" | grep -qF -- "$expected"; then
    echo "  OK: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "       expected substring: $expected"
    echo "       actual: $(echo "$out" | head -3)"
    FAIL=$((FAIL + 1))
  fi
}

echo "Test 1: --help works (no cast required)"
run "help text present" "MEVREP" --help

echo "Test 2: no --wallet shows usage"
run "no-wallet shows usage" "wallet required"

echo "Test 3: unknown flag rejected"
run "unknown flag rejected" "Unknown flag" --foo

echo "Test 4: bad wallet address rejected"
run "bad wallet rejected" "0x-prefixed 20-byte hex" --wallet not-hex

echo "Test 5: bad chain rejected"
run "bad chain rejected" "Unknown chain" \
  --wallet 0x67992af9a87f2d6a3062c333d8a06abbe3929438 --chain bogus

echo "Test 6: bad blocks rejected"
run "bad blocks rejected" "positive integer" \
  --wallet 0x67992af9a87f2d6a3062c333d8a06abbe3929438 --blocks -1

echo "Test 7: too-large blocks rejected"
run "too-large blocks rejected" "cannot exceed 100000" \
  --wallet 0x67992af9a87f2d6a3062c333d8a06abbe3929438 --blocks 999999

echo "Test 8: bad format rejected"
run "bad format rejected" "Unknown format" \
  --wallet 0x67992af9a87f2d6a3062c333d8a06abbe3929438 --format xml

echo "Test 9: cast-missing error is clear (only when cast is not installed)"
if ! command -v cast >/dev/null 2>&1; then
  run "cast-missing error clear" "not found" \
    --wallet 0x67992af9a87f2d6a3062c333d8a06abbe3929438
else
  echo "  SKIP: cast is installed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ] || exit 1
