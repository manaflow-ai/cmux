#!/usr/bin/env python3
"""Cancel a nightly-next build or promotion run that is stuck on a runner label that stopped serving.

GitHub fixes a job's runner label when it creates the job. If that label stops serving, the job waits
forever, and changing the runner repository variables does not move it. Run 40771197361 (tip
1f0f687b, 2026-10-28) had `decide` waiting 34 minutes on blacksmith-4vcpu-ubuntu-2404, with more jobs
queued behind it, while every Blacksmith Linux label had stopped starting jobs. A re-run creates new
jobs, which evaluate their runs-on again, so the way out is to cancel the run and build it again.

This step only cancels, and only a run that an existing path builds again:
  - the tip's push run on nightly-next below MAX_ATTEMPTS: the next tick step,
    nightly_next_cancelled_tip.sh, re-runs a tip whose newest push run ended cancelled;
  - an older commit's run on nightly-next (push or dispatch): the tip builds instead (rulebook,
    Nightly freshness: stuck runs of older commits are skipped and the tip builds);
  - a promotion on main ("Promote nightly-next to ..."): the tick's promotion request asks again.
A dispatch of the tip, and the tip's push run at MAX_ATTEMPTS, are left alone with a warning: no path
here builds them again, and a cancelled run that nothing rebuilds is worse than a stuck one.

The rulebook allows cancelling a started nightly only when it is stuck past its timeout or certain to
fail. A run is stuck here only when all of these hold, read twice (the second read right before the
cancel, so a runner taking the job or a gate appearing in between keeps the run):
  - the run is `queued` or `in_progress` and has no pending deployment (a run waiting on an
    environment or a concurrency group is gated, not stuck);
  - a job has waited STUCK_MINUTES (3) `queued` with no runner, counted no earlier than the
    latest executed job's completion (job records can predate their dependencies), on labels none of which is owned
    (glaeda-* jobs belong to the owned-pool rescue, owned_pool_rescue.py);
  - every other job is `completed` or also `queued` with no runner.
A newer tip is never a reason to cancel.

Fail-closed: every Actions object is read through one typed reader (`Run`, `Job` below). A field that
is missing, of the wrong JSON type, or outside its enum (status, conclusion, and their pairing: a
completed object has a conclusion, an unfinished one has none), a list that is not a list, or a
paginated listing whose count does not add up, is Unreadable, and nothing is cancelled for that run
or, for a listing, that tick. The writes go out once, with no wrapper retries
(GH_BUDGET_WAIT_ATTEMPTS=1, gh_budget_wait.sh), so a cancel never lands long after the read that
justified it. After the cancel the run is read every SETTLE_SECONDS, at most FORCE_AFTER + 1 times;
a force-cancel is sent only when the run is still `queued` or `in_progress` on the same attempt and a
fresh stuck read still says so. A run that moves to a gate state, a new attempt, or that cannot be
read, gets nothing more.

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
import time
from collections.abc import Callable, Sequence
from typing import Any

STUCK_MINUTES = float(os.environ.get("STUCK_MINUTES", "3"))
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "3"))  # nightly_next_cancelled_tip.sh's bound
SETTLE_SECONDS = float(os.environ.get("SETTLE_SECONDS", "15"))
FORCE_AFTER = int(os.environ.get("FORCE_AFTER", "6"))
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
    """An answer that failed, or that is not the shape this reads. Nothing is cancelled on it."""


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


class Api:
    def __init__(self, repo: str, gh: Gh = gh_cli):
        self.repo, self.gh = repo, gh

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

    def cancel(self, run_id: int, force: bool = False) -> None:
        self.gh(["api", "-X", "POST", f"repos/{self.repo}/actions/runs/{run_id}/{'force-cancel' if force else 'cancel'}"], True)


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


def read_stuck(api: Api, run_id: int,
               now: Callable[[], dt.datetime]) -> tuple[Run, Job | None, bool, bool]:
    run = api.run(run_id)
    if run.status not in ("queued", "in_progress"):
        return run, None, False, False
    if api.pending_deployments(run_id):
        return run, None, False, False
    jobs = api.jobs(run_id)
    started = any(started_job(job) for job in jobs) and not any(timed_out_job(job) for job in jobs)
    started_waiting = started and any(queued_without_runner(job) for job in jobs)
    return run, stuck_job(run, jobs, now()), started, started_waiting


def rebuilt_by(run: Run, tip: str) -> str | None:
    """Which existing path builds the run's commit again once it is cancelled, or None."""
    if run.event == "workflow_dispatch" and run.title.startswith(PROMOTION_TITLE):
        if run.branch == "main" and os.environ.get("NIGHTLY_NEXT_TRAIN") != "on":
            return "the tick's promotion request asks again"
        return None
    if run.branch != "nightly-next":
        return None
    if run.head_sha != tip:
        return "an older commit's run; the tip builds"
    if run.event == "push" and run.attempt < MAX_ATTEMPTS:
        return "the next step (nightly_next_cancelled_tip.sh) re-runs the tip"
    return None


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


def settle(api: Api, run_id: int, attempt: int, sleep: Callable[[float], None]) -> str:
    """'cancelled', 'finished' (some other conclusion), 'running' (still queued or in progress on the
    same attempt after every read), or 'moved' (a gate state, a new attempt, or unreadable)."""
    for i in range(FORCE_AFTER + 1):
        if i:
            sleep(SETTLE_SECONDS)
        try:
            run = api.run(run_id)
        except Unreadable:
            return "moved"
        if run.attempt != attempt:
            return "moved"
        if run.status == "completed":
            return "cancelled" if run.conclusion == "cancelled" else "finished"
        if run.status not in ("queued", "in_progress"):
            return "moved"
    return "running"


def tick(api: Api, log: Callable[[str], None] = print, sleep: Callable[[float], None] = time.sleep,
         now: Callable[[], dt.datetime] = lambda: dt.datetime.now(dt.timezone.utc)) -> None:
    def warn(message: str) -> None:
        log(f"::warning title=nightly-next tick::{message}")

    try:
        tip = api.tip()
        runs = candidates(api)
    except Unreadable as why:
        warn(f"the nightly runs could not be read ({why}); no run is cancelled this tick")
        return
    if not runs:
        log("nightly-next: no unfinished nightly or promotion run")
        return
    for listed in runs:
        try:
            run, job, started, started_waiting = read_stuck(api, listed.id, now)
        except Unreadable as why:
            log(f"nightly-next run {listed.id}: could not be read ({why}); left alone")
            continue
        if job is None:
            if started_waiting:
                log(f"nightly-next run {run.id} ({run.event}, {run.head_sha[:12]}): started, waiting on a runner")
            else:
                log(f"nightly-next run {run.id} ({run.event}, {run.head_sha[:12]}): running or waiting, no job stuck without a runner")
            continue
        why = (f"{job.name} was created {int((now() - job.created).total_seconds() // 60)} min ago "
               f"and is queued with no runner on {','.join(job.labels)}")
        path = rebuilt_by(run, tip)
        if path is None:
            warn(f"run {run.id} is stuck ({why}), but it is the tip's {run.event} run on attempt {run.attempt}, "
                 "which nothing here builds again; left queued")
            continue
        try:
            # Read the branch tip before the final job snapshot. A runner can start
            # while a tip read is retried; the subsequent job read must observe it
            # before either cancellation write.
            current_tip = api.tip()
            again, still, started_again, _ = read_stuck(api, run.id, now)
        except Unreadable as error:
            log(f"nightly-next run {run.id}: could not be read again ({error}); left alone")
            continue
        if still is None or started_again or again.attempt != run.attempt:
            log(f"nightly-next run {run.id}: changed since it was read (a runner, a gate or a new attempt); left alone")
            continue
        try:
            # Discovery and earlier runs' settle waits can span a promotion. Re-evaluate
            # against the branch tip read immediately before the final job snapshot.
            path = rebuilt_by(again, current_tip)
            if path is None:
                log(f"nightly-next run {run.id}: no current rebuild path; left alone")
                continue
            api.cancel(run.id)
        except Unreadable as error:
            warn(f"run {run.id} is stuck ({why}), but the cancel was refused ({error}); the next tick reads it again")
            continue
        state = settle(api, run.id, run.attempt, sleep)
        if state == "running":
            try:
                current_tip = api.tip()
                again, still, started_again, _ = read_stuck(api, run.id, now)
            except Unreadable:
                still = None
            if still is not None and not started_again and again.attempt == run.attempt:
                try:
                    if rebuilt_by(again, current_tip) is None:
                        log(f"nightly-next run {run.id}: no current rebuild path; not force-cancelled")
                        continue
                    api.cancel(run.id, force=True)
                except Unreadable as error:
                    warn(f"run {run.id} did not finish after its cancel and the force-cancel was refused ({error})")
                    continue
                state = settle(api, run.id, run.attempt, sleep)
            else:
                state = "moved"
        if state == "cancelled":
            log(f"::notice title=nightly-next tick::cancelled run {run.id} ({run.event}, {run.head_sha[:12]}, "
                f"attempt {run.attempt}): {why}; {path}")
        elif state == "finished":
            log(f"nightly-next run {run.id}: finished on its own before the cancel took")
        else:
            warn(f"run {run.id} is stuck ({why}); the cancel was sent but it has not been seen finished; "
                 "the next tick reads it again")


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("usage: nightly_next_stuck_run.py OWNER/REPO", file=sys.stderr)
        return 2
    tick(Api(argv[1]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
