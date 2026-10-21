#!/usr/bin/env python3
"""Cancel macOS runner demand that no longer buys anything.

Pull request macOS jobs share a few small runner pools (Blacksmith and
GitHub-hosted macOS 15 and 26). When one is saturated, every queued job on it
that nobody will read delays one that somebody will. This janitor looks at
in-flight Actions runs and cancels runs that are waste, in this priority
order. Stale pull request runs (b) and lost runner assignments (e) are
cancelled on every sweep; the other categories only when the number of macOS
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
     it the job is just waiting in a backed-up pool and is left alone. A lost
     job holds nothing but never runs, so this category is not gated on a
     backed-up pool. A run whose head is stale (a push with no open pull
     request at its head, or a pull request run whose PR is closed, merged or
     superseded) is cancelled. A run at the current head of an open pull
     request is cancelled once no other job of it is running, and a later
     sweep re-runs its failed jobs (rerun-failed-jobs) when the run has
     completed as cancelled and the PR head still equals its head_sha
     (plan_lost_reruns()). It is re-run once: the pending re-run names the
     attempt it cancelled and is dropped when the run is past that attempt,
     and an attempt a bot started (the janitor's own re-run, or
     owned_pool_rescue.py's) is cancelled but never queued for a re-run
     (bot_rerun()), nor is a run that already failed. The pending re-runs ride
     in the `macos-pool-load` snapshot this sweep already uploads, under
     LOST_RERUNS_KEY, and the next sweep reads them from the newest trusted
     copy (previous_lost_reruns()); without that state nothing at an open
     pull request's head is cancelled.

Draft pull requests are deliberately not a category: a draft can be an active
integration branch other work depends on, and ci.yml has no ready_for_review
trigger to replace a cancelled ci-status.

A pool is the set of macOS labels a job asked for. Outside (b) and (e), a run
that only waits on a pool that is not backed up is never cancelled: its output
may still be read, and cancelling it frees nothing anyone is waiting for. A
stale pull request run's output is never read, so it goes whatever the queue,
unless someone re-ran it or labelled the PR no-janitor; those wait for a
backed-up pool like the other categories. A lost assignment (e) goes whatever
the queue, and a `no-janitor` label (or a label page left unread) leaves it
alone, as it does an orphan. Outside (b) and (e), candidates are skipped once
every pool's projected queue is back under the threshold. Every category shares
the per-sweep cancel cap, and runs holding a backed-up pool are spent first.
Main pushes, merge groups, scheduled and dispatched runs on main, release/tag
runs, nightly, and TestFlight/App Store workflows are never candidates,
whatever their state.

owned_pool_rescue.py also cancels and re-runs runs on owned pools, inside its
own watch of each run. The two never re-run the same attempt twice: each
re-checks the run's attempt right before re-running (the rescue in its
cancel-wait loop, the janitor in plan_lost_reruns()), and GitHub refuses a
re-run of a run that is not completed. The rescue usually moves a CI job
stuck on an owned pool first (its budget is about 16.5 minutes at the default
queue rounds, 46.5 at most); when (e) gets there first, the rescue's watch
ends with the cancelled run, and its sweeper watches the janitor's re-run
like any attempt 2. Where the rescue deliberately waits for a sibling still
running, (e) waits too at an open pull request's head. The rescue's own
re-runs are attempts a bot started, which (e) never re-runs, so the rescue's
attempt ladder (Blacksmith from attempt 3) is never extended by the janitor.

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
import owned_warm_state  # noqa: E402


API = "https://api.github.com"
DEFAULT_THRESHOLD = 6
DEFAULT_MAX_CANCELS = 10
MAX_RUN_PAGES = 3
MAX_JOB_PAGES = 3
GRAPHQL_BATCH = 25

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

CATEGORY_ORDER = ("experiment", "stale-pr", "label-dropped", "doomed", "lost")

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
    if event == "push" and (branch == "main" or branch.startswith("rc/")):
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
    if run.get("path") in linux_only_paths:
        return False
    if run.get("event") in PROTECTED_EVENTS - {"merge_group"}:
        # Deployment/tag bookkeeping never holds pool capacity worth counting.
        return False
    created = parse_time(run.get("created_at"))
    if run.get("status") == "queued" and created and now - created > GHOST_QUEUED_RUN_AGE:
        return False
    return True


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
OWNED_DISPATCH_WORKFLOWS = ("/test-e2e.yml", "/test-ios.yml", "/ios-screenshots.yml", "/iroh-release-gate.yml")
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


# ---------------------------------------------------------------------------
# Category e: lost runner assignments
# ---------------------------------------------------------------------------
#
# GitHub can lose a job's runner assignment: the job stays `queued` with no
# runner for hours while newer jobs on the same labels are picked up, and the
# runner fleet never sees it (run 39631559018, job 119450713364 on
# glaeda-side-std-xcode-26.6, queued 80+ minutes from 19:55Z on 2026-10-21).
# The sweep runs on a hosted runner that cannot reach the fleet dashboard, so
# "the fleet has no record of it" is read from GitHub alone: no runner id or
# name, and proof from the same inventory that runners serving exactly its
# labels took newer work and skipped it (skipped_by_pool()).


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
    alone.
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
    waiting in a backed-up pool and is left alone.
    """
    others = _all_jobs(jobs_by_run, evidence_jobs)
    lost: dict[int, LostJob] = {}
    for run in runs:
        if not _lost_scope(run):
            continue
        best: LostJob | None = None
        for job, since in _overdue(jobs_by_run.get(run["id"]) or (), now):
            skipped = skipped_by_pool(job, since, others)
            if skipped and (best is None or since < best.queued_since):
                best = LostJob(str(job.get("name") or ""), job_pool_key(job), since, skipped)
        if best is not None:
            lost[run["id"]] = best
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
        if not _lost_scope(run) or not workflow:
            continue
        for job, since in _overdue(jobs_by_run.get(run["id"]) or (), now):
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


def lost_pr_state(run: Mapping[str, Any], prs: Sequence[Mapping[str, Any]]) -> tuple[str, Mapping[str, Any] | None, str]:
    """("current" | "stale" | "unknown", the pull request it was judged by, why).

    A pull request run is current while its pull request is open at the run's
    head, and stale once it is merged, closed or superseded. A push run is
    current while an open pull request from the same owner has the run's head,
    and stale otherwise, including a branch with no pull request at all.
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
    if run.get("event") == "push":
        owner = run_head_owner(run)
        open_prs = [pr for pr in prs if pr.get("state") == "OPEN"
                    and str(((pr.get("headRepositoryOwner") or {}).get("login")) or "").lower() == owner]
        at_head = [pr for pr in open_prs if pr.get("headRefOid") == sha]
        if at_head:
            return "current", at_head[0], f"push at the head of open PR #{at_head[0].get('number')}"
        return "stale", (open_prs[0] if open_prs else None), f"push on {branch}: no open pull request at {sha[:9]}"
    return "unknown", None, f"{run.get('event')} run"


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
) -> LostVerdict | None:
    """What category e does with a run holding a lost job, or None to leave it to the other categories.

    `prs` is the lookup for the run's branch, None when the branch was not
    looked up (then nothing is known, and nothing is done). A stale run is
    cancelled whatever its siblings are doing: nobody reads it. A run at the
    current head of an open pull request is cancelled so that a later sweep
    re-runs its failed jobs, except:
    - while another of its jobs runs (the cancel would kill readable work;
      once they finish only the lost job is left to re-run);
    - a run that already failed, or an attempt a bot started (bot_rerun()),
      is cancelled but not re-run: the first is decided, and the second is the
      janitor's own re-run (or owned_pool_rescue.py's), which is never re-run
      again;
    - without re-run state (`rerun_state`: --pool-load, and the previous
      snapshot was readable) it is left alone, since a cancel nobody re-runs
      would leave the pull request with a cancelled run.
    `no-janitor` on the pull request, or a label page left unread, skips the
    run like an orphan.
    """
    if prs is None:
        return None
    state, pr, why = lost_pr_state(run, prs)
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
    running = sum(1 for job in run_jobs if job.get("status") in RUNNING_JOB_STATUSES)
    if running:
        return LostVerdict("skip", f"{evidence}; {why}", f"{running} other job(s) still running", pr=pr)
    if any(job.get("status") == "completed" and job.get("conclusion") == "failure" for job in run_jobs):
        return LostVerdict("cancel", f"{evidence}; {why}, but the run already failed, so it is not re-run", pr=pr)
    if bot_rerun(run):
        return LostVerdict("cancel", f"{evidence}; {why}, but attempt {run.get('run_attempt')} is a bot's re-run, "
                                     "which is never re-run again", pr=pr)
    if not rerun_state:
        return LostVerdict("skip", f"{evidence}; {why}", "no re-run state to carry the re-run to a later sweep", pr=pr)
    return LostVerdict("cancel", f"{evidence}; {why}: its failed jobs are re-run once the cancel settles",
                       rerun=True, pr=pr)


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
            entries.append({"run_id": run["id"], "attempt": int(run.get("run_attempt") or 1),
                            "head_sha": str(run.get("head_sha") or ""), "branch": str(run.get("head_branch") or ""),
                            "cancelled_at": _iso(now)})
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
) -> list[LostRerun]:
    """Which pending category-e cancels to re-run now.

    Each entry names the run and the attempt the janitor cancelled. It is
    re-run (rerun-failed-jobs) once that attempt has completed as cancelled,
    while its pull request is still open at the run's head (lost_pr_state()).
    The "once" is the attempt: a re-run makes a new attempt, so an entry whose
    run moved past its attempt (the janitor's re-run, a person's, or
    owned_pool_rescue.py's) is dropped, and the new attempt, started by a bot,
    is never queued for another re-run (classify_lost()). A run not readable
    this sweep, a cancel not settled yet, or a branch not looked up is kept for
    the next sweep, until LOST_RERUN_TTL.
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
        state, pr, why = lost_pr_state(run, prs_by_branch[branch])
        if state != "current":
            decisions.append(LostRerun(entry, "drop", f"not re-run: {why}", run))
            continue
        if pr is not None and (JANITOR_OPT_OUT_LABEL in pr_labels(pr) or not labels_complete(pr)):
            decisions.append(LostRerun(entry, "drop", f"not re-run: PR #{pr.get('number')} opted out", run))
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
) -> Plan:
    """Decide every category's candidates under the shared cap.

    Category e (lost, classify_lost()) is judged first, so a run holding a
    lost job is cancelled as one, never gated on a backed-up pool; a run it
    leaves alone still goes through classify(). `lost` defaults to
    find_lost() over `jobs_by_run` and `evidence_jobs`; `rerun_state` says
    whether a cancel at an open pull request's head can be carried to the
    sweep that re-runs it.
    """
    if lost is None:
        lost = find_lost(runs, jobs_by_run, now=now, evidence_jobs=evidence_jobs)
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
        if run["id"] in lost:
            lost_verdict = classify_lost(
                run, jobs_by_run.get(run["id"], ()), lost[run["id"]],
                prs_by_branch[branch] if branch in prs_by_branch else None, now=now, rerun_state=rerun_state)
            if lost_verdict is not None and lost_verdict.action == "cancel":
                candidates.append(Candidate(run, "lost", lost_verdict.reason, usage, lost_verdict.pr,
                                            rerun=lost_verdict.rerun))
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
            lost_skips.append(Decision(Candidate(run, "lost", lost_verdict.reason, usage, lost_verdict.pr),
                                       "skip", lost_verdict.note))

    initially_backed_up = {pool for pool, count in queued_by_pool.items() if count > threshold}

    def order(candidate: Candidate) -> tuple[int, int, str, int]:
        # Runs holding a backed-up pool take the shared cap first; a stale run on
        # an idle pool frees nothing anyone is waiting for.
        idle = not initially_backed_up.intersection(candidate.usage.held_by_pool)
        return (int(idle), CATEGORY_ORDER.index(candidate.category),
                str(candidate.run.get("created_at") or ""), candidate.run["id"])

    def needs_pressure(candidate: Candidate) -> bool:
        # A lost job frees nothing but never runs either: pure dead weight, on
        # any pool (classify_lost() already honoured no-janitor).
        if candidate.category == "lost":
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
                         f"pull requests, and runs holding a lost runner assignment, {verb}. Candidates seen:")
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
    if ORPHAN_PROTECTED_WORKFLOW.search(" ".join(str(run.get(key) or "") for key in ("name", "path"))):
        return "release/publish workflow"
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
            # The inventory is seconds old; drop anything that finished or
            # moved to a new head in between.
            current = github.run(run_id)
            if current.get("status") not in IN_FLIGHT_RUN_STATUSES:
                results[run_id] = f"skipped (now {current.get('status')})"
                continue
            if current.get("head_sha") != candidate.run.get("head_sha"):
                results[run_id] = "skipped (head changed)"
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


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self._token = token
        self.calls = 0
        # Rate limit resource ("core", "graphql") -> the newest response's values.
        self.rate_limits: dict[str, dict[str, int]] = {}
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-queue-janitor",
        }

    def request(self, method: str, path: str, body: Any | None = None) -> Any:
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
            raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.code})") from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error.reason})") from error

    def note_rate_limit(self, headers: Any) -> None:
        found = read_rate_limit(headers)
        if found:
            self.rate_limits[found[0]] = found[1]

    def in_flight_runs(self) -> list[dict[str, Any]]:
        runs: dict[int, dict[str, Any]] = {}
        for status in IN_FLIGHT_RUN_STATUSES:
            for page in range(1, MAX_RUN_PAGES + 1):
                query = urllib.parse.urlencode({"status": status, "per_page": 100, "page": page})
                payload = self.request("GET", f"/repos/{self.repo}/actions/runs?{query}")
                batch = payload.get("workflow_runs") or []
                for run in batch:
                    runs[run["id"]] = run
                if len(batch) < 100:
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

    def cancel(self, run_id: int) -> None:
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/cancel")

    def force_cancel(self, run_id: int) -> None:
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/force-cancel")

    def rerun_failed(self, run_id: int) -> None:
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/rerun-failed-jobs")

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
    sweep sees the new attempt and drops it, so it can never run twice.
    """
    pending = [dict(decision.entry) for decision in decisions if decision.action == "keep"]
    results: dict[int, str] = {}
    failures = 0
    for decision in decisions:
        if decision.action != "rerun":
            continue
        run_id = int(decision.entry["run_id"])
        try:
            github.rerun_failed(run_id)
            results[run_id] = "re-ran failed jobs"
        except RuntimeError as error:
            failures += 1
            results[run_id] = f"failed: {error}"
            pending.append(dict(decision.entry))
    return pending, results, failures


def utc_now() -> dt.datetime:
    return dt.datetime.now(UTC)


def env_int(name: str, default: int) -> int:
    raw = (os.environ.get(name) or "").strip()
    return int(raw) if raw else default


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

    github = GitHub(token, args.repo)
    now = utc_now()
    linux_only = linux_only_workflow_paths(args.workflows_dir)
    try:
        runs = github.in_flight_runs()
        jobs_by_run = {run["id"]: github.jobs(run["id"]) for run in runs if needs_jobs(run, linux_only, now)}
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
            except RuntimeError as error:
                print(f"queue-janitor: lost-assignment evidence for {workflow}: {error}", file=sys.stderr)
        lost = find_lost(runs, jobs_by_run, now=now, evidence_jobs=evidence_jobs)
        # The re-runs an earlier sweep left pending, from its pool snapshot.
        # None means unknown: then nothing at an open pull request's head is
        # cancelled for a re-run this sweep could not carry on.
        pending: list[dict[str, Any]] | None = None
        if args.pool_load:
            try:
                pending = previous_lost_reruns(github)
            except RuntimeError as error:
                print(f"queue-janitor: lost-assignment re-run state: {error}", file=sys.stderr)
        # Orphans read only what is already fetched; their PR branches join
        # the one batched GraphQL lookup for the no-janitor label.
        orphans = find_orphans(runs, jobs_by_run, min_age=orphan_age, now=now)
        branches = sorted(set(branches_to_resolve(runs, jobs_by_run)) | set(orphan_branches(orphans, now))
                          | set(lost_branches(runs, lost, pending or [])))
        prs_by_branch = github.pull_requests(branches) if branches else {}
    except RuntimeError as error:
        print(f"queue-janitor: {error}", file=sys.stderr)
        print(render_rate_limits(github.rate_limits), file=sys.stderr)
        return 1

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
        # Warm affinity on: which root runner kept a build of which main
        # commits (owned_warm_state.py). A failure leaves `warm` out, and the
        # picker then routes admission by the root label as before.
        if os.environ.get("OWNED_WARM", "").strip() == "1":
            try:
                snapshot["warm"] = owned_warm_state.sweep(PoolClient(token, args.repo), jobs_by_run, now)
            except Exception as error:  # noqa: BLE001 a routing hint never fails the sweep
                print(f"queue-janitor: owned warm state: {error}", file=sys.stderr)
        args.pool_load.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")

    plan = build_plan(
        runs, jobs_by_run, prs_by_branch,
        threshold=threshold, max_cancels=max_cancels, pull_request_policy=args.pull_request_policy,
        now=now, lost=lost, rerun_state=pending is not None,
    )

    results: dict[int, str] = {}
    failures = 0
    if not args.dry_run:
        results, failures = cancel_plan(github, plan.to_cancel())

    # Category e re-runs: one run request per pending entry, then at most
    # LOST_RERUN_MAX re-runs. What is still pending, plus this sweep's cancels
    # that asked for a re-run, goes into the snapshot for the next sweep.
    rerun_decisions: list[LostRerun] = []
    rerun_results: dict[int, str] = {}
    if pending is not None:
        runs_now: dict[int, Mapping[str, Any]] = {}
        for entry in pending:
            run_id = entry.get("run_id")
            if isinstance(run_id, int) and run_id not in runs_now:
                try:
                    runs_now[run_id] = github.run(run_id)
                except RuntimeError as error:
                    print(f"queue-janitor: pending re-run of run {run_id}: {error}", file=sys.stderr)
        rerun_decisions = plan_lost_reruns(pending, runs_now, prs_by_branch, now=now)
        if args.dry_run:
            still_pending = [dict(entry) for entry in pending]
        else:
            still_pending, rerun_results, rerun_failures = rerun_lost(github, rerun_decisions)
            failures += rerun_failures
            still_pending += new_lost_reruns(plan.to_cancel(), results, now=now)
        if snapshot is not None and args.pool_load:
            snapshot[LOST_RERUNS_KEY] = still_pending[-LOST_PENDING_MAX:]
            args.pool_load.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")

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
               f"{len(orphans)} orphans, {len(lost)} lost assignments, {len(evidence_jobs)} evidence job listings, " \
               f"{github.calls} API calls._\n"
    summary += f"\n_{render_rate_limits(github.rate_limits)}_\n"
    print(summary)
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as handle:
            handle.write(summary)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
