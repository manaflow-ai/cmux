#!/usr/bin/env bash
# Fleet entry for p08-startup task 067: what Sparkle.framework costs a launch before main(), and the decision
# (keep it linked, or dlopen it off main at afterStartup when the p50 is >= 3 ms). Resolves the CmuxNext package
# (no build: Sparkle is a SwiftPM binary target, so its image is the same in every cmux config), then runs
# scripts/cmux-next/sparkle-image-cost.py on the resolved framework and writes artifacts/sparkle-image-cost.json.
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/sparkle-image-cost.sh \
#     --ref <sha> --key <key> --artifact artifacts/sparkle-image-cost.json [--arg=--runs=20] [--arg=--purge]
#   nx-remote -- scripts/measure/sparkle-image-cost.sh [--runs=20] [--purge]
# Every argument goes to sparkle-image-cost.py. The controller runs a scripts/measure/ script only once hq lists it
# (cmuxterm-hq build-fleet/cmd/controller/ci_step.go measureScripts).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
if [[ -z "${CMUX_CI_STEP_KEY:-}" && -z "${NX_JOB_ID:-}" ]]; then
  echo "sparkle-image-cost: runs only on the fleet (cmux-ci run or nx-remote); see the usage at the top of this file" >&2
  exit 2
fi
swift package resolve --package-path Packages/macOS/CmuxNext
mkdir -p artifacts
exec python3 -I scripts/cmux-next/sparkle-image-cost.py --package-dir Packages/macOS/CmuxNext \
  --json artifacts/sparkle-image-cost.json "$@"
