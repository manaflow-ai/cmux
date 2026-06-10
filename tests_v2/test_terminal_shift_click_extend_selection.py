#!/usr/bin/env python3
"""Regression: shift+click must extend an existing terminal selection (Ghostty parity).

Ghostty core extends the current selection when a left click lands with shift
held, an earlier click recorded, and more than mouse-interval (500ms) elapsed.
cmux heavily customizes the macOS event path around GhosttyNSView, so this
guards the whole chain view-handlers -> ghostty_surface_mouse_* -> core
selection state via the debug.terminal.mouse / debug.terminal.selection
socket methods.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")

# Core refuses to extend within its mouse-interval (default 500ms) so a fast
# second click can still count as a double-click. Stay safely above it.
MOUSE_INTERVAL_GRACE_S = 0.8

ROW_Y = 0.5
DRAG_START_X = 0.10
DRAG_END_X = 0.30
EXTEND_X = 0.60


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _fill_viewport(c: cmux) -> None:
    c.send("clear; seq -f 'ROW%02g aaaa bbbb cccc dddd eeee ffff gggg hhhh' 1 40\\n")
    deadline = time.time() + 8.0
    while time.time() < deadline:
        if "ROW20" in c.read_terminal_text():
            return
        time.sleep(0.2)
    raise cmuxError("Timed out waiting for test rows to render")


def _drag_select(c: cmux) -> None:
    c.terminal_mouse("down", DRAG_START_X, ROW_Y)
    steps = 8
    for i in range(1, steps + 1):
        x = DRAG_START_X + (DRAG_END_X - DRAG_START_X) * i / steps
        c.terminal_mouse("drag", x, ROW_Y)
        time.sleep(0.02)
    c.terminal_mouse("up", DRAG_END_X, ROW_Y)


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        _fill_viewport(c)

        # Baseline: plain drag-select produces a selection.
        _drag_select(c)
        time.sleep(0.3)
        active, base_text = c.terminal_selection()
        _must(active, "drag-select did not produce a selection")
        _must(bool(base_text.strip()), f"drag-select produced empty text: {base_text!r}")

        time.sleep(MOUSE_INTERVAL_GRACE_S)

        # Shift+click further right on the same row must extend, not replace.
        c.terminal_mouse("down", EXTEND_X, ROW_Y, mods="shift")
        c.terminal_mouse("up", EXTEND_X, ROW_Y, mods="shift")
        time.sleep(0.3)
        active, extended_text = c.terminal_selection()
        _must(active, "selection vanished after shift+click")
        _must(
            len(extended_text) > len(base_text),
            f"shift+click did not extend selection: base={base_text!r} after={extended_text!r}",
        )
        _must(
            base_text.strip()[:6] in extended_text,
            f"extended selection lost the original anchor: base={base_text!r} after={extended_text!r}",
        )

        # Plain click clears the selection again (no sticky extend state).
        c.terminal_mouse("down", DRAG_START_X, 0.9)
        c.terminal_mouse("up", DRAG_START_X, 0.9)
        time.sleep(0.3)
        active, _ = c.terminal_selection()
        _must(not active, "plain click after shift+click extension should clear the selection")

    print("PASS: shift+click extends terminal selection")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except cmuxError as exc:
        print(f"FAIL: {exc}", file=sys.stderr)
        sys.exit(1)
