#!/usr/bin/env bash
# Focused CmuxNext validation for the agent-chat/feed shortcut slice.
# Run from any checkout directory; the package and hang sampler paths are absolute.
set -Eeuo pipefail

repair_url="https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md"
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"

on_error() {
  local status=$?
  echo "hotkey-agent-feed: failed (status ${status})" >&2
  echo "hotkey-agent-feed: check the fleet checkout and see ${repair_url} for the repair owner and fix." >&2
  exit "$status"
}
trap on_error ERR

cd "$root"
GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)" \
  "$root/scripts/download-prebuilt-ghosttykit.sh"
"$root/scripts/cmux-next/prefix-ghosttykit-archives.sh" "$root/GhosttyKit.xcframework"

filter='ActionCatalogTests|LeaderLayerTests|AgentPaneShortcutsTests|NewTabKindTests|ShortcutBindingTests|ApplierTests'
"$root/scripts/cmux-next/swift-test-with-hang-sampler.sh" \
  --package-path "$root/Packages/macOS/CmuxNext" \
  -j 4 -Xlinker -lc++ \
  --filter "$filter"

echo "hotkey-agent-feed: focused shortcut suites passed"
