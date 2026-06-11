#!/usr/bin/env bash
# Regression test for CI unit-test SwiftPM dependency flake handling.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT

mkdir -p "$TEMP_DIR/home"
MARKER="$TEMP_DIR/retried"
LOG_FILE="$TEMP_DIR/retry.log"
OUTPUT_FILE="$TEMP_DIR/test-output.txt"
DERIVED_DATA="$TEMP_DIR/DerivedData"

HOME="$TEMP_DIR/home" \
CMUX_FAKE_RETRY_MARKER="$MARKER" \
CMUX_UNIT_TEST_OUTPUT_FILE="$OUTPUT_FILE" \
CMUX_DERIVED_DATA_PATH="$DERIVED_DATA" \
CMUX_UNIT_TEST_FAKE_COMMAND='if [ ! -f "$CMUX_FAKE_RETRY_MARKER" ]; then touch "$CMUX_FAKE_RETRY_MARKER"; echo "Could not resolve package dependencies"; exit 74; fi; echo "Retry succeeded"; exit 0' \
  "$ROOT_DIR/scripts/ci/run-unit-tests-with-failure-gate.sh" >"$LOG_FILE" 2>&1

if ! grep -Fq "SwiftPM package resolution failed, clearing caches and retrying once" "$LOG_FILE"; then
  echo "FAIL: unit-test gate did not report SwiftPM retry"
  cat "$LOG_FILE"
  exit 1
fi

if ! grep -Fq "Retry succeeded" "$LOG_FILE"; then
  echo "FAIL: unit-test gate did not rerun after SwiftPM failure"
  cat "$LOG_FILE"
  exit 1
fi

echo "PASS: CI unit-test SwiftPM retry guard is present"
