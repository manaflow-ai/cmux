#!/usr/bin/env python3
"""Rerun the failed jobs of a completed, failed cmux-tui artifacts run.

A transient registry or R2 failure must not strand a tree key, so a failed run
gets up to two more attempts. A run cannot rerun itself while it is in
progress (GitHub answers 403 "This workflow is already running"), so the
cmux-tui-artifacts-retry workflow calls this after the run completes.
"Re-run failed jobs" also reruns the jobs that depend on them, so the publish
jobs are evaluated again.

Only tree-publishing runs (feat-cmux-next's and nightly-next's pushes, with
the tree preflight job) are retried; main's own cmux-tui artifacts runs share the workflow name
and are left alone.

An immutable R2 conflict (annotation title immutable-r2-conflict, written by
scripts/ci/upload-r2-object.py) is never retried: a rebuild is not
byte-identical, so a retry cannot succeed. The run stays red and this script
names the job.

A failure that repeats is not retried either: when every job that failed on
this attempt also failed at the same step on the attempt before, the failure
is deterministic and a third attempt repeats it (CI 10x, 2026-11-21: retries
of a cmux-tui artifacts job that failed again cost 21 runner-hours a day over
11-13..21, 16 of them on attempts 3 and later). One retry of a new failure
still runs, so a transient registry or R2 error is still covered.

usage: cmux_tui_artifacts_retry.py --repo OWNER/NAME --run-id ID [--dry-run]
Needs GH_TOKEN with actions: write and checks: read.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
import sys
import urllib.request

MAX_ATTEMPTS = 3
CONFLICT_TITLE = "immutable-r2-conflict"
TREE_PREFLIGHT_JOB = "cmux-tui tree preflight"
RETRIED_BRANCHES = ("feat-cmux-next", "nightly-next")
TREE_PUBLISH_JOBS = ("publish tree-addressed cmux-tui", "publish pull request tree-addressed cmux-tui")


@dataclass(frozen=True)
class Decision:
    action: str  # "rerun-failed-jobs", "refuse" or "skip"
    reason: str


def never_started(job: dict) -> bool:
    """A job no runner ever took: no runner name or id, no step."""
    return not job.get("runner_name") and not job.get("runner_id") and not job.get("steps")


def queue_orphaned(jobs: list[dict]) -> list[dict]:
    """The cancelled jobs of a cancelled run, when every one of them was cancelled before a runner took it.

    The CI queue janitor cancels a job queued with no runner for 2 h (scripts/ci/queue_janitor.py, find_orphans),
    and a feat-cmux-next push's attempt 1 queues its tree jobs on the owned GCP lane label. 2026-11-19: from
    02:34Z every feat-cmux-next push's tree preflight waited there (run 44445358522, a6082e85, cancelled at
    04:33Z with no runner) and no run was retried, so no commit after fa7b1aaa (2026-11-18 10:38Z) has a
    manifest or the mac-live.json `cmux app try` reads. A job someone cancelled while it ran had a runner:
    that run stays as it is.
    """
    cancelled = [job for job in jobs if job.get("conclusion") == "cancelled"]
    if not cancelled or not all(never_started(job) for job in cancelled):
        return []
    if any(job.get("conclusion") in ("failure", "timed_out") for job in jobs):
        return []
    return cancelled


def failure_fingerprint(jobs: list[dict]) -> frozenset[tuple[str, str]]:
    """{(job name, its first failed step)} of the jobs that failed or timed out."""
    out = set()
    for job in jobs:
        if job.get("conclusion") not in ("failure", "timed_out"):
            continue
        step = next((st.get("name") or "" for st in job.get("steps") or []
                     if st.get("conclusion") in ("failure", "timed_out")), "")
        out.add((job.get("name") or "", step))
    return frozenset(out)


def decide(run: dict, jobs: list[dict], annotations: dict[int, list[dict]], newest: dict | None = None,
           previous: list[dict] | None = None) -> Decision:
    """Pure policy: what to do with one workflow run.

    NEWEST is the newest feat-cmux-next push run of the same workflow (None when it could not be read).
    PREVIOUS is the jobs of the run's attempt before this one (None on attempt 1 or when it could not be read).
    """
    branch = run.get("head_branch") or ""
    # A cancelled feat-cmux-next tree run whose cancelled jobs never got a runner lost its queue, not its
    # build: "Re-run failed jobs" reruns them on attempt 2, which takes the Blacksmith route (the workflow's
    # documented way out of a stuck owned queue). Every feat-cmux-next tip needs its tree and mac-live.json.
    if (run.get("status") == "completed" and run.get("conclusion") == "cancelled" and run.get("event") == "push"
            and branch == "feat-cmux-next" and any(job.get("name") == TREE_PREFLIGHT_JOB for job in jobs)):
        # Latest wins (Leo: "if i wait for the nightly then i might as well just update to the thing"):
        # a newer feat-cmux-next push's mac-live.json lists this commit in live_from, and the artifacts
        # workflow's supersede-feat-runs cancels exactly such older never-started runs. Rerunning them
        # would queue the backlog oldest first again, so only a run at the newest pushed commit is retried.
        # An unreadable newest run keeps the old rule (retry): a missed rerun strands the tip.
        if newest and newest.get("head_sha") and newest.get("head_sha") != run.get("head_sha") \
                and int(newest.get("id") or 0) > int(run.get("id") or 0):
            return Decision("skip", f"superseded: run {newest.get('id')} at {str(newest['head_sha'])[:12]} "
                                    "is a newer feat-cmux-next push; its publication covers this commit")
        orphaned = queue_orphaned(jobs)
        if not orphaned:
            return Decision("skip", "run is completed/cancelled and a cancelled job had a runner: someone stopped it")
        attempt = int(run.get("run_attempt") or 1)
        if attempt >= MAX_ATTEMPTS:
            return Decision("skip", f"attempt {attempt} reached the cap of {MAX_ATTEMPTS}")
        return Decision("rerun-failed-jobs", "cancelled before a runner took it: "
                        + ", ".join(job["name"] for job in orphaned))
    if run.get("status") != "completed" or run.get("conclusion") != "failure":
        return Decision("skip", f"run is {run.get('status')}/{run.get('conclusion')}, not a completed failure")
    # The pushes nightly-next promotes from, and nightly-next itself: its run signs the Linux release file
    # the linux-nightly channel follows (2026-11-27 run 45981368445 at 7682aa45 failed on an aarch64 runner
    # shutdown, was never retried, and the channel stayed a NIGHTLY behind). A red lane branch or PR is
    # usually a real failure.
    if run.get("event") != "push" or not (branch in RETRIED_BRANCHES or branch.startswith("cmux-tui-pin-")):
        return Decision("skip", f"{run.get('event')} on {branch or '?'}: only "
                        + ", ".join(RETRIED_BRANCHES) + " and cmux-tui-pin-* pushes are retried")
    # main's cmux-tui artifacts workflow has the same name but publishes no tree;
    # only feat-cmux-next's tree-publishing runs (they have this job) are retried.
    if not any(job.get("name") == TREE_PREFLIGHT_JOB for job in jobs):
        return Decision("skip", f"no {TREE_PREFLIGHT_JOB!r} job: not a tree-publishing run")
    # The macOS fallback publishes the tree while its Linux-cross legs stay red.
    # That is recovered unless the separate Mac delivery failed: a source tree
    # alone does not provide the signed per-commit file `app try` consumes.
    published = [job["name"] for job in jobs if job.get("name") in TREE_PUBLISH_JOBS and job.get("conclusion") == "success"]
    mac_delivery_failed = any(job.get("name") == "publish the Mac live update"
                              and job.get("conclusion") in ("failure", "cancelled", "timed_out")
                              for job in jobs)
    if published and not mac_delivery_failed:
        return Decision("skip", f"{published[0]} succeeded: the tree is published")
    attempt = int(run.get("run_attempt") or 1)
    if attempt >= MAX_ATTEMPTS:
        return Decision("skip", f"attempt {attempt} reached the cap of {MAX_ATTEMPTS}")
    # A job that its own timeout cancels ends `cancelled` in a run that ends `failure` (a cancelled run ends
    # `cancelled` and is retried above only when no runner ever took its cancelled jobs), and "Re-run failed jobs" reruns it. 2026-11-13: run 43346255778's macOS
    # leg timed out, no job had failed, and the run was left as it was with its tree unpublished.
    failed = [job for job in jobs if job.get("conclusion") in ("failure", "cancelled", "timed_out")]
    if not failed:
        return Decision("skip", "no job failed (the failure is not a job failure)")
    conflicts = [
        job["name"]
        for job in failed
        if any(note.get("title") == CONFLICT_TITLE for note in annotations.get(job["id"], []))
    ]
    if conflicts:
        return Decision(
            "refuse",
            "immutable R2 conflict in " + ", ".join(conflicts)
            + ": a rebuild is not byte-identical, so a retry cannot fix it",
        )
    now = failure_fingerprint(jobs)
    if previous and now and now <= failure_fingerprint(previous):
        return Decision("skip", f"attempts {attempt - 1} and {attempt} failed the same way ("
                        + ", ".join(f"{name}: {step}" if step else name for name, step in sorted(now))
                        + "): deterministic, a retry repeats it")
    return Decision("rerun-failed-jobs", "failed: " + ", ".join(job["name"] for job in failed))


def _api(method: str, url: str, token: str) -> object:
    request = urllib.request.Request(
        url,
        method=method,
        headers={
            "Authorization": f"Bearer {token}",
            "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        body = response.read()
    return json.loads(body) if body else None


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--repo", required=True)
    parser.add_argument("--run-id", required=True, type=int)
    parser.add_argument("--dry-run", action="store_true", help="decide and print, never rerun")
    args = parser.parse_args(argv)
    token = os.environ.get("GH_TOKEN", "")
    if not token:
        print("GH_TOKEN is required", file=sys.stderr)
        return 2
    base = f"https://api.github.com/repos/{args.repo}"
    run = _api("GET", f"{base}/actions/runs/{args.run_id}", token)
    jobs = _api("GET", f"{base}/actions/runs/{args.run_id}/jobs?filter=latest&per_page=100", token)["jobs"]
    annotations = {
        job["id"]: _api("GET", f"{base}/check-runs/{job['id']}/annotations?per_page=100", token)
        for job in jobs
        if job.get("conclusion") == "failure"
    }
    newest = None
    if run.get("conclusion") == "cancelled" and run.get("head_branch") == "feat-cmux-next":
        try:
            listed = _api("GET", f"{base}/actions/workflows/{run['workflow_id']}/runs?branch=feat-cmux-next"
                                 "&event=push&per_page=1", token)
            newest = ((listed or {}).get("workflow_runs") or [None])[0]
        except (OSError, ValueError, KeyError) as error:
            print(f"::warning::could not read the newest feat-cmux-next push run ({error}); deciding without it")
    previous = None
    attempt = int(run.get("run_attempt") or 1)
    if run.get("conclusion") == "failure" and attempt > 1:
        try:
            listed = _api("GET", f"{base}/actions/runs/{args.run_id}/attempts/{attempt - 1}/jobs?per_page=100", token)
            previous = (listed or {}).get("jobs")
        except (OSError, ValueError, KeyError) as error:
            print(f"::warning::could not read attempt {attempt - 1}'s jobs ({error}); deciding without them")
    decision = decide(run, jobs, annotations, newest, previous)
    print(f"run {args.run_id} attempt {run.get('run_attempt')}: {decision.action} ({decision.reason})")
    if decision.action == "refuse":
        print(f"::error title=cmux-tui publish not retried::run {args.run_id}: {decision.reason}")
        return 1
    if decision.action == "rerun-failed-jobs" and not args.dry_run:
        _api("POST", f"{base}/actions/runs/{args.run_id}/rerun-failed-jobs", token)
        print(f"Reran the failed jobs of run {args.run_id}.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
