#!/usr/bin/env python3
"""Regression (#26204): workspace.list must drop a workspace that closed outside any socket call."""

from __future__ import annotations

import logging
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


def _listed_ids(c: cmux) -> set[str]:
    payload = c._call("workspace.list", {}) or {}
    return {str(row.get("id") or "") for row in payload.get("workspaces") or []}


def _tree_ids(c: cmux) -> set[str]:
    # all_windows makes this a live read, not the cached snapshot workspace.list serves.
    payload = c._call("system.tree", {"all_windows": True}) or {}
    return {
        str(workspace.get("id") or "")
        for window in payload.get("windows") or []
        for workspace in window.get("workspaces") or []
    }


def _wait_until(predicate, timeout_s: float) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.2)
    return predicate()


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        created_workspace = ""
        try:
            payload = c._call("workspace.create", {"focus": False}) or {}
            created_workspace = str(payload.get("workspace_id") or "")
            _must(bool(created_workspace), f"workspace.create returned no workspace_id: {payload}")
            _must(
                _wait_until(lambda: created_workspace in _listed_ids(c), 10.0),
                "workspace.list never listed the new workspace",
            )

            # Exiting the only shell closes the background workspace on its own,
            # with no socket mutation and no selection or order change. Input
            # typed before the shell is ready is lost, so keep sending until it exits.
            def exited() -> bool:
                if created_workspace not in _tree_ids(c):
                    return True
                try:
                    c._call("surface.send_text", {"workspace_id": created_workspace, "text": "exit\r"})
                except cmuxError as error:
                    if "not_found" in str(error):
                        return True
                    raise
                return _wait_until(lambda: created_workspace not in _tree_ids(c), 2.0)

            _must(_wait_until(exited, 20.0), "the workspace did not close after its shell exited")
            created_workspace_closed = created_workspace
            created_workspace = ""

            _must(
                _wait_until(lambda: created_workspace_closed not in _listed_ids(c), 5.0),
                "workspace.list still lists a workspace that system.tree shows closed",
            )
        finally:
            if created_workspace:
                try:
                    c.close_workspace(created_workspace)
                except Exception:
                    logging.exception("Failed to clean up workspace %s", created_workspace)

    print("PASS: workspace.list drops a workspace that closed in the background")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
