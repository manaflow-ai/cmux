#!/usr/bin/env python3
"""Pick the macOS pool a pull request CI run lands on.

ci.yml's `changes` job calls this once per run, and every pull-request macOS
job in the run reads the answer: compile admission, the app-host consumers
that follow it, tests-build-and-lag, cli-product-tests, the Claude wrapper
and remote daemon lanes. A run on a Blacksmith pool is never split across
pools, because the app-host product only loads under the Xcode that linked it
(#14163). A run on an owned pool may be, per job (see "Per-job placement"
below).

The run goes where it expects to wait least (pick()):

    vars.CI_PR_POOL_ORDER, comma-separated; by default
      blacksmith-12vcpu-macos-26   same macOS and Xcode as the lane, faster
      blacksmith-6vcpu-macos-26    vars.MACOS_RUNNER_PR today
      blacksmith-6vcpu-macos-15    macOS 15 Xcode (vars.CMUX_CI_XCODE_APP_MACOS_15),
                                   the pool and Xcode main's own CI runs on

    expected wait = the queue its job joins, in rounds (queued jobs over
                    machines, POOL_CAPACITIES), times a job's length there
                    (JOB_MINUTES: 12vcpu jobs run about twice as fast), plus
                    COLD_ROUNDS on the macOS 15 pool, which has no
                    DerivedData seed for its Xcode and compiles cold

Owned pools come first in the default order and take the run while the jobs
they would hold start within vars.CI_PR_POOL_QUEUE_ROUNDS job lengths
(default 1, at most MAX_QUEUE_ROUNDS) and within the queue bound
(owned_room()), whatever Blacksmith's expected wait: Blacksmith is overflow.
Comparing with that wait, read from a snapshot up to MAX_SNAPSHOT_MINUTES old,
sent runs off minis busy for a few minutes whenever a Blacksmith pool had
looked free. Otherwise the Blacksmith pool with the least expected wait takes
it, the earlier in the order on a tie.

The wait counts what holds a label now: jobs queued and running, and each
run since the snapshot at what it holds (young_charge(): admission and its
side lanes while it is younger than a job length, its whole peak after, when
its shards exist). So a run's shards that do not exist yet hold no idle mini:
a later run takes it, the shards join the label's queue when they exist, and
GitHub hands out runners in queue order. On 2026-09-25, 31 of 36 owned std
runners sat idle while 21 jobs queued on Blacksmith for 5 to 12 minutes,
because every in-flight run's future jobs held machines at its peak ("-5 of
15 root runners free"). The bound keeps those future jobs from growing the
queue without limit: everything the runs holding a label will need at their
peak (the janitor's `committed`, and the markers of runs since) plus this
run's peak stays within machines x (1 + rounds).

`CI_PR_POOL_QUEUE_ROUNDS == '0'` is the kill switch and restores the old rule
exactly: an owned pool only when the run's peak is free counting every run's
peak (committed and markers), then the first Blacksmith pool with a free
machine (or at most vars.CI_PR_POOL_MAX_QUEUED jobs queued once it arrives),
and when every pool is full the one whose queue is shortest in rounds (a cold
pool counting COLD_ROUNDS more). A pool
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
(`macos-pool-persistent-<run>-<attempt>-<jobs>-<pool>`). No token beyond
GITHUB_TOKEN is needed. A run replayed since the snapshot (its pick not
known yet) counts REPLAYED_RUN_JOBS on the owned pool it could take and one
on its root runners. With the rounds at 0 every run counts its whole peak
against the machines, as before (owned_free()). An owned pool is
skipped when it has no slot count, and like every pool when the snapshot is
older than MAX_SNAPSHOT_MINUTES. With the org route App's token, the runners
API (this repository's and the org's glaeda-minis group, GitHub.runners())
gives the online runners carrying each label, its capacity, and the
idle ones among them; every other online runner counts as busy
(live_pools()); a label with no idle runner is charged the
snapshot's queue and one job per run since it, since the API shows no queue.
Read live, in-flight runs' peaks (`committed`, the markers' peaks beyond the
live window) are not charged at all: those are the fallback without the
runners API. With the runners read, attempt 1 does not need the snapshot
either: when it cannot be downloaded or is stale, the owned pools are
decided from the runners alone and Blacksmith's queues count as unknown
(empty): a run that no owned pool takes keeps every job's default, as
before. Read live, the queue bound counts the peaks of the runs of the last
DEFAULT_JOB_MINUTES that took the pool (their shards are on the way).
A job on an owned pool may therefore wait up to about CI_PR_POOL_QUEUE_ROUNDS
job lengths, and ci-owned-pool-rescue.yml gives a CI run's jobs that much
(QUEUE_ROUND_SECONDS per round) on top of its budget before it moves the
run to Blacksmith (owned_pool_rescue.py). Without the runners API an
offline machine still counts toward capacity; what that gets wrong,
ci-owned-pool-rescue.yml catches: a run whose
job waits on an owned pool past its budget is re-run on Blacksmith. A re-run
of failed jobs reuses this run's outputs, so a persistent choice also names
`retry_runner`, the Blacksmith pool every macOS job takes from attempt 2 on. The owned order is `std` (48 GB minis),
then `light` (16 GB), then the Blacksmith pools: one order for every job type.

Per-job placement (`vars.CI_PR_POOL_OWNED_SPLIT == '1'`): without it, a run
takes an owned pool only when its whole peak fits, so a full suite on 9
idle minis with 2 busy went to Blacksmith entirely and queued there. With it,
when no owned pool fits the whole run, the run takes the owned pool with the
most room (at least one job), and `owned_jobs` names the jobs that fit,
in priority order (priority()): compile admission first (the heavy compile,
and a mini keeps its warm DerivedData), then the GUI jobs (app-host shards by
index, tests-build-and-lag), which queue longest on Blacksmith, then the light
jobs (cli-product-tests, the remote daemon and Claude wrapper lanes, and
swift-package-tests when it builds no Release helper; see run_plan()).
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
With the split off, a run takes an owned pool only when all its
owned-eligible jobs fit.

Root jobs: compile admission, the app-host shards, tests-build-and-lag and
cli-product-tests (and any job glaeda does not know) each hold one of a
mini's canonical roots. A class has `canonicalRoots` of them per mini (two on
a std mini, root-1 and root-2), and a compile takes any free root. The first
`canonicalRoots` runners of each mini are its root runners and carry
`glaeda-root-<class>-xcode-<version>` (root_label()); the others are its side
runners. GitHub hands a pool-label job to any free runner, so a root job on
the pool label could land on a mini whose roots were all taken and cost a
rescue re-run; on the root label it waits for a free root runner instead.
Two compiles can still share one mini's roots (see "Spread-first admission"
below). CI_OWNED_POOL_SLOTS gives the root runners' count beside the pool's
(`{"std": 40, "root-std": 20}`). A pool with
a root count sends its placed root jobs (ROOT_JOBS) to the `root_runner`
output, and place() puts no more of them there than its root runners have
room for, by the same expected wait; a
pool without one keeps the pool label for every job. A root job also holds
one of the pool's machines, so it counts against both.

Side lanes (the Claude wrapper, remote daemon and package lanes, light jobs
that never touch a canonical root) take the pool's side label,
`glaeda-side-<class>-xcode-<version>` (side_label()), the other runners of
each mini, whenever the pool has a root count and more machines than root
runners (the `side_runner` output). On the pool label a side lane landed on a
root runner about half the time (11 of 21 on 2026-09-25, 06:30 to 09:00Z,
3,300 s of root-runner time) and kept a compile or product consumer off that
mini's root while it ran; on cmux7s and cmux9s, with one root, it blocked the
mini's only compile. A pool without a root count keeps the pool label.

Warm affinity: an owned Mac keeps compile admission's DerivedData
(owned_build_state.py), and the queue janitor's snapshot carries `warm`: for
each root runner, the main commits its kept build starts from cheaply
(owned_warm_state.py, from the `owned-warm-keys` artifact admission uploads).
When `vars.CI_OWNED_WARM == '1'`, admission is placed on a pool with a root
count and the runners were read live, the picker routes by cost
(warm_distance.picker_route()): each online runner of that root label that
carries its own static label, `glaeda-runner-<runner name>`
(glaeda-cmux-runner gives every root runner one at install), costs its
expected wait (0 when idle, else what its current job has left, from the
snapshot's `running`) plus the compile predicted for its start: a kept build
of this run's merge base (MERGED_ONTO, the merge commit's first parent), of
this pull request (`pr-<PR_NUMBER>`, a re-push), or neither, by the pull
request's own distance tier (scripts/ci/warm-distance-model.json). The root
label costs the cold compile, plus a wait when Choice.root_budget leaves no
root runner free. When a warm runner is cheapest by ROUTE_MARGIN_SECONDS it
writes `admission_runner`, the JSON array `["<root label>",
"glaeda-runner-<name>"]`, which admission's attempt 1 takes as its runs-on;
a busy one only within the wait CI_PR_POOL_QUEUE_ROUNDS lets the rescue
allow. Otherwise it is empty and admission takes the root label. Nothing
writes a runner label at job time, so the routing App needs only
"Self-hosted runners: Read-only". A warm runner taken between the pick and
the queue leaves admission waiting on its label, and
ci-owned-pool-rescue.yml moves it to Blacksmith.

Spread-first admission (`vars.CI_OWNED_SPREAD == '1'`, off by default): a
std mini has two root runners and a compile takes either free root, so two
compiles (8 to 10 of the mini's 14 cores each) can share a mini while another
mini's root runners sit idle. This picker only names the warm runners, by
tier (`admission_warm`, warm_tiers(): the merge base's, then the pull
request's); ci-macos.yml's admission-placement job, which admission waits
for, re-reads the runners just before admission queues and pins it to an
idle root runner on a mini none of whose root runners is busy
(spread_admission_runner(), admission_placement.py), preferring a warm mini.
With no such mini it takes an idle warm runner, then the root label. Picking
there instead of here keeps other runs' late placement from taking the pinned
runner between the pick and the queue.

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
started it (GITHUB_TRIGGERING_ACTOR). That attempt is the full re-run the
rescue starts for a job stuck queued on `std`, which picks again; the rescue
watches it, and a job stuck or refused there goes to Blacksmith on attempt
3. The order is std, then light, then Blacksmith. The `persistent` output
tells ci.yml to publish the marker the rescue watcher looks for.

Main's full suite: ci-main-full-suite.yml dispatches ci.yml on main about
32 times a day, each a full suite (compile admission, 7 app-host shards,
tests-build-and-lag, cli-product-tests). That is main's own code, so it may
take an owned pool like a same-repository pull request, and ci-macos.yml
already routes a `workflow_dispatch` on `refs/heads/main` through the same
inputs. It is placed like a pull request, split and queue rounds
(CI_PR_POOL_QUEUE_ROUNDS) included, on the owned pools only; what does not
fit keeps its own route (MACOS_RUNNER_PR), since only an owned pool is a
candidate for it. With no Blacksmith pool to compare against, its jobs may
wait up to the queue rounds and the bound (owned_room()). CI_OWNED_MAIN_RESERVE (0 when unset) holds that many
machines and root runners back for pull requests; with a reserve it takes
an owned pool only whole, and only while its peak is free now (no queue
allowance). Its side lanes (the Claude wrapper and
remote daemon) route only for pull requests, so they are not in its plan.
Main's CI concurrency group holds one run at a time, so main holds at most
one run's machines. ci-owned-pool-rescue.yml watches it like a pull request.

Anything uncertain keeps today's route: an event other than pull_request or
main's dispatch, a
lane (MACOS_RUNNER_PR) naming another pool or unset (the documented way back
to the macOS 15 lane), an API error, a missing, stale or malformed snapshot,
or an invalid setting. The script then prints an empty runner, and every
job's own expression resolves exactly as before.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import hashlib
import io
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections.abc import Callable, Collection, Mapping, Sequence
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
# `glaeda-root-...` are each mini's root runners, the `canonicalRoots` runners
# (two on a std mini) that may take a root job (ROOT_JOBS).
# `glaeda-side-...` are its side runners, the other runners: the light side-lane workflows take it
# (vars.CI_SIDE_LANE_RUNNER, owned_pool_rescue.SIDE_WORKFLOW_PATHS), and so do
# this picker's side lanes (side_runner()). Its jobs hold its pool's machines.
OWNED_LABEL = re.compile(r"glaeda-(?:root-|side-)?(?:xl|std|light)-xcode-[0-9]+(?:\.[0-9]+)*")
ROOT_PREFIX = "glaeda-root-"
SIDE_PREFIX = "glaeda-side-"
# Capability labels glaeda puts on some runners of an owned pool, requested
# beside the pool label, never alone. `glaeda-ios-sim`: a mini with an iOS
# simulator role and an iOS 26.x runtime (ios_runner_pool.py). They are not
# pools: slots() leaves them out, and capability_slots() reads their count
# (machines, one simulator job each) from CI_OWNED_POOL_SLOTS.
CAPABILITY_LABELS = ("glaeda-ios-sim",)
# A warm key (owned_warm_state.py): a main commit's first 12 hex digits, or
# `pr-<number>` for a kept build of that pull request.
WARM_KEY = re.compile(r"[0-9a-f]{12}|pr-[1-9][0-9]{0,8}")
# `glaeda-runner-<runner name>`: the static label naming one root runner
# (glaeda-cmux-runner runner_label()), which warm affinity puts in runs-on.
RUNNER_LABEL_PREFIX = "glaeda-runner-"
# A glaeda runner's name: `<member>-glaeda` or `<member>-glaeda-<K>`, where
# the member is the mini it runs on (runner_member()).
GLAEDA_RUNNER_NAME = re.compile(r"(?P<member>.+)-glaeda(?:-[0-9]+)?")
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
# Attempt 2 of a re-run of failed jobs keeps attempt 1's outputs, so its owned-eligible jobs go back to the
# owned pool (pr_root_runner or pr_refused_retry_runner) whoever started it: the rescue after a refusal, or a
# person or agent re-running a failed job, which the rescue then watches like its own (attempt 3 and later
# always take Blacksmith). Only the light tier, which a full re-run's picker may claim, stays the rescue's:
# a person's full re-run must not claim light (or publish its marker) behind the rescue's back.
RESCUE_ACTOR = "github-actions[bot]"
MAIN_RESERVE_VARIABLE = "CI_OWNED_MAIN_RESERVE"
# Machines and root runners main's full suite leaves free for pull requests.
# 0: main takes the minis like a pull request. Its run holds 9 root runners
# at peak, so a reserve only lets it in whole when the fleet is nearly idle.
DEFAULT_MAIN_RESERVE = 0
# The ref of main's full-suite dispatch (ci-main-full-suite.yml).
MAIN_REF = "refs/heads/main"
MAIN_BRANCH = "main"
# A pull request run holds several macOS machines at once, each job on its
# own. Beside compile admission run the Claude wrapper, remote daemon and
# package lanes; once admission passes, a full suite adds APP_HOST_SHARDS
# shards, tests-build-and-lag and cli-product-tests, a changed-suites run one
# shard, and a CLI change cli-product-tests. A run takes an owned pool when
# its own peak (run_jobs) fits there by the expected wait and the queue bound
# (owned_room()); a run whose peak is unknown needs MAX_RUN_JOBS. A run
# created since the snapshot is looked up first (pull_request_routes_since):
# its marker gives the owned pool and peak it took, and a finished `changes`
# job without one means it took none. Its peak counts toward the queue bound,
# and toward the wait only once it is older than a job (young_charge()).
# Only a run still picking is replayed and charged REPLAYED_RUN_JOBS, the
# peak of a compile-only run with the Claude wrapper and remote daemon lanes.
# swift-package-tests (SWIFT_PACKAGE_JOB) is a third side lane on a run that
# builds no Release helper (package_lane_owned()): a package change, or a full
# suite with release_build false, which then peaks at all three side lanes
# beside admission and its nine follow-on jobs. MAX_RUN_JOBS counts all three;
# the replay charge leaves out the package lane, which a compile-only run
# carries only on a package change.
APP_HOST_SHARDS = 7
SIDE_LANES = 3
MAX_RUN_JOBS = SIDE_LANES + APP_HOST_SHARDS + 2
REPLAYED_RUN_JOBS = 3
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
# An absolute queue limit beside the rounds below; the larger one counts.
DEFAULT_MAX_QUEUED = 0
# Rounds of queue a pool may hold once this run arrives, each as many jobs as
# the pool has machines (see the module docstring). 0 rolls a full pool over
# at once, and takes an owned pool only when the run's peak is free.
QUEUE_ROUNDS_VARIABLE = "CI_PR_POOL_QUEUE_ROUNDS"
DEFAULT_QUEUE_ROUNDS = 1
# More is clamped to this: each round adds 900 s to the rescue's budget
# (owned_pool_rescue.QUEUE_ROUND_SECONDS), which must stay well inside its
# 60-minute watch so a stuck job is still moved.
MAX_QUEUE_ROUNDS = 3
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
# The org runner group holding the glaeda minis (glaeda#1222 moved them there).
RUNNER_GROUP = "glaeda-minis"


@dataclasses.dataclass(frozen=True)
class Settings:
    order: tuple[str, ...] = DEFAULT_ORDER
    max_queued: int = DEFAULT_MAX_QUEUED
    # Owned labels the order named for another Xcode than the lane's pin.
    stale: tuple[str, ...] = ()
    # CI_PR_POOL_QUEUE_ROUNDS; 0 for a caller that does not pass it (E2E, iOS).
    queue_rounds: int = 0


def persistent(label: str) -> bool:
    """An owned pool: its machines outlive the job, so a queued job there can wait for good."""
    return bool(OWNED_LABEL.fullmatch(label or ""))


def root_label(label: str) -> str:
    """The root runners' label for an owned pool label, or "" for any other label."""
    if not persistent(label) or label.startswith((ROOT_PREFIX, SIDE_PREFIX)):
        return ""
    return ROOT_PREFIX + label.removeprefix("glaeda-")


def side_label(label: str) -> str:
    """The side runners' label for an owned pool label, or "" for any other label."""
    if not persistent(label) or label.startswith((ROOT_PREFIX, SIDE_PREFIX)):
        return ""
    return SIDE_PREFIX + label.removeprefix("glaeda-")


def side_runner(choice: "Choice", owned_slots: Mapping[str, int]) -> str:
    """The label a pick's side lanes take: the pool's side label, or "" to keep the pool label.

    Only on a pool with a root count (the root and side runners are split),
    and only while CI_OWNED_POOL_SLOTS leaves it machines beyond its root
    runners, so a side lane never waits on a label no runner carries.
    """
    if not choice.root_runner or not persistent(choice.runner):
        return ""
    if owned_slots.get(choice.runner, 0) <= owned_slots.get(choice.root_runner, 0):
        return ""
    return side_label(choice.runner)


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
    their peak, read from each run's marker. `owned_now` is what they hold
    now (young_charge()): a run younger than a job length has only
    admission and its side lanes, at most REPLAYED_RUN_JOBS, and an older
    one its shards too, so its whole peak. `ephemeral` counts runs whose
    pick already finished without a marker, so they hold no owned machine.
    `unknown` counts runs whose pick this one cannot see yet; they are
    replayed and charged REPLAYED_RUN_JOBS on an owned pool they could take.
    `owned_runs` counts the runs behind `owned` on each pool. `live_now` and
    `live_runs` are `owned_now` and `owned_runs` for the runs younger than
    LIVE_WINDOW_MINUTES alone (None: not split by age).
    """
    unknown: int = 0
    owned: Mapping[str, int] = dataclasses.field(default_factory=dict)
    ephemeral: int = 0
    owned_now: Mapping[str, int] | None = dataclasses.field(default=None, compare=False)  # None: `owned`
    # None: one run per pool with a peak in `owned`.
    owned_runs: Mapping[str, int] | None = dataclasses.field(default=None, compare=False)
    live_now: Mapping[str, int] | None = dataclasses.field(default=None, compare=False)
    live_runs: Mapping[str, int] | None = dataclasses.field(default=None, compare=False)
    # `unknown` for the runs younger than LIVE_WINDOW_MINUTES alone (None: not split).
    live_unknown: int | None = dataclasses.field(default=None, compare=False)

    def runs(self) -> Mapping[str, int]:
        if self.owned_runs is not None:
            return self.owned_runs
        return {label: 1 for label, peak in self.owned.items() if peak}


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
                   ("claude-wrapper", "remote-daemon", "swift-package"))


def run_plan(*, macos: str | None, full_suite: str | None, unit_suite: str | None,
             unit_in_admission: str | None, claude_wrapper: str | None, cli: str | None,
             remote_daemon: str | None, unit_selectors: str | None = None,
             swift_packages: str | None = None, release_build: str | None = None) -> RunJobs:
    """This run's macOS jobs, from the changes job's routing.

    Counted high on purpose: compile admission is assumed to run (the reuse
    checks come later), and a changed-suites canary that may yet be dropped
    counts its shard. ci-macos.yml runs admission for a macOS or a CLI change,
    and cli-product-tests after it for a CLI change or a full suite. A unit
    suite with no selectors (the unit-ci label) runs all seven shards; with
    selectors, the one changed-suites worker. `unit_selectors` None (a caller
    that does not know) counts one shard, as before. swift-package-tests is a
    side lane only when package_lane_owned() says it may take the pool;
    `swift_packages` None (a caller that does not pass it) leaves it out.
    """
    full = flag(macos) and flag(full_suite)
    side = tuple(key for key, on in (("claude-wrapper", flag(claude_wrapper) or full),
                                     ("remote-daemon", flag(remote_daemon)),
                                     (SWIFT_PACKAGE_JOB, package_lane_owned(
                                         full=full, full_suite=full_suite, swift_packages=swift_packages,
                                         release_build=release_build))) if on)
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


# swift-package-tests (ci-macos.yml): `swift test` per selected package into
# the workspace's .build, which glaeda's hook classes as light (no canonical
# root, no GUI). It runs for a full suite or a change the router attributed to
# a Swift package. With a full suite that also checks the Release build it
# first builds the Ghostty CLI helper against an SDK 15 Xcode, which only the
# Blacksmith macOS 15 image carries (the minis have Xcode 26.6 alone), so only
# a run without that helper build places it on an owned pool.
SWIFT_PACKAGE_JOB = "swift-package"


def package_lane_owned(*, full: bool, full_suite: str | None, swift_packages: str | None,
                       release_build: str | None) -> bool:
    """swift-package-tests runs in this run and needs no SDK 15 Xcode, so an owned Mac can take it.

    `release_build` None (a caller that does not pass it) counts as a helper
    build under a full suite: the safe side.
    """
    runs = full or flag(swift_packages)
    helper = flag(full_suite) and (release_build is None or flag(release_build))
    return runs and not helper


def run_jobs(**routing: str | None) -> int:
    """Most macOS machines this run holds at once, from the changes job's routing (run_plan)."""
    return run_plan(**routing).peak


# Owned placement priority: the heavy compile, then GUI jobs (the longest
# Blacksmith queues), then light jobs. GUI jobs need the mini's console
# session; CI_PR_POOL_OWNED_GUI=0 keeps them off.
LIGHT_JOBS = ("cli-product", "remote-daemon", "claude-wrapper", SWIFT_PACKAGE_JOB)
# glaeda's canonical-root jobs: admission and every job after it (RunJobs.after:
# the shards, tests-build-and-lag, cli-product-tests). The side lanes are not.
ROOT_JOBS = "admission, shards, lag, cli-product"
# The side lanes (RunJobs.side): light, no canonical root; they take side_runner() on a pool with a root count.
SIDE_LANE_JOBS = ("claude-wrapper", "remote-daemon", SWIFT_PACKAGE_JOB)


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
             owned: str | None = None, pr_xcode_app: str | None = None,
             queue_rounds: str | None = None) -> Settings | None:
    """Settings from repository variables; None when turned off or invalid.

    `queue_rounds` is CI_PR_POOL_QUEUE_ROUNDS as the workflow passes it ("" when
    unset, which means DEFAULT_QUEUE_ROUNDS). None, from a caller that never
    reads it (the E2E and iOS pickers), means no rounds.

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
    allowed = parse_queue_rounds(queue_rounds) if queue_rounds is not None else 0
    if allowed is None:
        return None
    return Settings(labels, limit, stale, allowed)


def parse_queue_rounds(value: str | None) -> int | None:
    """CI_PR_POOL_QUEUE_ROUNDS: whole rounds, 0 to MAX_QUEUE_ROUNDS (more is clamped); "" is the default.

    None when invalid (not a whole number, or negative).
    """
    raw = (value or "").strip()
    if not raw:
        return DEFAULT_QUEUE_ROUNDS
    try:
        rounds = int(raw)
    except ValueError:
        return None
    return min(rounds, MAX_QUEUE_ROUNDS) if rounds >= 0 else None


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
            # Side runners are a pool's machines less its root runners (side_runner()), so a count is a mistake.
            problems.append(f"{SLOTS_VARIABLE} entry {label!r} names side runners, which are counted "
                            "as the pool's machines less its root runners")
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
    if "future" in entry:
        counts["future"] = int(entry.get("future") or 0)
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


# Typical minutes of one job on a pool: what one round of its queue costs.
# Compile admission, the longest job, took a median 638 s on the minis and
# about 10 minutes on the 6vcpu pools (2026-09-25); a 12vcpu job runs about
# twice as fast.
JOB_MINUTES = {LARGE_RUNNER: 5}
DEFAULT_JOB_MINUTES = 10


def job_minutes(label: str) -> int:
    return JOB_MINUTES.get(pool_label(label), DEFAULT_JOB_MINUTES)


def expected_wait(label: str, counts: Mapping[str, int], arriving: int) -> float:
    """Minutes the last of `arriving` more jobs waits on a pool: its queue in rounds, times a job's length.

    A cold pool (cold()) counts COLD_ROUNDS more, for the compile it runs cold.
    """
    return rounds(counts, effective_queue(counts, arriving)) * job_minutes(label)


def young_charge(peak: int, age_minutes: float | None) -> int:
    """What a run holds now: admission and its side lanes while younger than a job, then its whole peak."""
    if age_minutes is not None and age_minutes < DEFAULT_JOB_MINUTES:
        return min(peak, REPLAYED_RUN_JOBS)
    return peak


def run_age_minutes(run: Mapping[str, Any], now: dt.datetime) -> float | None:
    created = parse_time(str(run.get("created_at") or ""))
    return None if created is None else (now - created).total_seconds() / 60


def owned_free(counts: Mapping[str, int], added_runs: int, taken_since: int = 0) -> int:
    """Machines of an owned pool still free once `added_runs` more runs took theirs.

    Taken is the larger of the jobs the janitor saw and what the runs holding
    the pool will need at their peak, so a run whose later jobs do not exist
    yet still counts them. `taken_since` is the known peak of the runs that
    took the pool since the snapshot, from their markers. Each run replayed
    since the snapshot is charged REPLAYED_RUN_JOBS, since its own peak is
    unknown here. The kill switch (rounds 0) uses exactly this.
    """
    taken = max(counts["running"] + counts["queued"], counts.get("committed", 0))
    return counts.get("capacity", 0) - taken - taken_since - added_runs * REPLAYED_RUN_JOBS


def owned_room(label: str, counts: Mapping[str, int], added_jobs: int, taken_peak: int, taken_now: int,
               queue_rounds: int, limit_minutes: float) -> int:
    """How many more jobs an owned label takes for this run.

    Rounds 0 (the kill switch): its machines free now, counting every run's
    peak (owned_free()), as before. Otherwise the smaller of:

    - wait: the jobs that start within `limit_minutes`, from what holds the
      label now: jobs running and queued, `taken_now` for the runs since the
      snapshot (young_charge()) and `added_jobs` for those replayed. Past
      the free machines, a job at queue place q waits about q / machines
      rounds, so limit x machines / job_minutes() places are allowed. A run's
      shards that do not exist yet hold no machine, so a later run may take
      the idle ones and the shards queue behind it.
    - bound: machines x (1 + rounds) less everything the runs holding it will
      need at their peak (the janitor's `committed`, or `future` read live,
      and `taken_peak` since the snapshot). So the queue those shards join
      never grows past `queue_rounds` rounds, however many runs arrive.
    """
    capacity = counts.get("capacity", 0)
    busy = counts["running"] + counts["queued"]
    if not queue_rounds:
        return capacity - max(busy, counts.get("committed", 0)) - taken_peak - added_jobs
    places = int(max(0.0, limit_minutes) * capacity / job_minutes(label) + 1e-9)
    wait = capacity + places - busy - taken_now - added_jobs
    committed = counts.get("future", counts.get("committed", 0))
    bound = capacity * (1 + queue_rounds) - max(busy, committed) - taken_peak - added_jobs
    return min(wait, bound)


def snapshot_problem(snapshot: Any, now: dt.datetime) -> str:
    """Why decide() would not read `snapshot` (missing, undated, stale or without pools), or ""."""
    if not isinstance(snapshot, Mapping) or not snapshot.get("generated_at"):
        return "no readable pool snapshot"
    if not isinstance(snapshot.get("pools"), Mapping):
        return "malformed pool snapshot"
    age = snapshot_age_minutes(snapshot, now)
    if age is None or age < -5 or age > MAX_SNAPSHOT_MINUTES:
        return f"pool snapshot is stale or undated (age {age if age is None else round(age)} min)"
    return ""


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


def warm_key(commit: str | None) -> str:
    """A commit's warm key (its first 12 hex digits), a `pr-<n>` key as is, or "" for anything else."""
    key = (commit or "").strip().lower()
    key = key if key.startswith("pr-") else key[:12]
    return key if WARM_KEY.fullmatch(key) else ""


def pr_warm_key(number: str | None) -> str:
    """The warm key of pull request NUMBER, or ""."""
    return warm_key(f"pr-{(number or '').strip()}")


def runner_label(name: str) -> str:
    """The static label only runner `name` carries: glaeda-cmux-runner's runner_label()."""
    return RUNNER_LABEL_PREFIX + re.sub(r"[^a-z0-9._-]+", "-", name.lower())


def warm_tiers(merged_onto: str | None, warm: Any, pr_number: str | None = None) -> list[list[str]]:
    """The runners the snapshot's `warm` (owned_warm_state.py) calls warm for this run, best first.

    One tier per key, in warm affinity's order: those whose keys hold
    `merged_onto`'s key, then those holding this pull request's `pr-<n>` (a
    re-push starts from the previous push's build). A runner is listed once,
    in its best tier; empty tiers are dropped.
    """
    kept = warm.get("runners") if isinstance(warm, Mapping) else None
    if not isinstance(kept, Mapping):
        return []
    tiers: list[list[str]] = []
    seen: set[str] = set()
    for key in (warm_key(merged_onto), pr_warm_key(pr_number)):
        if not key:
            continue
        tier = sorted(str(name) for name, entry in kept.items()
                      if isinstance(entry, Mapping) and key in (entry.get("keys") or []) and str(name) not in seen)
        seen.update(tier)
        if tier:
            tiers.append(tier)
    return tiers


def runner_labels(runner: Mapping[str, Any]) -> set[str]:
    return {str(item.get("name")) for item in runner.get("labels") or [] if isinstance(item, Mapping)}


def pinned_admission(root: str, name: str) -> str:
    """Admission's runs-on labels as JSON: `root` and the static label only runner `name` carries."""
    return json.dumps([root, runner_label(name)], separators=(",", ":"))


def idle_warm_runner(runners: Sequence[Mapping[str, Any]], root: str, tiers: Sequence[Collection[str]]) -> str:
    """The first online, idle `root` runner of the best tier (warm_tiers()) with its own runner_label(), or ""."""
    if not root.startswith(ROOT_PREFIX):
        return ""
    for tier in tiers:
        for runner in runners:
            if runner.get("status") != "online" or runner.get("busy"):
                continue
            name = str(runner.get("name") or "")
            names = runner_labels(runner)
            if name and name in tier and root in names and runner_label(name) in names:
                return name
    return ""


def warm_admission_runner(runners: Sequence[Mapping[str, Any]], root: str, merged_onto: str | None,
                          warm: Any, pr_number: str | None = None) -> str:
    """Admission's runs-on labels as JSON when an idle `root` runner is warm for this run, else "".

    Warm for this run: its keys hold `merged_onto`'s key, or else this pull
    request's `pr-<n>` key (a re-push starts from the previous push's build).
    `warm` is the snapshot's `warm` (owned_warm_state.py). The runner must
    carry its own runner_label(), or a job naming it would wait forever.
    """
    name = idle_warm_runner(runners, root, warm_tiers(merged_onto, warm, pr_number))
    return pinned_admission(root, name) if name else ""


def runner_member(name: str) -> str:
    """The mini a glaeda runner runs on: its name less `-glaeda` or `-glaeda-<K>`, or "" for another name."""
    match = GLAEDA_RUNNER_NAME.fullmatch(name or "")
    return match.group("member") if match else ""


def spread_admission_runner(runners: Sequence[Mapping[str, Any]], root: str,
                            tiers: Sequence[Collection[str]] = (), *, seed: str = "") -> tuple[str, bool]:
    """Admission's runs-on labels as JSON for an idle `root` runner on a mini running no `root` job.

    A std mini has two root runners, and a compile takes either free root, so
    two compiles (8 to 10 of the mini's 14 cores each) can share a mini while
    another mini's root runners sit idle. This picks an empty mini, one none
    of whose online `root` runners is busy, then an idle root runner on it
    that carries its own runner_label().

    Warmth is the mini's: a runner's warm keys cover every root of its mini
    (owned_build_state.py warm-keys), and glaeda's job-started hook gives an
    admission the free root whose stamp is warm for it, whichever root runner
    took the job. So an empty mini with any root runner in the best tier of
    `tiers` (warm_tiers()) comes first, then the next tier's, then any; that
    runner itself when it is idle, else another idle root runner there.
    Among the candidate minis `seed` (the run ID) picks, so runs picking at
    once land on different minis and a mini with more root runners is not
    favored. Returns the labels ("" when no mini is empty) and whether the
    mini is warm.
    """
    if not root.startswith(ROOT_PREFIX):
        return "", False
    busy: set[str] = set()
    idle: dict[str, list[str]] = {}
    listed: dict[str, set[str]] = {}
    for runner in runners:
        name = str(runner.get("name") or "")
        member = runner_member(name)
        names = runner_labels(runner)
        if not member or root not in names:
            continue
        listed.setdefault(member, set()).add(name)
        if runner.get("status") != "online":
            continue
        if runner.get("busy"):
            busy.add(member)
        elif runner_label(name) in names:
            idle.setdefault(member, []).append(name)
    empty = {member: sorted(names) for member, names in idle.items() if member not in busy}
    if not empty:
        return "", False
    tier: Collection[str] = ()
    members: list[str] = []
    for tier in tiers:
        members = sorted(member for member in empty if listed[member] & set(tier))
        if members:
            break
    warm = bool(members)
    members = members or sorted(empty)
    member = members[int(hashlib.sha256(seed.encode()).hexdigest(), 16) % len(members) if seed else 0]
    name = next((name for name in empty[member] if warm and name in tier), empty[member][0])
    return pinned_admission(root, name), warm


def live_online(runners: Sequence[Mapping[str, Any]], labels: Sequence[str]) -> dict[str, int]:
    """Runners online and carrying each owned label, busy or idle: its live capacity."""
    online = {label: 0 for label in labels}
    for runner in runners:
        if runner.get("status") != "online":
            continue
        names = runner_labels(runner)
        for label in labels:
            if label in names:
                online[label] += 1
    return online


def live_pools(snapshot: Mapping[str, Any], idle: Mapping[str, int], slot_counts: Mapping[str, int],
               older: Mapping[str, int], online: Mapping[str, int] | None = None,
               ) -> tuple[Mapping[str, Any], dict[str, int]]:
    """The snapshot with each owned label's counts read live, and the owned capacities.

    A label's capacity is its online runners (`online`, live_online()): the
    hand-set CI_OWNED_POOL_SLOTS drifts from what is registered, and an
    offline runner takes no job. Without `online` it is the variable's count,
    or the idle runners when those are more (a label without a count), and
    an offline machine counts as running. What is not idle is running. The
    runners API shows no queue:
    a label with an idle runner has none, and one without counts the
    snapshot's queue plus `older`: the jobs of the runs that took the pool
    since the snapshot and before the live window that may still wait there
    (pull request CI passes one per run, its admission).

    The snapshot's `committed` (every in-flight run's peak) is not charged:
    charging it kept runs off idle minis ("0 of 19 root runners free" and
    "every pool is full" while 12.7k unit-min of owned time sat idle beside
    Blacksmith work on 2026-09-25). It remains the fallback when the runners
    cannot be read. `future` is 0, so the queue bound (owned_room()) counts
    what holds the label now plus what choose() passes: the peaks of runs
    younger than DEFAULT_JOB_MINUTES, less what they already hold.

    A root label counts only while CI_OWNED_POOL_SLOTS gives it a root count,
    which is what turns root routing on (root_label()).
    """
    pools = dict(snapshot.get("pools") or {})
    capacity: dict[str, int] = {}
    for label, count in idle.items():
        if label.startswith(ROOT_PREFIX) and label not in slot_counts:
            continue
        free = max(0, int(count))
        if online is not None and label in online:
            capacity[label] = max(int(online[label]), free)
        else:
            capacity[label] = max(int(slot_counts.get(label) or 0), free)
        seen = (pools.get(label) or {}) if isinstance(pools.get(label), Mapping) else {}
        queued = 0 if free else int(seen.get("queued") or 0) + max(0, int(older.get(pool_label(label), 0)))
        pools[label] = {"queued": queued, "running": capacity[label] - free, "committed": 0, "future": 0}
    return {**snapshot, "pools": pools}, capacity


@dataclasses.dataclass(frozen=True)
class Pick:
    label: str
    # "owned": an owned pool holds this run's jobs within `limit` minutes;
    # "free": a Blacksmith pool with headroom (queueing off); "wait": the
    # Blacksmith pool with the least expected wait; "fallback": every pool full.
    how: str
    room: int = 0  # owned only: this run's jobs it starts within `limit`
    root_room: int | None = None  # owned with a root count only
    limit: float = 0.0  # owned only: the wait allowed there, in minutes
    blacksmith_wait: float | None = None  # the least expected wait on Blacksmith, when queueing


def pick(load: Mapping[str, Mapping[str, int]], added: Mapping[str, int], usable: Sequence[str],
         max_queued: int, jobs: int = MAX_RUN_JOBS, split: bool = False,
         roots: Mapping[str, Mapping[str, int]] | None = None, root_jobs: int = 0,
         queue_rounds: int = 0, taken: Mapping[str, int] | None = None,
         taken_now: Mapping[str, int] | None = None, reserve: int = 0,
         compared_jobs: int | None = None) -> Pick:
    """The rule itself. `added` counts runs replayed since the snapshot on each pool.

    With `queue_rounds` (CI_PR_POOL_QUEUE_ROUNDS) above 0: an owned pool, in
    order, when the jobs it would place there start within `queue_rounds`
    job lengths and within the queue bound (owned_room()), whatever
    Blacksmith's expected wait (Blacksmith is overflow); else the Blacksmith
    pool with the least expected wait (expected_wait()), the earlier in
    order on a tie. `taken` is the
    peak of the runs since the snapshot that took each owned pool, by their
    markers, and `taken_now` what they hold now (young_charge()). A
    replayed run counts REPLAYED_RUN_JOBS on an owned pool and one on its
    root runners and on Blacksmith. `reserve` (main's full suite with
    CI_OWNED_MAIN_RESERVE) is kept free on top of this run's jobs and root
    jobs, and turns `split` off. `compared_jobs` (default `jobs`) is how
    many jobs Blacksmith's wait (reported, not compared) is read at: a
    replayed run takes the pool with one job but has REPLAYED_RUN_JOBS at once.

    With 0, the old rule: an owned pool only with machines free now, the
    first Blacksmith pool with a free machine (or at most max_queued
    queued), else the shortest queue in rounds.

    An owned pool fits while it holds all `jobs` (and, with a root count,
    `root_jobs` on its root runners). With `split`, when none does, the owned
    pool with the most room holds what fits (place()). An owned pool is never
    the fallback.
    """
    roots, taken, taken_now = roots or {}, taken or {}, taken_now if taken_now is not None else taken or {}
    blacksmith = [label for label in usable if not persistent(label)]
    # Which Blacksmith pool: by its wait for this run's admission, since the
    # shards may take another pool on the lane's Xcode (spread_shards()).
    waits = {label: expected_wait(label, load[label], added[label] + 1) for label in blacksmith}
    best = min(blacksmith, key=lambda label: (waits[label], blacksmith.index(label))) if blacksmith else ""
    # Owned or Blacksmith: the wait of this run's last job on each side, so an
    # owned pool is measured against Blacksmith holding the same jobs.
    compared = max(1, jobs if compared_jobs is None else compared_jobs)
    whole = min((expected_wait(label, load[label], added[label] + compared) for label in blacksmith),
                default=float("inf"))
    rooms: dict[str, Pick] = {}
    for label in usable:
        if not persistent(label):
            continue
        # Fleet first: an owned pool may queue its full allowance whatever
        # Blacksmith's wait looks like. That wait comes from a snapshot up to
        # MAX_SNAPSHOT_MINUTES old and is 0 whenever a Blacksmith pool showed
        # a free machine, which sent runs off minis busy for a few minutes
        # (2026-09-25: 2.5k Blacksmith job-min on "0 of 19 root runners free").
        limit = float(queue_rounds * job_minutes(label))
        peak, now = taken.get(label, 0), taken_now.get(label, 0)
        room = owned_room(label, load[label], added[label] * REPLAYED_RUN_JOBS, peak, now, queue_rounds, limit)
        root_room = (owned_room(label, roots[label], added[label], peak, now, queue_rounds, limit)
                     if label in roots else None)
        rooms[label] = Pick(label, "owned", room, root_room, limit, whole if best and queue_rounds else None)
    reserve = max(0, reserve)
    fits = [label for label, room in rooms.items() if room.room >= max(1, jobs) + reserve
            and (room.root_room is None or room.root_room >= root_jobs + reserve)]
    if split and not reserve and not fits and rooms and max(room.room for room in rooms.values()) >= 1:
        fits = [max(rooms, key=lambda label: rooms[label].room)]
    for label in usable:
        if label in fits:
            return rooms[label]
        if not queue_rounds and not persistent(label) and \
                effective_queue(load[label], added[label] + 1) <= max_queued:
            return Pick(label, "free")
    if queue_rounds and best:
        return Pick(best, "wait", blacksmith_wait=waits[best])
    fallback = blacksmith or list(usable)
    queued = {label: effective_queue(load[label], added[label] + 1) for label in fallback}
    return Pick(min(fallback, key=lambda label: rounds(load[label], queued[label])), "fallback")


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
    reserve: int = 0,
    owned_now: Mapping[str, int] | None = None,
) -> Choice:
    """The preference rule over a janitor snapshot. Uncertainty keeps today's route.

    `routed_since` runs were created after the snapshot and each already took
    a pool by this rule; they are replayed first. `placed` counts runs created
    since the snapshot whose pool is already known (an E2E run naming a
    Blacksmith pool; e2e_runner_pool passes owned ones as `owned_since`), one
    job each. `auto_xcode` (a fork run, which has no pins) lets every pool
    fall back to each job selecting its pool's newest SDK 26 Xcode.
    `choose_from` limits the final pick to some pools of the order (E2E stays
    on macOS 26) while the replay still spreads over the whole order. `jobs`
    is this run's peak machine count, which an owned pool must hold.
    Replayed runs are placed as if they needed one machine (so any that could
    have taken an owned pool is assumed to) and charged REPLAYED_RUN_JOBS there.
    `owned_since` is what runs since the snapshot took on each owned pool, by
    their markers (their peaks), and `ephemeral_since` counts runs whose pick
    finished off the owned pools; those are replayed over the Blacksmith
    pools only.
    `split` lets this run take part of an owned pool (pick(), place()).
    `root_jobs` is this run's peak on root runners, which an owned pool with
    a root count must have free too. Its root runners are charged one per
    replayed run (its admission), and a newer run's whole marker peak, since
    a marker does not split it. `reserve` (main's full suite) is how many
    machines, and root runners, an owned pool must keep free beyond this run.
    `owned_now` is what the runs in `owned_since` hold now
    (Routed.owned_now); None means their peaks.
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
    # Runs since the snapshot that took an owned pool, by their markers: their
    # peak, and what they hold now (young_charge()).
    taken = {label: max(0, int((owned_since or {}).get(label) or 0)) for label in usable if persistent(label)}
    held = taken if owned_now is None else {
        label: max(0, int(owned_now.get(label) or 0)) for label in usable if persistent(label)}
    ephemeral = [label for label in usable if not persistent(label)]
    queue_rounds = limits.queue_rounds
    for _ in range(max(0, ephemeral_since) if ephemeral else 0):
        added[pick(load, added, ephemeral, limits.max_queued, jobs=1, queue_rounds=queue_rounds).label] += 1
    for _ in range(max(0, routed_since)):
        added[pick(load, added, usable, limits.max_queued, jobs=1, queue_rounds=queue_rounds,
                   taken=taken, taken_now=held, compared_jobs=REPLAYED_RUN_JOBS).label] += 1
    if reserve:
        # Main's full suite with a reserve (CI_OWNED_MAIN_RESERVE) takes an
        # owned pool only while its peak and the reserve are free now: no
        # queue, which would put it behind the pull requests the reserve
        # keeps room for. The replay above keeps the queue rounds.
        queue_rounds = 0
    chosen = pick(load, added, candidates, limits.max_queued, jobs, split=split, roots=roots,
                  root_jobs=root_jobs, queue_rounds=queue_rounds, taken=taken, taken_now=held,
                  reserve=reserve)
    label = chosen.label
    if persistent(label) and chosen.how != "owned":
        return Choice("", "", "every owned pool this run may take is busy, and no other pool is in the order")
    replayed = sum(added.values())
    replay = f" after replaying {replayed} newer run(s)" if replayed else ""
    if any(taken.values()):
        replay += " and counting " + ", ".join(f"{count} machine(s) newer runs took on {pool_label}"
                                               for pool_label, count in taken.items() if count)
    if chosen.how == "owned":

        def idle(counts: Mapping[str, int], added_jobs: int) -> int:
            """Free now: machines less running, queued and what newer runs hold (peaks with rounds 0)."""
            if not queue_rounds:
                return owned_room(label, counts, added_jobs, taken.get(label, 0), 0, 0, 0)
            return counts["capacity"] - counts["running"] - counts["queued"] - held.get(label, 0) - added_jobs

        # Clamped for the text: an oversubscribed label has 0 free, not a negative count.
        free_now = max(0, idle(load[label], added[label] * REPLAYED_RUN_JOBS))
        places = max(0, chosen.room) - free_now
        machines = f"{free_now} of {load[label]['capacity']} owned machines free"
        if places > 0:
            machines += f" and {places} queue places within {chosen.limit:g} min"
        if chosen.blacksmith_wait is not None:
            machines += f" (Blacksmith's expected wait {chosen.blacksmith_wait:g} min)"
        root = ""
        if chosen.root_room is not None:
            root_now = max(0, idle(roots[label], added[label]))
            root = f"; {root_now} of {roots[label]['capacity']} root runners free"
            if chosen.root_room > root_now:
                root += f" and {chosen.root_room - root_now} queue places"
            root += f", it needs {root_jobs}"
        whole = chosen.room >= max(1, jobs) and (chosen.root_room is None or chosen.root_room >= root_jobs)
        kept = f", and {reserve} kept free for pull requests" if reserve else ""
        if whole:
            why = f"first pool in order with headroom ({machines}, this run needs {max(1, jobs)}{root}{kept}){replay}"
        else:
            why = (f"owned pool with the most room ({machines}, this run needs {max(1, jobs)}{root}): "
                   f"the jobs that fit run there, the rest on the retry runner{replay}")
    elif chosen.how == "wait":
        why = f"least expected wait ({chosen.blacksmith_wait:g} min, from the jobs queued and running now){replay}"
        if cold(label):
            why += f", counting {COLD_ROUNDS} more round for a pool with no seed for its Xcode"
    elif chosen.how == "free":
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
        retry = pick(load, added, lane, limits.max_queued, queue_rounds=queue_rounds).label if lane else DEFAULT_RUNNER
    shard = spread_shards(load, added, usable, label, shards)
    if shard:
        note += f"; its {shards} app-host shards take {shard}, which has more room for them"
    if not persistent(label):
        return Choice(label, xcode(label) or "", why + note, retry, 0, shard)
    budget = max(0, min(chosen.room, max(1, jobs)))
    if chosen.root_room is not None:
        return Choice(label, xcode(label) or "", why + note, retry, budget, shard_runner=shard,
                      root_runner=root_label(label), root_budget=max(0, chosen.root_room))
    return Choice(label, xcode(label) or "", why + note, retry, budget, shard)


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
    live_online: Mapping[str, int] | None = None,
    shards: int = 0,
    queue_rounds: str | None = None,
    ref: str = "",
    main_reserve: str | None = None,
) -> tuple[Choice, Mapping[str, Any] | None]:
    """The pool for this run and the snapshot it was read from (None when none was read).

    Main's full-suite dispatch (`workflow_dispatch` on MAIN_REF) may take an
    owned pool only, placed like a pull request unless `main_reserve` holds
    machines back (see "Main's full suite" above); anything else keeps its route.

    `queue_rounds` is CI_PR_POOL_QUEUE_ROUNDS as settings() reads it; a fork
    run reads the janitor's copy instead.
    """
    main = event == "workflow_dispatch" and ref == MAIN_REF
    if event != "pull_request" and not main:
        return Choice("", "", f"{event or 'unknown'} event on {ref or 'an unknown ref'}; "
                              "not a pull request or main's full-suite dispatch"), None
    reserve = 0
    if main:
        if (owned or "").strip() != "1":
            return Choice("", "", f"main's full-suite dispatch takes only an owned pool, and {OWNED_VARIABLE} "
                                  "is not 1"), None
        if run_attempt > 1:
            return Choice("", "", f"retry attempt {run_attempt} of main's full-suite dispatch; "
                                  "it keeps its own route"), None
        try:
            reserve = int(main_reserve) if (main_reserve or "").strip() else DEFAULT_MAIN_RESERVE
        except ValueError:
            return Choice("", "", f"{MAIN_RESERVE_VARIABLE} is not a number"), None
        if reserve < 0:
            return Choice("", "", f"{MAIN_RESERVE_VARIABLE} is negative"), None
        # Main's own code: the same repository by definition.
        head_repo = repo
    if not head_repo:
        return Choice("", "", "pull request head repository unknown"), None
    fork = head_repo != repo
    if not fork:
        if (default_runner or "").strip() != DEFAULT_RUNNER:
            return Choice("", "", f"MACOS_RUNNER_PR is {default_runner or 'unset'}, not {DEFAULT_RUNNER}"), None
        limits = settings(overflow, order, max_queued, owned, xcode_pins.get(PR_XCODE_VARIABLE), queue_rounds)
        if limits is None:
            return Choice("", "", f"{OVERFLOW_VARIABLE} is 0, or {ORDER_VARIABLE}/{MAX_QUEUED_VARIABLE}/"
                                  f"{QUEUE_ROUNDS_VARIABLE} is invalid"), None
    unreadable = ""
    try:
        snapshot = fetch()
    except Exception as error:  # noqa: BLE001 - every failure keeps the default, or the live runners decide
        snapshot, unreadable = None, f"could not read the pool snapshot ({error})"
    if fork:
        if unreadable:
            return Choice("", "", unreadable), None
        # No repository variables reach a fork run; the janitor copied them.
        copied = snapshot.get("settings") if isinstance(snapshot, Mapping) else None
        if not isinstance(copied, Mapping):
            return Choice("", "", "fork head; the snapshot carries no settings"), snapshot
        if str(copied.get("lane") or "").strip() != DEFAULT_RUNNER:
            return Choice("", "", f"fork head; the lane is {copied.get('lane') or 'unset'}, "
                                  f"not {DEFAULT_RUNNER}"), snapshot
        copied_rounds = copied.get("queue_rounds")
        limits = settings(copied.get("overflow"), copied.get("order"), copied.get("max_queued"),
                          queue_rounds="" if copied_rounds is None else str(copied_rounds))
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
        # A retry exists to get off a queue, so it does not queue (rounds 0):
        # the light tier only with its peak free now, Blacksmith rolling over
        # at a full pool, and the rescue's short budget.
        limits = dataclasses.replace(limits, queue_rounds=0, order=tuple(
            label for label in limits.order
            if not persistent(label) or light and label.startswith(f"glaeda-{LIGHT_CLASS}-")))
        if not limits.order:
            return Choice("", "", f"retry attempt {run_attempt}; no ephemeral pool in the order"), snapshot
    live = live_owned is not None and not fork
    # Attempt 1 with the owned runners read live does not need the janitor:
    # a failed download (an HTTP 503 from artifact storage) or a stale
    # snapshot leaves the owned pools to the live runners and Blacksmith's
    # queues unknown, instead of skipping the fleet (2026-09-25: 2.8k
    # Blacksmith job-min on a stale snapshot, 0.6k on a 503).
    live_only = ""
    if live and not retry:
        live_only = unreadable or snapshot_problem(snapshot, now)
        if live_only:
            # A stale snapshot's warm keys still name kept builds (warm affinity).
            warm = snapshot.get("warm") if isinstance(snapshot, Mapping) else None
            snapshot, unreadable = {"generated_at": iso(now), "pools": {}, "source": "live", "warm": warm}, ""
    if unreadable:
        return Choice("", "", unreadable), snapshot
    if not isinstance(snapshot, Mapping) or not snapshot.get("generated_at"):
        return Choice("", "", "no readable pool snapshot"), snapshot
    if live_only:
        # The live window below counts the runs that matter.
        routed = Routed()
    else:
        try:
            routed = count_routed(str(snapshot["generated_at"]))
        except Exception as error:  # noqa: BLE001 - every failure keeps the default
            return Choice("", "", f"could not count runs since the snapshot ({error})"), snapshot
    if not isinstance(routed, Routed):
        routed = Routed(unknown=int(routed))
    owned_capacity = {} if fork else slots(owned_slots, xcode_pins.get(PR_XCODE_VARIABLE))
    if live:
        # The idle runners replace the slot counts and the snapshot's owned
        # counts. Runs of the last DEFAULT_JOB_MINUTES that took an owned pool
        # count their peaks toward the queue bound (owned_room()): their
        # shards are on the way, and nothing else here sees them coming. Only
        # those of the last LIVE_WINDOW_MINUTES hold machines toward the wait;
        # older ones' jobs show on the runners. The rest of the snapshot
        # window counts on Blacksmith.
        try:
            recent = count_routed(iso(now - dt.timedelta(minutes=DEFAULT_JOB_MINUTES)))
        except Exception as error:  # noqa: BLE001 - every failure keeps the default
            return Choice("", "", f"could not count recent runs ({error})"), snapshot
        if not isinstance(recent, Routed):
            recent = Routed(unknown=int(recent))
        before = routed
        # Replayed: only the unknown runs of the live window; older ones'
        # jobs are on the runners already.
        unknown = recent.unknown if recent.live_unknown is None else recent.live_unknown
        held_now = recent.owned_now if recent.live_now is None else recent.live_now
        # The bound: each run's peak less what the runs past the live window
        # already hold, which the runners count busy.
        on_runners = {label: max(0, (recent.owned_now or recent.owned).get(label, 0) - held_now.get(label, 0))
                      for label in recent.owned} if recent.live_now is not None else {}
        routed = Routed(unknown=unknown,
                        owned={label: max(0, peak - on_runners.get(label, 0)) for label, peak in recent.owned.items()},
                        owned_now=held_now,
                        owned_runs=recent.runs() if recent.live_runs is None else recent.live_runs,
                        ephemeral=routed.ephemeral + max(0, routed.unknown - unknown))
        recent = routed
        # Runs since the snapshot but before the live window: their owned jobs
        # are running (so busy below) or still queued, which the runners API
        # cannot show. One job each (admission) may still wait where no
        # runner is idle; their later jobs are not charged (live_pools()).
        older = {label: max(0, count - recent.runs().get(label, 0)) for label, count in before.runs().items()}
        snapshot, owned_capacity = live_pools(snapshot, live_owned or {}, owned_capacity, older, live_online)
    choice = decide(snapshot, limits, now=now, xcode_pins={} if fork else xcode_pins,
                    routed_since=routed.unknown, owned_since=routed.owned, ephemeral_since=routed.ephemeral,
                    auto_xcode=fork, owned_slots=owned_capacity, jobs=jobs,
                    split=(split or "").strip() == "1", shards=shards,
                    root_jobs=root_jobs, reserve=reserve, owned_now=routed.owned_now,
                    # Main only ever takes an owned pool; the replay still
                    # spreads newer runs over the whole order.
                    choose_from=tuple(label for label in limits.order if persistent(label)) if main else None)
    if main and not persistent(choice.runner):
        # A Blacksmith pick would move main off MACOS_RUNNER_PR; keep its route.
        choice = Choice("", "", f"main's full-suite dispatch: no owned pool fits its whole run with "
                                f"{reserve} machine(s) and root runner(s) left free for pull requests "
                                f"({choice.reason})")
    if live_only and not persistent(choice.runner):
        # Blacksmith's queues are unknown: overflow keeps every job's default
        # route, as it did before the live runners could decide.
        choice = Choice("", "", f"{live_only}; no owned pool has room ({choice.reason})")
    if live and persistent(choice.runner):
        choice = dataclasses.replace(choice, reason=f"{choice.reason}; owned machines read live from the runners API")
    if live_only and choice.runner:
        choice = dataclasses.replace(choice, reason=f"{choice.reason}; no janitor snapshot ({live_only}), so "
                                                    "Blacksmith's queues are unknown")
    if fork and choice.runner:
        choice = dataclasses.replace(choice, reason=f"fork head; {choice.reason}")
    if retry and choice.runner:
        choice = dataclasses.replace(choice, reason=f"retry attempt {run_attempt}; {choice.reason}")
    if main and choice.runner:
        choice = dataclasses.replace(choice, reason=f"main's full-suite dispatch; {choice.reason}")
    return choice, snapshot


def main_dispatch(run: Mapping[str, Any]) -> bool:
    """A CI run of main's full-suite dispatch (ci-main-full-suite.yml)."""
    return run.get("event") == "workflow_dispatch" and run.get("head_branch") == MAIN_BRANCH


def routed_run(run: Mapping[str, Any]) -> bool:
    """A CI run this picker routes: a pull request, or main's full-suite dispatch."""
    return run.get("event") == "pull_request" or main_dispatch(run)


def may_hold_owned_pool(run: Mapping[str, Any], *, light_retry: bool = False) -> bool:
    """Only attempt 1 of a same-repository pull request run (or of main's dispatch) can take an owned pool,
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
        """GET a path under this repository."""
        return self.get_api(f"/repos/{self.repo}{path}")

    def get_api(self, path: str) -> Any:
        """GET any API path (an org endpoint, for one)."""
        request = urllib.request.Request(f"{API}{path}", headers=self.headers)
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
                                  light_retry: bool = False, now: dt.datetime | None = None) -> Routed:
        """Where the pull request runs (and main's dispatches) since `since` went, so they are not all guessed.

        One unfiltered page of CI runs, kept to the routed ones (routed_run()),
        so main's full-suite dispatch is counted at no extra request.

        A fork run or a retry attempt never takes an owned pool, so it is off
        them without a lookup (and a fork's own marker is never trusted). For
        the rest, a marker names the owned pool and peak the run took; a
        finished `changes` job whose marker step was skipped means the pick
        was not an owned pool. Any other run (still picking, a lost marker
        upload, a failed lookup, or past ROUTE_LOOKUPS) is replayed.
        """
        runs = [run for run in self.runs_since(CI_WORKFLOW, since)
                if routed_run(run) and run.get("id") != exclude_run_id and run.get("status") != "completed"]
        owned: dict[str, int] = {}
        owned_now: dict[str, int] = {}
        owned_runs: dict[str, int] = {}
        live_now: dict[str, int] = {}
        live_runs: dict[str, int] = {}
        ephemeral = unknown = live_unknown = looked_up = 0
        clock = now or dt.datetime.now(dt.timezone.utc)

        def young(run: Mapping[str, Any]) -> bool:
            age = run_age_minutes(run, clock)
            return age is not None and age < LIVE_WINDOW_MINUTES
        for run in runs:
            if not may_hold_owned_pool(run, light_retry=light_retry):
                ephemeral += 1
                continue
            if looked_up >= ROUTE_LOOKUPS:
                unknown += 1
                live_unknown += young(run)
                continue
            looked_up += 1
            try:
                route = self.run_route(run)
            except Exception:  # noqa: BLE001 - one unreadable run is only replayed
                route = None
            if isinstance(route, tuple):
                owned[route[0]] = owned.get(route[0], 0) + route[1]
                owned_runs[route[0]] = owned_runs.get(route[0], 0) + 1
                age = run_age_minutes(run, clock)
                owned_now[route[0]] = owned_now.get(route[0], 0) + young_charge(route[1], age)
                if age is not None and age < LIVE_WINDOW_MINUTES:
                    live_now[route[0]] = live_now.get(route[0], 0) + young_charge(route[1], age)
                    live_runs[route[0]] = live_runs.get(route[0], 0) + 1
            elif route == "ephemeral":
                ephemeral += 1
            else:
                unknown += 1
                live_unknown += young(run)
        return Routed(unknown=unknown, owned=owned, ephemeral=ephemeral, owned_now=owned_now, owned_runs=owned_runs,
                      live_now=live_now, live_runs=live_runs, live_unknown=live_unknown)

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
        """The self-hosted runners this repository can use: its own and the org's RUNNER_GROUP.

        The glaeda minis are org runners in RUNNER_GROUP (glaeda#1222), which
        the repository endpoint does not list. Listing that group needs the
        App's organization permission "Self-hosted runners: read" (ci.yml
        mints the token with it). Raises when the group cannot be read, so
        each caller falls back to the snapshot instead of counting every
        mini as busy.
        """
        found = {runner.get("id"): runner for runner in self._runner_pages(f"/repos/{self.repo}/actions/runners")}
        owner, _, name = self.repo.partition("/")
        try:
            groups = self.get_api(f"/orgs/{owner}/actions/runner-groups?per_page={PAGE_SIZE}"
                                  f"&visible_to_repository={urllib.parse.quote(name)}").get("runner_groups") or []
            group = next((group for group in groups
                          if isinstance(group, Mapping) and group.get("name") == RUNNER_GROUP
                          and isinstance(group.get("id"), int)), None)
            if group is None:
                raise RuntimeError(f"no runner group {RUNNER_GROUP} is visible to {self.repo}")
            org = self._runner_pages(f"/orgs/{owner}/actions/runner-groups/{group.get('id')}/runners")
        except urllib.error.HTTPError as error:
            raise RuntimeError(f"org runner group {RUNNER_GROUP} unreadable (HTTP {error.code}); the routing "
                               "App needs the organization permission Self-hosted runners: read") from error
        found.update((runner.get("id"), runner) for runner in org)
        return list(found.values())

    def _runner_pages(self, path: str) -> list[Mapping[str, Any]]:
        found: list[Mapping[str, Any]] = []
        for page in range(1, 6):
            batch = self.get_api(f"{path}?per_page={PAGE_SIZE}&page={page}").get("runners") or []
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
            owned_jobs: Sequence[str] = (), admission_runner: str = "", side: str = "") -> str:
    runner = choice.runner or "each job's default (MACOS_RUNNER_PR or its fallback)"
    lines = ["### macOS pool for this run", "", f"- Pool: `{runner}`", f"- Why: {choice.reason}"]
    if choice.xcode_app:
        lines.append(f"- Xcode: `{choice.xcode_app}`")
    if choice.retry_runner:
        lines.append(f"- Jobs on `{choice.runner}`: {', '.join(owned_jobs) or 'none'}; every other job, "
                     f"and a re-run of failed jobs, goes to: `{choice.retry_runner}`")
    if choice.root_runner:
        lines.append(f"- Root jobs among them ({ROOT_JOBS}) take `{choice.root_runner}`")
    if side:
        lines.append(f"- Side lanes among them ({', '.join(SIDE_LANE_JOBS)}) take `{side}`")
    if admission_runner:
        labels = " + ".join(f"`{label}`" for label in json.loads(admission_runner))
        lines.append(f"- Compile admission takes {labels}: an idle root runner kept a build of this run's merge base")
    for problem in problems:
        lines.append(f"- **Error:** {problem}; that pool gets no machines")
    if isinstance(snapshot, Mapping) and snapshot.get("source") == "live":
        lines.append("- No janitor snapshot: owned pools read live from the runners API:")
        for label in sorted(owned_slots or {}):
            lines.append(f"  - {describe(snapshot, label, owned_slots)}")
    elif isinstance(snapshot, Mapping) and isinstance(snapshot.get("pools"), Mapping):
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
            light_retry=(env.get("OWNED_LIGHT_RETRY") or "").strip() == "1", now=now)

    event = env.get("EVENT_NAME") or ""
    ref = env.get("GITHUB_REF") or ""
    on_main = event == "workflow_dispatch" and ref == MAIN_REF
    # The changes job's routing, when the step runs after it; without it every
    # run is charged the most machines any run can hold.
    plan = FULL_RUN if "RUN_MACOS" not in env else run_plan(
        macos=env.get("RUN_MACOS"), full_suite=env.get("RUN_FULL_SUITE"), unit_suite=env.get("RUN_UNIT_SUITE"),
        # A persistent pick moves the changed suites out of admission to
        # shard 8 (ci.yml), so the plan always counts that shard.
        unit_in_admission="false", claude_wrapper=env.get("RUN_CLAUDE_WRAPPER"),
        cli=env.get("RUN_CLI"), remote_daemon=env.get("RUN_REMOTE_DAEMON"),
        unit_selectors=env.get("RUN_UNIT_SELECTORS"),
        swift_packages=env.get("RUN_SWIFT_PACKAGES"), release_build=env.get("RUN_RELEASE_BUILD"))
    if on_main:
        # The side lanes read the pick only on a pull request (ci.yml's
        # claude-wrapper, remote-daemon.yml); main's keep their own route.
        plan = dataclasses.replace(plan, side=())
    # What an owned pool must have free for the whole run: its owned-eligible
    # jobs at their peak.
    gui = (env.get("POOL_OWNED_GUI") or "").strip() != "0"
    jobs = owned_peak(plan, gui)
    # The org App's token (ci.yml mints it for same-repository pull requests
    # only) reads which owned runners are idle now. Without it, or on any
    # error, the slot counts and the snapshot decide as before.
    live_owned = online = None
    live_runners: list[Mapping[str, Any]] | None = None
    route_token = (env.get("ROUTE_TOKEN") or "").strip()
    if route_token and repo and not args.snapshot and (env.get("POOL_OWNED") or "").strip() == "1":
        try:
            labels = owned_pools(env.get(PR_XCODE_VARIABLE))
            # Each pool's root runners too; choose() keeps those with a root count.
            labels += tuple(root_label(label) for label in labels)
            live_runners = GitHub(route_token, repo).runners() if labels else None
            live_owned = live_owned_free(live_runners, labels) if live_runners is not None else None
            online = live_online(live_runners, labels) if live_runners is not None else None
        except Exception as error:  # noqa: BLE001 - the snapshot path still decides
            print(f"::warning title=live owned capacity::could not list runners ({error}); using the snapshot")
            live_owned = online = live_runners = None
    choice, snapshot = choose(
        event=event,
        ref=ref,
        main_reserve=env.get("OWNED_MAIN_RESERVE"),
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
        live_online=online,
        shards=sum(1 for key in plan.after if key.startswith("shard-")),
        queue_rounds=env.get("POOL_QUEUE_ROUNDS") or "",
    )
    pr_xcode_app = env.get(PR_XCODE_VARIABLE)
    # Only a same-repository pull request (and main's dispatch) reads the slots;
    # ci.yml blanks the pin everywhere else, so checking there would flag a
    # class entry on every run.
    same_repo_pr = event == "pull_request" and env.get("HEAD_REPO") == repo or on_main
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
    # (see "Warm affinity" above). Attempt 1 only: only it is placed, and
    # ci-macos.yml reads both outputs on attempt 1 only.
    admission_runner = ""
    admission_warm: list[list[str]] = []
    # CI_OWNED_WARM off ignores the snapshot's `warm`, so the switch alone
    # turns affinity off.
    if (attempt in ("", "1") and env.get("OWNED_WARM") == "1" and choice.root_runner and ADMISSION_JOB in owned_jobs
            and snapshot):
        # The warm runners' names by tier (merge base, then this pull request),
        # for ci-macos.yml's admission-placement, which re-reads the runners
        # just before admission queues.
        admission_warm = warm_tiers(env.get("MERGED_ONTO"), snapshot.get("warm"), env.get("PR_NUMBER"))
        if live_runners is not None:
            # Cost routing (warm_distance.py): expected wait plus predicted compile per root runner, a
            # busy warm one included when the rescue budget covers its wait, against the root label.
            from pathlib import Path  # noqa: PLC0415
            sys.path.insert(0, str(Path(__file__).resolve().parent))
            import warm_distance  # noqa: PLC0415
            admission_runner, route = warm_distance.picker_route(
                live_runners, choice.root_runner, merged_onto=env.get("MERGED_ONTO"),
                pr_number=env.get("PR_NUMBER"), snapshot=snapshot, workspace=Path.cwd(),
                queue_rounds=parse_queue_rounds(env.get("POOL_QUEUE_ROUNDS")), now=now,
                warm_key=warm_key, runner_label=runner_label, root_free=choice.root_budget)
            print(f"warm routing: {route.get('why')} {json.dumps(route, sort_keys=True)}")
    owned_slots = slots(env.get("OWNED_SLOTS"), pr_xcode_app)
    side = side_runner(choice, owned_slots)
    text = summary(choice, snapshot, now=now, owned_slots=owned_slots, problems=problems,
                   owned_jobs=owned_jobs, admission_runner=admission_runner, side=side)
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
                         # What the side lanes in owned_jobs take instead of
                         # the pool label, on attempt 1 and on that attempt 2.
                         f"side_runner={side}\n"
                         # JSON labels for admission's attempt 1: the root label
                         # and the static label of the runner warm for this
                         # run's merge base, or "".
                         f"admission_runner={admission_runner}\n"
                         # JSON tiers of the names of the root runners warm for
                         # this run's merge base, then its pull request, or ""
                         # (admission_placement.py).
                         f"admission_warm={json.dumps(admission_warm, separators=(',', ':')) if admission_warm else ''}\n"
                         # Space-delimited with a space at each end, so each job's
                         # contains(' <key> ') test matches whole keys only.
                         f"owned_jobs={' ' + ' '.join(owned_jobs) + ' ' if owned_jobs else ''}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
