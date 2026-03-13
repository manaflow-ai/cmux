#!/usr/bin/env python3
"""Regression: sidebar metadata CLI commands still dispatch through the public cmux CLI."""

from __future__ import annotations

import glob
import os
import subprocess
import sys
from pathlib import Path

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


def _run_cli(cli: str, args: list[str]) -> str:
    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, *args],
        capture_output=True,
        text=True,
        check=False,
        env=dict(os.environ),
    )
    if proc.returncode != 0:
        merged = f"{proc.stdout}\n{proc.stderr}".strip()
        raise cmuxError(f"CLI failed ({' '.join(args)}): {merged}")
    return proc.stdout.strip()


def main() -> int:
    cli = _find_cli_binary()
    workspace_id = ""

    try:
        with cmux(SOCKET_PATH) as client:
            workspace_id = client.new_workspace()

            status_response = _run_cli(cli, ["set-status", "build", "compiling", "--workspace", workspace_id])
            _must(status_response.startswith("OK"), f"set-status should succeed, got {status_response!r}")

            status_list = _run_cli(cli, ["list-status", "--workspace", workspace_id])
            _must("build=compiling" in status_list, f"list-status should include the inserted status entry: {status_list!r}")

            progress_response = _run_cli(cli, ["set-progress", "0.5", "--workspace", workspace_id, "--label", "Building"])
            _must(progress_response.startswith("OK"), f"set-progress should succeed, got {progress_response!r}")

            log_response = _run_cli(cli, ["log", "--workspace", workspace_id, "--", "ship it"])
            _must(log_response.startswith("OK"), f"log should succeed, got {log_response!r}")

            log_list = _run_cli(cli, ["list-log", "--workspace", workspace_id, "--limit", "5"])
            _must("ship it" in log_list, f"list-log should include the appended log entry: {log_list!r}")

            sidebar_state = _run_cli(cli, ["sidebar-state", "--workspace", workspace_id])
            _must("status_count=1" in sidebar_state, f"sidebar-state should include the status entry count: {sidebar_state!r}")
            _must("progress=0.50 Building" in sidebar_state, f"sidebar-state should include the progress label: {sidebar_state!r}")
            _must("[info] ship it" in sidebar_state, f"sidebar-state should include the recent log entry: {sidebar_state!r}")

            clear_status_response = _run_cli(cli, ["clear-status", "build", "--workspace", workspace_id])
            _must(clear_status_response.startswith("OK"), f"clear-status should succeed, got {clear_status_response!r}")

            clear_progress_response = _run_cli(cli, ["clear-progress", "--workspace", workspace_id])
            _must(clear_progress_response.startswith("OK"), f"clear-progress should succeed, got {clear_progress_response!r}")

            clear_log_response = _run_cli(cli, ["clear-log", "--workspace", workspace_id])
            _must(clear_log_response.startswith("OK"), f"clear-log should succeed, got {clear_log_response!r}")

            cleared_sidebar_state = _run_cli(cli, ["sidebar-state", "--workspace", workspace_id])
            _must("status_count=0" in cleared_sidebar_state, f"sidebar-state should clear status entries: {cleared_sidebar_state!r}")
            _must("progress=none" in cleared_sidebar_state, f"sidebar-state should clear progress: {cleared_sidebar_state!r}")
            _must("log_count=0" in cleared_sidebar_state, f"sidebar-state should clear log entries: {cleared_sidebar_state!r}")

            client.close_workspace(workspace_id)
            workspace_id = ""
    finally:
        if workspace_id:
            try:
                with cmux(SOCKET_PATH) as cleanup_client:
                    cleanup_client.close_workspace(workspace_id)
            except Exception:
                pass

    print("PASS: sidebar metadata CLI commands dispatch and update workspace state")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
