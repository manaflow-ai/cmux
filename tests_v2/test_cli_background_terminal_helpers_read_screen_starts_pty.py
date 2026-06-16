#!/usr/bin/env python3
"""Regression: read-screen should materialize cold background helper terminals."""

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


def _run_cli(cli: str, args: List[str], check: bool = True, timeout: float = 10.0) -> Tuple[int, str]:
    env = dict(os.environ)
    env.pop("CMUX_WORKSPACE_ID", None)
    env.pop("CMUX_SURFACE_ID", None)
    env.pop("CMUX_TAB_ID", None)

    cmd = [cli, "--socket", SOCKET_PATH] + args
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=timeout,
        )
    except subprocess.TimeoutExpired as exc:
        merged = f"{exc.stdout or ''}\n{exc.stderr or ''}".strip()
        raise cmuxError(f"CLI timed out after {timeout:.1f}s ({' '.join(cmd)}): {merged}") from exc
    merged = f"{proc.stdout}\n{proc.stderr}".strip()
    if check and proc.returncode != 0:
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.returncode, proc.stdout.strip() if proc.returncode == 0 else merged


def _extract_ref(output: str, kind: str) -> str:
    match = re.search(rf"\b{kind}:\d+\b", output)
    if not match:
        raise cmuxError(f"Could not find {kind} ref in CLI output: {output!r}")
    return match.group(0)


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

            health = c._call("surface.health", {"workspace_id": workspace_ref}) or {}
            surfaces = health.get("surfaces") or []
            if any(row.get("type") == "terminal" and row.get("in_window") is False for row in surfaces):
                created_workspaces.remove(workspace_ref)
                return workspace_ref, created_workspaces

        raise cmuxSkip("could not create an unhosted background workspace for read-screen regression")
    except Exception:
        for workspace_ref in created_workspaces:
            try:
                c.close_workspace(workspace_ref)
            except Exception:
                pass
        raise


def _assert_cli_read_materializes(cli: str, args: List[str], surface_ref: str, label: str) -> None:
    code, output = _run_cli(
        cli,
        args,
        check=False,
        timeout=10.0,
    )
    _must(code == 0, f"{label}: read failed for {surface_ref}: {output!r}")
    _must(
        "Terminal surface not found" not in output and "Failed to read terminal text" not in output,
        f"{label}: read did not materialize {surface_ref}: {output!r}",
    )


def _new_terminal_surface(cli: str, workspace_ref: str, pane_ref: str) -> str:
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
    return _extract_ref(surface_output, "surface")


def _surface_in_window(c: cmux, workspace_ref: str, surface_ref: str) -> bool:
    health = c._call("surface.health", {"workspace_id": workspace_ref}) or {}
    for row in health.get("surfaces") or []:
        if surface_ref in (str(row.get("ref") or ""), str(row.get("id") or "")):
            return bool(row.get("in_window"))
    raise cmuxError(f"surface.health did not include {surface_ref}: {health}")


def _workspace_id(c: cmux, workspace_ref: str) -> str:
    health = c._call("surface.health", {"workspace_id": workspace_ref}) or {}
    workspace_id = str(health.get("workspace_id") or "")
    if not workspace_id:
        raise cmuxError(f"surface.health did not include workspace_id for {workspace_ref}: {health}")
    return workspace_id


def _assert_tmux_pane_command_probe_does_not_materialize(
    c: cmux,
    cli: str,
    workspace_ref: str,
    surface_ref: str,
) -> None:
    _must(
        _surface_in_window(c, workspace_ref, surface_ref) is False,
        f"test setup expected {surface_ref} to start unhosted",
    )
    code, output = _run_cli(
        cli,
        [
            "__tmux-compat",
            "list-panes",
            "-t",
            _workspace_id(c, workspace_ref),
            "-F",
            "#{pane_id}\t#{pane_start_command}",
        ],
        check=False,
        timeout=3.0,
    )
    _must(code == 0, f"tmux pane command metadata probe failed: {output!r}")
    _must(
        _surface_in_window(c, workspace_ref, surface_ref) is False,
        f"tmux pane command metadata probe should not materialize {surface_ref}: {output!r}",
    )


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

            helper_surface_ref = _new_terminal_surface(cli, workspace_ref, pane_ref)
            _assert_cli_read_materializes(
                cli,
                [
                    "read-screen",
                    "--workspace",
                    workspace_ref,
                    "--surface",
                    helper_surface_ref,
                    "--scrollback",
                    "--lines",
                    "20",
                ],
                helper_surface_ref,
                "read-screen new-surface",
            )

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
            _assert_tmux_pane_command_probe_does_not_materialize(
                c,
                cli,
                workspace_ref,
                helper_pane_surface_ref,
            )
            _assert_cli_read_materializes(
                cli,
                [
                    "read-screen",
                    "--workspace",
                    workspace_ref,
                    "--surface",
                    helper_pane_surface_ref,
                    "--scrollback",
                    "--lines",
                    "20",
                ],
                helper_pane_surface_ref,
                "read-screen new-pane",
            )

            capture_surface_ref = _new_terminal_surface(cli, workspace_ref, pane_ref)
            _assert_cli_read_materializes(
                cli,
                [
                    "capture-pane",
                    "--workspace",
                    workspace_ref,
                    "--surface",
                    capture_surface_ref,
                    "--lines",
                    "20",
                ],
                capture_surface_ref,
                "capture-pane new-surface",
            )

            pipe_surface_ref = _new_terminal_surface(cli, workspace_ref, pane_ref)
            _assert_cli_read_materializes(
                cli,
                [
                    "pipe-pane",
                    "--workspace",
                    workspace_ref,
                    "--surface",
                    pipe_surface_ref,
                    "--command",
                    "cat",
                ],
                pipe_surface_ref,
                "pipe-pane new-surface",
            )

            current = c._call("workspace.current") or {}
            _must(
                str(current.get("workspace_ref") or current.get("workspace_id") or "") == baseline_ws,
                f"helper read-screen should not switch selected workspace: {current}",
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

    print("PASS: read-screen materializes CLI-created background terminal helpers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
