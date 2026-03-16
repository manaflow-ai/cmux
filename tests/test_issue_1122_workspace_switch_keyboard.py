#!/usr/bin/env python3
"""
Regression test for #1122: terminal keyboard focus must survive workspace switch-back.

Why: workspace activation and first-responder restoration can race. If the retiring
workspace clears first responder before the selected terminal reclaims it, typing stops
until the user clicks the terminal again.

This test verifies:
  1) Repeated switch-away / switch-back cycles restore the selected terminal as first responder.
  2) Simulated typing reaches that terminal through the real current first-responder path.
"""

import os
import sys
import time
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")
FOCUS_FILE = Path(tempfile.gettempdir()) / f"cmux_issue_1122_focus_{os.getpid()}.txt"


def _selected_terminal_panel_id(c: cmux) -> str:
    surfaces = c.list_surfaces()
    if not surfaces:
        raise cmuxError("Expected a selected terminal surface")
    return surfaces[0][1]


def _wait_for_terminal_focus(c: cmux, panel_id: str, timeout_s: float = 3.0) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if c.is_terminal_focused(panel_id):
            return
        time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for terminal focus after workspace switch: {panel_id}")


def _wait_for_file_content(path: Path, timeout_s: float = 3.0) -> str:
    start = time.time()
    while time.time() - start < timeout_s:
        if path.exists():
            data = path.read_text().strip()
            if data:
                return data
        time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for file content: {path}")


def _assert_typed_input_routes_to_selected_terminal(c: cmux, expected_surface_id: str) -> None:
    FOCUS_FILE.unlink(missing_ok=True)
    c.simulate_type(f"printf %s $CMUX_SURFACE_ID > {FOCUS_FILE}")
    c.simulate_shortcut("enter")
    actual = _wait_for_file_content(FOCUS_FILE)
    if actual != expected_surface_id:
        raise cmuxError(
            f"Typed input routed to wrong terminal after workspace switch: "
            f"expected={expected_surface_id} actual={actual}"
        )


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        ws_a = c.new_workspace()
        time.sleep(0.3)
        c.activate_app()
        time.sleep(0.2)
        panel_a = _selected_terminal_panel_id(c)

        ws_b = c.new_workspace()
        time.sleep(0.3)

        for _ in range(6):
            c.select_workspace(ws_a)
            time.sleep(0.12)
            c.select_workspace(ws_b)
            time.sleep(0.12)

        c.select_workspace(ws_a)
        time.sleep(0.2)

        _wait_for_terminal_focus(c, panel_a, timeout_s=3.0)
        _assert_typed_input_routes_to_selected_terminal(c, panel_a)

    print("PASS: workspace switch-back restores terminal keyboard focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
