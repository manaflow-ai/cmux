#!/usr/bin/env python3
"""
Regression test: the initial terminal surface must be interactive and rendering
immediately on launch.

Bug: the first terminal (or a newly-created surface) could appear "frozen" until
the user manually changes focus (alt-tab / click another split and back). In this
state, input may be buffered and only becomes visible after pressing Enter or
after a focus toggle.

This test avoids screenshots (which can mask redraw issues) by checking:
  - The terminal view is first responder.
  - Typing a command is visible in the terminal text *before* pressing Enter.
  - Pressing Enter executes the command (verified via a tmp file write).
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
    token = f"CMUX_INIT_{int(time.time() * 1000)}"
    tmp = f"/tmp/cmux_init_{token}.txt"
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.2)

        ws_id = c.new_workspace()
        c.select_workspace(ws_id)
        time.sleep(0.3)

        surfaces = c.list_surfaces()
        if not surfaces:
            raise cmuxError("Expected at least 1 surface after new_workspace")
        panel_id = next((sid for _i, sid, focused in surfaces if focused), surfaces[0][1])

        # Ensure the first terminal is focused without requiring any manual interaction.
        _wait_for(lambda: c.is_terminal_focused(panel_id), timeout_s=3.0)

        baseline = c.render_stats(panel_id)
        if not baseline.get("appIsActive", True):
            raise cmuxError(f"Expected appIsActive=true, got: {baseline}")
        if not baseline.get("windowIsKey", True):
            raise cmuxError(f"Expected windowIsKey=true, got: {baseline}")
        if not baseline.get("windowOcclusionVisible", True):
            raise cmuxError(f"Expected windowOcclusionVisible=true, got: {baseline}")

        baseline_present = int(baseline.get("presentCount", 0) or 0)

        cmd = f"echo {token} > {tmp}"
        c.simulate_type(cmd)

        # The key regression: typed text must become visible before pressing Enter.
        _wait_for(lambda: cmd in c.read_terminal_text(panel_id), timeout_s=2.0)

        # Also require at least one layer presentation after typing; this is a stronger
        # proxy for "the UI actually updated" than reading terminal text alone.
        def did_present() -> bool:
            stats = c.render_stats(panel_id)
            return int(stats.get("presentCount", 0) or 0) > baseline_present

        _wait_for(did_present, timeout_s=2.0)

        # Use insertText for newline instead of a synthetic keyDown "enter" event.
        # KeyDown delivery can be flaky when the app is activating or the key window
        # is transitioning; insertText keeps this test focused on the "frozen rendering"
        # regression rather than AppKit event routing.
        c.simulate_type("\n")

        # Verify the shell actually received/ran the command.
        def wrote_file() -> bool:
            try:
                return Path(tmp).read_text().strip() == token
            except Exception:
                return False

        _wait_for(wrote_file, timeout_s=3.0)

    print("PASS: initial terminal interactive + rendering")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
