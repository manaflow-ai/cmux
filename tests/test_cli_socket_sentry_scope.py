#!/usr/bin/env python3
"""Regression test: CLI socket Sentry telemetry must apply to all commands."""

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


def reject(content: str, needle: str, message: str, failures: list[str]) -> None:
    if needle in content:
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
        "private final class CLISocketSentryTelemetry {",
        "Missing CLISocketSentryTelemetry definition",
        failures,
    )
    require(
        content,
        'processEnv["CMUX_CLI_SENTRY_DISABLED"] == "1" ||',
        "Missing CMUX_CLI_SENTRY_DISABLED kill switch",
        failures,
    )
    require(
        content,
        'processEnv["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] == "1"',
        "Missing backwards-compatible CMUX_CLAUDE_HOOK_SENTRY_DISABLED kill switch",
        failures,
    )
    require(
        content,
        "private var shouldEmit: Bool {\n        !disabledByEnv\n    }",
        "Telemetry scope should be command-agnostic (only disabled by env kill switch)",
        failures,
    )
    require(
        content,
        'let crumb = Breadcrumb(level: .info, category: "cmux.cli")',
        "Telemetry breadcrumb category should be cmux.cli",
        failures,
    )
    require(
        content,
        '"command": command,',
        "Base telemetry context must include command name",
        failures,
    )
    require(
        content,
        "let cliTelemetry = CLISocketSentryTelemetry(",
        "CLI should initialize generic socket telemetry",
        failures,
    )
    require(
        content,
        'cliTelemetry.breadcrumb(\n            "socket.connect.attempt",',
        "CLI should emit socket.connect.attempt breadcrumb for commands",
        failures,
    )

    reject(
        content,
        "self.enabled = command == \"claude-hook\"",
        "Telemetry regressed to claude-hook-only scope",
        failures,
    )
    reject(
        content,
        "enabled && !disabledByEnv",
        "Telemetry still depends on legacy enabled flag",
        failures,
    )

    if failures:
        print("FAIL: CLI socket telemetry scope regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: CLI socket telemetry scope is command-agnostic")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
