#!/usr/bin/env bash
# How long a one-module incremental rebuild of the heavy NEXT modules takes with a warm SwiftPM .build, for the UI
# preview worker's Swift peer (scripts/cmux-next/ui-preview-worker.py): can a push that touches CmuxNextAgentPane or
# CmuxNextApp be shot by building the CmuxNextApp product incrementally, inside the shoot's ~40 s of the 60 s budget?
# It builds `swift build --product CmuxNextApp` (Debug) once, then for each edit appends one declaration to a source
# file of the module, rebuilds and times it, and takes the edit back (and times that rebuild too: the base side).
#   cmux-ci run --class exclusive --measurement --label measure --script scripts/measure/ui-preview-heavy-rebuild.sh \
#     --ref <sha> --artifact artifacts/ui-preview-heavy-rebuild/report.json
# The log prints UI-PREVIEW-HEAVY-ROW {json} per build and UI-PREVIEW-HEAVY {json} at the end.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
# A step's checkout has empty submodules; the package's CmuxGhosttyKit binary target needs the prebuilt xcframework.
if [ ! -f GhosttyKit.xcframework/Info.plist ]; then
  rm -rf GhosttyKit.xcframework
  if [ -z "${GHOSTTY_SHA:-}" ] && [ ! -e ghostty/.git ]; then
    GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)"
    export GHOSTTY_SHA
  fi
  if [ -z "${GHOSTTYKIT_ARCHIVE_CACHE_DIR:-}" ] && [ -n "${CI_SHARED_CACHE_DIR:-}" ]; then
    export GHOSTTYKIT_ARCHIVE_CACHE_DIR="$CI_SHARED_CACHE_DIR/ghosttykit-archives"
  fi
  ./scripts/download-prebuilt-ghosttykit.sh
fi
echo "UI-PREVIEW-HEAVY-MACHINE sha=$(git rev-parse HEAD) model=$(sysctl -n hw.model) cores=$(sysctl -n hw.ncpu) macos=$(sw_vers -productVersion) load=\"$(uptime | sed 's/.*load averages*: //')\""
python3 scripts/measure/ui-preview-heavy-rebuild.py --out "$(pwd)/artifacts/ui-preview-heavy-rebuild" "$@"
