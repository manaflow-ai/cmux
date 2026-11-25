#!/usr/bin/env python3
"""IME-INPUT guard (bead cx-dd5b4).

cmux-classic had about 120 IME and keyboard-layout bugs. Most came from code that made key
events out of characters, re-derived keys from text, or let a page handler act on a key that
an input method was using. This guard blocks new code paths of those kinds:

1. No new key-event synthesis in the app (Swift): `NSEvent.keyEvent(`, `CGEvent(keyboardEventSource`
   and `keyboardSetUnicodeString` only in the reviewed sites below. A synthesized key event skips
   the input method (or carries characters the active layout did not type). Text goes in as
   text: NSTextInputClient.insertText, `ghostty_surface_key` with `text` from the terminal's own
   keyDown, the page's DOM, or the daemon's `terminal send` (bytes).
2. Terminal text enters libghostty only through the terminal's NSTextInputClient files:
   `ghostty_surface_key(` and `ghostty_surface_preedit(` are called only from CmuxNextTerminal's
   keyboard and text-input files (key equivalents go through the view's keyDown). Committed
   text is a key event with text, as upstream Ghostty: `ghostty_surface_text_input(` (the fork's
   paste-like committed-text call) is refused everywhere.
3. Every web page entry (webviews/src/**/main.tsx) loads the shared desktop layer, which
   installs the IME key layer (webviews/src/pages/shared/imeKeys.ts): no page handler sees a
   key an input method is using.

Tracked files only. Usage: scripts/cmux-next/check-ime-input.py [repo-root]
A new entry in an allowlist needs a reason and a review that the path cannot reach a text
input (debug-only, automation of a named page, or a key the user typed being moved, never made).
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

SWIFT_ROOTS = ("Packages/macOS/CmuxNext/Sources", "Packages/Shared")

KEY_SYNTHESIS = re.compile(r"NSEvent\.keyEvent\(|CGEvent\(\s*keyboardEventSource|keyboardSetUnicodeString")

# path -> reason. Counts are per file; a second new site in a listed file still fails.
KEY_SYNTHESIS_ALLOWED: dict[str, tuple[int, str]] = {
    "Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/GhosttyInput.swift": (
        1, "Ghostty's translation event: the same physical key with option-as-alt mods (upstream SurfaceView keyDown)"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/TerminalKeyEquivalent.swift": (
        1, "Ghostty's Ctrl-Return / Ctrl-/ / unbound chord re-dispatch of the user's own key (upstream performKeyEquivalent)"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/TerminalSurfaceView+Pasteboard.swift": (
        1, "Cmd-V / Cmd-C menu chord for paste/copy, no text"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextBrowserAutomation/WebKitDriver+Input.swift": (
        1, "browser automation of a named page (agent tool), never the user's keyboard"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextBrowser/UI/AddressBarView.swift": (
        1, "Return to commit the omnibar after a suggestion click, no text"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Control/DebugViewKey.swift": (1, "DEBUG debug.view_key"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Focus/DebugKey+Sequence.swift": (
        1, "DEBUG debug.key sequence: raw key codes, the system layout fills characters"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Focus/DebugKey.swift": (1, "DEBUG debug.key"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Focus/WindowScopedShortcutHintModifierMonitor+Debug.swift": (
        1, "DEBUG flagsChanged for the shortcut hint overlay"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Focus/KeyRouter+NewTabInput.swift": (
        1, "moves a held key the user typed to the window that now has the page (cx-dd5b4 follow-up: replay the original event)"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/RemoteView/RemoteBrowserPages.swift": (1, "DEBUG remote browser page fixture 'type'"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Handlers/ListHandlers.swift": (1, "list arrow key for a list command, no text"),
    "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Overlay/WindowOverlayHost+Modal.swift": (
        1, "re-targets the user's own key to the modal's window"),
    "Packages/Shared/CmuxMessagesLab/Sources/MessagesLabHome/Cmux/MessagesLabHomeView.swift": (1, "MessagesLab lab harness"),
}

TERMINAL_ENTRY = re.compile(r"\bghostty_surface_(key|preedit)\(")
TEXT_INPUT = re.compile(r"\bghostty_surface_text_input\(")
TERMINAL_ENTRY_ALLOWED = {
    "Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/TerminalSurfaceView+Keyboard.swift",
    "Packages/macOS/CmuxNext/Sources/CmuxNextTerminal/TerminalSurfaceView+TextInput.swift",
}

PAGE_ENTRY_EXEMPT = {
    "webviews/src/optchat-inspector/main.tsx": "debug inspector, no text fields",
}


def tracked(root: Path, *paths: str) -> list[str]:
    out = subprocess.run(["git", "-C", str(root), "ls-files", "--", *paths], check=True, capture_output=True, text=True)
    return [line for line in out.stdout.splitlines() if line]


def code_lines(text: str):
    """Lines with `//` comments removed (enough for these patterns)."""
    for number, line in enumerate(text.splitlines(), 1):
        yield number, line.split("//", 1)[0]


def main() -> int:
    root = Path(sys.argv[1] if len(sys.argv) > 1 else subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], check=True, capture_output=True, text=True).stdout.strip())
    errors: list[str] = []

    for rel in tracked(root, *SWIFT_ROOTS):
        if not rel.endswith(".swift") or "/Tests/" in rel or "/Patches/" in rel:
            continue
        text = (root / rel).read_text(encoding="utf-8", errors="replace")
        synth = [n for n, line in code_lines(text) if KEY_SYNTHESIS.search(line)]
        allowed = KEY_SYNTHESIS_ALLOWED.get(rel, (0, ""))[0]
        if len(synth) > allowed:
            for n in synth[allowed:]:
                errors.append(
                    f"{rel}:{n}: synthesizes a key event. Text goes in as text (insertText, the page DOM, "
                    "`terminal send` bytes), never as made-up keys; a key the user typed is moved, never rebuilt "
                    "(DESIGN.md rule K1). If this is debug-only or automation of a named page, add it to "
                    "KEY_SYNTHESIS_ALLOWED with the reason.")
        for n, line in code_lines(text):
            if TEXT_INPUT.search(line):
                errors.append(
                    f"{rel}:{n}: ghostty_surface_text_input is not a terminal input path: committed text is a key "
                    "event with text and no physical key (upstream Ghostty committedTextAction, DESIGN.md rule T1).")
        if rel not in TERMINAL_ENTRY_ALLOWED:
            for n, line in code_lines(text):
                if TERMINAL_ENTRY.search(line):
                    errors.append(
                        f"{rel}:{n}: sends key or preedit text into libghostty outside the terminal's "
                        "NSTextInputClient (TerminalSurfaceView+Keyboard/+TextInput). Route the input through "
                        "the view's keyDown/insertText (DESIGN.md rule T1).")

    for rel in tracked(root, "webviews/src"):
        if not rel.endswith("/main.tsx") or rel in PAGE_ENTRY_EXEMPT or "/gallery/" in rel:
            continue
        text = (root / rel).read_text(encoding="utf-8", errors="replace")
        if "createRoot(" in text and "shared/desktop" not in text:
            errors.append(
                f"{rel}: a page entry without the shared desktop layer (pages/shared/desktop), so the IME key "
                "layer (imeKeys.ts) is missing: its key handlers would act on keys an input method is using "
                "(DESIGN.md rule W1). Import it first, as the other entries do.")

    for error in errors:
        print(f"check-ime-input: {error}", file=sys.stderr)
    if errors:
        print(f"check-ime-input: {len(errors)} violation(s)", file=sys.stderr)
        return 1
    print("check-ime-input: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
