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
        with urllib.request.urlopen(request, timeout=30) as response:
            jobs = json.load(response).get("jobs", [])
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
