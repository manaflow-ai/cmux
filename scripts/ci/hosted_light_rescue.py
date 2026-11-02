#!/usr/bin/env python3
"""Fail a declared hosted light job over to its re-run route when GitHub-hosted Ubuntu never assigns it a runner.

The jobs in .github/runners.json `hosted_light_jobs` (resolvers, routers, report steps) take GitHub-hosted
`ubuntu-24.04` on attempt 1 and RUNNER_POOLS.linux (or their declared fallback) on a re-run:
`github.run_attempt == 1 && 'ubuntu-24.04' || fromJSON(vars.RUNNER_POOLS).linux` (cmux#31785, cmux#31878). The
fallback only exists on a re-run, and nothing re-ran one: ci-hosted-queue-rescue.yml watches only CI, CLA and CI
fast guards, and only once GitHub itself cancels a whole run after about 15 minutes; the queue janitor's lost-
assignment pass waits 30 minutes and needs a newer job on the same labels taken. The rulebook's stall-aware
failover is about 3 minutes.

Each pass of the scheduled overflow watch (main's ci-cloud-overflow-probe.yml, which checks this file out from
feat-cmux-next at a pinned commit) runs this:

- lists the in-flight (`queued`, `in_progress`) pull request runs of every workflow file that declares a hosted
  light job, created STALL_SECONDS to WINDOW ago (one listing page per workflow and status);
- reads the jobs of at most MAX_RUNS of them (plus one re-read per rescue, so at most MAX_RUNS + MAX_RESCUES) (attempt 1 only, at the pull request's current head), oldest first;
- finds a stalled job: queued, no runner id or name, every label a GitHub-hosted `ubuntu-*` label (in this repo only
  declared hosted light jobs may ask for one, tests/test_ci_self_hosted_guard.sh), created STALL_SECONDS or more ago;
- when every unfinished job of the run is such a stalled job (so the cancel stops nothing that is running), cancels
  the run, waits (within SETTLE_BUDGET_S for the whole pass) for the cancel to settle, and re-runs its failed jobs.
  The re-run is attempt 2, so each re-run job takes its fallback route; jobs that already passed keep their result.

Bounds: only pull request runs (never push, schedule, dispatch, nightly, DEV, promote or release runs), only attempt
1 (so a job is failed over at most once), only runs at their pull request's current head, at most MAX_RESCUES
re-runs a pass, and a run with any other unfinished job is left alone and reported. A cancel that does not settle
in time is reported and left; it is never re-run blind on a later pass, since a later pass cannot tell this cancel
from a person's or a concurrency group's.
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
SETTLE_BUDGET_S = 90.0
SETTLE_INTERVAL_S = 5.0
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
    """Workflow files with a hosted light job: `file.yml#job` (feat) or `file.yml:job` (main) keys."""
    table = runners.get("hosted_light_jobs")
    if not isinstance(table, Mapping):
        return []
    files = {re.split(r"[#:]", str(key), maxsplit=1)[0] for key in table if not str(key).startswith("$")}
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


class GitHub:
    def __init__(self, token: str, repo: str, write_token: str | None = None) -> None:
        self.repo = repo
        self.token = token
        self.write_token = write_token or token

    def request(self, method: str, path: str) -> Any:
        token = self.token if method == "GET" else self.write_token
        request = urllib.request.Request(
            f"https://api.github.com/repos/{self.repo}{path}", method=method,
            data=b"" if method != "GET" else None,
            headers={"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
                     "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-hosted-light-rescue"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                body = response.read()
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"{method} {path}: HTTP {error.code}") from error
        return json.loads(body) if body.strip() else {}

    def runs(self, workflow: str, status: str, start: dt.datetime, end: dt.datetime) -> list[dict[str, Any]]:
        # Filtered to pull_request runs server-side, so push and dispatch runs never fill the one page.
        query = urllib.parse.urlencode({"status": status, "event": "pull_request", "per_page": 100,
                                        "created": f"{iso(start)}..{iso(end)}"})
        return list(self.request("GET", f"/actions/workflows/{workflow}/runs?{query}").get("workflow_runs") or [])

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


def at_head(run: Mapping[str, Any]) -> bool:
    """The run is at its pull request's current head (a stale head's result is read by nobody)."""
    prs = run.get("pull_requests") or []
    head = run.get("head_sha")
    return bool(prs) and bool(head) and any(
        isinstance(pr, Mapping) and isinstance(pr.get("head"), Mapping) and pr["head"].get("sha") == head
        for pr in prs)


def pull_at_head(client: Any, run: Mapping[str, Any]) -> bool:
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
            if not re.search(r"HTTP (403|404)$", str(error)):
                raise
            refused = True
    return refused and at_head(run)


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


def sweep(client: Any, workflows: Sequence[str], *, now: dt.datetime, dry_run: bool,
          sleep: Callable[[float], None] = time.sleep, clock: Callable[[], float] = time.monotonic) -> list[str]:
    lines: list[str] = []
    start, end = now - WINDOW, now - dt.timedelta(seconds=STALL_SECONDS)
    listed: dict[int, Mapping[str, Any]] = {}
    for workflow in workflows:
        for status in IN_FLIGHT:
            try:
                page = client.runs(workflow, status, start, end)
            except Exception as error:  # noqa: BLE001 - an unread listing only narrows this pass
                lines.append(f"could not list {status} runs of {workflow} ({error})")
                continue
            for run in page:
                if isinstance(run, Mapping) and isinstance(run.get("id"), int) and candidate(run):
                    listed[run["id"]] = {**run, "_workflow": workflow}
    runs = sorted(listed.values(), key=lambda run: (str(run.get("created_at")), run["id"]))
    if len(runs) > MAX_RUNS:
        lines.append(f"{len(runs)} candidate runs; read the oldest {MAX_RUNS}")
        runs = runs[:MAX_RUNS]
    rescued = 0
    deadline = clock() + SETTLE_BUDGET_S
    for run in runs:
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
        if rescued >= MAX_RESCUES:
            lines.append(f"{where}: {names} stalled; over this pass's {MAX_RESCUES} re-runs, left to the next")
            continue
        if not dry_run and clock() >= deadline:
            # No settle time left: a cancel now could not be followed by its re-run.
            lines.append(f"{where}: {names} stalled; this pass's settle time is spent, left to the next")
            continue
        if dry_run:
            lines.append(f"{where}: {names} stalled; would cancel and re-run its failed jobs (dry run)")
            rescued += 1
            continue
        # Right before the cancel: the run is still attempt 1 and in flight at its pull request's head (read again,
        # so a concurrent re-run is never cancelled), the pull request is still open at this head, and nothing has
        # started since the jobs were read (a runner may have taken the stalled job meanwhile).
        try:
            fresh = {**client.run(run["id"])}
            live_head = candidate(fresh) and fresh.get("head_sha") == run.get("head_sha")
            if live_head:
                live_head = pull_at_head(client, fresh)
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
        settled = False
        while True:
            try:
                state = client.run(run["id"])
            except Exception:  # noqa: BLE001 - read again until the budget runs out
                state = {}
            if state.get("status") == "completed":
                settled = state.get("run_attempt") == 1
                break
            if clock() >= deadline:
                break
            sleep(SETTLE_INTERVAL_S)
        if not settled:
            lines.append(f"{where}: {names} stalled; cancelled, but the cancel did not settle in this pass's "
                         f"{SETTLE_BUDGET_S:.0f} s, so it was not re-run")
            continue
        try:
            client.rerun_failed(run["id"])
        except Exception as error:  # noqa: BLE001
            lines.append(f"{where}: cancelled, re-run refused ({error})")
            continue
        rescued += 1
        lines.append(f"{where}: {names} stalled; cancelled and re-ran its failed jobs on their fallback route")
    lines.append(f"{len(listed)} candidate runs, {min(len(runs), MAX_RUNS)} read, {rescued} failed over")
    return lines


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None, *, client: Any = None,
         now: dt.datetime | None = None, sleep: Callable[[float], None] = time.sleep) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--runners", type=Path, required=True,
                        help="the .github/runners.json whose hosted_light_jobs scope the pass")
    parser.add_argument("--workflows", type=Path, default=None,
                        help="the .github/workflows directory whose callers of reusable declared workflows are listed too")
    parser.add_argument("--dry-run", action="store_true",
                        default=(env.get("DRY_RUN", "").strip().lower() in {"1", "true", "yes"}))
    args = parser.parse_args(argv)
    now = now or dt.datetime.now(UTC)
    try:
        workflows = with_callers(declared_workflows(json.loads(args.runners.read_text(encoding="utf-8"))),
                                 args.workflows)
    except (OSError, ValueError) as error:
        print(f"::warning title=Hosted light rescue::could not read {args.runners} ({error}); nothing to do")
        return 0
    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
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
