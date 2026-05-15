#!/usr/bin/env python3
"""
Regression test: a Cmd+N-created workspace must present its first terminal frame
without requiring a tab/workspace switch.

Issue 3068 reports that the newly selected workspace can stay visibly mounted but
blank until another selection change re-triggers portal visibility updates. This
test drives the real shortcut path, creates a burst of workspaces to amplify the
attach timing churn, and then verifies the final selected terminal presents at
least one frame without any follow-up input.
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
WORKSPACE_BURST = 10
FIRST_PRESENT_TIMEOUT_S = float(os.environ.get("CMUX_FIRST_PRESENT_TIMEOUT_S", "5.0"))


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


def _workspace_ids(c: cmux) -> list[str]:
    return [workspace_id for _index, workspace_id, _title, _selected in c.list_workspaces()]


def _selected_workspace_id(c: cmux) -> str:
    return c.current_workspace()


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


def _wait_for_first_present(c: cmux, surface_id: str) -> dict:
    last_stats: dict = {}

    def presented() -> bool:
        nonlocal last_stats
        last_stats = c.render_stats(surface_id)
        return int(last_stats.get("presentCount") or 0) > 0

    try:
        _wait_for(
            presented,
            timeout_s=FIRST_PRESENT_TIMEOUT_S,
            cadence_s=0.05,
            label=f"first presented frame for {surface_id}",
        )
    except Exception as exc:
        raise cmuxError(
            "Newly selected workspace never presented its first terminal frame before any "
            "manual tab switch.\n"
            f"surface_id={surface_id}\n"
            f"render_stats={last_stats}\n"
            f"surface_health={_surface_health_row(c, surface_id)}"
        ) from exc
    return last_stats


def _create_workspace_via_shortcut(c: cmux, expected_count: int, previous_workspace_id: str) -> str:
    c.simulate_shortcut("cmd+n")
    _wait_for(
        lambda: len(_workspace_ids(c)) >= expected_count,
        timeout_s=4.0,
        label=f"workspace count >= {expected_count} after Cmd+N",
    )
    _wait_for(
        lambda: _selected_workspace_id(c) != previous_workspace_id,
        timeout_s=4.0,
        label="workspace selection after Cmd+N",
    )
    return _selected_workspace_id(c)


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        c.activate_app()
        time.sleep(0.25)

        starting_workspaces = _workspace_ids(c)
        if not starting_workspaces:
            raise cmuxError("Expected at least one workspace before Cmd+N burst")

        selected_workspace_id = _selected_workspace_id(c)
        expected_count = len(starting_workspaces)

        for _ in range(WORKSPACE_BURST):
            expected_count += 1
            selected_workspace_id = _create_workspace_via_shortcut(
                c,
                expected_count=expected_count,
                previous_workspace_id=selected_workspace_id,
            )

        surface_id = _focused_surface_id(c, selected_workspace_id)
        _wait_for_surface_mount(c, surface_id)
        _wait_for_first_present(c, surface_id)

    print("PASS: Cmd+N-created workspace presents its first terminal frame without a tab switch")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
