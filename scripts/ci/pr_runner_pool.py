#!/usr/bin/env python3
"""Pick the macOS pool a pull request CI run lands on.

ci.yml's `changes` job calls this once per run, and every pull-request macOS
job in the run reads the answer: compile admission, the app-host consumers
that follow it, tests-build-and-lag, the Claude wrapper, CLI pipe and remote
daemon lanes. A run is never split across pools, because the app-host product
only loads under the Xcode that linked it (#14163).

The run takes the first pool in preference order that has headroom:

    vars.CI_PR_POOL_ORDER, comma-separated; by default
      blacksmith-12vcpu-macos-26   same macOS and Xcode as the lane, faster
      blacksmith-6vcpu-macos-26    vars.MACOS_RUNNER_PR today
      blacksmith-6vcpu-macos-15    macOS 15 Xcode (vars.CMUX_CI_XCODE_APP_MACOS_15),
                                   the pool and Xcode main's own CI runs on

    headroom = fewer than vars.CI_PR_POOL_MAX_QUEUED jobs queued (default 3)
               and no queued release or nightly job on the pool

When no pool has headroom, the run takes the one with the fewest queued jobs
(the earlier pool on a tie). A pool holding a queued release or nightly job
is never chosen: pull requests must not delay those. Every Blacksmith pool
is sponsored, so cost is not a reason to prefer one.

`vars.CI_PR_POOL_OVERFLOW == '0'` turns this off. Only the labels in POOLS
are accepted, because each one's Xcode pin is known here.

Owned Macs (fleet RFC, cmuxterm-hq#573) join as class pools keyed by the
label glaeda issues, `glaeda-<class>-xcode-<version>`. glaeda puts that label
only on a dedicated member whose Xcode at the pinned path reports the pinned
build, so the one label carries the class, the availability and the Xcode.
The version follows the pull-request lane's pin (vars.CMUX_CI_XCODE_APP_PR,
`/Applications/Xcode_26.6.app` -> `glaeda-std-xcode-26.6`), so moving the
pin moves the pool, and no runner carries the new label until glaeda has
verified the new Xcode on it. Owned pools are persistent: the machine
outlives the job. They take part only when `vars.CI_PR_POOL_OWNED == '1'`,
and then go first in the default order so Blacksmith is overflow. Their
capacity is the number of machines the fleet manifest gives each label,
published as vars.CI_OWNED_POOL_SLOTS (JSON, `{"glaeda-std-xcode-26.6": 12}`).
The janitor's snapshot counts the jobs queued and running on each owned label
from the job listings it already makes, and `committed`: what the runs
holding the pool need at their peak, read from the marker each one uploads
(`macos-pool-persistent-<run>-<attempt>-<jobs>-<pool>`), so a run whose later
jobs do not exist yet still counts them. No token beyond GITHUB_TOKEN is
needed. A run takes an owned pool only when its own peak (run_jobs) is free
at once. An owned pool is skipped when it has no slot count, or when the
snapshot is older than OWNED_MAX_AGE_MINUTES. An offline machine still counts
as a slot; what that gets wrong, ci-owned-pool-rescue.yml catches: a run whose
job waits on an owned pool past its budget is re-run on Blacksmith. A re-run
of failed jobs reuses this run's outputs, so a persistent choice also names
`retry_runner`, the Blacksmith pool every macOS job takes from attempt 2 on. The owned order is `std` (48 GB minis),
then `light` (16 GB), then the Blacksmith pools: one order for every job type.

The queue comes from the queue janitor, which lists every in-flight run's
jobs each sweep and publishes what it saw as the `macos-pool-load` artifact.
Only a copy uploaded by a run on main of this repository counts, so no other
branch can steer the choice. The janitor sweeps every 10 to 30 minutes, so
every pull request run created since the snapshot is replayed through the
same rule first, one job each, filling a pool's idle slots (POOL_CAPACITY
less what is running) before they count as queued, so a burst of pushes
spreads across the pools instead of all taking the one that looked idle. That costs three
API requests (the artifact listing, its download redirect, and one page of
CI runs); listing jobs here would cost one per in-flight run on every push,
out of the GITHUB_TOKEN's shared budget of about 1000 an hour. A snapshot
older than MAX_SNAPSHOT_MINUTES counts as unknown.

A pull request from a fork into manaflow-ai/cmux gets no repository
variables. It follows the settings and lane the janitor copied into the
snapshot (so the kill switch reaches it too), never pins an Xcode (each job
selects the newest SDK 26 Xcode on the pool it lands on, and the product
consumers restate compile admission's empty pin), and only lands on
ephemeral Blacksmith pools.

A retry attempt (GITHUB_RUN_ATTEMPT above 1) never takes a persistent pool
either. A job queued on a persistent pool waits for it however long it stays
busy, so owned_pool_rescue.py cancels such a run and re-runs it, and the
re-run has to land somewhere with capacity. A rerun after a job failed on an
owned Mac lands on Blacksmith for the same reason. The `persistent` output
tells ci.yml to publish the marker the rescue watcher looks for.

Anything uncertain keeps today's route: an event other than pull_request, a
lane (MACOS_RUNNER_PR) naming another pool or unset (the documented way back
to the macOS 15 lane), an API error, a missing, stale or malformed snapshot,
or an invalid setting. The script then prints an empty runner, and every
job's own expression resolves exactly as before.
"""
from __future__ import annotations

import argparse
import dataclasses
import datetime as dt
import io
import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from collections.abc import Callable, Mapping, Sequence
from typing import Any

DEFAULT_RUNNER = "blacksmith-6vcpu-macos-26"
LARGE_RUNNER = "blacksmith-12vcpu-macos-26"
MACOS_15_RUNNER = "blacksmith-6vcpu-macos-15"
# Pool -> the variable holding its Xcode pin; "" keeps the pull-request lane's
# own pin, which is right for every macOS 26 pool.
POOLS = {
    LARGE_RUNNER: "",
    DEFAULT_RUNNER: "",
    MACOS_15_RUNNER: "CMUX_CI_XCODE_APP_MACOS_15",
}
DEFAULT_ORDER = (LARGE_RUNNER, DEFAULT_RUNNER, MACOS_15_RUNNER)
# Owned classes in preference order, ahead of Blacksmith in the default order
# once CI_PR_POOL_OWNED is 1. Their label embeds the lane's Xcode version, and
# their POOLS pin is "" (the lane's own), which is the Xcode that label names.
RUN_CLASSES = ("std", "light")
OWNED_LABEL = re.compile(r"glaeda-(?:xl|std|light)-xcode-[0-9]+(?:\.[0-9]+)*")
XCODE_APP = re.compile(r"/Xcode_([0-9]+(?:\.[0-9]+)*)\.app/?")
PR_XCODE_VARIABLE = "CMUX_CI_XCODE_APP_PR"
OWNED_VARIABLE = "CI_PR_POOL_OWNED"
SLOTS_VARIABLE = "CI_OWNED_POOL_SLOTS"
# A pull request run holds several macOS machines at once, each job on its
# own. Beside compile admission run the Claude wrapper, CLI pipe and remote
# daemon lanes; once admission passes, a full suite adds APP_HOST_SHARDS
# shards, tests-build-and-lag and cli-product-tests, a changed-suites run one
# shard, and a CLI change cli-product-tests. A run takes an owned pool only
# when its own peak (run_jobs) is free, so none of its jobs queues there. A
# run whose peak is unknown is charged MAX_RUN_JOBS. A run replayed since the
# snapshot is charged REPLAYED_RUN_JOBS, the peak of a compile-only run with
# every side lane, which is what the default pull request policy runs: a
# full-suite run among them is under-counted until the next snapshot, and a
# job that then finds its mini busy is refused or queued, and moved to
# Blacksmith by ci-owned-pool-rescue.yml.
APP_HOST_SHARDS = 7
SIDE_LANES = 3
MAX_RUN_JOBS = SIDE_LANES + APP_HOST_SHARDS + 2
REPLAYED_RUN_JOBS = SIDE_LANES + 1
# A snapshot older than this is not trusted to place a run on an owned pool.
OWNED_MAX_AGE_MINUTES = 20
# Pools whose machines are discarded after each job; the only ones a fork run may use.
EPHEMERAL_PREFIX = "blacksmith-"

OVERFLOW_VARIABLE = "CI_PR_POOL_OVERFLOW"
ORDER_VARIABLE = "CI_PR_POOL_ORDER"
MAX_QUEUED_VARIABLE = "CI_PR_POOL_MAX_QUEUED"
DEFAULT_MAX_QUEUED = 3
# Concurrent jobs one Blacksmith macOS pool ran at most, measured 2026-09-24:
# 10 or 11 on each 6vcpu pool while jobs queued behind them.
POOL_CAPACITY = 10

ARTIFACT_NAME = "macos-pool-load"
SNAPSHOT_FILE = "macos-pool-load.json"
SNAPSHOT_BRANCH = "main"
CI_WORKFLOW = "ci.yml"
MAX_SNAPSHOT_MINUTES = 45
PAGE_SIZE = 100
API = "https://api.github.com"


@dataclasses.dataclass(frozen=True)
class Settings:
    order: tuple[str, ...] = DEFAULT_ORDER
    max_queued: int = DEFAULT_MAX_QUEUED
    # Owned labels the order named for another Xcode than the lane's pin.
    stale: tuple[str, ...] = ()


def persistent(label: str) -> bool:
    """An owned pool: its machines outlive the job, so a queued job there can wait for good."""
    return bool(OWNED_LABEL.fullmatch(label or ""))


def owned_pools(pr_xcode_app: str | None) -> tuple[str, ...]:
    """The owned pool labels for the lane's Xcode pin; none when the pin names no version."""
    match = XCODE_APP.search(pr_xcode_app or "")
    if not match:
        return ()
    return tuple(f"glaeda-{name}-xcode-{match.group(1)}" for name in RUN_CLASSES)


@dataclasses.dataclass(frozen=True)
class Choice:
    runner: str  # "" keeps every job's own fallback expression
    xcode_app: str  # "" keeps every job's own Xcode pin
    reason: str
    # For a persistent runner only: the Blacksmith pool (the lane's own Xcode)
    # a re-run of failed jobs takes instead, since it reuses this run's pick.
    retry_runner: str = ""


def flag(value: str | None) -> bool:
    return (value or "").strip() == "true"


def run_jobs(*, macos: str | None, full_suite: str | None, unit_suite: str | None,
             unit_in_admission: str | None, claude_wrapper: str | None, cli: str | None,
             remote_daemon: str | None) -> int:
    """Most macOS machines this run holds at once, from the changes job's routing.

    Counted high on purpose: compile admission is assumed to run (the reuse
    checks come later), and a changed-suites canary that may yet be dropped
    counts its shard. ci-macos.yml runs admission for a macOS or a CLI change,
    and cli-product-tests after it for a CLI change or a full suite.
    """
    side = sum(flag(lane) for lane in (cli, remote_daemon))
    full = flag(macos) and flag(full_suite)
    side += flag(claude_wrapper) or full
    if not (flag(macos) or flag(cli)):
        return side
    shards = APP_HOST_SHARDS if full else int(flag(macos) and flag(unit_suite) and not flag(unit_in_admission))
    after = shards + full + (flag(cli) or full)
    return side + max(1, after)


def settings(overflow: str | None, order: str | None, max_queued: str | None,
             owned: str | None = None, pr_xcode_app: str | None = None) -> Settings | None:
    """Settings from repository variables; None when turned off or invalid.

    Owned pools are dropped from the order unless `owned` is "1", even when
    CI_PR_POOL_ORDER names them, so one variable turns the fleet on and off.
    An owned label for another Xcode than the lane's pin is dropped too and
    reported, so a moved pin never turns off the Blacksmith preference.
    """
    if (overflow or "").strip() == "0":
        return None
    use_owned = (owned or "").strip() == "1"
    current = owned_pools(pr_xcode_app)
    default = (current + DEFAULT_ORDER) if use_owned else DEFAULT_ORDER
    labels = tuple(label.strip() for label in (order or "").split(",") if label.strip()) or default
    if not use_owned:
        # Dropped before validation: a fork run reads the order without the
        # lane's Xcode pin, and must not lose the Blacksmith preference to it.
        labels = tuple(label for label in labels if not persistent(label))
        if not labels:
            return None
    stale = tuple(label for label in labels if persistent(label) and label not in current)
    labels = tuple(label for label in labels if label not in stale)
    if not labels:
        return None
    if len(set(labels)) != len(labels) or any(label not in POOLS and label not in current for label in labels):
        return None
    try:
        limit = int(max_queued) if (max_queued or "").strip() else DEFAULT_MAX_QUEUED
    except ValueError:
        return None
    if limit < 1:
        return None
    return Settings(labels, limit, stale)


def parse_time(value: str | None) -> dt.datetime | None:
    if not value:
        return None
    try:
        return dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def snapshot_age_minutes(snapshot: Mapping[str, Any], now: dt.datetime) -> float | None:
    generated = parse_time(str(snapshot.get("generated_at") or ""))
    if generated is None:
        return None
    return (now - generated).total_seconds() / 60


def slots(raw: str | None) -> dict[str, int]:
    """CI_OWNED_POOL_SLOTS: owned pool label -> machines. Anything malformed counts as none."""
    return _slots(raw)[0]


def slot_problems(raw: str | None) -> list[str]:
    """Why CI_OWNED_POOL_SLOTS, or an entry of it, counts as no machines.

    The picker treats all of these as zero slots, which is safe but silent: a
    mistyped label or a count of "11" or 11.0 just leaves the pool unused.
    main() turns each one into a workflow warning.
    """
    return _slots(raw)[1]


def _slots(raw: str | None) -> tuple[dict[str, int], list[str]]:
    if not (raw or "").strip():
        return {}, []
    try:
        data = json.loads(raw or "")
    except ValueError as error:
        return {}, [f"{SLOTS_VARIABLE} is not JSON ({error})"]
    if not isinstance(data, Mapping):
        return {}, [f"{SLOTS_VARIABLE} is not a JSON object"]
    counted, problems = {}, []
    for label, count in data.items():
        if not persistent(str(label)):
            problems.append(f"{SLOTS_VARIABLE} entry {label!r} is not an owned pool label (glaeda-<class>-xcode-<version>)")
        elif not isinstance(count, int) or isinstance(count, bool) or count <= 0:
            problems.append(f"{SLOTS_VARIABLE} entry {label!r} has {count!r} machines, not a positive whole number")
        else:
            counted[str(label)] = count
    return counted, problems


def pool(snapshot: Mapping[str, Any], label: str, owned_slots: Mapping[str, int] | None = None) -> Mapping[str, int]:
    """One pool's counts; a pool the janitor saw no job on is empty, not unknown.

    `capacity` is POOL_CAPACITY for a Blacksmith pool and the slot count for
    an owned pool (0 when CI_OWNED_POOL_SLOTS gives it none). `committed` is
    what the janitor counted the runs holding an owned pool to need at their
    peak, including jobs they have not created yet.
    """
    entry = (snapshot.get("pools") or {}).get(label) or {}
    counts = {key: int(entry.get(key) or 0)
              for key in ("queued", "running", "reserved_queued", "oldest_queued_minutes", "committed")}
    counts["capacity"] = int((owned_slots or {}).get(label) or 0) if persistent(label) else POOL_CAPACITY
    return counts


def describe(snapshot: Mapping[str, Any], label: str, owned_slots: Mapping[str, int] | None = None) -> str:
    counts = pool(snapshot, label, owned_slots)
    text = f"{label}: {counts['queued']} queued, {counts['running']} running"
    if persistent(label):
        text += f" of {counts['capacity']} slots"
    if counts["queued"]:
        text += f", oldest {counts['oldest_queued_minutes']} min"
    if counts["reserved_queued"]:
        text += f", {counts['reserved_queued']} release/nightly queued"
    return text


def effective_queue(counts: Mapping[str, int], added: int) -> int:
    """Queued jobs once `added` more arrive: they fill the pool's idle slots first.

    A pool with jobs queued is already full, so everything added queues. One
    with none queued has capacity - running idle slots to fill first.
    """
    idle = 0 if counts["queued"] else max(0, counts.get("capacity", POOL_CAPACITY) - counts["running"])
    return counts["queued"] + max(0, added - idle)


def owned_free(counts: Mapping[str, int], added_runs: int) -> int:
    """Machines of an owned pool still free once `added_runs` more runs took theirs.

    Taken is the larger of the jobs the janitor saw and what the runs holding
    the pool will need at their peak, so a run whose later jobs do not exist
    yet still counts them. Each run replayed since the snapshot is charged
    REPLAYED_RUN_JOBS, since its own peak is unknown here.
    """
    taken = max(counts["running"] + counts["queued"], counts.get("committed", 0))
    return counts.get("capacity", 0) - taken - added_runs * REPLAYED_RUN_JOBS


def pick(load: Mapping[str, Mapping[str, int]], added: Mapping[str, int], usable: Sequence[str],
         max_queued: int, jobs: int = MAX_RUN_JOBS) -> tuple[str, bool]:
    """The rule itself: first usable pool with headroom, else the fewest queued.

    An owned pool has headroom only while every job of this run gets a machine
    at once (`jobs` of them, its peak): a job queued there waits for that pool
    alone. It is never the fewest-queued fallback.
    """
    queued = {label: effective_queue(load[label], added[label]) for label in usable}
    for label in usable:
        if persistent(label):
            if owned_free(load[label], added[label]) >= max(1, jobs):
                return label, True
        elif queued[label] < max_queued:
            return label, True
    fallback = [label for label in usable if not persistent(label)] or list(usable)
    return min(fallback, key=lambda label: queued[label]), False


def decide(
    snapshot: Mapping[str, Any] | None,
    limits: Settings,
    *,
    now: dt.datetime,
    xcode_pins: Mapping[str, str],
    routed_since: int = 0,
    auto_xcode: bool = False,
    placed: Mapping[str, int] | None = None,
    choose_from: Sequence[str] | None = None,
    owned_slots: Mapping[str, int] | None = None,
    jobs: int = MAX_RUN_JOBS,
) -> Choice:
    """The preference rule over a janitor snapshot. Uncertainty keeps today's route.

    `routed_since` runs were created after the snapshot and each already took
    a pool by this rule; they are replayed first. `placed` counts runs created
    since the snapshot whose pool is already known (an E2E run names it), one
    job each. `auto_xcode` (a fork run, which has no pins) lets every pool
    fall back to each job selecting its pool's newest SDK 26 Xcode.
    `choose_from` limits the final pick to some pools of the order (E2E stays
    on macOS 26) while the replay still spreads over the whole order. `jobs`
    is this run's peak machine count, which an owned pool must have free.
    Replayed runs are placed as if they needed one machine (so any that could
    have taken an owned pool is assumed to) and charged REPLAYED_RUN_JOBS there.
    """
    if not isinstance(snapshot, Mapping) or not isinstance(snapshot.get("pools"), Mapping):
        return Choice("", "", "no readable pool snapshot")
    age = snapshot_age_minutes(snapshot, now)
    if age is None or age < -5 or age > MAX_SNAPSHOT_MINUTES:
        return Choice("", "", f"pool snapshot is stale or undated (age {age if age is None else round(age)} min)")
    try:
        load = {label: pool(snapshot, label, owned_slots) for label in limits.order}
    except (TypeError, ValueError, AttributeError):
        return Choice("", "", "malformed pool snapshot")

    def xcode(label: str) -> str | None:
        variable = POOLS.get(label, "")
        if not variable or auto_xcode:
            return ""
        return (xcode_pins.get(variable) or "").strip() or None

    def counted(label: str) -> bool:
        """An owned pool places runs only with a slot count and a fresh snapshot."""
        if not persistent(label):
            return True
        return age <= OWNED_MAX_AGE_MINUTES and load[label]["capacity"] > 0

    usable = [label for label in limits.order
              if load[label]["reserved_queued"] == 0 and xcode(label) is not None and counted(label)]
    if not usable:
        return Choice("", "", "every pool in the order is reserved, has no Xcode pin, or is an owned pool "
                              "without slots or a fresh snapshot")
    candidates = [label for label in usable if choose_from is None or label in choose_from]
    if not candidates:
        return Choice("", "", "every pool this run may take is reserved or has no Xcode pin")
    skipped = [label for label in limits.order if label not in usable]
    note = f"; skipped {', '.join(skipped)} (reserved, no Xcode pin, or owned without slots or a fresh snapshot)" if skipped else ""
    added = {label: max(0, int((placed or {}).get(label) or 0)) for label in usable}
    for _ in range(max(0, routed_since)):
        earlier, _ = pick(load, added, usable, limits.max_queued, jobs=1)
        added[earlier] += 1
    label, headroom = pick(load, added, candidates, limits.max_queued, jobs)
    if persistent(label) and not headroom:
        return Choice("", "", "every owned pool this run may take is busy, and no other pool is in the order")
    replayed = sum(added.values())
    replay = f" after replaying {replayed} newer run(s)" if replayed else ""
    if headroom and persistent(label):
        free = owned_free(load[label], added[label])
        why = (f"first pool in order with headroom ({free} of {load[label]['capacity']} owned machines free, "
               f"this run needs {max(1, jobs)}){replay}")
    elif headroom:
        why = f"first pool in order with headroom (< {limits.max_queued} queued){replay}"
    else:
        why = f"no pool has headroom{replay}; fewest queued"
    if limits.stale:
        note += f"; dropped {', '.join(limits.stale)} (not the lane's Xcode pin)"
    retry = ""
    if persistent(label):
        # A re-run of failed jobs keeps this run's outputs, so it needs a pool
        # named now: the Blacksmith pool this rule would take on the lane's
        # own Xcode, which is also the Xcode the owned label names.
        lane = [pool_label for pool_label in usable if not persistent(pool_label) and not POOLS.get(pool_label)]
        retry = pick(load, added, lane, limits.max_queued)[0] if lane else DEFAULT_RUNNER
    return Choice(label, xcode(label) or "", why + note, retry)


def choose(
    *,
    event: str,
    repo: str,
    head_repo: str,
    default_runner: str,
    overflow: str | None,
    order: str | None,
    max_queued: str | None,
    xcode_pins: Mapping[str, str],
    owned: str | None = None,
    owned_slots: str | None = None,
    jobs: int = MAX_RUN_JOBS,
    fetch: Callable[[], Mapping[str, Any] | None],
    count_routed: Callable[[str], int] = lambda since: 0,
    now: dt.datetime,
    run_attempt: int = 1,
) -> tuple[Choice, Mapping[str, Any] | None]:
    """The pool for this run and the snapshot it was read from (None when none was read)."""
    if event != "pull_request":
        return Choice("", "", f"{event or 'unknown'} event; not a pull request"), None
    if not head_repo:
        return Choice("", "", "pull request head repository unknown"), None
    fork = head_repo != repo
    if not fork:
        if (default_runner or "").strip() != DEFAULT_RUNNER:
            return Choice("", "", f"MACOS_RUNNER_PR is {default_runner or 'unset'}, not {DEFAULT_RUNNER}"), None
        limits = settings(overflow, order, max_queued, owned, xcode_pins.get(PR_XCODE_VARIABLE))
        if limits is None:
            return Choice("", "", f"{OVERFLOW_VARIABLE} is 0, or {ORDER_VARIABLE}/{MAX_QUEUED_VARIABLE} "
                                  "is invalid"), None
    try:
        snapshot = fetch()
    except Exception as error:  # noqa: BLE001 - every failure keeps the default
        return Choice("", "", f"could not read the pool snapshot ({error})"), None
    if fork:
        # No repository variables reach a fork run; the janitor copied them.
        copied = snapshot.get("settings") if isinstance(snapshot, Mapping) else None
        if not isinstance(copied, Mapping):
            return Choice("", "", "fork head; the snapshot carries no settings"), snapshot
        if str(copied.get("lane") or "").strip() != DEFAULT_RUNNER:
            return Choice("", "", f"fork head; the lane is {copied.get('lane') or 'unset'}, "
                                  f"not {DEFAULT_RUNNER}"), snapshot
        limits = settings(copied.get("overflow"), copied.get("order"), copied.get("max_queued"))
        if limits is None:
            return Choice("", "", f"fork head; {OVERFLOW_VARIABLE} is 0, or the copied settings "
                                  "are invalid"), snapshot
        # Fork code runs only on ephemeral Blacksmith machines, never on a
        # persistent pool (owned Macs) that may join POOLS later.
        limits = dataclasses.replace(limits, order=tuple(
            label for label in limits.order if label.startswith(EPHEMERAL_PREFIX)))
        if not limits.order:
            return Choice("", "", "fork head; no ephemeral pool in the order"), snapshot
    retry = run_attempt > 1
    if retry:
        limits = dataclasses.replace(limits, order=tuple(label for label in limits.order if not persistent(label)))
        if not limits.order:
            return Choice("", "", f"retry attempt {run_attempt}; no ephemeral pool in the order"), snapshot
    if not isinstance(snapshot, Mapping) or not snapshot.get("generated_at"):
        return Choice("", "", "no readable pool snapshot"), snapshot
    try:
        routed = count_routed(str(snapshot["generated_at"]))
    except Exception as error:  # noqa: BLE001 - every failure keeps the default
        return Choice("", "", f"could not count runs since the snapshot ({error})"), snapshot
    choice = decide(snapshot, limits, now=now, xcode_pins={} if fork else xcode_pins,
                    routed_since=routed, auto_xcode=fork, owned_slots={} if fork else slots(owned_slots),
                    jobs=jobs)
    if fork and choice.runner:
        choice = dataclasses.replace(choice, reason=f"fork head; {choice.reason}")
    if retry and choice.runner:
        choice = dataclasses.replace(choice, reason=f"retry attempt {run_attempt}; {choice.reason}")
    return choice, snapshot


def count_in_flight(runs: Sequence[Mapping[str, Any]], *, exclude_run_id: int | None) -> int:
    return sum(1 for run in runs if run.get("id") != exclude_run_id and run.get("status") != "completed")


def trusted_snapshot_artifact(artifact: Mapping[str, Any], branch: str) -> bool:
    """Uploaded by a run on `branch` of this repository itself, not a fork or another branch."""
    run = artifact.get("workflow_run") or {}
    return (
        not artifact.get("expired")
        and run.get("head_branch") == branch
        and run.get("repository_id") is not None
        and run.get("head_repository_id") == run.get("repository_id")
    )


def newest_snapshot_artifact(artifacts: Sequence[Any], *, now: dt.datetime,
                             branch: str = SNAPSHOT_BRANCH) -> Mapping[str, Any] | None:
    """The newest trusted snapshot artifact young enough to read, or None."""
    trusted = [artifact for artifact in artifacts
               if isinstance(artifact, Mapping) and trusted_snapshot_artifact(artifact, branch)]
    if not trusted:
        return None
    newest = max(trusted, key=lambda artifact: str(artifact.get("created_at") or ""))
    created = parse_time(newest.get("created_at"))
    if created is None or (now - created).total_seconds() / 60 > MAX_SNAPSHOT_MINUTES:
        return None
    return newest


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:
        return None


class GitHub:
    def __init__(self, token: str, repo: str) -> None:
        self.repo = repo
        self.headers = {
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
            "User-Agent": "cmux-ci-pr-runner-pool",
        }

    def get(self, path: str) -> Any:
        request = urllib.request.Request(f"{API}/repos/{self.repo}{path}", headers=self.headers)
        with urllib.request.urlopen(request, timeout=15) as response:
            return json.loads(response.read())

    def snapshot(self, *, now: dt.datetime, branch: str = SNAPSHOT_BRANCH) -> Mapping[str, Any] | None:
        """The newest trusted, unexpired janitor snapshot, in two API requests."""
        artifacts = self.get(f"/actions/artifacts?name={ARTIFACT_NAME}&per_page={PAGE_SIZE}").get("artifacts") or []
        newest = newest_snapshot_artifact(artifacts, now=now, branch=branch)
        if newest is None:
            return None
        archive = zipfile.ZipFile(io.BytesIO(self.download(newest)))
        return json.loads(archive.read(SNAPSHOT_FILE))

    def download(self, artifact: Mapping[str, Any]) -> bytes:
        """One artifact's zip archive (one API request)."""
        # The download answers with a redirect to signed blob storage, which must
        # not receive the token, so follow it by hand.
        opener = urllib.request.build_opener(_NoRedirect)
        download = urllib.request.Request(str(artifact["archive_download_url"]), headers=self.headers)
        try:
            opener.open(download, timeout=15)
            raise RuntimeError("artifact download did not redirect")
        except urllib.error.HTTPError as error:
            location = error.headers.get("Location") if error.code in (301, 302, 303, 307, 308) else None
            if not location:
                raise RuntimeError(f"artifact download failed ({error.code})") from error
        blob = urllib.request.Request(location, headers={"User-Agent": self.headers["User-Agent"]})
        with urllib.request.urlopen(blob, timeout=30) as response:
            return response.read()

    def runs_since(self, workflow: str, since: str, **filters: str) -> list[Mapping[str, Any]]:
        """One page of `workflow`'s runs created at or after `since` (one request)."""
        query = urllib.parse.urlencode({**filters, "created": f">={since}", "per_page": PAGE_SIZE})
        runs = self.get(f"/actions/workflows/{workflow}/runs?{query}").get("workflow_runs") or []
        return [run for run in runs if isinstance(run, Mapping)]

    def pull_request_runs_since(self, since: str, *, exclude_run_id: int | None) -> int:
        """CI pull request runs created at or after `since` and still in flight (one request).

        A finished run (cancelled, superseded, or one with no macOS work)
        holds no pool, so it is not replayed. Each replayed run weighs one
        job, its compile admission: pull request runs are compile-only by
        default, so a full-suite run's shards are under-counted.
        """
        runs = self.runs_since(CI_WORKFLOW, since, event="pull_request")
        return count_in_flight(runs, exclude_run_id=exclude_run_id)


def summary(choice: Choice, snapshot: Mapping[str, Any] | None, *, now: dt.datetime,
            owned_slots: Mapping[str, int] | None = None, problems: Sequence[str] = ()) -> str:
    runner = choice.runner or "each job's default (MACOS_RUNNER_PR or its fallback)"
    lines = ["### macOS pool for this run", "", f"- Pool: `{runner}`", f"- Why: {choice.reason}"]
    if choice.xcode_app:
        lines.append(f"- Xcode: `{choice.xcode_app}`")
    if choice.retry_runner:
        lines.append(f"- A re-run of failed jobs goes to: `{choice.retry_runner}`")
    for problem in problems:
        lines.append(f"- **Warning:** {problem}; that pool gets no machines")
    if isinstance(snapshot, Mapping) and isinstance(snapshot.get("pools"), Mapping):
        age = snapshot_age_minutes(snapshot, now)
        lines.append(f"- Queue seen by the janitor at {snapshot.get('generated_at')}"
                     + (f" ({round(age)} min before this run)" if age is not None else "") + ":")
        for label in [*POOLS, *sorted(owned_slots or {})]:
            lines.append(f"  - {describe(snapshot, label, owned_slots)}")
    return "\n".join(lines) + "\n"


def main(argv: Sequence[str] | None = None, env: Mapping[str, str] | None = None) -> int:
    env = os.environ if env is None else env
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--snapshot", help="read the snapshot from this file instead of the API")
    args = parser.parse_args(argv)
    now = dt.datetime.now(dt.timezone.utc)
    repo = env.get("GITHUB_REPOSITORY") or ""
    token = env.get("GH_TOKEN") or env.get("GITHUB_TOKEN") or ""
    run_id = (env.get("GITHUB_RUN_ID") or "").strip()
    attempt = (env.get("GITHUB_RUN_ATTEMPT") or "").strip()

    def client() -> GitHub:
        if not token or not repo:
            raise RuntimeError("GH_TOKEN and GITHUB_REPOSITORY are required")
        return GitHub(token, repo)

    def fetch() -> Mapping[str, Any] | None:
        if args.snapshot:
            with open(args.snapshot, encoding="utf-8") as handle:
                return json.load(handle)
        return client().snapshot(now=now, branch=(env.get("POOL_SNAPSHOT_BRANCH") or SNAPSHOT_BRANCH))

    def count_routed(since: str) -> int:
        if args.snapshot:
            return 0
        return client().pull_request_runs_since(since, exclude_run_id=int(run_id) if run_id.isdigit() else None)

    # The changes job's routing, when the step runs after it; without it every
    # run is charged the most machines any run can hold.
    jobs = MAX_RUN_JOBS if "RUN_MACOS" not in env else run_jobs(
        macos=env.get("RUN_MACOS"), full_suite=env.get("RUN_FULL_SUITE"), unit_suite=env.get("RUN_UNIT_SUITE"),
        unit_in_admission=env.get("RUN_UNIT_IN_ADMISSION"), claude_wrapper=env.get("RUN_CLAUDE_WRAPPER"),
        cli=env.get("RUN_CLI"), remote_daemon=env.get("RUN_REMOTE_DAEMON"))
    choice, snapshot = choose(
        event=env.get("EVENT_NAME") or "",
        repo=repo,
        head_repo=env.get("HEAD_REPO") or "",
        default_runner=env.get("DEFAULT_RUNNER") or "",
        overflow=env.get("POOL_OVERFLOW"),
        order=env.get("POOL_ORDER"),
        max_queued=env.get("POOL_MAX_QUEUED"),
        owned=env.get("POOL_OWNED"),
        owned_slots=env.get("OWNED_SLOTS"),
        jobs=jobs,
        xcode_pins={variable: env.get(variable) or ""
                    for variable in {*POOLS.values(), PR_XCODE_VARIABLE} if variable},
        fetch=fetch,
        count_routed=count_routed,
        now=now,
        run_attempt=int(attempt) if attempt.isdigit() else 1,
    )
    problems = slot_problems(env.get("OWNED_SLOTS")) if (env.get("POOL_OWNED") or "").strip() == "1" else []
    for problem in problems:
        print(f"::warning title={SLOTS_VARIABLE}::{problem}")
    text = summary(choice, snapshot, now=now, owned_slots=slots(env.get("OWNED_SLOTS")), problems=problems)
    print(text)
    if env.get("GITHUB_STEP_SUMMARY"):
        with open(env["GITHUB_STEP_SUMMARY"], "a", encoding="utf-8") as handle:
            handle.write(text)
    if env.get("GITHUB_OUTPUT"):
        with open(env["GITHUB_OUTPUT"], "a", encoding="utf-8") as handle:
            handle.write(f"runner={choice.runner}\nxcode_app={choice.xcode_app}\n"
                         f"persistent={'true' if persistent(choice.runner) else 'false'}\n"
                         f"retry_runner={choice.retry_runner}\njobs={jobs}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
