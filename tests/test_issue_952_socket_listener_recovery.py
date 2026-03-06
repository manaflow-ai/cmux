#!/usr/bin/env python3
"""Regression guard for issue #952 (flaky CLI socket connections)."""

from __future__ import annotations

import re
import shutil
import subprocess
from pathlib import Path


def get_repo_root() -> Path:
    """Return the repository root for source inspections."""
    fallback_root = Path(__file__).resolve().parents[1]
    git_path = shutil.which("git")
    if git_path is None:
        return fallback_root

    try:
        result = subprocess.run(
            [git_path, "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return fallback_root
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return fallback_root


def require(content: str, needle: str, message: str, failures: list[str], *, regex: bool = False) -> None:
    """Record a failure when a required source pattern is missing."""
    matched = re.search(needle, content, re.MULTILINE) is not None if regex else needle in content
    if not matched:
        failures.append(message)


def collect_failures() -> list[str]:
    """Collect missing source-level guards for the socket listener recovery fix."""
    repo_root = get_repo_root()
    terminal_controller_path = repo_root / "Sources" / "TerminalController.swift"
    app_delegate_path = repo_root / "Sources" / "AppDelegate.swift"
    failures: list[str] = []

    missing_paths = [
        str(path) for path in [terminal_controller_path, app_delegate_path] if not path.exists()
    ]
    if missing_paths:
        for path in missing_paths:
            failures.append(f"Missing expected file: {path}")
        return failures

    terminal_controller = terminal_controller_path.read_text(encoding="utf-8")
    app_delegate = app_delegate_path.read_text(encoding="utf-8")

    require(
        terminal_controller,
        "let socketProbePerformed: Bool",
        "Socket health snapshot no longer tracks whether connectability was probed",
        failures,
    )
    require(
        terminal_controller,
        "let socketConnectable: Bool?",
        "Socket health snapshot no longer distinguishes unprobed vs connectable sockets",
        failures,
    )
    require(
        terminal_controller,
        "let socketConnectErrno: Int32?",
        "Socket health snapshot no longer preserves probe errno",
        failures,
    )
    require(
        terminal_controller,
        "signals.append(\"socket_unreachable\")",
        "Socket health failures no longer flag unreachable listeners",
        failures,
    )
    require(
        terminal_controller,
        r"private\s+nonisolated\s+static\s+func\s+probeSocketConnectability\s*\(\s*path:\s*String\s*\)",
        "Missing active socket connectability probe helper",
        failures,
        regex=True,
    )
    require(
        terminal_controller,
        r"connect\s*\(\s*probeSocket\s*,\s*sockaddrPtr\s*,\s*socklen_t\s*\(\s*MemoryLayout<sockaddr_un>\.size\s*\)\s*\)",
        "Socket health probe no longer performs a real connect() check",
        failures,
        regex=True,
    )
    require(
        terminal_controller,
        "stage: \"bind_path_too_long\"",
        "Socket listener start no longer reports overlong Unix socket paths",
        failures,
    )
    require(
        terminal_controller,
        "Self.unixSocketPathMaxLength",
        "Socket listener path-length telemetry was removed",
        failures,
    )

    require(
        app_delegate,
        "private static let socketListenerHealthCheckInterval: DispatchTimeInterval = .seconds(2)",
        "Socket health timer interval drifted from the fast recovery setting",
        failures,
    )
    require(
        app_delegate,
        "\"socketProbePerformed\": health.socketProbePerformed ? 1 : 0",
        "Health telemetry no longer records whether a connectability probe ran",
        failures,
    )
    require(
        app_delegate,
        "if let socketConnectable = health.socketConnectable {",
        "Health telemetry no longer gates connectability on an actual probe result",
        failures,
    )
    require(
        app_delegate,
        "data[\"socketConnectable\"] = socketConnectable ? 1 : 0",
        "Health telemetry no longer includes connectability when a probe ran",
        failures,
    )
    require(
        app_delegate,
        "if let socketConnectErrno = health.socketConnectErrno {",
        "Health telemetry no longer records connect probe errno when available",
        failures,
    )
    return failures


def test_issue_952_socket_listener_recovery() -> None:
    """Keep the source-level recovery guards for issue #952 in CI."""
    failures = collect_failures()
    assert not failures, "issue #952 regression(s) detected:\n- " + "\n- ".join(failures)


def main() -> int:
    """Run the regression guard without requiring pytest to be installed."""
    failures = collect_failures()
    if failures:
        print("FAIL: issue #952 regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: issue #952 socket listener recovery guards are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
