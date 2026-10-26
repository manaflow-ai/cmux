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

CI is minis first; Blacksmith is overflow only, and only while a label has a
free slot for the run (in flight + queued + reserved below its capacity) and
its queue is moving (stalled(), the cmux-next cascade's rule). With no owned
pool free and no free, moving Blacksmith slot, a same-repository run (not the
bot's re-run; State.wait_on_owned) waits on the online owned pool with the
shortest expected wait (expected_wait_minutes()) instead of a Blacksmith queue (2026-10-20:
blacksmith-12vcpu-macos-26 queued 5+ hours, about 95 PRs behind 318 queued
runs). Only a run with no owned pool to wait on (a fork, owned pools off, an
unread runner list) still takes the least-loaded Blacksmith label. An owned
pick's retry_runner stays a Blacksmith label (_retry_label): it also carries
the jobs the minis cannot run.
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
# blacksmith_stalled(), the one stall rule: a Blacksmith label whose oldest queued job has waited
# this long by now has had no job start on it since (its queue is first in, first out), so it has
# no free slot. 2026-10-27: blacksmith-12vcpu-macos-26 had 44 queued (oldest 396 min), 0 running.
BLACKSMITH_STALL_MINUTES = 10
# The older names, kept for callers: every one is the same rule now.
STALL_MINUTES = BLACKSMITH_STALL_MINUTES
FRESH_STALL_MINUTES = BLACKSMITH_STALL_MINUTES
# A label the snapshot saw wait this long with nothing running is stalled too.
IDLE_STALL_MINUTES = 5
# The measured runner minutes one job holds an owned runner, by class (expected_wait_minutes()): every
# completed job with a duration on the pool's machines, 2026-10-20 to 2026-10-26, from the build-fleet job
# log (cmuxterm-hq build-fleet/data, aggregated in tests/fixtures/owned-pool-turnover/2026-10-20-to-26.json,
# which test_ci_simple_pool_picker re-derives these from). std (M4 Pro, 48 GB): 20003 jobs, 150199.5 min.
# light (M4, 16 GB): 1360 jobs, 15751.3 min; the same job runs up to 3.5x longer there (release-compile p50
# 26.1 min against 7.7, fast-tier 19.3 against 6.6). A class with no figure takes the slowest measured one.
TURNOVER_MINUTES = {"std": 7.51, "light": 11.58}
# Owned classes in preference order, as pr_runner_pool.RUN_CLASSES.
RUN_CLASSES = ("std", "light", "xl")
# glaeda-[root-|side-|gui-]<class>-xcode-<version>: one family of labels on the same machines.
XCODE_VERSION = re.compile(r"(?:^|/)Xcode_(?P<version>[0-9]+(?:\.[0-9]+)*)\.app(?:/|$)")
# The org-wide fallback read (LiveState.runners(), only when the glaeda-minis group is unreadable):
# 2,862 org runners on 2026-10-27 held the minis past page 10, so read up to 5,000.
MAX_RUNNER_PAGES = 50
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
    # A Blacksmith label whose queue is not moving (stalled()): it has no free slot.
    stalled: bool = False
    # Minutes its oldest queued job has waited by now (the snapshot's figure plus its age).
    waited: float = 0.0

    @property
    def available(self) -> int:
        if self.stalled:
            return 0
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
    # Whether a run that no owned pool and no free Blacksmith slot fits may wait on an owned
    # pool: only where the owned-pool rescue watches it (a same-repository head, never a trusted
    # fork, which owned_pool_rescue never rescues) and not on the bot's re-run, which has already
    # waited behind the fleet once. Off unless the caller says so (main(), wait_on_owned()).
    wait_on_owned: bool = False


@dataclasses.dataclass(frozen=True)
class Choice:
    label: str = ""
    reason: str = "routing disabled"
    xcode_app: str = ""
    owned: bool = False
    blocked: bool = False
    # For an owned pick: the Blacksmith pool rescue attempt 3 moves its jobs to.
    retry_label: str = ""
    # For a run that overflows to the 6vcpu macOS 26 pool: a free 12vcpu slot
    # for its compile admission, the job every other one waits on.
    admission_label: str = ""


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
            wait_on_owned=bool(state.get("wait_on_owned", False)),
        )
    if state.jobs <= 0:
        return Choice(state.fallback, "no macOS jobs")

    def fits(pool: Pool) -> bool:
        return pool.unreserved_available >= state.jobs

    blacksmith = _pick_blacksmith(state)
    eligible: list[Pool] = []
    if state.owned_enabled and not state.fork:
        # The retry pool must carry the owned label's Xcode (the lane's pin):
        # only the Blacksmith pools that keep the lane's own pin qualify.
        for pool in sorted(state.owned, key=lambda pool: owned_order(pool.label)):
            # AWS is deliberately compile-only until its console login is
            # reliable. Keep GUI suites on a pool that advertises a GUI token.
            if state.gui_required and _owned_namespace(pool.label) == "aws":
                continue
            # A pool with no online runner is no queue to wait in.
            if pool.capacity > 0:
                eligible.append(pool)
            if fits(pool):
                retry = _retry_label(state, pool)
                return Choice(pool.label, "owned label has enough free runners now, its queue counted",
                              pool.xcode_app, True, retry_label=retry)
    if eligible and state.wait_on_owned and state.overflow_enabled and _free_blacksmith(state) is None:
        # Never a Blacksmith queue: wait behind the fleet, which the rescue watches, on the owned
        # pool where the run is expected to start soonest (owned order on a tie).
        pool = min(eligible, key=lambda pool: (expected_wait_minutes(pool, state.jobs), owned_order(pool.label)))
        return Choice(pool.label, "no owned pool and no Blacksmith label has a free, moving slot now; "
                      "waits on the owned label rather than a Blacksmith queue",
                      pool.xcode_app, True, retry_label=_retry_label(state, pool))
    return _borrow_large_for_admission(state, blacksmith)


def expected_wait_minutes(pool: Pool, jobs: int) -> float:
    """Minutes until the last of a run's `jobs` starts on owned `pool`, from its measured turnover.

    Its idle runners take the first of the queued jobs and then the run's own at once; the rest start
    in waves of `capacity` (its online runners), one TURNOVER_MINUTES of its class apart. queued / capacity
    alone read a busy 4-runner light pool with 12 queued (3 a runner) as shorter than a busy 30-runner std
    pool with 108 (3.6 a runner), though light's run starts after four turnovers of 11.58 min (46.3) and
    std's after four of 7.51 (30.0); and it ranked a pool with fewer runners than the run has jobs as if
    every job started at once.
    """
    match = OWNED_FAMILY.fullmatch(pool.label or "")
    turnover = TURNOVER_MINUTES.get(match.group("class") if match else "", max(TURNOVER_MINUTES.values()))
    if pool.free:  # state_from(): idle runners left once the family's queue took its share
        waiting = max(0, max(1, jobs) - pool.free)
    else:
        waiting = max(0, pool.queued + max(1, jobs) - max(0, pool.capacity - pool.running))
    return -(-waiting // max(1, pool.capacity)) * turnover


def _borrow_large_for_admission(state: State, choice: Choice) -> Choice:
    """Compile an overflow run on 12vcpu when one slot is free there.

    12vcpu takes a whole run only when every job of it fits, so most runs
    overflow to 6vcpu, compile included (about 18 min, against about 10). The
    compile is one job and its product runs anywhere on the same image, so it
    alone takes a free 12vcpu slot; the other jobs stay on the chosen pool.
    """
    large, small = BLACKSMITH[0], BLACKSMITH[1]
    if state.fork or choice.blocked or choice.label != small:
        return choice
    pool = next((pool for pool in state.blacksmith if pool.label == large), None)
    if pool is None or pool.xcode_app or pool.unreserved_available < 1:
        return choice
    return dataclasses.replace(choice, admission_label=large)


def _owned_namespace(label: str) -> str:
    """Return an owned pool's namespace, or an empty string for the minis."""
    match = OWNED_FAMILY.fullmatch(label or "")
    return match.group("namespace") or "" if match else ""


def _xcode_version(path: str) -> tuple[int, ...]:
    """Extract an Xcode app version for matching a retry image."""
    match = re.search(r"/Xcode_([0-9]+(?:\.[0-9]+)*)\.app(?:/|$)", path or "")
    return _version_key(match.group(1)) if match else ()


def _retry_label(state: State, owned: Pool) -> str:
    """Choose a Blacksmith rescue image with the owned pool's Xcode when known.

    It stays a Blacksmith label even when every one is full: ci-macos.yml also sends an owned
    run's jobs the minis cannot run (the SDK 15 helper build, for one) to pr_retry_runner, so an
    owned label here would fail them. A free, moving label comes first (_pick_blacksmith).
    """
    wanted = _xcode_version(owned.xcode_app)
    if wanted:
        matching = tuple(pool for pool in state.blacksmith if _xcode_version(pool.xcode_app) == wanted)
        if matching:
            lane = _pick_blacksmith(dataclasses.replace(state, blacksmith=matching))
            return lane.label if lane.label and not lane.blocked else state.fallback
    lane = _pick_blacksmith(dataclasses.replace(
        state, blacksmith=tuple(pool for pool in state.blacksmith if not pool.xcode_app)))
    return lane.label if lane.label and not lane.blocked else state.fallback


def _free_blacksmith(state: State) -> Pool | None:
    """The first Blacksmith label, in BLACKSMITH order, with a free, moving slot for every job of the run.

    A label blacksmith_stalled() names is not moving, so it does not count."""
    pools = {pool.label: pool for pool in state.blacksmith}
    return next((pools[label] for label in BLACKSMITH
                 if label in pools and pools[label].unreserved_available >= state.jobs
                 and not blacksmith_stalled(pools[label].queued, pools[label].waited)), None)


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
        """The repository's runners and the org's glaeda-minis group, as pr_runner_pool reads them.

        The org-wide listing below is only the fallback: with 2,862 org runners on 2026-10-27 its
        MAX_RUNNER_PAGES pages held none of the minis, so every owned pool read as offline and an
        owned-first pick (DEV publish 40454509260) went to a stalled Blacksmith queue.
        """
        try:
            return self._group_runners()
        except Exception as error:  # noqa: BLE001 - the org-wide pages below may still hold them
            print(f"::warning title=live runner state::{error}; reading the org-wide runner list", file=sys.stderr)
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

    def _group_runners(self) -> list[Mapping[str, Any]]:
        sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
        import pr_runner_pool

        return pr_runner_pool.GitHub(self.token, self.repository).runners()

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


def wait_on_owned(env: Mapping[str, str], *, head: str, repository: str) -> bool:
    """State.wait_on_owned for ci.yml's pick: a same-repository head, and not the bot's re-run."""
    if not repository or head != repository:
        return False
    rerun = (env.get("GITHUB_RUN_ATTEMPT") or "1").strip() not in ("", "1")
    return not (rerun and (env.get("GITHUB_TRIGGERING_ACTOR") or "").strip() == "github-actions[bot]")


def observe(*, token: str, repository: str, jobs: int, env: Mapping[str, str], fork: bool,
            wait_owned: bool = False) -> State:
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
    return dataclasses.replace(state_from(jobs=jobs, env=env, fork=fork, runners=runners, snapshot=snapshot,
                                          fallback=fallback, owned_enabled=enabled), wait_on_owned=wait_owned)


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
    age = snapshot_age(snapshot)
    counts = {label: {"running": count(label, "running"), "queued": count(label, "queued"),
                      "reserved": count(label, "reserved_queued"),
                      "stalled": stalled(count(label, "queued"), count(label, "running"),
                                         count(label, "oldest_queued_minutes"), age),
                      "waited": count(label, "oldest_queued_minutes") + age if count(label, "queued") else 0.0}
              for label in BLACKSMITH}
    blacksmith = tuple(Pool(label, CAPACITY[label], **counts[label],
                            xcode_app=env.get("CMUX_CI_XCODE_APP_MACOS_15", "") if label == BLACKSMITH[2] else "")
                       for label in BLACKSMITH)
    return State(jobs, tuple(owned), blacksmith, fork, owned_enabled,
                 (env.get("CI_PR_POOL_OVERFLOW") or "1") != "0", fallback,
                 gui_required=(env.get("RUN_FULL_SUITE") == "true" or env.get("RUN_UNIT_SUITE") == "true"))


def snapshot_age(snapshot: Mapping[str, Any] | None) -> float:
    """The janitor snapshot's age in minutes (0 when unknown)."""
    import datetime as dt

    try:
        generated = dt.datetime.fromisoformat(str((snapshot or {}).get("generated_at") or "").replace("Z", "+00:00"))
    except ValueError:
        return 0.0
    if generated.tzinfo is None:
        return 0.0
    return max(0.0, (dt.datetime.now(dt.timezone.utc) - generated).total_seconds() / 60)


def blacksmith_stalled(queued: int, waited: float) -> bool:
    """The one stall rule for a Blacksmith label: a queued job has waited BLACKSMITH_STALL_MINUTES by
    now (`waited`: the snapshot's oldest_queued_minutes plus the snapshot's age).

    The janitor snapshot carries no start times; on a first-in, first-out label queue a job that
    started since would have been that oldest one, so the wait alone says nothing has started."""
    return queued > 0 and waited >= BLACKSMITH_STALL_MINUTES


def stalled(queued: int, running: int, oldest_queued_minutes: int, age: float = 0.0) -> bool:
    """blacksmith_stalled() on the snapshot, or IDLE_STALL_MINUTES (as the snapshot saw it) with
    nothing running."""
    if queued <= 0:
        return False
    return (blacksmith_stalled(queued, oldest_queued_minutes + max(0.0, age))
            or running == 0 and oldest_queued_minutes >= IDLE_STALL_MINUTES)


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
                  admission_runner=json.dumps([root]) if root and "admission" in owned_jobs
                  else json.dumps([choice.admission_label])
                  if choice.admission_label and not choice.owned and env.get("RUN_MACOS") == "true" else "")
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
                       jobs=jobs, env=env, fork=head != repository and not trusted_fork,
                       wait_owned=wait_on_owned(env, head=head, repository=repository)))
    values = write_outputs(choice, jobs, env.get("GITHUB_OUTPUT"), env)
    for key, value in values.items():
        print(f"{key}={value}")
    print(f"Selected {choice.label}: {choice.reason}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
