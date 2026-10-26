#!/usr/bin/env python3
"""Pinpoint's job core, pure: Job, Change, Attempt, JobState and step().

A port of catapult Pinpoint's job model (p12-perf-process.md 3.6) with no I/O. The executor
(pinpoint_exec.py, task 016) owns builds, hosts and the store; it loops:

    state = JobState(job)
    while True:
        actions = step(state)
        if any Done: stop
        for Build(change): build it, then state.record_build(change, ok)
        for Run(change, start, count): run attempts start..start+count-1 of the story on the
            job's host class, then state.record_attempt(Attempt(...)) for each

step() never repeats an action it already returned, so the executor may run actions in parallel and
call step() again after each result. An empty list means "waiting on results".

Rules, from catapult at commit 0e8f52413a40b5c868739293e784428041275f81:
  https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/job_state.py
  https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/exploration.py
- Adjacent Changes are compared with perf_stats.compare on the pooled values of their attempts and
  catapult's sample count (job_state.py _Compare). A bisect takes the floored verdict (DIFFERENT
  p <= 0.05); try and verify jobs take the strict original one (DIFFERENT p <= 0.01) (R5).
- A DIFFERENT whose mean moved in the improvement direction is SAME (job_state.py _Compare).
- UNKNOWN doubles both Changes' attempts, MIN_ATTEMPTS 10 up to MAX_ATTEMPTS 160.
- DIFFERENT inserts the midpoint (exploration.Speculate, _DEFAULT_SPECULATION_LEVELS = 1). Two
  levels (midpoint and both quartiles) only when every commit between the pair has a stored build.
- At most MAX_BUILDS (60) builds per job; a stored build is free.
Changes for cmux:
- Batch granularity first: the midpoint is a batch tip while one lies inside the range (those
  builds exist), and a commit inside the batch only after that.
- A commit that does not build is skipped: the next candidate inside the range is tried instead.
- A Change that is not measurable (the story needs a capability the commit lacks) is skipped the
  same way. At an end of the range, both narrow the range to the nearest commit inward.
- A DIFFERENT pair with only skipped commits between it is a range culprit (all commits in (a, b]).

Stdlib only; loaded by file path, with perf_stats.py next to it.
"""
from __future__ import annotations

import importlib.util
import json
import os
import sys
from collections.abc import Callable
from dataclasses import asdict, dataclass, field


def _load_perf_stats():
    name = "perf_lab_perf_stats"
    if name in sys.modules:
        return sys.modules[name]
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "perf_stats.py")
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


perf_stats = _load_perf_stats()

BISECT, TRY, VERIFY = "bisect", "try", "verify"
PERFORMANCE, FUNCTIONAL = "performance", "functional"
MIN_ATTEMPTS = 10
MAX_ATTEMPTS = 160
MAX_BUILDS = 60
SPECULATION_LEVELS = 1
STORED_BUILD_SPECULATION_LEVELS = 2
FUNCTIONAL_MAGNITUDE = 0.5  # job_state.py: the failure rate looked for when the job sets none

UNBUILDABLE = "unbuildable"
NOT_MEASURABLE = "not_measurable"

# Job outcomes.
CULPRITS = "culprits"  # at least one culprit
NO_CULPRIT = "no_culprit"  # every pair is SAME
UNRESOLVED = "unresolved"  # no culprit, and a pair stayed UNKNOWN at MAX_ATTEMPTS
UNMEASURABLE = "unmeasurable"  # skipped commits left fewer than two Changes

_STORED, _NEEDED, _REQUESTED, _BUILT = "stored", "needed", "requested", "built"


class PinpointError(ValueError):
    """A job whose definition is inconsistent, or a result for a Change the job never asked for."""


@dataclass(frozen=True)
class Change:
    """One build to measure: a cmux commit and the dependency pins on top of it (repo, sha)."""

    sha: str
    deps: tuple[tuple[str, str], ...] = ()

    def label(self) -> str:
        pins = "".join(f" {repo}@{sha[:12]}" for repo, sha in self.deps)
        return f"{self.sha[:12]}{pins}"


@dataclass(frozen=True)
class Commit:
    """One commit of a bisect range, oldest first. batch_tip: a batch tip; stored_build: a build exists."""

    sha: str
    batch_tip: bool = False
    stored_build: bool = False
    deps: tuple[tuple[str, str], ...] = ()

    @property
    def change(self) -> Change:
        return Change(self.sha, self.deps)


@dataclass(frozen=True)
class Job:
    """What to compare.

    kind: bisect (good..bad over `commits`), try (base `good` vs head `bad`) or verify (C^ vs C).
    mode: performance (the metric's values) or functional (the pass/fail rate).
    magnitude: performance, the alert's delta in the metric's unit (None: 1 IQR, catapult's default);
      functional, the failure rate to look for (None: 0.5).
    better: "lower" or "higher", the metric's improvement direction (functional: fewer failures).
    commits: a bisect's range, good first and bad last; empty means just (good, bad).
    """

    kind: str
    mode: str
    story: str
    metric: str
    host_class: str
    good: Change
    bad: Change
    magnitude: float | None = None
    better: str = "lower"
    commits: tuple[Commit, ...] = ()

    def __post_init__(self) -> None:
        if self.kind not in (BISECT, TRY, VERIFY):
            raise PinpointError(f"kind is {self.kind!r}, not bisect, try or verify")
        if self.mode not in (PERFORMANCE, FUNCTIONAL):
            raise PinpointError(f"mode is {self.mode!r}, not performance or functional")
        if self.better not in ("lower", "higher"):
            raise PinpointError(f"better is {self.better!r}, not 'lower' or 'higher'")
        if self.good == self.bad:
            raise PinpointError(f"{self.good.label()}: good and bad are the same Change")
        if self.commits:
            if self.kind != BISECT:
                raise PinpointError(f"a {self.kind} job compares two Changes; only a bisect takes commits")
            if self.commits[0].change != self.good or self.commits[-1].change != self.bad:
                raise PinpointError("commits must start at good and end at bad")
            if len({c.change for c in self.commits}) != len(self.commits):
                raise PinpointError("commits repeat a Change")

    def range(self) -> tuple[Commit, ...]:
        return self.commits or (Commit(self.good.sha, deps=self.good.deps), Commit(self.bad.sha, deps=self.bad.deps))


@dataclass(frozen=True)
class Attempt:
    """One run of the story on one Change. failed: it ran and measured nothing (functional: a failure).
    measurable False: the Change lacks a capability the story needs."""

    change: Change
    index: int
    values: tuple[float, ...] = ()
    failed: bool = False
    measurable: bool = True


@dataclass(frozen=True)
class Build:
    change: Change


@dataclass(frozen=True)
class Run:
    change: Change
    start: int  # the first attempt index to run
    count: int


@dataclass(frozen=True)
class Comparison:
    """One adjacent pair's verdict. verdict: the job's rule, with an improvement counted as SAME."""

    parent: Change
    change: Change
    verdict: str
    raw: str  # the rule's verdict before the improvement-direction check
    p_value: float | None
    ks_p_value: float | None
    mwu_p_value: float | None
    strict: str  # catapult's original verdict
    floored: str  # catapult's floored verdict
    mean_parent: float | None
    mean_change: float | None
    attempts_parent: int
    attempts_change: int


@dataclass(frozen=True)
class Culprit:
    parent: Change  # the last measured Change before the step
    change: Change  # the first measured Change after it
    commits: tuple[str, ...]  # every commit in (parent, change]: one sha, or a range across skipped commits
    comparison: Comparison


@dataclass(frozen=True)
class Result:
    outcome: str
    culprits: tuple[Culprit, ...]
    comparisons: tuple[Comparison, ...]  # every final adjacent pair
    skipped: tuple[tuple[str, str], ...]  # (sha, UNBUILDABLE or NOT_MEASURABLE)
    builds: int  # builds requested; stored ones are free
    build_limit_hit: bool

    def to_json(self) -> str:
        return json.dumps(asdict(self), sort_keys=True)


@dataclass(frozen=True)
class Done:
    result: Result


Comparator = Callable[..., "perf_stats.Comparison"]


@dataclass
class JobState:
    """A job's progress. Only step() and the record_* methods change it."""

    job: Job
    compare: Comparator = perf_stats.compare  # seam for tests; the lab always uses perf_stats.compare
    changes: list[Change] = field(default_factory=list)
    result: Result | None = None
    _commits: tuple[Commit, ...] = ()
    _index: dict[Change, int] = field(default_factory=dict)
    _build: dict[Change, str] = field(default_factory=dict)
    _wanted: dict[Change, int] = field(default_factory=dict)
    _issued: dict[Change, int] = field(default_factory=dict)
    _attempts: dict[Change, dict[int, Attempt]] = field(default_factory=dict)
    _skipped: dict[Change, str] = field(default_factory=dict)
    _builds: int = 0
    _build_limit_hit: bool = False

    def __post_init__(self) -> None:
        self._commits = self.job.range()
        self._index = {commit.change: i for i, commit in enumerate(self._commits)}
        for commit in (self._commits[0], self._commits[-1]):
            self._add(commit.change)

    # ---------- executor results ----------

    def record_build(self, change: Change, ok: bool) -> None:
        if self._build.get(change) != _REQUESTED:
            raise PinpointError(f"{change.label()}: no build of it is outstanding")
        if ok:
            self._build[change] = _BUILT
        else:
            self._skip(change, UNBUILDABLE)

    def record_attempt(self, attempt: Attempt) -> None:
        change = attempt.change
        if change in self._skipped:
            return  # an attempt that was in flight when the Change was skipped
        if change not in self._attempts or not 0 <= attempt.index < self._issued[change]:
            raise PinpointError(f"{change.label()}: attempt {attempt.index} was never issued")
        if not attempt.measurable:
            self._skip(change, NOT_MEASURABLE)
            return
        self._attempts[change][attempt.index] = attempt

    def attempts(self, change: Change) -> tuple[Attempt, ...]:
        return tuple(a for _, a in sorted(self._attempts.get(change, {}).items()))

    # ---------- bookkeeping ----------

    def _add(self, change: Change) -> None:
        stored = self._commits[self._index[change]].stored_build
        if not stored:
            self._builds += 1
        self._build[change] = _STORED if stored else _NEEDED
        self._wanted[change] = MIN_ATTEMPTS
        self._issued[change] = 0
        self._attempts[change] = {}
        self.changes.append(change)
        self.changes.sort(key=self._index.__getitem__)

    def _skip(self, change: Change, reason: str) -> None:
        """Drop a Change; at an end of the range, the nearest commit inward takes its place."""
        position = self.changes.index(change)
        self._skipped[change] = reason
        self.changes.remove(change)
        if position not in (0, len(self.changes)):
            return
        inward = 1 if position == 0 else -1
        i = self._index[change] + inward
        while 0 <= i < len(self._commits):
            candidate = self._commits[i].change
            if candidate in self.changes:
                return  # the range has shrunk to the Changes already in it
            if candidate not in self._skipped:
                if self._can_build(0 if self._commits[i].stored_build else 1):
                    self._add(candidate)
                else:
                    self._build_limit_hit = True
                return
            i += inward

    def _can_build(self, needed: int) -> bool:
        return self._builds + needed <= MAX_BUILDS

    def _complete(self, change: Change) -> bool:
        return self._build[change] in (_STORED, _BUILT) and len(self._attempts[change]) >= self._wanted[change]

    def _schedule(self) -> list:
        actions = []
        for change in self.changes:
            status = self._build[change]
            if status == _NEEDED:
                self._build[change] = _REQUESTED
                actions.append(Build(change))
            elif status in (_STORED, _BUILT) and self._issued[change] < self._wanted[change]:
                actions.append(Run(change, self._issued[change], self._wanted[change] - self._issued[change]))
                self._issued[change] = self._wanted[change]
        return actions

    def _pending(self) -> bool:
        return any(not self._complete(change) for change in self.changes)

    # ---------- comparison ----------

    def _values(self, change: Change) -> list[float]:
        attempts = self.attempts(change)
        if self.job.mode == FUNCTIONAL:
            return [1.0 if a.failed else 0.0 for a in attempts]
        return [v for a in attempts if not a.failed for v in a.values]

    def _compare(self, a: Change, b: Change) -> Comparison:
        values_a, values_b = self._values(a), self._values(b)
        if self.job.mode == FUNCTIONAL:
            magnitude = self.job.magnitude or FUNCTIONAL_MAGNITUDE
            better = "lower"
        else:
            magnitude = perf_stats.magnitude_from(self.job.magnitude, values_a, values_b) if values_a and values_b else 1.0
            better = self.job.better
        # Performance pools values (catapult's sample_count); functional counts attempts, one value each.
        count = (len(values_a) + len(values_b)) // 2
        both = self.compare(values_a, values_b, count, self.job.mode, magnitude)
        rule = both.floored if self.job.kind == BISECT else both.original
        mean_a = sum(values_a) / len(values_a) if values_a else None
        mean_b = sum(values_b) / len(values_b) if values_b else None
        verdict = rule.result
        if verdict == perf_stats.DIFFERENT and mean_a is not None and mean_b is not None:
            improved = mean_b < mean_a if better == "lower" else mean_b > mean_a
            if improved:
                verdict = perf_stats.SAME
        return Comparison(a, b, verdict, rule.result, rule.p_value, both.ks_p_value, both.mwu_p_value,
                          both.original.result, both.floored.result, mean_a, mean_b,
                          len(self._attempts[a]), len(self._attempts[b]))

    # ---------- exploration ----------

    def _candidates(self, lo: int, hi: int) -> list[int]:
        """Commit indexes strictly between lo and hi that may still be tried, batch tips only while any is left."""
        inside = [i for i in range(lo + 1, hi) if self._commits[i].change not in self._skipped]
        tips = [i for i in inside if self._commits[i].batch_tip]
        return tips or inside

    def _midpoint(self, lo: int, hi: int) -> int | None:
        candidates = self._candidates(lo, hi)
        return candidates[(len(candidates) - 1) // 2] if candidates else None

    def _speculate(self, lo: int, hi: int, levels: int, out: list[int]) -> None:
        """exploration.Speculate: the midpoint, then (levels - 1) more levels on each side."""
        if not levels:
            return
        mid = self._midpoint(lo, hi)
        if mid is None:
            return
        self._speculate(lo, mid, levels - 1, out)
        out.append(mid)
        self._speculate(mid, hi, levels - 1, out)

    def _explore(self) -> bool:
        """Refine UNKNOWN pairs and split DIFFERENT ones; True when anything was added."""
        changed = False
        for a, b in list(zip(self.changes, self.changes[1:])):
            if not (self._complete(a) and self._complete(b)):
                continue
            verdict = self._compare(a, b).verdict
            if verdict == perf_stats.UNKNOWN:
                grown = min(MAX_ATTEMPTS, 2 * max(self._wanted[a], self._wanted[b]))
                for change in (a, b):
                    if grown > self._wanted[change]:
                        self._wanted[change] = grown
                        changed = True
            elif verdict == perf_stats.DIFFERENT and self.job.kind == BISECT:
                points = self._split(self._index[a], self._index[b])
                for i in points:
                    self._add(self._commits[i].change)
                changed = changed or bool(points)
        return changed

    def _split(self, lo: int, hi: int) -> list[int]:
        """The commits to add for a DIFFERENT pair, within MAX_BUILDS: the full speculation, else the midpoint."""
        inside = range(lo + 1, hi)
        stored = bool(inside) and all(self._commits[i].stored_build for i in inside)
        points: list[int] = []
        self._speculate(lo, hi, STORED_BUILD_SPECULATION_LEVELS if stored else SPECULATION_LEVELS, points)
        if not points:
            return []
        if self._can_build(sum(not self._commits[i].stored_build for i in points)):
            return points
        mid = self._midpoint(lo, hi)
        if self._can_build(0 if self._commits[mid].stored_build else 1):
            return [mid]
        self._build_limit_hit = True
        return []

    def _finish(self) -> Result:
        comparisons = tuple(self._compare(a, b) for a, b in zip(self.changes, self.changes[1:]))
        culprits = tuple(
            Culprit(c.parent, c.change,
                    tuple(self._commits[i].sha for i in range(self._index[c.parent] + 1, self._index[c.change] + 1)), c)
            for c in comparisons if c.verdict == perf_stats.DIFFERENT)
        if len(self.changes) < 2:
            outcome = UNMEASURABLE
        elif culprits:
            outcome = CULPRITS
        elif any(c.verdict == perf_stats.UNKNOWN for c in comparisons):
            outcome = UNRESOLVED
        else:
            outcome = NO_CULPRIT
        skipped = tuple((change.sha, reason) for change, reason in
                        sorted(self._skipped.items(), key=lambda item: self._index[item[0]]))
        return Result(outcome, culprits, comparisons, skipped, self._builds, self._build_limit_hit)


def step(state: JobState) -> list:
    """The next actions: Build and Run for new work, [] while results are outstanding, or [Done(result)]."""
    if state.result is not None:
        return [Done(state.result)]
    actions = state._schedule()
    if actions:
        return actions
    if state._explore():
        actions = state._schedule()
        if actions:
            return actions
    if state._pending():
        return []
    state.result = state._finish()
    return [Done(state.result)]


def run_to_end(state: JobState, build: Callable[[Change], bool], attempt: Callable[[Change, int], Attempt],
               max_rounds: int = 100_000) -> Result:
    """Drive a job to its result with synchronous callbacks (tests and dry runs)."""
    for _ in range(max_rounds):
        actions = step(state)
        for action in actions:
            if isinstance(action, Done):
                return action.result
            if isinstance(action, Build):
                state.record_build(action.change, build(action.change))
            elif isinstance(action, Run):
                for index in range(action.start, action.start + action.count):
                    state.record_attempt(attempt(action.change, index))
        if not actions:
            raise PinpointError("step() is waiting, but every action has been answered")
    raise PinpointError(f"no result after {max_rounds} rounds")

