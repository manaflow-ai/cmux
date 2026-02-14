#!/usr/bin/env python3
"""
E2E tests for multi-window socket control (v2).

Goals:
- window handles are stable UUIDs
- workspace IDs can be moved across windows
- surface IDs remain stable when their workspace moves windows
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _focused_window_id(c: cmux) -> str:
    ident = c.identify()
    focused = ident.get("focused") or {}
    if isinstance(focused, dict):
        wid = focused.get("window_id")
        if wid:
            return str(wid)
    # Fallback in case identify.focused isn't populated yet.
    return c.current_window()


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        windows0 = c.list_windows()
        if not windows0:
            raise cmuxError("Expected at least one window from window.list")

        w1 = _focused_window_id(c)

        w2 = c.new_window()
        time.sleep(0.2)

        windows1 = c.list_windows()
        ids1 = {str(w.get("id")) for w in windows1 if w.get("id")}
        if w1 not in ids1:
            raise cmuxError(f"Expected original window id in window.list (w1={w1}, ids={sorted(ids1)})")
        if w2 not in ids1:
            raise cmuxError(f"Expected new window id in window.list (w2={w2}, ids={sorted(ids1)})")

        # Create a workspace in w1, ensure it has at least 2 surfaces, then move it to w2.
        ws = c.new_workspace(window_id=w1)
        c.select_workspace(ws)
        time.sleep(0.2)

        _ = c.new_split("right")
        time.sleep(0.5)

        before = c.list_surfaces(ws)
        before_ids = [sid for _, sid, _focused in before]
        if len(before_ids) < 2:
            raise cmuxError(f"Expected >=2 surfaces before move, got {len(before_ids)} ({before_ids})")

        c.move_workspace_to_window(ws, w2, focus=True)
        time.sleep(0.5)

        # Wait for reattachment after cross-window move.
        start = time.time()
        while time.time() - start < 6.0:
            health = c.surface_health(ws)
            if health and all(h.get("in_window") is True for h in health):
                break
            time.sleep(0.2)
        else:
            raise cmuxError(f"Expected all moved surfaces to be in_window=true (health={health})")

        # Ensure the moved workspace is now associated with destination window.
        w2_workspaces = c.list_workspaces(window_id=w2)
        w2_ids = {wid for _, wid, _title, _sel in w2_workspaces}
        if ws not in w2_ids:
            raise cmuxError("Expected moved workspace to be present in destination window")

        # Focus behavior can lag under VM/SSH app-activation conditions.
        # Ensure the workspace is at least selectable post-move.
        c.select_workspace(ws)
        time.sleep(0.2)
        ident2 = c.identify()
        focused2 = ident2.get("focused") or {}
        if not isinstance(focused2, dict) or str(focused2.get("workspace_id")) != ws:
            raise cmuxError(f"Expected moved workspace to be selectable after move (focused={focused2})")

        after = c.list_surfaces(ws)
        after_ids = [sid for _, sid, _focused in after]
        if set(after_ids) != set(before_ids):
            raise cmuxError(f"Expected surface IDs to remain stable after move (before={before_ids}, after={after_ids})")

        # Source window should still have workspaces, but not this one.
        w1_workspaces = c.list_workspaces(window_id=w1)
        w1_ids = {wid for _, wid, _title, _sel in w1_workspaces}
        if ws in w1_ids:
            raise cmuxError("Expected moved workspace to no longer be present in source window")

    print("PASS: window list/create + workspace move preserves surface IDs")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
