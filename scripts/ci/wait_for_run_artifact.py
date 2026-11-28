#!/usr/bin/env python3
"""Wait inside a job until another job of the same run uploads an artifact.

    wait_for_run_artifact.py --name <artifact> --job <producer job name> [--interval 10] [--deadline 2400]

A short macOS job that `needs:` its producer is queued only when the producer ends, so it pays the
whole runner pickup after it. On the saturated Blacksmith macOS 26 labels that pickup was 8-10 min
for nightly.yml's verify-signed-nightly (runs 46092619778, 46095010445: signing ended 02:21:36Z and
02:18:44Z, verify started 02:29:40Z and 02:28:12Z), longer than the job itself and than the
signing step it waited for. Queued beside its producer instead, the job spends its pickup while the
producer works and waits here only for the rest.

Exit 0 once the run lists an unexpired artifact named --name. Exit 1 when the job named --job has
completed and the artifact is still absent (the producer failed before its upload or was skipped),
or at --deadline. A read that fails is retried until --deadline; it never counts as either outcome.

Needs GH_TOKEN with actions:read, GITHUB_REPOSITORY and GITHUB_RUN_ID (and GITHUB_API_URL on GHES).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Optional


def api_get(path: str) -> Any:
    base = os.environ.get("GITHUB_API_URL", "https://api.github.com").rstrip("/")
    request = urllib.request.Request(
        f"{base}/{path}",
        headers={
            "Authorization": f"Bearer {os.environ['GH_TOKEN']}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=20) as response:
        return json.load(response)


def artifact_present(get: Callable[[str], Any], repo: str, run_id: str, name: str) -> bool:
    query = urllib.parse.urlencode({"name": name, "per_page": 100})
    body = get(f"repos/{repo}/actions/runs/{run_id}/artifacts?{query}")
    return any(a.get("name") == name and not a.get("expired") for a in body.get("artifacts", []))


def job_conclusion(get: Callable[[str], Any], repo: str, run_id: str, job: str) -> Optional[str]:
    """The named job's conclusion once it completed; None while it has not (or is not listed yet)."""
    page = 1
    while True:
        body = get(f"repos/{repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100&page={page}")
        jobs = body.get("jobs", [])
        for entry in jobs:
            if entry.get("name") == job and entry.get("status") == "completed":
                return entry.get("conclusion") or "unknown"
        if len(jobs) < 100:
            return None
        page += 1


def wait(
    name: str,
    job: str,
    *,
    repo: str,
    run_id: str,
    interval: float,
    deadline: float,
    get: Callable[[str], Any] = api_get,
    sleep: Callable[[float], None] = time.sleep,
    clock: Callable[[], float] = time.monotonic,
) -> int:
    start = clock()
    while True:
        try:
            if artifact_present(get, repo, run_id, name):
                print(f"wait_for_run_artifact: {name} is uploaded ({clock() - start:.0f} s)")
                return 0
            done = job_conclusion(get, repo, run_id, job)
            # The producer may finish between the two reads: look once more before giving up.
            if done is not None and not artifact_present(get, repo, run_id, name):
                print(f"::error::{job} ended ({done}) without uploading {name}", file=sys.stderr)
                return 1
        except (urllib.error.URLError, OSError, ValueError, KeyError) as error:
            print(f"wait_for_run_artifact: read failed, retrying: {error}", file=sys.stderr)
        if clock() - start >= deadline:
            print(f"::error::{name} was not uploaded within {deadline:.0f} s", file=sys.stderr)
            return 1
        sleep(interval)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--name", required=True)
    parser.add_argument("--job", required=True)
    parser.add_argument("--interval", type=float, default=10)
    parser.add_argument("--deadline", type=float, default=2400)
    args = parser.parse_args(argv)
    return wait(
        args.name,
        args.job,
        repo=os.environ["GITHUB_REPOSITORY"],
        run_id=os.environ["GITHUB_RUN_ID"],
        interval=args.interval,
        deadline=args.deadline,
    )


if __name__ == "__main__":
    sys.exit(main())
