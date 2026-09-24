#!/usr/bin/env python3
"""Move a pull request CI run off a busy persistent macOS pool.

pr_runner_pool.py puts every macOS job of a run on one pool. When that pool is
owned (a `glaeda-<class>-xcode-<version>` label, pr_runner_pool.persistent),
GitHub never re-routes a queued job: it waits for that pool however long the
pool stays busy. ci-owned-pool-rescue.yml starts this script when a CI run is
requested, from the default branch, with Actions write.

The script waits for ci.yml's `changes` job, which runs the picker. When the
picker chose a persistent pool, that job uploads a marker artifact
(`macos-pool-persistent-<run id>-<attempt>-<jobs>-<pool>`, the jobs and pool
for the janitor's count); no marker means the run is on an
ephemeral pool and the watch ends. Otherwise it watches the run's jobs until the
run finishes. If a job on the persistent pool is still queued with no runner
after the budget (CI_OWNED_POOL_RESCUE_SECONDS, 90 by default), it confirms the
pull request head has not moved, cancels the run, waits for it to finish, and
re-runs it. The re-run is attempt 2, and pr_runner_pool.py never gives a
retry attempt a persistent pool, so every macOS job of the re-run lands on
Blacksmith together. A run is never split
across pools, because app-host products only load under the Xcode that linked
them (#14163); that is why the whole run is re-run, not one job.

An owned runner can also refuse a job it was handed: glaeda's job-started
hook exits 1 when the host is busy (its lock is held), and the job fails
within seconds, before any step of the workflow succeeds. GitHub does not
retry it, so the pull request would stay red until someone re-ran it. A job
on the persistent pool that failed within REFUSAL_SECONDS of starting, with
its runner setup step failed or no workflow step succeeded, counts as refused
(compile admission's `always()` metrics steps still succeed after a refusal): the watcher confirms the head has
not moved, cancels the run if it is still going, and re-runs its failed jobs.
That attempt 2 reuses attempt 1's outputs, so every macOS job in it takes
retry_runner, the Blacksmith pool the picker named, and what already passed
(compile admission, say) is kept. That splits the run across machines, which
is sound only because both sides run the same Xcode: retry_runner is a macOS
26 pool on the lane's pin, the pin the owned label names, and on 2026-09-24
both the minis and Blacksmith's 6vcpu and 12vcpu macOS 26 images reported
Xcode 26.6 build 17F113. If those builds ever differ, re-run the whole run
here instead (rescue with failed_only=False).

E2E runs (test-e2e.yml) are watched the same way. Its `runner` job runs
e2e_runner_pool.py, which may pick an owned pool, and uploads the same marker
(with 1 job). An E2E run is a workflow_dispatch, not a pull request, so there
is no head to re-check, and its build and test jobs are not a split that can
break: from attempt 2 on both take the runner job's retry_label, a macOS 26
Blacksmith pool on the same Xcode build. So a stuck or refused E2E job always
gets its failed and cancelled jobs re-run, keeping a build that passed. Its
watch lasts E2E_WATCH_LIMIT_SECONDS, since its test job queues only after a
sibling wait and a build.

A job's wait is measured from the later of its `created_at` and the first
time the watcher saw it queued, so a job record created before its `needs`
were met can never count as already past the budget.

It stops watching, doing nothing, when:
- owned pools are off (CI_PR_POOL_OWNED is not 1), before any API request;
- the run is not attempt 1 of a same-repository pull request run of ci.yml;
- `changes` finished without a marker: the run is on an ephemeral pool;
- the run finished, or the watch limit passed.

Request budget: the GITHUB_TOKEN allows about 1000 requests an hour for the
whole repository. A run on an ephemeral pool costs a jobs listing every
POLL_SECONDS until `changes` finishes (usually two or three) plus one artifact
listing. A run on a persistent pool adds a jobs listing every POLL_SECONDS
while one of its jobs waits for a runner and every IDLE_POLL_SECONDS otherwise,
about 30 in all for an hour-long run. A read that fails is retried
READ_ATTEMPTS times before the watch gives up; a failed cancel or re-run is
never retried.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import http.client
import json
import os
import sys
import time
import urllib.error
import urllib.request
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pr_runner_pool import persistent  # noqa: E402

CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
E2E_WORKFLOW_PATH = ".github/workflows/test-e2e.yml"
# ci.yml's job that runs the pool picker; its jobs-API name (no `name:` override).
PICKER_JOB = "changes"
# test-e2e.yml's job that runs e2e_runner_pool.py.
E2E_PICKER_JOB = "runner"
DEFAULT_BUDGET_SECONDS = 90
MIN_BUDGET_SECONDS = 30
MAX_BUDGET_SECONDS = 600
FIRST_LOOK_SECONDS = 45
POLL_SECONDS = 20
IDLE_POLL_SECONDS = 120
# Long enough for a compile-only pull request run and its consumers to queue.
WATCH_LIMIT_SECONDS = 60 * 60
# An E2E test job queues after a sibling wait (up to 35 min) and a build.
E2E_WATCH_LIMIT_SECONDS = 150 * 60
READ_ATTEMPTS = 3
READ_RETRY_SECONDS = 10
MARKER_PREFIX = "macos-pool-persistent"
CANCEL_WAIT_SECONDS = 180
FORCE_CANCEL_AFTER_SECONDS = 90
# A refused job fails in seconds; a real failure of the first step after
# checkout takes longer than this, and one that does not is cheap to retry.
REFUSAL_SECONDS = 120
# The runner's own steps, which run before glaeda's hook decides.
SETUP_STEPS = frozenset({"Set up job", "Set up runner"})
MAX_JOB_PAGES = 3
API = "https://api.github.com"


def budget(value: str | None) -> int | None:
    """The queued-seconds budget from the variable, or None when it is invalid."""
    raw = (value or "").strip()
    if not raw:
        return DEFAULT_BUDGET_SECONDS
    try:
        seconds = int(raw)
    except ValueError:
        return None
    return seconds if MIN_BUDGET_SECONDS <= seconds <= MAX_BUDGET_SECONDS else None


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def job_pool(job: Mapping[str, Any]) -> str | None:
    """The owned pool a job asked for, if any."""
    for label in job.get("labels") or []:
        if persistent(str(label)):
            return str(label)
    return None


def waiting_for_runner(job: Mapping[str, Any]) -> bool:
    return job.get("status") == "queued" and not job.get("runner_name")


def queued_seconds(job: Mapping[str, Any], now: dt.datetime, first_seen: dt.datetime | None = None) -> float:
    created = parse_time(job.get("created_at"))
    since = max(filter(None, (created, first_seen)), default=None)
    return 0.0 if since is None else max(0.0, (now - since).total_seconds())


def refused(job: Mapping[str, Any]) -> bool:
    """A job the owned runner refused at job start (see the module docstring)."""
    if not job_pool(job) or job.get("status") != "completed" or job.get("conclusion") != "failure":
        return False
    started, completed = parse_time(job.get("started_at")), parse_time(job.get("completed_at"))
    if started is None or completed is None or (completed - started).total_seconds() > REFUSAL_SECONDS:
        return False
    steps = [step for step in job.get("steps") or [] if isinstance(step, Mapping)]
    # The hook runs inside the runner's own setup, so a failed setup step is a
    # refusal even when the job's `always()` steps still ran and succeeded.
    if any(step.get("name") in SETUP_STEPS and step.get("conclusion") == "failure" for step in steps):
        return True
    return not any(step.get("conclusion") == "success" and step.get("name") not in SETUP_STEPS
                   for step in steps)


def picker_finished(jobs: Sequence[Mapping[str, Any]], picker_job: str = PICKER_JOB) -> bool:
    picker = [job for job in jobs if job.get("name") == picker_job]
    return bool(picker) and all(job.get("status") == "completed" for job in picker)


def run_finished(jobs: Sequence[Mapping[str, Any]]) -> bool:
    return bool(jobs) and all(job.get("status") == "completed" for job in jobs)


@dataclasses.dataclass(frozen=True)
class Look:
    action: str  # "rescue" (cancel, re-run all), "refused" (re-run failed jobs) or "watch"
    reason: str
    waiting: bool = False  # a persistent-pool job has no runner yet


def assess(jobs: Sequence[Mapping[str, Any]], *, now: dt.datetime, budget_seconds: int,
           first_seen: Mapping[Any, dt.datetime] | None = None) -> Look:
    """One look at the jobs of a run on a persistent pool."""
    seen = first_seen or {}
    waiting = [job for job in jobs if job_pool(job) and waiting_for_runner(job)]
    stuck = [job for job in waiting if queued_seconds(job, now, seen.get(job.get("id"))) >= budget_seconds]
    if stuck:
        names = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in stuck))
        return Look("rescue", f"{names} queued on {job_pool(stuck[0])} for at least "
                              f"{budget_seconds}s with no runner")
    turned_away = [job for job in jobs if refused(job)]
    if turned_away:
        names = ", ".join(sorted(str(job.get("name") or job.get("id")) for job in turned_away))
        return Look("refused", f"{names} refused by {job_pool(turned_away[0])} at job start")
    if waiting:
        return Look("watch", f"{len(waiting)} job(s) waiting for a persistent runner", waiting=True)
    return Look("watch", "no job is waiting for a persistent runner")


class Aborted(Exception):
    pass


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-owned-pool-rescue",
        }

    def request(self, method: str, path: str) -> Any:
        request = urllib.request.Request(f"{API}/repos/{self.repo}{path}", method=method, headers=self.headers)
        with urllib.request.urlopen(request, timeout=20) as response:
            body = response.read()
        return json.loads(body) if body else None

    def run(self, run_id: int) -> Mapping[str, Any]:
        return self.request("GET", f"/actions/runs/{run_id}")

    def jobs(self, run_id: int, attempt: int) -> list[Mapping[str, Any]]:
        found: list[Mapping[str, Any]] = []
        for page in range(1, MAX_JOB_PAGES + 1):
            data = self.request("GET", f"/actions/runs/{run_id}/attempts/{attempt}/jobs?per_page=100&page={page}")
            batch = [job for job in (data or {}).get("jobs") or [] if isinstance(job, Mapping)]
            found.extend(batch)
            if len(batch) < 100:
                break
        return found

    def has_artifact(self, run_id: int, prefix: str, pages: int = 5) -> bool:
        """Whether the run uploaded an artifact whose name starts with `prefix`."""
        for page in range(1, pages + 1):
            data = self.request("GET", f"/actions/runs/{run_id}/artifacts?per_page=100&page={page}")
            names = [str(item.get("name") or "") for item in (data or {}).get("artifacts") or []]
            if any(name.startswith(prefix) for name in names):
                return True
            if len(names) < 100:
                return False
        return False

    def pull(self, number: int) -> Mapping[str, Any]:
        return self.request("GET", f"/pulls/{number}")

    def cancel(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/cancel")

    def force_cancel(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/force-cancel")

    def rerun(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/rerun")

    def rerun_failed(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/rerun-failed-jobs")


@dataclasses.dataclass
class Target:
    run_id: int
    attempt: int
    head_sha: str
    pr_number: int  # 0 for an E2E dispatch, which has no pull request
    e2e: bool = False

    @property
    def picker_job(self) -> str:
        return E2E_PICKER_JOB if self.e2e else PICKER_JOB

    @property
    def watch_limit(self) -> int:
        return E2E_WATCH_LIMIT_SECONDS if self.e2e else WATCH_LIMIT_SECONDS


def target_from_event(event: Mapping[str, Any], repository: str) -> Target | str:
    """The CI or E2E run to watch, or why this event is not one."""
    run = event.get("workflow_run") or {}
    path = run.get("path")
    if path not in (CI_WORKFLOW_PATH, E2E_WORKFLOW_PATH):
        return f"started by {path or 'an unknown workflow'}, not {CI_WORKFLOW_PATH} or {E2E_WORKFLOW_PATH}"
    e2e = path == E2E_WORKFLOW_PATH
    expected = "workflow_dispatch" if e2e else "pull_request"
    if run.get("event") != expected:
        return f"a {run.get('event') or 'unknown'} run of {path}, not a {expected}"
    head = (run.get("head_repository") or {}).get("full_name") or ""
    if head.casefold() != repository.casefold():
        return "a fork head; forks never take a persistent pool"
    attempt = int(run.get("run_attempt") or 0)
    if attempt != 1:
        return f"attempt {attempt}; a retry attempt never takes a persistent pool"
    if e2e:
        return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), 0, e2e=True)
    pulls = [pr for pr in run.get("pull_requests") or [] if isinstance(pr, Mapping) and pr.get("number")]
    if len(pulls) != 1:
        return "the run does not name exactly one pull request"
    return Target(int(run["id"]), attempt, str(run.get("head_sha") or ""), int(pulls[0]["number"]))


def marker_name(target: Target) -> str:
    """The marker's name up to its jobs and pool, which only the janitor reads."""
    return f"{MARKER_PREFIX}-{target.run_id}-{target.attempt}-"


READ_ERRORS = (urllib.error.URLError, http.client.HTTPException, OSError, ValueError)


def read(call: Callable[[], Any], sleep: Callable[[float], None], log: Callable[[str], None]) -> Any:
    """A GET, retried: one transient error must not end the watch it exists for."""
    for attempt in range(1, READ_ATTEMPTS + 1):
        try:
            return call()
        except READ_ERRORS as error:
            if attempt == READ_ATTEMPTS:
                raise
            log(f"read failed ({error}); retrying")
            sleep(READ_RETRY_SECONDS * attempt)
    raise AssertionError("unreachable")


def watch(api: GitHub, target: Target, *, budget_seconds: int,
          now: Callable[[], dt.datetime], sleep: Callable[[float], None],
          log: Callable[[str], None]) -> tuple[str, str]:
    """Watch until a stop or a rescue. Returns (outcome, reason)."""
    started = now()
    sleep(FIRST_LOOK_SECONDS)
    looks = 0
    on_persistent = False
    first_seen: dict[Any, dt.datetime] = {}
    while True:
        looks += 1
        jobs = read(lambda: api.jobs(target.run_id, target.attempt), sleep, log)
        if not on_persistent:
            if picker_finished(jobs, target.picker_job):
                if not read(lambda: api.has_artifact(target.run_id, marker_name(target)), sleep, log):
                    return "stop", "the run is on an ephemeral pool"
                on_persistent = True
                log("the picker chose a persistent pool")
            elif run_finished(jobs):
                return "stop", "the run finished before the pool choice"
        interval = POLL_SECONDS
        if on_persistent:
            if any(refused(job) for job in jobs):
                look = assess(jobs, now=now(), budget_seconds=budget_seconds, first_seen=first_seen)
                log(f"look {looks}: {look.reason}")
                return look.action, look.reason
            if run_finished(jobs) and read(lambda: api.run(target.run_id), sleep, log).get("status") == "completed":
                return "stop", "the run finished"
            seen_at = now()
            for job in jobs:
                if job_pool(job) and waiting_for_runner(job):
                    first_seen.setdefault(job.get("id"), seen_at)
            look = assess(jobs, now=seen_at, budget_seconds=budget_seconds, first_seen=first_seen)
            log(f"look {looks}: {look.reason}")
            if look.action in ("rescue", "refused"):
                return look.action, look.reason
            if not look.waiting:
                interval = IDLE_POLL_SECONDS
        if (now() - started).total_seconds() >= target.watch_limit:
            return "stop", "watch limit reached"
        sleep(interval)


def pull_moved(api: GitHub, target: Target, sleep: Callable[[float], None],
               log: Callable[[str], None]) -> str:
    """Why the pull request no longer wants this run, or "" when it still does."""
    if target.e2e:
        return ""  # a dispatch has no head to move; a newer one cancels it by concurrency
    pull = read(lambda: api.pull(target.pr_number), sleep, log)
    if pull.get("state") != "open":
        return "the pull request is closed"
    if (pull.get("head") or {}).get("sha") != target.head_sha:
        return "the pull request has a newer head, whose own run replaces this one"
    return ""


def rescue(api: GitHub, target: Target, *, now: Callable[[], dt.datetime], sleep: Callable[[float], None],
           log: Callable[[str], None], failed_only: bool = False, refused: bool | None = None) -> str:
    """Cancel and re-run, unless the pull request has moved on. Returns what happened.

    `failed_only` (a refused job) re-runs only the failed and cancelled jobs,
    keeping what passed. Only a refusal (`refused`, which defaults to
    `failed_only`) re-runs a run that already finished: an E2E run that
    finished otherwise may have been cancelled by a newer dispatch of the same
    group, which re-running it would cancel in turn.
    """
    moved = pull_moved(api, target, sleep, log)
    if moved:
        return f"not rescued: {moved}"
    run = read(lambda: api.run(target.run_id), sleep, log)
    if int(run.get("run_attempt") or 0) != target.attempt:
        return "not rescued: someone else already re-ran the run"
    if run.get("status") == "completed":
        if not (failed_only if refused is None else refused):
            return "not rescued: the run already finished"
        api.rerun_failed(target.run_id)
        return f"re-ran the failed jobs of run {target.run_id}; attempt {target.attempt + 1} takes retry_runner"
    api.cancel(target.run_id)
    log(f"cancelled run {target.run_id}")
    started = now()
    forced = False
    while True:
        sleep(10)
        run = read(lambda: api.run(target.run_id), sleep, log)
        if int(run.get("run_attempt") or 0) != target.attempt:
            return "not rescued: someone else already re-ran the run"
        if run.get("status") == "completed":
            break
        waited = (now() - started).total_seconds()
        if not forced and waited >= FORCE_CANCEL_AFTER_SECONDS:
            api.force_cancel(target.run_id)
            forced = True
            log(f"force-cancelled run {target.run_id}")
        if waited >= CANCEL_WAIT_SECONDS:
            raise Aborted(f"run {target.run_id} did not finish {CANCEL_WAIT_SECONDS}s after cancel; not re-run")
    # A push during the cancel starts the new head's run; re-running the old
    # head now would join its concurrency group and cancel it.
    moved = pull_moved(api, target, sleep, log)
    if moved:
        return f"cancelled but not re-run: {moved}"
    if failed_only:
        api.rerun_failed(target.run_id)
        return f"re-ran the failed jobs of run {target.run_id}; attempt {target.attempt + 1} takes retry_runner"
    api.rerun(target.run_id)
    return f"re-ran run {target.run_id}; attempt {target.attempt + 1} takes an ephemeral pool"


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None, *,
         api: GitHub | None = None, now: Callable[[], dt.datetime] | None = None,
         sleep: Callable[[float], None] = time.sleep) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.parse_args(argv)
    clock = now or (lambda: dt.datetime.now(dt.timezone.utc))
    lines: list[str] = []

    def log(text: str) -> None:
        print(text, flush=True)
        lines.append(text)

    def finish(outcome: str) -> int:
        log(outcome)
        if env.get("GITHUB_STEP_SUMMARY"):
            with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
                handle.write("### Persistent-pool rescue\n\n" + "\n".join(f"- {line}" for line in lines) + "\n")
        return 0

    if (env.get("POOL_OWNED") or "").strip() != "1":
        return finish("owned pools are off (CI_PR_POOL_OWNED is not 1); nothing to watch")
    seconds = budget(env.get("RESCUE_SECONDS"))
    if seconds is None:
        return finish(f"CI_OWNED_POOL_RESCUE_SECONDS must be {MIN_BUDGET_SECONDS} to {MAX_BUDGET_SECONDS}; "
                      "nothing to watch")
    repository = env.get("GITHUB_REPOSITORY") or ""
    with open(env["GITHUB_EVENT_PATH"], encoding="utf-8") as handle:
        event = json.load(handle)
    target = target_from_event(event, repository)
    if isinstance(target, str):
        return finish(f"not watched: {target}")
    client = api or GitHub(env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or "", repository)
    subject = "an E2E dispatch" if target.e2e else f"pull request #{target.pr_number}"
    log(f"watching run {target.run_id} of {subject} (budget {seconds}s)")
    try:
        outcome, reason = watch(client, target, budget_seconds=seconds, now=clock, sleep=sleep, log=log)
        if outcome not in ("rescue", "refused"):
            return finish(f"stopped: {reason}")
        log(f"{'rescue' if outcome == 'rescue' else 'refused'}: {reason}")
        # An E2E run's jobs may split across pools (see the module docstring),
        # so it keeps a build that passed.
        failed_only = outcome == "refused" or target.e2e
        return finish(rescue(client, target, now=clock, sleep=sleep, log=log, failed_only=failed_only,
                             refused=outcome == "refused"))
    except (*READ_ERRORS, Aborted) as error:
        # A failed watch leaves the run exactly as GitHub scheduled it.
        finish(f"gave up: {error}")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
