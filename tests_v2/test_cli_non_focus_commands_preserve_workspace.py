#!/usr/bin/env python3
"""Regression: non-focus CLI commands should not switch the selected workspace."""

import glob
import os
import subprocess
import sys
from pathlib import Path
from typing import List

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug.sock")


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    env_cli = os.environ.get("CMUXTERM_CLI")
    if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
        return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"), recursive=True)
    candidates += glob.glob("/tmp/cmux-*/Build/Products/Debug/cmux")
    candidates = [p for p in candidates if os.path.isfile(p) and os.access(p, os.X_OK)]
    if not candidates:
        raise cmuxError("Could not locate cmux CLI binary; set CMUXTERM_CLI")
    candidates.sort(key=lambda p: os.path.getmtime(p), reverse=True)
    return candidates[0]


def _run_cli(cli: str, args: List[str]) -> str:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout.strip()


def _current_workspace(c: cmux) -> str:
    payload = c._call("workspace.current") or {}
    ws_id = str(payload.get("workspace_id") or "")
    if not ws_id:
        raise cmuxError(f"workspace.current returned no workspace_id: {payload}")
    return ws_id


def main() -> int:
    cli = _find_cli_binary()

    with cmux(SOCKET_PATH) as c:
        baseline_ws = _current_workspace(c)

        created = _run_cli(cli, ["new-workspace"])
        _must(created.startswith("OK "), f"new-workspace expected OK response, got: {created}")
        created_ws = created.removeprefix("OK ").strip()
        _must(bool(created_ws), f"new-workspace returned no workspace id: {created}")
        _must(_current_workspace(c) == baseline_ws, "new-workspace should not switch selected workspace")

        _run_cli(cli, ["new-surface", "--workspace", created_ws])
        _must(_current_workspace(c) == baseline_ws, "new-surface --workspace should not switch selected workspace")

        _run_cli(cli, ["new-pane", "--workspace", created_ws, "--direction", "right"])
        _must(_current_workspace(c) == baseline_ws, "new-pane --workspace should not switch selected workspace")

        _run_cli(cli, ["tab-action", "--workspace", created_ws, "--action", "new-terminal-right"])
        _must(_current_workspace(c) == baseline_ws, "tab-action new-terminal-right should not switch selected workspace")

        c.close_workspace(created_ws)

    print("PASS: non-focus CLI commands preserve selected workspace")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
