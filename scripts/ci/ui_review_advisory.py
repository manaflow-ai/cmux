#!/usr/bin/env python3
"""Warn when a UI pull request does not carry its review verdict.

This check is deliberately advisory. It always exits successfully: the review
section is a prompt for reviewers, never a merge gate.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any, Iterable


UI_PATHS = (
    re.compile(r"^webviews/src/.*\.(?:css|tsx)$"),
    # Native CmuxNext UI is Swift under the package Sources tree. Keep this
    # advisory broad: the review section is warning-only and the native UI
    # surface is split across several source modules.
    re.compile(r"^Packages/macOS/CmuxNext/Sources/.*\.swift$"),
)
HEADING = re.compile(r"(?im)^#{2,6}\s+UI review\s*$")
VERDICT = re.compile(r"(?im)^\s*Verdict:\s*(blocked|approve with changes|ship it)\s*$")


def ui_files(files: Iterable[Any]) -> list[str]:
    """Return changed webview or native CmuxNext UI paths, tolerating API or plain strings."""
    paths: list[str] = []
    for item in files:
        path = item if isinstance(item, str) else item.get("filename") if isinstance(item, dict) else None
        if isinstance(path, str) and any(pattern.fullmatch(path) for pattern in UI_PATHS):
            paths.append(path)
    return sorted(set(paths))


def missing_parts(body: str) -> list[str]:
    """Return the review fields absent from a pull-request body."""
    missing: list[str] = []
    if not HEADING.search(body or ""):
        missing.append("the `## UI review` heading")
    if not VERDICT.search(body or ""):
        missing.append("a `Verdict:` line")
    return missing


def inspect(body: str, files: Iterable[Any]) -> dict[str, Any]:
    touched = ui_files(files)
    missing = missing_parts(body) if touched else []
    return {"touched": touched, "missing": missing, "warning": bool(missing)}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--body-file", type=Path, required=True)
    parser.add_argument("--files-json", type=Path, required=True)
    args = parser.parse_args(argv)
    try:
        body = args.body_file.read_text(encoding="utf-8")
        files = json.loads(args.files_json.read_text(encoding="utf-8"))
        if not isinstance(files, list):
            raise ValueError("files JSON must be a list")
        result = inspect(body, files)
    except (OSError, ValueError, json.JSONDecodeError) as error:
        # An unavailable patch or body must not become a merge gate.
        result = {"touched": [], "missing": [], "warning": False, "error": str(error)}
    if result["warning"]:
        paths = ", ".join(f"`{path}`" for path in result["touched"])
        missing = " and ".join(result["missing"])
        print(f"::warning title=UI review::{missing} is missing for {paths}")
    else:
        print("UI review advisory: no missing review fields")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
