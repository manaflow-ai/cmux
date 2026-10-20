#!/usr/bin/env python3
"""Regression test for Swift CLI relocation of a moved managed launch surface."""

from __future__ import annotations

import os
import subprocess
import tempfile
from pathlib import Path

from claude_teams_test_utils import (
    focused_cmux_server,
    resolve_cmux_cli,
    stable_tmux_numeric_id,
)


def parsed_environment(stdout: str) -> dict[str, str]:
    return dict(line.split("=", 1) for line in stdout.splitlines() if "=" in line)


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    old_workspace_id = "11111111-1111-4111-8111-111111111111"
    current_workspace_id = "22222222-2222-4222-8222-222222222222"
    surface_id = "33333333-3333-4333-8333-333333333333"
    current_pane_id = "44444444-4444-4444-8444-444444444444"
    current_window_id = "55555555-5555-4555-8555-555555555555"
    stale_panel_id = "66666666-6666-4666-8666-666666666666"
    stale_pane_id = "77777777-7777-4777-8777-777777777777"

    with tempfile.TemporaryDirectory(prefix="cmux-moved-teams-surface-") as td:
        socket_path = Path(td) / "cmux.sock"
        with focused_cmux_server(
            socket_path,
            workspace_id=current_workspace_id,
            window_id=current_window_id,
            pane_id=current_pane_id,
            surface_id=surface_id,
            stale_workspace_id=old_workspace_id,
            identified_workspace_id="aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
            identified_window_id="bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
            identified_pane_id="cccccccc-cccc-4ccc-8ccc-cccccccccccc",
            identified_surface_id="dddddddd-dddd-4ddd-8ddd-dddddddddddd",
        ) as (resolved_socket_path, requests):
            environment = os.environ.copy()
            environment.pop("CMUX_SOCKET", None)
            environment.pop("CMUX_SOCKET_CAPABILITY", None)
            environment.pop("CMUX_SOCKET_PASSWORD", None)
            environment.update(
                {
                    "CMUX_SOCKET_PATH": resolved_socket_path,
                    "CMUX_WORKSPACE_ID": old_workspace_id,
                    "CMUX_SURFACE_ID": surface_id,
                    "CMUX_PANEL_ID": stale_panel_id,
                    "CMUX_TAB_ID": old_workspace_id,
                    "CMUX_PANE_ID": stale_pane_id,
                    "TMUX": "__STALE_TMUX__",
                    "TMUX_PANE": "%999",
                }
            )
            result = subprocess.run(
                [cli_path, "--socket", resolved_socket_path, "__debug-tmux-compat-env"],
                capture_output=True,
                text=True,
                check=False,
                env=environment,
                timeout=30,
            )

    if result.returncode != 0:
        print(f"FAIL: moved-surface debug launch exited {result.returncode}: {result.stderr.strip()}")
        return 1
    if requests != ["surface.list", "surface.list"]:
        print(f"FAIL: expected workspace lookup then stable-surface relocation, got {requests!r}")
        return 1

    pane_token = stable_tmux_numeric_id(current_pane_id)
    expected = {
        "CMUX_WORKSPACE_ID": current_workspace_id,
        "CMUX_TAB_ID": current_workspace_id,
        "CMUX_SURFACE_ID": surface_id,
        "CMUX_PANEL_ID": surface_id,
        "CMUX_PANE_ID": current_pane_id,
        "TMUX": f"/tmp/cmux-debug/{current_workspace_id},{current_window_id},{pane_token}",
        "TMUX_PANE": f"%{pane_token}",
    }
    observed = parsed_environment(result.stdout)
    if observed != expected:
        print(f"FAIL: moved launch identity was not canonicalized; expected {expected!r}, got {observed!r}")
        return 1
    if any(stale in result.stdout for stale in [old_workspace_id, stale_panel_id, stale_pane_id]):
        print(f"FAIL: stale inherited identity leaked into child environment: {result.stdout!r}")
        return 1

    print("PASS: moved launch surface relocates by UUID and canonicalizes all child identity aliases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
