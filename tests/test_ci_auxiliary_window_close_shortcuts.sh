#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

python3 scripts/lint_auxiliary_window_close_shortcuts.py

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

OWNER_LIST_REL="Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/AuxiliaryWindowRegistry.swift"
mkdir -p "$TMP_DIR/Sources"
mkdir -p "$TMP_DIR/$(dirname "$OWNER_LIST_REL")"

# Write the owner-list fixture in the production AuxiliaryWindowRegistry shape:
# `public static let `default` = AuxiliaryWindowRegistry(identifiers: [...])`.
# Each argument after the first is emitted as a quoted identifier in the set.
write_owner_list() {
    {
        echo "public struct AuxiliaryWindowRegistry: Sendable, Equatable {"
        echo "    public let identifiers: Set<String>"
        echo "    public static let \`default\` = AuxiliaryWindowRegistry(identifiers: ["
        for identifier in "$@"; do
            echo "        $identifier"
        done
        echo "    ])"
        echo "}"
    } > "$TMP_DIR/$OWNER_LIST_REL"
}

write_owner_list '"cmux.settings",'

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

write_owner_list \
    '// "cmux.newWindow",' \
    '/*' \
    '"cmux.newWindow",' \
    '*/' \
    '"cmux.settings",'

if python3 scripts/lint_auxiliary_window_close_shortcuts.py --repo-root "$TMP_DIR" >"$TMP_DIR/commented-owner.out" 2>&1; then
    echo "Expected commented-out auxiliary-window close owner to be ignored" >&2
    exit 1
fi
grep -q "cmux.newWindow" "$TMP_DIR/commented-owner.out"

write_owner_list \
    '// MARK: - Main Windows [user-closable]' \
    '// This comment intentionally contains a lone ] bracket.' \
    '"cmux.newWindow",' \
    '"cmux.settings",'

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

write_owner_list '"cmux.settings",'

cat > "$TMP_DIR/Sources/NewWindow.swift" <<'SWIFT'
import AppKit

func makeWindow() {
    let window = NSWindow()
    window.identifier = NSUserInterfaceItemIdentifier("cmux.bootstrap")
}
SWIFT

python3 scripts/lint_auxiliary_window_close_shortcuts.py --repo-root "$TMP_DIR"

# Identifier assigned through a named constant (the MobilePairingWindowController
# pattern) must be resolved and enforced, not silently skipped.
write_owner_list '"cmux.settings",'

cat > "$TMP_DIR/Sources/NewWindow.swift" <<'SWIFT'
import AppKit

final class ConstantWindowController {
    static let windowIdentifier = "cmux.constantWindow"

    func makeWindow() {
        let window = NSWindow()
        window.identifier = NSUserInterfaceItemIdentifier(Self.windowIdentifier)
    }
}
SWIFT

if python3 scripts/lint_auxiliary_window_close_shortcuts.py --repo-root "$TMP_DIR" >"$TMP_DIR/constant.out" 2>&1; then
    echo "Expected constant-assigned auxiliary-window identifier to fail when missing" >&2
    exit 1
fi
grep -q "cmux.constantWindow" "$TMP_DIR/constant.out"
grep -q "Sources/NewWindow.swift:8" "$TMP_DIR/constant.out"

write_owner_list \
    '"cmux.constantWindow",' \
    '"cmux.settings",'

python3 scripts/lint_auxiliary_window_close_shortcuts.py --repo-root "$TMP_DIR"
