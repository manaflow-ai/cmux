#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 scripts/lint_auxiliary_window_close_shortcuts.py

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

mkdir -p "$TMP_DIR/Sources"

cat > "$TMP_DIR/Sources/cmuxApp.swift" <<'SWIFT'
private let cmuxAuxiliaryWindowIdentifiers: Set<String> = [
    "cmux.settings",
]
SWIFT

cat > "$TMP_DIR/Sources/NewWindow.swift" <<'SWIFT'
import AppKit

/*
window.identifier = NSUserInterfaceItemIdentifier("cmux.blockCommentOnly")
*/

func makeWindow() {
    let window = NSWindow()
    window.identifier =
        NSUserInterfaceItemIdentifier("cmux.newWindow")
}
SWIFT

if python3 scripts/lint_auxiliary_window_close_shortcuts.py --repo-root "$TMP_DIR" >"$TMP_DIR/missing.out" 2>&1; then
    echo "Expected missing auxiliary-window close owner to fail" >&2
    exit 1
fi
grep -q "cmux.newWindow" "$TMP_DIR/missing.out"
grep -q "Sources/NewWindow.swift:9" "$TMP_DIR/missing.out"

cat > "$TMP_DIR/Sources/cmuxApp.swift" <<'SWIFT'
private let cmuxAuxiliaryWindowIdentifiers: Set<String> = [
    // "cmux.newWindow",
    /*
    "cmux.newWindow",
    */
    "cmux.settings",
]
SWIFT

if python3 scripts/lint_auxiliary_window_close_shortcuts.py --repo-root "$TMP_DIR" >"$TMP_DIR/commented-owner.out" 2>&1; then
    echo "Expected commented-out auxiliary-window close owner to be ignored" >&2
    exit 1
fi
grep -q "cmux.newWindow" "$TMP_DIR/commented-owner.out"

cat > "$TMP_DIR/Sources/cmuxApp.swift" <<'SWIFT'
private let cmuxAuxiliaryWindowIdentifiers: Set<String> = [
    // MARK: - Main Windows [user-closable]
    // This comment intentionally contains a lone ] bracket.
    "cmux.newWindow",
    "cmux.settings",
]
SWIFT

python3 scripts/lint_auxiliary_window_close_shortcuts.py --repo-root "$TMP_DIR"

cat > "$TMP_DIR/Sources/NewWindow.swift" <<'SWIFT'
import AppKit

func makeWindow() {
    let window = NSWindow()
    /*
    window.identifier = NSUserInterfaceItemIdentifier("cmux.blockCommentOnly")
    */
    // window.identifier = NSUserInterfaceItemIdentifier("cmux.commentOnly")
    _ = window
}
SWIFT

python3 scripts/lint_auxiliary_window_close_shortcuts.py --repo-root "$TMP_DIR"

cat > "$TMP_DIR/Sources/cmuxApp.swift" <<'SWIFT'
private let cmuxAuxiliaryWindowIdentifiers: Set<String> = [
    "cmux.settings",
]
SWIFT

cat > "$TMP_DIR/Sources/NewWindow.swift" <<'SWIFT'
import AppKit

func makeWindow() {
    let window = NSWindow()
    window.identifier = NSUserInterfaceItemIdentifier("cmux.bootstrap")
}
SWIFT

python3 scripts/lint_auxiliary_window_close_shortcuts.py --repo-root "$TMP_DIR"
