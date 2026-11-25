#!/usr/bin/env python3
"""Cancel queued Actions runs nobody will read: runs of a commit its branch has moved past.

Leo, 2026-11-19: "why are there even 20,000? What are the 20,000 [jobs] doing?" At 20:12Z 28,318 cmux jobs
were queued, 12,848 of them for commits a newer push on the same branch had already replaced. The janitors
that should shed them run on Blacksmith labels and queue behind what they would cancel, and
scripts/ci/queue_janitor.py reads 300 runs per status per sweep, so it never sees a backlog of thousands.

One sweep (.github/workflows/ci-shed-superseded-runs.yml, every 10 minutes on an owned runner):
  1. one `git ls-remote --heads` for every branch tip,
  2. every queued run, listing created= windows bisected until each holds at most 1,000 results
     (GitHub's cap on a filtered run listing),
  3. verdict() per run, then cancels (at most SHED_MAX_CANCELS, default 1500), SHED_CANCEL_SPACING_SECONDS
     apart (default 0.2) against secondary rate limits.

A run is cancelled only when every rule holds (verdict()):
  status queued, or in_progress with nothing running (unstarted(): every job of the latest attempt finished or
  queued with no runner and no step, read again right before the cancel; at most SHED_MAX_JOB_READS, default 300,
  such runs read per sweep), so a cancel only ever stops jobs that never started; run_attempt 1, head in this repository, workflow
  name and path not nightly/dev/promote/release/testflight/app store/deploy/publish/sign, and then:
  - a lane branch (not master/release*/nightly*/gh-pages), event push, pull_request or workflow_run:
      superseded:  the branch tip is another commit,
      branch-gone: the branch no longer exists;
  - main or feat-cmux-next, event push only, not a workflow that publishes per commit (BASE_KEEP_PATHS):
      superseded-base: the branch tip is another commit. The tip's own run is never touched, so the newest head is
      always tested. What a skipped commit loses: its own run of that workflow. Workflows that diff a push against
      github.event.before (rust-workspaces, gallery-health) then never scope that commit's change on base; it was
      tested on its pull request's merge ref before landing, and a red it causes surfaces on a later head that
      touches the same files or on the nightly. A red is found by bisecting from the next tested head (as
      web_coalesce.py does) and fixed forward. Readers of base verdicts already skip a cancelled push run that ran
      no job (base_red_excuse.web_base_runs, next_batch's coalesced()).
A run at its branch's tip is kept whatever its pull request's state: a host sweep on 2026-11-19 found no queued
pull_request run at a tip without an open pull request, so that check would only cost reads.
Every cancel is one row in the step summary.

The token's primary rate limit ("API rate limit exceeded for installation", shared with every workflow in the
repository) is not an error of the sweep: a listing read that meets it stops the listing, the sweep sheds what it
already listed, and it exits 0 with a warning naming the reset (2026-11-21: 34 of 100 sweeps died on that 403
mid-listing and shed nothing). Job reads stop while fewer than SHED_KEEP_CALLS_PCT (default 25) percent of the
limit remain, so the sweep spends its quota on cancels, not on reads, and leaves the rest to the repository.

usage: shed_superseded_runs.py [--dry-run] [--max N] [--hours H] [--spacing S]
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable

API = "https://api.github.com"
LIST_CAP = 1000  # GitHub answers a filtered run listing with at most this many results.
MIN_WINDOW = dt.timedelta(seconds=2)
MAX_DEPTH = 16

PROTECTED_BRANCH = re.compile(r"^(main|master|feat-cmux-next|release.*|nightly.*|gh-pages)$")
PROTECTED_WORKFLOW = re.compile(
    r"nightly|\bdev\b|dev[- ]build|promot|release|testflight|app ?store|deploy|publish|sign", re.I)
# Base branches whose queued push runs a newer push sheds too (Leo, 2026-11-19: "if we can cut ci by 50% and we
# need an extra fix forward on 5%, that's ok"). At 11:52Z on 2026-11-20, 2,921 queued Linux jobs sat on
# feat-cmux-next push runs a newer push had replaced. Only push runs: a base issue_comment, workflow_run, schedule
# or workflow_dispatch run answers one event, not one commit, so a newer push does not replace it.
BASE_BRANCHES = frozenset({"main", "feat-cmux-next"})
# Base push workflows that publish per commit and so keep every push's run, besides PROTECTED_WORKFLOW's names:
# cmux-tui artifacts uploads each feat-cmux-next commit's daemon and acpmux as immutable objects (hot-apply and the
# nightly train read them by commit).
BASE_KEEP_PATHS = frozenset({".github/workflows/cmux-tui-artifacts.yml"})
# Lane events a newer push to the same branch replaces. workflow_run runs carry the triggering run's branch and
# head, so a follow-up of a replaced head (attribution, PR media) reads a commit nobody looks at any more.
LANE_EVENTS = ("push", "pull_request", "workflow_run")
# Pull request runs of a workflow whose PR Mac jobs moved elsewhere, created before the move: the run, even at its
# branch tip, asks for a Mac route no current run asks for. cmux#53487 (merged 2026-11-25T00:59:59Z) moved the PR
# fast tier and Swift gates to pr-pipeline.yml's mac job; at 01:20Z 191 jobs still waited on
# glaeda-side-std-xcode-26.6 for those old runs (median 39 min, oldest 143 min), 184 of 187 queued cmux-next runs
# predating the move, ahead of every newer job on that label. Shedding one stops only jobs that never started; the
# PR's next head (a push or land's base update) runs the new route. Leo, 2026-11-25: "do not catch-22 yourselves".
RETIRED_PR_ROUTES = {".github/workflows/cmux-next.yml": "2026-11-25T00:59:59Z"}
SHED_VERDICTS = ("superseded", "superseded-base", "branch-gone", "retired-route")


def unstarted(jobs: list[dict[str, Any]]) -> bool:
    """True when nothing of a run is running or claimed: every job of its latest attempt finished or is queued with
    no runner and no step. Cancelling such a run stops only jobs that never started; finished jobs keep results."""
    waiting = 0
    for job in jobs:
        status = job.get("status")
        if status == "completed":
            continue
        if status != "queued" or job.get("runner_id") or job.get("runner_name") or job.get("steps"):
            return False
        waiting += 1
    return waiting > 0


def verdict(run: dict[str, Any], repo: str, tips: dict[str, str],
            jobs: dict[int, list[dict[str, Any]]] | None = None) -> str:
    """Why RUN is kept ("keep:...") or cancelled (one of SHED_VERDICTS). Pure: no I/O.

    tips maps branch name -> tip sha from `git ls-remote --heads`. jobs maps run id -> its latest attempt's jobs,
    read only for in_progress runs that would otherwise be shed: such a run is shed only when unstarted()."""
    status = run.get("status")
    if status == "in_progress":
        listed = (jobs or {}).get(run.get("id"))
        if listed is None:
            return "keep:status-in_progress"
        if not unstarted(listed):
            return "keep:running"
    elif status != "queued":
        return f"keep:status-{status}"
    if (run.get("run_attempt") or 1) > 1:
        return "keep:attempt"
    event = run.get("event")
    branch = run.get("head_branch") or ""
    base = branch in BASE_BRANCHES
    if event not in (("push",) if base else LANE_EVENTS):
        return f"keep:event-{event}"
    if (run.get("head_repository") or {}).get("full_name") != repo:
        return "keep:fork"
    if not branch or (PROTECTED_BRANCH.match(branch) and not base):
        return "keep:protected-branch"
    if PROTECTED_WORKFLOW.search(run.get("name") or "") or PROTECTED_WORKFLOW.search(run.get("path") or ""):
        return "keep:protected-workflow"
    if base and run.get("path") in BASE_KEEP_PATHS:
        return "keep:publishes-per-commit"
    tip = tips.get(branch)
    if tip is None:
        return "keep:base-unread" if base else "branch-gone"
    if tip != run.get("head_sha"):
        return "superseded-base" if base else "superseded"
    retired = RETIRED_PR_ROUTES.get(run.get("path") or "")
    if not base and event == "pull_request" and retired and (run.get("created_at") or "9") < retired:
        return "retired-route"
    return f"keep:current-{event}"


def needs_jobs(runs: list[dict[str, Any]], repo: str, tips: dict[str, str], cap: int) -> list[dict[str, Any]]:
    """The in_progress runs, oldest first and at most cap, that verdict() would shed if they were still queued:
    the only runs whose jobs this sweep reads."""
    out = []
    for run in sorted({r["id"]: r for r in runs}.values(), key=lambda r: (r.get("created_at") or "", r["id"])):
        if run.get("status") == "in_progress" and verdict({**run, "status": "queued"}, repo, tips) in SHED_VERDICTS:
            out.append(run)
    return out[:max(0, cap)]


def plan(runs: list[dict[str, Any]], repo: str, tips: dict[str, str], max_cancels: int,
         jobs: dict[int, list[dict[str, Any]]] | None = None
         ) -> tuple[list[tuple[dict[str, Any], str]], dict[str, int]]:
    """Cancels for this sweep, oldest first and at most max_cancels, plus a count per verdict."""
    unique = {run["id"]: run for run in runs}
    counts: dict[str, int] = {}
    picks: list[tuple[dict[str, Any], str]] = []
    for run in sorted(unique.values(), key=lambda r: (r.get("created_at") or "", r["id"])):
        why = verdict(run, repo, tips, jobs)
        counts[why] = counts.get(why, 0) + 1
        if why in SHED_VERDICTS:
            picks.append((run, why))
    return picks[:max(0, max_cancels)], counts


def windows(since: dt.datetime, until: dt.datetime,
            total: Callable[[dt.datetime, dt.datetime], int]) -> list[tuple[dt.datetime, dt.datetime]]:
    """Split since..until (inclusive, whole seconds) until each window's total(...) is at most LIST_CAP."""
    out: list[tuple[dt.datetime, dt.datetime]] = []
    stack = [(since, until, 0)]
    while stack:
        lo, hi, depth = stack.pop()
        if total(lo, hi) <= LIST_CAP or hi - lo < MIN_WINDOW or depth >= MAX_DEPTH:
            out.append((lo, hi))
            continue
        mid = lo + (hi - lo) / 2
        mid = mid.replace(microsecond=0)
        stack.append((mid + dt.timedelta(seconds=1), hi, depth + 1))
        stack.append((lo, mid, depth + 1))
    return out


def parse_ls_remote(text: str) -> dict[str, str]:
    tips: dict[str, str] = {}
    for line in text.splitlines():
        sha, _, ref = line.partition("\t")
        if ref.startswith("refs/heads/"):
            tips[ref.removeprefix("refs/heads/")] = sha.strip()
    return tips


class RateLimited(RuntimeError):
    """The token's primary rate limit: every further call fails until reset (unix seconds, 0 when unknown)."""

    def __init__(self, message: str, reset: int) -> None:
        super().__init__(message)
        self.reset = reset


def is_primary_limit(code: int, body: str, remaining: str | None) -> bool:
    text = body.lower()
    if code not in (403, 429) or "secondary" in text:
        return False
    return "rate limit" in text or remaining == "0"


class GitHub:
    def __init__(self, repo: str, token: str) -> None:
        self.repo = repo
        self.token = token
        self.calls = 0
        self.limit: int | None = None
        self.remaining: int | None = None
        self.limited: RateLimited | None = None
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-shed-superseded-runs",
        }
        self._totals: dict[str, dict[str, Any]] = {}

    def request(self, method: str, path: str) -> Any:
        for attempt in range(4):
            self.calls += 1
            req = urllib.request.Request(API + path, headers=self.headers, method=method)
            try:
                with urllib.request.urlopen(req, timeout=30) as response:
                    self._note_quota(response.headers)
                    raw = response.read()
                    return json.loads(raw) if raw else {}
            except urllib.error.HTTPError as error:
                body = error.read().decode(errors="replace")[:300]
                self._note_quota(error.headers)
                if is_primary_limit(error.code, body, error.headers.get("x-ratelimit-remaining")):
                    self.limited = RateLimited(f"{method} {path.split('?')[0]} rate limited ({error.code}): {body}",
                                               int(error.headers.get("x-ratelimit-reset") or 0))
                    raise self.limited from error
                secondary = error.code in (403, 429) and "secondary" in body.lower()
                if secondary or error.code in (502, 503, 504):
                    time.sleep(min(60, int(error.headers.get("Retry-After") or 0) or 10 * (attempt + 1)))
                    continue
                raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.code}): {body}") from error
            except urllib.error.URLError as error:
                if attempt < 3:
                    time.sleep(5)
                    continue
                raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.reason})") from error
        raise RuntimeError(f"{method} {path.split('?')[0]} kept failing")

    def _note_quota(self, headers: Any) -> None:
        if headers is None:
            return
        try:
            if headers.get("x-ratelimit-limit"):
                self.limit = int(headers["x-ratelimit-limit"])
            if headers.get("x-ratelimit-remaining"):
                self.remaining = int(headers["x-ratelimit-remaining"])
        except ValueError:
            pass

    def can_spend_on_reads(self, keep_pct: float) -> bool:
        """False once the limit was met or fewer than keep_pct percent of it remain (unknown counts as enough)."""
        if self.limited is not None:
            return False
        if self.limit is None or self.remaining is None:
            return True
        return self.remaining > self.limit * keep_pct / 100

    def _page(self, lo: dt.datetime, hi: dt.datetime, page: int, status: str = "queued") -> dict[str, Any]:
        rng = f"{lo:%Y-%m-%dT%H:%M:%SZ}..{hi:%Y-%m-%dT%H:%M:%SZ}"
        query = urllib.parse.urlencode({"status": status, "per_page": 100, "page": page, "created": rng})
        return self.request("GET", f"/repos/{self.repo}/actions/runs?{query}")

    def queued_total(self, lo: dt.datetime, hi: dt.datetime, status: str = "queued") -> int:
        payload = self._page(lo, hi, 1, status)
        self._totals[f"{status}|{lo}|{hi}"] = payload  # page 1 is reused by queued_runs: bisection costs no read
        return int(payload.get("total_count") or 0)

    def queued_runs(self, since: dt.datetime, until: dt.datetime,
                    status: str = "queued") -> tuple[list[dict[str, Any]], int]:
        runs: list[dict[str, Any]] = []
        failed = 0
        if self.limited is not None:
            return runs, 1
        try:
            spans = windows(since, until, lambda a, b: self.queued_total(a, b, status))
        except RateLimited as error:
            # Bisection met the limit: keep the windows it already read whole, drop the rest.
            print(f"::warning::{error}", file=sys.stderr)
            spans = [tuple(map(dt.datetime.fromisoformat, key.split("|")[1:]))  # type: ignore[misc]
                     for key, page in self._totals.items()
                     if key.startswith(f"{status}|") and int(page.get("total_count") or 0) <= LIST_CAP]
            failed += 1
        for lo, hi in spans:
            try:
                first = self._totals.pop(f"{status}|{lo}|{hi}", None) or self._page(lo, hi, 1, status)
            except RuntimeError as error:
                print(f"::warning::{error}", file=sys.stderr)
                failed += 1
                if isinstance(error, RateLimited):
                    break
                continue
            batch = first.get("workflow_runs") or []
            runs += batch
            pages = min(LIST_CAP // 100, (int(first.get("total_count") or 0) + 99) // 100)
            for page in range(2, pages + 1):
                try:
                    batch = self._page(lo, hi, page, status).get("workflow_runs") or []
                except RuntimeError as error:
                    print(f"::warning::{error}", file=sys.stderr)
                    failed += 1
                    break
                runs += batch
                if len(batch) < 100:
                    break
            if self.limited is not None:
                break
        return runs, failed

    def cancel(self, run_id: int) -> None:
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/cancel")

    def run_jobs(self, run_id: int) -> list[dict[str, Any]] | None:
        """The latest attempt's jobs, or None when unread or past one page (then the run is kept)."""
        try:
            payload = self.request("GET", f"/repos/{self.repo}/actions/runs/{run_id}/jobs?filter=latest&per_page=100")
        except RuntimeError as error:
            print(f"::warning::{error}", file=sys.stderr)
            return None
        jobs = payload.get("jobs") or []
        return jobs if int(payload.get("total_count") or 0) == len(jobs) else None

    def branch_tips(self) -> dict[str, str]:
        auth = base64.b64encode(f"x-access-token:{self.token}".encode()).decode()
        env = {**os.environ, "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "http.extraheader",
               "GIT_CONFIG_VALUE_0": f"AUTHORIZATION: basic {auth}", "GIT_TERMINAL_PROMPT": "0"}
        last = ""
        for _ in range(3):
            proc = subprocess.run(["git", "ls-remote", "--heads", f"https://github.com/{self.repo}.git"],
                                  capture_output=True, text=True, env=env, timeout=120)
            tips = parse_ls_remote(proc.stdout) if proc.returncode == 0 else {}
            if tips:
                return tips
            last = proc.stderr.strip()[:200]
            time.sleep(10)
        raise SystemExit(f"git ls-remote failed: {last}")


def summary_line(text: str) -> None:
    print(text)
    path = os.environ.get("GITHUB_STEP_SUMMARY")
    if path:
        with Path(path).open("a", encoding="utf-8") as handle:
            handle.write(text + "\n")


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--dry-run", action="store_true", default=os.environ.get("DRY_RUN") == "true")
    ap.add_argument("--max", type=int, default=int(os.environ.get("SHED_MAX_CANCELS") or 1500))
    ap.add_argument("--hours", type=float, default=float(os.environ.get("SHED_LOOKBACK_HOURS") or 72))
    ap.add_argument("--spacing", type=float, default=float(os.environ.get("SHED_CANCEL_SPACING_SECONDS") or 0.2))
    ap.add_argument("--max-job-reads", type=int, default=int(os.environ.get("SHED_MAX_JOB_READS") or 300))
    ap.add_argument("--keep-calls-pct", type=float, default=float(os.environ.get("SHED_KEEP_CALLS_PCT") or 25))
    args = ap.parse_args(argv)
    repo = os.environ["GH_REPO"]
    gh = GitHub(repo, os.environ["GH_TOKEN"])

    # `now` is taken before the tips are read and bounds the listing, so every listed run was created before
    # the ls-remote: a branch missing from it was deleted, and a tip that differs is a newer push.
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)
    tips = gh.branch_tips()
    since = now - dt.timedelta(hours=args.hours)
    runs, failed_pages = gh.queued_runs(since, now)
    # A started run whose remaining jobs all wait for a runner (a light gate job finished, nothing running) holds
    # most of a superseded commit's queued jobs: its jobs are read, and it is shed only when nothing of it runs.
    active, failed_active = gh.queued_runs(since, now, "in_progress")
    jobs: dict[int, list[dict[str, Any]]] = {}
    for run in needs_jobs(active, repo, tips, args.max_job_reads):
        if not gh.can_spend_on_reads(args.keep_calls_pct):
            break
        listed = gh.run_jobs(run["id"])
        if listed is not None:
            jobs[run["id"]] = listed
    runs += active
    failed_pages += failed_active
    picks, counts = plan(runs, repo, tips, args.max, jobs)
    eligible = sum(n for why, n in counts.items() if why in SHED_VERDICTS)

    summary_line(f"## Shed queued runs on superseded heads{' (dry run)' if args.dry_run else ''}\n")
    summary_line(f"{len({r['id'] for r in runs})} queued or in-progress runs read ({failed_pages} listing pages "
                 f"failed, {len(jobs)} job lists read), {len(tips)} branches; {eligible} to shed, cap {args.max}.\n")
    summary_line("| verdict | runs |\n|---|---|")
    for why, n in sorted(counts.items(), key=lambda kv: -kv[1]):
        summary_line(f"| {why} | {n} |")
    summary_line("\n| run | workflow | event | branch | sha | created | why | result |\n|---|---|---|---|---|---|---|---|")
    done = errors = 0
    for run, why in picks:
        result = "dry run"
        if gh.limited is not None and not args.dry_run:
            break
        if not args.dry_run and run.get("status") == "in_progress":
            # Read again right before the cancel: a runner may have taken a job since the first read.
            fresh = gh.run_jobs(run["id"])
            if fresh is None or not unstarted(fresh):
                summary_line(f"| {run['id']} | | | | | | {why} | kept: a job started since the first read |")
                continue
        if not args.dry_run:
            try:
                gh.cancel(run["id"])
                done += 1
                result = "cancelled"
            except RuntimeError as error:
                errors += 1
                result = f"error: {str(error)[:80]}"
                if "rate limit" in str(error).lower() and "secondary" not in str(error).lower():
                    summary_line(f"| {run['id']} | | | | | | {why} | {result} (stopping) |")
                    break
            time.sleep(args.spacing)
        summary_line(f"| [{run['id']}]({run.get('html_url', '')}) | {(run.get('name') or '').replace('|', '/')} "
                     f"| {run.get('event')} | {run.get('head_branch')} | {(run.get('head_sha') or '')[:10]} "
                     f"| {run.get('created_at')} | {why} | {result} |")
    summary_line(f"\ncancelled {done}, errors {errors}, candidates {eligible}, API calls {gh.calls}, "
                 f"quota left {gh.remaining}/{gh.limit}")
    if gh.limited is not None:
        reset = (dt.datetime.fromtimestamp(gh.limited.reset, dt.timezone.utc).strftime("%H:%M:%SZ")
                 if gh.limited.reset else "unknown")
        summary_line(f"\nThe token's rate limit was met (resets {reset}); the next sweep goes on from there.")
        print(f"::warning::rate limited; resets {reset}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())
