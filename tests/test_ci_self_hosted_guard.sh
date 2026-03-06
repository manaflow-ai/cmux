#!/usr/bin/env bash
# Regression test for https://github.com/manaflow-ai/cmux/issues/385.
# Ensures heavy macOS jobs are gated by PR scope, not contributor origin.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CI_WORKFLOW="$ROOT_DIR/.github/workflows/ci.yml"
COMPAT_WORKFLOW="$ROOT_DIR/.github/workflows/ci-macos-compat.yml"
BUILD_WORKFLOW="$ROOT_DIR/.github/workflows/build-ghosttykit.yml"
EXPECTED_IF="if: needs.classify-pr-scope.outputs.run_heavy_macos == 'true'"
FORK_GUARD="github.event.pull_request.head.repo.full_name == github.repository"
UPLOAD_ARTIFACT="uses: actions/upload-artifact@"
DOWNLOAD_ARTIFACT="uses: actions/download-artifact@"
ENSURE_HELPER="run: bash scripts/ci/ensure_ghosttykit.sh"

assert_job_block_contains() {
  local file="$1"
  local job="$2"
  local needle="$3"

  if ! awk -v job="$job" -v needle="$needle" '
    $0 == "  " job ":" { in_job=1; next }
    in_job && /^  [^[:space:]]/ { exit found ? 0 : 1 }
    in_job && index($0, needle) { found=1 }
    END { exit found ? 0 : 1 }
  ' "$file"; then
    echo "FAIL: Expected $job block in $file to contain: $needle" >&2
    exit 1
  fi
}

assert_job_block_not_contains() {
  local file="$1"
  local job="$2"
  local needle="$3"

  if awk -v job="$job" -v needle="$needle" '
    $0 == "  " job ":" { in_job=1; next }
    in_job && /^  [^[:space:]]/ { exit found ? 0 : 1 }
    in_job && index($0, needle) { found=1 }
    END { exit found ? 0 : 1 }
  ' "$file"; then
    echo "FAIL: Unexpected $needle in $job block of $file" >&2
    exit 1
  fi
}

assert_job_block_contains "$CI_WORKFLOW" "tests-depot" "runs-on: depot-macos-latest"
assert_job_block_contains "$CI_WORKFLOW" "prepare-ghosttykit" "runs-on: macos-15"
assert_job_block_contains "$CI_WORKFLOW" "prepare-ghosttykit" "$UPLOAD_ARTIFACT"
assert_job_block_contains "$CI_WORKFLOW" "prepare-ghosttykit" "$ENSURE_HELPER"
assert_job_block_contains "$CI_WORKFLOW" "tests" "$DOWNLOAD_ARTIFACT"
assert_job_block_contains "$CI_WORKFLOW" "tests-depot" "$DOWNLOAD_ARTIFACT"
assert_job_block_contains "$CI_WORKFLOW" "tests-depot" "$EXPECTED_IF"
assert_job_block_not_contains "$CI_WORKFLOW" "tests" "$ENSURE_HELPER"
assert_job_block_not_contains "$CI_WORKFLOW" "tests-depot" "$ENSURE_HELPER"
assert_job_block_not_contains "$CI_WORKFLOW" "tests-depot" "$FORK_GUARD"

assert_job_block_contains "$COMPAT_WORKFLOW" "prepare-ghosttykit" "runs-on: macos-15"
assert_job_block_contains "$COMPAT_WORKFLOW" "prepare-ghosttykit" "$UPLOAD_ARTIFACT"
assert_job_block_contains "$COMPAT_WORKFLOW" "prepare-ghosttykit" "$ENSURE_HELPER"
assert_job_block_contains "$COMPAT_WORKFLOW" "compat-tests" "$EXPECTED_IF"
assert_job_block_contains "$COMPAT_WORKFLOW" "compat-tests" "$DOWNLOAD_ARTIFACT"
assert_job_block_not_contains "$COMPAT_WORKFLOW" "compat-tests" "$ENSURE_HELPER"
assert_job_block_not_contains "$COMPAT_WORKFLOW" "compat-tests" "$FORK_GUARD"

assert_job_block_contains "$BUILD_WORKFLOW" "build-ghosttykit" "$EXPECTED_IF"
assert_job_block_not_contains "$BUILD_WORKFLOW" "build-ghosttykit" "$FORK_GUARD"

echo "PASS: heavy macOS jobs are gated by docs-only scope, not contributor origin, and share one GhosttyKit artifact per workflow"
