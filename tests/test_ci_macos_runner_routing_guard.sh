#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/scripts/ci/check-macos-runner-routing.sh"
CI_FILE="$ROOT_DIR/.github/workflows/ci.yml"

# Validated labels and the unset fallback must pass.
for value in "" "warp-macos-15-arm64-6x" "blacksmith-6vcpu-macos-15"; do
  if ! MACOS_RUNNER_15_VALUE="$value" "$SCRIPT" >/dev/null; then
    echo "FAIL: MACOS_RUNNER_15='$value' should be accepted"
    exit 1
  fi
done

# Labels without the dual-Xcode toolchain must fail closed with an actionable
# message (2026-07-10: tart-macos-15 lacked an SDK-15 Xcode and killed
# swift-package-tests on every branch).
for value in "tart-macos-15" "tart-gui" "blacksmith-6vcpu-macos-26" "self-hosted"; do
  if output="$(MACOS_RUNNER_15_VALUE="$value" "$SCRIPT" 2>&1)"; then
    echo "FAIL: MACOS_RUNNER_15='$value' should be rejected"
    exit 1
  fi
  if ! grep -Fq "not a validated dual-Xcode runner label" <<< "$output"; then
    echo "FAIL: rejection for '$value' did not explain the dual-Xcode contract"
    printf '%s\n' "$output" >&2
    exit 1
  fi
  if ! grep -Fq "gh variable set MACOS_RUNNER_15" <<< "$output"; then
    echo "FAIL: rejection for '$value' did not include the remediation command"
    printf '%s\n' "$output" >&2
    exit 1
  fi
done

# The guard only helps if ci.yml actually runs it against the live variable.
if ! grep -Fq "MACOS_RUNNER_15_VALUE: \${{ vars.MACOS_RUNNER_15 }}" "$CI_FILE"; then
  echo "FAIL: ci.yml must pass vars.MACOS_RUNNER_15 to the routing guard"
  exit 1
fi
if ! grep -Fq "scripts/ci/check-macos-runner-routing.sh" "$CI_FILE"; then
  echo "FAIL: ci.yml must run scripts/ci/check-macos-runner-routing.sh"
  exit 1
fi

echo "PASS: MACOS_RUNNER_15 routing guard rejects non-dual-Xcode labels and is wired into ci.yml"
