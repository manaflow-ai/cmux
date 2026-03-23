#!/usr/bin/env python3
"""Regression: pane.swap and pane.break should not steal visible focus."""

from __future__ import annotations

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


def _focused_pane_id(client: cmux, workspace_id: str) -> str:
    payload = client._call("pane.list", {"workspace_id": workspace_id}) or {}
    for row in payload.get("panes") or []:
        if bool(row.get("focused")):
            return str(row.get("id") or "")
    return ""


def main() -> int:
    created_workspaces: list[str] = []

    try:
        with cmux(SOCKET_PATH) as client:
            workspace_id = client.new_workspace()
            created_workspaces.append(workspace_id)
            client.select_workspace(workspace_id)
            time.sleep(0.2)

            _ = client.new_split("right")
            time.sleep(0.2)

            panes_payload = client._call("pane.list", {"workspace_id": workspace_id}) or {}
            panes = panes_payload.get("panes") or []
            _must(len(panes) == 2, f"expected two panes after split: {panes_payload}")

            focused_row = next((row for row in panes if bool(row.get("focused"))), None)
            _must(focused_row is not None, f"expected focused pane after split: {panes_payload}")
            focused_pane_id = str(focused_row.get("id") or "")
            other_row = next((row for row in panes if str(row.get("id") or "") != focused_pane_id), None)
            _must(other_row is not None, f"expected non-focused pane after split: {panes_payload}")
            other_pane_id = str(other_row.get("id") or "")

            client.focus_pane(other_pane_id)
            time.sleep(0.2)
            _must(
                _focused_pane_id(client, workspace_id) == other_pane_id,
                "expected explicit pane focus before pane.swap regression check",
            )

            client._call("pane.swap", {"pane_id": other_pane_id, "target_pane_id": focused_pane_id})
            time.sleep(0.2)
            _must(
                _focused_pane_id(client, workspace_id) == other_pane_id,
                "pane.swap should preserve the currently focused pane when invoked over the socket",
            )
            _must(
                client.current_workspace() == workspace_id,
                "pane.swap should not change the selected workspace",
            )

            broken_payload = client._call("pane.break", {"pane_id": other_pane_id}) or {}
            broken_workspace_id = str(broken_payload.get("workspace_id") or "")
            _must(bool(broken_workspace_id), f"pane.break returned no workspace_id: {broken_payload}")
            created_workspaces.append(broken_workspace_id)
            time.sleep(0.2)

            _must(
                client.current_workspace() == workspace_id,
                "pane.break should preserve the selected workspace when invoked over the socket",
            )
    finally:
        with cmux(SOCKET_PATH) as cleanup_client:
            for workspace_id in reversed(created_workspaces):
                try:
                    cleanup_client.close_workspace(workspace_id)
                except Exception:
                    pass

    print("PASS: pane.swap and pane.break preserve visible focus for socket callers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
