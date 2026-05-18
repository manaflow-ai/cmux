#!/usr/bin/env python3
"""Regression: surface.send_text must start a background split terminal without selecting it."""

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


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _wait_for_file_text(path: Path, needle: str, timeout_s: float = 8.0) -> str:
    deadline = time.time() + timeout_s
    last_text = ""
    while time.time() < deadline:
        if path.exists():
            last_text = path.read_text(encoding="utf-8", errors="replace")
        if needle in last_text:
            return last_text
        time.sleep(0.1)
    raise cmuxError(f"Timed out waiting for {needle!r} from background split terminal: {last_text!r}")


def _first_terminal_surface_id(payload: dict) -> str:
    surfaces = payload.get("surfaces") or []
    for row in surfaces:
        if row.get("type") == "terminal":
            surface_id = str(row.get("id") or "")
            if surface_id:
                return surface_id
    raise cmuxError(f"surface.list returned no terminal surface: {payload}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        baseline_workspace = c.current_workspace()
        created_workspace = ""
        marker_path = Path(tempfile.gettempdir()) / f"cmux-bg-split-send-{time.time_ns()}.txt"
        try:
            payload = c._call("workspace.create", {}) or {}
            created_workspace = str(payload.get("workspace_id") or "")
            _must(bool(created_workspace), f"workspace.create returned no workspace_id: {payload}")
            _must(
                c.current_workspace() == baseline_workspace,
                "workspace.create should preserve selected workspace",
            )

            surfaces_payload = c._call("surface.list", {"workspace_id": created_workspace}) or {}
            initial_surface = _first_terminal_surface_id(surfaces_payload)

            split_payload = c._call(
                "surface.split",
                {
                    "workspace_id": created_workspace,
                    "surface_id": initial_surface,
                    "direction": "right",
                    "focus": False,
                },
            ) or {}
            split_surface = str(split_payload.get("surface_id") or "")
            _must(bool(split_surface), f"surface.split returned no surface_id: {split_payload}")
            _must(
                c.current_workspace() == baseline_workspace,
                "surface.split in a background workspace should not steal workspace focus",
            )

            token = f"CMUX_BG_SPLIT_SEND_{time.time_ns()}"
            command = (
                "python3 -c "
                + shlex.quote(
                    f"from pathlib import Path; Path({marker_path.as_posix()!r}).write_text({token!r}, encoding='utf-8')"
                )
                + "\n"
            )
            send_payload = c._call(
                "surface.send_text",
                {
                    "workspace_id": created_workspace,
                    "surface_id": split_surface,
                    "text": command,
                },
            ) or {}
            _must(
                str(send_payload.get("surface_id") or "") == split_surface,
                f"surface.send_text returned unexpected surface_id: {send_payload}",
            )

            _wait_for_file_text(marker_path, token)
            _must(
                c.current_workspace() == baseline_workspace,
                "surface.send_text should start the background terminal without selecting its workspace",
            )
        finally:
            try:
                marker_path.unlink()
            except FileNotFoundError:
                pass
            if created_workspace:
                try:
                    c.close_workspace(created_workspace)
                except Exception:
                    logging.exception("Failed to clean up workspace %s", created_workspace)

    print("PASS: background split surface.send_text starts the terminal without focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
