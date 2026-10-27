#!/usr/bin/env python3
"""Stop a nightly build job when a job publish-nightly needs has already failed.

    python3 scripts/ci/stop_if_publish_doomed.py JOB [JOB ...]

Reads this run attempt's jobs once (GITHUB_API_URL, GITHUB_REPOSITORY,
GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, GH_TOKEN) and exits 1, with an ::error
naming the job, when one of JOB concluded failure or cancelled: the run can
no longer publish, so the job gives its runner back instead of compiling or
uploading for nothing. Any other state, and any error reading the jobs, exits
0: the check never stops a run on missing data. One read per call, no retry,
no wait. tests/test_nightly_stop_if_publish_doomed.py derives JOB from the
needs graph of nightly.yml.
"""
from __future__ import annotations

import json
import os
import sys
import urllib.request


def jobs_of_attempt() -> list[dict]:
    api = os.environ.get("GITHUB_API_URL", "https://api.github.com")
    url = (f"{api}/repos/{os.environ['GITHUB_REPOSITORY']}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
           f"/attempts/{os.environ['GITHUB_RUN_ATTEMPT']}/jobs?per_page=100")
    request = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {os.environ['GH_TOKEN']}", "Accept": "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)["jobs"]


def main(watched: list[str]) -> int:
    if not watched:
        print("usage: stop_if_publish_doomed.py JOB [JOB ...]", file=sys.stderr)
        return 2
    try:
        jobs = jobs_of_attempt()
    except Exception as error:  # fail open: never stop on missing data
        print(f"::warning title=Publish check::could not read this run's jobs ({error}); carrying on")
        return 0
    for job in jobs:
        if job.get("name") in watched and job.get("conclusion") in ("failure", "cancelled"):
            print(f"::error title=Run cannot publish::{job['name']} {job['conclusion']} "
                  f"({job.get('html_url', '')}), and publish-nightly needs it; stopping here to free this runner")
            return 1
    states = {job.get("name"): job.get("conclusion") or job.get("status") for job in jobs if job.get("name") in watched}
    print(f"publish still possible: {states}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
