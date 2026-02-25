#!/usr/bin/env python3
"""Regression test: sidebar context menu shows Copy SSH Error only when an SSH error exists."""

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
    content_view_path = repo_root / "Sources" / "ContentView.swift"
    if not content_view_path.exists():
        print(f"FAIL: missing expected file: {content_view_path}")
        return 1

    content = content_view_path.read_text(encoding="utf-8")
    failures: list[str] = []

    require(
        content,
        "private var copyableSidebarSSHError: String?",
        "Missing sidebar SSH error extraction helper",
        failures,
    )
    require(
        content,
        'tab.statusEntries["remote.error"]?.value',
        "Missing remote.error status fallback for copyable SSH error text",
        failures,
    )
    require(
        content,
        "if let copyableSidebarSSHError {",
        "Copy SSH Error menu entry is no longer conditionally gated",
        failures,
    )
    require(
        content,
        'Button("Copy SSH Error")',
        "Missing Copy SSH Error context menu button",
        failures,
    )
    require(
        content,
        "copyTextToPasteboard(copyableSidebarSSHError)",
        "Copy SSH Error button no longer writes the resolved error text",
        failures,
    )

    if failures:
        print("FAIL: sidebar copy SSH error context-menu regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: sidebar Copy SSH Error context menu wiring is intact")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
