#!/usr/bin/env bash
# Regression test for CI unit-test hard-failure detection.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci-unit-test-output-guard.sh"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [ ! -x "$SCRIPT" ]; then
  echo "FAIL: missing executable hard-failure guard at $SCRIPT" >&2
  exit 1
fi

if ! grep -Fq './tests/test_ci_unit_test_output_guard.sh' "$WORKFLOW_FILE"; then
  echo "FAIL: ci.yml must run the unit-test hard-failure guard test" >&2
  exit 1
fi

if ! grep -Fq './scripts/ci-unit-test-output-guard.sh "$EXIT_CODE" /tmp/test-output.txt' "$WORKFLOW_FILE"; then
  echo "FAIL: ci.yml must run the hard-failure guard before parsing XCTest summaries" >&2
  exit 1
fi

write_log() {
  local name="$1"
  shift
  printf '%s\n' "$@" > "$TMP_DIR/$name.log"
}

expect_pass() {
  local exit_code="$1"
  local log_name="$2"
  if ! "$SCRIPT" "$exit_code" "$TMP_DIR/$log_name.log" > "$TMP_DIR/$log_name.out" 2>&1; then
    echo "FAIL: expected $log_name to pass guard" >&2
    cat "$TMP_DIR/$log_name.out" >&2
    exit 1
  fi
}

expect_fail() {
  local exit_code="$1"
  local log_name="$2"
  local expected="$3"
  if "$SCRIPT" "$exit_code" "$TMP_DIR/$log_name.log" > "$TMP_DIR/$log_name.out" 2>&1; then
    echo "FAIL: expected $log_name to fail guard" >&2
    exit 1
  fi
  if ! grep -Fq "$expected" "$TMP_DIR/$log_name.out"; then
    echo "FAIL: $log_name did not report expected reason: $expected" >&2
    cat "$TMP_DIR/$log_name.out" >&2
    exit 1
  fi
}

write_log expected-fail \
  "Test Suite 'Selected tests' failed." \
  "Executed 1 test, with 1 failure (0 unexpected) in 0.1 seconds"
expect_pass 65 expected-fail

write_log timeout-after-summary \
  "Executed 1 test, with 1 failure (0 unexpected) in 0.1 seconds" \
  "xcodebuild unit test timeout after 900s; terminating" \
  "** BUILD INTERRUPTED **"
expect_fail 124 timeout-after-summary "xcodebuild watchdog timeout"

write_log build-interrupted \
  "Executed 1 test, with 1 failure (0 unexpected) in 0.1 seconds" \
  "** BUILD INTERRUPTED **"
expect_fail 65 build-interrupted "xcodebuild build interruption"

write_log swift-crash \
  "Executed 1 test, with 1 failure (0 unexpected) in 0.1 seconds" \
  "Program crashed: Signal 11: Backtracing from 0x18b5c4028..."
expect_fail 65 swift-crash "Swift crash output"

write_log swift-backtrace-prompt \
  "Executed 1 test, with 1 failure (0 unexpected) in 0.1 seconds" \
  "Press space to interact, D to debug, or any other key to quit (1s)"
expect_fail 65 swift-backtrace-prompt "Swift crash output"

echo "PASS: CI unit-test output guard fails hard-failure logs"
