#!/usr/bin/env bash
# Fail fast when the MACOS_RUNNER_DUAL_XCODE repository variable routes the
# required swift-package-tests lane at a runner image that cannot serve it.
#
# swift-package-tests must build the universal Ghostty CLI helper with an
# SDK-15 Xcode (16.x, CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=15) and then run the
# package tests on the pinned SDK-26 Xcode (vars.CMUX_CI_XCODE_APP_MACOS_15),
# so its runner image must ship BOTH Xcodes.
#
# Runner routing lives in repository variables, so a cutover is a config flip
# that no PR review ever sees. On 2026-07-10 `MACOS_RUNNER_15` (which then
# routed this lane) was flipped to `tart-macos-15` alongside the Tart canary
# rollout (#7796). The Tart Sequoia image ships only SDK-26 Xcodes, so
# swift-package-tests died on every branch with "No Xcode.app found under
# /Applications with macOS SDK major 15" and the failure read as fleet
# breakage instead of misrouting. This guard turns that mistake into an
# immediate, named failure on every run.
#
# To move the lane to a new runner type (including Tart once its image ships
# an SDK-15 Xcode): prove swift-package-tests green on the new label via
# workflow_dispatch, then add the label to the allowlist below in a reviewed
# PR *before* flipping the variable. See docs/ci-runners.md.
set -euo pipefail

VALUE="${MACOS_RUNNER_DUAL_XCODE_VALUE:-}"

# Labels validated to carry both an SDK-15 Xcode and the pinned SDK-26 Xcode.
# An empty variable is fine: the workflow falls back to
# blacksmith-6vcpu-macos-15, which is on this list.
ALLOWED=(
  "blacksmith-6vcpu-macos-15"
  "warp-macos-15-arm64-6x"
)

if [ -z "$VALUE" ]; then
  echo "MACOS_RUNNER_DUAL_XCODE is unset; the workflow falls back to blacksmith-6vcpu-macos-15. OK."
  exit 0
fi

for label in "${ALLOWED[@]}"; do
  if [ "$VALUE" = "$label" ]; then
    echo "MACOS_RUNNER_DUAL_XCODE=$VALUE is a validated dual-Xcode runner label. OK."
    exit 0
  fi
done

cat >&2 <<EOF
::error::MACOS_RUNNER_DUAL_XCODE is set to "$VALUE", which is not a validated dual-Xcode runner label.
swift-package-tests routes through MACOS_RUNNER_DUAL_XCODE and requires a runner image
with BOTH an SDK-15 Xcode (16.x, for the universal Ghostty CLI helper) and the pinned
SDK-26 Xcode. Routing it to an image without that toolchain breaks required CI on every
branch (incident 2026-07-10: routing this lane to tart-macos-15 made it fail with
"No Xcode.app found ... with macOS SDK major 15").

Fix: gh variable set MACOS_RUNNER_DUAL_XCODE --repo manaflow-ai/cmux -b blacksmith-6vcpu-macos-15
To adopt a new runner type instead, prove swift-package-tests green on it via
workflow_dispatch and add the label to ALLOWED in scripts/ci/check-macos-runner-routing.sh
in a reviewed PR before flipping the variable. See docs/ci-runners.md.
EOF
exit 1
