#!/usr/bin/env bash
# Regression test for CI unit-test SwiftPM dependency flake handling.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"
COMPAT_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
DEPOT_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/test-depot.yml"
ISOLATED_RUNNER="$ROOT_DIR/scripts/ci/run-cmux-unit-tests-isolated.sh"

REQUIRED_PATTERNS=(
  "run_unit_tests()"
  "Could not resolve package dependencies"
  "rm -rf ~/Library/Caches/org.swift.swiftpm"
  'rm -rf "$DERIVED_DATA_PATH"'
  'DERIVED_DATA_PATH="$PWD/.ci-derived-data/unit-tests"'
  'CMUX_UNIT_TEST_SHARD_INDEX="${{ matrix.shard_index }}"'
  'CMUX_UNIT_TEST_SHARD_COUNT="${{ matrix.shard_count }}"'
  "scripts/ci/run-cmux-unit-tests-isolated.sh"
  "run_unit_tests | tee /tmp/test-output.txt"
  "selected cmuxTests XCTestCase classes and Swift Testing suites passed in shard-.* batches"
  "Unit tests failed"
  'exit "$EXIT_CODE"'
)

for pattern in "${REQUIRED_PATTERNS[@]}"; do
  if ! grep -Fq -- "$pattern" "$WORKFLOW_FILE"; then
    echo "FAIL: Missing pattern in ci.yml: $pattern"
    exit 1
  fi
done

if grep -Fq 'grep -q "(0 unexpected)"' "$WORKFLOW_FILE" "$COMPAT_WORKFLOW_FILE"; then
  echo "FAIL: unit-test workflows must not convert broad XCTest expected failures into passing CI"
  exit 1
fi

if ! grep -Fq 'exit "$EXIT_CODE"' "$COMPAT_WORKFLOW_FILE"; then
  echo "FAIL: ci-macos-compat.yml must propagate unexpected unit-test exit codes"
  exit 1
fi

for file in "$COMPAT_WORKFLOW_FILE" "$DEPOT_WORKFLOW_FILE"; do
  if ! grep -Fq -- 'scripts/ci/run-cmux-unit-tests-isolated.sh' "$file"; then
    echo "FAIL: $(basename "$file") must run the class-sharded app-host unit-test runner"
    exit 1
  fi
done

ISOLATED_RUNNER_PATTERNS=(
  "build-for-testing"
  "test-without-building"
  '-only-testing:cmuxTests/$class'
  '"${ONLY_TESTING_ARGS[@]}"'
  'env -u SSH_AUTH_SOCK'
  'CMUX_UNIT_TEST_BATCH_SIZE must be a positive integer'
  'HOME="$home_path"'
  'CFFIXED_USER_HOME="$home_path"'
  'CMUX_UI_TEST_SUPPRESS_SYSTEM_NOTIFICATIONS=1'
  'RUSTUP_HOME="$ORIGINAL_HOME/.rustup" CARGO_HOME="$ORIGINAL_HOME/.cargo"'
	  'run_xctest_batch()'
  'executed_test_count()'
  'candidate_kind = "xctest"'
  '\bfunc\s+test[A-Za-z0-9_]*\s*\('
  '\@Test\b'
  '\@Suite\b'
  'assert_executed_tests "$BATCH_LABEL" "$BATCH_LOG" "$BATCH_RESULT"'
  'Rerunning full $BATCH_LABEL after crash-reported method retries'
  'run_xctest_batch "$rerun_label" "$rerun_log" "$rerun_result" "$rerun_home" "${ONLY_TESTING_ARGS[@]}"'
  'assert_executed_tests "$rerun_label" "$rerun_log" "$rerun_result"'
  'reported zero executed tests'
	  'Retrying ${#CRASH_RETRY_TESTS[@]} crash-reported XCTest methods from $BATCH_LABEL in fresh app-host processes'
	  'in_flight_test = test_identifier'
	  'Restarting after unexpected exit, crash, or test timeout'
  'retry_identifier="${test_identifier#cmuxTests/}"'
  'retry_identifier="${retry_identifier//\\\\/}"'
  'retry_identifier="${retry_identifier/./\/}"'
  'retry_only_testing="cmuxTests/$retry_identifier"'
  '"-only-testing:$retry_only_testing"'
  'retry_executed_count="$(executed_test_count "$retry_log" "$retry_result")"'
  'retry_suite_identifier="${retry_identifier%%/*}"'
  'retry_suite_only_testing="cmuxTests/$retry_suite_identifier"'
  'method selector reported zero tests; retrying containing suite'
  'run_xctest_batch "$retry_suite_label" "$retry_suite_log" "$retry_suite_result" "$retry_suite_home" "-only-testing:$retry_suite_only_testing"'
  'assert_executed_tests "$retry_suite_label" "$retry_suite_log" "$retry_suite_result"'
  'PASS $BATCH_LABEL after crash-reported XCTest method retries'
  'SHARD_INDEX="${CMUX_UNIT_TEST_SHARD_INDEX:-0}"'
  'SHARD_COUNT="${CMUX_UNIT_TEST_SHARD_COUNT:-1}"'
  'class_hash="$(printf '\''%s'\'' "$test_identifier" | cksum | awk '\''{print $1}'\'')"'
  'if [ $((class_hash % SHARD_COUNT)) -eq "$SHARD_INDEX" ]; then'
  'BATCH_SIZE="${CMUX_UNIT_TEST_BATCH_SIZE:-1}"'
  'BATCH_TIMEOUT_SECONDS="${CMUX_UNIT_TEST_BATCH_TIMEOUT_SECONDS:-900}"'
  'Timed out after ${BATCH_TIMEOUT_SECONDS}s running $label; terminating xcodebuild'
  'FAIL $label timed out after ${BATCH_TIMEOUT_SECONDS}s'
  'tail -n 1200 "$BATCH_LOG"'
  'exit 124'
  'SWIFT_COMPILER_SUPPORTS_6_2="$('
  'xcrun swift -e'
  "compiler\\(>=\\s*6\\.2\\)"
  "Test Suite 'Selected tests' passed"
  "All \${#SELECTED_TEST_IDENTIFIERS[@]} selected cmuxTests XCTestCase classes and Swift Testing suites passed in \$SHARD_LABEL batches"
)

for pattern in "${ISOLATED_RUNNER_PATTERNS[@]}"; do
  if ! grep -Fq -- "$pattern" "$ISOLATED_RUNNER"; then
    echo "FAIL: run-cmux-unit-tests-isolated.sh missing pattern: $pattern"
    exit 1
  fi
done

if grep -Fq -- "-skip-testing" "$ISOLATED_RUNNER"; then
  echo "FAIL: run-cmux-unit-tests-isolated.sh must not skip cmuxTests classes"
  exit 1
fi

normalize_retry_identifier() {
  local test_identifier="$1"
  local retry_identifier
  retry_identifier="${test_identifier#cmuxTests/}"
  retry_identifier="${retry_identifier//\\/}"
  retry_identifier="${retry_identifier/./\/}"
  printf 'cmuxTests/%s\n' "$retry_identifier"
}

if [ "$(normalize_retry_identifier 'CLIHookNoResponseTests\/genericLifecycleFeedTelemetryDoesNotWaitForSocketResponse')" != "cmuxTests/CLIHookNoResponseTests/genericLifecycleFeedTelemetryDoesNotWaitForSocketResponse" ]; then
  echo "FAIL: retry selector normalization must strip XCTest escaped slash backslashes"
  exit 1
fi

if [ "$(normalize_retry_identifier 'CLIHookNoResponseTests.genericLifecycleFeedTelemetryDoesNotWaitForSocketResponse')" != "cmuxTests/CLIHookNoResponseTests/genericLifecycleFeedTelemetryDoesNotWaitForSocketResponse" ]; then
  echo "FAIL: retry selector normalization must convert XCTest dot identifiers to -only-testing paths"
  exit 1
fi

if ! grep -Fq 'echo "Unit tests failed"' "$DEPOT_WORKFLOW_FILE"; then
  echo "FAIL: test-depot.yml must report nonzero unit-test exits as failures"
  exit 1
fi

if ! grep -Fq 'exit "$EXIT_CODE"' "$DEPOT_WORKFLOW_FILE"; then
  echo "FAIL: test-depot.yml must propagate nonzero unit-test exit codes"
  exit 1
fi

echo "PASS: CI unit-test SwiftPM retry and failure propagation guards are present"
