#!/usr/bin/env python3
"""Warn when a UI pull request does not carry its review verdict.

This check is deliberately advisory. It always exits successfully: the review
section is a prompt for reviewers, never a merge gate.
"""
from __future__ import annotations

import argparse
import json
import re
import subprocess
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
# A reviewer tries the change before reading the diff: the body names the command that opens this pull
# request in a copy of cmux NEXT (scripts/cmux-next/try-pr.sh, or `cmux app try`), or says why not.
TRY = re.compile(r"(?im)^\s*Try:\s*\S")


# Any of these already names a way to open the change, so the body needs no added line.
TRY_MENTION = re.compile(r"(?i)cmux app try|try-pr\.sh|cmux customize use pr:")
# Marks the line risk-tier.yml writes, so an edit of the body can tell it apart from the author's text.
ADDED_MARK = "<!-- try line: added by CI for a UI change; edit it, or write `Try: none, <why>` -->"


def try_line(pr: str | None) -> str:
    """The `Try:` line a UI pull request's body carries."""
    n = pr if pr and pr.isdigit() else "N"
    return f"Try: `cmux app try {n}` (from a checkout: `scripts/cmux-next/try-pr.sh {n}`)"


def with_try_line(body: str | None, files: Iterable[Any], pr: str | None) -> str | None:
    """The body with this pull request's `Try:` line added, or None when it needs none: it changes no UI,
    or already has a `Try:` line or another try command. It adds, never refuses."""
    text = body or ""
    if not ui_files(files) or TRY.search(text) or TRY_MENTION.search(text):
        return None
    return f"{text.rstrip()}\n\n{ADDED_MARK}\n{try_line(pr)}\n"


def gh(*args: str, stdin: str | None = None) -> str:
    return subprocess.run(["gh", *args], input=stdin, capture_output=True, text=True, check=True, timeout=60).stdout


def add_try_line(repo: str, pr: str, files: list[Any], event_body: str | None) -> str:
    """Write the `Try:` line into a UI pull request's body. The event's body decides whether to read the
    live one: most pull requests need nothing, so they cost no call. The live body is read just before
    the write, so an edit made since the event is kept, not overwritten."""
    if with_try_line(event_body, files, pr) is None:
        return "try line: not needed"
    live = json.loads(gh("api", f"repos/{repo}/pulls/{pr}")).get("body")
    body = with_try_line(live, files, pr)
    if body is None:
        return "try line: already present"
    gh("api", "-X", "PATCH", f"repos/{repo}/pulls/{pr}", "--input", "-", stdin=json.dumps({"body": body}))
    return f"try line: added `{try_line(pr)}`"


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
    if not TRY.search(body or ""):
        missing.append("a `Try:` line")
    return missing


def inspect(body: str, files: Iterable[Any]) -> dict[str, Any]:
    touched = ui_files(files)
    missing = missing_parts(body) if touched else []
    return {"touched": touched, "missing": missing, "warning": bool(missing)}


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--body-file", type=Path, required=True)
    parser.add_argument("--files-json", type=Path, required=True)
    parser.add_argument("--pr", help="the pull request number, for the suggested `Try:` line")
    parser.add_argument("--add-try", metavar="REPO",
                        help="write the `Try:` line into this UI pull request's body (needs --pr and GH_TOKEN)")
    args = parser.parse_args(argv)
    if args.add_try:
        try:
            files = json.loads(args.files_json.read_text(encoding="utf-8"))
            body = args.body_file.read_text(encoding="utf-8")
            print(add_try_line(args.add_try, args.pr or "", files if isinstance(files, list) else [], body))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            # The line is a convenience: a failed read or write never fails the job.
            print(f"::warning title=UI review::could not add the try line: {error}")
        return 0
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
        hint = f"; add `{try_line(args.pr)}` (or `Try: none, <why>`)" if "a `Try:` line" in result["missing"] else ""
        print(f"::warning title=UI review::{missing} is missing for {paths}{hint}")
    else:
        print("UI review advisory: no missing review fields")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
