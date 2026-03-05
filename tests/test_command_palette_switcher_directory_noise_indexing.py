#!/usr/bin/env python3
"""Regression test for command-palette switcher directory metadata indexing."""

from __future__ import annotations

import re
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


def expect_regex(content: str, pattern: str, message: str, failures: list[str]) -> None:
    if re.search(pattern, content, flags=re.DOTALL) is None:
        failures.append(message)


def main() -> int:
    repo_root = get_repo_root()
    content_view_path = repo_root / "Sources" / "ContentView.swift"
    if not content_view_path.exists():
        print(f"Missing expected file: {content_view_path}")
        return 1

    content = content_view_path.read_text(encoding="utf-8")
    failures: list[str] = []

    expect_regex(
        content,
        r"let abbreviated = homeRelativePathForSearch\(canonicalPath: canonical\)\s*\?\?\s*\(canonical as NSString\)\.abbreviatingWithTildeInPath",
        "directory indexing should prefer a home-relative path before tilde abbreviation",
        failures,
    )
    expect_regex(
        content,
        r"private static func homeRelativePathForSearch\(",
        "missing homeRelativePathForSearch helper",
        failures,
    )
    expect_regex(
        content,
        r"private static func directorySegmentTokensForSearch\(",
        "missing directorySegmentTokensForSearch helper",
        failures,
    )
    expect_regex(
        content,
        r"let maxSegments = includeAllSegments \? 4 : 2",
        "directory segment indexing should cap indexed path depth",
        failures,
    )

    fn_match = re.search(
        r"private static func directoryTokensForSearch\([^)]*\)\s*->\s*\[String\]\s*\{(.*?)\n    \}\n\n    private static func homeRelativePathForSearch",
        content,
        flags=re.DOTALL,
    )
    if fn_match is None:
        failures.append("could not locate directoryTokensForSearch function body")
    else:
        function_body = fn_match.group(1)
        workspace_match = re.search(
            r"case \.workspace:(.*?)case \.surface:",
            function_body,
            flags=re.DOTALL,
        )
        if workspace_match is None:
            failures.append("could not locate workspace branch in directoryTokensForSearch")
        else:
            workspace_body = workspace_match.group(1)
            if "trimmed" in workspace_body or "canonical" in workspace_body:
                failures.append("workspace branch should not directly index raw/canonical full directory paths")

        surface_match = re.search(
            r"case \.surface:(.*)$",
            function_body,
            flags=re.DOTALL,
        )
        if surface_match is None:
            failures.append("could not locate surface branch in directoryTokensForSearch")
        else:
            surface_body = surface_match.group(1)
            if "canonical" in surface_body and "abbreviated" not in surface_body:
                failures.append("surface branch should index normalized abbreviated/home-relative metadata")

    if failures:
        print("FAIL: switcher directory metadata indexing regression(s) detected")
        for failure in failures:
            print(f"- {failure}")
        return 1

    print("PASS: switcher directory metadata indexing avoids home-root noise")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
