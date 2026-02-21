#!/usr/bin/env python3
"""Regression: explicit `rename-tab` CLI command parity with tab.action rename."""

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


def _run_cli(cli: str, args: List[str], env: Optional[Dict[str, str]] = None) -> str:
    merged_env = dict(os.environ)
    merged_env.pop("CMUX_WORKSPACE_ID", None)
    merged_env.pop("CMUX_SURFACE_ID", None)
    merged_env.pop("CMUX_TAB_ID", None)
    if env:
        merged_env.update(env)

    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=merged_env)
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout.strip()


def _surface_title(c: cmux, workspace_id: str, surface_id: str) -> str:
    payload = c._call("surface.list", {"workspace_id": workspace_id}) or {}
    for row in payload.get("surfaces") or []:
        if str(row.get("id") or "") == surface_id:
            return str(row.get("title") or "")
    raise cmuxError(f"surface.list missing surface {surface_id} in workspace {workspace_id}: {payload}")


def main() -> int:
    cli = _find_cli_binary()
    stamp = int(time.time() * 1000)

    with cmux(SOCKET_PATH) as c:
        caps = c.capabilities() or {}
        methods = set(caps.get("methods") or [])
        _must("tab.action" in methods, f"Missing tab.action in capabilities: {sorted(methods)[:40]}")

        created = c._call("workspace.create") or {}
        ws_id = str(created.get("workspace_id") or "")
        _must(bool(ws_id), f"workspace.create returned no workspace_id: {created}")

        c._call("workspace.select", {"workspace_id": ws_id})
        current = c._call("surface.current", {"workspace_id": ws_id}) or {}
        surface_id = str(current.get("surface_id") or "")
        _must(bool(surface_id), f"surface.current returned no surface_id: {current}")

        socket_title = f"socket rename {stamp}"
        c._call(
            "tab.action",
            {
                "workspace_id": ws_id,
                "surface_id": surface_id,
                "action": "rename",
                "title": socket_title,
            },
        )
        _must(_surface_title(c, ws_id, surface_id) == socket_title, "tab.action rename did not update tab title")

        cli_title = f"cli rename {stamp}"
        _run_cli(cli, ["rename-tab", "--workspace", ws_id, "--tab", surface_id, cli_title])
        _must(_surface_title(c, ws_id, surface_id) == cli_title, "rename-tab --tab did not update tab title")

        env_title = f"env rename {stamp}"
        _run_cli(
            cli,
            ["rename-tab", env_title],
            env={
                "CMUX_WORKSPACE_ID": ws_id,
                "CMUX_TAB_ID": surface_id,
            },
        )
        _must(_surface_title(c, ws_id, surface_id) == env_title, "rename-tab via CMUX_TAB_ID did not update tab title")

        invalid = subprocess.run(
            [cli, "--socket", SOCKET_PATH, "rename-tab", "--workspace", ws_id],
            capture_output=True,
            text=True,
            check=False,
            env={k: v for k, v in os.environ.items() if k not in {"CMUX_WORKSPACE_ID", "CMUX_SURFACE_ID", "CMUX_TAB_ID"}},
        )
        invalid_output = f"{invalid.stdout}\n{invalid.stderr}"
        _must(invalid.returncode != 0, "Expected rename-tab without title to fail")
        _must("rename-tab requires a title" in invalid_output, f"Unexpected rename-tab error: {invalid_output!r}")

        c.close_workspace(ws_id)

    print("PASS: rename-tab CLI parity works with explicit and env-derived targets")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
