#!/usr/bin/env python3
"""The verdict so far of pr-pipeline.yml's `ios macos` job, read by the `ios` job's ios-kit step.

The kit's macOS `swift test` (ci/steps.toml's ios-kit-macos) runs in a job of its own, beside the `ios` job's
simulator leg (ios-kit), so the two legs no longer wait on each other. Before the split a red macOS run skipped the
simulator leg and the phone cells after it, and turned `ios` red. ios-kit keeps that rule: it asks this script once
before the simulator starts and once after it ends, and a red macOS leg skips the simulator (or fails the step) as
before, so `pr pipeline / ios` stays red whenever the macOS leg it used to hold is.

Prints one word: `failure` (the `ios macos` job of this run attempt concluded red: failure, timed_out or
cancelled), `success`, `pending` (still running or queued) or `unknown` (no token, no run, no such job, or the API
did not answer). It always exits 0: an unread verdict runs the simulator leg, as a green one does, and the
`ios macos` check itself still holds the macOS result.

It reads the run from the env GitHub Actions sets (GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GITHUB_REPOSITORY,
GITHUB_API_URL) and GH_TOKEN, so the step's run text names none of them and its result is still reused
(scripts/ci/ci_steps.py EVENT_VARS).
"""

from __future__ import annotations

import json
import os
import sys
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import deadline_http  # noqa: E402

JOB = "ios macos"
RED = {"failure", "timed_out", "cancelled"}
DEADLINE_S = 20.0
PAGES = 5


def leg_job(jobs: list[dict]) -> dict | None:
    """The `ios macos` job: named alone, or `pr pipeline / ios macos` under pr-router.yml's caller job."""
    for job in jobs:
        name = str(job.get("name") or "")
        if name == JOB or name.endswith(f" / {JOB}"):
            return job
    return None


def verdict(job: dict | None) -> str:
    if job is None:
        return "unknown"
    if job.get("status") != "completed":
        return "pending"
    conclusion = job.get("conclusion")
    if conclusion in RED:
        return "failure"
    return "success" if conclusion == "success" else "unknown"


def read_jobs(env: dict, read) -> list[dict]:
    run, attempt, repo = env.get("GITHUB_RUN_ID"), env.get("GITHUB_RUN_ATTEMPT") or "1", env.get("GITHUB_REPOSITORY")
    if not run or not repo:
        return []
    jobs: list[dict] = []
    for page in range(1, PAGES + 1):
        got = read(f"/repos/{repo}/actions/runs/{run}/attempts/{attempt}/jobs?per_page=100&page={page}")
        batch = got.get("jobs") or []
        jobs += batch
        if leg_job(batch) is not None or len(batch) < 100:
            break
    return jobs


def state(env: dict, read=None) -> str:
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
    if read is None:
        if not token:
            return "unknown"
        api = env.get("GITHUB_API_URL") or "https://api.github.com"
        deadline = deadline_http.Deadline(DEADLINE_S)

        def read(path: str) -> dict:
            req = urllib.request.Request(f"{api}{path}", headers={
                "Accept": "application/vnd.github+json",
                "Authorization": f"Bearer {token}",
                "X-GitHub-Api-Version": "2022-11-28",
            })
            status, body, _ = deadline_http.request(req, deadline=deadline)
            if status != 200:
                raise RuntimeError(f"GET {path}: HTTP {status}")
            return json.loads(body)
    try:
        return verdict(leg_job(read_jobs(env, read)))
    except Exception as err:  # fail open: the `ios macos` check still holds the macOS verdict
        print(f"ios macos leg: unread ({err})", file=sys.stderr)
        return "unknown"


def main(argv: list[str]) -> int:
    if argv[1:] != ["state"]:
        print("usage: ios_macos_leg.py state", file=sys.stderr)
        return 2
    print(state(dict(os.environ)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
