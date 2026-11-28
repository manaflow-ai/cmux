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


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux-debug.sock")


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


def _run_cli(cli: str, args: list[str], *, extra_env: dict[str, str] | None = None) -> str:
    env = dict(os.environ)
    if extra_env:
        env.update(extra_env)
    proc = subprocess.run(
        [cli, "--socket", SOCKET_PATH, *args],
        capture_output=True,
        text=True,
        check=False,
        env=env,
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

            deploy_response = _run_cli(cli, ["set-status", "deploy", "v1.2.3", "--workspace", workspace_id])
            _must(deploy_response.startswith("OK"), f"first set-status should succeed, got {deploy_response!r}")

            build_response = _run_cli(
                cli,
                [
                    "set-status",
                    "build",
                    "compiling",
                    "--workspace",
                    workspace_id,
                    "--priority",
                    "80",
                ],
            )
            _must(build_response.startswith("OK"), f"second set-status should succeed, got {build_response!r}")

            wrap_response = _run_cli(
                cli,
                [
                    "set-status",
                    "wrap",
                    "done",
                    "--workspace",
                    workspace_id,
                    "--priority",
                    "40",
                ],
            )
            _must(wrap_response.startswith("OK"), f"third set-status should succeed, got {wrap_response!r}")

            status_list = _run_cli(cli, ["list-status", "--workspace", workspace_id])
            _must("build=compiling" in status_list, f"list-status should include the inserted status entry: {status_list!r}")
            _must("deploy=v1.2.3" in status_list, f"list-status should include the second status entry: {status_list!r}")
            _must("priority=80" in status_list, f"list-status should include the inserted status priority: {status_list!r}")
            _must("wrap=done" in status_list, f"list-status should include the third status entry: {status_list!r}")
            _must("priority=40" in status_list, f"list-status should include the third status priority: {status_list!r}")
            status_lines = [line for line in status_list.splitlines() if line.strip()]
            build_index = next((idx for idx, line in enumerate(status_lines) if line.startswith("build=compiling")), None)
            deploy_index = next((idx for idx, line in enumerate(status_lines) if line.startswith("deploy=v1.2.3")), None)
            wrap_index = next((idx for idx, line in enumerate(status_lines) if line.startswith("wrap=done")), None)
            _must(build_index is not None, f"list-status should include the build status row: {status_list!r}")
            _must(deploy_index is not None, f"list-status should include the deploy status row: {status_list!r}")
            _must(wrap_index is not None, f"list-status should include the wrap status row: {status_list!r}")
            _must(
                build_index < wrap_index < deploy_index,
                f"status rows should sort by priority, not insertion order or timestamp: {status_list!r}",
            )

            progress_response = _run_cli(cli, ["set-progress", "0.5", "--workspace", workspace_id, "--label", "Building"])
            _must(progress_response.startswith("OK"), f"set-progress should succeed, got {progress_response!r}")

            log_response = _run_cli(cli, ["log", "--workspace", workspace_id, "--", "ship it"])
            _must(log_response.startswith("OK"), f"log should succeed, got {log_response!r}")

            env_log_response = _run_cli(
                cli,
                ["log", "--", "env scoped log"],
                extra_env={"CMUX_WORKSPACE_ID": workspace_id},
            )
            _must(env_log_response.startswith("OK"), f"log with env workspace should succeed, got {env_log_response!r}")

            log_list = _run_cli(cli, ["list-log", "--workspace", workspace_id, "--limit", "5"])
            _must("ship it" in log_list, f"list-log should include the appended log entry: {log_list!r}")
            _must("env scoped log" in log_list, f"list-log should include env-routed log entry: {log_list!r}")

            sidebar_state = _run_cli(cli, ["sidebar-state", "--workspace", workspace_id])
            _must("status_count=3" in sidebar_state, f"sidebar-state should include the status entry count: {sidebar_state!r}")
            _must("progress=0.50 Building" in sidebar_state, f"sidebar-state should include the progress label: {sidebar_state!r}")
            _must("[info] ship it" in sidebar_state, f"sidebar-state should include the recent log entry: {sidebar_state!r}")

            clear_status_response = _run_cli(cli, ["clear-status", "build", "--workspace", workspace_id])
            _must(clear_status_response.startswith("OK"), f"clear-status should succeed, got {clear_status_response!r}")
            clear_deploy_response = _run_cli(cli, ["clear-status", "deploy", "--workspace", workspace_id])
            _must(clear_deploy_response.startswith("OK"), f"second clear-status should succeed, got {clear_deploy_response!r}")
            clear_wrap_response = _run_cli(cli, ["clear-status", "wrap", "--workspace", workspace_id])
            _must(clear_wrap_response.startswith("OK"), f"third clear-status should succeed, got {clear_wrap_response!r}")

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
