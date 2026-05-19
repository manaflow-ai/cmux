#!/usr/bin/env python3
"""Regression: CLI-created terminal surfaces should become automation-ready without focus."""

from __future__ import annotations

import glob
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path
from typing import Any, List

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")
CLI_TIMEOUT_SECONDS = 15.0


def _must(cond: bool, msg: str) -> None:
    if not cond:
        raise cmuxError(msg)


def _find_cli_binary() -> str:
    for env_name in ("CMUX_BUNDLED_CLI_PATH", "CMUXTERM_CLI"):
        env_cli = os.environ.get(env_name)
        if env_cli and os.path.isfile(env_cli) and os.access(env_cli, os.X_OK):
            return env_cli

    fixed = os.path.expanduser("~/Library/Developer/Xcode/DerivedData/cmux-tests-v2/Build/Products/Debug/cmux")
    if os.path.isfile(fixed) and os.access(fixed, os.X_OK):
        return fixed

    candidates = glob.glob(
        os.path.expanduser("~/Library/Developer/Xcode/DerivedData/**/Build/Products/Debug/cmux"),
        recursive=True,
    )
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
    try:
        proc = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=CLI_TIMEOUT_SECONDS,
        )
    except subprocess.TimeoutExpired as exc:
        stdout = exc.stdout or ""
        stderr = exc.stderr or ""
        merged = f"{stdout}\n{stderr}".strip()
        raise cmuxError(f"CLI timed out after {CLI_TIMEOUT_SECONDS:.0f}s ({' '.join(cmd)}): {merged}") from exc
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(cmd)}): {merged}")
    return proc.stdout.strip()


def _run_cli_json(cli: str, args: List[str]) -> Any:
    output = _run_cli(cli, ["--json"] + args)
    try:
        return json.loads(output or "{}")
    except Exception as exc:
        raise cmuxError(f"Invalid JSON output: {output!r} ({exc})")


def _extract_ref(output: str, kind: str) -> str:
    match = re.search(rf"\b{kind}:\d+\b", output)
    if not match:
        raise cmuxError(f"Could not find {kind} ref in CLI output: {output!r}")
    return match.group(0)


def _current_workspace(c: cmux) -> str:
    payload = c._call("workspace.current") or {}
    ws_id = str(payload.get("workspace_id") or "")
    if not ws_id:
        raise cmuxError(f"workspace.current returned no workspace_id: {payload}")
    return ws_id


def _surface_ref_by_index(c: cmux, workspace_ref: str, index: int = 0) -> str:
    deadline = time.time() + 5.0
    rows: list[dict] = []
    while time.time() < deadline:
        rows = c.surface_health(workspace_ref)
        if len(rows) > index:
            surface_ref = str(rows[index].get("ref") or rows[index].get("id") or "")
            if surface_ref:
                return surface_ref
        time.sleep(0.1)
    raise cmuxError(f"surface health missing index {index}: {rows}")


def _terminal_surface_refs(c: cmux, workspace_ref: str, expected_count: int) -> list[str]:
    deadline = time.time() + 5.0
    rows: list[dict] = []
    while time.time() < deadline:
        rows = c.surface_health(workspace_ref)
        refs = [
            str(row.get("ref") or row.get("id") or "")
            for row in rows
            if row.get("type") == "terminal"
        ]
        refs = [ref for ref in refs if ref]
        if len(refs) >= expected_count:
            return refs
        time.sleep(0.1)
    raise cmuxError(f"surface health missing {expected_count} terminal refs: {rows}")


def _wait_for_terminal_ready(c: cmux, workspace_ref: str, surface_ref: str, label: str) -> dict:
    deadline = time.time() + 10.0
    last_row: dict = {}
    while time.time() < deadline:
        rows = c.surface_health(workspace_ref)
        for row in rows:
            if str(row.get("ref") or "") == surface_ref or str(row.get("id") or "") == surface_ref:
                last_row = dict(row)
                runtime_ready = row.get("runtime_surface_ready") is True
                terminal_ready = row.get("terminal_ready") is True
                tty_ready = bool(str(row.get("tty") or "").strip())
                foreground_ready = isinstance(row.get("foreground_pid"), int) and row.get("foreground_pid") > 0
                not_exited = row.get("process_exited") is False
                if runtime_ready and terminal_ready and tty_ready and foreground_ready and not_exited:
                    return dict(row)
        time.sleep(0.1)

    raise cmuxError(f"{label} did not become terminal-ready: {last_row}")


def _assert_not_visible_ready(row: dict, label: str) -> None:
    _must(row.get("runtime_surface_ready") is True, f"{label} runtime not ready: {row}")
    _must(row.get("terminal_ready") is True, f"{label} terminal not ready: {row}")
    _must(bool(str(row.get("tty") or "").strip()), f"{label} missing tty: {row}")
    _must(isinstance(row.get("foreground_pid"), int) and row.get("foreground_pid") > 0, f"{label} missing foreground pid: {row}")
    _must(row.get("process_exited") is False, f"{label} process exited: {row}")
    _must(row.get("visible_in_ui") is False, f"{label} should stay hidden while its workspace is backgrounded: {row}")


def main() -> int:
    cli = _find_cli_binary()

    with cmux(SOCKET_PATH) as c:
        baseline_ws = _current_workspace(c)
        baseline_window = c.current_window()
        cleanup_workspaces: list[str] = []
        cleanup_windows: list[str] = []

        try:
            created = _run_cli(cli, ["new-workspace", "--focus", "false"])
            workspace_ref = created.removeprefix("OK ").strip()
            _must(bool(workspace_ref), f"new-workspace returned no workspace ref: {created!r}")
            cleanup_workspaces.append(workspace_ref)
            _must(_current_workspace(c) == baseline_ws, "background new-workspace should not switch selected workspace")

            initial_surface = _surface_ref_by_index(c, workspace_ref, 0)
            row = _wait_for_terminal_ready(c, workspace_ref, initial_surface, "background workspace initial surface")
            _assert_not_visible_ready(row, "background workspace initial surface")

            surface_created = _run_cli(
                cli,
                [
                    "new-surface",
                    "--workspace",
                    workspace_ref,
                    "--type",
                    "terminal",
                    "--focus",
                    "false",
                ],
            )
            surface_ref = _extract_ref(surface_created, "surface")
            row = _wait_for_terminal_ready(c, workspace_ref, surface_ref, "background new-surface")
            _assert_not_visible_ready(row, "background new-surface")

            tab_action = _run_cli_json(
                cli,
                [
                    "tab-action",
                    "--workspace",
                    workspace_ref,
                    "--action",
                    "new-terminal-right",
                    "--focus",
                    "false",
                ],
            )
            tab_surface_ref = str(tab_action.get("created_surface_ref") or "")
            _must(bool(tab_surface_ref), f"new-terminal-right returned no created surface ref: {tab_action}")
            row = _wait_for_terminal_ready(c, workspace_ref, tab_surface_ref, "background new-terminal-right")
            _assert_not_visible_ready(row, "background new-terminal-right")

            split_created = _run_cli(
                cli,
                [
                    "new-split",
                    "right",
                    "--workspace",
                    workspace_ref,
                    "--surface",
                    initial_surface,
                    "--focus",
                    "false",
                ],
            )
            split_ref = _extract_ref(split_created, "surface")
            row = _wait_for_terminal_ready(c, workspace_ref, split_ref, "background new-split")
            _assert_not_visible_ready(row, "background new-split")

            pane_created = _run_cli(
                cli,
                [
                    "new-pane",
                    "--workspace",
                    workspace_ref,
                    "--type",
                    "terminal",
                    "--direction",
                    "down",
                    "--focus",
                    "false",
                ],
            )
            pane_surface_ref = _extract_ref(pane_created, "surface")
            row = _wait_for_terminal_ready(c, workspace_ref, pane_surface_ref, "background new-pane")
            _assert_not_visible_ready(row, "background new-pane")

            layout = {
                "pane": {
                    "surfaces": [
                        {"type": "terminal", "name": "layout-a"},
                        {"type": "terminal", "name": "layout-b"},
                        {"type": "terminal", "name": "layout-c"},
                    ]
                }
            }
            layout_created = _run_cli(
                cli,
                [
                    "new-workspace",
                    "--layout",
                    json.dumps(layout),
                    "--focus",
                    "false",
                ],
            )
            layout_workspace = layout_created.removeprefix("OK ").strip()
            _must(bool(layout_workspace), f"layout new-workspace returned no workspace ref: {layout_created!r}")
            cleanup_workspaces.append(layout_workspace)
            for index, layout_surface_ref in enumerate(_terminal_surface_refs(c, layout_workspace, 3), start=1):
                row = _wait_for_terminal_ready(
                    c,
                    layout_workspace,
                    layout_surface_ref,
                    f"background layout terminal {index}",
                )
                _assert_not_visible_ready(row, f"background layout terminal {index}")

            other_window = c.new_window()
            cleanup_windows.append(other_window)
            c.focus_window(baseline_window)
            _must(_current_workspace(c) == baseline_ws, "test setup should restore original window/workspace before cross-window case")
            other_created = _run_cli(
                cli,
                [
                    "new-workspace",
                    "--window",
                    other_window,
                    "--focus",
                    "false",
                ],
            )
            other_workspace = other_created.removeprefix("OK ").strip()
            _must(bool(other_workspace), f"new-workspace in another window returned no workspace ref: {other_created!r}")
            cleanup_workspaces.append(other_workspace)
            other_surface = _surface_ref_by_index(c, other_workspace, 0)
            row = _wait_for_terminal_ready(c, other_workspace, other_surface, "other window background workspace")
            _assert_not_visible_ready(row, "other window background workspace")

            _must(_current_workspace(c) == baseline_ws, "non-focus lifecycle setup should preserve the original workspace")
        finally:
            for workspace_ref in reversed(cleanup_workspaces):
                try:
                    c.close_workspace(workspace_ref)
                except Exception:
                    pass
            for window_id in reversed(cleanup_windows):
                try:
                    c.close_window(window_id)
                except Exception:
                    pass

    print("PASS: CLI terminal lifecycle readiness is explicit for background workspace/window/pane cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
