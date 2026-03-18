#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid/gated CI jobs are never run for fork pull requests.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"
BUILD_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/build-ghosttykit.yml"
COMPAT_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
EXPECTED_IF="if: github.event_name != 'pull_request' || github.event.pull_request.head.repo.full_name == github.repository"

assert_workflow_guard() {
  local workflow_file="$1"
  if ! grep -Fq "$EXPECTED_IF" "$workflow_file"; then
    echo "FAIL: Missing fork pull_request guard in $workflow_file"
    echo "Expected line:"
    echo "  $EXPECTED_IF"
    exit 1
  fi
}

assert_job_runner_guard() {
  local workflow_file="$1"
  local job_name="$2"
  local runner_label="$3"
  local failure_message="$4"

  if ! awk -v job_header="  ${job_name}:" -v runner_line="runs-on: ${runner_label}" -v guard_text="github.event.pull_request.head.repo.full_name == github.repository" '
    $0 == job_header { in_job=1; next }
    in_job && /^  [^[:space:]]/ { in_job=0 }
    in_job && index($0, runner_line) { saw_runner=1 }
    in_job && index($0, guard_text) { saw_guard=1 }
    END { exit !(saw_runner && saw_guard) }
  ' "$workflow_file"; then
    echo "FAIL: $failure_message"
    exit 1
  fi
}

assert_workflow_guard "$CI_WORKFLOW_FILE"
assert_workflow_guard "$BUILD_WORKFLOW_FILE"
assert_workflow_guard "$COMPAT_WORKFLOW_FILE"

warp_ci_jobs=(
  tests-shard-1-attempt-1
  tests-shard-1-attempt-2
  tests-shard-2-attempt-1
  tests-shard-2-attempt-2
  tests-shard-3-attempt-1
  tests-shard-3-attempt-2
  tests-shard-4-attempt-1
  tests-shard-4-attempt-2
  tests-shard-5-attempt-1
  tests-shard-5-attempt-2
  tests-shard-6-attempt-1
  tests-shard-6-attempt-2
  tests-build-and-lag-attempt-1
  tests-build-and-lag-attempt-2
  ui-display-resolution-regression-attempt-1
  ui-display-resolution-regression-attempt-2
)

hosted_ci_jobs=(
  tests-shard-1
  tests-shard-2
  tests-shard-3
  tests-shard-4
  tests-shard-5
  tests-shard-6
  tests
  tests-build-and-lag
  ui-display-resolution-regression
)

warp_build_jobs=(
  build-ghosttykit-attempt-1
  build-ghosttykit-attempt-2
)

hosted_build_jobs=(
  build-ghosttykit
)

warp_compat_jobs=(
  compat-tests-macos-15-attempt-1
  compat-tests-macos-15-attempt-2
  compat-tests-macos-26-attempt-1
  compat-tests-macos-26-attempt-2
)

hosted_compat_jobs=(
  compat-tests
)

for job_name in "${warp_ci_jobs[@]}"; do
  assert_job_runner_guard \
    "$CI_WORKFLOW_FILE" \
    "$job_name" \
    "warp-macos-15-arm64-6x" \
    "$job_name block must keep both warp-macos-15-arm64-6x runner and fork guard"
  echo "PASS: $job_name WarpBuild runner fork guard is present"
done

for job_name in "${hosted_ci_jobs[@]}"; do
  assert_job_runner_guard \
    "$CI_WORKFLOW_FILE" \
    "$job_name" \
    "ubuntu-latest" \
    "$job_name block must keep both ubuntu-latest runner and fork guard"
  echo "PASS: $job_name hosted runner guard is present"
done

for job_name in "${warp_build_jobs[@]}"; do
  assert_job_runner_guard \
    "$BUILD_WORKFLOW_FILE" \
    "$job_name" \
    "warp-macos-15-arm64-6x" \
    "$job_name block must keep both warp-macos-15-arm64-6x runner and fork guard"
  echo "PASS: $job_name WarpBuild runner fork guard is present"
done

for job_name in "${hosted_build_jobs[@]}"; do
  assert_job_runner_guard \
    "$BUILD_WORKFLOW_FILE" \
    "$job_name" \
    "ubuntu-latest" \
    "$job_name block must keep both ubuntu-latest runner and fork guard"
  echo "PASS: $job_name hosted runner guard is present"
done

for job_name in "${warp_compat_jobs[@]}"; do
  if [[ "$job_name" == compat-tests-macos-26-* ]]; then
    runner_label="warp-macos-26-arm64-6x"
  else
    runner_label="warp-macos-15-arm64-6x"
  fi

  assert_job_runner_guard \
    "$COMPAT_WORKFLOW_FILE" \
    "$job_name" \
    "$runner_label" \
    "$job_name block must keep both $runner_label runner and fork guard"
  echo "PASS: $job_name WarpBuild runner fork guard is present"
done

for job_name in "${hosted_compat_jobs[@]}"; do
  assert_job_runner_guard \
    "$COMPAT_WORKFLOW_FILE" \
    "$job_name" \
    "ubuntu-latest" \
    "$job_name block must keep both ubuntu-latest runner and fork guard"
  echo "PASS: $job_name hosted runner guard is present"
done
