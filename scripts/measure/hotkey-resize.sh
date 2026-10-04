#!/usr/bin/env bash
set -Eeuo pipefail

# Focused cmux-next validation for the pane-resize and location-history keymap.
# Run this on an enrolled fleet worker, never on a developer laptop. The
# package test is intentionally narrow so a hotkey change has a small, useful
# receipt while the native app build remains owned by the fleet controller.

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
REPAIR_URL="https://github.com/manaflow-ai/cmuxterm-hq/blob/main/REPAIR.md"
REPAIR_ANCHOR="hotkey-resize-validation"
SAMPLE_BIN="${SAMPLE_BIN:-/usr/bin/sample}"
SAMPLE_PID="${HOTKEY_RESIZE_SAMPLE_PID:-$$}"
SAMPLE_OUT="${HOTKEY_RESIZE_SAMPLE_OUT:-${TMPDIR:-/tmp}/cmux-hotkey-resize.sample.txt}"

on_error() {
    local status=$?
    printf 'hotkey-resize failed (status %s): %s\n' "$status" "${BASH_COMMAND:-unknown command}" >&2
    if [[ -x "$SAMPLE_BIN" && "$SAMPLE_PID" =~ ^[0-9]+$ ]]; then
        "$SAMPLE_BIN" "$SAMPLE_PID" 2 -file "$SAMPLE_OUT" >/dev/null 2>&1 || true
        printf 'Diagnostic sample: %s\n' "$SAMPLE_OUT" >&2
    fi
    printf 'Fix: inspect the diagnostic, correct the failing source or fleet state, push the fix, and rerun the admitted fleet job at the new exact SHA.\n' >&2
    printf 'Repair: %s#%s\n' "$REPAIR_URL" "$REPAIR_ANCHOR" >&2
    exit "$status"
}
trap on_error ERR

if [[ "$(uname -s)" != Darwin ]]; then
    printf 'hotkey-resize requires a Darwin fleet worker (got %s).\nFix: rerun on an admitted fleet worker at the exact pushed SHA.\nRepair: %s#%s\n' "$(uname -s)" "$REPAIR_URL" "$REPAIR_ANCHOR" >&2
    exit 2
fi
if [[ ! -x "$SAMPLE_BIN" ]]; then
    printf 'hotkey-resize requires the absolute sampler at %s.\nFix: restore the fleet sampler path, then rerun the admitted job.\nRepair: %s#%s\n' "$SAMPLE_BIN" "$REPAIR_URL" "$REPAIR_ANCHOR" >&2
    exit 2
fi

cd "$ROOT"
export GHOSTTY_SHA="$(git rev-parse HEAD:ghostty)"
"$ROOT/scripts/download-prebuilt-ghosttykit.sh"
"$ROOT/scripts/cmux-next/prefix-ghosttykit-archives.sh" "$ROOT/GhosttyKit.xcframework"

# Keep the linker spelling explicit: cmux-next's Ghostty bridge needs libc++
# when this focused package suite links on the fleet worker.
swift test \
    --package-path "$ROOT/Packages/macOS/CmuxNext" \
    --parallel \
    -Xswiftc -j4 \
    -Xlinker -lc++ \
    --filter 'RegistryShortcutTests/paneResizeUsesControlCommandArrowsAndVimKeys'

printf 'hotkey-resize passed: Ctrl-Cmd arrows/HJKL and Ctrl--/Ctrl-Shift-- ownership.\n'
