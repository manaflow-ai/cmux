#!/usr/bin/env bash
# Fail fast when the MACOS_RUNNER_15 repository variable routes required CI to
# a runner image that cannot serve the jobs behind it.
#
# swift-package-tests and the app-host unit-test shards run on
# `vars.MACOS_RUNNER_15`. Their toolchain contract is a dual-Xcode image:
#   - an SDK-15 Xcode (16.x) for the universal Ghostty CLI helper
#     (`Select helper Xcode` runs with CMUX_CI_REQUIRED_MACOS_SDK_MAJOR=15), and
#   - the pinned SDK-26 Xcode (`vars.CMUX_CI_XCODE_APP_MACOS_15`,
#     currently /Applications/Xcode_26.3.app) for the app/test gates.
#
# Runner routing lives in repository variables, so a cutover is a config flip
# that no PR review ever sees. On 2026-07-10 `MACOS_RUNNER_15` was flipped to
# `tart-macos-15` alongside the Tart canary rollout (#7796); the Tart Sequoia
# image ships only SDK-26 Xcodes, so every swift-package-tests run on main
# died mid-job with "No Xcode.app found under /Applications with macOS SDK
# major 15" and the failure read as fleet breakage instead of misrouting.
# This guard turns that mistake into an immediate, named failure on every run.
#
# To move MACOS_RUNNER_15 to a new runner type: prove the image serves the
# dual-Xcode contract (run swift-package-tests and all app-host shards green
# on it via workflow_dispatch), then add the label to the allowlist below in a
# reviewed PR *before* flipping the variable.
set -euo pipefail

VALUE="${MACOS_RUNNER_15_VALUE:-}"

# Labels validated to carry both an SDK-15 Xcode and the pinned SDK-26 Xcode.
# An empty variable is fine: the workflows fall back to warp-macos-15-arm64-6x.
ALLOWED=(
  "warp-macos-15-arm64-6x"
  "blacksmith-6vcpu-macos-15"
)

if [ -z "$VALUE" ]; then
  echo "MACOS_RUNNER_15 is unset; workflows use their baked-in fallback (warp-macos-15-arm64-6x). OK."
  exit 0
fi

for label in "${ALLOWED[@]}"; do
  if [ "$VALUE" = "$label" ]; then
    echo "MACOS_RUNNER_15=$VALUE is a validated dual-Xcode runner label. OK."
    exit 0
  fi
done

cat >&2 <<EOF
::error::MACOS_RUNNER_15 is set to "$VALUE", which is not a validated dual-Xcode runner label.
swift-package-tests and the app-host unit-test shards route through MACOS_RUNNER_15 and
require a runner image with BOTH an SDK-15 Xcode (16.x, for the universal Ghostty CLI
helper) and the pinned SDK-26 Xcode. Routing them to an image without that toolchain
breaks required CI on every branch (incident 2026-07-10: MACOS_RUNNER_15=tart-macos-15
made swift-package-tests fail with "No Xcode.app found ... with macOS SDK major 15").

Fix: gh variable set MACOS_RUNNER_15 --repo manaflow-ai/cmux -b warp-macos-15-arm64-6x
To adopt a new runner type instead, validate its image against the dual-Xcode contract
and add the label to ALLOWED in scripts/ci/check-macos-runner-routing.sh in a reviewed
PR before flipping the variable. See docs/ci-runners.md.
EOF
exit 1
