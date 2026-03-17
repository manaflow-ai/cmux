#!/usr/bin/env python3
"""Regression: background workspace.create should start its initial terminal before selection."""

from __future__ import annotations

import os
import shlex
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


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
    raise cmuxError(f"Timed out waiting for {needle!r} in background workspace file: {last_text!r}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        baseline_workspace = c.current_workspace()
        created_workspace = ""
        marker_path = Path(tempfile.gettempdir()) / f"cmux-bg-start-{int(time.time() * 1000)}.txt"
        try:
            token = f"CMUX_BG_START_{int(time.time() * 1000)}"
            initial_command = (
                "python3 -c " +
                shlex.quote(
                    f"from pathlib import Path; Path({marker_path.as_posix()!r}).write_text({token!r}, encoding='utf-8')"
                )
            )
            payload = c._call(
                "workspace.create",
                {"initial_command": initial_command},
            ) or {}
            created_workspace = str(payload.get("workspace_id") or "")
            _must(bool(created_workspace), f"workspace.create returned no workspace_id: {payload}")
            _must(
                c.current_workspace() == baseline_workspace,
                "workspace.create should preserve selected workspace",
            )

            text = _wait_for_file_text(marker_path, token)
            _must(token in text, f"Background workspace did not run its initial command: {text!r}")
            _must(
                c.current_workspace() == baseline_workspace,
                "background eager load should not switch the selected workspace",
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
                    pass

    print("PASS: workspace.create eager background load starts the initial terminal without focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
