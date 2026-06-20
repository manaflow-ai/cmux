#!/usr/bin/env python3
"""Regression: pane.swap and pane.break should not steal visible focus."""

from __future__ import annotations

import os
import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for(pred, msg: str, timeout_s: float = 5.0, step_s: float = 0.05):
    """Poll the real socket state until pred() is truthy; return its value.

    Deadline-bounded so it returns the instant the predicate holds instead of
    sleeping a fixed interval and hoping the async work finished. Fails only at
    a generous deadline, which doubles as the "did not hang" guard.
    """
    deadline = time.time() + timeout_s
    while True:
        value = pred()
        if value:
            return value
        if time.time() >= deadline:
            raise cmuxError(f"Timed out waiting for condition: {msg}")
        time.sleep(step_s)


def _panes(client: cmux, workspace_id: str) -> list:
    payload = client._call("pane.list", {"workspace_id": workspace_id}) or {}
    return payload.get("panes") or []


def _surface_ids_by_pane(client: cmux, workspace_id: str) -> dict:
    return {
        str(row.get("id") or ""): tuple(row.get("surface_ids") or [])
        for row in _panes(client, workspace_id)
    }


def _focused_pane_id(client: cmux, workspace_id: str) -> str:
    for row in _panes(client, workspace_id):
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
            _wait_for(
                lambda: client.current_workspace() == workspace_id,
                "new workspace becomes the selected workspace",
            )

            _ = client.new_split("right")
            panes = _wait_for(
                lambda: (p := _panes(client, workspace_id)) if len(p) == 2 else None,
                "two panes appear after split",
            )

            focused_row = next((row for row in panes if bool(row.get("focused"))), None)
            _must(focused_row is not None, f"expected focused pane after split: {panes}")
            focused_pane_id = str(focused_row.get("id") or "")
            other_row = next((row for row in panes if str(row.get("id") or "") != focused_pane_id), None)
            _must(other_row is not None, f"expected non-focused pane after split: {panes}")
            other_pane_id = str(other_row.get("id") or "")

            client.focus_pane(other_pane_id)
            _wait_for(
                lambda: _focused_pane_id(client, workspace_id) == other_pane_id,
                "explicit pane focus lands on the other pane before pane.swap",
            )

            # Snapshot the surface layout so we can wait for the swap to actually
            # take effect (its positive completion signal is the two panes
            # exchanging their surface ids), then assert the focus invariant on
            # the settled state instead of after a fixed sleep.
            before_swap = _surface_ids_by_pane(client, workspace_id)
            client._call("pane.swap", {"pane_id": other_pane_id, "target_pane_id": focused_pane_id})
            _wait_for(
                lambda: _surface_ids_by_pane(client, workspace_id) != before_swap,
                "pane.swap exchanges the panes' surfaces",
            )
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

            # The break's positive completion signal is the broken pane leaving
            # the original workspace (its pane count drops back to one). Wait for
            # that settled state, then assert the selected workspace invariant.
            _wait_for(
                lambda: len(_panes(client, workspace_id)) == 1,
                "broken pane leaves the original workspace",
            )
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
