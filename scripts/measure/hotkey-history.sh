#!/usr/bin/env bash
# Build and execute the focused CmuxNext action-catalog regression test on a
# fleet macOS worker. Keep the root absolute so this also works from a CI
# checkout whose current directory is the package.
set -Eeuo pipefail

readonly REPAIR_URL="https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md#builds-from-big-red"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
readonly PACKAGE_PATH="$REPO_ROOT/Packages/macOS/CmuxNext"
readonly TEST_FILTER="ActionCatalogTests/browserHistoryOwnsCmdYAndRightSidebarHasNoDigitDefaults"

on_failure() {
    local status=$?
    printf 'hotkey-history: failed at line %s (exit %s).\n' "${1:-unknown}" "$status" >&2
    printf 'Fix: rerun this helper from the exact pushed checkout on an enrolled fleet macOS worker.\n' >&2
    printf 'Repair: %s\n' "$REPAIR_URL" >&2
    exit "$status"
}
trap 'on_failure "$LINENO"' ERR

cd "$REPO_ROOT"
printf 'hotkey-history: repo=%s\n' "$REPO_ROOT"
printf 'hotkey-history: head=%s\n' "$(git rev-parse HEAD)"

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'hotkey-history: this helper requires a fleet macOS worker, got %s.\n' "$(uname -s)" >&2
    printf 'Fix: submit or run it on the enrolled macOS fleet; do not build natively on Big Red.\n' >&2
    printf 'Repair: %s\n' "$REPAIR_URL" >&2
    exit 2
fi

ghostty_sha="$(git rev-parse HEAD:ghostty)"
GHOSTTY_SHA="$ghostty_sha" GHOSTTYKIT_OUTPUT_DIR="$REPO_ROOT/GhosttyKit.xcframework" \
    "$REPO_ROOT/scripts/download-prebuilt-ghosttykit.sh"
"$REPO_ROOT/scripts/cmux-next/prefix-ghosttykit-archives.sh" "$REPO_ROOT/GhosttyKit.xcframework"

cd "$PACKAGE_PATH"
swift build --build-tests -j 4 -Xlinker -lc++
"$REPO_ROOT/scripts/cmux-next/swift-test-with-hang-sampler.sh" \
    --skip-build -j 4 -Xlinker -lc++ --filter "$TEST_FILTER"

printf 'hotkey-history: focused test passed (%s).\n' "$TEST_FILTER"
