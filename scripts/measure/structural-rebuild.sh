#!/usr/bin/env bash
# Fleet entry for the structural rebuild timing (fast-swift-rebuild): how long a Swift change that cannot be
# injected (a new stored property in CmuxNextApp) takes to reach a relaunched tagged DEV app. It builds the
# tagged app at this checkout once, then for each edit adds one stored property to HomeHostView, rebuilds with
# scripts/reload.sh in place (the warm DerivedData the step keeps in .build) and relaunches the app until its
# socket answers. Each edit records the reload's wall time, xcodebuild's timing summary, the Swift files the
# driver compiled, and the relaunch to usable time. The edits are taken back when the run ends.
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/structural-rebuild.sh \
#     --ref <sha> --artifact artifacts/structural-rebuild/report.json [--arg=--edits=3] [--arg=--config=debug]
# The log prints STRUCTURAL-REBUILD-ROW {json} per build and STRUCTURAL-REBUILD {json} with the medians.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers and ghostty-next for the bundled cmux-tui.
git submodule update --init --depth 1 ghostty ghostty-next >/dev/null
echo "STRUCTURAL-REBUILD-MACHINE sha=$(git rev-parse HEAD) model=$(sysctl -n hw.model) cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
exec python3 scripts/measure/structural-rebuild.py --out "$(pwd)/artifacts/structural-rebuild" "$@"
