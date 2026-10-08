#!/usr/bin/env python3
"""One live, per-label rule for macOS CI pool placement.

Load comes from two reads made once per pick: the organization's runners
(online, busy) and the queue janitor's pool snapshot (`macos-pool-load`, the
queued, running and reserved jobs per label; pr_runner_pool.GitHub.snapshot).
GitHub has no repository-wide job listing, so the snapshot is the only queue
source.

An owned class pool (glaeda-<class>-xcode-<version>) shares its machines with
its root, side and gui labels, so its free runners are its idle online runners
less every job queued on any label of that family. Owned pools are tried in
RUN_CLASSES order (std, then light). Without a runners read no owned pool is
eligible: CI_OWNED_POOL_SLOTS alone says nothing about load, and a run queued on
a busy mini waits for the rescue (two rounds of CI_PR_POOL_QUEUE_ROUNDS).

A run placed on an owned pool names a Blacksmith `retry_runner`, the pool
github-actions[bot]'s rescue attempt 3 moves its jobs to (ci-macos.yml).
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

BLACKSMITH = ("blacksmith-12vcpu-macos-26", "blacksmith-6vcpu-macos-26", "blacksmith-6vcpu-macos-15")
CAPACITY = dict(zip(BLACKSMITH, (5, 10, 10)))
# Public alias retained for callers and table-driven tests.
BLACKSMITH_CAPACITY = CAPACITY
XCODE_VERSION_PATTERN = r"[0-9]+(?:\.[0-9]+)*"
# The optional namespace keeps pools from different fleets separate.  AWS
# runners use glaeda-aws-<class>-xcode-<version>; the unnamespaced labels are
# the owned Mac minis.
OWNED = re.compile(rf"^glaeda-(?:(?P<namespace>aws)-)?(?:std|light|xl)-xcode-{XCODE_VERSION_PATTERN}$")
RESERVED = re.compile(r"(?:release|nightly)", re.IGNORECASE)
# Owned classes in preference order, as pr_runner_pool.RUN_CLASSES.
RUN_CLASSES = ("std", "light", "xl")
# glaeda-[root-|side-|gui-]<class>-xcode-<version>: one family of labels on the same machines.
XCODE_VERSION = re.compile(r"(?:^|/)Xcode_(?P<version>[0-9]+(?:\.[0-9]+)*)\.app(?:/|$)")
# Ten pages of 100 is twice the organization's runners today.
MAX_RUNNER_PAGES = 10
OWNED_FAMILY = re.compile(
    rf"^glaeda-(?:(?P<namespace>aws)-)?(?:root-|side-|gui-)?"
    rf"(?P<class>std|light|xl)-xcode-(?P<version>{XCODE_VERSION_PATTERN})$"
)


def owned_family(label: str) -> str:
    """Return a namespace-qualified family key for any owned label."""
    match = OWNED_FAMILY.fullmatch(label or "")
    if not match:
        return ""
    namespace = f"{match.group('namespace')}-" if match.group("namespace") else ""
    return f"{namespace}{match.group('class')}-xcode-{match.group('version')}"


def _version_key(version: str) -> tuple[int, ...]:
    """Compare dotted Xcode versions numerically, ignoring trailing zeroes."""
    parts = [int(part) for part in version.split(".")]
    while len(parts) > 1 and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def owned_order(label: str) -> tuple[object, ...]:
    """Sort owned pools by class, numeric Xcode version, then namespace.

    Class preference remains the first key.  A missing namespace is the local
    mini fleet and sorts before the explicit ``aws`` namespace when versions
    match; the namespace and full label keep ties deterministic.
    """
    match = OWNED_FAMILY.fullmatch(label or "")
    if not match:
        return (len(RUN_CLASSES), (), 1, "", label)
    owned_class = match.group("class")
    namespace = match.group("namespace") or ""
    return (
        RUN_CLASSES.index(owned_class) if owned_class in RUN_CLASSES else len(RUN_CLASSES),
        _version_key(match.group("version")),
        0 if not namespace else 1,
        namespace,
        label,
    )


def owned_matches_xcode(label: str, xcode_app: str) -> bool:
    """Whether an owned label belongs to the configured PR Xcode lane."""
    family = owned_family(label)
    version = XCODE_VERSION.search(xcode_app or "")
    return bool(family and version and family.endswith(f"-xcode-{version.group('version')}"))

def owned_xcode_app(label: str, configured: str) -> str:
    """Return the toolchain path matching an owned label's embedded version."""
    match = OWNED_FAMILY.fullmatch(label or "")
    if not match:
        return configured
    version = match.group("version")
    configured_match = re.search(r"/Xcode_([0-9]+(?:\.[0-9]+)*)\.app(?:/|$)", configured or "")
    if configured_match and _version_key(configured_match.group(1)) == _version_key(version):
        return configured
    return f"/Applications/Xcode_{version}.app"


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

    @property
    def unreserved_available(self) -> int:
        """Slots a new run can use without delaying queued release/nightly jobs."""
        return max(0, self.available - self.reserved)


@dataclasses.dataclass(frozen=True)
class State:
    jobs: int
    owned: tuple[Pool, ...] = ()
    blacksmith: tuple[Pool, ...] = ()
    fork: bool = False
    owned_enabled: bool = False
    overflow_enabled: bool = True
    fallback: str = BLACKSMITH[1]
    gui_required: bool = False


@dataclasses.dataclass(frozen=True)
class Choice:
    label: str = ""
    reason: str = "routing disabled"
    xcode_app: str = ""
    owned: bool = False
    blocked: bool = False
    # For an owned pick: the Blacksmith pool rescue attempt 3 moves its jobs to.
    retry_label: str = ""


def pick(state: State | Mapping[str, Any]) -> Choice:
    """Choose from a fully observed state. This function has no side effects."""
    if not isinstance(state, State):
        state = State(
            jobs=int(state.get("jobs", 0)),
            owned=tuple(_pool(item) for item in state.get("owned", ())),
            blacksmith=tuple(_pool(item) for item in state.get("blacksmith", ())),
            fork=bool(state.get("fork", False)), owned_enabled=bool(state.get("owned_enabled", False)),
            overflow_enabled=bool(state.get("overflow_enabled", True)), fallback=str(state.get("fallback", BLACKSMITH[1])),
            gui_required=bool(state.get("gui_required", False)),
        )
    if state.jobs <= 0:
        return Choice(state.fallback, "no macOS jobs")

    def fits(pool: Pool) -> bool:
        return pool.unreserved_available >= state.jobs

    blacksmith = _pick_blacksmith(state)
    if state.owned_enabled and not state.fork:
        # The retry pool must carry the owned label's Xcode (the lane's pin):
        # only the Blacksmith pools that keep the lane's own pin qualify.
        for pool in sorted(state.owned, key=lambda pool: owned_order(pool.label)):
            # AWS is deliberately compile-only until its console login is
            # reliable. Keep GUI suites on a pool that advertises a GUI token.
            if state.gui_required and _owned_namespace(pool.label) == "aws":
                continue
            if fits(pool):
                retry = _retry_label(state, pool)
                return Choice(pool.label, "owned label has enough free runners now, its queue counted",
                              pool.xcode_app, True, retry_label=retry)
    return blacksmith


def _owned_namespace(label: str) -> str:
    """Return an owned pool's namespace, or an empty string for the minis."""
    match = OWNED_FAMILY.fullmatch(label or "")
    return match.group("namespace") or "" if match else ""


def _xcode_version(path: str) -> tuple[int, ...]:
    """Extract an Xcode app version for matching a retry image."""
    match = re.search(r"/Xcode_([0-9]+(?:\.[0-9]+)*)\.app(?:/|$)", path or "")
    return _version_key(match.group(1)) if match else ()


def _retry_label(state: State, owned: Pool) -> str:
    """Choose a Blacksmith rescue image with the owned pool's Xcode when known."""
    wanted = _xcode_version(owned.xcode_app)
    if wanted:
        matching = tuple(pool for pool in state.blacksmith if _xcode_version(pool.xcode_app) == wanted)
        if matching:
            lane = _pick_blacksmith(dataclasses.replace(state, blacksmith=matching))
            return lane.label if lane.label and not lane.blocked else state.fallback
    lane = _pick_blacksmith(dataclasses.replace(
        state, blacksmith=tuple(pool for pool in state.blacksmith if not pool.xcode_app)))
    return lane.label if lane.label and not lane.blocked else state.fallback


def _pick_blacksmith(state: State) -> Choice:
    """Choose the least-loaded configured Blacksmith fallback pool."""
    if not state.overflow_enabled:
        return Choice(state.fallback, "Blacksmith overflow disabled")
    pools = {pool.label: pool for pool in state.blacksmith}
    eligible = [pools[label] for label in BLACKSMITH if label in pools]
    for pool in eligible:
        if pool.unreserved_available >= state.jobs:
            return Choice(pool.label, "first Blacksmith label with enough free slots", pool.xcode_app)
    if eligible:
        winner = min(eligible, key=lambda pool: ((pool.queued + pool.running) / max(1, pool.capacity),
                                                  BLACKSMITH.index(pool.label)))
        return Choice(winner.label, "lowest (queued + running) / per-label cap", winner.xcode_app)
    return Choice(state.fallback, "no Blacksmith pool in the snapshot", blocked=True)


def _pool(item: Pool | Mapping[str, Any]) -> Pool:
    """Normalize a serialized pool entry into the immutable pool model."""
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
        # The routing runners can sit behind several pages, so read all pages
        # that can contain the current fleet while keeping the API usage bounded.
        runners: list[Mapping[str, Any]] = []
        for page in range(1, MAX_RUNNER_PAGES + 1):
            batch = self._get(f"/orgs/{owner}/actions/runners?per_page=100&page={page}").get("runners") or []
            runners.extend(batch)
            if len(batch) < 100:
                break
        return runners

    def snapshot(self) -> Mapping[str, Any] | None:
        """The queue janitor's newest trusted pool snapshot, or None when missing or stale (two API calls)."""
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import datetime as dt

        import pr_runner_pool

        now = dt.datetime.now(dt.timezone.utc)
        snapshot = pr_runner_pool.GitHub(self.token, self.repository).snapshot(now=now)
        if snapshot is None or pr_runner_pool.snapshot_problem(snapshot, now):
            return None
        return snapshot


def _slots(raw: str | None) -> dict[str, int]:
    """Parse positive, valid owned-pool capacities from CI configuration."""
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
    """Read live runner and queue state once, degrading safely when unavailable."""
    fallback = (env.get("MACOS_RUNNER_PR") or BLACKSMITH[1]).strip() or BLACKSMITH[1]
    enabled = (env.get("CI_PR_POOL_OWNED") or "").strip() == "1"
    runners: list[Mapping[str, Any]] | None = None
    snapshot: Mapping[str, Any] | None = None
    if token and repository:
        api = LiveState(token, repository)
        try:
            runners = api.runners()
        except Exception as error:  # noqa: BLE001 - owned pools are then skipped
            print(f"::warning title=live runner state::{error}; owned pools skipped", file=sys.stderr)
        try:
            snapshot = api.snapshot()
        except Exception as error:  # noqa: BLE001 - queues then read as unknown (empty)
            print(f"::warning title=pool snapshot::{error}", file=sys.stderr)
    return state_from(jobs=jobs, env=env, fork=fork, runners=runners, snapshot=snapshot,
                      fallback=fallback, owned_enabled=enabled)


def state_from(*, jobs: int, env: Mapping[str, str], fork: bool, runners: Sequence[Mapping[str, Any]] | None,
               snapshot: Mapping[str, Any] | None, fallback: str, owned_enabled: bool) -> State:
    """The pick's input from one runners read (None: failed) and one janitor snapshot (None: missing or stale)."""
    pools = (snapshot or {}).get("pools") or {}
    if not isinstance(pools, Mapping):
        pools = {}

    def count(label: str, key: str) -> int:
        entry = pools.get(label) or {}
        try:
            return max(0, int(entry.get(key, 0))) if isinstance(entry, Mapping) else 0
        except (TypeError, ValueError):
            return 0

    owned: list[Pool] = []
    if runners is not None:
        xcode_app = env.get("CMUX_CI_XCODE_APP_PR", "")
        labels = {label for label in _slots(env.get("CI_OWNED_POOL_SLOTS"))
                  if owned_matches_xcode(label, xcode_app)}
        # Only the configured class pools: a runner can carry an owned-looking
        # label (the aws Macs' glaeda-std-xcode-26.3, five runners per Mac)
        # that is not a pool PR compiles should land on.
        # A runner may carry an owned-looking label for another fleet.  Only
        # labels explicitly listed in CI_OWNED_POOL_SLOTS are candidates.
        for label in sorted(labels, key=owned_order):
            online = [runner for runner in runners if runner.get("status") == "online"
                      and any(item.get("name") == label for item in runner.get("labels", ()))]
            idle = sum(not bool(runner.get("busy")) for runner in online)
            # Every job queued on this family waits for the same machines.
            family = owned_family(label)
            queued = sum(count(name, "queued") for name in pools if owned_family(str(name)) == family)
            free = max(0, idle - queued)
            owned.append(Pool(label, len(online), len(online) - idle, queued, free=free,
                               xcode_app=owned_xcode_app(label, env.get("CMUX_CI_XCODE_APP_PR", ""))))
    counts = {label: {"running": count(label, "running"), "queued": count(label, "queued"),
                      "reserved": count(label, "reserved_queued")} for label in BLACKSMITH}
    blacksmith = tuple(Pool(label, CAPACITY[label], **counts[label],
                            xcode_app=env.get("CMUX_CI_XCODE_APP_MACOS_15", "") if label == BLACKSMITH[2] else "")
                       for label in BLACKSMITH)
    return State(jobs, tuple(owned), blacksmith, fork, owned_enabled,
                 (env.get("CI_PR_POOL_OVERFLOW") or "1") != "0", fallback,
                 gui_required=(env.get("RUN_FULL_SUITE") == "true" or env.get("RUN_UNIT_SUITE") == "true"))


def planned_jobs(env: Mapping[str, str]) -> int:
    """Estimate a run's peak macOS job count from its workflow inputs."""
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
    def role_label(role: str) -> str:
        """Return the configured role label for the selected owned pool."""
        if not choice.owned:
            return ""
        match = OWNED_FAMILY.fullmatch(choice.label)
        if not match:
            return ""
        namespace = f"{match.group('namespace')}-" if match.group("namespace") else ""
        return f"glaeda-{namespace}{role}-{match.group('class')}-xcode-{match.group('version')}"

    root = role_label("root")
    side = role_label("side")
    gui = role_label("gui")
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
    values.update(runner=choice.label, xcode_app=choice.xcode_app,
                  retry_runner=choice.retry_label if choice.owned and choice.retry_label else choice.label,
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
    choice = pick(observe(token=env.get("ROUTE_TOKEN") or env.get("GH_TOKEN") or "", repository=repository,
                       jobs=jobs, env=env, fork=head != repository and not trusted_fork))
    values = write_outputs(choice, jobs, env.get("GITHUB_OUTPUT"), env)
    for key, value in values.items():
        print(f"{key}={value}")
    print(f"Selected {choice.label}: {choice.reason}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
