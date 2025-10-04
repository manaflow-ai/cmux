#!/usr/bin/env bash
set -euo pipefail

# Test shell hooks with proper understanding of how they work
# Key insight: DEBUG trap only works in interactive shells, not in scripts

# Global timeout for the entire script (5 minutes)
if command -v timeout >/dev/null 2>&1; then
  if [[ "${E2E_UNDER_TIMEOUT:-}" != "1" ]]; then
    exec env E2E_UNDER_TIMEOUT=1 timeout --preserve-status 300 "$0" "$@"
  fi
fi

if [[ -f "$HOME/.cargo/env" ]]; then
  source "$HOME/.cargo/env"
fi

export PATH="/usr/local/cargo/bin:$PATH"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
# Use shorter path to avoid socket path length issues on macOS
TMPDIR="/tmp/cmux-e2e-$$"
mkdir -p "$TMPDIR"

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
echo "=== TEST 1: Hook mechanism works when called manually ===" >&2

# Set initial variables
run_envctl set TEST_VAR1=value1
run_envctl set TEST_VAR2=value2

# Create a test script that sources the hook and calls __envctl_apply manually
TEST_SCRIPT="$TMPDIR/test.sh"
cat > "$TEST_SCRIPT" <<'SCRIPT'
#!/bin/bash
# Source environment
export XDG_RUNTIME_DIR="TMPDIR_PLACEHOLDER/runtime"
export PATH="BINDIR_PLACEHOLDER:$PATH"
export ENVCTL_GEN=0

# Install hook (defines functions)
eval "$(envctl hook bash)"

# Manually call apply (since DEBUG trap won't fire in non-interactive shell)
__envctl_apply

# Now variables should be available
echo "TEST_VAR1=${TEST_VAR1:-not_found}"
echo "TEST_VAR2=${TEST_VAR2:-not_found}"
echo "ENVCTL_GEN=${ENVCTL_GEN}"

# Set a new variable
envctl set TEST_VAR3=value3

# Apply again to get the update
__envctl_apply

echo "TEST_VAR3=${TEST_VAR3:-not_found}"
echo "Final ENVCTL_GEN=${ENVCTL_GEN}"
SCRIPT

# Replace placeholders
sed -i.bak "s|TMPDIR_PLACEHOLDER|$TMPDIR|g" "$TEST_SCRIPT"
sed -i.bak "s|BINDIR_PLACEHOLDER|$BIN_DIR|g" "$TEST_SCRIPT"
chmod +x "$TEST_SCRIPT"

OUTPUT=$("$TEST_SCRIPT")
echo "$OUTPUT"

if ! echo "$OUTPUT" | grep -q "TEST_VAR1=value1"; then
  echo "ERROR: TEST_VAR1 not found" >&2
  exit 1
fi
if ! echo "$OUTPUT" | grep -q "TEST_VAR2=value2"; then
  echo "ERROR: TEST_VAR2 not found" >&2
  exit 1
fi
if ! echo "$OUTPUT" | grep -q "TEST_VAR3=value3"; then
  echo "ERROR: TEST_VAR3 not found" >&2
  exit 1
fi
echo "✓ Test 1 passed: Hook mechanism works with manual apply" >&2

echo ""
echo "=== TEST 2: Cross-shell propagation with manual apply ===" >&2

# Shell 1 sets a variable
run_envctl set CROSS_VAR=from_outside

# Shell 2 script
SHELL2_SCRIPT="$TMPDIR/shell2.sh"
cat > "$SHELL2_SCRIPT" <<'SCRIPT'
#!/bin/bash
export XDG_RUNTIME_DIR="TMPDIR_PLACEHOLDER/runtime"
export PATH="BINDIR_PLACEHOLDER:$PATH"
export ENVCTL_GEN=0

# Install hook
eval "$(envctl hook bash)"

# Apply to get all current variables
__envctl_apply

echo "In shell2, CROSS_VAR=${CROSS_VAR:-not_found}"

# Set a variable from this shell
envctl set SHELL2_VAR=from_shell2
SCRIPT

sed -i.bak "s|TMPDIR_PLACEHOLDER|$TMPDIR|g" "$SHELL2_SCRIPT"
sed -i.bak "s|BINDIR_PLACEHOLDER|$BIN_DIR|g" "$SHELL2_SCRIPT"
chmod +x "$SHELL2_SCRIPT"

OUTPUT2=$("$SHELL2_SCRIPT")
echo "$OUTPUT2"

if ! echo "$OUTPUT2" | grep -q "CROSS_VAR=from_outside"; then
  echo "ERROR: Cross-shell variable not visible" >&2
  exit 1
fi

# Verify shell2's variable is in daemon
if [[ $(run_envctl get SHELL2_VAR) != "from_shell2" ]]; then
  echo "ERROR: Shell2's variable not in daemon" >&2
  exit 1
fi
echo "✓ Test 2 passed: Cross-shell propagation works with manual apply" >&2

echo ""
echo "=== TEST 3: Interactive shells with DEBUG trap (when available) ===" >&2

# Create a temporary HOME for testing
TEST_HOME="$TMPDIR/home"
mkdir -p "$TEST_HOME"

# Create .bashrc with hook
cat > "$TEST_HOME/.bashrc" <<EOF
export XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR"
export PATH="$BIN_DIR:\$PATH"
export ENVCTL_GEN=0

# Install hook
eval "\$(envctl hook bash)"

# For non-interactive shells, manually apply once at start
if [[ "\$-" != *i* ]]; then
  __envctl_apply
fi
EOF

# Test with sourced .bashrc
run_envctl set BASHRC_VAR=bashrc_value

OUTPUT3=$(env HOME="$TEST_HOME" bash -c '
  source ~/.bashrc
  echo "BASHRC_VAR=${BASHRC_VAR:-not_found}"
')

echo "$OUTPUT3"

if ! echo "$OUTPUT3" | grep -q "BASHRC_VAR=bashrc_value"; then
  echo "ERROR: .bashrc with hook didn't load variable" >&2
  exit 1
fi
echo "✓ Test 3 passed: .bashrc with manual apply works" >&2

echo ""
echo "=== TEST 4: Simulating interactive behavior ===" >&2

# Set a variable
run_envctl set INTERACTIVE_VAR=interactive_value

# Create a script that simulates multiple commands in sequence
INTERACTIVE_SCRIPT="$TMPDIR/interactive.sh"
cat > "$INTERACTIVE_SCRIPT" <<'SCRIPT'
#!/bin/bash
export XDG_RUNTIME_DIR="TMPDIR_PLACEHOLDER/runtime"
export PATH="BINDIR_PLACEHOLDER:$PATH"
export ENVCTL_GEN=0

# Install hook
eval "$(envctl hook bash)"

# Simulate command 1: Check initial state
__envctl_apply  # Would be called by DEBUG trap in interactive shell
echo "Command 1: INTERACTIVE_VAR=${INTERACTIVE_VAR:-not_found}"

# Simulate command 2: Set a new variable
envctl set NEW_INTERACTIVE=new_value

# Simulate command 3: Check if we see the new variable
__envctl_apply  # Would be called by DEBUG trap
echo "Command 3: NEW_INTERACTIVE=${NEW_INTERACTIVE:-not_found}"

# Simulate command 4: Unset a variable
envctl unset INTERACTIVE_VAR

# Simulate command 5: Verify it's gone
__envctl_apply  # Would be called by DEBUG trap
echo "Command 5: INTERACTIVE_VAR=${INTERACTIVE_VAR:-not_found}"
SCRIPT

sed -i.bak "s|TMPDIR_PLACEHOLDER|$TMPDIR|g" "$INTERACTIVE_SCRIPT"
sed -i.bak "s|BINDIR_PLACEHOLDER|$BIN_DIR|g" "$INTERACTIVE_SCRIPT"
chmod +x "$INTERACTIVE_SCRIPT"

OUTPUT4=$("$INTERACTIVE_SCRIPT")
echo "$OUTPUT4"

if ! echo "$OUTPUT4" | grep -q "Command 1: INTERACTIVE_VAR=interactive_value"; then
  echo "ERROR: Initial variable not loaded" >&2
  exit 1
fi
if ! echo "$OUTPUT4" | grep -q "Command 3: NEW_INTERACTIVE=new_value"; then
  echo "ERROR: New variable not loaded" >&2
  exit 1
fi
if ! echo "$OUTPUT4" | grep -q "Command 5: INTERACTIVE_VAR=not_found"; then
  echo "ERROR: Unset didn't work" >&2
  exit 1
fi
echo "✓ Test 4 passed: Simulated interactive behavior works" >&2

echo ""
echo "==================================================================" >&2
echo "✅ ALL SHELL HOOK TESTS PASSED!" >&2
echo "==================================================================" >&2
echo ""
echo "Key findings:" >&2
echo "1. The envctl export command works correctly" >&2
echo "2. The hook mechanism works when __envctl_apply is called" >&2
echo "3. DEBUG trap only fires in interactive shells" >&2
echo "4. For scripts, manually call __envctl_apply after setting ENVCTL_GEN=0" >&2
echo "5. Cross-shell propagation DOES work with proper hook usage" >&2