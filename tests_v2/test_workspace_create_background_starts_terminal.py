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
    raise cmuxError(f"Timed out waiting for {needle!r} in background workspace file: {last_text!r}")


def main() -> int:
    with cmux(SOCKET_PATH) as c:
        baseline_workspace = c.current_workspace()
        created_workspaces: list[str] = []
        marker_path = Path(tempfile.gettempdir()) / f"cmux-bg-start-{int(time.time() * 1000)}.txt"
        layout_marker_path = Path(tempfile.gettempdir()) / f"cmux-bg-layout-start-{int(time.time() * 1000)}.txt"
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
            created_workspaces.append(created_workspace)
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

            layout_token = f"CMUX_BG_LAYOUT_START_{int(time.time() * 1000)}"
            layout_command = (
                "python3 -c " +
                shlex.quote(
                    f"from pathlib import Path; Path({layout_marker_path.as_posix()!r}).write_text({layout_token!r}, encoding='utf-8')"
                )
            )
            layout_payload = c._call(
                "workspace.create",
                {
                    "layout": {
                        "pane": {
                            "surfaces": [
                                {
                                    "type": "terminal",
                                    "command": layout_command,
                                },
                            ],
                        },
                    },
                },
            ) or {}
            layout_workspace = str(layout_payload.get("workspace_id") or "")
            _must(
                bool(layout_workspace),
                f"workspace.create with layout returned no workspace_id: {layout_payload}",
            )
            created_workspaces.append(layout_workspace)
            _must(
                c.current_workspace() == baseline_workspace,
                "background layout workspace.create should preserve selected workspace",
            )

            layout_text = _wait_for_file_text(layout_marker_path, layout_token)
            _must(
                layout_token in layout_text,
                f"Background layout workspace did not run its terminal command: {layout_text!r}",
            )
            _must(
                c.current_workspace() == baseline_workspace,
                "background layout eager load should not switch the selected workspace",
            )
        finally:
            active_exc_type = sys.exc_info()[0]
            close_workspace_exc_info = None
            try:
                marker_path.unlink()
            except FileNotFoundError:
                pass
            try:
                layout_marker_path.unlink()
            except FileNotFoundError:
                pass
            for workspace_id in reversed(created_workspaces):
                try:
                    c.close_workspace(workspace_id)
                except Exception as exc:
                    print(f"cleanup: close_workspace({workspace_id}) failed: {exc!r}", file=sys.stderr)
                    if close_workspace_exc_info is None:
                        close_workspace_exc_info = sys.exc_info()
            if close_workspace_exc_info is not None and active_exc_type is None:
                _, close_workspace_exc, close_workspace_tb = close_workspace_exc_info
                raise close_workspace_exc.with_traceback(close_workspace_tb)

    print("PASS: workspace.create eager background load starts deferred terminal work without focus")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
