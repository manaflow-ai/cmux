#!/usr/bin/env python3
"""Spill an owned-first cmux-tui tree job off a busy owned label after a bounded wait.

On the nightly path (feat-cmux-next and nightly-next pushes, tree-request dispatches) attempt 1 of the jobs a NEXT
nightly waits for queues on our own GCP Linux labels, and attempt 2+ takes the Blacksmith pools (feat-cmux-next
cmux-tui-artifacts.yml; tests/test_ci_owned_first_not_census_frozen.py there). The route is never decided by a
one-shot runner census: on 2026-11-19 run 44464326281's "cmux_next_ daemon tests" was put on
blacksmith-16vcpu-ubuntu-2404 because no GCP member was idle at the instant tree-preflight looked, and it sat queued
there from 05:23Z while the GCP runners freed up, holding the tree publish the nightly and Leo's tip build waited for
(Leo: a job already headed for an owned 16 vCPU GCP runner class must not move off GCP onto Blacksmith).

GitHub never moves a queued job, so the bound needs someone to act: this sweep. For each unfinished attempt-1
nightly-path run of cmux-tui-artifacts.yml with a job queued on an owned label for SPILL_MINUTES or more, it cancels
the run and re-runs its failed and cancelled jobs, which is attempt 2: those jobs take their spill route, the jobs that
already passed keep their results. It never cancels a run with a job in progress (a publish of immutable objects must
never stop mid-upload; cmux-tui-artifacts.yml's concurrency comment): such a run waits for the next sweep. At most
MAX_SPILLS runs move per sweep, newest first, and attempt 2+ is never touched (one spill per run).

Keyless: the workflow mints the cmux-bot App token in its environment (GITHUB_TOKEN with actions: write without
it); no person's login. DRY_RUN=true reports what it would do and changes nothing.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Iterable, Mapping
from typing import Any

WORKFLOW = "cmux-tui-artifacts.yml"
# Our own Linux labels an owned-first job queues on (the persistent GCP build lane, the nightly-only runner, the
# ephemeral GCP fleet). A job queued on one of these past the bound is the one this sweep moves.
OWNED_LABELS = frozenset({"cmux-gcp-lane-build-x64", "cmux-gcp-nightly-x64", "cmux-fleet-linux-x64"})
NIGHTLY_BRANCHES = frozenset({"feat-cmux-next", "nightly-next"})
SPILL_MINUTES = 20
MAX_SPILLS = 3
CANCEL_SETTLE_SECONDS = 300
API = "https://api.github.com"


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def nightly_path(run: Mapping[str, Any]) -> bool:
    """Attempt 1 of a run whose owned-first jobs queue on an owned label (the routes the tree workflow gives them)."""
    if run.get("run_attempt") != 1:
        return False
    event = run.get("event")
    return event == "workflow_dispatch" or event == "push" and run.get("head_branch") in NIGHTLY_BRANCHES


def owned_wait_minutes(job: Mapping[str, Any], now: dt.datetime) -> float | None:
    """Minutes a queued job has waited on an owned label, else None."""
    if job.get("status") != "queued" or not OWNED_LABELS & set(job.get("labels") or ()):
        return None
    created = parse_time(job.get("created_at"))
    return None if created is None else (now - created).total_seconds() / 60


def decide(run: Mapping[str, Any], jobs: Iterable[Mapping[str, Any]], now: dt.datetime,
           spill_minutes: float = SPILL_MINUTES) -> tuple[str, str] | None:
    """("spill", why) when the run should move now, ("wait", why) when it is stuck but may not move yet, else None."""
    if not nightly_path(run) or run.get("status") == "completed":
        return None
    jobs = list(jobs)
    stuck = []
    for job in jobs:
        waited = owned_wait_minutes(job, now)
        if waited is not None and waited >= spill_minutes:
            stuck.append(f"{job.get('name')} queued {int(waited)} min on {','.join(job.get('labels') or ())}")
    if not stuck:
        return None
    running = [str(job.get("name")) for job in jobs if job.get("status") == "in_progress"]
    if running:
        return "wait", f"{'; '.join(stuck)}; not cancelled while running: {', '.join(running)}"
    return "spill", "; ".join(stuck)


class GitHub:
    def __init__(self, token: str, repo: str):
        self.token, self.repo = token, repo

    def call(self, method: str, path: str) -> Any:
        request = urllib.request.Request(f"{API}/repos/{self.repo}/{path}", method=method, headers={
            "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"}, data=b"" if method == "POST" else None)
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
        return json.loads(body) if body else None

    def runs(self, status: str) -> list[dict]:
        return self.call("GET", f"actions/workflows/{WORKFLOW}/runs?status={status}&per_page=50").get(
            "workflow_runs") or []

    def jobs(self, run_id: int) -> list[dict]:
        return self.call("GET", f"actions/runs/{run_id}/jobs?filter=latest&per_page=100").get("jobs") or []


def spill(github: GitHub, run: Mapping[str, Any], now: dt.datetime, spill_minutes: float = SPILL_MINUTES,
          sleep: Callable[[float], None] = time.sleep, settle_seconds: float = CANCEL_SETTLE_SECONDS) -> str:
    """Cancel the run, wait for it to finish, re-run its failed and cancelled jobs (attempt 2).

    The jobs are read again right before the cancel: a job that started since the sweep's first read (the stuck job
    itself, or a publish) keeps the run whole. Once the cancel is sent, the re-run is retried until the settle budget
    ends; a run that still could not be re-run is an ::error:: that fails the sweep, so it is seen, never silent."""
    run_id = run["id"]
    verdict = decide(run, github.jobs(run_id), now, spill_minutes)
    if verdict is None or verdict[0] != "spill":
        return "not cancelled: the run changed since the first read" + (f" ({verdict[1]})" if verdict else "")
    github.call("POST", f"actions/runs/{run_id}/cancel")
    waited = 0.0
    while True:
        try:
            if github.call("GET", f"actions/runs/{run_id}").get("status") == "completed":
                github.call("POST", f"actions/runs/{run_id}/rerun-failed-jobs")
                return "cancelled and re-run as attempt 2 (spill route)"
        except urllib.error.URLError as error:
            last = str(error)
        else:
            last = "cancel not settled"
        if waited >= settle_seconds:
            raise SpillFailed(f"run {run_id} was cancelled but not re-run after {int(waited)} s ({last}): "
                              f"gh run rerun {run_id} --failed")
        sleep(10)
        waited += 10


class SpillFailed(RuntimeError):
    """A run this sweep cancelled that it could not re-run."""


def main(env: Mapping[str, str] = os.environ, now: dt.datetime | None = None) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    token, repo = env.get("GH_TOKEN", ""), env.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
    if not token:
        print("::error::GH_TOKEN is unset")
        return 1
    dry_run = env.get("DRY_RUN", "").lower() == "true"
    spill_minutes = float(env.get("SPILL_MINUTES") or SPILL_MINUTES)
    max_spills = int(env.get("MAX_SPILLS") or MAX_SPILLS)
    github = GitHub(token, repo)
    lines = [f"Owned-first spill sweep ({'dry run' if dry_run else 'live'}), bound {spill_minutes:g} min"]
    try:
        runs = [run for status in ("queued", "in_progress") for run in github.runs(status) if nightly_path(run)]
    except urllib.error.HTTPError as error:
        lines.append(f"Skipped: listing runs failed ({error.code}); nothing was cancelled")
        return report(lines, env)
    runs.sort(key=lambda run: run.get("created_at") or "", reverse=True)
    moved, failed = 0, []
    for run in runs:
        try:
            jobs = github.jobs(run["id"])
        except urllib.error.URLError as error:
            lines.append(f"- skipped {run.get('html_url') or run['id']}: reading its jobs failed ({error})")
            continue
        verdict = decide(run, jobs, now, spill_minutes)
        if verdict is None:
            continue
        kind, why = verdict
        url = run.get("html_url") or run["id"]
        if kind == "wait" or moved >= max_spills:
            lines.append(f"- wait {url}: {why}" + (" (spill cap reached)" if kind == "spill" else ""))
            continue
        if dry_run:
            lines.append(f"- would spill {url}: {why}")
        else:
            try:
                lines.append(f"- spill {url}: {why}: {spill(github, run, now, spill_minutes)}")
            except (SpillFailed, urllib.error.URLError) as error:
                failed.append(str(error))
                lines.append(f"- FAILED {url}: {error}")
        moved += 1
    if len(lines) == 1:
        lines.append("Nothing queued past the bound on an owned label.")
    report(lines, env)
    for message in failed:
        print(f"::error title=Owned-first spill::{message}")
    return 1 if failed else 0


def report(lines: list[str], env: Mapping[str, str]) -> int:
    text = "\n".join(lines)
    print(text)
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(text + "\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
