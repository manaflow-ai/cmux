#!/usr/bin/env python3
"""Pick the macOS pool the unsigned iOS jobs land on.

test-ios.yml (mobile-core-package, ios-simulator-build, ios-simulator) and
ios-screenshots.yml (screenshots) run this in a `runner` job, the way
test-e2e.yml runs e2e_runner_pool.py, and every macOS job of the run reads its
outputs.

The choice is the E2E rule (e2e_runner_pool.decide(), which calls pull
request CI's pr_runner_pool.decide()), limited to one question: may this run
take an owned Mac? Owned Macs are `glaeda-<class>-xcode-<version>` pools
(pr_runner_pool.persistent). The answer is yes only when all of these hold:

    vars.CI_PR_POOL_OWNED == '1'   the fleet switch pull requests and E2E read
    vars.CI_IOS_OWNED == '1'       this lane's own switch (IOS_OWNED_VARIABLE)
    `runner` is auto               an explicit runner is never rerouted
    the default is the 6vcpu       MACOS_RUNNER_TESTS, then MACOS_RUNNER_IOS,
      macOS 26 pool                  names blacksmith-6vcpu-macos-26
    no `ios_version`               the minis carry one iOS 26.x runtime; another
                                     version would download a platform onto a
                                     shared machine
    not an App Store upload        the upload writes the ASC key to $HOME
    not a release call             release runs stay on Blacksmith
    no `seed_cache`                seeding runs in the ci-cache-writer
                                     environment with the R2 write keys
    the lane is measured           ios-screenshots.yml is a reusable workflow
                                     that release.yml calls with only
                                     `contents: read`, so its runner job cannot
                                     hold the `actions: read` the queue snapshot
                                     needs; it reaches the minis only on request
    the pool has room              LANES[lane].jobs owned machines are free
                                     live, or without the live read the pull
                                     request rule places them on an owned
                                     pool within its queue rounds (below)
    the simulators have room       SIM_LABEL has the run's simulator jobs free

Otherwise the run keeps the default, exactly as before: when the picker would
have chosen a Blacksmith pool (12vcpu overflow, say), iOS still takes its own
variable, so MACOS_RUNNER_IOS keeps meaning what it meant.

Queue rounds. The pool rule is pull request CI's with its
vars.CI_PR_POOL_QUEUE_ROUNDS (`--queue-rounds`): an owned pool takes the run
while its jobs start there within that many job lengths, whatever
Blacksmith's wait, and the queue stays within machines x (1 + rounds)
(pr_runner_pool.owned_room()). Without the rounds the picker used the kill
switch rule, which counts every in-flight run's whole future peak (the
janitor's `committed`) as taken now: on 2026-09-25 (run 36136190497) that read
43 of 32 std machines taken while 8 ran, so the run went to the 6vcpu macOS
26 pool with 62 jobs queued and waited 15 minutes there. `--queue-rounds 0`
restores that rule; a caller that omits the flag gets it too.
ci-owned-pool-rescue.yml gives a test-ios.yml run's owned jobs the same queue
allowance as a CI run's before it moves them. The simulators are not queued
for: SIM_LABEL must have the run's simulator jobs free now.

Live capacity. test-ios.yml mints the org's glaeda-route App token (as ci.yml
does) for same-repository runs and passes it as ROUTE_TOKEN. With it, "free"
is read from live state, not estimated from run titles. Each in-flight
test-ios.yml and ios-screenshots.yml run of the last SIM_WINDOW_MINUTES (only
those two workflows hold simulators) is charged what its jobs show it holds
or will take on the owned pool (hold()), and nothing else. ios-screenshots.yml
runs are known by their workflow path and need one machine and one simulator.

    a job running on an owned runner   already shows as a busy runner; a
                                         simulator job (SIM_JOB) also holds its
                                         mini's simulator
    a queued job on an owned label     one machine, and a simulator if it is
                                         a simulator job
    simulator jobs not created yet     one simulator each, and a machine each
                                         beyond the one a running build frees;
                                         none once the build failed
    a run placed owned, no jobs yet    its whole need from its title
    a run still picking                its whole need: it may yet go owned
    a run on Blacksmith                nothing: a re-run, a named Blacksmith
                                         pool, macOS jobs on a Blacksmith label,
                                         or a finished picker without a marker

The pool is its online idle runners (pr_runner_pool.live_owned_free()) less
the machines charged. Simulators are counted per mini, not per runner: every
runner instance of a simulator mini carries SIM_LABEL (`<member>-glaeda`,
`<member>-glaeda-K`), and the mini runs one simulator job at a time, so an
idle runner says nothing about its simulator. The free simulators are the
online SIM_LABEL minis of the pool that no running simulator job holds, at
most CI_OWNED_POOL_SLOTS' SIM_LABEL entry less those held, less the
simulators charged. Neither count goes below zero. live_placements() lists
the markers, reads the jobs of the runs they and age leave open (at most
MAX_JOB_READS, newest first), and lists one more page of markers when a run
read has a finished picker the first listing did not mark, so a picker that
finishes between the reads is never taken for Blacksmith. A run left unread
is charged its title's need, the machines only within
pr_runner_pool.LIVE_WINDOW_MINUTES (after that its jobs show busy).
Until 2026-09-28 every run was charged its whole need from its title, the
simulators for SIM_WINDOW_MINUTES and the machines for
pr_runner_pool.LIVE_WINDOW_MINUTES, wherever it went: a burst of pull
request runs, each sent to Blacksmith within a minute, read as "-2
glaeda-ios-sim free" and a pool of -1 while std runners, root and side, sat
idle, so every run behind them overflowed too, and a run whose simulators had
finished still held them. The run takes the pool `runner: owned` takes when
both counts cover it; otherwise it keeps the default. The janitor snapshot is
not read. On 2026-09-25 the snapshot
estimate, which charges every newer pull request run it cannot place,
counted the owned pool full while 20 of its runners sat idle. Without the
token, or when the runners cannot be listed or none carries the pool label,
the snapshot rules below decide.

Simulator capacity. glaeda puts SIM_LABEL (`glaeda-ios-sim`) on the runners of
minis that have an iOS simulator role and an iOS 26.x runtime, and runs one
simulator job at a time on each such mini (a second is refused). Its count is
CI_OWNED_POOL_SLOTS' SIM_LABEL entry (`{"glaeda-ios-sim": 2}`, read by
pr_runner_pool.capability_slots()), one simulator job per machine; without the
entry the lane never takes the fleet on its own. What is taken comes from the
queue janitor's snapshot, which counts every queued or running job carrying
the label and each run's capability marker (queue_janitor.capability_marker),
plus every test-ios.yml and ios-screenshots.yml run created since the snapshot
and still in flight, charged the simulator jobs its title says it needs
(charged_sim_jobs()): none for a Swift package run or one dispatched to a named
Blacksmith pool, one for a single device family, else MAX_SIM_JOBS. A run
whose title does not parse is charged in full.

Where an `auto` run went. Its title says `auto` wherever the picker sent it,
so the runs it sent to Blacksmith would otherwise be charged simulators they
never hold. On 2026-09-25 that kept the picker at "-5 of 8 free" with nine
simulator minis idle: every run it sent to Blacksmith was charged two
simulators, so the next run went to Blacksmith too. A run the picker put on
the owned pool uploads the fixed-name `owned-pool-watch` marker (the rescue
sweeper's), so a listing of that name (owned_placements(), at most
MARKER_PAGES pages) says which runs took the fleet. An `auto` run without it is charged nothing once its runner
job has had PLACEMENT_GRACE_MINUTES to pick, and so is a re-run attempt,
which always takes the retry label. A run younger than that, a listing that
failed, or one older than the listing reaches is charged in full. (The live
path reads the runs' jobs instead; see Live capacity.)

Labels. ios-simulator-build and ios-simulator need the iOS runtime, and
screenshots too, so they ask for the owned pool label and SIM_LABEL together
(`runs_on`); the plain pool label alone never reaches them. mobile-core-package
runs SwiftPM tests on the host and needs no simulator, so it takes the pool
label alone (`package_runs_on`). glaeda knows these jobs (the build and package
jobs are isolated jobs, the simulator jobs hold its per-mini simulator token),
so unlike an E2E run they never take the root label. Neither label appears in
workflow text (tests/test_ci_self_hosted_guard.sh refuses `glaeda-` there):
runs-on reads the JSON this prints.

`runner: owned` forces the owned pool for the lane's Xcode pin
(vars.CMUX_CI_XCODE_APP_PR), without reading the queue, for a proof run. It
is an explicit request, so instead of falling back it fails the runner job
when the run could not be rescued or has nowhere to go: CI_PR_POOL_OWNED is
not 1 (ci-owned-pool-rescue.yml then never watches it, and a job left queued
would wait for good), or CI_OWNED_POOL_SLOTS gives SIM_LABEL no machines. It
also refuses what auto refuses: an `ios_version`, an upload, a release call
and `seed_cache`. CI_IOS_OWNED is not required, so a proof run can precede it.

A `swift_package` run of test-ios.yml runs mobile-core-package alone: one
machine and no simulator, so it needs no SIM_LABEL capacity.

A job left queued on the owned labels, or refused by glaeda at job start, is
re-run by ci-owned-pool-rescue.yml, which watches the run through the marker
the runner job uploads (as for E2E). From attempt 2 on every macOS job takes
`retry_runs_on`: the default when it is a Blacksmith pool, else the 6vcpu
macOS 26 pool.

API budget: the E2E picker's four requests, plus one page of runs for each
of the two iOS workflows and up to MARKER_PAGES pages of `owned-pool-watch`
markers; on the live path, four pages of in-flight runs, the marker pages,
one job listing for each run they and age leave open (at most MAX_JOB_READS),
and one more marker page when a run read was picked after the first listing.
Anything uncertain keeps the default.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
import re
import sys
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
from typing import Any

sys.path.insert(0, str(Path(__file__).resolve().parent))
import e2e_runner_pool  # noqa: E402
import pr_runner_pool  # noqa: E402

SMALL_RUNNER = pr_runner_pool.DEFAULT_RUNNER
# The capability label glaeda puts on runners of minis with an iOS simulator
# role and an iOS 26.x runtime. Requested beside the owned pool label.
SIM_LABEL = "glaeda-ios-sim"
assert SIM_LABEL in pr_runner_pool.CAPABILITY_LABELS
# The `runner` choice that forces the owned pool for a proof run.
OWNED_CHOICE = "owned"
IOS_OWNED_VARIABLE = "CI_IOS_OWNED"
# The workflows whose in-flight runs since the snapshot hold simulators.
IOS_WORKFLOWS = ("test-ios.yml", "ios-screenshots.yml")
# How far back an in-flight iOS run is charged its simulator jobs on the live
# path: longer than any iOS run lives (ios-screenshots.yml's 300 minute
# capture; see Live capacity).
SIM_WINDOW_MINUTES = 360
# The marker every owned placement uploads (test-ios.yml's runner job, ci.yml,
# test-e2e.yml), read to learn which `auto` runs took the owned pool.
WATCH_MARKER = "owned-pool-watch"
# How long a run's runner job has to pick and upload that marker. An `auto` run
# younger than this is charged in full; an older one without it is on Blacksmith.
PLACEMENT_GRACE_MINUTES = 5
# The picker's job in test-ios.yml and ios-screenshots.yml. Once it has
# finished, the run's marker (if any) is uploaded, so a finished picker without
# one means Blacksmith.
PICKER_JOB = "runner"
# The jobs that hold a mini's simulator: test-ios.yml's ios-simulator matrix
# and ios-screenshots.yml's capture. ios-simulator-build carries SIM_LABEL only
# to land on a mini with the runtime; glaeda runs it as an isolated build job.
SIM_JOB = re.compile(r"ios-simulator(?: \(.*\))?|screenshots")
# In-flight iOS runs whose jobs are read (one request each), newest first.
MAX_JOB_READS = 20
# Job statuses before a runner has taken the job.
WAITING = frozenset({"queued", "waiting", "pending", "requested"})
# Pages of markers read. The name is shared with ci.yml and test-e2e.yml, so one
# page of 100 reached back about an hour on 2026-09-25; three cover a saturated
# Blacksmith pool's longest waits.
MARKER_PAGES = 3
# A glaeda runner's name: `<member>-glaeda`, or `<member>-glaeda-K` for instance K.
RUNNER_INSTANCE_SUFFIX = re.compile(r"-glaeda(?:-\d+)?$")


@dataclasses.dataclass(frozen=True)
class Lane:
    # Most owned machines one run holds at once.
    jobs: int
    # Whether auto may read the queue (the runner job holds `actions: read`).
    measured: bool


LANES = {
    # mobile-core-package and ios-simulator-build run side by side; the
    # simulator matrix (iPhone, iPad) follows the build, two again.
    "test-ios": Lane(jobs=2, measured=True),
    # One capture job.
    "screenshots": Lane(jobs=1, measured=False),
}
# The most simulator jobs any one iOS run holds: test-ios.yml's two families.
MAX_SIM_JOBS = 2


@dataclasses.dataclass(frozen=True)
class LiveFree:
    # The owned pool's runners free now, and those of them with SIM_LABEL,
    # less the recent iOS runs' jobs (see Live capacity).
    pool: int
    sim: int


@dataclasses.dataclass(frozen=True)
class IOSLoad:
    pool: e2e_runner_pool.PoolLoad | None
    # Simulator jobs charged to test-ios.yml and ios-screenshots.yml runs created
    # since the snapshot and still in flight (charged_sim_jobs()).
    ios_since: int = 0
    # Read from the runners API instead of the snapshot, when the route token works.
    live: LiveFree | None = None


@dataclasses.dataclass(frozen=True)
class Route:
    label: str  # the pool label
    retry_label: str  # what every macOS job takes from attempt 2 on
    persistent: bool

    @property
    def runs_on(self) -> str:
        """runs-on as JSON for a job that needs the iOS runtime: an owned pool adds SIM_LABEL."""
        return json.dumps([self.label, SIM_LABEL] if self.persistent else self.label)

    @property
    def package_runs_on(self) -> str:
        """runs-on as JSON for mobile-core-package, which needs no simulator."""
        return json.dumps(self.label)

    @property
    def retry_runs_on(self) -> str:
        return json.dumps(self.retry_label)


def ephemeral(label: str) -> Route:
    return Route(label, label, False)


def retry_label(default: str) -> str:
    """A Blacksmith pool for re-runs: the default when it is one, else the 6vcpu macOS 26 pool."""
    return default if default.startswith(pr_runner_pool.EPHEMERAL_PREFIX) else SMALL_RUNNER


def sim_jobs(lane: str, device_family: str | None, swift_package: str | None = None) -> int:
    """The simulator jobs this run holds at once: one per device family, the one capture, or none."""
    if lane == "screenshots":
        return 1
    if (swift_package or "").strip():
        # mobile-core-package alone: SwiftPM tests on the host.
        return 0
    return 1 if (device_family or "").strip() in ("iphone", "ipad") else MAX_SIM_JOBS


def run_jobs(lane: str, swift_package: str | None = None) -> int:
    """The owned machines this run holds at once."""
    return 1 if lane == "test-ios" and (swift_package or "").strip() else LANES[lane].jobs


def owned_blocker(*, ios_version: str | None, upload: str | None, called: str | None,
                  seed_cache: str | None = None) -> str:
    """Why this run may not take an owned Mac, or "" when it may."""
    if (ios_version or "").strip():
        return "an ios_version is requested; the minis carry one iOS 26.x runtime"
    if (upload or "").strip() == "true":
        return "an App Store upload writes the ASC key to $HOME"
    if (called or "").strip() == "true":
        return "a release call stays on Blacksmith"
    if (seed_cache or "").strip() == "true":
        return "seed_cache runs in the ci-cache-writer environment with the R2 write keys"
    return ""


def pool_slots(owned_slots: str | None, pr_xcode_app: str | None) -> dict[str, int]:
    """The owned pools' machines, without root counts: iOS jobs never take a root label."""
    return {label: count for label, count in pr_runner_pool.slots(owned_slots, pr_xcode_app).items()
            if not label.startswith((pr_runner_pool.ROOT_PREFIX, pr_runner_pool.GUI_PREFIX))}


def sim_free(load: IOSLoad, capacity: int) -> int:
    """SIM_LABEL machines free: capacity less what the snapshot saw and the iOS runs since."""
    entry: Mapping[str, Any] = ((load.pool.snapshot if load.pool else {}).get("pools") or {}).get(SIM_LABEL) or {}
    taken = max(int(entry.get("running") or 0) + int(entry.get("queued") or 0), int(entry.get("committed") or 0))
    return capacity - taken - load.ios_since


def resolve(
    lane: str,
    requested: str | None,
    variable: str | None,
    *,
    ios_owned: str | None,
    owned: str | None,
    owned_slots: str | None,
    pr_xcode_app: str | None,
    order: str | None,
    max_queued: str | None,
    queue_rounds: str | None = None,
    ios_version: str | None = None,
    device_family: str | None = None,
    swift_package: str | None = None,
    upload: str | None = None,
    called: str | None = None,
    seed_cache: str | None = None,
    measure: Callable[[], IOSLoad],
    now: dt.datetime,
    log: Callable[[str], None] = lambda message: None,
    fork: bool = False,
) -> Route:
    """The route for one run, from its inputs and variables. Raises ValueError on a refused request."""
    config = LANES[lane]
    if fork:
        # A fork's pull request: never an owned Mac (they keep build state
        # between jobs), and never a variable that could name one.
        log(f"a fork pull request; staying on {SMALL_RUNNER}")
        return ephemeral(SMALL_RUNNER)
    requested = (requested or "").strip()
    default = (variable or "").strip() or SMALL_RUNNER
    if requested and requested not in ("auto", OWNED_CHOICE):
        return ephemeral(requested)
    blocker = owned_blocker(ios_version=ios_version, upload=upload, called=called, seed_cache=seed_cache)
    capacity = pr_runner_pool.capability_slots(owned_slots).get(SIM_LABEL, 0)
    if requested == OWNED_CHOICE:
        if blocker:
            raise ValueError(f"runner: {OWNED_CHOICE} refused: {blocker}")
        if (owned or "").strip() != "1":
            raise ValueError(f"runner: {OWNED_CHOICE} refused: {pr_runner_pool.OWNED_VARIABLE} is not 1, so "
                             "ci-owned-pool-rescue.yml would not watch the run and a queued job could wait for good")
        if capacity < 1:
            raise ValueError(f"runner: {OWNED_CHOICE} refused: {pr_runner_pool.SLOTS_VARIABLE} gives {SIM_LABEL} "
                             f"no machines (add \"{SIM_LABEL}\": <simulator minis>)")
        pools = pr_runner_pool.owned_pools(pr_xcode_app)
        if not pools:
            raise ValueError(f"runner: {OWNED_CHOICE} needs {pr_runner_pool.PR_XCODE_VARIABLE} to name an "
                             "Xcode version (/Applications/Xcode_<version>.app)")
        log(f"runner: {OWNED_CHOICE} -> {pools[0]} with {SIM_LABEL}")
        return Route(pools[0], retry_label(default), True)
    if blocker:
        log(f"{blocker}; staying on {default}")
        return ephemeral(default)
    if (owned or "").strip() != "1" or (ios_owned or "").strip() != "1":
        log(f"{pr_runner_pool.OWNED_VARIABLE} or {IOS_OWNED_VARIABLE} is not 1; staying on {default}")
        return ephemeral(default)
    if not config.measured:
        log(f"the {lane} lane cannot read the queue; staying on {default} (dispatch runner: {OWNED_CHOICE} "
            "to use an owned Mac)")
        return ephemeral(default)
    if default != SMALL_RUNNER:
        # As for E2E: only the 6vcpu macOS 26 default is routed.
        return ephemeral(default)
    needed = sim_jobs(lane, device_family, swift_package)
    if needed and not capacity:
        log(f"{pr_runner_pool.SLOTS_VARIABLE} gives {SIM_LABEL} no machines; staying on {default}")
        return ephemeral(default)
    limits = e2e_runner_pool.settings(order, max_queued, owned, pr_xcode_app, queue_rounds)
    if limits is None or not any(pr_runner_pool.persistent(label) for label in limits.order):
        log(f"no owned pool in {pr_runner_pool.ORDER_VARIABLE} for {pr_runner_pool.PR_XCODE_VARIABLE}, or an invalid "
            f"{pr_runner_pool.ORDER_VARIABLE}/{pr_runner_pool.MAX_QUEUED_VARIABLE}/{pr_runner_pool.QUEUE_ROUNDS_VARIABLE}; "
            f"staying on {default}")
        return ephemeral(default)
    try:
        load = measure()
    except Exception as error:  # noqa: BLE001 - every failure is fail-safe
        log(f"could not read the runner queue ({error}); staying on {default}")
        return ephemeral(default)
    if load.live is not None:
        pools = pr_runner_pool.owned_pools(pr_xcode_app)
        jobs = run_jobs(lane, swift_package)
        if pools and pools[0] in limits.order and load.live.pool >= jobs and load.live.sim >= needed:
            log(f"live: {load.live.pool} owned runner(s) and {load.live.sim} {SIM_LABEL} free, {jobs} and "
                f"{needed} needed -> {pools[0]} with {SIM_LABEL}")
            return Route(pools[0], retry_label(default), True)
        log(f"live: {load.live.pool} owned runner(s) and {load.live.sim} {SIM_LABEL} free, {jobs} and "
            f"{needed} needed; staying on {default}")
        return ephemeral(default)
    # Simulator jobs take the first owned pool only, as the live path above
    # routes them, since SIM_LABEL is on that pool's runners. The replay of
    # newer runs still spreads over the whole order.
    try:
        choice = e2e_runner_pool.decide(load.pool, limits, now=now,
                                        owned_slots=pool_slots(owned_slots, pr_xcode_app),
                                        jobs=run_jobs(lane, swift_package),
                                        owned_choices=pr_runner_pool.owned_pools(pr_xcode_app)[:1])
        free = sim_free(load, capacity)
    except Exception as error:  # noqa: BLE001 - every failure is fail-safe
        log(f"could not read the runner queue ({error}); staying on {default}")
        return ephemeral(default)
    if not pr_runner_pool.persistent(choice.runner):
        log(f"{choice.reason or 'no owned pool has room'}; staying on {default}")
        return ephemeral(default)
    if needed and free < needed:
        log(f"{SIM_LABEL}: {free} of {capacity} free, {needed} needed; staying on {default}")
        return ephemeral(default)
    log(f"{choice.reason} -> {choice.runner} with {SIM_LABEL} ({free} of {capacity} free, {needed} needed)")
    return Route(choice.runner, retry_label(default), True)


# test-ios.yml's run-name: "iOS tests · REF · PACKAGE|simulator · FILTER · FAMILY · iOS VERSION · on RUNNER".
TITLE_PREFIX = "iOS tests · "
TITLE_SEPARATOR = " · "


@dataclasses.dataclass(frozen=True)
class Placements:
    """The runs whose picker took the owned pool, from the newest WATCH_MARKER artifacts."""
    runs: frozenset[int]
    # The oldest marker read when more remain: a run created before it may be on an unread page.
    since: str | None = None

    def off_fleet(self, run: Mapping[str, Any], now: dt.datetime) -> bool:
        """True when `run` certainly holds no owned machine: a re-run, or picked a while ago without a marker.

        "A while ago" assumes the picker finished within PLACEMENT_GRACE_MINUTES
        of the run's creation. Neither the run's status nor run_started_at says
        whether its picker has started (a run whose jobs wait on Blacksmith
        reads `queued`, and run_started_at is its creation), so only the
        run's jobs could; the live path reads them for runs younger than this.
        """
        attempt = run.get("run_attempt")
        if isinstance(attempt, int) and attempt > 1:
            return True
        if run.get("id") in self.runs:
            return False
        created = str(run.get("created_at") or "")
        if not created or self.since is not None and created < self.since:
            return False
        age = pr_runner_pool.run_age_minutes(run, now)
        return age is not None and age >= PLACEMENT_GRACE_MINUTES


def owned_placements(client: Any, pages: int = MARKER_PAGES) -> Placements | None:
    """Which runs took the owned pool (`pages` requests at most), or None when the markers cannot be read."""
    artifacts: list[Mapping[str, Any]] = []
    more = False
    try:
        for page in range(1, pages + 1):
            found = client.get(f"/actions/artifacts?name={WATCH_MARKER}&per_page={pr_runner_pool.PAGE_SIZE}"
                               f"&page={page}").get("artifacts") or []
            artifacts += [item for item in found if isinstance(item, Mapping)]
            more = len(found) >= pr_runner_pool.PAGE_SIZE
            if not more:
                break
    except Exception as error:  # noqa: BLE001 - unknown placements are charged in full
        print(f"::warning title=owned placements::could not list {WATCH_MARKER} markers ({error})", file=sys.stderr)
        return None
    runs = frozenset(int(item["workflow_run"]["id"]) for item in artifacts
                     if isinstance(item.get("workflow_run"), Mapping)
                     and isinstance(item["workflow_run"].get("id"), int))
    since = None
    if more:
        since = min((str(item.get("created_at") or "") for item in artifacts), default="") or None
    return Placements(runs, since)


def screenshots_run(run: Mapping[str, Any]) -> bool:
    """An ios-screenshots.yml run, by its workflow path: one capture job, one simulator."""
    return str(run.get("path") or "").split("@", 1)[0].endswith("/ios-screenshots.yml")


def charged_sim_jobs(run: Mapping[str, Any], placements: Placements | None = None,
                     now: dt.datetime | None = None) -> int:
    """The simulator jobs an in-flight iOS run may hold, read from its title; in full when unsure.

    With `placements`, an `auto` run the picker sent to Blacksmith is charged nothing (see "Where an
    `auto` run went").
    """
    if screenshots_run(run):
        return LANES["screenshots"].jobs
    title = str(run.get("display_title") or "")
    fields = title.split(TITLE_SEPARATOR)
    if not title.startswith(TITLE_PREFIX) or len(fields) != 7 or not fields[6].startswith("on "):
        return MAX_SIM_JOBS
    runner = fields[6][len("on "):].strip()
    if runner not in ("", "auto", OWNED_CHOICE):
        # Dispatched to a named pool (Blacksmith, Tart): never an owned simulator.
        return 0
    if runner != OWNED_CHOICE and placements is not None \
            and placements.off_fleet(run, now or dt.datetime.now(dt.timezone.utc)):
        return 0
    package = "" if fields[2] == "simulator" else fields[2]
    return sim_jobs("test-ios", fields[4], package)


def charged_jobs(run: Mapping[str, Any]) -> int:
    """The owned machines an in-flight iOS run may hold, read from its title; in full when unsure."""
    if screenshots_run(run):
        return LANES["screenshots"].jobs
    title = str(run.get("display_title") or "")
    fields = title.split(TITLE_SEPARATOR)
    if not title.startswith(TITLE_PREFIX) or len(fields) != 7 or not fields[6].startswith("on "):
        return LANES["test-ios"].jobs
    if fields[6][len("on "):].strip() not in ("", "auto", OWNED_CHOICE):
        return 0
    return run_jobs("test-ios", "" if fields[2] == "simulator" else fields[2])


def runner_host(runner: Mapping[str, Any]) -> str:
    """The mini a runner instance runs on, from its name (its id when it has none)."""
    name = str(runner.get("name") or "")
    return RUNNER_INSTANCE_SUFFIX.sub("", name) if name else f"#{runner.get('id')}"


@dataclasses.dataclass(frozen=True)
class Hold:
    """What one in-flight iOS run holds or will take on the owned pool (see Live capacity)."""
    # Machines it will take that no runner shows busy yet.
    machines: int = 0
    # Simulators it will take that no running simulator job holds yet.
    sims: int = 0
    # Minis whose simulator one of its running simulator jobs holds.
    sim_hosts: frozenset[str] = frozenset()


def settled_off(run: Mapping[str, Any]) -> bool:
    """True when `run`'s title or attempt alone puts it on Blacksmith: a re-run, or a named pool."""
    attempt = run.get("run_attempt")
    if isinstance(attempt, int) and attempt > 1:
        return True
    title = str(run.get("display_title") or "")
    fields = title.split(TITLE_SEPARATOR)
    return (title.startswith(TITLE_PREFIX) and len(fields) == 7 and fields[6].startswith("on ")
            and fields[6][len("on "):].strip() not in ("", "auto", OWNED_CHOICE))


def job_labels(job: Mapping[str, Any]) -> set[str]:
    """A jobs-API job's labels (plain strings there, unlike the runners API)."""
    return {str(label) for label in job.get("labels") or []}


def on_runner(job: Mapping[str, Any]) -> bool:
    return job.get("status") == "in_progress" and bool(job.get("runner_name"))


def hosted_macos(label: str) -> bool:
    """A Blacksmith (blacksmith-*-macos-*) or GitHub-hosted (macos-*) label: owned labels are glaeda-*."""
    return not label.startswith("glaeda-") and "macos" in label


def picked_unmarked(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]]) -> bool:
    """The run's picker finished and no macOS job exists yet: its marker alone says where it went."""
    return (any(job.get("name") == PICKER_JOB and job.get("status") == "completed" for job in jobs)
            and not any(hosted_macos(label) for job in jobs for label in job_labels(job)))


def hold(run: Mapping[str, Any], jobs: Sequence[Mapping[str, Any]] | None, pool: str,
         placements: Placements | None, now: dt.datetime) -> Hold:
    """What `run` holds or will take on `pool`, from its jobs when read (None: unread)."""
    need = Hold(charged_jobs(run), charged_sim_jobs(run))
    if settled_off(run):
        return Hold()
    if jobs is None:
        # Unread: the age rule may settle it; otherwise its title's need, the
        # machines only while they may not have reached a runner yet (older
        # runs' owned jobs show busy on the runners).
        if placements is not None and placements.off_fleet(run, now):
            return Hold()
        age = pr_runner_pool.run_age_minutes(run, now)
        young = age is None or age < pr_runner_pool.LIVE_WINDOW_MINUTES
        return Hold(need.machines if young else 0, need.sims)
    owned = [job for job in jobs if job_labels(job) & {pool, SIM_LABEL}]
    if not owned:
        if any(hosted_macos(label) for job in jobs for label in job_labels(job)):
            # Its macOS jobs asked for a Blacksmith (or hosted) label.
            return Hold()
        created = str(run.get("created_at") or "")
        if (not screenshots_run(run) and picked_unmarked(run, jobs) and placements is not None
                and run.get("id") not in placements.runs and created
                and (placements.since is None or created >= placements.since)):
            # Picked, and no marker: Blacksmith. (ios-screenshots.yml uploads
            # no watch marker, so a capture waits for its job's label.)
            return Hold()
        # Still picking, or placed owned with no macOS job yet.
        return need
    sims = [job for job in owned if SIM_JOB.fullmatch(str(job.get("name") or ""))]
    # ios-simulator-build: SIM_LABEL for the runtime, but no simulator of its own.
    builds = [job for job in owned if job not in sims and SIM_LABEL in job_labels(job)]
    waiting = [job for job in owned if job.get("status") != "completed" and not on_runner(job)]
    failed = any(job.get("status") == "completed" and job.get("conclusion") != "success" for job in builds)
    # Simulator jobs GitHub has not created yet: the matrix follows a
    # successful build, so none will come after a failed one.
    to_come = 0 if failed else max(0, need.sims - len(sims))
    waiting_sims = sum(1 for job in waiting if job in sims)
    waiting_rest = sum(1 for job in waiting if job not in sims and job not in builds)
    running_builds = sum(1 for job in builds if on_runner(job))
    # Now: every waiting job takes a machine. After the build: the rest still
    # waiting, the simulator jobs, less the machine the running build frees.
    machines = max(len(waiting), waiting_rest + waiting_sims + to_come - running_builds, 0)
    return Hold(machines=machines, sims=waiting_sims + to_come,
                sim_hosts=frozenset(runner_host({"name": job["runner_name"]}) for job in sims if on_runner(job)))


def live_free(runners: Sequence[Mapping[str, Any]], pool: str, recent: Sequence[Mapping[str, Any]], *,
              now: dt.datetime, capacity: int, placements: Placements | None = None,
              jobs: Mapping[int, Sequence[Mapping[str, Any]]] | None = None) -> LiveFree:
    """The pool's idle runners and its free simulator minis, less what in-flight iOS runs will take.

    `recent` are the in-flight runs of the last SIM_WINDOW_MINUTES and `jobs`
    the jobs read for some of them (see Live capacity). Never negative.
    Raises when no runner carries `pool`, so the snapshot decides instead.
    """
    mine = [runner for runner in runners
            if pool in {str(item.get("name")) for item in runner.get("labels") or [] if isinstance(item, Mapping)}]
    if not mine:
        raise RuntimeError(f"no runner carries {pool}")
    idle = pr_runner_pool.live_owned_free(mine, (pool,))
    sim_hosts = {runner_host(runner) for runner in mine if runner.get("status") == "online"
                 and SIM_LABEL in {str(item.get("name")) for item in runner.get("labels") or []
                                   if isinstance(item, Mapping)}}
    holds = [hold(run, (jobs or {}).get(run.get("id")), pool, placements, now) for run in recent]
    held = sim_hosts & frozenset().union(*(item.sim_hosts for item in holds))
    sim_room = max(0, min(len(sim_hosts - held), capacity - len(held)))
    return LiveFree(pool=max(0, idle[pool] - sum(item.machines for item in holds)),
                    sim=max(0, sim_room - sum(item.sims for item in holds)))


def run_jobs_read(client: Any, runs: Sequence[Mapping[str, Any]], placements: Placements | None,
                  now: dt.datetime) -> dict[int, list[Mapping[str, Any]]]:
    """The latest jobs of the newest MAX_JOB_READS runs that may hold the fleet (one request each).

    A run its attempt, title or age already settles on Blacksmith (settled_off(),
    Placements.off_fleet()) is not read. A run whose jobs cannot be read is left
    out, and so charged its title's need.
    """
    wanted = sorted((run for run in runs if isinstance(run.get("id"), int) and not settled_off(run)
                     and not (placements is not None and placements.off_fleet(run, now))),
                    key=lambda run: str(run.get("created_at") or ""), reverse=True)
    read: dict[int, list[Mapping[str, Any]]] = {}
    for run in wanted[:MAX_JOB_READS]:
        try:
            listing = client.get(f"/actions/runs/{run['id']}/jobs?filter=latest&per_page={pr_runner_pool.PAGE_SIZE}")
        except Exception as error:  # noqa: BLE001 - an unread run is charged its title's need
            print(f"::warning title=live owned capacity::could not read run {run['id']}'s jobs ({error})",
                  file=sys.stderr)
            continue
        read[run["id"]] = [job for job in (listing or {}).get("jobs") or [] if isinstance(job, Mapping)]
    return read


def live_placements(client: Any, runs: Sequence[Mapping[str, Any]], now: dt.datetime
                    ) -> tuple[dict[int, list[Mapping[str, Any]]], Placements | None]:
    """The runs' jobs and the markers, read so a picker finishing in between is never taken for Blacksmith.

    The markers are listed first, to skip reading the runs they and age
    already settle, then the jobs. A run read with its picker finished and
    no macOS job, whose marker was not in the first listing, may have
    uploaded it since: one more page of markers, read after its jobs, says.
    If that page cannot be read, no such run is settled (placements None).
    """
    early = owned_placements(client)
    jobs = run_jobs_read(client, runs, early, now)
    if early is None:
        return jobs, None
    unsure = [run for run in runs if run.get("id") in jobs and run.get("id") not in early.runs
              and picked_unmarked(run, jobs[run["id"]])]
    if not unsure:
        return jobs, early
    late = owned_placements(client, pages=1)
    if late is None:
        return jobs, None
    return jobs, Placements(early.runs | late.runs, early.since)


def in_flight_ios_runs(client: Any, since: str, *, exclude_run_id: int | None) -> list[Mapping[str, Any]]:
    """In-flight test-ios.yml and ios-screenshots.yml runs created at or after `since` (four requests).

    Asked for by status, so completed runs never fill the one page of 100 a
    long window would need (505 test-ios.yml runs in 6 hours on 2026-09-25).
    """
    return [run for workflow in IOS_WORKFLOWS for status in ("in_progress", "queued")
            for run in client.runs_since(workflow, since, status=status)
            if run.get("id") != exclude_run_id and run.get("status") != "completed"]


def ios_runs_since(client: Any, since: str, *, exclude_run_id: int | None,
                   placements: Placements | None = None, now: dt.datetime | None = None) -> int:
    """Simulator jobs of in-flight test-ios.yml and ios-screenshots.yml runs created at or after `since`.

    Two requests. Each run is charged charged_sim_jobs(); ios-screenshots.yml
    titles never parse, so a capture is charged in full.
    """
    return sum(charged_sim_jobs(run, placements, now)
               for workflow in IOS_WORKFLOWS for run in client.runs_since(workflow, since)
               if run.get("id") != exclude_run_id and run.get("status") != "completed")


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--lane", required=True, choices=sorted(LANES))
    parser.add_argument("--requested", default="", help="the workflow's runner input")
    parser.add_argument("--fork", default="", help="'true' for a pull request from a fork")
    parser.add_argument("--variable", default="", help="the lane's runner variable")
    parser.add_argument("--ios-owned", default="", help=f"vars.{IOS_OWNED_VARIABLE}")
    parser.add_argument("--owned", default="", help=f"vars.{pr_runner_pool.OWNED_VARIABLE}")
    parser.add_argument("--owned-slots", default="", help=f"vars.{pr_runner_pool.SLOTS_VARIABLE}")
    parser.add_argument("--pr-xcode-app", default="", help=f"vars.{pr_runner_pool.PR_XCODE_VARIABLE}")
    parser.add_argument("--order", default="", help=f"vars.{pr_runner_pool.ORDER_VARIABLE}")
    parser.add_argument("--max-queued", default="", help=f"vars.{pr_runner_pool.MAX_QUEUED_VARIABLE}")
    parser.add_argument("--queue-rounds", default=None,
                        help=f"vars.{pr_runner_pool.QUEUE_ROUNDS_VARIABLE} (\"\" is its default; omitted is 0)")
    parser.add_argument("--ios-version", default="", help="the workflow's ios_version input")
    parser.add_argument("--device-family", default="", help="the workflow's device_family input")
    parser.add_argument("--swift-package", default="", help="the workflow's swift_package input")
    parser.add_argument("--seed-cache", default="", help="the workflow's seed_cache input")
    parser.add_argument("--upload", default="", help="'true' for an App Store upload")
    parser.add_argument("--called", default="", help="'true' when another workflow called this one")
    args = parser.parse_args(argv)

    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
    run_id = (env.get("GITHUB_RUN_ID") or "").strip()
    exclude = int(run_id) if run_id.isdigit() else None
    now = dt.datetime.now(dt.timezone.utc)

    route_token = (env.get("ROUTE_TOKEN") or "").strip()

    def measure() -> IOSLoad:
        if not token or not repo:
            raise RuntimeError("GH_TOKEN and GH_REPO are required")
        client = pr_runner_pool.GitHub(token, repo)
        pools = pr_runner_pool.owned_pools(args.pr_xcode_app)
        if route_token and pools:
            try:
                runners = pr_runner_pool.GitHub(route_token, repo).runners()
                since = pr_runner_pool.iso(now - dt.timedelta(minutes=SIM_WINDOW_MINUTES))
                recent = in_flight_ios_runs(client, since, exclude_run_id=exclude)
                capacity = pr_runner_pool.capability_slots(args.owned_slots).get(SIM_LABEL, 0)
                jobs, placements = live_placements(client, recent, now)
                return IOSLoad(None, live=live_free(runners, pools[0], recent, now=now, capacity=capacity,
                                                    placements=placements, jobs=jobs))
            except Exception as error:  # noqa: BLE001 - the snapshot path still decides
                print(f"::warning title=live owned capacity::could not list runners ({error}); using the snapshot",
                      file=sys.stderr)
        load = e2e_runner_pool.measure_load(client, now=now, exclude_run_id=exclude)
        if load is None:
            return IOSLoad(None)
        return IOSLoad(load, ios_runs_since(client, str(load.snapshot["generated_at"]), exclude_run_id=exclude,
                                            placements=owned_placements(client), now=now))

    def log(message: str) -> None:
        print(message, file=sys.stderr)

    try:
        route = resolve(
            args.lane, args.requested, args.variable,
            ios_owned=args.ios_owned, owned=args.owned, owned_slots=args.owned_slots,
            pr_xcode_app=args.pr_xcode_app, order=args.order, max_queued=args.max_queued,
            queue_rounds=args.queue_rounds,
            ios_version=args.ios_version, device_family=args.device_family,
            swift_package=args.swift_package, upload=args.upload, called=args.called,
            seed_cache=args.seed_cache,
            measure=measure, now=now, log=log, fork=args.fork.strip() == "true",
        )
    except ValueError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 1
    print(f"label={route.label}")
    print(f"retry_label={route.retry_label}")
    print(f"runs_on={route.runs_on}")
    print(f"package_runs_on={route.package_runs_on}")
    print(f"retry_runs_on={route.retry_runs_on}")
    print(f"persistent={'true' if route.persistent else 'false'}")
    print(f"jobs={run_jobs(args.lane, args.swift_package)}")
    print(f"sim_jobs={sim_jobs(args.lane, args.device_family, args.swift_package)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
