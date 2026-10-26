#!/usr/bin/env python3
"""Harness-broken alerts, story coverage, and Pinpoint's functional mode (p12-perf-process.md 3.6, task 214).

A story that errors is not slow, it measures nothing, so the change-point detector (alerts.py) never
sees it. This module turns the story runner's outcomes into the alerts a broken harness needs:

- A story that errors on an env-valid host on 2 consecutive batches is harness-broken. It gets an
  alert (rule `harness_broken`) on each of its series on that host class, and those alerts form one
  harness-broken group, never a regression group. Outcomes of an env-invalid host are no evidence
  either way (host_env refused the job and nothing ran), so they neither count nor break the streak.
  A pass ends the streak; when the story passes again after its group opened, the group moves to
  `fixed`.
- story_coverage() counts a planned story as measured only for an env-valid pass. An error, a
  harness-broken story and an env-invalid gap all count missing; a broken story is never dropped from
  the planned count, so a broken harness cannot raise coverage.
- When the breakage has a passing batch before it, the group gets a queued functional bisect job
  (jobs row, kind `bisect`, params mode `functional`) from the last passing batch tip to the first
  failing one, for the Pinpoint executor (task 016) to run with pinpoint.py's Job (task 015).
- functional_comparison() is how functional mode compares two Changes: the pass/fail of each attempt,
  as catapult `dashboard/dashboard/pinpoint/models/job_state.py` _Compare compares
  `bool(execution.exception)` tuples with `compare.Compare(..., FUNCTIONAL, comparison_magnitude)`,
  magnitude 0.5 when the job sets none. The thresholds are perf_stats.compare's functional
  HighThreshold row; the bisect takes the floored verdict (R5). Fewer failures on the later Change is
  SAME, as a shift in the improvement direction is for performance (015), so a bisect follows the
  breaking step and not a later fix.
- functional_bisect() runs that comparison over a commit range with Pinpoint's attempt doubling
  (10 up to 160) and midpoint split, skipping commits that do not build, down to the breaking commit.

The outcomes come from the story runner (task 008: run_story.py exits 3 on env-invalid) through the
executor; on the command line they are ndjson, one StoryOutcome per line:

  {"story": "...", "host_class": "apple-m6/24gb/120hz", "host": "cmux15", "batch_pos": 1234,
   "sha": "<batch tip>", "status": "pass" | "error" | "env-invalid", "reason": "..."}

  python3 scripts/perf-lab/harness_alerts.py detect --db lab.sqlite --outcomes outcomes.ndjson [--dry-run]
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import sqlite3
import sys
import tempfile
from collections import defaultdict
from collections.abc import Callable, Iterable, Sequence
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent

PASS, ERROR, ENV_INVALID = "pass", "error", "env-invalid"
STATUSES = (PASS, ERROR, ENV_INVALID)
BROKEN_AFTER = 2  # consecutive env-valid errored batches
RULE = "harness_broken"
ACTOR = "perf-lab-harness-alerts"
FUNCTIONAL = "functional"
FUNCTIONAL_METRIC = "harness.failed"  # 1 per failed attempt, 0 per passed one; lower is better
FUNCTIONAL_MAGNITUDE = 0.5  # job_state.py _Compare: the functional magnitude when the job sets none
BISECT_JOB_STATE = "queued"


class HarnessAlertsError(RuntimeError):
    pass


def _load_sibling(module_name: str, filename: str):
    """Loads a perf-lab module by path once, under the name alerts.py and the tests use."""
    if module_name in sys.modules:
        return sys.modules[module_name]
    path = HERE / filename
    if not path.exists():
        raise HarnessAlertsError(f"{path} is missing")
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(module_name, None)
        raise
    return module


alerts = _load_sibling("perf_lab_alerts", "alerts.py")
store_mod = alerts.store_mod
perf_stats = alerts.perf_stats


# ---------- outcomes ----------


@dataclass(frozen=True)
class StoryOutcome:
    """One run of one story on one waterfall host for one batch."""

    story: str
    host_class: str
    host: str
    batch_pos: int  # commit position of the batch tip
    sha: str  # the batch tip
    status: str  # PASS, ERROR or ENV_INVALID
    reason: str = ""

    def __post_init__(self) -> None:
        if self.status not in STATUSES:
            raise HarnessAlertsError(f"{self.story}@{self.batch_pos}: status {self.status!r} is not one of {STATUSES}")

    @classmethod
    def from_dict(cls, raw: object, where: str) -> "StoryOutcome":
        fields = {"story": str, "host_class": str, "host": str, "batch_pos": int, "sha": str, "status": str}
        if not isinstance(raw, dict) or set(raw) - set(fields) - {"reason"}:
            raise HarnessAlertsError(f"{where}: expected an object with {sorted(fields)} and an optional reason")
        for name, kind in fields.items():
            value = raw.get(name)
            if not isinstance(value, kind) or isinstance(value, bool) or (kind is str and not value):
                raise HarnessAlertsError(f"{where}: {name} must be a non-empty {kind.__name__}")
        if raw["status"] not in STATUSES:
            raise HarnessAlertsError(f"{where}: status {raw['status']!r} is not one of {STATUSES}")
        reason = raw.get("reason", "")
        if not isinstance(reason, str):
            raise HarnessAlertsError(f"{where}: reason must be a string")
        return cls(raw["story"], raw["host_class"], raw["host"], raw["batch_pos"], raw["sha"], raw["status"], reason)


def read_outcomes(path: Path) -> list[StoryOutcome]:
    try:
        lines = path.read_text().splitlines()
    except OSError as error:
        raise HarnessAlertsError(f"{path}: {error.strerror or error}") from None
    outcomes = []
    for number, line in enumerate(lines, 1):
        if not line.strip():
            continue
        try:
            raw = json.loads(line)
        except json.JSONDecodeError as error:
            raise HarnessAlertsError(f"{path}:{number}: {error.msg}") from None
        outcomes.append(StoryOutcome.from_dict(raw, f"{path}:{number}"))
    return outcomes


@dataclass(frozen=True)
class BatchStatus:
    """What one batch says about one story: a pass if any env-valid run passed, an error if every
    env-valid run errored, env-invalid when no run was env-valid."""

    batch_pos: int
    sha: str
    status: str
    reason: str


def batch_statuses(outcomes: Iterable[StoryOutcome]) -> dict[tuple[str, str], list[BatchStatus]]:
    """(story, host_class) -> its batches in commit order."""
    runs: dict[tuple[str, str], dict[int, list[StoryOutcome]]] = defaultdict(lambda: defaultdict(list))
    for outcome in outcomes:
        runs[(outcome.story, outcome.host_class)][outcome.batch_pos].append(outcome)
    result = {}
    for key, by_batch in runs.items():
        batches = []
        for pos in sorted(by_batch):
            batch = by_batch[pos]
            shas = {outcome.sha for outcome in batch}
            if len(shas) != 1:
                raise HarnessAlertsError(f"{key[0]} ({key[1]}): batch {pos} has tips {sorted(shas)}")
            valid = [outcome for outcome in batch if outcome.status != ENV_INVALID]
            if any(outcome.status == PASS for outcome in valid):
                status, reason = PASS, ""
            elif valid:
                status, reason = ERROR, valid[-1].reason
            else:
                status, reason = ENV_INVALID, batch[-1].reason
            batches.append(BatchStatus(pos, shas.pop(), status, reason))
        result[key] = batches
    return result


@dataclass(frozen=True)
class Breakage:
    story: str
    host_class: str
    first_error: BatchStatus
    last_error: BatchStatus
    errored_batches: int
    last_pass: BatchStatus | None  # the newest env-valid pass before the streak; None if none is known

    @property
    def start_pos(self) -> int:
        """The first commit that may have broken the story: the one after the last passing batch tip."""
        return self.last_pass.batch_pos + 1 if self.last_pass else self.first_error.batch_pos

    @property
    def end_pos(self) -> int:
        return self.first_error.batch_pos


def breakage(story: str, host_class: str, batches: Sequence[BatchStatus]) -> Breakage | None:
    """The trailing streak of env-valid errored batches, when it is at least BROKEN_AFTER long."""
    valid = [batch for batch in batches if batch.status != ENV_INVALID]
    streak = 0
    while streak < len(valid) and valid[-1 - streak].status == ERROR:
        streak += 1
    if streak < BROKEN_AFTER:
        return None
    errors = valid[len(valid) - streak:]
    last_pass = valid[-1 - streak] if streak < len(valid) else None
    return Breakage(story, host_class, errors[0], errors[-1], streak, last_pass)


# ---------- coverage ----------


@dataclass(frozen=True)
class PlannedStory:
    story: str
    host_class: str
    batch_pos: int


@dataclass(frozen=True)
class MissingStory:
    story: str
    host_class: str
    batch_pos: int
    reason: str  # "harness-broken", "error", "env-invalid" or "not-run"


@dataclass
class Coverage:
    planned: int = 0
    measured: int = 0
    missing: list[MissingStory] = field(default_factory=list)

    @property
    def fraction(self) -> float:
        return self.measured / self.planned if self.planned else 1.0


def story_coverage(planned: Iterable[PlannedStory], outcomes: Iterable[StoryOutcome]) -> Coverage:
    """Measured = an env-valid pass of the planned story in that batch; everything else is missing.

    An error is `harness-broken` when it is part of a streak of BROKEN_AFTER or more env-valid errors.
    """
    statuses = batch_statuses(outcomes)
    by_batch = {key: {batch.batch_pos: batch for batch in batches} for key, batches in statuses.items()}
    broken = {key: _broken_positions(batches) for key, batches in statuses.items()}
    coverage = Coverage()
    for plan in planned:
        coverage.planned += 1
        key = (plan.story, plan.host_class)
        batch = by_batch.get(key, {}).get(plan.batch_pos)
        if batch is not None and batch.status == PASS:
            coverage.measured += 1
            continue
        if batch is None:
            reason = "not-run"
        elif batch.status == ENV_INVALID:
            reason = "env-invalid"
        else:
            reason = "harness-broken" if plan.batch_pos in broken[key] else "error"
        coverage.missing.append(MissingStory(plan.story, plan.host_class, plan.batch_pos, reason))
    return coverage


def _broken_positions(batches: Sequence[BatchStatus]) -> set[int]:
    """Positions of errored batches inside a run of BROKEN_AFTER or more env-valid errors."""
    broken: set[int] = set()
    streak: list[int] = []
    for batch in [b for b in batches if b.status != ENV_INVALID] + [None]:
        if batch is not None and batch.status == ERROR:
            streak.append(batch.batch_pos)
            continue
        if len(streak) >= BROKEN_AFTER:
            broken.update(streak)
        streak = []
    return broken


# ---------- functional mode ----------


def failure_values(outcomes: Iterable[StoryOutcome]) -> list[int]:
    """A functional Attempt's values: 1 per env-valid error, 0 per pass; env-invalid runs measured nothing."""
    return [int(outcome.status == ERROR) for outcome in outcomes if outcome.status != ENV_INVALID]


@dataclass(frozen=True)
class FunctionalVerdict:
    verdict: str  # perf_stats DIFFERENT, SAME or UNKNOWN: the bisect's (floored) verdict
    comparison: object  # perf_stats.Comparison, both rules and both p-values
    failure_rate_a: float | None
    failure_rate_b: float | None


def functional_comparison(failed_a: Sequence[int], failed_b: Sequence[int], *,
                          magnitude: float = FUNCTIONAL_MAGNITUDE) -> FunctionalVerdict:
    """Compares the pass/fail of two Changes' attempts in Pinpoint's functional mode.

    The verdict is the floored one (DIFFERENT p <= 0.05, SAME p > max(HighThreshold('functional',
    magnitude, n), 0.10)); fewer failures on Change b is SAME.
    """
    a, b = [int(bool(value)) for value in failed_a], [int(bool(value)) for value in failed_b]
    comparison = perf_stats.compare(a, b, mode=FUNCTIONAL, magnitude=magnitude)
    rate_a = sum(a) / len(a) if a else None
    rate_b = sum(b) / len(b) if b else None
    verdict = comparison.floored.result
    if verdict == perf_stats.DIFFERENT and rate_b < rate_a:
        verdict = perf_stats.SAME
    return FunctionalVerdict(verdict, comparison, rate_a, rate_b)


MIN_ATTEMPTS, MAX_ATTEMPTS = 10, 160  # catapult job_state.py
# Runs `attempts` attempts of the story at a commit: 1 per failed attempt, 0 per pass; None when the
# commit does not build (it is skipped, as Pinpoint skips an unbuildable Change).
AttemptRunner = Callable[[str, int], "Sequence[int] | None"]


@dataclass(frozen=True)
class FunctionalBisectResult:
    culprit: str | None  # the first failing commit, when the step is between two adjacent measured commits
    good: str  # the last commit judged passing
    bad: str  # the first commit judged failing
    skipped: tuple[str, ...]  # unbuildable commits inside the range
    comparisons: tuple[tuple[str, str, str], ...]  # (a, b, verdict) in order


def functional_bisect(commits: Sequence[str], run: AttemptRunner, *,
                      magnitude: float = FUNCTIONAL_MAGNITUDE) -> FunctionalBisectResult:
    """Bisects the pass/fail rate between commits[0] (good) and commits[-1] (bad), first parent order.

    Pinpoint's loop for one step: compare a Change with its neighbour; UNKNOWN doubles both Changes'
    attempts from MIN_ATTEMPTS up to MAX_ATTEMPTS (still UNKNOWN there counts SAME); DIFFERENT splits
    the range at its midpoint. The executor (task 016) runs this until pinpoint.py's functional Job
    (task 015) takes it over with the same comparison, functional_comparison().
    """
    if len(commits) < 2:
        raise HarnessAlertsError("a functional bisect needs a good and a bad commit")
    values: dict[str, list[int]] = {}
    unbuildable: set[str] = set()
    log: list[tuple[str, str, str]] = []

    def measure(sha: str, count: int) -> bool:
        have = values.setdefault(sha, [])
        if len(have) < count:
            more = run(sha, count - len(have))
            if more is None:
                unbuildable.add(sha)
                return False
            have.extend(int(bool(value)) for value in more)
        return True

    def verdict(a: str, b: str) -> str:
        count = MIN_ATTEMPTS
        while True:
            if not (measure(a, count) and measure(b, count)):
                raise HarnessAlertsError(f"{a if a in unbuildable else b}: the bisect's end does not build")
            result = functional_comparison(values[a], values[b], magnitude=magnitude).verdict
            if result != perf_stats.UNKNOWN or count >= MAX_ATTEMPTS:
                result = perf_stats.SAME if result == perf_stats.UNKNOWN else result
                log.append((a, b, result))
                return result
            count = min(count * 2, MAX_ATTEMPTS)

    lo, hi = 0, len(commits) - 1

    def result(culprit: str | None) -> FunctionalBisectResult:
        skipped = tuple(sha for sha in commits[lo + 1:hi] if sha in unbuildable)
        return FunctionalBisectResult(culprit, commits[lo], commits[hi], skipped, tuple(log))

    if verdict(commits[lo], commits[hi]) != perf_stats.DIFFERENT:
        return result(None)
    while True:
        inside = [index for index in range(lo + 1, hi) if commits[index] not in unbuildable]
        if not inside:
            # Adjacent measured commits: the later one broke the story, unless unbuildable commits sit between.
            return result(None if lo + 1 < hi else commits[hi])
        mid = inside[len(inside) // 2]
        if not measure(commits[mid], MIN_ATTEMPTS):
            continue
        if verdict(commits[lo], commits[mid]) == perf_stats.DIFFERENT:
            hi = mid
        elif verdict(commits[mid], commits[hi]) == perf_stats.DIFFERENT:
            lo = mid
        else:
            return result(None)  # no single step: the failure rate grew gradually over the range


@dataclass(frozen=True)
class FunctionalBisect:
    """The fields of pinpoint.py's Job (task 015) for a harness-broken group, as its jobs row stores them."""

    group_id: int
    story: str
    host_class: str
    good: str  # the last passing batch tip
    bad: str  # the first failing batch tip
    kind: str = "bisect"
    mode: str = FUNCTIONAL
    metric: str = FUNCTIONAL_METRIC
    magnitude: float = FUNCTIONAL_MAGNITUDE

    def params(self) -> dict[str, object]:
        return {"mode": self.mode, "metric": self.metric, "magnitude": self.magnitude}

    @classmethod
    def from_job_row(cls, row: sqlite3.Row) -> "FunctionalBisect":
        params = json.loads(row["params_json"])
        if params.get("mode") != FUNCTIONAL:
            raise HarnessAlertsError(f"job {row['id']} is not a functional bisect")
        return cls(row["alert_group_id"], row["story"], row["host_class"], row["base_sha"], row["head_sha"],
                   row["kind"], params["mode"], params["metric"], float(params["magnitude"]))


def functional_bisects(store, group_id: int) -> list[FunctionalBisect]:
    rows = store._db.execute("SELECT * FROM jobs WHERE alert_group_id = ? AND kind = 'bisect' ORDER BY id",
                             (group_id,)).fetchall()
    return [FunctionalBisect.from_job_row(row) for row in rows
            if json.loads(row["params_json"]).get("mode") == FUNCTIONAL]


# ---------- detection ----------


@dataclass
class DetectReport:
    stories: int = 0
    broken: int = 0
    alerts: int = 0
    groups_created: list[int] = field(default_factory=list)
    groups_joined: list[int] = field(default_factory=list)
    groups_fixed: list[int] = field(default_factory=list)
    bisects: list[int] = field(default_factory=list)
    no_series: list[str] = field(default_factory=list)  # broken stories with no stored series to alert on
    no_good_batch: list[str] = field(default_factory=list)  # broken stories with no passing batch to bisect from

    def to_dict(self) -> dict[str, object]:
        return dict(self.__dict__)


def detect(store, outcomes: Iterable[StoryOutcome]) -> DetectReport:
    """Opens or joins a harness-broken group per broken (story, host class); fixes groups whose story passes again."""
    report = DetectReport()
    for (story, host_class), batches in sorted(batch_statuses(outcomes).items()):
        report.stories += 1
        newest_pass = next((b for b in reversed(batches) if b.status == PASS), None)
        if newest_pass is not None:
            store._write(lambda: _fix_recovered(store, story, host_class, newest_pass, report))
        broken = breakage(story, host_class, batches)
        if broken is not None:
            report.broken += 1
            store._write(lambda: _record(store, broken, report))
    return report


def _story_series(db: sqlite3.Connection, story: str, host_class: str) -> list[sqlite3.Row]:
    return db.execute("SELECT id FROM series WHERE story = ? AND host_class = ? ORDER BY id",
                      (story, host_class)).fetchall()


def _open_harness_groups(db: sqlite3.Connection, story: str, host_class: str) -> list[sqlite3.Row]:
    marks = ",".join("?" * len(alerts.OPEN_STATES))
    return db.execute(
        f"""SELECT DISTINCT g.* FROM alert_groups g JOIN alerts a ON a.group_id = g.id
            JOIN series s ON s.id = a.series_id
            WHERE a.rule = ? AND s.story = ? AND s.host_class = ? AND g.state IN ({marks}) ORDER BY g.id""",
        (RULE, story, host_class, *alerts.OPEN_STATES)).fetchall()


def _history(db: sqlite3.Connection, group_id: int, from_state: str | None, to_state: str, reason: str, now: str) -> None:
    db.execute("INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) VALUES (?, ?, ?, ?, ?, ?)",
               (group_id, from_state, to_state, ACTOR, reason, now))


def _record(store, broken: Breakage, report: DetectReport) -> None:
    db, now = store._db, store._now()
    label = f"{broken.story} ({broken.host_class})"
    series = _story_series(db, broken.story, broken.host_class)
    if not series:
        report.no_series.append(label)
        return
    start, end = broken.start_pos, broken.end_pos
    group = next((g for g in _open_harness_groups(db, broken.story, broken.host_class)
                  if g["start_pos"] <= end and g["end_pos"] >= start), None)
    if group is None:
        reason = (f"harness broken: {label} errored on {broken.errored_batches} consecutive batches "
                  f"from {broken.first_error.sha[:12]}: {broken.last_error.reason or 'no reason given'}")
        group_id = db.execute(
            "INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at) VALUES ('new', ?, ?, ?, ?)",
            (start, end, now, now)).lastrowid
        _history(db, group_id, None, "new", reason, now)
        report.groups_created.append(group_id)
        if broken.last_pass is None:
            report.no_good_batch.append(label)
        else:
            job = FunctionalBisect(group_id, broken.story, broken.host_class, broken.last_pass.sha, broken.first_error.sha)
            report.bisects.append(db.execute(
                """INSERT INTO jobs (kind, state, story, host_class, base_sha, head_sha, alert_group_id, params_json,
                                     created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (job.kind, BISECT_JOB_STATE, job.story, job.host_class, job.good, job.bad, group_id,
                 json.dumps(job.params(), sort_keys=True), now, now)).lastrowid)
    else:
        group_id = group["id"]
    added = 0
    for row in series:
        already = db.execute(
            "SELECT 1 FROM alerts WHERE series_id = ? AND rule = ? AND start_pos <= ? AND end_pos >= ?",
            (row["id"], RULE, end, start)).fetchone()
        if already:
            continue
        db.execute(
            """INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,
                                   is_improvement, created_at) VALUES (?, ?, ?, ?, ?, NULL, NULL, 0, ?)""",
            (row["id"], group_id, RULE, start, end, now))
        added += 1
    report.alerts += added
    if group is not None and added:
        report.groups_joined.append(group_id)


def _fix_recovered(store, story: str, host_class: str, newest_pass: BatchStatus, report: DetectReport) -> None:
    db, now = store._db, store._now()
    for group in _open_harness_groups(db, story, host_class):
        if group["end_pos"] >= newest_pass.batch_pos:
            continue
        db.execute("UPDATE alert_groups SET state = 'fixed', updated_at = ? WHERE id = ?", (now, group["id"]))
        _history(db, group["id"], group["state"], "fixed",
                 f"{story} ({host_class}) passed again at {newest_pass.sha[:12]}", now)
        report.groups_fixed.append(group["id"])


# ---------- CLI ----------


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="harness_alerts.py", description=__doc__.split("\n\n")[0])
    commands = parser.add_subparsers(dest="command", required=True)
    detect_cmd = commands.add_parser("detect", help="harness-broken groups from story outcomes")
    detect_cmd.add_argument("--db", type=Path, required=True)
    detect_cmd.add_argument("--outcomes", type=Path, required=True, help="ndjson, one StoryOutcome per line")
    detect_cmd.add_argument("--dry-run", action="store_true", help="run on a copy of the store")
    args = parser.parse_args(argv)
    try:
        outcomes = read_outcomes(args.outcomes)
        with tempfile.TemporaryDirectory(prefix="perf-lab-harness-") as scratch:
            store = alerts._open(args.db, Path(scratch) if args.dry_run else None)
            try:
                report = detect(store, outcomes)
            finally:
                store.close()
        print(json.dumps({"dry_run": args.dry_run, **report.to_dict()}, indent=2))
    except (HarnessAlertsError, alerts.AlertsError, store_mod.StoreError, sqlite3.Error) as error:
        print(f"harness_alerts.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
