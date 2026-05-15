#!/usr/bin/env python3
"""
Regression test: switching to an already-existing workspace must render its first
visible frame without requiring a second switch away and back.

Issue 3068's broader symptom family includes existing workspaces that stay blank
on the first return, then recover on a second workspace/tab switch. This test
warms two workspaces, repeatedly switches between them, and requires the selected
terminal surface to present a new frame on every first switch.
"""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path
from typing import Callable, Optional

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH") or os.environ.get("CMUX_SOCKET") or cmux.DEFAULT_SOCKET_PATH
SWITCH_CYCLES = 4
PRESENT_ADVANCE_TIMEOUT_S = float(os.environ.get("CMUX_PRESENT_ADVANCE_TIMEOUT_S", "5.0"))


def _wait_for(
    predicate: Callable[[], bool],
    *,
    timeout_s: float = 5.0,
    cadence_s: float = 0.05,
    label: str = "condition",
) -> None:
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        if predicate():
            return
        time.sleep(cadence_s)
    raise cmuxError(f"Timed out waiting for {label}")


def _focused_surface_id(c: cmux, workspace_id: str) -> str:
    surfaces = c.list_surfaces(workspace_id)
    if not surfaces:
        raise cmuxError(f"Expected at least one surface in workspace {workspace_id}")
    return next((sid for _idx, sid, focused in surfaces if focused), surfaces[0][1])


def _surface_health_row(c: cmux, surface_id: str) -> Optional[dict]:
    needle = surface_id.lower()
    for row in c.surface_health():
        if str(row.get("surface_id") or "").lower() == needle:
            return row
    return None


def _wait_for_surface_mount(c: cmux, surface_id: str) -> dict:
    last_row: dict | None = None

    def ready() -> bool:
        nonlocal last_row
        row = _surface_health_row(c, surface_id)
        if row is None:
            return False
        last_row = row
        width = float(((row.get("hosted_view_frame") or {}).get("width")) or 0.0)
        height = float(((row.get("hosted_view_frame") or {}).get("height")) or 0.0)
        return (
            row.get("mapped") is True
            and row.get("workspace_selected") is True
            and row.get("runtime_surface_ready") is True
            and row.get("hosted_view_in_window") is True
            and row.get("hosted_view_has_superview") is True
            and row.get("hosted_view_visible_in_ui") is True
            and row.get("hosted_view_hidden") is False
            and width > 0.0
            and height > 0.0
        )

    _wait_for(ready, timeout_s=5.0, label=f"mounted selected terminal {surface_id}")
    assert last_row is not None
    return last_row


def _wait_for_present_advance(c: cmux, surface_id: str, baseline_present: int, label: str) -> dict:
    last_stats: dict = {}

    def presented() -> bool:
        nonlocal last_stats
        last_stats = c.render_stats(surface_id)
        return int(last_stats.get("presentCount") or 0) > baseline_present

    try:
        _wait_for(presented, timeout_s=PRESENT_ADVANCE_TIMEOUT_S, cadence_s=0.05, label=label)
    except Exception as exc:
        raise cmuxError(
            "Selected workspace never presented a new terminal frame on its first return.\n"
            f"label={label}\n"
            f"surface_id={surface_id}\n"
            f"baseline_present={baseline_present}\n"
            f"render_stats={last_stats}\n"
            f"surface_health={_surface_health_row(c, surface_id)}"
        ) from exc
    return last_stats


def _select_workspace(c: cmux, workspace_id: str) -> None:
    c.select_workspace(workspace_id)
    _wait_for(lambda: c.current_workspace() == workspace_id, timeout_s=4.0, label=f"workspace {workspace_id} selected")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.25)

        workspace_a = c.new_workspace()
        workspace_b = c.new_workspace()

        _select_workspace(c, workspace_a)
        surface_a = _focused_surface_id(c, workspace_a)
        _wait_for_surface_mount(c, surface_a)
        _wait_for_present_advance(c, surface_a, baseline_present=0, label="warm workspace A")

        _select_workspace(c, workspace_b)
        surface_b = _focused_surface_id(c, workspace_b)
        _wait_for_surface_mount(c, surface_b)
        _wait_for_present_advance(c, surface_b, baseline_present=0, label="warm workspace B")

        for cycle in range(SWITCH_CYCLES):
            baseline_a = int(c.render_stats(surface_a).get("presentCount") or 0)
            _select_workspace(c, workspace_a)
            _wait_for_surface_mount(c, surface_a)
            _wait_for_present_advance(c, surface_a, baseline_a, label=f"switch to workspace A cycle {cycle}")

            baseline_b = int(c.render_stats(surface_b).get("presentCount") or 0)
            _select_workspace(c, workspace_b)
            _wait_for_surface_mount(c, surface_b)
            _wait_for_present_advance(c, surface_b, baseline_b, label=f"switch to workspace B cycle {cycle}")

    print("PASS: existing workspaces render on the first switch back")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
