#!/usr/bin/env python3
"""Regression tests for markdown-open CLI parsing/help behavior."""

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
    panel_path = repo_root / "Sources" / "Panels" / "MarkdownPanel.swift"

    if not cli_path.exists():
        print(f"FAIL: missing expected file: {cli_path}")
        return 1
    if not panel_path.exists():
        print(f"FAIL: missing expected file: {panel_path}")
        return 1

    cli_content = cli_path.read_text(encoding="utf-8")
    panel_content = panel_path.read_text(encoding="utf-8")
    failures: list[str] = []

    # CLI parser behavior.
    require(
        cli_content,
        'if let first = args.first, first.lowercased() == "open" {',
        "markdown parser should explicitly support the 'open' subcommand",
        failures,
    )
    require(
        cli_content,
        "args.count == 1",
        "markdown parser should accept single-arg shorthand path",
        failures,
    )
    require(
        cli_content,
        "args.count == 1, let first = args.first, !first.hasPrefix(\"-\")",
        "markdown parser should reject option-like single args from shorthand path mode",
        failures,
    )
    require(
        cli_content,
        "let trailingArgs = Array(subArgs.dropFirst())",
        "markdown parser should validate trailing arguments",
        failures,
    )
    require(
        cli_content,
        'trailingArgs.first(where: { $0.hasPrefix("-") })',
        "markdown parser should detect unknown trailing flags",
        failures,
    )
    require(
        cli_content,
        "markdown open: unexpected argument",
        "markdown parser should error on unexpected trailing args",
        failures,
    )

    # Help text should document shorthand and full index handle support.
    require(
        cli_content,
        "Usage: cmux markdown open <path> [options]\n                   cmux markdown <path>       (shorthand for 'open')",
        "markdown subcommand help should include shorthand usage",
        failures,
    )
    require(
        cli_content,
        "--window <id|ref|index>      Target window",
        "markdown subcommand help should document window index handles",
        failures,
    )
    require(
        cli_content,
        "markdown [open] <path>             (open markdown file in formatted viewer panel with live reload)",
        "top-level help should include markdown shorthand syntax",
        failures,
    )

    # Session restore edge case: file missing at startup should still attempt reconnect.
    require(
        panel_content,
        "if isFileUnavailable && fileWatchSource == nil {",
        "MarkdownPanel should schedule reattach when watcher cannot start at init",
        failures,
    )
    require(
        panel_content,
        "scheduleReattach(attempt: 1)",
        "MarkdownPanel should trigger reattach retries for missing files",
        failures,
    )

    if failures:
        print("FAIL: markdown-open regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: markdown-open CLI/help/reattach regression checks are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
