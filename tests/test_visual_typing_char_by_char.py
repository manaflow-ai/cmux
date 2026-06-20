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


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


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
        text = "cmux"

        # A single glyph can be surprisingly small at some font sizes; keep this low but
        # non-zero to still catch the "no visual updates until Enter/unfocus" regression.
        min_pixels = 20

        for i, ch in enumerate(text):
            c.panel_snapshot_reset(panel_id)
            # Establish the diff baseline; subsequent panel_snapshot calls diff the current
            # frame against this captured "before" image.
            c.panel_snapshot(panel_id, f"typing_{i}_before")

            # Use a real keyDown path (not NSTextInputClient.insertText) to better match
            # physical typing behavior and catch "input doesn't render until Enter/unfocus".
            c.simulate_shortcut(ch)

            # The chain keystroke -> PTY echo -> Ghostty render -> committed frame -> snapshot
            # diff is asynchronous; under CI/VM load a single committed frame can take well
            # over 120ms. Instead of a fixed sleep + one hard assert, poll the real signals:
            # the rendered pixel diff crossing min_pixels AND the terminal text buffer holding
            # the typed prefix. Each panel_snapshot diffs against the prior call, so a frame can
            # commit between two polls; latch on the first snapshot that crosses the threshold so
            # a split diff across polls still counts. Fail only at the deadline.
            expected_prefix = text[: i + 1]
            state = {"changed": -1, "snap": None, "buf": ""}

            def _typed_visible() -> bool:
                snap = c.panel_snapshot(panel_id, f"typing_{i}_after_{ord(ch)}")
                changed = int(snap.get("changed_pixels", -1))
                state["snap"] = snap
                if changed > state["changed"]:
                    state["changed"] = changed
                buf = c.read_terminal_text(panel_id)
                state["buf"] = buf
                return state["changed"] >= min_pixels and expected_prefix in buf

            try:
                _wait_for(_typed_visible, timeout_s=6.0)
            except cmuxError:
                snap = state["snap"] or {}
                if state["changed"] < min_pixels:
                    raise cmuxError(
                        "Expected visible pixel changes after typing a character.\n"
                        f"char={ch!r} index={i} changed_pixels={state['changed']} "
                        f"min_pixels={min_pixels}\n"
                        f"snapshot_path={snap.get('path')}"
                    )
                # Pixels changed but the terminal text buffer never showed the prefix. (This is
                # weaker than the visual assertion, but helps triage whether the issue is
                # rendering vs tick/IO.)
                tail = state["buf"][-600:].replace("\r", "\\r")
                raise cmuxError(
                    "Terminal text did not update after typing.\n"
                    f"expected_prefix={expected_prefix!r}\n"
                    f"last_tail:\n{tail}"
                )

    print("PASS: visual typing updates char-by-char")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
