#!/usr/bin/env bash
set -euo pipefail

# Global timeout for the entire script (5 minutes)
if command -v timeout >/dev/null 2>&1; then
  # Re-exec with timeout if not already under timeout
  if [[ "${E2E_UNDER_TIMEOUT:-}" != "1" ]]; then
    exec env E2E_UNDER_TIMEOUT=1 timeout --preserve-status 300 "$0" "$@"
  fi
fi

if [[ -f "$HOME/.cargo/env" ]]; then
  # Load cargo environment in minimal containers
  # shellcheck disable=SC1090
  source "$HOME/.cargo/env"
fi

export PATH="/usr/local/cargo/bin:$PATH"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMPDIR=$(mktemp -d -t cmux-e2e-XXXXXX)

# When running in Docker, binaries are already built
if [[ "${IN_DOCKER:-}" == "1" ]]; then
  BIN_DIR="/app/target/debug"
  echo "=== Using pre-built binaries in Docker ===" >&2
else
  CARGO_TARGET_DIR="$TMPDIR/target"
  export CARGO_TARGET_DIR
  BIN_DIR="$CARGO_TARGET_DIR/debug"

  echo "=== Building envd/envctl binaries ===" >&2
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status 60 cargo build --locked --bins
  else
    cargo build --locked --bins
  fi
  echo "Build completed successfully" >&2
fi

ENVD_BIN="$BIN_DIR/envd"
ENVCTL_BIN="$BIN_DIR/envctl"

cleanup() {
  # Kill any daemon we started
  if [[ -n "${DAEMON_PID:-}" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    echo "Cleaning up daemon PID $DAEMON_PID" >&2
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
  fi

  # Also try to kill by name
  pkill -f "$ENVD_BIN" 2>/dev/null || true

  rm -rf "$TMPDIR"
}
trap cleanup EXIT INT TERM

export XDG_RUNTIME_DIR="$TMPDIR/runtime"
mkdir -p "$XDG_RUNTIME_DIR/cmux-envd"
export PATH="$BIN_DIR:$PATH"

# Helper function to run envctl with timeout
run_envctl() {
  if command -v timeout >/dev/null 2>&1; then
    timeout --preserve-status 15 "$ENVCTL_BIN" "$@"
  else
    "$ENVCTL_BIN" "$@"
  fi
}

echo ""
echo "=== TEST 1: Basic envctl commands with manual daemon start ===" >&2
echo "Starting envd daemon manually..." >&2
"$ENVD_BIN" >/tmp/envd.log 2>&1 &
DAEMON_PID=$!
echo "Started daemon with PID $DAEMON_PID" >&2

# Give it a moment to start
sleep 0.5

# Check if daemon is still running
if ! kill -0 "$DAEMON_PID" 2>/dev/null; then
  echo "ERROR: Daemon died immediately!" >&2
  echo "Daemon log:" >&2
  cat /tmp/envd.log 2>&1 || echo "No log file" >&2
  exit 1
fi

# Wait for daemon socket
i=0
SOCK="$XDG_RUNTIME_DIR/cmux-envd/envd.sock"
MAX_WAIT=100  # 10 seconds
echo "Waiting for socket at: $SOCK" >&2
until [[ -S "$SOCK" ]]; do
  ((i++))
  if (( i > MAX_WAIT )); then
    echo "ERROR: envd socket did not appear after $i attempts" >&2
    echo "Checking runtime dir:" >&2
    ls -la "$XDG_RUNTIME_DIR/cmux-envd/" 2>&1 || echo "No socket dir" >&2
    echo "Daemon log:" >&2
    cat /tmp/envd.log 2>&1 || echo "No log file" >&2
    exit 1
  fi
  sleep 0.1
done
echo "Daemon ready after $i attempts" >&2

# Test ping
echo "Testing ping..." >&2
PING_OUT=$(run_envctl ping)
if ! grep -q "pong" <<<"$PING_OUT"; then
  echo "ERROR: ping failed, got: $PING_OUT" >&2
  exit 1
fi

# Test set/get/unset
echo "Testing set/get/unset..." >&2
run_envctl set TEST_VAR1=value1
if [[ $(run_envctl get TEST_VAR1) != "value1" ]]; then
  echo "ERROR: get failed" >&2
  exit 1
fi
run_envctl unset TEST_VAR1
echo "✓ Test 1 passed: Basic commands work" >&2

echo ""
echo "=== TEST 2: Lazy daemon startup ===" >&2
# Kill the daemon
if kill -0 "$DAEMON_PID" 2>/dev/null; then
  kill "$DAEMON_PID"
  wait "$DAEMON_PID" 2>/dev/null || true
fi
unset DAEMON_PID

# Remove socket and verify daemon is not running
rm -f "$SOCK"
sleep 0.5

if [[ -S "$SOCK" ]]; then
  echo "ERROR: Socket still exists" >&2
  exit 1
fi

echo "Daemon stopped, testing lazy startup via envctl..." >&2

# This should start the daemon lazily
run_envctl set LAZY_TEST=lazy_value

# Check if daemon started
if [[ ! -S "$SOCK" ]]; then
  echo "ERROR: Daemon did not start lazily" >&2
  exit 1
fi

# Verify the value was set
if [[ $(run_envctl get LAZY_TEST) != "lazy_value" ]]; then
  echo "ERROR: Lazy startup didn't preserve value" >&2
  exit 1
fi
run_envctl unset LAZY_TEST
echo "✓ Test 2 passed: Lazy daemon startup works" >&2

# Get the new daemon PID for cleanup
DAEMON_PID=$(pgrep -f "$ENVD_BIN" | head -1)

echo ""
echo "=== TEST 3: Multiple envctl operations ===" >&2
echo "Testing bulk operations..." >&2

# Set multiple variables
run_envctl set VAR1=val1
run_envctl set VAR2=val2
run_envctl set VAR3=val3

# Get all our variables
if [[ $(run_envctl get VAR1) != "val1" ]]; then
  echo "ERROR: VAR1 not found" >&2
  exit 1
fi
if [[ $(run_envctl get VAR2) != "val2" ]]; then
  echo "ERROR: VAR2 not found" >&2
  exit 1
fi
if [[ $(run_envctl get VAR3) != "val3" ]]; then
  echo "ERROR: VAR3 not found" >&2
  exit 1
fi

# Unset all
run_envctl unset VAR1
run_envctl unset VAR2
run_envctl unset VAR3
echo "✓ Test 3 passed: Multiple operations work" >&2

echo ""
echo "=== TEST 4: Persistence across envctl calls ===" >&2

# Set a variable
run_envctl set PERSIST_VAR=persist_value

# Call envctl from different process contexts
OUT1=$(bash -c "export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'; '$ENVCTL_BIN' get PERSIST_VAR")
if [[ "$OUT1" != "persist_value" ]]; then
  echo "ERROR: Variable not persistent across calls, got: $OUT1" >&2
  exit 1
fi

OUT2=$(sh -c "export XDG_RUNTIME_DIR='$XDG_RUNTIME_DIR'; '$ENVCTL_BIN' get PERSIST_VAR")
if [[ "$OUT2" != "persist_value" ]]; then
  echo "ERROR: Variable not persistent in sh, got: $OUT2" >&2
  exit 1
fi

run_envctl unset PERSIST_VAR
echo "✓ Test 4 passed: Variables persist across envctl calls" >&2

echo ""
echo "=== TEST 5: Concurrent envctl operations ===" >&2

# Launch multiple envctl operations in parallel
for i in {1..5}; do
  (run_envctl set "CONCURRENT_$i=value_$i") &
done
wait

# Verify all were set
for i in {1..5}; do
  VAL=$(run_envctl get "CONCURRENT_$i")
  if [[ "$VAL" != "value_$i" ]]; then
    echo "ERROR: CONCURRENT_$i not set correctly, got: $VAL" >&2
    exit 1
  fi
done

# Unset all
for i in {1..5}; do
  run_envctl unset "CONCURRENT_$i"
done
echo "✓ Test 5 passed: Concurrent operations work" >&2

echo ""
echo "==================================================================" >&2
echo "✅ ALL E2E TESTS PASSED SUCCESSFULLY!" >&2
echo "==================================================================" >&2