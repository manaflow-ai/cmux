#!/usr/bin/env python3
"""Move a run's post-admission job onto an owned runner that is idle now.

pr_runner_pool.py places every macOS job of a run when the run starts. The
job after compile admission (cli-product-tests) only starts once admission
finishes, often ten minutes later. If the owned pool was full at the start, they are committed to
Blacksmith (admission's pool, or pr_retry_runner) and wait in its queue even
when root runners have drained in the meantime.

ci-macos.yml's late-placement job runs this after admission succeeds, for a
same-repository pull request: on attempt 1, and on a re-run that runs compile
admission again (a full re-run, or a re-run of a failed admission). A re-run
of failed jobs after admission keeps the outputs of the attempt before, so
ci-macos.yml takes `runners` only in the attempt that made it (output
`attempt`), and those jobs take their owned labels.
It reads the idle root runners live through the org route App and gives
each job that is not already owned the root label, in owned priority order,
up to that many idle runners. cli-product-tests then runs
test-without-building on the mini against admission's uploaded products, as
it does after an owned admission; it never compiles.

When a runner carries the pool's gui label (pr_runner_pool.gui_label(): one
gui runner per mini), the jobs that hold the
gui token (pr_runner_pool.gui_token_job(): cli-product-tests) take that label instead, one per
idle gui runner, and the other jobs the root label, one per idle root runner: each mini runs one
gui-token job at a time.

Overflow off a full gui pool: each mini has one gui runner, so the gui label
has about ten machines, and the picker charges a run's gui-token jobs to the
std pool's forty-odd. When the picker owned some of this run's gui-token
jobs and the gui runners idle now cannot take them all, this counts the jobs
already queued on the gui label and on RETRY_RUNNER, the Blacksmith pool the
picker named for this run (gui_backlog(): the jobs of in-flight CI runs,
oldest runs first). Minis first: a job an idle gui runner takes now stays.
Every other one goes where it is expected to start sooner, in seconds: on the
gui label behind the backlog on its online runners (GUI_JOB_SECONDS a job), or
on RETRY_RUNNER after its start latency (BLACKSMITH_START_SECONDS) behind its
queue on RETRY_RUNNER's label capacity (RETRY_JOB_SECONDS a job). A tie stays
on the minis. There is no fixed allowance of queue on the gui label: until
2026-09-29 a job stayed while it started within one gui job length
(GUI_QUEUE_ROUNDS), whatever Blacksmith's queue, and over the 24 hours to
10:00Z that day the gui label queued a p50 202 s and p90 1014 s (988 jobs,
base 3 s), its runners 10 to 12 of 12 busy every hour from 20:00Z, while on
2026-09-27 164 of the 193 gui jobs that waited over 300 s were created while
a Blacksmith macOS pool had nothing queued. Blacksmith is not free capacity:
from 07:00 to 10:30Z on 2026-09-28 it ran 22 macOS jobs at most across its
three pools with a median of 100 queued behind them, and the post-admission
jobs moved there after an owned admission waited 18.4 minutes on average
against 5.6 for those that stayed, which is why a move needs the RETRY_RUNNER
backlog to say Blacksmith starts the job sooner. With CI_PR_POOL_QUEUE_ROUNDS at 0 (the kill
switch) no job queues on purpose. With no gui runner idle and either the kill
switch on or no gui runner online, every owned gui job moves without a read.
Otherwise an unreadable backlog moves nothing.

Output `runners` is a JSON object from job key (cli-product) to label. Any failure prints a warning and outputs {} (no change).
"""
from __future__ import annotations

import concurrent.futures
import datetime as dt
import importlib.util
import json
import os
import sys
from pathlib import Path
from typing import Any, Callable, Mapping, Sequence


def _picker():
    path = Path(__file__).with_name("pr_runner_pool.py")
    spec = importlib.util.spec_from_file_location("pr_runner_pool", path)
    module = importlib.util.module_from_spec(spec)
    sys.modules.setdefault("pr_runner_pool", module)
    spec.loader.exec_module(module)
    return module


pool = _picker()

# Measured on 2026-09-27 (build-fleet/data/raw/2026/09/27/gh-jobs.jsonl.gz, successful jobs):
# a gui-token job (then an app-host shard) ran a p50 407 s on the gui label (523 jobs), 295 s on 12vcpu (72), 334 s on
# 6vcpu macOS 26 (66) and 341 s on macOS 15 (38); a Blacksmith macOS job waited a p90 15 to 19 s on
# the macOS 26 pools and 65 s on macOS 15 to start (5,327 jobs, most with nothing queued ahead).
GUI_JOB_SECONDS = 407
RETRY_JOB_SECONDS = {"blacksmith-12vcpu-macos-26": 295, "blacksmith-6vcpu-macos-26": 334,
                     "blacksmith-6vcpu-macos-15": 341}
DEFAULT_RETRY_JOB_SECONDS = 334
BLACKSMITH_START_SECONDS = {"blacksmith-12vcpu-macos-26": 15, "blacksmith-6vcpu-macos-26": 19,
                            "blacksmith-6vcpu-macos-15": 65}
DEFAULT_BLACKSMITH_START_SECONDS = 20
# In-flight CI runs gui_backlog() reads jobs from, oldest first, and the window it reads them in: a run's gui
# jobs queue only once its admission finished (p50 about 9 minutes), so a run younger than BACKLOG_MIN_AGE has none,
# and one older than the window has finished its gui jobs.
BACKLOG_LOOKUPS = 30
BACKLOG_READERS = 8
BACKLOG_WINDOW_MINUTES = 120
BACKLOG_MIN_AGE_MINUTES = 4
E2E_WORKFLOW = "test-e2e.yml"
BACKLOG_WORKFLOWS = (pool.CI_WORKFLOW, E2E_WORKFLOW)


def late_jobs(*, macos: str | None, cli: str | None, full_suite: str | None) -> tuple[str, ...]:
    """The jobs that run after compile admission in this run (pr_runner_pool.run_plan)."""
    plan = pool.run_plan(macos=macos, full_suite=full_suite, claude_wrapper=None, cli=cli,
                         remote_daemon=None)
    return plan.after


def root_for(xcode_app: str | None) -> str:
    """The std root label for admission's Xcode; "" when no owned pool pins it."""
    std = [label for label in pool.owned_pools(xcode_app) if label.startswith("glaeda-std-")]
    return pool.root_label(std[0]) if std else ""


def place(jobs: Sequence[str], *, owned_jobs: str, idle: int, root: str,
          gui_label: str = "", gui_idle: int = 0) -> dict[str, str]:
    """Give the not-yet-owned jobs the root label, highest priority first, one per idle runner.

    With `gui_label`, the gui-token jobs (pool.gui_token_job()) take it instead, one per idle gui runner (`gui_idle`)."""
    if not root:
        return {}
    owned = f" {owned_jobs.strip()} " if owned_jobs.strip() else " "
    waiting = sorted((key for key in jobs if f" {key} " not in owned), key=pool.priority)
    if not gui_label:
        return {key: root for key in waiting[:max(0, idle)]}
    on_gui = [key for key in waiting if pool.gui_token_job(key)][:max(0, gui_idle)]
    on_root = [key for key in waiting if not pool.gui_token_job(key)][:max(0, idle)]
    return {**{key: gui_label for key in on_gui}, **{key: root for key in on_root}}


def gui_backlog(github: Any, labels: Sequence[str], *, exclude_run_id: int | None,
                now: dt.datetime) -> dict[str, int]:
    """Jobs queued on each of `labels` in the CI runs still in flight (one request per run), read
    BACKLOG_READERS runs at a time.

    GitHub lists a run as `queued` while any of its jobs is, even with others
    running, so both `queued` and `in_progress` runs are read. Oldest first,
    at most BACKLOG_LOOKUPS runs created between BACKLOG_WINDOW_MINUTES and
    BACKLOG_MIN_AGE_MINUTES ago. Raises when a read fails.
    """
    since = (now - dt.timedelta(minutes=BACKLOG_WINDOW_MINUTES)).strftime("%Y-%m-%dT%H:%M:%SZ")
    newest = now - dt.timedelta(minutes=BACKLOG_MIN_AGE_MINUTES)
    runs: dict[Any, Mapping[str, Any]] = {}
    for workflow in BACKLOG_WORKFLOWS:
        for status in ("queued", "in_progress"):
            for run in github.runs_since(workflow, since, status=status):
                created = pool.parse_time(str(run.get("created_at") or ""))
                if run.get("id") != exclude_run_id and created is not None and created <= newest:
                    runs[run.get("id")] = {**run, "_backlog_workflow": workflow}
    def queued_in(run: Mapping[str, Any]) -> list[str]:
        gui_pool = pool.pool_label(labels[0]) if labels else ""
        gui_root = pool.root_label(gui_pool) if gui_pool else ""
        jobs = github.get(f"/actions/runs/{run['id']}/jobs?filter=latest&per_page={pool.PAGE_SIZE}").get("jobs") or []
        found: list[str] = []
        for job in jobs:
            if not isinstance(job, Mapping) or job.get("status") != "queued":
                continue
            job_labels = {str(label) for label in job.get("labels") or []}
            matched = [label for label in labels if label in job_labels]
            # E2E build/test jobs request the owned pool/root label, then take
            # the GUI token inside the job. Charge those queued jobs to the
            # GUI backlog even though the token is not in runs-on.
            if not matched and run.get("_backlog_workflow") == E2E_WORKFLOW \
                    and any(pool.persistent(label) for label in job_labels) and labels \
                    and {gui_pool, gui_root}.intersection(job_labels):
                matched = [labels[0]]
            found.extend(matched)
        return found

    # Read BACKLOG_READERS runs at a time: one by one, 30 job lists under load outran the step's minute.
    ordered = sorted(runs.values(), key=lambda run: str(run.get("created_at")))[:BACKLOG_LOOKUPS]
    queued = dict.fromkeys(labels, 0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=BACKLOG_READERS) as readers:
        for found in readers.map(queued_in, ordered):
            for label in found:
                queued[label] += 1
    return queued


def overflow(jobs: Sequence[str], *, owned_jobs: str, gui_idle: int, gui_online: int, backlog: int,
             retry_queued: int | None = None, retry_capacity: int | None = None,
             retry: str = "") -> tuple[str, ...]:
    """The owned gui-token jobs no idle gui runner takes now that are expected to start sooner on the
    retry pool.

    The `backlog` queued before them takes the idle runners first, and the highest priority jobs take
    the idle runners left. Past those, in priority order, each job goes wherever it starts sooner in
    seconds: at queue place q behind the jobs that stayed, about q / gui_online gui jobs
    (GUI_JOB_SECONDS) from now, or on the retry pool after BLACKSMITH_START_SECONDS, behind
    `retry_queued` and the jobs moved before it on its `retry_capacity` machines (RETRY_JOB_SECONDS a
    job), which start at once while nothing is queued there. A tie stays. Without `retry_queued` (the
    kill switch, or no gui runner online) every job past the idle runners moves."""
    owned = f" {owned_jobs.strip()} "
    mine = sorted((key for key in jobs if f" {key} " in owned and pool.gui_token_job(key)), key=pool.priority)
    # GitHub hands the idle runners to the jobs queued before these first.
    keep = max(0, max(0, gui_idle) - max(0, backlog))
    if retry_queued is None:
        return tuple(mine[keep:])
    capacity = max(1, retry_capacity if retry_capacity is not None else pool.BLACKSMITH_CAPACITIES.get(retry, pool.POOL_CAPACITY))
    retry_idle = capacity if retry_queued <= 0 else 0
    start = BLACKSMITH_START_SECONDS.get(retry, DEFAULT_BLACKSMITH_START_SECONDS)
    length = RETRY_JOB_SECONDS.get(retry, DEFAULT_RETRY_JOB_SECONDS)
    moved: list[str] = []
    stayed = 0
    for key in mine[keep:]:
        ahead = max(0, max(0, backlog) - max(0, gui_idle)) + stayed
        gui_wait = (ahead + 1) / gui_online * GUI_JOB_SECONDS if gui_online > 0 else float("inf")
        retry_wait = start + max(0, max(0, retry_queued) + len(moved) + 1 - retry_idle) / capacity * length
        if retry_wait < gui_wait:
            moved.append(key)
        else:
            stayed += 1
    return tuple(moved)


def decide(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None,
           backlog: Callable[[Sequence[str]], Mapping[str, int]] | None = None) -> tuple[dict[str, str], str]:
    jobs = late_jobs(macos=env.get("MACOS"), cli=env.get("CLI"), full_suite=env.get("FULL_SUITE"))
    if not jobs:
        return {}, "no job runs after compile admission"
    root = root_for(env.get("ADMISSION_XCODE_APP"))
    if not root:
        return {}, f"no owned pool runs admission's Xcode ({env.get('ADMISSION_XCODE_APP') or 'unknown'})"
    if runners is None:
        return {}, "owned runners could not be read live"
    # From the runners, not the picker's gui_runner: a run the picker sent to Blacksmith has none,
    # and its gui-token jobs must still never take the root label once the minis have gui runners. Any
    # runner carrying the label counts, online or not (drained minis' runners go offline), so the
    # jobs never fall back to the root label; CI_OWNED_POOL_SLOTS no longer decides it.
    gui_label = pool.gui_label(pool.pool_label(root))
    if not any(gui_label in pool.runner_labels(runner) for runner in runners):
        gui_label = ""
    free = pool.live_owned_free(runners, [root, *([gui_label] if gui_label else [])])
    idle, gui_idle = free[root], free.get(gui_label, 0)
    owned_jobs = env.get("OWNED_JOBS", "")
    seen = f"{idle} idle `{root}` runner(s)" + (f" and {gui_idle} idle `{gui_label}`" if gui_label else "")
    # Owned gui-token jobs the idle gui runners cannot take now: past the allowed queue, Blacksmith.
    moved_off: tuple[str, ...] = ()
    retry = (env.get("RETRY_RUNNER") or "").strip()
    rounds = pool.parse_queue_rounds(env.get("POOL_QUEUE_ROUNDS"))
    rounds = 1 if rounds is None else rounds
    owned_gui = [key for key in jobs if f" {key} " in f" {owned_jobs.strip()} " and pool.gui_token_job(key)]
    if gui_label and retry and not pool.persistent(retry) and backlog is not None \
            and len(owned_gui) > gui_idle:
        online = pool.live_online(runners, [gui_label])[gui_label]
        try:
            # With no rounds (the kill switch) nothing queues on purpose: every job past the idle runners moves,
            # whatever the retry pool's queue. With nothing idle and no rounds or no gui runner online, every
            # job moves without a read.
            if gui_idle <= 0 and (rounds <= 0 or online <= 0):
                labels = []
            else:
                labels = [gui_label, retry] if rounds > 0 else [gui_label]
            counts = backlog(labels) if labels else {}
        except Exception as error:  # noqa: BLE001 - an unread backlog moves nothing
            print(f"::warning title=late placement::could not count the gui backlog ({error})")
            counts = None
        if counts is not None:
            queued, retry_queued = counts.get(gui_label, 0), counts.get(retry) if labels[1:] else None
            moved_off = overflow(jobs, owned_jobs=owned_jobs, gui_idle=gui_idle, gui_online=online,
                                 backlog=queued, retry_queued=retry_queued,
                                 retry_capacity=pool.BLACKSMITH_CAPACITIES.get(retry, pool.POOL_CAPACITY), retry=retry)
            seen += f", {queued} gui job(s) queued ahead on {online} online"
            if retry_queued is not None:
                seen += f" and {retry_queued} on `{retry}`"
    # Moved off the gui label, a job frees its place there for the not-yet-owned ones only while idle.
    placed = place(jobs, owned_jobs=owned_jobs, idle=idle, root=root, gui_label=gui_label,
                   gui_idle=max(0, gui_idle - (len(owned_gui) - len(moved_off))))
    placed.update({key: retry for key in moved_off})
    if not placed:
        return {}, f"{seen}; nothing to move"
    return placed, (f"{seen} now; moved {', '.join(f'{key} to `{label}`' for key, label in placed.items())} "
                    f"(admission ran on `{env.get('ADMISSION_RUNNER') or 'unknown'}`)")


def main(env: Mapping[str, str] = os.environ) -> int:
    runners = None
    backlog = None
    token, repo = env.get("ROUTE_TOKEN", ""), env.get("GITHUB_REPOSITORY", "")
    if token and repo:
        github = pool.GitHub(token, repo)
        run_id = env.get("GITHUB_RUN_ID", "")

        def backlog(labels: Sequence[str]) -> dict[str, int]:
            return gui_backlog(github, labels, exclude_run_id=int(run_id) if run_id.isdigit() else None,
                               now=dt.datetime.now(dt.timezone.utc))
        try:
            runners = github.runners()
        except Exception as error:  # noqa: BLE001 - fail open: keep the run-start placement
            print(f"::warning title=late placement::could not list runners ({error})")
    placed, why = decide(env, runners, backlog)
    print(f"late placement: {why}")
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"runners={json.dumps(placed, sort_keys=True)}\nattempt={env.get('GITHUB_RUN_ATTEMPT', '')}\n")
            # The rescue watch's markers are for jobs moved onto owned runners; a move to Blacksmith needs none.
            onto_owned = any(pool.persistent(label) for label in placed.values())
            handle.write(f"onto_owned={str(onto_owned).lower()}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"### Late placement\n\n{why}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
