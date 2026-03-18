#!/usr/bin/env bash
# Regression test for bounded WarpBuild unit-shard hangs in CI.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_WORKFLOW_FILE="$ROOT_DIR/.github/workflows/ci.yml"

assert_job_timeout() {
  local job_name="$1"
  local timeout_minutes="$2"

  if ! awk -v job_header="  ${job_name}:" -v timeout_line="timeout-minutes: ${timeout_minutes}" '
    $0 == job_header { in_job=1; next }
    in_job && /^  [^[:space:]]/ { in_job=0 }
    in_job {
      line=$0
      sub(/^[[:space:]]+/, "", line)
      if (line == timeout_line) {
        found=1
      }
    }
    END { exit !found }
  ' "$CI_WORKFLOW_FILE"; then
    echo "FAIL: ${job_name} must keep timeout-minutes: ${timeout_minutes}"
    exit 1
  fi
}

for shard in 1 2 3 4 5 6; do
  for attempt in 1 2; do
    assert_job_timeout "tests-shard-${shard}-attempt-${attempt}" "10"
    echo "PASS: tests-shard-${shard}-attempt-${attempt} timeout is bounded to 10 minutes"
  done
done
