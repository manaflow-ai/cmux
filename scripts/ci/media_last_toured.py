#!/usr/bin/env python3
"""Pick the base of a nightly-tip media tour, and whether to tour now.

.github/workflows/cmux-next-media.yml "Find the last toured tip". Every
nightly-next push used to tour its own previous tip against itself, side by
side: 36 tours and 47.7 owned-Mac job-hours on 2026-11-24, each 80 to 120
minutes, for tips minutes apart. The push runs now share one concurrency group
(one tours, the newest waits, older waiting tips are dropped), so a tip's base
is the last tip a tour actually finished on, not the push's `before`: no
dropped or deferred tip goes untoured, its changes are in the next tour.

A tip whose last tour finished less than --gap-hours ago defers: it takes no
Mac, and the next push past the gap tours everything since. --gap-hours 0
tours every tip that reaches the front of the queue.

Prints `base=SHA` and `defer=true|false` lines for $GITHUB_OUTPUT. Reads the
Actions runs and jobs API through `gh`; any failure falls back to
`base=BEFORE defer=false` (the old behavior), never to skipping a tour.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import subprocess
import sys

TOUR_JOB = "Tour the app"
HEX40 = set("0123456789abcdef")


def is_sha(value: str | None) -> bool:
    return bool(value) and len(value) == 40 and set(value) <= HEX40 and value != "0" * 40


def parse_time(value: str) -> dt.datetime:
    return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))


def choose(runs, run_id: int, jobs_of, is_ancestor, max_lookups: int = 15):
    """The newest earlier push run whose tour finished, as (head_sha, completed_at).

    `runs` is the runs API's list, newest first. A run counts when its tour
    job succeeded, whatever later jobs did (a failed clip publish still
    toured); a run that took no Mac, was cancelled or deferred does not, so
    its changes stay in the next tour's range. The tip must be an ancestor of
    the new head (nightly-next only moves forward; a rewind skips it).
    """
    lookups = 0
    for run in runs:
        if int(run["id"]) >= run_id or run.get("status") != "completed":
            continue
        if run.get("conclusion") not in ("success", "failure"):
            continue
        if lookups >= max_lookups:
            break
        lookups += 1
        tour = next((j for j in jobs_of(run["id"]) if j.get("name") == TOUR_JOB), None)
        if not tour or tour.get("conclusion") != "success" or not tour.get("completed_at"):
            continue
        sha = run.get("head_sha")
        if is_sha(sha) and is_ancestor(sha):
            return sha, parse_time(tour["completed_at"])
    return None


def gh_json(path: str):
    out = subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True, timeout=30).stdout
    return json.loads(out)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--repo", required=True)
    ap.add_argument("--run-id", type=int, required=True)
    ap.add_argument("--head", required=True)
    ap.add_argument("--before", default="")
    ap.add_argument("--gap-hours", type=float, default=0.0)
    ap.add_argument("--branch", default="nightly-next")
    ap.add_argument("--workflow", default="cmux-next-media.yml")
    args = ap.parse_args(argv)

    fallback = args.before if is_sha(args.before) else ""
    try:
        runs = gh_json(
            f"repos/{args.repo}/actions/workflows/{args.workflow}/runs"
            f"?event=push&branch={args.branch}&per_page=40"
        )["workflow_runs"]

        def jobs_of(rid):
            return gh_json(f"repos/{args.repo}/actions/runs/{rid}/jobs?per_page=50")["jobs"]

        def is_ancestor(sha):
            if sha == args.head:
                return True
            cmp = gh_json(f"repos/{args.repo}/compare/{sha}...{args.head}")
            return cmp.get("status") in ("ahead", "identical")

        found = choose(runs, args.run_id, jobs_of, is_ancestor)
    except Exception as exc:  # noqa: BLE001 - any API failure keeps the old base
        print(f"media_last_toured: {exc!r}; touring from the push's before", file=sys.stderr)
        found = None

    if not found:
        print(f"no earlier finished tour found; base is the push's before ({fallback or 'none'})", file=sys.stderr)
        print(f"base={fallback}")
        print("defer=false")
        return 0
    sha, finished = found
    age_h = (dt.datetime.now(dt.timezone.utc) - finished).total_seconds() / 3600
    defer = sha != args.head and args.gap_hours > 0 and age_h < args.gap_hours
    print(
        f"last toured tip {sha}, its tour finished {age_h:.2f} h ago"
        + (f"; deferring: under the {args.gap_hours:g} h gap, the next tip past it tours this one's changes" if defer else ""),
        file=sys.stderr,
    )
    print(f"base={sha}")
    print(f"defer={'true' if defer else 'false'}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
