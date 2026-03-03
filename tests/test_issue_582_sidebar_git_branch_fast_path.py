#!/usr/bin/env python3
"""Regression guard for issue #582 (sidebar git branch updates stalling)."""

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


def extract_function(content: str, signature: str) -> str:
    start = content.find(signature)
    if start < 0:
        return ""
    brace = content.find("{", start)
    if brace < 0:
        return ""
    depth = 0
    for idx in range(brace, len(content)):
        ch = content[idx]
        if ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return content[start : idx + 1]
    return ""


def require(content: str, needle: str, message: str, failures: list[str]) -> None:
    if needle not in content:
        failures.append(message)


def main() -> int:
    repo_root = get_repo_root()
    terminal_controller_path = repo_root / "Sources" / "TerminalController.swift"
    if not terminal_controller_path.exists():
        print(f"Missing expected file: {terminal_controller_path}")
        return 1

    terminal_controller = terminal_controller_path.read_text(encoding="utf-8")
    report_body = extract_function(terminal_controller, "private func reportGitBranch(_ args: String) -> String")
    clear_body = extract_function(terminal_controller, "private func clearGitBranch(_ args: String) -> String")

    failures: list[str] = []

    if not report_body:
        failures.append("Unable to locate reportGitBranch implementation")
    if not clear_body:
        failures.append("Unable to locate clearGitBranch implementation")

    if report_body:
        require(
            report_body,
            "if let scope = Self.explicitSocketScope(options: parsed.options)",
            "reportGitBranch is missing explicit-scope fast path",
            failures,
        )
        require(
            report_body,
            "DispatchQueue.main.async",
            "reportGitBranch no longer schedules explicit-scope updates with main.async",
            failures,
        )
        require(
            report_body,
            "tab.updatePanelGitBranch(panelId: scope.panelId",
            "reportGitBranch fast path no longer writes branch state to the scoped panel",
            failures,
        )
        require(
            report_body,
            "DispatchQueue.main.sync",
            "reportGitBranch lost sync fallback path for non-explicit/manual calls",
            failures,
        )

    if clear_body:
        require(
            clear_body,
            "if let scope = Self.explicitSocketScope(options: parsed.options)",
            "clearGitBranch is missing explicit-scope fast path",
            failures,
        )
        require(
            clear_body,
            "DispatchQueue.main.async",
            "clearGitBranch no longer schedules explicit-scope clears with main.async",
            failures,
        )
        require(
            clear_body,
            "tab.clearPanelGitBranch(panelId: scope.panelId)",
            "clearGitBranch fast path no longer clears branch state for the scoped panel",
            failures,
        )
        require(
            clear_body,
            "DispatchQueue.main.sync",
            "clearGitBranch lost sync fallback path for non-explicit/manual calls",
            failures,
        )

    if failures:
        print("FAIL: issue #582 regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: issue #582 git branch socket fast path guards are present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
