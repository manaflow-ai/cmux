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

A build leg that failed on a rerun is not retried again. A rerun loses
attempt 1's runner pick, and on 2026-11-19 58 of the 67 build legs that
failed on a rerun died the same way (rustc killed by SIGKILL during the fat
LTO build), and attempts 2 and 3 together cost 3,096 runner-min and published
2 trees. A leg that ended cancelled or timed out is still retried (#42380).

A build leg that failed on a Rust compile error is not retried at all
(cmux_tui_tree_handoff.compile_error_failure): a rerun builds the same source
and fails on the same rustc error. The channel heal (#64931) and tree requests
hold the same way. An unreadable log is no evidence, and the run is retried as
before.

usage: cmux_tui_artifacts_retry.py --repo OWNER/NAME --run-id ID [--dry-run]
Needs GH_TOKEN with actions: write and checks: read.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cmux_tui_tree_handoff import compile_error_failure  # noqa: E402

MAX_ATTEMPTS = 3
API_ATTEMPTS = 3
MAX_RATE_WAIT = 45
CONFLICT_TITLE = "immutable-r2-conflict"
TREE_PREFLIGHT_JOB = "cmux-tui tree preflight"
TREE_PUBLISH_JOBS = ("publish tree-addressed cmux-tui",)
# The reusable build workflow's legs: "build / build TARGET", "build-linux / build TARGET", and the
# macOS fallback's legs under its own caller job.
BUILD_LEG_MARK = " / build "


@dataclass(frozen=True)
class Decision:
    action: str  # "rerun-failed-jobs", "refuse" or "skip"
    reason: str


def decide(run: dict, jobs: list[dict], annotations: dict[int, list[dict]], compile_red: bool = False) -> Decision:
    """Pure policy: what to do with one workflow run."""
    if run.get("status") != "completed" or run.get("conclusion") != "failure":
        return Decision("skip", f"run is {run.get('status')}/{run.get('conclusion')}, not a completed failure")
    # The pushes nightly-next promotes from; a red lane branch or PR is usually a real failure.
    branch = run.get("head_branch") or ""
    if run.get("event") != "push" or branch != "feat-cmux-next":
        return Decision("skip", f"{run.get('event')} on {branch or '?'}: only feat-cmux-next pushes are retried")
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
    # `cancelled` and is skipped above), and "Re-run failed jobs" reruns it. 2026-11-13: run 43346255778's macOS
    # leg timed out, no job had failed, and the run was left as it was with its tree unpublished.
    failed = [job for job in jobs if job.get("conclusion") in ("failure", "cancelled", "timed_out")]
    if not failed:
        return Decision("skip", "no job failed (the failure is not a job failure)")
    if attempt >= 2:
        rebuilt_red = [job["name"] for job in failed
                       if job.get("conclusion") == "failure" and BUILD_LEG_MARK in (job.get("name") or "")]
        if rebuilt_red:
            return Decision(
                "skip",
                "build leg failed on rerun attempt " + str(attempt) + ": " + ", ".join(rebuilt_red)
                + "; another rerun takes the same runner and fails the same way",
            )
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
    if compile_red:
        return Decision(
            "skip",
            "a build leg failed on a Rust compile error: a rerun builds the same source and fails the same way",
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
    # A 403/429 with a rate-limit signal is the token's REST budget, not a missing permission
    # (the job holds actions: write, which includes read). Run 46120896444 (a49c3280) died on a
    # bare "HTTP Error 403" with no body printed, so the cause could not be told. Print the body,
    # and wait out a short limit instead of leaving the failed publish unretried.
    for attempt in range(1, API_ATTEMPTS + 1):
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
            return json.loads(body) if body else None
        except urllib.error.HTTPError as err:
            detail = err.read().decode("utf-8", "replace")[:500]
            wait = _rate_limit_wait(err.code, err.headers, detail)
            print(f"{method} {url}: HTTP {err.code}: {detail}", file=sys.stderr)
            if wait is None or attempt == API_ATTEMPTS:
                raise
            print(f"rate limited; waiting {wait}s (try {attempt}/{API_ATTEMPTS})", file=sys.stderr)
            time.sleep(wait)
    raise AssertionError("unreachable")


def _log_text(url: str, token: str) -> str | None:
    """A job log as text (urllib follows the redirect to the log blob), or None when it cannot be read."""
    request = urllib.request.Request(url, headers={"Authorization": f"Bearer {token}",
                                                   "X-GitHub-Api-Version": "2022-11-28"})
    try:
        with urllib.request.urlopen(request, timeout=60) as response:
            return response.read().decode("utf-8", "replace")
    except (urllib.error.URLError, OSError) as err:
        print(f"GET {url}: {err}", file=sys.stderr)
        return None


def _rate_limit_wait(code: int, headers, detail: str) -> int | None:
    """Seconds to wait when the response is a rate limit that clears within MAX_RATE_WAIT, else None."""
    if code not in (403, 429):
        return None
    retry_after = headers.get("Retry-After")
    reset = headers.get("X-RateLimit-Reset")
    if retry_after and retry_after.isdigit():
        wait = int(retry_after)
    elif headers.get("X-RateLimit-Remaining") == "0" and reset and reset.isdigit():
        wait = max(1, int(reset) - int(time.time()) + 1)
    elif "rate limit" in detail.lower():
        wait = 30
    else:
        return None
    return wait if wait <= MAX_RATE_WAIT else None


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
    if decision.action == "rerun-failed-jobs":
        # Logs are read only when a rerun is about to happen: one GET per failed build leg.
        compile_red = compile_error_failure(jobs, lambda job: _log_text(f"{base}/actions/jobs/{job['id']}/logs", token))
        decision = decide(run, jobs, annotations, compile_red=compile_red)
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
