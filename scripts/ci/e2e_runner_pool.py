#!/usr/bin/env python3
"""Pick the macOS pool an E2E run lands on.

test-e2e.yml and scripts/ci/dispatch-focused-test.py both call this, so a
workflow started from the Actions UI, `gh workflow run`, or run-e2e.sh applies
one rule.

`runner: auto` means `vars.MACOS_RUNNER_TESTS` when it names a pool, else the
6vcpu macOS 26 pool. The 12vcpu macOS 26 pool ("macOS large") is reserved
first for release and nightly builds (nightly.yml's build job, the release
workflows), so E2E must never be the reason it is backed up. An `auto` run on
the 6vcpu default therefore overflows to the 12vcpu pool only when the 6vcpu
pool is backed up and the 12vcpu pool has spare room:

    queued(6vcpu)  >= vars.CI_E2E_OVERFLOW_MIN_QUEUED        (default 4)
    queued(12vcpu) == 0
    running(12vcpu) < vars.CI_E2E_OVERFLOW_MAX_LARGE_RUNNING (default 2)

Anything else stays on the 6vcpu pool: any error reading the queue, a listing
that may be truncated, or an invalid threshold. `vars.CI_E2E_LARGE_POOL_OVERFLOW
== '0'` turns overflow off. An explicit runner, or a variable naming any other
pool, is never rerouted.

API budget: at most two requests per decision, never retried or polled. The
GITHUB_TOKEN allows about 1000 requests an hour for the whole repository and
E2E dispatches can run to dozens an hour, so the queue janitor's per-run job
listings (one request per in-flight run) are out of reach. The decision reads
one page of in-progress runs and one page of queued runs and attributes pool
demand from run metadata alone:

  * an E2E run's title names its pool ("<filter> on <runner> @ <ref>"), so an
    in-flight E2E run titled with the 12vcpu pool counts as running there, or
    queued there while the run itself is queued;
  * an in-flight release or nightly run (the queue janitor's reserved
    workflow names, minus workflows that never use macOS) counts as queued on
    the 12vcpu pool, so E2E yields to it whether or not its macOS job has
    started;
  * queued(6vcpu) is estimated as the other E2E runs in flight on the 6vcpu
    pool. That is E2E's own demand on the pool, not the pool's whole job
    queue, which only job listings can show.

The in-progress page is read first, and when it already rules overflow out
the queued page is never requested. A full page (100 runs) may hide more, so
it counts as unknown. A 6vcpu `auto` run started from the Actions UI that
overflowed is still titled 6vcpu (run-name cannot read job outputs), so it
counts as 6vcpu demand; run-e2e.sh names its pool, so its titles are exact.
"""
from __future__ import annotations

import argparse
import dataclasses
import os
from collections.abc import Callable, Mapping, Sequence
from pathlib import Path
import re
import sys
from typing import Any, Protocol

sys.path.insert(0, str(Path(__file__).resolve().parent))
import queue_janitor  # noqa: E402

SMALL_RUNNER = "blacksmith-6vcpu-macos-26"
LARGE_RUNNER = "blacksmith-12vcpu-macos-26"
E2E_WORKFLOW_PATH = ".github/workflows/test-e2e.yml"

# Repository variables. The kill switch turns overflow off when set to "0".
OVERFLOW_VARIABLE = "CI_E2E_LARGE_POOL_OVERFLOW"
MIN_QUEUED_VARIABLE = "CI_E2E_OVERFLOW_MIN_QUEUED"
MAX_LARGE_RUNNING_VARIABLE = "CI_E2E_OVERFLOW_MAX_LARGE_RUNNING"
DEFAULT_MIN_QUEUED = 4
DEFAULT_MAX_LARGE_RUNNING = 2

# The whole API budget of one decision; see the module docstring.
MAX_API_CALLS = 2
PAGE_SIZE = 100
# Workflows whose macOS jobs have first claim on the 12vcpu pool.
RESERVED_WORKFLOW = re.compile(r"release|nightly", re.IGNORECASE)
TITLE_RUNNER = re.compile(r" on (?P<runner>\S+) @ ")

WORKFLOWS_DIR = Path(__file__).resolve().parents[2] / ".github" / "workflows"


@dataclasses.dataclass(frozen=True)
class Thresholds:
    min_queued: int = DEFAULT_MIN_QUEUED
    max_large_running: int = DEFAULT_MAX_LARGE_RUNNING


@dataclasses.dataclass(frozen=True)
class PoolLoad:
    small_queued: int = 0
    large_queued: int = 0
    large_running: int = 0


class ApiClient(Protocol):
    """queue_janitor.GitHub's request(), or anything with the same shape."""

    def request(self, method: str, path: str) -> Any: ...


def overflow_enabled(value: str | None) -> bool:
    """Whether overflow is on. Unset or anything but "0" is on."""
    return (value or "").strip() != "0"


def thresholds(min_queued: str | None, max_large_running: str | None) -> Thresholds | None:
    """Thresholds from repository variables; None when either is invalid.

    Blank means the default. A minimum below one would send every run to the
    12vcpu pool whenever it is idle, so it counts as invalid, and an invalid
    value keeps E2E off the 12vcpu pool rather than guessing.
    """
    try:
        queued = int(min_queued) if (min_queued or "").strip() else DEFAULT_MIN_QUEUED
        running = (int(max_large_running) if (max_large_running or "").strip()
                   else DEFAULT_MAX_LARGE_RUNNING)
    except ValueError:
        return None
    if queued < 1 or running < 0:
        return None
    return Thresholds(queued, running)


def overflows(load: PoolLoad | None, limits: Thresholds) -> bool:
    """The overflow rule itself. An unknown load never overflows."""
    return (
        load is not None
        and load.small_queued >= limits.min_queued
        and load.large_queued == 0
        and load.large_running < limits.max_large_running
    )


def title_runner(run: Mapping[str, Any]) -> str | None:
    """The pool an E2E run's title names, or None for any other run."""
    if str(run.get("path") or "").split("@", 1)[0] != E2E_WORKFLOW_PATH:
        return None
    match = TITLE_RUNNER.search(str(run.get("display_title") or ""))
    return match.group("runner") if match else None


def is_reserved(run: Mapping[str, Any], linux_only: frozenset[str]) -> bool:
    """A release or nightly run that may want the 12vcpu pool."""
    path = str(run.get("path") or "").split("@", 1)[0]
    if path in linux_only:
        return False
    return bool(RESERVED_WORKFLOW.search(f"{run.get('name') or ''} {path}"))


def add_runs(
    load: PoolLoad,
    runs: Sequence[Mapping[str, Any]],
    *,
    queued: bool,
    linux_only: frozenset[str],
    exclude_run_id: int | None,
) -> PoolLoad:
    small, large_queued, large_running = load.small_queued, load.large_queued, load.large_running
    for run in runs:
        if run.get("id") == exclude_run_id:
            continue
        if is_reserved(run, linux_only):
            large_queued += 1
            continue
        runner = title_runner(run)
        if runner == LARGE_RUNNER:
            if queued:
                large_queued += 1
            else:
                large_running += 1
        elif runner == SMALL_RUNNER:
            small += 1
    return PoolLoad(small, large_queued, large_running)


def measure_load(
    client: ApiClient,
    repo: str,
    limits: Thresholds,
    *,
    workflows_dir: Path = WORKFLOWS_DIR,
    exclude_run_id: int | None = None,
) -> PoolLoad | None:
    """Pool demand from at most MAX_API_CALLS requests, or None when unknown.

    Raises RuntimeError (from the client) on an API failure.
    """
    linux_only = queue_janitor.linux_only_workflow_paths(workflows_dir)
    load = PoolLoad()
    for status in ("in_progress", "queued"):
        payload = client.request("GET", f"/repos/{repo}/actions/runs?status={status}&per_page={PAGE_SIZE}")
        runs = payload.get("workflow_runs") if isinstance(payload, Mapping) else None
        if not isinstance(runs, list):
            raise RuntimeError(f"unexpected {status} runs payload")
        if len(runs) >= PAGE_SIZE:
            return None
        load = add_runs(load, [run for run in runs if isinstance(run, Mapping)],
                        queued=status == "queued", linux_only=linux_only,
                        exclude_run_id=exclude_run_id)
        if load.large_queued or load.large_running >= limits.max_large_running:
            # Already ruled out; the second page cannot change that.
            break
    return load


def auto_runner(
    default: str | None,
    *,
    enabled: bool,
    limits: Thresholds | None,
    measure: Callable[[Thresholds], PoolLoad | None],
    log: Callable[[str], None] = lambda message: None,
) -> str | None:
    """The pool an unpinned run lands on, given what `auto` means.

    Only the 6vcpu default overflows. None stays None: a caller that could
    not establish the default must not act on a guess. `measure` is called
    only when overflow is possible, and any error it raises stays on 6vcpu.
    """
    if default != SMALL_RUNNER:
        return default
    if not enabled:
        log(f"{OVERFLOW_VARIABLE}=0; staying on {SMALL_RUNNER}")
        return default
    if limits is None:
        log(f"invalid {MIN_QUEUED_VARIABLE} or {MAX_LARGE_RUNNING_VARIABLE}; staying on {SMALL_RUNNER}")
        return default
    try:
        load = measure(limits)
    except Exception as error:  # noqa: BLE001 - every failure is fail-safe
        log(f"could not read the runner queue ({error}); staying on {SMALL_RUNNER}")
        return default
    if load is None:
        log(f"too many in-flight runs to read in one page; staying on {SMALL_RUNNER}")
        return default
    chosen = LARGE_RUNNER if overflows(load, limits) else default
    log(
        f"E2E waiting on {SMALL_RUNNER}: {load.small_queued} (overflow at >= {limits.min_queued}); "
        f"{LARGE_RUNNER} queued {load.large_queued}, running {load.large_running} "
        f"(max {limits.max_large_running}) -> {chosen}"
    )
    return chosen


def resolve(
    requested: str | None,
    variable: str | None,
    *,
    overflow: str | None,
    min_queued: str | None,
    max_large_running: str | None,
    measure: Callable[[Thresholds], PoolLoad | None],
    log: Callable[[str], None] = lambda message: None,
) -> str:
    """The runner label for a workflow run, from its inputs and variables."""
    requested = (requested or "").strip()
    if requested and requested != "auto":
        return requested
    default = (variable or "").strip() or SMALL_RUNNER
    return auto_runner(
        default,
        enabled=overflow_enabled(overflow),
        limits=thresholds(min_queued, max_large_running),
        measure=measure,
        log=log,
    ) or SMALL_RUNNER


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--requested", default="", help="the workflow's runner input")
    parser.add_argument("--variable", default="", help="vars.MACOS_RUNNER_TESTS")
    parser.add_argument("--overflow", default="", help=f"vars.{OVERFLOW_VARIABLE}")
    parser.add_argument("--min-queued", default="", help=f"vars.{MIN_QUEUED_VARIABLE}")
    parser.add_argument("--max-large-running", default="", help=f"vars.{MAX_LARGE_RUNNING_VARIABLE}")
    parser.add_argument("--workflows-dir", type=Path, default=WORKFLOWS_DIR)
    args = parser.parse_args(argv)

    repo = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN")
    run_id = (env.get("GITHUB_RUN_ID") or "").strip()

    def measure(limits: Thresholds) -> PoolLoad | None:
        if not token or not repo:
            raise RuntimeError("GH_TOKEN and GH_REPO are required")
        return measure_load(
            queue_janitor.GitHub(token, repo), repo, limits,
            workflows_dir=args.workflows_dir,
            exclude_run_id=int(run_id) if run_id.isdigit() else None,
        )

    print(resolve(
        args.requested, args.variable,
        overflow=args.overflow, min_queued=args.min_queued,
        max_large_running=args.max_large_running,
        measure=measure,
        log=lambda message: print(message, file=sys.stderr),
    ))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
