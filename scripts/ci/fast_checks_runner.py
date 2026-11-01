#!/usr/bin/env python3
"""Select a live runner for a read-only fast-checks command.

The admission job is a small hosted Ubuntu picker: it reads the routing App's
runner census, accepts the fleet label only when an exact Linux runner is
registered, online, and idle, and falls back after 180 seconds to the
measured Blacksmith Linux set. Only the read-only routing token reaches this
picker; no source snapshot or test credential does, and the selected label is
the only output consumed by the checks job.
"""
from __future__ import annotations

import datetime as dt
import os
import sys
import time
from typing import Any, Mapping, Sequence

import pr_runner_pool

FLEET = "cmux-fleet-linux-x64"
BLACKSMITH = (
    "blacksmith-8vcpu-ubuntu-2404",
    "blacksmith-16vcpu-ubuntu-2404",
    "blacksmith-32vcpu-ubuntu-2404",
)
WAIT_SECONDS = 180
POLL_SECONDS = 15
ALLOWED = frozenset((FLEET, *BLACKSMITH))


def fallback(env: Mapping[str, str]) -> str:
    requested = (env.get("REQUESTED_RUNNER") or "").strip()
    if requested in BLACKSMITH:
        return requested
    return BLACKSMITH[0]


def labels(runner: Mapping[str, Any]) -> frozenset[str]:
    result: set[str] = set()
    for value in runner.get("labels") or []:
        if isinstance(value, Mapping):
            value = value.get("name")
        if isinstance(value, str) and value:
            result.add(value)
    return frozenset(result)


def fresh_snapshot(snapshot: Mapping[str, Any] | None, now=None) -> bool:
    """A queue snapshot is usable only while the janitor considers it fresh."""
    if snapshot is None:
        return False
    moment = now or dt.datetime.now(dt.timezone.utc)
    return not pr_runner_pool.snapshot_problem(snapshot, moment)


def idle_runner(runners: Sequence[Mapping[str, Any]]) -> str:
    for runner in runners:
        if (runner.get("status") or "").lower() != "online" or runner.get("busy") is not False:
            continue
        if (runner.get("os") or "").lower() != "linux":
            continue
        if FLEET in labels(runner):
            return FLEET
    return ""


def read_live(env: Mapping[str, str]) -> Sequence[Mapping[str, Any]] | None:
    token = (env.get("ROUTE_TOKEN") or env.get("GITHUB_TOKEN") or "").strip()
    repo = (env.get("GITHUB_REPOSITORY") or "").strip()
    if not token or not repo:
        return None
    try:
        client = pr_runner_pool.GitHub(token, repo)
        runners = client.runners()
        # When the workflow provides the janitor token, require its queue
        # snapshot to be fresh as well. A stale or missing snapshot is not
        # evidence that an idle runner can accept this control job.
        if env.get("SNAPSHOT_TOKEN"):
            snapshot = client.snapshot(now=dt.datetime.now(dt.timezone.utc))
            if not fresh_snapshot(snapshot):
                return None
        return runners
    except Exception as error:  # noqa: BLE001 - safe bounded fallback
        print(f"::warning title=nightly control admission::live runner read failed ({error})", file=sys.stderr)
        return None


def choose(env: Mapping[str, str], read=read_live, sleep=time.sleep, clock=time.monotonic) -> str:
    requested = (env.get("REQUESTED_RUNNER") or "").strip()
    if requested in ALLOWED and requested != FLEET:
        return requested
    # A missing token or repository cannot become readable during this job;
    # skip the bounded poll and use the measured overflow immediately.
    if not (env.get("ROUTE_TOKEN") or env.get("GITHUB_TOKEN") or "").strip() or not (env.get("GITHUB_REPOSITORY") or "").strip():
        return fallback(env)
    deadline = clock() + WAIT_SECONDS
    while True:
        runners = read(env)
        if runners is not None:
            selected = idle_runner(runners)
            if selected:
                return selected
        remaining = deadline - clock()
        if remaining <= 0:
            return fallback(env)
        sleep(min(POLL_SECONDS, remaining))


def main(env: Mapping[str, str] = os.environ) -> int:
    selected = choose(env)
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"runner={selected}\n")
    print(f"nightly-next control runner: {selected}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
