#!/usr/bin/env python3
"""Regression test: subcommand --help should never execute command dispatch."""

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
        'if commandArgs.contains("--help") || commandArgs.contains("-h") {',
        "Subcommand help pre-dispatch gate is missing",
        failures,
    )
    require(
        content,
        'if dispatchSubcommandHelp(command: command, commandArgs: commandArgs) {',
        "Subcommand help dispatch call is missing",
        failures,
    )
    require(
        content,
        'print("Usage: cmux <command>")',
        "Subcommand help fallback usage line is missing",
        failures,
    )
    require(
        content,
        'print("No detailed help available for this command.")',
        "Subcommand help fallback message is missing",
        failures,
    )
    require(
        content,
        "print(\"No detailed help available for this command.\")\n            return",
        "Subcommand help fallback must return before command execution",
        failures,
    )

    # Commands that must now have dedicated usage text.
    for needle, message in [
        ('case "new-window":', "Missing subcommandUsage entry for new-window"),
        ('case "list-panes":', "Missing subcommandUsage entry for list-panes"),
        ('case "list-pane-surfaces":', "Missing subcommandUsage entry for list-pane-surfaces"),
        ('case "surface-health":', "Missing subcommandUsage entry for surface-health"),
        ('case "trigger-flash":', "Missing subcommandUsage entry for trigger-flash"),
        ('case "list-panels":', "Missing subcommandUsage entry for list-panels"),
        ('case "focus-panel":', "Missing subcommandUsage entry for focus-panel"),
        ('case "set-app-focus":', "Missing subcommandUsage entry for set-app-focus"),
    ]:
        require(content, needle, message, failures)

    # Simple commands should still have a basic one-liner help entry.
    for needle, message in [
        ('case "ping":', "Missing subcommandUsage entry for ping"),
        ('case "capabilities":', "Missing subcommandUsage entry for capabilities"),
        ('case "identify":', "Missing subcommandUsage entry for identify"),
        ('case "list-windows":', "Missing subcommandUsage entry for list-windows"),
        ('case "current-window":', "Missing subcommandUsage entry for current-window"),
        ('case "refresh-surfaces":', "Missing subcommandUsage entry for refresh-surfaces"),
        ('case "current-workspace":', "Missing subcommandUsage entry for current-workspace"),
        ('case "list-notifications":', "Missing subcommandUsage entry for list-notifications"),
        ('case "clear-notifications":', "Missing subcommandUsage entry for clear-notifications"),
    ]:
        require(content, needle, message, failures)

    if failures:
        print("FAIL: CLI subcommand help regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: CLI subcommand help fallback and usage coverage are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
