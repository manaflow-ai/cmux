#!/usr/bin/env python3
"""Warn when a bug-fix PR body has no Observed / Not run proof section.

Run via scripts/gh-merge-green with the PR metadata JSON (title, body,
labels) on stdin. A bug-fix PR states the focused command that failed on the
base and passes on the head, then splits what was run and seen ("Observed")
from what was only read or left unrun ("Not run"). This prints one warning
line when a bug-fix PR lacks that section and nothing otherwise. It never
blocks a merge: it always exits 0, including on unreadable input.

A PR is a bug fix when its title starts with a `fix` conventional-commit
type (`fix:`, `fix(scope):`, `fix!:`), the word "Fix", or it carries the
`bug` label. The section is any Markdown heading or bold line that starts
with "Observed".
"""
from __future__ import annotations

import json
import re
import sys

FIX_TITLE = re.compile(r"^\s*(?:(?:bug|hot)?fix(?:\([^)]*\))?!?:|fix(?:es|ed)?\b)", re.IGNORECASE)
OBSERVED = re.compile(r"^\s{0,3}(?:#{1,6}\s*|\*\*\s*)Observed\b", re.IGNORECASE | re.MULTILINE)
COMMENT = re.compile(r"<!--.*?-->", re.DOTALL)


def is_bug_fix(pr: dict) -> bool:
    if FIX_TITLE.match(pr.get("title") or ""):
        return True
    return any((label.get("name") or "").lower() == "bug" for label in pr.get("labels") or [])


def has_proof_section(body: str) -> bool:
    return bool(OBSERVED.search(COMMENT.sub("", body or "")))


def warning(pr: dict) -> str | None:
    if "body" not in pr or not is_bug_fix(pr) or has_proof_section(pr.get("body") or ""):
        return None
    return (
        "warning: bug-fix PR body has no \"Observed / Not run\" section; state the focused "
        "command that failed on the base and passes on the head, then what ran and what did not "
        "(CLAUDE.md, CI, review and merge). Not blocking."
    )


def main() -> int:
    try:
        pr = json.load(sys.stdin)
    except (ValueError, OSError):
        return 0
    if isinstance(pr, dict):
        message = warning(pr)
        if message:
            print(message, file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
