#!/usr/bin/env python3
"""Regression test: `cmux tree` command wiring and output contract."""

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
    controller_path = repo_root / "Sources" / "TerminalController.swift"
    if not cli_path.exists():
        print(f"FAIL: missing expected file: {cli_path}")
        return 1
    if not controller_path.exists():
        print(f"FAIL: missing expected file: {controller_path}")
        return 1

    content = cli_path.read_text(encoding="utf-8")
    controller_content = controller_path.read_text(encoding="utf-8")
    failures: list[str] = []

    require(
        content,
        'case "tree":\n            try runTreeCommand(commandArgs: commandArgs, client: client, jsonOutput: jsonOutput, idFormat: idFormat)',
        "Missing `tree` command dispatch",
        failures,
    )
    require(
        content,
        "tree [--all] [--workspace <id|ref|index>]",
        "Top-level usage text missing tree command",
        failures,
    )
    require(
        content,
        "Usage: cmux tree [flags]",
        "Subcommand help for `cmux tree --help` is missing",
        failures,
    )
    require(
        content,
        "Known flags: --all --workspace <id|ref|index> --json",
        "Tree flag validation for --all/--workspace is missing",
        failures,
    )
    require(
        content,
        "--json                        Structured JSON output",
        "Tree help text should document --json",
        failures,
    )
    require(
        content,
        'print(jsonString(formatIDs(payload, mode: idFormat)))',
        "Tree command JSON output should honor --id-format conversion",
        failures,
    )

    # Data sources needed for full hierarchy + browser URLs.
    for method in [
        'method: "system.tree"',
        'method: "system.identify"',
        'method: "window.list"',
        'method: "workspace.list"',
        'method: "pane.list"',
        'method: "surface.list"',
        'method: "browser.tab.list"',
        'method: "browser.url.get"',
    ]:
        require(
            content,
            method,
            f"Tree command is missing expected API call: {method}",
            failures,
        )

    # Text tree rendering contract.
    for glyph in ['"├── "', '"└── "', '"│   "']:
        require(
            content,
            glyph,
            f"Tree output missing box-drawing glyph: {glyph}",
            failures,
        )

    for marker in ["[current]", "[selected]", "[focused]", "◀ active", "◀ here"]:
        require(
            content,
            marker,
            f"Tree output missing required marker: {marker}",
            failures,
        )

    require(
        content,
        'surfaceType.lowercased() == "browser"',
        "Tree surface rendering should special-case browser surfaces",
        failures,
    )
    require(
        content,
        'let url = surface["url"] as? String',
        "Tree surface rendering should include browser URL when available",
        failures,
    )

    # Server-side one-shot hierarchy path for performance.
    for needle, message in [
        ('case "system.tree":', "Socket router is missing system.tree dispatch"),
        ('"system.tree"', "Capabilities list should advertise system.tree"),
        ("private func v2SystemTree(params: [String: Any]) -> V2CallResult {", "Missing v2SystemTree implementation"),
        ('"active":', "system.tree payload should include focused path"),
        ('"caller":', "system.tree payload should include caller path"),
        ('"windows":', "system.tree payload should include hierarchy windows"),
    ]:
        require(controller_content, needle, message, failures)

    if failures:
        print("FAIL: cmux tree command regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: cmux tree command wiring and output contract are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
