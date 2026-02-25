#!/usr/bin/env python3
"""Regression: tmux rename-window parity via workspace.rename + CLI aliases."""

import glob
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional

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


def _run_cli(cli: str, args: List[str], env_overrides: Optional[Dict[str, str]] = None) -> str:
    env = dict(os.environ)
    # Keep this test deterministic when running from inside another cmux shell.
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    if env_overrides:
        env.update(env_overrides)
    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout


def _workspace_title(c: cmux, workspace_id: str) -> str:
    payload = c._call("workspace.list") or {}
    for row in payload.get("workspaces") or []:
        if str(row.get("id") or "") == workspace_id:
            return str(row.get("title") or "")
    raise cmuxError(f"workspace.list missing workspace {workspace_id}: {payload}")


def main() -> int:
    cli = _find_cli_binary()
    stamp = int(time.time() * 1000)

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        _must("workspace.rename" in methods, f"Missing workspace.rename in capabilities: {sorted(methods)[:30]}")

        created = c._call("workspace.create") or {}
        ws_id = str(created.get("workspace_id") or "")
        _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")
        c._call("workspace.select", {"workspace_id": ws_id})

        api_title = f"tmux-api-{stamp}"
        c.rename_workspace(api_title, workspace=ws_id)
        _must(_workspace_title(c, ws_id) == api_title, "workspace.rename API did not update workspace title")

        cli_title = f"tmux cli {stamp}"
        _run_cli(cli, ["rename-workspace", "--workspace", ws_id, cli_title])
        _must(_workspace_title(c, ws_id) == cli_title, "cmux rename-workspace did not update workspace title")

        alias_title = f"tmux alias {stamp}"
        _run_cli(cli, ["rename-window", "--workspace", ws_id, alias_title])
        _must(_workspace_title(c, ws_id) == alias_title, "cmux rename-window did not update workspace title")

        current_title = f"tmux current {stamp}"
        _run_cli(cli, ["rename-window", current_title])
        _must(
            _workspace_title(c, ws_id) == current_title,
            "cmux rename-window without --workspace should target current workspace",
        )

        env_title = f"tmux env {stamp}"
        _run_cli(
            cli,
            ["rename-workspace", env_title],
            env_overrides={"CMUX_WORKSPACE_ID": ws_id},
        )
        _must(
            _workspace_title(c, ws_id) == env_title,
            "cmux rename-workspace should default to CMUX_WORKSPACE_ID",
        )

        env = dict(os.environ)
        env.pop("CMUX_WORKSPACE_ID", None)
        env.pop("CMUX_SURFACE_ID", None)
        invalid = subprocess.run(
            [cli, "--socket", SOCKET_PATH, "rename-window", "--workspace", ws_id],
            capture_output=True,
            text=True,
            check=False,
            env=env,
        )
        invalid_output = f"{invalid.stdout}\n{invalid.stderr}"
        _must(invalid.returncode != 0, "Expected rename-window without title to fail")
        _must(
            "rename-window requires a title" in invalid_output,
            f"Unexpected error for rename-window without title: {invalid_output!r}",
        )

    print("PASS: tmux rename-window parity works via workspace.rename and CLI aliases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
