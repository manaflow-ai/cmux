#!/usr/bin/env python3
"""Pick the macOS pool a pull request CI run lands on.

ci.yml's `changes` job calls this once per run, and every pull-request macOS
job in the run reads the answer: compile admission, the app-host consumers
that follow it, tests-build-and-lag, cli-product-tests, the Claude wrapper
and remote daemon lanes. A run on a Blacksmith pool is never split across
pools, because the app-host product only loads under the Xcode that linked it
(#14163). A run on an owned pool may be, per job (see "Per-job placement"
below).

The run takes the first pool in preference order that has headroom:

    vars.CI_PR_POOL_ORDER, comma-separated; by default
      blacksmith-12vcpu-macos-26   same macOS and Xcode as the lane, faster
      blacksmith-6vcpu-macos-26    vars.MACOS_RUNNER_PR today
      blacksmith-6vcpu-macos-15    macOS 15 Xcode (vars.CMUX_CI_XCODE_APP_MACOS_15),
                                   the pool and Xcode main's own CI runs on

    headroom = a machine free for this run (POOL_CAPACITIES less what is
               running and queued there), or at most
               vars.CI_PR_POOL_MAX_QUEUED jobs queued once it arrives
               (default 0), and no queued release or nightly job on the pool

So a full pool rolls over to the next one in the order, every time, the
macOS 15 pool included. When every pool is full, the run takes the one whose
queue is shortest in rounds (queued jobs over capacity; the earlier pool on
a tie). The macOS 15 pool has no DerivedData seed for its Xcode, so its
queue counts COLD_ROUNDS more there, for the compile it runs cold. A pool
holding a queued release or nightly job
is never chosen: pull requests must not delay those. Every Blacksmith pool
is sponsored, so cost is not a reason to prefer one.

`vars.CI_PR_POOL_OVERFLOW == '0'` turns this off. Only the labels in POOLS
are accepted, because each one's Xcode pin is known here.

Owned Macs (fleet RFC, cmuxterm-hq#573) join as class pools keyed by the
label glaeda issues, `glaeda-<class>-xcode-<version>`. glaeda puts that label
only on a dedicated member whose Xcode at the pinned path reports the pinned
build, so the one label carries the class, the availability and the Xcode.
The version follows the pull-request lane's pin (vars.CMUX_CI_XCODE_APP_PR,
`/Applications/Xcode_26.6.app` -> `glaeda-std-xcode-26.6`), so moving the
pin moves the pool, and no runner carries the new label until glaeda has
verified the new Xcode on it. Owned pools are persistent: the machine
outlives the job. They take part only when `vars.CI_PR_POOL_OWNED == '1'`,
and then go first in the default order so Blacksmith is overflow. Their
capacity is the number of machines the fleet manifest gives each label,
published as vars.CI_OWNED_POOL_SLOTS (JSON, `{"glaeda-std-xcode-26.6": 12}`;
`{"std": 12}` and a bare `12` mean the same for the lane's Xcode pin).
The janitor's snapshot counts the jobs queued and running on each owned label
from the job listings it already makes, and `committed`: what the runs
holding the pool need at their peak, read from the marker each one uploads
(`macos-pool-persistent-<run>-<attempt>-<jobs>-<pool>`), so a run whose later
jobs do not exist yet still counts them. No token beyond GITHUB_TOKEN is
needed. A run takes an owned pool only when its own peak (run_jobs) is free
at once. An owned pool is skipped when it has no slot count, and like every
pool when the snapshot is older than MAX_SNAPSHOT_MINUTES. With the org
route App's token, the idle runners carrying its label are its capacity
instead (live_owned_free). An offline machine still counts
as a slot; what that gets wrong, ci-owned-pool-rescue.yml catches: a run whose
job waits on an owned pool past its budget is re-run on Blacksmith. A re-run
of failed jobs reuses this run's outputs, so a persistent choice also names
`retry_runner`, the Blacksmith pool every macOS job takes from attempt 2 on. The owned order is `std` (48 GB minis),
then `light` (16 GB), then the Blacksmith pools: one order for every job type.

Per-job placement (`vars.CI_PR_POOL_OWNED_SPLIT == '1'`): without it, a run
takes an owned pool only when its whole peak is free, so a full suite on 9
idle minis with 2 busy went to Blacksmith entirely and queued there. With it,
when no owned pool fits the whole run, the run takes the owned pool with the
most free machines (at least one), and `owned_jobs` names the jobs that fit,
in priority order (priority()): compile admission first (the heavy compile,
and a mini keeps its warm DerivedData), then the GUI jobs (app-host shards by
index, tests-build-and-lag), which queue longest on Blacksmith, then the light
jobs (cli-product-tests, the remote daemon and Claude wrapper lanes).
Each job counts one machine; the jobs after admission reuse its machine.
Every other job of attempt 1 takes
`retry_runner`, the Blacksmith pool on the lane's Xcode. The shards and
cli-product-tests then run compile admission's product on another pool, which
is sound only because both run the same Xcode: the owned label names the
lane's pin, and on 2026-09-24 the minis and Blacksmith's 6vcpu and 12vcpu
macOS 26 images all reported Xcode 26.6 build 17F113. The product only ever
moves from a mini to Blacksmith (admission is always placed first), and
app_host_test_products.check_xcode refuses a product linked by a newer Xcode
than the consumer's, so a drift fails closed instead of crashing in dlopen.
The marker's `<jobs>` is the owned machines the run holds at its peak, so the
janitor's `committed` counts only the owned jobs actually placed. With the
split off, a run takes an owned pool only when all its owned-eligible jobs fit.

Root jobs: glaeda gives compile admission, the app-host shards,
tests-build-and-lag and cli-product-tests (and any job it does not know) the
mini's one canonical-root token, and refuses such a job on a mini whose token
is taken. GitHub hands a pool-label job to any free runner, so a root job on
the pool label could land on a mini whose root was busy and cost a rescue
re-run. glaeda also labels one runner per mini
`glaeda-root-<class>-xcode-<version>` (root_label()), and a root job on that
label waits for a free root instead. CI_OWNED_POOL_SLOTS gives the root
runners' count beside the pool's (`{"std": 40, "root-std": 10}`). A pool with
a root count sends its placed root jobs (ROOT_JOBS) to the `root_runner`
output, and place() puts no more of them there than its root runners free; a
pool without one keeps the pool label for every job. The side lanes keep the
pool label either way. A root job also holds one of the pool's machines, so
it counts against both.

Warm affinity: an owned Mac keeps compile admission's DerivedData
(owned_build_state.py), and ci-owned-warm-labels.yml labels its root runner
`glaeda-warm-<sha12>` for each main commit that build starts from cheaply
(owned_warm_labels.py). When admission is placed on a pool with a root count
and the runners were read live, the picker looks for an idle root runner of
that pool carrying the label of this run's merge base (MERGED_ONTO, the merge
commit's first parent) and, if one does, writes `admission_runner`, the JSON
array `["<root label>", "glaeda-warm-<sha12>"]`, which admission's attempt 1
takes as its runs-on. Otherwise it is empty and admission takes the root
label. The match is exact: v1 does not rank runners by commit distance. A
warm runner taken between the pick and the queue leaves admission waiting on
the label, and ci-owned-pool-rescue.yml moves it to Blacksmith.

GUI jobs (app-host shards, tests-build-and-lag) take an owned pool unless
`vars.CI_PR_POOL_OWNED_GUI == '0'`: the minis' runners are LaunchAgents in
the logged-in user's Aqua session, and each mini runs one job at a time. With
it 0 they take `retry_runner`. ci.yml turns off `unit_in_admission` for every
persistent pick, so the changed suites a compile admission would run itself
move to shard 8: glaeda gives admission the compile token, not the gui token. A run's owned peak
(`jobs`, and the marker's) counts only the jobs that may take the pool.

The queue comes from the queue janitor, which lists every in-flight run's
jobs each sweep and publishes what it saw as the `macos-pool-load` artifact.
Only a copy uploaded by a run on main of this repository counts, so no other
branch can steer the choice. The janitor sweeps every 10 to 30 minutes, so
every pull request run created since the snapshot is replayed through the
same rule first, one job each, filling a pool's idle slots (its capacity
less what is running) before they count as queued, so a burst of pushes
spreads across the pools instead of all taking the one that looked idle. That costs three
API requests (the artifact listing, its download redirect, and one page of
CI runs); listing jobs here would cost one per in-flight run on every push,
out of the GITHUB_TOKEN's shared budget of about 1000 an hour. A snapshot
older than MAX_SNAPSHOT_MINUTES counts as unknown.

A pull request from a fork into manaflow-ai/cmux gets no repository
variables. It follows the settings and lane the janitor copied into the
snapshot (so the kill switch reaches it too), never pins an Xcode (each job
selects the newest SDK 26 Xcode on the pool it lands on, and the product
consumers restate compile admission's empty pin), and only lands on
ephemeral Blacksmith pools.

A retry attempt (GITHUB_RUN_ATTEMPT above 1) never takes a persistent pool
either. A job queued on a persistent pool waits for it however long it stays
busy, so owned_pool_rescue.py cancels such a run and re-runs it, and the
re-run has to land somewhere with capacity. A rerun after a job failed on an
owned Mac lands on Blacksmith for the same reason. One exception, off unless
`vars.CI_OWNED_LIGHT_RETRY == '1'`: attempt 2 (LIGHT_RETRY_ATTEMPT) may take
a `light` owned pool, the next fleet tier, when its whole owned peak is free
there by the same rule as attempt 1, and only when github-actions[bot]
started it (GITHUB_TRIGGERING_ACTOR, the same gate as ci.yml's runs-on for
pr_refused_retry_runner). That attempt is the full re-run the
rescue starts for a job stuck queued on `std`, which picks again; the rescue
watches it, and a job stuck or refused there goes to Blacksmith on attempt
3. The order is std, then light, then Blacksmith. The `persistent` output
tells ci.yml to publish the marker the rescue watcher looks for.

Anything uncertain keeps today's route: an event other than pull_request, a
lane (MACOS_RUNNER_PR) naming another pool or unset (the documented way back
to the macOS 15 lane), an API error, a missing, stale or malformed snapshot,
or an invalid setting. The script then prints an empty runner, and every
job's own expression resolves exactly as before.
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
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections.abc import Callable, Mapping, Sequence
from typing import Any

DEFAULT_RUNNER = "blacksmith-6vcpu-macos-26"
LARGE_RUNNER = "blacksmith-12vcpu-macos-26"
MACOS_15_RUNNER = "blacksmith-6vcpu-macos-15"
# Pool -> the variable holding its Xcode pin; "" keeps the pull-request lane's
# own pin, which is right for every macOS 26 pool.
POOLS = {
    LARGE_RUNNER: "",
    DEFAULT_RUNNER: "",
    MACOS_15_RUNNER: "CMUX_CI_XCODE_APP_MACOS_15",
}
DEFAULT_ORDER = (LARGE_RUNNER, DEFAULT_RUNNER, MACOS_15_RUNNER)
# Owned classes in preference order, ahead of Blacksmith in the default order
# once CI_PR_POOL_OWNED is 1. Their label embeds the lane's Xcode version, and
# their POOLS pin is "" (the lane's own), which is the Xcode that label names.
RUN_CLASSES = ("std", "light")
# `glaeda-root-...` is the one runner per mini that may take a root job (ROOT_JOBS).
# `glaeda-side-...` are the other runners: the light side-lane workflows take it
# (vars.CI_SIDE_LANE_RUNNER, owned_pool_rescue.SIDE_WORKFLOW_PATHS). No picker
# routes to it, but its jobs hold its pool's machines.
OWNED_LABEL = re.compile(r"glaeda-(?:root-|side-)?(?:xl|std|light)-xcode-[0-9]+(?:\.[0-9]+)*")
ROOT_PREFIX = "glaeda-root-"
SIDE_PREFIX = "glaeda-side-"
# Capability labels glaeda puts on some runners of an owned pool, requested
# beside the pool label, never alone. `glaeda-ios-sim`: a mini with an iOS
# simulator role and an iOS 26.x runtime (ios_runner_pool.py). They are not
# pools: slots() leaves them out, and capability_slots() reads their count
# (machines, one simulator job each) from CI_OWNED_POOL_SLOTS.
CAPABILITY_LABELS = ("glaeda-ios-sim",)
# `glaeda-warm-<sha12>`: a root runner whose kept build starts from that main commit.
WARM_PREFIX = "glaeda-warm-"
WARM_KEY = re.compile(r"[0-9a-f]{12}")
XCODE_APP = re.compile(r"/Xcode_([0-9]+(?:\.[0-9]+)*)\.app/?")
PR_XCODE_VARIABLE = "CMUX_CI_XCODE_APP_PR"
OWNED_VARIABLE = "CI_PR_POOL_OWNED"
SPLIT_VARIABLE = "CI_PR_POOL_OWNED_SPLIT"
GUI_VARIABLE = "CI_PR_POOL_OWNED_GUI"
SLOTS_VARIABLE = "CI_OWNED_POOL_SLOTS"
LIGHT_RETRY_VARIABLE = "CI_OWNED_LIGHT_RETRY"
# The one retry attempt that may take the light tier (owned_pool_rescue.py's
# LAST_OWNED_ATTEMPT): later attempts always go to Blacksmith.
LIGHT_RETRY_ATTEMPT = 2
LIGHT_CLASS = "light"
# ci.yml sends attempt 2's owned-eligible jobs to pr_refused_retry_runner (the
# light label on a light pick) only when this actor started it: the rescue's
# re-run. A human re-run sends them to pr_retry_runner, so the picker must not
# take light (or publish its marker) for one.
RESCUE_ACTOR = "github-actions[bot]"
# A pull request run holds several macOS machines at once, each job on its
# own. Beside compile admission run the Claude wrapper and remote daemon
# lanes; once admission passes, a full suite adds APP_HOST_SHARDS
# shards, tests-build-and-lag and cli-product-tests, a changed-suites run one
# shard, and a CLI change cli-product-tests. A run takes an owned pool only
# when its own peak (run_jobs) is free, so none of its jobs queues there. A
# run whose peak is unknown is charged MAX_RUN_JOBS. A run created since the
# snapshot is looked up first (pull_request_routes_since): its marker gives
# the owned pool and peak it took, and a finished `changes` job without one
# means it took none. Only a run still picking is replayed and charged
# REPLAYED_RUN_JOBS, the peak of a compile-only run with every side lane.
# Charging every newer run that guess shut a 5-machine pool after two runs
# while its minis sat idle (2026-09-24). A job that still finds its mini busy
# is refused or queued, and moved to Blacksmith by ci-owned-pool-rescue.yml.
APP_HOST_SHARDS = 7
SIDE_LANES = 2
MAX_RUN_JOBS = SIDE_LANES + APP_HOST_SHARDS + 2
REPLAYED_RUN_JOBS = SIDE_LANES + 1
# Owned pools once had a stricter snapshot age (20 minutes) than the rest,
# but GitHub delays scheduled runs: the janitor's */10 cron fired 55 minutes
# apart (23:59Z to 00:54Z, 2026-09-25) and every run skipped 40 idle minis.
# They now share MAX_SNAPSHOT_MINUTES; ci-queue-janitor.yml also sweeps when CI
# is requested, and a mini that turns out busy is caught by the rescue.
# With live owned capacity (live_owned_free), runs this recent are subtracted
# from the idle runners: their owned jobs may not have reached a runner yet.
# Older runs' owned jobs are already running, so the runners API shows them busy.
LIVE_WINDOW_MINUTES = 3
# Pools whose machines are discarded after each job; the only ones a fork run may use.
EPHEMERAL_PREFIX = "blacksmith-"

OVERFLOW_VARIABLE = "CI_PR_POOL_OVERFLOW"
ORDER_VARIABLE = "CI_PR_POOL_ORDER"
MAX_QUEUED_VARIABLE = "CI_PR_POOL_MAX_QUEUED"
# A full pool rolls over: a run queues behind a busy pool only when every
# pool in the order is full.
DEFAULT_MAX_QUEUED = 0
# A pool on another Xcode than the lane's pin (the macOS 15 pool, 26.3) has no
# DerivedData seed: seed-derived-data.yml seeds the lane's Xcode only. Its
# compile admission runs cold, 10 to 20 minutes longer than a seeded one
# (1,034 s and 1,537 s against a 321 s median on 2026-09-24), about one more
# job's length. When every pool is full it counts one more round of queue.
# A free machine there still beats queueing on a full macOS 26 pool: on
# 2026-09-24 the 6vcpu macOS 26 pool queued 45 jobs and 12vcpu 18 while
# macOS 15 ran 1 to 5 of its 10.
COLD_ROUNDS = 1
# Concurrent jobs each Blacksmith macOS pool ran at most while jobs queued
# behind it, from the janitor's snapshots of 2026-09-24: 10 or 11 on each
# 6vcpu pool, 3 to 5 on 12vcpu (it once showed 7) with 8 to 18 queued.
# 12vcpu is counted at 5, the most it ran in several snapshots with jobs
# queued behind it, so it fills first and rolls over when full, not after
# 10 jobs that queue behind it.
POOL_CAPACITIES = {
    "blacksmith-12vcpu-macos-26": 5,
    "blacksmith-6vcpu-macos-26": 10,
    "blacksmith-6vcpu-macos-15": 10,
}
POOL_CAPACITY = 10

ARTIFACT_NAME = "macos-pool-load"
SNAPSHOT_FILE = "macos-pool-load.json"
SNAPSHOT_BRANCH = "main"
CI_WORKFLOW = "ci.yml"
MAX_SNAPSHOT_MINUTES = 45
PAGE_SIZE = 100
# The marker ci.yml's changes job uploads when it puts a run on an owned pool.
OWNED_MARKER = re.compile(r"macos-pool-persistent-(?P<run>[0-9]+)-(?P<attempt>[0-9]+)-(?P<jobs>[0-9]+)-(?P<pool>.+)")
# The job that runs this picker; once it finishes, a run without a marker is off the owned pools.
ROUTING_JOB = "changes"
# The changes job step that is skipped exactly when the pick was not an owned pool.
MARKER_STEP = "Mark a run on a persistent macOS pool"
# Newer runs looked up one by one (two requests at most each); any past this
# many are replayed as unknown.
ROUTE_LOOKUPS = 8
API = "https://api.github.com"


@dataclasses.dataclass(frozen=True)
class Settings:
    order: tuple[str, ...] = DEFAULT_ORDER
    max_queued: int = DEFAULT_MAX_QUEUED
    # Owned labels the order named for another Xcode than the lane's pin.
    stale: tuple[str, ...] = ()


def persistent(label: str) -> bool:
    """An owned pool: its machines outlive the job, so a queued job there can wait for good."""
    return bool(OWNED_LABEL.fullmatch(label or ""))


def root_label(label: str) -> str:
    """The root runners' label for an owned pool label, or "" for any other label."""
    if not persistent(label) or label.startswith((ROOT_PREFIX, SIDE_PREFIX)):
        return ""
    return ROOT_PREFIX + label.removeprefix("glaeda-")


def pool_label(label: str) -> str:
    """The owned pool a root or side label's runners belong to; any other label unchanged."""
    for prefix in (ROOT_PREFIX, SIDE_PREFIX):
        if persistent(label) and label.startswith(prefix):
            return "glaeda-" + label.removeprefix(prefix)
    return label


def owned_pools(pr_xcode_app: str | None) -> tuple[str, ...]:
    """The owned pool labels for the lane's Xcode pin; none when the pin names no version."""
    match = XCODE_APP.search(pr_xcode_app or "")
    if not match:
        return ()
    return tuple(f"glaeda-{name}-xcode-{match.group(1)}" for name in RUN_CLASSES)


@dataclasses.dataclass(frozen=True)
class Choice:
    runner: str  # "" keeps every job's own fallback expression
    xcode_app: str  # "" keeps every job's own Xcode pin
    reason: str
    # For a persistent runner only: the Blacksmith pool (the lane's own Xcode)
    # a re-run of failed jobs takes instead, since it reuses this run's pick.
    retry_runner: str = ""
    # For a persistent runner only: its machines free for this run (capped at
    # the run's peak), which place() fills in priority order.
    owned_budget: int = 0
    # For a Blacksmith pick on the lane's Xcode only: the pool the app-host
    # shards take, when another pool on that Xcode has more room for them
    # (spread_shards). "" keeps them on compile admission's pool.
    shard_runner: str = ""
    # For a persistent runner with a root count only: its root label, which
    # the placed root jobs take, and its root runners free for this run.
    root_runner: str = ""
    root_budget: int = 0


@dataclasses.dataclass(frozen=True)
class Routed:
    """Pull request runs created since the snapshot and still in flight.

    `owned` maps an owned pool to the machines the runs it took there need at
    their peak, read from each run's marker. `ephemeral` counts runs whose
    pick already finished without a marker, so they hold no owned machine.
    `unknown` counts runs whose pick this one cannot see yet; they are
    replayed and charged REPLAYED_RUN_JOBS on an owned pool they could take.
    """
    unknown: int = 0
    owned: Mapping[str, int] = dataclasses.field(default_factory=dict)
    ephemeral: int = 0


def flag(value: str | None) -> bool:
    return (value or "").strip() == "true"


# The job keys `owned_jobs` lists; each workflow job tests for its own key.
ADMISSION_JOB = "admission"
# The changed-suites worker is matrix shard 8 (ci-macos.yml app-host-unit-tests).
CHANGED_SUITES_SHARD = 8


@dataclasses.dataclass(frozen=True)
class RunJobs:
    """A run's macOS jobs by key: compile admission, what runs after it, and beside it."""
    admission: bool
    after: tuple[str, ...]  # after admission, in owned priority order; they reuse its machine
    side: tuple[str, ...]  # beside admission and what follows it

    @property
    def peak(self) -> int:
        return len(self.side) + (max(1, len(self.after)) if self.admission else 0)


def shard_job(index: int) -> str:
    return f"shard-{index}"


# A full suite with every side lane: what a run whose routing is unknown is charged.
FULL_RUN = RunJobs(True, (*(shard_job(index) for index in range(1, APP_HOST_SHARDS + 1)), "lag", "cli-product"),
                   ("claude-wrapper", "remote-daemon"))


def run_plan(*, macos: str | None, full_suite: str | None, unit_suite: str | None,
             unit_in_admission: str | None, claude_wrapper: str | None, cli: str | None,
             remote_daemon: str | None, unit_selectors: str | None = None) -> RunJobs:
    """This run's macOS jobs, from the changes job's routing.

    Counted high on purpose: compile admission is assumed to run (the reuse
    checks come later), and a changed-suites canary that may yet be dropped
    counts its shard. ci-macos.yml runs admission for a macOS or a CLI change,
    and cli-product-tests after it for a CLI change or a full suite. A unit
    suite with no selectors (the unit-ci label) runs all seven shards; with
    selectors, the one changed-suites worker. `unit_selectors` None (a caller
    that does not know) counts one shard, as before.
    """
    full = flag(macos) and flag(full_suite)
    side = tuple(key for key, on in (("claude-wrapper", flag(claude_wrapper) or full),
                                     ("remote-daemon", flag(remote_daemon))) if on)
    if not (flag(macos) or flag(cli)):
        return RunJobs(False, (), side)
    unit = flag(macos) and flag(unit_suite) and not flag(unit_in_admission)
    if full or (unit and unit_selectors is not None and not unit_selectors.strip()):
        shards = tuple(shard_job(index) for index in range(1, APP_HOST_SHARDS + 1))
    elif unit:
        shards = (shard_job(CHANGED_SUITES_SHARD),)
    else:
        shards = ()
    after = shards + (("lag",) if full else ()) + (("cli-product",) if flag(cli) or full else ())
    return RunJobs(True, after, side)


def run_jobs(**routing: str | None) -> int:
    """Most macOS machines this run holds at once, from the changes job's routing (run_plan)."""
    return run_plan(**routing).peak


# Owned placement priority: the heavy compile, then GUI jobs (the longest
# Blacksmith queues), then light jobs. GUI jobs need the mini's console
# session; CI_PR_POOL_OWNED_GUI=0 keeps them off.
LIGHT_JOBS = ("cli-product", "remote-daemon", "claude-wrapper")
# glaeda's canonical-root jobs: admission and every job after it (RunJobs.after:
# the shards, tests-build-and-lag, cli-product-tests). The side lanes are not.
ROOT_JOBS = "admission, shards, lag, cli-product"


def gui_job(key: str) -> bool:
    return key == "lag" or key.startswith("shard-")


def priority(key: str) -> tuple[int, int]:
    if key == ADMISSION_JOB:
        return 0, 0
    if key.startswith("shard-"):
        return 1, int(key.removeprefix("shard-"))
    if key == "lag":
        return 2, 0
    return 3, LIGHT_JOBS.index(key)


def owned_peak(plan: RunJobs, gui: bool = True) -> int:
    """The machines a run holds on an owned pool when every job that may take one does."""
    return place(plan, plan.peak, gui)[1]


def root_held(plan: RunJobs, keys: Sequence[str]) -> int:
    """The root runners `keys` hold at peak: admission, then the jobs after it (ROOT_JOBS)."""
    after = sum(1 for key in keys if key in plan.after)
    return max(1, after) if ADMISSION_JOB in keys else after


def root_peak(plan: RunJobs, gui: bool = True) -> int:
    """The root runners a run holds on an owned pool when every job that may take one does."""
    return root_held(plan, place(plan, plan.peak, gui)[0])


def place(plan: RunJobs, budget: int, gui: bool = True,
          root_budget: int | None = None) -> tuple[tuple[str, ...], int]:
    """The jobs that take the owned pool with `budget` machines free, and the machines they hold at peak.

    Jobs are taken in priority() order while the run's owned peak stays within
    `budget`: the side lanes (beside admission) plus the larger of admission
    and the jobs after it, which reuse its machine. A job that does not fit is
    skipped, and a later one that does is still taken. Admission comes first,
    so a run whose admission is not placed places nothing after it. Without
    `gui`, GUI jobs (gui_job()) are never placed. With `root_budget` (a pool
    with a root count), the root runners held (root_held()) stay within it too.
    """
    chosen: list[str] = []

    def held(keys: Sequence[str]) -> int:
        side = sum(1 for key in keys if key in plan.side)
        after = sum(1 for key in keys if key in plan.after)
        return side + (max(1, after) if ADMISSION_JOB in keys else after)

    keys = ((ADMISSION_JOB,) if plan.admission else ()) + plan.after + plan.side
    for key in sorted((key for key in keys if gui or not gui_job(key)), key=priority):
        if key in plan.after and ADMISSION_JOB not in chosen:
            continue
        if held([*chosen, key]) <= max(0, budget) and (
                root_budget is None or root_held(plan, [*chosen, key]) <= max(0, root_budget)):
            chosen.append(key)
    return tuple(chosen), held(chosen)


def settings(overflow: str | None, order: str | None, max_queued: str | None,
             owned: str | None = None, pr_xcode_app: str | None = None) -> Settings | None:
    """Settings from repository variables; None when turned off or invalid.

    Owned pools are dropped from the order unless `owned` is "1", even when
    CI_PR_POOL_ORDER names them, so one variable turns the fleet on and off.
    An owned label for another Xcode than the lane's pin is dropped too and
    reported, so a moved pin never turns off the Blacksmith preference.
    """
    if (overflow or "").strip() == "0":
        return None
    use_owned = (owned or "").strip() == "1"
    current = owned_pools(pr_xcode_app)
    default = (current + DEFAULT_ORDER) if use_owned else DEFAULT_ORDER
    labels = tuple(label.strip() for label in (order or "").split(",") if label.strip()) or default
    if not use_owned:
        # Dropped before validation: a fork run reads the order without the
        # lane's Xcode pin, and must not lose the Blacksmith preference to it.
        labels = tuple(label for label in labels if not persistent(label))
        if not labels:
            return None
    stale = tuple(label for label in labels if persistent(label) and label not in current)
    labels = tuple(label for label in labels if label not in stale)
    if not labels:
        return None
    if len(set(labels)) != len(labels) or any(label not in POOLS and label not in current for label in labels):
        return None
    try:
        limit = int(max_queued) if (max_queued or "").strip() else DEFAULT_MAX_QUEUED
    except ValueError:
        return None
    if limit < 0:
        return None
    return Settings(labels, limit, stale)


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def snapshot_age_minutes(snapshot: Mapping[str, Any], now: dt.datetime) -> float | None:
    generated = parse_time(str(snapshot.get("generated_at") or ""))
    if generated is None:
        return None
    return (now - generated).total_seconds() / 60


def slots(raw: str | None, pr_xcode_app: str | None = None) -> dict[str, int]:
    """CI_OWNED_POOL_SLOTS: owned pool label -> machines. Anything malformed counts as none."""
    return _slots(raw, pr_xcode_app)[0]


def capability_slots(raw: str | None) -> dict[str, int]:
    """CI_OWNED_POOL_SLOTS: capability label -> machines carrying it (`{"glaeda-ios-sim": 2}`)."""
    try:
        data = json.loads((raw or "").strip() or "{}")
    except ValueError:
        return {}
    if not isinstance(data, Mapping):
        return {}
    return {str(label): count for label, count in data.items()
            if str(label) in CAPABILITY_LABELS and isinstance(count, int) and not isinstance(count, bool) and count > 0}


def slot_problems(raw: str | None, pr_xcode_app: str | None = None) -> list[str]:
    """Why CI_OWNED_POOL_SLOTS, or an entry of it, counts as no machines.

    The picker treats all of these as zero slots, which is safe but silent: a
    mistyped label or a count of "11" or 11.0 just leaves the pool unused.
    main() turns each one into a workflow error annotation.
    """
    return _slots(raw, pr_xcode_app)[1]


def _slots(raw: str | None, pr_xcode_app: str | None = None) -> tuple[dict[str, int], list[str]]:
    # Accepted forms, so a plausible value never silently means "no minis":
    #   {"glaeda-std-xcode-26.6": 40}  a full label
    #   {"std": 40, "light": 4}        a class, for the lane's Xcode pin
    #   40                             the std class, for the lane's Xcode pin
    #   {"root-std": 10}               a class's root runners, one per mini
    #   {"glaeda-root-std-xcode-26.6": 10}  (root_label()), beside its pool
    #   {"glaeda-ios-sim": 2}          a capability label (capability_slots()), no pool
    text = (raw or "").strip()
    if not text:
        return {}, []
    try:
        data = json.loads(text)
    except ValueError as error:
        return {}, [f"{SLOTS_VARIABLE} is not JSON ({error})"]
    if isinstance(data, int) and not isinstance(data, bool):
        data = {"std": data}
    if not isinstance(data, Mapping):
        return {}, [f"{SLOTS_VARIABLE} is not a JSON object or a whole number"]
    match = XCODE_APP.search(pr_xcode_app or "")
    counted, by_class, problems = {}, {}, []
    for label, count in data.items():
        label = str(label)
        if not isinstance(count, int) or isinstance(count, bool) or count <= 0:
            problems.append(f"{SLOTS_VARIABLE} entry {label!r} has {count!r} machines, not a positive whole number")
        elif label.startswith(("side-", SIDE_PREFIX)):
            # No picker routes to side runners (vars.CI_SIDE_LANE_RUNNER does), so a count is a mistake.
            problems.append(f"{SLOTS_VARIABLE} entry {label!r} names side runners, which take no picked run")
        elif label in CAPABILITY_LABELS:
            continue
        elif persistent(label):
            counted[label] = count
        elif OWNED_LABEL.fullmatch(f"glaeda-{label}-xcode-0"):
            if match:
                by_class[f"glaeda-{label}-xcode-{match.group(1)}"] = count
            else:
                problems.append(f"{SLOTS_VARIABLE} entry {label!r} names a class, but {PR_XCODE_VARIABLE} "
                                "names no Xcode version to pair it with")
        else:
            problems.append(f"{SLOTS_VARIABLE} entry {label!r} is not an owned pool label "
                            "(glaeda-[root-]<class>-xcode-<version>) or class (std, light, xl, root-std, ...)")
    # A full label is more specific than its class, so it wins.
    counted = {**by_class, **counted}
    for label, count in list(counted.items()):
        # Each root runner is one of its pool's machines, so a larger count is a typo.
        machines = counted.get(pool_label(label), 0)
        if label.startswith(ROOT_PREFIX) and count > machines:
            problems.append(f"{SLOTS_VARIABLE} gives {label} {count} root runners, more than the "
                            f"{machines} machines of {pool_label(label)}")
            del counted[label]
    return counted, problems


def pool(snapshot: Mapping[str, Any], label: str, owned_slots: Mapping[str, int] | None = None) -> Mapping[str, int]:
    """One pool's counts; a pool the janitor saw no job on is empty, not unknown.

    `capacity` is POOL_CAPACITIES' entry for a Blacksmith pool and the slot count for
    an owned pool (0 when CI_OWNED_POOL_SLOTS gives it none). `committed` is
    what the janitor counted the runs holding an owned pool to need at their
    peak, including jobs they have not created yet.
    """
    entry = (snapshot.get("pools") or {}).get(label) or {}
    counts = {key: int(entry.get(key) or 0)
              for key in ("queued", "running", "reserved_queued", "oldest_queued_minutes", "committed")}
    counts["capacity"] = int((owned_slots or {}).get(label) or 0) if persistent(label) else POOL_CAPACITIES.get(label, POOL_CAPACITY)
    counts["cold"] = int(cold(label))
    return counts


def describe(snapshot: Mapping[str, Any], label: str, owned_slots: Mapping[str, int] | None = None) -> str:
    counts = pool(snapshot, label, owned_slots)
    text = f"{label}: {counts['queued']} queued, {counts['running']} running"
    if persistent(label):
        text += f" of {counts['capacity']} slots"
    if counts["queued"]:
        text += f", oldest {counts['oldest_queued_minutes']} min"
    if counts["reserved_queued"]:
        text += f", {counts['reserved_queued']} release/nightly queued"
    return text


def effective_queue(counts: Mapping[str, int], added: int) -> int:
    """Queued jobs once `added` more arrive: they fill the pool's idle slots first.

    A pool with jobs queued is already full, so everything added queues. One
    with none queued has capacity - running idle slots to fill first.
    """
    idle = 0 if counts["queued"] else max(0, counts.get("capacity", POOL_CAPACITY) - counts["running"])
    return counts["queued"] + max(0, added - idle)


def cold(label: str) -> bool:
    """A pool whose Xcode is not the lane's pin, so no DerivedData seed matches it."""
    return bool(POOLS.get(label))


def owned_free(counts: Mapping[str, int], added_runs: int, taken_since: int = 0) -> int:
    """Machines of an owned pool still free once `added_runs` more runs took theirs.

    Taken is the larger of the jobs the janitor saw and what the runs holding
    the pool will need at their peak, so a run whose later jobs do not exist
    yet still counts them. `taken_since` is the known peak of the runs that
    took the pool since the snapshot, from their markers. Each run replayed
    since the snapshot is charged REPLAYED_RUN_JOBS, since its own peak is
    unknown here.
    """
    taken = max(counts["running"] + counts["queued"], counts.get("committed", 0))
    return counts.get("capacity", 0) - taken - taken_since - added_runs * REPLAYED_RUN_JOBS


def iso(moment: dt.datetime) -> str:
    return moment.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def live_owned_free(runners: Sequence[Mapping[str, Any]], labels: Sequence[str]) -> dict[str, int]:
    """Runners online, not busy and carrying each owned label: its free machines now."""
    free = {label: 0 for label in labels}
    for runner in runners:
        if runner.get("status") != "online" or runner.get("busy"):
            continue
        names = {str(item.get("name")) for item in runner.get("labels") or [] if isinstance(item, Mapping)}
        for label in labels:
            if label in names:
                free[label] += 1
    return free


def warm_label(commit: str | None) -> str:
    """The warm label for a commit (its first 12 hex digits), or "" for anything else."""
    key = (commit or "").strip().lower()[:12]
    return WARM_PREFIX + key if WARM_KEY.fullmatch(key) else ""


def warm_admission_runner(runners: Sequence[Mapping[str, Any]], root: str, merged_onto: str | None) -> str:
    """Admission's runs-on labels as JSON when an idle `root` runner is warm for `merged_onto`, else ""."""
    warm = warm_label(merged_onto)
    if not warm or not root.startswith(ROOT_PREFIX):
        return ""
    for runner in runners:
        if runner.get("status") != "online" or runner.get("busy"):
            continue
        names = {str(item.get("name")) for item in runner.get("labels") or [] if isinstance(item, Mapping)}
        if root in names and warm in names:
            return json.dumps([root, warm], separators=(",", ":"))
    return ""


def pick(load: Mapping[str, Mapping[str, int]], added: Mapping[str, int], usable: Sequence[str],
         max_queued: int, jobs: int = MAX_RUN_JOBS,
         taken: Mapping[str, int] | None = None, split: bool = False,
         root_free: Mapping[str, int] | None = None, root_jobs: int = 0) -> tuple[str, bool]:
    """The rule itself: first usable pool with headroom, else the shortest queue.

    An owned pool has headroom only while every job of this run gets a machine
    at once (`jobs` of them, its peak): a job queued there waits for that pool
    alone. With `split`, when no owned pool fits the whole run, the owned pool
    with the most machines free (the earlier on a tie) has headroom too, if it
    has one: the jobs that do not fit go to Blacksmith (place()). A pool in
    `root_free` (it has a root count) fits the whole run only while its
    `root_jobs` root runners are free too. An owned pool is never the
    fallback.

    A Blacksmith pool has headroom while this run's job still finds a free
    machine there (or at most max_queued queue once it arrives), so a full
    pool rolls over to the next. When all are full, the fallback is the
    shortest queue in rounds, a cold pool (cold()) counting COLD_ROUNDS more.
    """
    queued = {label: effective_queue(load[label], added[label] + 1) for label in usable}
    free = {label: owned_free(load[label], added[label], (taken or {}).get(label, 0))
            for label in usable if persistent(label)}
    fits = [label for label in free if free[label] >= max(1, jobs)
            and (root_free or {}).get(label, root_jobs) >= root_jobs]
    if split and not fits and free and max(free.values()) >= 1:
        fits = [max(free, key=lambda label: free[label])]
    for label in usable:
        if persistent(label):
            if label in fits:
                return label, True
        elif queued[label] <= max_queued:
            return label, True
    fallback = [label for label in usable if not persistent(label)] or list(usable)
    return min(fallback, key=lambda label: rounds(load[label], queued[label])), False


def rounds(counts: Mapping[str, int], queued: int) -> float:
    """How many job lengths a job queued there waits, a cold pool one more."""
    return queued / max(1, counts.get("capacity", POOL_CAPACITY)) + (COLD_ROUNDS if counts.get("cold") else 0)


def decide(
    snapshot: Mapping[str, Any] | None,
    limits: Settings,
    *,
    now: dt.datetime,
    xcode_pins: Mapping[str, str],
    routed_since: int = 0,
    owned_since: Mapping[str, int] | None = None,
    ephemeral_since: int = 0,
    auto_xcode: bool = False,
    placed: Mapping[str, int] | None = None,
    choose_from: Sequence[str] | None = None,
    owned_slots: Mapping[str, int] | None = None,
    jobs: int = MAX_RUN_JOBS,
    split: bool = False,
    shards: int = 0,
    root_jobs: int = 0,
) -> Choice:
    """The preference rule over a janitor snapshot. Uncertainty keeps today's route.

    `routed_since` runs were created after the snapshot and each already took
    a pool by this rule; they are replayed first. `placed` counts runs created
    since the snapshot whose pool is already known (an E2E run names it), one
    job each. `auto_xcode` (a fork run, which has no pins) lets every pool
    fall back to each job selecting its pool's newest SDK 26 Xcode.
    `choose_from` limits the final pick to some pools of the order (E2E stays
    on macOS 26) while the replay still spreads over the whole order. `jobs`
    is this run's peak machine count, which an owned pool must have free.
    Replayed runs are placed as if they needed one machine (so any that could
    have taken an owned pool is assumed to) and charged REPLAYED_RUN_JOBS there.
    `owned_since` is what runs since the snapshot took on each owned pool, by
    their markers, and `ephemeral_since` counts runs whose pick finished off
    the owned pools; those are replayed over the Blacksmith pools only.
    `split` lets this run take part of an owned pool (pick(), place()).
    `root_jobs` is this run's peak on root runners, which an owned pool with
    a root count must have free too. Its root runners are charged one per
    replayed run (its admission), and a newer run's whole marker peak, since
    a marker does not split it.
    """
    if not isinstance(snapshot, Mapping) or not isinstance(snapshot.get("pools"), Mapping):
        return Choice("", "", "no readable pool snapshot")
    age = snapshot_age_minutes(snapshot, now)
    if age is None or age < -5 or age > MAX_SNAPSHOT_MINUTES:
        return Choice("", "", f"pool snapshot is stale or undated (age {age if age is None else round(age)} min)")
    try:
        load = {label: pool(snapshot, label, owned_slots) for label in limits.order}
        roots = {label: pool(snapshot, root_label(label), owned_slots) for label in limits.order
                 if root_label(label) and root_label(label) in (owned_slots or {})}
    except (TypeError, ValueError, AttributeError):
        return Choice("", "", "malformed pool snapshot")

    def xcode(label: str) -> str | None:
        variable = POOLS.get(label, "")
        if not variable or auto_xcode:
            return ""
        return (xcode_pins.get(variable) or "").strip() or None

    def counted(label: str) -> bool:
        """An owned pool places runs only with a machine free by its slot count or live."""
        return not persistent(label) or load[label]["capacity"] > 0

    usable = [label for label in limits.order
              if load[label]["reserved_queued"] == 0 and xcode(label) is not None and counted(label)]
    if not usable:
        return Choice("", "", "every pool in the order is reserved, has no Xcode pin, or is an owned pool "
                              "without slots")
    candidates = [label for label in usable if choose_from is None or label in choose_from]
    if not candidates:
        return Choice("", "", "every pool this run may take is reserved or has no Xcode pin")
    skipped = [label for label in limits.order if label not in usable]
    note = f"; skipped {', '.join(skipped)} (reserved, no Xcode pin, or owned without slots)" if skipped else ""
    added = {label: max(0, int((placed or {}).get(label) or 0)) for label in usable}
    taken = {label: max(0, int((owned_since or {}).get(label) or 0)) for label in usable if persistent(label)}
    ephemeral = [label for label in usable if not persistent(label)]
    for _ in range(max(0, ephemeral_since) if ephemeral else 0):
        earlier, _ = pick(load, added, ephemeral, limits.max_queued, jobs=1)
        added[earlier] += 1
    for _ in range(max(0, routed_since)):
        earlier, _ = pick(load, added, usable, limits.max_queued, jobs=1, taken=taken)
        added[earlier] += 1
    root_free = {label: owned_free(counts, 0, taken.get(label, 0)) - added[label]
                 for label, counts in roots.items() if label in usable}
    label, headroom = pick(load, added, candidates, limits.max_queued, jobs, taken=taken, split=split,
                           root_free=root_free, root_jobs=root_jobs)
    if persistent(label) and not headroom:
        return Choice("", "", "every owned pool this run may take is busy, and no other pool is in the order")
    replayed = sum(added.values())
    replay = f" after replaying {replayed} newer run(s)" if replayed else ""
    if any(taken.values()):
        replay += " and counting " + ", ".join(f"{count} machine(s) newer runs took on {pool_label}"
                                               for pool_label, count in taken.items() if count)
    free = 0
    if headroom and persistent(label):
        free = owned_free(load[label], added[label], taken.get(label, 0))
        root = (f"; {root_free[label]} of {roots[label]['capacity']} root runners free, it needs {root_jobs}"
                if label in root_free else "")
        if free >= max(1, jobs) and root_free.get(label, root_jobs) >= root_jobs:
            why = (f"first pool in order with headroom ({free} of {load[label]['capacity']} owned machines free, "
                   f"this run needs {max(1, jobs)}{root}){replay}")
        else:
            why = (f"owned pool with the most machines free ({free} of {load[label]['capacity']}, this run needs "
                   f"{max(1, jobs)}{root}): the jobs that fit run there, the rest on the retry runner{replay}")
    elif headroom:
        why = f"first pool in order with a free machine{replay}" if not limits.max_queued else \
              f"first pool in order with headroom (<= {limits.max_queued} queued){replay}"
    elif len(candidates) == 1:
        why = f"the only pool this run may take{replay}"
    else:
        why = f"every pool is full{replay}; shortest queue in rounds"
        waits = {pool_label: effective_queue(load[pool_label], added[pool_label] + 1) / max(1, load[pool_label]["capacity"])
                 for pool_label in candidates}
        # Name the extra round only where it counted: the winner is cold, or
        # a cold pool had a shorter queue than the winner and lost for it.
        if cold(label) or any(cold(pool_label) and waits[pool_label] < waits[label] for pool_label in candidates):
            why += f", counting {COLD_ROUNDS} more for a pool with no seed for its Xcode"
    if limits.stale:
        note += f"; dropped {', '.join(limits.stale)} (not the lane's Xcode pin)"
    retry = ""
    if persistent(label):
        # A re-run of failed jobs keeps this run's outputs, so it needs a pool
        # named now: the Blacksmith pool this rule would take on the lane's
        # own Xcode, which is also the Xcode the owned label names.
        lane = [pool_label for pool_label in usable if not persistent(pool_label) and not POOLS.get(pool_label)]
        retry = pick(load, added, lane, limits.max_queued)[0] if lane else DEFAULT_RUNNER
    shard = spread_shards(load, added, usable, label, shards)
    if shard:
        note += f"; its {shards} app-host shards take {shard}, which has more room for them"
    if persistent(label) and label in root_free:
        # By keyword: shard_runner comes first, and a persistent pick has none.
        return Choice(label, xcode(label) or "", why + note, retry, min(free, max(1, jobs)),
                      shard_runner=shard, root_runner=root_label(label), root_budget=max(0, root_free[label]))
    return Choice(label, xcode(label) or "", why + note, retry, min(free, max(1, jobs)) if persistent(label) else 0,
                  shard)


def spread_shards(load: Mapping[str, Mapping[str, int]], added: Mapping[str, int], usable: Sequence[str],
                  label: str, shards: int) -> str:
    """The pool a full suite's app-host shards take, or "" for admission's own.

    Admission and the shards need the same Xcode, not the same pool: every
    Blacksmith pool on the lane's Xcode reproduces the canonical build root, so
    the product runs on any of them. A run that compiles on the 5-machine
    12vcpu pool left its 7 shards waiting for it, the last one starting a
    median 23 minutes (p90 42) after the compile (2026-09-25). They take the
    pool on that Xcode whose queue is shortest in rounds once they all arrive
    there, admission's own on a tie.
    """
    if shards < 2 or persistent(label) or POOLS.get(label):
        return ""
    lane = [pool_label for pool_label in usable if not persistent(pool_label) and not POOLS.get(pool_label)]
    if label not in lane or len(lane) < 2:
        return ""
    after = {**added, label: added.get(label, 0) + 1}  # this run's admission

    def wait(pool_label: str) -> tuple[float, int]:
        queued = effective_queue(load[pool_label], after.get(pool_label, 0) + shards)
        return rounds(load[pool_label], queued), 0 if pool_label == label else 1 + lane.index(pool_label)

    best = min(lane, key=wait)
    return "" if best == label else best


def choose(
    *,
    event: str,
    repo: str,
    head_repo: str,
    default_runner: str,
    overflow: str | None,
    order: str | None,
    max_queued: str | None,
    xcode_pins: Mapping[str, str],
    owned: str | None = None,
    owned_slots: str | None = None,
    jobs: int = MAX_RUN_JOBS,
    split: str | None = None,
    root_jobs: int = 0,
    light_retry: str | None = None,
    triggering_actor: str | None = None,
    fetch: Callable[[], Mapping[str, Any] | None],
    count_routed: Callable[[str], "int | Routed"] = lambda since: 0,
    now: dt.datetime,
    run_attempt: int = 1,
    live_owned: Mapping[str, int] | None = None,
    shards: int = 0,
) -> tuple[Choice, Mapping[str, Any] | None]:
    """The pool for this run and the snapshot it was read from (None when none was read)."""
    if event != "pull_request":
        return Choice("", "", f"{event or 'unknown'} event; not a pull request"), None
    if not head_repo:
        return Choice("", "", "pull request head repository unknown"), None
    fork = head_repo != repo
    if not fork:
        if (default_runner or "").strip() != DEFAULT_RUNNER:
            return Choice("", "", f"MACOS_RUNNER_PR is {default_runner or 'unset'}, not {DEFAULT_RUNNER}"), None
        limits = settings(overflow, order, max_queued, owned, xcode_pins.get(PR_XCODE_VARIABLE))
        if limits is None:
            return Choice("", "", f"{OVERFLOW_VARIABLE} is 0, or {ORDER_VARIABLE}/{MAX_QUEUED_VARIABLE} "
                                  "is invalid"), None
    try:
        snapshot = fetch()
    except Exception as error:  # noqa: BLE001 - every failure keeps the default
        return Choice("", "", f"could not read the pool snapshot ({error})"), None
    if fork:
        # No repository variables reach a fork run; the janitor copied them.
        copied = snapshot.get("settings") if isinstance(snapshot, Mapping) else None
        if not isinstance(copied, Mapping):
            return Choice("", "", "fork head; the snapshot carries no settings"), snapshot
        if str(copied.get("lane") or "").strip() != DEFAULT_RUNNER:
            return Choice("", "", f"fork head; the lane is {copied.get('lane') or 'unset'}, "
                                  f"not {DEFAULT_RUNNER}"), snapshot
        limits = settings(copied.get("overflow"), copied.get("order"), copied.get("max_queued"))
        if limits is None:
            return Choice("", "", f"fork head; {OVERFLOW_VARIABLE} is 0, or the copied settings "
                                  "are invalid"), snapshot
        # Fork code runs only on ephemeral Blacksmith machines, never on a
        # persistent pool (owned Macs) that may join POOLS later.
        limits = dataclasses.replace(limits, order=tuple(
            label for label in limits.order if label.startswith(EPHEMERAL_PREFIX)))
        if not limits.order:
            return Choice("", "", "fork head; no ephemeral pool in the order"), snapshot
    retry = run_attempt > 1
    if retry:
        light = (not fork and run_attempt == LIGHT_RETRY_ATTEMPT and (light_retry or "").strip() == "1"
                 and (triggering_actor or "").strip() == RESCUE_ACTOR)
        limits = dataclasses.replace(limits, order=tuple(
            label for label in limits.order
            if not persistent(label) or light and label.startswith(f"glaeda-{LIGHT_CLASS}-")))
        if not limits.order:
            return Choice("", "", f"retry attempt {run_attempt}; no ephemeral pool in the order"), snapshot
    if not isinstance(snapshot, Mapping) or not snapshot.get("generated_at"):
        return Choice("", "", "no readable pool snapshot"), snapshot
    try:
        routed = count_routed(str(snapshot["generated_at"]))
    except Exception as error:  # noqa: BLE001 - every failure keeps the default
        return Choice("", "", f"could not count runs since the snapshot ({error})"), snapshot
    if not isinstance(routed, Routed):
        routed = Routed(unknown=int(routed))
    owned_capacity = {} if fork else slots(owned_slots, xcode_pins.get(PR_XCODE_VARIABLE))
    live = live_owned is not None and not fork
    if live:
        # The idle runners replace the slot counts and the snapshot's owned
        # counts. Only the runs of the last LIVE_WINDOW_MINUTES are charged to
        # the owned pools; the rest of the snapshot window counts on Blacksmith.
        try:
            recent = count_routed(iso(now - dt.timedelta(minutes=LIVE_WINDOW_MINUTES)))
        except Exception as error:  # noqa: BLE001 - every failure keeps the default
            return Choice("", "", f"could not count recent runs ({error})"), snapshot
        if not isinstance(recent, Routed):
            recent = Routed(unknown=int(recent))
        routed = Routed(unknown=recent.unknown, owned=recent.owned,
                        ephemeral=routed.ephemeral + max(0, routed.unknown - recent.unknown))
        # A root label counts only while CI_OWNED_POOL_SLOTS gives it a root
        # count, which is what turns root routing on (root_label()).
        owned_capacity = {label: max(0, int(count)) for label, count in (live_owned or {}).items()
                          if not label.startswith(ROOT_PREFIX) or label in owned_capacity}
        pools = dict(snapshot.get("pools") or {})
        for label in owned_capacity:
            pools[label] = {"queued": 0, "running": 0, "committed": 0}
        snapshot = {**snapshot, "pools": pools}
    choice = decide(snapshot, limits, now=now, xcode_pins={} if fork else xcode_pins,
                    routed_since=routed.unknown, owned_since=routed.owned, ephemeral_since=routed.ephemeral,
                    auto_xcode=fork, owned_slots=owned_capacity, jobs=jobs,
                    split=(split or "").strip() == "1", shards=shards,
                    root_jobs=root_jobs)
    if live and persistent(choice.runner):
        choice = dataclasses.replace(choice, reason=f"{choice.reason}; owned machines read live from the runners API")
    if fork and choice.runner:
        choice = dataclasses.replace(choice, reason=f"fork head; {choice.reason}")
    if retry and choice.runner:
        choice = dataclasses.replace(choice, reason=f"retry attempt {run_attempt}; {choice.reason}")
    return choice, snapshot


def may_hold_owned_pool(run: Mapping[str, Any], *, light_retry: bool = False) -> bool:
    """Only attempt 1 of a same-repository pull request run can take an owned pool,
    and attempt 2 too while CI_OWNED_LIGHT_RETRY is 1 (`light_retry`).

    Attempt 2 then may hold the light tier, or a refused job's retry
    (pr_refused_retry_runner); with the variable off it is not looked up,
    so no request is spent on it. The same rule as
    queue_janitor.may_hold_owned_pool: a fork runs its own ci.yml and could
    upload any marker, so its markers are never read.
    """
    if int(run.get("run_attempt") or 1) > (LIGHT_RETRY_ATTEMPT if light_retry else 1):
        return False
    head, base = (run.get("head_repository") or {}).get("id"), (run.get("repository") or {}).get("id")
    return head is not None and head == base


def run_marker(artifacts: Sequence[Any], run: Mapping[str, Any]) -> tuple[str, int] | None:
    """The owned pool and peak a run's `macos-pool-persistent-...` marker names, or None."""
    for artifact in artifacts:
        match = OWNED_MARKER.fullmatch(str((artifact or {}).get("name") or "")) if isinstance(artifact, Mapping) else None
        if (match and not artifact.get("expired") and int(match["run"]) == run.get("id")
                and int(match["attempt"]) == int(run.get("run_attempt") or 1) and persistent(match["pool"])):
            return match["pool"], min(max(1, int(match["jobs"])), MAX_RUN_JOBS)
    return None


def count_in_flight(runs: Sequence[Mapping[str, Any]], *, exclude_run_id: int | None) -> int:
    return sum(1 for run in runs if run.get("id") != exclude_run_id and run.get("status") != "completed")


def trusted_snapshot_artifact(artifact: Mapping[str, Any], branch: str) -> bool:
    """Uploaded by a run on `branch` of this repository itself, not a fork or another branch."""
    run = artifact.get("workflow_run") or {}
    return (
        not artifact.get("expired")
        and run.get("head_branch") == branch
        and run.get("repository_id") is not None
        and run.get("head_repository_id") == run.get("repository_id")
    )


def newest_snapshot_artifact(artifacts: Sequence[Any], *, now: dt.datetime,
                             branch: str = SNAPSHOT_BRANCH) -> Mapping[str, Any] | None:
    """The newest trusted snapshot artifact young enough to read, or None."""
    trusted = [artifact for artifact in artifacts
               if isinstance(artifact, Mapping) and trusted_snapshot_artifact(artifact, branch)]
    if not trusted:
        return None
    newest = max(trusted, key=lambda artifact: str(artifact.get("created_at") or ""))
    created = parse_time(newest.get("created_at"))
    if created is None or (now - created).total_seconds() / 60 > MAX_SNAPSHOT_MINUTES:
        return None
    return newest


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        return None


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-pr-runner-pool",
        }

    def get(self, path: str) -> Any:
        request = urllib.request.Request(f"{API}/repos/{self.repo}{path}", headers=self.headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read())

    def snapshot(self, *, now: dt.datetime, branch: str = SNAPSHOT_BRANCH) -> Mapping[str, Any] | None:
        """The newest trusted, unexpired janitor snapshot, in two API requests."""
        artifacts = self.get(f"/actions/artifacts?name={ARTIFACT_NAME}&per_page={PAGE_SIZE}").get("artifacts") or []
        newest = newest_snapshot_artifact(artifacts, now=now, branch=branch)
        if newest is None:
            return None
        archive = zipfile.ZipFile(io.BytesIO(self.download(newest)))
        return json.loads(archive.read(SNAPSHOT_FILE))

    def download(self, artifact: Mapping[str, Any]) -> bytes:
        """One artifact's zip archive (one API request)."""
        # The download answers with a redirect to signed blob storage, which must
        # not receive the token, so follow it by hand.
        opener = urllib.request.build_opener(_NoRedirect)
        download = urllib.request.Request(str(artifact["archive_download_url"]), headers=self.headers)
        try:
            opener.open(download, timeout=15)
            raise RuntimeError("artifact download did not redirect")
        except urllib.error.HTTPError as error:
            location = error.headers.get("Location") if error.code in (301, 302, 303, 307, 308) else None
            if not location:
                raise RuntimeError(f"artifact download failed ({error.code})") from error
        blob = urllib.request.Request(location, headers={"User-Agent": self.headers["User-Agent"]})
        with urllib.request.urlopen(blob, timeout=30) as response:
            return response.read()

    def runs_since(self, workflow: str, since: str, **filters: str) -> list[Mapping[str, Any]]:
        """One page of `workflow`'s runs created at or after `since` (one request)."""
        query = urllib.parse.urlencode({**filters, "created": f">={since}", "per_page": PAGE_SIZE})
        runs = self.get(f"/actions/workflows/{workflow}/runs?{query}").get("workflow_runs") or []
        return [run for run in runs if isinstance(run, Mapping)]

    def pull_request_routes_since(self, since: str, *, exclude_run_id: int | None,
                                  light_retry: bool = False) -> Routed:
        """Where the pull request runs since `since` went, so they are not all guessed.

        A fork run or a retry attempt never takes an owned pool, so it is off
        them without a lookup (and a fork's own marker is never trusted). For
        the rest, a marker names the owned pool and peak the run took; a
        finished `changes` job whose marker step was skipped means the pick
        was not an owned pool. Any other run (still picking, a lost marker
        upload, a failed lookup, or past ROUTE_LOOKUPS) is replayed.
        """
        runs = [run for run in self.runs_since(CI_WORKFLOW, since, event="pull_request")
                if run.get("id") != exclude_run_id and run.get("status") != "completed"]
        owned: dict[str, int] = {}
        ephemeral = unknown = looked_up = 0
        for run in runs:
            if not may_hold_owned_pool(run, light_retry=light_retry):
                ephemeral += 1
                continue
            if looked_up >= ROUTE_LOOKUPS:
                unknown += 1
                continue
            looked_up += 1
            try:
                route = self.run_route(run)
            except Exception:  # noqa: BLE001 - one unreadable run is only replayed
                route = None
            if isinstance(route, tuple):
                owned[route[0]] = owned.get(route[0], 0) + route[1]
            elif route == "ephemeral":
                ephemeral += 1
            else:
                unknown += 1
        return Routed(unknown=unknown, owned=owned, ephemeral=ephemeral)

    def run_route(self, run: Mapping[str, Any]) -> tuple[str, int] | str | None:
        """(owned pool, peak), "ephemeral", or None while this run's pick is unknown."""
        artifacts = self.get(f"/actions/runs/{run['id']}/artifacts?per_page={PAGE_SIZE}").get("artifacts") or []
        marker = run_marker(artifacts, run)
        if marker is not None:
            return marker
        jobs = self.get(f"/actions/runs/{run['id']}/jobs?filter=latest&per_page={PAGE_SIZE}").get("jobs") or []
        for job in jobs:
            if not isinstance(job, Mapping) or job.get("name") != ROUTING_JOB or job.get("status") != "completed":
                continue
            steps = [step for step in job.get("steps") or []
                     if isinstance(step, Mapping) and step.get("name") == MARKER_STEP]
            if steps and all(step.get("conclusion") == "skipped" for step in steps):
                return "ephemeral"
        return None

    def runners(self) -> list[Mapping[str, Any]]:
        """This repository's self-hosted runners (needs administration:read)."""
        found: list[Mapping[str, Any]] = []
        for page in range(1, 6):
            batch = self.get(f"/actions/runners?per_page={PAGE_SIZE}&page={page}").get("runners") or []
            found.extend(runner for runner in batch if isinstance(runner, Mapping))
            if len(batch) < PAGE_SIZE:
                break
        return found

    def pull_request_runs_since(self, since: str, *, exclude_run_id: int | None) -> int:
        """CI pull request runs created at or after `since` and still in flight (one request).

        A finished run (cancelled, superseded, or one with no macOS work)
        holds no pool, so it is not replayed. Each replayed run weighs one
        job, its compile admission: pull request runs are compile-only by
        default, so a full-suite run's shards are under-counted.
        """
        runs = self.runs_since(CI_WORKFLOW, since, event="pull_request")
        return count_in_flight(runs, exclude_run_id=exclude_run_id)


def summary(choice: Choice, snapshot: Mapping[str, Any] | None, *, now: dt.datetime,
            owned_slots: Mapping[str, int] | None = None, problems: Sequence[str] = (),
            owned_jobs: Sequence[str] = (), admission_runner: str = "") -> str:
    runner = choice.runner or "each job's default (MACOS_RUNNER_PR or its fallback)"
    lines = ["### macOS pool for this run", "", f"- Pool: `{runner}`", f"- Why: {choice.reason}"]
    if choice.xcode_app:
        lines.append(f"- Xcode: `{choice.xcode_app}`")
    if choice.retry_runner:
        lines.append(f"- Jobs on `{choice.runner}`: {', '.join(owned_jobs) or 'none'}; every other job, "
                     f"and a re-run of failed jobs, goes to: `{choice.retry_runner}`")
    if choice.root_runner:
        lines.append(f"- Root jobs among them ({ROOT_JOBS}) take `{choice.root_runner}`")
    if admission_runner:
        labels = " + ".join(f"`{label}`" for label in json.loads(admission_runner))
        lines.append(f"- Compile admission takes {labels}: an idle root runner kept a build of this run's merge base")
    for problem in problems:
        lines.append(f"- **Error:** {problem}; that pool gets no machines")
    if isinstance(snapshot, Mapping) and isinstance(snapshot.get("pools"), Mapping):
        age = snapshot_age_minutes(snapshot, now)
        lines.append(f"- Queue seen by the janitor at {snapshot.get('generated_at')}"
                     + (f" ({round(age)} min before this run)" if age is not None else "") + ":")
        for label in [*POOLS, *sorted(owned_slots or {})]:
            lines.append(f"  - {describe(snapshot, label, owned_slots)}")
    return "\n".join(lines) + "\n"


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--snapshot", help="read the snapshot from this file instead of the API")
    args = parser.parse_args(argv)
    now = dt.datetime.now(dt.timezone.utc)
    repo = env.get("GITHUB_REPOSITORY") or ""
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or ""
    run_id = (env.get("GITHUB_RUN_ID") or "").strip()
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip()

    def client() -> GitHub:
        if not token or not repo:
            raise RuntimeError("GH_TOKEN and GITHUB_REPOSITORY are required")
        return GitHub(token, repo)

    def fetch() -> Mapping[str, Any] | None:
        if args.snapshot:
            with open(args.snapshot, encoding="utf-8") as handle:
                return json.load(handle)
        return client().snapshot(now=now, branch=(env.get("POOL_SNAPSHOT_BRANCH") or SNAPSHOT_BRANCH))

    def count_routed(since: str) -> int:
        if args.snapshot:
            return 0
        return client().pull_request_routes_since(
            since, exclude_run_id=int(run_id) if run_id.isdigit() else None,
            light_retry=(env.get("OWNED_LIGHT_RETRY") or "").strip() == "1")

    # The changes job's routing, when the step runs after it; without it every
    # run is charged the most machines any run can hold.
    plan = FULL_RUN if "RUN_MACOS" not in env else run_plan(
        macos=env.get("RUN_MACOS"), full_suite=env.get("RUN_FULL_SUITE"), unit_suite=env.get("RUN_UNIT_SUITE"),
        # A persistent pick moves the changed suites out of admission to
        # shard 8 (ci.yml), so the plan always counts that shard.
        unit_in_admission="false", claude_wrapper=env.get("RUN_CLAUDE_WRAPPER"),
        cli=env.get("RUN_CLI"), remote_daemon=env.get("RUN_REMOTE_DAEMON"),
        unit_selectors=env.get("RUN_UNIT_SELECTORS"))
    # What an owned pool must have free for the whole run: its owned-eligible
    # jobs at their peak.
    gui = (env.get("POOL_OWNED_GUI") or "").strip() != "0"
    jobs = owned_peak(plan, gui)
    # The org App's token (ci.yml mints it for same-repository pull requests
    # only) reads which owned runners are idle now. Without it, or on any
    # error, the slot counts and the snapshot decide as before.
    live_owned = None
    live_runners: list[Mapping[str, Any]] | None = None
    route_token = (env.get("ROUTE_TOKEN") or "").strip()
    if route_token and repo and not args.snapshot and (env.get("POOL_OWNED") or "").strip() == "1":
        try:
            labels = owned_pools(env.get(PR_XCODE_VARIABLE))
            # Each pool's root runners too; choose() keeps those with a root count.
            labels += tuple(root_label(label) for label in labels)
            live_runners = GitHub(route_token, repo).runners() if labels else None
            live_owned = live_owned_free(live_runners, labels) if live_runners is not None else None
        except Exception as error:  # noqa: BLE001 - the snapshot path still decides
            print(f"::warning title=live owned capacity::could not list runners ({error}); using the snapshot")
            live_owned = live_runners = None
    choice, snapshot = choose(
        event=env.get("EVENT_NAME") or "",
        repo=repo,
        head_repo=env.get("HEAD_REPO") or "",
        default_runner=env.get("DEFAULT_RUNNER") or "",
        overflow=env.get("POOL_OVERFLOW"),
        order=env.get("POOL_ORDER"),
        max_queued=env.get("POOL_MAX_QUEUED"),
        owned=env.get("POOL_OWNED"),
        owned_slots=env.get("OWNED_SLOTS"),
        jobs=jobs,
        split=env.get("POOL_OWNED_SPLIT"),
        root_jobs=root_peak(plan, gui),
        light_retry=env.get("OWNED_LIGHT_RETRY"),
        triggering_actor=env.get("GITHUB_TRIGGERING_ACTOR"),
        xcode_pins={variable: env.get(variable) or ""
                    for variable in {*POOLS.values(), PR_XCODE_VARIABLE} if variable},
        fetch=fetch,
        count_routed=count_routed,
        now=now,
        run_attempt=int(attempt) if attempt.isdigit() else 1,
        live_owned=live_owned,
        shards=sum(1 for key in plan.after if key.startswith("shard-")),
    )
    pr_xcode_app = env.get(PR_XCODE_VARIABLE)
    # Only a same-repository pull request reads the slots; ci.yml blanks the pin
    # everywhere else, so checking there would flag a class entry on every run.
    same_repo_pr = env.get("EVENT_NAME") == "pull_request" and env.get("HEAD_REPO") == repo
    problems = (slot_problems(env.get("OWNED_SLOTS"), pr_xcode_app)
                if same_repo_pr and (env.get("POOL_OWNED") or "").strip() == "1" else [])
    for problem in problems:
        # An error, not a warning: a malformed entry silently takes the
        # fleet out of the order (a bare `40` did for 30 minutes on 2026-09-25).
        print(f"::error title={SLOTS_VARIABLE}::{problem}")
    # A persistent pick names the jobs that take it; every other job of the
    # run takes retry_runner. The marker's jobs are the owned machines held.
    owned_jobs, held = (place(plan, choice.owned_budget, gui, choice.root_budget if choice.root_runner else None)
                        if persistent(choice.runner) else ((), plan.peak))
    # Admission on a root runner whose kept build is of this run's merge base
    # (see "Warm affinity" above); attempt 1 only, since only it is placed.
    admission_runner = ""
    # CI_OWNED_WARM_LABELS off ignores labels already set, so the switch alone
    # turns affinity off without clearing them.
    if (env.get("WARM_LABELS") == "1" and choice.root_runner and ADMISSION_JOB in owned_jobs
            and live_runners is not None):
        admission_runner = warm_admission_runner(live_runners, choice.root_runner, env.get("MERGED_ONTO"))
    text = summary(choice, snapshot, now=now, owned_slots=slots(env.get("OWNED_SLOTS"), pr_xcode_app), problems=problems,
                   owned_jobs=owned_jobs, admission_runner=admission_runner)
    print(text)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(text)
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"runner={choice.runner}\nxcode_app={choice.xcode_app}\n"
                         f"persistent={'true' if persistent(choice.runner) else 'false'}\n"
                         f"retry_runner={choice.retry_runner}\njobs={held}\n"
                         f"shard_runner={choice.shard_runner}\n"
                         # Attempt 2 of an owned job the fleet refused tries it
                         # once more: a re-run of failed jobs reuses these outputs.
                         f"refused_retry_runner={choice.runner if persistent(choice.runner) else ''}\n"
                         # What the root jobs in owned_jobs take instead of
                         # the pool label, on attempt 1 and on that attempt 2.
                         f"root_runner={choice.root_runner}\n"
                         # JSON labels for admission's attempt 1: the root label
                         # and the warm label of this run's merge base, or "".
                         f"admission_runner={admission_runner}\n"
                         # Space-delimited with a space at each end, so each job's
                         # contains(' <key> ') test matches whole keys only.
                         f"owned_jobs={' ' + ' '.join(owned_jobs) + ' ' if owned_jobs else ''}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
