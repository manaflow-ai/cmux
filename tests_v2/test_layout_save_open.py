#!/usr/bin/env python3
"""E2E: save a workspace layout, then open a new workspace from it."""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "").strip()
if not SOCKET_PATH:
    raise cmuxError("CMUX_SOCKET_PATH is required")


def _must(condition: bool, message: str) -> None:
    if not condition:
        raise cmuxError(message)


def _create_workspace(c: cmux, layout: dict) -> str:
    payload = c._call(
        "workspace.create",
        {
            "title": f"layout-save-source-{int(time.time() * 1000)}",
            "layout": layout,
        },
    ) or {}
    workspace_id = str(payload.get("workspace_id") or "")
    _must(bool(workspace_id), f"workspace.create returned no workspace_id: {payload}")
    return workspace_id


def _pane_rows(c: cmux, workspace_id: str) -> list[dict]:
    payload = c._call("pane.list", {"workspace_id": workspace_id}) or {}
    return list(payload.get("panes") or [])


def _surface_rows(c: cmux, workspace_id: str) -> list[dict]:
    payload = c._call("surface.list", {"workspace_id": workspace_id}) or {}
    return list(payload.get("surfaces") or [])


def _frame(row: dict) -> dict:
    frame = row.get("pixel_frame")
    _must(isinstance(frame, dict), f"pane row missing pixel_frame: {row}")
    return frame


def _assert_live_layout(c: cmux, workspace_id: str) -> None:
    panes = _pane_rows(c, workspace_id)
    _must(len(panes) == 3, f"expected 3 panes, got {len(panes)}: {panes}")
    frames = [_frame(row) for row in panes]
    left = min(frames, key=lambda frame: float(frame.get("x", 0)))
    right_frames = [frame for frame in frames if frame is not left]
    left_width = float(left["width"])
    right_width = max(float(frame["x"]) + float(frame["width"]) for frame in right_frames) - min(float(frame["x"]) for frame in right_frames)
    root_ratio = left_width / (left_width + right_width)
    _must(abs(root_ratio - 0.4) <= 0.04, f"root split ratio mismatch: {root_ratio} frames={frames}")

    top = min(right_frames, key=lambda frame: float(frame.get("y", 0)))
    bottom = max(right_frames, key=lambda frame: float(frame.get("y", 0)))
    nested_ratio = float(top["height"]) / (float(top["height"]) + float(bottom["height"]))
    _must(abs(nested_ratio - 0.65) <= 0.05, f"nested split ratio mismatch: {nested_ratio} frames={frames}")

    surfaces = _surface_rows(c, workspace_id)
    types = sorted(str(row.get("type") or "") for row in surfaces)
    _must(types == ["browser", "terminal", "terminal"], f"unexpected surface types: {types} rows={surfaces}")


def main() -> int:
    layout_name = f"e2e-layout-{os.getpid()}-{int(time.time() * 1000)}"
    source_workspace = ""
    opened_workspace = ""
    layout = {
        "direction": "horizontal",
        "split": 0.4,
        "children": [
                    {"pane": {"surfaces": [{"type": "terminal", "name": "Left"}]}},
                    {
                        "direction": "vertical",
                        "split": 0.65,
                        "children": [
                    {"pane": {"surfaces": [{"type": "browser", "url": "about:blank", "name": "Docs"}]}},
                    {"pane": {"surfaces": [{"type": "terminal", "cwd": "/tmp", "name": "Bottom"}]}},
                ],
            },
        ],
    }

    with cmux(SOCKET_PATH) as c:
        baseline_workspace = c.current_workspace()
        try:
            source_workspace = _create_workspace(c, layout)
            saved = c._call(
                "layout.save",
                {"name": layout_name, "workspace_id": source_workspace, "overwrite": True},
            ) or {}
            _must(saved.get("name") == layout_name, f"layout.save returned unexpected payload: {saved}")

            listed = c._call("layout.list") or {}
            rows = list(listed.get("layouts") or [])
            match = next((row for row in rows if row.get("name") == layout_name), None)
            _must(match is not None, f"layout.list did not include {layout_name}: {rows}")
            _must(int(match.get("pane_count") or 0) == 3, f"layout.list pane_count mismatch: {match}")
            _must(int(match.get("surface_count") or 0) == 3, f"layout.list surface_count mismatch: {match}")

            got = c._call("layout.get", {"name": layout_name}) or {}
            saved_layout = ((got.get("workspace") or {}).get("layout") or {})
            _must(saved_layout.get("direction") == "horizontal", f"layout.get root mismatch: {got}")
            _must(abs(float(saved_layout.get("split") or 0) - 0.4) <= 0.02, f"layout.get split mismatch: {got}")

            opened = c._call("layout.open", {"name": layout_name, "focus": True}) or {}
            opened_workspace = str(opened.get("workspace_id") or "")
            _must(bool(opened_workspace), f"layout.open returned no workspace_id: {opened}")
            _must(c.current_workspace() == opened_workspace, f"layout.open focus:true did not focus workspace {opened_workspace}")
            _assert_live_layout(c, opened_workspace)

            deleted = c._call("layout.delete", {"name": layout_name}) or {}
            _must(deleted.get("deleted") is True, f"layout.delete returned unexpected payload: {deleted}")
            try:
                c._call("layout.open", {"name": layout_name})
                raise cmuxError("layout.open should fail after delete")
            except cmuxError as err:
                _must("not_found" in str(err), f"layout.open after delete should be not_found, got: {err}")

            if baseline_workspace:
                c.select_workspace(baseline_workspace)
        finally:
            try:
                c._call("layout.delete", {"name": layout_name})
            except Exception:
                pass
            for workspace_id in [opened_workspace, source_workspace]:
                if workspace_id:
                    try:
                        c.close_workspace(workspace_id)
                    except Exception:
                        pass

    print("PASS: saved layout save/list/get/open/delete round-trips split geometry and surface types")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
