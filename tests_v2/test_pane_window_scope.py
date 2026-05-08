#!/usr/bin/env python3
"""Window-scope coverage for pane mutations on moved workspaces."""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _focused_window_id(c: cmux) -> str:
    focused = (c.identify().get("focused") or {})
    if isinstance(focused, dict) and focused.get("window_id"):
        return str(focused["window_id"])
    return c.current_window()


def _window_has_workspace(c: cmux, window_id: str, workspace_id: str) -> bool:
    return workspace_id in {
        wid for _, wid, _title, _selected in c.list_workspaces(window_id=window_id)
    }


def _pane_ids(c: cmux, workspace_id: str) -> list[str]:
    panes = (c._call("pane.list", {"workspace_id": workspace_id}) or {}).get("panes") or []
    return [str(pane.get("id") or "") for pane in panes if pane.get("id") is not None]


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        w1 = _focused_window_id(c)
        w2 = c.new_window()
        time.sleep(0.3)
        try:
            workspace_id = c.new_workspace(window_id=w1)
            c.select_workspace(workspace_id, window_id=w1)
            split = c._call(
                "surface.split",
                {"workspace_id": workspace_id, "direction": "right"},
            ) or {}
            if not split.get("surface_id"):
                raise cmuxError(f"surface.split returned no surface_id: {split}")
            time.sleep(0.3)
            panes = _pane_ids(c, workspace_id)
            if len(panes) < 2:
                raise cmuxError(f"Expected at least two panes before mutation, got {panes}")

            c.move_workspace_to_window(workspace_id, w2, focus=True)
            time.sleep(0.4)
            if _window_has_workspace(c, w1, workspace_id):
                raise cmuxError("Setup left moved workspace in source window")

            swapped = c._call(
                "pane.swap",
                {
                    "workspace_id": workspace_id,
                    "pane_id": panes[0],
                    "target_pane_id": panes[1],
                    "focus": True,
                },
            ) or {}
            if str(swapped.get("window_id") or swapped.get("window_ref") or "") != w2:
                raise cmuxError(f"pane.swap did not stay in destination window: {swapped}")
            if _window_has_workspace(c, w1, workspace_id):
                raise cmuxError("pane.swap reattached workspace to source window")

            joined = c._call(
                "pane.join",
                {
                    "workspace_id": workspace_id,
                    "pane_id": panes[1],
                    "target_pane_id": panes[0],
                    "focus": True,
                },
            ) or {}
            if str(joined.get("window_id") or joined.get("window_ref") or "") != w2:
                raise cmuxError(f"pane.join did not stay in destination window: {joined}")
            if _window_has_workspace(c, w1, workspace_id):
                raise cmuxError("pane.join reattached workspace to source window")

            surface_id = str(joined.get("surface_id") or joined.get("surface_ref") or "")
            broken = c._call(
                "pane.break",
                {
                    "workspace_id": workspace_id,
                    "surface_id": surface_id,
                    "title": "cmx-pane-window-scope",
                    "focus": False,
                },
            ) or {}
            created_workspace_id = str(
                broken.get("workspace_id") or broken.get("workspace_ref") or ""
            )
            if not created_workspace_id or created_workspace_id == workspace_id:
                raise cmuxError(f"pane.break did not create a workspace: {broken}")
            if str(broken.get("window_id") or broken.get("window_ref") or "") != w2:
                raise cmuxError(f"pane.break did not stay in destination window: {broken}")
            if _window_has_workspace(c, w1, workspace_id):
                raise cmuxError("pane.break reattached original workspace to source window")
            if _window_has_workspace(c, w1, created_workspace_id):
                raise cmuxError("pane.break reattached created workspace to source window")
            if not _window_has_workspace(c, w2, created_workspace_id):
                raise cmuxError("pane.break did not add created workspace to destination window")
        finally:
            try:
                c.close_window(w2)
            except Exception:
                pass

    print("PASS: pane mutations preserve moved-workspace window scope")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
