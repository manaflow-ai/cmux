#!/usr/bin/env python3
"""Picks and classifies the pull requests the cmux-next generated catch-up
(.github/workflows/cmux-next-generated-catch-up.yml) merges feat-cmux-next into.

The generated web bundles and strings tables (.gitattributes, merge driver
cmux-generated-v1) collide on nearly every feat-cmux-next move, and GitHub
ignores merge drivers, so each landed UI PR left the other open PRs
conflicting until someone merged the base and rebuilt them by hand. CI does
that now for a PR whose only conflicts are those files.

  generated_catch_up.py select --repo OWNER/REPO [--base BRANCH] [--limit N]
      JSON list of {number, branch, sha} to catch up, newest first.
  generated_catch_up.py authored --gitattributes FILE < unmerged-paths
      Prints the unmerged paths that are not generated; exits 1 when any are.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from typing import Any, Iterable

DRIVER = "cmux-generated-v1"
# At most this many PRs per base move: each one costs a bundle rebuild and a
# full PR CI run.
DEFAULT_LIMIT = 12
# GitHub computes mergeability lazily after a base move; a listing first
# answers UNKNOWN.
MERGEABLE_POLLS = 6
MERGEABLE_POLL_SECONDS = 20


def generated_patterns(gitattributes: str) -> list[str]:
    """The path patterns .gitattributes routes through the generated-file driver."""
    patterns = []
    for line in gitattributes.splitlines():
        fields = line.split()
        if fields and not fields[0].startswith("#") and f"merge={DRIVER}" in fields[1:]:
            patterns.append(fields[0])
    return patterns


def _regex(pattern: str) -> re.Pattern[str]:
    """A gitattributes pattern (`*`, `?`, `**`) as a regex over a repo path."""
    out, index = "", 0
    if "/" not in pattern:
        out = "(?:.*/)?"  # no slash: matches the basename at any depth
    while index < len(pattern):
        if pattern.startswith("**/", index):
            out, index = out + "(?:.*/)?", index + 3
        elif pattern.startswith("**", index):
            out, index = out + ".*", index + 2
        elif pattern[index] == "*":
            out, index = out + "[^/]*", index + 1
        elif pattern[index] == "?":
            out, index = out + "[^/]", index + 1
        else:
            out, index = out + re.escape(pattern[index]), index + 1
    return re.compile(out + r"\Z")


def is_generated(path: str, patterns: Iterable[str]) -> bool:
    return any(_regex(pattern).match(path) for pattern in patterns)


def authored(paths: Iterable[str], patterns: list[str]) -> list[str]:
    """The paths a rebuild cannot resolve."""
    return [path for path in paths if not is_generated(path, patterns)]


def select(prs: Iterable[dict[str, Any]], *, limit: int = DEFAULT_LIMIT) -> list[dict[str, Any]]:
    """Same-repository, ready, conflicting PRs, at most `limit`."""
    chosen = []
    for pr in prs:
        if pr.get("isDraft") or pr.get("isCrossRepository") or pr.get("mergeable") != "CONFLICTING":
            continue
        if pr.get("headRefName") in ("main", "feat-cmux-next"):
            continue
        chosen.append({"number": pr["number"], "branch": pr["headRefName"], "sha": pr["headRefOid"]})
        if len(chosen) >= limit:
            break
    return chosen


def _list(repo: str, base: str) -> list[dict[str, Any]]:
    out = subprocess.run(
        ["gh", "pr", "list", "--repo", repo, "--base", base, "--state", "open", "--limit", "200",
         "--json", "number,headRefName,headRefOid,isDraft,isCrossRepository,mergeable"],
        check=True, capture_output=True, text=True,
    ).stdout
    return json.loads(out)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    pick = commands.add_parser("select")
    pick.add_argument("--repo", required=True)
    pick.add_argument("--base", default="feat-cmux-next")
    pick.add_argument("--limit", type=int, default=DEFAULT_LIMIT)
    classify = commands.add_parser("authored")
    classify.add_argument("--gitattributes", required=True)
    args = parser.parse_args(argv)

    if args.command == "authored":
        with open(args.gitattributes, encoding="utf-8") as handle:
            patterns = generated_patterns(handle.read())
        found = authored([line.strip() for line in sys.stdin if line.strip()], patterns)
        for path in found:
            print(path)
        return 1 if found else 0

    prs = _list(args.repo, args.base)
    for _ in range(MERGEABLE_POLLS - 1):
        if not any(pr.get("mergeable") == "UNKNOWN" and not pr.get("isDraft") for pr in prs):
            break
        time.sleep(MERGEABLE_POLL_SECONDS)
        prs = _list(args.repo, args.base)
    print(json.dumps(select(prs, limit=args.limit)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
