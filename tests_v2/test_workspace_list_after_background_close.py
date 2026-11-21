#!/usr/bin/env python3
"""Regression (#26204): workspace.list must drop a workspace that closed outside any socket call."""

from __future__ import annotations

import logging
import os
import shlex
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")

Rows = list[tuple[str, bool]]


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _listed_rows(c: cmux) -> Rows:
    # Served from the published read snapshot; reading it never refreshes that snapshot.
    payload = c._call("workspace.list", {}) or {}
    return [(str(row.get("id") or ""), bool(row.get("selected"))) for row in payload.get("workspaces") or []]


def _wait_until(predicate, timeout_s: float) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.2)
    return predicate()


def _workspace_exists(c: cmux, workspace_id: str) -> bool:
    try:
        c._call("surface.read_text", {"workspace_id": workspace_id})
    except cmuxError as error:
        if "not_found" in str(error):
            return False
        raise
    return True


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="cmux-background-close-") as directory, cmux(SOCKET_PATH) as c:
        exit_signal = Path(directory) / "exit.fifo"
        os.mkfifo(exit_signal, 0o600)
        # Keep both ends open so releasing the shell never blocks, even if it
        # has not reached its read yet. The unread signal remains buffered.
        signal_fd = os.open(exit_signal, os.O_RDWR | os.O_NONBLOCK)
        created_workspace = ""
        try:
            # Hold the shell until the initial snapshot is recorded, then let
            # it exit without a socket mutation that could refresh the snapshot.
            payload = c._call(
                "workspace.create",
                {"focus": False, "initial_command": f"read -r cmux_close_signal < {shlex.quote(str(exit_signal))}; exit"},
            ) or {}
            created_workspace = str(payload.get("workspace_id") or "")
            _must(bool(created_workspace), f"workspace.create returned no workspace_id: {payload}")

            # workspace.create schedules a snapshot refresh; once it lands, the
            # list is the live state from before the shell exits.
            _must(
                _wait_until(lambda: created_workspace in dict(_listed_rows(c)), 2.0),
                f"workspace.list never listed the new workspace: {_listed_rows(c)}",
            )
            before = _listed_rows(c)
            # A background close: not selected and not the window's last
            # workspace, so the selection and the window stay as they are.
            _must(
                dict(before)[created_workspace] is False,
                "workspace.create with focus=false selected the new workspace",
            )
            _must(len(before) > 1, f"the new workspace is the only one, so closing it closes the window: {before}")
            expected = [row for row in before if row[0] != created_workspace]

            os.write(signal_fd, b"close\n")
            if not _wait_until(lambda: _listed_rows(c) == expected, 20.0):
                listed = _listed_rows(c)
                # This live read publishes a fresh snapshot, so it only runs after the wait.
                _must(
                    not _workspace_exists(c, created_workspace),
                    "the workspace did not close after its shell exited",
                )
                created_workspace = ""
                raise cmuxError(f"workspace.list still lists the closed workspace: {listed}, expected {expected}")
            created_workspace = ""
        finally:
            if created_workspace:
                try:
                    c.close_workspace(created_workspace)
                except Exception:
                    logging.exception("Failed to clean up workspace %s", created_workspace)
            os.close(signal_fd)

    print("PASS: workspace.list drops a workspace that closed in the background")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
