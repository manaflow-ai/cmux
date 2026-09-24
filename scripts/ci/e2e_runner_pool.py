#!/usr/bin/env python3
"""Pick the macOS pool an E2E run lands on.

test-e2e.yml and scripts/ci/dispatch-focused-test.py both call this, so a
workflow started from the Actions UI, `gh workflow run`, or run-e2e.sh applies
one rule.

`runner: auto` means `vars.MACOS_RUNNER_TESTS` when it names a pool, else the
6vcpu macOS 26 pool. On that default an E2E run takes a pool by the rule pull
request CI uses (pr_runner_pool.py, whose decide() this calls), limited to the
macOS 26 pools:

    order     vars.CI_PR_POOL_ORDER without its macOS 15 pool; by default
                blacksmith-12vcpu-macos-26, then blacksmith-6vcpu-macos-26
    headroom  fewer than vars.CI_PR_POOL_MAX_QUEUED jobs queued (default 3)
              and no queued release or nightly job on the pool

When neither pool has headroom the run takes the one with fewer queued jobs.
Every Blacksmith pool is sponsored, so cost is not a reason to hold the
12vcpu pool back: a release or nightly job actually queued on it is the only
thing that keeps E2E off it (release and nightly builds must not wait behind
E2E). E2E never goes to macOS 15, whose Xcode and app-host tests differ from
the macOS 26 lane E2E answers for.

The queue comes from the queue janitor's `macos-pool-load` snapshot, the one
pull request CI reads (only a copy uploaded by a run on main counts). Runs
created since the snapshot are replayed before choosing, one job each:
in-flight E2E runs on the pool their title names ("<filter> on <runner> @
<ref>"), and in-flight pull request CI runs through the pull request rule
over its whole order (or on their lane, when the snapshot's copied settings
show pull request routing off). The replay treats macOS 15 as usable without
checking its Xcode pin, so it can lean slightly toward macOS 26 headroom. A 6vcpu `auto` run started from the Actions UI is
titled with the default (run-name cannot read job outputs), so it counts
there wherever it landed; run-e2e.sh names its pool, so its titles are exact.

API budget: at most four requests per decision, never retried or polled (the
artifact listing, its download, and one page each of E2E and pull request CI
runs since the snapshot). The GITHUB_TOKEN allows about 1000 requests an hour
for the whole repository, so listing jobs here is out of reach.

Anything uncertain stays on the 6vcpu default: an API error, a missing, stale
or malformed snapshot, an order with no macOS 26 pool, or an invalid setting.
`vars.CI_E2E_LARGE_POOL_OVERFLOW == '0'` turns the choice off without reading
the queue. An explicit runner, or a variable naming any other pool, is never
rerouted.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import os
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
import re
import sys
from typing import Any, Protocol

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pr_runner_pool  # noqa: E402

SMALL_RUNNER = pr_runner_pool.DEFAULT_RUNNER
LARGE_RUNNER = pr_runner_pool.LARGE_RUNNER
# The pools E2E may take, all macOS 26.
E2E_POOLS = (LARGE_RUNNER, SMALL_RUNNER)
E2E_WORKFLOW = "test-e2e.yml"

# Repository variables. The kill switch turns the choice off when set to "0";
# the order and threshold are pull request CI's own.
OVERFLOW_VARIABLE = "CI_E2E_LARGE_POOL_OVERFLOW"
ORDER_VARIABLE = pr_runner_pool.ORDER_VARIABLE
MAX_QUEUED_VARIABLE = pr_runner_pool.MAX_QUEUED_VARIABLE

# The whole API budget of one decision; see the module docstring.
MAX_API_CALLS = 4
TITLE_RUNNER = re.compile(r" on (?P<runner>\S+) @ ")


@dataclasses.dataclass(frozen=True)
class PoolLoad:
    snapshot: Mapping[str, Any]
    # In-flight E2E runs created since the snapshot, by the pool each names.
    e2e_since: Mapping[str, int] = dataclasses.field(default_factory=dict)
    # In-flight pull request CI runs created since the snapshot.
    pull_requests_since: int = 0


class ApiClient(Protocol):
    """pr_runner_pool.GitHub, or anything with the same shape."""

    def snapshot(self, *, now: dt.datetime) -> Mapping[str, Any] | None: ...

    def runs_since(self, workflow: str, since: str, **filters: str) -> list[Mapping[str, Any]]: ...

    def pull_request_runs_since(self, since: str, *, exclude_run_id: int | None) -> int: ...


def enabled(value: str | None) -> bool:
    """Whether the choice is on. Unset or anything but "0" is on."""
    return (value or "").strip() != "0"


def settings(order: str | None, max_queued: str | None) -> pr_runner_pool.Settings | None:
    """Pull request CI's order and threshold; None when either is invalid."""
    return pr_runner_pool.settings(None, order, max_queued)


def title_runner(run: Mapping[str, Any]) -> str | None:
    """The pool an E2E run's title names, or None."""
    match = TITLE_RUNNER.search(str(run.get("display_title") or ""))
    return match.group("runner") if match else None


def e2e_by_pool(runs: Sequence[Mapping[str, Any]], *, exclude_run_id: int | None) -> dict[str, int]:
    counts: dict[str, int] = {}
    for run in runs:
        if run.get("id") == exclude_run_id or run.get("status") == "completed":
            continue
        runner = title_runner(run)
        if runner:
            counts[runner] = counts.get(runner, 0) + 1
    return counts


def measure_load(client: ApiClient, *, now: dt.datetime, exclude_run_id: int | None = None) -> PoolLoad | None:
    """The janitor snapshot and the runs since it, or None when there is no usable snapshot.

    Raises (from the client) on an API failure.
    """
    snapshot = client.snapshot(now=now)
    if not isinstance(snapshot, Mapping) or not snapshot.get("generated_at"):
        return None
    since = str(snapshot["generated_at"])
    return PoolLoad(
        snapshot,
        e2e_by_pool(client.runs_since(E2E_WORKFLOW, since), exclude_run_id=exclude_run_id),
        client.pull_request_runs_since(since, exclude_run_id=exclude_run_id),
    )


def decide(load: PoolLoad | None, limits: pr_runner_pool.Settings, *, now: dt.datetime) -> pr_runner_pool.Choice:
    """The pull request rule over the macOS 26 pools. An empty runner keeps the default."""
    if load is None:
        return pr_runner_pool.Choice("", "", "no readable pool snapshot")
    pools = [label for label in limits.order if label in E2E_POOLS]
    if not pools:
        return pr_runner_pool.Choice("", "", f"{ORDER_VARIABLE} names no macOS 26 pool")
    placed, routed = dict(load.e2e_since), load.pull_requests_since
    lane = pr_routing_off(load.snapshot)
    if lane is not None:
        # Pull request runs are not being routed, so each stays on its lane.
        placed[lane] = placed.get(lane, 0) + routed
        routed = 0
    return pr_runner_pool.decide(
        load.snapshot, limits, now=now, xcode_pins={},
        routed_since=routed, auto_xcode=True,
        placed=placed, choose_from=pools,
    )


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
        log(f"invalid {ORDER_VARIABLE} or {MAX_QUEUED_VARIABLE}; staying on {SMALL_RUNNER}")
        return default
    if not any(label in E2E_POOLS for label in limits.order):
        log(f"{ORDER_VARIABLE} names no macOS 26 pool; staying on {SMALL_RUNNER}")
        return default
    try:
        load = measure()
        choice = decide(load, limits, now=now)
        if not choice.runner:
            log(f"{choice.reason}; staying on {SMALL_RUNNER}")
            return default
        queue = "; ".join(pr_runner_pool.describe(load.snapshot, label) for label in E2E_POOLS)
    except Exception as error:  # noqa: BLE001 - every failure is fail-safe
        log(f"could not read the runner queue ({error}); staying on {SMALL_RUNNER}")
        return default
    log(f"{choice.reason} -> {choice.runner} (janitor saw {queue})")
    return choice.runner


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
) -> str:
    """The runner label for a workflow run, from its inputs and variables."""
    requested = (requested or "").strip()
    if requested and requested != "auto":
        return requested
    default = (variable or "").strip() or SMALL_RUNNER
    return auto_runner(
        default,
        enabled=enabled(overflow),
        limits=settings(order, max_queued),
        measure=measure,
        now=now,
        log=log,
    ) or SMALL_RUNNER


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--requested", default="", help="the workflow's runner input")
    parser.add_argument("--variable", default="", help="vars.MACOS_RUNNER_TESTS")
    parser.add_argument("--overflow", default="", help=f"vars.{OVERFLOW_VARIABLE}")
    parser.add_argument("--order", default="", help=f"vars.{ORDER_VARIABLE}")
    parser.add_argument("--max-queued", default="", help=f"vars.{MAX_QUEUED_VARIABLE}")
    args = parser.parse_args(argv)

    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
    run_id = (env.get("GITHUB_RUN_ID") or "").strip()
    now = dt.datetime.now(dt.timezone.utc)

    def measure() -> PoolLoad | None:
        if not token or not repo:
            raise RuntimeError("GH_TOKEN and GH_REPO are required")
        return measure_load(pr_runner_pool.GitHub(token, repo), now=now,
                            exclude_run_id=int(run_id) if run_id.isdigit() else None)

    print(resolve(
        args.requested, args.variable,
        overflow=args.overflow, order=args.order, max_queued=args.max_queued,
        measure=measure, now=now,
        log=lambda message: print(message, file=sys.stderr),
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
