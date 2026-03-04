#!/usr/bin/env python3
"""Regression test: CLI should survive broken pipes and emit send breadcrumbs."""

from __future__ import annotations

import subprocess
from pathlib import Path


def get_repo_root() -> Path:
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"],
        capture_output=True,
        text=True,
        check=False,
    )
    if result.returncode == 0:
        return Path(result.stdout.strip())
    return Path.cwd()


def require(content: str, needle: str, message: str, failures: list[str]) -> None:
    if needle not in content:
        failures.append(message)


def main() -> int:
    repo_root = get_repo_root()
    cli_path = repo_root / "CLI" / "cmux.swift"
    if not cli_path.exists():
        print(f"FAIL: missing expected file: {cli_path}")
        return 1

    content = cli_path.read_text(encoding="utf-8")
    failures: list[str] = []

    require(
        content,
        "_ = signal(SIGPIPE, SIG_IGN)",
        "CLI main must ignore SIGPIPE so socket write failures return errors instead of terminating the process",
        failures,
    )
    require(
        content,
        "let client = SocketClient(path: socketPath, telemetry: cliTelemetry)",
        "SocketClient should receive CLI telemetry for per-command send breadcrumbs",
        failures,
    )
    require(
        content,
        '"socket.send.write.failure"',
        "Socket send write failures should emit breadcrumbs",
        failures,
    )
    require(
        content,
        '"socket.send.timeout"',
        "Socket send timeouts should emit breadcrumbs",
        failures,
    )
    require(
        content,
        '"socket.send.read.failure"',
        "Socket read failures should emit breadcrumbs",
        failures,
    )
    require(
        content,
        'if trimmed.lowercased().hasPrefix("auth ") {\n            return "auth <redacted>"',
        "Socket command summaries must redact auth payloads",
        failures,
    )
    require(
        content,
        'cliTelemetry.captureError(stage: "command_dispatch", error: error)',
        "Command dispatch failures should be captured for non-claude-hook commands",
        failures,
    )

    if failures:
        print("FAIL: CLI SIGPIPE/breadcrumb regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: CLI SIGPIPE handling and send breadcrumbs are wired")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
