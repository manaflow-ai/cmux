#!/usr/bin/env python3
"""Close the issues a pull request merged into feat-cmux-next says it fixes.

GitHub closes an issue from a closing keyword ("Fixes #123") only when the pull request merges into the
repository's default branch. manaflow-ai/cmux's default branch is main, and most work merges into
feat-cmux-next, so those issues stayed open after their fix landed. The workflow
.github/workflows/cmux-next-closes-issues.yml runs this on every merged pull request into feat-cmux-next:

    python3 scripts/ci/next_closes_issues.py --event "$GITHUB_EVENT_PATH" --repo "$GITHUB_REPOSITORY"

It reads the pull request's title and body the way GitHub does: the keywords close, closes, closed, fix,
fixes, fixed, resolve, resolves, resolved (any case, an optional colon), each followed by one ref to this
repository (#N, OWNER/REPO#N or https://github.com/OWNER/REPO/issues/N). Refs inside HTML comments (the pull
request template's example) and code are not refs. Each referenced item that is an open issue gets one
comment naming the pull request and its merge commit, and is closed as completed. Pull requests, closed
issues and missing numbers are skipped. `--dry-run` reads and prints, and changes nothing.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass, field
from typing import Any, List, Optional

BASE = "feat-cmux-next"

_KEYWORD = r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)"
_REF = (
    r"(?:https?://github\.com/(?P<url_repo>[\w.-]+/[\w.-]+)/issues/(?P<url_number>\d+)"
    r"|(?P<repo>[\w.-]+/[\w.-]+)?#(?P<number>\d+))"
)
CLOSING = re.compile(rf"(?<![\w/#-]){_KEYWORD}:?[ \t]+{_REF}(?![\w-])", re.IGNORECASE)

_HTML_COMMENT = re.compile(r"<!--.*?(?:-->|\Z)", re.DOTALL)
_FENCE = re.compile(r"^[ \t]*(```|~~~).*?(?:^[ \t]*\1[^\n]*$|\Z)", re.DOTALL | re.MULTILINE)
_INLINE_CODE = re.compile(r"(`+).+?\1", re.DOTALL)


def _prose(text: str) -> str:
    """The text with HTML comments, fenced code blocks and inline code cut out."""
    text = _HTML_COMMENT.sub(" ", text)
    text = _FENCE.sub(" ", text)
    return _INLINE_CODE.sub(" ", text)


def closing_refs(text: Optional[str], repo: str) -> List[int]:
    """The issue numbers in this repository that `text` closes, in order, each once."""
    found: List[int] = []
    for match in CLOSING.finditer(_prose(text or "")):
        named = match.group("url_repo") or match.group("repo")
        if named and named.lower() != repo.lower():
            continue
        number = int(match.group("url_number") or match.group("number"))
        if number not in found:
            found.append(number)
    return found


@dataclass
class Plan:
    pull: int = 0
    sha: str = ""
    issues: List[int] = field(default_factory=list)
    skip: Optional[str] = None

    @property
    def comment(self) -> str:
        return f"Fixed on {BASE} by #{self.pull} ({self.sha})."


def plan(event: dict, repo: str) -> Plan:
    pr = event.get("pull_request") or {}
    result = Plan(pull=int(pr.get("number") or 0), sha=str(pr.get("merge_commit_sha") or ""))
    base = (pr.get("base") or {}).get("ref")
    head_repo = ((pr.get("head") or {}).get("repo") or {}).get("full_name") or ""
    if not pr.get("merged"):
        result.skip = "the pull request closed but was not merged"
    elif base != BASE:
        result.skip = f"the pull request merged into {base}, not {BASE}; GitHub closes main's issues itself"
    elif head_repo.lower() != repo.lower():
        result.skip = f"the pull request came from the fork {head_repo or '(deleted)'}, whose run has a read-only token"
    if result.skip:
        return result
    text = f"{pr.get('title') or ''}\n{pr.get('body') or ''}"
    result.issues = [n for n in closing_refs(text, repo) if n != result.pull]
    return result


class GitHub:
    """The two calls this needs, through the gh CLI (GH_TOKEN from the workflow)."""

    def __init__(self, repo: str):
        self.repo = repo

    def _gh(self, *args: str) -> subprocess.CompletedProcess:
        return subprocess.run(["gh", "api", *args], capture_output=True, text=True, timeout=60)

    def issue(self, number: int) -> Optional[dict]:
        done = self._gh(f"repos/{self.repo}/issues/{number}")
        if done.returncode != 0:
            if "Not Found" in done.stderr or "HTTP 404" in done.stderr or "HTTP 410" in done.stderr:
                return None
            raise RuntimeError(f"reading #{number}: {done.stderr.strip()}")
        return json.loads(done.stdout)

    def close(self, number: int, comment: str) -> None:
        for args in (
            ("-X", "POST", f"repos/{self.repo}/issues/{number}/comments", "-f", f"body={comment}"),
            ("-X", "PATCH", f"repos/{self.repo}/issues/{number}", "-f", "state=closed", "-f", "state_reason=completed"),
        ):
            done = self._gh(*args)
            if done.returncode != 0:
                raise RuntimeError(f"closing #{number}: {done.stderr.strip()}")


def run(the_plan: Plan, github: Any, dry_run: bool) -> List[int]:
    """Close each open issue in the plan; return the numbers closed (or that would be, on a dry run)."""
    closed: List[int] = []
    for number in the_plan.issues:
        item = github.issue(number)
        if item is None:
            print(f"#{number}: no such issue, skipped")
            continue
        if "pull_request" in item:
            print(f"#{number}: a pull request, not an issue, skipped")
            continue
        if item.get("state") != "open":
            print(f"#{number}: already {item.get('state')}, skipped")
            continue
        if not dry_run:
            github.close(number, the_plan.comment)
        print(f"#{number}: {'would close' if dry_run else 'closed'} ({the_plan.comment})")
        closed.append(number)
    return closed


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--event", default=os.environ.get("GITHUB_EVENT_PATH", ""), help="the pull_request event JSON")
    parser.add_argument("--repo", default=os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"))
    parser.add_argument("--dry-run", action="store_true", help="read and print, change nothing")
    args = parser.parse_args(argv)
    if not args.event:
        parser.error("--event (or GITHUB_EVENT_PATH) is required")
    with open(args.event, encoding="utf-8") as handle:
        event = json.load(handle)
    the_plan = plan(event, args.repo)
    if the_plan.skip:
        print(f"nothing to close: {the_plan.skip}")
        return 0
    if not the_plan.issues:
        print(f"#{the_plan.pull} names no issue with a closing keyword")
        return 0
    try:
        run(the_plan, GitHub(args.repo), args.dry_run)
    except RuntimeError as error:
        print(f"::error::{error}")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
