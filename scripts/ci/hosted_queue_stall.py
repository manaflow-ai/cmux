#!/usr/bin/env python3
"""Whether GitHub-hosted Ubuntu is stalled for this nightly run, read from the run's own jobs.

The signer jobs (signer-app, signer-dmg, the legacy pool signers) take GitHub-hosted
ubuntu-24.04 first and Blacksmith Linux 4 vCPU on a re-run. GitHub never re-routes a
queued job, and a started nightly is never cancelled, so a re-run cannot help a run that
is still going: in run 41683652930 (2026-11-03) pick-nightly-sign-runner waited 526 s and
signer-app 532 s on hosted Ubuntu, then signer-dmg and legacy-signer-app over 10 min each.

pick-nightly-sign-runner runs this right before those jobs queue. It reads the jobs of
this run attempt (one API request per hundred jobs) and calls hosted Ubuntu stalled when a job on
ubuntu-24.04 waited STALL_SECONDS or more before it started, or is still queued that
long. The pick's own job counts: it ran on hosted Ubuntu, so its own wait is a sample.
The signer jobs then take Blacksmith Linux 4 vCPU on this attempt, the route a re-run
already takes, so they never wait on a hosted queue that has stopped moving. A read that
fails leaves hosted Ubuntu as the route (the behaviour before this check).

    GH_TOKEN=<actions: read> GITHUB_REPOSITORY=o/r RUN_ID=N RUN_ATTEMPT=N hosted_queue_stall.py
    -> `hosted=stalled|moving|unknown` in $GITHUB_OUTPUT and why in the step summary
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import urllib.request
from typing import Any, Callable, Iterable, Mapping

HOSTED = "ubuntu-24.04"
# The fleet rule's stall-aware failover: about 3 minutes with no start.
STALL_SECONDS = 180


def parse(value: Any) -> dt.datetime | None:
    if not value:
        return None
    try:
        when = dt.datetime.fromisoformat(str(value).replace("Z", "+00:00"))
    except ValueError:
        return None
    return when if when.tzinfo else when.replace(tzinfo=dt.timezone.utc)


def hosted_waits(jobs: Iterable[Mapping[str, Any]], now: dt.datetime) -> list[tuple[str, int, bool]]:
    """(job name, seconds it waited for a runner, still queued) for each job on hosted Ubuntu alone."""
    out = []
    for job in jobs:
        if list(job.get("labels") or []) != [HOSTED]:
            continue
        created = parse(job.get("created_at"))
        if created is None:
            continue
        started = parse(job.get("started_at"))
        queued = job.get("status") == "queued"
        if not queued and started is None:
            continue  # held by an environment (`waiting`) or skipped: it never asked hosted Ubuntu for a runner
        end = now if queued else started
        if end < created:
            continue
        out.append((str(job.get("name") or ""), int((end - created).total_seconds()), queued))
    return out


def verdict(jobs: Iterable[Mapping[str, Any]], now: dt.datetime) -> tuple[str, str]:
    waits = hosted_waits(jobs, now)
    if not waits:
        return "moving", "no job of this run asked for hosted Ubuntu yet"
    name, seconds, queued = max(waits, key=lambda item: item[1])
    state = "is still queued" if queued else "waited"
    if seconds >= STALL_SECONDS:
        return "stalled", f"{name} {state} {seconds} s for hosted Ubuntu (stall at {STALL_SECONDS} s)"
    return "moving", f"the longest hosted Ubuntu wait in this run is {seconds} s ({name})"


def read_jobs(repo: str, run_id: str, attempt: str, token: str, pages: int = 3) -> list[dict[str, Any]]:
    jobs: list[dict[str, Any]] = []
    for page in range(1, pages + 1):
        url = (f"https://api.github.com/repos/{repo}/actions/runs/{run_id}/attempts/{attempt}/jobs"
               f"?per_page=100&page={page}")
        request = urllib.request.Request(url, headers={
            "Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-hosted-queue-stall/1"})
        with urllib.request.urlopen(request, timeout=15) as response:  # noqa: S310 - fixed api.github.com URL
            body = json.load(response)
        batch = list(body.get("jobs") or [])
        jobs.extend(batch)
        if len(batch) < 100 or len(jobs) >= int(body.get("total_count") or 0):
            break
    return jobs


def main(env: Mapping[str, str] = os.environ,
         read: Callable[[str, str, str, str], list[dict[str, Any]]] = read_jobs,
         now: Callable[[], dt.datetime] = lambda: dt.datetime.now(dt.timezone.utc)) -> int:
    run_id, attempt = env.get("RUN_ID", ""), env.get("RUN_ATTEMPT", "")
    if not (run_id.isdigit() and attempt.isdigit()):
        state, why = "unknown", "no valid run id or attempt"
    else:
        try:
            state, why = verdict(read(env.get("GITHUB_REPOSITORY", ""), run_id, attempt, env.get("GH_TOKEN", "")), now())
        except Exception as error:  # noqa: BLE001 - an unreadable run keeps the hosted route
            state, why = "unknown", f"could not read this run's jobs ({error.__class__.__name__}); hosted Ubuntu stays the route"
    route = "Blacksmith Linux 4 vCPU" if state == "stalled" else "hosted Ubuntu"
    line = f"hosted Ubuntu {state}: {why}; the signer jobs take {route}"
    print(line)
    if state == "stalled":
        print(f"::warning title=Hosted Ubuntu stalled::{line}")
    for name, text in (("GITHUB_OUTPUT", f"hosted={state}\n"), ("GITHUB_STEP_SUMMARY", f"- {line}\n")):
        path = env.get(name)
        if path:
            with open(path, "a", encoding="utf-8") as handle:
                handle.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
