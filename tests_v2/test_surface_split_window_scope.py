#!/usr/bin/env python3
"""Window-scope coverage for split-off and drag-to-split on moved workspaces."""

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


def _surface_id(payload: dict) -> str:
    return str(payload.get("surface_id") or payload.get("surface_ref") or payload.get("id") or "")


def _assert_window(payload: dict, expected_window_id: str, label: str) -> None:
    window_id = str(payload.get("window_id") or payload.get("window_ref") or "")
    if window_id != expected_window_id:
        raise cmuxError(f"{label} did not stay in destination window: {payload}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        w1 = _focused_window_id(c)
        w2 = c.new_window()
        workspace_id = ""
        time.sleep(0.3)
        try:
            workspace_id = c.new_workspace(window_id=w1)
            c.select_workspace(workspace_id, window_id=w1)
            time.sleep(0.2)

            second = _surface_id(
                c._call(
                    "surface.create",
                    {"workspace_id": workspace_id, "pane_id": "0", "focus": False},
                )
                or {}
            )
            third = _surface_id(
                c._call(
                    "surface.create",
                    {"workspace_id": workspace_id, "pane_id": "0", "focus": False},
                )
                or {}
            )
            close_target = _surface_id(
                c._call(
                    "surface.create",
                    {"workspace_id": workspace_id, "pane_id": "0", "focus": False},
                )
                or {}
            )
            move_target = _surface_id(
                c._call(
                    "surface.create",
                    {"workspace_id": workspace_id, "pane_id": "0", "focus": False},
                )
                or {}
            )
            if (
                not second
                or not third
                or not close_target
                or not move_target
                or len({second, third, close_target, move_target}) != 4
            ):
                raise cmuxError(
                    "surface.create returned invalid surfaces: "
                    f"{second=} {third=} {close_target=} {move_target=}"
                )

            c.move_workspace_to_window(workspace_id, w2, focus=True)
            time.sleep(0.4)
            if _window_has_workspace(c, w1, workspace_id):
                raise cmuxError("Setup left moved workspace in source window")

            health = c._call("surface.health", {"workspace_id": workspace_id}) or {}
            _assert_window(health, w2, "surface.health")

            refresh = c._call("surface.refresh", {"workspace_id": workspace_id}) or {}
            _assert_window(refresh, w2, "surface.refresh")

            clear_history = c._call(
                "surface.clear_history",
                {"workspace_id": workspace_id, "surface_id": second},
            ) or {}
            _assert_window(clear_history, w2, "surface.clear_history")

            flash = c._call(
                "surface.trigger_flash",
                {"workspace_id": workspace_id, "surface_id": second},
            ) or {}
            _assert_window(flash, w2, "surface.trigger_flash")

            sent = c._call(
                "surface.send_text",
                {"workspace_id": workspace_id, "surface_id": second, "text": "CMX_SCOPE"},
            ) or {}
            _assert_window(sent, w2, "surface.send_text")

            renamed = c._call(
                "tab.action",
                {
                    "workspace_id": workspace_id,
                    "surface_id": second,
                    "action": "rename",
                    "title": "cmx-window-scope",
                },
            ) or {}
            _assert_window(renamed, w2, "tab.action rename")

            created_right = c._call(
                "tab.action",
                {
                    "workspace_id": workspace_id,
                    "surface_id": second,
                    "action": "new_terminal_right",
                    "focus": True,
                },
            ) or {}
            _assert_window(created_right, w2, "tab.action new_terminal_right")

            moved_to_workspace = c._call(
                "tab.action",
                {
                    "workspace_id": workspace_id,
                    "surface_id": move_target,
                    "action": "move_to_new_workspace",
                    "title": "cmx-tab-action-window-scope",
                    "focus": False,
                },
            ) or {}
            _assert_window(moved_to_workspace, w2, "tab.action move_to_new_workspace")
            created_workspace_id = str(
                moved_to_workspace.get("created_workspace_id")
                or moved_to_workspace.get("workspace_id")
                or ""
            )
            if not created_workspace_id or created_workspace_id == workspace_id:
                raise cmuxError(f"tab.action move_to_new_workspace returned no created workspace: {moved_to_workspace}")
            if _window_has_workspace(c, w1, created_workspace_id):
                raise cmuxError("tab.action move_to_new_workspace reattached created workspace to source window")
            if not _window_has_workspace(c, w2, created_workspace_id):
                raise cmuxError("tab.action move_to_new_workspace did not add created workspace to destination window")

            reordered = c._call(
                "surface.reorder",
                {"workspace_id": workspace_id, "surface_id": third, "index": 0, "focus": True},
            ) or {}
            _assert_window(reordered, w2, "surface.reorder")

            closed = c._call(
                "surface.close",
                {"workspace_id": workspace_id, "surface_id": close_target},
            ) or {}
            _assert_window(closed, w2, "surface.close")

            split_off = c._call(
                "surface.split_off",
                {
                    "workspace_id": workspace_id,
                    "surface_id": second,
                    "direction": "right",
                    "focus": True,
                },
            ) or {}
            _assert_window(split_off, w2, "surface.split_off")
            if _window_has_workspace(c, w1, workspace_id):
                raise cmuxError("surface.split_off reattached workspace to source window")

            dragged = c._call(
                "surface.drag_to_split",
                {
                    "workspace_id": workspace_id,
                    "surface_id": third,
                    "target_surface_id": second,
                    "edge": "bottom",
                    "focus": True,
                },
            ) or {}
            _assert_window(dragged, w2, "surface.drag_to_split")
            if _window_has_workspace(c, w1, workspace_id):
                raise cmuxError("surface.drag_to_split reattached workspace to source window")

            last_pane = c._call("pane.last", {"workspace_id": workspace_id}) or {}
            _assert_window(last_pane, w2, "pane.last")
            if _window_has_workspace(c, w1, workspace_id):
                raise cmuxError("pane.last reattached workspace to source window")
        finally:
            try:
                c.close_window(w2)
            except Exception:
                pass

    print(
        "PASS: split-off and drag-to-split preserve moved-workspace window scope "
        f"workspace={workspace_id} window={w2}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
