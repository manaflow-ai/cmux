#!/usr/bin/env python3
"""Spill an owned-first cmux-tui tree job off a busy owned label after a bounded wait.

On the nightly path (feat-cmux-next and nightly-next pushes, tree-request dispatches) attempt 1 of the jobs a NEXT
nightly waits for queues on our own GCP Linux labels, and attempt 2+ takes the Blacksmith pools (feat-cmux-next
cmux-tui-artifacts.yml; tests/test_ci_owned_first_not_census_frozen.py there). The route is never decided by a
one-shot runner census: on 2026-11-19 run 44464326281's "cmux_next_ daemon tests" was put on
blacksmith-16vcpu-ubuntu-2404 because no GCP member was idle at the instant tree-preflight looked, and it sat queued
there from 05:23Z while the GCP runners freed up, holding the tree publish the nightly and Leo's tip build waited for
(Leo: "why would it move OFF of gcp and into blacksmith if it was already linux 16!?").

GitHub never moves a queued job, so the bound needs someone to act: this sweep. For each unfinished attempt-1
nightly-path run of cmux-tui-artifacts.yml with a job queued on an owned label for SPILL_MINUTES or more, it cancels
the run and re-runs its failed and cancelled jobs ("Re-run failed jobs" includes cancelled ones), which is attempt 2:
those jobs take their spill route, the jobs that already passed keep their results. It does not cancel a run with a
job in progress (a publish of immutable objects must never stop mid-upload; cmux-tui-artifacts.yml's concurrency
comment): such a run waits for the next sweep. The jobs are read again right before the cancel, but the cancel
endpoint takes no "only if idle" condition, so a job a runner picks up in the second between that read and the
cancel is still cancelled: the rule is enforced as far as the API allows, not absolutely. At most MAX_SPILLS runs
move per sweep, newest first, and attempt 2+ is never touched (one spill per run).

Once a run is cancelled, the re-run is retried until a settle deadline (a monotonic clock, counting request time
too). A run whose attempt already moved past the one the sweep cancelled is never re-POSTed: a re-run GitHub
accepted but whose answer was lost, or one cmux-tui-artifacts-retry.yml started first, is not run a third time. A
run the sweep cancelled but could not re-run is written to PENDING_FILE and its id to the step output `pending`;
the workflow uploads it as an artifact named owned-first-spill-pending-<ids>, the sweep fails, and every later
sweep reads the pending ids of its failed predecessors from those artifact names and re-runs them (recover()).

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
SWEEP_WORKFLOW = "ci-owned-first-spill.yml"
# Our own Linux labels an owned-first job queues on (the persistent GCP build lane, the nightly-only runner, the
# ephemeral GCP fleet). A job queued on one of these past the bound is the one this sweep moves.
OWNED_LABELS = frozenset({"cmux-gcp-lane-build-x64", "cmux-gcp-nightly-x64", "cmux-fleet-linux-x64"})
NIGHTLY_BRANCHES = frozenset({"feat-cmux-next", "nightly-next"})
SPILL_MINUTES = 20
MAX_SPILLS = 3
CANCEL_SETTLE_SECONDS = 300
POLL_SECONDS = 10
REQUEST_TIMEOUT = 30
PER_PAGE = 100
MAX_PAGES = 10
# How far back a sweep looks for its failed predecessors' pending re-runs, and how old a pending run may be
# before the sweep stops retrying it and names the manual command instead.
RECOVER_HOURS = 6
RECOVER_MAX_AGE_HOURS = 24
PENDING_ARTIFACT = "owned-first-spill-pending-"
API = "https://api.github.com"


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def nightly_path(run: Mapping[str, Any]) -> bool:
    """Attempt 1 of a run whose owned-first jobs queue on an owned label (the routes the tree workflow gives them).

    A dispatch on any ref counts: the tree workflow sends attempt 1 of every workflow_dispatch to
    cmux-gcp-nightly-x64 (the bot-head and tree-request dispatches are not all on a nightly branch)."""
    if run.get("run_attempt") != 1:
        return False
    event = run.get("event")
    return event == "workflow_dispatch" or (event == "push" and run.get("head_branch") in NIGHTLY_BRANCHES)


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

    def call(self, method: str, path: str, timeout: float = REQUEST_TIMEOUT) -> Any:
        request = urllib.request.Request(f"{API}/repos/{self.repo}/{path}", method=method, headers={
            "Authorization": f"Bearer {self.token}", "Accept": "application/vnd.github+json",
            "X-GitHub-Api-Version": "2022-11-28"}, data=b"" if method == "POST" else None)
        with urllib.request.urlopen(request, timeout=max(1.0, timeout)) as response:
            body = response.read()
        return json.loads(body) if body else None

    def paged(self, path: str, key: str) -> list[dict]:
        """Every item of a paged list (up to MAX_PAGES pages), read before any filter is applied."""
        items: list[dict] = []
        separator = "&" if "?" in path else "?"
        for page in range(1, MAX_PAGES + 1):
            body = self.call("GET", f"{path}{separator}per_page={PER_PAGE}&page={page}") or {}
            batch = body.get(key) or []
            items.extend(batch)
            if len(batch) < PER_PAGE or len(items) >= int(body.get("total_count") or 0):
                break
        return items

    def runs(self, status: str) -> list[dict]:
        return self.paged(f"actions/workflows/{WORKFLOW}/runs?status={status}", "workflow_runs")

    def jobs(self, run_id: int) -> list[dict]:
        return self.paged(f"actions/runs/{run_id}/jobs?filter=latest", "jobs")


class SpillFailed(RuntimeError):
    """A run this sweep cancelled that it could not re-run."""

    def __init__(self, run_id: int, message: str):
        super().__init__(message)
        self.run_id = run_id


def rerun_until(github: GitHub, run_id: int, baseline: int, deadline: float,
                sleep: Callable[[float], None], clock: Callable[[], float]) -> str:
    """Re-run the failed and cancelled jobs of a cancelled run once it settles, by the monotonic DEADLINE.

    BASELINE is the attempt the sweep cancelled: once GitHub reports a later attempt, the re-run is accepted (ours,
    whose answer may have been lost, or cmux-tui-artifacts-retry.yml's), and no further POST is sent."""
    last = "cancel not settled"
    while True:
        remaining = deadline - clock()
        if remaining <= 0:
            raise SpillFailed(run_id, f"run {run_id} was cancelled but not re-run by the settle deadline "
                                      f"({last}): gh run rerun {run_id} --failed")
        try:
            current = github.call("GET", f"actions/runs/{run_id}", timeout=min(REQUEST_TIMEOUT, remaining)) or {}
            attempt = int(current.get("run_attempt") or baseline)
            if attempt > baseline:
                return f"re-run as attempt {attempt} (spill route)"
            if current.get("status") == "completed":
                remaining = deadline - clock()
                if remaining > 0:
                    github.call("POST", f"actions/runs/{run_id}/rerun-failed-jobs",
                                timeout=min(REQUEST_TIMEOUT, remaining))
                    return f"cancelled and re-run as attempt {baseline + 1} (spill route)"
            else:
                last = "cancel not settled"
        except (urllib.error.URLError, OSError, ValueError) as error:
            last = str(error)
        remaining = deadline - clock()
        if remaining > 0:
            sleep(min(POLL_SECONDS, remaining))


def spill(github: GitHub, run: Mapping[str, Any], now: dt.datetime, spill_minutes: float = SPILL_MINUTES,
          sleep: Callable[[float], None] = time.sleep, settle_seconds: float = CANCEL_SETTLE_SECONDS,
          clock: Callable[[], float] = time.monotonic) -> str:
    """Cancel the run, wait for it to finish, re-run its failed and cancelled jobs (attempt 2).

    The jobs are read again right before the cancel: a job that started since the sweep's first read (the stuck job
    itself, or a publish) keeps the run whole. Once the cancel is sent, the re-run is retried until the settle
    deadline; a run that still could not be re-run raises SpillFailed, which fails the sweep and leaves the run
    pending for the next one (recover())."""
    run_id = run["id"]
    verdict = decide(run, github.jobs(run_id), now, spill_minutes)
    if verdict is None or verdict[0] != "spill":
        return "not cancelled: the run changed since the first read" + (f" ({verdict[1]})" if verdict else "")
    baseline = int(run.get("run_attempt") or 1)
    deadline = clock() + settle_seconds
    github.call("POST", f"actions/runs/{run_id}/cancel")
    return rerun_until(github, run_id, baseline, deadline, sleep, clock)


def pending_from(name: str) -> list[int]:
    """The run ids an owned-first-spill-pending-<id>-<id> artifact name carries."""
    if not name.startswith(PENDING_ARTIFACT):
        return []
    return [int(part) for part in name[len(PENDING_ARTIFACT):].split("-") if part.isdigit()]


def pending_runs(github: GitHub, now: dt.datetime) -> list[int]:
    """Run ids earlier failed sweeps cancelled and could not re-run (their artifact names), oldest sweep first."""
    since = (now - dt.timedelta(hours=RECOVER_HOURS)).strftime("%Y-%m-%dT%H:%M:%SZ")
    sweeps = github.paged(f"actions/workflows/{SWEEP_WORKFLOW}/runs?status=failure&created=%3E%3D{since}",
                          "workflow_runs")
    ids: list[int] = []
    for sweep in sorted(sweeps, key=lambda run: run.get("created_at") or ""):
        for artifact in github.paged(f"actions/runs/{sweep['id']}/artifacts", "artifacts"):
            for run_id in pending_from(str(artifact.get("name") or "")):
                if run_id not in ids:
                    ids.append(run_id)
    return ids


def recover(github: GitHub, run_ids: Iterable[int], now: dt.datetime, dry_run: bool) -> tuple[list[str], list[int]]:
    """Re-run each pending run still at attempt 1 and completed; return report lines and the ids still pending."""
    lines: list[str] = []
    still: list[int] = []
    for run_id in run_ids:
        try:
            run = github.call("GET", f"actions/runs/{run_id}") or {}
        except (urllib.error.URLError, OSError, ValueError) as error:
            lines.append(f"- pending {run_id}: reading it failed ({error}); kept for the next sweep")
            still.append(run_id)
            continue
        url = run.get("html_url") or run_id
        attempt = int(run.get("run_attempt") or 1)
        created = parse_time(run.get("created_at"))
        if attempt > 1:
            lines.append(f"- recovered {url}: already re-run (attempt {attempt})")
        elif created is not None and now - created > dt.timedelta(hours=RECOVER_MAX_AGE_HOURS):
            lines.append(f"- gave up on {url}: cancelled {RECOVER_MAX_AGE_HOURS} h+ ago and never re-run; "
                         f"gh run rerun {run_id} --failed")
        elif run.get("status") != "completed":
            lines.append(f"- pending {url}: the cancel has not settled; kept for the next sweep")
            still.append(run_id)
        elif dry_run:
            lines.append(f"- would re-run pending {url}")
        else:
            try:
                github.call("POST", f"actions/runs/{run_id}/rerun-failed-jobs")
                lines.append(f"- recovered {url}: re-run as attempt 2 (spill route)")
            except (urllib.error.URLError, OSError, ValueError) as error:
                lines.append(f"- pending {url}: the re-run failed ({error}); kept for the next sweep")
                still.append(run_id)
    return lines, still


def main(env: Mapping[str, str] = os.environ, now: dt.datetime | None = None,
         github: GitHub | None = None) -> int:
    now = now or dt.datetime.now(dt.timezone.utc)
    token, repo = env.get("GH_TOKEN", ""), env.get("GITHUB_REPOSITORY", "manaflow-ai/cmux")
    if github is None and not token:
        print("::error::GH_TOKEN is unset")
        return 1
    dry_run = env.get("DRY_RUN", "").lower() == "true"
    spill_minutes = float(env.get("SPILL_MINUTES") or SPILL_MINUTES)
    max_spills = int(env.get("MAX_SPILLS") or MAX_SPILLS)
    github = github or GitHub(token, repo)
    lines = [f"Owned-first spill sweep ({'dry run' if dry_run else 'live'}), bound {spill_minutes:g} min"]
    failed: list[str] = []
    pending: list[int] = []
    try:
        recovered, pending = recover(github, pending_runs(github, now), now, dry_run)
        lines.extend(recovered)
    except (urllib.error.URLError, OSError, ValueError) as error:
        lines.append(f"- could not read earlier sweeps' pending re-runs ({error})")
    try:
        runs = [run for status in ("queued", "in_progress") for run in github.runs(status) if nightly_path(run)]
    except (urllib.error.URLError, OSError, ValueError) as error:
        lines.append(f"Skipped: listing runs failed ({error}); nothing was cancelled")
        runs = []
    runs.sort(key=lambda run: run.get("created_at") or "", reverse=True)
    moved = 0
    for run in runs:
        try:
            jobs = github.jobs(run["id"])
        except (urllib.error.URLError, OSError, ValueError) as error:
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
            except SpillFailed as error:
                failed.append(str(error))
                pending.append(error.run_id)
                lines.append(f"- FAILED {url}: {error}")
            except (urllib.error.URLError, OSError, ValueError) as error:
                # The cancel itself failed: nothing was cancelled, so the next sweep finds the run again.
                failed.append(f"run {run['id']}: the cancel failed ({error})")
                lines.append(f"- FAILED {url}: the cancel failed ({error})")
        moved += 1
    if len(lines) == 1:
        lines.append("Nothing queued past the bound on an owned label.")
    for run_id in pending:
        if not any(str(run_id) in message for message in failed):
            failed.append(f"run {run_id} is still pending a re-run: gh run rerun {run_id} --failed")
    write_pending(pending, env)
    report(lines, env)
    for message in failed:
        print(f"::error title=Owned-first spill::{message}")
    return 1 if failed else 0


def write_pending(pending: list[int], env: Mapping[str, str]) -> None:
    """Hand the runs still waiting for a re-run to the workflow (artifact name) so the next sweep retries them."""
    ids = sorted(set(pending))
    path = env.get("PENDING_FILE")
    if path and ids:
        with open(path, "w", encoding="utf-8") as handle:
            json.dump({"pending": ids}, handle)
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"pending={'-'.join(str(run_id) for run_id in ids)}\n")


def report(lines: list[str], env: Mapping[str, str]) -> None:
    text = "\n".join(lines)
    print(text)
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(text + "\n")


if __name__ == "__main__":
    sys.exit(main())
