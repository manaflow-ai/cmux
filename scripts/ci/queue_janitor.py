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
     any other job of the run created before it is unfinished (running, held,
     or queued without being lost itself), it may be the gate the job waits
     behind, so the run is left alone at any head (_gated()). A job created
     with or after it is never one of its needs (may_need(): GitHub creates a
     job once its needs finished), so it neither gates the job nor restarts
     its 30 minutes when it finishes (lost_wait_start()). A lost job holds nothing but never
     runs, so this category is not gated on a backed-up pool. A run whose
     head is stale (a push with no open pull request at its head, or a pull
     request run whose PR is closed, merged or superseded) is cancelled. A
     run at the current head of an open pull request is never cancelled by
     any other category (open_pr_at_head(), OPEN_HEAD_RULE): run
     40398277457 (cmux-next, PR #25446) attempt 2 was cancelled at its head
     and stayed cancelled until a person re-ran it, because the carried
     re-run needs a later sweep and this workflow's concurrency group evicts
     pending sweeps. A lost job there is the stall-aware failover instead
     (open_head_lost(), coordinator-approved 2026-10-30): the sweep cancels
     the run, waits a bounded time for the cancel to settle, reads its pull
     request and the runs at its head again (plan_lost_reruns()), and
     re-runs its failed jobs as cmux-bot at the same head (rerun_open_head()), and the
     pending re-run state, written before the cancel's first read, carries
     it to the next sweep when the cancel has not settled or the re-run was
     refused. A bot's re-run at LOST_FAILOVER_MAX_ATTEMPT or later, a run
     that already failed with an unfinished job that is not lost, one a newer
     run took over, and a nightly, DEV or promote run keep OPEN_HEAD_RULE, as
     does every open head while this sweep has no cmux-bot token or no
     re-run state. On 2026-10-30 23 such runs had waited 1.5 to 10 hours
     on glaeda-side-std, glaeda-gui-std and Blacksmith 6 vCPU while newer
     jobs on their labels started. A push or dispatch run whose
     branch head (read this sweep, branch_head_lookups()) is still its head,
     with no open pull request at it, is current: it is cancelled and a later
     sweep re-runs its failed jobs (rerun-failed-jobs) when the run has
     completed as cancelled and the branch head still equals its head_sha
     (plan_lost_reruns()). It is re-run once: the pending re-run names the
     attempt it cancelled and is dropped when the run is past that attempt,
     and an attempt a bot started at that head (the janitor's own re-run, or
     owned_pool_rescue.py's) is left to the rescue and the orphan pass
     (bot_rerun()). A run that already failed, or one a newer run of its
     workflow at its head took over, is cancelled but never re-run, since
     re-running it would replay its event over the newer run
     (newer_run_at_head()). The pending re-runs ride in the `macos-pool-load`
     snapshot this sweep already uploads, under LOST_RERUNS_KEY, and the next
     sweep reads them from the newest trusted copy (previous_lost_reruns());
     without that state nothing at a live head is cancelled.
  f. push, pull request and workflow_dispatch runs holding an unclaimed leg
     (find_unclaimed()): a job on an owned label (owned_pool_rescue.job_pool())
     still queued with no runner, longer after it could first run than
     max(UNCLAIMED_QUEUED_SECONDS, 45 minutes; the pool's p90 wait over the
     jobs a runner took in this sweep's inventory, from when each could first
     run, pool_wait_p90(), once a pool has UNCLAIMED_MIN_SAMPLES of them,
     published in the snapshot under WAIT_P90_KEY), with no evidence needed.
     Run 39652497071's cmux-tui macOS leg (a dispatch on a live branch, on
     glaeda-side-std-xcode-26.6) sat unclaimed 18:25Z to 00:37Z until
     GitHub's queue timeout. A push or dispatch on a short-lived branch (not
     main, feat-cmux-next, nightly-next or rc/*; no nightly, DEV or promote
     run) whose branch moved on or is gone is cancelled outright and not
     re-run, as in category e (stale_head_cancellable()). Otherwise it is
     moved only at a live head with no open
     pull request at it (an open pull request's head is never cancelled, as
     in category e): a push or dispatch whose branch head, read with
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
     label the rescue watches. A cmux-next pull request run at its open
     head (PR #25446's case) is left to the controller's fall-through.

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
Categories (c) and (d) only ever judge a run at its open pull request's head,
so they no longer cancel anything: such a run is listed as skipped with
OPEN_HEAD_RULE.
Main and feat-cmux-next pushes, merge groups, scheduled and dispatched runs on
main, release/tag runs, nightly, and TestFlight/App Store workflows are never
candidates, whatever their state.

owned_pool_rescue.py also cancels and re-runs runs on owned pools, inside its
own watch of each run. The two never re-run the same attempt twice: each
re-checks the run's attempt right before re-running (the rescue in its
cancel-wait loop, the janitor in plan_lost_reruns()), and GitHub refuses a
re-run of a run that is not completed. The janitor never cancels a run at
its open pull request's head. On a live push or dispatch head, when (e) gets
there first, the rescue's watch ends with the cancelled run, and its sweeper
watches the janitor's re-run like any attempt 2. Where the rescue
deliberately waits for a sibling still running, (e) waits too, at any head.
The rescue's own re-runs are attempts a bot started, which (e) leaves alone,
so the rescue's attempt ladder (Blacksmith from attempt 3) is never
preempted or extended by the janitor.

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
has its own cap, and may end main schedules and TestFlight runs, which the
categories above never touch. It never ends a nightly, DEV or promote run
(scripts/ci/delivery_workflows.py): those are reported for more capacity. It acts later than (e)
(CI_JANITOR_ORPHAN_MINUTES, 120 by default) and re-runs only a workflow_dispatch
on a long-lived branch (orphan_reruns()): the next sweep re-runs it at the same
head, below LOST_FAILOVER_MAX_ATTEMPT, unless a newer dispatch of its kind took
its job (superseding_dispatch()). A run (e) cancels this sweep is excluded from it. An orphan at an open pull request's
head, whatever its event, is skipped like every category's (open_pr_at_head()).

Superseded delivery runs are one more pass (skip_superseded_delivery): "When
nightly runs for older commits are stuck waiting (queued for a runner or a
gate), skip them and build from the tip: cancel the stale runs" (Leo,
2026-10-26). A nightly, DEV or promote run is cancelled only when
delivery_workflows.superseded_unstarted() says it is stale: every job but the
light control and decide ones is still queued for a runner, it has waited at
least 20 min, and a newer head of its branch has its own run of the same
workflow that is already building. The
agents' cancel guard reads that same function, so the two never disagree. A
run's jobs are read again right before its cancel, and a run whose build
started in between is kept. Its own cap; no force-cancel.
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
import threading
import time
import urllib.error
import urllib.parse
import urllib.request
import zipfile
import zlib
from collections.abc import Iterable, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
from pr_runner_pool import MAX_RUN_JOBS  # noqa: E402
from pr_runner_pool import persistent as owned_pool  # noqa: E402
from pr_runner_pool import CAPABILITY_LABELS, pool_label, root_label, side_label  # noqa: E402
from pr_runner_pool import LANE_LABEL  # noqa: E402
from pr_runner_pool import GitHub as PoolClient  # noqa: E402
from pr_runner_pool import ARTIFACT_NAME as SNAPSHOT_ARTIFACT  # noqa: E402
from pr_runner_pool import SNAPSHOT_BRANCH, SNAPSHOT_FILE, trusted_snapshot_artifact  # noqa: E402
import owned_pool_rescue as rescue  # noqa: E402
import owned_warm_state  # noqa: E402
import ui_tests_dispatch  # noqa: E402
import starved_labels  # noqa: E402
from delivery_workflows import REPLACEMENT_JOB_READS, attempt_jobs, build_started, is_delivery_run  # noqa: E402
from delivery_workflows import delivers, is_delivery_event, is_delivery_workflow  # noqa: E402
from delivery_workflows import newer_head_runs, superseded_unstarted  # noqa: E402
from delivery_workflows import dev_publish_published, dev_publish_source, dev_publish_superseded  # noqa: E402


API = "https://api.github.com"
DEFAULT_THRESHOLD = 6
DEFAULT_MAX_CANCELS = 10
# The in-flight run listing pages each status until an empty page, up to MAX_RUN_PAGES pages a status
# (4,000 runs). Until 2026-10-30 it stopped at 3 pages: with 1,138 runs queued that day the sweep saw
# 300 of them, and the pool snapshot read every other one's jobs as nothing queued. A filtered
# listing answers at most LISTING_RESULT_PAGES pages (GitHub's 1,000-result cap), so a status that
# fills them is listed again from the oldest run seen (`created<=`), window by window. A listing
# that hits MAX_RUN_PAGES is marked truncated in the snapshot (listing_state()).
MAX_RUN_PAGES = 40
LISTING_RESULT_PAGES = 10
MAX_JOB_PAGES = 3
# Each listed run's jobs are one request; at most MAX_JOB_LISTINGS a sweep (about twice the 1,100 the
# 2026-10-30 queue needed), JOB_LISTING_WORKERS at a time: one at a time took 0.5 s a request, and
# 1,100 of them would not fit the workflow's 10 minutes. Runs past the cap leave the listing truncated.
MAX_JOB_LISTINGS = 2000
JOB_LISTING_WORKERS = 6
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
# A lost job at an open pull request's head (classify_lost(), open_head): the sweep that cancels it reads
# the run up to LOST_SETTLE_READS times, LOST_SETTLE_INTERVAL_S apart, for the cancel to settle, re-checks
# its pull request and the runs at its head, then re-runs its failed jobs as cmux-bot (rerun_open_head()).
# A cancel still unsettled after that, or a re-run GitHub refused, stays in LOST_RERUNS_KEY for the next
# sweep. LOST_SETTLE_BUDGET_S bounds the whole of it in wall time, requests, their retries and their socket
# timeouts included (GitHub.deadline): a sweep that lists the whole queue already takes up to 13 minutes of
# the job's 15, and a timed-out job never uploads the snapshot that carries the entry to the next sweep.
# A sweep past LOST_FAILOVER_CUTOFF_S leaves the re-run to the next sweep.
LOST_SETTLE_READS = 12
LOST_SETTLE_INTERVAL_S = 10
LOST_SETTLE_BUDGET_S = 90.0
# The last LOST_RECOVERY_RESERVE_S of it are kept for the reads and re-runs after the wait, so a cancel that
# never settles does not use up the time the settled ones need.
LOST_RECOVERY_RESERVE_S = 30.0
LOST_FAILOVER_CUTOFF_S = 9 * 60.0
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
# PROTECTED_WORKFLOW without "nightly": what still protects a pull request's run of a delivery workflow. Such a run
# (nightly-next-canary.yml or nightly-next-launch-smoke.yml testing its own edit) publishes, signs, rolls back and
# files nothing, so dep-fleet's ruling (#27521) does not cover it and the sweep treats it as any pull request run.
PULL_REQUEST_PROTECTED_WORKFLOW = re.compile(r"release|testflight|app[-_ ]?store|appstore|publish|notar",
                                             re.IGNORECASE)
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
    # Shared workflows carry DEV/promote delivery runs in their title (for
    # example `cmux NEXT DEV daily · <sha>` on cmux-next.yml), so the path
    # alone does not match PROTECTED_WORKFLOW.  Delivery runs are protected
    # here as well as by the orphan pass: a lost or unclaimed job is a
    # capacity problem, not a reason to cancel a run that may already have
    # started its build, sign or publish work.
    if delivers(run.get("path"), event, run.get("name"), run.get("display_title")):
        return "nightly/DEV/promote delivery workflow"
    test_run = not is_delivery_event(event) and is_delivery_workflow(str(run.get("path") or ""))
    if (PULL_REQUEST_PROTECTED_WORKFLOW if test_run else PROTECTED_WORKFLOW).search(haystack):
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


def branch_linux_only_paths(specs: Iterable[str]) -> dict[str, frozenset[str]]:
    """{branch: its linux-only workflow paths} from `BRANCH=DIR` specs, DIR holding that branch's workflow files.

    The workflow checks feat-cmux-next's .github/workflows out beside main's, over git (no REST request). A spec
    whose directory is missing or holds no workflow file names no branch, so that branch's runs are all listed,
    as before. main is read from --workflows-dir and never from here."""
    found: dict[str, frozenset[str]] = {}
    for spec in specs:
        branch, _, directory = spec.partition("=")
        branch, directory = branch.strip(), directory.strip()
        if not branch or not directory or branch == "main":
            continue
        path = Path(directory)
        if not path.is_dir() or not any(path.glob("*.y*ml")):
            print(f"queue-janitor: no workflow files for {branch} in {directory}; its runs are all listed",
                  file=sys.stderr)
            continue
        found[branch] = linux_only_workflow_paths(path)
    return found


def needs_jobs(run: Mapping[str, Any], linux_only_paths: frozenset[str], now: dt.datetime, *,
               branch_linux_only: Mapping[str, frozenset[str]] | None = None) -> bool:
    """Whether a run's jobs are worth one API call this sweep.

    A run follows its own branch's workflow copy (follows_another_copy()): main's `linux_only_paths` answer for
    main's runs, and `branch_linux_only` (branch_linux_only_paths()) for a branch's, so a feat-cmux-next run of
    a workflow that branch's copy runs only on Linux is not listed. On 2026-10-31 those were 573 of the 1,324
    runs a sweep listed, each one REST request on the cmux-bot installation's budget."""
    if run.get("path") in linux_only_paths and not follows_another_copy(run):
        return False
    target = run_target_branch(run)
    if target and target != "main" and run.get("path") in (branch_linux_only or {}).get(target, frozenset()):
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


def lane_label(job: Mapping[str, Any]) -> str | None:
    """The feat-cmux-next lane label (pr_runner_pool.LANE_LABEL: session, fast, dev, nightly) a job asked for."""
    return next((str(label) for label in job.get("labels") or () if LANE_LABEL.fullmatch(str(label))), None)


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


# Workflows whose queued macOS jobs a pull request must not take a pool from (`reserved_queued`): freshness
# work, the release workflow below plus every delivery workflow (delivery_workflows.DELIVERY_GLOBS: nightly,
# its sign, verify and notarization follow-ups, DEV and promote builds). One declared list, so a new nightly
# or notarization workflow reserves its label without an edit here; tests/test_ci_queue_janitor.py fails on a
# nightly, release, promote or notarization workflow with a Blacksmith macOS job that is neither reserved nor
# exempted there. auto-resume-nightly-notarization.yml was missing from the old release|nightly regex, so on
# 2026-10-30 12:43Z its three wait-and-staple jobs queued on blacksmith-6vcpu-macos-26 behind 22 pull request
# overflow jobs without holding the label.
# Match the workflow path only.  CI run names include routing metadata such as
# ``release=arm64``; looking at the combined name and path made every ordinary
# pull-request run look like a release reservation.
RESERVED_RELEASE_WORKFLOWS = frozenset({"release.yml"})


def reserves_pool(path: str | None, event: str | None = None) -> bool:
    """Whether a run of the workflow at `path` from `event` is freshness work whose queued jobs hold their pool: a
    release run, or a delivery run (delivery_workflows.delivers()). A pull request's test run of a delivery workflow
    holds nothing; an unread event counts as a delivery one."""
    name = Path(str(path or "").split("@", 1)[0]).name.lower()
    return name in RESERVED_RELEASE_WORKFLOWS or delivers(name, event)


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


# Fleet gate state, the gates' own view of each owned runner label, in the snapshot as `gates`. GitHub lists a
# runner whose glaeda gate holds its listener off as offline, the same as a dead one, so its runner list cannot tell
# a full label from a broken one. The fleet dashboard (cmuxterm-hq build-fleet/ci-dash, fleet_gates) reads each
# mini's probe and copies the reading into the CI_FLEET_GATES repository variable at least every 2 minutes; the
# workflow passes it in as FLEET_GATES (a variable costs no API request). The fields, per label:
#   listening        runners with their listener up and idle: a job queued for the label can start now
#   busy             runners running a job
#   held_offline     runners the gate holds off: {"total", "units", "cpu", "livelock", "other"}, where units is
#                    capacity units taken by jobs, livelock is free units the other gates' listen claims hold
#                    (glaeda#1751), cpu is the mini saturated at 80% CPU or more, and other is the rest (disk, a
#                    token, the host lock, a restart delay); total is their sum
#   down             offline with no hold (between jobs, or a listener that died)
#   unreported       on a mini whose probe failed in that pass
#   queued           the label's jobs waiting for a runner (not behind concurrency or an approval)
#   oldest_queued_s  the oldest of those, in seconds; 0 with none queued
#   as_of            when the dashboard read it (UTC), also once for the whole reading
# Staleness is the reader's to judge, against its own clock and as_of, never the snapshot's generated_at: a reading
# older than FLEET_GATES_STALE_S is stale, and a reader treats a stale or missing reading (no `gates` key, see
# `gates_error`) as full for a job queued over 3 minutes. The snapshot itself can be a sweep interval old, so a
# reading in it is often minutes old already; a workflow that can read ${{ vars.CI_FLEET_GATES }} gets it fresher.
FLEET_GATES_VERSION = 1
FLEET_GATES_STALE_S = 300
FLEET_GATES_COUNTS = ("listening", "busy", "down", "unreported", "queued", "oldest_queued_s")
FLEET_GATES_HELD = ("total", "units", "cpu", "livelock", "other")
FLEET_GATES_MAX_LABELS = 200


def fleet_gates(raw: str | None) -> tuple[dict[str, Any] | None, str | None]:
    """(reading, None) from the CI_FLEET_GATES variable's text, checked and cut to the fields above, or (None, why).

    Any field out of shape refuses the whole reading: a reader treats a missing one as full, which is the safe side.
    """
    if not (raw or "").strip():
        return None, "no CI_FLEET_GATES reading"
    try:
        data = json.loads(raw or "")
    except ValueError as error:
        return None, f"CI_FLEET_GATES is not JSON ({error})"
    if not isinstance(data, dict) or data.get("version") != FLEET_GATES_VERSION:
        return None, f"CI_FLEET_GATES is not version {FLEET_GATES_VERSION}"

    def stamp(value: Any) -> str | None:
        when = parse_time(value) if isinstance(value, str) and value.endswith("Z") else None
        return when.strftime("%Y-%m-%dT%H:%M:%SZ") if when else None

    def count(value: Any) -> bool:
        return isinstance(value, int) and not isinstance(value, bool) and value >= 0

    as_of = stamp(data.get("as_of"))
    labels = data.get("labels")
    if not as_of or not isinstance(labels, dict) or len(labels) > FLEET_GATES_MAX_LABELS:
        return None, "CI_FLEET_GATES has no as_of or no labels"
    out: dict[str, dict[str, Any]] = {}
    for label, row in labels.items():
        held = row.get("held_offline") if isinstance(row, dict) else None
        if (not isinstance(label, str) or not label.startswith("glaeda-") or not isinstance(held, dict)
                or not all(count(row.get(key)) for key in FLEET_GATES_COUNTS)
                or not all(count(held.get(key)) for key in FLEET_GATES_HELD)):
            return None, f"CI_FLEET_GATES label {str(label)[:80]!r} is out of shape"
        out[label] = {**{key: row[key] for key in FLEET_GATES_COUNTS[:2]},
                      "held_offline": {key: held[key] for key in FLEET_GATES_HELD},
                      **{key: row[key] for key in FLEET_GATES_COUNTS[2:]},
                      "as_of": stamp(row.get("as_of")) or as_of}
    return {"version": FLEET_GATES_VERSION, "as_of": as_of, "labels": dict(sorted(out.items()))}, None


MAX_ARTIFACT_PAGES = 5
# ci.yml's `changes` job uploads this marker when the picker chose an owned
# pool: macos-pool-persistent-<run>-<attempt>-<jobs>p<placed>-<pool>, where
# <jobs> is the machines held at peak and <placed> the owned jobs placed
# (post-admission jobs reuse admission's machine, so placed can exceed jobs).
# The E2E and iOS markers, and ones uploaded before `p<placed>`, omit it.
# workflow_dispatch workflows whose runner job may pick an owned pool and upload it.
OWNED_DISPATCH_WORKFLOWS = ("/test-e2e.yml", "/test-ios.yml", "/ios-screenshots.yml", "/cmux-next-ios-kit.yml", "/iroh-release-gate.yml",
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
    return ((run.get("event") == "pull_request" and (path.endswith("/ci.yml") or path.endswith("/cmux-next-ios-kit.yml"))) or
            (run.get("event") == "push" and path.endswith("/cmux-next-ios-kit.yml")))


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
    `reserved_queued` counts the queued jobs of release, nightly, DEV and
    promote runs (reserves_pool()); it is what tells a pull request to stay
    off a pool those runs are waiting on.
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
        reserved = reserves_pool(run.get("path"), run.get("event"))
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
            # A lane label (session, fast, dev, nightly) is no owned pool to the pickers, but its own queue: the
            # placements and the rescue read whether it runs anything (run 40887257098's daemon test waited
            # 3 h 20 min on glaeda-session-std-xcode-26.6 with no runner online, unseen here).
            lane = lane_label(job)
            macos = is_macos_job(job)
            if not macos and not lane:
                continue
            status = job.get("status")
            if status not in POOL_QUEUED_JOB_STATUSES and status not in RUNNING_JOB_STATUSES:
                continue
            # A lane job counts on its lane label whatever else it asked for (`macOS`, `self-hosted`), and on its
            # macOS pool as before.
            counted = (*counted_pools(runner_pool(job)), *capabilities(job)) if macos else ()
            for pool in dict.fromkeys(((lane,) if lane else ()) + counted):
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
        LABEL_STARTED_KEY: label_started(runs, jobs_by_run),
        "settings": dict(settings or {}),
    }


# The snapshot's map of each macOS runner label (an owned pool, a lane, a Blacksmith macOS label) to when a runner
# last took a job that asked for exactly that label, among the in-flight runs listed (label_started()).
LABEL_STARTED_KEY = "label_started"


def label_started(runs: Sequence[Mapping[str, Any]],
                  jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]]) -> dict[str, str]:
    """When a runner last took a job on each macOS runner label: the newest `started_at` of a listed job a runner
    took (runner_name or runner_id; a queued job's started_at is only its creation), running or finished, keyed by
    each owned, lane or macOS label it asked for exactly (no root or capability rollup, as `pools` has).

    The rescue's stall-aware failover reads it (owned_pool_rescue.label_quiet()): a label whose pool count shows a
    job running but that started nothing while a job waited is no queue that job is moving in. Run 40993742146's
    fast tier waited five hours on glaeda-side-std-xcode-26.6 while that label ran one job started before it queued
    (2026-10-30). Only in-flight runs are listed, so a start in a run that has finished is not seen: the time errs
    old, which can only offer a re-placement, never cancel a started job."""
    newest: dict[str, dt.datetime] = {}
    for run in runs:
        for job in jobs_by_run.get(run.get("id"), ()):
            if not (job.get("runner_name") or job.get("runner_id")) or job.get("conclusion") == "skipped":
                continue
            if job.get("status") not in RUNNING_JOB_STATUSES and job.get("status") != "completed":
                continue
            started = parse_time(job.get("started_at"))
            if started is None:
                continue
            for label in {str(item) for item in job.get("labels") or ()}:
                if not (owned_pool(label) or LANE_LABEL.fullmatch(label) or "macos" in label.lower()):
                    continue
                if label not in newest or started > newest[label]:
                    newest[label] = started
    return {label: moment.strftime("%Y-%m-%dT%H:%M:%SZ") for label, moment in sorted(newest.items())}


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
    # Category e at an open pull request's head: this sweep re-runs it as cmux-bot once the cancel
    # settles (rerun_open_head()), and the pending entry carries it otherwise (open_head_lost()).
    open_head: bool = False
    # That re-run is of this job alone, not the run's failed jobs (LostVerdict.rerun_job).
    rerun_job: int | None = None


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


def may_need(job: Mapping[str, Any], other: Mapping[str, Any]) -> bool:
    """`other`, a job of the same run, may be one of `job`'s `needs`: it was created before `job`.

    The jobs API names no `needs`, but GitHub creates a job's record only once
    its `needs` have finished, so a need always predates its dependent. A
    sibling created at the same moment or later came from the same or a later
    completion and cannot be what `job` waits on. Run 41158893861 (2026-10-31):
    `GhosttyKit release check` (job 124413283263, needs `changes`) was created
    at 02:18:12Z, the second `changes` finished, beside `web / runners` and
    `web / web-subarea-scope`; the `web / react-*` jobs were created at 02:30Z
    and 02:43Z as their own needs finished, and `ci-status`, which needs every
    job, had no record at all. Counting those later jobs as possible gates kept
    the job, queued with no runner while a newer job on its label started,
    from ever being found lost. A sibling or job with no `created_at` may be a
    need, which errs toward leaving the job alone.
    """
    if other is job:
        return False
    created, other_created = parse_time(job.get("created_at")), parse_time(other.get("created_at"))
    return created is None or other_created is None or other_created < created


def lost_wait_start(job: Mapping[str, Any], run_jobs: Iterable[Mapping[str, Any]]) -> dt.datetime | None:
    """When the job could first have run: its `created_at`, or the last completion among the jobs it may need.

    The jobs API names no `needs`, so the completion of any sibling that may
    be one (may_need(): created before the job) may be the one it waited for.
    Taking the latest errs toward a later start, and so toward leaving a job
    alone. Such a sibling not finished yet may be the gate too, so the wait
    counts only once none is left (_gated()).
    """
    created = parse_time(job.get("created_at"))
    if created is None:
        return None
    finished = [parse_time(other.get("completed_at")) for other in run_jobs
                if may_need(job, other) and other.get("status") == "completed"]
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
    # The job's id: in a run that already failed, the failover re-runs this job alone (open_head_lost()).
    job_id: int | None = None
    # Every lost job of the run (their ids), this one among them: a failed run whose unfinished jobs are all
    # lost re-runs its failed jobs, bringing every one of them back (open_head_lost()).
    job_ids: tuple[int, ...] = ()


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
    Nor is a sibling no suspect may need (may_need(): created with or after
    every suspect), running or not: the run cannot finish without the lost
    job, a cancel's re-run brings the sibling back with it, and in run
    41158893861 such siblings were created in waves (02:30Z, 02:43Z, 02:57Z)
    and kept running beside the lost `GhosttyKit release check` until a
    runner took it at 02:59Z, 41 minutes in.
    """
    suspects = list(suspects)
    exempt = {id(job) for job in suspects}
    return any(job.get("status") != "completed" and id(job) not in exempt
               and any(may_need(suspect, job) for suspect in suspects) for job in run_jobs)


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
                job_id = job.get("id") if isinstance(job.get("id"), int) else None
                found.append((job, LostJob(str(job.get("name") or ""), job_pool_key(job), since, skipped, job_id)))
        if found and not _gated(run_jobs, [job for job, _ in found]):
            oldest = min((item for _, item in found), key=lambda item: item.queued_since)
            ids = tuple(item.job_id for _, item in found if item.job_id is not None)
            lost[run["id"]] = dataclasses.replace(oldest, job_ids=ids if len(ids) == len(found) else ())
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


OPEN_HEAD_RULE = ("never cancelled: an open pull request's run at its head is never cancelled by anything "
                  "automatic; the controller's fall-through moves its compile instead")
# The one exception (classify_lost(), open_head): a job GitHub never assigned at an open pull request's head is
# the stall-aware failover, cancelled and re-run at the same head in the same sweep (rerun_open_head()).
OPEN_HEAD_FAILOVER = ("stall-aware failover at the open head: cancelled and its failed jobs re-run as cmux-bot "
                      "at the same head in this sweep (or the next, if the cancel has not settled)")
OPEN_HEAD_JOB_FAILOVER = ("stall-aware failover at the open head: the run already failed, so it is cancelled and "
                          "only the lost job is re-run as cmux-bot at the same head, keeping that red, in this sweep "
                          "(or the next, if the cancel has not settled)")
OPEN_HEAD_LOST_JOBS_FAILOVER = ("stall-aware failover at the open head: the run already failed and every unfinished "
                                "job is lost, so it is cancelled and its failed jobs (the red among them) re-run as "
                                "cmux-bot at the same head in this sweep (or the next, if the cancel has not settled)")
# A bot's re-run (bot_rerun()) whose job is lost again fails over again while its attempt is below this: the
# janitor's own attempt 2 of a cmux-next fast tier takes CI_SIDE_LANE_RUNNER again, the backed-up label it was
# lost on, and attempt 3 takes MACOS_RUNNER_26. On 2026-10-31 at 12:49Z 28 of the 30 lost runs kept at open
# heads were such attempts, PR #29228's `cmux-next fast tier` 2h46m among them, held by the old "never cancel a
# bot's attempt again" rule. That rule dates from run 40398277457, whose cancel waited on a later sweep's re-run
# and got none; the same sweep re-runs it now (rerun_open_head()), so the bound only keeps the loop finite.
LOST_FAILOVER_MAX_ATTEMPT = 3


def open_pr_at_head(run: Mapping[str, Any], prs: Sequence[Mapping[str, Any]] | None) -> Mapping[str, Any] | None:
    """The open pull request whose head is this run's head, or None.

    The one predicate every cancelling path checks first (categories a-f and
    the orphan pass): nothing the janitor does automatically cancels such a
    run, except category e's stall-aware failover of a job GitHub never
    assigned (classify_lost(), OPEN_HEAD_FAILOVER), which re-runs it at once
    at the same head. Run 40398277457 (cmux-next, PR #25446 at 8be738c84d8) attempt 2 was
    cancelled at its head for a Blacksmith leg (category f) and stayed
    cancelled until a person re-ran it: the carried re-run needs a later
    sweep, and the janitor's concurrency group evicts pending sweeps. Any run
    whose event names that commit counts (pull_request, a push or dispatch at
    it), from the head's own repository owner; a pull_request run whose
    resolved PR is open with no head read is counted too. A branch whose open
    pull requests were not all read (OPEN_PRS_UNREAD, parse_graphql_prs())
    fails closed: that marker is returned, whatever the run.
    """
    unread = next((pr for pr in prs or () if pr.get(OPEN_PRS_UNREAD)), None)
    if unread is not None:
        return unread
    sha = str(run.get("head_sha") or "")
    owner = run_head_owner(run)
    for pr in prs or ():
        pr_owner = str(((pr.get("headRepositoryOwner") or {}).get("login")) or "").lower()
        if pr.get("state") == "OPEN" and sha and pr.get("headRefOid") == sha and pr_owner == owner:
            return pr
    if run.get("event") in ("pull_request", "pull_request_target"):
        pr = resolve_pull_request(run, prs or ())
        if pr is not None and pr.get("state") == "OPEN" and not pr.get("headRefOid"):
            return pr
    return None


@dataclasses.dataclass(frozen=True)
class LostVerdict:
    action: str  # "cancel" or "skip"
    reason: str
    note: str = ""
    rerun: bool = False
    pr: Mapping[str, Any] | None = None
    # The cancel is at an open pull request's head: this sweep re-runs it as cmux-bot (rerun_open_head()).
    open_head: bool = False
    # Re-run this job alone (POST /actions/jobs/{id}/rerun) instead of the run's failed jobs: the run already
    # failed, and re-running its failed jobs would repeat that red (open_head_lost()).
    rerun_job: int | None = None


def open_head_lost(run: Mapping[str, Any], run_jobs: Sequence[Mapping[str, Any]], evidence: str,
                   pr: Mapping[str, Any], *, rerun_state: bool, newer: Mapping[str, Any] | None,
                   cmux_bot: bool, lost_job_id: int | None = None,
                   lost_job_ids: Sequence[int] = ()) -> LostVerdict:
    """Category e at the head of open pull request `pr`: the stall-aware failover, or OPEN_HEAD_RULE.

    A job GitHub never assigned (runner_id 0, no runner name), queued 30 minutes or more since it could run
    while newer jobs on exactly its labels started (find_lost()), is cancelled and its failed jobs re-run at
    the same head, as cmux-bot, in the same sweep (rerun_open_head()); the pending re-run state carries it
    to the next sweep when the cancel has not settled or the re-run was refused. Leo's rulebook, as the
    coordinator approved it on 2026-10-30: this is the stall-aware failover, the run comes back at the same
    head, and it never applies to a started nightly, DEV or promote build. Everything else at an open head
    keeps OPEN_HEAD_RULE:
    - a branch whose open pull requests were not all read (OPEN_PRS_UNREAD);
    - a nightly, DEV or promote run (_lost_scope() already leaves out protected runs; checked again here);
    - an attempt a bot started (bot_rerun()) at LOST_FAILOVER_MAX_ATTEMPT or later. Run 40398277457, the
      rescue's attempt 2, was cancelled at its head and never re-run, because its re-run waited on a later
      sweep; this sweep re-runs what it cancels (rerun_open_head()), so a bot's attempt below the bound that
      is lost again fails over again, and the bound keeps that finite;
    - a run that already failed, unless its unfinished jobs are all lost. When the lost job (`lost_job_id`)
      is the only one, the cancel kills nothing else and only that job is re-run (`rerun_job`, POST
      /actions/jobs/{id}/rerun), so the red stays as it is. Run 41150189497 (PR #28544, 2026-10-31):
      `cmux-next fast tier` on glaeda-side-std-xcode-26.6 queued from 00:36Z with no runner while newer jobs
      on that label ran, kept here for 2.5 hours because `cmux-next swift test` had failed, until a person
      failed it over by hand. When several are (`lost_job_ids`), a one-job re-run would leave the others
      cancelled, so the run's failed jobs are re-run, the red among them: run 41192867338 (PR #28562,
      2026-10-31) held `cmux-next fast tier` and `cmux-next swift test` lost for 2h16m beside a failed
      `cmux-next daemon tests`. Any other unfinished job keeps the rule;
    - a run a newer run at its head took over, which reports for that head;
    - no re-run state (rerun_state) or no cmux-bot token this sweep (cmux_bot): the cancel could not be
      carried or re-run as cmux-bot, so nothing is cancelled.
    """
    reason = f"{evidence}; at the head of open PR #{pr.get('number')}"

    def keep(why: str) -> LostVerdict:
        return LostVerdict("skip", f"{reason} ({why})", OPEN_HEAD_RULE, pr=pr)

    if pr.get(OPEN_PRS_UNREAD):
        return keep("the branch's open pull requests were not all read")
    if protected_reason(run) is not None or is_delivery_run(str(run.get("path") or ""), run.get("name"),
                                                            run.get("display_title")):
        return keep("a nightly, DEV or promote run")
    if bot_rerun(run) and int(run.get("run_attempt") or 1) >= LOST_FAILOVER_MAX_ATTEMPT:
        return keep(f"attempt {run.get('run_attempt')} is a bot's re-run")
    failed = any(job.get("status") == "completed" and job.get("conclusion") == "failure" for job in run_jobs)
    unfinished = [job.get("id") for job in run_jobs if job.get("status") != "completed"]
    alone = lost_job_id is not None and unfinished == [lost_job_id]
    all_lost = len(unfinished) > 1 and None not in unfinished and set(unfinished) <= set(lost_job_ids)
    if failed and not (alone or all_lost):
        return keep("the run already failed, and a re-run of its failed jobs would repeat that red")
    if newer is not None:
        return keep(f"newer run {newer.get('id')} at its head took over")
    if not rerun_state:
        return keep("no re-run state to fall back on")
    if not cmux_bot:
        return keep("no cmux-bot token this sweep to re-run it")
    if failed and alone:
        return LostVerdict("cancel", f"{reason}: {OPEN_HEAD_JOB_FAILOVER}", rerun=True, pr=pr, open_head=True,
                           rerun_job=lost_job_id)
    if failed:
        return LostVerdict("cancel", f"{reason}: {OPEN_HEAD_LOST_JOBS_FAILOVER}", rerun=True, pr=pr, open_head=True)
    return LostVerdict("cancel", f"{reason}: {OPEN_HEAD_FAILOVER}", rerun=True, pr=pr, open_head=True)


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
    cmux_bot: bool = False,
) -> LostVerdict | None:
    """What category e does with a run holding a lost job, or None to leave it to the other categories.

    `prs` is the lookup for the run's branch, None when the branch was not
    looked up (then nothing is known, and nothing is done). find_lost()
    already left alone any run with another job unfinished, so no cancel
    kills readable work. A stale run is cancelled: nobody reads it. A run at
    the current head of an open pull request (open_pr_at_head()) is cancelled
    and re-run at that head in the same sweep, as cmux-bot (the stall-aware
    failover), or else keeps OPEN_HEAD_RULE: open_head_lost() has the rules
    (`cmux_bot`: this sweep's token is cmux-bot's). A push or dispatch run at its live branch
    head is cancelled so that a later sweep re-runs its failed jobs, except:
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
    at_head = open_pr_at_head(run, prs)
    if at_head is not None:
        return open_head_lost(run, run_jobs, evidence, at_head, rerun_state=rerun_state, newer=newer,
                              cmux_bot=cmux_bot, lost_job_id=lost.job_id, lost_job_ids=lost.job_ids)
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


# Branches whose push and dispatch runs are never cancelled for a moved head: their tip moves on every merge, and a
# run there (feat-cmux-next's tip suites, which base-red judgment reads) is the base's signal, not a superseded try.
LONG_LIVED_BRANCHES = frozenset({"main", "feat-cmux-next", "nightly-next"})


def stale_head_cancellable(run: Mapping[str, Any]) -> bool:
    """Whether category f may cancel `run` once its head is stale (lost_pr_state() "stale"): a push or dispatch on a
    short-lived branch that moved on or is gone, and no nightly, DEV or promote run (delivery_workflows.delivers()).

    Its output is never read, like a superseded pull request run's (category b), so the cancel carries no re-run.
    Before this, a stale run's unclaimed leg was left to the orphan pass (120 minutes, and only once a newer job on
    its labels got a runner): on 2026-10-30 five dispatches at moved or deleted lane heads held
    glaeda-side-std-xcode-26.6 queue places for two to three and a half hours (runs 41066827744, 41077686537,
    41081194145, 41080779296, 41095093014).
    """
    branch = str(run.get("head_branch") or "")
    return (run.get("event") in ("push", "workflow_dispatch") and bool(branch)
            and branch not in LONG_LIVED_BRANCHES and not branch.startswith("rc/")
            and not delivers(run.get("path"), run.get("event"), run.get("name"), run.get("display_title")))


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

    Only a run at a live head is moved (lost_pr_state() "current"): a push
    or dispatch at its branch's head. One at the head of an open pull request
    is listed as skipped and never cancelled (open_pr_at_head(),
    OPEN_HEAD_RULE). A push or dispatch on a short-lived branch whose head is
    stale (the branch moved on or is gone; stale_head_cancellable()) is
    cancelled and not re-run, as category e does: nobody reads its output.
    Any other stale or unknown run is left to category b and the orphan pass
    (None, so it is not even listed). A current run is cancelled for a later
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
    # Only a head read this sweep says stale: lost_pr_state() calls a push with an unread head stale too.
    stale = state == "stale" and branch_head is not None and stale_head_cancellable(run)
    if state != "current" and not stale:
        return None
    if pr is not None and JANITOR_OPT_OUT_LABEL in pr_labels(pr):
        return LostVerdict("skip", evidence, f"PR #{pr.get('number')} is labelled `{JANITOR_OPT_OUT_LABEL}`", pr=pr)
    if pr is not None and not labels_complete(pr):
        return LostVerdict("skip", evidence, f"PR #{pr.get('number')} has more labels than were read", pr=pr)
    at_head = open_pr_at_head(run, prs)
    if at_head is not None:
        return LostVerdict("skip", f"{evidence}; at the head of open PR #{at_head.get('number')}", OPEN_HEAD_RULE,
                           pr=at_head)
    if stale:
        # Nobody reads a stale head's output (category b's rule for a superseded pull request run), so it is
        # cancelled whatever its attempt or its re-run route, and never re-run.
        return LostVerdict("cancel", f"{evidence}; {why}: a stale head, so it is not re-run", pr=pr)
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
    labels left unread), or a category-f run (`unclaimed`) whose re-run would stay on the owned label. The
    exception is a category-f run stale_head_cancellable() covers: a stale head cancels it with no re-run,
    so its head is read whatever its attempt, its failures or its re-run route.
    """
    wanted = set(run_ids)
    in_f = set(unclaimed)
    seen = set(known)
    branches: list[str] = []
    for run in sorted(runs, key=lambda item: (str(item.get("created_at") or ""), int(item.get("id") or 0))):
        branch = str(run.get("head_branch") or "")
        # A category-f run on a short-lived branch is cancelled once its head is stale (stale_head_cancellable()),
        # whatever its attempt or its re-run would do, so its head is worth a read either way.
        stale_eligible = run.get("id") in in_f and stale_head_cancellable(run)
        if run.get("id") not in wanted or run.get("event") not in ("push", "workflow_dispatch") or not branch \
                or branch in seen or (bot_rerun(run) and not stale_eligible):
            continue
        if run.get("id") in in_f and not stale_eligible and not rescue.bot_rerun_leaves_owned(
                str(run.get("path") or ""), int(run.get("run_attempt") or 1)):
            continue
        if not stale_eligible and jobs_by_run is not None and any(
                job.get("status") == "completed" and job.get("conclusion") == "failure"
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
    """Pending re-run entries for this sweep's category-e cancels that took and asked for one.

    A cancel whose POST failed (CANCEL_SENT) may have taken anyway: its entry is kept too, marked
    `cancel_unconfirmed`, and a later sweep's plan_lost_reruns() re-runs it once the run has completed as
    cancelled, keeps it while it is still in flight, and drops it once it finished any other way."""
    entries = []
    for candidate in candidates:
        result = results.get(candidate.run["id"]) or ""
        unconfirmed = result.startswith(CANCEL_SENT)
        if candidate.rerun and (result == "cancelled" or result.startswith("force-cancelled") or unconfirmed):
            run = candidate.run
            entry = {"run_id": run["id"], "attempt": int(run.get("run_attempt") or 1),
                     "head_sha": str(run.get("head_sha") or ""), "branch": str(run.get("head_branch") or ""),
                     "cancelled_at": _iso(now)}
            if candidate.app_actor:
                entry["app_actor"] = True
            if candidate.open_head:
                # At an open pull request's head: only cmux-bot re-runs it (rerun_open_head(), plan_lost_reruns()).
                entry["open_head"] = True
            if candidate.rerun_job is not None:
                # The run already failed: only this job is re-run (rerun_lost()).
                entry["job_id"] = candidate.rerun_job
            if unconfirmed:
                entry["cancel_unconfirmed"] = True
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
    cmux_bot: bool = False,
    rerun_cap: int | None = None,
    dispatch_runs: Mapping[int, Sequence[Mapping[str, Any]]] | None = None,
    dispatch_jobs: Mapping[int, Sequence[Mapping[str, Any]]] | None = None,
) -> list[LostRerun]:
    """Which pending category-e and category-f cancels, and orphaned dispatches, to re-run now.

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
    Blacksmith leg) is kept while this sweep has none (`app_token`), and one
    cancelled at an open pull request's head (`open_head`, open_head_lost())
    while this sweep's token is not cmux-bot's (`cmux_bot`). At most `rerun_cap`
    (LOST_RERUN_MAX by default) are re-run; main() shares that one allowance
    between rerun_open_head() and the pending entries.

    An orphaned dispatch's entry (`dispatch`, orphan_reruns()) is judged by its run alone: once its cancel has
    settled at the same attempt and head it is re-run, unless a newer dispatch of its kind took its job
    (superseding_dispatch() over `dispatch_runs`, run id -> its workflow's dispatches on its branch, and
    `dispatch_jobs`, run id -> jobs). Its branch moving on is no reason: it tests a long-lived branch's commit.
    One whose dispatches were not listed this sweep is kept.
    """
    cap = LOST_RERUN_MAX if rerun_cap is None else max(0, rerun_cap)
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
        if isinstance(entry.get("dispatch"), Mapping):
            job = str(entry["dispatch"].get("job") or "")
            if dispatch_runs is None or run_id not in dispatch_runs:
                decisions.append(LostRerun(entry, "keep", "newer dispatches not listed this sweep", run))
                continue
            newer = superseding_dispatch(entry, run, dispatch_runs[run_id], dispatch_jobs or {})
            if newer is not None:
                decisions.append(LostRerun(entry, "drop", f"not re-run: newer dispatch {newer.get('id')} took "
                                                          f"`{job}`", run))
                continue
            if reruns >= cap:
                decisions.append(LostRerun(entry, "keep", f"re-run cap of {LOST_RERUN_MAX} a sweep reached", run))
                continue
            reruns += 1
            decisions.append(LostRerun(entry, "rerun", f"orphaned dispatch: no newer dispatch took `{job}`", run))
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
        if entry.get("open_head") and not (cmux_bot and app_token):
            decisions.append(LostRerun(entry, "keep", "needs cmux-bot's re-run; this sweep has no cmux-bot token", run))
            continue
        if reruns >= cap:
            decisions.append(LostRerun(entry, "keep", f"re-run cap of {LOST_RERUN_MAX} a sweep reached", run))
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


def rerun_open_head(
    github: GitHub,
    entries: Sequence[Mapping[str, Any]],
    *,
    now: dt.datetime,
    inventory: Sequence[Mapping[str, Any]] = (),
    reads: int = LOST_SETTLE_READS,
    interval_s: float = LOST_SETTLE_INTERVAL_S,
    budget_s: float = LOST_SETTLE_BUDGET_S,
    reserve_s: float = LOST_RECOVERY_RESERVE_S,
    rerun_cap: int = LOST_RERUN_MAX,
) -> tuple[list[LostRerun], list[dict[str, Any]], dict[int, str], int]:
    """Re-run, in the sweep that cancelled them, the lost jobs category e cancelled at an open PR's head.

    `entries` are this sweep's pending entries for those cancels (new_lost_reruns(), `open_head`), already
    saved in the snapshot. Each run is read up to `reads` times, `interval_s` apart, all of them together,
    until its cancel has settled. Then the pull requests of their branches and the runs at each settled
    run's head (plus `inventory`, this sweep's in-flight runs) are read again, and plan_lost_reruns()
    judges every entry as a later sweep would: a pull request a push moved past the run's head, a newer
    run at its head (even one already green), an opt-out label or another attempt drops it, so a re-run
    never lands on an old head and cancels the new head's CI through a shared concurrency group. What it
    keeps is re-run as cmux-bot (rerun_lost(), app_only: never on the workflow's token, whose re-run is
    github-actions[bot]'s).

    All of it, requests, their retries and their socket timeouts included, ends within `budget_s` of the
    first read (GitHub.deadline): the job's timeout skips the snapshot upload that carries an entry to the
    next sweep. The wait itself stops `reserve_s` before that, so the cancels that did settle still get
    their reads and re-runs when another never settles. At most `rerun_cap` are re-run. Returns (decisions, entries still pending, results, failures): an entry whose cancel did not
    settle in time, whose run or pull request could not be read, or whose re-run GitHub refused stays
    pending, and the next sweep's plan_lost_reruns() re-runs it (run 40398277457 stayed cancelled because
    its re-run waited on a later sweep with no state to find it; here the state is written before the first
    read).
    """
    deadline = time.monotonic() + budget_s
    wait_until = deadline - min(reserve_s, budget_s)
    waiting = {int(entry["run_id"]): entry for entry in entries}
    seen: dict[int, Mapping[str, Any]] = {}
    previous = github.deadline
    github.deadline = deadline
    try:
        for read in range(max(1, reads)):
            for run_id in list(waiting):
                if time.monotonic() >= wait_until:
                    break
                try:
                    run = github.run(run_id)
                except Exception as error:  # noqa: BLE001 the entry stays pending for the next sweep
                    print(f"queue-janitor: open-head re-run of run {run_id}: {error!r}", file=sys.stderr)
                    continue
                seen[run_id] = run
                if run.get("status") == "completed":
                    del waiting[run_id]
            pause = min(interval_s, wait_until - time.monotonic())
            if not waiting or read == reads - 1 or pause <= 0:
                break
            time.sleep(pause)
        settled = {run_id: run for run_id, run in seen.items() if run_id not in waiting}
        branches = sorted({str(entry.get("branch") or "") for entry in entries if int(entry["run_id"]) in settled})
        prs_now: dict[str, Sequence[Mapping[str, Any]]] = {}
        if branches and time.monotonic() < deadline:
            try:
                prs_now = github.pull_requests(branches)
            except Exception as error:  # noqa: BLE001 every entry is kept: "pull request lookup missing"
                print(f"queue-janitor: open-head re-run: pull requests: {error!r}", file=sys.stderr)
        head_runs: dict[int, list[Mapping[str, Any]]] = {}
        for run_id, run in settled.items():
            if run.get("conclusion") != "cancelled" or time.monotonic() >= deadline:
                continue
            try:
                head_runs[run_id] = [*github.runs_at_head(run), *inventory]
            except Exception as error:  # noqa: BLE001 the entry is kept: "runs at its head not listed"
                print(f"queue-janitor: open-head re-run: runs at the head of run {run_id}: {error!r}",
                      file=sys.stderr)
        judged = {id(decision.entry): decision for decision in plan_lost_reruns(
            [entry for entry in entries if int(entry["run_id"]) in settled], settled, prs_now, now=now,
            head_runs=head_runs, app_token=github.app_token, cmux_bot=True, rerun_cap=rerun_cap)}
        decisions: list[LostRerun] = []
        for entry in entries:
            run_id = int(entry["run_id"])
            if run_id in waiting:
                run = seen.get(run_id)
                why = f"cancel not settled ({run.get('status')})" if run else "run not readable"
                decisions.append(LostRerun(entry, "keep", f"{why} within the wait; the next sweep re-runs it", run))
                continue
            decision = judged[id(entry)]
            if decision.action == "rerun" and time.monotonic() >= deadline:
                decision = LostRerun(entry, "keep", "the wait ran out; the next sweep re-runs it", decision.run)
            elif decision.action == "rerun":
                decision = LostRerun(entry, "rerun", f"open PR head: the cancel settled, {decision.note}; "
                                     "re-run as cmux-bot", decision.run)
            decisions.append(decision)
        pending, results, failures = rerun_lost(github, decisions)
    finally:
        github.deadline = previous
    return decisions, pending, results, failures


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
    cmux_bot_rerun: bool = False,
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
    `cmux_bot_rerun` (this sweep's token is cmux-bot's) lets category e fail
    a lost job over at an open pull request's head (open_head_lost()).
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
                    rerun_state=rerun_state, newer=newer, branch_head=heads.get(branch),
                    cmux_bot=cmux_bot_rerun)
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
                                            rerun=lost_verdict.rerun, app_actor=app_actor,
                                            open_head=lost_verdict.open_head, rerun_job=lost_verdict.rerun_job))
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
        at_head = open_pr_at_head(run, prs_by_branch.get(branch, ())) if verdict else None
        if verdict and at_head is not None:
            # Categories a-d (label-dropped and doomed only ever judge a run at its open PR's head; b's run can
            # share its head with another open PR from the same branch).
            lost_skips.append(Decision(Candidate(run, verdict[0], verdict[1], usage, at_head), "skip",
                                       OPEN_HEAD_RULE))
        elif verdict:
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
    """PR branches worth one GraphQL lookup: PR runs and experiment pushes that hold macOS jobs.

    An experiment push (category a) is looked up so that one at an open pull
    request's head is never cancelled (open_pr_at_head()).
    """
    branches = set()
    for run in runs:
        experiment = run.get("event") == "push" and str(run.get("head_branch") or "").startswith(
            EXPERIMENT_BRANCH_PREFIXES)
        if (run.get("event") != "pull_request" and not experiment) or protected_reason(run):
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


# Open pull requests per branch, beside the five newest: open_pr_at_head() must see an open one however many
# newer closed ones the branch has. When a branch has more open ones than this (forks, several bases), the
# lookup is incomplete and the branch fails closed: OPEN_PRS_UNREAD marks it, and nothing on it is cancelled.
OPEN_PRS_PER_BRANCH = 20
OPEN_PRS_UNREAD = "openPullRequestsUnread"
OPEN_PR_FIELDS = """
        number state headRefOid url
        headRepositoryOwner { login }
        labels(first: 100) { pageInfo { hasNextPage } nodes { name } }
"""


def graphql_query(owner: str, name: str, branches: Sequence[str]) -> tuple[str, dict[str, Any]]:
    """One query that resolves every branch to its recent pull requests, and to every open one (o<index>)."""
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
        fields.append(
            f"    o{index}: pullRequests(headRefName: $b{index}, states: [OPEN], first: {OPEN_PRS_PER_BRANCH}) "
            f"{{\n      pageInfo {{ hasNextPage }}\n      nodes {{{OPEN_PR_FIELDS}      }}\n    }}"
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
        nodes = list(connection.get("nodes") or [])
        # An open pull request older than the five newest joins with the fields it was read with.
        seen = {node.get("number") for node in nodes}
        open_connection = repository.get(f"o{index}") or {}
        nodes += [node for node in (open_connection.get("nodes") or []) if node.get("number") not in seen]
        if (open_connection.get("pageInfo") or {}).get("hasNextPage"):
            # More open pull requests than were read: one of them may be at a run's head. This node has no
            # state or owner, so every other reader skips it; open_pr_at_head() returns it (fail closed).
            nodes.append({"number": "?", OPEN_PRS_UNREAD: True})
        result[branch] = nodes
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


def render_open_head_reruns(decisions: Sequence[LostRerun], results: Mapping[int, str], *, freed: int) -> str:
    """This sweep's stall-aware failovers at open PR heads (rerun_open_head()), with the count it freed."""
    if not decisions:
        return ""
    lines = ["", "### Lost jobs failed over at open PR heads", "",
             f"**Freed: {freed}** of {len(decisions)} lost job run(s) cancelled at an open pull request's head "
             "were re-run as cmux-bot at the same head in this sweep; the rest are kept for the next sweep or "
             "dropped as noted.", "",
             "| Decision | Run | Attempt | Note |", "| --- | --- | --- | --- |"]
    for decision in decisions:
        run_id = decision.entry.get("run_id")
        if decision.action == "rerun":
            verb = results.get(run_id) or "re-run failed jobs"
        else:
            verb = "keep for the next sweep" if decision.action == "keep" else "drop"
        url = (decision.run or {}).get("html_url") or f"run {run_id}"
        note = decision.note.replace("|", "\\|")
        lines.append(f"| {verb.replace('|', '/')} | {url} | {decision.entry.get('attempt')} | {note} |")
    # One line the PR body's freed count is read from (grep "open-head failover freed").
    lines += ["", f"_open-head failover freed {freed} lost job run(s) this sweep._"]
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
    # The lost job's id, for a re-run of that job alone (orphan_reruns()).
    job_id: int | None = None


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
                found = Orphan(run, evidence, str(job.get("name") or ""), queued_at, running,
                               job.get("id") if isinstance(job.get("id"), int) else None)
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
    a main schedule or TestFlight upload only lets the next one start
    (ios-appstore-upload.yml does not count a cancelled run as an upload). A
    release that stopped halfway, or a merge-queue check, is not the
    janitor's to end. Neither is a nightly, DEV or promote build of classic
    or NEXT (delivery_workflows.py): "Never cancel a nightly, dev or promote
    build or its Release compile once it has started ... unless it is stuck
    past its timeout or certain to fail." A job waiting for a runner is
    neither; the sweep reports it so the pool gets capacity. Run 40428578701
    (a DEV publish whose verify job waited 126 minutes) was cancelled here
    on 2026-10-27 while its tip job had just started.
    """
    event = run.get("event") or ""
    branch = run.get("head_branch") or ""
    if event in ORPHAN_PROTECTED_EVENTS:
        return f"{event} event"
    if TAG_LIKE_REF.match(branch):
        return f"tag-like ref {branch}"
    # Match the workflow path only, as reserves_pool() does: ci.yml's
    # run name carries `release=arm64`, which kept an orphaned main dispatch
    # holding CI's concurrency group (and every later main run pending).
    if ORPHAN_PROTECTED_WORKFLOW.search(str(run.get("path") or "")):
        return "release/publish workflow"
    if delivers(run.get("path"), event, run.get("name"), run.get("display_title")):
        return "nightly/DEV/promote delivery workflow; needs runner capacity, never a cancel"
    if event == "push" and branch in PROTECTED_PUSH_BRANCHES - {"main"}:
        # Listed since follows_another_copy(): a feat-cmux-next push gates the nightly-next build,
        # which is cancelled only when stuck past its timeout (ci.yml's main pushes are listed as before).
        return f"push to {branch}"
    return None


PULL_REQUEST_EVENTS = ("pull_request", "pull_request_target")


# --- superseded delivery runs ----------------------------------------------------------------------------------
SUPERSEDED_MAX_CANCELS = 10
# A candidate with no newer run among the in-flight ones gets one listing of its workflow's runs on its branch
# (the newer run may have finished already); at most this many listings a sweep.
SUPERSEDED_BRANCH_LISTINGS = 3
# Delivery runs whose jobs the sweep did not list (queued past GHOST_QUEUED_RUN_AGE): at most this many read a sweep.
SUPERSEDED_EXTRA_JOBS = 5
# Jobs of newer runs the sweep did not list (a finished one found by a branch listing): at most this many a sweep.
SUPERSEDED_REPLACEMENT_READS = 5


def complete_jobs(jobs: Sequence[Mapping[str, Any]] | None) -> Sequence[Mapping[str, Any]] | None:
    """A job listing, or None (unread) when it filled every page GitHub.jobs() reads, so some jobs may be missing."""
    return None if jobs is None or len(jobs) >= 100 * MAX_JOB_PAGES else jobs


def superseded_candidates(runs: Sequence[Mapping[str, Any]],
                          jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]]) -> list[Mapping[str, Any]]:
    """In-flight nightly, DEV or promote runs whose build has not started (no I/O), oldest first."""
    found = [run for run in runs
             if run.get("status") in IN_FLIGHT_RUN_STATUSES and run.get("id") in jobs_by_run
             and is_delivery_run(run.get("path"), run.get("name"), run.get("display_title"))
             and complete_jobs(jobs_by_run[run["id"]]) is not None
             and (mine := attempt_jobs(run, jobs_by_run[run["id"]])) is not None and build_started(mine) is None]
    return sorted(found, key=lambda run: (str(run.get("created_at") or ""), run["id"]))


@dataclasses.dataclass
class SupersededDecision:
    run: Mapping[str, Any]
    action: str  # "cancel" or "keep"
    note: str


def skip_superseded_delivery(
    github: "GitHub",
    candidates: Sequence[Mapping[str, Any]],
    runs: Sequence[Mapping[str, Any]],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
    prs_by_branch: Mapping[str, Sequence[Mapping[str, Any]]],
    *,
    dry_run: bool,
    max_cancels: int = SUPERSEDED_MAX_CANCELS,
    now: dt.datetime | None = None,
) -> tuple[list[SupersededDecision], int]:
    """Cancel each candidate delivery_workflows.superseded_unstarted() allows, re-reading its jobs first."""
    decisions: list[SupersededDecision] = []
    failures = 0
    listed: dict[tuple[Any, str], list[Mapping[str, Any]]] = {}
    read_jobs: dict[int, list[dict[str, Any]] | None] = {}

    def jobs_of(other: Mapping[str, Any]) -> Sequence[Mapping[str, Any]] | None:
        """A newer run's jobs: the sweep's listing, else one read (at most SUPERSEDED_REPLACEMENT_READS a sweep)."""
        other_id = other.get("id")
        if other_id in jobs_by_run:
            return complete_jobs(jobs_by_run[other_id])
        if other_id not in read_jobs:
            if len(read_jobs) >= SUPERSEDED_REPLACEMENT_READS or not isinstance(other_id, int):
                return None
            try:
                read_jobs[other_id] = complete_jobs(github.jobs(other_id))
            except RateLimited:
                raise
            except RuntimeError as error:
                read_jobs[other_id] = None
                print(f"queue-janitor: jobs of run {other_id}: {error}", file=sys.stderr)
        return read_jobs[other_id]

    tips: dict[str, str] = {}

    def tip_of(branch: str) -> str:
        """The branch's head, read once a sweep ("" when unread or gone: the run is then kept)."""
        if branch not in tips:
            try:
                tips[branch] = github.branch_head(branch) if branch else ""
            except RateLimited:
                raise
            except RuntimeError as error:
                tips[branch] = ""
                print(f"queue-janitor: head of {branch}: {error}", file=sys.stderr)
        return tips[branch]

    cancels = 0
    for run in candidates:
        run_id = run["id"]
        tip = tip_of(str(run.get("head_branch") or ""))
        ok, why = superseded_unstarted(run, complete_jobs(jobs_by_run.get(run_id)), runs, jobs_of, tip_sha=tip, now=now)
        if not ok and why.startswith("condition 3 fails: no newer"):
            key = (run.get("workflow_id") or run.get("path"), str(run.get("head_branch") or ""))
            if key not in listed and len(listed) < SUPERSEDED_BRANCH_LISTINGS:
                try:
                    listed[key] = github.branch_runs(run)
                except RateLimited:
                    raise
                except RuntimeError as error:
                    listed[key] = []
                    print(f"queue-janitor: runs of {key[1]} for run {run_id}: {error}", file=sys.stderr)
            ok, why = superseded_unstarted(run, complete_jobs(jobs_by_run.get(run_id)), [*runs, *listed.get(key, [])],
                                           jobs_of, tip_sha=tip, now=now)
        if not ok:
            decisions.append(SupersededDecision(run, "keep", why))
            continue
        at_head = open_pr_at_head(run, prs_by_branch.get(str(run.get("head_branch") or ""), ()))
        if at_head is not None:
            decisions.append(SupersededDecision(run, "keep", f"at the head of open PR #{at_head.get('number')}; "
                                                f"{OPEN_HEAD_RULE}"))
            continue
        if cancels >= max_cancels:
            decisions.append(SupersededDecision(run, "keep", f"cap of {max_cancels} reached"))
            continue
        if dry_run:
            decisions.append(SupersededDecision(run, "cancel", f"would cancel: {why}"))
            cancels += 1
            continue
        # Right before the cancel, the run, its jobs and the newer runs that may replace it (each run and its jobs)
        # are read again: a run whose build started since, or whose replacement failed or was cancelled, is kept.
        try:
            current, jobs = github.run(run_id), complete_jobs(github.jobs(run_id))
            fresh_tip = github.branch_head(str(current.get("head_branch") or ""))  # the tip may have moved
            # The run once more after its jobs: a re-run that began between the two reads changes its attempt.
            after = github.run(run_id)
            pool = [*runs, *[r for rs in listed.values() for r in rs]]
            fresh_runs = [github.run(other["id"]) for other in newer_head_runs(current, pool)[:REPLACEMENT_JOB_READS]]
            fresh_jobs = {other["id"]: complete_jobs(github.jobs(other["id"])) for other in fresh_runs}
            # Each replacement once more after its jobs: one cancelled, failed or re-run meanwhile does not count.
            for other in fresh_runs:
                again = github.run(other["id"])
                if (again.get("run_attempt"), again.get("status"), again.get("conclusion")) != (
                        other.get("run_attempt"), other.get("status"), other.get("conclusion")):
                    fresh_jobs[other["id"]] = None
        except RateLimited:
            raise
        except RuntimeError as error:
            failures += 1
            decisions.append(SupersededDecision(run, "keep", f"failed to re-read: {error}"))
            continue
        if (after.get("run_attempt"), after.get("status")) != (current.get("run_attempt"), current.get("status")):
            decisions.append(SupersededDecision(run, "keep", "on re-read: it changed while its jobs were read"))
            continue
        ok, why = superseded_unstarted(current, jobs, fresh_runs, lambda other: fresh_jobs.get(other.get("id")),
                                       tip_sha=fresh_tip, now=now)
        if not ok:
            decisions.append(SupersededDecision(run, "keep", f"on re-read: {why}"))
            continue
        # The branch's open pull requests again too: one may have been opened at this head during the reads.
        branch = str(current.get("head_branch") or "")
        try:
            fresh_prs = github.pull_requests([branch]).get(branch, []) if branch else []
        except RateLimited:
            raise
        except RuntimeError as error:
            failures += 1
            decisions.append(SupersededDecision(run, "keep", f"failed to re-read open PRs: {error}"))
            continue
        at_head = open_pr_at_head(current, fresh_prs)
        if at_head is not None:
            decisions.append(SupersededDecision(run, "keep", f"on re-read, at the head of open PR "
                                                f"#{at_head.get('number')}; {OPEN_HEAD_RULE}"))
            continue
        try:
            github.cancel(run_id)
        except RuntimeError as error:
            if not _cancel_refused(error):
                failures += 1
            decisions.append(SupersededDecision(run, "keep", f"cancel failed: {error}"))
            continue
        decisions.append(SupersededDecision(run, "cancel", f"cancelled: {why}"))
        cancels += 1
    return decisions, failures


# --- DEV publish runs a newer publish already covered ---------------------------------------------------------
# delivery_workflows.dev_publish_superseded() is the rule. Reads a sweep: one listing of the publisher's
# successful runs, the jobs of up to DEV_PUBLISH_WINNER_READS of them, then per candidate (oldest first, at most
# DEV_PUBLISH_JOB_READS) its jobs, its source run and one compare; a cancel re-reads the run and its jobs first.
DEV_PUBLISH_MAX_CANCELS = 20
DEV_PUBLISH_JOB_READS = 25
DEV_PUBLISH_WINNER_READS = 3


def skip_superseded_dev_publish(
    github: "GitHub",
    runs: Sequence[Mapping[str, Any]],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]],
    *,
    dry_run: bool,
    max_cancels: int = DEV_PUBLISH_MAX_CANCELS,
    max_reads: int = DEV_PUBLISH_JOB_READS,
    now: dt.datetime | None = None,
) -> tuple[list[SupersededDecision], int]:
    """Cancel each in-flight DEV publish run a newer published one already covers (dev_publish_superseded())."""
    candidates = sorted((run for run in runs if run.get("status") in IN_FLIGHT_RUN_STATUSES
                         and dev_publish_source(run) is not None),
                        key=lambda run: (dev_publish_source(run) or 0, run["id"]))
    if not candidates:
        return [], 0
    decisions: list[SupersededDecision] = []
    winner: Mapping[str, Any] | None = None
    winner_jobs: Sequence[Mapping[str, Any]] | None = None
    try:
        published = sorted((run for run in github.dev_publish_runs() if dev_publish_source(run) is not None),
                           key=lambda run: dev_publish_source(run) or 0, reverse=True)
        for run in published[:DEV_PUBLISH_WINNER_READS]:
            jobs = complete_jobs(github.jobs(run["id"]))
            if dev_publish_published(run, jobs):
                winner, winner_jobs = run, jobs
                break
        winner_source = github.run(dev_publish_source(winner)).get("head_sha") if winner else None
    except RateLimited:
        raise
    except RuntimeError as error:
        print(f"queue-janitor: DEV publish runs: {error}", file=sys.stderr)
        return [SupersededDecision(run, "keep", f"the published DEV runs could not be read: {error}")
                for run in candidates], 1
    failures = cancels = reads = 0
    compares: dict[str, bool | None] = {}

    def contains(old: str, new: str) -> bool | None:
        if old not in compares:
            try:
                compares[old] = github.compare_status(old, new) in ("ahead", "identical")
            except RateLimited:
                raise
            except RuntimeError as error:
                print(f"queue-janitor: compare {old[:12]}...{new[:12]}: {error}", file=sys.stderr)
                compares[old] = None
        return compares[old]

    for run in candidates:
        if winner is None:
            decisions.append(SupersededDecision(run, "keep", "no newer DEV publish run has published"))
            continue
        if (dev_publish_source(run) or 0) >= (dev_publish_source(winner) or 0):
            decisions.append(SupersededDecision(run, "keep", f"it publishes a source run no older than run "
                                                f"{winner.get('id')}'s"))
            continue
        if cancels >= max_cancels:
            decisions.append(SupersededDecision(run, "keep", f"cap of {max_cancels} reached"))
            continue
        if reads >= max_reads:
            decisions.append(SupersededDecision(run, "keep", f"read budget of {max_reads} runs spent"))
            continue
        reads += 1
        try:
            jobs = complete_jobs(jobs_by_run[run["id"]]) if run["id"] in jobs_by_run else complete_jobs(
                github.jobs(run["id"]))
            source_sha = github.run(dev_publish_source(run)).get("head_sha")
        except RateLimited:
            raise
        except RuntimeError as error:
            failures += 1
            decisions.append(SupersededDecision(run, "keep", f"failed to read: {error}"))
            continue
        ok, why = dev_publish_superseded(run, jobs, source_sha=source_sha, newer=winner, newer_jobs=winner_jobs,
                                         newer_source_sha=winner_source, contains=contains, now=now)
        if not ok:
            decisions.append(SupersededDecision(run, "keep", why))
            continue
        if dry_run:
            decisions.append(SupersededDecision(run, "cancel", f"would cancel: {why}"))
            cancels += 1
            continue
        # Right before the cancel the run and its jobs are read again: one whose Mac job started since is kept.
        try:
            current, fresh = github.run(run["id"]), complete_jobs(github.jobs(run["id"]))
        except RateLimited:
            raise
        except RuntimeError as error:
            failures += 1
            decisions.append(SupersededDecision(run, "keep", f"failed to re-read: {error}"))
            continue
        ok, why = dev_publish_superseded(current, fresh, source_sha=source_sha, newer=winner,
                                         newer_jobs=winner_jobs, newer_source_sha=winner_source,
                                         contains=contains, now=now)
        if not ok:
            decisions.append(SupersededDecision(run, "keep", f"on re-read: {why}"))
            continue
        try:
            github.cancel(run["id"])
        except RuntimeError as error:
            if not _cancel_refused(error):
                failures += 1
            decisions.append(SupersededDecision(run, "keep", f"cancel failed: {error}"))
            continue
        decisions.append(SupersededDecision(run, "cancel", f"cancelled: {why}"))
        cancels += 1
    return decisions, failures


def render_superseded_summary(decisions: Sequence[SupersededDecision]) -> str:
    lines = ["", "### Superseded nightly, DEV and promote runs", "",
             "A stale delivery run (every job but the light control and decide ones still queued for 20 min or more, "
             "with a newer run of its workflow on the same branch already building) is skipped so the tip builds "
             "(delivery_workflows.superseded_unstarted()).", ""]
    if not decisions:
        lines.append("None waiting.")
        return "\n".join(lines) + "\n"
    lines.append("| Decision | Run | Workflow | Head | Why |")
    lines.append("| --- | --- | --- | --- | --- |")
    for decision in decisions:
        run = decision.run
        url = run.get("html_url") or f"run {run.get('id')}"
        name = str(run.get("name") or run.get("path") or "").replace("|", "\\|")
        lines.append(f"| {decision.action} | {url} | {name} | {str(run.get('head_sha') or '')[:12]} | "
                     f"{decision.note.replace('|', '/')} |")
    return "\n".join(lines) + "\n"


def left_to_github(orphan: Orphan, now: dt.datetime) -> bool:
    """A ghost past GHOST_GIVE_UP_AGE that no human was asked to look at."""
    return (orphan.job_name is None and orphan.queued_since is not None
            and now - orphan.queued_since >= GHOST_GIVE_UP_AGE and orphan_protected_reason(orphan.run) is None)


def orphan_branches(orphans: Iterable[Orphan], now: dt.datetime) -> list[str]:
    """Branches whose pull requests the orphan plan needs: `no-janitor`, and an open PR at a run's head.

    Every event's branch is looked up (a push, a dispatch, pull_request_review ...),
    since a run at an open pull request's head is never cancelled whatever its
    event (open_pr_at_head()); a protected orphan is never cancelled anyway.
    """
    return sorted({str(o.run["head_branch"]) for o in orphans
                   if o.run.get("head_branch") and not left_to_github(o, now)
                   and orphan_protected_reason(o.run) is None})


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
        branch_prs = prs_by_branch.get(str(run.get("head_branch") or ""), ())
        if run.get("event") in PULL_REQUEST_EVENTS:
            pr = resolve_pull_request(run, branch_prs)
            if pr is not None and JANITOR_OPT_OUT_LABEL in pr_labels(pr):
                decisions.append(OrphanDecision(orphan, "skip", f"PR #{pr.get('number')} is labelled "
                                                f"`{JANITOR_OPT_OUT_LABEL}`"))
                continue
        at_head = open_pr_at_head(run, branch_prs)
        if at_head is not None:
            decisions.append(OrphanDecision(orphan, "skip", f"at the head of open PR #{at_head.get('number')}; "
                                            f"{OPEN_HEAD_RULE}"))
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


def _job_key(job: Mapping[str, Any]) -> Any:
    return job.get("id") or (job.get("name"), job.get("created_at"))


def _failed(job: Mapping[str, Any]) -> bool:
    return job.get("status") == "completed" and job.get("conclusion") == "failure"


def open_head_jobs_moved(
    before: Sequence[Mapping[str, Any]],
    now: Sequence[Mapping[str, Any]],
    rerun_job: int | None = None,
) -> str | None:
    """Why a lost run at an open PR's head may no longer be cancelled, from its jobs read again just before.

    The plan judged the sweep's job inventory, which can be minutes old: a lost job that took a runner since
    is running valid work at the PR's head, and cancelling it would interrupt that work. None when every job
    the inventory showed unassigned still is, at least one still is, and none has failed since.

    A job that had already failed in the inventory is not one that "failed since": the plan already judged
    it (open_head_lost() fails such a run over by re-running its lost job alone, `rerun_job`). Counting it
    here refused every one of those failovers: on 2026-10-31, after #28852, every sweep from 06:30Z listed
    each lost job in a failed cmux-next run as "skipped (a job failed since the inventory)", and those skips
    filled the per-sweep cap of 10. For such a run the lost job must also still be its only unfinished job,
    or the job-only re-run would leave a sibling created since the inventory cancelled and never re-run."""
    lost = {_job_key(job) for job in before if unassigned(job)}
    if not lost:
        return "no lost job in the inventory"
    for job in now:
        if _job_key(job) in lost and not unassigned(job):
            return f"job {job.get('name')!r} took a runner since the inventory"
    if not any(unassigned(job) for job in now):
        return "no job is still unassigned"
    already_failed = {_job_key(job) for job in before if _failed(job)}
    if any(_failed(job) and _job_key(job) not in already_failed for job in now):
        return "a job failed since the inventory"
    if rerun_job is not None:
        others = [job for job in now if job.get("status") != "completed" and job.get("id") != rerun_job]
        if others:
            return f"job {others[0].get('name')!r} is unfinished beside the lost job"
    elif already_failed:
        # A failed run cancelled because every unfinished job was lost (open_head_lost(), #29392): a job created
        # or started since the inventory is not lost, and the cancel would kill it (#29405).
        fresh = [job for job in now if job.get("status") != "completed" and _job_key(job) not in lost]
        if fresh:
            return f"job {fresh[0].get('name')!r} is unfinished beside the lost jobs"
    return None


# cancel_plan()'s result for a cancel or force-cancel POST that failed: GitHub may have taken it all the same
# (a dropped connection after it did), so the run's re-run entry is kept and the next sweep reconciles it
# (new_lost_reruns(), plan_lost_reruns()).
CANCEL_SENT = "failed (cancel sent, outcome unknown): "

# rerun_lost()'s result prefix for a re-run GitHub took: "re-ran failed jobs", or "re-ran job <id>" for a lost
# job re-run alone; the sweep summary counts both as freed.
RERAN = "re-ran "


def cancel_plan(
    github: "GitHub",
    candidates: Sequence[Candidate],
    jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]] | None = None,
) -> tuple[dict[int, str], int]:
    """Cancel planned runs, treating GitHub's uncancellable-run race as benign.

    A lost run at an open pull request's head (`open_head`) has its jobs read again first and is cancelled
    only while its lost jobs are still unassigned (open_head_jobs_moved(), against `jobs_by_run`, the
    sweep's inventory); one whose jobs cannot be read again is left alone."""
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
        if candidate.open_head:
            # GitHub.jobs() lists the latest attempt: a re-run someone starts between the read above and this
            # one lists the new attempt's jobs, whose ids match nothing in the inventory. So a job of another
            # attempt, or a run read again afterwards at another attempt or head, means no cancel.
            attempt = int(candidate.run.get("run_attempt") or 1)
            try:
                now_jobs = github.jobs(run_id)
                again = github.run(run_id)
            except RuntimeError as error:
                results[run_id] = f"skipped (its jobs could not be read again at the open PR head: {error})"
                continue
            other = next((job.get("run_attempt") for job in now_jobs
                          if job.get("run_attempt") not in (None, attempt)), None)
            if other is not None or int(again.get("run_attempt") or 1) != attempt:
                results[run_id] = f"skipped (now attempt {other or again.get('run_attempt')})"
                continue
            if again.get("head_sha") != candidate.run.get("head_sha"):
                results[run_id] = "skipped (head changed)"
                continue
            if again.get("status") not in IN_FLIGHT_RUN_STATUSES:
                results[run_id] = f"skipped (now {again.get('status')})"
                continue
            moved = open_head_jobs_moved((jobs_by_run or {}).get(run_id, ()), now_jobs, candidate.rerun_job)
            if moved:
                results[run_id] = f"skipped ({moved})"
                continue
        try:
            github.cancel(run_id)
            results[run_id] = "cancelled"
        except RuntimeError as error:
            if not _cancel_refused(error):
                failures += 1
                results[run_id] = f"{CANCEL_SENT}{error}"
                continue
            try:
                github.force_cancel(run_id)
            except RuntimeError as force_error:
                if not _cancel_refused(force_error):
                    failures += 1
                    results[run_id] = f"{CANCEL_SENT}{force_error}"
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


# --- orphaned dispatches on long-lived branches come back ------------------------------------------------------
# A workflow_dispatch run has no pull request or live branch head for category e or f to judge it by, so its lost
# job reached the orphan pass, which cancelled it and never re-ran it. Every `cmux-next base tier · <sha>` run whose
# daemon tests waited on a runner died that way: 15 of them between 2026-10-30 12:00Z and 2026-10-31 13:00Z, among
# them 41190186270 (`cmux-next daemon tests` queued 2h14m on blacksmith-6vcpu-macos-26), so base had no
# daemon-tests verdict for base_red_excuse.py. The same-tree `cmux-next · <sha>` dispatches on feat-cmux-next too:
# 41193804308's `cmux app scheme compile (Debug)` queued 2h04m on glaeda-std-xcode-26.6 while 5 newer jobs there
# started. Now such a cancel carries a re-run through LOST_RERUNS_KEY, as
# category e's does: the next sweep re-runs it at the same head (plan_lost_reruns()) unless a newer dispatch of
# the same kind already took that job (superseding_dispatch()). The attempt bounds it: at most
# LOST_FAILOVER_MAX_ATTEMPT - 1 re-runs, so a job that keeps losing its runner cannot loop.
# These dispatches test a commit of a long-lived branch, whose head moves on by design, so "the branch moved"
# is no reason to drop one; a dispatch on a short-lived branch stays category f's (stale_head_cancellable()).
ORPHAN_RERUN_BRANCHES = LONG_LIVED_BRANCHES
# Run names (cmux-next.yml's run-name) of dispatches that test their branch's tip: a newer one of the same kind
# that took the job covers the old one whatever its commit. Any other kind is covered only by a newer dispatch
# with the very same run name (the same commit and mode).
TIP_DISPATCH_KINDS = frozenset({"cmux-next base tier", "cmux-next tip daemon suite", "cmux-next tip Swift suite"})
# Newer dispatches whose jobs a sweep reads to judge supersession, over every pending entry; the in-flight ones
# are in the inventory already. One listing of the workflow's dispatches per settled entry besides.
DISPATCH_SUPERSEDE_JOB_READS = 6
TITLE_SHA = re.compile(r"^(.*?) · [0-9a-f]{7,40}$")


def dispatch_kind(run: Mapping[str, Any]) -> str:
    """A dispatch's run name without its trailing ` · <sha>`: `cmux-next base tier · abc..` -> `cmux-next base tier`."""
    title = str(run.get("display_title") or run.get("name") or "")
    match = TITLE_SHA.match(title)
    return match.group(1) if match else title


def orphan_rerun_scope(orphan: Orphan) -> str | None:
    """Why the orphan pass's cancel of this run carries a re-run, or None when it does not."""
    run = orphan.run
    branch = str(run.get("head_branch") or "")
    attempt = int(run.get("run_attempt") or 1)
    if orphan.job_name is None or run.get("event") != "workflow_dispatch" or branch not in ORPHAN_RERUN_BRANCHES:
        return None
    if attempt >= LOST_FAILOVER_MAX_ATTEMPT or orphan_protected_reason(run) is not None:
        return None
    return f"a {branch} dispatch at attempt {attempt}"


def orphan_reruns(decisions: Sequence[OrphanDecision], results: Mapping[int, str],
                  jobs_by_run: Mapping[int, Sequence[Mapping[str, Any]]], *, now: dt.datetime) -> list[dict[str, Any]]:
    """Pending re-run entries (LOST_RERUNS_KEY) for this sweep's orphan cancels that took, in orphan_rerun_scope().

    A run that already failed gets only its lost job re-run (`job_id`), so its red stays as it was."""
    entries = []
    for decision in decisions:
        run = decision.orphan.run
        result = results.get(run["id"]) or ""
        if decision.action != "cancel" or not (result == "cancelled" or result.startswith("force-cancelled")):
            continue
        if orphan_rerun_scope(decision.orphan) is None:
            continue
        entry: dict[str, Any] = {
            "run_id": run["id"], "attempt": int(run.get("run_attempt") or 1),
            "head_sha": str(run.get("head_sha") or ""), "branch": str(run.get("head_branch") or ""),
            "cancelled_at": _iso(now),
            "dispatch": {"kind": dispatch_kind(run), "title": str(run.get("display_title") or run.get("name") or ""),
                         "job": decision.orphan.job_name or ""},
        }
        if decision.orphan.job_id is not None and any(_failed(job) for job in jobs_by_run.get(run["id"]) or ()):
            entry["job_id"] = decision.orphan.job_id
        entries.append(entry)
    return entries


def newer_dispatches(entry: Mapping[str, Any], run: Mapping[str, Any],
                     listed: Iterable[Mapping[str, Any]]) -> list[Mapping[str, Any]]:
    """The dispatches of `run`'s workflow and branch after it that can cover it, newest first."""
    dispatch = entry.get("dispatch") if isinstance(entry.get("dispatch"), Mapping) else {}
    kind = str(dispatch.get("kind") or dispatch_kind(run))
    title = str(dispatch.get("title") or "")
    found = [other for other in listed
             if int(other.get("id") or 0) > int(run.get("id") or 0) and other.get("event") == "workflow_dispatch"
             and other.get("path") == run.get("path") and other.get("head_branch") == run.get("head_branch")
             and dispatch_kind(other) == kind
             and (kind in TIP_DISPATCH_KINDS or str(other.get("display_title") or other.get("name") or "") == title)]
    return sorted(found, key=lambda other: int(other.get("id") or 0), reverse=True)


def superseding_dispatch(entry: Mapping[str, Any], run: Mapping[str, Any], listed: Iterable[Mapping[str, Any]],
                         jobs_of: Mapping[int, Sequence[Mapping[str, Any]]]) -> Mapping[str, Any] | None:
    """A newer dispatch of the same kind whose job of the same name a runner took and that was not cancelled.

    Only that drops an orphaned dispatch's re-run: a newer dispatch whose job is still queued, was skipped or was
    cancelled covers nothing (the kick's own base tier run skips the daemon tests its same-tree run carries). A
    dispatch whose jobs were not read counts as not covering it, so the re-run goes ahead (the attempt bounds it).
    """
    dispatch = entry.get("dispatch") if isinstance(entry.get("dispatch"), Mapping) else {}
    name = str(dispatch.get("job") or "")
    for other in newer_dispatches(entry, run, listed):
        for job in jobs_of.get(int(other.get("id") or 0)) or ():
            if job.get("name") == name and took_runner(job) and job.get("conclusion") != "cancelled":
                return other
    return None


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
    """The token is out of budget: the sweep stops (GitHub.request()), and main() ends it as an infra skip."""


def request_kind(method: str, path: str, repo: str) -> str:
    """`GET /actions/runs/{id}/jobs`: a request with its ids and query dropped (the summary's REST line)."""
    bare = path.split("?", 1)[0].replace(f"/repos/{repo}", "", 1)
    return f"{method} {re.sub(r'/[0-9]+(?=/|$)', '/{id}', bare)}"


def rest_line(kinds: Mapping[str, int]) -> str:
    """`REST by kind: GET /actions/runs/{id}/jobs 285, ...`, most first: what a sweep spent on the
    cmux-bot installation's 5000 an hour (it ran out five hours in a row on 2026-10-27), by endpoint."""
    return "REST by kind: " + (", ".join(f"{kind} {count}" for kind, count in
                                         sorted(kinds.items(), key=lambda item: (-item[1], item[0]))) or "none")


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
        self.kinds: dict[str, int] = {}  # requests by request_kind(), for the summary's REST line
        # The job listings run on JOB_LISTING_WORKERS threads (read_run_jobs()); the counters are shared.
        self._count_lock = threading.Lock()
        # in_flight_runs()'s account of its listing, per status (listing_state()).
        self.run_listing: dict[str, dict[str, Any]] = {}
        self.fallback_token = fallback_token if fallback_token != token else ""
        # A time.monotonic() bound: while set, a read is not made again past it and no request waits past it
        # (rerun_open_head()).
        self.deadline: float | None = None
        # An App's token is in use: one was minted beside the workflow's, and it was not refused yet.
        self.app_token = bool(self.fallback_token)
        # Rate limit resource ("core", "graphql") -> the newest response's values.
        self.rate_limits: dict[str, dict[str, int]] = {}
        # The first rate-limit refusal this sweep met, or "": main() then ends the sweep green with a warning.
        self.rate_limited = ""
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
                if not retry or delay is None or (self.deadline is not None
                                                  and time.monotonic() + delay >= self.deadline):
                    raise RuntimeError(f"{method} {path.split('?')[0]} failed ({error})") from error.__cause__
                print(f"queue-janitor: {method} {path.split('?')[0]} failed ({error}); again in {delay:.0f} s",
                      file=sys.stderr)
                time.sleep(delay)
        raise AssertionError("unreachable")

    def _request(self, method: str, path: str, body: Any | None = None, *, app_only: bool = False) -> Any:
        kind = request_kind(method, path, self.repo)
        with self._count_lock:
            self.calls += 1
            self.kinds[kind] = self.kinds.get(kind, 0) + 1
        data = json.dumps(body).encode() if body is not None else None
        headers = dict(self.headers)
        if data is not None:
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(API + path, data=data, headers=headers, method=method)
        try:
            timeout = 30.0
            if self.deadline is not None:
                remaining = self.deadline - time.monotonic()
                if remaining <= 0:
                    raise RuntimeError(f"{method} {path.split('?')[0]} not sent: past the sweep's deadline")
                timeout = min(timeout, remaining)
            with urllib.request.urlopen(request, timeout=timeout) as response:
                self.note_rate_limit(response.headers)
                raw = response.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as error:
            self.note_rate_limit(error.headers)
            if error.code in (403, 429) and rate_limited(error):
                limited = RateLimited(f"{method} {path.split('?')[0]} failed ({error.code}: rate limit; "
                                      "the sweep stops rather than spend the workflow token)")
                with self._count_lock:
                    self.rate_limited = self.rate_limited or str(limited)
                raise limited from error
            if error.code in (401, 403) and not app_only:
                # The job listings run on several threads (read_run_jobs()): one switches the token, and a
                # request another sent with the refused token before the switch is made again with the new
                # one, instead of failing for want of a fallback the first thread already used.
                with self._count_lock:
                    switched = headers.get("Authorization") != self.headers.get("Authorization")
                    if not switched and self.fallback_token:
                        print(f"queue-janitor: App token refused ({error.code}) on {path.split('?')[0]}; "
                              "using the workflow token for the rest of the sweep", file=sys.stderr)
                        self.headers["Authorization"] = f"Bearer {self.fallback_token}"
                        # The snapshot download (download()) uses the same token.
                        self._token = self.fallback_token
                        self.fallback_token = ""
                        self.app_token = False
                        switched = True
                if switched:
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
        """Every run in IN_FLIGHT_RUN_STATUSES, up to MAX_RUN_PAGES pages a status; how complete each status's
        listing is goes to `run_listing` (listing_state()).

        A status-filtered listing can return a short page before its last one: `status=queued` answered
        99 runs on page 1 and 85 on page 2 of a total_count of 182 at 06:10Z on 2026-10-26. Stopping at the first short page dropped every queued run older than page 1, so the
        snapshot's oldest wait on blacksmith-12vcpu-macos-26 read 24 minutes while run 40259152940's fast
        tier had waited 205, and the janitor never cancelled that run after PR #24021 landed. So only an
        empty page ends a status: neither a short page nor total_count, which a page
        repeating rows or a listing that shifts between pages would satisfy early. Runs keyed by id drop
        the repeats; a run a shift moves past a page boundary is read on the next sweep.

        GitHub answers a filtered listing's first 1,000 results only (LISTING_RESULT_PAGES pages): a status
        whose last such page still had runs is listed again from the oldest run it showed (`created<=` that
        time, newest first), until a window ends in an empty page. A status that reaches MAX_RUN_PAGES, or a
        window that cannot move past its oldest run, is truncated.
        """
        runs: dict[int, dict[str, Any]] = {}
        self.run_listing = {}
        for status in IN_FLIGHT_RUN_STATUSES:
            seen: set[int] = set()
            total: int | None = None
            pages = 0
            before = ""  # the window's `created<=` bound; "" for the first window
            truncated = False
            while True:
                oldest = ""
                ended = False
                for page in range(1, LISTING_RESULT_PAGES + 1):
                    if pages >= MAX_RUN_PAGES:
                        truncated = True
                        break
                    params = {"status": status, "per_page": 100, "page": page}
                    if before:
                        params["created"] = f"<={before}"
                    payload = self.request("GET", f"/repos/{self.repo}/actions/runs?{urllib.parse.urlencode(params)}")
                    pages += 1
                    if total is None and isinstance(payload.get("total_count"), int):
                        total = payload["total_count"]
                    batch = payload.get("workflow_runs") or []
                    if not batch:
                        ended = True
                        break
                    for run in batch:
                        runs[run["id"]] = run
                        seen.add(run["id"])
                        created = str(run.get("created_at") or "")
                        if created and (not oldest or created < oldest):
                            oldest = created
                if ended or truncated:
                    break
                # Every page of the window had runs: the 1,000-result cap may hide older ones.
                if not oldest or oldest == before:
                    truncated = True  # no older bound to move to (over 1,000 runs created in one second)
                    break
                before = oldest
            self.run_listing[status] = {"listed": len(seen), "total": total if total is not None else len(seen),
                                        "pages": pages, "truncated": truncated}
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

    def compare_status(self, base: str, head: str) -> str:
        """GitHub's compare status of base...head (ahead, behind, identical or diverged)."""
        payload = self.request("GET", f"/repos/{self.repo}/compare/{base}...{head}?per_page=1")
        return str((payload or {}).get("status") or "")

    def dev_publish_runs(self) -> list[dict[str, Any]]:
        """One page of the newest successful runs of the DEV publisher (skip_superseded_dev_publish())."""
        query = urllib.parse.urlencode({"status": "success", "event": "workflow_dispatch", "per_page": 20})
        payload = self.request("GET", f"/repos/{self.repo}/actions/workflows/cmux-next-dev-daily.yml/runs?{query}")
        return [run for run in payload.get("workflow_runs") or [] if isinstance(run, Mapping)]

    def cancel(self, run_id: int) -> None:
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/cancel")

    def force_cancel(self, run_id: int) -> None:
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/force-cancel")

    def rerun_failed(self, run_id: int, *, app_only: bool = False) -> None:
        """Re-run the run's failed and cancelled jobs; `app_only` never retries it on the workflow's token."""
        if app_only and not self.app_token:
            raise RuntimeError(f"run {run_id} needs an App's re-run; this sweep has only GITHUB_TOKEN")
        self.request("POST", f"/repos/{self.repo}/actions/runs/{run_id}/rerun-failed-jobs", app_only=app_only)

    def rerun_job(self, job_id: int, *, app_only: bool = False) -> None:
        """Re-run one job (and the jobs that need it), keeping every other job's result; see rerun_failed()."""
        if app_only and not self.app_token:
            raise RuntimeError(f"job {job_id} needs an App's re-run; this sweep has only GITHUB_TOKEN")
        self.request("POST", f"/repos/{self.repo}/actions/jobs/{job_id}/rerun", app_only=app_only)

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

    def branch_runs(self, run: Mapping[str, Any]) -> list[dict[str, Any]]:
        """One page of the newest runs of `run`'s workflow on its branch (skip_superseded_delivery())."""
        workflow = str(run.get("path") or "").rsplit("/", 1)[-1]
        query = urllib.parse.urlencode({"branch": run.get("head_branch") or "", "per_page": 20})
        payload = self.request("GET", f"/repos/{self.repo}/actions/workflows/{urllib.parse.quote(workflow)}/runs?{query}")
        return [other for other in payload.get("workflow_runs") or [] if isinstance(other, Mapping)]

    def dispatch_runs(self, run: Mapping[str, Any]) -> list[dict[str, Any]]:
        """One page of the newest workflow_dispatch runs of `run`'s workflow on its branch (superseding_dispatch())."""
        workflow = str(run.get("path") or "").rsplit("/", 1)[-1]
        query = urllib.parse.urlencode({"branch": run.get("head_branch") or "", "event": "workflow_dispatch",
                                        "per_page": 50})
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
        self.kinds["GET /actions/artifacts/{id}/zip"] = self.kinds.get("GET /actions/artifacts/{id}/zip", 0) + 1
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
        app_only = bool(decision.entry.get("app_actor") or decision.entry.get("open_head"))
        job_id = decision.entry.get("job_id")
        try:
            if isinstance(job_id, int) and not isinstance(job_id, bool):
                github.rerun_job(job_id, app_only=app_only)
                results[run_id] = f"{RERAN}job {job_id}"
            else:
                github.rerun_failed(run_id, app_only=app_only)
                results[run_id] = f"{RERAN}failed jobs"
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
                  now: dt.datetime, *, cap: int | None = None, workers: int | None = None,
                  branch_linux_only: Mapping[str, frozenset[str]] | None = None,
                  ) -> tuple[dict[int, list[dict[str, Any]]], set[int], set[int]]:
    """({run id: jobs} for the runs needs_jobs() lists, the ids whose listing failed, the ids left unlisted).

    One run's failed listing skips that run, not the sweep (a rate limit still ends it): the sweep
    that ended on one 502 at 08:08Z on 2026-10-26 wrote no pool snapshot (RETRY_DELAYS).
    At most `cap` (MAX_JOB_LISTINGS) runs are listed, the newest first; the rest are left unlisted and
    the snapshot says it is truncated. The listings run `workers` (JOB_LISTING_WORKERS) at a time."""
    cap = MAX_JOB_LISTINGS if cap is None else cap
    workers = JOB_LISTING_WORKERS if workers is None else workers
    wanted = [run for run in runs if needs_jobs(run, linux_only, now, branch_linux_only=branch_linux_only)]
    # Newest first, so a capped sweep still sees the demand that is arriving now.
    wanted.sort(key=lambda run: (str(run.get("created_at") or ""), run["id"]), reverse=True)
    listed, unlisted = wanted[:max(0, cap)], {run["id"] for run in wanted[max(0, cap):]}
    jobs_by_run: dict[int, list[dict[str, Any]]] = {}
    unread: set[int] = set()

    def one(run: Mapping[str, Any]) -> list[dict[str, Any]] | None:
        try:
            return github.jobs(run["id"])
        except RateLimited:
            raise
        except RuntimeError as error:
            print(f"queue-janitor: run {run['id']} skipped this sweep: {error}", file=sys.stderr)
            return None

    if workers <= 1 or len(listed) <= 1:
        results = [one(run) for run in listed]
    else:
        with ThreadPoolExecutor(max_workers=workers) as pool:
            futures = [pool.submit(one, run) for run in listed]
            try:
                results = [future.result() for future in futures]
            except RateLimited:
                for future in futures:
                    future.cancel()
                raise
    # In run order, whatever order the listings finished in.
    by_id = {run["id"]: jobs for run, jobs in zip(listed, results)}
    for run in runs:
        if run["id"] not in by_id:
            continue
        if by_id[run["id"]] is None:
            unread.add(run["id"])
        else:
            jobs_by_run[run["id"]] = by_id[run["id"]]
    return jobs_by_run, unread, unlisted


def listing_state(github: Any, unlisted: set[int]) -> dict[str, Any]:
    """The snapshot's account of how much of the in-flight queue this sweep saw.

    `listed` runs of GitHub's `total` (its total_count per status, as the first page reported it; the
    queue moves while the pages are read, so the two can differ by a few either way), per status in
    `statuses`. `truncated` is true when a status's listing hit MAX_RUN_PAGES or runs were left past
    MAX_JOB_LISTINGS (`jobs_unlisted`): the snapshot's pools then miss demand, and its readers take the
    queue as unknown (pr_runner_pool.snapshot_truncated()), never as nothing queued."""
    statuses = {status: dict(entry) for status, entry in (getattr(github, "run_listing", None) or {}).items()}
    truncated = any(entry.get("truncated") for entry in statuses.values()) or bool(unlisted)
    return {
        "truncated": truncated,
        "listed": sum(int(entry.get("listed") or 0) for entry in statuses.values()),
        "total": sum(int(entry.get("total") or 0) for entry in statuses.values()),
        "jobs_unlisted": len(unlisted),
        "statuses": statuses,
    }


def render_listing(listing: Mapping[str, Any]) -> str:
    """`Listed 866 of 866 in-flight runs (queued 600/600, ...)`, plus what was cut when truncated."""
    parts = ", ".join(f"{status} {entry.get('listed', 0)}/{entry.get('total', 0)}"
                      + (" truncated" if entry.get("truncated") else "")
                      for status, entry in (listing.get("statuses") or {}).items())
    text = f"Listed {listing.get('listed', 0)} of {listing.get('total', 0)} in-flight runs ({parts or 'none'})"
    if listing.get("jobs_unlisted"):
        text += f"; {listing['jobs_unlisted']} run(s) past the {MAX_JOB_LISTINGS} job listings a sweep left unread"
    return text


def main(argv: Sequence[str] | None = None) -> int:
    """One sweep (sweep()). A sweep that met a rate limit ends green with a ::warning:: (an infra skip).

    The App's budget is shared by every cmux-bot caller, and running out of it says nothing about the queue:
    on 2026-10-31 it ran out at about 00:50Z and the sweeps until its reset failed red. The sweep still stops
    at the refusal (it never moves onto the workflow token, GitHub.request()), and the first sweep after the
    reset reads the whole queue again; what it did before the refusal is in its log."""
    clients: list[GitHub] = []
    try:
        code = sweep(argv, clients)
    except RateLimited as error:
        code = 1
        if clients:
            clients[0].rate_limited = clients[0].rate_limited or str(error)
    limited = clients[0].rate_limited if clients else ""
    if not limited:
        return code
    print(f"::warning title=queue janitor out of API budget::{limited}. This sweep stopped early and is "
          f"skipped; the next sweep after the budget resets reads the queue again. "
          f"{render_rate_limits(clients[0].rate_limits)}")
    return 0


def sweep(argv: Sequence[str] | None, clients: list["GitHub"]) -> int:
    """The sweep itself. Its GitHub client goes into `clients`, for main() to read once it ends."""
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
    parser.add_argument("--branch-workflows", action="append", metavar="BRANCH=DIR",
                        default=(os.environ.get("BRANCH_WORKFLOWS") or "").split(),
                        help="another branch's workflow files, so its linux-only runs are not listed "
                             "(branch_linux_only_paths()); repeatable")
    parser.add_argument("--pool-load", type=Path, default=(
        Path(os.environ["POOL_LOAD_OUT"]) if os.environ.get("POOL_LOAD_OUT") else None),
        help="write this sweep's per-pool macOS demand here as JSON")
    parser.add_argument("--summary", type=Path, default=(
        Path(os.environ["GITHUB_STEP_SUMMARY"]) if os.environ.get("GITHUB_STEP_SUMMARY") else None))
    # The open-head failover's cutoff (LOST_FAILOVER_CUTOFF_S) counts from here.
    sweep_started = time.monotonic()
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
    clients.append(github)
    # The workflow passes cmux-bot's token as CMUX_BOT_TOKEN too: GH_TOKEN is cmux-bot's only when they match
    # (its mint can fail, and GH_TOKEN then falls back to the glaeda-route App's). While it is, and not yet
    # refused (app_token), category e fails a lost job at an open PR's head over (open_head_lost()).
    cmux_bot_token = os.environ.get("CMUX_BOT_TOKEN") or ""

    def cmux_bot() -> bool:
        return bool(cmux_bot_token) and cmux_bot_token == token and github.app_token
    now = utc_now()
    linux_only = linux_only_workflow_paths(args.workflows_dir)
    branch_linux_only = branch_linux_only_paths(args.branch_workflows)
    try:
        runs = github.in_flight_runs()
        jobs_by_run, unread, unlisted = read_run_jobs(github, runs, linux_only, now,
                                                      branch_linux_only=branch_linux_only)
        # The runs not listed because their branch's copy of the workflow runs only on Linux (needs_jobs()).
        branch_skipped = sum(1 for run in runs if needs_jobs(run, linux_only, now)
                             and not needs_jobs(run, linux_only, now, branch_linux_only=branch_linux_only))
        listing = listing_state(github, unlisted)
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
        # A delivery run queued past GHOST_QUEUED_RUN_AGE has no listing (needs_jobs()); read a few of them here.
        delivery_jobs = dict(jobs_by_run)
        unlisted = sorted((r for r in runs if r["id"] not in jobs_by_run and r.get("status") in IN_FLIGHT_RUN_STATUSES
                           and is_delivery_run(r.get("path"), r.get("name"), r.get("display_title"))),
                          key=lambda r: (str(r.get("created_at") or ""), r["id"]))  # oldest first
        for run in unlisted[:SUPERSEDED_EXTRA_JOBS]:
            try:
                delivery_jobs[run["id"]] = github.jobs(run["id"])
            except RateLimited:
                raise
            except RuntimeError as error:  # unread: never a candidate
                print(f"queue-janitor: jobs of delivery run {run['id']}: {error}", file=sys.stderr)
        superseded = superseded_candidates(runs, delivery_jobs)
        branches = sorted(set(branches_to_resolve(runs, jobs_by_run)) | set(orphan_branches(orphans, now))
                          | {str(run["head_branch"]) for run in superseded if run.get("head_branch")}
                          | set(lost_branches(runs, {**lost, **unclaimed}, pending or [])))
        prs_by_branch = github.pull_requests(branches) if branches else {}
    except RuntimeError as error:
        print(f"queue-janitor: {error}", file=sys.stderr)
        print(render_rate_limits(github.rate_limits), file=sys.stderr)
        if isinstance(error, RateLimited):
            github.rate_limited = github.rate_limited or str(error)
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
            github.rate_limited = github.rate_limited or str(error)
            return 1
        # How much of the queue this sweep saw: `truncated` makes every pool reader take the queue as unknown.
        snapshot.update({key: listing[key] for key in ("truncated", "listed", "total")})
        snapshot["listing"] = {key: listing[key] for key in ("jobs_unlisted", "statuses")}
        if unread or listing["truncated"]:
            # Read from every run but these: their jobs are missing, so a label one of them is running on
            # can look starved and one it waits on can look recovered. No starved-label issue is opened,
            # updated or closed on this sweep (starved_labels.py), and readers can tell it is partial.
            snapshot["starved"] = []
            snapshot["starved_incomplete"] = True
        if unread:
            snapshot[UNREAD_RUNS_KEY] = sorted(unread)
        # Warm affinity on: which root runner kept a build of which main
        # commits (owned_warm_state.py). A failure leaves `warm` out, and the
        # picker then routes admission by the root label as before.
        if os.environ.get("OWNED_WARM", "").strip() == "1":
            try:
                snapshot["warm"] = owned_warm_state.sweep(PoolClient(token, args.repo), jobs_by_run, now)
            except Exception as error:  # noqa: BLE001 a routing hint never fails the sweep
                print(f"queue-janitor: owned warm state: {error}", file=sys.stderr)
        # The gates' own state per owned label, from the CI_FLEET_GATES variable (fleet_gates()); readers treat
        # a missing or stale reading as full.
        gates, gates_error = fleet_gates(os.environ.get("FLEET_GATES"))
        if gates:
            snapshot["gates"] = gates
        else:
            snapshot["gates_error"] = gates_error
            print(f"queue-janitor: fleet gates: {gates_error}", file=sys.stderr)
        args.pool_load.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")

    if unread or listing["truncated"]:
        # Nothing is acted on, so the pending re-runs an earlier sweep left are carried forward as they were.
        if snapshot is not None and args.pool_load and pending is not None:
            snapshot[LOST_RERUNS_KEY] = [dict(entry) for entry in pending][-LOST_PENDING_MAX:]
            args.pool_load.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")
        if unread:
            summary = (f"\n_The job listings of {len(unread)} run(s) failed ({', '.join(map(str, sorted(unread)))}): "
                       f"the pool snapshot was written from the other {len(runs)}, and this sweep decided nothing._\n")
        else:
            summary = ""
        if listing["truncated"]:
            # An annotation too: the ceilings (MAX_RUN_PAGES, MAX_JOB_LISTINGS) need raising.
            print(f"::warning title=queue janitor listing truncated::{render_listing(listing)}")
            summary += (f"\n_{render_listing(listing)}: the pool snapshot says `truncated`, and this sweep "
                        "decided nothing._\n")
        summary += f"\n_{render_rate_limits(github.rate_limits)}_\n"
        print(summary)
        if args.summary:
            with args.summary.open("a", encoding="utf-8") as handle:
                handle.write(summary)
        return 0

    plan = build_plan(
        runs, jobs_by_run, prs_by_branch,
        threshold=threshold, max_cancels=max_cancels, pull_request_policy=args.pull_request_policy,
        now=now, lost=lost, rerun_state=pending is not None, unclaimed=unclaimed, branch_heads=branch_heads,
        app_rerun=github.app_token, cmux_bot_rerun=cmux_bot(),
    )

    results: dict[int, str] = {}
    failures = 0
    if not args.dry_run:
        results, failures = cancel_plan(github, plan.to_cancel(), jobs_by_run)

    carried: list[dict[str, Any]] = []

    def save_lost_reruns(entries: Sequence[Mapping[str, Any]]) -> None:
        carried[:] = [dict(entry) for entry in entries]
        if snapshot is not None and args.pool_load:
            snapshot[LOST_RERUNS_KEY] = [dict(entry) for entry in entries][-LOST_PENDING_MAX:]
            args.pool_load.write_text(json.dumps(snapshot, indent=2) + "\n", encoding="utf-8")

    # Category e re-runs: one run request per pending entry, then at most
    # LOST_RERUN_MAX re-runs. What is still pending, plus this sweep's cancels
    # that asked for a re-run, goes into the snapshot for the next sweep.
    rerun_decisions: list[LostRerun] = []
    rerun_results: dict[int, str] = {}
    open_head_decisions: list[LostRerun] = []
    open_head_results: dict[int, str] = {}
    open_head_freed = 0
    if pending is not None:
        # Saved before anything else can fail: this sweep's cancels are
        # already made, and an entry read twice is harmless (plan_lost_reruns()).
        fresh = [] if args.dry_run else new_lost_reruns(plan.to_cancel(), results, now=now)
        save_lost_reruns([*pending, *fresh])
        # The stall-aware failover at an open PR's head: re-run in this sweep, once the cancels settle. What it
        # cannot re-run now stays in `fresh` for the next sweep; the rest leaves it.
        # A cancel whose POST failed is not waited on here: the next sweep reconciles it (new_lost_reruns()).
        open_head = [entry for entry in fresh if entry.get("open_head") and not entry.get("cancel_unconfirmed")]
        if open_head:
            if cmux_bot() and time.monotonic() - sweep_started < LOST_FAILOVER_CUTOFF_S:
                open_head_decisions, open_head_pending, open_head_results, open_head_failures = rerun_open_head(
                    github, open_head, now=now, inventory=runs, rerun_cap=LOST_RERUN_MAX)
            else:
                # Refused since the plan (app_token), or the sweep is too far into its timeout to wait: leave
                # every one to the next sweep, which re-runs it once it holds cmux-bot's token.
                why = ("cmux-bot's token was refused" if not cmux_bot()
                       else f"the sweep is past {LOST_FAILOVER_CUTOFF_S / 60:.0f} minutes")
                open_head_decisions = [LostRerun(entry, "keep", f"{why}; the next sweep re-runs it")
                                       for entry in open_head]
                open_head_pending, open_head_results, open_head_failures = [dict(e) for e in open_head], {}, 0
            failures += open_head_failures
            open_head_freed = sum(1 for decision in open_head_decisions if decision.action == "rerun"
                                  and open_head_results.get(int(decision.entry["run_id"]), "").startswith(RERAN))
            fresh = [*(entry for entry in fresh if not (entry.get("open_head") and not entry.get("cancel_unconfirmed"))),
                     *open_head_pending]
            save_lost_reruns([*pending, *fresh])
        runs_now: dict[int, Mapping[str, Any]] = {}
        for entry in pending:
            run_id = entry.get("run_id")
            if isinstance(run_id, int) and run_id not in runs_now:
                try:
                    runs_now[run_id] = github.run(run_id)
                except Exception as error:  # noqa: BLE001 the entry is kept for the next sweep
                    print(f"queue-janitor: pending re-run of run {run_id}: {error!r}", file=sys.stderr)
        # Orphaned dispatches (orphan_reruns()) are judged by newer dispatches of their kind, not by their head.
        dispatch_ids = {entry.get("run_id") for entry in pending if isinstance(entry.get("dispatch"), Mapping)}
        # One listing per settled cancel: a newer run at its head that took
        # over (even one finished since) means no re-run.
        head_runs: dict[int, list[Mapping[str, Any]]] = {}
        for run_id, run in runs_now.items():
            if run_id in dispatch_ids:
                continue
            if run.get("status") == "completed" and run.get("conclusion") == "cancelled":
                try:
                    head_runs[run_id] = [*github.runs_at_head(run), *runs]
                except Exception as error:  # noqa: BLE001 the entry is kept for the next sweep
                    print(f"queue-janitor: runs at the head of run {run_id}: {error!r}", file=sys.stderr)
        # A settled push or dispatch cancel is re-run only while its branch is live.
        settled = [run for run_id, run in runs_now.items() if run_id not in dispatch_ids
                   and run.get("status") == "completed" and run.get("conclusion") == "cancelled"]
        # A settled orphaned dispatch: one listing of its workflow's dispatches on its branch, and the jobs of the
        # newer ones of its kind that may have run its job (the in-flight ones are in the inventory), newest
        # first, at most DISPATCH_SUPERSEDE_JOB_READS a sweep.
        dispatch_runs: dict[int, list[Mapping[str, Any]]] = {}
        dispatch_jobs: dict[int, Sequence[Mapping[str, Any]]] = dict(jobs_by_run)
        job_reads = 0
        for entry in pending:
            run = runs_now.get(entry.get("run_id"))
            if (entry.get("run_id") not in dispatch_ids or not run or run.get("status") != "completed"
                    or run.get("conclusion") != "cancelled" or run["id"] in dispatch_runs):
                continue
            try:
                dispatch_runs[run["id"]] = github.dispatch_runs(run)
            except Exception as error:  # noqa: BLE001 the entry is kept for the next sweep
                print(f"queue-janitor: dispatches after run {run['id']}: {error!r}", file=sys.stderr)
                continue
            for other in newer_dispatches(entry, run, dispatch_runs[run["id"]]):
                if other["id"] in dispatch_jobs or other.get("status") in ("queued", "pending", "waiting", "requested"):
                    continue
                if job_reads >= DISPATCH_SUPERSEDE_JOB_READS:
                    break
                job_reads += 1
                try:
                    dispatch_jobs[other["id"]] = github.jobs(other["id"])
                except Exception as error:  # noqa: BLE001 unread: counts as not covering it
                    print(f"queue-janitor: jobs of dispatch {other['id']}: {error!r}", file=sys.stderr)
        read_heads(branch_head_lookups(settled, {run.get("id") for run in settled}, prs_by_branch=prs_by_branch,
                                       known=branch_heads, cap=PENDING_HEAD_LOOKUPS))
        # One LOST_RERUN_MAX a sweep: what the open-head failover re-ran comes out of the pending entries' share.
        open_head_reruns = sum(1 for decision in open_head_decisions if decision.action == "rerun")
        rerun_decisions = plan_lost_reruns(pending, runs_now, prs_by_branch, now=now, head_runs=head_runs,
                                           branch_heads=branch_heads, app_token=github.app_token,
                                           cmux_bot=cmux_bot(), rerun_cap=LOST_RERUN_MAX - open_head_reruns,
                                           dispatch_runs=dispatch_runs, dispatch_jobs=dispatch_jobs)
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
    orphan_rerun_entries: list[dict[str, Any]] = []
    if not args.dry_run:
        orphan_results, orphan_failures = cancel_orphans(github, orphan_decisions)
        failures += orphan_failures
        # An orphaned dispatch on a long-lived branch comes back: the next sweep re-runs it (plan_lost_reruns()).
        # Without the re-run state (pending is None) it is cancelled with none, as before.
        if pending is not None:
            orphan_rerun_entries = orphan_reruns(orphan_decisions, orphan_results, jobs_by_run, now=now)
            if orphan_rerun_entries:
                save_lost_reruns([*carried, *orphan_rerun_entries])

    try:
        superseded_decisions, superseded_failures = skip_superseded_delivery(
            github, superseded, runs, delivery_jobs, prs_by_branch, dry_run=args.dry_run)
    except RuntimeError as error:  # a rate limit: what was cancelled before it is in the next sweep's inventory
        print(f"queue-janitor: superseded delivery runs: {error}", file=sys.stderr)
        if isinstance(error, RateLimited):
            github.rate_limited = github.rate_limited or str(error)
        superseded_decisions, superseded_failures = [], 1
    failures += superseded_failures
    try:
        dev_decisions, dev_failures = skip_superseded_dev_publish(github, runs, delivery_jobs, dry_run=args.dry_run)
    except RuntimeError as error:  # a rate limit: the next sweep reads them again
        print(f"queue-janitor: superseded DEV publish runs: {error}", file=sys.stderr)
        dev_decisions, dev_failures = [], 1
    superseded_decisions = [*superseded_decisions, *dev_decisions]
    failures += dev_failures

    summary = render_summary(plan, dry_run=args.dry_run, now=now, results=results)
    summary += render_open_head_reruns(open_head_decisions, open_head_results, freed=open_head_freed)
    summary += render_lost_reruns(rerun_decisions, dry_run=args.dry_run, results=rerun_results)
    summary += render_orphan_summary(orphan_decisions, dry_run=args.dry_run, now=now, min_age=orphan_age,
                                     results=orphan_results)
    if orphan_rerun_entries:
        summary += "\nRe-run by the next sweep unless a newer dispatch of the same kind took the job: " + ", ".join(
            f"run {entry['run_id']} (`{entry['dispatch']['job']}`)" for entry in orphan_rerun_entries) + ".\n"
    summary += render_superseded_summary(superseded_decisions)
    summary += f"\n_{render_listing(listing)}._\n"
    summary += f"\n_{len(runs)} in-flight runs, {len(jobs_by_run)} job listings " \
               f"({branch_skipped} more runs not listed: linux-only on their branch), {len(branches)} PR branches, " \
               f"{len(orphans)} orphans, {len(lost)} lost assignments, {len(unclaimed)} unclaimed legs, " \
               f"{head_reads} branch head reads, {len(evidence_jobs)} evidence job listings, " \
               f"{github.calls} API calls._\n"
    summary += f"\n_{render_rate_limits(github.rate_limits)}_\n"
    summary += f"\n_{rest_line(getattr(github, 'kinds', {}))}_\n"
    print(summary)
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as handle:
            handle.write(summary)
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
