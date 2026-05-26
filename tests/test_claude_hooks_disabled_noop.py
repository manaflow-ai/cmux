#!/usr/bin/env python3
"""
Regression test: disabled Claude integration must no-op before socket use.
"""

from __future__ import annotations

import os
import subprocess
import tempfile

from claude_teams_test_utils import resolve_cmux_cli


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    missing_socket = os.path.join(tempfile.gettempdir(), f"cmux-disabled-claude-{os.getpid()}.sock")
    env = os.environ.copy()
    env["CMUX_CLAUDE_HOOKS_DISABLED"] = "1"
    env["CMUX_SURFACE_ID"] = "00000000-0000-0000-0000-000000000001"
    env["CMUX_WORKSPACE_ID"] = "00000000-0000-0000-0000-000000000002"
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"

    payload = '{"session_id":"disabled-test","hook_event_name":"PreToolUse","tool_name":"Read"}'
    cases = [
        [cli_path, "--socket", missing_socket, "hooks", "claude", "pre-tool-use"],
        [cli_path, "--socket", missing_socket, "hooks", "feed", "--source", "claude", "--event", "PreToolUse"],
        [cli_path, "--socket", missing_socket, "claude-hook", "pre-tool-use"],
    ]

    for command in cases:
        proc = subprocess.run(
            command,
            input=payload,
            text=True,
            capture_output=True,
            env=env,
            check=False,
        )
        if proc.returncode != 0:
            print(f"FAIL: disabled Claude hook command exited {proc.returncode}: {' '.join(command)}")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            return 1
        if proc.stdout.strip() != "{}":
            print(f"FAIL: expected disabled Claude hook command to print {{}}: {' '.join(command)}")
            print(f"stdout={proc.stdout!r}")
            print(f"stderr={proc.stderr!r}")
            return 1

    install_proc = subprocess.run(
        [cli_path, "--socket", missing_socket, "hooks", "claude", "install"],
        text=True,
        capture_output=True,
        env=env,
        check=False,
    )
    if install_proc.returncode == 0:
        print("FAIL: disabled Claude hooks must not turn install into a no-op success")
        print(f"stdout={install_proc.stdout!r}")
        print(f"stderr={install_proc.stderr!r}")
        return 1
    if install_proc.stdout.strip() == "{}":
        print("FAIL: disabled Claude hooks must not hide install errors behind {}")
        print(f"stdout={install_proc.stdout!r}")
        print(f"stderr={install_proc.stderr!r}")
        return 1
    if "does not install Claude hooks" not in install_proc.stderr:
        print("FAIL: expected explicit Claude install guidance")
        print(f"stdout={install_proc.stdout!r}")
        print(f"stderr={install_proc.stderr!r}")
        return 1

    print("PASS: disabled Claude hooks no-op before socket use")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
