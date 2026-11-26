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

`--backlog` is a second, separate pass (ci-hosted-backlog-rescue.yml, every 10 minutes and on dispatch) for what the
minute pass leaves: any pull request run, up to GitHub's 24 h queue limit, whose every unfinished job has waited
BACKLOG_STALL on hosted Ubuntu, on a one-job JIT label its route moved off (MOVED_JIT_LABELS), or on Blacksmith Ubuntu
when its re-run takes the owned LINUX_RUNNER (RerunRoutes). A run at its pull request's head is cancelled, journalled in
the pass's log, and re-run on today's routes by the next pass once the cancel settled; a superseded one is only cancelled
(see BACKLOG_STALL below).

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

sys.path.insert(0, str(Path(__file__).resolve().parent))
from app_spend_mark import MIN_FLOOR  # noqa: E402  (the cmux-bot hour's last calls are HQ's)

UTC = dt.timezone.utc
HOSTED_LABEL = re.compile(r"^ubuntu-[0-9][\w.-]*$")
# Blacksmith's Ubuntu labels (blacksmith-4vcpu-ubuntu-2404, blacksmith-4vcpu-ubuntu-2404-arm). Only the backlog pass
# moves a job queued on one, and only when its re-run provably leaves Blacksmith for an owned label (RerunRoutes).
BLACKSMITH_LINUX_LABEL = re.compile(r"^blacksmith-[0-9]+vcpu-ubuntu-[0-9]+(?:-[a-z0-9]+)*$")
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
# The cmux-bot App pool (the read token when the workflow token is the fallback) stops at HQ's default floor: no
# read here spends it below that, so next-autoland and NOW keep the hour's last calls; reads move to the fallback
# instead (app_spend_mark.MIN_FLOOR).
APP_POOL_RESERVE = max(POOL_RESERVE, MIN_FLOOR)
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
# Discovery URLs use a rounded lower window reused for a short interval. Fresh runs that fall
# above the stall bound remain in ScanState and are checked again as they age; a cached page never authorizes a rescue.
DISCOVERY_CACHE_SECONDS = 75.0
DISCOVERY_STEP_SECONDS = 30 * 60
FORBIDDEN_COOLDOWN_SECONDS = 60.0
JOB_LOG_BYTES = 4 * 1024 * 1024  # a backlog pass logs a few hundred short lines


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


def _trigger_scope(text: str) -> set[str] | None:
    """Return top-level trigger names, or None when the workflow cannot be parsed conservatively."""
    lines = text.splitlines()
    start = next((index for index, line in enumerate(lines)
                  if re.match(r"^\s*on\s*:", line) and not line.lstrip().startswith("#")), None)
    if start is None:
        return None
    line = lines[start]
    value = line.split(":", 1)[1].strip()
    if value:
        if value.startswith("[") and value.endswith("]"):
            return {item.strip().strip("'\"") for item in value[1:-1].split(",") if item.strip()}
        if re.fullmatch(r"['\"]?[A-Za-z0-9_-]+['\"]?", value):
            return {value.strip("'\"")}
        return None
    indent = len(line) - len(line.lstrip())
    names: set[str] = set()
    known = {"pull_request", "pull_request_target", "workflow_call", "workflow_dispatch", "schedule",
             "push", "workflow_run", "repository_dispatch", "issues", "issue_comment", "release",
             "deployment", "deployment_status", "branch_protection_rule", "check_run", "check_suite",
             "create", "delete", "discussion", "discussion_comment", "fork", "gollum", "label", "merge_group",
             "page_build", "project", "project_card", "project_column", "public", "status", "watch"}
    child_indent: int | None = None
    for candidate in lines[start + 1:]:
        if not candidate.strip() or candidate.lstrip().startswith("#"):
            continue
        candidate_indent = len(candidate) - len(candidate.lstrip())
        if candidate_indent <= indent:
            break
        if child_indent is None:
            child_indent = candidate_indent
        if candidate_indent != child_indent:
            # Nested inputs/outputs/configuration belong to the trigger above and are not trigger names.
            continue
        match = re.match(r"^\s*([A-Za-z0-9_-]+)\s*:", candidate)
        if not match:
            return None
        name = match.group(1)
        if name not in known:
            return None
        names.add(name)
    return names or None


def _has_pull_request_trigger(text: str) -> bool | None:
    scope = _trigger_scope(text)
    if scope is None:
        return None
    return bool(scope & {"pull_request", "pull_request_target"})


class GitHubHTTPError(RuntimeError):
    """A bounded GitHub API error whose status remains machine-readable."""

    def __init__(self, message: str, *, status: int) -> None:
        super().__init__(message)
        self.status = status
        self.code = status  # GitHub.request() moves a refused primary read to the fallback by `code`


def _forbidden_diagnostic(error: urllib.error.HTTPError) -> str:
    """Classify a 403 without putting arbitrary response data in logs."""
    raw = b""
    try:
        raw = error.read(4096)
    except Exception:  # noqa: BLE001 - diagnostics must never mask the API refusal
        pass
    message = ""
    resource = ""
    try:
        payload = json.loads(raw.decode("utf-8", "replace")) if raw else {}
        if isinstance(payload, Mapping):
            message = str(payload.get("message") or "")[:240]
            resource = str(payload.get("resource") or "")[:40]
    except (UnicodeError, json.JSONDecodeError, TypeError, ValueError):
        pass
    headers = getattr(error, "headers", None) or {}
    normalized = {str(key).lower(): str(value).strip() for key, value in headers.items()}
    resource = resource or normalized.get("x-ratelimit-resource", "")
    lowered = message.lower()
    remaining = normalized.get("x-ratelimit-remaining", "")
    if "secondary rate limit" in lowered or "abuse detection" in lowered:
        kind = "secondary-limit"
    elif remaining == "0" or "rate limit" in lowered or normalized.get("retry-after"):
        kind = "quota"
    elif "resource not accessible" in lowered or "permission" in lowered or "forbidden" in lowered:
        kind = "permission"
    else:
        kind = "forbidden"
    fields = []
    for name, header in (("remaining", "x-ratelimit-remaining"), ("limit", "x-ratelimit-limit"),
                         ("reset", "x-ratelimit-reset"), ("retry-after", "retry-after")):
        value = normalized.get(header, "")
        if value and re.fullmatch(r"\d+(?:\.\d+)?", value):
            fields.append(f"{name}={value}")
    if resource in {"core", "search", "graphql", "integration_manifest", "code_search", "source_import"}:
        fields.append(f"resource={resource}")
    return kind + (" (" + ", ".join(fields) + ")" if fields else "")


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
            # A reusable workflow has no run of its own. Drop only files whose trigger block proves that fact;
            # unreadable or unfamiliar syntax stays included so a new trigger cannot silently disappear.
            return sorted(name for name in found
                          if name not in texts or _has_pull_request_trigger(texts[name]) is not False)
        found |= callers


APP_TOKEN_SECONDS = 50 * 60  # an installation token lasts an hour; mint the next one before it ends


class Pool:
    """One token's rate-limit pool as its last response reported it: None until a response carries it."""

    def __init__(self, reserve: int = POOL_RESERVE) -> None:
        self.remaining: int | None = None
        self.reset: float = 0.0
        self.reserve = reserve

    def spare(self, now: float) -> bool:
        return self.remaining is None or self.remaining > self.reserve or now >= self.reset


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
        # With a fallback, `token` is the cmux-bot App's: its pool stops at HQ's default floor (APP_POOL_RESERVE).
        self.pools: dict[str, Pool] = {"primary": Pool(APP_POOL_RESERVE if self.fallback else POOL_RESERVE),
                                       "fallback": Pool()}
        self.primary_refused_until = 0.0

        self.etags: dict[str, tuple[str, Any]] = {}
        self.history: Any = None
        # pool -> (clock time the GET pause ends, the quota refusal it repeats)
        self.forbidden_cooldowns: dict[str, tuple[float, GitHubHTTPError]] = {}

    @property
    def remaining(self) -> int | None:
        """The pool reads use now (for the pass's log line)."""
        return self.pools[self.read_pool()].remaining

    @property
    def reserve(self) -> int:
        """The reserve of the pool reads use now."""
        return self.pools[self.read_pool()].reserve

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
        for job_id in self.history.rescue_jobs(
                now - WINDOW, events=("schedule", "workflow_dispatch"), titles=("owned-pool-sweeper",)):
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
        cooldown = self.forbidden_cooldowns.get(pool)
        if cooldown is not None and self.clock() < cooldown[0]:
            raise cooldown[1]  # a quota refusal pauses this pool's GETs instead of spending more of it
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
            if error.code == 403:
                diagnostic = _forbidden_diagnostic(error)
                refusal: RuntimeError = GitHubHTTPError(f"{method} {path}: {diagnostic}: HTTP 403", status=403)
                if method == "GET" and diagnostic.startswith(("quota", "secondary-limit")):
                    self.forbidden_cooldowns[pool] = (self.clock() + FORBIDDEN_COOLDOWN_SECONDS, refusal)
                raise refusal from error
            refusal = RuntimeError(f"{method} {path}: HTTP {error.code}")
            refusal.code = error.code  # type: ignore[attr-defined]
            raise refusal from error

    def runs(self, workflow: str | None, status: str, start: dt.datetime, end: dt.datetime, *,
             page: int = 1) -> list[dict[str, Any]]:
        """One page of in-flight pull request runs: of one workflow file, or of the whole repository (None)."""
        # Filtered to pull_request runs server-side, so push and dispatch runs never fill the one page.
        # The upper stall bound is applied locally: retaining fresh metadata lets it age into eligibility while a
        # discovery page is cached, and keeps the URL stable for conditional requests after the short cache TTL.
        query = urllib.parse.urlencode({"status": status, "event": "pull_request", "per_page": 100, "page": page,
                                        "created": f">={iso(start)}"})
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

    def force_cancel(self, run_id: int) -> None:
        self.request("POST", f"/actions/runs/{run_id}/force-cancel")

    def rate_limit(self) -> tuple[int, float] | None:
        """(core remaining, reset epoch) of the write token, the one that cancels and re-runs; GitHub does not charge
        GET /rate_limit against it."""
        request = urllib.request.Request("https://api.github.com/rate_limit", headers={
            "Accept": "application/vnd.github+json", "Authorization": f"Bearer {self.write_token}",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-hosted-light-rescue"})
        with urllib.request.urlopen(request, timeout=30) as response:
            core = (json.loads(response.read()).get("resources") or {}).get("core") or {}
        if not isinstance(core.get("remaining"), int):
            return None
        return core["remaining"], float(core.get("reset") or 0)

    def job_log(self, job_id: int) -> list[str]:
        """A finished job's log lines, at most JOB_LOG_BYTES. The API answers with a redirect to signed storage,
        which is fetched without the token."""

        class Stay(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *args: Any, **kwargs: Any) -> None:
                return None
        pool, token = self.read_token()
        request = urllib.request.Request(
            f"https://api.github.com/repos/{self.repo}/actions/jobs/{job_id}/logs",
            headers={"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
                     "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-hosted-light-rescue"})
        try:
            with urllib.request.build_opener(Stay).open(request, timeout=30) as response:
                self.note_limit(response.headers, pool)
                body = response.read(JOB_LOG_BYTES)
        except urllib.error.HTTPError as error:
            self.note_limit(error.headers, pool)
            location = error.headers.get("Location") if error.headers is not None else None
            if error.code not in (301, 302, 303, 307, 308) or not location:
                raise RuntimeError(f"GET job {job_id} logs: HTTP {error.code}") from error
            with urllib.request.urlopen(location, timeout=60) as response:
                body = response.read(JOB_LOG_BYTES)
        return body.decode("utf-8", "replace").splitlines()

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
    # (REPOSITORY, status, page) -> (monotonic read time, page rows).
    discovery_pages: dict[tuple[str, str, int], tuple[float, list[Mapping[str, Any]]]] = field(
        default_factory=dict)
    # A cached non-stalled jobs answer is safe only until its oldest queued job reaches the stall bound. Stalled
    # verdicts are never cached, so a rescue always gets a fresh authoritative read.
    jobs_cache: dict[int, tuple[float, dt.datetime, list[Mapping[str, Any]]]] = field(default_factory=dict)
    fresh_candidates: dict[int, Mapping[str, Any]] = field(default_factory=dict)


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
    # Keep bounded process-local caches from retaining completed/expired candidates forever.
    state.discovery_pages = {
        key: value for key, value in state.discovery_pages.items()
        if clock() - value[0] < DISCOVERY_CACHE_SECONDS
    }
    state.jobs_cache = {
        run_id: value for run_id, value in state.jobs_cache.items()
        if clock() - value[0] < DISCOVERY_CACHE_SECONDS and now < value[1]
    }
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
        lines.append(f"the read token's pool is down to {client.remaining} (reserve {getattr(client, 'reserve', POOL_RESERVE)}); "
                     f"no listing or job read until its reset at {iso(dt.datetime.fromtimestamp(client.reset, UTC))}")
        return lines
    # Round the server query lower bound so the same URL remains cacheable for a short interval. The exact upper
    # bound is always enforced locally; a retained fresh candidate therefore becomes eligible as
    # soon as its timestamp ages into the stall window, even while the listing page is cached.
    def floor(moment: dt.datetime) -> dt.datetime:
        stamp = int(moment.astimezone(UTC).timestamp())
        return dt.datetime.fromtimestamp(stamp - stamp % DISCOVERY_STEP_SECONDS, UTC)

    exact_start, exact_end = now - WINDOW, now - dt.timedelta(seconds=STALL_SECONDS)
    start, end = floor(exact_start), exact_end
    # Overflow pages rotate independently of the job-read cursor. Retain the discovered union so a page
    # disappearing from the next listing cannot discard candidates before their turn. Metadata never
    # authorizes a mutation: the run, PR head and jobs are still re-read immediately before cancellation.
    listed = state.candidates
    for run_id, run in list(listed.items()):
        created = parse_time(run.get("created_at"))
        if created is not None and created > exact_end:
            state.fresh_candidates[run_id] = run
            del listed[run_id]
            continue
        if (created is None or created < exact_start or run.get("_workflow") not in workflows
                or run_id in recovering):
            del listed[run_id]
    for run_id, run in list(state.fresh_candidates.items()):
        created = parse_time(run.get("created_at"))
        if created is None or created < exact_start or run.get("_workflow") not in workflows or run_id in recovering:
            del state.fresh_candidates[run_id]
        elif created <= exact_end:
            listed[run_id] = run
            del state.fresh_candidates[run_id]
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
                # Keep the cache key independent of the moving time window. The local exact-window filter below
                # drops aged rows, while the short TTL keeps newly-created rows boundedly fresh.
                cache_key = (REPOSITORY, status, listing_page)
                cached = state.discovery_pages.get(cache_key)
                if cached is not None and clock() - cached[0] < DISCOVERY_CACHE_SECONDS:
                    page = cached[1]
                else:
                    page = client.runs(None, status, start, end, page=listing_page)
                    state.discovery_pages[cache_key] = (clock(), list(page))
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
                        and (created := parse_time(run.get("created_at"))) is not None
                        and created >= exact_start):
                    item = {**run, "_workflow": workflow}
                    if created > exact_end:
                        state.fresh_candidates[run["id"]] = item
                    else:
                        listed[run["id"]] = item
        if full_overflow:
            state.pages[key] = 3 if overflow >= MAX_RUN_LIST_PAGES else overflow + 1
        else:
            state.pages[key] = 3
    runs = sorted(listed.values(), key=run_key)
    live_ids = set(listed) | set(state.fresh_candidates)
    state.jobs_cache = {run_id: value for run_id, value in state.jobs_cache.items() if run_id in live_ids}
    candidate_count = len(runs)
    runs, state.cursor = scan_slice(runs, state.cursor)
    if candidate_count > MAX_RUNS:
        lines.append(f"{candidate_count} candidate runs; read a rotating slice of {MAX_RUNS}")
    for read, run in enumerate(runs):
        if pool_low(client, now):
            lines.append(f"the read token's pool is down to {client.remaining} (reserve {getattr(client, 'reserve', POOL_RESERVE)}); "
                         f"{len(runs) - read} job reads left to a later pass")
            break
        created = parse_time(run.get("created_at"))
        if created is None or created > exact_end:
            # Retained fresh metadata is kept for the next pass, but it cannot spend a job read until it enters the
            # local stall window. This is what lets an eligible run age into service while discovery is cached.
            continue
        try:
            cached_jobs = state.jobs_cache.get(run["id"])
            if cached_jobs is not None:
                checked_at, expires_at, jobs = cached_jobs
                if clock() - checked_at >= DISCOVERY_CACHE_SECONDS or now >= expires_at:
                    cached_jobs = None
            if cached_jobs is None:
                jobs = client.jobs(run["id"])
                # Cache only a clearly non-stalled result, and expire when its oldest queued job can age into the
                # rescue window. A read failure is never cached as absence.
                queued_times = [parse_time(job.get("created_at")) for job in jobs
                                if job.get("status") == "queued" and parse_time(job.get("created_at")) is not None]
                expires_at = min((created + dt.timedelta(seconds=STALL_SECONDS) for created in queued_times),
                                 default=now + dt.timedelta(seconds=DISCOVERY_CACHE_SECONDS))
                complete = bool(jobs) and all(
                    str(job.get("name") or "") != "(jobs past the first page)"
                    and job.get("status") in {"queued", "in_progress", "completed"}
                    for job in jobs)
                if complete and verdict(jobs, now)[0] == "none":
                    state.jobs_cache[run["id"]] = (clock(), expires_at, list(jobs))
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


# The backlog pass (`--backlog`, ci-hosted-backlog-rescue.yml). On 2026-11-18 Blacksmith Linux started almost no jobs
# from about 21:34Z, so LINUX_RUNNER and the x64 pools pointed at GitHub-hosted `ubuntu-24.04` until 02:34Z (cmux#45710).
# Every job queued in that window stayed bound to the hosted label after the routes came back, since GitHub never
# re-routes a queued job: at 02:20Z about 2,500 runs were queued, cmux#44204's 35 light jobs had waited 3 h, and new
# pushes' hosted light jobs queued behind them. The minute pass above never saw those runs: it lists runs under WINDOW
# (90 min) old, in declared workflows only, on the premise that GitHub cancels a hosted job that never got a runner
# well before then; GitHub keeps it queued for 24 h. The backlog pass covers the rest of that class, bounded:
# - pull request runs only (pull_request and pull_request_target, attempt 1, of this repository's own branches),
#   never a push, schedule, dispatch, nightly, DEV, promote or release run, never nightly.yml;
# - created BACKLOG_STALL to BACKLOG_WINDOW ago, except a run the minute pass owns (a declared workflow's run under
#   WINDOW old), so the two never act on the same run;
# - every unfinished job queued, with no runner, on GitHub-hosted Ubuntu labels only, for BACKLOG_STALL or more
#   (a run with anything running or waiting otherwise is left alone);
# - a run at its pull request's current head is cancelled and its failed jobs re-run (attempt 2: each job takes its
#   route as the variables read now); a run whose pull request closed or moved on is only cancelled, since nobody
#   reads its result; a run whose pull request cannot be read is left alone.
#
# A cancel and its re-run are paired by a journal, not by waiting. A cancel of jobs that never had a runner can take
# many minutes to settle, and the run cannot be re-run until it has: on 2026-11-18 from 08:50Z the pass polled each
# cancelled run every 5 s for 120 s (up to 500 more GitHub calls a pass, uncounted), almost none settled, and each
# pass left about 20 pull request heads with no checks and no later re-run. Now a pass never waits: every
# current-head run it cancels goes into the journal, the last lines of the pass's log (`hosted-backlog journal: ...`),
# and the next pass reads the newest earlier log that has one (or, with --recover-since, every pass's log back to that
# time) and re-runs each journalled run once its cancel settled, still attempt 1 and still at its open pull request's
# head with no newer run of its workflow there. A cancel still unsettled after BACKLOG_FORCE_AFTER is force-cancelled
# once. A run not re-run within BACKLOG_RECOVER_WINDOW leaves the journal with a ::warning naming it. A pass cancels a
# current-head run only while fewer than BACKLOG_PENDING_MAX journalled runs wait (and only once it read a journal),
# and recovery is sized to re-run BACKLOG_PENDING_MAX runs in one pass, so no cancel is made that the next pass cannot
# re-run. Logs of passes from before the journal (cmux#45886's "re-run it by hand" lines) count as journal entries.
#
# Budget: BACKLOG_READS GitHub calls a pass, every call counted (the rate-limit read, journal reads, listings, jobs,
# pull requests, the re-read before a cancel, recovery reads, and every cancel, force-cancel and re-run). First the
# pass reads the write token's rate limit once (GET /rate_limit): below BACKLOG_READS + POOL_RESERVE it reads, cancels
# and re-runs nothing, says why and exits 0 (the journal stays in the earlier log for the next pass). Recovery stops
# at BACKLOG_RECOVER_SHARE calls; listings stop walking pages at half; at most BACKLOG_ACTIONS cancels and
# BACKLOG_IN_PROGRESS_READS job reads for runs that started a job, oldest queued runs first, and a run is read only
# while the calls to cancel it remain. Six passes an hour spend at most 900 of cmux-bot's 12,500.
BACKLOG_STALL = dt.timedelta(minutes=30)
BACKLOG_WINDOW = dt.timedelta(hours=24)
BACKLOG_EVENTS = ("pull_request", "pull_request_target")
BACKLOG_ACTIONS = 20
BACKLOG_ACTIONS_MAX = 100
BACKLOG_READS = 150
BACKLOG_IN_PROGRESS_READS = 20
BACKLOG_SLICE = dt.timedelta(hours=3)
BACKLOG_WORKFLOW = "ci-hosted-backlog-rescue.yml"
# A run the backlog pass looks at. `pending` is a run GitHub holds behind its concurrency group (a newer push's run
# cancelled the older one, cancel-in-progress) while its job is already queued and bound to a label: on 2026-11-19 the
# required React Doctor check of cmux#47559 (run 44604684959, created 20:03Z while RUNNER_POOLS.linux_4 read
# `ubuntu-24.04`) sat `pending` with its one job queued on hosted Ubuntu for 8 h, and no pass ever listed it, since
# the pass listed `queued` and `in_progress` runs only. A run `waiting` on an environment approval is never one.
BACKLOG_STATUSES = ("queued", "pending", "in_progress")
BACKLOG_WAITING = ("queued", "pending")
# Waiting runs are read oldest first, but a pass reads about 110 of them (one call each) and the same oldest ones stay
# queued on Blacksmith for hours: on 2026-11-20 each pass listed 489 candidates, read the same 116 oldest, found 0
# stalled, and never reached the hosted-bound runs created after them. The oldest BACKLOG_OLDEST_FIRST keep their place;
# the rest rotate by BACKLOG_ROTATE_STEP a pass (passes are ten minutes apart), so each waiting run is read within a few
# passes however deep the queue is.
BACKLOG_OLDEST_FIRST = 40
BACKLOG_ROTATE_STEP = 70
BACKLOG_PASS_SECONDS = 600
# Journalled cancels: at most BACKLOG_PENDING_MAX wait at once, and each costs at most BACKLOG_RECOVER_CALLS to re-run
# (the run, its pull request, its head's runs, the re-run), so BACKLOG_RECOVER_SHARE covers the rate-limit read, the
# usual journal read (3 calls) and all of them in one pass (84 calls); a long journal walk leaves fewer for that pass,
# and the rest wait for the next. A run not re-run within BACKLOG_RECOVER_WINDOW (it never settled, or its pull request
# could not be read) is reported and dropped.
BACKLOG_PENDING_MAX = 20
BACKLOG_RECOVER_CALLS = 4
BACKLOG_RECOVER_SHARE = 100
BACKLOG_RECOVER_WINDOW = dt.timedelta(hours=24)
BACKLOG_FORCE_AFTER = dt.timedelta(minutes=10)
# The journal walk: one listing of earlier passes, then two calls a pass (its jobs, its log), newest first; it stops at
# the newest log holding a journal, or at BACKLOG_JOURNAL_READS calls.
BACKLOG_JOURNAL_RUNS = 20
BACKLOG_JOURNAL_READS = 41
# The most calls one candidate takes up to and including its cancel (its jobs, its pull request, the re-read of the
# run and its jobs, the cancel).
BACKLOG_RUN_READS = 5
JOURNAL_ENTRY = "hosted-backlog journal: run"
JOURNAL_END = "hosted-backlog journal end:"
# A pass that could not read every newer pass's log writes its entries without JOURNAL_END, so the next pass walks
# back past it to the log it missed.
JOURNAL_PARTIAL = "hosted-backlog journal partial:"
JOURNAL_LINE = re.compile(r"hosted-backlog journal: run (\d+) cancelled (\S+)( force-cancelled)?")
# cmux#45886's passes logged a cancel they never re-ran as "run N (workflow, event, branch): ...; re-run it by hand". A
# pass stopped before its journal (a step timeout) still logged each cancel as it went: "...; the next pass re-runs it".
LEGACY_STRANDED = re.compile(r"\brun (\d+) \(.*(?:re-run it by hand|a later pass re-runs it|the next pass re-runs it)")
UNDATED = dt.datetime.min.replace(tzinfo=UTC)


class EchoLines(list):
    """A pass's log lines, each also printed as it is added, so a pass stopped part way has logged its cancels."""

    def __init__(self, echo: Callable[[str], None] | None) -> None:
        super().__init__()
        self.echo = echo

    def append(self, line: str) -> None:
        super().append(line)
        if self.echo is not None:
            self.echo(line)

    def extend(self, lines: Any) -> None:
        for line in lines:
            self.append(line)


class BacklogReadsSpent(RuntimeError):
    """The pass has made BACKLOG_READS calls; nothing more is sent until the next pass."""


class BacklogReads:
    """The pass's client, every GitHub call through it (read or write) counted against one budget."""

    def __init__(self, client: Any, budget: int) -> None:
        self._client, self.budget, self.spent = client, budget, 0

    def __getattr__(self, name: str) -> Any:
        return getattr(self._client, name)

    @property
    def reads_left(self) -> int:
        return self.budget - self.spent

    def _take(self) -> None:
        if self.spent >= self.budget:
            raise BacklogReadsSpent(f"the pass's {self.budget} calls are spent")
        self.spent += 1

    def request(self, method: str, path: str, *payload: Any) -> Any:
        self._take()
        return self._client.request(method, path, *payload)

    def jobs(self, run_id: int) -> list[dict[str, Any]]:
        self._take()
        return self._client.jobs(run_id)

    def job_log(self, job_id: int) -> list[str]:
        self._take()
        return self._client.job_log(job_id)

    def rate_limit(self) -> tuple[int, float] | None:
        self._take()
        return self._client.rate_limit()

    def cancel(self, run_id: int) -> None:
        self._take()
        self._client.cancel(run_id)

    def force_cancel(self, run_id: int) -> None:
        self._take()
        self._client.force_cancel(run_id)

    def rerun_failed(self, run_id: int) -> None:
        self._take()
        self._client.rerun_failed(run_id)


def reads_left(client: Any) -> float:
    """Calls the pass may still make (unbounded for a client that does not count them)."""
    return getattr(client, "reads_left", float("inf"))


# One-job JIT labels a route moved off, and the workflows whose re-run (attempt 2) takes the job somewhere else. On
# 2026-11-21 cmux#49216 moved cmux-next.yml's Linux control hops from cmux-gcp-pr-control-jit-x64 (one fresh VM per
# job, created at most about 60 a minute) to cmux-linux, the persistent pool; at 18:20Z 1,420 jobs were still queued on
# the JIT label, the oldest from 15:24Z, and 30 on cmux-gcp-gate-jit-x64, since GitHub never re-routes a queued job.
# A job queued alone on one of these labels for BACKLOG_STALL counts as stalled. A superseded run is cancelled for good
# whatever its workflow. A run at its pull request's head is cancelled and re-run only when its workflow's re-run
# leaves the label: cmux-next.yml names cmux-gcp-pr-control-jit-x64 on `github.run_attempt == 1` only, so attempt 2
# falls through to RUNNER_POOLS. The other workflows on these labels (main's pull_request_target control workflows,
# backend-migrations.yml on the gate label) name it on every attempt; a re-run there would only rejoin the queue at
# its tail, so such a run stays queued at its head.
MOVED_JIT_LABELS: Mapping[str, frozenset[str]] = {
    "cmux-gcp-pr-control-jit-x64": frozenset({"cmux-next.yml"}),
    "cmux-gcp-gate-jit-x64": frozenset(),
}


def backlog_rerun_moves(stuck: Sequence[Mapping[str, Any]], workflow: str | None) -> str:
    """"" when a re-run takes every stalled job off its label; else the moved JIT label a re-run would return to."""
    for job in stuck:
        labels = [str(label) for label in job.get("labels") or ()]
        if len(labels) == 1 and labels[0] in MOVED_JIT_LABELS and workflow not in MOVED_JIT_LABELS[labels[0]]:
            return labels[0]
    return ""


def backlog_where(stuck: Sequence[Mapping[str, Any]]) -> str:
    """Where the stalled jobs wait: hosted Ubuntu, a moved JIT label, or both (Blacksmith jobs are counted apart)."""
    jit = sorted({str(label) for job in stuck for label in job.get("labels") or () if label in MOVED_JIT_LABELS})
    hosted = any(all(HOSTED_LABEL.match(str(label)) for label in job.get("labels") or ()) for job in stuck)
    return " and ".join((["hosted Ubuntu"] if hosted else []) + jit)


# Blacksmith is overflow only, and owned labels come first (Leo: "stop ... relying on it"). A job queued on a Blacksmith
# Ubuntu label keeps it, like any queued job, after its route moved to an owned label; on 2026-11-21 about 70 waited
# there at 12:00Z while owned Linux runners sat idle. A cancel and re-run moves such a job only when its `runs-on`
# reads the route again on the re-run; a job pinned to a Blacksmith label goes back to the same queue's tail
# (test_legacy_blacksmith_web_validation_is_never_cancelled_back_onto_its_fixed_label). So a Blacksmith job counts as
# stalled only when RerunRoutes shows its re-run takes an owned label: its job in the workflow file of its pull
# request's base branch reads `vars.LINUX_RUNNER` first, and that variable (read by the workflow, passed in
# BACKLOG_LINUX_RUNNER) names neither a Blacksmith nor a GitHub-hosted label. Anything else stays where it is.
RUNS_ON_OWNER_CLAUSE = re.compile(r"github\.repository_owner != 'manaflow-ai' && '[^']*' \|\| ")
RUNS_ON_FORK_CLAUSE = re.compile(r"github\.event_name == 'pull_request' && github\.event\.pull_request\.head\.repo\."
                                 r"full_name != github\.repository && '[^']*' \|\| ")
RUNS_ON_LINUX_RUNNER_FIRST = re.compile(r"(?:!startsWith\(vars\.LINUX_RUNNER, 'blacksmith-'\) && )?"
                                        r"vars\.LINUX_RUNNER \|\| ")
HOSTED_ANY_LABEL = re.compile(r"^(?:ubuntu|macos|windows)-[\w.-]+$")


def owned_linux_route(label: str | None) -> bool:
    """`label` (vars.LINUX_RUNNER) names an owned runner label: set, and neither Blacksmith nor GitHub-hosted."""
    label = (label or "").strip()
    return bool(label) and not label.startswith("blacksmith-") and not HOSTED_ANY_LABEL.match(label)


def rerun_reads_linux_runner(runs_on: str) -> bool:
    """A same-repository pull request job with this `runs-on` takes vars.LINUX_RUNNER when it is set (and not
    Blacksmith): the owner clause and the fork clause aside, the expression starts with the variable."""
    match = re.fullmatch(r"\$\{\{\s*(.*?)\s*\}\}", runs_on.strip())
    if not match:
        return False
    body = match.group(1)
    for clause in (RUNS_ON_OWNER_CLAUSE, RUNS_ON_FORK_CLAUSE):
        found = clause.match(body)
        if found:
            body = body[found.end():]
    return bool(RUNS_ON_LINUX_RUNNER_FIRST.match(body))


def workflow_job_routes(text: str) -> list[tuple[re.Pattern[str], str]]:
    """(display-name pattern, single-line `runs-on`) of each job in a workflow file. A templated name matches any
    value, and a matrix job's ` (a, b)` suffix is allowed; a job with no `name:` shows its key."""
    routes: list[tuple[re.Pattern[str], str]] = []
    in_jobs = False
    key = name = runs_on = None

    def close() -> None:
        if key is not None and runs_on is not None:
            shown = name if name is not None else key
            parts = re.split(r"\$\{\{.*?\}\}", shown)
            routes.append((re.compile("(?:" + ".+?".join(re.escape(part) for part in parts) + r")(?: \(.*\))?"),
                           runs_on))

    for line in text.splitlines():
        if re.match(r"^jobs:\s*(?:#.*)?$", line):
            in_jobs = True
            continue
        if not in_jobs:
            continue
        if line and not line.startswith(" ") and not line.startswith("#"):
            break
        top = re.match(r"^  ([A-Za-z_][\w-]*):\s*(?:#.*)?$", line)
        if top:
            close()
            key, name, runs_on = top.group(1), None, None
            continue
        field_ = re.match(r"^    (name|runs-on):\s*(.+?)\s*$", line)
        if field_ and key is not None:
            value = re.sub(r"\s+#\s.*$", "", field_.group(2))
            if field_.group(1) == "name":
                name = value[1:-1] if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"" else value
            else:
                runs_on = value
    close()
    return routes


class RerunRoutes:
    """Whether a backlog re-run takes a stalled Blacksmith job to an owned label (see RUNS_ON_LINUX_RUNNER_FIRST)."""

    def __init__(self, workflows: Mapping[str, Path], linux_runner: str | None) -> None:
        self.workflows, self.linux_runner = dict(workflows), linux_runner
        self._routes: dict[tuple[str, str], list[tuple[re.Pattern[str], str]] | None] = {}

    def routes(self, base: str, workflow: str) -> list[tuple[re.Pattern[str], str]] | None:
        if (base, workflow) not in self._routes:
            directory = self.workflows.get(base)
            try:
                text = (directory / workflow).read_text(encoding="utf-8") if directory is not None else None
            except OSError:
                text = None
            self._routes[(base, workflow)] = workflow_job_routes(text) if text is not None else None
        return self._routes[(base, workflow)]

    def for_run(self, run: Mapping[str, Any]) -> Callable[[Mapping[str, Any]], bool]:
        """A judge for one run's jobs: True only for a job whose every matching `runs-on` reads LINUX_RUNNER first,
        while LINUX_RUNNER names an owned label."""
        if not owned_linux_route(self.linux_runner):
            return lambda _job: False
        bases = {str((pr.get("base") or {}).get("ref") or "") for pr in run.get("pull_requests") or ()
                 if isinstance(pr, Mapping)}
        workflow = workflow_file(run)
        if len(bases) != 1 or workflow is None:
            return lambda _job: False
        routes = self.routes(bases.pop(), workflow)
        if not routes:
            return lambda _job: False

        def leaves(job: Mapping[str, Any]) -> bool:
            name = str(job.get("name") or "")
            found = [runs_on for pattern, runs_on in routes if pattern.fullmatch(name)]
            return bool(found) and all(rerun_reads_linux_runner(runs_on) for runs_on in found)
        return leaves


def backlog_stalled(job: Mapping[str, Any], now: dt.datetime,
                    leaves: Callable[[Mapping[str, Any]], bool] | None = None) -> bool:
    """Queued with no runner for BACKLOG_STALL or more on GitHub-hosted Ubuntu labels only, on one moved JIT label
    (MOVED_JIT_LABELS) alone, or on Blacksmith Ubuntu labels (with hosted ones or alone) when `leaves(job)` says its
    re-run takes an owned label."""
    labels = [str(label) for label in job.get("labels") or ()]
    created = parse_time(job.get("created_at"))
    if not (job.get("status") == "queued" and not job.get("runner_id") and not job.get("runner_name")
            and bool(labels) and created is not None and now - created >= BACKLOG_STALL):
        return False
    if all(HOSTED_LABEL.match(label) for label in labels):
        return True
    if len(labels) == 1 and labels[0] in MOVED_JIT_LABELS:
        return True
    return (all(HOSTED_LABEL.match(label) or BLACKSMITH_LINUX_LABEL.match(label) for label in labels)
            and leaves is not None and leaves(job))


def backlog_verdict(jobs: Sequence[Mapping[str, Any]], now: dt.datetime,
                    leaves: Callable[[Mapping[str, Any]], bool] | None = None
                    ) -> tuple[bool, list[Mapping[str, Any]]]:
    """(every unfinished job is a stalled hosted (or movable Blacksmith) job, the stalled jobs)."""
    stuck = [job for job in jobs if backlog_stalled(job, now, leaves)]
    stuck_ids = {id(job) for job in stuck}
    others = [job for job in jobs if job.get("status") != "completed" and id(job) not in stuck_ids]
    return bool(stuck) and not others, stuck


def backlog_listing(client: Any, status: str, event: str, start: dt.datetime, end: dt.datetime,
                    page: int = 1) -> tuple[int, list[dict[str, Any]]]:
    """One page of `status` runs of `event` created in [start, end], newest first, and the listing's total count."""
    query = urllib.parse.urlencode({"status": status, "event": event, "per_page": LIST_PAGE, "page": page,
                                    "created": f"{iso(start)}..{iso(end)}"})
    answer = client.request("GET", f"/actions/runs?{query}")
    return int(answer.get("total_count") or 0), list(answer.get("workflow_runs") or [])


def backlog_oldest(client: Any, status: str, event: str, start: dt.datetime, end: dt.datetime,
                   want: int, turn: int = 0) -> list[dict[str, Any]]:
    """The oldest `status` runs of `event` in [start, end], about `want` of them.

    A quiet repository costs one read. A listing over one page reads its last (oldest) page instead, and one over
    the 1,000 runs GitHub serves is walked in BACKLOG_SLICE slices from the oldest, so the runs that waited longest
    are found first however deep the queue is. Under 1,000 runs the first page (the newest, read anyway for the
    count) is kept too, and one of the pages between is read by `turn` (the pass), so a run created after the
    oldest `want` is still listed within a few passes."""
    total, rows = backlog_listing(client, status, event, start, end)
    if total <= LIST_PAGE:
        return rows
    if total <= 10 * LIST_PAGE:
        return oldest_pages(client, status, event, start, end, total, want, turn=turn) + rows
    found: list[dict[str, Any]] = []
    cut = start
    while cut < end and len(found) < want and reads_left(client) > BACKLOG_READS // 2:
        upper = min(end, cut + BACKLOG_SLICE)
        part_total, part = backlog_listing(client, status, event, cut, upper)
        if part_total > LIST_PAGE:
            part = oldest_pages(client, status, event, cut, upper, min(part_total, 10 * LIST_PAGE), want - len(found))
        found.extend(part)
        cut = upper
    return found


def oldest_pages(client: Any, status: str, event: str, start: dt.datetime, end: dt.datetime, total: int,
                 want: int, turn: int = 0) -> list[dict[str, Any]]:
    """The last pages of a listing of `total` runs (the oldest), back to at least `want` runs; with `turn`, also one
    of the unread pages after page 1, chosen by it."""
    found: list[dict[str, Any]] = []
    page = -(-total // LIST_PAGE)
    while page >= 1 and len(found) < want and reads_left(client) > BACKLOG_READS // 2:
        found.extend(backlog_listing(client, status, event, start, end, page=page)[1])
        page -= 1
    if turn and page >= 2 and reads_left(client) > BACKLOG_READS // 2:
        found.extend(backlog_listing(client, status, event, start, end, page=2 + turn % (page - 1))[1])
    return found


def backlog_pulls(client: Any, run: Mapping[str, Any]) -> list[tuple[str, str]]:
    """(state, head sha) of each pull request the run belongs to, read live.

    From the run's own pull request list; when GitHub left it empty (it drops the link once the head moves on), the
    pull requests whose head is the run's branch in this repository."""
    numbers = [pr["number"] for pr in run.get("pull_requests") or ()
               if isinstance(pr, Mapping) and isinstance(pr.get("number"), int)]
    if numbers:
        found = []
        for number in numbers:
            pull = client.request("GET", f"/pulls/{number}")
            found.append((str(pull.get("state") or ""), str((pull.get("head") or {}).get("sha") or "")))
        return found
    branch = str(run.get("head_branch") or "")
    owner = str(((run.get("head_repository") or {}).get("owner") or {}).get("login") or "")
    if not branch or not owner:
        return []
    query = urllib.parse.urlencode({"state": "all", "head": f"{owner}:{branch}", "per_page": 10})
    pulls = client.request("GET", f"/pulls?{query}")
    return [(str(pull.get("state") or ""), str((pull.get("head") or {}).get("sha") or ""))
            for pull in pulls if isinstance(pull, Mapping)] if isinstance(pulls, list) else []


def backlog_head(client: Any, run: Mapping[str, Any]) -> str:
    """'current', 'superseded' or 'unknown' for the run's pull request.

    A pull_request run is at its head when an open pull request's head is the run's head_sha. A pull_request_target
    run's head_sha is the base branch's, so its pull request is at the head the run was made for when the head the run
    lists for it is still the live one."""
    if run.get("event") == "pull_request_target":
        listed = {pr["number"]: str((pr.get("head") or {}).get("sha") or "") for pr in run.get("pull_requests") or ()
                  if isinstance(pr, Mapping) and isinstance(pr.get("number"), int)}
        if not listed:
            return "unknown"
        live = backlog_pulls(client, run)
        if any(state == "open" and head and head in listed.values() for state, head in live):
            return "current"
        return "superseded" if live else "unknown"
    live = backlog_pulls(client, run)
    if any(state == "open" and head == run.get("head_sha") for state, head in live):
        return "current"
    return "superseded" if live else "unknown"


@dataclass
class Journalled:
    """A current-head run a backlog pass cancelled and has not re-run yet."""

    cancelled_at: dt.datetime
    forced: bool = False


def parse_journal(log: Sequence[str]) -> tuple[bool, dict[int, Journalled]]:
    """(the log holds a whole journal, its entries). Journal lines are entries in any log; a log without a whole
    journal also yields its legacy and per-cancel "re-run" lines, UNDATED."""
    whole = any(JOURNAL_END in line for line in log)
    entries: dict[int, Journalled] = {}
    for line in log:
        match = JOURNAL_LINE.search(line)
        moment = parse_time(match.group(2)) if match else None
        if match and moment is not None:
            entries[int(match.group(1))] = Journalled(moment, bool(match.group(3)))
            continue
        legacy = None if whole else LEGACY_STRANDED.search(line)
        if legacy:
            entries.setdefault(int(legacy.group(1)), Journalled(UNDATED))
    return whole, entries


def journal_lines(journal: Mapping[int, Journalled], *, whole: bool = True) -> list[str]:
    """The journal as the pass's last log lines, oldest cancel first, for the next pass to read. A partial one (this
    pass missed a newer log) ends without JOURNAL_END, so the next pass reads past it."""
    lines = [f"{JOURNAL_ENTRY} {run_id} cancelled {iso(entry.cancelled_at)}{' force-cancelled' if entry.forced else ''}"
             for run_id, entry in sorted(journal.items(), key=lambda item: (item[1].cancelled_at, item[0]))]
    end = JOURNAL_END if whole else JOURNAL_PARTIAL
    return lines + [f"{end} {len(journal)} cancelled runs wait for their re-run"]


@dataclass
class JournalRead:
    """What read_journal found: the entries, whether a newer log went unread (the journal is partial), and whether
    current-head cancels wait this pass (a partial journal, or a walk that ran out before a whole one)."""

    entries: dict[int, Journalled]
    partial: bool = False
    hold: str = ""


def read_journal(client: Any, *, now: dt.datetime, since: dt.datetime | None,
                 lines: list[str]) -> JournalRead | None:
    """The journal from the newest earlier pass's log that has one (with `since`, the union of every pass's back to
    it), or None when no earlier pass's log could be read. Legacy lines on the way are entries too, dated by their
    pass."""
    floor = since or now - BACKLOG_RECOVER_WINDOW
    query = urllib.parse.urlencode({"status": "completed", "per_page": BACKLOG_JOURNAL_RUNS,
                                    "created": f">={iso(floor)}"})
    own = int(os.environ.get("GITHUB_RUN_ID") or 0)
    spend_from = reads_left(client)
    try:
        answer = client.request("GET", f"/actions/workflows/{BACKLOG_WORKFLOW}/runs?{query}")
    except Exception as error:  # noqa: BLE001 - no journal: no current-head cancel this pass
        lines.append(f"could not list earlier backlog passes ({error})")
        return None
    passes = [run for run in answer.get("workflow_runs") or ()
              if isinstance(run, Mapping) and isinstance(run.get("id"), int) and run["id"] != own]
    journal: dict[int, Journalled] = {}
    read_any = unread = found_whole = stopped = False
    for earlier in passes:
        if spend_from - reads_left(client) + 2 > BACKLOG_JOURNAL_READS:
            lines.append(f"the journal walk stopped at {BACKLOG_JOURNAL_READS} calls")
            stopped = True
            break
        dated = parse_time(earlier.get("created_at")) or now
        log: list[str] | None = None
        for attempt in range(2):  # a log GitHub has not served yet, or a passing 5xx, gets one more read
            if attempt and spend_from - reads_left(client) + 2 > BACKLOG_JOURNAL_READS:
                break
            try:
                log = []
                for found in client.jobs(earlier["id"]):
                    if isinstance(found.get("id"), int):
                        log = list(client.job_log(found["id"]))
                        break
                break
            except Exception as error:  # noqa: BLE001 - an unread log is skipped; an older one may hold the journal
                log = None
                lines.append(f"could not read backlog pass {earlier['id']}'s log ({error})")
        if log is None:
            unread = True  # its cancels may be in no older log: the journal written below is partial
            continue
        read_any = True
        whole, entries = parse_journal(log)
        for run_id, entry in entries.items():
            if entry.cancelled_at == UNDATED:
                entry.cancelled_at = dated
            journal.setdefault(run_id, entry)  # newest pass first: its view of a run wins
        if whole:
            found_whole = True
            if since is None:
                break
    if not read_any and passes:
        return None
    result = JournalRead(journal, partial=unread)
    if unread:
        result.hold = "a newer pass's log could not be read"
    elif not found_whole and (stopped or len(passes) >= BACKLOG_JOURNAL_RUNS):
        # Older passes than this walk reaches may hold cancels nobody re-ran: say so, and start a whole journal anew.
        result.hold = "no whole journal within the passes read"
        lines.append(f"::warning title=Hosted backlog rescue::no whole journal in the {len(passes)} newest backlog passes "
                     f"read; cancels logged before {passes[-1].get('created_at')} are not re-run by this rescue")
    elif since is not None and (stopped or len(passes) >= BACKLOG_JOURNAL_RUNS):
        lines.append(f"::warning title=Hosted backlog rescue::the walk back to {iso(since)} read only "
                     f"{len(passes)} passes; dispatch again with a later recover_since for the rest")
    return result


def pull_numbers(run: Mapping[str, Any]) -> set[int]:
    return {pr["number"] for pr in run.get("pull_requests") or ()
            if isinstance(pr, Mapping) and isinstance(pr.get("number"), int)}


def newer_for_same_pull(run: Mapping[str, Any], other: Any) -> bool:
    """`other` is a newer run of `run`'s workflow and event for the same pull request, so it stands in for a re-run.

    A pull_request_target run's head_sha is the base branch's, shared by every pull request on that base (and by push
    runs there): only a run listing one of the same pull requests counts. A pull_request run must share its branch."""
    if not isinstance(other, Mapping) or int(other.get("id") or 0) <= int(run.get("id") or 0):
        return False
    if other.get("path") != run.get("path") or other.get("event") != run.get("event"):
        return False
    if run.get("event") == "pull_request_target":
        return bool(pull_numbers(run) & pull_numbers(other))
    return other.get("head_branch") == run.get("head_branch")


def backlog_recover(client: Any, journal: dict[int, Journalled], *, now: dt.datetime, dry_run: bool,
                    lines: list[str], counts: dict[str, int]) -> None:
    """Re-run each journalled run whose cancel settled; drop the ones that need nothing more, keep the rest."""
    repo = getattr(client, "repo", "")
    for run_id, entry in sorted(journal.items(), key=lambda item: (item[1].cancelled_at, item[0])):
        where = f"run {run_id}"
        if now - entry.cancelled_at > BACKLOG_RECOVER_WINDOW:
            counts["expired"] += 1
            lines.append(f"::warning title=Hosted backlog rescue::{where} was cancelled at {iso(entry.cancelled_at)} "
                         f"and not re-run in {int(BACKLOG_RECOVER_WINDOW.total_seconds() // 3600)} h; re-run its "
                         f"failed jobs: https://github.com/{repo}/actions/runs/{run_id}")
            del journal[run_id]
            continue
        if BACKLOG_READS - reads_left(client) + BACKLOG_RECOVER_CALLS > BACKLOG_RECOVER_SHARE:
            lines.append(f"recovery stopped at {BACKLOG_RECOVER_SHARE} calls; the next pass goes on")
            break
        try:
            state = client.request("GET", f"/actions/runs/{run_id}")
            if state.get("run_attempt") != 1 or (state.get("status") == "completed"
                                                 and state.get("conclusion") != "cancelled"):
                del journal[run_id]  # re-run by someone else, or it finished after all
                continue
            if state.get("status") != "completed":
                if not entry.forced and now - entry.cancelled_at >= BACKLOG_FORCE_AFTER and not dry_run:
                    client.force_cancel(run_id)
                    entry.forced = True
                    lines.append(f"{where}: its cancel did not settle in "
                                 f"{int(BACKLOG_FORCE_AFTER.total_seconds() // 60)} min; force-cancelled")
                continue
            head = backlog_head(client, state)
            if head == "superseded":
                lines.append(f"{where}: its pull request closed or moved on since the cancel; not re-run")
                del journal[run_id]
                continue
            if head != "current":
                continue
            others = client.request("GET", f"/actions/runs?head_sha={state.get('head_sha')}&per_page=100")
            if any(newer_for_same_pull(state, other) for other in others.get("workflow_runs") or ()):
                del journal[run_id]
                continue
            if dry_run:
                lines.append(f"{where}: cancelled by a backlog pass and settled; would re-run (dry run)")
                continue
            client.rerun_failed(run_id)
        except Exception as error:  # noqa: BLE001 - unread or refused: the next pass looks again
            lines.append(f"{where}: cancelled by a backlog pass, not re-run this pass ({error})")
            continue
        del journal[run_id]
        counts["recovered"] += 1
        lines.append(f"{where}: cancelled by a backlog pass; re-ran its failed jobs on today's routes")


def budget_short(client: Any, lines: list[str]) -> bool:
    """Read the write token's rate limit once; True (and why) when it cannot cover a whole pass."""
    read = getattr(client, "rate_limit", None)
    if not callable(read):
        return False
    try:
        limit = read()
    except Exception as error:  # noqa: BLE001 - an unknown budget cannot promise a cancel its re-run
        lines.append(f"skipped: the token's rate limit could not be read ({error}); nothing read, cancelled or "
                     f"re-run")
        return True
    if limit is None:
        return False
    remaining, reset = limit
    if remaining >= BACKLOG_READS + POOL_RESERVE:
        return False
    until = dt.datetime.fromtimestamp(reset, UTC).strftime("%H:%M:%SZ") if reset else "its reset"
    lines.append(f"skipped: the token has {remaining} core API calls left until {until}; a pass needs "
                 f"{BACKLOG_READS} plus the {POOL_RESERVE} reserve; nothing read, cancelled or re-run")
    return True


def backlog_sweep(client: Any, *, now: dt.datetime, dry_run: bool, declared: Sequence[str] | None,
                  actions: int = BACKLOG_ACTIONS, since: dt.datetime | None = None, run_ids: Sequence[int] = (),
                  echo: Callable[[str], None] | None = None, sleep: Callable[[float], None] = time.sleep,
                  clock: Callable[[], float] = time.monotonic,
                  routes: RerunRoutes | None = None) -> tuple[list[str], dict[str, int]]:
    """One bounded backlog pass. Returns its log lines (the journal last) and counts (cancelled, recovered, ...).

    A pass never waits for a cancel to settle (the next pass re-runs it), so `sleep` and `clock` go unused."""
    del sleep, clock
    lines: list[str] = EchoLines(echo)
    counts = {"candidates": 0, "read": 0, "stalled": 0, "cancelled": 0, "superseded": 0, "journalled": 0,
              "recovered": 0, "expired": 0, "pending": 0, "stays": 0, "requests": 0}
    actions = max(0, min(int(actions), BACKLOG_ACTIONS_MAX))
    client = BacklogReads(client, BACKLOG_READS)
    if budget_short(client, lines) or pool_low(client, now):
        if not lines:
            lines.append(f"the read token's pool is down to {client.remaining} (reserve {getattr(client, 'reserve', POOL_RESERVE)}); nothing read")
        counts["requests"] = client.spent
        return lines, counts
    read = read_journal(client, now=now, since=since, lines=lines)
    journal = read.entries if read is not None else None
    hold = "no journal was read" if read is None else read.hold
    if journal is None:
        lines.append("::warning title=Hosted backlog rescue::no earlier pass's journal could be read; no current-head "
                     "run is cancelled this pass")
    else:
        backlog_recover(client, journal, now=now, dry_run=dry_run, lines=lines, counts=counts)
    try:
        backlog_scan(client, journal, now=now, dry_run=dry_run, declared=declared, actions=actions, lines=lines,
                     counts=counts, hold=hold, run_ids=run_ids, routes=routes)
    except Exception as error:  # noqa: BLE001 - the journal below still goes out for the next pass
        lines.append(f"the pass stopped early ({error})")
    counts["pending"] = len(journal or {})
    counts["requests"] = client.spent
    lines.append(f"{counts['candidates']} candidate runs, {counts['read']} read, {counts['stalled']} stalled, "
                 f"{counts['cancelled']} cancelled ({counts['superseded']} superseded), {counts['recovered']} "
                 f"earlier cancels re-run, {counts['pending']} wait for their re-run; {client.spent} of "
                 f"{BACKLOG_READS} API calls")
    if counts["stays"]:
        lines.append(f"{counts['stays']} stalled runs at their head left queued: their re-run takes the same JIT label")
    if journal is not None:
        lines.extend(journal_lines(journal, whole=not read.partial))
    return lines, counts


def backlog_rotate(waiting: Sequence[Mapping[str, Any]], now: dt.datetime) -> list[Mapping[str, Any]]:
    """`waiting` (oldest first) with its oldest BACKLOG_OLDEST_FIRST in place and the rest rotated by this pass."""
    head, tail = list(waiting[:BACKLOG_OLDEST_FIRST]), list(waiting[BACKLOG_OLDEST_FIRST:])
    if not tail:
        return head
    offset = (int(now.timestamp()) // BACKLOG_PASS_SECONDS * BACKLOG_ROTATE_STEP) % len(tail)
    return head + tail[offset:] + tail[:offset]


def backlog_scan(client: Any, journal: dict[int, Journalled] | None, *, now: dt.datetime, dry_run: bool,
                 declared: Sequence[str] | None, actions: int, lines: list[str], counts: dict[str, int],
                 hold: str = "", run_ids: Sequence[int] = (), routes: RerunRoutes | None = None) -> None:
    """Find stalled runs and cancel them: a current-head one into the journal, a superseded one for good. With
    `run_ids`, only those runs are read (one call each), under the same rules, instead of the listings."""
    start, end = now - BACKLOG_WINDOW, now - BACKLOG_STALL
    minute_pass_from = now - WINDOW
    repo = getattr(client, "repo", "")
    listed: dict[int, Mapping[str, Any]] = {}

    def eligible(run: Any) -> str:
        """Why the backlog rules leave `run` alone, or "" when it is a candidate."""
        created = parse_time(run.get("created_at")) if isinstance(run, Mapping) else None
        workflow = workflow_file(run) if isinstance(run, Mapping) else None
        if not isinstance(run, Mapping) or not isinstance(run.get("id"), int) or created is None:
            return "not a run"
        if run.get("event") not in BACKLOG_EVENTS:
            return f"a {run.get('event')} run, not a pull request's"
        if workflow is None or workflow in EXCLUDED_WORKFLOWS:
            return f"workflow {workflow} is never touched"
        if repo and str((run.get("head_repository") or {}).get("full_name") or "") != repo:
            return "a fork's run"
        if run.get("run_attempt") != 1:
            return f"attempt {run.get('run_attempt')}, not 1"
        if run.get("status") not in BACKLOG_STATUSES:
            return f"{run.get('status')}, not queued, pending or in progress"
        if not (start <= created <= end):
            return f"created {run.get('created_at')}, outside {int(BACKLOG_STALL.total_seconds() // 60)} min to 24 h ago"
        # The minute pass owns a declared workflow's run under WINDOW old; unread declarations leave every run under
        # WINDOW to it.
        if created >= minute_pass_from and (declared is None or workflow in declared):
            return "the minute pass's run"
        return ""

    if run_ids:
        for run_id in run_ids:
            try:
                run = client.request("GET", f"/actions/runs/{run_id}")
            except Exception as error:  # noqa: BLE001
                lines.append(f"run {run_id}: could not read ({error}); left alone")
                continue
            why = eligible(run)
            if why:
                lines.append(f"run {run_id}: {why}; left alone")
                continue
            listed[run["id"]] = {**run, "_workflow": workflow_file(run)}
    for status in () if run_ids else BACKLOG_STATUSES:
        for event in BACKLOG_EVENTS:
            try:
                rows = backlog_oldest(client, status, event, start, end, BACKLOG_READS,
                                      turn=int(now.timestamp()) // BACKLOG_PASS_SECONDS)
            except Exception as error:  # noqa: BLE001 - an unread listing only narrows this pass
                lines.append(f"could not list {status} {event} runs ({error})")
                continue
            for run in rows:
                if not eligible(run):
                    listed[run["id"]] = {**run, "_workflow": workflow_file(run)}
    # Waiting runs first (nothing of theirs started), then the rest; oldest first within each, the waiting tail rotated.
    order = sorted(listed.values(), key=lambda run: (run.get("status") not in BACKLOG_WAITING,) + run_key(run))
    waiting = [run for run in order if run.get("status") in BACKLOG_WAITING]
    order = backlog_rotate(waiting, now) + order[len(waiting):]
    counts["candidates"] = len(order)
    in_progress_reads = 0
    held = False
    for run in order:
        if counts["cancelled"] >= actions:
            break
        if reads_left(client) < BACKLOG_RUN_READS:
            lines.append(f"stopped: the pass's {BACKLOG_READS} API calls are spent")
            break
        if run.get("status") not in BACKLOG_WAITING:
            # A run that started something is usually still working: read a few a pass, not every old one.
            if in_progress_reads >= BACKLOG_IN_PROGRESS_READS:
                break
            in_progress_reads += 1
        if pool_low(client, now):
            lines.append(f"the read token's pool is down to {client.remaining} (reserve {getattr(client, 'reserve', POOL_RESERVE)}); stopped")
            break
        where = f"run {run['id']} ({run['_workflow']}, {run.get('event')}, {run.get('head_branch')})"
        try:
            counts["read"] += 1
            leaves = routes.for_run(run) if routes is not None else None
            rescue_it, stuck = backlog_verdict(client.jobs(run["id"]), now, leaves)
            if not rescue_it:
                if run_ids:
                    lines.append(f"{where}: not every unfinished job has waited {int(BACKLOG_STALL.total_seconds() // 60)}"
                                 f" min with no runner on hosted Ubuntu, a moved JIT label (or on Blacksmith Ubuntu with an"
                                 f" owned re-run route); left alone")
                continue
            counts["stalled"] += 1
            head = backlog_head(client, run)
        except Exception as error:  # noqa: BLE001 - unread means unknown: leave the run
            lines.append(f"{where}: could not read ({error}); left alone")
            continue
        oldest = max(int((now - parse_time(job["created_at"])).total_seconds() // 60) for job in stuck)
        on_blacksmith = sum(1 for job in stuck
                            if not all(HOSTED_LABEL.match(str(label)) for label in job.get("labels") or ())
                            and not set(job.get("labels") or ()) & set(MOVED_JIT_LABELS))
        on_where = backlog_where(stuck)
        detail = (f"{len(stuck)} jobs queued on {on_where}, the oldest {oldest} min" if not on_blacksmith else
                  f"{len(stuck)} jobs queued{' on ' + on_where if on_where else ''} ({on_blacksmith} on Blacksmith"
                  f" Ubuntu, re-run on {routes.linux_runner}), the oldest {oldest} min")
        if head == "unknown":
            lines.append(f"{where}: {detail}; its pull request could not be told; left alone")
            continue
        stays = backlog_rerun_moves(stuck, run["_workflow"]) if head == "current" else ""
        if stays:
            counts["stays"] += 1
            lines.append(f"{where}: {detail}; at its head, and its re-run would queue on {stays} again; left alone")
            continue
        if head == "current" and (journal is None or hold or len(journal) >= BACKLOG_PENDING_MAX):
            # A cancel the next pass could not re-run would leave its pull request with no checks: leave it queued.
            if not held:
                why = ("no journal was read" if journal is None else hold
                       or f"{len(journal)} earlier cancels still wait for their re-run")
                lines.append(f"current-head runs are left queued this pass: {why}")
                held = True
            continue
        if dry_run:
            verb = "cancel, and re-run next pass" if head == "current" else "cancel (superseded)"
            lines.append(f"{where}: {detail}; would {verb} (dry run)")
            continue
        # Right before the cancel: still attempt 1, in flight, and every unfinished job still a stalled hosted one.
        try:
            fresh = client.request("GET", f"/actions/runs/{run['id']}")
            again, _ = backlog_verdict(client.jobs(run["id"]), now, leaves)
        except Exception as error:  # noqa: BLE001
            lines.append(f"{where}: could not re-read before the cancel ({error}); left alone")
            continue
        if fresh.get("run_attempt") != 1 or fresh.get("status") not in BACKLOG_STATUSES or not again:
            lines.append(f"{where}: a job started, or the run moved on, since the read; left alone")
            continue
        try:
            client.cancel(run["id"])
        except Exception as error:  # noqa: BLE001
            code = getattr(error, "code", None) or getattr(error, "status", None)
            if head != "current" or (isinstance(code, int) and 400 <= code < 500) or isinstance(error, BacklogReadsSpent):
                lines.append(f"{where}: cancel refused ({error})")
                continue
            # A timeout or 5xx may come after GitHub took the cancel: journal it; recovery drops it if it ran on.
            journal[run["id"]] = Journalled(now)
            counts["journalled"] += 1
            lines.append(f"{where}: {detail}; the cancel's answer was lost ({error}); journalled, and the next pass "
                         f"re-runs it if it was cancelled")
            continue
        counts["cancelled"] += 1
        if head == "superseded":
            counts["superseded"] += 1
            lines.append(f"{where}: {detail}; its pull request closed or moved on: cancelled, not re-run")
            continue
        assert journal is not None
        journal[run["id"]] = Journalled(now)
        counts["journalled"] += 1
        lines.append(f"{where}: {detail}; cancelled; the next pass re-runs it once the cancel settles")


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


def backlog_main(args: argparse.Namespace, env: Mapping[str, str], repo: str, *, client: Any,
                 now: dt.datetime, sleep: Callable[[float], None]) -> int:
    """Run one backlog pass. Reads and writes go out as cmux-bot (HOSTED_LIGHT_TOKEN) when the workflow minted it, so
    the repository's shared GITHUB_TOKEN pool (GH_TOKEN) answers only reads, only while cmux-bot is low or refused."""
    declared: list[str] | None = None
    if args.policy is not None:
        try:
            runners = json.loads((args.policy / "runners.json").read_text(encoding="utf-8"))
            declared = with_callers(declared_workflows(runners), args.policy / "workflows")
        except (OSError, ValueError) as error:
            print(f"could not read the declared workflows under {args.policy} ({error}); "
                  f"every run under {int(WINDOW.total_seconds() // 60)} min is left to the minute pass")
    raw = (env.get("BACKLOG_ACTIONS") or "").strip()
    actions = int(raw) if raw.isdigit() else BACKLOG_ACTIONS
    raw_ids = (args.run_ids or env.get("BACKLOG_RUN_IDS") or "").strip()
    run_ids = [int(part) for part in re.split(r"[\s,]+", raw_ids) if part.isdigit()]
    if raw_ids and not run_ids:
        print(f"::warning title=Hosted backlog rescue::no run id in {raw_ids!r}; nothing to do")
        return 0
    raw_since = (args.recover_since or env.get("BACKLOG_RECOVER_SINCE") or "").strip()
    since = parse_time(raw_since) if raw_since else None
    if raw_since and since is None:
        print(f"could not read the recovery start {raw_since!r} (want e.g. 2026-11-18T08:50:00Z); the newest journal "
              f"is read")
    if client is None:
        bot = (env.get("HOSTED_LIGHT_TOKEN") or "").strip()
        workflow = (env.get("GH_TOKEN") or "").strip()
        if not (bot or workflow) or not repo:
            print("::warning title=Hosted backlog rescue::no token or repository; nothing to do")
            return 0
        if bot and workflow and bot != workflow:
            client = GitHub(bot, repo, bot, fallback=workflow)
        else:
            client = GitHub(bot or workflow, repo, bot or workflow)
    route_dirs: dict[str, Path] = {}
    for spec in args.route_workflows or ():
        base, _, directory = spec.partition("=")
        if base and directory:
            route_dirs[base] = Path(directory)
    routes = RerunRoutes(route_dirs, env.get("BACKLOG_LINUX_RUNNER"))
    lines, _ = backlog_sweep(client, now=now, dry_run=args.dry_run, declared=declared, actions=actions, since=since,
                             run_ids=run_ids, echo=lambda line: print(line, flush=True), sleep=sleep, routes=routes)
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("### Hosted backlog rescue\n\n" + "\n".join(f"- {line}" for line in lines) + "\n\n")
    return 0


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None, *, client: Any = None,
         now: dt.datetime | None = None, sleep: Callable[[float], None] = time.sleep) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--runners", type=Path,
                      help="the .github/runners.json whose hosted_light_jobs scope the pass")
    mode.add_argument("--wake-sweeper", action="store_true",
                      help="wake the existing single concurrency owner without cancelling or rerunning any job")
    mode.add_argument("--backlog", action="store_true",
                      help="one backlog pass: pull request runs stalled on hosted Ubuntu for 30 min or more")
    parser.add_argument("--policy", type=Path, default=None,
                        help="with --backlog: the .github directory whose declared workflows the minute pass owns")
    parser.add_argument("--workflows", type=Path, default=None,
                        help="the .github/workflows directory whose callers of reusable declared workflows are listed too")
    parser.add_argument("--route-workflows", action="append", default=None, metavar="BASE=DIR",
                        help="with --backlog: the workflows directory of pull requests into BASE, read to tell whether "
                             "a job queued on Blacksmith Ubuntu re-runs on vars.LINUX_RUNNER (BACKLOG_LINUX_RUNNER)")
    parser.add_argument("--run-ids", default=None,
                        help="with --backlog: act on exactly these runs (comma-separated ids) under the pass's rules, "
                             "instead of listing the queue")
    parser.add_argument("--recover-since", default=None,
                        help="with --backlog: read every earlier pass's journal back to this UTC time (ISO 8601), "
                             "not just the newest, and re-run what they left")
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
    if args.backlog:
        return backlog_main(args, env, repo, client=client, now=now, sleep=sleep)
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
