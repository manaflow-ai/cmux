#!/usr/bin/env python3
"""
Regression test: CLI error reporting must not abort when stderr is a closed pipe.

macOS `FileHandle.standardError.write` raises an Objective-C exception on EPIPE,
which Swift cannot catch. The CLI should report through low-level writes that
treat a closed standard handle as a normal CLI pipe condition.
"""

from __future__ import annotations

import os
import subprocess
import sys

from claude_teams_test_utils import resolve_cmux_cli


def run_with_closed_stderr(cli_path: str) -> subprocess.CompletedProcess[bytes]:
    read_fd, write_fd = os.pipe()
    os.close(read_fd)
    try:
        env = dict(os.environ)
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        proc = subprocess.Popen(
            [cli_path, "__definitely_missing_command_for_closed_pipe_regression__"],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=write_fd,
            env=env,
        )
    finally:
        os.close(write_fd)

    return subprocess.CompletedProcess(proc.args, proc.wait(timeout=10))


def run_printing_command_with_closed_stdout(cli_path: str) -> subprocess.CompletedProcess[bytes]:
    read_fd, write_fd = os.pipe()
    os.close(read_fd)
    try:
        env = dict(os.environ)
        env["CMUX_CLI_SENTRY_DISABLED"] = "1"
        proc = subprocess.Popen(
            [cli_path, "--help"],
            stdin=subprocess.DEVNULL,
            stdout=write_fd,
            stderr=subprocess.DEVNULL,
            env=env,
        )
    finally:
        os.close(write_fd)

    return subprocess.CompletedProcess(proc.args, proc.wait(timeout=10))


def main() -> int:
    cli_path = resolve_cmux_cli()
    stderr_result = run_with_closed_stderr(cli_path)
    if stderr_result.returncode == -6:
        print("FAIL: cmux aborted with SIGABRT when stderr was closed", file=sys.stderr)
        return 1
    if stderr_result.returncode < 0:
        print(f"FAIL: cmux terminated by signal {-stderr_result.returncode}", file=sys.stderr)
        return 1
    if stderr_result.returncode != 1:
        print(f"FAIL: expected CLIError exit code 1, got {stderr_result.returncode}", file=sys.stderr)
        return 1

    stdout_result = run_printing_command_with_closed_stdout(cli_path)
    if stdout_result.returncode == -6:
        print("FAIL: cmux aborted with SIGABRT when stdout was closed", file=sys.stderr)
        return 1
    if stdout_result.returncode < 0:
        print(f"FAIL: cmux terminated by signal {-stdout_result.returncode}", file=sys.stderr)
        return 1
    if stdout_result.returncode != 0:
        print(f"FAIL: expected help command exit code 0, got {stdout_result.returncode}", file=sys.stderr)
        return 1

    print("PASS: closed stdout/stderr exit cleanly without Objective-C FileHandle abort")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
