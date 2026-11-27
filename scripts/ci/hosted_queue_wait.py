#!/usr/bin/env python3
"""Whether GitHub-hosted Ubuntu is slow to start this run's jobs, for the nightly signer route.

The signer jobs take hosted Ubuntu on attempt 1 (tests/test_ci_self_hosted_guard.sh's signer route).
A job can't be moved once it is queued without cancelling the started nightly, so the route is chosen
before they queue: decide and pick-nightly-sign-runner each read how long hosted took to start them,
and a wait over THRESHOLD_SECONDS sends the jobs after them to their Blacksmith Linux re-run route on
attempt 1 too. Run 41684606067 waited 6.8 min for the pick and 9.3 min for signer-app.

Outputs `hosted_slow` (true/false), `hosted_wait_s` and `slow_runner`: when slow, RUNNER_POOLS's linux_4
label (the smallest Blacksmith size the light jobs fit), which decide's hosted light jobs read as their
picker output before hosted Ubuntu; else empty. A job that did not run on hosted Ubuntu, or any read that
fails, passes INHERITED_SLOW on: it never fails the job.

Env: GH_TOKEN, GITHUB_REPOSITORY, GITHUB_RUN_ID, GITHUB_RUN_ATTEMPT, RUNNER_NAME, RUNNER_ENVIRONMENT,
JOB_NAME, INHERITED_SLOW, THRESHOLD_SECONDS (default 120), RUNNER_POOLS, GITHUB_OUTPUT.
"""
from __future__ import annotations

import datetime as dt
import json
import os
import sys
import urllib.request
from typing import Any, Mapping, Sequence

THRESHOLD_SECONDS = 120


def parse(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def own_wait(jobs: Sequence[Mapping[str, Any]], name: str, runner: str) -> float | None:
    """Seconds this job queued: the one job of NAME this runner took."""
    mine = [job for job in jobs if job.get("name") == name and job.get("runner_name") == runner
            and job.get("created_at") and job.get("started_at")]
    if len(mine) != 1:
        return None
    return (parse(mine[0]["started_at"]) - parse(mine[0]["created_at"])).total_seconds()


def decide(env: Mapping[str, str], jobs: Sequence[Mapping[str, Any]] | None) -> tuple[bool, float | None]:
    inherited = env.get("INHERITED_SLOW") == "true"
    if env.get("RUNNER_ENVIRONMENT") != "github-hosted" or jobs is None:
        return inherited, None
    wait = own_wait(jobs, env.get("JOB_NAME", ""), env.get("RUNNER_NAME", ""))
    if wait is None:
        return inherited, None
    threshold = int(env["THRESHOLD_SECONDS"]) if (env.get("THRESHOLD_SECONDS") or "").isdigit() else THRESHOLD_SECONDS
    return wait > threshold, wait


def slow_runner(env: Mapping[str, str], slow: bool) -> str:
    """The light jobs' runner off a slow hosted start: RUNNER_POOLS's linux_4 label, or empty."""
    if not slow:
        return ""
    try:
        label = json.loads(env.get("RUNNER_POOLS") or "{}").get("linux_4", "")
    except (ValueError, AttributeError):
        return ""
    return label if isinstance(label, str) and label.startswith("blacksmith-") and "ubuntu" in label else ""


def read_jobs(env: Mapping[str, str]) -> list[dict[str, Any]] | None:
    url = (f"https://api.github.com/repos/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}"
           f"/attempts/{env['GITHUB_RUN_ATTEMPT']}/jobs?per_page=100")
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {env['GH_TOKEN']}",
                                                   "Accept": "application/vnd.github+json"})
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response).get("jobs")


def main(env: Mapping[str, str] = os.environ) -> int:
    try:
        jobs = read_jobs(env) if env.get("RUNNER_ENVIRONMENT") == "github-hosted" else None
    except Exception as error:  # A failed read keeps the inherited route; it never fails the job.
        print(f"hosted-queue-wait: could not read this run's jobs: {error}", file=sys.stderr)
        jobs = None
    slow, wait = decide(env, jobs)
    print(f"hosted-queue-wait: hosted_slow={str(slow).lower()} wait={'unknown' if wait is None else f'{wait:.0f} s'}")
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"hosted_slow={str(slow).lower()}\nhosted_wait_s={'' if wait is None else int(wait)}\n"
                         f"slow_runner={slow_runner(env, slow)}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
