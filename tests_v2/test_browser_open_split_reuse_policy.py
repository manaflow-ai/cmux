#!/usr/bin/env python3
"""Regression tests for browser.open_split caller-relative pane reuse."""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _surface_id(payload: dict) -> str:
    return str((payload or {}).get("surface_id") or "")


def _pane_id(payload: dict) -> str:
    return str((payload or {}).get("pane_id") or "")


def _pane_count(c: cmux, workspace_id: str) -> int:
    panes_payload = c._call("pane.list", {"workspace_id": workspace_id}) or {}
    panes = panes_payload.get("panes") or []
    return len(panes)


def _pane_for_surface(c: cmux, workspace_id: str, surface_id: str) -> str:
    payload = c._call("surface.list", {"workspace_id": workspace_id}) or {}
    for row in payload.get("surfaces") or []:
        if str(row.get("id") or "") == surface_id:
            pane = str(row.get("pane_id") or "")
            if pane:
                return pane
    raise cmuxError(f"Surface {surface_id} not found in workspace {workspace_id}: {payload}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        created = c._call("workspace.create", {}) or {}
        workspace_id = str(created.get("workspace_id") or "")
        _must(bool(workspace_id), f"workspace.create returned no workspace_id: {created}")
        c._call("workspace.select", {"workspace_id": workspace_id})

        current = c._call("surface.current", {"workspace_id": workspace_id}) or {}
        left_surface = str(current.get("surface_id") or "")
        _must(bool(left_surface), f"surface.current returned no surface_id: {current}")

        right = c._call(
            "surface.split",
            {"workspace_id": workspace_id, "surface_id": left_surface, "direction": "right"},
        ) or {}
        right_surface = _surface_id(right)
        _must(bool(right_surface), f"surface.split right returned no surface_id: {right}")

        right_down = c._call(
            "surface.split",
            {"workspace_id": workspace_id, "surface_id": right_surface, "direction": "down"},
        ) or {}
        right_bottom_surface = _surface_id(right_down)
        _must(bool(right_bottom_surface), f"surface.split right/down returned no surface_id: {right_down}")

        left_down = c._call(
            "surface.split",
            {"workspace_id": workspace_id, "surface_id": left_surface, "direction": "down"},
        ) or {}
        left_bottom_surface = _surface_id(left_down)
        _must(bool(left_bottom_surface), f"surface.split left/down returned no surface_id: {left_down}")

        right_top_pane = _pane_for_surface(c, workspace_id, right_surface)
        right_bottom_pane = _pane_for_surface(c, workspace_id, right_bottom_surface)

        base_panes = _pane_count(c, workspace_id)

        open_from_left_top = c._call(
            "browser.open_split",
            {"workspace_id": workspace_id, "surface_id": left_surface, "url": "about:blank"},
        ) or {}
        _must(bool(open_from_left_top.get("created_split")) is False, f"Expected pane reuse from left-top: {open_from_left_top}")
        _must(
            str(open_from_left_top.get("target_pane_id") or "") == right_top_pane,
            f"Expected left-top to reuse top-right pane ({right_top_pane}): {open_from_left_top}",
        )
        _must(_pane_count(c, workspace_id) == base_panes, "Pane count changed during left-top reuse")

        open_from_left_bottom = c._call(
            "browser.open_split",
            {"workspace_id": workspace_id, "surface_id": left_bottom_surface, "url": "about:blank"},
        ) or {}
        _must(bool(open_from_left_bottom.get("created_split")) is False, f"Expected pane reuse from left-bottom: {open_from_left_bottom}")
        _must(
            str(open_from_left_bottom.get("target_pane_id") or "") == right_bottom_pane,
            f"Expected left-bottom to reuse bottom-right pane ({right_bottom_pane}): {open_from_left_bottom}",
        )
        _must(_pane_count(c, workspace_id) == base_panes, "Pane count changed during left-bottom reuse")

        before_right_open = _pane_count(c, workspace_id)
        open_from_right = c._call(
            "browser.open_split",
            {"workspace_id": workspace_id, "surface_id": right_bottom_surface, "url": "about:blank"},
        ) or {}
        _must(bool(open_from_right.get("created_split")) is True, f"Expected new split from right-most pane: {open_from_right}")
        _must(
            _pane_count(c, workspace_id) == before_right_open + 1,
            f"Expected pane count +1 after right-most open_split: before={before_right_open} after={_pane_count(c, workspace_id)}",
        )

    print("PASS: browser.open_split reuses nearest right pane and only splits from right-most callers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
