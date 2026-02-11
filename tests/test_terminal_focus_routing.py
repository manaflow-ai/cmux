#!/usr/bin/env python3
"""
Regression test: terminal focus must track the visible/focused surface across split operations.

Why: we've seen cases where the focused surface highlights correctly, but AppKit first responder
remains on another (often detached) terminal view. Users then type but nothing appears (input is
routed elsewhere).

This test validates:
  1) The focused terminal is actually first responder (`is_terminal_focused`).
  2) Text insertion via debug socket (`simulate_type`) lands in the expected terminal by writing
     $CMUX_SURFACE_ID to a temp file.
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmuxterm-debug.sock")
FOCUS_FILE = Path("/tmp/cmux_focus_routing.txt")


def _focused_surface_id(c: cmux) -> str:
    surfaces = c.list_surfaces()
    for _, sid, focused in surfaces:
        if focused:
            return sid
    raise cmuxError(f"No focused surface in list_surfaces: {surfaces}")


def _wait_for_file_content(path: Path, timeout_s: float = 3.0) -> str:
    start = time.time()
    while time.time() - start < timeout_s:
        if path.exists():
            try:
                data = path.read_text().strip()
            except Exception:
                data = ""
            if data:
                return data
        time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for file content: {path}")


def _wait_for_terminal_focus(c: cmux, panel_id: str, timeout_s: float = 2.0) -> None:
    start = time.time()
    while time.time() - start < timeout_s:
        if c.is_terminal_focused(panel_id):
            return
        time.sleep(0.05)
    raise cmuxError(f"Timed out waiting for terminal focus: {panel_id}")


def _assert_routed_to_surface(c: cmux, expected_surface_id: str) -> None:
    if FOCUS_FILE.exists():
        try:
            FOCUS_FILE.unlink()
        except Exception:
            pass

    # Write the currently focused surface id into a well-known file.
    c.simulate_type(f"echo $CMUX_SURFACE_ID > {FOCUS_FILE}")
    c.simulate_shortcut("enter")
    actual = _wait_for_file_content(FOCUS_FILE)
    if actual != expected_surface_id:
        raise cmuxError(f"Input routed to wrong surface: expected={expected_surface_id} actual={actual}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        # Isolate from any user workspace state.
        c.new_workspace()
        time.sleep(0.2)
        # Focus-sensitive assertions require the main window to be key.
        # When launched via SSH, `open` does not always activate the app.
        c.activate_app()
        time.sleep(0.2)

        # Create a bunch of terminals to stress layout/focus code paths.
        for _ in range(12):
            c.new_surface(panel_type="terminal")
            time.sleep(0.02)

        surfaces = c.list_surfaces()
        if not surfaces:
            raise cmuxError("Expected at least one surface after new_workspace")
        left_id = surfaces[0][1]

        # Create a split to the right (this may trigger bonsplit reparenting/structural updates).
        right_id = c.new_split("right")
        if not right_id:
            # Should not happen with current server, but keep a fallback for older behavior.
            right_id = _focused_surface_id(c)
        time.sleep(0.25)

        # Focus left then right, verifying both first responder and input routing.
        c.activate_app()
        c.focus_surface_by_panel(left_id)
        time.sleep(0.15)
        _wait_for_terminal_focus(c, left_id)
        _assert_routed_to_surface(c, left_id)

        c.activate_app()
        c.focus_surface_by_panel(right_id)
        time.sleep(0.15)
        _wait_for_terminal_focus(c, right_id)
        _assert_routed_to_surface(c, right_id)

        # Stress: repeated split/close should never leave focus on a detached/hidden terminal.
        for i in range(10):
            new_id = c.new_split("right")
            time.sleep(0.1)
            c.focus_surface_by_panel(new_id)
            time.sleep(0.15)
            _wait_for_terminal_focus(c, new_id, timeout_s=2.0)
            _assert_routed_to_surface(c, new_id)

            c.close_surface(new_id)
            time.sleep(0.25)
            focused = _focused_surface_id(c)
            _wait_for_terminal_focus(c, focused, timeout_s=2.0)
            _assert_routed_to_surface(c, focused)

    print("PASS: terminal focus routing")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
