#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/check-macos-runner-routing.sh"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"

run_guard() {
  local dual="$1" app_host="$2"
  MACOS_RUNNER_DUAL_XCODE_VALUE="$dual" \
    MACOS_RUNNER_APP_HOST_VALUE="$app_host" \
    "$SCRIPT"
}

# Validated labels and the unset fallback must pass, per lane.
for dual in "" "warp-macos-15-arm64-6x" "blacksmith-6vcpu-macos-15"; do
  if ! run_guard "$dual" "" >/dev/null; then
    echo "FAIL: MACOS_RUNNER_DUAL_XCODE='$dual' should be accepted"
    exit 1
  fi
done
if ! run_guard "" "warp-macos-15-arm64-6x" >/dev/null; then
  echo "FAIL: MACOS_RUNNER_APP_HOST='warp-macos-15-arm64-6x' should be accepted"
  exit 1
fi

# Labels not validated for a lane must fail closed with an actionable message
# (2026-07-10: tart-macos-15 lacked an SDK-15 Xcode and killed
# swift-package-tests on every branch; a poisoned tart slot failed app-host
# shard 4).
expect_reject() {
  local dual="$1" app_host="$2" label="$3"
  local output
  if output="$(run_guard "$dual" "$app_host" 2>&1)"; then
    echo "FAIL: $label should be rejected"
    exit 1
  fi
  if ! grep -Fq "not validated for its lane" <<< "$output"; then
    echo "FAIL: rejection for $label did not explain the lane contract"
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! grep -Fq "gh variable set" <<< "$output"; then
    echo "FAIL: rejection for $label did not include the remediation command"
    printf '%s\n' "$output" >&2
    exit 1
  fi
}

for dual in "tart-macos-15" "blacksmith-6vcpu-macos-26" "self-hosted"; do
  expect_reject "$dual" "" "MACOS_RUNNER_DUAL_XCODE='$dual'"
done
# Blacksmith macOS cannot broker testmanagerd control sessions, so it is
# validated for the dual-Xcode lane but NOT for the app-host lane.
for app_host in "tart-macos-15" "blacksmith-6vcpu-macos-15" "self-hosted"; do
  expect_reject "" "$app_host" "MACOS_RUNNER_APP_HOST='$app_host'"
done

# One bad lane fails the guard even when the other lane is fine.
expect_reject "warp-macos-15-arm64-6x" "tart-macos-15" "good dual + bad app-host"

# The guard only helps if ci.yml actually runs it against the live variables
# and routes the lanes through the guarded variables.
for needle in \
  "MACOS_RUNNER_DUAL_XCODE_VALUE: \${{ vars.MACOS_RUNNER_DUAL_XCODE }}" \
  "MACOS_RUNNER_APP_HOST_VALUE: \${{ vars.MACOS_RUNNER_APP_HOST }}" \
  "scripts/ci/check-macos-runner-routing.sh" \
  "runs-on: \${{ vars.MACOS_RUNNER_DUAL_XCODE || 'warp-macos-15-arm64-6x' }}" \
  "runs-on: \${{ vars.MACOS_RUNNER_APP_HOST || 'warp-macos-15-arm64-6x' }}"; do
  if ! grep -Fq "$needle" "$CI_FILE"; then
    echo "FAIL: ci.yml is missing: $needle"
    exit 1
  fi
done

# The contested shared variable must no longer route any ci.yml job; a re-flip
# of MACOS_RUNNER_15 (as happened on 2026-07-10) must not be able to move
# required ci.yml lanes onto an unproven fleet.
if grep -E "runs-on:.*MACOS_RUNNER_15" "$CI_FILE" | grep -vq "^ *#"; then
  echo "FAIL: ci.yml jobs must not route through the shared MACOS_RUNNER_15 variable"
  exit 1
fi

echo "PASS: macOS lane routing guard rejects unvalidated labels and is wired into ci.yml"
