#!/usr/bin/env python3
"""Socket-level active-window membership budget test for panel lifecycle snapshots."""

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


def _wait_for_workspace_records(c: cmux, workspace_id: str, timeout_s: float = 5.0) -> dict:
    start = time.time()
    last_snapshot: dict | None = None
    while time.time() - start < timeout_s:
        snapshot = c.panel_lifecycle()
        last_snapshot = snapshot
        records = [
            dict(row)
            for row in list(snapshot.get("records") or [])
            if str(row.get("workspaceId") or "") == workspace_id
        ]
        if records:
            return snapshot
        time.sleep(0.05)
    raise cmuxError(
        f"timed out waiting for lifecycle records in workspace {workspace_id}: snapshot={last_snapshot}"
    )


def _wait_for_selected_workspace(c: cmux, workspace_id: str, timeout_s: float = 5.0) -> None:
    start = time.time()
    last_workspace: str | None = None
    while time.time() - start < timeout_s:
        last_workspace = c.current_workspace()
        if last_workspace == workspace_id:
            return
        time.sleep(0.05)
    raise cmuxError(
        f"timed out waiting for selected workspace {workspace_id}, current={last_workspace}"
    )


def _new_workspace(c: cmux, timeout_s: float = 60.0) -> str:
    res = c._call("workspace.create", {}, timeout_s=timeout_s) or {}
    wsid = res.get("workspace_id")
    if not wsid:
        raise cmuxError(f"workspace.create returned no workspace_id: {res}")
    return str(wsid)


def _select_workspace(c: cmux, workspace_id: str, timeout_s: float = 60.0) -> None:
    c._call("workspace.select", {"workspace_id": str(workspace_id)}, timeout_s=timeout_s)


def _wait_for_steady_hidden_workspace(c: cmux, workspace_id: str, timeout_s: float = 15.0) -> dict:
    start = time.time()
    last_snapshot: dict | None = None
    while time.time() - start < timeout_s:
        snapshot = _wait_for_workspace_records(c, workspace_id, timeout_s=timeout_s)
        last_snapshot = snapshot
        records = [
            dict(row)
            for row in list(snapshot.get("records") or [])
            if str(row.get("workspaceId") or "") == workspace_id
        ]
        if all(not bool(record.get("retiringWorkspace")) for record in records):
            return snapshot
        time.sleep(0.05)
    raise cmuxError(
        f"timed out waiting for hidden workspace {workspace_id} to leave handoff: snapshot={last_snapshot}"
    )


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        original_workspace = c.current_workspace()
        hidden_workspace = _new_workspace(c)
        _select_workspace(c, hidden_workspace)
        _wait_for_selected_workspace(c, hidden_workspace, timeout_s=15.0)
        _select_workspace(c, original_workspace)
        _wait_for_selected_workspace(c, original_workspace, timeout_s=15.0)

        snapshot = _wait_for_steady_hidden_workspace(c, hidden_workspace)
        counts = dict(snapshot.get("counts") or {})
        hidden_records = [
            dict(row)
            for row in list(snapshot.get("records") or [])
            if str(row.get("workspaceId") or "") == hidden_workspace
        ]

        _must(hidden_records, f"missing hidden workspace records for {hidden_workspace}")
        _must(
            all(record.get("selectedWorkspace") is False for record in hidden_records),
            f"hidden workspace still selected: {hidden_records}",
        )
        _must(
            all(record.get("retiringWorkspace") is False for record in hidden_records),
            f"hidden workspace still retiring: {hidden_records}",
        )
        _must(
            all(record.get("activeWindowMembership") is False for record in hidden_records),
            f"hidden workspace still has active-window membership: {hidden_records}",
        )
        _must(
            all(record.get("responderEligible") is False for record in hidden_records),
            f"hidden workspace still has responder-eligible panels: {hidden_records}",
        )
        _must(
            all(record.get("accessibilityParticipation") is False for record in hidden_records),
            f"hidden workspace still has accessibility-participating panels: {hidden_records}",
        )

        active_count = sum(
            1 for row in list(snapshot.get("records") or []) if bool(row.get("activeWindowMembership"))
        )
        _must(
            counts.get("visibleInActiveWindowCount") == active_count,
            f"visibleInActiveWindowCount mismatch: counts={counts} computed={active_count}",
        )

    print("PASS: hidden workspace panels do not contribute active-window membership budget")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
