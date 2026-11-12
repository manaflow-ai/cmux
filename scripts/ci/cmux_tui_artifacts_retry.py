#!/usr/bin/env python3
"""Rerun the failed jobs of a completed, failed cmux-tui artifacts run.

A transient registry or R2 failure must not strand a tree key, so a failed run
gets up to two more attempts. A run cannot rerun itself while it is in
progress (GitHub answers 403 "This workflow is already running"), so the
cmux-tui-artifacts-retry workflow calls this after the run completes.
"Re-run failed jobs" also reruns the jobs that depend on them, so the publish
jobs are evaluated again.

Only tree-publishing runs (feat-cmux-next's workflow, with its tree preflight
job) are retried; main's own cmux-tui artifacts runs share the workflow name
and are left alone.

An immutable R2 conflict (annotation title immutable-r2-conflict, written by
scripts/ci/upload-r2-object.py) is never retried: a rebuild is not
byte-identical, so a retry cannot succeed. The run stays red and this script
names the job.

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
TREE_PUBLISH_JOBS = ("publish tree-addressed cmux-tui", "publish pull request tree-addressed cmux-tui")


@dataclass(frozen=True)
class Decision:
    action: str  # "rerun-failed-jobs", "refuse" or "skip"
    reason: str


def decide(run: dict, jobs: list[dict], annotations: dict[int, list[dict]]) -> Decision:
    """Pure policy: what to do with one workflow run."""
    if run.get("status") != "completed" or run.get("conclusion") != "failure":
        return Decision("skip", f"run is {run.get('status')}/{run.get('conclusion')}, not a completed failure")
    # The pushes nightly-next promotes from; a red lane branch or PR is usually a real failure.
    branch = run.get("head_branch") or ""
    if run.get("event") != "push" or not (branch == "feat-cmux-next" or branch.startswith("cmux-tui-pin-")):
        return Decision("skip", f"{run.get('event')} on {branch or '?'}: only feat-cmux-next and cmux-tui-pin-* pushes are retried")
    # main's cmux-tui artifacts workflow has the same name but publishes no tree;
    # only feat-cmux-next's tree-publishing runs (they have this job) are retried.
    if not any(job.get("name") == TREE_PREFLIGHT_JOB for job in jobs):
        return Decision("skip", f"no {TREE_PREFLIGHT_JOB!r} job: not a tree-publishing run")
    # The macOS fallback publishes the tree while its Linux-cross legs stay red:
    # nothing is left to rescue, and a rerun would only rerun publish.
    published = [job["name"] for job in jobs if job.get("name") in TREE_PUBLISH_JOBS and job.get("conclusion") == "success"]
    if published:
        return Decision("skip", f"{published[0]} succeeded: the tree is published")
    attempt = int(run.get("run_attempt") or 1)
    if attempt >= MAX_ATTEMPTS:
        return Decision("skip", f"attempt {attempt} reached the cap of {MAX_ATTEMPTS}")
    failed = [job for job in jobs if job.get("conclusion") == "failure"]
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
    decision = decide(run, jobs, annotations)
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
