#!/usr/bin/env python3
"""
Regression test: the initial terminal surface must be interactive and rendering
immediately on launch.

Bug: the first terminal (or a newly-created surface) could appear "frozen" until
the user manually changes focus (alt-tab / click another split and back). In this
state, input may be buffered and only becomes visible after pressing Enter or
after a focus toggle.

This test avoids screenshots (which can mask redraw issues) by checking:
  - The terminal view is attached and selected.
  - Typing a command is visible in the terminal text *before* pressing Enter.
  - Pressing Enter executes the command (verified via a tmp file write).
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _wait_for(pred, timeout_s: float, step_s: float = 0.05) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if pred():
            return
        time.sleep(step_s)
    raise cmuxError("Timed out waiting for condition")


def _wait_for_surface_focus(c: cmux, panel_id: str, timeout_s: float = 5.0) -> None:
    panel_lower = panel_id.lower()
    start = time.time()
    while time.time() - start < timeout_s:
        try:
            c.activate_app()
        except Exception:
            pass

        try:
            if c.is_terminal_focused(panel_id):
                return
        except Exception:
            pass

        try:
            ident = c.identify()
            focused = (ident or {}).get("focused") or {}
            sid = str(focused.get("surface_id") or "").lower()
            if sid and sid == panel_lower:
                return
        except Exception:
            pass

        time.sleep(0.05)

    raise cmuxError(f"Timed out waiting for surface focus: {panel_id}")


def _wait_for_render_context(c: cmux, panel_id: str, timeout_s: float = 5.0) -> dict:
    """Wait until terminal view is attached for interactive checks."""
    start = time.time()
    last = {}
    while time.time() - start < timeout_s:
        try:
            c.activate_app()
        except Exception:
            pass
        last = c.render_stats(panel_id)
        if bool(last.get("inWindow")):
            return last
        time.sleep(0.1)
    raise cmuxError(f"Expected inWindow render context, got: {last}")


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
        _wait_for_surface_focus(c, panel_id, timeout_s=5.0)

        baseline = _wait_for_render_context(c, panel_id, timeout_s=5.0)
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
