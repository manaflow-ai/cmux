#!/usr/bin/env python3
"""Regression: global CLI flags still parse and v1 ERROR responses fail with non-zero exit."""

from __future__ import annotations

import glob
import os
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmuxError


SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "").strip()
if not SOCKET_PATH:
    raise cmuxError("CMUX_SOCKET_PATH is required (expected /tmp/cmux-debug-<tag>.sock)")
LAST_SOCKET_HINT_PATH = Path("/tmp/cmux-last-socket-path")


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


def _run(cmd: list[str], env: dict[str, str] | None = None) -> subprocess.CompletedProcess[str]:
    return subprocess.run(cmd, capture_output=True, text=True, check=False, env=env)


def _merged_output(proc: subprocess.CompletedProcess[str]) -> str:
    return f"{proc.stdout}\n{proc.stderr}".strip()


def main() -> int:
    cli = _find_cli_binary()

    # Global --version should be handled before socket command dispatch.
    version_proc = _run([cli, "--version"])
    version_out = _merged_output(version_proc).lower()
    _must(version_proc.returncode == 0, f"--version should succeed: {version_proc.returncode} {version_out!r}")
    _must("cmux" in version_out, f"--version output should mention cmux: {version_out!r}")

    legacy_socket_key = "CMUX_" + "SOCKET"
    conflict_env = dict(os.environ)
    conflict_env["CMUX_SOCKET_PATH"] = SOCKET_PATH
    conflict_env[legacy_socket_key] = "/tmp/cmux-conflicting-legacy.sock"
    conflict_version = _run([cli, "--version"], env=conflict_env)
    conflict_version_out = _merged_output(conflict_version).lower()
    _must(conflict_version.returncode == 0, f"--version should ignore socket env conflicts: {conflict_version_out!r}")
    _must("cmux" in conflict_version_out, f"--version with socket env conflict should mention cmux: {conflict_version_out!r}")
    conflict_help = _run([cli, "--help"], env=conflict_env)
    conflict_help_out = _merged_output(conflict_help).lower()
    _must(conflict_help.returncode == 0, f"--help should ignore socket env conflicts: {conflict_help_out!r}")
    _must("usage" in conflict_help_out, f"--help with socket env conflict should show usage: {conflict_help_out!r}")
    conflict_help_command = _run([cli, "help"], env=conflict_env)
    conflict_help_command_out = _merged_output(conflict_help_command).lower()
    _must(conflict_help_command.returncode == 0, f"help command should ignore socket env conflicts: {conflict_help_command_out!r}")
    _must("usage" in conflict_help_command_out, f"help command with socket env conflict should show usage: {conflict_help_command_out!r}")
    conflict_help_command_help = _run([cli, "help", "--help"], env=conflict_env)
    conflict_help_command_help_out = _merged_output(conflict_help_command_help).lower()
    _must(conflict_help_command_help.returncode == 0, f"help --help should ignore socket env conflicts: {conflict_help_command_help_out!r}")
    _must("usage: cmux help" in conflict_help_command_help_out, f"help --help should show help command usage: {conflict_help_command_help_out!r}")
    conflict_subcommand_help = _run([cli, "ping", "--help"], env=conflict_env)
    conflict_subcommand_help_out = _merged_output(conflict_subcommand_help).lower()
    _must(conflict_subcommand_help.returncode == 0, f"subcommand --help should ignore socket env conflicts: {conflict_subcommand_help_out!r}")
    _must("usage: cmux ping" in conflict_subcommand_help_out, f"subcommand --help should show command usage: {conflict_subcommand_help_out!r}")
    for docs_cmd, expected in [
        ([cli, "docs"], "topics:"),
        ([cli, "docs", "settings"], "config files:"),
        ([cli, "settings", "path"], "config files:"),
        ([cli, "settings", "--", "path"], "config files:"),
        ([cli, "settings", "docs"], "config files:"),
        ([cli, "settings", "--", "docs"], "config files:"),
        ([cli, "welcome"], "built for coding agents"),
    ]:
        docs_proc = _run(docs_cmd, env=conflict_env)
        docs_out = _merged_output(docs_proc).lower()
        _must(docs_proc.returncode == 0, f"{docs_cmd[1:]} should ignore socket env conflicts: {docs_out!r}")
        _must(expected in docs_out, f"{docs_cmd[1:]} should show no-socket output: {docs_out!r}")
    override_ping = _run([cli, "--socket", SOCKET_PATH, "ping"], env=conflict_env)
    override_ping_out = _merged_output(override_ping).lower()
    _must(override_ping.returncode == 0, f"--socket should override conflicting socket env: {override_ping_out!r}")
    _must("pong" in override_ping_out, f"--socket override should still return pong: {override_ping_out!r}")
    conflict_proc = _run([cli, "ping"], env=conflict_env)
    conflict_out = _merged_output(conflict_proc)
    _must(conflict_proc.returncode != 0, f"conflicting socket env should fail: {conflict_out!r}")
    _must("CMUX_SOCKET_PATH" in conflict_out and "differ" in conflict_out, f"conflict error should name canonical socket env: {conflict_out!r}")

    # Debug builds should auto-resolve the active debug socket via /tmp/cmux-last-socket-path
    # when CMUX_SOCKET_PATH is not set.
    hint_backup: str | None = None
    hint_had_file = LAST_SOCKET_HINT_PATH.exists()
    if hint_had_file:
        hint_backup = LAST_SOCKET_HINT_PATH.read_text(encoding="utf-8")
    try:
        LAST_SOCKET_HINT_PATH.write_text(f"{SOCKET_PATH}\n", encoding="utf-8")
        auto_env = dict(os.environ)
        auto_env.pop("CMUX_SOCKET_PATH", None)
        auto_ping = _run([cli, "ping"], env=auto_env)
        auto_ping_out = _merged_output(auto_ping).lower()
        _must(auto_ping.returncode == 0, f"debug auto socket resolution should succeed: {auto_ping.returncode} {auto_ping_out!r}")
        _must("pong" in auto_ping_out, f"debug auto socket resolution should return pong: {auto_ping_out!r}")
    finally:
        try:
            if hint_had_file:
                LAST_SOCKET_HINT_PATH.write_text(hint_backup or "", encoding="utf-8")
            else:
                LAST_SOCKET_HINT_PATH.unlink(missing_ok=True)
        except OSError:
            pass

    # Global --password should parse as a flag (not a command name) and still allow non-password sockets.
    ping_proc = _run([cli, "--socket", SOCKET_PATH, "--password", "ignored-in-cmuxonly", "ping"])
    ping_out = _merged_output(ping_proc).lower()
    _must(ping_proc.returncode == 0, f"ping with --password should succeed: {ping_proc.returncode} {ping_out!r}")
    _must("pong" in ping_out, f"ping should still return pong: {ping_out!r}")

    # V1 errors must produce non-zero exit codes for automation correctness.
    bad_focus = _run([cli, "--socket", SOCKET_PATH, "focus-window", "--window", "window:999999"])
    bad_out = _merged_output(bad_focus).lower()
    _must(bad_focus.returncode != 0, f"focus-window with invalid target should fail non-zero: {bad_out!r}")
    _must("error" in bad_out, f"focus-window failure should surface an error: {bad_out!r}")

    print("PASS: global flags parse correctly and v1 ERROR responses fail the CLI process")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
