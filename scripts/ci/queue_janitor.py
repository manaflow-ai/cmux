#!/usr/bin/env python3
"""Cancel macOS runner demand that no longer buys anything.

Pull request macOS jobs share a few small runner pools (Blacksmith and
GitHub-hosted macOS 15 and 26). When one is saturated, every queued job on it
that nobody will read delays one that somebody will. This janitor looks at
in-flight Actions runs and cancels runs that are waste, in this priority
order. Stale pull request runs (b), lost runner assignments (e) and
unclaimed legs (f) are cancelled on every sweep; the other categories only when the number of macOS
jobs queued on a pool they hold exceeds a threshold:

  a. push-triggered experiment workflows on ``exp/*`` branches;
  b. pull request runs whose PR is closed or merged, or whose head SHA is no
     longer the PR head (superseded);
  c. full-suite CI runs whose PR no longer carries the ``full-ci`` label, once
     a newer CI run for that PR is already waiting to replace them and the old
     run's compile admission is not mid-flight (ci.yml deliberately lets that
     compile finish so the queued run can reuse its product).
  d. CI runs whose required ``ci-status`` is already decided against them:
     ``macOS compile admission`` or an ``app-host unit tests`` shard has
     concluded ``failure``, so the ``macos``
     reusable-workflow call cannot report ``success`` or ``skipped`` and no
     later job can take that back, while sibling macOS jobs still hold the
     pool. Unlike (a)-(c) the run is current and its remaining output is still
     readable, so this category is ordered last and never touches a run whose
     diff changes what the failing shard does.
  e. push and pull request runs holding a lost runner assignment
     (find_lost()): a job GitHub shows `queued` with no runner (runner_id
     null or 0, no runner_name) more than LOST_QUEUED_SECONDS (30 minutes)
     after it could first run, while at least one job created later on the
     identical label set has been taken by a runner (skipped_by_pool()). That
     evidence comes from GitHub alone, since the sweep's hosted runner cannot
     reach the fleet: the in-flight jobs already listed, plus, only when a
     suspect lacks it, the jobs of at most two recently completed runs of its
     own workflow for up to three workflows (evidence_queries()). Without
     it the job is just waiting in a backed-up pool and is left alone. While
     any other job of the run is unfinished (running, held, or queued without
     being lost itself), it may be the gate the job waits behind, so the run
     is left alone at any head (_gated()). A lost job holds nothing but never
     runs, so this category is not gated on a backed-up pool. A run whose
     head is stale (a push with no open pull request at its head, or a pull
     request run whose PR is closed, merged or superseded) is cancelled. A
     run at the current head of an open pull request is cancelled, and a
     later sweep re-runs its failed jobs (rerun-failed-jobs) when the run has
     completed as cancelled and the PR head still equals its head_sha
     (plan_lost_reruns()). It is re-run once: the pending re-run names the
     attempt it cancelled and is dropped when the run is past that attempt,
     and an attempt a bot started at that head (the janitor's own re-run, or
     owned_pool_rescue.py's) is left to the rescue and the orphan pass
     (bot_rerun()). A run that already failed, or one a newer run of its
     workflow at its head took over (a `labeled` run queued behind it), is
     cancelled but never re-run, since re-running it would replay its event
     over the newer run (newer_run_at_head()). A re-run of a pull request's
     ci.yml run starts ci-ui-tests.yml for the new attempt, as the rescue's
     does. The pending re-runs ride in the `macos-pool-load` snapshot this
     sweep already uploads, under LOST_RERUNS_KEY, and the next sweep reads
     them from the newest trusted copy (previous_lost_reruns()); without that
     state nothing at an open pull request's head is cancelled. A push run
     whose branch head (read this sweep, branch_head_lookups()) is still its
     head is current too, like one at an open pull request's head.
  f. push, pull request and workflow_dispatch runs holding an unclaimed leg
     (find_unclaimed()): a job on an owned label (owned_pool_rescue.job_pool())
     still queued with no runner, longer after it could first run than
     max(UNCLAIMED_QUEUED_SECONDS, 45 minutes; the pool's p90 wait over the
     jobs a runner took in this sweep's inventory, from when each could first
     run, pool_wait_p90(), once a pool has UNCLAIMED_MIN_SAMPLES of them,
     published in the snapshot under WAIT_P90_KEY), with no evidence needed.
     Run 39652497071's cmux-tui macOS leg (a dispatch on a live branch, on
     glaeda-side-std-xcode-26.6) sat unclaimed 18:25Z to 00:37Z until
     GitHub's queue timeout. It is acted on only at a live head: the head of
     an open pull request, or a push or dispatch whose branch head, read with
     one request (CANDIDATE_HEAD_LOOKUPS a sweep, and PENDING_HEAD_LOOKUPS
     more for the settled cancels waiting on a re-run), is still the run's.
     The run is cancelled and its failed jobs re-run once by the same carried
     re-run as category e, so the leg takes the route a re-run gives it:
     owned_pool_rescue.bot_rerun_leaves_owned() must say it leaves the owned
     label (a side lane's attempt 2 takes its Blacksmith macOS default), or
     the run is left to owned_pool_rescue.py's watch. A run category e holds
     is never counted here, so the two never cancel it twice, and the same
     exceptions hold: a bot's attempt, a run that already failed, a newer run
     at its head (never a second workflow_dispatch: each dispatch is its own
     request), no re-run state, `no-janitor`, and an unfinished sibling.
     A cascade job of a same-repository cmux-next pull request run queued on a
     Blacksmith macOS label (blacksmith_leg()) counts too, past
     BLACKSMITH_LEG_SECONDS (25 minutes, the cascade's own stall wait), while
     owned pools are on: nothing else moves it, and the janitor's re-run, made
     only with an App's token (in category e too), sends it to the owned side
     label the rescue watches.

cmux-next runs follow feat-cmux-next's workflow copy, not main's inert
registration, so they are listed like any macOS workflow's
(follows_another_copy()): the pool snapshot counts their Blacksmith queue for
next_macos_cascade.py, and every category above may act on them.

Draft pull requests are deliberately not a category: a draft can be an active
integration branch other work depends on, and ci.yml has no ready_for_review
trigger to replace a cancelled ci-status.

A pool is the set of macOS labels a job asked for. Outside (b), (e) and (f),
a run that only waits on a pool that is not backed up is never cancelled: its
output may still be read, and cancelling it frees nothing anyone is waiting
for. A stale pull request run's output is never read, so it goes whatever the
queue, unless someone re-ran it or labelled the PR no-janitor; those wait for a
backed-up pool like the other categories. A lost assignment (e) goes whatever
the queue, and so does an unclaimed leg (f); a `no-janitor` label (or a label
page left unread) leaves either alone, as it does an orphan. Outside (b), (e)
and (f), candidates are skipped once every pool's projected queue is back under
the threshold. Every category shares
the per-sweep cancel cap, and runs holding a backed-up pool are spent first.
Main and feat-cmux-next pushes, merge groups, scheduled and dispatched runs on
main, release/tag runs, nightly, and TestFlight/App Store workflows are never
candidates, whatever their state.

owned_pool_rescue.py also cancels and re-runs runs on owned pools, inside its
own watch of each run. The two never re-run the same attempt twice: each
re-checks the run's attempt right before re-running (the rescue in its
cancel-wait loop, the janitor in plan_lost_reruns()), and GitHub refuses a
re-run of a run that is not completed. The rescue usually moves a CI job
stuck on an owned pool first (its budget is about 16.5 minutes at the default
queue rounds, 46.5 at most); when (e) gets there first, the rescue's watch
ends with the cancelled run, and its sweeper watches the janitor's re-run
like any attempt 2. Where the rescue deliberately waits for a sibling still
running, (e) waits too, at any head. The rescue's own
re-runs are attempts a bot started, which (e) leaves alone at an open pull
request's head, so the rescue's attempt ladder (Blacksmith from attempt 3) is
never preempted or extended by the janitor.

Everything that decides is a pure function over already-fetched JSON; the
GitHub client at the bottom only fetches and cancels.

Every sweep can also write what it saw per pool (``--pool-load``): queued and
running macOS jobs, the oldest queued job's age, and the queued jobs that
belong to release or nightly runs. ci-queue-janitor.yml uploads it as the
``macos-pool-load`` artifact, and pr_runner_pool.py reads the newest one to
pick a pull request run's pool (and, through it, e2e_runner_pool.py an E2E
run's) without listing every in-flight run's jobs itself.

An owned Mac pool (``glaeda-<class>-xcode-<version>``) is one more pool
here: stale pull request runs (b) on it are cancelled whatever its queue,
which frees minis, and the other categories only while it is backed up. With
CI_PR_POOL_OWNED on, the snapshot also carries each owned pool's
``committed`` machines: the owned machines each run holding it declared at
its peak (the jobs it placed there, not the whole run) in its
``macos-pool-persistent-<run>-<attempt>-<jobs>-<pool>`` marker, read with one
artifact listing per run that may hold one.

Orphaned runs are a separate pass (find_orphans): a job the runner scheduler
lost holds nothing on any pool, so that pass ignores the queue threshold,
has its own cap, and may end main schedules, nightly and TestFlight runs,
which the categories above never touch. It acts later than (e)
(CI_JANITOR_ORPHAN_MINUTES, 120 by default) and never re-runs; a run (e)
cancels this sweep is excluded from it.
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import http.client
import io
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib
from collections.abc import Iterable, Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pr_runner_pool import MAX_RUN_JOBS  # noqa: E402
from pr_runner_pool import persistent as owned_pool  # noqa: E402
from pr_runner_pool import CAPABILITY_LABELS, pool_label, root_label, side_label  # noqa: E402
from pr_runner_pool import GitHub as PoolClient  # noqa: E402
from pr_runner_pool import ARTIFACT_NAME as SNAPSHOT_ARTIFACT  # noqa: E402
from pr_runner_pool import SNAPSHOT_BRANCH, SNAPSHOT_FILE, trusted_snapshot_artifact  # noqa: E402
import owned_pool_rescue as rescue  # noqa: E402
import owned_warm_state  # noqa: E402
import ui_tests_dispatch  # noqa: E402
import starved_labels  # noqa: E402


API = "https://api.github.com"
DEFAULT_THRESHOLD = 6
DEFAULT_MAX_CANCELS = 10
MAX_RUN_PAGES = 3
MAX_JOB_PAGES = 3
GRAPHQL_BATCH = 25
# A read that meets a 5xx or a dropped connection is made again after each of these delays (seconds),
# then fails. At 08:08Z on 2026-10-26 one 502 on a run's job listing ended the sweep before it wrote
# the macOS pool snapshot; the snapshot went stale, the cascade then sent no job to Blacksmith, and a
# feat-cmux-next push's Release compile waited on a busy owned label (run 40291067104).
RETRY_DELAYS = (2.0, 6.0)
RETRY_STATUSES = frozenset({500, 502, 503, 504})
# Snapshot key: the in-flight runs whose job listing failed this sweep (read_run_jobs()).
UNREAD_RUNS_KEY = "unread_runs"

# Statuses a run can hold runner demand in. `pending` is a run parked behind a
# concurrency group, which is how a label-triggered CI rerun waits.
IN_FLIGHT_RUN_STATUSES = ("queued", "in_progress", "pending")
QUEUED_JOB_STATUSES = frozenset({"queued", "waiting", "pending", "requested"})
RUNNING_JOB_STATUSES = frozenset({"in_progress"})

# A queued run this old is a ghost the Actions backend never scheduled, not
# demand. Skip fetching its jobs every sweep.
GHOST_QUEUED_RUN_AGE = dt.timedelta(hours=24)

# Orphans (see find_orphans): a job still `queued` with no runner this long
# after it was created, on a pool that has since served a newer job. The
# default is several times the worst real pool wait measured on 2026-09-23 (a
# 26-minute median on the most backed-up macOS 15 pool, a 45-minute outlier).
DEFAULT_ORPHAN_MINUTES = 120
MIN_ORPHAN_MINUTES = 30
# A ghost still queued this long has been offered to cancel and force-cancel
# many times over: the rotation below reaches every ghost within a few hours.
# What is left is on GitHub's side (the 2026-09-13 set answers 409 to both),
# so it is reported once, as a count, and no longer costs calls every sweep.
GHOST_GIVE_UP_AGE = dt.timedelta(hours=72)
# Orphans burn no runner time, so relieving them is never urgent: a small cap
# of their own keeps them from spending the backlog cap and bounds the calls
# a sweep spends on runs GitHub refuses to cancel.
DEFAULT_MAX_ORPHAN_CANCELS = 5
MAX_ORPHAN_CANCELS_LIMIT = 10
# How long to let a cancel settle before checking whether it took.
ORPHAN_RECHECK_SECONDS = 20
# An orphan is never cancelled from a release pipeline or the merge queue: a
# human should look at a release that stopped halfway, and the merge queue
# already times out its own checks.
ORPHAN_PROTECTED_EVENTS = frozenset({"release", "merge_group"})
ORPHAN_PROTECTED_WORKFLOW = re.compile(r"release|publish|notar", re.IGNORECASE)

EXPERIMENT_BRANCH_PREFIXES = ("exp/",)
CI_WORKFLOW_PATH = ".github/workflows/ci.yml"
FULL_SUITE_LABEL = "full-ci"
COMPILE_ONLY_POLICY = "compile-only"
COMPILE_ADMISSION_JOB = re.compile(r"(^|/ )macOS compile admission$")

CATEGORY_ORDER = ("experiment", "stale-pr", "label-dropped", "doomed", "lost", "unclaimed")

# Category e (lost runner assignments, find_lost()). A job queued with no
# runner this long after it could first run, while a newer job on exactly its
# labels started, was skipped by its pool.
LOST_QUEUED_SECONDS = 1800
# Only these events have a head to judge the run by (lost_pr_state()); a lost
# job in any other run is left to the orphan pass.
LOST_EVENTS = frozenset({"push", "pull_request"})
# Evidence the in-flight inventory lacks is looked for in a few completed runs
# of the suspect's own workflow: at most this many workflows per sweep, one
# listing of LOST_EVIDENCE_LISTING runs each, and the jobs of at most
# LOST_EVIDENCE_RUNS_PER_WORKFLOW of them.
LOST_EVIDENCE_WORKFLOWS = 3
LOST_EVIDENCE_LISTING = 20
# How far back the starved-label alert's completed-run listing reaches (starved_result()).
STARVED_EVIDENCE_LOOKBACK = dt.timedelta(hours=6)
LOST_EVIDENCE_RUNS_PER_WORKFLOW = 2
# The snapshot key that carries a cancelled run to the sweep that re-runs it.
LOST_RERUNS_KEY = "lost_reruns"
# Older snapshots read when the newest has no LOST_RERUNS_KEY (its sweep
# failed before rewriting it).
LOST_PREVIOUS_SNAPSHOTS = 3
# A pending re-run older than this is dropped: the cancel never settled, or the
# lookups kept failing, and the pull request has had hours to move on.
LOST_RERUN_TTL = dt.timedelta(hours=6)
# Pending re-runs read (one run request each) and re-runs posted per sweep.
LOST_PENDING_MAX = 25
LOST_RERUN_MAX = 10
# Unclaimed legs (find_unclaimed()): a leg on an owned label still queued with
# no runner this long after it could first run, or the pool's p90 wait when
# that is longer (unclaimed_bound()), at a live head, needs no evidence.
UNCLAIMED_QUEUED_SECONDS = 45 * 60
# Events whose run can sit at a live head: a pull request's, or a branch's
# (push, workflow_dispatch). A schedule runs on main, which is protected.
UNCLAIMED_EVENTS = frozenset({"push", "pull_request", "workflow_dispatch"})
# The pool-wait percentile the bound follows, from the jobs a runner took.
UNCLAIMED_WAIT_PERCENTILE = 90
# Branch head reads (one REST request each) per sweep, for push and dispatch
# runs of categories e and f (branch_head_lookups()), and, from a budget of
# their own so new candidates can never starve them, for the settled cancels
# whose re-run waits on the branch being live (at most LOST_RERUN_MAX re-run a
# sweep anyway).
CANDIDATE_HEAD_LOOKUPS = 6
PENDING_HEAD_LOOKUPS = 10
# A pool's p90 wait needs this many samples; with fewer the bound is the floor.
UNCLAIMED_MIN_SAMPLES = 5
# The snapshot key with each owned pool's p90 wait in seconds.
WAIT_P90_KEY = "wait_p90_seconds"
# Category f also moves a cmux-next leg queued on a Blacksmith macOS label (blacksmith_leg()). Its bound
# is next_macos_cascade.STALL_MINUTES, the wait at which the cascade itself calls such a label stalled.
BLACKSMITH_MACOS_LABEL = re.compile(r"blacksmith-[0-9]+vcpu-macos-[0-9]+")
BLACKSMITH_LEG_SECONDS = 25 * 60
# The cmux-next jobs next_macos_cascade.py places (its CASCADE_JOBS), by their names in feat-cmux-next's
# cmux-next.yml. Each one's runs-on sends a re-run github-actions[bot] did not start to
# needs.macos-placement.outputs.runner, the owned side label, before any Blacksmith label. The GUI and
# session jobs (swift test, daemon tests, generated files) are left out: with no GUI or session runner
# online their re-run still takes blacksmith-6vcpu-macos-26.
CASCADE_JOB_NAMES = frozenset({
    "cmux-next fast tier",
    "cmux-next Swift canary",
    "cmux-next Release compile (Xcode 26)",
    "cmux app scheme compile (Debug)",
})
SNAPSHOT_UNREADABLE = (ValueError, KeyError, EOFError, NotImplementedError, zipfile.BadZipFile, zlib.error)

# The jobs whose failure decides ci-status. ci-macos.yml shards the app-host
# suite and the reusable-call prefix makes the API name "macos / app-host unit
# tests (3/6)", so match on the substring. A failed compile admission fails
# the same `macos` call before any shard starts, and so do the changed suites
# it runs itself (ci-macos.yml inputs.unit_in_admission, when admission
# takes its Mac's gui token).
DOOMED_JOB_NAME = "app-host unit tests"


def decides_ci_status(name: str) -> bool:
    return DOOMED_JOB_NAME in name or bool(COMPILE_ADMISSION_JOB.search(name))

# How long a shard failure must have stood before the run is a candidate, so a
# run that just turned red keeps its siblings while someone looks at it.
DOOMED_GRACE = dt.timedelta(minutes=10)

# The shards' own inputs, read off the app-host-unit-tests job block in
# ci-macos.yml: the XCTest sources it runs, the scripts that shard, compile,
# isolate and grade them, the known-failure quarantine list and the workflow
# that defines the job. A run that changes any of these is an attempt to change
# what the shard does, and its remaining shards are the result someone is
# waiting for. Sources/ is deliberately absent: the suite exercises it, but
# nearly every pull request changes it, and a set matching every pull request
# is not a rule. JANITOR_OPT_OUT_LABEL covers a fix that lives only there.
DOOMED_INPUT_PREFIXES = ("cmuxTests/", "scripts/ci/workloads/")
DOOMED_INPUT_MARKERS = ("app-host", "app_host")
DOOMED_INPUT_FILES = (
    ".github/workflows/ci-macos.yml",
    "scripts/ci/cmux_unit_test_shard.py",
    "scripts/ci/enable-xctest-automation-mode.sh",
)
JANITOR_OPT_OUT_LABEL = "no-janitor"

PROTECTED_EVENTS = frozenset({"merge_group", "release", "create", "delete", "deployment", "deployment_status"})
# Long-lived branches whose pushes are the base other work merges onto, like
# main's: no pull request ever has their head, so a push there would otherwise
# read as stale (lost_pr_state()).
PROTECTED_PUSH_BRANCHES = frozenset({"main", "feat-cmux-next"})
MAIN_ONLY_EVENTS = frozenset({"schedule", "workflow_dispatch", "repository_dispatch"})
PROTECTED_WORKFLOW = re.compile(r"release|nightly|testflight|app[-_ ]?store|appstore|publish|notar", re.IGNORECASE)
TAG_LIKE_REF = re.compile(r"^(v\d|cmux-tui-v\d|.*-v\d+\.\d+)")

UTC = dt.timezone.utc


# ---------------------------------------------------------------------------
# Pure helpers
# ---------------------------------------------------------------------------


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def format_age(delta: dt.timedelta | None) -> str:
    if delta is None:
        return "-"
    minutes = max(0, int(delta.total_seconds() // 60))
    if minutes < 60:
        return f"{minutes}m"
    return f"{minutes // 60}h{minutes % 60:02d}m"


def protected_reason(run: Mapping[str, Any]) -> str | None:
    """Why a run must never be cancelled, or None when policy may look at it."""
    event = run.get("event") or ""
    branch = run.get("head_branch") or ""
    haystack = " ".join(str(run.get(key) or "") for key in ("name", "path"))
    if not event or not branch:
        return "missing event or branch"
    if event in PROTECTED_EVENTS:
        return f"{event} event"
    if event == "push" and (branch in PROTECTED_PUSH_BRANCHES or branch.startswith("rc/")):
        return f"push to {branch}"
    if event in MAIN_ONLY_EVENTS and branch == "main":
        return f"{event} on main"
    if TAG_LIKE_REF.match(branch):
        return f"tag-like ref {branch}"
    if PROTECTED_WORKFLOW.search(haystack):
        return "release/nightly/TestFlight/App Store workflow"
    return None


def workflow_may_use_macos(text: str) -> bool:
    """False only when a workflow file cannot schedule a macOS job.

    Reusable workflows are followed by the text check on the caller: any
    workflow that calls a local reusable workflow is treated as macOS-capable.
    """
    lowered = text.lower()
    return "macos" in lowered or "uses: ./.github/workflows/" in lowered


def linux_only_workflow_paths(workflows_dir: Path) -> frozenset[str]:
    """Workflow paths on the default branch that never run macOS jobs."""
    paths = set()
    if not workflows_dir.is_dir():
        return frozenset()
    for path in sorted(workflows_dir.glob("*.y*ml")):
        try:
            text = path.read_text(encoding="utf-8")
        except OSError:
            continue
        if not workflow_may_use_macos(text):
            paths.add(f".github/workflows/{path.name}")
    return frozenset(paths)


def needs_jobs(run: Mapping[str, Any], linux_only_paths: frozenset[str], now: dt.datetime) -> bool:
    """Whether a run's jobs are worth one API call this sweep."""
    if run.get("path") in linux_only_paths and not follows_another_copy(run):
        return False
    if run.get("event") in PROTECTED_EVENTS - {"merge_group"}:
        # Deployment/tag bookkeeping never holds pool capacity worth counting.
        return False
    created = parse_time(run.get("created_at"))
    if run.get("status") == "queued" and created and now - created > GHOST_QUEUED_RUN_AGE:
        return False
    return True


def run_target_branch(run: Mapping[str, Any]) -> str | None:
    """The branch whose workflow copy a run follows: a pull request's base, a push's or dispatch's branch; None when unknown."""
    for pr in run.get("pull_requests") or ():
        base = (pr.get("base") or {}).get("ref") if isinstance(pr, Mapping) else None
        if base:
            return str(base)
    if run.get("event") in ("push", "workflow_dispatch") and run.get("head_branch"):
        return str(run["head_branch"])
    return None


def follows_another_copy(run: Mapping[str, Any]) -> bool:
    """A run that may follow a workflow copy other than main's, so main's linux-only reading says nothing about it.

    linux_only_workflow_paths() reads main's workflow files, but a run into or
    on another branch follows that branch's copy: main's cmux-next.yml is an
    inert registration, while feat-cmux-next's puts Mac jobs on the minis,
    Blacksmith macOS and hosted macOS. Until 2026-10-26 those runs were listed
    for the starved-label alert only, so the pool snapshot that
    next_macos_cascade.py reads to count a Blacksmith label's queue and spot a
    stall never saw a cmux-next job: at 02:32Z that day the cascade counted 2
    queued on blacksmith-12vcpu-macos-26 while about ten cmux-next jobs waited
    there, and sent run 40259152940's fast tier into a queue it then sat in
    for over 90 minutes. A same-repository pull request run that names no pull
    request has lost it when the pull request closed (run 40259152940 named
    none once PR #24021 landed), so its base is unknown and it is listed too:
    category b cancels it while it holds a Mac job.
    """
    target = run_target_branch(run)
    if target is not None:
        return target != "main"
    head = (run.get("head_repository") or {}).get("id")
    return (run.get("event") == "pull_request" and not run.get("pull_requests")
            and head is not None and head == (run.get("repository") or {}).get("id"))


def starved_result(github: "GitHub", runs: Sequence[Mapping[str, Any]],
                   jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
                   evidence_jobs: Mapping[int, Sequence[Mapping[str, Any]]], *,
                   now: dt.datetime) -> dict[str, Any]:
    """The snapshot's `starved` and `unserved` (starved_labels.py), and `starved_incomplete` when a listing failed.

    Reads the sweep's jobs, cmux-next's among them (follows_another_copy()). Starts in completed runs
    count as service: the lost-assignment evidence already listed and, only for
    a label about to alert, up to LOST_EVIDENCE_RUNS_PER_WORKFLOW completed runs
    of each of its stuck jobs' workflows (at most LOST_EVIDENCE_WORKFLOWS) that
    finished inside the starved window, among one listing page created within
    STARVED_EVIDENCE_LOOKBACK. A failed listing marks the result incomplete,
    and the alert step then closes no issue as recovered.
    """
    fleet_jobs: dict[int, Sequence[Mapping[str, Any]]] = dict(jobs_by_run)
    evidence: dict[int, Sequence[Mapping[str, Any]]] = dict(evidence_jobs)
    incomplete = False
    found = starved_labels.starved(runs, fleet_jobs, now=now, evidence=evidence)
    alerting = {entry["label"] for entry in found}
    earliest: dict[str, dt.datetime] = {}
    for run in runs:
        workflow = str(run.get("path") or "").rsplit("/", 1)[-1]
        if workflow and any(starved_labels.stuck(job) and starved_labels.fleet_key(job) in alerting
                            for job in fleet_jobs.get(run.get("id"), ())):
            created = parse_time(run.get("created_at")) or now
            earliest[workflow] = min(created, earliest.get(workflow, created))
    window = now - starved_labels.STARVED_AFTER
    for workflow, _ in sorted(earliest.items(), key=lambda item: (item[1], item[0]))[:LOST_EVIDENCE_WORKFLOWS]:
        try:
            # Service is a job start inside the window, so a run holding one finished (was updated)
            # inside it, whenever it was created: list the newest runs and keep those.
            listed = github.completed_runs(workflow, (now - STARVED_EVIDENCE_LOOKBACK).strftime("%Y-%m-%dT%H:%M:%SZ"))
            recent = sorted((run for run in listed if (parse_time(run.get("updated_at")) or dt.datetime.min.replace(
                tzinfo=dt.timezone.utc)) >= window), key=lambda run: str(run.get("updated_at") or ""), reverse=True)
            # Any conclusion: a run cancelled after its fleet job started still shows a runner took it
            # (starved_labels judges service from each job's runner and start).
            known = set(fleet_jobs) | set(evidence)
            for run in [run for run in recent if run.get("id") not in known][:LOST_EVIDENCE_RUNS_PER_WORKFLOW]:
                evidence[run["id"]] = github.jobs(run["id"])
        except RateLimited:
            raise
        except RuntimeError as error:
            incomplete = True
            print(f"queue-janitor: starved-label evidence for {workflow}: {error}", file=sys.stderr)
    if earliest:
        found = starved_labels.starved(runs, fleet_jobs, now=now, evidence=evidence)
    result: dict[str, Any] = {"starved": found,
                              "unserved": starved_labels.unserved(runs, fleet_jobs, now=now, evidence=evidence)}
    if incomplete:
        result["starved_incomplete"] = True
    return result


def owned_label(job: Mapping[str, Any]) -> str | None:
    """The owned Mac pool a job asked for (glaeda-<class>-xcode-<version>), which names no macOS."""
    return next((str(label) for label in job.get("labels") or () if owned_pool(str(label))), None)


def is_macos_job(job: Mapping[str, Any]) -> bool:
    return bool(owned_label(job)) or any("macos" in str(label).lower() for label in job.get("labels") or ())


def runner_pool(job: Mapping[str, Any]) -> str:
    """The pool a macOS job waits on: its owned pool label, else the macOS labels it asked for."""
    owned = owned_label(job)
    if owned:
        return owned
    labels = sorted({str(label).lower() for label in job.get("labels") or () if "macos" in str(label).lower()})
    return ",".join(labels)


def capabilities(job: Mapping[str, Any]) -> tuple[str, ...]:
    """The capability labels (pr_runner_pool.CAPABILITY_LABELS) an owned job asked for beside its pool."""
    if not owned_label(job):
        return ()
    return tuple(label for label in CAPABILITY_LABELS if label in {str(item) for item in job.get("labels") or ()})


def counted_pools(pool: str) -> tuple[str, ...]:
    """The pools a job on `pool` counts toward: an owned pool's root runners are its machines too."""
    return (pool, pool_label(pool)) if pool_label(pool) != pool else (pool,)


def marker_peaks(marker: tuple[str, int, int], owned_jobs: Sequence[Mapping[str, Any]]) -> list[tuple[str, int]]:
    """The peak a run's marker reserves on each pool it counts toward.

    ci.yml's marker names the pool label and every owned machine the run
    placed, root jobs and side lanes alike. Its root jobs' share is that peak
    less the jobs it put on the pool label itself or on its side label (the
    side lanes, which start beside admission and take the side label when
    the picker named one); a side lane not listed yet only reserves more.
    An E2E marker names the root label when the run took one, which is also
    one of the pool's machines.
    """
    pool, peak = marker[0], marker[1]
    if pool_label(pool) != pool:
        return [(pool, peak), (pool_label(pool), peak)]
    side = sum(1 for job in owned_jobs if owned_label(job) in (pool, side_label(pool)))
    return [(pool, peak)] + ([(root_label(pool), peak - side)] if root_label(pool) and peak > side else [])


@dataclasses.dataclass(frozen=True)
class MacosUsage:
    queued: int = 0
    running: int = 0
    oldest_queued_at: dt.datetime | None = None
    compile_admission_running: bool = False
    # The compile admission or app-host shard whose failure decided ci-status,
    # and when it landed.
    # Read from the same pass over the run's jobs, at no extra API cost.
    decided_by: str | None = None
    decided_at: dt.datetime | None = None
    # Queued plus running macOS jobs, per runner pool.
    held_by_pool: Mapping[str, int] = dataclasses.field(default_factory=dict)
    queued_by_pool: Mapping[str, int] = dataclasses.field(default_factory=dict)

    @property
    def held(self) -> int:
        return self.queued + self.running


def macos_usage(jobs: Iterable[Mapping[str, Any]]) -> MacosUsage:
    queued = running = 0
    oldest: dt.datetime | None = None
    compiling = False
    decided_by: str | None = None
    decided_at: dt.datetime | None = None
    undated_failure = False
    held_by_pool: dict[str, int] = {}
    queued_by_pool: dict[str, int] = {}
    for job in jobs:
        if not is_macos_job(job):
            continue
        status = job.get("status")
        name = job.get("name") or ""
        if status in QUEUED_JOB_STATUSES or status in RUNNING_JOB_STATUSES:
            for pool in counted_pools(runner_pool(job)):
                held_by_pool[pool] = held_by_pool.get(pool, 0) + 1
                if status in QUEUED_JOB_STATUSES:
                    queued_by_pool[pool] = queued_by_pool.get(pool, 0) + 1
        if status in QUEUED_JOB_STATUSES:
            queued += 1
            created = parse_time(job.get("created_at"))
            if created and (oldest is None or created < oldest):
                oldest = created
        elif status in RUNNING_JOB_STATUSES:
            running += 1
            if COMPILE_ADMISSION_JOB.search(name):
                compiling = True
        elif status == "completed" and decides_ci_status(name):
            # Job conclusion, never step conclusion: a job whose only failed
            # steps carry continue-on-error concludes `success`, so reading the
            # job already excludes tolerated failures.
            if job.get("conclusion") != "failure":
                continue
            finished = parse_time(job.get("completed_at"))
            if finished is None:
                undated_failure = True
            elif decided_at is None or finished < decided_at:
                decided_by, decided_at = name, finished
    if undated_failure:
        # A failure we cannot time cannot clear the grace window; fail closed.
        decided_by = decided_at = None
    return MacosUsage(queued, running, oldest, compiling, decided_by, decided_at, held_by_pool, queued_by_pool)


# Workflows whose queued macOS jobs a pull request must not take a pool from.
# Match the workflow path only.  CI run names include routing metadata such as
# ``release=arm64``; looking at the combined name and path made every ordinary
# pull-request run look like a release reservation.
RESERVED_POOL_WORKFLOW = re.compile(r"(?:^|/)(?:release|nightly)\.yml$", re.IGNORECASE)
POOL_QUEUED_JOB_STATUSES = QUEUED_JOB_STATUSES - {"waiting"}
POOL_LOAD_VERSION = 1
# Environment variable -> snapshot settings key, for pr_runner_pool.py.
POOL_SETTINGS_ENV = {
    "PR_POOL_LANE": "lane",
    "PR_POOL_OVERFLOW": "overflow",
    "PR_POOL_ORDER": "order",
    "PR_POOL_MAX_QUEUED": "max_queued",
    "PR_POOL_QUEUE_ROUNDS": "queue_rounds",
}


MAX_ARTIFACT_PAGES = 5
# ci.yml's `changes` job uploads this marker when the picker chose an owned
# pool: macos-pool-persistent-<run>-<attempt>-<jobs>p<placed>-<pool>, where
# <jobs> is the machines held at peak and <placed> the owned jobs placed
# (post-admission jobs reuse admission's machine, so placed can exceed jobs).
# The E2E and iOS markers, and ones uploaded before `p<placed>`, omit it.
# workflow_dispatch workflows whose runner job may pick an owned pool and upload it.
OWNED_DISPATCH_WORKFLOWS = ("/test-e2e.yml", "/test-ios.yml", "/ios-screenshots.yml", "/iroh-release-gate.yml",
                            "/cmux-next-dev-daily.yml")
OWNED_MARKER = re.compile(r"macos-pool-persistent-(?P<run>[0-9]+)-(?P<attempt>[0-9]+)-(?P<jobs>[0-9]+)"
                          r"(?:p(?P<placed>[0-9]+))?-(?P<pool>.+)")


def owned_marker(run: Mapping[str, Any], names: Iterable[str]) -> tuple[str, int, int] | None:
    """(pool, peak jobs, placed jobs) from the newest owned-pool marker up to this attempt, or None.

    A re-run of failed jobs does not re-run the picker, so it holds the pool of the attempt that last
    picked. A marker without a placed count places as many jobs as its peak.
    """
    best: tuple[int, str, int, int] | None = None
    for name in names:
        match = OWNED_MARKER.fullmatch(str(name))
        if (match and int(match["run"]) == run.get("id") and int(match["attempt"]) <= (run.get("run_attempt") or 1)
                and owned_pool(match["pool"]) and (best is None or int(match["attempt"]) > best[0])):
            peak = min(int(match["jobs"]), MAX_RUN_JOBS)
            placed = min(int(match["placed"]), MAX_RUN_JOBS) if match["placed"] is not None else peak
            best = int(match["attempt"]), match["pool"], peak, placed
    return best[1:] if best else None


def capability_marker(run: Mapping[str, Any], names: Iterable[str]) -> tuple[str, int] | None:
    """(capability label, peak jobs) from this attempt's capability marker, or None.

    ios_runner_pool.py's runner job uploads it beside the pool marker, in the
    same shape with a capability label (glaeda-ios-sim) for the pool: the
    simulator jobs the run will hold at its peak, before they exist.
    """
    for name in names:
        match = OWNED_MARKER.fullmatch(str(name))
        if (match and int(match["run"]) == run.get("id") and int(match["attempt"]) == (run.get("run_attempt") or 1)
                and match["pool"] in CAPABILITY_LABELS):
            return match["pool"], min(int(match["jobs"]), MAX_RUN_JOBS)
    return None


def may_hold_owned_pool(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]]) -> bool:
    """A run whose marker is worth an artifact listing: it may hold an owned pool.

    Only attempts 1 and 2 (pr_runner_pool.LAST_OWNED_ATTEMPT) of a
    same-repository pull request run of CI, of main's full-suite dispatch of
    CI (pr_runner_pool.py routes it too), or of an E2E, iOS or Iroh release
    gate dispatch (the runner job of test-e2e.yml, test-ios.yml,
    ios-screenshots.yml and iroh-release-gate.yml uploads the same marker),
    can: a full re-run picks again like attempt 1 and publishes its own
    marker, and a re-run of failed jobs publishes none, costing one listing.
    A pull request run's re-run someone other than github-actions[bot]
    started follows a code failure and picks like attempt 1
    (pr_runner_pool.host_fault_retry()), so any attempt of it can too; the
    bot's later attempts never hold one. Its other macOS jobs say nothing:
    swift-package-tests usually runs on a Blacksmith pool beside a run on an
    owned one (only a run that builds no Release helper places it there).
    """
    path = str(run.get("path") or "")
    code_retry = (run.get("event") == "pull_request" and path.endswith("/ci.yml")
                  and str((run.get("triggering_actor") or {}).get("login") or "") != "github-actions[bot]")
    if (run.get("run_attempt") or 1) > 2 and not code_retry:
        return False
    if (run.get("head_repository") or {}).get("id") != (run.get("repository") or {}).get("id"):
        return False
    if run.get("event") == "workflow_dispatch":
        return path.endswith(OWNED_DISPATCH_WORKFLOWS) or (
            path.endswith("/ci.yml") and run.get("head_branch") == "main")
    return run.get("event") == "pull_request" and path.endswith("/ci.yml")


def marker_may_exist(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]]) -> bool:
    """Whether an owned-pool marker can exist yet, so listing the run's artifacts could find one.

    One of the run's own jobs uploads the marker (ci.yml's `changes`, the
    runner job of the dispatch workflows). A first attempt whose jobs have
    not left the queue has therefore uploaded nothing. A later attempt may
    hold an earlier attempt's marker (owned_marker()), and a listing cut off
    at MAX_JOB_PAGES may hide a started job, so both are still listed. Queued
    pull request runs make up much of a backed-up sweep, and each skipped
    listing saves one API request per sweep.
    """
    if (run.get("run_attempt") or 1) > 1 or len(jobs) >= MAX_JOB_PAGES * 100:
        return True
    return any(job.get("status") not in QUEUED_JOB_STATUSES for job in jobs)


def pool_load_snapshot(
    runs: Sequence[Mapping[str, Any]],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
    *,
    now: dt.datetime,
    settings: Mapping[str, str] | None = None,
    markers: Mapping[int, tuple[str, int, int]] | None = None,
    capability_markers: Mapping[int, tuple[str, int]] | None = None,
) -> dict[str, Any]:
    """Per-pool macOS demand from the jobs this sweep already listed.

    A pool is a job's single runner label when it asked for one, which is
    every Blacksmith job, so pr_runner_pool.py can look a label up directly.
    Only jobs waiting for a runner count as queued; a `waiting` job is held
    by an environment approval and asks no pool for anything yet.
    `reserved_queued` counts the queued jobs of release and nightly runs; it
    is what tells a pull request to stay off a pool those runs are waiting on.
    `settings` carries the pool-choice repository variables, which a fork
    pull request's run cannot read itself.

    A job on an owned pool (`glaeda-<class>-xcode-<version>`) is keyed by
    that label (runner_pool); its counts are how pr_runner_pool.py knows how
    many of the pool's machines are taken. An owned pool also gets
    `committed`: for each run holding it, the larger of the jobs seen there
    and the peak its marker declares (`markers`, run id -> (pool, jobs, placed)), so
    a run whose later jobs do not exist yet still counts them. A job on an
    owned pool's root runners (`glaeda-root-...`) counts toward both the root
    label and the pool (counted_pools()), and so does its run's marker
    (marker_peaks()), so the picker reads free root runners and free machines
    from one snapshot.

    A job that also asked for a capability label (glaeda-ios-sim, see
    capabilities()) counts toward that label as well, and a run's capability
    marker (`capability_markers`, run id -> (label, jobs)) sets its
    `committed` the same way, so ios_runner_pool.py reads the simulator
    machines taken. Every job carrying the label counts, whether it holds a
    simulator or not, so the count errs toward Blacksmith.
    """
    pools: dict[str, dict[str, Any]] = {}
    oldest: dict[str, dt.datetime] = {}
    committed: dict[str, int] = {}
    for run in runs:
        reserved = bool(RESERVED_POOL_WORKFLOW.search(str(run.get("path") or "")))
        seen: dict[str, int] = {}
        for job in jobs_by_run.get(run.get("id"), ()):
            if is_macos_job(job) and owned_label(job) and job.get("status") in (
                    POOL_QUEUED_JOB_STATUSES | RUNNING_JOB_STATUSES):
                for label in (*counted_pools(runner_pool(job)), *capabilities(job)):
                    seen[label] = seen.get(label, 0) + 1
        marker = (markers or {}).get(run.get("id"))
        # A run whose owned jobs all finished holds no owned machine, even while
        # its Blacksmith jobs (per-job placement) keep it in flight. Shard jobs
        # exist only after admission finishes, so the marker keeps reserving its
        # peak until as many owned jobs as it placed have completed (more than
        # its peak when the jobs after admission reuse admission's machine).
        owned_jobs = [job for job in jobs_by_run.get(run.get("id"), ()) if is_macos_job(job) and owned_label(job)]
        done = sum(1 for job in owned_jobs if job.get("status") == "completed")
        released = (bool(owned_jobs) and done == len(owned_jobs)
                    and (not marker or done >= marker[2]))
        if marker and run.get("status") != "completed" and not released:
            for label, peak in marker_peaks(marker, owned_jobs):
                seen[label] = max(seen.get(label, 0), peak)
        capability = (capability_markers or {}).get(run.get("id"))
        if capability and run.get("status") != "completed":
            label, peak = capability
            carrying = [job for job in owned_jobs if label in capabilities(job)]
            finished = sum(1 for job in carrying if job.get("status") == "completed")
            # Released once as many of its capability jobs finished as it declared.
            if not (carrying and finished == len(carrying) and finished >= peak):
                seen[label] = max(seen.get(label, 0), peak)
        for label, count in seen.items():
            committed[label] = committed.get(label, 0) + count
        for job in jobs_by_run.get(run.get("id"), ()):
            if not is_macos_job(job):
                continue
            status = job.get("status")
            if status not in POOL_QUEUED_JOB_STATUSES and status not in RUNNING_JOB_STATUSES:
                continue
            for pool in (*counted_pools(runner_pool(job)), *capabilities(job)):
                entry = pools.setdefault(pool, {"queued": 0, "running": 0, "reserved_queued": 0,
                                                "oldest_queued_minutes": 0})
                if status in RUNNING_JOB_STATUSES:
                    entry["running"] += 1
                    continue
                entry["queued"] += 1
                if reserved:
                    entry["reserved_queued"] += 1
                created = parse_time(job.get("created_at"))
                if created and (pool not in oldest or created < oldest[pool]):
                    oldest[pool] = created
    for pool, created in oldest.items():
        pools[pool]["oldest_queued_minutes"] = max(0, int((now - created).total_seconds() // 60))
    # Which job each owned runner is running and since when: pr_runner_pool.py's warm routing
    # estimates a busy warm runner's wait from it (warm_distance.remaining_seconds()).
    running: dict[str, dict[str, str]] = {}
    for run in runs:
        for job in jobs_by_run.get(run.get("id"), ()):
            if job.get("status") in RUNNING_JOB_STATUSES and job.get("runner_name") and owned_label(job):
                running[str(job["runner_name"])] = {"job": str(job.get("name") or ""),
                                                    "started_at": str(job.get("started_at") or "")}
    for pool, count in committed.items():
        pools.setdefault(pool, {"queued": 0, "running": 0, "reserved_queued": 0,
                                "oldest_queued_minutes": 0})["committed"] = count
    return {
        "version": POOL_LOAD_VERSION,
        "generated_at": now.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "pools": dict(sorted(pools.items())),
        "running": dict(sorted(running.items())),
        "settings": dict(settings or {}),
    }


def touches_doomed_job_inputs(paths: Iterable[str]) -> bool:
    for path in paths:
        if path in DOOMED_INPUT_FILES or path.startswith(DOOMED_INPUT_PREFIXES):
            return True
        if any(marker in path for marker in DOOMED_INPUT_MARKERS):
            return True
    return False


def pr_changed_paths(pr: Mapping[str, Any]) -> list[str] | None:
    """Changed paths, or None when the diff cannot be read in full."""
    files = pr.get("files") or {}
    if (files.get("pageInfo") or {}).get("hasNextPage"):
        return None
    nodes = files.get("nodes")
    if nodes is None:
        return None
    return [str(node.get("path")) for node in nodes]


def run_head_owner(run: Mapping[str, Any]) -> str:
    repo = run.get("head_repository") or {}
    owner = repo.get("owner") or {}
    return str(owner.get("login") or "").lower()


def resolve_pull_request(run: Mapping[str, Any], candidates: Sequence[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """Pick the pull request a pull_request-event run belongs to, or None if unsure."""
    owner = run_head_owner(run)
    prs = [pr for pr in candidates if str(((pr.get("headRepositoryOwner") or {}).get("login")) or "").lower() == owner]
    if not prs:
        return None
    numbers = {pr.get("number") for pr in run.get("pull_requests") or ()}
    by_number = [pr for pr in prs if pr.get("number") in numbers]
    if len(by_number) == 1:
        return by_number[0]
    same_head = [pr for pr in prs if pr.get("headRefOid") == run.get("head_sha")]
    open_same_head = [pr for pr in same_head if pr.get("state") == "OPEN"]
    if len(open_same_head) == 1:
        return open_same_head[0]
    if len(same_head) == 1:
        return same_head[0]
    open_prs = [pr for pr in prs if pr.get("state") == "OPEN"]
    if len(open_prs) == 1:
        return open_prs[0]
    if not open_prs and len(prs) == 1:
        return prs[0]
    return None


def had_label_at(pr: Mapping[str, Any], label: str, when: dt.datetime) -> bool | None:
    """Whether `label` was on the PR at `when`, from its label timeline.

    None means the timeline cannot say (no event for that label at all while
    the label is absent now is taken as "never had it"; a label present now
    with no events is unknowable).
    """
    events = []
    for node in ((pr.get("timelineItems") or {}).get("nodes") or ()):
        name = ((node.get("label") or {}).get("name"))
        created = parse_time(node.get("createdAt"))
        if name != label or created is None:
            continue
        events.append((created, node.get("__typename")))
    events.sort()
    before = [kind for created, kind in events if created <= when]
    if before:
        return before[-1] == "LabeledEvent"
    if events:
        # Every event is later: the label state before them is the opposite of
        # the first one.
        return events[0][1] == "UnlabeledEvent"
    has_now = label in {n.get("name") for n in ((pr.get("labels") or {}).get("nodes") or ())}
    return None if has_now else False


def pr_labels(pr: Mapping[str, Any]) -> set[str]:
    return {str(n.get("name")) for n in ((pr.get("labels") or {}).get("nodes") or ())}


def labels_complete(pr: Mapping[str, Any]) -> bool:
    return not ((pr.get("labels") or {}).get("pageInfo") or {}).get("hasNextPage")


@dataclasses.dataclass(frozen=True)
class Candidate:
    run: Mapping[str, Any]
    category: str
    reason: str
    usage: MacosUsage
    pr: Mapping[str, Any] | None = None
    # Category e at the current head of an open pull request: once the cancel
    # has settled, a later sweep re-runs the run's failed jobs (new_lost_reruns()).
    rerun: bool = False
    # That re-run must come from an App's token, never GITHUB_TOKEN (a Blacksmith leg, blacksmith_leg()).
    app_actor: bool = False


def classify(
    run: Mapping[str, Any],
    usage: MacosUsage,
    pr: Mapping[str, Any] | None,
    *,
    newer_ci_run_waiting: bool,
    pull_request_policy: str,
    now: dt.datetime,
) -> tuple[str, str] | None:
    """Return (category, reason) for a wasteful run, or None to leave it alone."""
    if usage.held == 0 or protected_reason(run):
        return None
    event = run.get("event")
    branch = run.get("head_branch") or ""

    if event == "push":
        if branch.startswith(EXPERIMENT_BRANCH_PREFIXES):
            return "experiment", f"push-triggered experiment on {branch}"
        return None

    if event != "pull_request" or pr is None:
        return None

    number = pr.get("number")
    state = pr.get("state")
    if state == "MERGED":
        return "stale-pr", f"PR #{number} is merged"
    if state == "CLOSED":
        return "stale-pr", f"PR #{number} is closed"
    if state != "OPEN":
        return None
    if pr.get("headRefOid") and pr.get("headRefOid") != run.get("head_sha"):
        return "stale-pr", f"superseded: PR #{number} head is now {str(pr.get('headRefOid'))[:9]}"

    if (
        run.get("path") == CI_WORKFLOW_PATH
        and pull_request_policy.strip() == COMPILE_ONLY_POLICY
        and FULL_SUITE_LABEL not in pr_labels(pr)
        and newer_ci_run_waiting
        and not usage.compile_admission_running
    ):
        created = parse_time(run.get("created_at"))
        if created and had_label_at(pr, FULL_SUITE_LABEL, created) is True:
            return "label-dropped", f"full suite, but PR #{number} no longer has `{FULL_SUITE_LABEL}`"

    # Doomed: ci-status is already decided against this run. Reaching here means
    # the PR is open and this run is still its current head, so unlike the
    # categories above the run is live and its remaining shards are readable
    # output. Everything unknown therefore preserves the run.
    if (
        run.get("path") == CI_WORKFLOW_PATH
        and usage.decided_by
        and usage.decided_at is not None
        # A re-run replays a subset of jobs, so an older attempt's failure is
        # not evidence about this one.
        and run.get("run_attempt") == 1
        and now - usage.decided_at >= DOOMED_GRACE
        and JANITOR_OPT_OUT_LABEL not in pr_labels(pr)
    ):
        changed = pr_changed_paths(pr)
        # An unreadable diff is not evidence that this run is not the fix.
        if changed is not None and not touches_doomed_job_inputs(changed):
            return "doomed", (
                f"ci-status already decided for PR #{number} ({branch}): `{usage.decided_by}` "
                f"failed {format_age(now - usage.decided_at)} ago, "
                f"{usage.held} macOS job(s) still held"
            )
    return None


def newer_ci_run_waiting(run: Mapping[str, Any], runs: Iterable[Mapping[str, Any]]) -> bool:
    """A later CI run for the same PR branch is in flight to take over ci-status."""
    if run.get("path") != CI_WORKFLOW_PATH:
        return False
    created = parse_time(run.get("created_at"))
    for other in runs:
        if other.get("id") == run.get("id") or other.get("path") != CI_WORKFLOW_PATH:
            continue
        if other.get("event") != "pull_request" or other.get("head_branch") != run.get("head_branch"):
            continue
        if run_head_owner(other) != run_head_owner(run):
            continue
        other_created = parse_time(other.get("created_at"))
        if created and other_created and other_created > created and other.get("status") in IN_FLIGHT_RUN_STATUSES:
            return True
    return False


def newer_run_at_head(run: Mapping[str, Any], runs: Iterable[Mapping[str, Any]]) -> Mapping[str, Any] | None:
    """A later run of `run`'s workflow and event at its branch and head, not cancelled: it took over.

    A `labeled` ci.yml run queued behind `run` in the same concurrency group is
    one. Re-running `run` would replay its event (cancel-in-progress included)
    over the newer run, so category e never re-runs a run that has one.

    A workflow_dispatch has none: each dispatch is its own request
    (cmux-tui.yml runs each in its own `cmux-tui-<request_id>` group, never
    cancelled in progress), so a second dispatch at the same head takes
    nothing over, and counting it would block category f's rescue or drop its
    pending re-run, leaving the run cancelled for good.
    """
    if run.get("event") == "workflow_dispatch":
        return None
    for other in runs:
        if (int(other.get("id") or 0) > int(run.get("id") or 0)
                and other.get("path") == run.get("path") and other.get("event") == run.get("event")
                and other.get("head_branch") == run.get("head_branch") and other.get("head_sha") == run.get("head_sha")
                and run_head_owner(other) == run_head_owner(run) and other.get("conclusion") != "cancelled"):
            return other
    return None


# ---------------------------------------------------------------------------
# Category e: lost runner assignments
# ---------------------------------------------------------------------------
#
# GitHub can lose a job's runner assignment: the job stays `queued` with no
# runner for hours while newer jobs on the same labels are picked up, and the
# runner fleet never sees it (run 39631559018, job 119450713364 on
# glaeda-side-std-xcode-26.6, queued 80+ minutes from 19:55Z on 2026-10-21).
# The same pattern hit PR #23694 that day: run 39667716636's job
# 119458409272 (`cmux-next swift test`, glaeda-gui-std-xcode-26.6) queued from
# 20:11Z past 23:03Z with no runner while newer gui-std jobs started at 22:51Z
# and 23:07Z. The sweep runs on a hosted runner that cannot reach the fleet
# dashboard, so "the fleet has no record of it" is read from GitHub alone: no
# runner id or name, and proof from the same inventory that runners serving
# exactly its labels took newer work and skipped it (skipped_by_pool()).


def unassigned(job: Mapping[str, Any]) -> bool:
    """GitHub shows the job queued with no runner: runner_id null or 0 and no runner_name.

    `waiting` (an environment approval) and `pending` (a concurrency group)
    are deliberate holds, not lost assignments. A job with no labels asked no
    pool for anything.
    """
    return (job.get("status") == "queued" and not job.get("runner_id") and not job.get("runner_name")
            and bool(job.get("labels")))


def took_runner(job: Mapping[str, Any]) -> bool:
    """A runner took the job: it is running, or it finished after a runner started it.

    A job cancelled while still queued is `completed` with a `started_at` too,
    but no runner id or name, so `started_at` alone proves nothing.
    """
    if job.get("status") in RUNNING_JOB_STATUSES:
        return True
    return (job.get("status") == "completed" and bool(job.get("started_at"))
            and bool(job.get("runner_id") or job.get("runner_name")))


def lost_wait_start(job: Mapping[str, Any], run_jobs: Iterable[Mapping[str, Any]]) -> dt.datetime | None:
    """When the job could first have run: its `created_at`, or the last completion among its run's other jobs.

    A job record can exist before its `needs` finished, and the jobs API names
    no `needs`, so any sibling's completion may be the one it waited for.
    Taking the latest errs toward a later start, and so toward leaving a job
    alone. A sibling not finished yet may be the gate too, so the wait counts
    only once none is left (_gated()).
    """
    created = parse_time(job.get("created_at"))
    if created is None:
        return None
    finished = [parse_time(other.get("completed_at")) for other in run_jobs
                if other is not job and other.get("status") == "completed"]
    return max([created, *(moment for moment in finished if moment is not None)])


def skipped_by_pool(job: Mapping[str, Any], since: dt.datetime, others: Iterable[Mapping[str, Any]]) -> int:
    """How many jobs on exactly this job's labels, created after `since`, a runner took (took_runner()).

    This is the evidence rule. The label set is the job's whole `labels`
    list, lowercased (job_pool_key(): GitHub matches labels without case),
    compared for equality: a runner serving it can take any job asking for
    those labels, while a job asking for one label more or less may need a
    runner this job cannot use, or the reverse. A pool serves its queue
    roughly in order, so a newer job on the same labels being taken means the
    pool had a runner and passed this job over. A merely backed-up pool leaves
    the newer jobs queued too, and the count stays 0.
    """
    key = job_pool_key(job)
    count = 0
    for other in others:
        if other is job or job_pool_key(other) != key or not took_runner(other):
            continue
        created = parse_time(other.get("created_at"))
        if created is not None and created > since:
            count += 1
    return count


@dataclasses.dataclass(frozen=True)
class LostJob:
    job_name: str
    labels: str
    queued_since: dt.datetime
    # Newer jobs on the same labels that a runner took (skipped_by_pool()).
    skipped: int


def _overdue(run_jobs: Sequence[Mapping[str, Any]], now: dt.datetime) -> Iterable[tuple[Mapping[str, Any], dt.datetime]]:
    for job in run_jobs:
        if not unassigned(job):
            continue
        since = lost_wait_start(job, run_jobs)
        if since is not None and (now - since).total_seconds() > LOST_QUEUED_SECONDS:
            yield job, since


def _gated(run_jobs: Iterable[Mapping[str, Any]], suspects: Iterable[Mapping[str, Any]]) -> bool:
    """Another job of the run is unfinished (queued, waiting, pending or running) and not itself a suspect.

    The jobs API names no `needs`, so any such job may be the gate a queued
    job waits behind: one still building, held, or queued in a backed-up pool.
    Its wait has not begun, whether the run is stale or current. A sibling
    that is itself a suspect (unassigned and overdue, and in find_lost() also
    skipped by its pool) is no gate, so two lost jobs never mask each other.
    """
    exempt = {id(job) for job in suspects}
    return any(job.get("status") != "completed" and id(job) not in exempt for job in run_jobs)


def _lost_scope(run: Mapping[str, Any]) -> bool:
    return (run.get("status") in IN_FLIGHT_RUN_STATUSES and run.get("event") in LOST_EVENTS
            and protected_reason(run) is None)


def _all_jobs(*maps: Mapping[int, Sequence[Mapping[str, Any]]] | None) -> list[Mapping[str, Any]]:
    return [job for jobs_by_run in maps if jobs_by_run for jobs in jobs_by_run.values() for job in jobs]


def find_lost(
    runs: Sequence[Mapping[str, Any]],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
    *,
    now: dt.datetime,
    evidence_jobs: Mapping[int, Sequence[Mapping[str, Any]]] | None = None,
) -> dict[int, LostJob]:
    """Run id -> its longest-waiting lost job, for in-flight push and pull request runs policy may touch.

    A job is lost when it is unassigned(), could have run for more than
    LOST_QUEUED_SECONDS (lost_wait_start()), and skipped_by_pool() finds at
    least one newer job on its labels taken, among every job this sweep
    listed: the in-flight runs' and the completed runs listed for this
    (`evidence_jobs`, evidence_queries()). Without that evidence the job is
    waiting in a backed-up pool and is left alone. A run with any other
    unfinished job that is not lost itself has none (_gated()).
    """
    others = _all_jobs(jobs_by_run, evidence_jobs)
    lost: dict[int, LostJob] = {}
    for run in runs:
        if not _lost_scope(run):
            continue
        run_jobs = jobs_by_run.get(run["id"]) or ()
        found: list[tuple[Mapping[str, Any], LostJob]] = []
        for job, since in _overdue(run_jobs, now):
            skipped = skipped_by_pool(job, since, others)
            if skipped:
                found.append((job, LostJob(str(job.get("name") or ""), job_pool_key(job), since, skipped)))
        if found and not _gated(run_jobs, [job for job, _ in found]):
            lost[run["id"]] = min((item for _, item in found), key=lambda item: item.queued_since)
    return lost


def evidence_queries(
    runs: Sequence[Mapping[str, Any]],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
    *,
    now: dt.datetime,
) -> list[tuple[str, str]]:
    """(workflow file, earliest wait start) to list completed runs for, when the inventory holds no evidence.

    In-flight runs show only the jobs still in flight; a short side lane that
    started after a lost job may already have finished with its run. Such
    newer runs of the suspect's own workflow most likely asked for the same
    labels, so one listing of its completed runs created since the wait began
    finds them. At most LOST_EVIDENCE_WORKFLOWS, oldest suspect first.
    """
    others = _all_jobs(jobs_by_run)
    earliest: dict[str, dt.datetime] = {}
    for run in runs:
        workflow = str(run.get("path") or "").rsplit("/", 1)[-1]
        run_jobs = jobs_by_run.get(run["id"]) or ()
        overdue = list(_overdue(run_jobs, now))
        if not _lost_scope(run) or not workflow or _gated(run_jobs, [job for job, _ in overdue]):
            continue
        for job, since in overdue:
            if not skipped_by_pool(job, since, others) and (workflow not in earliest or since < earliest[workflow]):
                earliest[workflow] = since
    ordered = sorted(earliest.items(), key=lambda item: (item[1], item[0]))[:LOST_EVIDENCE_WORKFLOWS]
    return [(workflow, _iso(since)) for workflow, since in ordered]


def evidence_runs(listed: Iterable[Mapping[str, Any]], *, known: Iterable[int], cap: int) -> list[Mapping[str, Any]]:
    """The first `cap` listed runs whose jobs ran (success or failure) and whose jobs the sweep has not listed."""
    known = set(known)
    return [run for run in listed
            if run.get("id") not in known and run.get("conclusion") in ("success", "failure")][:cap]


def lost_branches(runs: Iterable[Mapping[str, Any]], lost: Mapping[int, LostJob],
                  pending: Iterable[Mapping[str, Any]]) -> list[str]:
    """Branches the pull request lookup needs for category e: lost runs' and pending re-runs'."""
    branches = {str(run.get("head_branch")) for run in runs if run.get("id") in lost and run.get("head_branch")}
    branches |= {str(entry.get("branch")) for entry in pending if isinstance(entry, Mapping) and entry.get("branch")}
    return sorted(branches)


def bot_rerun(run: Mapping[str, Any]) -> bool:
    """This attempt is a re-run a bot started: the janitor's own, owned_pool_rescue.py's, or another App's."""
    actor = str((run.get("triggering_actor") or {}).get("login") or "")
    return int(run.get("run_attempt") or 1) > 1 and actor.endswith("[bot]")


def lost_pr_state(run: Mapping[str, Any], prs: Sequence[Mapping[str, Any]],
                  branch_head: str | None = None) -> tuple[str, Mapping[str, Any] | None, str]:
    """("current" | "stale" | "unknown", the pull request it was judged by, why).

    A pull request run is current while its pull request is open at the run's
    head, and stale once it is merged, closed or superseded. A push or
    workflow_dispatch run is current while an open pull request from the same
    owner has the run's head, or while its branch is live: `branch_head`, the
    branch's head read this sweep ("" when the branch is gone, None when not
    read), is still the run's head. Otherwise it is stale; a push whose branch
    head was not read is stale as before (a branch with no pull request at
    all), a dispatch's is unknown.
    """
    branch = run.get("head_branch") or ""
    sha = str(run.get("head_sha") or "")
    if run.get("event") == "pull_request":
        pr = resolve_pull_request(run, prs)
        if pr is None:
            return "unknown", None, "its pull request could not be resolved"
        number, state = pr.get("number"), pr.get("state")
        if state in ("MERGED", "CLOSED"):
            return "stale", pr, f"PR #{number} is {str(state).lower()}"
        if state != "OPEN":
            return "unknown", pr, f"PR #{number} is {state}"
        if pr.get("headRefOid") and pr.get("headRefOid") != sha:
            return "stale", pr, f"superseded: PR #{number} head is now {str(pr.get('headRefOid'))[:9]}"
        return "current", pr, f"at the head of open PR #{number}"
    event = run.get("event")
    if event in ("push", "workflow_dispatch"):
        what = "push" if event == "push" else "dispatch"
        owner = run_head_owner(run)
        open_prs = [pr for pr in prs if pr.get("state") == "OPEN"
                    and str(((pr.get("headRepositoryOwner") or {}).get("login")) or "").lower() == owner]
        at_head = [pr for pr in open_prs if pr.get("headRefOid") == sha]
        if at_head:
            return "current", at_head[0], f"{what} at the head of open PR #{at_head[0].get('number')}"
        some_pr = open_prs[0] if open_prs else None
        if branch_head is not None and sha and branch_head == sha:
            return "current", some_pr, f"{what} at the head of live branch {branch}"
        if branch_head is None:
            if event == "push":
                return "stale", some_pr, f"push on {branch}: no open pull request at {sha[:9]}"
            return "unknown", some_pr, f"dispatch on {branch}: its branch head was not read"
        if not branch_head:
            return "stale", some_pr, f"{what} on {branch}: the branch is gone"
        return "stale", some_pr, f"{what} on {branch}: the branch moved on to {branch_head[:9]}"
    return "unknown", None, f"{event} run"


@dataclasses.dataclass(frozen=True)
class LostVerdict:
    action: str  # "cancel" or "skip"
    reason: str
    note: str = ""
    rerun: bool = False
    pr: Mapping[str, Any] | None = None


def classify_lost(
    run: Mapping[str, Any],
    run_jobs: Sequence[Mapping[str, Any]],
    lost: LostJob,
    prs: Sequence[Mapping[str, Any]] | None,
    *,
    now: dt.datetime,
    rerun_state: bool,
    newer: Mapping[str, Any] | None = None,
    branch_head: str | None = None,
) -> LostVerdict | None:
    """What category e does with a run holding a lost job, or None to leave it to the other categories.

    `prs` is the lookup for the run's branch, None when the branch was not
    looked up (then nothing is known, and nothing is done). find_lost()
    already left alone any run with another job unfinished, so no cancel
    kills readable work. A stale run is cancelled: nobody reads it. A run at
    the current head of an open pull request is cancelled so that a later
    sweep re-runs its failed jobs, except:
    - an attempt a bot started (bot_rerun()) is left alone: it is the
      janitor's own re-run or owned_pool_rescue.py's, which the rescue's watch
      and then the orphan pass own, and is never re-run again;
    - a run that already failed, or one a newer run at its head took over
      (`newer`: newer_ci_run_waiting() or newer_run_at_head() over the
      inventory), is cancelled but not re-run: the first is decided, and
      re-running the second would replay its event over the newer run;
    - without re-run state (`rerun_state`: --pool-load, and the previous
      snapshot was readable) it is left alone, since a cancel nobody re-runs
      would leave the pull request with a cancelled run.
    `no-janitor` on the pull request, or a label page left unread, skips the
    run like an orphan.
    """
    if prs is None:
        return None
    state, pr, why = lost_pr_state(run, prs, branch_head)
    evidence = (f"lost runner assignment: `{lost.job_name}` queued {format_age(now - lost.queued_since)} with no "
                f"runner while {lost.skipped} newer job(s) on `{lost.labels}` started")
    if state == "unknown":
        return LostVerdict("skip", evidence, why)
    if pr is not None and JANITOR_OPT_OUT_LABEL in pr_labels(pr):
        return LostVerdict("skip", evidence, f"PR #{pr.get('number')} is labelled `{JANITOR_OPT_OUT_LABEL}`", pr=pr)
    if pr is not None and not labels_complete(pr):
        return LostVerdict("skip", evidence, f"PR #{pr.get('number')} has more labels than were read", pr=pr)
    if state == "stale":
        return LostVerdict("cancel", f"{evidence}; {why}", pr=pr)
    if bot_rerun(run):
        return LostVerdict("skip", f"{evidence}; {why}", f"attempt {run.get('run_attempt')} is a bot's re-run, left "
                                                         "to the owned-pool rescue and the orphan pass", pr=pr)
    if any(job.get("status") == "completed" and job.get("conclusion") == "failure" for job in run_jobs):
        return LostVerdict("cancel", f"{evidence}; {why}, but the run already failed, so it is not re-run", pr=pr)
    if newer is not None:
        return LostVerdict("cancel", f"{evidence}; {why}, but newer run {newer.get('id')} at its head took over, "
                                     "so it is not re-run", pr=pr)
    if not rerun_state:
        return LostVerdict("skip", f"{evidence}; {why}", "no re-run state to carry the re-run to a later sweep", pr=pr)
    return LostVerdict("cancel", f"{evidence}; {why}: its failed jobs are re-run once the cancel settles",
                       rerun=True, pr=pr)


# ---------------------------------------------------------------------------
# Category f: unclaimed legs
# ---------------------------------------------------------------------------
#
# The macOS leg of side-lane cmux-tui run 39652497071 (a workflow_dispatch on
# acpmux-policy-everywhere at d9d0e2ca, job 119404259678 `macOS lint and
# tests` on glaeda-side-std-xcode-26.6) sat unclaimed from 18:25Z to 00:37Z,
# until GitHub's queue timeout cancelled it. Category e did not apply (a
# dispatch, and no newer same-label job was seen taken), and
# owned_pool_rescue.py's sweeper re-runs only a side lane's refused jobs. So a
# leg on an owned label no runner claimed within a bounded wait is moved
# whatever the evidence: max(UNCLAIMED_QUEUED_SECONDS, the pool's p90 wait)
# after it could first run, at the head of an open pull request or a live
# branch, by the same cancel and carried re-run of failed jobs as category e,
# where that re-run leaves the owned label (owned_pool_rescue.
# bot_rerun_leaves_owned(); a side lane's attempt 2 takes its Blacksmith
# macOS default).


def pool_wait_p90(*maps: Mapping[int, Sequence[Mapping[str, Any]]] | None) -> dict[str, int]:
    """Owned pool -> the p90 (nearest rank) of how long the jobs a runner took waited for one, in seconds.

    Read from the jobs the sweep already listed (run id -> jobs, one or more
    maps), so it costs nothing; it is published in the pool snapshot under
    WAIT_P90_KEY. A wait runs from when the job could first run to its start:
    its `created_at`, or the last completion among its run's other jobs before
    it started (as lost_wait_start() measures a queued one), since a job record
    can exist before its `needs` finished. A pool with fewer than
    UNCLAIMED_MIN_SAMPLES samples has no p90, so its bound is the floor.
    """
    waits: dict[str, list[float]] = {}
    for jobs_by_run in maps:
        for run_jobs in (jobs_by_run or {}).values():
            for job in run_jobs:
                pool = rescue.job_pool(job)
                if not pool or not took_runner(job):
                    continue
                created, started = parse_time(job.get("created_at")), parse_time(job.get("started_at"))
                if created is None or started is None:
                    continue
                gates = [parse_time(other.get("completed_at")) for other in run_jobs
                         if other is not job and other.get("status") == "completed"]
                since = max([created, *(moment for moment in gates if moment is not None and moment <= started)])
                if started >= since:
                    waits.setdefault(pool, []).append((started - since).total_seconds())
    result = {}
    for pool, values in waits.items():
        if len(values) < UNCLAIMED_MIN_SAMPLES:
            continue
        values.sort()
        rank = max(1, -(-len(values) * UNCLAIMED_WAIT_PERCENTILE // 100))
        result[pool] = int(values[rank - 1])
    return dict(sorted(result.items()))


def unclaimed_bound(pool: str, p90: Mapping[str, int]) -> int:
    """How long a leg on `pool` may wait unclaimed: UNCLAIMED_QUEUED_SECONDS, or the pool's p90 wait when longer."""
    return max(UNCLAIMED_QUEUED_SECONDS, int(p90.get(pool) or 0))


@dataclasses.dataclass(frozen=True)
class UnclaimedJob:
    job_name: str
    pool: str
    queued_since: dt.datetime
    bound_seconds: int
    blacksmith: bool = False


def blacksmith_leg(run: Mapping[str, Any], job: Mapping[str, Any]) -> str | None:
    """The Blacksmith macOS label a cmux-next job waits on, if any.

    next_macos_cascade.py sends a cmux-next Mac job no idle mini takes to a
    Blacksmith macOS label it reads as free, and no rescue watches it there:
    owned_pool_rescue.py moves only owned legs, and GitHub never re-routes a
    queued job. Run 40259152940's fast tier waited on
    blacksmith-12vcpu-macos-26 from 02:32Z on 2026-10-26, and in the 18 hours
    before, 58 of 110 cmux-next jobs sent to that label never got a runner.
    Category f moves such a leg as it moves an owned one, only because the
    janitor re-runs as an App: cmux-next.yml sends a re-run that
    github-actions[bot] did not start to the placement's owned side label
    (`github.triggering_actor != 'github-actions[bot]' && ...outputs.runner`),
    where the owned-pool rescue watches it, while that bot's attempt 2 takes
    attempt 1's Blacksmith placement again. So only a cascade job
    (CASCADE_JOB_NAMES) of a same-repository pull request run counts: a fork's
    runs-on takes Blacksmith first whoever re-runs it, and a push or dispatch
    would need a branch-head read this rule does not spend.
    """
    head = (run.get("head_repository") or {}).get("id")
    if (run.get("path") != rescue.CMUX_NEXT_WORKFLOW_PATH or run.get("event") != "pull_request"
            or head is None or head != (run.get("repository") or {}).get("id")
            or job.get("name") not in CASCADE_JOB_NAMES):
        return None
    return next((str(label) for label in job.get("labels") or () if BLACKSMITH_MACOS_LABEL.fullmatch(str(label))),
                None)


def _unclaimed_scope(run: Mapping[str, Any]) -> bool:
    return (run.get("status") in IN_FLIGHT_RUN_STATUSES and run.get("event") in UNCLAIMED_EVENTS
            and protected_reason(run) is None)


def find_unclaimed(
    runs: Sequence[Mapping[str, Any]],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
    *,
    now: dt.datetime,
    lost: Mapping[int, Any] | None = None,
    evidence_jobs: Mapping[int, Sequence[Mapping[str, Any]]] | None = None,
    blacksmith_legs: bool = False,
) -> dict[int, UnclaimedJob]:
    """Run id -> its longest-waiting unclaimed leg, for in-flight runs category e does not already hold.

    A leg is unclaimed when it is unassigned(), asks for an owned label
    (owned_pool_rescue.job_pool(): another Blacksmith leg's re-run would rejoin
    the same label) and could have run (lost_wait_start()) for longer than
    unclaimed_bound(). With `blacksmith_legs` (owned pools on, so cmux-next's
    placement names an owned side label), a cmux-next leg on a Blacksmith macOS
    label (blacksmith_leg()) counts too, past BLACKSMITH_LEG_SECONDS. As in
    category e, a run with any other unfinished job that is not unclaimed
    itself is left alone (_gated()).
    """
    p90 = pool_wait_p90(jobs_by_run, evidence_jobs)
    held = set(lost or ())
    found_by_run: dict[int, UnclaimedJob] = {}
    for run in runs:
        if not _unclaimed_scope(run):
            continue
        run_jobs = jobs_by_run.get(run["id"]) or ()
        found: list[tuple[Mapping[str, Any], UnclaimedJob]] = []
        for job in run_jobs:
            pool = rescue.job_pool(job)
            blacksmith = None if pool or not blacksmith_legs else blacksmith_leg(run, job)
            # A run category e holds is judged here only for a Blacksmith leg, in case e leaves it (a bot's
            # attempt): no other rule moves that leg.
            if not (pool or blacksmith) or not unassigned(job) or (run["id"] in held and not blacksmith):
                continue
            since = lost_wait_start(job, run_jobs)
            bound = BLACKSMITH_LEG_SECONDS if blacksmith else unclaimed_bound(str(pool), p90)
            if since is not None and (now - since).total_seconds() > bound:
                found.append((job, UnclaimedJob(str(job.get("name") or ""), str(pool or blacksmith), since, bound,
                                                blacksmith=bool(blacksmith))))
        if found and not _gated(run_jobs, [job for job, _ in found]):
            found_by_run[run["id"]] = min((item for _, item in found), key=lambda item: item.queued_since)
    return found_by_run


def classify_unclaimed(
    run: Mapping[str, Any],
    run_jobs: Sequence[Mapping[str, Any]],
    leg: UnclaimedJob,
    prs: Sequence[Mapping[str, Any]] | None,
    *,
    now: dt.datetime,
    rerun_state: bool,
    newer: Mapping[str, Any] | None = None,
    branch_head: str | None = None,
    app_rerun: bool = False,
) -> LostVerdict | None:
    """What category f does with a run holding an unclaimed leg, or None to leave it to the other categories.

    A Blacksmith leg (blacksmith_leg()) is moved only while this sweep holds an
    App's token (`app_rerun`), and its re-run is made only with one
    (Candidate.app_actor); a bot's attempt is no reason to skip it, since no
    rescue watches a Blacksmith leg, but past owned_pool_rescue.
    REFUSAL_RESCUE_ATTEMPT it is left alone, so the janitor adds one attempt
    to the rescue's ladder at most.

    Only a run at a live head is touched (lost_pr_state() "current"): one at
    the head of an open pull request, or a push or dispatch at its branch's
    head. Without evidence that the pool skipped the leg, a stale or unknown
    run is left to category b and the orphan pass (None, so it is not even
    listed). A current run is cancelled for a later
    sweep's re-run of its failed jobs, as in category e, unless that re-run
    would keep the leg on the owned label (owned_pool_rescue.
    bot_rerun_leaves_owned(): owned_pool_rescue.py's watch owns those runs),
    the attempt is a bot's re-run, the run already failed, a newer run at its
    head took over, there is no re-run state, or the pull request opted out.
    """
    if prs is None:
        return None
    state, pr, why = lost_pr_state(run, prs, branch_head)
    bound = ("the cascade's stall wait" if leg.blacksmith else "45m, or the pool's p90 wait when longer")
    evidence = (f"unclaimed leg: `{leg.job_name}` queued {format_age(now - leg.queued_since)} with no runner on "
                f"`{leg.pool}`, past its {format_age(dt.timedelta(seconds=leg.bound_seconds))} bound ({bound})")
    if state != "current":
        return None
    if pr is not None and JANITOR_OPT_OUT_LABEL in pr_labels(pr):
        return LostVerdict("skip", evidence, f"PR #{pr.get('number')} is labelled `{JANITOR_OPT_OUT_LABEL}`", pr=pr)
    if pr is not None and not labels_complete(pr):
        return LostVerdict("skip", evidence, f"PR #{pr.get('number')} has more labels than were read", pr=pr)
    attempt = int(run.get("run_attempt") or 1)
    if leg.blacksmith:
        if attempt > rescue.REFUSAL_RESCUE_ATTEMPT:
            return LostVerdict("skip", f"{evidence}; {why}", f"attempt {attempt} is past the rescue's ladder", pr=pr)
        if not app_rerun:
            return LostVerdict("skip", f"{evidence}; {why}", "no App token this sweep: a GITHUB_TOKEN re-run would "
                                                             "take attempt 1's Blacksmith placement again", pr=pr)
    elif bot_rerun(run):
        return LostVerdict("skip", f"{evidence}; {why}", f"attempt {attempt} is a bot's re-run, left to the "
                                                         "owned-pool rescue and the orphan pass", pr=pr)
    elif not rescue.bot_rerun_leaves_owned(str(run.get("path") or ""), attempt):
        return LostVerdict("skip", f"{evidence}; {why}", f"a re-run of attempt {attempt} would stay on the owned "
                                                         "label; left to the owned-pool rescue", pr=pr)
    if any(job.get("status") == "completed" and job.get("conclusion") == "failure" for job in run_jobs):
        return LostVerdict("skip", f"{evidence}; {why}", "the run already failed, so a re-run of its failed jobs "
                                                         "would repeat that failure", pr=pr)
    if newer is not None:
        return LostVerdict("skip", f"{evidence}; {why}", f"newer run {newer.get('id')} at its head took over", pr=pr)
    if not rerun_state:
        return LostVerdict("skip", f"{evidence}; {why}", "no re-run state to carry the re-run to a later sweep", pr=pr)
    off = "the Blacksmith label, by an App," if leg.blacksmith else "the owned label"
    return LostVerdict("cancel", f"{evidence}; {why}: its failed jobs are re-run off {off} once the "
                                 "cancel settles", rerun=True, pr=pr)


def branch_head_lookups(runs: Iterable[Mapping[str, Any]], run_ids: Iterable[int], *,
                        prs_by_branch: Mapping[str, Sequence[Mapping[str, Any]]] | None = None,
                        known: Iterable[str] = (), cap: int = CANDIDATE_HEAD_LOOKUPS,
                        jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]] | None = None,
                        unclaimed: Iterable[int] = ()) -> list[str]:
    """Branches whose head to read (one request each, at most `cap`): those of the push and dispatch runs
    named, oldest run first, unless an open pull request already has the run's head or the head is `known`.

    A read is spent only where it can change the outcome into a re-run: never for a bot's attempt, a run
    that already failed (in `jobs_by_run`), a branch whose open pull request opted out (`no-janitor`, or
    labels left unread), or a category-f run (`unclaimed`) whose re-run would stay on the owned label.
    """
    wanted = set(run_ids)
    in_f = set(unclaimed)
    seen = set(known)
    branches: list[str] = []
    for run in sorted(runs, key=lambda item: (str(item.get("created_at") or ""), int(item.get("id") or 0))):
        branch = str(run.get("head_branch") or "")
        if run.get("id") not in wanted or run.get("event") not in ("push", "workflow_dispatch") or not branch \
                or branch in seen or bot_rerun(run):
            continue
        if run.get("id") in in_f and not rescue.bot_rerun_leaves_owned(str(run.get("path") or ""),
                                                                       int(run.get("run_attempt") or 1)):
            continue
        if jobs_by_run is not None and any(job.get("status") == "completed" and job.get("conclusion") == "failure"
                                           for job in jobs_by_run.get(run.get("id")) or ()):
            continue
        prs = (prs_by_branch or {}).get(branch) or []
        if prs_by_branch is not None and lost_pr_state(run, prs)[0] == "current":
            continue
        if any(pr.get("state") == "OPEN" and (JANITOR_OPT_OUT_LABEL in pr_labels(pr) or not labels_complete(pr))
               for pr in prs):
            continue
        seen.add(branch)
        branches.append(branch)
    return branches[:max(0, cap)]


def _iso(moment: dt.datetime) -> str:
    return moment.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def new_lost_reruns(candidates: Iterable[Candidate], results: Mapping[int, str], *,
                    now: dt.datetime) -> list[dict[str, Any]]:
    """Pending re-run entries for this sweep's category-e cancels that took and asked for one."""
    entries = []
    for candidate in candidates:
        result = results.get(candidate.run["id"]) or ""
        if candidate.rerun and (result == "cancelled" or result.startswith("force-cancelled")):
            run = candidate.run
            entry = {"run_id": run["id"], "attempt": int(run.get("run_attempt") or 1),
                     "head_sha": str(run.get("head_sha") or ""), "branch": str(run.get("head_branch") or ""),
                     "cancelled_at": _iso(now)}
            if candidate.app_actor:
                entry["app_actor"] = True
            entries.append(entry)
    return entries


@dataclasses.dataclass(frozen=True)
class LostRerun:
    entry: Mapping[str, Any]
    action: str  # "rerun", "keep" (try again next sweep) or "drop"
    note: str = ""
    run: Mapping[str, Any] | None = None


def plan_lost_reruns(
    pending: Sequence[Mapping[str, Any]],
    runs_now: Mapping[int, Mapping[str, Any]],
    prs_by_branch: Mapping[str, Sequence[Mapping[str, Any]]],
    *,
    now: dt.datetime,
    head_runs: Mapping[int, Sequence[Mapping[str, Any]]],
    branch_heads: Mapping[str, str] | None = None,
    app_token: bool = True,
) -> list[LostRerun]:
    """Which pending category-e and category-f cancels to re-run now.

    Each entry names the run and the attempt the janitor cancelled. It is
    re-run (rerun-failed-jobs) once that attempt has completed as cancelled,
    while its pull request is still open at the run's head (lost_pr_state()).
    The "once" is the attempt: a re-run makes a new attempt, so an entry whose
    run moved past its attempt (the janitor's re-run, a person's, or
    owned_pool_rescue.py's) is dropped, and the new attempt, started by a bot,
    is never queued for another re-run (classify_lost()). An entry whose run
    a newer run at its head took over (newer_run_at_head() over `head_runs`,
    run id -> the runs listed at its workflow, event, branch and head) is
    dropped. A run not readable this sweep, a cancel not settled yet, or a
    branch or head not looked up is kept for the next sweep, until
    LOST_RERUN_TTL. A push or dispatch run is current at a live branch's
    head (`branch_heads`, lost_pr_state()); one whose branch head was not read
    is kept too. An entry that needs an App's re-run (`app_actor`, a
    Blacksmith leg) is kept while this sweep has none (`app_token`).
    """
    decisions: list[LostRerun] = []
    reruns = 0
    for entry in pending:
        run_id = entry.get("run_id") if isinstance(entry, Mapping) else None
        if not isinstance(run_id, int) or isinstance(run_id, bool):
            continue
        cancelled = parse_time(str(entry.get("cancelled_at") or ""))
        if cancelled is None or now - cancelled > LOST_RERUN_TTL:
            decisions.append(LostRerun(entry, "drop", "expired"))
            continue
        run = runs_now.get(run_id)
        if not run:
            decisions.append(LostRerun(entry, "keep", "run not readable this sweep"))
            continue
        attempt = int(run.get("run_attempt") or 0)
        if attempt != int(entry.get("attempt") or 0):
            decisions.append(LostRerun(entry, "drop", f"already re-run (now attempt {attempt})", run))
            continue
        if run.get("status") != "completed":
            decisions.append(LostRerun(entry, "keep", f"cancel not settled ({run.get('status')})", run))
            continue
        if run.get("conclusion") != "cancelled":
            decisions.append(LostRerun(entry, "drop", f"finished {run.get('conclusion')}", run))
            continue
        if run.get("head_sha") != entry.get("head_sha"):
            decisions.append(LostRerun(entry, "drop", "head changed", run))
            continue
        branch = str(entry.get("branch") or "")
        if branch not in prs_by_branch:
            decisions.append(LostRerun(entry, "keep", "pull request lookup missing", run))
            continue
        head = None if branch_heads is None else branch_heads.get(branch)
        state, pr, why = lost_pr_state(run, prs_by_branch[branch], head)
        if state != "current" and branch_heads is not None and branch not in branch_heads \
                and run.get("event") in ("push", "workflow_dispatch"):
            decisions.append(LostRerun(entry, "keep", "branch head not read", run))
            continue
        if state != "current":
            decisions.append(LostRerun(entry, "drop", f"not re-run: {why}", run))
            continue
        if pr is not None and (JANITOR_OPT_OUT_LABEL in pr_labels(pr) or not labels_complete(pr)):
            decisions.append(LostRerun(entry, "drop", f"not re-run: PR #{pr.get('number')} opted out", run))
            continue
        if run_id not in head_runs:
            decisions.append(LostRerun(entry, "keep", "runs at its head not listed", run))
            continue
        newer = newer_run_at_head(run, head_runs[run_id])
        if newer is not None:
            decisions.append(LostRerun(entry, "drop", f"not re-run: newer run {newer.get('id')} at its head "
                                                      "took over", run))
            continue
        if entry.get("app_actor") and not app_token:
            decisions.append(LostRerun(entry, "keep", "needs an App's re-run; this sweep has only GITHUB_TOKEN", run))
            continue
        if reruns >= LOST_RERUN_MAX:
            decisions.append(LostRerun(entry, "keep", f"re-run cap of {LOST_RERUN_MAX} reached", run))
            continue
        reruns += 1
        decisions.append(LostRerun(entry, "rerun", why, run))
    return decisions


@dataclasses.dataclass
class Decision:
    candidate: Candidate
    action: str  # "cancel" or "skip"
    note: str = ""


@dataclasses.dataclass
class Plan:
    queued_macos_jobs: int
    running_macos_jobs: int
    threshold: int
    decisions: list[Decision]
    queued_by_pool: Mapping[str, int] = dataclasses.field(default_factory=dict)

    @property
    def over_threshold(self) -> bool:
        return any(count > self.threshold for count in self.queued_by_pool.values())

    def to_cancel(self) -> list[Candidate]:
        return [d.candidate for d in self.decisions if d.action == "cancel"]


def pr_key(run: Mapping[str, Any]) -> tuple[str, str]:
    return (run_head_owner(run), str(run.get("head_branch") or ""))


def build_plan(
    runs: Sequence[Mapping[str, Any]],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
    prs_by_branch: Mapping[str, Sequence[Mapping[str, Any]]],
    *,
    threshold: int,
    max_cancels: int,
    pull_request_policy: str,
    now: dt.datetime,
    evidence_jobs: Mapping[int, Sequence[Mapping[str, Any]]] | None = None,
    lost: Mapping[int, LostJob] | None = None,
    rerun_state: bool = True,
    unclaimed: Mapping[int, UnclaimedJob] | None = None,
    branch_heads: Mapping[str, str] | None = None,
    app_rerun: bool = False,
) -> Plan:
    """Decide every category's candidates under the shared cap.

    Category e (lost, classify_lost()) is judged first, so a run holding a
    lost job is cancelled as one, never gated on a backed-up pool; a run it
    leaves alone still goes through classify(). `lost` defaults to
    find_lost() over `jobs_by_run` and `evidence_jobs`; `rerun_state` says
    whether a cancel at an open pull request's head can be carried to the
    sweep that re-runs it.

    Category f (unclaimed, classify_unclaimed()) is judged next for a run
    category e does not hold, the same way. `unclaimed` defaults to
    find_unclaimed(); `branch_heads` (branch -> head read this sweep, "" when
    gone) tells a live branch's push or dispatch run from a stale one.
    """
    if lost is None:
        lost = find_lost(runs, jobs_by_run, now=now, evidence_jobs=evidence_jobs)
    if unclaimed is None:
        unclaimed = find_unclaimed(runs, jobs_by_run, now=now, lost=lost, evidence_jobs=evidence_jobs)
    heads = branch_heads or {}
    usages = {run["id"]: macos_usage(jobs_by_run.get(run["id"], ())) for run in runs}
    queued = sum(u.queued for u in usages.values())
    running = sum(u.running for u in usages.values())
    queued_by_pool: dict[str, int] = {}
    for usage in usages.values():
        for pool, count in usage.queued_by_pool.items():
            queued_by_pool[pool] = queued_by_pool.get(pool, 0) + count

    candidates: list[Candidate] = []
    lost_skips: list[Decision] = []
    for run in runs:
        usage = usages[run["id"]]
        branch = str(run.get("head_branch") or "")
        lost_verdict = None
        held_category = "lost"
        # A cmux-next run holding a Blacksmith leg is re-run only by an App, whichever category cancels
        # it: a GITHUB_TOKEN re-run is github-actions[bot]'s, whose attempt 2 keeps attempt 1's placement.
        # No earlier snapshot's pending entry names a cmux-next run: none was listed before.
        app_actor = run.get("path") == rescue.CMUX_NEXT_WORKFLOW_PATH and any(
            unassigned(job) and any(BLACKSMITH_MACOS_LABEL.fullmatch(str(label)) for label in job.get("labels") or ())
            for job in jobs_by_run.get(run["id"], ()))
        if run["id"] in lost or run["id"] in unclaimed:
            # A newer run at its head, or a later CI run waiting to take over ci-status.
            newer = newer_run_at_head(run, runs) or next(
                (other for other in runs if newer_ci_run_waiting(run, [other])), None)
            branch_prs = prs_by_branch[branch] if branch in prs_by_branch else None
            if run["id"] in lost:
                lost_verdict = classify_lost(
                    run, jobs_by_run.get(run["id"], ()), lost[run["id"]], branch_prs, now=now,
                    rerun_state=rerun_state, newer=newer, branch_head=heads.get(branch))
            if run["id"] in unclaimed and (lost_verdict is None or lost_verdict.action != "cancel"):
                held_category = "unclaimed"
                lost_verdict = classify_unclaimed(
                    run, jobs_by_run.get(run["id"], ()), unclaimed[run["id"]], branch_prs, now=now,
                    rerun_state=rerun_state, newer=newer, branch_head=heads.get(branch), app_rerun=app_rerun)
            if (lost_verdict is not None and lost_verdict.action == "cancel" and lost_verdict.rerun
                    and app_actor and not app_rerun):
                lost_verdict = LostVerdict("skip", lost_verdict.reason, "no App token this sweep: a GITHUB_TOKEN "
                                           "re-run would take attempt 1's Blacksmith placement again",
                                           pr=lost_verdict.pr)
            if lost_verdict is not None and lost_verdict.action == "cancel":
                candidates.append(Candidate(run, held_category, lost_verdict.reason, usage, lost_verdict.pr,
                                            rerun=lost_verdict.rerun, app_actor=app_actor))
                continue
        pr = None
        if run.get("event") == "pull_request":
            pr = resolve_pull_request(run, prs_by_branch.get(branch, ()))
        verdict = classify(
            run, usage, pr,
            newer_ci_run_waiting=newer_ci_run_waiting(run, runs),
            pull_request_policy=pull_request_policy,
            now=now,
        )
        if verdict:
            candidates.append(Candidate(run, verdict[0], verdict[1], usage, pr))
        elif lost_verdict is not None:
            lost_skips.append(Decision(Candidate(run, held_category, lost_verdict.reason, usage, lost_verdict.pr),
                                       "skip", lost_verdict.note))

    initially_backed_up = {pool for pool, count in queued_by_pool.items() if count > threshold}

    def order(candidate: Candidate) -> tuple[int, int, str, int]:
        # Runs holding a backed-up pool take the shared cap first; a stale run on
        # an idle pool frees nothing anyone is waiting for.
        idle = not initially_backed_up.intersection(candidate.usage.held_by_pool)
        return (int(idle), CATEGORY_ORDER.index(candidate.category),
                str(candidate.run.get("created_at") or ""), candidate.run["id"])

    def needs_pressure(candidate: Candidate) -> bool:
        # A lost or unclaimed leg frees nothing but never runs either: pure dead
        # weight, on any pool (classify_lost() and classify_unclaimed() already
        # honoured no-janitor).
        if candidate.category in ("lost", "unclaimed"):
            return False
        # A re-run or a no-janitor label means someone wants this output.
        return candidate.category != "stale-pr" or deliberate(candidate)

    def deliberate(candidate: Candidate) -> bool:
        pr = candidate.pr or {}
        # An unread label page may hold no-janitor, so treat it as present.
        return ((candidate.run.get("run_attempt") or 1) > 1 or JANITOR_OPT_OUT_LABEL in pr_labels(pr)
                or not labels_complete(pr))

    candidates.sort(key=order)
    decisions: list[Decision] = []
    projected = dict(queued_by_pool)
    cancels = 0
    for candidate in candidates:
        backed_up = {pool for pool, count in projected.items() if count > threshold}
        # Nobody reads a merged, closed or superseded PR's results, so that run
        # is waste on any pool; every other category waits for a backed-up one.
        if needs_pressure(candidate):
            if not backed_up:
                busiest = max(projected.values(), default=0)
                decisions.append(Decision(
                    candidate, "skip", f"busiest pool projected at {busiest} queued, not over {threshold}"))
                continue
            if not backed_up.intersection(candidate.usage.held_by_pool):
                decisions.append(Decision(candidate, "skip", "its macOS jobs are on pools that are not backed up"))
                continue
        if cancels >= max_cancels:
            decisions.append(Decision(candidate, "skip", f"per-sweep cap of {max_cancels} reached"))
            continue
        decisions.append(Decision(candidate, "cancel"))
        cancels += 1
        # Each cancelled queued job leaves its pool's queue; each cancelled
        # running job frees a slot that the pool's next queued job takes.
        for pool, held in candidate.usage.held_by_pool.items():
            if pool in projected:
                projected[pool] = max(0, projected[pool] - held)
    return Plan(queued, running, threshold, decisions + lost_skips, queued_by_pool)


def branches_to_resolve(
    runs: Iterable[Mapping[str, Any]],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
) -> list[str]:
    """PR branches worth one GraphQL lookup: PR runs that hold macOS jobs."""
    branches = set()
    for run in runs:
        if run.get("event") != "pull_request" or protected_reason(run):
            continue
        if macos_usage(jobs_by_run.get(run["id"], ())).held and run.get("head_branch"):
            branches.add(str(run["head_branch"]))
    return sorted(branches)


PR_FIELDS = """
        number state headRefOid url
        headRepositoryOwner { login }
        labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
        files(first: 100) { pageInfo { hasNextPage } nodes { path } }
        timelineItems(last: 50, itemTypes: [LABELED_EVENT, UNLABELED_EVENT]) {
          nodes {
            __typename
            ... on LabeledEvent { createdAt label { name } }
            ... on UnlabeledEvent { createdAt label { name } }
          }
        }
"""


def graphql_query(owner: str, name: str, branches: Sequence[str]) -> tuple[str, dict[str, Any]]:
    """One query that resolves every branch to its recent pull requests."""
    variables: dict[str, Any] = {"owner": owner, "name": name}
    params = ["$owner: String!", "$name: String!"]
    fields = []
    for index, branch in enumerate(branches):
        variables[f"b{index}"] = branch
        params.append(f"$b{index}: String!")
        fields.append(
            f"    b{index}: pullRequests(headRefName: $b{index}, first: 5, "
            f"orderBy: {{field: CREATED_AT, direction: DESC}}) {{\n      nodes {{{PR_FIELDS}      }}\n    }}"
        )
    query = (
        f"query({', '.join(params)}) {{\n  repository(owner: $owner, name: $name) {{\n"
        + "\n".join(fields)
        + "\n  }\n}"
    )
    return query, variables


def parse_graphql_prs(response: Mapping[str, Any], branches: Sequence[str]) -> dict[str, list[dict[str, Any]]]:
    repository = ((response.get("data") or {}).get("repository")) or {}
    result: dict[str, list[dict[str, Any]]] = {}
    for index, branch in enumerate(branches):
        connection = repository.get(f"b{index}") or {}
        result[branch] = list(connection.get("nodes") or [])
    return result


def render_summary(plan: Plan, *, dry_run: bool, now: dt.datetime, results: Mapping[int, str] | None = None) -> str:
    results = results or {}
    mode = "dry run" if dry_run else "live"
    lines = [
        f"## CI queue janitor ({mode})",
        "",
        f"Queued macOS jobs: **{plan.queued_macos_jobs}** (threshold {plan.threshold} per pool); "
        f"running macOS jobs: {plan.running_macos_jobs}.",
        "",
    ]
    if plan.queued_by_pool:
        lines.append("Queued by pool: " + ", ".join(
            f"`{pool}` {count}" for pool, count in sorted(plan.queued_by_pool.items(), key=lambda item: -item[1])) + ".")
        lines.append("")
    if not plan.decisions:
        lines.append("No wasteful macOS demand found.")
        return "\n".join(lines) + "\n"
    if not plan.over_threshold:
        if plan.to_cancel():
            verb = "would be cancelled" if dry_run else "are cancelled"
            lines.append("No pool is over the threshold, so only runs for merged, closed or superseded "
                         f"pull requests, and runs holding a lost runner assignment or an unclaimed leg, {verb}. "
                         "Candidates seen:")
        else:
            lines.append("No pool is over the threshold, so nothing is cancelled. Candidates seen:")
        lines.append("")
    lines.append("| Decision | Run | Workflow | Reason | Queued age | macOS jobs (queued/running) |")
    lines.append("| --- | --- | --- | --- | --- | --- |")
    for decision in plan.decisions:
        run = decision.candidate.run
        usage = decision.candidate.usage
        if decision.action == "cancel":
            verb = results.get(run["id"]) or ("would cancel" if dry_run else "cancel")
        else:
            verb = f"keep ({decision.note})"
        age = format_age(now - usage.oldest_queued_at) if usage.oldest_queued_at else "-"
        url = run.get("html_url") or f"run {run.get('id')}"
        name = str(run.get("name") or run.get("path") or "").replace("|", "\\|")
        reason = f"({decision.candidate.category}) {decision.candidate.reason}".replace("|", "\\|")
        lines.append(f"| {verb} | {url} | {name} | {reason} | {age} | {usage.queued}/{usage.running} |")
    return "\n".join(lines) + "\n"


def render_lost_reruns(decisions: Sequence[LostRerun], *, dry_run: bool,
                       results: Mapping[int, str] | None = None) -> str:
    """The pending category-e re-runs this sweep looked at."""
    if not decisions:
        return ""
    results = results or {}
    lines = ["", "### Lost-assignment re-runs", "",
             "Runs cancelled for a lost runner assignment at an open pull request's head get their failed jobs "
             "re-run once, after the cancel settles.", "",
             "| Decision | Run | Attempt | Note |", "| --- | --- | --- | --- |"]
    for decision in decisions:
        run_id = decision.entry.get("run_id")
        if decision.action == "rerun":
            verb = results.get(run_id) or ("would re-run failed jobs" if dry_run else "re-run failed jobs")
        else:
            verb = "keep for the next sweep" if decision.action == "keep" else "drop"
        url = (decision.run or {}).get("html_url") or f"run {run_id}"
        note = decision.note.replace("|", "\\|")
        lines.append(f"| {verb.replace('|', '/')} | {url} | {decision.entry.get('attempt')} | {note} |")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# Orphaned runs
# ---------------------------------------------------------------------------
#
# GitHub (or Blacksmith behind it) sometimes loses a job's runner assignment:
# the job stays `queued` with no runner_name while its pool is idle, and the
# run never finishes. It burns nothing, but it can hold a concurrency group
# (ios-appstore-upload.yml's `ios-app-store-production`), and a stuck
# required job such as `ci-status` blocks its pull request forever. This is a
# separate category from the backlog policy above: it is not gated on a pool
# being backed up, has its own small cap, and reads only the runs and jobs the
# sweep already fetched.


def job_pool_key(job: Mapping[str, Any]) -> str:
    """Every label a job asked for: runners that can take it serve all of them."""
    return ",".join(sorted({str(label).lower() for label in job.get("labels") or ()}))


def never_assigned(job: Mapping[str, Any]) -> bool:
    # `waiting` (environment approval) and `pending` (concurrency) are
    # deliberate holds, not lost assignments.
    return job.get("status") == "queued" and not job.get("runner_name")


@dataclasses.dataclass(frozen=True)
class Orphan:
    run: Mapping[str, Any]
    evidence: str
    # None for a run that is itself stuck in `queued` without usable jobs.
    job_name: str | None = None
    queued_since: dt.datetime | None = None
    # Other jobs of the run still executing; the run waits for them.
    running_jobs: int = 0


def find_orphans(
    runs: Sequence[Mapping[str, Any]],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
    *,
    min_age: dt.timedelta,
    now: dt.datetime,
) -> list[Orphan]:
    """In-flight runs holding a job the runner scheduler lost.

    A job is orphaned when it has been `queued` with no runner for `min_age`
    and a job on exactly the same labels that was created after it has
    already been given a runner. A backed-up pool serves its queue roughly
    in order, so a newer job overtaking this one means the pool had capacity
    and skipped it; a merely backed-up pool leaves every newer job queued too
    and is never read as orphaned. Without that evidence (a pool that served
    nothing, or none of whose newer jobs are in this sweep's inventory), a
    job is only orphaned after GHOST_QUEUED_RUN_AGE, as is a run still in
    `queued` that long, whose jobs the sweep never lists (needs_jobs).
    """
    hard_age = max(GHOST_QUEUED_RUN_AGE, min_age)
    served: dict[str, list[dt.datetime]] = {}
    for jobs in jobs_by_run.values():
        for job in jobs:
            created = parse_time(job.get("created_at"))
            if job.get("runner_name") and created is not None:
                served.setdefault(job_pool_key(job), []).append(created)

    orphans: list[Orphan] = []
    for run in runs:
        if run.get("status") not in IN_FLIGHT_RUN_STATUSES:
            continue
        jobs = jobs_by_run.get(run["id"]) or ()
        running = sum(1 for job in jobs if job.get("status") in RUNNING_JOB_STATUSES)
        found: Orphan | None = None
        for job in jobs:
            if not never_assigned(job):
                continue
            queued_at = parse_time(job.get("created_at"))
            if queued_at is None or now - queued_at < min_age:
                continue
            pool = job_pool_key(job)
            age = format_age(now - queued_at)
            newer = sum(1 for created in served.get(pool, ()) if created > queued_at)
            if newer:
                evidence = (f"`{job.get('name')}` queued {age} with no runner while {newer} newer job(s) "
                            f"on `{pool}` got one")
            elif now - queued_at >= hard_age:
                evidence = f"`{job.get('name')}` queued {age} with no runner on `{pool}`"
            else:
                continue
            if found is None or (found.queued_since is not None and queued_at < found.queued_since):
                found = Orphan(run, evidence, str(job.get("name") or ""), queued_at, running)
        if found is not None:
            orphans.append(found)
            continue
        created = parse_time(run.get("created_at"))
        if run.get("status") == "queued" and created is not None and now - created >= hard_age and not running:
            orphans.append(Orphan(run, f"run still queued after {format_age(now - created)}", None, created, 0))
    return orphans


def orphan_protected_reason(run: Mapping[str, Any]) -> str | None:
    """Why an orphaned run is reported but left for a human.

    Narrower than protected_reason: an orphaned job never runs, so cancelling
    a main schedule, nightly or TestFlight upload only lets the next one
    start (ios-appstore-upload.yml does not count a cancelled run as an
    upload). A release that stopped halfway, or a merge-queue check, is not
    the janitor's to end.
    """
    event = run.get("event") or ""
    branch = run.get("head_branch") or ""
    if event in ORPHAN_PROTECTED_EVENTS:
        return f"{event} event"
    if TAG_LIKE_REF.match(branch):
        return f"tag-like ref {branch}"
    # Match the workflow path only, as RESERVED_POOL_WORKFLOW does: ci.yml's
    # run name carries `release=arm64`, which kept an orphaned main dispatch
    # holding CI's concurrency group (and every later main run pending).
    if ORPHAN_PROTECTED_WORKFLOW.search(str(run.get("path") or "")):
        return "release/publish workflow"
    if event == "push" and branch in PROTECTED_PUSH_BRANCHES - {"main"}:
        # Listed since follows_another_copy(): a feat-cmux-next push gates the nightly-next build,
        # which is cancelled only when stuck past its timeout (ci.yml's main pushes are listed as before).
        return f"push to {branch}"
    return None


PULL_REQUEST_EVENTS = ("pull_request", "pull_request_target")


def left_to_github(orphan: Orphan, now: dt.datetime) -> bool:
    """A ghost past GHOST_GIVE_UP_AGE that no human was asked to look at."""
    return (orphan.job_name is None and orphan.queued_since is not None
            and now - orphan.queued_since >= GHOST_GIVE_UP_AGE and orphan_protected_reason(orphan.run) is None)


def orphan_branches(orphans: Iterable[Orphan], now: dt.datetime) -> list[str]:
    """PR branches whose `no-janitor` label the orphan plan needs."""
    return sorted({str(o.run["head_branch"]) for o in orphans
                   if o.run.get("event") in PULL_REQUEST_EVENTS and o.run.get("head_branch")
                   and not left_to_github(o, now)})


@dataclasses.dataclass
class OrphanDecision:
    orphan: Orphan
    action: str  # "cancel", "skip" or "github-side" (past GHOST_GIVE_UP_AGE)
    note: str = ""


def build_orphan_plan(
    orphans: Sequence[Orphan],
    prs_by_branch: Mapping[str, Sequence[Mapping[str, Any]]],
    *,
    max_cancels: int,
    exclude_ids: set[int],
    now: dt.datetime,
) -> list[OrphanDecision]:
    """Which orphans to cancel this sweep, under their own cap.

    Lost assignments go first, oldest first: they are the ones holding a
    pull request's required check or a concurrency group today. Runs stuck in
    `queued` for days follow, in an order that rotates every sweep, so a run
    GitHub refuses to cancel cannot hold the cap forever. Past
    GHOST_GIVE_UP_AGE a ghost is left to GitHub and never tried again,
    unless it is protected: that row stays for the human it names.
    """
    lost = sorted((o for o in orphans if o.job_name is not None and o.run["id"] not in exclude_ids),
                  key=lambda o: (o.queued_since or now, o.run["id"]))
    ghosts = sorted((o for o in orphans if o.job_name is None and o.run["id"] not in exclude_ids),
                    key=lambda o: o.run["id"])
    decisions: list[OrphanDecision] = []
    retry: list[Orphan] = []
    for ghost in ghosts:
        if left_to_github(ghost, now):
            decisions.append(OrphanDecision(ghost, "github-side"))
        else:
            retry.append(ghost)
    ghosts = retry
    if ghosts:
        offset = int(now.timestamp() // 600) % len(ghosts)
        ghosts = ghosts[offset:] + ghosts[:offset]

    cancels = 0
    for orphan in lost + ghosts:
        run = orphan.run
        protected = orphan_protected_reason(run)
        if protected:
            decisions.append(OrphanDecision(orphan, "skip", f"{protected}; left for a human"))
            continue
        if orphan.running_jobs:
            # Siblings still running are output someone may read, and
            # force-cancel would skip their cleanup. The run is still an
            # orphan once they finish.
            decisions.append(OrphanDecision(orphan, "skip", f"{orphan.running_jobs} other job(s) still running"))
            continue
        if run.get("event") in PULL_REQUEST_EVENTS:
            pr = resolve_pull_request(run, prs_by_branch.get(str(run.get("head_branch") or ""), ()))
            if pr is not None and JANITOR_OPT_OUT_LABEL in pr_labels(pr):
                decisions.append(OrphanDecision(orphan, "skip", f"PR #{pr.get('number')} is labelled "
                                                f"`{JANITOR_OPT_OUT_LABEL}`"))
                continue
        if cancels >= max_cancels:
            decisions.append(OrphanDecision(orphan, "skip", f"orphan cap of {max_cancels} reached"))
            continue
        decisions.append(OrphanDecision(orphan, "cancel"))
        cancels += 1
    return decisions


def _cancel_refused(error: RuntimeError) -> bool:
    """Whether GitHub rejected a cancellation because the run cannot be cancelled."""
    return "(409)" in str(error)


def _force_cancel(github: "GitHub", orphan: Orphan, why: str) -> str:
    try:
        github.force_cancel(orphan.run["id"])
    except RuntimeError as error:
        return f"stuck: GitHub refused cancel and force-cancel ({why}; {error})"
    return f"force-cancelled ({why})"


def cancel_plan(
    github: "GitHub",
    candidates: Sequence[Candidate],
) -> tuple[dict[int, str], int]:
    """Cancel planned runs, treating GitHub's uncancellable-run race as benign."""
    results: dict[int, str] = {}
    failures = 0
    for candidate in candidates:
        run_id = candidate.run["id"]
        try:
            # The inventory is seconds old; drop anything that finished, moved
            # to a new head or was re-run (a new attempt) in between.
            current = github.run(run_id)
            if current.get("status") not in IN_FLIGHT_RUN_STATUSES:
                results[run_id] = f"skipped (now {current.get('status')})"
                continue
            if current.get("head_sha") != candidate.run.get("head_sha"):
                results[run_id] = "skipped (head changed)"
                continue
            if int(current.get("run_attempt") or 1) != int(candidate.run.get("run_attempt") or 1):
                results[run_id] = f"skipped (now attempt {current.get('run_attempt')})"
                continue
        except RuntimeError as error:
            failures += 1
            results[run_id] = f"failed: {error}"
            continue
        try:
            github.cancel(run_id)
            results[run_id] = "cancelled"
        except RuntimeError as error:
            if not _cancel_refused(error):
                failures += 1
                results[run_id] = f"failed: {error}"
                continue
            try:
                github.force_cancel(run_id)
            except RuntimeError as force_error:
                if not _cancel_refused(force_error):
                    failures += 1
                    results[run_id] = f"failed: {force_error}"
                else:
                    results[run_id] = (f"stuck: GitHub refused cancel and force-cancel "
                                       f"(cancel refused: {error}; {force_error})")
            else:
                results[run_id] = f"force-cancelled (cancel refused: {error})"
    return results, failures


def cancel_orphans(
    github: "GitHub",
    decisions: Sequence[OrphanDecision],
    *,
    sleep: Any = None,
    recheck_seconds: float = ORPHAN_RECHECK_SECONDS,
) -> tuple[dict[int, str], int]:
    """Cancel, then force-cancel what a normal cancel leaves in flight.

    GitHub documents force-cancel for runs that do not respond to cancel,
    which is how orphaned runs often behave. A run GitHub will not end either
    way (ios-testflight.yml has met these) is reported, not counted as a
    failure: nothing the next sweep does differently would change that.
    """
    results: dict[int, str] = {}
    failures = 0
    pending: list[Orphan] = []
    for decision in decisions:
        if decision.action != "cancel":
            continue
        orphan = decision.orphan
        run_id = orphan.run["id"]
        try:
            current = github.run(run_id)
            if current.get("status") not in IN_FLIGHT_RUN_STATUSES:
                results[run_id] = f"skipped (now {current.get('status')})"
                continue
        except RuntimeError as error:
            failures += 1
            results[run_id] = f"failed: {error}"
            continue
        try:
            github.cancel(run_id)
        except RuntimeError as error:
            results[run_id] = _force_cancel(github, orphan, f"cancel refused: {error}")
            continue
        pending.append(orphan)
    if pending:
        (sleep or time.sleep)(recheck_seconds)
    for orphan in pending:
        run_id = orphan.run["id"]
        try:
            status = github.run(run_id).get("status")
        except RuntimeError as error:
            failures += 1
            results[run_id] = f"failed: {error}"
            continue
        if status not in IN_FLIGHT_RUN_STATUSES:
            results[run_id] = "cancelled"
        else:
            results[run_id] = _force_cancel(github, orphan, f"cancel left it {status}")
    return results, failures


def render_orphan_summary(
    decisions: Sequence[OrphanDecision],
    *,
    dry_run: bool,
    now: dt.datetime,
    min_age: dt.timedelta,
    results: Mapping[int, str] | None = None,
) -> str:
    results = results or {}
    lines = [
        "",
        "### Orphaned runs",
        "",
        f"A job queued with no runner for {format_age(min_age)} while a newer job on its pool got one, or "
        f"anything still queued after {format_age(max(GHOST_QUEUED_RUN_AGE, min_age))}. Cancelled whatever the "
        "queue length, under their own cap.",
        "",
    ]
    if not decisions:
        lines.append("No orphaned runs found.")
        return "\n".join(lines) + "\n"
    given_up = [d for d in decisions if d.action == "github-side"]
    decisions = [d for d in decisions if d.action != "github-side"]
    if given_up:
        oldest = min(d.orphan.queued_since for d in given_up if d.orphan.queued_since)
        lines.append(f"{len(given_up)} run(s) still queued after {format_age(GHOST_GIVE_UP_AGE)} are left to "
                     f"GitHub, which refuses to cancel them; oldest queued {format_age(now - oldest)}.")
        lines.append("")
    if not decisions:
        return "\n".join(lines) + "\n"
    lines.append("| Decision | Run | Workflow | Evidence | Queued age |")
    lines.append("| --- | --- | --- | --- | --- |")
    for decision in decisions:
        run = decision.orphan.run
        if decision.action == "cancel":
            verb = results.get(run["id"]) or ("would cancel" if dry_run else "cancel")
        else:
            verb = f"keep ({decision.note})"
        since = decision.orphan.queued_since
        age = format_age(now - since) if since else "-"
        url = run.get("html_url") or f"run {run.get('id')}"
        name = str(run.get("name") or run.get("path") or "").replace("|", "\\|")
        evidence = decision.orphan.evidence.replace("|", "\\|")
        lines.append(f"| {verb.replace('|', '/')} | {url} | {name} | {evidence} | {age} |")
    return "\n".join(lines) + "\n"


# ---------------------------------------------------------------------------
# GitHub I/O
# ---------------------------------------------------------------------------


RATE_LIMIT_HEADERS = {
    "limit": "X-RateLimit-Limit",
    "remaining": "X-RateLimit-Remaining",
    "used": "X-RateLimit-Used",
    "reset": "X-RateLimit-Reset",
}


def read_rate_limit(headers: Any) -> tuple[str, dict[str, int]] | None:
    """(resource, {limit, remaining, used, reset}) from a response's rate limit headers, or None.

    Every workflow in the repository spends the same GITHUB_TOKEN
    installation budget. On 2026-10-06 that budget ran out, and the required
    CLA and migration checks failed on every pull request.
    """
    if headers is None:
        return None
    values: dict[str, int] = {}
    for key, name in RATE_LIMIT_HEADERS.items():
        raw = headers.get(name)
        if raw is None:
            continue
        try:
            values[key] = int(raw)
        except (TypeError, ValueError):
            continue
    if "remaining" not in values:
        return None
    return str(headers.get("X-RateLimit-Resource") or "core"), values


def render_rate_limits(limits: Mapping[str, Mapping[str, int]]) -> str:
    """The API budget left after the sweep's last request, per resource, to measure what sweeps cost."""
    if not limits:
        return "GitHub API budget: no rate limit headers seen."
    parts = []
    for resource, values in sorted(limits.items()):
        text = f"{resource} {values['remaining']}"
        if "limit" in values:
            text += f" of {values['limit']}"
        text += " left"
        if "used" in values:
            text += f", {values['used']} used"
        if "reset" in values:
            text += f", resets {dt.datetime.fromtimestamp(values['reset'], UTC).strftime('%H:%M:%SZ')}"
        parts.append(text)
    return "GitHub API budget after this sweep's last request: " + "; ".join(parts) + "."


def rate_limited(error: urllib.error.HTTPError) -> bool:
    """Whether a refusal is GitHub's rate limit (primary or secondary), not a permission refusal."""
    headers = error.headers
    if headers is not None and (headers.get("X-RateLimit-Remaining") == "0" or headers.get("Retry-After")):
        return True
    try:
        body = error.read() or b""
    except Exception:  # noqa: BLE001 - an unreadable body is not a rate limit
        body = b""
    return b"rate limit" in body.lower()


class RateLimited(RuntimeError):
    """The token is out of budget: the sweep stops (GitHub.request())."""


class GitHub:
    """The Actions and GraphQL APIs. `token` is an App's when one was minted (its own budget, not
    the GITHUB_TOKEN budget every workflow shares); `fallback_token` is the workflow's, which takes
    over for the rest of the sweep once the App's is refused (401 or 403: expired or not permitted).
    A cancel is idempotent, so the refused request is simply made again. An App out of budget (a
    rate-limit 403 or 429) ends the sweep instead: moving its ~500 calls onto the shared
    GITHUB_TOKEN emptied that budget too, and the nightly's publish then failed (2026-10-25)."""

    def __init__(self, token: str, repo: str, fallback_token: str = "") -> None:
        self.repo = repo
        self._token = token
        self.calls = 0
        self.fallback_token = fallback_token if fallback_token != token else ""
        # An App's token is in use: one was minted beside the workflow's, and it was not refused yet.
        self.app_token = bool(self.fallback_token)
        # Rate limit resource ("core", "graphql") -> the newest response's values.
        self.rate_limits: dict[str, dict[str, int]] = {}
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-queue-janitor",
        }

    def request(self, method: str, path: str, body: Any | None = None, *, app_only: bool = False) -> Any:
        """One API call. A read (GET, or a GraphQL query) that meets a 5xx or a dropped connection is
        made again after each RETRY_DELAYS delay; a write is not, since it may have taken effect."""
        retry = method == "GET" or path == "/graphql"
        for delay in (*RETRY_DELAYS, None):
            try:
                return self._request(method, path, body, app_only=app_only)
            except _Transient as error:
                if not retry or delay is None:
                    raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error})") from error.__cause__
                print(f"queue-janitor: {method} {path.split('?')[0]} failed ({error}); again in {delay:.0f} s",
                      file=sys.stderr)
                time.sleep(delay)
        raise AssertionError("unreachable")

    def _request(self, method: str, path: str, body: Any | None = None, *, app_only: bool = False) -> Any:
        self.calls += 1
        data = json.dumps(body).encode() if body is not None else None
        headers = dict(self.headers)
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(API + path, data=data, headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                self.note_rate_limit(response.headers)
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            self.note_rate_limit(error.headers)
            if error.code in (403, 429) and rate_limited(error):
                raise RateLimited(f"{method} {path.split('?')[0]} failed ({error.code}: rate limit; "
                                   "the sweep stops rather than spend the workflow token)") from error
            if error.code in (401, 403) and self.fallback_token and not app_only:
                print(f"queue-janitor: App token refused ({error.code}) on {path.split('?')[0]}; "
                      "using the workflow token for the rest of the sweep", file=sys.stderr)
                self.headers["Authorization"] = f"Bearer {self.fallback_token}"
                # The snapshot download (download()) uses the same token.
                self._token = self.fallback_token
                self.fallback_token = ""
                self.app_token = False
                return self.request(method, path, body)
            if error.code in RETRY_STATUSES:
                raise _Transient(str(error.code)) from error
            raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.code})") from error
        except urllib.error.URLError as error:
            raise _Transient(str(error.reason)) from error
        except (http.client.HTTPException, OSError) as error:
            # A dropped or truncated response, opening it or reading it: IncompleteRead, BadStatusLine,
            # RemoteDisconnected, a reset or a timeout.
            raise _Transient(repr(error)) from error

    def note_rate_limit(self, headers: Any) -> None:
        found = read_rate_limit(headers)
        if found:
            self.rate_limits[found[0]] = found[1]

    def in_flight_runs(self) -> list[dict[str, Any]]:
        """Every run in IN_FLIGHT_RUN_STATUSES, up to MAX_RUN_PAGES pages a status.

        A status-filtered listing can return a short page before its last one: `status=queued` answered
        99 runs on page 1 and 85 on page 2 of a total_count of 182 at 06:10Z on 2026-10-26. Stopping at the first short page dropped every queued run older than page 1, so the
        snapshot's oldest wait on blacksmith-12vcpu-macos-26 read 24 minutes while run 40259152940's fast
        tier had waited 205, and the janitor never cancelled that run after PR #24021 landed. So only an
        empty page ends a status before MAX_RUN_PAGES: neither a short page nor total_count, which a page
        repeating rows or a listing that shifts between pages would satisfy early. Runs keyed by id drop
        the repeats; a run a shift moves past a page boundary is read on the next sweep.
        """
        runs: dict[int, dict[str, Any]] = {}
        for status in IN_FLIGHT_RUN_STATUSES:
            for page in range(1, MAX_RUN_PAGES + 1):
                query = urllib.parse.urlencode({"status": status, "per_page": 100, "page": page})
                payload = self.request("GET", f"/repos/{self.repo}/actions/runs?{query}")
                batch = payload.get("workflow_runs") or []
                for run in batch:
                    runs[run["id"]] = run
                if not batch:
                    break
        return list(runs.values())

    def artifact_names(self, run_id: int, *, stop: str) -> list[str]:
        """The run's artifact names, page by page until one starts with `stop`."""
        names: list[str] = []
        for page in range(1, MAX_ARTIFACT_PAGES + 1):
            query = urllib.parse.urlencode({"per_page": 100, "page": page})
            payload = self.request("GET", f"/repos/{self.repo}/actions/runs/{run_id}/artifacts?{query}")
            batch = [str(item.get("name") or "") for item in payload.get("artifacts") or []]
            names.extend(batch)
            if len(batch) < 100 or any(name.startswith(stop) for name in batch):
                break
        return names

    def jobs(self, run_id: int) -> list[dict[str, Any]]:
        jobs: list[dict[str, Any]] = []
        for page in range(1, MAX_JOB_PAGES + 1):
            query = urllib.parse.urlencode({"filter": "latest", "per_page": 100, "page": page})
            payload = self.request("GET", f"/repos/{self.repo}/actions/runs/{run_id}/jobs?{query}")
            batch = payload.get("jobs") or []
            jobs.extend(batch)
            if len(batch) < 100:
                break
        return jobs

    def pull_requests(self, branches: Sequence[str]) -> dict[str, list[dict[str, Any]]]:
        owner, name = self.repo.split("/", 1)
        result: dict[str, list[dict[str, Any]]] = {}
        for start in range(0, len(branches), GRAPHQL_BATCH):
            chunk = list(branches[start:start + GRAPHQL_BATCH])
            query, variables = graphql_query(owner, name, chunk)
            response = self.request("POST", "/graphql", {"query": query, "variables": variables})
            if response.get("errors"):
                raise RuntimeError(f"GraphQL errors: {response['errors'][:1]}")
            result.update(parse_graphql_prs(response, chunk))
        return result

    def run(self, run_id: int) -> dict[str, Any]:
        return self.request("GET", f"/repos/{self.repo}/actions/runs/{run_id}")

    def branch_head(self, branch: str) -> str:
        """The branch's head commit, or "" when the branch is gone (404). Raises RuntimeError otherwise."""
        try:
            payload = self.request("GET", f"/repos/{self.repo}/branches/{urllib.parse.quote(branch, safe='')}")
        except RuntimeError as error:
            if "(404)" in str(error):
                return ""
            raise
        return str(((payload or {}).get("commit") or {}).get("sha") or "")

    def cancel(self, run_id: int) -> None:
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/cancel")

    def force_cancel(self, run_id: int) -> None:
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/force-cancel")

    def rerun_failed(self, run_id: int, *, app_only: bool = False) -> None:
        """Re-run the run's failed and cancelled jobs; `app_only` never retries it on the workflow's token."""
        if app_only and not self.app_token:
            raise RuntimeError(f"run {run_id} needs an App's re-run; this sweep has only GITHUB_TOKEN")
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/rerun-failed-jobs", app_only=app_only)

    def request_ui_tests(self, run: Mapping[str, Any], attempt: int) -> None:
        """Start ci-ui-tests.yml for the attempt a re-run of a pull request's CI began.

        This token's re-run may emit no workflow_run event, and that attempt's
        ui-tests job waits for ci-ui-tests.yml (ui_tests_dispatch.rerun_dispatch(),
        as owned_pool_rescue.py and classify_failures.py do). Best effort: a
        failure is a warning, never a failed sweep.
        """
        if run.get("path") != CI_WORKFLOW_PATH or run.get("event") != "pull_request":
            return
        try:
            path, body = ui_tests_dispatch.rerun_dispatch(run["id"], attempt)
            self.request("POST", f"/repos/{self.repo}/{path}", body)
        except Exception as error:  # noqa: BLE001 a best-effort dispatch never fails the sweep
            print(f"::warning::could not start {ui_tests_dispatch.DISPATCH_WORKFLOW_FILE} for run {run['id']}: "
                  f"{error}", file=sys.stderr)

    def runs_at_head(self, run: Mapping[str, Any]) -> list[dict[str, Any]]:
        """One page of the runs of `run`'s workflow at its branch, event and head (newer_run_at_head())."""
        workflow = str(run.get("path") or "").rsplit("/", 1)[-1]
        query = urllib.parse.urlencode({"branch": run.get("head_branch") or "", "event": run.get("event") or "",
                                        "head_sha": run.get("head_sha") or "", "per_page": 20})
        payload = self.request("GET", f"/repos/{self.repo}/actions/workflows/{urllib.parse.quote(workflow)}/runs?{query}")
        return [other for other in payload.get("workflow_runs") or [] if isinstance(other, Mapping)]

    def completed_runs(self, workflow: str, since: str) -> list[dict[str, Any]]:
        """One page of `workflow`'s completed runs created at or after `since`, newest first."""
        query = urllib.parse.urlencode({"status": "completed", "created": f">={since}",
                                        "per_page": LOST_EVIDENCE_LISTING})
        payload = self.request("GET", f"/repos/{self.repo}/actions/workflows/{urllib.parse.quote(workflow)}/runs?{query}")
        return [run for run in payload.get("workflow_runs") or [] if isinstance(run, Mapping)]

    def snapshot_artifacts(self) -> list[dict[str, Any]]:
        """The newest `macos-pool-load` artifacts (the listing by name; the unfiltered one answers 500)."""
        payload = self.request("GET", f"/repos/{self.repo}/actions/artifacts?name={SNAPSHOT_ARTIFACT}&per_page=20")
        return [artifact for artifact in payload.get("artifacts") or [] if isinstance(artifact, Mapping)]

    def download(self, artifact: Mapping[str, Any]) -> bytes:
        """One artifact's zip archive, through pr_runner_pool.py's redirect-safe download."""
        self.calls += 1
        try:
            return PoolClient(self._token, self.repo).download(artifact)
        except OSError as error:  # urllib's HTTPError and URLError
            raise RuntimeError(f"artifact download failed ({error})") from error


def previous_lost_reruns(github: GitHub) -> list[dict[str, Any]]:
    """The pending category-e re-runs the newest janitor snapshot that has them carried.

    Read from the `macos-pool-load` artifact every sweep already uploads (the
    same trusted main-branch copies pr_runner_pool.py reads), so the state
    lives where GitHub keeps it and needs no new storage. A snapshot whose
    sweep failed before writing LOST_RERUNS_KEY is passed over for the one
    before it (at most LOST_PREVIOUS_SNAPSHOTS). An entry read twice is
    harmless: plan_lost_reruns() re-checks its run's attempt. Raises
    RuntimeError when a request fails, so the caller knows the state is
    unknown rather than empty.
    """
    trusted = sorted((artifact for artifact in github.snapshot_artifacts()
                      if trusted_snapshot_artifact(artifact, SNAPSHOT_BRANCH)),
                     key=lambda artifact: str(artifact.get("created_at") or ""), reverse=True)
    for artifact in trusted[:LOST_PREVIOUS_SNAPSHOTS]:
        blob = github.download(artifact)
        try:
            document = json.loads(zipfile.ZipFile(io.BytesIO(blob)).read(SNAPSHOT_FILE))
        except SNAPSHOT_UNREADABLE:
            continue
        entries = document.get(LOST_RERUNS_KEY) if isinstance(document, Mapping) else None
        if isinstance(entries, list):
            return [dict(entry) for entry in entries if isinstance(entry, Mapping)][-LOST_PENDING_MAX:]
    return []


def rerun_lost(github: GitHub, decisions: Sequence[LostRerun]) -> tuple[list[dict[str, Any]], dict[int, str], int]:
    """POST rerun-failed-jobs for each `rerun` decision. Returns (entries still pending, results, failures).

    A re-run GitHub refused stays pending: if it took after all, the next
    sweep sees the new attempt and drops it, so it can never run twice. A
    pull request's CI re-run also starts ci-ui-tests.yml for its new attempt
    (GitHub.request_ui_tests()).
    """
    pending = [dict(decision.entry) for decision in decisions if decision.action == "keep"]
    results: dict[int, str] = {}
    failures = 0
    for decision in decisions:
        if decision.action != "rerun":
            continue
        run_id = int(decision.entry["run_id"])
        try:
            github.rerun_failed(run_id, app_only=bool(decision.entry.get("app_actor")))
            results[run_id] = "re-ran failed jobs"
        except Exception as error:  # noqa: BLE001 one failed re-run never drops the other entries
            failures += 1
            results[run_id] = f"failed: {error!r}"
            pending.append(dict(decision.entry))
            continue
        # The attempt the re-run began: a read right after it may still show the old one.
        github.request_ui_tests(decision.run or {"id": run_id}, int(decision.entry.get("attempt") or 1) + 1)
    return pending, results, failures


def utc_now() -> dt.datetime:
    return dt.datetime.now(UTC)


def env_int(name: str, default: int) -> int:
    raw = (os.environ.get(name) or "").strip()
    return int(raw) if raw else default


class _Transient(Exception):
    """A 5xx or a dropped connection: GitHub.request() makes a read again."""


def read_run_jobs(github: GitHub, runs: Sequence[Mapping[str, Any]], linux_only: frozenset[str],
                  now: dt.datetime) -> tuple[dict[int, list[dict[str, Any]]], set[int]]:
    """({run id: jobs} for the runs needs_jobs() lists, the ids whose listing failed).

    One run's failed listing skips that run, not the sweep (a rate limit still ends it): the sweep
    that ended on one 502 at 08:08Z on 2026-10-26 wrote no pool snapshot (RETRY_DELAYS)."""
    jobs_by_run: dict[int, list[dict[str, Any]]] = {}
    unread: set[int] = set()
    for run in runs:
        if not needs_jobs(run, linux_only, now):
            continue
        try:
            jobs_by_run[run["id"]] = github.jobs(run["id"])
        except RateLimited:
            raise
        except RuntimeError as error:
            unread.add(run["id"])
            print(f"queue-janitor: run {run['id']} skipped this sweep: {error}", file=sys.stderr)
    return jobs_by_run, unread


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--repo", default=os.environ.get("GH_REPO") or os.environ.get("GITHUB_REPOSITORY"))
    parser.add_argument("--dry-run", action="store_true",
                        default=(os.environ.get("DRY_RUN", "").lower() in {"1", "true", "yes"}))
    parser.add_argument("--threshold", type=int, default=None)
    parser.add_argument("--max-cancels", type=int, default=None)
    parser.add_argument("--pull-request-policy", default=os.environ.get("CI_PULL_REQUEST_SUITE", ""))
    parser.add_argument("--orphan-minutes", type=int, default=None)
    parser.add_argument("--max-orphan-cancels", type=int, default=None)
    parser.add_argument("--workflows-dir", type=Path,
                        default=Path(__file__).resolve().parents[2] / ".github" / "workflows")
    parser.add_argument("--pool-load", type=Path, default=(
        Path(os.environ["POOL_LOAD_OUT"]) if os.environ.get("POOL_LOAD_OUT") else None),
        help="write this sweep's per-pool macOS demand here as JSON")
    parser.add_argument("--summary", type=Path, default=(
        Path(os.environ["GITHUB_STEP_SUMMARY"]) if os.environ.get("GITHUB_STEP_SUMMARY") else None))
    args = parser.parse_args(argv)

    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if not token or not args.repo:
        print("queue-janitor: GH_TOKEN and GH_REPO are required", file=sys.stderr)
        return 2
    try:
        threshold = args.threshold if args.threshold is not None else env_int("QUEUE_THRESHOLD", DEFAULT_THRESHOLD)
        max_cancels = args.max_cancels if args.max_cancels is not None else env_int("MAX_CANCELS", DEFAULT_MAX_CANCELS)
    except ValueError:
        print("queue-janitor: QUEUE_THRESHOLD and MAX_CANCELS must be integers", file=sys.stderr)
        return 2
    if threshold < 0 or not 0 <= max_cancels <= 25:
        print("queue-janitor: threshold must be >= 0 and max cancels within 0..25", file=sys.stderr)
        return 2
    try:
        orphan_minutes = (args.orphan_minutes if args.orphan_minutes is not None
                          else env_int("ORPHAN_MINUTES", DEFAULT_ORPHAN_MINUTES))
        max_orphan_cancels = (args.max_orphan_cancels if args.max_orphan_cancels is not None
                              else env_int("MAX_ORPHAN_CANCELS", DEFAULT_MAX_ORPHAN_CANCELS))
    except ValueError:
        print("queue-janitor: ORPHAN_MINUTES and MAX_ORPHAN_CANCELS must be integers", file=sys.stderr)
        return 2
    if orphan_minutes < MIN_ORPHAN_MINUTES or not 0 <= max_orphan_cancels <= MAX_ORPHAN_CANCELS_LIMIT:
        print(f"queue-janitor: orphan minutes must be >= {MIN_ORPHAN_MINUTES} and max orphan cancels "
              f"within 0..{MAX_ORPHAN_CANCELS_LIMIT}", file=sys.stderr)
        return 2
    orphan_age = dt.timedelta(minutes=orphan_minutes)

    github = GitHub(token, args.repo, fallback_token=os.environ.get("GH_FALLBACK_TOKEN") or "")
    now = utc_now()
    linux_only = linux_only_workflow_paths(args.workflows_dir)
    try:
        runs = github.in_flight_runs()
        jobs_by_run, unread = read_run_jobs(github, runs, linux_only, now)
        # A run whose jobs could not be read: the snapshot below is still written from every other run,
        # and then the sweep decides nothing (no cancel, re-run or orphan), since a partial inventory
        # misjudges the others too (a newer run at the same head, the pool's wait p90).
        runs = [run for run in runs if run["id"] not in unread]
        # Category e: a suspect whose evidence the in-flight jobs lack gets a
        # few completed runs of its own workflow listed (evidence_queries()),
        # only when such a suspect exists.
        evidence_jobs: dict[int, list[dict[str, Any]]] = {}
        for workflow, since in evidence_queries(runs, jobs_by_run, now=now):
            try:
                listed = github.completed_runs(workflow, since)
                for run in evidence_runs(listed, known=set(jobs_by_run) | set(evidence_jobs),
                                         cap=LOST_EVIDENCE_RUNS_PER_WORKFLOW):
                    evidence_jobs[run["id"]] = github.jobs(run["id"])
            except RateLimited:
                raise
            except RuntimeError as error:
                print(f"queue-janitor: lost-assignment evidence for {workflow}: {error}", file=sys.stderr)
        lost = find_lost(runs, jobs_by_run, now=now, evidence_jobs=evidence_jobs)
        unclaimed = find_unclaimed(runs, jobs_by_run, now=now, lost=lost, evidence_jobs=evidence_jobs,
                                   blacksmith_legs=os.environ.get("PR_POOL_OWNED", "").strip() == "1")
        # The re-runs an earlier sweep left pending, from its pool snapshot.
        # None means unknown: then nothing at an open pull request's head is
        # cancelled for a re-run this sweep could not carry on.
        pending: list[dict[str, Any]] | None = None
        if args.pool_load:
            try:
                pending = previous_lost_reruns(github)
            except Exception as error:  # noqa: BLE001 optional state (IncompleteRead, ...) never fails a sweep
                print(f"queue-janitor: lost-assignment re-run state: {error!r}", file=sys.stderr)
        # Orphans read only what is already fetched; their PR branches join
        # the one batched GraphQL lookup for the no-janitor label.
        orphans = find_orphans(runs, jobs_by_run, min_age=orphan_age, now=now)
        branches = sorted(set(branches_to_resolve(runs, jobs_by_run)) | set(orphan_branches(orphans, now))
                          | set(lost_branches(runs, {**lost, **unclaimed}, pending or [])))
        prs_by_branch = github.pull_requests(branches) if branches else {}
    except RuntimeError as error:
        print(f"queue-janitor: {error}", file=sys.stderr)
        print(render_rate_limits(github.rate_limits), file=sys.stderr)
        return 1

    # Categories e and f: is a push or dispatch run's branch live (its head still the run's)? One request a
    # branch: at most CANDIDATE_HEAD_LOOKUPS for this sweep's candidates, and PENDING_HEAD_LOOKUPS of their
    # own for settled cancels waiting on a re-run. A read that fails leaves the branch unknown.
    branch_heads: dict[str, str] = {}
    head_reads = 0

    def read_heads(branches_wanted: Sequence[str]) -> None:
        nonlocal head_reads
        for branch in branches_wanted:
            head_reads += 1
            try:
                branch_heads[branch] = github.branch_head(branch)
            except RuntimeError as error:
                print(f"queue-janitor: head of {branch}: {error}", file=sys.stderr)

    read_heads(branch_head_lookups(runs, {*lost, *unclaimed}, prs_by_branch=prs_by_branch, jobs_by_run=jobs_by_run,
                                   unclaimed=unclaimed))

    snapshot: dict[str, Any] | None = None
    if args.pool_load:
        # Before any cancellation: pr_runner_pool.py wants the demand a new run
        # would queue behind, and the janitor's cancels are capped anyway.
        pool_settings = {key: os.environ.get(name, "") for name, key in POOL_SETTINGS_ENV.items()}
        # Owned pools on: one artifact listing per run that may hold one, for
        # the peak its marker declares. Off: no request at all.
        markers: dict[int, tuple[str, int, int]] = {}
        capability_markers: dict[int, tuple[str, int]] = {}
        if os.environ.get("PR_POOL_OWNED", "").strip() == "1":
            for run in runs:
                jobs = jobs_by_run.get(run.get("id"))
                if jobs is not None and may_hold_owned_pool(run, jobs) and marker_may_exist(run, jobs):
                    try:
                        names = github.artifact_names(
                            run["id"], stop=f"macos-pool-persistent-{run['id']}-{run.get('run_attempt') or 1}-")
                    except RuntimeError as error:
                        print(f"queue-janitor: owned-pool marker for run {run['id']}: {error}", file=sys.stderr)
                        continue
                    found = owned_marker(run, names)
                    if found:
                        markers[run["id"]] = found
                    capability = capability_marker(run, names)
                    if capability:
                        capability_markers[run["id"]] = capability
        snapshot = pool_load_snapshot(runs, jobs_by_run, now=now, settings=pool_settings, markers=markers,
                                      capability_markers=capability_markers)
        # Category f's bound, published for the next reader (pr_runner_pool.py ignores unknown keys).
        waits = pool_wait_p90(jobs_by_run, evidence_jobs)
        if waits:
            snapshot[WAIT_P90_KEY] = waits
        # Fleet labels no runner is taking jobs from; the workflow's alert step
        # (starved_labels.py) annotates them and keeps one issue per label.
        try:
            snapshot.update(starved_result(github, runs, jobs_by_run, evidence_jobs, now=now))
        except RateLimited as error:
            print(f"queue-janitor: {error}", file=sys.stderr)
            print(render_rate_limits(github.rate_limits), file=sys.stderr)
            return 1
        if unread:
            # Read from every run but these: their jobs are missing, so a label one of them is running on
            # can look starved and one it waits on can look recovered. No starved-label issue is opened,
            # updated or closed on this sweep (starved_labels.py), and readers can tell it is partial.
            snapshot["starved"] = []
            snapshot["starved_incomplete"] = True
            snapshot[UNREAD_RUNS_KEY] = sorted(unread)
        # Warm affinity on: which root runner kept a build of which main
        # commits (owned_warm_state.py). A failure leaves `warm` out, and the
        # picker then routes admission by the root label as before.
        if os.environ.get("OWNED_WARM", "").strip() == "1":
            try:
                snapshot["warm"] = owned_warm_state.sweep(PoolClient(token, args.repo), jobs_by_run, now)
            except Exception as error:  # noqa: BLE001 a routing hint never fails the sweep
                print(f"queue-janitor: owned warm state: {error}", file=sys.stderr)
        args.pool_load.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")

    if unread:
        # Nothing is acted on, so the pending re-runs an earlier sweep left are carried forward as they were.
        if snapshot is not None and args.pool_load and pending is not None:
            snapshot[LOST_RERUNS_KEY] = [dict(entry) for entry in pending][-LOST_PENDING_MAX:]
            args.pool_load.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
        summary = (f"\n_The job listings of {len(unread)} run(s) failed ({', '.join(map(str, sorted(unread)))}): "
                   f"the pool snapshot was written from the other {len(runs)}, and this sweep decided nothing._\n"
                   f"\n_{render_rate_limits(github.rate_limits)}_\n")
        print(summary)
        if args.summary:
            with args.summary.open("a", encoding="utf-8") as handle:
                handle.write(summary)
        return 0

    plan = build_plan(
        runs, jobs_by_run, prs_by_branch,
        threshold=threshold, max_cancels=max_cancels, pull_request_policy=args.pull_request_policy,
        now=now, lost=lost, rerun_state=pending is not None, unclaimed=unclaimed, branch_heads=branch_heads,
        app_rerun=github.app_token,
    )

    results: dict[int, str] = {}
    failures = 0
    if not args.dry_run:
        results, failures = cancel_plan(github, plan.to_cancel())

    def save_lost_reruns(entries: Sequence[Mapping[str, Any]]) -> None:
        if snapshot is not None and args.pool_load:
            snapshot[LOST_RERUNS_KEY] = [dict(entry) for entry in entries][-LOST_PENDING_MAX:]
            args.pool_load.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")

    # Category e re-runs: one run request per pending entry, then at most
    # LOST_RERUN_MAX re-runs. What is still pending, plus this sweep's cancels
    # that asked for a re-run, goes into the snapshot for the next sweep.
    rerun_decisions: list[LostRerun] = []
    rerun_results: dict[int, str] = {}
    if pending is not None:
        # Saved before anything else can fail: this sweep's cancels are
        # already made, and an entry read twice is harmless (plan_lost_reruns()).
        fresh = [] if args.dry_run else new_lost_reruns(plan.to_cancel(), results, now=now)
        save_lost_reruns([*pending, *fresh])
        runs_now: dict[int, Mapping[str, Any]] = {}
        for entry in pending:
            run_id = entry.get("run_id")
            if isinstance(run_id, int) and run_id not in runs_now:
                try:
                    runs_now[run_id] = github.run(run_id)
                except Exception as error:  # noqa: BLE001 the entry is kept for the next sweep
                    print(f"queue-janitor: pending re-run of run {run_id}: {error!r}", file=sys.stderr)
        # One listing per settled cancel: a newer run at its head that took
        # over (even one finished since) means no re-run.
        head_runs: dict[int, list[Mapping[str, Any]]] = {}
        for run_id, run in runs_now.items():
            if run.get("status") == "completed" and run.get("conclusion") == "cancelled":
                try:
                    head_runs[run_id] = [*github.runs_at_head(run), *runs]
                except Exception as error:  # noqa: BLE001 the entry is kept for the next sweep
                    print(f"queue-janitor: runs at the head of run {run_id}: {error!r}", file=sys.stderr)
        # A settled push or dispatch cancel is re-run only while its branch is live.
        settled = [run for run in runs_now.values()
                   if run.get("status") == "completed" and run.get("conclusion") == "cancelled"]
        read_heads(branch_head_lookups(settled, {run.get("id") for run in settled}, prs_by_branch=prs_by_branch,
                                       known=branch_heads, cap=PENDING_HEAD_LOOKUPS))
        rerun_decisions = plan_lost_reruns(pending, runs_now, prs_by_branch, now=now, head_runs=head_runs,
                                           branch_heads=branch_heads, app_token=github.app_token)
        if args.dry_run:
            # Nothing acted on, so only an expired entry goes.
            still_pending = [dict(decision.entry) for decision in rerun_decisions
                             if not (decision.action == "drop" and decision.note == "expired")]
        else:
            still_pending, rerun_results, rerun_failures = rerun_lost(github, rerun_decisions)
            failures += rerun_failures
        save_lost_reruns([*still_pending, *fresh])

    orphan_decisions = build_orphan_plan(
        orphans, prs_by_branch, max_cancels=max_orphan_cancels,
        exclude_ids={candidate.run["id"] for candidate in plan.to_cancel()}, now=now,
    )
    orphan_results: dict[int, str] = {}
    if not args.dry_run:
        orphan_results, orphan_failures = cancel_orphans(github, orphan_decisions)
        failures += orphan_failures

    summary = render_summary(plan, dry_run=args.dry_run, now=now, results=results)
    summary += render_lost_reruns(rerun_decisions, dry_run=args.dry_run, results=rerun_results)
    summary += render_orphan_summary(orphan_decisions, dry_run=args.dry_run, now=now, min_age=orphan_age,
                                     results=orphan_results)
    summary += f"\n_{len(runs)} in-flight runs, {len(jobs_by_run)} job listings, {len(branches)} PR branches, " \
               f"{len(orphans)} orphans, {len(lost)} lost assignments, {len(unclaimed)} unclaimed legs, " \
               f"{head_reads} branch head reads, {len(evidence_jobs)} evidence job listings, " \
               f"{github.calls} API calls._\n"
    summary += f"\n_{render_rate_limits(github.rate_limits)}_\n"
    print(summary)
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as handle:
            handle.write(summary)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
