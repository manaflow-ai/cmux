#!/usr/bin/env python3
"""Harness-broken alerts and story coverage (p12-perf-process.md 3.6, task 214).

A story that errors is not slow, it measures nothing, so the change-point detector (alerts.py) never
sees it. This module turns the story runner's outcomes into the alerts a broken harness needs:

- A story that errors on an env-valid host on 2 consecutive batches is harness-broken. It gets an
  alert (rule `harness_broken`) on each of its series on that host class, and those alerts form one
  harness-broken group, never a regression group. Outcomes of an env-invalid host are no evidence
  either way (host_env refused the job and nothing ran), so they neither count nor break the streak.
  The group's range is (last passing batch tip, first failing batch tip]. It then moves through the
  sheriff's states like any group; sheriff.py closes it once the story ran again after the break.
- story_coverage() counts a planned story as measured only for an env-valid pass. An error, a
  harness-broken story and an env-invalid gap all count missing; a broken story is never dropped from
  the planned count, so a broken harness cannot raise coverage.
- functional_target() is what the Pinpoint executor (pinpoint_exec.py) bisects a harness-broken group
  with: a functional-mode pinpoint.Job, which compares the attempts' pass/fail rates with
  perf_stats.compare in functional mode (the functional HighThreshold row, magnitude 0.5, the floored
  verdict for a bisect), as catapult `dashboard/dashboard/pinpoint/models/job_state.py` _Compare
  compares `bool(execution.exception)` tuples. Fewer failures on the later Change is SAME, so the
  bisect follows the breaking step and not a later fix. The good end is the story's newest stored
  waterfall pass before the range and the series is the one that pass stored: a passing attempt
  stores that metric, a broken one stores nothing.

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
from collections.abc import Iterable, Sequence
from dataclasses import dataclass, field
from pathlib import Path

HERE = Path(__file__).resolve().parent

PASS, ERROR, ENV_INVALID = "pass", "error", "env-invalid"
STATUSES = (PASS, ERROR, ENV_INVALID)
BROKEN_AFTER = 2  # consecutive env-valid errored batches
RULE = "harness_broken"
ACTOR = "perf-lab-harness-alerts"


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


# ---------- detection ----------


@dataclass
class DetectReport:
    stories: int = 0
    broken: int = 0
    alerts: int = 0
    groups_created: list[int] = field(default_factory=list)
    groups_joined: list[int] = field(default_factory=list)
    no_series: list[str] = field(default_factory=list)  # broken stories with no stored series to alert on
    no_good_batch: list[str] = field(default_factory=list)  # broken stories whose outcomes hold no earlier pass

    def to_dict(self) -> dict[str, object]:
        return dict(self.__dict__)


def detect(store, outcomes: Iterable[StoryOutcome]) -> DetectReport:
    """Opens or joins a harness-broken group per broken (story, host class)."""
    report = DetectReport()
    for (story, host_class), batches in sorted(batch_statuses(outcomes).items()):
        report.stories += 1
        broken = breakage(story, host_class, batches)
        if broken is not None:
            report.broken += 1
            store._write(lambda: _record(store, broken, report))
    return report


def _record(store, broken: Breakage, report: DetectReport) -> None:
    db, now = store._db, store._now()
    label = f"{broken.story} ({broken.host_class})"
    series = db.execute("SELECT id FROM series WHERE story = ? AND host_class = ? ORDER BY id",
                        (broken.story, broken.host_class)).fetchall()
    if not series:
        report.no_series.append(label)
        return
    start, end = broken.start_pos, broken.end_pos
    # A series that already has a harness-broken alert on this break (in any group, closed ones too) gets no other.
    new = [row["id"] for row in series if db.execute(
        "SELECT 1 FROM alerts WHERE series_id = ? AND rule = ? AND start_pos <= ? AND end_pos >= ?",
        (row["id"], RULE, end, start)).fetchone() is None]
    if not new:
        return
    marks = ",".join("?" * len(alerts.OPEN_STATES))
    group = db.execute(
        f"""SELECT g.id FROM alert_groups g WHERE g.state IN ({marks}) AND g.start_pos <= ? AND g.end_pos >= ?
            AND EXISTS (SELECT 1 FROM alerts a JOIN series s ON s.id = a.series_id WHERE a.group_id = g.id
                        AND a.rule = ? AND s.story = ? AND s.host_class = ?) ORDER BY g.id LIMIT 1""",
        (*alerts.OPEN_STATES, end, start, RULE, broken.story, broken.host_class)).fetchone()
    if group is None:
        reason = (f"harness broken: {label} errored on {broken.errored_batches} consecutive batches "
                  f"from {broken.first_error.sha[:12]}: {broken.last_error.reason or 'no reason given'}")
        group_id = db.execute(
            "INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at) VALUES ('new', ?, ?, ?, ?)",
            (start, end, now, now)).lastrowid
        db.execute("INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) "
                   "VALUES (?, NULL, 'new', ?, ?, ?)", (group_id, ACTOR, reason, now))
        report.groups_created.append(group_id)
        if broken.last_pass is None:
            report.no_good_batch.append(label)
    else:
        group_id = group["id"]
        report.groups_joined.append(group_id)
    for series_id in new:
        db.execute(
            """INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,
                                   is_improvement, created_at) VALUES (?, ?, ?, ?, ?, NULL, NULL, 0, ?)""",
            (series_id, group_id, RULE, start, end, now))
    report.alerts += len(new)


# ---------- the functional bisect's target ----------


@dataclass(frozen=True)
class FunctionalTarget:
    """What a harness-broken group's functional bisect measures; pinpoint_exec.py builds the Job from it."""

    series: object  # alerts.SeriesInfo: the bisect's story, metric, host class and build config
    good: str | None  # the story's newest stored waterfall pass before the range; None when none is stored


def functional_target(store, group_id: int) -> FunctionalTarget | None:
    """The target of a harness-broken group; None when the group has no harness-broken alert."""
    db = store._db
    group = db.execute("SELECT start_pos FROM alert_groups WHERE id = ?", (group_id,)).fetchone()
    members = db.execute(
        """SELECT s.* FROM alerts a JOIN series s ON s.id = a.series_id
           WHERE a.group_id = ? AND a.rule = ? ORDER BY s.id""", (group_id, RULE)).fetchall()
    if group is None or not members:
        return None
    marks = ",".join("?" * len(members))
    passed = db.execute(
        f"""SELECT r.series_id, b.sha FROM results r JOIN runs u ON u.id = r.run_id JOIN builds b ON b.id = u.build_id
            WHERE r.series_id IN ({marks}) AND u.kind = 'waterfall' AND b.commit_pos < ?
            ORDER BY b.commit_pos DESC, r.series_id LIMIT 1""",
        (*(row["id"] for row in members), group["start_pos"])).fetchone()
    if passed is None:
        return FunctionalTarget(alerts.SeriesInfo.from_row(members[0]), None)
    series = next(row for row in members if row["id"] == passed["series_id"])
    return FunctionalTarget(alerts.SeriesInfo.from_row(series), passed["sha"])


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
