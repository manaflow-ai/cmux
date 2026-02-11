#!/usr/bin/env python3
"""
Visual regression test: typing must visibly update the terminal as each character is entered.

Bug: the terminal can appear "frozen" where typed characters do not show up until Enter
or a focus toggle (unfocus/refocus, pane switch, alt-tab).

This test verifies *visual* updates by capturing per-panel screenshots via the debug socket
(`panel_snapshot`) and asserting the pixel-diff is non-trivial after each character.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")


def _wait_for(pred, timeout_s: float, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.25)

        ws_id = c.new_workspace()
        c.select_workspace(ws_id)
        time.sleep(0.35)

        surfaces = c.list_surfaces()
        if not surfaces:
            raise cmuxError("Expected at least 1 surface after new_workspace")
        panel_id = next((sid for _i, sid, focused in surfaces if focused), surfaces[0][1])

        _wait_for(lambda: c.is_terminal_focused(panel_id), timeout_s=3.0)

        # Type into the shell prompt without pressing Enter.
        text = "cmuxterm"

        # A single glyph can be surprisingly small at some font sizes; keep this low but
        # non-zero to still catch the "no visual updates until Enter/unfocus" regression.
        min_pixels = 20

        for i, ch in enumerate(text):
            c.panel_snapshot_reset(panel_id)
            c.panel_snapshot(panel_id, f"typing_{i}_before")

            # Use a real keyDown path (not NSTextInputClient.insertText) to better match
            # physical typing behavior and catch "input doesn't render until Enter/unfocus".
            c.simulate_shortcut(ch)
            time.sleep(0.12)

            snap = c.panel_snapshot(panel_id, f"typing_{i}_after_{ord(ch)}")
            changed = int(snap.get("changed_pixels", -1))
            if changed < min_pixels:
                raise cmuxError(
                    "Expected visible pixel changes after typing a character.\n"
                    f"char={ch!r} index={i} changed_pixels={changed} min_pixels={min_pixels}\n"
                    f"snapshot_path={snap.get('path')}"
                )

            # Also ensure the terminal text buffer updated before Enter. (This is weaker than the
            # visual assertion, but helps triage whether the issue is rendering vs tick/IO.)
            buf = c.read_terminal_text(panel_id)
            if text[: i + 1] not in buf:
                tail = buf[-600:].replace("\r", "\\r")
                raise cmuxError(
                    "Terminal text did not update after typing.\n"
                    f"expected_prefix={text[:i+1]!r}\n"
                    f"last_tail:\n{tail}"
                )

    print("PASS: visual typing updates char-by-char")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
