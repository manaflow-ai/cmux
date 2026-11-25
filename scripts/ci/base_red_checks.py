#!/usr/bin/env python3
"""Classify push check-job reds against the immediately previous tip.

The checks job stays red for every red check; this only names, in annotations, which reds
the push added and which the previous tip already had (or had not finished), so the commit
that broke a check is the one told to fix it.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")
# The job-logs endpoint starts every line with its time, "2026-10-27T22:43:14.6689782Z ".
STAMP = re.compile(r"^\d{4}-\d\d-\d\dT[0-9:.]+Z ")
RED_LINE = re.compile(r"^- (.+?) \((?:failure|cancelled|timed_out|not run)\)$")
JOB_ID = re.compile(r"/job/(\d+)(?:$|[/?#])")
CHECKS_JOB = "cmux-next checks (god files, concurrency, crash safety, l10n)"
# Only these read as "not finished yet"; a missing or unknown status fails closed.
PENDING = {"queued", "in_progress", "waiting", "requested", "pending"}


def failed_names(text: str) -> set[str]:
    out = set()
    for line in ANSI.sub("", text).splitlines():
        match = RED_LINE.match(STAMP.sub("", line).strip())
        if match:
            out.add(match.group(1))
    return out


class DropAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    # The job-logs endpoint answers 302 to a signed blob URL on another host.
    # urllib carries the Authorization header along, and the blob store refuses
    # the request with 401 (push run 40596227506), so a token never leaves the
    # API host.
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        old, moved = urllib.parse.urlsplit(req.full_url), urllib.parse.urlsplit(newurl)
        if new is not None and (moved.scheme, moved.netloc) != (old.scheme, old.netloc):
            new.remove_header("Authorization")
        return new


def api(base: str, token: str, path: str):
    request = urllib.request.Request(
        base.rstrip("/") + path,
        headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json",
                 "X-GitHub-Api-Version": "2022-11-28"},
    )
    with urllib.request.build_opener(DropAuthOnRedirect).open(request, timeout=30) as response:
        return response.read()


def base_reds(repo: str, before: str, base: str, token: str) -> set[str] | None:
    # Asked for by name: a feat-cmux-next tip carries 250+ check runs, and the
    # unfiltered first page of 100 often left this job out ("no checks job").
    query = urllib.parse.urlencode({"check_name": CHECKS_JOB, "filter": "latest", "per_page": 100})
    payload = json.loads(api(base, token, f"/repos/{repo}/commits/{before}/check-runs?{query}"))
    runs = [r for r in payload.get("check_runs", []) if str(r.get("name", "")) == CHECKS_JOB]
    if not runs:
        raise RuntimeError("previous tip has no cmux-next checks job")
    # A push can start before the previous tip's checks job has finished.  Leo's
    # feat-cmux-next rule is that pending and queued base checks never block a
    # landing, so let the caller name this push's reds as inherited until
    # the next completed tip provides comparable evidence.
    status = runs[0].get("status")
    if status in PENDING:
        return None
    if status != "completed":
        raise RuntimeError(f"previous checks job has status {status!r}")
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
        print(f"base-red: previous tip {args.before} is still pending; current reds are named as inherited",
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
