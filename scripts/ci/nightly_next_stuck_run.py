#!/usr/bin/env python3
"""Report a nightly-next build or promotion run stuck on a runner label that stopped serving, and
re-run the jobs that never got a runner once the run has ended. It never cancels a nightly.

GitHub fixes a job's runner label when it creates the job. If that label stops serving, the job waits
(GitHub ends a job queued 24 hours), and changing the runner repository variables does not move it.
Run 40771197361 (tip 1f0f687b, 2026-10-28) had `decide` waiting 34 minutes on
blacksmith-4vcpu-ubuntu-2404, with more jobs queued behind it. This step used to cancel such a run for
another path to build again. Nobody cancels a nightly (Lawrence, 2026-11-04; CLAUDE.md, "Nightlies run
on one Mac mini, and nobody cancels them"), so now:
  - an unfinished run with a job stuck STUCK_MINUTES (3) `queued` with no runner gets a warning and
    keeps waiting. Stuck is read as before: no pending deployment, the wait counted no earlier than the
    latest executed job's completion, labels none of which is owned (glaeda-* jobs belong to the
    owned-pool rescue, owned_pool_rescue.py), every other job completed or also queued with no runner;
  - once the tip's newest push run on nightly-next has ended, below MAX_ATTEMPTS, with every failed
    job one that never got a runner (no runner and never started) on a label that is not owned, its
    failed jobs are re-run, which re-runs the jobs that needed them too: follow()'s re-run after a run
    ends in owned_pool_rescue.py. A run that ended cancelled is left to the next tick step,
    nightly_next_cancelled_tip.sh, and a job that failed on a runner is a real red, never re-run here.

Fail-closed: every Actions object is read through one typed reader (`Run`, `Job` below). A field that
is missing, of the wrong JSON type, or outside its enum (status, conclusion, and their pairing: a
completed object has a conclusion, an unfinished one has none), a list that is not a list, or a
paginated listing whose count does not add up, is Unreadable, and nothing is re-run for that run or,
for a listing, that tick. The re-run goes out once, with no wrapper retries
(GH_BUDGET_WAIT_ATTEMPTS=1, gh_budget_wait.sh).

    nightly_next_stuck_run.py REPO
Needs gh with GH_TOKEN (actions: write). Exit 0 always once the arguments read: the step is advisory
and its findings are annotations.
"""
from __future__ import annotations

import dataclasses
import datetime as dt
import json
import os
import re
import subprocess
import sys
from collections.abc import Callable, Sequence
from typing import Any

STUCK_MINUTES = float(os.environ.get("STUCK_MINUTES", "3"))
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "3"))  # nightly_next_cancelled_tip.sh's bound
PAGE = 100
PROMOTION_TITLE = "Promote nightly-next to"

RUN_STATUSES = frozenset({"queued", "in_progress", "completed", "waiting", "requested", "pending",
                          "action_required"})
JOB_STATUSES = frozenset({"queued", "in_progress", "completed", "waiting", "requested", "pending"})
CONCLUSIONS = frozenset({"success", "failure", "neutral", "cancelled", "skipped", "timed_out",
                         "action_required", "stale", "startup_failure"})
SHA = re.compile(r"[0-9a-f]{40}")
TIMESTAMP = re.compile(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z")


class Unreadable(Exception):
    """An answer that failed, or that is not the shape this reads. Nothing is re-run on it."""


# ---- the typed reader


def field(obj: Any, key: str, kinds: tuple[type, ...], *, nullable: bool = False) -> Any:
    """obj[key], present and of one of `kinds` (bool is never an int here), or None when nullable."""
    if not isinstance(obj, dict) or key not in obj:
        raise Unreadable(f"no {key!r} in {type(obj).__name__}")
    value = obj[key]
    if value is None and nullable:
        return None
    if isinstance(value, bool) or not isinstance(value, kinds):
        raise Unreadable(f"{key!r} is {type(value).__name__}")
    return value


def status_pair(obj: Any, statuses: frozenset[str]) -> tuple[str, str | None]:
    status = field(obj, "status", (str,))
    if status not in statuses:
        raise Unreadable(f"status {status!r}")
    conclusion = field(obj, "conclusion", (str,), nullable=True)
    if conclusion is not None and conclusion not in CONCLUSIONS:
        raise Unreadable(f"conclusion {conclusion!r}")
    if (status == "completed") != (conclusion is not None):
        raise Unreadable(f"status {status!r} with conclusion {conclusion!r}")
    return status, conclusion


def parse_timestamp(value: str, key: str) -> dt.datetime:
    if not TIMESTAMP.fullmatch(value):
        raise Unreadable(f"{key!r} {value!r}")
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise Unreadable(f"{key!r} {value!r}") from error


def timestamp(obj: Any, key: str) -> dt.datetime:
    return parse_timestamp(field(obj, key, (str,)), key)


@dataclasses.dataclass(frozen=True)
class Run:
    id: int
    event: str
    status: str
    conclusion: str | None
    attempt: int
    head_sha: str
    title: str
    branch: str

    @classmethod
    def parse(cls, obj: Any) -> "Run":
        run_id = field(obj, "id", (int,))
        attempt = field(obj, "run_attempt", (int,))
        head_sha = field(obj, "head_sha", (str,))
        if run_id <= 0 or attempt <= 0 or not SHA.fullmatch(head_sha):
            raise Unreadable(f"run {run_id!r}: id, attempt or head_sha out of range")
        status, conclusion = status_pair(obj, RUN_STATUSES)
        return cls(run_id, field(obj, "event", (str,)), status, conclusion, attempt, head_sha,
                   field(obj, "display_title", (str,)), field(obj, "head_branch", (str,)))


@dataclasses.dataclass(frozen=True)
class Job:
    id: int
    name: str
    status: str
    conclusion: str | None
    runner: str | None
    labels: tuple[str, ...]
    created: dt.datetime
    started: dt.datetime | None
    completed: dt.datetime | None

    @classmethod
    def parse(cls, obj: Any) -> "Job":
        labels = field(obj, "labels", (list,))
        if not all(isinstance(label, str) for label in labels):
            raise Unreadable("a label that is not a string")
        status, conclusion = status_pair(obj, JOB_STATUSES)
        if status == "queued" and not labels:
            raise Unreadable("a queued job with no label")  # a queued job is judged by its label
        started_at = field(obj, "started_at", (str,), nullable=True)
        started = parse_timestamp(started_at, "started_at") if started_at is not None else None
        return cls(field(obj, "id", (int,)), field(obj, "name", (str,)), status, conclusion,
                   field(obj, "runner_name", (str,), nullable=True) or None, tuple(labels),
                   timestamp(obj, "created_at"), started,
                   timestamp(obj, "completed_at") if status == "completed" and conclusion != "skipped" else None)


# ---- GitHub, through gh


Gh = Callable[[Sequence[str], bool], str]


def gh_cli(args: Sequence[str], write: bool) -> str:
    """Run gh. A write goes out once (no gh_budget_wait.sh retries); a read may wait out a rate limit."""
    env = dict(os.environ)
    if write:
        env["GH_BUDGET_WAIT_ATTEMPTS"] = "1"
    result = subprocess.run(["gh", *args], capture_output=True, text=True, env=env, stdin=subprocess.DEVNULL)
    if result.returncode:
        raise Unreadable(f"gh {' '.join(args[:3])} failed: {result.stderr.strip()[:200]}")
    return result.stdout


def ls_remote_sha(repo: str, branch: str) -> str:
    """A branch's tip from git's ref advertisement of the public repository: no token and none of
    the installation's API budget, which ran out on 2026-11-04 and failed the refs API read."""
    server = os.environ.get("GITHUB_SERVER_URL", "https://github.com").rstrip("/")
    out = subprocess.run(
        ["git", "ls-remote", "--exit-code", f"{server}/{repo}", f"refs/heads/{branch}"],
        capture_output=True, text=True, timeout=60, check=True, stdin=subprocess.DEVNULL,
        env={**os.environ, "GIT_TERMINAL_PROMPT": "0"}).stdout
    return out.split()[0].lower() if out.split() else ""


class Api:
    def __init__(self, repo: str, gh: Gh = gh_cli, ls_remote: Callable[[str, str], str] | None = None):
        self.repo, self.gh, self.ls_remote = repo, gh, ls_remote

    def get(self, path: str) -> Any:
        text = self.gh(["api", f"repos/{self.repo}/{path}"], False)
        try:
            return json.loads(text)
        except json.JSONDecodeError as error:
            raise Unreadable(f"{path}: not JSON") from error

    def listing(self, path: str, key: str) -> list[Any]:
        """Every item of a paginated listing, page by page. Each page must be an object whose `key` is
        a list and whose total_count is the first page's; the items must add up to it, with no item
        twice (a list that moved between page reads)."""
        items: list[Any] = []
        total = None
        page = 1
        while True:
            body = self.get(f"{path}{'&' if '?' in path else '?'}per_page={PAGE}&page={page}")
            count = field(body, "total_count", (int,))
            batch = field(body, key, (list,))
            if total is None:
                total = count
            elif count != total:
                raise Unreadable(f"{path}: total_count moved from {total} to {count} between pages")
            items.extend(batch)
            ids = [item.get("id") for item in items if isinstance(item, dict)]
            if len(ids) != len(set(map(repr, ids))):
                raise Unreadable(f"{path}: an item repeats across pages (the list moved while it was read)")
            if len(items) >= total or not batch:
                break
            page += 1
        if len(items) != total:
            raise Unreadable(f"{path}: {len(items)} items for a total_count of {total}")
        return items

    def tip(self) -> str:
        """nightly-next's head: git ls-remote when given one (main does), else or on its failure the refs API."""
        if self.ls_remote is not None:
            try:
                sha = self.ls_remote(self.repo, "nightly-next")
                if SHA.fullmatch(sha):
                    return sha
                print(f"git ls-remote nightly-next answered {sha!r}; reading it through the API")
            except (OSError, subprocess.SubprocessError) as error:
                print(f"git ls-remote nightly-next failed ({error!r}); reading it through the API")
        sha = field(field(self.get("git/ref/heads/nightly-next"), "object", (dict,)), "sha", (str,))
        if not SHA.fullmatch(sha):
            raise Unreadable(f"nightly-next is {sha!r}")
        return sha

    def run(self, run_id: int) -> Run:
        return Run.parse(self.get(f"actions/runs/{run_id}"))

    def jobs(self, run_id: int) -> list[Job]:
        return [Job.parse(job) for job in self.listing(f"actions/runs/{run_id}/jobs?filter=latest", "jobs")]

    def pending_deployments(self, run_id: int) -> int:
        body = self.get(f"actions/runs/{run_id}/pending_deployments")
        if not isinstance(body, list):
            raise Unreadable("pending deployments are not a list")
        return len(body)

    def tip_push_runs(self, tip: str) -> list[Run]:
        """The tip's push runs of nightly.yml on nightly-next, newest first."""
        runs = [Run.parse(item) for item in self.listing(
            f"actions/workflows/nightly.yml/runs?branch=nightly-next&event=push&head_sha={tip}", "workflow_runs")]
        return sorted(runs, key=lambda run: run.id, reverse=True)

    def rerun_failed_jobs(self, run_id: int) -> None:
        self.gh(["api", "-X", "POST", f"repos/{self.repo}/actions/runs/{run_id}/rerun-failed-jobs"], True)


# ---- the decision


def started_job(job: Job) -> bool:
    """Whether GitHub records that this job acquired execution, rather than only being queued."""
    return job.started is not None and (job.status == "in_progress" or (
        job.conclusion is not None and job.conclusion != "skipped"))


def timed_out_job(job: Job) -> bool:
    """A timed-out job is the explicit certain-to-fail exception to the started-work hold."""
    return started_job(job) and job.conclusion == "timed_out"


def queued_without_runner(job: Job) -> bool:
    return job.status == "queued" and job.runner is None


def stuck_job(run: Run, jobs: list[Job], now: dt.datetime) -> Job | None:
    """The run's first job stuck without a runner, when the run as a whole is stuck; else None."""
    if run.status not in ("queued", "in_progress") or not jobs:
        return None

    # A downstream queue is not safe to cancel after any non-skipped job has
    # started: its completed result may be the only evidence that work already
    # happened while GitHub was still creating later job records. A timed-out
    # started job is certain to fail and remains cancellable.
    if any(started_job(job) for job in jobs) and not any(timed_out_job(job) for job in jobs):
        return None

    # A queued owned build may be the dependency of an already-created signer.
    # Leave the entire run to owned-pool recovery rather than treating that signer
    # as proof that the run is stalled on a non-owned label.
    if any(job.status == "queued" and any(label.startswith("glaeda-") for label in job.labels) for job in jobs):
        return None

    # GitHub can create downstream job records before their dependencies complete. Using
    # their creation alone would count build time as queue time and cancel a signer just
    # as it becomes runnable. Waiting from the latest executed completion is conservative
    # even when that job is not this one's dependency; no workflow graph read is needed.
    completed = max((job.completed for job in jobs if job.completed is not None), default=None)
    stuck = [job for job in jobs if queued_without_runner(job)
             and not any(label.startswith("glaeda-") for label in job.labels)
             and (now - max(job.created, completed or job.created)).total_seconds() / 60 >= STUCK_MINUTES]
    if stuck and all(job.status == "completed" or queued_without_runner(job) for job in jobs):
        return stuck[0]
    return None


def read_stuck(api: Api, run_id: int, now: Callable[[], dt.datetime]) -> tuple[Run, Job | None, bool]:
    run = api.run(run_id)
    if run.status not in ("queued", "in_progress"):
        return run, None, False
    if api.pending_deployments(run_id):
        return run, None, False
    jobs = api.jobs(run_id)
    started = any(started_job(job) for job in jobs) and not any(timed_out_job(job) for job in jobs)
    started_waiting = started and any(queued_without_runner(job) for job in jobs)
    return run, stuck_job(run, jobs, now()), started_waiting


def candidates(api: Api) -> list[Run]:
    found: dict[int, Run] = {}
    for status in ("queued", "in_progress"):
        for item in api.listing(f"actions/workflows/nightly.yml/runs?branch=nightly-next&status={status}", "workflow_runs"):
            run = Run.parse(item)
            if run.event in ("push", "workflow_dispatch"):
                found[run.id] = run
        for item in api.listing(f"actions/workflows/nightly.yml/runs?branch=main&event=workflow_dispatch&status={status}",
                                "workflow_runs"):
            run = Run.parse(item)
            if run.title.startswith(PROMOTION_TITLE):
                found[run.id] = run
    return [found[run_id] for run_id in sorted(found)]


def lost_job(job: Job) -> bool:
    """A job that ended failed or cancelled without ever getting a runner, on a label that is not owned."""
    return (job.status == "completed" and job.conclusion in ("failure", "cancelled", "timed_out")
            and job.runner is None and job.started is None
            and not any(label.startswith("glaeda-") for label in job.labels))


def rerun_lost(api: Api, tip: str, log: Callable[[str], None], warn: Callable[[str], None]) -> None:
    """Re-run the failed jobs of the tip's newest push run when it has ended and every failed job never got a runner."""
    try:
        runs = api.tip_push_runs(tip)
        if not runs:
            return
        newest = runs[0]
        if newest.status != "completed" or newest.conclusion in ("success", "cancelled", "skipped"):
            return  # building, green, or nightly_next_cancelled_tip.sh's
        jobs = api.jobs(newest.id)
    except Unreadable as why:
        log(f"nightly-next tip {tip[:12]}: its newest run could not be read ({why}); nothing re-run")
        return
    failed = [job for job in jobs if job.status == "completed" and job.conclusion not in ("success", "skipped", "neutral")]
    if not failed or not all(lost_job(job) for job in failed):
        return
    names = ", ".join(job.name for job in failed)
    if newest.attempt >= MAX_ATTEMPTS:
        warn(f"the tip {tip[:12]}'s run {newest.id} ended {newest.conclusion} on attempt {newest.attempt} of "
             f"{MAX_ATTEMPTS} because {names} never got a runner; not re-run again")
        return
    try:
        # A push can land while the tick reads; the old tip's jobs must not be re-run over the newer
        # nightly, so the tip is read again right before the write.
        current = api.tip()
    except Unreadable as why:
        log(f"nightly-next tip could not be read again ({why}); run {newest.id} not re-run")
        return
    if current != tip:
        log(f"nightly-next moved from {tip[:12]} to {current[:12]}; run {newest.id} not re-run")
        return
    try:
        api.rerun_failed_jobs(newest.id)
    except Unreadable as error:
        warn(f"run {newest.id}: the re-run of {names} was refused ({error}); the next tick reads it again")
        return
    log(f"::notice title=nightly-next tick::re-ran the failed jobs of run {newest.id} ({tip[:12]}, attempt "
        f"{newest.attempt}): {names} never got a runner")


def tick(api: Api, log: Callable[[str], None] = print,
         now: Callable[[], dt.datetime] = lambda: dt.datetime.now(dt.timezone.utc)) -> None:
    def warn(message: str) -> None:
        log(f"::warning title=nightly-next tick::{message}")

    try:
        tip = api.tip()
        runs = candidates(api)
    except Unreadable as why:
        warn(f"the nightly runs could not be read ({why}); nothing is re-run this tick")
        return
    if not runs:
        log("nightly-next: no unfinished nightly or promotion run")
    for listed in runs:
        try:
            run, job, started_waiting = read_stuck(api, listed.id, now)
        except Unreadable as why:
            log(f"nightly-next run {listed.id}: could not be read ({why}); left alone")
            continue
        if job is None:
            if started_waiting:
                log(f"nightly-next run {run.id} ({run.event}, {run.head_sha[:12]}): started, waiting on a runner")
            else:
                log(f"nightly-next run {run.id} ({run.event}, {run.head_sha[:12]}): running or waiting, no job stuck without a runner")
            continue
        warn(f"run {run.id} is stuck ({job.name} was created {int((now() - job.created).total_seconds() // 60)} min ago "
             f"and is queued with no runner on {','.join(job.labels)}); a nightly run is never cancelled: it waits, "
             "and once it ends the jobs that never got a runner are re-run")
    rerun_lost(api, tip, log, warn)


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: nightly_next_stuck_run.py OWNER/REPO", file=sys.stderr)
        return 2
    tick(Api(argv[1], ls_remote=ls_remote_sha))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
