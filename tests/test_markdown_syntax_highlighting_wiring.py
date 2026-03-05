#!/usr/bin/env python3
"""Regression checks for markdown syntax highlighting wiring."""

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
    markdown_view_path = repo_root / "Sources" / "Panels" / "MarkdownPanelView.swift"
    highlighter_path = repo_root / "Sources" / "Panels" / "MarkdownCodeSyntaxHighlighter.swift"
    pbxproj_path = repo_root / "GhosttyTabs.xcodeproj" / "project.pbxproj"
    resolved_path = (
        repo_root
        / "GhosttyTabs.xcodeproj"
        / "project.xcworkspace"
        / "xcshareddata"
        / "swiftpm"
        / "Package.resolved"
    )

    for path in [markdown_view_path, highlighter_path, pbxproj_path, resolved_path]:
        if not path.exists():
            print(f"FAIL: missing expected file: {path}")
            return 1

    markdown_view = markdown_view_path.read_text(encoding="utf-8")
    highlighter = highlighter_path.read_text(encoding="utf-8")
    pbxproj = pbxproj_path.read_text(encoding="utf-8")
    resolved = resolved_path.read_text(encoding="utf-8")
    failures: list[str] = []

    # Markdown view wiring.
    require(
        markdown_view,
        ".markdownCodeSyntaxHighlighter(cmuxCodeSyntaxHighlighter)",
        "Markdown panel view must apply markdownCodeSyntaxHighlighter",
        failures,
    )
    require(
        markdown_view,
        "private var cmuxCodeSyntaxHighlighter: CodeSyntaxHighlighter",
        "Markdown panel view must expose a code syntax highlighter property",
        failures,
    )

    # Highlighter implementation contract.
    require(highlighter, "import Highlightr", "Highlighter implementation must import Highlightr", failures)
    require(
        highlighter,
        "struct CMUXMarkdownCodeSyntaxHighlighter: CodeSyntaxHighlighter",
        "Highlighter implementation must conform to CodeSyntaxHighlighter",
        failures,
    )
    require(
        highlighter,
        "highlightr.highlight(code, as: normalizedLanguage) ?? highlightr.highlight(code)",
        "Highlighter implementation must try fenced language then auto-detect",
        failures,
    )
    require(
        highlighter,
        'case "js":',
        "Highlighter should normalize common language aliases",
        failures,
    )

    # Xcode package wiring.
    for needle, message in [
        ('XCRemoteSwiftPackageReference "Highlightr"', "Project should include Highlightr package reference"),
        ('productName = Highlightr;', "Project should include Highlightr package product"),
        ('Highlightr in Frameworks', "GhosttyTabs target should link Highlightr"),
    ]:
        require(pbxproj, needle, message, failures)

    # Dependency versions.
    require(
        resolved,
        '"identity" : "highlightr"',
        "Package.resolved should pin Highlightr",
        failures,
    )
    require(
        resolved,
        '"version" : "2.3.0"',
        "Package.resolved should pin Highlightr to 2.3.0",
        failures,
    )
    require(
        resolved,
        '"identity" : "swift-markdown-ui"',
        "Package.resolved should include swift-markdown-ui",
        failures,
    )
    require(
        resolved,
        '"version" : "2.4.1"',
        "Package.resolved should keep swift-markdown-ui at 2.4.1",
        failures,
    )

    if failures:
        print("FAIL: markdown syntax-highlighting wiring regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: markdown syntax-highlighting wiring is present")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

