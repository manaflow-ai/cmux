#!/usr/bin/env python3
"""Move a run's post-admission jobs onto owned root runners that are idle now.

pr_runner_pool.py places every macOS job of a run when the run starts. The
jobs after compile admission (the app-host shards, tests-build-and-lag and
cli-product-tests) only start once admission finishes, often ten minutes
later. If the owned pool was full at the start, they are committed to
Blacksmith (admission's pool, or pr_retry_runner) and wait in its queue even
when root runners have drained in the meantime.

ci-macos.yml's late-placement job runs this after admission succeeds, on
attempt 1 of a same-repository pull request.
It reads the idle root runners live through the org route App and gives
each job that is not already owned the root label, in owned priority order,
up to that many idle runners. The shards and friends then run
test-without-building on the mini against admission's uploaded products, as
they do after an owned admission; they never compile.

When OWNED_SLOTS (vars.CI_OWNED_POOL_SLOTS) gives the pool's gui label a count
(pr_runner_pool.gui_label(): one gui runner per mini), the jobs that hold the
gui token (pr_runner_pool.gui_token_job(): the shards, tests-build-and-lag,
cli-product-tests) take that label instead, one per idle gui runner, and the other jobs the root
label, one per idle root runner: each mini runs one GUI job at a time.

Overflow off a full gui pool: each mini has one gui runner, so the gui label
has about ten machines, and the picker charges a run's gui-token jobs to the
std pool's forty-odd. On 2026-09-27 from 22:00 to 02:00Z the gui runners were
busy 80% of the time and their queue reached a p90 of 15 to 37 minutes
(max 42), against 6 s over the week before. A shard on a mini only runs
test-without-building on admission's uploaded product, as it does on
Blacksmith (about 350 s against 240 to 400 s), so a job should start
wherever its queue is shorter. When the picker owned some of this run's
gui-token jobs and the gui runners idle now cannot take them all, this counts
the jobs already queued on the gui label and on RETRY_RUNNER, the Blacksmith
pool the picker named for this run (gui_backlog(): the jobs of in-flight CI
runs, oldest runs first). The run keeps on the gui label the jobs that start
within GUI_QUEUE_ROUNDS gui job lengths (the idle runners plus that many
rounds of the online ones, less the backlog). Past that, a job moves to
RETRY_RUNNER only if it would start there sooner, counting that pool's
queue in rounds of its POOL_CAPACITIES machines. Blacksmith is not free
capacity: from 07:00 to 10:30Z on 2026-09-28 it ran 22 macOS jobs at most
across its three pools with a median of 100 queued behind them, and the
post-admission jobs this moved there after an owned admission waited 18.4
minutes on average against 5.6 for those that stayed on the minis. With
CI_PR_POOL_QUEUE_ROUNDS at 0 (the kill switch) no job queues on purpose. With
no gui runner idle and either the kill switch on or no gui runner online,
every owned gui job moves without a read. Otherwise an unreadable backlog
moves nothing.

Output `runners` is a JSON object from job key (shard-N, lag, cli-product)
to label. Any failure prints a warning and outputs {} (no change).
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

# Rounds of gui jobs an owned gui-token job may queue behind (at most the picker's CI_PR_POOL_QUEUE_ROUNDS).
# One: a gui job waits for about one shard on a busy mini, longer only while Blacksmith's queue is longer still.
GUI_QUEUE_ROUNDS = 1
# In-flight CI runs gui_backlog() reads jobs from, oldest first, and the window it reads them in: a run's gui
# jobs queue only once its admission finished (p50 about 9 minutes), so a run younger than BACKLOG_MIN_AGE has none,
# and one older than the window has finished its shards.
BACKLOG_LOOKUPS = 30
BACKLOG_READERS = 8
BACKLOG_WINDOW_MINUTES = 120
BACKLOG_MIN_AGE_MINUTES = 4


def late_jobs(*, macos: str | None, cli: str | None, full_suite: str | None, unit_suite: str | None,
              unit_in_admission: str | None, unit_selectors: str | None) -> tuple[str, ...]:
    """The jobs that run after compile admission in this run (pr_runner_pool.run_plan)."""
    plan = pool.run_plan(macos=macos, full_suite=full_suite, unit_suite=unit_suite,
                         unit_in_admission=unit_in_admission, claude_wrapper=None, cli=cli,
                         remote_daemon=None, unit_selectors=unit_selectors)
    return plan.after


def root_for(xcode_app: str | None) -> str:
    """The std root label for admission's Xcode; "" when no owned pool pins it."""
    std = [label for label in pool.owned_pools(xcode_app) if label.startswith("glaeda-std-")]
    return pool.root_label(std[0]) if std else ""


def place(jobs: Sequence[str], *, owned_jobs: str, idle: int, root: str, gui: bool = True,
          gui_label: str = "", gui_idle: int = 0) -> dict[str, str]:
    """Give the not-yet-owned jobs the root label, highest priority first, one per idle runner.

    With `gui_label`, the gui-token jobs (pool.gui_token_job()) take it instead, one per idle gui runner (`gui_idle`)."""
    if not root:
        return {}
    owned = f" {owned_jobs.strip()} " if owned_jobs.strip() else " "
    waiting = sorted((key for key in jobs if f" {key} " not in owned and (gui or not pool.gui_job(key))),
                     key=pool.priority)
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
    for status in ("queued", "in_progress"):
        for run in github.runs_since(pool.CI_WORKFLOW, since, status=status):
            created = pool.parse_time(str(run.get("created_at") or ""))
            if run.get("id") != exclude_run_id and created is not None and created <= newest:
                runs[run.get("id")] = run
    def queued_in(run: Mapping[str, Any]) -> list[str]:
        jobs = github.get(f"/actions/runs/{run['id']}/jobs?filter=latest&per_page={pool.PAGE_SIZE}").get("jobs") or []
        return [label for job in jobs if isinstance(job, Mapping) and job.get("status") == "queued"
                for label in labels if label in (job.get("labels") or [])]

    # Read BACKLOG_READERS runs at a time: one by one, 30 job lists under load outran the step's minute.
    ordered = sorted(runs.values(), key=lambda run: str(run.get("created_at")))[:BACKLOG_LOOKUPS]
    queued = dict.fromkeys(labels, 0)
    with concurrent.futures.ThreadPoolExecutor(max_workers=BACKLOG_READERS) as readers:
        for found in readers.map(queued_in, ordered):
            for label in found:
                queued[label] += 1
    return queued


def overflow(jobs: Sequence[str], *, owned_jobs: str, gui_idle: int, gui_online: int, backlog: int,
             rounds: int, retry_queued: int | None = None, retry_capacity: int = pool.POOL_CAPACITY) -> tuple[str, ...]:
    """The owned gui-token jobs that would wait more than `rounds` gui job lengths and would start sooner on
    the retry pool.

    The `backlog` queued before them takes the idle runners first; after those, a job at queue place q
    waits about q / gui_online rounds, so gui_idle + rounds x gui_online places are allowed in all, to the
    highest priority jobs. Past those, in priority order, each job goes wherever it starts sooner: behind
    the jobs that stayed on the gui label, or behind `retry_queued` and the jobs moved before it on the
    retry pool's `retry_capacity` machines, which start at once while nothing is queued there. Without
    `retry_queued` (the kill switch, or no gui runner online) every job past the allowed places moves."""
    owned = f" {owned_jobs.strip()} "
    mine = sorted((key for key in jobs if f" {key} " in owned and pool.gui_token_job(key)), key=pool.priority)
    # GitHub hands the idle runners to the jobs queued before these first.
    keep = max(0, max(0, gui_idle) + rounds * max(0, gui_online) - max(0, backlog))
    if retry_queued is None:
        return tuple(mine[keep:])
    capacity = max(1, retry_capacity)
    retry_idle = capacity if retry_queued <= 0 else 0
    moved: list[str] = []
    stayed = 0
    for key in mine[keep:]:
        ahead = max(0, backlog) + keep + stayed - max(0, gui_idle)
        gui_rounds = (ahead + 1) / gui_online if gui_online > 0 else float("inf")
        retry_rounds = max(0, max(0, retry_queued) + len(moved) + 1 - retry_idle) / capacity
        if retry_rounds < gui_rounds:
            moved.append(key)
        else:
            stayed += 1
    return tuple(moved)


def decide(env: Mapping[str, str], runners: Sequence[Mapping[str, Any]] | None,
           backlog: Callable[[Sequence[str]], Mapping[str, int]] | None = None) -> tuple[dict[str, str], str]:
    jobs = late_jobs(macos=env.get("MACOS"), cli=env.get("CLI"), full_suite=env.get("FULL_SUITE"),
                     unit_suite=env.get("UNIT_SUITE"), unit_in_admission=env.get("UNIT_IN_ADMISSION"),
                     unit_selectors=env.get("UNIT_SELECTORS"))
    if not jobs:
        return {}, "no job runs after compile admission"
    root = root_for(env.get("ADMISSION_XCODE_APP"))
    if not root:
        return {}, f"no owned pool runs admission's Xcode ({env.get('ADMISSION_XCODE_APP') or 'unknown'})"
    if runners is None:
        return {}, "owned runners could not be read live"
    # From the slots, not the picker's gui_runner: a run the picker sent to Blacksmith has none,
    # and its GUI jobs must still never take the root label once the minis have gui runners.
    gui_label = pool.gui_label(pool.pool_label(root))
    if pool.slots(env.get("OWNED_SLOTS"), env.get("ADMISSION_XCODE_APP")).get(gui_label, 0) <= 0:
        gui_label = ""
    free = pool.live_owned_free(runners, [root, *([gui_label] if gui_label else [])])
    idle, gui_idle = free[root], free.get(gui_label, 0)
    owned_jobs = env.get("OWNED_JOBS", "")
    gui_on = env.get("POOL_OWNED_GUI", "").strip() != "0"
    seen = f"{idle} idle `{root}` runner(s)" + (f" and {gui_idle} idle `{gui_label}`" if gui_label else "")
    # Owned gui-token jobs the idle gui runners cannot take now: past the allowed queue, Blacksmith.
    moved_off: tuple[str, ...] = ()
    retry = (env.get("RETRY_RUNNER") or "").strip()
    rounds = pool.parse_queue_rounds(env.get("POOL_QUEUE_ROUNDS"))
    rounds = min(GUI_QUEUE_ROUNDS, 1 if rounds is None else rounds)
    owned_gui = [key for key in jobs if f" {key} " in f" {owned_jobs.strip()} " and pool.gui_token_job(key)]
    if gui_label and gui_on and retry and not pool.persistent(retry) and backlog is not None \
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
                                 backlog=queued, rounds=rounds, retry_queued=retry_queued,
                                 retry_capacity=pool.POOL_CAPACITIES.get(retry, pool.POOL_CAPACITY))
            seen += f", {queued} gui job(s) queued ahead on {online} online"
            if retry_queued is not None:
                seen += f" and {retry_queued} on `{retry}`"
    # Moved off the gui label, a job frees its place there for the not-yet-owned ones only while idle.
    placed = place(jobs, owned_jobs=owned_jobs, idle=idle, root=root, gui=gui_on, gui_label=gui_label,
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
            handle.write(f"runners={json.dumps(placed, sort_keys=True)}\n")
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
