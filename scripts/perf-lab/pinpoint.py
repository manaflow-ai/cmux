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
call step() again after each result. An empty list means "waiting on results". The executor saves
state.to_dict() after every step and result; after a restart, JobState.from_dict() restores it and
state.outstanding() lists the work whose results are still due, to match against the controller.

Rules, from catapult at commit 0e8f52413a40b5c868739293e784428041275f81:
  https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/job_state.py
  https://github.com/catapult-project/catapult/blob/0e8f52413a40b5c868739293e784428041275f81/dashboard/dashboard/pinpoint/models/exploration.py
- Adjacent Changes are compared in two parts, as job_state.py _Compare: first the attempts' failure
  flags (a functional comparison; magnitude job.magnitude or 0.5 in functional mode, 1.0 in
  performance mode), then in performance mode the pooled values of the attempts that did not fail,
  when both sides have some. A DIFFERENT part decides; else an UNKNOWN part; else SAME. Each part
  gets catapult's sample count. A bisect takes the floored verdict (DIFFERENT p <= 0.05); try and
  verify jobs take the strict original one (DIFFERENT p <= 0.01) (R5).
- A DIFFERENT in the improvement direction (a lower or higher mean; fewer failures) is SAME.
- UNKNOWN doubles both Changes' attempts, MIN_ATTEMPTS 10 up to MAX_ATTEMPTS 160.
- DIFFERENT inserts the midpoint (exploration.Speculate, _DEFAULT_SPECULATION_LEVELS = 1). Two
  levels (midpoint and both quartiles) only when every commit between the pair has a stored build.
- At most MAX_BUILDS (60) builds per job; a stored build is free.
Changes for cmux:
- A verify job (C^ vs C) uses verify.py's rule: VERIFY_ATTEMPTS (20) attempts each, fixed (an
  UNKNOWN stays UNKNOWN), the values alone, and DIFFERENT only when the median moved in the
  regression direction. verify.judge gives the same verdict on the same samples.
- Batch granularity first: the midpoint is a batch tip while one lies inside the range (those
  builds exist), and a commit inside the batch only after that.
- A commit that does not build is skipped: the next candidate inside the range is tried instead.
- A Change that is not measurable (the story needs a capability the commit lacks) is skipped the
  same way. A skipped end moves the range's bound past it, and the first usable commit inside the
  bound is found by bisection (batch tips first, stored builds preferred), each probe one build.
- A pair whose failure rate is DIFFERENT while one side measured no values is split too, so the
  values are compared on each side of the failing commits.
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
VERIFY_ATTEMPTS = 20  # verify.py DEFAULT_ATTEMPTS, p12-perf-process.md 3.6
STATE_VERSION = 1
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

# Comparison.basis: the part that decided a pair.
FAILURES = "failures"
VALUES = "values"

_STORED, _NEEDED, _REQUESTED, _BUILT, _FAILED = "stored", "needed", "requested", "built", "failed"
_BUILD_STATES = (_STORED, _NEEDED, _REQUESTED, _BUILT, _FAILED)


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
    attempts: the attempts each Change starts with (None: MIN_ATTEMPTS, or VERIFY_ATTEMPTS for a
      verify job, whose count stays fixed).
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
    attempts: int | None = None

    def initial_attempts(self) -> int:
        if self.attempts is not None:
            return self.attempts
        return VERIFY_ATTEMPTS if self.kind == VERIFY else MIN_ATTEMPTS

    def fixed_attempts(self) -> bool:
        """A verify job runs its attempts once; UNKNOWN does not double them."""
        return self.kind == VERIFY

    def __post_init__(self) -> None:
        if self.attempts is not None and (
                isinstance(self.attempts, bool) or not isinstance(self.attempts, int)
                or not 1 <= self.attempts <= MAX_ATTEMPTS):
            raise PinpointError(f"attempts is {self.attempts!r}, not an int in 1..{MAX_ATTEMPTS}")
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
    """One adjacent pair's verdict, from catapult job_state._Compare's two parts: the failure rate (a
    functional comparison), then, in performance mode, the pooled values. basis names the deciding part.

    verdict: the job's rule, with an improvement counted as SAME (a verify job: DIFFERENT only for a
      regression, as verify.judge). raw, p_value, strict and floored are the deciding part's.
    failure_raw: the failure-rate part's verdict before the direction check; None when it is not compared.
    values_hidden: the failure rate is DIFFERENT and one side measured no values, so the values could
      not be compared across the pair (a bisect splits it to compare them on each side).
    """

    parent: Change
    change: Change
    verdict: str
    basis: str  # FAILURES or VALUES
    raw: str
    p_value: float | None
    ks_p_value: float | None
    mwu_p_value: float | None
    strict: str  # catapult's original verdict
    floored: str  # catapult's floored verdict
    failure_raw: str | None
    values_hidden: bool
    mean_parent: float | None
    mean_change: float | None
    median_parent: float | None
    median_change: float | None
    failures_parent: int
    failures_change: int
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


@dataclass(frozen=True)
class _Part:
    """One part of a pair's comparison: perf_stats.compare's result and the verdict after the direction check."""

    basis: str
    both: "perf_stats.Comparison"
    rule: "perf_stats.ComparisonResults"
    verdict: str


@dataclass
class JobState:
    """A job's progress. Only step() and the record_* methods change it; to_dict()/from_dict() persist it."""

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
    # Commit indexes <= _lo or >= _hi are out of the range: skipped ends narrowed it past them.
    _lo: int = -1
    _hi: int = 0

    def __post_init__(self) -> None:
        self._commits = self.job.range()
        self._index = {commit.change: i for i, commit in enumerate(self._commits)}
        self._hi = len(self._commits)
        for commit in (self._commits[0], self._commits[-1]):
            self._add(commit.change)

    # ---------- executor results ----------

    def record_build(self, change: Change, ok: bool) -> None:
        if self._build.get(change) != _REQUESTED:
            raise PinpointError(f"{change.label()}: no build of it is outstanding")
        if ok:
            self._build[change] = _BUILT
        else:
            self._build[change] = _FAILED
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

    def outstanding(self) -> list:
        """Work step() returned whose result has not come back: a Build per requested build and a Run per
        stretch of issued attempts with no result. A resumed executor matches these against the controller
        and resubmits only what the controller lost."""
        actions: list = []
        for change in self.changes:
            if self._build[change] == _REQUESTED:
                actions.append(Build(change))
                continue
            for k in range(self._issued[change]):
                if k in self._attempts[change]:
                    continue
                last = actions[-1] if actions else None
                if isinstance(last, Run) and last.change == change and last.start + last.count == k:
                    actions[-1] = Run(change, last.start, last.count + 1)
                else:
                    actions.append(Run(change, k, 1))
        return actions

    # ---------- persistence ----------

    def to_dict(self) -> dict:
        """The whole state as JSON-ready data; from_dict() restores it. Changes are keyed by commit index."""
        tracked = sorted(self._build, key=self._index.__getitem__)
        return {
            "version": STATE_VERSION,
            "job": asdict(self.job),
            "changes": [self._index[c] for c in self.changes],
            "tracked": {
                str(self._index[c]): {
                    "build": self._build[c],
                    "wanted": self._wanted[c],
                    "issued": self._issued[c],
                    "attempts": [[a.index, list(a.values), a.failed] for a in self.attempts(c)],
                } for c in tracked},
            "skipped": {str(self._index[c]): reason for c, reason in self._skipped.items()},
            "builds": self._builds,
            "build_limit_hit": self._build_limit_hit,
            "lo": self._lo,
            "hi": self._hi,
            "finished": self.result is not None,
        }

    @classmethod
    def from_dict(cls, data: dict, compare: Comparator = perf_stats.compare) -> "JobState":
        """The state to_dict() saved; a saved state that does not fit its own job raises PinpointError."""
        try:
            if data["version"] != STATE_VERSION:
                raise PinpointError(f"state version {data['version']}, not {STATE_VERSION}")
            state = cls(_job_from_dict(data["job"]), compare)
            change_at = [commit.change for commit in state._commits]
            state.changes = [change_at[i] for i in data["changes"]]
            state._build, state._wanted, state._issued, state._attempts = {}, {}, {}, {}
            for key, entry in data["tracked"].items():
                change = change_at[int(key)]
                if entry["build"] not in _BUILD_STATES:
                    raise PinpointError(f"{change.label()}: build state {entry['build']!r}")
                state._build[change] = entry["build"]
                state._wanted[change] = int(entry["wanted"])
                state._issued[change] = int(entry["issued"])
                state._attempts[change] = {
                    int(index): Attempt(change, int(index), tuple(values), bool(failed))
                    for index, values, failed in entry["attempts"]}
            state._skipped = {change_at[int(key)]: reason for key, reason in data["skipped"].items()}
            state._builds = int(data["builds"])
            state._build_limit_hit = bool(data["build_limit_hit"])
            state._lo, state._hi = int(data["lo"]), int(data["hi"])
            finished = bool(data["finished"])
        except PinpointError:
            raise
        except (KeyError, IndexError, TypeError, ValueError) as error:
            raise PinpointError(f"not a saved job state: {error!r}") from error
        if any(c not in state._build for c in state.changes):
            raise PinpointError("not a saved job state: a Change in the range has no build entry")
        if finished:
            state.result = state._finish()
        return state

    # ---------- bookkeeping ----------

    def _add(self, change: Change) -> None:
        stored = self._commits[self._index[change]].stored_build
        if not stored:
            self._builds += 1
        self._build[change] = _STORED if stored else _NEEDED
        self._wanted[change] = self.job.initial_attempts()
        self._issued[change] = 0
        self._attempts[change] = {}
        self.changes.append(change)
        self.changes.sort(key=self._index.__getitem__)

    def _skip(self, change: Change, reason: str) -> None:
        """Drop a Change. A skipped end moves the range's bound past it; _probe_edges then bisects for the
        first usable commit between that bound and the remaining end."""
        index = self._index[change]
        position = self.changes.index(change)
        self._skipped[change] = reason
        self.changes.remove(change)
        if not self.changes:
            # The last Change: a missing capability rules out every older commit too, a broken build only itself.
            if reason == NOT_MEASURABLE or index == self._lo + 1:
                self._lo = index
            elif index == self._hi - 1:
                self._hi = index
        elif position == 0:
            self._lo = index
        elif position == len(self.changes):
            self._hi = index

    def _can_build(self, needed: int) -> bool:
        return self._builds + needed <= MAX_BUILDS

    def _cost(self, i: int) -> int:
        return 0 if self._commits[i].stored_build else 1

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

    def _direction_ok(self, before: float | None, after: float | None, better: str) -> bool:
        """Whether a DIFFERENT stays DIFFERENT: any shift but an improvement; for a verify job, only a regression."""
        if before is None or after is None:
            return True
        if self.job.kind == VERIFY:
            return after > before if better == "lower" else after < before
        return not (after < before if better == "lower" else after > before)

    def _part(self, basis: str, values_a: list[float], values_b: list[float], mode: str, magnitude: float,
              centers: tuple[float | None, float | None], better: str) -> _Part:
        # job_state._Compare passes the mean sample count: attempts for failures, pooled values for values.
        both = self.compare(values_a, values_b, (len(values_a) + len(values_b)) // 2, mode, magnitude)
        rule = both.floored if self.job.kind == BISECT else both.original
        verdict = rule.result
        if verdict == perf_stats.DIFFERENT and not self._direction_ok(*centers, better):
            verdict = perf_stats.SAME
        return _Part(basis, both, rule, verdict)

    def _compare(self, a: Change, b: Change) -> Comparison:
        attempts_a, attempts_b = self.attempts(a), self.attempts(b)
        failed_a = [1.0 if x.failed else 0.0 for x in attempts_a]
        failed_b = [1.0 if x.failed else 0.0 for x in attempts_b]
        values_a = [v for x in attempts_a if not x.failed for v in x.values]
        values_b = [v for x in attempts_b if not x.failed for v in x.values]
        means = _mean(values_a), _mean(values_b)
        medians = perf_stats.pct(values_a, 0.5), perf_stats.pct(values_b, 0.5)

        parts: list[_Part] = []
        failure_raw = None
        if self.job.mode == FUNCTIONAL or self.job.kind != VERIFY:  # a verify job judges values alone (verify.judge)
            magnitude = (self.job.magnitude or FUNCTIONAL_MAGNITUDE) if self.job.mode == FUNCTIONAL else 1.0
            failures = self._part(FAILURES, failed_a, failed_b, FUNCTIONAL, magnitude,
                                  (_mean(failed_a), _mean(failed_b)), "lower")
            failure_raw = failures.rule.result
            parts.append(failures)
        if self.job.mode == PERFORMANCE and ((values_a and values_b) or self.job.kind == VERIFY):
            magnitude = perf_stats.magnitude_from(self.job.magnitude, values_a, values_b)
            centers = medians if self.job.kind == VERIFY else means
            parts.append(self._part(VALUES, values_a, values_b, PERFORMANCE, magnitude, centers, self.job.better))

        decided = (next((p for p in parts if p.verdict == perf_stats.DIFFERENT), None)
                   or next((p for p in parts if p.verdict == perf_stats.UNKNOWN), None)
                   or parts[-1])
        values_hidden = (self.job.mode == PERFORMANCE and failure_raw == perf_stats.DIFFERENT
                         and not (values_a and values_b))
        return Comparison(a, b, decided.verdict, decided.basis, decided.rule.result, decided.rule.p_value,
                          decided.both.ks_p_value, decided.both.mwu_p_value, decided.both.original.result,
                          decided.both.floored.result, failure_raw, values_hidden, *means, *medians,
                          int(sum(failed_a)), int(sum(failed_b)), len(attempts_a), len(attempts_b))

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

    def _probe_point(self, lo: int, hi: int) -> int | None:
        """The candidates' midpoint, or the stored build nearest it in their middle half: free, and each
        probe still drops at least a quarter of the candidates."""
        candidates = self._candidates(lo, hi)
        if not candidates:
            return None
        mid = candidates[(len(candidates) - 1) // 2]
        quarter = len(candidates) // 4
        stored = [i for i in candidates[quarter:len(candidates) - quarter] if self._commits[i].stored_build]
        return min(stored, key=lambda i: (abs(i - mid), i)) if stored else mid

    def _probe(self, lo: int, hi: int) -> bool:
        point = self._probe_point(lo, hi)
        if point is None:
            return False
        if not self._can_build(self._cost(point)):
            self._build_limit_hit = True
            return False
        self._add(self._commits[point].change)
        return True

    def _probe_edges(self) -> bool:
        """Bisect for the first usable commit inside each bound a skipped end moved: one probe per side at a
        time, between the bound and the side's end once that end has measured an attempt."""
        if not self.changes:
            return self._probe(self._lo, self._hi)
        first, last = self.changes[0], self.changes[-1]
        changed = False
        if self._attempts[first]:
            changed = self._probe(self._lo, self._index[first])
        if self._attempts[last]:
            changed = self._probe(self._index[last], self._hi) or changed
        return changed

    def _explore(self) -> bool:
        """Narrow skipped ends, refine UNKNOWN pairs and split DIFFERENT ones; True when anything was added."""
        changed = self._probe_edges()
        for a, b in list(zip(self.changes, self.changes[1:])):
            if not (self._complete(a) and self._complete(b)):
                continue
            comparison = self._compare(a, b)
            if comparison.verdict == perf_stats.UNKNOWN and not self.job.fixed_attempts():
                grown = min(MAX_ATTEMPTS, 2 * max(self._wanted[a], self._wanted[b]))
                for change in (a, b):
                    if grown > self._wanted[change]:
                        self._wanted[change] = grown
                        changed = True
            elif self.job.kind == BISECT and (comparison.verdict == perf_stats.DIFFERENT or comparison.values_hidden):
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
        if self._can_build(sum(self._cost(i) for i in points)):
            return points
        mid = self._midpoint(lo, hi)
        if self._can_build(self._cost(mid)):
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


def _mean(values: list[float]) -> float | None:
    return sum(values) / len(values) if values else None


def _deps(raw) -> tuple[tuple[str, str], ...]:
    return tuple((repo, sha) for repo, sha in raw)


def _job_to_dict(job: Job) -> dict:
    return asdict(job)


def _job_from_dict(data: dict) -> Job:
    def change(raw: dict) -> Change:
        return Change(raw["sha"], _deps(raw["deps"]))

    commits = tuple(Commit(c["sha"], c["batch_tip"], c["stored_build"], _deps(c["deps"])) for c in data["commits"])
    return Job(data["kind"], data["mode"], data["story"], data["metric"], data["host_class"], change(data["good"]),
               change(data["bad"]), data["magnitude"], data["better"], commits, data["attempts"])


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
