#!/usr/bin/env python3
"""Fail a declared hosted light job over to its re-run route when GitHub-hosted Ubuntu never assigns it a runner.

The jobs in .github/runners.json `hosted_light_jobs` (resolvers, routers, report steps) take GitHub-hosted
`ubuntu-24.04` on attempt 1 and RUNNER_POOLS.linux (or their declared fallback) on a re-run:
`github.run_attempt == 1 && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux` (cmux#31785, cmux#31878). The
fallback only exists on a re-run, and nothing re-ran one: ci-hosted-queue-rescue.yml watches only CI, CLA and CI
fast guards, and only once GitHub itself cancels a whole run after about 15 minutes; the queue janitor's lost-
assignment pass waits 30 minutes and needs a newer job on the same labels taken. The rulebook's stall-aware
failover is about 3 minutes.

The existing owned-pool sweeper runs this on a separate workflow-token client every minute.
An independent scheduled workflow wakes that same concurrency owner when it is not running; it never
cancels or re-runs target jobs itself. Each pass:

- lists the repository's in-flight (`queued`, `in_progress`) pull request runs, created STALL_SECONDS to WINDOW
  ago, in one repository-wide listing per status (the newest page; the second while the first is full; one
  rotating overflow page from the third while the second is full), and keeps those of the workflow files that
  declare a hosted light job: 2-6 requests a pass instead of 24-48 (cmux#35099 measured 50-100 requests a minute
  against the repository's 1,000-an-hour GITHUB_TOKEN pool);
- retains discovered candidates within WINDOW and reads the jobs of at most MAX_RUNS of them (plus one re-read
  per rescue, so at most MAX_RUNS + MAX_RESCUES) (attempt 1 only, at the pull request's current head); the first
  pass is oldest first and later passes rotate from an in-memory cursor;
- finds a stalled job: queued, no runner id or name, every label a GitHub-hosted `ubuntu-*` label (in this repo only
  declared hosted light jobs may ask for one, tests/test_ci_self_hosted_guard.sh), created STALL_SECONDS or more ago;
- when every unfinished job of the run is such a stalled job (so the cancel stops nothing that is running), cancels
  the run, waits (within SETTLE_BUDGET_S for the whole pass) for the cancel to settle, and re-runs its failed jobs.
  The re-run is attempt 2, so each re-run job takes its fallback route; jobs that already passed keep their result.

Bounds: only pull request runs (never push, schedule, dispatch, nightly, DEV, promote or release runs), only attempt
1 (so a job is failed over at most once), only runs at their pull request's current head, at most MAX_RESCUES
recovery attempts a pass, and a run with any other unfinished job is left alone and reported. Confirmed rescue
cancellations have durable log receipts. A later minute or successor may resume only those receipts, after reading
the live attempt and current open PR again; incomplete history and unmarked cancellations never authorize a rerun.

Quota: reads go out as the cmux-bot App (HOSTED_LIGHT_TOKEN is its installation token when the workflow minted one;
with BOT_APP_ID and BOT_APP_KEY a new one is minted before the hour is up), whose installation pool is its own. The
workflow token (HOSTED_LIGHT_FALLBACK_TOKEN) is the repository's one GITHUB_TOKEN pool (1,000 requests an hour on this
plan), shared by every workflow, the NEXT nightly's tick and notarization among them; it is read only while the
App's pool is down to POOL_RESERVE or the App token is refused. A pass makes no new listing or job read once both
pools are down to POOL_RESERVE until a reset (owned recovery still finishes), and an unreadable recovery journal is
read again only every JOURNAL_RETRY, not every minute. Cancels, re-runs and the sweeper wake stay on the workflow
token, as before.
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

UTC = dt.timezone.utc
HOSTED_LABEL = re.compile(r"^ubuntu-[0-9][\w.-]*$")
# The stall-aware failover's bound: a hosted light job is 2-50 s of work, and on 2026-11-02 27 of them sampled
# between 07:36Z and 08:25Z waited 1-94 s for a runner (median about 10 s).
STALL_SECONDS = 180
# Runs older than this are not listed: GitHub cancels a hosted job that never got a runner well before it.
WINDOW = dt.timedelta(minutes=90)
MAX_RUNS = 40
MAX_RESCUES = 10
MAX_RUN_LIST_PAGES = 10
LIST_PAGE = 100
# Left in the repository's GITHUB_TOKEN pool for every other workflow. On 2026-11-04 this pass alone made
# about 50-100 requests a minute (24 listings, 40 job reads and a 10-page journal read that always failed) and
# spent the 1,000-request pool within minutes of each reset (sweeper run 41788968966 logged 403s on every read
# from 07:06Z); the NEXT nightly tick and its notarization
# preflight then failed with "API rate limit exceeded for installation" (runs 41791114042, 41790985234).
POOL_RESERVE = 500
JOURNAL_RETRY = dt.timedelta(minutes=15)
SETTLE_BUDGET_S = 90.0
SETTLE_INTERVAL_S = 5.0
RERUN_TRIES = 3
LIGHT_CANCEL_SENT = "hosted-light rescue: cancel sent, re-run to follow:"
LIGHT_CANCEL_SETTLED = "hosted-light rescue: cancel settled:"
EVENTS = frozenset({"pull_request"})
IN_FLIGHT = ("queued", "in_progress")
# Workflows a pass never touches, whatever runners.json declares: the nightly picks its own routes.
EXCLUDED_WORKFLOWS = frozenset({"nightly.yml"})


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_time(value: object) -> dt.datetime | None:
    if not isinstance(value, str) or not value:
        return None
    try:
        moment = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return moment if moment.tzinfo is not None else None


def declared_workflows(runners: Mapping[str, Any]) -> list[str]:
    """PR-triggered workflow files with a hosted light job.

    A colon key (the main-branch ``file.yml:job`` form) can describe a
    workflow_dispatch admission such as fast-checks. Those runs test an
    explicit snapshot input rather than a pull-request head, so this PR-only
    rescue cannot prove current-head provenance and excludes them. The
    declaration remains available to the runner policy and its own failover.
    """
    table = runners.get("hosted_light_jobs")
    if not isinstance(table, Mapping):
        return []
    files = {str(key).split("#", 1)[0] for key in table
             if not str(key).startswith("$") and "#" in str(key)}
    return sorted(name for name in files if name.endswith((".yml", ".yaml")) and name not in EXCLUDED_WORKFLOWS)


def with_callers(workflows: Sequence[str], directory: Path | None) -> list[str]:
    """`workflows` plus every workflow in `directory` that calls one of them (transitively).

    A reusable workflow (`workflow_call`: pr-red-checks-comment.yml, ci-guards.yml) has no runs of its own; its jobs
    run in the caller's run (cmux-next.yml, cmux-next-guards.yml, ci.yml), so those are the runs to list."""
    found = set(workflows)
    if directory is None or not directory.is_dir():
        return sorted(found)
    texts = {}
    for path in sorted(directory.iterdir()):
        if path.suffix in (".yml", ".yaml") and path.name not in EXCLUDED_WORKFLOWS:
            try:
                texts[path.name] = path.read_text(encoding="utf-8")
            except OSError:
                continue
    while True:
        callers = {name for name, text in texts.items() if name not in found and any(
            re.search(rf"uses:\s*['\"]?\./\.github/workflows/{re.escape(callee)}['\"]?\s*$", text, re.MULTILINE)
            for callee in found)}
        if not callers:
            return sorted(found)
        found |= callers


APP_TOKEN_SECONDS = 50 * 60  # an installation token lasts an hour; mint the next one before it ends


class Pool:
    """One token's rate-limit pool as its last response reported it: None until a response carries it."""

    def __init__(self) -> None:
        self.remaining: int | None = None
        self.reset: float = 0.0

    def spare(self, now: float) -> bool:
        return self.remaining is None or self.remaining > POOL_RESERVE or now >= self.reset


class GitHub:
    def __init__(self, token: str, repo: str, write_token: str | None = None, *, fallback: str | None = None,
                 mint: Callable[[], str] | None = None, clock: Callable[[], float] = time.time) -> None:
        """READS go out with `token`; with `fallback` (the workflow token) they move to it while `token`'s pool is at
        POOL_RESERVE or `token` is refused. `mint` replaces `token` before its hour is up. Writes use `write_token`
        (default: `fallback`, else `token`)."""
        self.repo = repo
        self.token = token
        self.fallback = fallback if fallback and fallback != token else None
        self.write_token = write_token or self.fallback or token
        self.mint, self.clock = mint, clock
        self.minted_at = clock()
        self.pools: dict[str, Pool] = {"primary": Pool(), "fallback": Pool()}
        self.primary_refused_until = 0.0

        self.etags: dict[str, tuple[str, Any]] = {}
        self.history: Any = None
    @property
    def remaining(self) -> int | None:
        """The pool reads use now (for the pass's log line)."""
        return self.pools[self.read_pool()].remaining

    @property
    def reset(self) -> float:
        return self.pools[self.read_pool()].reset

    def note_limit(self, headers: Any, pool: str = "primary") -> None:
        """Record X-RateLimit-Remaining and -Reset from any response, a refusal or a 304 included."""
        try:
            remaining = headers.get("X-RateLimit-Remaining") if headers is not None else None
            reset = headers.get("X-RateLimit-Reset") if headers is not None else None
            if remaining is not None:
                self.pools[pool].remaining = int(remaining)
            if reset is not None:
                self.pools[pool].reset = float(reset)
        except (AttributeError, TypeError, ValueError):
            pass

    def read_pool(self, now: float | None = None) -> str:
        """`primary` while its pool is spare and it is not refused, else `fallback` when there is one."""
        now = self.clock() if now is None else now
        if self.fallback is None:
            return "primary"
        if now >= self.primary_refused_until and self.pools["primary"].spare(now):
            return "primary"
        return "fallback"

    def spare(self, now: dt.datetime) -> bool:
        """A read pool is above POOL_RESERVE, unknown, or past its reset: a pass may read."""
        return self.pools[self.read_pool(now.timestamp())].spare(now.timestamp())

    def read_token(self) -> tuple[str, str]:
        if self.mint is not None and self.clock() - self.minted_at >= APP_TOKEN_SECONDS:
            try:
                self.token, self.minted_at = self.mint(), self.clock()
            except Exception:  # noqa: BLE001 - keep the old token; a refusal moves reads to the fallback
                self.minted_at = self.clock() - APP_TOKEN_SECONDS + 300  # try again in five minutes
        pool = self.read_pool()
        return pool, (self.token if pool == "primary" else str(self.fallback))

    def pending_cancellations(self, now: dt.datetime) -> set[int]:
        """Restore only this worker's confirmed cancellations from the existing durable rescue log journal.

        The shared reader bounds history pages and log bytes and refuses incomplete history. It uses this
        worker's workflow token; the routing App is never involved. A live predecessor is not judged.
        """
        import owned_pool_rescue
        if self.history is None:
            self.history = owned_pool_rescue.GitHub(self.read_token()[1], self.repo)
            self.history.own_run = int(os.environ.get("GITHUB_RUN_ID") or 0)
            self.history.no_rate_limit_waits()
        states: dict[tuple[int, int], str] = {}
        for job_id in self.history.rescue_jobs(now - WINDOW):
            marks = self.history.job_marks(job_id)
            if marks is None:
                raise RuntimeError(f"rescue job {job_id}'s recovery journal could not be read whole")
            for pair, state in marks.items():
                states.setdefault(pair, state)  # newest completed rescue jobs first
        return {run_id for (run_id, attempt), state in states.items()
                if attempt == 1 and state == "sent hosted-light"}

    def request(self, method: str, path: str, payload: Mapping[str, Any] | None = None) -> Any:
        if method != "GET":
            return self._send(method, path, payload, self.write_token, "fallback" if self.fallback else "primary")
        pool, token = self.read_token()
        try:
            return self._send(method, path, payload, token, pool)
        except RuntimeError as error:
            refused = getattr(error, "code", None)
            if pool != "primary" or self.fallback is None or refused not in (401, 403, 429):
                raise
            # The App token was refused (expired, revoked or rate limited): the same read on the workflow token. A
            # refused GET did nothing, so the retry is safe; the App is tried again after its reset or 5 minutes.
            primary = self.pools["primary"]
            self.primary_refused_until = max(self.clock() + 300, primary.reset if primary.remaining == 0 else 0)
            return self._send(method, path, payload, str(self.fallback), "fallback")

    def _send(self, method: str, path: str, payload: Mapping[str, Any] | None, token: str, pool: str) -> Any:
        request = urllib.request.Request(
            f"https://api.github.com/repos/{self.repo}{path}", method=method,
            data=json.dumps(payload).encode() if payload is not None else b"" if method != "GET" else None,
            headers={"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
                     "Content-Type": "application/json",
                     "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-hosted-light-rescue"})
        # An ETag is per URL, not per token: a 304 answers whichever token asked.
        cached = self.etags.get(path) if method == "GET" else None
        if cached:
            request.add_header("If-None-Match", cached[0])
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                self.note_limit(response.headers, pool)
                body = response.read()
                result = json.loads(body) if body.strip() else {}
                if method == "GET" and response.headers.get("ETag"):
                    self.etags[path] = (response.headers["ETag"], result)
                return result
        except urllib.error.HTTPError as error:
            self.note_limit(error.headers, pool)
            if error.code == 304 and cached:
                return cached[1]
            refusal = RuntimeError(f"{method} {path}: HTTP {error.code}")
            refusal.code = error.code  # type: ignore[attr-defined]
            raise refusal from error

    def runs(self, workflow: str | None, status: str, start: dt.datetime, end: dt.datetime, *,
             page: int = 1) -> list[dict[str, Any]]:
        """One page of in-flight pull request runs: of one workflow file, or of the whole repository (None)."""
        # Filtered to pull_request runs server-side, so push and dispatch runs never fill the one page.
        query = urllib.parse.urlencode({"status": status, "event": "pull_request", "per_page": 100, "page": page,
                                        "created": f"{iso(start)}..{iso(end)}"})
        where = "/actions/runs" if workflow is None else f"/actions/workflows/{workflow}/runs"
        return list(self.request("GET", f"{where}?{query}").get("workflow_runs") or [])

    def jobs(self, run_id: int) -> list[dict[str, Any]]:
        page = self.request("GET", f"/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
        jobs = list(page.get("jobs") or [])
        if int(page.get("total_count") or 0) > len(jobs):
            # A second page may hide an unfinished job: stand one in, so verdict() calls the run gated.
            jobs.append({"name": "(jobs past the first page)", "status": "unknown"})
        return jobs

    def pull_head(self, number: int) -> str | None:
        pull = self.request("GET", f"/pulls/{number}")
        return pull.get("head", {}).get("sha") if pull.get("state") == "open" else None

    def run(self, run_id: int) -> dict[str, Any]:
        return self.request("GET", f"/actions/runs/{run_id}")

    def cancel(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/cancel")

    def rerun_failed(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/rerun-failed-jobs")

    def wake_sweeper(self) -> None:
        # The workflow's owned-pool-sweeper concurrency group is the one mutation owner. Repeated
        # wakes only refresh its pending handover; they cannot run a second cancellation pass.
        self.request("POST", "/actions/workflows/ci-owned-pool-rescue.yml/dispatches", {"ref": "main"})


REPOSITORY = "*"  # ScanState.pages key for the repository-wide listing


def workflow_file(run: Any) -> str | None:
    """The workflow file a listed run belongs to (`.github/workflows/ci.yml@ref` -> `ci.yml`), or None."""
    if not isinstance(run, Mapping):
        return None
    path = str(run.get("path") or "").split("@", 1)[0]
    return path.rsplit("/", 1)[-1] if path.startswith(".github/workflows/") else None


def at_head(run: Mapping[str, Any]) -> bool:
    """The run is at its pull request's current head (a stale head's result is read by nobody)."""
    prs = run.get("pull_requests") or []
    head = run.get("head_sha")
    return bool(prs) and bool(head) and any(
        isinstance(pr, Mapping) and isinstance(pr.get("head"), Mapping) and pr["head"].get("sha") == head
        for pr in prs)


def pull_at_head(client: Any, run: Mapping[str, Any], *, strict: bool = False) -> bool:
    """A pull request of the run is open at the run's head.

    Read from the pull request itself; when the token may not read pull requests (HTTP 403 or 404: the overflow
    watch's GITHUB_TOKEN has no pull-requests scope), the run just read again stands in (at_head()), which GitHub
    keeps at each pull request's current head."""
    numbers = [pr["number"] for pr in run.get("pull_requests") or ()
               if isinstance(pr, Mapping) and isinstance(pr.get("number"), int)]
    refused = False
    for number in numbers:
        try:
            if client.pull_head(number) == run.get("head_sha"):
                return True
        except RuntimeError as error:
            if strict or not re.search(r"HTTP (403|404)$", str(error)):
                raise
            refused = True
    return not strict and refused and at_head(run)


def finish_cancel(client: Any, run_id: int, workflows: Sequence[str], *, pending: set[int],
                  deadline: float, sleep: Callable[[float], None], clock: Callable[[], float],
                  log: Callable[[str], None]) -> tuple[bool, str]:
    """Finish only an owned cancellation, checking the live attempt and open PR before every rerun POST.

    A failed response may conceal an accepted rerun: a later attempt ends recovery without another POST.
    Unread state and exhausted retries retain the journal entry for the next minute or successor.
    """
    def settled(message: str, reran: bool = False) -> tuple[bool, str]:
        log(f"{LIGHT_CANCEL_SETTLED} run {run_id} attempt 1")
        pending.discard(run_id)
        return reran, message

    last = "the cancellation has not settled"
    for retry in range(RERUN_TRIES):
        if clock() >= deadline:
            break
        try:
            run = client.run(run_id)
            if run.get("run_attempt") != 1:
                return settled("a later attempt already exists; no further rerun sent")
            workflow = str(run.get("path") or "").split("@", 1)[0].rsplit("/", 1)[-1]
            if run.get("event") not in EVENTS or workflow not in workflows or not at_head(run):
                return settled("the run is no longer eligible; left alone")
            if not pull_at_head(client, run, strict=True):
                return settled("the pull request closed or moved on; left alone")
            if run.get("status") != "completed":
                return False, last
            if run.get("conclusion") != "cancelled":
                return settled("the run finished without a cancellation; left alone")
            if clock() >= deadline:
                break
            client.rerun_failed(run_id)
        except Exception as error:  # noqa: BLE001 - keep confirmed ownership through transient failures
            last = f"rerun not confirmed ({error})"
            if retry + 1 >= RERUN_TRIES or clock() >= deadline:
                break
            # Permanent refusals are visible and retained, not hammered within this pass.
            status = re.search(r"HTTP (\d{3})$", str(error))
            if status and int(status[1]) in {401, 403, 404, 422}:
                break
            sleep(min(SETTLE_INTERVAL_S, max(0.0, deadline - clock())))
            continue
        return settled("re-ran its failed jobs on their fallback route", reran=True)
    return False, f"{last}; owned recovery remains pending"


def candidate(run: Mapping[str, Any]) -> bool:
    return (run.get("event") in EVENTS and run.get("run_attempt") == 1 and run.get("status") in IN_FLIGHT
            and at_head(run))


def stalled(job: Mapping[str, Any], now: dt.datetime) -> bool:
    """Queued on GitHub-hosted Ubuntu with no runner for STALL_SECONDS or more."""
    labels = [str(label) for label in job.get("labels") or ()]
    created = parse_time(job.get("created_at"))
    return (job.get("status") == "queued" and not job.get("runner_id") and not job.get("runner_name")
            and bool(labels) and all(HOSTED_LABEL.match(label) for label in labels)
            and created is not None and (now - created).total_seconds() >= STALL_SECONDS)


def verdict(jobs: Sequence[Mapping[str, Any]], now: dt.datetime) -> tuple[str, list[Mapping[str, Any]]]:
    """('rescue'|'gated'|'none', stalled jobs) for one run's latest jobs."""
    stuck = [job for job in jobs if stalled(job, now)]
    if not stuck:
        return "none", []
    stuck_ids = {id(job) for job in stuck}
    others = [job for job in jobs if job.get("status") != "completed" and id(job) not in stuck_ids]
    return ("gated" if others else "rescue"), stuck


def run_key(run: Mapping[str, Any]) -> tuple[str, int]:
    """The stable ordering key shared by the bounded scan and its in-memory cursor."""
    return str(run.get("created_at") or ""), int(run["id"])


@dataclass
class ScanState:
    """Process-local discovery and progress; expired candidates are removed on every pass."""

    cursor: tuple[str, int] | None = None
    recovery_cursor: int | None = None
    pages: dict[tuple[str, str], int] = field(default_factory=dict)
    candidates: dict[int, Mapping[str, Any]] = field(default_factory=dict)


def scan_slice(runs: Sequence[Mapping[str, Any]], cursor: tuple[str, int] | None) -> tuple[
        list[Mapping[str, Any]], tuple[str, int] | None]:
    """Select one bounded rotating slice and return the key after which the next pass starts.

    The cursor is intentionally only process-local. A new sweeper starts from the oldest run, while the
    minute passes in one sweeper visit every candidate even when old runs stay gated. If the run at the
    cursor disappears, the first remaining run after it (or the oldest run after a full wrap) is safe.
    """
    if not runs:
        return [], cursor
    start = 0 if cursor is None else next(
        (index for index, run in enumerate(runs) if run_key(run) > cursor), 0)
    ordered = list(runs[start:]) + list(runs[:start])
    selected = ordered[:MAX_RUNS]
    return selected, run_key(selected[-1])


def pool_low(client: Any, now: dt.datetime) -> bool:
    """The client's token pool is down to POOL_RESERVE (a client that does not track it never is)."""
    spare = getattr(client, "spare", None)
    return callable(spare) and not spare(now)


def sweep(client: Any, workflows: Sequence[str], *, now: dt.datetime, dry_run: bool,
          sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic,
          pending: set[int] | None = None, log: Callable[[str], None] = print,
          scan_state: ScanState | None = None) -> list[str]:
    lines: list[str] = []
    pending = set() if pending is None else pending
    recovering = set(pending)
    state = scan_state if scan_state is not None else ScanState()
    rescued, attempted = 0, 0
    started = clock()
    deadline = started + SETTLE_BUDGET_S
    recovery_deadline = started + SETTLE_BUDGET_S / 2
    # A broken receipt must not consume every slot every minute. Rotate owned recovery IDs and reserve
    # half the mutation and settle budgets for fresh stalled work, even while old reads keep failing.
    ordered = sorted(recovering)
    offset = next((index for index, run_id in enumerate(ordered)
                   if state.recovery_cursor is None or run_id > state.recovery_cursor), 0)
    ordered = ordered[offset:] + ordered[:offset]
    for run_id in ordered[:max(1, MAX_RESCUES // 2)]:
        if not dry_run and clock() >= recovery_deadline:
            break
        state.recovery_cursor = run_id
        if dry_run:
            lines.append(f"run {run_id}: would resume its owned cancellation (dry run)")
            continue
        attempted += 1
        reran, outcome = finish_cancel(client, run_id, workflows, pending=pending, deadline=recovery_deadline,
                                       sleep=sleep, clock=clock, log=log)
        rescued += int(reran)
        lines.append(f"run {run_id}: {outcome}")
    if pool_low(client, now):
        lines.append(f"the read token's pool is down to {client.remaining} (reserve {POOL_RESERVE}); "
                     f"no listing or job read until its reset at {iso(dt.datetime.fromtimestamp(client.reset, UTC))}")
        return lines
    start, end = now - WINDOW, now - dt.timedelta(seconds=STALL_SECONDS)
    # Overflow pages rotate independently of the job-read cursor. Retain the discovered union so a page
    # disappearing from the next listing cannot discard candidates before their turn. Metadata never
    # authorizes a mutation: the run, PR head and jobs are still re-read immediately before cancellation.
    listed = state.candidates
    for run_id, run in list(listed.items()):
        created = parse_time(run.get("created_at"))
        if (created is None or not start <= created <= end or run.get("_workflow") not in workflows
                or run_id in recovering):
            del listed[run_id]
    declared = set(workflows)
    for status in IN_FLIGHT:
        # One repository-wide listing per status; a run is kept when its workflow file is declared. A reusable
        # declaration's runs carry their caller's path, and with_callers() already lists the callers.
        # Pages 1 and 2 are read every pass while full (every workflow now shares them), and one rotating page
        # from 3 on beyond that, so a declared run is not left to the rotation behind undeclared ones.
        key = REPOSITORY, status
        overflow = state.pages.get(key, 3)
        full_overflow = False
        previous_full = True
        for listing_page in (1, 2, overflow):
            if not previous_full:
                break  # the pages so far hold every run: a later page would come back empty
            try:
                page = client.runs(None, status, start, end, page=listing_page)
            except Exception as error:  # noqa: BLE001 - an unread listing only narrows this pass
                lines.append(f"could not list {status} pull request runs ({error})")
                break
            previous_full = len(page) >= LIST_PAGE
            if listing_page == overflow:
                full_overflow = previous_full
            for run in page:
                workflow = workflow_file(run)
                if (workflow in declared and isinstance(run.get("id"), int) and candidate(run)
                        and run["id"] not in recovering
                        and (created := parse_time(run.get("created_at"))) is not None and start <= created <= end):
                    listed[run["id"]] = {**run, "_workflow": workflow}
        if full_overflow:
            state.pages[key] = 3 if overflow >= MAX_RUN_LIST_PAGES else overflow + 1
        else:
            state.pages[key] = 3
    runs = sorted(listed.values(), key=run_key)
    candidate_count = len(runs)
    runs, state.cursor = scan_slice(runs, state.cursor)
    if candidate_count > MAX_RUNS:
        lines.append(f"{candidate_count} candidate runs; read a rotating slice of {MAX_RUNS}")
    for read, run in enumerate(runs):
        if pool_low(client, now):
            lines.append(f"the read token's pool is down to {client.remaining} (reserve {POOL_RESERVE}); "
                         f"{len(runs) - read} job reads left to a later pass")
            break
        try:
            jobs = client.jobs(run["id"])
        except Exception as error:  # noqa: BLE001
            lines.append(f"run {run['id']}: could not read jobs ({error})")
            continue
        kind, stuck = verdict(jobs, now)
        if kind == "none":
            continue
        names = ", ".join(f"{job.get('name')} ({int((now - parse_time(job['created_at'])).total_seconds())} s, "
                          f"{','.join(job.get('labels') or ())})" for job in stuck)
        where = f"run {run['id']} ({run['_workflow']}, {run.get('head_branch')})"
        if kind == "gated":
            lines.append(f"{where}: {names} stalled on hosted Ubuntu, but other jobs are unfinished; left alone")
            continue
        if attempted >= MAX_RESCUES:
            lines.append(f"{where}: {names} stalled; over this pass's {MAX_RESCUES} re-runs, left to the next")
            continue
        if not dry_run and clock() >= deadline:
            # No settle time left: a cancel now could not be followed by its re-run.
            lines.append(f"{where}: {names} stalled; this pass's settle time is spent, left to the next")
            continue
        if dry_run:
            lines.append(f"{where}: {names} stalled; would cancel and re-run its failed jobs (dry run)")
            rescued += 1
            attempted += 1
            continue
        # Right before the cancel: the run is still attempt 1 and in flight at its pull request's head (read again,
        # so a concurrent re-run is never cancelled), the pull request is still open at this head, and nothing has
        # started since the jobs were read (a runner may have taken the stalled job meanwhile).
        try:
            fresh = {**client.run(run["id"])}
            live_head = candidate(fresh) and fresh.get("head_sha") == run.get("head_sha")
            if live_head:
                live_head = pull_at_head(client, fresh, strict=True)
            again, _ = verdict(client.jobs(run["id"]), now) if live_head else ("none", [])
        except Exception as error:  # noqa: BLE001 - unread means unknown: leave the run
            lines.append(f"{where}: could not re-read before the cancel ({error}); left alone")
            continue
        if not live_head:
            lines.append(f"{where}: the run or its pull request moved on (attempt, status, head or closed); left alone")
            continue
        if again != "rescue":
            lines.append(f"{where}: a job started or finished since the read; left alone")
            continue
        try:
            client.cancel(run["id"])
        except Exception as error:  # noqa: BLE001
            lines.append(f"{where}: cancel refused ({error})")
            continue
        attempted += 1
        pending.add(run["id"])
        # Immediate log output is GitHub's durable receipt; a successor reads it if this worker stops.
        log(f"{LIGHT_CANCEL_SENT} run {run['id']} attempt 1")
        settled = False
        while True:
            try:
                current = client.run(run["id"])
            except Exception:  # noqa: BLE001 - read again until the budget runs out
                current = {}
            if current.get("status") == "completed":
                settled = current.get("run_attempt") == 1
                break
            if clock() >= deadline:
                break
            sleep(SETTLE_INTERVAL_S)
        if not settled:
            lines.append(f"{where}: {names} stalled; cancelled, but the cancel did not settle in this pass's "
                         f"{SETTLE_BUDGET_S:.0f} s; owned recovery remains pending")
            continue
        reran, outcome = finish_cancel(client, run["id"], workflows, pending=pending, deadline=deadline,
                                       sleep=sleep, clock=clock, log=log)
        rescued += int(reran)
        lines.append(f"{where}: {names} stalled; cancelled; {outcome}")
    lines.append(f"{len(listed)} candidate runs, {len(runs)} read, {rescued} failed over")
    return lines


def follow(pass_once: Callable[[], Any], *, stopped: Callable[[float], bool], seconds: float,
           clock: Callable[[], float] = time.monotonic, log: Callable[[str], None] = print) -> None:
    """One bounded light-job watch inside the existing sweeper, independent of its App budget pacing.

    Never overlap passes. Handover interrupts the wait; a cancel already under way finishes before this
    worker joins the sweeper's normal rescue grace. A slow pass delays its next tick rather than fan out.
    """
    end = clock() + seconds
    while clock() < end:
        started = clock()
        try:
            pass_once()
        except Exception as error:  # one unread pass must not end recovery for the rest of the sweep
            log(f"hosted light rescue: {type(error).__name__}: {error}; next minute")
        delay = min(max(0.0, 60.0 - (clock() - started)), max(0.0, end - clock()))
        if stopped(delay):
            break


def from_env(env: Mapping[str, str], repo: str, *, now: Callable[[], dt.datetime],
             log: Callable[[str], None]) -> Callable[[], None] | None:
    """Build a pass that reads as cmux-bot (its own pool) with the workflow token as fallback, never the routing App."""
    token = env.get("HOSTED_LIGHT_TOKEN", "").strip()
    fallback = env.get("HOSTED_LIGHT_FALLBACK_TOKEN", "").strip() or None
    directory = Path(env.get("HOSTED_LIGHT_POLICY", ".rescue-workflows/.github"))
    if env.get("HOSTED_LIGHT_DISABLED") == "1" or not token:
        return None
    runners = json.loads((directory / "runners.json").read_text(encoding="utf-8"))
    workflows = with_callers(declared_workflows(runners), directory / "workflows")
    mint = None
    if fallback and env.get("BOT_APP_ID") and env.get("BOT_APP_KEY"):
        import owned_pool_rescue
        mint = owned_pool_rescue.app_token_minter(env["BOT_APP_ID"], env["BOT_APP_KEY"], repo)
    client = GitHub(token, repo, fallback=fallback, mint=mint) if fallback else GitHub(token, repo)
    scan_state = ScanState()
    pending: set[int] = set()
    restored = False
    retry_at: dt.datetime | None = None
    def once() -> None:
        nonlocal restored, retry_at
        if not restored and (retry_at is None or now() >= retry_at):
            try:
                pending.update(client.pending_cancellations(now()))
                restored = True
            except Exception as error:  # noqa: BLE001 - incomplete journal cannot authorize a rerun
                # Each attempt pages the rescue history (up to 10 reads), and an over-long window fails the same
                # way every minute: try again after JOURNAL_RETRY, not on every pass.
                retry_at = now() + JOURNAL_RETRY
                log(f"hosted light recovery journal unavailable ({error}); existing cancellations left alone; "
                    f"read again after {iso(retry_at)}")
        for line in sweep(client, workflows, now=now(), dry_run=False, pending=pending, log=log,
                          scan_state=scan_state):
            log(f"[hosted light] {line}")
    return once


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None, *, client: Any = None,
         now: dt.datetime | None = None, sleep: Callable[[float], None] = time.sleep) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--runners", type=Path,
                      help="the .github/runners.json whose hosted_light_jobs scope the pass")
    mode.add_argument("--wake-sweeper", action="store_true",
                      help="wake the existing single concurrency owner without cancelling or rerunning any job")
    parser.add_argument("--workflows", type=Path, default=None,
                        help="the .github/workflows directory whose callers of reusable declared workflows are listed too")
    parser.add_argument("--dry-run", action="store_true",
                        default=(env.get("DRY_RUN", "").strip().lower() in {"1", "true", "yes"}))
    args = parser.parse_args(argv)
    now = now or dt.datetime.now(UTC)
    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    if args.wake_sweeper and args.dry_run:
        print("would dispatch the owned-pool-sweeper on main (dry run)")
        return 0
    if args.wake_sweeper:
        if client is None:
            token = (env.get("GH_TOKEN") or "").strip()
            if not token or not repo:
                print("::warning title=Hosted light rescue::no GH_TOKEN or repository; nothing to do")
                return 0
            client = GitHub(token, repo, token)
        client.wake_sweeper()
        print("dispatched the single owned-pool-sweeper on main")
        return 0
    try:
        workflows = with_callers(declared_workflows(json.loads(args.runners.read_text(encoding="utf-8"))),
                                 args.workflows)
    except (OSError, ValueError) as error:
        print(f"::warning title=Hosted light rescue::could not read {args.runners} ({error}); nothing to do")
        return 0
    if client is None:
        write = (env.get("GH_TOKEN") or "").strip()
        read = (env.get("READ_TOKEN") or "").strip() or write
        if not write or not repo:
            print("::warning title=Hosted light rescue::no GH_TOKEN or repository; nothing to do")
            return 0
        client = GitHub(read, repo, write)
    lines = sweep(client, workflows, now=now, dry_run=args.dry_run, sleep=sleep)
    for line in lines:
        print(line)
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### Hosted light rescue\n\n" + "\n".join(f"- {line}" for line in lines) + "\n\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
