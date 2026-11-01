#!/usr/bin/env python3
"""cmux-next's macOS cascade: idle minis, Blacksmith 12 vCPU, 6 vCPU, then the minis' queue.

side_lane_placement.py gives an idle owned side runner to each job it can and
leaves the rest queued on the owned label. Until this cascade, a busy fleet
meant every remaining job waited there for the rescue's ten-minute budget, and
the bot's attempt 3 then sent the compile jobs to vars.MACOS_RUNNER_26
(Blacksmith 12 vCPU) and the session jobs to Blacksmith 6 vCPU, however full
either was. From 14:00Z to 21:15Z on 2026-10-19, 533 cmux-next and ci.yml jobs
asked for blacksmith-12vcpu-macos-26; the ones that got a runner waited a
median 40 minutes (p90 68). The label never ran more than six at once (five in
11 of the 20 five-minute samples it had a queue), the "about 5" Blacksmith
gives us. Meanwhile the minis' side label queued at p90 29 minutes.

The cascade places the jobs that idle minis did not take, in the placement's
priority order, while each Blacksmith label has a free slot now:
blacksmith-12vcpu-macos-26 (CAPACITY 5) first, then blacksmith-6vcpu-macos-26
(CAPACITY 10), at most MAX_PER_RUN on each label. When the owned runners were
read and none was idle for them (`saturated`), the rest take 6 vCPU's queue
while it moves and is short (overflow(): not stalled, fewer than
OVERFLOW_BACKLOG queued ahead, MAX_PER_RUN a run), and with the counts unread
up to MAX_PER_RUN of them take 6 vCPU, as a feed's compile does. Only what is
left then stays queued on the owned label, where the rescue still watches it:
the placement is the only lever, since GitHub never moves a queued job and a
refusals-only run is never re-run for its queue (cmux#26723's fast tier waited
on the side label for hours on 2026-10-29).

Only CASCADE_JOBS take part, and only those the workflow says run on this route
(CASCADE_RUNS: not fast-tier while an idle vars.CI_FAST_LANE_RUNNER runner takes
it, not a job path routing or labels skip), so no slot is spent on a job
that never asks for it. The jobs that need a logged-in session (swift-test,
daemon-test, generated-files) keep the gui route. release-compile cascades too
(2026-10-21 ~20:10Z: 76 Release compiles queued on the minis); off a mini it
skips the CEF shim compile, which is advisory and already skipped by a
Blacksmith re-run. On attempt 1 of a feat-cmux-next push it compiles on the
reserved promotion mini (PROMOTE_LABEL, vars.CI_NEXT_PROMOTE_POOL): while a
runner there is idle it stays there and takes no slot, and with none idle it
takes a Blacksmith slot ahead of the other jobs, since it gates the nightly-next
request. It never counts against an idle side mini then: it does not run there.

The labels are not independent: every Blacksmith macOS label the organization
runs (these two and blacksmith-6vcpu-macos-15) draws on one pool of POOL_VCPU
vCPUs, so a job takes a label only while that pool has room for it
(pool_room()). From 13:34Z to 21:30Z on 2026-10-26, 53 of 55 placements sampled saw 12
vCPU with no runner in flight, while 6 vCPU ran up to ten at once
(60 vCPU; the janitor's snapshots never saw this repository's Blacksmith macOS
jobs run more than 60 vCPU at once). The old per-label count saw "0 in flight + 0
queued of 5" on 12 vCPU and sent jobs there that waited behind the pool: two DEV
Release compiles, runs 40386035282 and 40386506758, queued at 19:25Z and started
at 20:42Z and 20:52Z. A 12 vCPU job needs twelve vCPUs freed at once, so while
any Blacksmith macOS job queues the 6 vCPU jobs take each freed slot first:
LARGE takes a job only while nothing queues on any Blacksmith macOS label
(pool_queued()), and otherwise SMALL does.

A slot counted free can still be taken by another run placing in the same
snapshot window, and nothing rescues a job queued on Blacksmith. MAX_PER_RUN
bounds how far a burst of runs can overfill a label.

A free slot is CAPACITY less the jobs in flight and the jobs already queued:
- In flight comes live from the organization's runner groups. Blacksmith
  registers each label's just-in-time runners in its own scale-set group
  ("Blacksmith scale sets - <label>"); a runner online there holds a job or is
  about to take one. That is one request for the group list and one per label.
  A pool label whose group is not visible here counts the snapshot's running
  jobs instead (with_running()).
- Queued comes from the queue janitor's pool snapshot (macos-pool-load), the
  only repository-wide job listing, read with the job's GITHUB_TOKEN. It counts
  only while it is at most QUEUE_SNAPSHOT_MINUTES old: a job sent to a label with
  a backlog would wait behind it, so without a fresh count nothing cascades.
Anything unread places nothing, which is today's route.

A stalled label gets no job, whatever its free slots say (stalled()). On
2026-10-20 Blacksmith's macOS starts stopped (status.blacksmith.sh, "Delayed job
starts on macOS runners"): with no runner online the slots all counted free,
so every run's cascade kept sending jobs to labels where none started, about
80 by 10:50Z. The janitor's snapshot (the same read as the queued counts)
records each label's oldest queued job; by now it has waited that long plus
the snapshot's age. A label is stalled when that wait is STALL_MINUTES or
more, or when the snapshot itself saw it wait IDLE_STALL_MINUTES or more and
the label has no runner online now (age is not added there: an idle scale set
has no runner online, and a job queued at snapshot time may since have run):
a moving Blacksmith label starts a job in a few minutes (6 vCPU: median 2.6
min, p90 14.7, 2026-10-20 01:04Z to 02:35Z).

A dead label counts as stalled too, with or without a queue (dead():
simple_pool_picker.blacksmith_dead(), nothing running and no job started on it
for an hour, read from a snapshot up to six hours old). The stall rule alone
cannot tell a dead label from a busy one, and a label whose queue was cleared
reads as free: on 2026-10-30 blacksmith-12vcpu-macos-26 had started nothing for
about a day. A dead label takes no slot, no overflow and no retry_runner, and a
feed's compile counts it full (fresh_stalled()), while another label shows
life; with every label dead the snapshot says nothing to choose by.

Only owned Macs participate in this cascade. Before it existed, fast-tier and
swift-canary overflowed to an external macOS runner while Blacksmith was full or
stalled, and built cold there for up to 45 minutes; the fast-tier seed kept that
external pool warm (21 jobs, 891 minutes a day). A job Blacksmith cannot take
(no free slot, and 6 vCPU stalled or backed up: overflow()) stays on the owned
label, where an idle mini or the rescue takes it
(tests/test_ci_no_github_hosted_macos.py). A feed's compile (FRESH_JOBS: a DEV
daily, a feat-cmux-next push) counts a label whose oldest queued job has waited
FRESH_STALL_MINUTES as full, and so does its last resort when the runner groups
are unread: the compile takes the owned label then (the DEV slot while idle, else
the side queue).

The rescue's full re-run (attempt 2, triggered by RESCUE_ACTOR: bot_rerun()) is
placed afresh, from what is free when it starts, instead of reading nothing:
until 2026-10-26 the placement skipped every attempt after 1, so the re-run's
outputs were empty and its cascade jobs went back to the end of the owned side
queue they had just waited in (rerun-failed-jobs carries attempt 1's outputs,
read while that queue was already full). Only the cascade's outputs are written
then; side_lane_placement.py leaves the owned routes (runner, gui_runner,
fast_runner, gateway_runner) empty, as a re-run had them. An idle mini still
comes first: a re-run job the idle minis would take gets no Blacksmith slot and
no overflow label, so it takes the owned side label, where that mini is.

`retry_runner` is the Blacksmith label the bot's overflow attempt (2 or
later: the rescue's re-runs) takes for these jobs: among moving (not stalled)
labels with a free slot, the lowest (in flight + queued) / capacity, the
larger label on a tie (retry_label). With no free, moving slot it is empty, and the job takes the
owned side label: waiting behind the fleet is acceptable, waiting in a
Blacksmith queue is not (Leo, 2026-10-20: 5+ hour waits on 12 vCPU, about 95
PRs behind 318 queued runs). It is written as `free_retry_runner`, a key a
placement script that predates the rule never writes, so a pull request still
running the old script from its base gets the owned fallback instead of a full
label. It is computed with the same reads, at attempt 1, as classic's picker
computes its retry_runner.
"""
from __future__ import annotations

import dataclasses
import datetime as dt
import json
import time
import sys
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Callable, Mapping, Sequence

sys.path.insert(0, __import__("os").path.dirname(__import__("os").path.abspath(__file__)))
import simple_pool_picker as _picker_rule  # noqa: E402 - the one Blacksmith stall rule

LARGE = "blacksmith-12vcpu-macos-26"
SMALL = "blacksmith-6vcpu-macos-26"
LABELS = (LARGE, SMALL)
# Every Blacksmith macOS label draws on one organization pool; cmux-next places only on LABELS, but the
# others' jobs use the same vCPUs (classic CI's vars.MACOS_RUNNER_15 is blacksmith-6vcpu-macos-15).
POOL_LABELS = (*LABELS, "blacksmith-6vcpu-macos-15")
# The pool's size: ten 6 vCPU jobs at most in flight at once (2026-10-26 19:35Z, with 12 vCPU at none), the
# same 60 vCPU as the five 12 vCPU and the ten 6 vCPU slots CAPACITY counted when they were read as separate.
POOL_VCPU = 60
# simple_pool_picker.blacksmith_stalled(), the one Blacksmith stall rule (10 min): every picker reads the same
# figure. 2026-10-27: 82 jobs queued on the two macOS 26 labels (oldest 396 min) with 3 running.
STALL_MINUTES = _picker_rule.BLACKSMITH_STALL_MINUTES
IDLE_STALL_MINUTES = 5
# A feed's compile (FRESH_JOBS) counts a stalled label as full too: 2026-10-26 22:25Z to
# 01:30Z, 92 jobs queued on 6 vCPU (oldest 148 min) while a DEV Release compile queued there.
FRESH_STALL_MINUTES = STALL_MINUTES
# simple_pool_picker.CAPACITY's figures for these labels. 12 vCPU: at most six
# at once, five whenever it had a queue (2026-10-19); 6 vCPU: ten online at 21:40Z.
CAPACITY = {LARGE: 5, SMALL: 10}
# Headless compile and test jobs. A job missing here never leaves the minis on attempt 1.
CASCADE_JOBS = ("fast-tier", "swift-canary", "cmux-scheme-compile", "release-compile")
# The jobs a feat-cmux-next push runs on the promotion mini (PROMOTE_LABEL) instead of the side label.
PROMOTE_JOBS = ("release-compile",)
MAX_PER_RUN = 2
# The overflow (overflow()) joins 6 vCPU's queue only while fewer than this many jobs wait ahead of it on the
# labels whose jobs take 6 vCPU's freed slots: one turn of its ten slots, so a job there waits at most about
# one job's length. A longer queue, like a stalled one, keeps the owned label.
OVERFLOW_BACKLOG = 10
# Jobs a feed's freshness waits on (FRESH_JOBS: a feat-cmux-next push's Release compile, a DEV daily's
# Release compile). When the counts cannot be read they take SMALL, the last resort, instead of the owned
# label: on 2026-10-26 the route token read 403 and the queue snapshot was stale, so every DEV compile from
# 20:15Z on queued behind ~260 jobs on glaeda-side/std and the DEV feed fell 100 minutes behind (Leo,
# 2026-10-24: a feed is never more than 30 minutes behind its branch).
# The rescue's re-runs (owned_pool_rescue.py) come from GITHUB_TOKEN's actor or, with the cmux-bot App's
# token, from cmux-bot[bot] (pr_runner_pool.RESCUE_ACTORS).
RESCUE_ACTOR = "github-actions[bot]"
RESCUE_ACTORS = frozenset({RESCUE_ACTOR, "cmux-bot[bot]"})
# The step has two minutes, and the placement's own reads come first.
READ_BUDGET_SECONDS = 45
QUEUE_SNAPSHOT_MINUTES = 15
# glaeda's per-label listener health is deliberately a tighter freshness
# contract than the Blacksmith queue counts.  A missing or stale health record
# must overflow a job that has already waited three minutes; it must never
# turn that job into an unbounded wait on an owned label.
OWNED_HEALTH_STALE_SECONDS = 5 * 60
OWNED_HEALTH_QUEUE_SECONDS = 3 * 60
# How old a snapshot may be and still hold a Blacksmith label for the freshness work it shows queued there
# (reserved_from()): pr_runner_pool.MAX_SNAPSHOT_MINUTES, the oldest artifact the read fetches at all.
RESERVED_SNAPSHOT_MINUTES = 45
SCALE_SET_GROUP = "Blacksmith scale sets - {label}"
API = "https://api.github.com"
# A refused read is logged with its detail and raised, never retried here: the reads share
# READ_BUDGET_SECONDS (45 s), which a wait would only spend before the answer is dropped.

# What a refused GitHub read said: its status, the rate-limit headers and the start of its
# body ("secondary rate limit", "Resource not accessible by integration", ...). urllib's own
# message is only "HTTP Error 403: Forbidden", which cannot tell those apart.
REFUSAL_HEADERS = ("Retry-After", "X-RateLimit-Remaining", "X-RateLimit-Resource")


def refusal(error: "urllib.error.HTTPError") -> str:
    headers = error.headers or {}
    shown = " ".join(f"{name}={headers.get(name)}" for name in REFUSAL_HEADERS if headers.get(name) is not None)
    try:
        body = " ".join(error.read(2000).decode("utf-8", "replace").split())[:300]
    except Exception:  # noqa: BLE001 - the detail is best effort
        body = ""
    return f"HTTP {error.code}" + (f" {shown}" if shown else "") + (f" body: {body}" if body else "")




@dataclasses.dataclass(frozen=True)
class Placement:
    jobs: Mapping[str, tuple[str, ...]]  # Blacksmith label -> the jobs it takes now
    retry_runner: str
    why: str
    # The labels a feed's compile counts as full (fresh_stalled()); release-compile's re-run route reads them.
    fresh_stall: tuple[str, ...] = ()
    # Jobs for which every owned and Blacksmith macOS target is full/dead;
    # cmux-next sends these to the thin build-fleet gateway.
    fleet_jobs: tuple[str, ...] = ()
    # Jobs allowed to consume retry_runner on a rescue attempt, capped by MAX_PER_RUN and pool room.
    retry_jobs: tuple[str, ...] = ()


def vcpus(label: str) -> int:
    """The vCPUs one job on a Blacksmith label takes: the `<n>vcpu` in its name."""
    size = label.removeprefix("blacksmith-").split("vcpu-", 1)[0]
    return int(size) if size.isdigit() else 0


def pool_label(label: str) -> bool:
    """A Blacksmith macOS label: it draws on the organization's one macOS pool."""
    return label.startswith("blacksmith-") and "-macos-" in label and vcpus(label) > 0


def label_full_or_dead(label: str, snapshot: Mapping[str, Any] | None,
                       *, live: int = 0, queued: int = 0,
                       now: dt.datetime | None = None, queued_wait_s: float | None = None) -> bool:
    """One adapter for owned listener health and bs_health.label_outages.

    The dashboard exports outages as [{pool, queued, running, oldest_wait_s,
    last_start_s}]. At-capacity backlog is full, independently of outages.
    """
    now = now or dt.datetime.now(dt.timezone.utc)
    if label.startswith("glaeda-"):
        return owned_label_full(snapshot, label, now, queued_wait_s=queued_wait_s)
    if not pool_label(label):
        return False
    snapshot = snapshot if isinstance(snapshot, Mapping) else {}
    # Owned gates have their own clock; they must not keep expired Blacksmith
    # outages or capacity readings alive. Nightly reservations expire separately.
    if _fresh(snapshot, now) is None:
        return False
    health = snapshot.get("bs_health") or {}
    outages = health.get("label_outages", []) if isinstance(health, Mapping) else []
    for outage in outages if isinstance(outages, list) else []:
        if not isinstance(outage, Mapping) or outage.get("pool") != label:
            continue
        try:
            last = outage.get("last_start_s")
            if (int(outage.get("queued", 0)) > 0 and last is not None and float(last) > 1800):
                return True
        except (TypeError, ValueError):
            continue
    gates = snapshot.get("gates") if isinstance(snapshot, Mapping) else None
    labels = gates.get("labels") if isinstance(gates, Mapping) else None
    entry = labels.get(label) if isinstance(labels, Mapping) else None
    if isinstance(entry, Mapping):
        try:
            q = int(entry.get("queued", 0))
            oldest = float(entry.get("oldest_queued_s", 0))
            listening = int(entry.get("listening", live))
            held = entry.get("held_offline") or {}
            held_total = int(held.get("total", 0)) if isinstance(held, Mapping) else 0
            return (q > 0 and oldest >= OWNED_HEALTH_QUEUE_SECONDS) or (listening == 0 and held_total > 0)
        except (TypeError, ValueError):
            return True if queued > 0 else False
    if isinstance(snapshot, Mapping):
        pools = snapshot.get("pools") or {}
        legacy = pools.get(label) if isinstance(pools, Mapping) else None
        if isinstance(legacy, Mapping) and ("cap" in legacy or "capacity" in legacy):
            try:
                cap = int(legacy.get("cap", legacy.get("capacity", 0)))
                return cap > 0 and max(int(queued), int(legacy.get("queued", 0))) > 0 and max(int(live), int(legacy.get("running", 0))) >= cap
            except (TypeError, ValueError):
                pass
    return False


def in_flight(groups: Sequence[Mapping[str, Any]], runners_of: Callable[[int], Sequence[Mapping[str, Any]]],
              ) -> dict[str, int] | None:
    """Each pool label's online just-in-time runners, from its scale-set group; None when a LABELS group is
    missing. Another pool label is counted while its group is visible, else left to with_running()."""
    by_name = {str(group.get("name") or ""): group.get("id") for group in groups if isinstance(group, Mapping)}
    counts: dict[str, int] = {}
    for label in POOL_LABELS:
        group = by_name.get(SCALE_SET_GROUP.format(label=label))
        if not isinstance(group, int):
            if label in LABELS:
                return None
            continue
        counts[label] = sum(1 for runner in runners_of(group) if runner.get("status") == "online")
    return counts


def with_running(live: Mapping[str, int], snapshot: Mapping[str, Any] | None, now: dt.datetime) -> dict[str, int]:
    """`live`, plus the fresh snapshot's running jobs on each pool label no visible group counted."""
    counts = dict(live)
    fresh = _fresh(snapshot, now)
    if fresh is not None:
        for label in fresh[1]:
            if pool_label(str(label)) and label not in counts:
                counts[str(label)] = _field(fresh[1], str(label), "running")
    return counts


def pool_queued(waiting: Mapping[str, int]) -> int:
    """The jobs queued on every Blacksmith macOS label."""
    return sum(count for label, count in waiting.items() if pool_label(label))


def pool_room(live: Mapping[str, int], waiting: Mapping[str, int]) -> int:
    """The pool's vCPUs neither in flight nor promised to a queued job (negative when oversubscribed).

    A job queued on LARGE holds no room: it waits for twelve vCPUs freed at once while the 6 vCPU jobs
    take each freed slot (2026-10-26 20:38Z to 20:47Z: six queued on 12 vCPU for 78 to 83 minutes while
    6 vCPU ran seven and five with none queued).
    """
    return POOL_VCPU - sum(vcpus(label) * count for counts in (live, waiting)
                           for label, count in counts.items()
                           if pool_label(label) and not (counts is waiting and label == LARGE))


def fits(label: str, room: int, queue: int) -> bool:
    """Whether a job on `label` starts now: the pool has its vCPUs, and for LARGE nothing queues ahead."""
    return room >= vcpus(label) and (label != LARGE or queue == 0)


@dataclasses.dataclass(frozen=True)
class Seen:
    """What else the snapshot says: each label's oldest queued wait by now (minutes)."""
    waits: Mapping[str, float]
    age: float = 0.0  # the snapshot's age in minutes, already in `waits`
    # Each label's queued freshness work: the janitor's `reserved_queued`, the jobs of nightly.yml and
    # release.yml runs (queue_janitor.RESERVED_POOL_WORKFLOW) queued for it. No PR job takes a label's
    # slot while it is above 0 (place()).
    reserved: Mapping[str, int] = dataclasses.field(default_factory=dict)
    # Each owned label's oldest queued wait by now (minutes), for the labels the snapshot saw a queue on:
    # how long the side route's queue has gone without starting its oldest job (dead_end()).
    owned: Mapping[str, float] = dataclasses.field(default_factory=dict)
    # Queue counts are a separate unit from oldest waits. GUI/session placement weighs them against
    # online runners; the side-route dead-end check above keeps reading wait durations.
    owned_queued: Mapping[str, int] = dataclasses.field(default_factory=dict)
    # When the janitor carries glaeda's listener health fields, these maps say
    # whether the contract was evaluated and whether the label is full.
    owned_full: Mapping[str, bool] = dataclasses.field(default_factory=dict)
    owned_full_known: Mapping[str, bool] = dataclasses.field(default_factory=dict)
    snapshot: Mapping[str, Any] | None = dataclasses.field(default=None, compare=False)
    observed_at: dt.datetime | None = dataclasses.field(default=None, compare=False)
    # Stale snapshots preserve freshness reservations (#28341) and the waits they saw, without their age
    # (late_waits()): a queue already stalled then still keeps jobs off it.
    stale: bool = False
    # The LABELS the snapshot, fresh or not, shows dead (dead()).
    dead: frozenset[str] = frozenset()
    # The owned labels the janitor found unserved (queue_janitor.py's `unserved`, starved_labels.unserved()): a
    # job queued on the label and none running or started on it within starved_labels.STARVED_AFTER. A label
    # whose runners are online and busy elsewhere looks like room by its counts, yet starts nothing:
    # glaeda-session-std-xcode-26.6 held cmux#24295's daemon tests 90 minutes on 2026-10-29 that way, with
    # five runners online and the queue shorter than them (role_room() in side_lane_placement.py reads this).
    unserved: frozenset[str] = frozenset()


def _fleet_gates(snapshot: Mapping[str, Any] | None, env: Mapping[str, str]) -> Mapping[str, Any] | None:
    """Overlay the janitor's authoritative gates reading from CI_FLEET_GATES."""
    raw = (env.get("CI_FLEET_GATES") or env.get("FLEET_GATES") or "").strip()
    if not raw:
        return snapshot
    try:
        gates = json.loads(raw)
    except (TypeError, ValueError):
        return snapshot
    return {**(snapshot if isinstance(snapshot, Mapping) else {}), "gates": gates} if isinstance(gates, Mapping) else snapshot


def owned_label_full(snapshot: Mapping[str, Any] | None, label: str, now: dt.datetime,
                     *, queued_wait_s: float | None = None) -> bool:
    """Full after a three-minute queue; missing/>5-minute health overflows.

    One adapter for the janitor's legacy queue records and glaeda's listener
    records. Rescue passes its own observed wait; placement uses the snapshot.
    """
    gates = snapshot.get("gates") if isinstance(snapshot, Mapping) else None
    gate_labels = gates.get("labels") if isinstance(gates, Mapping) else None
    entry = gate_labels.get(label) if isinstance(gate_labels, Mapping) else None
    if not isinstance(gates, Mapping):
        pools = snapshot.get("pools") if isinstance(snapshot, Mapping) else None
        entry = pools.get(label) if isinstance(pools, Mapping) else None
    observed_wait = queued_wait_s is not None
    if queued_wait_s is None:
        if not isinstance(entry, Mapping):
            return False  # placement has no evidence a job is already queued
        try:
            queued_wait_s = float(entry.get("oldest_queued_s", float(entry.get("oldest_queued_minutes", 0)) * 60))
        except (TypeError, ValueError):
            queued_wait_s = 0
    if not isinstance(entry, Mapping):
        return queued_wait_s >= OWNED_HEALTH_QUEUE_SECONDS
    try:
        # A snapshot with no queued jobs cannot acquire a queue merely by
        # aging. Rescue's own wait remains authoritative even if that reading
        # predates the job it is watching.
        queued = int(entry.get("queued", 0))
        if not observed_wait and queued <= 0:
            return False
        as_of = dt.datetime.fromisoformat(str(entry.get("as_of") or "").replace("Z", "+00:00"))
        snapshot_age = (now - as_of).total_seconds()
        if not observed_wait:
            queued_wait_s += max(0, snapshot_age)
        if queued_wait_s < OWNED_HEALTH_QUEUE_SECONDS:
            return False
        try:
            generated = dt.datetime.fromisoformat(str(snapshot.get("generated_at") or "").replace("Z", "+00:00"))
            generated_age = (now - generated).total_seconds() if generated.tzinfo else float("inf")
        except (TypeError, ValueError):
            generated_age = float("inf")
        # Authoritative gates have their own clock and can be newer than the
        # artifact (CI_FLEET_GATES). Only legacy pool records require both.
        if (as_of.tzinfo is None or not 0 <= snapshot_age <= OWNED_HEALTH_STALE_SECONDS
                or not isinstance(gates, Mapping)
                and not 0 <= generated_age <= OWNED_HEALTH_STALE_SECONDS):
            return True
        listening, queued = int(entry.get("listening", 0)), int(entry.get("queued", 0))
        held = entry.get("held_offline") or {}
        held_total = int(held.get("total", sum(int(held.get(key, 0)) for key in ("units", "cpu", "livelock", "other")))) if isinstance(held, Mapping) else 0
        if min(listening, queued, held_total) < 0:
            return True
    except (KeyError, TypeError, ValueError):
        # An unreadable timestamp or counter is not a fresh listener reading.
        return queued_wait_s >= OWNED_HEALTH_QUEUE_SECONDS
    return listening == 0 and (held_total > 0 or (queued > 0 and queued_wait_s >= OWNED_HEALTH_QUEUE_SECONDS))


def _fresh(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> tuple[float, Mapping[str, Any]] | None:
    """(age in minutes, pools) of a janitor snapshot at most QUEUE_SNAPSHOT_MINUTES old, else None."""
    if not isinstance(snapshot, Mapping):
        return None
    try:
        generated = dt.datetime.fromisoformat(str(snapshot.get("generated_at") or "").replace("Z", "+00:00"))
    except ValueError:
        return None
    if generated.tzinfo is None:
        return None
    age = (now - generated).total_seconds() / 60
    pools = snapshot.get("pools")
    if not -5 <= age <= QUEUE_SNAPSHOT_MINUTES or not isinstance(pools, Mapping):
        return None
    return age, pools


def _field(pools: Mapping[str, Any], label: str, key: str) -> int:
    entry = pools.get(label) or {}
    try:
        return max(0, int(entry.get(key, 0))) if isinstance(entry, Mapping) else 0
    except (TypeError, ValueError):
        return 0


def late_waits(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> dict[str, float]:
    """Each LABEL's oldest queued wait as a snapshot too old for the counts saw it, from one at most
    RESERVED_SNAPSHOT_MINUTES old ({} for none, an older one, or a fresh one: seen() reads that).

    The janitor's snapshot lands every 12 to 25 minutes, so a placement often finds none under
    QUEUE_SNAPSHOT_MINUTES. It then read no wait at all and sent jobs to Blacksmith 6 vCPU blind: on 2026-10-31
    from about 04:00Z every cmux-next placement logged "no pool snapshot under 15 min old" and put swift test,
    daemon tests, the fast tier and the Release compile on blacksmith-6vcpu-macos-26 (run 41175923956), while
    the 06:17Z snapshot showed it with 166 queued and its oldest job waiting 179 min; about 100 PR jobs queued
    there in two hours. The figure is the snapshot's own, without its age added (seen() adds it to a fresh
    one): on a 30-minute-old snapshot the age alone would call every queue stalled, so only a queue that was
    already stalled when the snapshot was made reads stalled here. Only a label with a queue gets a wait."""
    if not isinstance(snapshot, Mapping) or _fresh(snapshot, now) is not None:
        return {}
    try:
        generated = dt.datetime.fromisoformat(str(snapshot.get("generated_at") or "").replace("Z", "+00:00"))
    except ValueError:
        return {}
    pools = snapshot.get("pools")
    if generated.tzinfo is None or not isinstance(pools, Mapping):
        return {}
    if not -5 <= (now - generated).total_seconds() / 60 <= RESERVED_SNAPSHOT_MINUTES:
        return {}
    return {label: float(_field(pools, label, "oldest_queued_minutes")) for label in LABELS
            if _field(pools, label, "queued")}


def dead(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> frozenset[str]:
    """The LABELS the snapshot (fresh or not) shows dead (simple_pool_picker.dead_macos_26(), blacksmith_dead():
    nothing running and no job started on it for an hour, from a snapshot up to six hours old), or none when it
    shows every one dead: with no label showing life it says nothing to choose by."""
    return frozenset(_picker_rule.dead_macos_26(snapshot, now)) & frozenset(LABELS)


def queued(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> dict[str, int] | None:
    """Each pool label's queued jobs (LABELS always) from a janitor snapshot at most
    QUEUE_SNAPSHOT_MINUTES old, else None."""
    fresh = _fresh(snapshot, now)
    if fresh is None:
        return None
    labels = [*LABELS, *(str(label) for label in fresh[1] if pool_label(str(label)) and label not in LABELS)]
    return {label: _field(fresh[1], label, "queued") for label in labels}


def seen(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> Seen | None:
    """Each label's oldest queued wait by now, from the same fresh snapshot."""
    fresh = _fresh(snapshot, now)
    gates = snapshot.get("gates") if isinstance(snapshot, Mapping) else None
    gate_labels = gates.get("labels") if isinstance(gates, Mapping) else None
    if fresh is None and not isinstance(gate_labels, Mapping):
        return None
    age, pools = fresh if fresh is not None else (0.0, {})
    age = max(0.0, age)
    if isinstance(gate_labels, Mapping):
        # Class-pool queue counts include concurrency waiters. Once gates are
        # available, only their per-label reading describes owned listeners.
        pools = {**{k: v for k, v in pools.items() if not str(k).startswith("glaeda-")},
                 **gate_labels}
    waits = {label: float(_field(pools, label, "oldest_queued_minutes")) + age
             if _field(pools, label, "queued") else 0.0 for label in LABELS}
    reserved = {label: _field(pools, label, "reserved_queued") for label in LABELS}
    owned = {str(label): float(_field(pools, str(label), "oldest_queued_minutes")) + age
             for label in pools if str(label).startswith("glaeda-") and _field(pools, str(label), "queued")}
    if isinstance(gate_labels, Mapping):
        for label in owned:
            entry = gate_labels[label]
            try:
                as_of = dt.datetime.fromisoformat(str(entry.get("as_of") or "").replace("Z", "+00:00"))
                owned[label] = (float(entry.get("oldest_queued_s", 0))
                                + max(0.0, (now - as_of).total_seconds())) / 60
            except (TypeError, ValueError):
                owned[label] = OWNED_HEALTH_QUEUE_SECONDS / 60
    owned_queued = {str(label): _field(pools, str(label), "queued")
                    for label in pools if str(label).startswith("glaeda-") and _field(pools, str(label), "queued")}
    labels = {str(label) for label in pools if str(label).startswith("glaeda-")}
    full: dict[str, bool] = {}
    known: dict[str, bool] = {}
    for label in labels:
        result = owned_label_full(snapshot, label, now)
        if result is not None:
            full[label] = result
            entry = pools[label]
            known[label] = isinstance(entry, Mapping) and "listening" in entry and "as_of" in entry
    if fresh is None:
        stale_reservations = reserved_from(snapshot, now)
        reserved = stale_reservations.reserved if stale_reservations is not None else {}
        # Too old for the counts, still read for a queue that was already stalled (late_waits()).
        waits = late_waits(snapshot, now)
    # A key names every fleet label a job asked for, joined with "+" (starved_labels.fleet_key()); only a
    # one-label key says that label itself starts nothing. Only a fresh snapshot says so: an older one's
    # unserved label may have started since.
    unserved = frozenset(str(key) for key in (snapshot.get("unserved") or ()) if fresh is not None
                         and isinstance(key, str) and key.startswith("glaeda-") and "+" not in key)
    return Seen(waits=waits, age=age, reserved={k: v for k, v in reserved.items() if v}, owned=owned,
                owned_queued=owned_queued, owned_full=full, owned_full_known=known, snapshot=snapshot,
                observed_at=now, stale=fresh is None, dead=dead(snapshot, now),
                unserved=unserved)


def reserved_from(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> Seen | None:
    """A stale Seen carrying only `reserved`, from a snapshot QUEUE_SNAPSHOT_MINUTES to RESERVED_SNAPSHOT_MINUTES
    old that shows freshness work queued for a Blacksmith label; else None.

    The janitor's snapshot lands every 12 to 25 minutes (its sweep queues on Linux like any job), so the
    15-minute read often finds none, and then the unread branch of place() sent MAX_PER_RUN PR jobs of every
    run to 6 vCPU blind. On 2026-10-30 from 12:20Z, every cmux-next placement logged "no pool snapshot under
    15 min old" and put its fast tier on blacksmith-6vcpu-macos-26 while nightly-next's
    sign-nightly-identity-legacy and generate-nightly-deltas waited there. A nightly job stays queued for
    longer than the snapshot is late, so the older snapshot's reservation still holds the label for it.
    """
    if not isinstance(snapshot, Mapping):
        return None
    try:
        generated = dt.datetime.fromisoformat(str(snapshot.get("generated_at") or "").replace("Z", "+00:00"))
    except ValueError:
        return None
    pools = snapshot.get("pools")
    if generated.tzinfo is None or not isinstance(pools, Mapping):
        return None
    age = (now - generated).total_seconds() / 60
    if not -5 <= age <= RESERVED_SNAPSHOT_MINUTES:
        return None
    reserved = {label: _field(pools, label, "reserved_queued") for label in LABELS}
    reserved = {label: count for label, count in reserved.items() if count}
    if not reserved:
        return None
    return Seen(waits=late_waits(snapshot, now), age=max(0.0, age), reserved=reserved, observed_at=now, stale=True,
                dead=dead(snapshot, now))


def stale_seen(snapshot: Mapping[str, Any] | None, now: dt.datetime) -> Seen | None:
    """seen(), else reserved_from(), else a stale Seen carrying only dead labels and late waits (late_waits())."""
    found = seen(snapshot, now) or reserved_from(snapshot, now)
    if found is not None:
        return found
    gone, waits = dead(snapshot, now), late_waits(snapshot, now)
    return Seen(waits=waits, stale=True, dead=gone) if gone or waits else None


def stalled(live: Mapping[str, int], waiting: Mapping[str, int], waits: Mapping[str, float],
            age: float = 0.0) -> tuple[str, ...]:
    """The labels whose queue is not moving: a wait of STALL_MINUTES by now, or one of IDLE_STALL_MINUTES
    the snapshot saw (`waits` less its `age`) with no runner online now."""
    return tuple(label for label in LABELS
                 if waiting.get(label, 0) > 0
                 and (_picker_rule.blacksmith_stalled(waiting.get(label, 0), waits.get(label, 0.0))
                      or live.get(label, 0) == 0 and waits.get(label, 0.0) - age >= IDLE_STALL_MINUTES))


def fresh_stalled(waits: Mapping[str, float], gone: Sequence[str] = ()) -> tuple[str, ...]:
    """The labels a feed's compile counts as full: an oldest queued wait of FRESH_STALL_MINUTES by now (seen()
    gives a wait only to a label with a queue), or dead (`gone`, Seen.dead)."""
    return tuple(label for label in LABELS
                 if label in gone or _picker_rule.blacksmith_stalled(1, waits.get(label, 0.0)))


def cascade(jobs: Sequence[str], live: Mapping[str, int], waiting: Mapping[str, int], *,
            stall: Sequence[str] = (), reserved: Sequence[str] = (),
            fresh: Sequence[str] = (), fresh_stall: Sequence[str] = ()) -> dict[str, tuple[str, ...]]:
    """Give `jobs`, in order, the free slots of LARGE, then SMALL (unless stalled). A job no slot takes stays
    on the owned label: there is no GitHub-hosted overflow.

    A Blacksmith slot is free while its label is under CAPACITY and the shared pool fits the job (fits()).
    A `reserved` label (freshness work queued for it) gives its slots only to `fresh` jobs.
    A `fresh` job never takes a `fresh_stall` label (fresh_stalled()).
    """
    free = {label: 0 if label in stall else CAPACITY[label] - live.get(label, 0) - waiting.get(label, 0)
            for label in LABELS}
    room, queue = pool_room(live, waiting), pool_queued(waiting)
    placed: dict[str, list[str]] = {label: [] for label in LABELS}
    for job in jobs:
        label = next((label for label in LABELS
                      if free[label] > 0 and fits(label, room, queue)
                      and (label not in reserved or job in fresh)
                      and not (job in fresh and label in fresh_stall)), None)
        if label is None:
            continue
        placed[label].append(job)
        if len(placed[label]) >= MAX_PER_RUN:
            free[label] = 0
        free[label] -= 1
        room -= vcpus(label)
    return {label: tuple(names) for label, names in placed.items()}


def _pool_backlog(waiting: Mapping[str, int]) -> int:
    """The jobs queued ahead of a new 6 vCPU job: every Blacksmith macOS label's but LARGE's, which waits for
    twelve vCPUs freed at once and so takes none of the freed 6 vCPU slots (pool_room())."""
    return sum(count for label, count in waiting.items() if pool_label(label) and label != LARGE)


def dead_end(route_wait: float | None, live: Mapping[str, int], waiting: Mapping[str, int],
             seen: "Seen | None") -> bool:
    """Whether the owned route the jobs would stay on is a worse queue than SMALL's: overflow() then waives
    SMALL's stall and backlog rules.

    `route_wait` (side_lane_placement.route_wait()) is how long the route's oldest queued job has waited with
    no idle runner carrying the route, in minutes (math.inf when every online runner carrying it is on one
    host), or None (an idle runner, or nothing read). It is a dead end once that wait reaches STALL_MINUTES
    (the stall rule every picker reads) and exceeds SMALL's own oldest wait, while SMALL still starts jobs:
    a runner in flight, or no queue. On 2026-10-29 cmux#26723's fast tier (run 40841809952) queued on
    glaeda-side-std-xcode-26.6 from 08:24Z behind 96 jobs whose oldest had waited 443 minutes, while
    blacksmith-6vcpu-macos-26 ran 4 with its oldest queued 27 minutes: overflow() called that queue stalled
    and kept the job on the far longer one.
    """
    if route_wait is None or route_wait < STALL_MINUTES:
        return False
    small_wait = seen.waits.get(SMALL, 0.0) if seen is not None else 0.0
    moving = live.get(SMALL, 0) > 0 or waiting.get(SMALL, 0) == 0
    return moving and small_wait < route_wait


def overflow_refusal(waiting: Mapping[str, int], stall: Sequence[str], reserved: Sequence[str]) -> str:
    """Why SMALL takes no overflow job that is not a feed's compile, or "" when it does."""
    if SMALL in stall:
        return "its queue is stalled"
    if SMALL in reserved:
        return "freshness work is queued for it"
    if _pool_backlog(waiting) >= OVERFLOW_BACKLOG:
        return f"{_pool_backlog(waiting)} jobs already queue ahead"
    return ""


def overflow(jobs: Sequence[str], waiting: Mapping[str, int], *, stall: Sequence[str] = (),
             reserved: Sequence[str] = (), fresh: Sequence[str] = (),
             fresh_stall: Sequence[str] = (), already: int = 0, dead_end: bool = False) -> tuple[str, ...]:
    """The `jobs` (no idle mini and no free slot took them) that queue on SMALL instead of the owned label.

    Leo's routing order is Linux, then owned Macs, then Blacksmith macOS as the last resort, and no job
    waits on one reserved pool with no fallback (2026-10-24: "THERE SHOULD BE 0 QUEUE EVER HERE"). With
    every owned side runner busy and no free Blacksmith slot, the jobs used to stay on the side label and
    the run took the refusals-only marker, so nothing moved them again: on 2026-10-29 cmux#26723's fast
    tier waited on glaeda-side-std-xcode-26.6 from 03:14Z for hours while glaeda's listener gate held the
    saturated std minis' side runners offline, and cmux#27066's waited 2 h the same way.

    6 vCPU is the overflow, never 12: its ten slots turn over (median start 2.6 min on 2026-10-20), while a
    12 vCPU job waits behind every queued 6 vCPU job (pool_room()). It takes a job only while its queue
    moves and is short, so the overflow never builds the 5-hour Blacksmith queues of 2026-10-20 (Leo:
    waiting in a Blacksmith queue is not acceptable): not while it is stalled (stalled(), the pickers'
    one stall rule), not while OVERFLOW_BACKLOG or more jobs queue ahead (_pool_backlog()), at most
    MAX_PER_RUN jobs of one run on SMALL counting the `already` its free slots took, and, as in cascade(), only a feed's compile while freshness work is
    queued for it and never a feed's compile on a fresh-stalled label.

    `dead_end` (dead_end(): the owned route the jobs would otherwise wait on has started nothing for longer
    than SMALL's oldest job has waited, or one host alone serves it) waives SMALL's stall and backlog rules:
    the shorter queue wins. MAX_PER_RUN, freshness work and a fresh-stalled label still hold.
    """
    if SMALL in stall and not dead_end:
        return ()
    taken: list[str] = []
    ahead = _pool_backlog(waiting)
    for job in jobs:
        if already + len(taken) >= MAX_PER_RUN or not dead_end and ahead + len(taken) >= OVERFLOW_BACKLOG:
            break
        if SMALL in reserved and job not in fresh or job in fresh and SMALL in fresh_stall:
            continue
        taken.append(job)
    return tuple(taken)


def retry_label(live: Mapping[str, int], waiting: Mapping[str, int], stall: Sequence[str] = ()) -> str:
    """The overflow label: the lowest (in flight + queued) / capacity among moving labels with a free slot that
    the shared pool fits (fits()), else "".

    "" sends the bot's overflow to the owned side label: a job never falls back
    to a Blacksmith label with no free slot, where it would queue for hours.

    With no free slot anywhere the load ratio misleads: other workflows' long jobs
    hold the 12 vCPU label's five slots for an hour or more. From 01:04Z to 02:35Z on
    2026-10-20 the ratio sent 25 cmux-next jobs there and none started (14 queued
    over 15 minutes, up to 89, then cancelled), while 6 vCPU, whose ten slots turn
    over, started 69 at a median 2.5 minutes.
    """
    load = {label: live.get(label, 0) + waiting.get(label, 0) for label in LABELS}
    room, queue = pool_room(live, waiting), pool_queued(waiting)
    free = [label for label in LABELS
            if load[label] < CAPACITY[label] and label not in stall and fits(label, room, queue)]
    if not free:
        return ""
    return min(free, key=lambda label: (load[label] / CAPACITY[label], LABELS.index(label)))


def gui_overflow_label(live: Mapping[str, int] | None, waiting: Mapping[str, int] | None, seen: Seen | None,
                       jobs: int = 1) -> str:
    """The Blacksmith macOS label the GUI jobs (cmux-next.yml swift-test, daemon-test, generated-files) take
    when no owned GUI runner has room: LARGE while it can start all `jobs` now, else SMALL, the last resort.

    LARGE needs a fresh reading that vouches for it: not stalled (stalled(), the pickers' one rule), not dead
    (Seen.dead: on 2026-10-30 it had started nothing for about a day, 158 queued, oldest 1431 min), no
    freshness work queued for it (Seen.reserved), a free slot for each job under CAPACITY, and the shared pool
    fitting each (fits(): nothing queued on any Blacksmith macOS label). Without that reading (runner groups or
    snapshot unread, or a snapshot too old for waits) nothing does, so SMALL. On 6 vCPU, swift-test's suites
    ran starved (run 41123927916: tests that take under a second idle took 78-227 s).
    """
    if live is None or waiting is None or seen is None or seen.stale:
        return SMALL
    stall = {*stalled(live, waiting, seen.waits, seen.age), *seen_dead(seen)}
    if LARGE in stall or seen.reserved.get(LARGE, 0) > 0:
        return SMALL
    jobs = max(jobs, 1)
    free = CAPACITY[LARGE] - live.get(LARGE, 0) - waiting.get(LARGE, 0)
    room, queue = pool_room(live, waiting), pool_queued(waiting)
    return LARGE if free >= jobs and fits(LARGE, room - vcpus(LARGE) * (jobs - 1), queue) else SMALL


def bot_rerun(env: Mapping[str, str]) -> bool:
    """The rescue's full re-run: attempt 2 that a RESCUE_ACTORS bot triggered, placed afresh like attempt 1."""
    return ((env.get("GITHUB_RUN_ATTEMPT") or "").strip() == "2"
            and (env.get("GITHUB_TRIGGERING_ACTOR") or "").strip() in RESCUE_ACTORS)


def skipped(env: Mapping[str, str]) -> str:
    """Why this run places nothing on Blacksmith before reading anything, or ""."""
    label = (env.get("SIDE_LABEL") or "").strip()
    if (env.get("GITHUB_RUN_ATTEMPT") or "").strip() not in ("", "1") and not bot_rerun(env):
        return "a person re-run keeps its own route"
    if not label.startswith("glaeda-side-"):
        return f"`{label or 'no label'}` is not an owned side label"
    return ""


def cascade_jobs(env: Mapping[str, str]) -> tuple[str, ...]:
    """CASCADE_JOBS plus the env's CASCADE_JOBS: another side workflow's own Mac jobs (the post-publish
    launch smoke's `launch-smoke`) take the same cascade without joining cmux-next's list."""
    return (*CASCADE_JOBS, *(job for job in (env.get("CASCADE_JOBS") or "").split() if job not in CASCADE_JOBS))


def candidates(env: Mapping[str, str], owned: Sequence[str], promote_busy: bool = False) -> list[str]:
    """The cascade jobs that run here and no idle mini takes, in the order they take Blacksmith slots."""
    runs = set((env.get("CASCADE_RUNS") or "").split())
    # idle_placement() hands the idle minis to the first JOBS, running or not, and
    # every side job takes the side label whatever owned_jobs says: so the idle
    # minis count against the jobs that run here, in order, before Blacksmith.
    running = [job for job in (env.get("JOBS") or "").split() if job in cascade_jobs(env) and job in runs]
    promoted = [job for job in running if job in PROMOTE_JOBS] if (env.get("PROMOTE_LABEL") or "").strip() else []
    side = [job for job in running if job not in promoted]
    # FIRST_JOBS (a feat-cmux-next push's Release compile, which gates the nightly-next request) take the
    # run's slots first: with MAX_PER_RUN slots a run it was last and found none (2026-10-26 09:21Z, run
    # 40298786351: fast-tier and the scheme compile took 6 vCPU's two). Every side job takes the same
    # label and races for its idle minis, so the count of jobs those minis take is all that is known:
    # it is spent on the run's other jobs first, and a FIRST_JOBS job has a slot whenever one is free.
    # FRESH_JOBS (the compiles a feed's freshness waits on: a DEV daily's Release compile) lead the same way.
    # Across runs they need no reservation: a slot is free only while its label is under CAPACITY counting
    # its queued jobs too (cascade()), so a freshness compile already queued for a Blacksmith label holds
    # its place, and no PR compile placed later takes a slot ahead of it.
    first = set((env.get("FIRST_JOBS") or "").split()) | set((env.get("FRESH_JOBS") or "").split())
    rest = [job for job in side if job not in first]
    leading = [job for job in side if job in first]
    return (promoted if promote_busy else []) + leading[max(0, len(owned) - len(rest)):] + rest[len(owned):]


def place(env: Mapping[str, str], owned: Sequence[str], live: Mapping[str, int] | None,
          waiting: Mapping[str, int] | None, seen: Seen | None = None, promote_busy: bool = False,
          saturated: bool = False, route_wait: float | None = None) -> Placement:
    """The Blacksmith jobs of attempt 1, after the idle minis took `owned`.

    With PROMOTE_LABEL set (a feat-cmux-next push), PROMOTE_JOBS run on that label: they cascade,
    first, only when `promote_busy` (no idle runner carries it), and never take an idle side mini's turn.

    `saturated`: the owned runners were read live, so the jobs past `owned` are known to have no idle
    mini. Those jobs then never stay on the owned label while Blacksmith 6 vCPU is a live last resort
    (overflow(); with the counts unread, the same MAX_PER_RUN cap as a feed's compile).

    `route_wait`: how long the owned route the jobs would stay on has started nothing (dead_end()).
    """
    empty = {label: () for label in LABELS}
    unavailable = tuple(label for label in LABELS if seen is not None and label_full_or_dead(
        label, seen.snapshot, live=(live or {}).get(label, 0), queued=(waiting or {}).get(label, 0), now=seen.observed_at))
    if skipped(env):
        return Placement(empty, "", skipped(env))
    if live is None or waiting is None:
        why = ("Blacksmith's runner groups could not be read" if live is None else
               f"no pool snapshot under {QUEUE_SNAPSHOT_MINUTES} min old to count Blacksmith's queue")
        # Without the counts no slot is known free, so the overflow keeps the owned label. A feed's
        # compile takes the last resort rather than an owned queue nobody measured, and so does every
        # job once the owned pool was read with no idle mini for it (`saturated`): run 40810932618's
        # fast tier (2026-10-29 03:14Z, a stale snapshot) otherwise waited hours on the side label.
        # Queued freshness work the snapshot still shows keeps 6 vCPU for a feed's compile, as in cascade().
        feeds = set((env.get("FRESH_JOBS") or "").split())
        held = seen is not None and seen.reserved.get(SMALL, 0) > 0
        if held and seen.stale:
            why += (f"; the {seen.age:.0f}-min-old snapshot shows freshness work queued for `{SMALL}`, "
                    "so only a feed's compile takes it")
        fresh = (tuple([job for job in candidates(env, owned, promote_busy)
                        if (not held or job in feeds) and SMALL not in unavailable][:MAX_PER_RUN]) if saturated
                 else unread_fresh_jobs(env, owned) if SMALL not in unavailable else ())
        fresh_stall = fresh_stalled(seen.waits, seen.dead) if seen is not None else ()
        if fresh:
            # A feed's compile takes the last resort. The snapshot, read even when the
            # runner groups were refused, still shows a stalled queue: a feed's compile does not join it
            # (2026-10-27 01:11Z: 6 vCPU's oldest job had waited 148 min) and keeps the owned label.
            # A label the snapshot, however old, shows dead is never that last resort.
            if SMALL in seen_dead(seen):
                why += f"; `{SMALL}` is dead (nothing running, no job started in an hour)"
            elif SMALL in fresh_stall:
                why += f"; `{SMALL}`'s oldest queued job has waited {seen.waits[SMALL]:.0f} min"
            else:
                reason = ("no idle mini can take them" if saturated else "a feed's freshness waits on them")
                return Placement({**empty, SMALL: fresh}, "",
                                 f"{why}; {reason}, so {', '.join(fresh)} take `{SMALL}`; "
                                 "the rest stay on the minis' queue", fresh_stall)
        return Placement(empty, "", f"{why}; no job leaves the minis' queue", fresh_stall)
    gone = seen_dead(seen)
    stall = stalled(live, waiting, seen.waits, seen.age) if seen is not None else ()
    # Controller-declared outages, full labels, and dead labels cannot be made live
    # by the shorter-queue exception below.
    stall = tuple(dict.fromkeys((*stall, *unavailable, *(label for label in LABELS if label in gone))))
    jobs = candidates(env, owned, promote_busy)
    # Freshness first across runs too: while a nightly's build or signing job is queued for a Blacksmith
    # label (2026-10-26: nightly-next's build-sign-notarize-nightly from 19:38Z behind 68 PR jobs on
    # blacksmith-6vcpu-macos-26), no PR job of this run takes a slot there, and neither does its overflow.
    reserved = tuple(label for label in LABELS if seen is not None and seen.reserved.get(label, 0) > 0)
    fresh = tuple((env.get("FRESH_JOBS") or "").split())
    fresh_stall = fresh_stalled(seen.waits, gone) if seen is not None else ()
    placed = cascade(jobs, live, waiting, stall=stall, reserved=reserved,
                     fresh=fresh, fresh_stall=fresh_stall)
    # Free slots taken, the jobs left would wait on the owned label. With the owned pool read saturated,
    # 6 vCPU's moving queue takes them instead (overflow()): it is the routing order's last resort.
    unplaced = [job for job in jobs if not any(job in names for names in placed.values())]
    # A dead SMALL is no shorter queue: dead_end() never waives its stall.
    blocked = saturated and SMALL not in gone and dead_end(route_wait, live, waiting, seen)
    spilled = (overflow(unplaced, waiting, stall=stall, reserved=reserved, fresh=fresh, fresh_stall=fresh_stall,
                        already=len(placed[SMALL]), dead_end=blocked)
               if saturated and SMALL not in unavailable else ())
    if spilled:
        placed = {**placed, SMALL: (*placed[SMALL], *spilled)}
    # If every route is full/dead, reserve the tier for the thin cmux-ci gateway.
    requested_fleet = set((env.get("FLEET_CLIENT_JOBS") or "").split())
    route_labels = tuple(label for label in (*LABELS, (env.get("SIDE_LABEL") or "").strip()) if label)
    all_routes_blocked = bool(requested_fleet) and seen is not None and bool(route_labels) and all(
        label_full_or_dead(label, seen.snapshot, live=live.get(label, 0), queued=waiting.get(label, 0),
                           now=seen.observed_at)
        for label in route_labels)
    fleet_jobs = tuple(job for job in unplaced if job in requested_fleet) if all_routes_blocked else ()
    # The overflow label counts the slots this run's own jobs just took: they fit, so they start, and hold
    # the pool's vCPUs as jobs in flight do.
    # A run with a feed's compile keeps its overflow off a fresh-stalled label too: the compile's re-run reads it.
    retry_live = {**live, **{label: live.get(label, 0) + len(placed.get(label, ())) for label in LABELS}}
    retry = retry_label(retry_live, waiting, (*stall, *reserved, *(fresh_stall if fresh else ())))
    # A re-run's jobs that no Blacksmith label listed take the overflow label before the owned side label
    # (cmux-next.yml's runs-on), so while an idle mini would take one of them the overflow stays owned.
    rerun_owned = bot_rerun(env) and len(owned) > 0
    if rerun_owned:
        retry = ""
    # A shared retry label is still subject to the same per-run cap as first placement.
    # Export the exact jobs allowed to consume it; workflow jobs outside this set stay on the owned route.
    retry_jobs = ()
    if retry:
        label_room = CAPACITY[retry] - retry_live.get(retry, 0) - waiting.get(retry, 0)
        pool_room_slots = pool_room(retry_live, waiting) // vcpus(retry)
        available = max(0, min(label_room, pool_room_slots))
        retry_candidates = tuple(job for job in jobs
                                 if job not in fleet_jobs
                                 and not any(job in names for names in placed.values()))
        retry_allowance = max(0, MAX_PER_RUN - len(placed.get(retry, ())))
        retry_jobs = retry_candidates[:min(retry_allowance, available)]
    load = ", ".join(f"`{label}` {live.get(label, 0)} in flight + {waiting.get(label, 0)} queued of {CAPACITY[label]}"
                     + (" (dead: nothing running, no job started in an hour)" if label in gone
                        else f" (stalled: oldest queued {seen.waits.get(label, 0.0):.0f} min)"
                        if label in stall and seen else "")
                     for label in LABELS)
    used = POOL_VCPU - pool_room(live, waiting)
    others = ", ".join(f"`{label}` {live.get(label, 0)} + {waiting.get(label, 0)}"
                       for label in sorted({*live, *waiting}) if pool_label(label) and label not in LABELS)
    pool_text = (f"pool {used} of {POOL_VCPU} vCPU in flight or queued"
                 + (f" ({others} in flight + queued)" if others else "")
                 + (", so 12 vCPU waits behind the queue" if pool_queued(waiting) else ""))
    moved = "; ".join(f"`{label}` takes {', '.join(names)}" for label, names in placed.items() if names)
    left = [job for job in jobs if not any(job in names for names in placed.values())]
    why = f"Blacksmith: {load}; {pool_text}. " + (moved or "No free Blacksmith slot")
    if spilled and blocked:
        why += (f"; no idle mini and no free slot, and the owned route has started nothing for "
                f"{'ever: one host serves it' if route_wait == float('inf') else f'{route_wait:.0f} min'}, "
                f"so {', '.join(spilled)} queue on `{SMALL}`, the shorter queue "
                f"({_pool_backlog(waiting)} queued ahead)")
    elif spilled:
        why += (f"; no idle mini and no free slot, so {', '.join(spilled)} queue on `{SMALL}`, which is moving "
                f"({_pool_backlog(waiting)} queued ahead, under {OVERFLOW_BACKLOG})")
    elif saturated and left:
        why += f"; `{SMALL}` is not a live overflow ({overflow_refusal(waiting, stall, reserved)})"
    if reserved:
        why += (f"; freshness work is queued for {', '.join(f'`{label}`' for label in reserved)}, "
                "so only a feed's compile takes it")
    if fleet_jobs:
        why += f"; {', '.join(fleet_jobs)} reserved for the fleet gateway"
    left = [job for job in left if job not in fleet_jobs]
    if left:
        why += f"; {', '.join(left)} stay queued on the owned label"
    if bot_rerun(env):
        why = f"the rescue's re-run (attempt 2) is placed afresh. {why}"
    return Placement(placed, retry, why + (f"; overflow goes to `{retry}`" if retry
                                           else "; an idle mini takes the re-run, so overflow stays on the owned label"
                                           if rerun_owned
                                           else "; no free Blacksmith slot, so overflow stays on the owned label"),
                     fresh_stall=fresh_stall, fleet_jobs=fleet_jobs, retry_jobs=retry_jobs)


def seen_dead(seen: Seen | None) -> frozenset[str]:
    """The labels `seen` shows dead (Seen.dead), none without it."""
    return seen.dead if seen is not None else frozenset()


def unread_fresh_jobs(env: Mapping[str, str], owned: Sequence[str]) -> tuple[str, ...]:
    """The FRESH_JOBS that run here and that no idle mini took (`owned` counts against the run's other jobs
    first, as in place()), at most MAX_PER_RUN."""
    runs = set((env.get("CASCADE_RUNS") or "").split())
    running = [job for job in (env.get("JOBS") or "").split() if job in cascade_jobs(env) and job in runs]
    fresh = [job for job in running if job in set((env.get("FRESH_JOBS") or "").split())]
    others = len(running) - len(fresh)
    return tuple(fresh[max(0, len(owned) - others):][:MAX_PER_RUN])


class Api:
    """The two reads: the route App token lists runner groups, GITHUB_TOKEN (actions: read) the snapshot."""

    def __init__(self, route_token: str, repository: str):
        self.route_token = route_token
        self.repository = repository

    def _get(self, path: str) -> Any:
        request = urllib.request.Request(f"{API}{path}", headers={
            "Accept": "application/vnd.github+json", "Authorization": f"Bearer {self.route_token}",
            "X-GitHub-Api-Version": "2022-11-28", "User-Agent": "cmux-next-macos-cascade"})
        try:
            with urllib.request.urlopen(request, timeout=15) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            print(f"GitHub refused GET {path.split('?')[0]}: {refusal(error)}", file=sys.stderr)
            raise

    def in_flight(self) -> dict[str, int] | None:
        owner, _, name = self.repository.partition("/")
        groups = self._get(f"/orgs/{owner}/actions/runner-groups?per_page=100"
                           f"&visible_to_repository={urllib.parse.quote(name)}").get("runner_groups") or []
        return in_flight(groups, lambda group: self._get(
            f"/orgs/{owner}/actions/runner-groups/{group}/runners?per_page=100").get("runners") or [])


def read(env: Mapping[str, str], pool: Any, *, now: dt.datetime, log: Callable[[str], None] = print,
         clock: Callable[[], float] = time.monotonic,
         ) -> tuple[dict[str, int] | None, dict[str, int] | None, Seen | None]:
    """(in flight, queued, seen) for place(); each None when its read fails or READ_BUDGET_SECONDS ran out."""
    started = clock()
    live = waiting = None
    found: Seen | None = None
    if skipped(env):
        return live, waiting, found
    repository = env.get("GITHUB_REPOSITORY", "")
    # The routing App first, then cmux-bot (ROUTE_TOKEN_FALLBACK) when the first read is refused.
    for name in ("ROUTE_TOKEN", "ROUTE_TOKEN_FALLBACK"):
        route = env.get(name, "")
        if not (route and repository):
            continue
        try:
            live = Api(route, repository).in_flight()
            if live is None:
                log("::warning title=macOS cascade::no `Blacksmith scale sets - <label>` runner group is visible")
            break
        except Exception as error:  # noqa: BLE001 - fail closed: nothing leaves the minis' queue
            log(f"::warning title=macOS cascade::could not list Blacksmith's runner groups with {name} ({error})")
    snapshot_token = env.get("SNAPSHOT_TOKEN", "")
    if clock() - started > READ_BUDGET_SECONDS:
        log("::warning title=macOS cascade::the runner groups took too long; the pool snapshot is not read")
        # Gates are local repository-variable data; reading them consumes no
        # remaining API budget and must still reject a full owned label.
        return live, None, seen(_fleet_gates(None, env), now)
    # The snapshot never stands in for the runner groups: it counts this repository's jobs, while the pool is
    # the organization's, so a refused runner read leaves `live` and `waiting` None and only FRESH_JOBS move
    # (place()). Its waits are still read then, so a feed's compile skips a stalled queue (fresh_stalled()).
    snapshot = None
    if snapshot_token and repository:
        try:
            snapshot = pool.GitHub(snapshot_token, repository).snapshot(now=now)

        except Exception as error:  # noqa: BLE001 - fail closed, as above
            log(f"::warning title=macOS cascade::could not read the pool snapshot ({error})")
    snapshot = _fleet_gates(snapshot, env)
    found = stale_seen(snapshot, now)
    if live is not None:
        waiting = queued(snapshot, now)
        live = with_running(live, snapshot, now)
    return live, waiting, found


def delimited(jobs: Sequence[str]) -> str:
    return f" {' '.join(jobs)} " if jobs else ""


def write(placement: Placement, env: Mapping[str, str]) -> None:
    """Outputs blacksmith_12_jobs, blacksmith_6_jobs, fresh_stalled (space-delimited, as owned_jobs) and
    free_retry_runner (also as retry_runner), and retry_jobs (the capped per-run retry set)."""
    output = env.get("GITHUB_OUTPUT")
    if output:
        with open(output, "a", encoding="utf-8") as handle:
            handle.write(f"blacksmith_12_jobs={delimited(placement.jobs.get(LARGE, ()))}\n"
                         f"blacksmith_6_jobs={delimited(placement.jobs.get(SMALL, ()))}\n"
                         f"fresh_stalled={delimited(placement.fresh_stall)}\n"
                         f"fleet_jobs={delimited(placement.fleet_jobs)}\n"
                         f"retry_runner={placement.retry_runner}\n"
                         f"free_retry_runner={placement.retry_runner}\n"
                         f"retry_jobs={delimited(placement.retry_jobs)}\n")
    summary = env.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write(f"\n{placement.why}\n")
