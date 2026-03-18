#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
ACTION_FILE="$ROOT_DIR/.github/actions/run-macos-compat-check/action.yml"
STEP_BLOCK="$(
  sed -n '/^    - name: Run compatibility unit test slice$/,/^    - name:/p' "$ACTION_FILE" | sed '$d'
)"

extract_job_block() {
  local job_name="$1"

  awk -v job_header="  ${job_name}:" '
    $0 == job_header { in_job=1; print; next }
    in_job && /^  [^[:space:]]/ { exit }
    in_job { print }
  ' "$WORKFLOW_FILE"
}

require_in_block() {
  local block="$1"
  local pattern="$2"
  local message="$3"
  if ! grep -q -- "$pattern" <<<"$block"; then
    echo "FAIL: $message"
    exit 1
  fi
}

MACOS_15_BLOCK="$(extract_job_block "compat-tests-macos-15-attempt-1")"
MACOS_26_BLOCK="$(extract_job_block "compat-tests-macos-26-attempt-1")"

if [ -z "$MACOS_15_BLOCK" ]; then
  echo "FAIL: compat workflow is missing the macOS 15 retry lane"
  exit 1
fi

if [ -z "$MACOS_26_BLOCK" ]; then
  echo "FAIL: compat workflow is missing the macOS 26 retry lane"
  exit 1
fi

require_in_block "$MACOS_15_BLOCK" "uses: ./.github/actions/run-macos-compat-check" "macOS 15 compat lane must use the shared compat action"
require_in_block "$MACOS_15_BLOCK" "compat_test_filters: |" "macOS 15 compat lane must define explicit compatibility test filters"
require_in_block "$MACOS_15_BLOCK" "cmuxTests/AppDelegateLaunchServicesRegistrationTests" "macOS 15 compat filters are missing"
require_in_block "$MACOS_26_BLOCK" "uses: ./.github/actions/run-macos-compat-check" "macOS 26 compat lane must use the shared compat action"
require_in_block "$MACOS_26_BLOCK" "compat_test_filters: |" "macOS 26 compat lane must define explicit compatibility test filters"
require_in_block "$MACOS_26_BLOCK" "cmuxTests/ZshShellIntegrationHandoffTests" "macOS 26 compat filters are missing"

if [ -z "$STEP_BLOCK" ]; then
  echo "FAIL: compat action is missing the compatibility test-slice step"
  exit 1
fi

if ! grep -q -- "while IFS= read -r filter; do" <<<"$STEP_BLOCK"; then
  echo "FAIL: compat step must still load test filters into an array"
  exit 1
fi

if ! grep -q -- "-scheme cmux-unit" <<<"$STEP_BLOCK"; then
  echo "FAIL: compat step must run the cmux-unit scheme"
  exit 1
fi

if ! grep -q -- "test 2>&1" <<<"$STEP_BLOCK"; then
  echo "FAIL: compat step must execute unit tests"
  exit 1
fi

if grep -q -- "scripts/unit_test_shard_args.py" <<<"$STEP_BLOCK"; then
  echo "FAIL: compat workflow must not rely on shard-based test selection inside the compat step"
  exit 1
fi

echo "PASS: macOS compat workflow keeps an explicit compatibility unit test slice"
