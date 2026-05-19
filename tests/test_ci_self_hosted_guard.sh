#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid CI jobs use WarpBuild runners.
# Fork PRs are gated by GitHub's built-in "Require approval for outside
# collaborators" setting, so workflow-level fork guards are not needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
GHOSTTYKIT_FILE="$ROOT_DIR/.github/workflows/build-ghosttykit.yml"
COMPAT_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"

check_warp_runner() {
  local file="$1" job="$2" expected="${3:-}"
  if ! awk -v job="$job" -v expected="$expected" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]]/ { in_job=0 }
    in_job && expected != "" && /runs-on:/ && index($0, expected) { saw_warp=1 }
    in_job && expected != "" && /os:/ && index($0, expected) { saw_warp=1 }
    in_job && expected == "" && /runs-on:.*warp-macos-.*-arm64/ { saw_warp=1 }
    in_job && expected == "" && /os: warp-macos-.*-arm64/ { saw_warp=1 }
    END { exit !(saw_warp) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must default to a WarpBuild runner"
    exit 1
  fi
  echo "PASS: $job WarpBuild default runner is present"
}

# ci.yml jobs
check_warp_runner "$CI_FILE" "tests" "warp-macos-15-arm64-6x"
check_warp_runner "$CI_FILE" "tests-build-and-lag" "warp-macos-15-arm64-6x"
check_warp_runner "$CI_FILE" "release-build" "warp-macos-26-arm64-6x"
check_warp_runner "$CI_FILE" "ui-regressions" "warp-macos-15-arm64-6x"

# build-ghosttykit.yml
check_warp_runner "$GHOSTTYKIT_FILE" "build-ghosttykit"

# ci-macos-compat.yml (uses matrix.os with WarpBuild runners)
check_warp_runner "$COMPAT_FILE" "compat-tests"
