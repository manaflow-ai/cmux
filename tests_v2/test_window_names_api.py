#!/usr/bin/env python3
"""
E2E tests for addressing windows by name over the socket (v2).

Goals:
- window.create accepts a name and frame, and window.list reports both
- window.set_name renames and clears a window's name
- window.set_frame moves a window
- system.tree reports window names and each workspace's instance_index
"""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _window(c: cmux, window_id: str) -> dict:
    for w in c.list_windows():
        if str(w.get("id")) == window_id:
            return w
    raise cmuxError(f"window {window_id} missing from window.list")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        frame = {"x": 120, "y": 140, "width": 900, "height": 640}
        res = c._call("window.create", {"name": "Mirror Test", "frame": frame}) or {}
        wid = str(res.get("window_id") or "")
        if not wid:
            raise cmuxError(f"window.create returned no window_id: {res}")
        time.sleep(0.3)

        created = _window(c, wid)
        if created.get("name") != "Mirror Test":
            raise cmuxError(f"Expected name from window.create, got {created.get('name')!r}")
        got = created.get("frame") or {}
        if int(got.get("width", 0)) != 900 or int(got.get("height", 0)) != 640:
            raise cmuxError(f"Expected 900x640 frame from window.create, got {got}")

        c._call("window.set_name", {"window_id": wid, "name": "Mirror Renamed"})
        if _window(c, wid).get("name") != "Mirror Renamed":
            raise cmuxError("Expected window.set_name to rename the window")

        c._call("window.set_frame", {"window_id": wid, "frame": {"x": 160, "y": 180, "width": 800, "height": 600}})
        time.sleep(0.2)
        moved = _window(c, wid).get("frame") or {}
        if int(moved.get("width", 0)) != 800:
            raise cmuxError(f"Expected window.set_frame to resize the window, got {moved}")

        tree = c._call("system.tree", {"all_windows": True}) or {}
        node = next((w for w in tree.get("windows", []) if str(w.get("id")) == wid), None)
        if node is None or node.get("name") != "Mirror Renamed":
            raise cmuxError(f"Expected system.tree to report the window name, got {node}")
        workspaces = node.get("workspaces") or []
        if not workspaces or not all(isinstance(ws.get("instance_index"), int) for ws in workspaces):
            raise cmuxError(f"Expected instance_index on every workspace in system.tree, got {workspaces}")

        c._call("window.set_name", {"window_id": wid, "name": None})
        if _window(c, wid).get("name") is not None:
            raise cmuxError("Expected window.set_name with null to clear the name")

        try:
            c._call("window.set_name", {"window_id": "00000000-0000-0000-0000-000000000000", "name": "x"})
        except cmuxError:
            pass
        else:
            raise cmuxError("Expected window.set_name on an unknown window to fail")

        c.close_window(wid)

    print("PASS: windows can be created, named, renamed, moved and read back by name")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
