#!/usr/bin/env python3
"""Select a live runner for a read-only fast-checks command.

The admission job is a small hosted Ubuntu picker: it reads the routing App's
runner census once and decides. An online Linux fleet runner, idle or busy,
keeps the checks on the fleet label: the lane-gh broker moves a checks job that
label leaves queued 180 seconds to the measured Blacksmith overflow, so the
fleet-first stall bound is kept there, never by holding this job. No online
fleet runner sends the checks to the smallest measured Blacksmith size at once.
An unreadable census is read once more after POLL_SECONDS, then overflows; a
spent quota overflows at once, since another look would only be refused again.
(cmux run 41718897738 spent 182 s here polling for an idle fleet runner before
taking Blacksmith, on every run with the fleet busy or gone.) Only the read-only
routing token reaches this picker; no source snapshot or test credential does,
and the selected label is the only output consumed by the checks job.
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
UNREAD_LOOKS = 2  # census reads before an unreadable census overflows
ALLOWED = frozenset((FLEET, *BLACKSMITH))
# read_live's answer when GitHub refused the census for a spent quota. Asking
# again every POLL_SECONDS only spends more of the shared routing quota and
# holds the checks for the whole wait, so admission overflows at once.
RATE_LIMITED = object()


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


def online_fleet(runners: Sequence[Mapping[str, Any]]) -> bool:
    """Whether any online Linux runner carries the fleet label, idle or busy:
    a checks job queued there starts when one frees, and the broker's stall
    reroute moves it to overflow if none does within its bound."""
    return any((runner.get("status") or "").lower() == "online"
               and (runner.get("os") or "").lower() == "linux"
               and FLEET in labels(runner) for runner in runners)


def read_live(env: Mapping[str, str], *, deadline: float | None = None,
              use_state: bool = True) -> Sequence[Mapping[str, Any]] | object | None:
    # GITHUB_TOKEN is the test job's repository credential, not authority to
    # read the organization runner census. Missing routing authority must go
    # straight to overflow instead of silently widening permissions.
    token = (env.get("ROUTE_TOKEN") or "").strip()
    repo = (env.get("GITHUB_REPOSITORY") or "").strip()
    if not token or not repo:
        return None
    try:
        client = pr_runner_pool.GitHub(token, repo, deadline=deadline)
        runners = client.runners(use_state=use_state)
        # When the workflow provides the janitor token, require its queue
        # snapshot to be fresh as well. A stale or missing snapshot is not
        # evidence that an idle runner can accept this control job.
        snapshot_token = (env.get("SNAPSHOT_TOKEN") or "").strip()
        if snapshot_token:
            snapshot_client = pr_runner_pool.GitHub(snapshot_token, repo, deadline=deadline)
            snapshot = snapshot_client.snapshot(now=dt.datetime.now(dt.timezone.utc))
            if not fresh_snapshot(snapshot):
                return None
        return runners
    except Exception as error:  # noqa: BLE001 - safe bounded fallback
        if pr_runner_pool.rate_limited(error):
            print("::warning title=nightly control admission::the routing token's GitHub quota is spent "
                  f"({error}); taking the measured overflow now instead of polling", file=sys.stderr)
            return RATE_LIMITED
        print(f"::warning title=nightly control admission::live runner read failed ({error})", file=sys.stderr)
        return None


def choose(env: Mapping[str, str], read=None, sleep=time.sleep, clock=time.monotonic) -> str:
    requested = (env.get("REQUESTED_RUNNER") or "").strip()
    if requested in ALLOWED and requested != FLEET:
        return requested
    # A missing token or repository cannot become readable during this job;
    # skip the bounded poll and use the measured overflow immediately.
    if not (env.get("ROUTE_TOKEN") or "").strip() or not (env.get("GITHUB_REPOSITORY") or "").strip():
        return fallback(env)
    deadline = clock() + WAIT_SECONDS
    first_look = True
    looks = 0
    while True:
        runners = (read(env, deadline=deadline) if read is not None else
                   read_live(env, deadline=deadline, use_state=first_look))
        first_look = False
        looks += 1
        if runners is RATE_LIMITED:
            return fallback(env)
        if runners is not None:
            # One readable census decides: waiting here for an idle runner only
            # delays the checks (the broker bounds a fleet queue, not this job).
            if idle_runner(runners) or online_fleet(runners):
                return FLEET
            return fallback(env)
        remaining = deadline - clock()
        if remaining <= 0 or looks >= UNREAD_LOOKS:
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
