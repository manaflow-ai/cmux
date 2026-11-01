#!/usr/bin/env python3
"""Select a live idle fleet runner for the NEXT control jobs.

The picker runs on hosted Ubuntu because no earlier job can provide a runner
receipt. Repository variables are only declared candidates: a candidate is
accepted after the routing App proves that the exact label is registered,
online, and idle. If that proof cannot be obtained for three minutes, attempt
one uses hosted Ubuntu and later attempts use the measured 16-vCPU overflow.
"""
from __future__ import annotations

import datetime as dt
import os
import sys
import time
from pathlib import Path
from typing import Any, Mapping, Sequence

import pr_runner_pool
import runner_label_policy

HOSTED = "ubuntu-24.04"
BLACKSMITH = "blacksmith-4vcpu-ubuntu-2404"
WAIT_SECONDS = 180
POLL_SECONDS = 15
CANDIDATE_VARS = (
    "CI_SIDE_LANE_RUNNER",
    "CI_LIGHT_LANE_RUNNER", "CI_LINUX_GATE_OWNED_RUNNER",
    "CI_NIGHTLY_ONLY_RUNNER", "CI_CONTROL_RUNNER", "LINUX_RUNNER",
)
def fallback(env: Mapping[str, str]) -> str:
    if (env.get("GITHUB_RUN_ATTEMPT") or "1") == "1":
        return HOSTED
    # Keep the overflow tied to the repository's measured runner catalog; the
    # constant is only a safe fallback when this checkout cannot be read.
    try:
        import json
        catalog = json.loads((Path(__file__).resolve().parents[2] / ".github/runners.json").read_text())
        measured = catalog["fleets"]["blacksmith"]["linux"]
        if isinstance(measured, str) and measured.startswith("blacksmith-"):
            return measured
    except (OSError, KeyError, TypeError, ValueError):
        pass
    return BLACKSMITH


def _candidate_allowed(name: str, label: str) -> bool:
    if not label or label.startswith(("blacksmith-", "ubuntu-", "macos-", "windows-")):
        return False
    if name == "CI_NIGHTLY_ONLY_RUNNER":
        return label == "glaeda-nightly-only-m4pro"
    if label == "cmux-fleet-linux-x64":
        return True
    if not label.startswith("glaeda-"):
        return False
    try:
        if name in ("CI_SIDE_LANE_RUNNER", "CI_LIGHT_LANE_RUNNER", "CI_LINUX_GATE_OWNED_RUNNER"):
            return runner_label_policy.side_lane_reason(label) is None
        return (runner_label_policy.nightly_next_build_reason(label) is None
                or runner_label_policy.side_lane_reason(label) is None)
    except runner_label_policy.PolicyUnreadable:
        return False


def candidates(env: Mapping[str, str]) -> tuple[str, ...]:
    found: list[str] = []
    for name in CANDIDATE_VARS:
        for label in (env.get(name) or "").replace(",", " ").split():
            if _candidate_allowed(name, label) and label not in found:
                found.append(label)
    return tuple(found)


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


def idle_runner(runners: Sequence[Mapping[str, Any]], wanted: Sequence[str]) -> str:
    for label in wanted:
        for runner in runners:
            if (runner.get("status") or "").lower() != "online" or runner.get("busy") is not False:
                continue
            if (runner.get("os") or "").lower() not in {"linux", "macos"}:
                continue
            if label in labels(runner):
                return label
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
    # A re-run is the no-start rescue for an admission label that refused or
    # never started. Do not select that same label again; use measured overflow.
    if (env.get("GITHUB_RUN_ATTEMPT") or "1") != "1":
        return fallback(env)
    wanted = candidates(env)
    if not wanted:
        return fallback(env)
    deadline = clock() + WAIT_SECONDS
    while True:
        runners = read(env)
        if runners is not None:
            selected = idle_runner(runners, wanted)
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
