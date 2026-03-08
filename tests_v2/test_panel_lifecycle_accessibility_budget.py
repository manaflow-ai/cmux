#!/usr/bin/env python3
"""Socket-level accessibility budget test for panel lifecycle snapshots."""

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

def _wait_for_workspace_records(socket_path: str, workspace_id: str, timeout_s: float = 5.0) -> dict:
    start = time.time()
    last_snapshot: dict | None = None
    while time.time() - start < timeout_s:
        with cmux(socket_path) as c:
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
    raise cmuxError(f"timed out waiting for workspace records: {workspace_id} snapshot={last_snapshot}")


def _selected_workspace_with_retry(socket_path: str, timeout_s: float = 5.0) -> str:
    start = time.time()
    last_error: Exception | None = None
    while time.time() - start < timeout_s:
        try:
            with cmux(socket_path) as c:
                snapshot = c.panel_lifecycle()
            for row in list(snapshot.get("records") or []):
                if bool(row.get("selectedWorkspace")):
                    workspace_id = str(row.get("workspaceId") or "")
                    if workspace_id:
                        return workspace_id
            raise cmuxError("panel_lifecycle returned no selected workspace")
        except cmuxError as e:
            last_error = e
            time.sleep(0.1)
    raise cmuxError(f"timed out waiting for selected workspace from lifecycle snapshot: {last_error}")


def _new_workspace_with_retry(socket_path: str, timeout_s: float = 5.0) -> str:
    start = time.time()
    last_error: Exception | None = None
    while time.time() - start < timeout_s:
        try:
            with cmux(socket_path) as c:
                return c.new_workspace()
        except cmuxError as e:
            last_error = e
            time.sleep(0.1)
    raise cmuxError(f"timed out creating workspace: {last_error}")

def _select_workspace_with_retry(socket_path: str, workspace: str, timeout_s: float = 5.0) -> None:
    start = time.time()
    last_error: Exception | None = None
    while time.time() - start < timeout_s:
        try:
            with cmux(socket_path) as c:
                c.select_workspace(workspace)
            return
        except cmuxError as e:
            last_error = e
            time.sleep(0.1)
    raise cmuxError(f"timed out selecting workspace: {last_error}")


def main() -> int:
    original_workspace = _selected_workspace_with_retry(SOCKET_PATH)
    visible_snapshot = _wait_for_workspace_records(SOCKET_PATH, original_workspace)
    visible_records = [
        dict(row)
        for row in list(visible_snapshot.get("records") or [])
        if str(row.get("workspaceId") or "") == original_workspace and bool(row.get("selectedWorkspace"))
    ]
    _must(visible_records, f"no visible records for selected workspace: {original_workspace}")
    visible_record = next(
        (row for row in visible_records if bool(row.get("accessibilityParticipation"))),
        visible_records[0],
    )

    hidden_workspace = _new_workspace_with_retry(SOCKET_PATH)
    _select_workspace_with_retry(SOCKET_PATH, original_workspace)

    snapshot = _wait_for_workspace_records(SOCKET_PATH, hidden_workspace)
    counts = dict(snapshot.get("counts") or {})
    hidden_records = [
        dict(row)
        for row in list(snapshot.get("records") or [])
        if str(row.get("workspaceId") or "") == hidden_workspace
    ]
    _must(hidden_records, f"no hidden records for workspace: {hidden_workspace}")
    hidden_record = hidden_records[0]

    _must(
        visible_record.get("accessibilityParticipation") is True,
        f"visible selected panel not in accessibility budget: {visible_record}",
    )
    _must(
        hidden_record.get("accessibilityParticipation") is False,
        f"hidden workspace still contributes accessibility budget: {hidden_record}",
    )

    accessibility_count = sum(
        1 for row in list(snapshot.get("records") or []) if bool(row.get("accessibilityParticipation"))
    )
    _must(
        counts.get("accessibilityParticipationCount") == accessibility_count,
        f"accessibilityParticipationCount mismatch: counts={counts} computed={accessibility_count}",
    )

    print("PASS: hidden workspaces do not contribute accessibility budget")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
