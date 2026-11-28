#!/usr/bin/env python3
"""Read ci.yml's `macOS admission gate` once for macOS compile admission.

The gate judges the fast Linux jobs. Compile admission starts beside them and
reads the gate's result twice, never waiting for it:

  compile    before the compile. A declined gate stops the job here: every
             declined compile measured after #14314 went unused (0 of 12
             reused, 2026-09-25), and each one held a macOS runner for 5 to 40
             minutes. A gate still running compiles as before.
  consumers  after the product is published. A declined gate fails the job
             so no product consumer starts.

Only a completed gate that concluded `failure` declines. Running, skipped,
absent or unreadable admits: ci-status still fails the run on the failed
Linux job.
"""

from __future__ import annotations

import json
import os
import re
import sys
import urllib.request

MESSAGES = {
    "compile": (
        "Not compiling",
        "{gate} declined: a fast Linux job failed, so this job stops before compiling. "
        "Fix it and push, or re-run failed jobs to collect macOS results anyway.",
        "compiling",
    ),
    "consumers": (
        "Not admitting macOS consumers",
        "{gate} declined: a fast Linux job failed. The product compiled and was uploaded; "
        "re-run failed jobs to collect macOS results anyway.",
        "admitting macOS consumers",
    ),
}


def _next_page(link_header: str | None) -> str | None:
    """Return GitHub's RFC 8288 ``rel=next`` URL, if one is present."""
    if not link_header:
        return None
    for link in link_header.split(","):
        match = re.match(r"\s*<([^>]+)>\s*;\s*rel=\"?([^\";, ]+)", link)
        if match and match.group(2) == "next":
            return match.group(1)
    return None


def _read_jobs(request: urllib.request.Request) -> list[dict]:
    """Read all pages so a late-created gate job cannot be mistaken as absent."""
    jobs: list[dict] = []
    while request is not None:
        with urllib.request.urlopen(request, timeout=30) as response:
            payload = json.load(response)
            jobs.extend(payload.get("jobs", []))
            next_url = _next_page(response.headers.get("Link"))
        request = urllib.request.Request(next_url, headers=dict(request.header_items())) if next_url else None
    return jobs


def main(argv: list[str], env: dict[str, str]) -> int:
    if len(argv) != 1 or argv[0] not in MESSAGES:
        print(f"usage: fast_linux_gate.py {{{'|'.join(MESSAGES)}}}", file=sys.stderr)
        return 2
    title, declined, admitted = MESSAGES[argv[0]]
    gate = env["GATE_JOB"]
    url = (
        f"{env['API_URL'].rstrip('/')}/repos/{env['REPOSITORY']}"
        f"/actions/runs/{env['RUN_ID']}/jobs?filter=latest&per_page=100"
    )
    request = urllib.request.Request(url, headers={
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {env['GH_TOKEN']}",
        "User-Agent": "cmux-ci-compile-admission",
        "X-GitHub-Api-Version": "2022-11-28",
    })
    try:
        jobs = _read_jobs(request)
    except Exception as exc:  # An unreadable gate admits.
        print(f"::warning::Could not read {gate} ({exc}); {admitted}.")
        return 0
    found = [job for job in jobs if job.get("name") == gate]
    if not found:
        print(f"{gate} is not in this run; {admitted}.")
        return 0
    status, conclusion = found[0].get("status"), found[0].get("conclusion")
    if status == "completed" and conclusion == "failure":
        print(f"::error title={title}::{declined.format(gate=gate)}")
        return 1
    print(f"{gate}: status={status} conclusion={conclusion}; {admitted}.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:], dict(os.environ)))
