#!/usr/bin/env bash
# Fleet entry for the structural rebuild timing (fast-swift-rebuild): how long a Swift change that cannot be
# injected (a new stored property in CmuxNextApp) takes to reach a relaunched tagged DEV app. It builds the
# tagged app at this checkout once, then for each edit adds one stored property to HomeHostView, rebuilds with
# scripts/reload.sh in place (the warm DerivedData the step keeps in .build) and relaunches the app until its
# socket answers. Each edit records the reload's wall time, xcodebuild's timing summary, the Swift files the
# driver compiled, and the relaunch to usable time. The edits are taken back when the run ends.
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/structural-rebuild.sh \
#     --ref <sha> --artifact artifacts/structural-rebuild/report.json [--arg=--edits=3] [--arg=--config=debug]
# A SIGTERM (the step's timeout) still takes the edits back, ends the reload and quits the app.
# The log prints STRUCTURAL-REBUILD-ROW {json} per build and STRUCTURAL-REBUILD {json} with the medians.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules: reload.sh needs Ghostty's headers and ghostty-next for the bundled cmux-tui,
# and GhosttyKit.xcframework (a prebuilt download, never a local Ghostty build), as action-signposts.sh.
for sub in ghostty ghostty-next; do
  [ -e "$sub/.git" ] || git submodule update --init --depth 1 "$sub" >/dev/null
done
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
# Steps run with a per-step HOME; bun and node for the build's web bundles live under the account's real home, and
# the step gets its own copy of the bun webviews/package.json pins, first on PATH (as action-signposts.sh).
account_home="$(dscl . -read "/Users/$(id -un)" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
for tool_dir in "$account_home/.bun/bin" "$account_home/.local/node/bin"; do
  [ -n "$account_home" ] && [ -d "$tool_dir" ] && export PATH="$tool_dir:$PATH"
done
bun_dir="$(mktemp -d)"
RUNNER_TEMP="$bun_dir" GITHUB_PATH="$bun_dir/bun-path" ./scripts/cmux-next/private-bun.sh
PATH="$(tail -n 1 "$bun_dir/bun-path"):$PATH"
export PATH
echo "STRUCTURAL-REBUILD-MACHINE sha=$(git rev-parse HEAD) model=$(sysctl -n hw.model) cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
exec python3 scripts/measure/structural-rebuild.py --out "$(pwd)/artifacts/structural-rebuild" "$@"
