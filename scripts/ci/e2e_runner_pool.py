#!/usr/bin/env python3
"""Pick the macOS pool a dispatch run lands on.

iroh-release-gate.yml runs this, and ios_runner_pool.py (test-ios.yml,
ios-screenshots.yml) calls its decide(), so every dispatch that offers a job
to the owned Macs applies one rule.

`runner: auto` means `vars.MACOS_RUNNER_TESTS` when it names a pool, else the
6vcpu macOS 26 pool. On that default an E2E run takes a pool by the rule pull
request CI uses (pr_runner_pool.py, whose decide() this calls), limited to the
macOS 26 pools:

    order     vars.CI_PR_POOL_ORDER without its macOS 15 pool; by default
                blacksmith-12vcpu-macos-26, then blacksmith-6vcpu-macos-26
    headroom  a machine free on that label's Blacksmith plan capacity, or at most
              vars.CI_PR_POOL_MAX_QUEUED jobs queued (default 0), and no
              queued release or nightly job on the pool

When neither pool has headroom the run takes the shorter queue in rounds.
Every Blacksmith pool is sponsored, so cost is not a reason to hold the
12vcpu pool back: a release or nightly job actually queued on it is the only
thing that keeps E2E off it (release and nightly builds must not wait behind
E2E). E2E never goes to macOS 15, whose Xcode differs from the macOS 26 lane
E2E answers for.

The queue comes from the queue janitor's `macos-pool-load` snapshot, the one
pull request CI reads (only a copy uploaded by a run on main counts). Runs
created since the snapshot are replayed before choosing, one job each:
in-flight pull request CI runs through the pull request rule over its whole
order (or on their lane, when the snapshot's copied settings show pull
request routing off). The replay treats macOS 15 as usable without checking
its Xcode pin, so it can lean slightly toward macOS 26 headroom.

API budget: at most three requests per decision, never retried or polled (the
artifact listing, its download, and one page of pull request CI runs since
the snapshot), plus one for the pull request runs of the live
window when the runners are read live (below). The GITHUB_TOKEN allows about 1000 requests an hour
for the whole repository, so listing jobs here is out of reach.

Anything uncertain stays on the 6vcpu default: an API error, a missing, stale
or malformed snapshot, an order with no macOS 26 pool, or an invalid setting.
`vars.CI_E2E_LARGE_POOL_OVERFLOW == '0'` turns the choice off without reading
the queue. An explicit runner, or a variable naming any other pool, is never
rerouted.

Owned Macs (glaeda-<class>-xcode-<version>, pr_runner_pool.persistent) join
the choice exactly as they do for pull requests: only when
`vars.CI_PR_POOL_OWNED == '1'`, only the labels for the lane's Xcode pin
(vars.CMUX_CI_XCODE_APP_PR), ahead of Blacksmith, on a snapshot younger than
pr_runner_pool.MAX_SNAPSHOT_MINUTES, and by pull request CI's queue rule
(vars.CI_PR_POOL_QUEUE_ROUNDS, `--queue-rounds`): an owned pool takes the run
while its job starts there within that many job lengths, whatever
Blacksmith's wait, and the queue stays within machines x (1 + rounds)
(pr_runner_pool.owned_room()). Without the rounds the picker used the kill
switch rule, which counts every in-flight run's whole future peak (the
janitor's `committed`) as taken now: on 2026-09-25 that read 43 of 32 std
machines taken while 8 ran (run 36136190497, an iOS run on this rule).
`--queue-rounds 0` restores it; a caller that omits the flag gets it too.
The rounds decide only whether an owned pool takes the run: when none does,
the Blacksmith pool is chosen by the headroom rule above, as before.
An E2E run holds one machine at a time
(build, then test), so it needs one free machine. glaeda gives both jobs the
mini's canonical-root token, so when CI_OWNED_POOL_SLOTS gives the pool a root
count (pr_runner_pool.root_label()) the run takes the root label and needs a
free root runner as well. An owned pool is never the
fewest-queued fallback: with no room within the rounds the run takes Blacksmith. A job
that waits on, or is refused by, an owned Mac is re-run by
ci-owned-pool-rescue.yml. A re-run that keeps attempt 1's pick, and every
attempt from 3 on, takes retry_runner(); a full re-run's attempt 2 takes its
own new pick (test-e2e.yml's `picked_attempt`). That holds for an explicit
owned runner too.

Live owned capacity: with the org App's token (ROUTE_TOKEN; the calling
workflow mints it for this repository's runs while owned pools are on), the owned pools are
counted from the runners API as pull request CI counts them
(pr_runner_pool.live_owned_free, live_online and live_pools): idle runners
carrying the label are its free machines, and the online ones its capacity.
An App without the organization runners permission gets a repository-only
token (the workflow's second mint), as pull request CI does. Only the pull request runs of the last
pr_runner_pool.LIVE_WINDOW_MINUTES are charged to the owned pools, since an
older run's jobs are already on runners and show busy there; the rest of the
snapshot window counts on the Blacksmith pools only. Without the token, or on
any error listing runners, the snapshot decides as before. The listing uses
the App's own request budget, not the GITHUB_TOKEN's.
"""
from __future__ import annotations

import argparse
import dataclasses
import json
import datetime as dt
import os
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
import sys
from typing import Any, Protocol

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_runner_pool  # noqa: E402
import simple_pool_picker  # noqa: E402

SMALL_RUNNER = pr_runner_pool.DEFAULT_RUNNER
LARGE_RUNNER = pr_runner_pool.LARGE_RUNNER
# The Blacksmith pools E2E may take, all macOS 26. Owned pools for the lane's
# Xcode pin join them when CI_PR_POOL_OWNED is 1 (e2e_pool()).
E2E_POOLS = (LARGE_RUNNER, SMALL_RUNNER)
# Most machines one E2E run holds at once: the build job, then the test job.
E2E_JOBS = 1

# Repository variables. The kill switch turns the choice off when set to "0";
# the order and threshold are pull request CI's own.
OVERFLOW_VARIABLE = "CI_E2E_LARGE_POOL_OVERFLOW"
ORDER_VARIABLE = pr_runner_pool.ORDER_VARIABLE
MAX_QUEUED_VARIABLE = pr_runner_pool.MAX_QUEUED_VARIABLE
QUEUE_ROUNDS_VARIABLE = pr_runner_pool.QUEUE_ROUNDS_VARIABLE
OWNED_VARIABLE = pr_runner_pool.OWNED_VARIABLE
SLOTS_VARIABLE = pr_runner_pool.SLOTS_VARIABLE
PR_XCODE_VARIABLE = pr_runner_pool.PR_XCODE_VARIABLE

# The whole API budget of one decision; see the module docstring.
MAX_API_CALLS = 3


@dataclasses.dataclass(frozen=True)
class PoolLoad:
    snapshot: Mapping[str, Any]
    # In-flight pull request CI runs created since the snapshot.
    pull_requests_since: int = 0
    # Idle runners per owned label, read live (None: the snapshot decides),
    # the online ones (its capacity; None: the slot counts), and the pull
    # request runs of the live window, the only ones charged to an owned pool then.
    live_owned: Mapping[str, int] | None = None
    live_online: Mapping[str, int] | None = None
    pull_requests_recent: int = 0


class ApiClient(Protocol):
    """pr_runner_pool.GitHub, or anything with the same shape."""

    def snapshot(self, *, now: dt.datetime) -> Mapping[str, Any] | None: ...

    def pull_request_runs_since(self, since: str, *, exclude_run_id: int | None) -> int: ...


def enabled(value: str | None) -> bool:
    """Whether the choice is on. Unset or anything but "0" is on."""
    return (value or "").strip() != "0"


def settings(order: str | None, max_queued: str | None, owned: str | None = None,
             pr_xcode_app: str | None = None, queue_rounds: str | None = None) -> pr_runner_pool.Settings | None:
    """Pull request CI's order and threshold; None when either is invalid.

    Owned pools stay in the order only when `owned` is "1", and only for the
    lane's Xcode pin, exactly as for pull requests. `queue_rounds` is
    CI_PR_POOL_QUEUE_ROUNDS ("" when unset, the default); None, from a caller
    that never reads it, means no rounds (pr_runner_pool.settings()).
    """
    return pr_runner_pool.settings(None, order, max_queued, owned, pr_xcode_app, queue_rounds)


def e2e_pool(label: str) -> bool:
    """A pool an E2E run may take: a macOS 26 Blacksmith pool or an owned one."""
    return label in E2E_POOLS or pr_runner_pool.persistent(label)


def retry_runner(label: str) -> str:
    """The pool a re-run attempt takes: never an owned one, which may be why it is re-run."""
    return SMALL_RUNNER if pr_runner_pool.persistent(label) else label


def measure_load(client: ApiClient, *, now: dt.datetime, exclude_run_id: int | None = None,
                 live_owned: Mapping[str, int] | None = None,
                 live_online: Mapping[str, int] | None = None) -> PoolLoad | None:
    """The janitor snapshot and the runs since it, or None when there is no usable snapshot.

    With `live_owned` (idle runners per owned label; `live_online`, the online
    ones), the runs of the live window are counted too. Raises (from the client) on an API failure.
    """
    snapshot = client.snapshot(now=now)
    if not isinstance(snapshot, Mapping) or not snapshot.get("generated_at"):
        return None
    since = str(snapshot["generated_at"])
    load = PoolLoad(snapshot, client.pull_request_runs_since(since, exclude_run_id=exclude_run_id))
    if live_owned is None:
        return load
    window = pr_runner_pool.iso(now - dt.timedelta(minutes=pr_runner_pool.LIVE_WINDOW_MINUTES))
    return dataclasses.replace(
        load, live_owned=live_owned, live_online=live_online,
        pull_requests_recent=client.pull_request_runs_since(window, exclude_run_id=exclude_run_id),
    )


def decide(load: PoolLoad | None, limits: pr_runner_pool.Settings, *, now: dt.datetime,
           owned_slots: Mapping[str, int] | None = None, jobs: int = E2E_JOBS,
           owned_choices: Sequence[str] | None = None) -> pr_runner_pool.Choice:
    """The pull request rule over the macOS 26 and owned pools. An empty runner keeps the default.

    `jobs` is the most machines one run holds at once (E2E_JOBS for an E2E
    run); ios_runner_pool.py passes its own lane's peak. `owned_choices`
    limits which owned pools the run itself may take (None: any), while
    the replay of newer runs still spreads over the whole order.
    """
    if load is None:
        return pr_runner_pool.Choice("", "", "no readable pool snapshot")
    pools = [label for label in limits.order if e2e_pool(label)]
    if not pools:
        return pr_runner_pool.Choice("", "", f"{ORDER_VARIABLE} names no macOS 26 pool")
    snapshot, capacity = live_view(load, owned_slots)
    live = load.live_owned is not None
    placed: dict[str, int] = {}
    routed, ephemeral = load.pull_requests_since, 0
    if live:
        # Only the window's pull request runs may still take an owned machine;
        # the older ones count on the Blacksmith pools only.
        routed = min(routed, load.pull_requests_recent)
        ephemeral = load.pull_requests_since - routed
    lane = pr_routing_off(load.snapshot)
    if lane is not None:
        # Pull request runs are not being routed, so each stays on its lane.
        placed[lane] = placed.get(lane, 0) + routed + ephemeral
        routed = ephemeral = 0
    def rule(settings: pr_runner_pool.Settings, choose_from: list[str]) -> pr_runner_pool.Choice:
        return pr_runner_pool.decide(
            snapshot, settings, now=now, xcode_pins={},
            routed_since=routed, ephemeral_since=ephemeral, auto_xcode=True,
            placed=placed, choose_from=choose_from,
            owned_slots=capacity, jobs=jobs, root_jobs=jobs,
        )

    chosen_from = [label for label in pools if owned_choices is None or
                   not pr_runner_pool.persistent(label) or label in owned_choices]
    choice = rule(limits, chosen_from)
    blacksmith = [label for label in pools if not pr_runner_pool.persistent(label)]
    if limits.queue_rounds and blacksmith and choice.runner and not pr_runner_pool.persistent(choice.runner):
        # The rounds decide only whether an owned pool takes the run; the
        # Blacksmith pool is the headroom rule's, as without them (the first
        # pool with a free machine, then the shorter queue in rounds).
        choice = rule(dataclasses.replace(limits, queue_rounds=0), blacksmith)
        # Name the owned pools this run could take: one owned_choices left
        # out (the iOS lane's light pool) was not full, only not allowed.
        allowed = [label for label in chosen_from if pr_runner_pool.persistent(label)]
        if allowed:
            which = "no owned pool" if owned_choices is None else f"no room on {', '.join(allowed)}"
            choice = dataclasses.replace(choice, reason=f"{which} within {limits.queue_rounds} queue "
                                                        f"round(s); {choice.reason}")
    if live and pr_runner_pool.persistent(choice.runner):
        choice = dataclasses.replace(choice, reason=f"{choice.reason}; owned machines read live from the runners API")
    return choice


def live_view(load: PoolLoad, owned_slots: Mapping[str, int] | None) -> tuple[Mapping[str, Any], dict[str, int]]:
    """The snapshot and owned capacities decide() reads: the owned counts read live when the runners were.

    Idle runners replace the snapshot's owned counts, and online ones the
    slot counts, as pull request CI reads them (pr_runner_pool.choose). No
    older runs are passed (`older={}`): a fully busy owned label is not
    charged the queued jobs of pull request runs from before the live
    window, so it may look shorter than it is; ci-owned-pool-rescue.yml
    moves a job that then waits too long.
    """
    capacity = dict(owned_slots or {})
    if load.live_owned is None:
        return load.snapshot, capacity
    return pr_runner_pool.live_pools(load.snapshot, load.live_owned or {}, capacity, {}, load.live_online)


def pr_routing_off(snapshot: Mapping[str, Any]) -> str | None:
    """The lane pull request runs stay on when the janitor saw their routing off, else None.

    The janitor copies MACOS_RUNNER_PR and the CI_PR_POOL_* variables into the
    snapshot. Routing is off when the kill switch is 0 or the lane is not the
    6vcpu macOS 26 pool; the runs then use the lane (or its 6vcpu fallback).
    """
    copied = snapshot.get("settings")
    if not isinstance(copied, Mapping):
        return None
    lane = str(copied.get("lane") or "").strip()
    if (str(copied.get("overflow") or "").strip() == "0") or (lane and lane != SMALL_RUNNER):
        return lane or SMALL_RUNNER
    return None


def auto_runner(
    default: str | None,
    *,
    enabled: bool,
    limits: pr_runner_pool.Settings | None,
    measure: Callable[[], PoolLoad | None],
    now: dt.datetime,
    log: Callable[[str], None] = lambda message: None,
    owned_slots: Mapping[str, int] | None = None,
) -> str | None:
    """The pool an unpinned run lands on, given what `auto` means.

    Only the 6vcpu macOS 26 default is routed. None stays None: a caller that
    could not establish the default must not act on a guess. `measure` is
    called only when routing is possible, and any error it raises keeps the
    default.
    """
    if default != SMALL_RUNNER:
        return default
    if not enabled:
        log(f"{OVERFLOW_VARIABLE}=0; staying on {SMALL_RUNNER}")
        return default
    if limits is None:
        log(f"invalid {ORDER_VARIABLE}, {MAX_QUEUED_VARIABLE} or {QUEUE_ROUNDS_VARIABLE}; staying on {SMALL_RUNNER}")
        return default
    if not any(e2e_pool(label) for label in limits.order):
        log(f"{ORDER_VARIABLE} names no macOS 26 pool; staying on {SMALL_RUNNER}")
        return default
    try:
        load = measure()
        choice = decide(load, limits, now=now, owned_slots=owned_slots)
        if not choice.runner:
            log(f"{choice.reason}; staying on {SMALL_RUNNER}")
            return default
        shown = [label for label in limits.order if pr_runner_pool.persistent(label)] + list(E2E_POOLS)
        # The counts decide() read: live for the owned labels when the runners were read.
        seen, capacity = live_view(load, owned_slots)
        queue = "; ".join(pr_runner_pool.describe(seen, label, capacity) for label in shown)
    except Exception as error:  # noqa: BLE001 - every failure is fail-safe
        log(f"could not read the runner queue ({error}); staying on {SMALL_RUNNER}")
        return default
    # glaeda gives an E2E job, which it does not know, the mini's root token,
    # so a pool with a root count sends it to its root runners.
    runner = choice.root_runner or choice.runner
    log(f"{choice.reason} -> {runner} (janitor saw {queue})")
    return runner


def resolve(
    requested: str | None,
    variable: str | None,
    *,
    overflow: str | None,
    order: str | None,
    max_queued: str | None,
    measure: Callable[[], PoolLoad | None],
    now: dt.datetime,
    log: Callable[[str], None] = lambda message: None,
    owned: str | None = None,
    owned_slots: str | None = None,
    pr_xcode_app: str | None = None,
    queue_rounds: str | None = None,
) -> str:
    """The runner label for a workflow run, from its inputs and variables."""
    requested = (requested or "").strip()
    if requested and requested != "auto":
        # An owned pool asked for by name still takes its root runners, as auto_runner() does: glaeda gives
        # the build a canonical root, and only the root runners' gate keeps a root free for what they take.
        # On the pool label a non-root runner took the build, and E2E builds on two of them held both of a
        # mini's roots while its root runner's compile admission waited (2026-09-28, cmux10s).
        root = pr_runner_pool.root_label(requested)
        if root and pr_runner_pool.slots(owned_slots, pr_xcode_app).get(root, 0) > 0:
            log(f"{requested} -> {root} (an E2E build takes a canonical root)")
            return root
        return requested
    default = (variable or "").strip() or SMALL_RUNNER
    return auto_runner(
        default,
        enabled=enabled(overflow),
        limits=settings(order, max_queued, owned, pr_xcode_app, queue_rounds),
        measure=measure,
        now=now,
        log=log,
        owned_slots=pr_runner_pool.slots(owned_slots, pr_xcode_app),
    ) or SMALL_RUNNER


def read_live_runners(repo: str, env: Mapping[str, str], owned: str | None,
                      pr_xcode_app: str | None) -> list[Mapping[str, Any]] | None:
    """The repository's runners from the runners API, or None.

    Needs the org App's token (ROUTE_TOKEN), owned pools on and a pin that
    names an owned pool; any error leaves the snapshot and CI_OWNED_POOL_SLOTS to decide.
    """
    token = (env.get("ROUTE_TOKEN") or "").strip()
    if not token or not repo or (owned or "").strip() != "1" or not pr_runner_pool.owned_pools(pr_xcode_app):
        return None
    try:
        return pr_runner_pool.GitHub(token, repo).runners()
    except Exception as error:  # noqa: BLE001 - the snapshot path still decides
        print(f"could not list runners ({error}); using the snapshot", file=sys.stderr)
        return None


def live_owned(runners: Sequence[Mapping[str, Any]] | None,
               pr_xcode_app: str | None) -> tuple[dict[str, int], dict[str, int]] | None:
    """Idle and online runners per owned label (and its root label), or None without a listing."""
    if runners is None:
        return None
    labels = pr_runner_pool.owned_pools(pr_xcode_app)
    labels += tuple(pr_runner_pool.root_label(label) for label in labels)
    return pr_runner_pool.live_owned_free(runners, labels), pr_runner_pool.live_online(runners, labels)


def read_live_owned(repo: str, env: Mapping[str, str], owned: str | None,
                    pr_xcode_app: str | None) -> tuple[dict[str, int], dict[str, int]] | None:
    """Idle and online runners per owned label (and its root label) from the runners API, or None."""
    return live_owned(read_live_runners(repo, env, owned, pr_xcode_app), pr_xcode_app)


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--requested", default="", help="the workflow's runner input")
    parser.add_argument("--variable", default="", help="vars.MACOS_RUNNER_TESTS")
    parser.add_argument("--overflow", default="", help=f"vars.{OVERFLOW_VARIABLE}")
    parser.add_argument("--order", default="", help=f"vars.{ORDER_VARIABLE}")
    parser.add_argument("--max-queued", default="", help=f"vars.{MAX_QUEUED_VARIABLE}")
    parser.add_argument("--queue-rounds", default=None,
                        help=f"vars.{QUEUE_ROUNDS_VARIABLE} (\"\" is its default; omitted is 0)")
    parser.add_argument("--owned", default="", help=f"vars.{OWNED_VARIABLE}")
    parser.add_argument("--owned-slots", default="", help=f"vars.{SLOTS_VARIABLE}")
    parser.add_argument("--pr-xcode-app", default="", help=f"vars.{PR_XCODE_VARIABLE}")
    parser.add_argument("--retry-of", help="print the pool a re-run of this label takes, and nothing else")
    args = parser.parse_args(argv)

    # Auto choices use the shared live rule. Explicit labels retain the
    # workflow's direct-request contract and its validation below.
    # The shared simple picker has no test-filter or console-session
    # semantics. Let UI E2E runs reach resolve(), which applies the owned GUI
    # override before choosing a Blacksmith fallback.
    if (not args.retry_of and (args.requested or "auto").strip() == "auto"
            and not ui_run(args.test_filter)):
        values = dict(env)
        values.update({"CI_PR_POOL_OWNED": args.owned, "CI_OWNED_POOL_SLOTS": args.owned_slots,
                       "CI_PR_POOL_OVERFLOW": args.overflow, "MACOS_RUNNER_PR": args.variable,
                       "CMUX_CI_XCODE_APP_PR": args.pr_xcode_app})
        choice = simple_pool_picker.pick(simple_pool_picker.observe(
            token=values.get("ROUTE_TOKEN") or values.get("GH_TOKEN") or "",
            repository=values.get("GH_REPO") or values.get("GITHUB_REPOSITORY") or "",
            jobs=1, env=values,
            fork=values.get("FORK_PULL_REQUEST") == "true"
            or (values.get("HEAD_REPO") or values.get("GITHUB_REPOSITORY"))
            != (values.get("GH_REPO") or values.get("GITHUB_REPOSITORY"))))
        print(choice.label or args.variable or SMALL_RUNNER)
        return 0
    if args.retry_of is not None:
        print(retry_runner(args.retry_of.strip()))
        return 0

    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
    run_id = (env.get("GITHUB_RUN_ID") or "").strip()
    now = dt.datetime.now(dt.timezone.utc)

    runners = read_live_runners(repo, env, args.owned, args.pr_xcode_app)
    # Which owned labels route (a pool, its root label): the online runners when they were read,
    # CI_OWNED_POOL_SLOTS only when they could not be (pr_runner_pool.routing_slots()).
    owned_slots = (args.owned_slots if runners is None else
                   json.dumps(pr_runner_pool.routing_slots(args.owned_slots, args.pr_xcode_app, runners)))

    def measure() -> PoolLoad | None:
        if not token or not repo:
            raise RuntimeError("GH_TOKEN and GH_REPO are required")
        idle, online = live_owned(runners, args.pr_xcode_app) or (None, None)
        return measure_load(pr_runner_pool.GitHub(token, repo), now=now,
                            exclude_run_id=int(run_id) if run_id.isdigit() else None,
                            live_owned=idle, live_online=online)

    print(resolve(
        args.requested, args.variable,
        overflow=args.overflow, order=args.order, max_queued=args.max_queued,
        owned=args.owned, owned_slots=owned_slots, pr_xcode_app=args.pr_xcode_app,
        queue_rounds=args.queue_rounds,
        measure=measure, now=now,
        log=lambda message: print(message, file=sys.stderr),
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
