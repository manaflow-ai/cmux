#!/usr/bin/env bash
# Regenerates plans/cmux-next/action-surfaces.json and actions.md on a fleet
# step (never on a laptop) and prints them base64 between BEGIN/END markers:
#   cmux-ci run --class light --script scripts/measure/export-action-surfaces.sh --ref <sha>
set -euo pipefail
export CMUX_UPDATE_ACTION_SURFACES=1
GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)" ./scripts/download-prebuilt-ghosttykit.sh
scripts/cmux-next/prefix-ghosttykit-archives.sh GhosttyKit.xcframework
swift test --package-path Packages/macOS/CmuxNext --filter ActionSurfaceParityTests
for file in plans/cmux-next/action-surfaces.json plans/cmux-next/actions.md; do
  echo "BEGIN_ARTIFACT:$file"
  base64 < "$file" | tr -d '\n'
  echo
  echo "END_ARTIFACT:$file"
done
