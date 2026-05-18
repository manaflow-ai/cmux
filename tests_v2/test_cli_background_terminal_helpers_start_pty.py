#!/usr/bin/env python3
"""Regression: CLI-created background terminal helpers should start a PTY."""

from __future__ import annotations

import glob
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import List, Tuple

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


class cmuxSkip(Exception):
    pass


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


def _run_cli(cli: str, args: List[str], check: bool = True) -> Tuple[int, str]:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    cmd = [cli, "--socket", SOCKET_PATH] + args
    proc = subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)
    merged = f"{proc.stdout}\n{proc.stderr}".strip()
    if check and proc.returncode != 0:
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.returncode, proc.stdout.strip() if proc.returncode == 0 else merged


def _extract_ref(output: str, kind: str) -> str:
    match = re.search(rf"\b{kind}:\d+\b", output)
    if not match:
        raise cmuxError(f"Could not find {kind} ref in CLI output: {output!r}")
    return match.group(0)


def _wait_for_read_screen(cli: str, workspace_ref: str, surface_ref: str, token: str) -> str:
    deadline = time.time() + 8.0
    last_output = ""
    while time.time() < deadline:
        code, output = _run_cli(
            cli,
            [
                "read-screen",
                "--workspace",
                workspace_ref,
                "--surface",
                surface_ref,
                "--scrollback",
                "--lines",
                "80",
            ],
            check=False,
        )
        last_output = output
        if code == 0 and token in output:
            return output
        time.sleep(0.1)
    raise cmuxError(f"read-screen never observed {token!r} for {surface_ref}: {last_output!r}")


def _exercise_helper(cli: str, workspace_ref: str, surface_ref: str, label: str) -> None:
    token = f"CMUX_HELPER_PTY_{label}_{int(time.time() * 1000)}"
    _run_cli(
        cli,
        [
            "send",
            "--workspace",
            workspace_ref,
            "--surface",
            surface_ref,
            "--",
            f"echo {token}\\n",
        ],
    )
    text = _wait_for_read_screen(cli, workspace_ref, surface_ref, token)
    _must(token in text, f"helper terminal output missing {token!r}: {text!r}")


def _create_background_workspace(cli: str) -> str:
    _, output = _run_cli(cli, ["new-workspace", "--focus", "false"])
    workspace_ref = output.removeprefix("OK ").strip()
    _must(bool(workspace_ref), f"new-workspace returned no workspace ref: {output!r}")
    return workspace_ref


def _find_unhosted_background_workspace(c: cmux, cli: str, baseline_ws: str) -> Tuple[str, List[str]]:
    created_workspaces: List[str] = []
    try:
        for _ in range(16):
            workspace_ref = _create_background_workspace(cli)
            created_workspaces.append(workspace_ref)
            _run_cli(cli, ["select-workspace", "--workspace", baseline_ws])

            health = c._call("surface.health", {"workspace_id": workspace_ref}) or {}
            surfaces = health.get("surfaces") or []
            if any(row.get("type") == "terminal" and row.get("in_window") is False for row in surfaces):
                created_workspaces.remove(workspace_ref)
                return workspace_ref, created_workspaces

        raise cmuxSkip("could not create an unhosted background workspace for helper terminal regression")
    except Exception:
        for workspace_ref in created_workspaces:
            try:
                c.close_workspace(workspace_ref)
            except Exception:
                pass
        raise


def main() -> int:
    cli = _find_cli_binary()

    with cmux(SOCKET_PATH) as c:
        baseline = c._call("workspace.current") or {}
        baseline_ws = str(baseline.get("workspace_ref") or baseline.get("workspace_id") or "")
        _must(bool(baseline_ws), f"workspace.current returned no workspace_id: {baseline}")

        workspace_ref = ""
        cleanup_workspaces: List[str] = []

        try:
            try:
                workspace_ref, cleanup_workspaces = _find_unhosted_background_workspace(c, cli, baseline_ws)
            except cmuxSkip as exc:
                print(f"SKIP: {exc}")
                return 0
            panes = c._call("pane.list", {"workspace_id": workspace_ref}) or {}
            pane_rows = panes.get("panes") or []
            _must(bool(pane_rows), f"pane.list returned no panes for background workspace: {panes}")
            pane_ref = str(pane_rows[0].get("ref") or pane_rows[0].get("id") or "")
            _must(bool(pane_ref), f"pane.list returned pane without ref/id: {panes}")

            _, surface_output = _run_cli(
                cli,
                [
                    "new-surface",
                    "--workspace",
                    workspace_ref,
                    "--pane",
                    pane_ref,
                    "--type",
                    "terminal",
                    "--focus",
                    "false",
                ],
            )
            helper_surface_ref = _extract_ref(surface_output, "surface")
            _exercise_helper(cli, workspace_ref, helper_surface_ref, "surface")

            _, pane_output = _run_cli(
                cli,
                [
                    "new-pane",
                    "--workspace",
                    workspace_ref,
                    "--type",
                    "terminal",
                    "--direction",
                    "right",
                    "--focus",
                    "false",
                ],
            )
            helper_pane_surface_ref = _extract_ref(pane_output, "surface")
            _exercise_helper(cli, workspace_ref, helper_pane_surface_ref, "pane")

            current = c._call("workspace.current") or {}
            _must(
                str(current.get("workspace_ref") or current.get("workspace_id") or "") == baseline_ws,
                f"helper creation should not switch selected workspace: {current}",
            )
        finally:
            for cleanup_workspace in cleanup_workspaces:
                try:
                    c.close_workspace(cleanup_workspace)
                except Exception:
                    pass
            try:
                if workspace_ref:
                    c.close_workspace(workspace_ref)
            except Exception:
                pass

    print("PASS: CLI-created background terminal helpers start a PTY")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
