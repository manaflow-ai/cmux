#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures PR CI jobs use assignable GitHub-hosted macOS runners instead of
# custom labels that can make required checks finish as skipped.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
GHOSTTYKIT_FILE="$ROOT_DIR/.github/workflows/build-ghosttykit.yml"
COMPAT_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"

check_warp_runner() {
  local file="$1" job="$2"
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]]/ { in_job=0 }
    in_job && /runs-on:.*warp-macos-.*-arm64/ { saw_warp=1 }
    in_job && /os: warp-macos-.*-arm64/ { saw_warp=1 }
    END { exit !(saw_warp) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must use a WarpBuild runner"
    exit 1
  fi
  echo "PASS: $job WarpBuild runner is present"
}

check_github_macos_runner() {
  local file="$1" job="$2" runner="$3"
  if ! awk -v job="$job" -v runner="$runner" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]]/ { in_job=0 }
    in_job && $0 ~ "runs-on: "runner"$" { saw_runner=1 }
    END { exit !(saw_runner) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must use GitHub-hosted $runner"
    exit 1
  fi
  echo "PASS: $job GitHub-hosted $runner runner is present"
}

# ci.yml PR jobs use GitHub-hosted runners so they execute instead of reporting
# skipped when custom macOS labels are unavailable.
check_github_macos_runner "$CI_FILE" "tests" "macos-15"
check_github_macos_runner "$CI_FILE" "tests-build-and-lag" "macos-15"
check_github_macos_runner "$CI_FILE" "release-build" "macos-26"
check_github_macos_runner "$CI_FILE" "ui-regressions" "macos-15"

# build-ghosttykit.yml
check_warp_runner "$GHOSTTYKIT_FILE" "build-ghosttykit"

# ci-macos-compat.yml (uses matrix.os with WarpBuild runners)
check_warp_runner "$COMPAT_FILE" "compat-tests"
