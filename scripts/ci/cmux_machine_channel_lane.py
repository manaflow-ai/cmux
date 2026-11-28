#!/usr/bin/env python3
"""Pick a feat-cmux-next push's machine channel build lane: a free one, else the one that frees first (FREE_LANE).

`pick` prints a lane number in 0..LANES-1 for this run (.github/workflows/cmux-machine-channel.yml plan job).
Each target's build group is split by lane, so builds in different lanes run at once. Until cmux#60373's
follow-up the lane was run_number % 2, which sends a push to a lane whatever that lane is doing: with one build
running in each lane, a push waits for its own lane's build even when the other lane is idle or about to free, a
mean of half a build (about 7.5 min of a 15-min leg) against about a quarter for the sooner of two
(cmuxterm-hq goals/cloud-fix-to-machine.md, Ceiling, cut 3). Here the plan reads the in-flight runs of this
workflow on the ref, the x86_64 build call each lane holds (the leg the first point waits on; any of its jobs still
unfinished), and takes:

1. the lowest lane with no x86_64 build running or waiting, else
2. the lane whose running x86_64 build started first and that holds no waiting build (GitHub keeps one waiting
   job per group, and a newer push replaces it: a lane with one already waiting means this push replaces it, no
   worse than a lane with none), else
3. the lane whose running build started first.

A read that fails prints run_number % LANES, the old rule. Read-only: one runs read and one jobs read per in-flight
run (at most MAX_RUNS), on the plan job's App token (tests/test_ci_no_github_token_polling.py).
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Callable

LANES = 3
WORKFLOW = "cmux-machine-channel.yml"
MAX_RUNS = 12
# The x86_64 build call's display name carries its lane: "build-machine-channel x86_64 lane N / <callee job>".
LANE_MARK = "build-machine-channel x86_64 lane "
# A job that holds its lane's running slot: running, or queued for a runner. Any other unfinished status
# (pending, waiting, requested) is the group's waiting job.
HOLDS = frozenset(("in_progress", "queued"))

Api = Callable[[str], object]


def log(msg: str) -> None:
    print(f"lane: {msg}", file=sys.stderr)


def github_api(repo: str, token: str) -> Api:
    def get(path: str) -> object:
        req = urllib.request.Request(
            f"https://api.github.com/repos/{repo}/{path}",
            headers={"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"},
        )
        with urllib.request.urlopen(req, timeout=20) as r:
            return json.load(r)

    return get


def job_lane(name: str) -> int | None:
    """The lane of a build job by its name, or None for any other job."""
    if LANE_MARK not in name:
        return None
    rest = name.split(LANE_MARK, 1)[1]
    digits = rest.split(" ", 1)[0].split("/", 1)[0].strip()
    return int(digits) if digits.isdigit() else None


def occupancy(api: Api, ref: str, own_run: int) -> dict[int, tuple[str, bool]]:
    """Per lane: the start of its running x86_64 build ('' if none runs) and whether one waits."""
    branch = urllib.parse.quote(ref, safe="")
    runs = (api(f"actions/workflows/{WORKFLOW}/runs?branch={branch}&event=push&status=in_progress&per_page=30")
            or {}).get("workflow_runs", [])
    lanes: dict[int, tuple[str, bool]] = {}
    for run in sorted(runs, key=lambda r: r.get("id", 0), reverse=True)[:MAX_RUNS]:
        if run.get("id") == own_run:
            continue
        for job in (api(f"actions/runs/{run['id']}/jobs?per_page=100") or {}).get("jobs", []):
            lane = job_lane(job.get("name", ""))
            if lane is None or job.get("status") == "completed":
                continue
            started, waiting = lanes.get(lane, ("", False))
            if job.get("status") in HOLDS:
                mine = job.get("started_at") or job.get("created_at") or ""
                started = min(started, mine) if started and mine else (started or mine)
            else:
                waiting = True
            lanes[lane] = (started, waiting)
    return lanes


def choose(lanes: dict[int, tuple[str, bool]], count: int = LANES) -> int:
    free = [n for n in range(count) if n not in lanes or (not lanes[n][0] and not lanes[n][1])]
    if free:
        return free[0]
    running = [n for n in range(count) if lanes[n][0]]
    if not running:
        return 0  # every lane only waits (none started yet): any is as good
    clear = [n for n in running if not lanes[n][1]]
    return min(clear or running, key=lambda n: lanes[n][0])


def pick(api: Api, ref: str, own_run: int, run_number: int, count: int = LANES) -> int:
    try:
        lanes = occupancy(api, ref, own_run)
    except (urllib.error.URLError, OSError, ValueError, KeyError, TypeError) as exc:
        log(f"read failed ({exc}): run_number % {count}")
        return run_number % count
    lane = choose(lanes, count)
    log(f"lanes {json.dumps({str(k): v for k, v in sorted(lanes.items())})}: lane {lane}")
    return lane


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("pick")
    p.add_argument("--lanes", type=int, default=LANES)
    args = ap.parse_args(argv)
    run_number = int(os.environ.get("GITHUB_RUN_NUMBER", "0") or 0)
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        log(f"no token: run_number % {args.lanes}")
        print(run_number % args.lanes)
        return 0
    api = github_api(os.environ.get("GITHUB_REPOSITORY", "manaflow-ai/cmux"), token)
    ref = os.environ.get("GITHUB_REF_NAME", "feat-cmux-next")
    print(pick(api, ref, int(os.environ.get("GITHUB_RUN_ID", "0") or 0), run_number, args.lanes))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
