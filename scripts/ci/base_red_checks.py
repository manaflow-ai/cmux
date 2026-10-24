#!/usr/bin/env python3
"""Classify push check-job reds against the immediately previous tip.

The checks job is warning-only for failures already present on the previous push;
missing or unreadable base evidence fails closed so a new red cannot be excused.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.request

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
RED_LINE = re.compile(r"^- (.+?) \((?:failure|cancelled|timed_out|not run)\)$")
JOB_ID = re.compile(r"/job/(\d+)(?:$|[/?#])")


def failed_names(text: str) -> set[str]:
    out = set()
    for line in ANSI.sub("", text).splitlines():
        match = RED_LINE.match(line.strip())
        if match:
            out.add(match.group(1))
    return out


def api(base: str, token: str, path: str):
    request = urllib.request.Request(
        base.rstrip("/") + path,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.read()


def base_reds(repo: str, before: str, base: str, token: str) -> set[str] | None:
    payload = json.loads(api(base, token, f"/repos/{repo}/commits/{before}/check-runs?filter=latest&per_page=100"))
    runs = [r for r in payload.get("check_runs", [])
            if str(r.get("name", "")).startswith("cmux-next checks (god files, concurrency, crash safety, l10n)")]
    if not runs:
        raise RuntimeError("previous tip has no cmux-next checks job")
    # A push can start before the previous tip's checks job has finished.  Leo's
    # feat-cmux-next rule is that pending and queued base checks never block a
    # landing, so let the caller classify this push's reds as warning-only until
    # the next completed tip provides comparable evidence.
    if runs[0].get("status") != "completed":
        return None
    details = runs[0].get("details_url", "")
    match = JOB_ID.search(details)
    if not match:
        raise RuntimeError("previous checks job has no Actions job URL")
    text = api(base, token, f"/repos/{repo}/actions/jobs/{match.group(1)}/logs").decode("utf-8", "replace")
    reds = failed_names(text)
    if not reds:
        # A completed green base is valid evidence; it simply excuses nothing.
        if runs[0].get("conclusion") == "success":
            return set()
        raise RuntimeError("previous checks job was red but exposed no failed-check list")
    return reds


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True)
    parser.add_argument("--before", required=True)
    parser.add_argument("--current", required=True)
    parser.add_argument("--api", default=os.environ.get("GITHUB_API_URL", "https://api.github.com"))
    args = parser.parse_args()
    current = {line.strip() for line in open(args.current) if line.strip()}
    try:
        previous = base_reds(args.repo, args.before, args.api, os.environ["GH_TOKEN"])
    except (KeyError, OSError, ValueError, RuntimeError, urllib.error.URLError) as error:
        print(f"base-red: unable to read previous tip {args.before}: {error}", file=sys.stderr)
        return 2
    if previous is None:
        print(f"base-red: previous tip {args.before} is still pending; current reds are warning-only",
              file=sys.stderr)
        for name in sorted(current):
            print(f"BASE_RED {name}")
        return 0
    for name in sorted(current):
        if name in previous:
            print(f"BASE_RED {name}")
        else:
            print(f"NEW_RED {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
