#!/usr/bin/env python3
"""One live, per-label rule for macOS CI pool placement.

Blacksmith overflow uses the macOS 26 pools only, the macOS and Xcode (the
pull-request lane's pin, vars.CMUX_CI_XCODE_APP_PR) main's full suite runs on.
`blacksmith-6vcpu-macos-15` (Xcode 26.3) is not a pull-request or merge-queue
pool: a run placed there tested a different OS and toolchain than main, so a
test could pass on main and fail in the pull request, or the reverse. macOS 15
keeps its own non-gating signal in ci-macos-15.yml, a scheduled full suite.
"""

from __future__ import annotations

import argparse
import dataclasses
import json
import os
import re
import sys
import urllib.request
from typing import Any, Mapping, Sequence

BLACKSMITH = ("blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26")
CAPACITY = dict(zip(BLACKSMITH, (5, 10)))
# Public alias retained for callers and table-driven tests.
BLACKSMITH_CAPACITY = CAPACITY
OWNED = re.compile(r"^glaeda-(?:std|light|xl)-xcode-[0-9]+(?:\.[0-9]+)*$")
RESERVED = re.compile(r"(?:release|nightly)", re.IGNORECASE)


@dataclasses.dataclass(frozen=True)
class Pool:
    label: str
    capacity: int
    running: int = 0
    queued: int = 0
    free: int | None = None
    reserved: int = 0
    xcode_app: str = ""

    @property
    def available(self) -> int:
        return max(0, self.capacity - self.running if self.free is None else self.free)


@dataclasses.dataclass(frozen=True)
class State:
    jobs: int
    owned: tuple[Pool, ...] = ()
    blacksmith: tuple[Pool, ...] = ()
    fork: bool = False
    owned_enabled: bool = False
    overflow_enabled: bool = True
    fallback: str = BLACKSMITH[1]


@dataclasses.dataclass(frozen=True)
class Choice:
    label: str = ""
    reason: str = "routing disabled"
    xcode_app: str = ""
    owned: bool = False
    blocked: bool = False


def pick(state: State | Mapping[str, Any]) -> Choice:
    """Choose from a fully observed state. This function has no side effects."""
    if not isinstance(state, State):
        state = State(
            jobs=int(state.get("jobs", 0)),
            owned=tuple(_pool(item) for item in state.get("owned", ())),
            blacksmith=tuple(_pool(item) for item in state.get("blacksmith", ())),
            fork=bool(state.get("fork", False)), owned_enabled=bool(state.get("owned_enabled", False)),
            overflow_enabled=bool(state.get("overflow_enabled", True)), fallback=str(state.get("fallback", BLACKSMITH[1])),
        )
    if state.jobs <= 0:
        return Choice(state.fallback, "no macOS jobs")

    def fits(pool: Pool) -> bool:
        return pool.reserved == 0 and pool.available >= state.jobs

    if state.owned_enabled and not state.fork:
        for pool in state.owned:
            if fits(pool):
                return Choice(pool.label, "owned label has enough free runners now", pool.xcode_app, True)
    if not state.overflow_enabled:
        return Choice(state.fallback, "Blacksmith overflow disabled")
    pools = {pool.label: pool for pool in state.blacksmith}
    eligible = [pools[label] for label in BLACKSMITH if label in pools and pools[label].reserved == 0]
    for pool in eligible:
        if pool.capacity - pool.running >= state.jobs:
            return Choice(pool.label, "first Blacksmith label with enough free slots", pool.xcode_app)
    if eligible:
        winner = min(eligible, key=lambda pool: ((pool.queued + pool.running) / max(1, pool.capacity),
                                                  BLACKSMITH.index(pool.label)))
        return Choice(winner.label, "lowest (queued + running) / per-label cap", winner.xcode_app)
    return Choice(state.fallback, "every pool protects a queued release or nightly job", blocked=True)


def _pool(item: Pool | Mapping[str, Any]) -> Pool:
    if isinstance(item, Pool):
        return item
    return Pool(str(item["label"]), int(item.get("capacity", 0)), int(item.get("running", 0)),
                int(item.get("queued", 0)), None if item.get("free") is None else int(item["free"]),
                int(item.get("reserved", 0)), str(item.get("xcode_app", "")))


class LiveState:
    """Read runners and active jobs; callers perform this once for one pick."""

    def __init__(self, token: str, repository: str):
        self.token = token
        self.repository = repository
        self.headers = {"Accept": "application/vnd.github+json", "Authorization": f"Bearer {token}",
                        "User-Agent": "cmux-simple-pool-picker"}

    def _get(self, path: str) -> Any:
        request = urllib.request.Request(f"https://api.github.com{path}", headers=self.headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.load(response)

    def runners(self) -> list[Mapping[str, Any]]:
        owner = self.repository.split("/", 1)[0]
        # Keep this to one bounded read. The organization has fewer than one
        # page of routing runners; a partial response is safer than spending
        # the shared Actions API quota on pagination for every run.
        return self._get(f"/orgs/{owner}/actions/runners?per_page=100").get("runners") or []

    def active_jobs(self) -> list[Mapping[str, Any]]:
        """Read the repository's queued and running jobs in one API call."""
        data = self._get(f"/repos/{self.repository}/actions/jobs?filter=all&per_page=100")
        return data.get("jobs") or []


def _slots(raw: str | None) -> dict[str, int]:
    try:
        data = json.loads(raw or "{}")
    except (TypeError, ValueError):
        return {}
    if not isinstance(data, dict):
        return {}
    result: dict[str, int] = {}
    for label, count in data.items():
        try:
            count = int(count)
        except (TypeError, ValueError):
            continue
        if OWNED.fullmatch(str(label)) and count > 0:
            result[str(label)] = count
    return result


def observe(*, token: str, repository: str, jobs: int, env: Mapping[str, str], fork: bool) -> State:
    fallback = (env.get("MACOS_RUNNER_PR") or BLACKSMITH[1]).strip() or BLACKSMITH[1]
    enabled = (env.get("CI_PR_POOL_OWNED") or "").strip() == "1"
    runners: list[Mapping[str, Any]] = []
    active: list[Mapping[str, Any]] = []
    if token and repository:
        try:
            api = LiveState(token, repository)
            runners, active = api.runners(), api.active_jobs()
        except Exception as error:  # noqa: BLE001 - configured fallback is safe
            print(f"::warning title=live pool state::{error}", file=sys.stderr)
            # Keep the configured owned capacity when the live read is
            # unavailable. The variable is the established fail-safe; a
            # transient API failure must not silently move trusted runs.
            runners, active = [], []
    slots = _slots(env.get("CI_OWNED_POOL_SLOTS"))
    labels = set(slots)
    for runner in runners:
        labels.update(str(item.get("name", "")) for item in runner.get("labels", ())
                      if OWNED.fullmatch(str(item.get("name", ""))))
    owned: list[Pool] = []
    for label in sorted(labels):
        online = [runner for runner in runners if runner.get("status") == "online"
                  and any(item.get("name") == label for item in runner.get("labels", ()))]
        capacity = len(online) if runners else slots.get(label, 0)
        free = sum(not bool(runner.get("busy")) for runner in online) if runners else capacity
        owned.append(Pool(label, capacity, capacity - free, free=free, xcode_app=env.get("CMUX_CI_XCODE_APP_PR", "")))
    counts = {label: {"running": 0, "queued": 0, "reserved": 0} for label in BLACKSMITH}
    for job in active:
        labels = {str(item) for item in job.get("labels", ())}
        status = str(job.get("status", "")).lower()
        for label in BLACKSMITH:
            if label not in labels:
                continue
            if status in {"in_progress", "in-progress", "running"}:
                counts[label]["running"] += 1
            elif status in {"queued", "pending", "waiting"}:
                counts[label]["queued"] += 1
                if RESERVED.search(f"{job.get('workflow_name', '')} {job.get('name', '')}"):
                    counts[label]["reserved"] += 1
    blacksmith = tuple(Pool(label, CAPACITY[label], **counts[label]) for label in BLACKSMITH)
    return State(jobs, tuple(owned), blacksmith, fork, enabled, (env.get("CI_PR_POOL_OVERFLOW") or "1") != "0", fallback)


def planned_jobs(env: Mapping[str, str]) -> int:
    if (env.get("RUN_JOBS") or "").isdigit():
        return max(0, int(env["RUN_JOBS"]))
    if not any((env.get(key) or "") == "true" for key in ("RUN_MACOS", "RUN_CLI", "RUN_CLAUDE_WRAPPER", "RUN_REMOTE_DAEMON", "RUN_SWIFT_PACKAGES", "RUN_RELEASE_BUILD")):
        return 0
    jobs = 1
    if env.get("RUN_FULL_SUITE") == "true":
        jobs += 7
    elif env.get("RUN_UNIT_SUITE") == "true" and env.get("RUN_UNIT_IN_ADMISSION") != "true":
        jobs += 1
    jobs += sum(env.get(key) == "true" for key in ("RUN_CLAUDE_WRAPPER", "RUN_REMOTE_DAEMON", "RUN_SWIFT_PACKAGES", "RUN_RELEASE_BUILD", "RUN_CLI"))
    return jobs


def write_outputs(choice: Choice, jobs: int, path: str | None = None,
                  env: Mapping[str, str] | None = None) -> dict[str, str]:
    """Write the stable output names consumed by ci.yml and ci-macos.yml."""
    env = {} if env is None else env
    values = {key: "" for key in ("runner", "xcode_app", "retry_runner", "shard_runner", "owned_jobs", "root_runner", "side_runner", "light_side_runner", "light_side_jobs", "gui_runner", "admission_runner", "admission_route", "admission_warm")}
    configured = set()
    try:
        raw_slots = json.loads(env.get("CI_OWNED_POOL_SLOTS", "{}"))
        if isinstance(raw_slots, dict):
            configured = {str(label) for label in raw_slots}
    except (TypeError, ValueError):
        pass
    root = f"glaeda-root-{choice.label.removeprefix('glaeda-')}" if choice.owned else ""
    side = f"glaeda-side-{choice.label.removeprefix('glaeda-')}" if choice.owned else ""
    gui = f"glaeda-gui-{choice.label.removeprefix('glaeda-')}" if choice.owned else ""
    if root not in configured:
        root = ""
    if side not in configured:
        side = ""
    if gui not in configured:
        gui = ""
    owned_jobs: list[str] = []
    if choice.owned:
        if env.get("RUN_MACOS") == "true":
            owned_jobs.append("admission")
        if env.get("RUN_FULL_SUITE") == "true":
            owned_jobs.extend(f"shard-{index}" for index in range(1, 9))
            owned_jobs.append("lag")
        if env.get("RUN_CLI") == "true":
            owned_jobs.append("cli-product")
        # swift-package-tests first builds the Release Ghostty CLI helper
        # against an SDK 15 Xcode when this run is a full suite that also
        # checks the Release build. Only the Blacksmith macOS 15 image carries
        # that SDK; the minis have Xcode 26.6 alone, where ci-macos.yml's
        # "Select helper Xcode" exits non-zero rather than falling back. So the
        # lane takes an owned Mac only when it builds no helper
        # (pr_runner_pool.package_lane_owned()).
        helper_build = env.get("RUN_FULL_SUITE") == "true" and env.get("RUN_RELEASE_BUILD") == "true"
        for key, lane in (("RUN_CLAUDE_WRAPPER", "claude-wrapper"),
                          ("RUN_REMOTE_DAEMON", "remote-daemon"),
                          ("RUN_SWIFT_PACKAGES", "swift-package"),
                          ("RUN_RELEASE_BUILD", "release-build")):
            if lane == "swift-package" and helper_build:
                continue
            if env.get(key) == "true":
                owned_jobs.append(lane)
    values.update(runner=choice.label, xcode_app=choice.xcode_app, retry_runner=choice.label,
                  shard_runner=choice.label,
                  persistent="true" if choice.owned else "false", jobs=str(jobs),
                  placed=str(jobs if choice.owned else 0),
                  owned_jobs=f" {' '.join(owned_jobs)} " if owned_jobs else "",
                  root_runner=root, side_runner=side or choice.label, gui_runner=gui,
                  admission_runner=json.dumps([root]) if root and "admission" in owned_jobs else "")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            for key, value in values.items():
                handle.write(f"{key}={value}\n")
    return values


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser()
    parser.add_argument("--jobs", type=int, default=None)
    args = parser.parse_args(argv)
    jobs = max(0, args.jobs if args.jobs is not None else planned_jobs(env))
    repository = env.get("GH_REPO") or env.get("GITHUB_REPOSITORY") or ""
    head = env.get("HEAD_REPO") or repository
    trusted_fork = (env.get("CI_PR_POOL_FORK_ALLOWED") or "").strip() == "1"
    # A merge group can carry a fork pull request's code, so it takes an
    # ephemeral Blacksmith pool like a fork (owned_pool_rescue.TRUSTED_SIDE_EVENTS).
    ephemeral_only = (head != repository and not trusted_fork) or env.get("EVENT_NAME") == "merge_group"
    choice = pick(observe(token=env.get("ROUTE_TOKEN") or env.get("GH_TOKEN") or "", repository=repository,
                       jobs=jobs, env=env, fork=ephemeral_only))
    values = write_outputs(choice, jobs, env.get("GITHUB_OUTPUT"), env)
    for key, value in values.items():
        print(f"{key}={value}")
    print(f"Selected {choice.label}: {choice.reason}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
