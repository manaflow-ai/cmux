#!/usr/bin/env python3
"""Socket-level visible-pane and inactive-tab budget test for panel lifecycle snapshots."""

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _record_by_panel(snapshot: dict, panel_id: str) -> dict:
    for row in list(snapshot.get("records") or []):
        if str(row.get("panelId") or "") == panel_id:
            return dict(row)
    raise cmuxError(f"missing lifecycle record for panel {panel_id}")


def _selected_workspace_with_retry(c: cmux, timeout_s: float = 5.0) -> str:
    start = time.time()
    last_error: Exception | None = None
    while time.time() - start < timeout_s:
        try:
            for _index, workspace_id, _title, selected in c.list_workspaces():
                if selected:
                    return workspace_id
            raise cmuxError("workspace.list returned no selected workspace")
        except cmuxError as e:
            last_error = e
            time.sleep(0.1)
    raise cmuxError(f"timed out waiting for selected workspace: {last_error}")


def _wait_for_records(c: cmux, panel_ids: list[str], timeout_s: float = 5.0) -> dict:
    start = time.time()
    last_snapshot: dict | None = None
    while time.time() - start < timeout_s:
        snapshot = c.panel_lifecycle()
        last_snapshot = snapshot
        try:
            for panel_id in panel_ids:
                _record_by_panel(snapshot, panel_id)
            return snapshot
        except cmuxError:
            time.sleep(0.05)
    raise cmuxError(f"timed out waiting for lifecycle records: {panel_ids} snapshot={last_snapshot}")


def _selected_surface_id(c: cmux, pane_id: str) -> str:
    for _index, surface_id, _title, selected in c.list_pane_surfaces(pane=pane_id):
        if selected:
            return surface_id
    raise cmuxError(f"no selected surface in pane {pane_id}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        budget_workspace = c.new_workspace()
        c.select_workspace(budget_workspace)

        browser_surface = c.new_pane(direction="right", panel_type="browser", url="https://example.com/pane-budget")
        panes = c.list_panes()
        _must(len(panes) >= 2, f"expected at least two panes after browser split, got {panes}")

        terminal_pane_id = next((pane_id for _index, pane_id, _count, focused in panes if focused), panes[0][1])
        selected_terminal = _selected_surface_id(c, terminal_pane_id)
        hidden_terminal = c.new_surface(pane=terminal_pane_id, panel_type="terminal")
        c.focus_surface(selected_terminal)

        snapshot = _wait_for_records(c, [browser_surface, selected_terminal, hidden_terminal])
        selected_workspace = _selected_workspace_with_retry(c)
        current_rows = [
            dict(row)
            for row in list(snapshot.get("records") or [])
            if str(row.get("workspaceId") or "") == selected_workspace
        ]

        active_count = sum(1 for row in current_rows if bool(row.get("activeWindowMembership")))
        visible_pane_count = len(c.list_panes())
        _must(
            active_count == visible_pane_count,
            f"active-window heavy-view count mismatch: active={active_count} panes={visible_pane_count} rows={current_rows}",
        )

        hidden_terminal_record = _record_by_panel(snapshot, hidden_terminal)
        _must(
            hidden_terminal_record.get("activeWindowMembership") is False,
            f"inactive tab still visible in active window: {hidden_terminal_record}",
        )
        _must(
            hidden_terminal_record.get("residency") in {"parkedOffscreen", "detachedRetained"},
            f"inactive tab not parked/detached in steady state: {hidden_terminal_record}",
        )

    print("PASS: visible pane count matches active-window heavy-view budget and inactive tabs are parked/detached")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
