#!/usr/bin/env bash
set -Eeuo pipefail

repair_url="https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md#builds-from-big-red"
on_error() {
  local status=$?
  printf 'hotkey catalog diagnostic failed at line %s: %s (exit %s)\n' \
    "$1" "$BASH_COMMAND" "$status" >&2
  printf 'Fix the reported dependency or checkout problem, then rerun this script at the exact pushed head.\n' >&2
  printf 'Repair runbook: %s\n' "$repair_url" >&2
  exit "$status"
}
trap 'on_error "$LINENO"' ERR

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"

GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)" ./scripts/download-prebuilt-ghosttykit.sh
scripts/cmux-next/prefix-ghosttykit-archives.sh GhosttyKit.xcframework

swift build --package-path Packages/macOS/CmuxNext --build-tests -j 4 -Xlinker -lc++
"$repo_root/scripts/cmux-next/swift-test-with-hang-sampler.sh" \
  --package-path "$repo_root/Packages/macOS/CmuxNext" \
  --skip-build -j 4 -Xlinker -lc++ \
  --filter ActionCatalogTests/neverTakeFromTerminalDefaultsStayOutOfTheResolver
