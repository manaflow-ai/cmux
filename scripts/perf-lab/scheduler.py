#!/usr/bin/env python3
"""The perf lab scheduler: merge batches, tiers, shard owners, host roles and the job each lab host runs next.

    plan(state, now, hosts, builds, branch_log, *, stories, shard_map, ...) -> Plan     # pure
    python3 -I scripts/perf-lab/lab.py schedule --state S --hosts H.json --builds B.json [--write]

Chrome's perf waterfall is the model (docs/speed/perf_waterfall.md): builders build commits, testers run
continuously, and each run covers the commits since the previous run up to the latest built commit. Each story is
bound to one device by a generated shard map (tools/perf/core/shard_maps, here shard_map.json from
gen_shard_map.py), and bisect devices are separate from waterfall devices (`pinpoint_only` in
tools/perf/core/bot_platforms.py). The rules (p12-perf-process.md 3.1-3.3, 3.5, 3.11):

- Batch: the commits after the last cut, cut at most every BATCH_INTERVAL. Its tip gets build requests first.
  T0 measures the newest built batch; older unmeasured batches fold into it. A T0 range is per shard: the commits
  since that shard's last T0 job, so a shard that could not start a round measures those commits in its next one.
  When the build queue is over EVERY_SECOND_QUEUE, every 2nd batch is cut as `skipped` (no build) and folds into
  the next one. A batch whose tip build failed, or did not come within BUILD_TIMEOUT, is `failed` and folds too.
- T0 of each story runs only on its shard-map owner. An owner that is down or missing is a gap, never a move.
- T1 runs every T1_INTERVAL per shard (longer for a shard whose T1 stories do not fit in it, so the host keeps
  idle time), one story per job, so a T0 waits for at most one T1 story. A shard's next T1 round starts only after
  its previous one is dispatched. A T1/T2 story whose build failed is a gap. T2 and A/A run once per lab day
  (NIGHTLY_HOUR_UTC).
- Pinpoint hosts take bisect, then verify, then A/A. Pinpoint work borrows a waterfall host of its class only when
  that host is idle, its next T0 is more than BORROW_LEAD away and the work ends before it; A/A on a waterfall host
  obeys the same rule. The next T0 comes from known work: a waiting batch or T0 shard, or merges not cut yet. A
  host that holds no T0 shard, or a branch with no new merge, has no T0 due. Priorities follow task 010:
  T0 > bisect > verify > T1 > T2 > aa; an A/A still waiting AA_PROMOTE_AFTER into its lab day goes before T1.
- Every REFERENCE_EVERY-th T0 job on a waterfall host also runs its stories on the weekly-frozen reference
  artifact (task 146), in the same job, as Chrome's `run_reference_build` does (tools/perf/core/bot_platforms.py).
  Expectations (task 023) and feature arms (task 098) are inputs: `skip(story, host)` and FeatureArm. Driver and
  `lab.py schedule` read expectations.json for each plan (expectations.active_at at the plan's `now`).
- One job per host: a host that the controller reports busy, or that runs a job of ours, gets nothing. A pinpoint
  work id is started once (task 016 gives each attempt its own id).
- A side lane (`Lane`: the regression canary, canary.py, p12-perf-process.md 3.7) measures its own commits into its
  own store. Its T0 rounds run on the waterfall's T0 shard owners, one job per free owner after the waterfall's T0
  and pinpoint work, and its builds are requested ahead. It touches no waterfall state: no batch, no queue item, no
  reference cadence. Each lane job id starts once, as a pinpoint work id does.

Driver wraps plan() for labd (task 012): it reads the branch tip with `git ls-remote` (labd calls tick() every
POLL_SECONDS and on controller callbacks), fetches only that one ref when the tip moved, hands the plan to labd's
submit callback and saves the state in a JSON file only after that returns, with each job the controller refused
put back (`unstarted`). Stdlib only; loads siblings by file path, so it runs under `python3 -I`.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
from collections.abc import Callable, Iterable, Mapping, Sequence
from dataclasses import dataclass, field, replace
from datetime import datetime, timedelta, timezone
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO_ROOT = HERE.parents[1]


def _load_sibling(name: str):
    module_name = f"perf_lab_{name}"
    if module_name in sys.modules:
        return sys.modules[module_name]
    spec = importlib.util.spec_from_file_location(module_name, HERE / f"{name}.py")
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module  # before exec: dataclasses resolve their module through sys.modules
    spec.loader.exec_module(module)
    return module


STATE_SCHEMA = "cmux-perf-scheduler-state/v1"
BATCH_INTERVAL = timedelta(minutes=10)
T1_INTERVAL = timedelta(hours=2)
T1_HEADROOM = 1.25  # a shard whose T1 stories take longer than T1_INTERVAL starts a round every 1.25x their seconds
BORROW_LEAD = timedelta(minutes=10)
REFERENCE_EVERY = 6
EVERY_SECOND_QUEUE = 2  # every-2nd-batch mode while more builds than this are queued (3.11)
NIGHTLY_HOUR_UTC = 9  # a lab day starts at 09:00 UTC (02:00 PDT)
AA_PROMOTE_AFTER = timedelta(hours=12)  # an A/A still waiting at 21:00 UTC goes before T1 and T2
BUILD_TIMEOUT = timedelta(hours=1)  # a batch-tip build not ready, queued or failed by then (or 3x the estimate)
POLL_SECONDS = 60
AA_PASSES = 2  # A/A: the T0 stories twice on one artifact (task 024)
STALE_SLACK = timedelta(minutes=10)
BATCH_HISTORY = 144  # one day of 10-minute batches kept in the state for coverage
REQUESTED_HISTORY = 256  # builds asked for and not stored yet; a failed build is never asked for again
DISPATCHED_HISTORY = 256  # pinpoint work ids already started; an id is never started twice

WATERFALL = "waterfall"
PINPOINT = "pinpoint"
ROLES = (WATERFALL, PINPOINT)
BISECT = "bisect"
VERIFY = "verify"
AA = "aa"
PINPOINT_KINDS = (BISECT, VERIFY)
SHARDED_TIERS = ("T0", "T1", "T2")

PENDING = "pending"  # cut, waits for its build
SKIPPED = "skipped"  # cut in every-2nd-batch mode: no build, folds into the next measured batch
MEASURED = "measured"  # a T0 round was planned on its tip (a shard that could not start it covers it next round)
FOLDED = "folded"  # a newer batch was built first; its T0 range covers this one
FAILED = "failed"  # its tip build failed or never came; it folds into the next measured batch, as a skipped one does


class SchedulerError(ValueError):
    """An input the scheduler cannot plan with (an unknown role, a broken shard map or state file)."""


# ---------- inputs ----------

@dataclass(frozen=True)
class StorySpec:
    id: str
    tier: str
    seconds: int
    config: str


@dataclass(frozen=True)
class Host:
    """A lab host as pool.json (task 130) and the controller's status describe it."""

    name: str
    role: str  # WATERFALL or PINPOINT
    lab_class: str  # a shard_map.json class
    host_class: str  # the series host class (store.host_class), which pinpoint work is pinned to
    shard: int | None = None  # the waterfall shard this host holds
    up: bool = True
    busy: bool = False

    def __post_init__(self) -> None:
        if self.role not in ROLES:
            raise SchedulerError(f"host {self.name}: role {self.role!r} is not one of {', '.join(ROLES)}")
        if self.role == WATERFALL and self.shard is None:
            raise SchedulerError(f"host {self.name}: a waterfall host needs a shard index")


@dataclass(frozen=True)
class Builds:
    """Bench builds by (sha, config): stored artifacts and the builders' queue (task 234)."""

    ready: frozenset[tuple[str, str]] = frozenset()
    queued: frozenset[tuple[str, str]] = frozenset()
    expected_seconds: int = 0  # a batch-tip build's recent wall time; 0 = unknown, so nothing borrows on a guess
    failed: frozenset[tuple[str, str]] = frozenset()  # builds the builders gave up on (task 234)


@dataclass(frozen=True)
class PinpointWork:
    """One unit of Pinpoint work (task 016) that needs a host of its class: a bisect step or a verification.

    `id` names one attempt. The scheduler starts an id once, so a retry of the same step needs a new id.
    `build_only`: a Pinpoint Build step. Its builds are requested in Pinpoint order (after batch tips and tier
    builds) and no job ever starts for it; the executor reads the answer from the build ledger."""

    id: str
    kind: str  # BISECT or VERIFY
    host_class: str
    story: str
    seconds: int
    builds: tuple[tuple[str, str], ...] = ()
    prefer_host: str | None = None  # bisect: the host its last story job ran on; verify: the bisect's host
    build_only: bool = False

    def __post_init__(self) -> None:
        if self.kind not in PINPOINT_KINDS:
            raise SchedulerError(f"pinpoint work {self.id}: kind {self.kind!r} is not bisect or verify")


@dataclass(frozen=True)
class LaneRound:
    """One T0 round of a side lane: the lane's stories at `sha`, covering the commits from `first`. `id` names one
    attempt; a lane that asks again uses a new id."""

    id: str
    sha: str
    first: str


@dataclass(frozen=True)
class Lane:
    """A side lane (the regression canary): `stories` (T0 story ids) at each round's sha on their T0 shard owners.
    `builds` are the shas the lane needs built, requested ahead so its rounds keep the batch cadence."""

    name: str
    stories: tuple[str, ...]
    builds: tuple[str, ...]
    rounds: tuple[LaneRound, ...]


@dataclass(frozen=True)
class FeatureArm:
    """Task 098: a perfPath feature whose default or story code changed; it gets an on/off try pair per day."""

    feature: str
    stories: tuple[str, ...] = ()


@dataclass(frozen=True)
class ShardMap:
    """shard_map.json: lab class -> its tiers and, per shard, the stories of each tier."""

    classes: Mapping[str, tuple[tuple[str, ...], tuple[Mapping[str, tuple[str, ...]], ...]]]

    @classmethod
    def from_document(cls, document: Mapping) -> "ShardMap":
        if not isinstance(document, Mapping) or not isinstance(document.get("classes"), Mapping):
            raise SchedulerError("shard map: expected {\"classes\": {...}}")
        classes = {}
        for name, entry in document["classes"].items():
            try:
                tiers = tuple(entry["tiers"])
                shards = tuple({tier: tuple(shard["stories"].get(tier, ())) for tier in tiers}
                               for shard in sorted(entry["shards"], key=lambda s: s["index"]))
            except (KeyError, TypeError, AttributeError) as error:
                raise SchedulerError(f"shard map class {name}: {error!r}") from None
            classes[name] = (tiers, shards)
        return cls(classes)

    @classmethod
    def load(cls, path: Path | str) -> "ShardMap":
        try:
            return cls.from_document(json.loads(Path(path).read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError) as error:
            raise SchedulerError(f"{path}: {error}") from None

    def tiers(self, lab_class: str) -> tuple[str, ...]:
        return self.classes.get(lab_class, ((), ()))[0]

    def shards(self, lab_class: str) -> tuple[Mapping[str, tuple[str, ...]], ...]:
        return self.classes.get(lab_class, ((), ()))[1]

    def owner(self, lab_class: str, tier: str, story: str) -> int | None:
        for index, shard in enumerate(self.shards(lab_class)):
            if story in shard.get(tier, ()):
                return index
        return None

    def sharded(self) -> set[tuple[str, str]]:
        return {(tier, story) for tiers, shards in self.classes.values() for shard in shards
                for tier in tiers for story in shard.get(tier, ())}


def stories_from_catalog(catalog) -> tuple[StorySpec, ...]:
    """The stories the lab can run: a not-measurable one (catalog.Story.not_measurable) gets no round and no build."""
    return tuple(StorySpec(s.id, s.tier, s.seconds, s.config) for s in catalog.stories if s.measurable())


# ---------- state ----------

@dataclass(frozen=True)
class Batch:
    seq: int
    first: str
    tip: str
    commits: int
    cut_at: datetime
    status: str = PENDING
    measured_in: int | None = None  # the seq of the batch whose T0 covered this one


@dataclass(frozen=True)
class Item:
    """Waterfall-side work waiting for its host: a T0 shard, one T1/T2 story or an A/A run."""

    kind: str  # "waterfall" or AA (store.RUN_KINDS)
    tier: str | None
    round: str
    key: str  # "<lab class>/<shard>" for shard work, the host name for A/A
    sha: str | None
    stories: tuple[str, ...]
    passes: int = 1
    first: str | None = None  # T0: the first commit of the measured range


@dataclass(frozen=True)
class Running:
    job_id: str
    host: str
    started: datetime
    seconds: int


@dataclass(frozen=True)
class State:
    seq: int = 0
    last_cut_tip: str | None = None
    last_cut_at: datetime | None = None
    last_t0_sha: str | None = None
    rounds: int = 0
    batches: tuple[Batch, ...] = ()
    queue: tuple[Item, ...] = ()
    running: tuple[Running, ...] = ()
    requested: tuple[tuple[str, str], ...] = ()
    tier_at: Mapping[str, datetime] = field(default_factory=dict)  # "T1:m6/0" -> its last round start
    tier_day: Mapping[str, str] = field(default_factory=dict)  # "T2:aws-m4pro/0" -> its last lab day
    aa_day: Mapping[str, str] = field(default_factory=dict)  # host -> the lab day of its last A/A
    t0_count: Mapping[str, int] = field(default_factory=dict)  # host -> T0 jobs dispatched
    arms_day: Mapping[str, str] = field(default_factory=dict)  # feature -> the lab day of its last arm pair
    dispatched: tuple[str, ...] = ()  # pinpoint work ids already started, newest last

    def to_document(self) -> dict:
        def stamp(moment: datetime | None) -> str | None:
            return None if moment is None else moment.astimezone(timezone.utc).isoformat()

        return {
            "schema": STATE_SCHEMA,
            "seq": self.seq, "last_cut_tip": self.last_cut_tip, "last_cut_at": stamp(self.last_cut_at),
            "last_t0_sha": self.last_t0_sha, "rounds": self.rounds,
            "batches": [{**b.__dict__, "cut_at": stamp(b.cut_at)} for b in self.batches],
            "queue": [{**i.__dict__, "stories": list(i.stories)} for i in self.queue],
            "running": [{**r.__dict__, "started": stamp(r.started)} for r in self.running],
            "requested": [list(r) for r in self.requested],
            "tier_at": {k: stamp(v) for k, v in sorted(self.tier_at.items())},
            "tier_day": dict(sorted(self.tier_day.items())), "aa_day": dict(sorted(self.aa_day.items())),
            "t0_count": dict(sorted(self.t0_count.items())), "arms_day": dict(sorted(self.arms_day.items())),
            "dispatched": list(self.dispatched),
        }

    @classmethod
    def from_document(cls, document: Mapping) -> "State":
        if document.get("schema") != STATE_SCHEMA:
            raise SchedulerError(f"scheduler state: schema is {document.get('schema')!r}, not {STATE_SCHEMA}")

        def when(text: str | None) -> datetime | None:
            return None if text is None else parse_time(text)

        try:
            return cls(
                seq=int(document["seq"]), last_cut_tip=document["last_cut_tip"],
                last_cut_at=when(document["last_cut_at"]), last_t0_sha=document["last_t0_sha"],
                rounds=int(document["rounds"]),
                batches=tuple(Batch(**{**b, "cut_at": when(b["cut_at"])}) for b in document["batches"]),
                queue=tuple(Item(**{**i, "stories": tuple(i["stories"])}) for i in document["queue"]),
                running=tuple(Running(**{**r, "started": when(r["started"])}) for r in document["running"]),
                requested=tuple(tuple(r) for r in document["requested"]),
                tier_at={k: when(v) for k, v in document["tier_at"].items()},
                tier_day=dict(document["tier_day"]), aa_day=dict(document["aa_day"]),
                t0_count={k: int(v) for k, v in document["t0_count"].items()},
                arms_day=dict(document["arms_day"]), dispatched=tuple(document.get("dispatched", ())),
            )
        except SchedulerError as error:
            raise SchedulerError(f"scheduler state: {error}") from None
        except (KeyError, TypeError, ValueError) as error:
            raise SchedulerError(f"scheduler state: {error!r}") from None


def parse_time(text: str) -> datetime:
    """An RFC 3339 time with its UTC offset. A time with no offset is refused: every time the scheduler compares
    is aware, and a naive one would raise TypeError deep inside plan()."""
    try:
        moment = datetime.fromisoformat(text)
    except ValueError:
        raise SchedulerError(f"{text!r} is not an RFC 3339 time") from None
    if moment.tzinfo is None:
        raise SchedulerError(f"{text!r} has no UTC offset (write it as {text}Z or {text}+00:00)")
    return moment


def finished(state: State, job_id: str) -> State:
    """The controller's job-finished callback: the job's host is free for the next plan."""
    return replace(state, running=tuple(r for r in state.running if r.job_id != job_id))


def unstarted(state: State, job: "Job") -> State:
    """A planned job the controller refused or labd could not submit: its work goes back to the front of the queue
    (pinpoint and lane work becomes dispatchable again) and its host is free for the next plan."""
    running = tuple(r for r in state.running if r.job_id != job.id)
    if job.kind in PINPOINT_KINDS or job.work_id is not None:
        return replace(state, running=running, dispatched=tuple(w for w in state.dispatched if w != job.work_id))
    item = Item(job.kind, job.tier, job.round, job.key, job.sha, job.stories, job.passes, job.first)
    t0_count = dict(state.t0_count)
    if job.tier == "T0" and t0_count.get(job.host, 0) > 0:
        t0_count[job.host] -= 1  # the reference cadence counts T0 jobs that ran
    return replace(state, running=running, queue=(item, *state.queue), t0_count=t0_count)


def arm_unsent(state: State, feature: str) -> State:
    """A feature's try pair that labd could not queue: the next plan of the same lab day offers it again."""
    return replace(state, arms_day={k: v for k, v in state.arms_day.items() if k != feature})


# ---------- outputs ----------

@dataclass(frozen=True)
class Job:
    id: str
    kind: str  # store.RUN_KINDS: waterfall, bisect, verify, aa
    host: str
    seconds: int
    tier: str | None = None
    round: str | None = None
    sha: str | None = None
    first: str | None = None
    stories: tuple[str, ...] = ()
    passes: int = 1
    reference: str | None = None  # T0: also run the stories on this frozen artifact (`reference` runs)
    work_id: str | None = None  # pinpoint work, or a lane job (its own id): started once, never queued
    key: str | None = None  # the queue key it came from: "<lab class>/<shard>", or the host for A/A
    lane: str | None = None  # the side lane whose store its results go to (Lane.name)


@dataclass(frozen=True)
class BuildRequest:
    sha: str
    config: str
    reason: str  # "batch-tip", "tier" or the pinpoint work id


@dataclass(frozen=True)
class Gap:
    tier: str
    round: str
    story: str
    key: str
    reason: str


@dataclass(frozen=True)
class Skip:
    story: str
    host: str
    round: str


@dataclass(frozen=True)
class TryArm:
    feature: str
    value: str  # "on" or "off"
    sha: str
    stories: tuple[str, ...]


@dataclass(frozen=True)
class Plan:
    state: State
    jobs: tuple[Job, ...]
    builds: tuple[BuildRequest, ...]
    gaps: tuple[Gap, ...]
    skipped: tuple[Skip, ...]
    arms: tuple[TryArm, ...]
    mode: str  # "every-batch" or "every-2nd-batch"
    cut: Batch | None
    problems: tuple[str, ...]

    def to_document(self) -> dict:
        return {
            "mode": self.mode, "cut": None if self.cut is None else self.cut.seq,
            "jobs": [{**j.__dict__, "stories": list(j.stories)} for j in self.jobs],
            "builds": [b.__dict__ for b in self.builds], "gaps": [g.__dict__ for g in self.gaps],
            "skipped": [s.__dict__ for s in self.skipped],
            "arms": [{**a.__dict__, "stories": list(a.stories)} for a in self.arms],
            "problems": list(self.problems),
        }


def lab_day(now: datetime) -> str:
    return (now.astimezone(timezone.utc) - timedelta(hours=NIGHTLY_HOUR_UTC)).date().isoformat()


def lab_day_start(now: datetime) -> datetime:
    day = datetime.fromisoformat(lab_day(now))
    return day.replace(hour=NIGHTLY_HOUR_UTC, tzinfo=timezone.utc)


# ---------- plan ----------

def plan(state: State, now: datetime, hosts: Sequence[Host], builds: Builds, branch_log: Sequence[str], *,
         stories: Sequence[StorySpec], shard_map: ShardMap, pinpoint: Sequence[PinpointWork] = (),
         skip: Callable[[str, Host], bool] | None = None, arms: Sequence[FeatureArm] = (),
         reference: str | None = None, lanes: Sequence[Lane] = ()) -> Plan:
    """The jobs to start now, the builds to request and the new state. No I/O; `now` is the only clock."""
    if now.tzinfo is None:
        raise SchedulerError(f"plan: now ({now.isoformat()}) has no UTC offset")
    return _Planner(state, now, hosts, builds, branch_log, stories, shard_map, pinpoint, skip, arms, reference,
                    lanes).run()


class _Planner:
    def __init__(self, state, now, hosts, builds, branch_log, stories, shard_map, pinpoint, skip, arms, reference,
                 lanes=()):
        self.state = state
        self.now = now
        self.hosts = sorted(hosts, key=lambda h: h.name)
        self.builds = builds
        self.log = tuple(branch_log)
        self.stories = {s.id: s for s in stories}
        self.shard_map = shard_map
        self.pinpoint = tuple(pinpoint)
        self.skip = skip or (lambda story, host: False)
        self.arms = tuple(arms)
        self.reference = reference
        self.lanes = tuple(lanes)
        self.day = lab_day(now)
        self.jobs: list[Job] = []
        self.requests: list[BuildRequest] = []
        self.gaps: list[Gap] = []
        self.skipped: list[Skip] = []
        self.problems: list[str] = []
        self.cut: Batch | None = None
        self.mode = "every-2nd-batch" if len(builds.queued) > EVERY_SECOND_QUEUE else "every-batch"
        self.batches = list(state.batches)
        self.queue = list(state.queue)
        self.tier_at = dict(state.tier_at)
        self.tier_day = dict(state.tier_day)
        self.aa_day = dict(state.aa_day)
        self.t0_count = dict(state.t0_count)
        self.arms_day = dict(state.arms_day)
        self.rounds = state.rounds
        self.last_t0_sha = state.last_t0_sha
        self.last_cut_tip = state.last_cut_tip
        self.last_cut_at = state.last_cut_at
        self.dispatched = list(state.dispatched)
        self.try_arms: list[TryArm] = []
        self.running = self._live_running()
        self.busy = {h.name for h in self.hosts if h.busy or not h.up} | {r.host for r in self.running}
        self.owners = self._owners()

    # --- helpers ---

    def _live_running(self) -> list[Running]:
        """Our jobs still on their hosts. One whose callback never came is dropped once the host reports idle
        well past the job's expected end, so a lost callback cannot hold a host forever."""
        idle = {h.name for h in self.hosts if h.up and not h.busy}
        live = []
        for job in self.state.running:
            deadline = job.started + timedelta(seconds=2 * job.seconds) + STALE_SLACK
            if job.host in idle and self.now > deadline:
                self.problems.append(f"job {job.job_id} on {job.host}: no finish callback and the host is idle; freed")
                continue
            live.append(job)
        return live

    def _owners(self) -> dict[str, Host]:
        owners: dict[str, Host] = {}
        for host in self.hosts:
            if host.role != WATERFALL:
                continue
            key = f"{host.lab_class}/{host.shard}"
            if key in owners:
                self.problems.append(f"shard {key}: held by both {owners[key].name} and {host.name}; "
                                     f"{owners[key].name} is the owner")
                continue
            owners[key] = host
        return owners

    def _tier_stories(self, tier: str) -> list[StorySpec]:
        return [s for s in self.stories.values() if s.tier == tier]

    def _configs(self, story_ids: Iterable[str]) -> set[str]:
        return {self.stories[s].config for s in story_ids if s in self.stories}

    def _ready(self, sha: str, configs: Iterable[str]) -> bool:
        return all((sha, config) in self.builds.ready for config in configs)

    def _failed(self, sha: str, configs: Iterable[str]) -> list[str]:
        return sorted(config for config in configs if (sha, config) in self.builds.failed)

    def _request(self, sha: str, configs: Iterable[str], reason: str) -> None:
        for config in sorted(configs):
            pair = (sha, config)
            if pair in self.builds.ready or pair in self.builds.queued or pair in self.builds.failed:
                continue
            if pair in self.state.requested:
                continue
            if any((r.sha, r.config) == pair for r in self.requests):
                continue
            self.requests.append(BuildRequest(sha, config, reason))

    def _free(self, host: Host) -> bool:
        return host.up and host.name not in self.busy

    def _holds_t0(self, host: Host) -> bool:
        if host.role != WATERFALL or "T0" not in self.shard_map.tiers(host.lab_class):
            return False
        shards = self.shard_map.shards(host.lab_class)
        return host.shard < len(shards) and any(s in self.stories for s in shards[host.shard].get("T0", ()))

    def _next_t0_at(self, host: Host, *, quiet_is_free: bool) -> datetime | None:
        """When a T0 may need this host: None on a host that holds no T0 shard, now while its T0 shard or a batch
        waits, else the next cut plus a build. On a branch with no merge since the last cut, that is when a merge
        landing now would be measured, unless `quiet_is_free` (the late A/A slot), which reads it as no T0 due."""
        if not self._holds_t0(host):
            return None
        key = f"{host.lab_class}/{host.shard}"
        if any(i.tier == "T0" and i.key == key for i in self.queue) or any(b.status == PENDING for b in self.batches):
            return self.now
        if quiet_is_free and (not self.log or self.log[-1] == self.last_cut_tip):
            return None
        earliest = self.now if self.last_cut_at is None else max(self.now, self.last_cut_at + BATCH_INTERVAL)
        return earliest + timedelta(seconds=self.builds.expected_seconds)

    def _may_take(self, host: Host, seconds: int, *, quiet_is_free: bool = False) -> bool:
        """Lower-priority work on a waterfall host must leave its next T0 untouched."""
        next_t0 = self._next_t0_at(host, quiet_is_free=quiet_is_free)
        if next_t0 is None:
            return True
        return next_t0 - self.now > BORROW_LEAD and self.now + timedelta(seconds=seconds) <= next_t0

    def _start(self, host: Host, job: Job) -> None:
        self.jobs.append(job)
        self.running.append(Running(job.id, host.name, self.now, job.seconds))
        self.busy.add(host.name)

    def _runnable(self, item: Item, host: Host) -> tuple[str, ...]:
        kept = []
        for story in item.stories:
            if self.skip(story, host):
                self.skipped.append(Skip(story, host.name, item.round))
            else:
                kept.append(story)
        return tuple(kept)

    def _seconds(self, story_ids: Iterable[str], passes: int = 1) -> int:
        return passes * sum(self.stories[s].seconds for s in story_ids if s in self.stories)

    # --- steps ---

    def run(self) -> Plan:
        unsharded = sorted(s.id for s in self.stories.values()
                           if s.tier in SHARDED_TIERS and (s.tier, s.id) not in self.shard_map.sharded())
        if unsharded:
            self.problems.append(f"stories not in the shard map: {', '.join(unsharded)}; run gen_shard_map.py")
        self._cut_batch()
        self._fail_batches()
        self._t0_round()
        self._tier_rounds()
        self._nightly()
        self._gap_unowned()
        self._lane_builds()
        self._dispatch()
        self._feature_arms()
        return self._result()

    def _cut_batch(self) -> None:
        last = self.state.last_cut_tip
        if not self.log or self.log[-1] == last:
            return
        if self.last_cut_at is not None and self.now - self.last_cut_at < BATCH_INTERVAL:
            return
        new = self.log[self.log.index(last) + 1:] if last in self.log else self.log
        previous = self.batches[-1] if self.batches else None
        skipped = self.mode == "every-2nd-batch" and previous is not None and previous.status != SKIPPED
        self.cut = Batch(self.state.seq + 1, new[0], new[-1], len(new), self.now, SKIPPED if skipped else PENDING)
        self.batches.append(self.cut)
        self.last_cut_tip = self.cut.tip
        self.last_cut_at = self.now
        if not skipped:
            self._request(self.cut.tip, self._configs(s.id for s in self._tier_stories("T0")), "batch-tip")

    def _fail_batches(self) -> None:
        """A pending batch whose tip build failed, or is neither ready nor queued long after its cut, stops waiting:
        it no longer holds the waterfall hosts as a T0 due now, and its commits fold into the next measured batch."""
        configs = self._configs(s.id for s in self._tier_stories("T0"))
        timeout = max(BUILD_TIMEOUT, timedelta(seconds=3 * self.builds.expected_seconds))
        for index, batch in enumerate(self.batches):
            if batch.status != PENDING or self._ready(batch.tip, configs):
                continue
            failed = self._failed(batch.tip, configs)
            queued = any((batch.tip, config) in self.builds.queued for config in configs)
            if failed:
                reason = f"its tip build {batch.tip[:12]} ({', '.join(failed)}) failed"
            elif not queued and self.now - batch.cut_at > timeout:
                reason = f"its tip build {batch.tip[:12]} did not come within {timeout}"
            else:
                continue
            self.batches[index] = replace(batch, status=FAILED)
            self.problems.append(f"batch {batch.seq}: {reason}; its commits fold into the next measured batch")

    def _t0_round(self) -> None:
        t0 = self._tier_stories("T0")
        configs = self._configs(s.id for s in t0)
        built = [b for b in self.batches if b.status == PENDING and self._ready(b.tip, configs)]
        if not built:
            return
        batch = max(built, key=lambda b: b.seq)
        covered = [b for b in self.batches if b.seq <= batch.seq and b.measured_in is None]
        first = min(covered, key=lambda b: b.seq).first
        for index, other in enumerate(self.batches):
            if other.seq == batch.seq:
                self.batches[index] = replace(other, status=MEASURED, measured_in=batch.seq)
            elif other in covered:
                status = FOLDED if other.status == PENDING else other.status
                self.batches[index] = replace(other, status=status, measured_in=batch.seq)
        self.last_t0_sha = batch.tip
        round_name = f"T0-{batch.seq}"
        # A shard that has not started its older round gets this one in its place, with the older range's first
        # commit, so its range still starts after its own last T0 job.
        stale: dict[str, Item] = {}
        for item in [i for i in self.queue if i.tier == "T0"]:
            stale.setdefault(item.key, item)
            self.queue.remove(item)
        for lab_class in sorted(self.shard_map.classes):
            if "T0" not in self.shard_map.tiers(lab_class):
                continue
            for index, shard in enumerate(self.shard_map.shards(lab_class)):
                key = f"{lab_class}/{index}"
                ids = tuple(s for s in shard.get("T0", ()) if s in self.stories)
                if ids:
                    since = stale[key].first if key in stale else first
                    self.queue.append(Item("waterfall", "T0", round_name, key, batch.tip, ids, first=since))

    def _tier_rounds(self) -> None:
        if self.last_t0_sha is None:
            return
        for index, item in enumerate(self.queue):  # a T1/T2 story whose build never came measures the newer tip
            if item.tier in ("T1", "T2") and item.sha != self.last_t0_sha and not self._ready(
                    item.sha, self._configs(item.stories)):
                self.queue[index] = replace(item, sha=self.last_t0_sha)
                self._request(self.last_t0_sha, self._configs(item.stories), "tier")
        self._drop_failed_builds()
        for lab_class in sorted(self.shard_map.classes):
            if "T1" not in self.shard_map.tiers(lab_class):
                continue
            for index, shard in enumerate(self.shard_map.shards(lab_class)):
                key = f"{lab_class}/{index}"
                started = self.tier_at.get(f"T1:{key}")
                if started is not None and self.now - started < self._t1_interval(shard.get("T1", ())):
                    continue
                if any(i.tier == "T1" and i.key == key for i in self.queue):
                    continue  # the previous round on this shard is still being dispatched
                self._shard_round("T1", key, shard.get("T1", ()))
                self.tier_at[f"T1:{key}"] = self.now

    def _t1_interval(self, story_ids: Iterable[str]) -> timedelta:
        """T1_INTERVAL, or T1_HEADROOM times the shard's T1 seconds when they do not fit in it, so an overloaded
        shard still leaves its host idle time for T2 and A/A (gen_shard_map.py warns about such a shard)."""
        return max(T1_INTERVAL, timedelta(seconds=T1_HEADROOM * self._seconds(story_ids)))

    def _drop_failed_builds(self) -> None:
        """A queued T1/T2 story or A/A run whose build failed at the newest T0 sha would block its shard's next
        round for ever: it is a gap (T1/T2) or a problem (A/A), and the next round measures a newer build."""
        for item in list(self.queue):
            if item.tier == "T0" or item.sha is None:
                continue
            failed = self._failed(item.sha, self._configs(item.stories))
            if not failed:
                continue
            self.queue.remove(item)
            reason = f"build {item.sha[:12]} ({', '.join(failed)}) failed"
            if item.kind == AA:
                self.problems.append(f"{item.round} on {item.key}: {reason}; no A/A this lab day")
            else:
                self.gaps.extend(Gap(item.tier, item.round, story, item.key, reason) for story in item.stories)

    def _shard_round(self, tier: str, key: str, story_ids: Iterable[str]) -> None:
        ids = [s for s in story_ids if s in self.stories]
        if not ids:
            return
        self.rounds += 1
        round_name = f"{tier}-{self.rounds}"
        for story in ids:
            self.queue.append(Item("waterfall", tier, round_name, key, self.last_t0_sha, (story,)))
        self._request(self.last_t0_sha, self._configs(ids), "tier")

    def _nightly(self) -> None:
        if self.last_t0_sha is None:
            return
        for lab_class in sorted(self.shard_map.classes):
            if "T2" not in self.shard_map.tiers(lab_class):
                continue
            for index, shard in enumerate(self.shard_map.shards(lab_class)):
                key = f"{lab_class}/{index}"
                if self.tier_day.get(f"T2:{key}") == self.day or any(i.tier == "T2" and i.key == key
                                                                     for i in self.queue):
                    continue
                self._shard_round("T2", key, shard.get("T2", ()))
                self.tier_day[f"T2:{key}"] = self.day
        t0_ids = tuple(sorted(s.id for s in self._tier_stories("T0")))
        if not t0_ids:
            return
        for host in self.hosts:
            if host.up and self.aa_day.get(host.name) != self.day:
                for old in [i for i in self.queue if i.kind == AA and i.key == host.name]:
                    self.queue.remove(old)
                    self.problems.append(f"{old.round} on {host.name}: never found a free slot; replaced")
                self.queue.append(Item(AA, None, f"aa-{self.day}", host.name, self.last_t0_sha, t0_ids,
                                       passes=AA_PASSES))
                self.aa_day[host.name] = self.day

    def _gap_unowned(self) -> None:
        """A shard item whose owner is down or missing is a coverage gap; the story is never moved."""
        for item in list(self.queue):
            if item.kind != "waterfall":
                continue
            owner = self.owners.get(item.key)
            if owner is not None and owner.up:
                continue
            reason = f"owner {owner.name} is down" if owner else f"no waterfall host holds shard {item.key}"
            self.queue.remove(item)
            self.gaps.extend(Gap(item.tier, item.round, story, item.key, reason) for story in item.stories)

    def _lane_builds(self) -> None:
        for lane in self.lanes:
            configs = self._configs(lane.stories)
            for sha in lane.builds:
                self._request(sha, configs, f"lane:{lane.name}")

    def _dispatch(self) -> None:
        self._dispatch_shard_items("T0")
        self._dispatch_pinpoint()
        self._dispatch_lanes()
        if self.now - lab_day_start(self.now) >= AA_PROMOTE_AFTER:
            self._dispatch_aa(late=True)
        self._dispatch_shard_items("T1")
        self._dispatch_shard_items("T2")
        self._dispatch_aa(late=False)

    def _dispatch_shard_items(self, tier: str) -> None:
        for item in [i for i in self.queue if i.tier == tier]:
            host = self.owners[item.key]
            if not self._free(host):
                continue
            if not self._ready(item.sha, self._configs(item.stories)):
                continue
            self.queue.remove(item)
            ids = self._runnable(item, host)
            if not ids:
                continue
            label = item.round if tier == "T0" else f"{item.round}:{ids[0]}"
            reference = self._reference(host) if tier == "T0" else None
            seconds = self._seconds(ids, 2 if reference else 1)
            self._start(host, Job(f"waterfall:{label}:{host.name}", "waterfall", host.name, seconds, tier=tier,
                                  round=item.round, sha=item.sha, first=item.first, stories=ids, reference=reference,
                                  key=item.key))

    def _reference(self, host: Host) -> str | None:
        count = self.t0_count.get(host.name, 0) + 1
        self.t0_count[host.name] = count
        return self.reference if self.reference is not None and count % REFERENCE_EVERY == 0 else None

    def _dispatch_pinpoint(self) -> None:
        started = {r.job_id for r in self.running} | set(self.dispatched)
        order = sorted(range(len(self.pinpoint)), key=lambda i: (PINPOINT_KINDS.index(self.pinpoint[i].kind), i))
        for work in (self.pinpoint[i] for i in order):
            if work.id in started:
                continue
            failed = sorted(f"{sha[:12]} {config}" for sha, config in work.builds
                            if (sha, config) in self.builds.failed)
            if failed:
                if not work.build_only:  # a failed build answers a Build step; the executor records it
                    self.problems.append(f"pinpoint work {work.id}: build {', '.join(failed)} failed; not started")
                continue
            if not all(pair in self.builds.ready for pair in work.builds):
                for sha, config in work.builds:
                    self._request(sha, (config,), work.id)
                continue
            if work.build_only:
                continue
            host = self._pinpoint_host(work)
            if host is None:
                continue
            self._start(host, Job(work.id, work.kind, host.name, work.seconds, stories=(work.story,), work_id=work.id))
            self.dispatched.append(work.id)
            started.add(work.id)

    def _dispatch_lanes(self) -> None:
        """Each lane round's T0 shards on their owners, once the owner is free and the build is ready. A job id
        (round id and shard) starts once. An owner that is down or busy only delays the lane: it is never moved."""
        started = {r.job_id for r in self.running} | set(self.dispatched)
        for lane in self.lanes:
            wanted = set(lane.stories)
            for lane_round in lane.rounds:
                if not self._ready(lane_round.sha, self._configs(lane.stories)):
                    continue
                for lab_class in sorted(self.shard_map.classes):
                    if "T0" not in self.shard_map.tiers(lab_class):
                        continue
                    for index, shard in enumerate(self.shard_map.shards(lab_class)):
                        job_id = f"{lane_round.id}:{lab_class}.{index}"
                        host = self.owners.get(f"{lab_class}/{index}")
                        ids = tuple(s for s in shard.get("T0", ()) if s in wanted and s in self.stories)
                        if not ids or job_id in started or host is None or not self._free(host):
                            continue
                        ids = tuple(s for s in ids if not self.skip(s, host))
                        if not ids:
                            continue
                        self._start(host, Job(job_id, "waterfall", host.name, self._seconds(ids), tier="T0",
                                              round=lane_round.id, sha=lane_round.sha, first=lane_round.first,
                                              stories=ids, work_id=job_id, key=f"{lab_class}/{index}",
                                              lane=lane.name))
                        self.dispatched.append(job_id)
                        started.add(job_id)

    def _pinpoint_host(self, work: PinpointWork) -> Host | None:
        own = [h for h in self.hosts if h.role == PINPOINT and h.host_class == work.host_class and self._free(h)]
        preferred = [h for h in own if h.name == work.prefer_host]
        if preferred or own:
            return (preferred or own)[0]
        borrow = [h for h in self.hosts if h.role == WATERFALL and h.host_class == work.host_class
                  and self._free(h) and self._may_take(h, work.seconds)]
        return borrow[0] if borrow else None

    def _dispatch_aa(self, *, late: bool) -> None:
        """A/A on its host. Late in the lab day (AA_PROMOTE_AFTER) it goes before T1 and T2, and on a waterfall host
        it may start while no merge waits, so a host whose T1 queue never empties still gets its daily A/A."""
        by_name = {h.name: h for h in self.hosts}
        for item in [i for i in self.queue if i.kind == AA]:
            host = by_name.get(item.key)
            if host is None:
                self.queue.remove(item)
                self.problems.append(f"{item.round}: host {item.key} left the pool")
                continue
            if not self._ready(item.sha, self._configs(item.stories)):
                continue
            seconds = self._seconds(item.stories, item.passes)
            if not self._free(host) or not self._may_take(host, seconds, quiet_is_free=late):
                continue
            self.queue.remove(item)
            ids = self._runnable(item, host)
            if not ids:
                continue
            self._start(host, Job(f"aa:{item.round}:{host.name}", AA, host.name, self._seconds(ids, item.passes),
                                  round=item.round, sha=item.sha, stories=ids, passes=item.passes, key=item.key))

    def _feature_arms(self) -> None:
        if self.last_t0_sha is None:
            return
        for arm in self.arms:
            if self.arms_day.get(arm.feature) == self.day:
                continue
            self.arms_day[arm.feature] = self.day
            for value in ("on", "off"):
                self.try_arms.append(TryArm(arm.feature, value, self.last_t0_sha, tuple(arm.stories)))

    def _result(self) -> Plan:
        ready = self.builds.ready
        pairs = [*self.state.requested, *((r.sha, r.config) for r in self.requests)]
        requested = tuple(pair for pair in dict.fromkeys(pairs) if pair not in ready)[-REQUESTED_HISTORY:]
        state = State(
            seq=self.cut.seq if self.cut else self.state.seq,
            last_cut_tip=self.cut.tip if self.cut else self.state.last_cut_tip,
            last_cut_at=self.cut.cut_at if self.cut else self.state.last_cut_at,
            last_t0_sha=self.last_t0_sha, rounds=self.rounds,
            batches=tuple(self.batches[-BATCH_HISTORY:]), queue=tuple(self.queue), running=tuple(self.running),
            requested=requested, tier_at=self.tier_at, tier_day=self.tier_day, aa_day=self.aa_day,
            t0_count=self.t0_count, arms_day=self.arms_day,
            dispatched=tuple(dict.fromkeys(self.dispatched))[-DISPATCHED_HISTORY:],
        )
        builds = sorted(self.requests, key=lambda r: (r.reason != "batch-tip", r.reason != "tier"))
        return Plan(state, tuple(self.jobs), tuple(builds), tuple(self.gaps), tuple(self.skipped),
                    tuple(self.try_arms), self.mode, self.cut, tuple(self.problems))


# ---------- driver (labd, task 012) ----------

def git_ls_remote(remote: str, branch: str, *, repo: Path | str = REPO_ROOT,
                  run: Callable[..., subprocess.CompletedProcess] = subprocess.run) -> str | None:
    """The branch tip on the remote, or None when it cannot be read (the driver then keeps its last view)."""
    try:
        done = run(["git", "-C", str(repo), "ls-remote", "--exit-code", remote, f"refs/heads/{branch}"],
                   capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    fields = done.stdout.split()
    return fields[0] if done.returncode == 0 and fields else None


def git_first_parent(remote: str, branch: str, *, repo: Path | str = REPO_ROOT,
                     run: Callable[..., subprocess.CompletedProcess] = subprocess.run
                     ) -> Callable[[str | None, str], tuple[str, ...] | None]:
    """A branch_log reader: fetches only `branch` and lists its first-parent commits after `anchor`, oldest first."""
    local = f"refs/perf-lab/{branch}"

    def git(*args: str) -> subprocess.CompletedProcess | None:
        try:
            return run(["git", "-C", str(repo), *args], capture_output=True, text=True, timeout=300)
        except (OSError, subprocess.TimeoutExpired):
            return None

    def read(anchor: str | None, tip: str) -> tuple[str, ...] | None:
        fetched = git("fetch", "--no-tags", "--quiet", remote, f"+refs/heads/{branch}:{local}")
        if fetched is None or fetched.returncode != 0:
            return None
        checked = git("merge-base", "--is-ancestor", anchor, tip) if anchor is not None else None
        ancestor = checked is not None and checked.returncode == 0
        args = ("rev-list", "--first-parent", "--reverse", f"{anchor}..{tip}") if ancestor else (
            "rev-list", "--first-parent", "--max-count=1", tip)
        listed = git(*args, "--")
        return tuple(listed.stdout.split()) if listed is not None and listed.returncode == 0 else None

    return read


@dataclass(frozen=True)
class Rejected:
    """What labd's submit callback could not hand on: job ids the controller refused, features whose try pair
    could not be queued, and (sha, config) builds the builders refused, which the next tick asks for again."""

    jobs: frozenset[str] = frozenset()
    arms: frozenset[str] = frozenset()
    builds: frozenset[tuple[str, str]] = frozenset()


def write_state(path: Path, state: State) -> None:
    """Atomic: a reader sees the old state file or the new one, never a partial one."""
    path.parent.mkdir(parents=True, exist_ok=True)
    handle, temp = tempfile.mkstemp(dir=path.parent, prefix=".scheduler-", suffix=".json")
    try:
        with os.fdopen(handle, "w", encoding="utf-8") as out:
            json.dump(state.to_document(), out, indent=1, sort_keys=True)
        os.replace(temp, path)
    except BaseException:
        Path(temp).unlink(missing_ok=True)
        raise


def with_expectations(active, state: State, now: datetime, hosts: Sequence[Host], builds: Builds,
                      branch_log: Sequence[str], **inputs) -> Plan:
    """plan() with expectations.ActiveExpectations: its `skip` is the hook, its problems join the plan's."""
    result = plan(state, now, hosts, builds, branch_log, skip=active.skip, **inputs)
    return replace(result, problems=result.problems + tuple(active.problems))


class Driver:
    """plan() with its state file and its branch view. labd calls tick() every POLL_SECONDS and after each
    controller callback (job_finished) with a submit callback that submits the plan's jobs, builds and try arms
    and returns what it could not. The state is saved only after submit returns, so a crash inside it leaves the
    previous state and the next tick plans the same work with the same job ids (labd skips an id the controller
    already has). `expectations(now)` (expectations.active_at) gives each plan its skip hook and adds the problems
    of the expectations file to the plan's."""

    def __init__(self, state_path: Path | str, *, ls_remote: Callable[[], str | None],
                 first_parent: Callable[[str | None, str], tuple[str, ...] | None],
                 stories: Sequence[StorySpec], shard_map: ShardMap,
                 clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
                 expectations: Callable[[datetime], object] | None = None) -> None:
        self.path = Path(state_path)
        self.ls_remote = ls_remote
        self.first_parent = first_parent
        self.stories = tuple(stories)
        self.shard_map = shard_map
        self.clock = clock
        self.expectations = expectations
        self.tip: str | None = None
        self.log: tuple[str, ...] = ()
        self.state = State.from_document(json.loads(self.path.read_text())) if self.path.is_file() else State()

    def _refresh(self) -> None:
        tip = self.ls_remote()
        if tip is None or tip == self.tip:
            return
        log = self.first_parent(self.state.last_cut_tip, tip)
        if log is not None:
            self.tip, self.log = tip, log

    def tick(self, hosts: Sequence[Host], builds: Builds, *, submit: Callable[[Plan], Rejected],
             **inputs) -> Plan:
        self._refresh()
        now = self.clock()
        if self.expectations is None:
            result = plan(self.state, now, hosts, builds, self.log, stories=self.stories, shard_map=self.shard_map,
                          **inputs)
        else:
            result = with_expectations(self.expectations(now), self.state, now, hosts, builds, self.log,
                                       stories=self.stories, shard_map=self.shard_map, **inputs)
        rejected = submit(result)
        state = result.state
        for job in result.jobs:
            if job.id in rejected.jobs:
                state = unstarted(state, job)
        for feature in sorted(rejected.arms):
            state = arm_unsent(state, feature)
        if rejected.builds:
            state = replace(state, requested=tuple(pair for pair in state.requested if pair not in rejected.builds))
        self._save(state)
        return result

    def job_finished(self, job_id: str) -> None:
        self._save(finished(self.state, job_id))

    def _save(self, state: State) -> None:
        write_state(self.path, state)
        self.state = state


# ---------- command (lab.py protocol, task 005) ----------

LAB_COMMANDS = {
    "schedule": "Print the scheduler's plan for given hosts and builds (JSON); --write keeps the new state.",
}


def hosts_from_document(document: Mapping) -> list[Host]:
    """pool.json hosts (task 130) merged with controller status: {"hosts": [{name, role, class, host_class,
    shard?, up?, busy?}]}."""
    try:
        return [Host(name=h["name"], role=h["role"], lab_class=h["class"], host_class=h["host_class"],
                     shard=h.get("shard"), up=bool(h.get("up", True)), busy=bool(h.get("busy", False)))
                for h in document["hosts"]]
    except (KeyError, TypeError) as error:
        raise SchedulerError(f"hosts: {error!r}") from None


def builds_from_document(document: Mapping) -> Builds:
    try:
        return Builds(ready=frozenset(tuple(p) for p in document.get("ready", ())),
                      queued=frozenset(tuple(p) for p in document.get("queued", ())),
                      failed=frozenset(tuple(p) for p in document.get("failed", ())),
                      expected_seconds=int(document.get("expected_seconds", 0)))
    except (TypeError, ValueError) as error:
        raise SchedulerError(f"builds: {error!r}") from None


def add_arguments(command: str, parser: argparse.ArgumentParser) -> None:
    parser.add_argument("--root", type=Path, default=REPO_ROOT, help=argparse.SUPPRESS)
    parser.add_argument("--state", type=Path, required=True, help="the scheduler state file")
    parser.add_argument("--hosts", type=Path, required=True, help="JSON {hosts: [...]} (pool.json plus status)")
    parser.add_argument("--builds", type=Path, required=True,
                        help="JSON {ready, queued, failed, expected_seconds}")
    parser.add_argument("--branch-log", type=Path, help="first-parent shas after the last cut, oldest first")
    parser.add_argument("--now", help="RFC 3339 time with its UTC offset, for example 2026-10-26T12:30Z "
                                      "(default: now)")
    parser.add_argument("--write", action="store_true", help="store the new state (default: dry run)")


def run(command: str, args: argparse.Namespace, out=None, err=None) -> int:
    out = out or sys.stdout
    err = err or sys.stderr
    catalog = _load_sibling("catalog")
    expectations = _load_sibling("expectations")
    try:
        stories = stories_from_catalog(catalog.load_catalog(args.root))
        shard_map = ShardMap.load(args.root / "scripts/perf-lab/shard_map.json")
        state = State.from_document(json.loads(args.state.read_text())) if args.state.is_file() else State()
        hosts = hosts_from_document(json.loads(args.hosts.read_text()))
        builds = builds_from_document(json.loads(args.builds.read_text()))
        log = tuple(args.branch_log.read_text().split()) if args.branch_log else ()
        now = parse_time(args.now) if args.now else datetime.now(timezone.utc)
    except (SchedulerError, catalog.CatalogError, OSError, ValueError) as error:
        print(f"schedule: {error}", file=err)
        return 2
    active = expectations.active_at(args.root / expectations.EXPECTATIONS_PATH, now)
    result = with_expectations(active, state, now, hosts, builds, log, stories=stories, shard_map=shard_map)
    json.dump(result.to_document(), out, indent=1)
    print(file=out)
    if args.write:
        write_state(args.state, result.state)
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="scheduler.py", description=LAB_COMMANDS["schedule"])
    add_arguments("schedule", parser)
    return run("schedule", parser.parse_args(argv))


if __name__ == "__main__":
    sys.exit(main())
