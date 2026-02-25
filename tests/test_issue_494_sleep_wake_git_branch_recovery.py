#!/usr/bin/env python3
"""Regression guard for issue #494 (post-wake sidebar git updates freezing)."""

from __future__ import annotations

import subprocess
from pathlib import Path


def get_repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path.cwd()


def read_text(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def require(content: str, needle: str, message: str, failures: list[str]) -> None:
    if needle not in content:
        failures.append(message)


def main() -> int:
    repo_root = get_repo_root()
    zsh_path = repo_root / "Resources" / "shell-integration" / "cmux-zsh-integration.zsh"
    bash_path = repo_root / "Resources" / "shell-integration" / "cmux-bash-integration.bash"
    app_delegate_path = repo_root / "Sources" / "AppDelegate.swift"

    required_paths = [zsh_path, bash_path, app_delegate_path]
    missing_paths = [str(path) for path in required_paths if not path.exists()]
    if missing_paths:
        print("Missing expected files:")
        for path in missing_paths:
            print(f"  - {path}")
        return 1

    zsh_content = read_text(zsh_path)
    bash_content = read_text(bash_path)
    app_delegate = read_text(app_delegate_path)

    failures: list[str] = []

    require(
        zsh_content,
        "_CMUX_GIT_JOB_STARTED_AT",
        "zsh integration is missing git probe start tracking",
        failures,
    )
    require(
        zsh_content,
        "_CMUX_PR_JOB_STARTED_AT",
        "zsh integration is missing PR probe start tracking",
        failures,
    )
    require(
        zsh_content,
        "_CMUX_ASYNC_JOB_TIMEOUT",
        "zsh integration is missing async probe timeout guard",
        failures,
    )
    require(
        zsh_content,
        "now - _CMUX_GIT_JOB_STARTED_AT >= _CMUX_ASYNC_JOB_TIMEOUT",
        "zsh integration no longer clears stale git probe PID after timeout",
        failures,
    )
    require(
        zsh_content,
        "now - _CMUX_PR_JOB_STARTED_AT >= _CMUX_ASYNC_JOB_TIMEOUT",
        "zsh integration no longer clears stale PR probe PID after timeout",
        failures,
    )
    require(
        zsh_content,
        "ncat -w 1 -U \"$CMUX_SOCKET_PATH\" --send-only",
        "zsh integration missing ncat socket timeout",
        failures,
    )
    require(
        zsh_content,
        "socat -T 1 - \"UNIX-CONNECT:$CMUX_SOCKET_PATH\"",
        "zsh integration missing socat socket timeout",
        failures,
    )

    require(
        bash_content,
        "_CMUX_GIT_JOB_STARTED_AT",
        "bash integration is missing git probe start tracking",
        failures,
    )
    require(
        bash_content,
        "_CMUX_PR_JOB_STARTED_AT",
        "bash integration is missing PR probe start tracking",
        failures,
    )
    require(
        bash_content,
        "_CMUX_ASYNC_JOB_TIMEOUT",
        "bash integration is missing async probe timeout guard",
        failures,
    )
    require(
        bash_content,
        "now - _CMUX_GIT_JOB_STARTED_AT >= _CMUX_ASYNC_JOB_TIMEOUT",
        "bash integration no longer clears stale git probe PID after timeout",
        failures,
    )
    require(
        bash_content,
        "now - _CMUX_PR_JOB_STARTED_AT >= _CMUX_ASYNC_JOB_TIMEOUT",
        "bash integration no longer clears stale PR probe PID after timeout",
        failures,
    )
    require(
        bash_content,
        "ncat -w 1 -U \"$CMUX_SOCKET_PATH\" --send-only",
        "bash integration missing ncat socket timeout",
        failures,
    )
    require(
        bash_content,
        "socat -T 1 - \"UNIX-CONNECT:$CMUX_SOCKET_PATH\"",
        "bash integration missing socat socket timeout",
        failures,
    )

    require(
        app_delegate,
        "NSWorkspace.didWakeNotification",
        "AppDelegate is missing wake observer for socket listener recovery",
        failures,
    )
    require(
        app_delegate,
        "restartSocketListenerIfEnabled(source: \"workspace.didWake\")",
        "Wake observer no longer re-arms the socket listener",
        failures,
    )
    require(
        app_delegate,
        "private func restartSocketListenerIfEnabled(source: String)",
        "Missing shared socket-listener restart helper",
        failures,
    )

    if failures:
        print("FAIL: issue #494 regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: issue #494 sleep/wake recovery guards are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
