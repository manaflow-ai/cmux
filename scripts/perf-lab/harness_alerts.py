#!/usr/bin/env python3
"""Harness-broken alerts and story coverage (p12-perf-process.md 3.6, task 214).

A story that errors is not slow, it measures nothing, so the change-point detector (alerts.py) never
sees it. This module turns the story runner's outcomes into the alerts a broken harness needs:

- Outcomes are stored (store.py table story_outcomes, one row per story, host, batch and status), because an
  errored story stores no result row. detect() records the outcomes it is given, then judges each (story, host
  class) they touch over the store, never over the given outcomes alone: a caller per job and a break longer than
  any caller's window judge the same history.
- A story that errors on an env-valid host on 2 consecutive batches is harness-broken. It gets an alert (rule
  `harness_broken`) on each of its series on that host class, and those alerts form one harness-broken group,
  never a regression group. Outcomes of an env-invalid host are no evidence either way (host_env refused the job
  and nothing ran), so they neither count nor break the streak.
- The break starts after the story's newest stored pass on that host class: a stored pass outcome or a stored
  waterfall point of its series (the query functional_target runs for the bisect's good end). The group's range is
  (that pass, the first errored batch tip after it]; with no stored pass it starts at FIRST_POSITION. One break is
  one group: a harness_broken alert of the (story, host class) that ends after the newest stored pass belongs to
  this break, so later batches of it join that group, or add nothing once a sheriff closed it. sheriff.py closes
  the group once the story ran again after the break, and only a new break after a pass opens another group.
- story_coverage() counts a planned story as measured only for an env-valid pass. An error, a
  harness-broken story and an env-invalid gap all count missing; a broken story is never dropped from
  the planned count, so a broken harness cannot raise coverage. stored_coverage() and broken_stories() apply the
  same rule to the store (the dashboard's coverage page and labd's /api/coverage show the broken stories).
- functional_target() is what the Pinpoint executor (pinpoint_exec.py) bisects a harness-broken group
  with: a functional-mode pinpoint.Job, which compares the attempts' pass/fail rates with
  perf_stats.compare in functional mode (the functional HighThreshold row, magnitude 0.5, the floored
  verdict for a bisect), as catapult `dashboard/dashboard/pinpoint/models/job_state.py` _Compare
  compares `bool(execution.exception)` tuples. Fewer failures on the later Change is SAME, so the
  bisect follows the breaking step and not a later fix. The good end is the story's newest stored
  waterfall pass before the range and the series is the one that pass stored: a passing attempt
  stores that metric, a broken one stores nothing.

The outcomes come from the story runner (task 008): outcomes_from_summary() reads run_story.py's summary.json and
exit code (3 = env-invalid), and ingest.py records the outcomes of a perf-lab job folder and runs detect() after it
stores the folder's results. On the command line they are ndjson, one StoryOutcome per line, or one job's summary:

  {"story": "...", "host_class": "apple-m6/24gb/120hz", "host": "cmux15", "batch_pos": 1234,
   "sha": "<batch tip>", "status": "pass" | "error" | "env-invalid", "reason": "..."}

  python3 scripts/perf-lab/harness_alerts.py detect --db lab.sqlite --outcomes outcomes.ndjson [--dry-run]
  python3 scripts/perf-lab/harness_alerts.py record --db lab.sqlite --summary summary.json --batch-pos N \\
      [--host H] [--host-class C] [--exit-code N] [--dry-run]
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
FIRST_POSITION = 0  # a break with no stored pass before it may start at any commit
RULE = "harness_broken"
ACTOR = "perf-lab-harness-alerts"
# run_story.py's exit codes: 0 (every run wrote results) and 1 (a run failed) carry the stories' verdicts, 3 is
# env-invalid, and any other (usage, no artifact, store down, a signal) says nothing about a story.
STORY_EXITS = (0, 1)
EXIT_ENV_INVALID = 3


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


def outcomes_from_summary(summary: object, *, batch_pos: int, host: str | None = None,
                          host_class: str | None = None, exit_code: int | None = None) -> list[StoryOutcome]:
    """One StoryOutcome per story run in run_story.py's summary.json of a batch-tip job.

    Exit 3 (refusal `env-invalid`): host_env refused the host before any story ran, so every planned story is
    env-invalid. Another refusal or exit code says nothing about a story: no outcome. A run is env-invalid when the
    host failed it (run_story's `env_invalid`: the app's validation after launch, a lost virtual display), a pass
    when it is ok, else an error with its reason. `host` and `host_class` default to the summary's host_env report;
    with no host class only env-invalid outcomes could be made, which are no evidence, so none are.
    """
    if not isinstance(summary, dict):
        raise HarnessAlertsError("summary.json is not an object")
    sha = summary.get("sha")
    if not isinstance(sha, str) or not sha:
        raise HarnessAlertsError("summary.json names no sha")
    env = summary.get("env") if isinstance(summary.get("env"), dict) else {}
    host_class = host_class or env.get("class")
    fingerprint = env.get("fingerprint")
    host = host or (f"fp-{fingerprint[:12]}" if isinstance(fingerprint, str) and fingerprint else None)
    if not isinstance(host_class, str) or not host_class or not host:
        return []
    refusal = summary.get("refusal") if isinstance(summary.get("refusal"), dict) else None
    kind = refusal.get("kind") if refusal else None
    if exit_code == EXIT_ENV_INVALID or kind == ENV_INVALID:
        reason = str(refusal.get("reason") or "") if refusal else ""
        stories = summary.get("stories") if isinstance(summary.get("stories"), list) else []
        return [StoryOutcome(story, host_class, host, batch_pos, sha, ENV_INVALID, reason)
                for story in stories if isinstance(story, str) and story]
    if kind is not None or (exit_code is not None and exit_code not in STORY_EXITS):
        return []
    runs = summary.get("runs")
    if not isinstance(runs, list):
        raise HarnessAlertsError("summary.json: runs is not a list")
    outcomes = []
    for index, run in enumerate(runs):
        story = run.get("story") if isinstance(run, dict) else None
        if not isinstance(story, str) or not story:
            raise HarnessAlertsError(f"summary.json: runs[{index}] names no story")
        if run.get("ok") is True:
            status, reason = PASS, ""
        elif run.get("env_invalid") is True:
            status, reason = ENV_INVALID, str(run.get("reason") or "")
        else:
            status, reason = ERROR, str(run.get("reason") or "failed")
        outcomes.append(StoryOutcome(story, host_class, host, batch_pos, sha, status, reason))
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


# ---------- the stored history ----------


@dataclass(frozen=True)
class Breakage:
    story: str
    host_class: str
    first_error: BatchStatus
    last_error: BatchStatus
    errored_batches: int
    last_pass: int | None  # the position of the story's newest stored pass on the host class; None if none is

    @property
    def start_pos(self) -> int:
        """The first commit that may have broken the story: the one after the newest stored pass."""
        return self.last_pass + 1 if self.last_pass is not None else FIRST_POSITION

    @property
    def end_pos(self) -> int:
        return self.first_error.batch_pos


def last_pass(db: sqlite3.Connection, story: str, host_class: str) -> int | None:
    """The position of the story's newest stored pass on the host class: a pass outcome, or a waterfall point of
    one of its series (a result row exists only for a run that measured)."""
    return db.execute(
        """SELECT MAX(pos) FROM (
               SELECT MAX(batch_pos) AS pos FROM story_outcomes WHERE story = ? AND host_class = ? AND status = ?
               UNION ALL
               SELECT MAX(b.commit_pos) FROM results r JOIN series s ON s.id = r.series_id
               JOIN runs u ON u.id = r.run_id JOIN builds b ON b.id = u.build_id
               WHERE s.story = ? AND s.host_class = ? AND u.kind = 'waterfall')""",
        (story, host_class, PASS, story, host_class)).fetchone()[0]


def _stored_outcomes(db: sqlite3.Connection, story: str, host_class: str, after: int | None) -> list[StoryOutcome]:
    """The stored outcomes of (story, host class) after position `after` (all of them for None), in commit order."""
    rows = db.execute(
        """SELECT story, host_class, host, batch_pos, sha, status, reason FROM story_outcomes
           WHERE story = ? AND host_class = ? AND (? IS NULL OR batch_pos > ?) ORDER BY batch_pos, id""",
        (story, host_class, after, after)).fetchall()
    return [StoryOutcome(*row) for row in rows]


def breakage(db: sqlite3.Connection, story: str, host_class: str) -> Breakage | None:
    """The stored env-valid errored batches after the story's newest stored pass, when there are BROKEN_AFTER."""
    passed = last_pass(db, story, host_class)
    batches = batch_statuses(_stored_outcomes(db, story, host_class, passed)).get((story, host_class), [])
    errors = [batch for batch in batches if batch.status == ERROR]
    if len(errors) < BROKEN_AFTER:
        return None
    return Breakage(story, host_class, errors[0], errors[-1], len(errors), passed)


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


def stored_coverage(store, planned: Iterable[PlannedStory]) -> Coverage:
    """story_coverage over the stored outcomes, read from each story's newest stored pass before its first planned
    batch, so an error inside a longer break counts harness-broken as it does over the whole history."""
    planned = list(planned)
    db, outcomes = store._db, []
    for story, host_class in sorted({(plan.story, plan.host_class) for plan in planned}):
        first = min(plan.batch_pos for plan in planned if (plan.story, plan.host_class) == (story, host_class))
        since = db.execute("""SELECT MAX(batch_pos) FROM story_outcomes WHERE story = ? AND host_class = ?
                              AND status = ? AND batch_pos < ?""", (story, host_class, PASS, first)).fetchone()[0]
        outcomes += _stored_outcomes(db, story, host_class, None if since is None else since - 1)
    return story_coverage(planned, outcomes)


def broken_stories(db: sqlite3.Connection) -> dict[tuple[str, str], Breakage]:
    """Every (story, host class) that is harness-broken now, by the stored outcomes and points."""
    keys = db.execute("SELECT DISTINCT story, host_class FROM story_outcomes WHERE status = ? ORDER BY 1, 2",
                      (ERROR,)).fetchall()
    found = {}
    for story, host_class in keys:
        broken = breakage(db, story, host_class)
        if broken is not None:
            found[(story, host_class)] = broken
    return found


# ---------- detection ----------


@dataclass
class DetectReport:
    recorded: int = 0  # outcomes newly stored (a repeated outcome is stored once)
    stories: int = 0
    broken: int = 0
    alerts: int = 0
    groups_created: list[int] = field(default_factory=list)
    groups_joined: list[int] = field(default_factory=list)
    no_series: list[str] = field(default_factory=list)  # broken stories with no stored series to alert on
    no_good_batch: list[str] = field(default_factory=list)  # broken stories with no stored pass before the break

    def to_dict(self) -> dict[str, object]:
        return dict(self.__dict__)


def detect(store, outcomes: Iterable[StoryOutcome]) -> DetectReport:
    """Records the outcomes, then opens or joins a harness-broken group for each broken (story, host class) they
    touch, judged over the store. One transaction: a refused outcome stores nothing."""
    outcomes = list(outcomes)
    batch_statuses(outcomes)  # refuses a batch with two tips before anything is written
    report = DetectReport()

    def write() -> None:
        db = store._db
        report.recorded = _store_outcomes(db, outcomes, store._now())
        for story, host_class in sorted({(outcome.story, outcome.host_class) for outcome in outcomes}):
            report.stories += 1
            broken = breakage(db, story, host_class)
            if broken is not None:
                report.broken += 1
                _record(store, broken, report)

    store._write(write)
    return report


def record_summary(store, summary: object, *, batch_pos: int, host: str | None = None,
                   host_class: str | None = None, exit_code: int | None = None) -> DetectReport:
    """detect() over one batch-tip job's run_story.py summary (outcomes_from_summary)."""
    return detect(store, outcomes_from_summary(summary, batch_pos=batch_pos, host=host, host_class=host_class,
                                               exit_code=exit_code))


def _store_outcomes(db: sqlite3.Connection, outcomes: Sequence[StoryOutcome], now: str) -> int:
    added = 0
    for outcome in outcomes:
        clash = db.execute("""SELECT sha FROM story_outcomes WHERE story = ? AND host_class = ? AND batch_pos = ?
                              AND sha != ? LIMIT 1""",
                           (outcome.story, outcome.host_class, outcome.batch_pos, outcome.sha)).fetchone()
        if clash is not None:
            raise HarnessAlertsError(f"{outcome.story} ({outcome.host_class}): batch {outcome.batch_pos} is stored "
                                     f"with tip {clash[0]}, not {outcome.sha}")
        added += db.execute(
            """INSERT OR IGNORE INTO story_outcomes (story, host_class, host, batch_pos, sha, status, reason,
                                                    recorded_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)""",
            (outcome.story, outcome.host_class, outcome.host, outcome.batch_pos, outcome.sha, outcome.status,
             outcome.reason, now)).rowcount
    return added


def _record(store, broken: Breakage, report: DetectReport) -> None:
    db, now = store._db, store._now()
    label = f"{broken.story} ({broken.host_class})"
    series = [row[0] for row in db.execute("SELECT id FROM series WHERE story = ? AND host_class = ? ORDER BY id",
                                           (broken.story, broken.host_class))]
    if not series:
        report.no_series.append(label)
        return
    # This break's alerts: the story's harness_broken alerts on the host class that end after its newest stored
    # pass. Any group state counts, so the same break never opens a group again after a sheriff closed it.
    current = db.execute(
        """SELECT a.series_id, g.id, g.state, g.start_pos, g.end_pos
           FROM alerts a JOIN series s ON s.id = a.series_id JOIN alert_groups g ON g.id = a.group_id
           WHERE a.rule = ? AND s.story = ? AND s.host_class = ? AND (? IS NULL OR a.end_pos > ?) ORDER BY a.id""",
        (RULE, broken.story, broken.host_class, broken.last_pass, broken.last_pass)).fetchall()
    if current:
        _, group_id, state, start, end = current[0]
        covered = {row[0] for row in current}
        new = [series_id for series_id in series if series_id not in covered]
        if state not in alerts.OPEN_STATES or not new:
            return
        report.groups_joined.append(group_id)
    else:
        new, start, end = series, broken.start_pos, broken.end_pos
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
    detect_cmd.add_argument("--outcomes", type=Path, required=True, help="ndjson, one StoryOutcome per line")
    record_cmd = commands.add_parser("record", help="harness-broken groups from one job's run_story.py summary")
    record_cmd.add_argument("--summary", type=Path, required=True, help="run_story.py's summary.json")
    record_cmd.add_argument("--batch-pos", type=int, required=True, help="the commit position of the batch tip")
    record_cmd.add_argument("--host", help="the lab host (default fp-<fingerprint> of the summary's host report)")
    record_cmd.add_argument("--host-class", help="the series host class (default the summary's host report)")
    record_cmd.add_argument("--exit-code", type=int, help="run_story.py's exit code (3 = env-invalid)")
    for command in (detect_cmd, record_cmd):
        command.add_argument("--db", type=Path, required=True)
        command.add_argument("--dry-run", action="store_true", help="run on a copy of the store")
    args = parser.parse_args(argv)
    try:
        if args.command == "detect":
            outcomes = read_outcomes(args.outcomes)
        else:
            try:
                summary = json.loads(args.summary.read_text(encoding="utf-8"))
            except (OSError, UnicodeDecodeError, ValueError) as error:
                raise HarnessAlertsError(f"{args.summary}: {error}") from None
            outcomes = outcomes_from_summary(summary, batch_pos=args.batch_pos, host=args.host,
                                             host_class=args.host_class, exit_code=args.exit_code)
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
