#!/usr/bin/env python3
"""Regression guard for issue #952 (flaky CLI socket connections)."""

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


def require(content: str, needle: str, message: str, failures: list[str]) -> None:
    if needle not in content:
        failures.append(message)


def main() -> int:
    repo_root = get_repo_root()
    terminal_controller_path = repo_root / "Sources" / "TerminalController.swift"
    app_delegate_path = repo_root / "Sources" / "AppDelegate.swift"

    missing_paths = [
        str(path) for path in [terminal_controller_path, app_delegate_path] if not path.exists()
    ]
    if missing_paths:
        print("Missing expected files:")
        for path in missing_paths:
            print(f"  - {path}")
        return 1

    terminal_controller = terminal_controller_path.read_text(encoding="utf-8")
    app_delegate = app_delegate_path.read_text(encoding="utf-8")

    failures: list[str] = []

    require(
        terminal_controller,
        "let socketConnectable: Bool",
        "Socket health snapshot no longer tracks connectability",
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
        "private nonisolated static func probeSocketConnectability(path: String)",
        "Missing active socket connectability probe helper",
        failures,
    )
    require(
        terminal_controller,
        "connect(probeSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))",
        "Socket health probe no longer performs a real connect() check",
        failures,
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
        "\"socketConnectable\": health.socketConnectable ? 1 : 0",
        "Health telemetry no longer includes connectability signal",
        failures,
    )
    require(
        app_delegate,
        "if let socketConnectErrno = health.socketConnectErrno {",
        "Health telemetry no longer records connect probe errno when available",
        failures,
    )

    if failures:
        print("FAIL: issue #952 regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: issue #952 socket listener recovery guards are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
