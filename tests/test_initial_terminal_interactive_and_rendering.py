#!/usr/bin/env python3
"""
Regression test: the initial terminal surface must be interactive and rendering
immediately on launch.

Bug: the first terminal (or a newly-created surface) could appear "frozen" until
the user manually changes focus (alt-tab / click another split and back). In this
state, input may be buffered and only becomes visible after refocus.

This test avoids screenshots (which can mask redraw issues) by checking:
  - The terminal view is first responder.
  - Typing a command results in visible text via read_terminal_text.
  - The CAMetalLayer drawable counter increases (render loop is active).
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
        baseline_count = int(baseline.get("drawCount", 0))

        c.simulate_type(f"echo {token}")
        c.simulate_shortcut("enter")

        # Wait for the text to become visible.
        def has_token() -> bool:
            return token in c.read_terminal_text(panel_id)

        _wait_for(has_token, timeout_s=3.0)

        # Rendering must also advance (even if text buffer updates).
        def drew() -> bool:
            stats = c.render_stats(panel_id)
            return int(stats.get("drawCount", 0)) > baseline_count

        _wait_for(drew, timeout_s=3.0)

    print("PASS: initial terminal interactive + rendering")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
