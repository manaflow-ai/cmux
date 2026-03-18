#!/usr/bin/env bash
# Regression test for retry and wrapper logic on continue-on-error CI jobs.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"
BUILD_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/build-ghosttykit.yml"
COMPAT_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
VERIFY_SCRIPT="$ROOT_DIR/scripts/verify_retry_result.sh"

extract_job_block() {
  local workflow_file="$1"
  local job_name="$2"

  awk -v job_header="  ${job_name}:" '
    $0 == job_header { in_job=1; print; next }
    in_job && /^  [^[:space:]]/ { exit }
    in_job { print }
  ' "$workflow_file"
}

assert_retry_guard_uses_completed_output() {
  local workflow_file="$1"
  local job_name="$2"
  local block
  local if_line

  block="$(extract_job_block "$workflow_file" "$job_name")"
  if [ -z "$block" ]; then
    echo "FAIL: missing job block for $job_name"
    exit 1
  fi

  if_line="$(printf '%s\n' "$block" | grep -m1 '^[[:space:]]*if:')"
  if [ -z "$if_line" ]; then
    echo "FAIL: missing if: line for $job_name"
    exit 1
  fi

  if [[ "$if_line" != *"outputs.completed != 'true'"* ]]; then
    echo "FAIL: $job_name retry guard must key off outputs.completed"
    exit 1
  fi

  if [[ "$if_line" != *"outputs.passed != 'true'"* ]]; then
    echo "FAIL: $job_name retry guard must only retry when the first attempt did not pass"
    exit 1
  fi

  if [[ "$if_line" == *".result"* ]]; then
    echo "FAIL: $job_name retry guard must not depend on needs.<job>.result"
    exit 1
  fi

  if [[ "$if_line" == *"outputs.test_started"* ]] || [[ "$if_line" == *"outputs.build_started"* ]]; then
    echo "FAIL: $job_name retry guard must not depend on started-only outputs"
    exit 1
  fi
}

assert_job_block_contains() {
  local workflow_file="$1"
  local job_name="$2"
  local pattern="$3"
  local message="$4"
  local block

  block="$(extract_job_block "$workflow_file" "$job_name")"
  if [ -z "$block" ]; then
    echo "FAIL: missing job block for $job_name"
    exit 1
  fi

  if ! printf '%s\n' "$block" | grep -Fq -- "$pattern"; then
    echo "FAIL: $message"
    exit 1
  fi
}

assert_retry_script_exit() {
  local expected_exit="$1"
  shift

  local output
  local status
  set +e
  output="$("$VERIFY_SCRIPT" "$@" 2>&1)"
  status=$?
  set -e

  if [ "$status" -ne "$expected_exit" ]; then
    echo "FAIL: verify_retry_result.sh exited $status, expected $expected_exit"
    printf '%s\n' "$output"
    exit 1
  fi
}

assert_retry_script_exit \
  0 \
  "Unit test shard" \
  "success" "true" "true" \
  "skipped" "" ""

assert_retry_script_exit \
  0 \
  "Unit test shard" \
  "cancelled" "" "" \
  "success" "true" "true"

assert_retry_script_exit \
  1 \
  "Unit test shard" \
  "failure" "true" "" \
  "skipped" "" ""

for shard in 1 2 3 4 5 6; do
  assert_retry_guard_uses_completed_output \
    "$CI_WORKFLOW_FILE" \
    "tests-shard-${shard}-attempt-2"

  assert_job_block_contains \
    "$CI_WORKFLOW_FILE" \
    "tests-shard-${shard}" \
    'scripts/verify_retry_result.sh' \
    "tests-shard-${shard} wrapper must use the shared retry-result verifier"
done

assert_retry_guard_uses_completed_output \
  "$CI_WORKFLOW_FILE" \
  "tests-build-and-lag-attempt-2"

assert_job_block_contains \
  "$CI_WORKFLOW_FILE" \
  "tests-build-and-lag" \
  'scripts/verify_retry_result.sh' \
  "tests-build-and-lag wrapper must use the shared retry-result verifier"

assert_retry_guard_uses_completed_output \
  "$CI_WORKFLOW_FILE" \
  "ui-display-resolution-regression-attempt-2"

assert_job_block_contains \
  "$CI_WORKFLOW_FILE" \
  "ui-display-resolution-regression" \
  'scripts/verify_retry_result.sh' \
  "ui-display-resolution-regression wrapper must use the shared retry-result verifier"

assert_retry_guard_uses_completed_output \
  "$BUILD_WORKFLOW_FILE" \
  "build-ghosttykit-attempt-2"

assert_job_block_contains \
  "$BUILD_WORKFLOW_FILE" \
  "build-ghosttykit" \
  'scripts/verify_retry_result.sh' \
  "build-ghosttykit wrapper must use the shared retry-result verifier"

assert_retry_guard_uses_completed_output \
  "$COMPAT_WORKFLOW_FILE" \
  "compat-tests-macos-15-attempt-2"

assert_retry_guard_uses_completed_output \
  "$COMPAT_WORKFLOW_FILE" \
  "compat-tests-macos-26-attempt-2"

assert_job_block_contains \
  "$CI_WORKFLOW_FILE" \
  "tests-shard-1-attempt-1" \
  'completed: ${{ steps.mark-attempt-complete.outputs.value }}' \
  "tests-shard-1-attempt-1 must expose completion after its post-unit regressions run"

assert_job_block_contains \
  "$CI_WORKFLOW_FILE" \
  "tests-shard-1-attempt-1" \
  'passed: ${{ steps.mark-attempt-pass.outputs.value }}' \
  "tests-shard-1-attempt-1 must only pass after its post-unit regressions succeed"

assert_job_block_contains \
  "$CI_WORKFLOW_FILE" \
  "tests-shard-1-attempt-2" \
  'completed: ${{ steps.mark-attempt-complete.outputs.value }}' \
  "tests-shard-1-attempt-2 must expose completion after its post-unit regressions run"

assert_job_block_contains \
  "$CI_WORKFLOW_FILE" \
  "tests-shard-1-attempt-2" \
  'passed: ${{ steps.mark-attempt-pass.outputs.value }}' \
  "tests-shard-1-attempt-2 must only pass after its post-unit regressions succeed"

assert_job_block_contains \
  "$COMPAT_WORKFLOW_FILE" \
  "compat-tests" \
  'scripts/verify_retry_result.sh' \
  "compat-tests wrapper must use the shared retry-result verifier"

echo "PASS: retry guards key off completed outputs and wrapper semantics stay correct"
