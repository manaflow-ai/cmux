#!/usr/bin/env python3
"""Regression tests for CLI subcommand help coverage and accuracy."""

from __future__ import annotations

import re
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


def extract_switch_commands(content: str, start_index: int = 0) -> tuple[set[str], int]:
    marker = "switch command {"
    marker_index = content.find(marker, start_index)
    if marker_index == -1:
        return set(), -1

    open_brace = content.find("{", marker_index)
    if open_brace == -1:
        return set(), -1

    depth = 1
    cursor = open_brace + 1
    while cursor < len(content) and depth > 0:
        char = content[cursor]
        if char == "{":
            depth += 1
        elif char == "}":
            depth -= 1
        cursor += 1

    block = content[open_brace + 1:cursor - 1]
    commands: set[str] = set()
    collecting_case = False
    case_lines: list[str] = []

    for line in block.splitlines():
        stripped = line.strip()
        if stripped.startswith("case "):
            collecting_case = True
            case_lines = [line]
        elif collecting_case:
            case_lines.append(line)

        if collecting_case and ":" in line:
            case_text = "\n".join(case_lines)
            commands.update(re.findall(r'"([^"]+)"', case_text))
            collecting_case = False
            case_lines = []

    return commands, cursor


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
        "print(\"Unknown command '\\(command)'. Run 'cmux help' to see available commands.\")",
        "Subcommand help fallback unknown-command line is missing",
        failures,
    )
    require(
        content,
        "print(\"Unknown command '\\(command)'. Run 'cmux help' to see available commands.\")\n            return",
        "Subcommand help fallback must return before command execution",
        failures,
    )

    dispatch_commands, next_index = extract_switch_commands(content, 0)
    subcommand_usage_commands, _ = extract_switch_commands(content, next_index if next_index != -1 else 0)
    if not dispatch_commands:
        failures.append("Failed to parse main dispatch switch command list")
    if not subcommand_usage_commands:
        failures.append("Failed to parse subcommandUsage switch command list")

    missing_help_entries = sorted(dispatch_commands - subcommand_usage_commands)
    if missing_help_entries:
        failures.append(
            "Missing subcommandUsage entries for dispatch command(s): "
            + ", ".join(missing_help_entries)
        )

    # Regression checks for concrete help text that previously drifted from dispatch logic.
    for needle, message in [
        ('case "help":', "Missing subcommandUsage entry for help"),
        ("Usage: cmux help", "help subcommand usage text is missing"),
        ("Usage: cmux move-workspace-to-window --workspace <id|ref|index> --window <id|ref|index>", "move-workspace-to-window help must document index handles"),
        ("--tab <id|ref|index>         Target tab (accepts tab:<n> or surface:<n>; default: $CMUX_TAB_ID, then $CMUX_SURFACE_ID, then focused tab)", "tab-action help must document CMUX_TAB_ID/CMUX_SURFACE_ID fallback"),
        ("--workspace <id|ref|index>   Workspace to rename (default: current/$CMUX_WORKSPACE_ID)", "rename-workspace help must document CMUX_WORKSPACE_ID fallback"),
        ("text|html|value|count|box|styles|attr: [--selector <css> | <css>]", "browser get help must document --selector"),
        ("attr: [--attr <name> | <name>]", "browser get attr help must document --attr"),
        ("styles: [--property <name>]", "browser get styles help must document --property"),
        ("role: [--name <text>] [--exact] <role>", "browser find role help must document --name/--exact"),
        ("text|label|placeholder|alt|title|testid: [--exact] <text>", "browser find text-like help must document --exact"),
        ("nth: [--index <n> | <n>] [--selector <css> | <css>]", "browser find nth help must document --index/--selector"),
        ("route <pattern> [--abort] [--body <text>]", "browser network route help must document --abort/--body"),
    ]:
        require(content, needle, message, failures)

    if failures:
        print("FAIL: CLI subcommand help regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: CLI subcommand help coverage and flag/env documentation are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
