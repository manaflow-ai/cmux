#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures paid CI jobs use Blacksmith macOS runners.
# Fork PRs are gated by GitHub's built-in "Require approval for outside
# collaborators" setting, so workflow-level fork guards are not needed.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"
GHOSTTYKIT_FILE="$ROOT_DIR/.github/workflows/build-ghosttykit.yml"
COMPAT_FILE="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"

check_blacksmith_runner() {
  local file="$1" job="$2"
  if ! awk -v job="$job" '
    $0 ~ "^  "job":" { in_job=1; next }
    in_job && /^  [^[:space:]#][^:]*:[[:space:]]*(#.*)?$/ { in_job=0 }
    in_job && /runs-on:.*blacksmith-[0-9]+vcpu-macos-/ { saw=1 }
    in_job && /os: blacksmith-[0-9]+vcpu-macos-/ { saw=1 }
    END { exit !(saw) }
  ' "$file"; then
    echo "FAIL: $job in $(basename "$file") must use the expected macOS runner"
    exit 1
  fi
  echo "PASS: $job in $(basename "$file") uses the expected macOS runner"
}

# ci.yml jobs
check_blacksmith_runner "$CI_FILE" "tests"
check_blacksmith_runner "$CI_FILE" "tests-build-and-lag"
check_blacksmith_runner "$CI_FILE" "release-build"
check_blacksmith_runner "$CI_FILE" "ui-regressions"

# build-ghosttykit.yml
check_blacksmith_runner "$GHOSTTYKIT_FILE" "build-ghosttykit"

# ci-macos-compat.yml (uses matrix.os with Blacksmith runners)
check_blacksmith_runner "$COMPAT_FILE" "compat-tests"
