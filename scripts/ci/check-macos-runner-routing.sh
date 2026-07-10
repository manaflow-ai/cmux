#!/usr/bin/env bash
# Fail fast when a runner-routing repository variable points a required ci.yml
# macOS lane at a runner image that cannot serve it.
#
# Runner routing lives in repository variables, so a cutover is a config flip
# that no PR review ever sees. On 2026-07-10 `MACOS_RUNNER_15` was flipped to
# `tart-macos-15` alongside the Tart canary rollout (#7796). The Tart Sequoia
# image ships only SDK-26 Xcodes, so swift-package-tests (which must build the
# universal Ghostty CLI helper with an SDK-15 Xcode) died on every branch with
# "No Xcode.app found under /Applications with macOS SDK major 15", and a
# poisoned tart slot repeatedly failed app-host shard 4. The failures read as
# fleet breakage instead of misrouting. The variable was flipped back and then
# re-flipped to tart within minutes, so ci.yml's required lanes now route
# through dedicated variables validated here, instead of the contested
# MACOS_RUNNER_15:
#
#   - MACOS_RUNNER_DUAL_XCODE -> swift-package-tests. Contract: image ships
#     BOTH an SDK-15 Xcode (16.x, Ghostty CLI helper via
#     CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=15) and the pinned SDK-26 Xcode
#     (vars.CMUX_CI_XCODE_APP_MACOS_15). Headless is fine.
#   - MACOS_RUNNER_APP_HOST -> app-host unit-test shards. Contract: GUI
#     session able to broker testmanagerd control sessions (XCTest app-host),
#     plus the pinned SDK-26 Xcode. Blacksmith macOS cannot do this.
#
# To cut a lane over to a new runner type: prove the lane's jobs green on the
# new label via workflow_dispatch, add the label to the lane's allowlist below
# in a reviewed PR, then flip the variable. Unset variables use the baked-in
# warp-macos-15-arm64-6x fallback, which is validated for both lanes.
set -euo pipefail

fail=0

check_lane() {
  local var_name="$1" value="$2" contract="$3"
  shift 3
  local allowed=("$@")

  if [ -z "$value" ]; then
    echo "$var_name is unset; the workflow falls back to warp-macos-15-arm64-6x. OK."
    return 0
  fi
  for label in "${allowed[@]}"; do
    if [ "$value" = "$label" ]; then
      echo "$var_name=$value is validated for its lane ($contract). OK."
      return 0
    fi
  done

  cat >&2 <<EOF
::error::$var_name is set to "$value", which is not validated for its lane ($contract).
Routing this lane to an unproven runner image breaks required CI on every branch
(incident 2026-07-10: MACOS_RUNNER_15=tart-macos-15 killed swift-package-tests with
"No Xcode.app found ... with macOS SDK major 15" and app-host shard 4 on a poisoned
tart slot). Fix: unset the variable or set it back to a validated label:
  gh variable set $var_name --repo manaflow-ai/cmux -b warp-macos-15-arm64-6x
To adopt a new runner type, prove the lane's jobs green on it via workflow_dispatch,
then add the label to the allowlist in scripts/ci/check-macos-runner-routing.sh in a
reviewed PR before flipping the variable. See docs/ci-runners.md.
EOF
  fail=1
}

check_lane "MACOS_RUNNER_DUAL_XCODE" "${MACOS_RUNNER_DUAL_XCODE_VALUE:-}" \
  "dual-Xcode: SDK-15 + SDK-26 Xcodes" \
  "warp-macos-15-arm64-6x" \
  "blacksmith-6vcpu-macos-15"

check_lane "MACOS_RUNNER_APP_HOST" "${MACOS_RUNNER_APP_HOST_VALUE:-}" \
  "GUI XCTest app-host: testmanagerd + SDK-26 Xcode" \
  "warp-macos-15-arm64-6x"

exit "$fail"
