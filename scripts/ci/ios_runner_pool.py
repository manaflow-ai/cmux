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
while its jobs start there within that many job lengths and no later than on
the best Blacksmith pool, and the queue stays within machines x (1 + rounds)
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
is read from the runners API instead of estimated: the owned pool's runners
that are online and not busy (pr_runner_pool.live_owned_free()), and of those
the ones that also carry SIM_LABEL, less what the test-ios.yml and
ios-screenshots.yml runs created in the last
pr_runner_pool.LIVE_WINDOW_MINUTES and still in flight will take (their jobs
may not have reached a runner yet). The run takes the pool `runner: owned`
takes when both counts cover it; otherwise it keeps the default. The janitor
snapshot and CI_OWNED_POOL_SLOTS are not read. On 2026-09-25 the snapshot
estimate, which charges every newer pull request run it cannot place,
counted the owned pool full while 20 of its runners sat idle. Without the
token, or when the runners cannot be listed, the snapshot rules below decide.

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
whose title does not parse, or that is still `auto` wherever it went, is
charged in full. Both err toward Blacksmith.

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
of the two iOS workflows. Anything uncertain keeps the default.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import json
import os
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
            if not label.startswith(pr_runner_pool.ROOT_PREFIX)}


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
        if pools and load.live.pool >= jobs and load.live.sim >= needed:
            log(f"live: {load.live.pool} owned runner(s) and {load.live.sim} {SIM_LABEL} free, {jobs} and "
                f"{needed} needed -> {pools[0]} with {SIM_LABEL}")
            return Route(pools[0], retry_label(default), True)
        log(f"live: {load.live.pool} owned runner(s) and {load.live.sim} {SIM_LABEL} free, {jobs} and "
            f"{needed} needed; staying on {default}")
        return ephemeral(default)
    try:
        choice = e2e_runner_pool.decide(load.pool, limits, now=now,
                                        owned_slots=pool_slots(owned_slots, pr_xcode_app),
                                        jobs=run_jobs(lane, swift_package))
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


def charged_sim_jobs(run: Mapping[str, Any]) -> int:
    """The simulator jobs an in-flight iOS run may hold, read from its title; in full when unsure."""
    title = str(run.get("display_title") or "")
    fields = title.split(TITLE_SEPARATOR)
    if not title.startswith(TITLE_PREFIX) or len(fields) != 7 or not fields[6].startswith("on "):
        return MAX_SIM_JOBS
    runner = fields[6][len("on "):].strip()
    if runner not in ("", "auto", OWNED_CHOICE):
        # Dispatched to a named pool (Blacksmith, Tart): never an owned simulator.
        return 0
    package = "" if fields[2] == "simulator" else fields[2]
    return sim_jobs("test-ios", fields[4], package)


def charged_jobs(run: Mapping[str, Any]) -> int:
    """The owned machines an in-flight iOS run may hold, read from its title; in full when unsure."""
    title = str(run.get("display_title") or "")
    fields = title.split(TITLE_SEPARATOR)
    if not title.startswith(TITLE_PREFIX) or len(fields) != 7 or not fields[6].startswith("on "):
        return LANES["test-ios"].jobs
    if fields[6][len("on "):].strip() not in ("", "auto", OWNED_CHOICE):
        return 0
    return run_jobs("test-ios", "" if fields[2] == "simulator" else fields[2])


def live_free(runners: Sequence[Mapping[str, Any]], pool: str, recent: Sequence[Mapping[str, Any]]) -> LiveFree:
    """The pool's idle runners and its idle SIM_LABEL runners, less what `recent` in-flight iOS runs will take."""
    mine = [runner for runner in runners
            if pool in {str(item.get("name")) for item in runner.get("labels") or [] if isinstance(item, Mapping)}]
    idle = pr_runner_pool.live_owned_free(mine, (pool, SIM_LABEL))
    return LiveFree(pool=idle[pool] - sum(charged_jobs(run) for run in recent),
                    sim=idle[SIM_LABEL] - sum(charged_sim_jobs(run) for run in recent))


def in_flight_ios_runs(client: Any, since: str, *, exclude_run_id: int | None) -> list[Mapping[str, Any]]:
    """In-flight test-ios.yml and ios-screenshots.yml runs created at or after `since` (two requests)."""
    return [run for workflow in IOS_WORKFLOWS for run in client.runs_since(workflow, since)
            if run.get("id") != exclude_run_id and run.get("status") != "completed"]


def ios_runs_since(client: Any, since: str, *, exclude_run_id: int | None) -> int:
    """Simulator jobs of in-flight test-ios.yml and ios-screenshots.yml runs created at or after `since`.

    Two requests. Each run is charged charged_sim_jobs(); ios-screenshots.yml
    titles never parse, so a capture is charged in full.
    """
    return sum(charged_sim_jobs(run) for workflow in IOS_WORKFLOWS for run in client.runs_since(workflow, since)
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
                since = pr_runner_pool.iso(now - dt.timedelta(minutes=pr_runner_pool.LIVE_WINDOW_MINUTES))
                recent = in_flight_ios_runs(client, since, exclude_run_id=exclude)
                return IOSLoad(None, live=live_free(runners, pools[0], recent))
            except Exception as error:  # noqa: BLE001 - the snapshot path still decides
                print(f"::warning title=live owned capacity::could not list runners ({error}); using the snapshot",
                      file=sys.stderr)
        load = e2e_runner_pool.measure_load(client, now=now, exclude_run_id=exclude)
        if load is None:
            return IOSLoad(None)
        return IOSLoad(load, ios_runs_since(client, str(load.snapshot["generated_at"]), exclude_run_id=exclude))

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
