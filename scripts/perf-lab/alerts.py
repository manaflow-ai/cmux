#!/usr/bin/env python3
"""Perf-lab alerts: subscriptions, alert groups, and GitHub issues only for verified culprits.

Chromeperf's flow, ported to the lab store (p12-perf-process.md 3.5):

- After an ingest, `detect()` runs the change-point detector and `target_miss` on the touched series.
  Only a series that a subscription in subscriptions.json matches can alert, as only a sheriff
  `Subscription` does in chromeperf (catapult `dashboard/dashboard/protobuf/sheriff.proto`,
  `dashboard/dashboard/sheriff_config/matcher.py`). An entry has an owner and an optional
  `AnomalyConfig` override with the proto's field names. Unmonitored series keep their points and
  get no alert.
- A change point the series already has an alert for (an overlapping range, same rule) is not
  alerted again, as catapult `find_anomalies.py` drops change points already alerted on a test.
- A regression joins the oldest open group whose range overlaps its own (catapult
  `dashboard/dashboard/models/alert_group.py`, `RevisionRange.IsOverlapping`); the group range becomes
  the intersection, because the culprit is in every member's range. Otherwise it opens a group.
  Improvements are stored and never grouped. A `target_miss` is a dashboard tile: stored, never grouped.
- `sync_issues()` opens a GitHub issue (label `perf-regression`) only for a group whose culprit is
  verified (task 017 sets `culprit_verified`). It posts one comment per sheriff state change after
  that and edits the body with it. Reads go through glaeda-gh; writes through `gh api` with backoff.

  python3 scripts/perf-lab/alerts.py detect --db lab.sqlite [--series KEY ...] [--dry-run]
  python3 scripts/perf-lab/alerts.py sync-issues --db lab.sqlite --dashboard-url URL [--dry-run]
  python3 scripts/perf-lab/alerts.py groups --db lab.sqlite --state new,triaged,culprit --json
  python3 scripts/perf-lab/alerts.py check-subscriptions
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import math
import re
import sqlite3
import subprocess
import sys
import tempfile
import time
from collections.abc import Callable, Mapping, Sequence
from dataclasses import dataclass, field
from fnmatch import fnmatchcase
from pathlib import Path
from typing import Protocol

HERE = Path(__file__).resolve().parent
DEFAULT_SUBSCRIPTIONS = HERE / "subscriptions.json"
DEFAULT_TARGETS = HERE / "targets.json"
REPO_ROOT = HERE.parents[1]
DEFAULT_REPO = "manaflow-ai/cmux"
ISSUE_LABEL = "perf-regression"
ACTOR = "perf-lab-alerts"


class AlertsError(RuntimeError):
    pass


def _load_sibling(module_name: str, filename: str):
    """Loads a perf-lab module by path once, so tests and labd share one module object."""
    if module_name in sys.modules:
        return sys.modules[module_name]
    path = HERE / filename
    if not path.exists():
        raise AlertsError(f"{path} is missing")
    spec = importlib.util.spec_from_file_location(module_name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(module_name, None)
        raise
    return module


store_mod = _load_sibling("perf_lab_store", "store.py")
perf_stats = _load_sibling("perf_lab_perf_stats", "perf_stats.py")

# The sheriff states (store.ALERT_GROUP_STATES) in which a group still takes new overlapping alerts.
OPEN_STATES = ("new", "triaged", "bisecting", "culprit", "assigned")
# Open states in which a joining alert still narrows the group range (no bisect has started).
NARROWING_STATES = ("new", "triaged")
# States that close the group's issue.
CLOSED_STATES = ("fixed", "flag-off", "accepted", "invalid", "lab-drift")
# A verified group in one of these never gets an issue: the alert was not a real regression.
NO_ISSUE_STATES = ("invalid", "lab-drift")

# sheriff.proto AnomalyConfig fields; catapult dashboard/common/defaults.py holds the defaults (task 003).
ANOMALY_CONFIG_KEYS = frozenset({
    "max_window_size", "min_segment_size", "min_absolute_change",
    "min_relative_change", "min_steppiness", "multiple_of_std_dev",
})
# AnomalyConfig fields that are point counts (int32 in sheriff.proto), with their least value.
ANOMALY_CONFIG_COUNTS = {"max_window_size": 1, "min_segment_size": 0}
DEFAULT_MAX_WINDOW_SIZE = 50
MATCH_FIELDS = ("story", "metric", "engine", "host_class", "build_config")
SUBSCRIPTION_KINDS = ("target", "perf-hot", "family", "aggregate")
TARGET_STATS = ("p50", "p95", "p99", "max")
STATE_MARKER = re.compile(r"<!-- perf-lab-alerts state-change=(\d+) -->")


# ---------- subscriptions ----------


@dataclass(frozen=True)
class SeriesInfo:
    id: int
    key: str
    story: str
    metric: str
    engine: str
    host_class: str
    macos_major: int
    build_config: str
    unit: str
    better: str

    @classmethod
    def from_row(cls, row: sqlite3.Row) -> "SeriesInfo":
        return cls(row["id"], row["series_key"], row["story"], row["metric"], row["engine"], row["host_class"],
                   row["macos_major"], row["build_config"], row["unit"], row["better"])


@dataclass(frozen=True)
class Subscription:
    name: str
    kind: str
    owner: str
    match: Mapping[str, str]
    targets: tuple[str, ...] = ()
    anomaly_config: Mapping[str, float] = field(default_factory=dict)

    def matches(self, series: SeriesInfo) -> bool:
        return all(fnmatchcase(str(getattr(series, name)), pattern) for name, pattern in self.match.items())


@dataclass(frozen=True)
class Subscriptions:
    """subscriptions.json. The first entry that matches a series owns it (file order is priority)."""

    build_configs: tuple[str, ...]
    entries: tuple[Subscription, ...]

    def match(self, series: SeriesInfo) -> Subscription | None:
        if series.build_config not in self.build_configs:
            return None
        return next((entry for entry in self.entries if entry.matches(series)), None)

    @classmethod
    def load(cls, path: Path | str = DEFAULT_SUBSCRIPTIONS) -> "Subscriptions":
        try:
            document = json.loads(Path(path).read_text())
        except (OSError, json.JSONDecodeError) as error:
            raise AlertsError(f"{path}: {error}") from None
        return cls.parse(document, source=str(path))

    @classmethod
    def parse(cls, document: object, *, source: str = "subscriptions") -> "Subscriptions":
        if not isinstance(document, dict) or set(document) - {"_doc", "build_configs", "subscriptions"}:
            raise AlertsError(f"{source}: expected an object with build_configs and subscriptions")
        configs = document.get("build_configs")
        if not isinstance(configs, list) or not configs or not all(isinstance(c, str) for c in configs):
            raise AlertsError(f"{source}: build_configs must be a non-empty list of build configs")
        raw_entries = document.get("subscriptions")
        if not isinstance(raw_entries, list) or not raw_entries:
            raise AlertsError(f"{source}: subscriptions must be a non-empty list")
        entries = tuple(_parse_entry(raw, f"{source}: subscriptions[{index}]")
                        for index, raw in enumerate(raw_entries))
        names = [entry.name for entry in entries]
        duplicates = sorted({name for name in names if names.count(name) > 1})
        if duplicates:
            raise AlertsError(f"{source}: duplicate subscription names {duplicates}")
        return cls(tuple(configs), entries)


def _parse_entry(raw: object, where: str) -> Subscription:
    allowed = {"name", "kind", "owner", "match", "targets", "anomaly_config"}
    if not isinstance(raw, dict) or set(raw) - allowed:
        raise AlertsError(f"{where}: expected an object with keys from {sorted(allowed)}")
    for key in ("name", "owner"):
        if not isinstance(raw.get(key), str) or not raw[key].strip():
            raise AlertsError(f"{where}: {key} must be a non-empty string")
    if raw.get("kind") not in SUBSCRIPTION_KINDS:
        raise AlertsError(f"{where} ({raw['name']}): kind must be one of {SUBSCRIPTION_KINDS}")
    match = raw.get("match")
    if (not isinstance(match, dict) or not match or set(match) - set(MATCH_FIELDS)
            or not all(isinstance(value, str) and value for value in match.values())):
        raise AlertsError(f"{where} ({raw['name']}): match must map fields from {MATCH_FIELDS} to globs")
    targets = raw.get("targets", [])
    if not isinstance(targets, list) or not all(isinstance(t, str) and t for t in targets):
        raise AlertsError(f"{where} ({raw['name']}): targets must be a list of targets.json ids")
    if targets and raw["kind"] != "target":
        raise AlertsError(f"{where} ({raw['name']}): only a kind=target entry names targets")
    config = raw.get("anomaly_config", {})
    if (not isinstance(config, dict) or set(config) - ANOMALY_CONFIG_KEYS
            or not all(isinstance(v, (int, float)) and not isinstance(v, bool) for v in config.values())):
        raise AlertsError(f"{where} ({raw['name']}): anomaly_config takes numbers for {sorted(ANOMALY_CONFIG_KEYS)}")
    config = dict(config)
    for key, least in ANOMALY_CONFIG_COUNTS.items():
        if key in config:
            if not float(config[key]).is_integer() or config[key] < least:
                raise AlertsError(f"{where} ({raw['name']}): anomaly_config {key} must be a whole number >= {least}")
            config[key] = int(config[key])
    return Subscription(raw["name"], raw["kind"], raw["owner"], dict(match), tuple(targets), config)


# ---------- targets (targets.json, task 007) ----------


@dataclass(frozen=True)
class Target:
    id: str
    value: float
    stat: str


TargetSource = Callable[[str], "Target | None"]


def load_targets(path: Path | str = DEFAULT_TARGETS) -> TargetSource:
    """Reads targets.json `{"targets": [{"id", "value", "stat"}]}`; with no file there are no target tiles yet."""
    path = Path(path)
    if not path.exists():
        return lambda target_id: None
    try:
        document = json.loads(path.read_text())
    except (OSError, json.JSONDecodeError) as error:
        raise AlertsError(f"{path}: {error}") from None
    rows = document.get("targets") if isinstance(document, dict) else None
    if not isinstance(rows, list):
        raise AlertsError(f"{path}: expected an object with a targets list")
    targets: dict[str, Target] = {}
    for row in rows:
        if not isinstance(row, dict) or not isinstance(row.get("id"), str):
            raise AlertsError(f"{path}: every target needs a string id")
        value, stat = row.get("value"), row.get("stat", "p50")
        if not isinstance(value, (int, float)) or isinstance(value, bool) or stat not in TARGET_STATS:
            raise AlertsError(f"{path}: target {row['id']} needs a numeric value and a stat from {TARGET_STATS}")
        targets[row["id"]] = Target(row["id"], float(value), stat)
    return targets.get


# ---------- the detector seam (anomaly.py, task 003) ----------


@dataclass(frozen=True)
class ChangePoint:
    """One step in a value list. Indexes are into that list.

    The step is at a split index in [extended_start, extended_end] (catapult ExtendChangePointRange):
    points before extended_start are before the step, points from extended_end on are after it.
    """

    extended_start: int
    extended_end: int
    median_before: float
    median_after: float


class Detector(Protocol):
    def change_points(self, values: Sequence[float], config: Mapping[str, float]) -> Sequence[ChangePoint]:
        """The steps that pass the config's thresholds, newest first (catapult FindChangePoints order)."""

    def target_miss(self, values: Sequence[float], target: float, better: str) -> int | None:
        """The index of the newest segment's first value when that segment's median misses the target and the
        previous segment's did not; else None."""


class CatapultDetector:
    """Adapts anomaly.py (the catapult port, task 003) to the Detector seam.

    anomaly.find_change_points takes catapult's (x, y) series and AnomalyConfig keywords and returns
    catapult ChangePoints (`find_change_points.py`: extended_start and extended_end as x values,
    median_before, median_after); here x is the value index. anomaly.target_miss(values, target) judges
    a lower-is-better series, so a higher-is-better one is passed negated; its TargetMiss.x_value is the
    index where the missing segment starts.
    """

    def __init__(self) -> None:
        self._anomaly = _load_sibling("perf_lab_anomaly", "anomaly.py")  # AlertsError until task 003 lands

    def change_points(self, values: Sequence[float], config: Mapping[str, float]) -> list[ChangePoint]:
        found = self._anomaly.find_change_points(list(enumerate(values)), **config)
        return [ChangePoint(int(point.extended_start), int(point.extended_end),
                            float(point.median_before), float(point.median_after)) for point in found]

    def target_miss(self, values: Sequence[float], target: float, better: str) -> int | None:
        if better == "higher":
            miss = self._anomaly.target_miss([-value for value in values], -target)
        else:
            miss = self._anomaly.target_miss(list(values), target)
        return None if miss is None else int(miss.x_value)


FloorSource = Callable[[SeriesInfo], "float | None"]


def load_floors(root: Path = REPO_ROOT) -> FloorSource:
    """Each series' noise floor: its catalog metric's floor_ref (stories.d), resolved by anomaly.row_floor.

    The series' story is the catalog story id; the first metric whose name pattern full-matches the series'
    metric gives the floor. A series with no such metric, or a metric with no floor_ref, has none.
    """
    anomaly = _load_sibling("perf_lab_anomaly", "anomaly.py")
    catalog = anomaly.catalog
    try:
        floors = {story.id: [(re.compile(metric.name), anomaly.row_floor(metric.floor_ref, root))
                             for metric in story.metrics if metric.floor_ref is not None]
                  for story in catalog.load_catalog(root).stories}
    except (catalog.CatalogError, catalog.RefError) as error:
        raise AlertsError(f"catalog floors under {root}: {error}") from None

    def floor(series: SeriesInfo) -> float | None:
        return next((value for pattern, value in floors.get(series.story, ()) if pattern.fullmatch(series.metric)),
                    None)

    return floor


# ---------- detection ----------


@dataclass
class DetectReport:
    series: int = 0
    unmonitored: int = 0
    alerts: int = 0
    improvements: int = 0
    target_misses: int = 0
    groups_created: list[int] = field(default_factory=list)
    groups_joined: list[int] = field(default_factory=list)

    def to_dict(self) -> dict[str, object]:
        return dict(self.__dict__)


def point_stat(samples: Sequence[float], stat: str) -> float | None:
    if stat == "max":
        return max(samples) if samples else None
    return perf_stats.pct(samples, {"p50": 0.50, "p95": 0.95, "p99": 0.99}[stat])


def judged_points(points: Sequence[object]) -> list[object]:
    """Points the detector may judge. Imported cron history (task 005: legacy_p95_only, legacy_stat) is shown only."""
    def legacy(point) -> bool:
        flags = point.summary or {}
        return point.measure_version.startswith("legacy") or bool(flags.get("legacy_p95_only") or flags.get("legacy_stat"))

    return [point for point in points if point.samples and not legacy(point)]


def is_regression(better: str, before: float, after: float) -> bool:
    return after > before if better == "lower" else after < before


def _candidate_range(positions: Sequence[int], start_index: int, end_index: int) -> tuple[int, int]:
    """The commits that may hold the step: after the last point before it, up to the first point after it."""
    end_index = min(max(end_index, 0), len(positions) - 1)
    start_index = min(max(start_index, 0), end_index)
    start = positions[start_index - 1] + 1 if start_index > 0 else positions[start_index]
    return min(start, positions[end_index]), positions[end_index]


def _series_rows(store, keys: Sequence[str] | None) -> list[SeriesInfo]:
    db = store._db  # store.py has no public alert API yet; this module uses its connection and _write.
    if keys is None:
        rows = db.execute("SELECT * FROM series ORDER BY id").fetchall()
    else:
        marks = ",".join("?" * len(keys))
        rows = db.execute(f"SELECT * FROM series WHERE series_key IN ({marks}) ORDER BY id", list(keys)).fetchall()
    return [SeriesInfo.from_row(row) for row in rows]


def detect(store, subscriptions: Subscriptions, detector: Detector, targets: TargetSource,
           *, keys: Sequence[str] | None = None, floors: FloorSource | None = None) -> DetectReport:
    """Runs change-point detection and target_miss on the given series (every series when keys is None).

    A series' noise floor (floors, from load_floors) is its MIN_ABSOLUTE_CHANGE. A subscription's
    min_absolute_change may raise it, never go below it: a step smaller than the noise floor is noise.
    """
    report = DetectReport()
    for series in _series_rows(store, keys):
        report.series += 1
        subscription = subscriptions.match(series)
        if subscription is None:
            report.unmonitored += 1
            continue
        config = dict(subscription.anomaly_config)
        floor = floors(series) if floors is not None else None
        if floor is not None:
            config["min_absolute_change"] = max(floor, config.get("min_absolute_change", floor))
        window = int(config.get("max_window_size", DEFAULT_MAX_WINDOW_SIZE))
        points = judged_points(store.series_points(series.key, limit=window))
        if not points:
            continue
        positions = [point.commit_pos for point in points]
        found: list[tuple[str, int, int, float | None, float | None, bool]] = []
        changes = list(detector.change_points([point_stat(point.samples, "p50") for point in points], config))
        for change in changes:
            if change.median_before == change.median_after:
                continue
            start, end = _candidate_range(positions, change.extended_start, change.extended_end)
            improvement = not is_regression(series.better, change.median_before, change.median_after)
            found.append(("edivisive", start, end, change.median_before, change.median_after, improvement))
        for target_id in subscription.targets:
            target = targets(target_id)
            if target is None:
                continue
            values = [point_stat(point.samples, target.stat) for point in points]
            miss_start = detector.target_miss(values, target.value, series.better)
            if miss_start is not None:
                # The tile's range: the commits between the last point before the missing segment and its first.
                found.append(("target_miss", *_candidate_range(positions, miss_start, miss_start), None, None, False))
        if found:
            store._write(lambda: _record(store, series, found, report))
    return report


def _record(store, series: SeriesInfo, found, report: DetectReport) -> None:
    """Inside one write transaction: drop already-alerted ranges, store the rest, group regressions."""
    db, now = store._db, store._now()
    for rule, start, end, before, after, improvement in found:
        overlapping = db.execute(
            "SELECT 1 FROM alerts WHERE series_id = ? AND rule = ? AND start_pos <= ? AND end_pos >= ?",
            (series.id, rule, end, start)).fetchone()
        if overlapping:
            continue
        group_id = None
        if rule == "edivisive" and not improvement:
            group_id = _group_for(db, now, series, start, end, report)
        db.execute(
            """INSERT INTO alerts (series_id, group_id, rule, start_pos, end_pos, median_before, median_after,
                                   is_improvement, created_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (series.id, group_id, rule, start, end, before, after, int(improvement), now))
        if rule == "target_miss":
            report.target_misses += 1
        elif improvement:
            report.improvements += 1
        else:
            report.alerts += 1


def _group_for(db: sqlite3.Connection, now: str, series: SeriesInfo, start: int, end: int,
               report: DetectReport) -> int:
    marks = ",".join("?" * len(OPEN_STATES))
    group = db.execute(
        f"""SELECT id, state, start_pos, end_pos FROM alert_groups
            WHERE state IN ({marks}) AND start_pos <= ? AND end_pos >= ?
              AND NOT EXISTS (SELECT 1 FROM alerts h WHERE h.group_id = alert_groups.id AND h.rule = 'harness_broken')
            ORDER BY id LIMIT 1""",
        (*OPEN_STATES, end, start)).fetchone()
    if group is not None:
        # The culprit is in every member's range. Once a bisect runs, its range stays fixed.
        if group["state"] in NARROWING_STATES:
            db.execute("UPDATE alert_groups SET start_pos = ?, end_pos = ?, updated_at = ? WHERE id = ?",
                       (max(group["start_pos"], start), min(group["end_pos"], end), now, group["id"]))
        report.groups_joined.append(group["id"])
        return group["id"]
    group_id = db.execute(
        """INSERT INTO alert_groups (state, start_pos, end_pos, created_at, updated_at)
           VALUES ('new', ?, ?, ?, ?)""", (start, end, now, now)).lastrowid
    db.execute(
        "INSERT INTO sheriff_history (group_id, from_state, to_state, actor, reason, at) VALUES (?, NULL, 'new', ?, ?, ?)",
        (group_id, ACTOR, f"alert on {series.story} {series.metric} ({series.host_class})", now))
    report.groups_created.append(group_id)
    return group_id


# ---------- group reads ----------


@dataclass(frozen=True)
class GroupAlert:
    series: SeriesInfo
    start_pos: int
    end_pos: int
    median_before: float
    median_after: float

    @property
    def relative_change(self) -> float:
        if self.median_before == 0:
            return math.inf
        return abs(self.median_after - self.median_before) / abs(self.median_before)


def group_alerts(store, group_id: int) -> list[GroupAlert]:
    """The group's regression alerts, largest relative change first."""
    rows = store._db.execute(
        """SELECT s.*, a.start_pos AS a_start, a.end_pos AS a_end, a.median_before, a.median_after
           FROM alerts a JOIN series s ON s.id = a.series_id
           WHERE a.group_id = ? AND a.rule = 'edivisive' AND a.is_improvement = 0 ORDER BY a.id""",
        (group_id,)).fetchall()
    alerts = [GroupAlert(SeriesInfo.from_row(row), row["a_start"], row["a_end"], row["median_before"],
                         row["median_after"]) for row in rows]
    return sorted(alerts, key=lambda alert: -alert.relative_change)


def group_owner(subscriptions: Subscriptions, alerts: Sequence[GroupAlert]) -> str | None:
    """The story owner: the owner of the subscription of the group's largest regression."""
    for alert in alerts:
        subscription = subscriptions.match(alert.series)
        if subscription is not None:
            return subscription.owner
    return None


def list_groups(store, subscriptions: Subscriptions, states: Sequence[str] | None = None) -> list[dict[str, object]]:
    query, args = "SELECT * FROM alert_groups", []
    if states:
        query += f" WHERE state IN ({','.join('?' * len(states))})"
        args = list(states)
    groups = []
    for row in store._db.execute(query + " ORDER BY id", args).fetchall():
        alerts = group_alerts(store, row["id"])
        groups.append({
            "id": row["id"], "state": row["state"], "start_pos": row["start_pos"], "end_pos": row["end_pos"],
            "owner": group_owner(subscriptions, alerts), "culprit_sha": row["culprit_sha"],
            "culprit_verified": bool(row["culprit_verified"]), "issue_number": row["issue_number"],
            "created_at": row["created_at"],
            "alerts": [{"series_key": a.series.key, "story": a.series.story, "metric": a.series.metric,
                        "host_class": a.series.host_class, "start_pos": a.start_pos, "end_pos": a.end_pos,
                        "median_before": a.median_before, "median_after": a.median_after} for a in alerts],
        })
    return groups


# ---------- GitHub ----------


class GitHub(Protocol):
    def issue_comment_bodies(self, number: int) -> list[str]: ...

    def create_issue(self, title: str, body: str, labels: Sequence[str]) -> int: ...

    def edit_issue(self, number: int, body: str, *, closed: bool) -> None: ...

    def comment(self, number: int, body: str) -> None: ...


Runner = Callable[..., subprocess.CompletedProcess]


class GhClient:
    """Reads through the glaeda-gh cache (no quota spent); writes through `gh api` with backoff.

    A rate-limited write is refused before GitHub acts on it, so every write retries it. A 5xx may have
    been applied, so only the idempotent PATCH retries it; a POST would risk a second issue or comment.
    """

    RATE_LIMITED = re.compile(r"HTTP 429|rate limit", re.IGNORECASE)
    SERVER_ERROR = re.compile(r"HTTP 5\d\d")

    def __init__(self, repo: str, *, runner: Runner = subprocess.run, sleep: Callable[[float], None] = time.sleep,
                 attempts: int = 4, base_delay_s: float = 2.0) -> None:
        self._repo, self._run, self._sleep = repo, runner, sleep
        self._attempts, self._base_delay_s = attempts, base_delay_s

    def issue_comment_bodies(self, number: int) -> list[str]:
        try:
            result = self._run(["glaeda-gh", "status", "comment", f"{self._repo}#{number}", "--json"],
                               capture_output=True, text=True)
        except OSError as error:
            raise AlertsError(f"glaeda-gh: {error}; install it (glaeda-mini-setup), do not poll GitHub") from None
        if result.returncode == 3:
            raise AlertsError("glaeda-gh daemon is down; start it (see the github-ci-wait skill), do not poll GitHub")
        if result.returncode != 0:
            raise AlertsError(f"glaeda-gh status comment {self._repo}#{number}: {result.stderr.strip()}")
        try:
            document = json.loads(result.stdout)
        except json.JSONDecodeError:
            raise AlertsError(f"glaeda-gh status comment {self._repo}#{number}: output is not JSON") from None
        comments = document.get("comments") if isinstance(document, dict) else document
        if not isinstance(comments, list) or not all(isinstance(c, dict) for c in comments):
            raise AlertsError(f"glaeda-gh status comment {self._repo}#{number}: no comments list")
        return [str(comment.get("body", "")) for comment in comments]

    def create_issue(self, title: str, body: str, labels: Sequence[str]) -> int:
        created = self._api("POST", f"repos/{self._repo}/issues", {"title": title, "body": body, "labels": list(labels)})
        return int(created["number"])

    def edit_issue(self, number: int, body: str, *, closed: bool) -> None:
        self._api("PATCH", f"repos/{self._repo}/issues/{number}",
                  {"body": body, "state": "closed" if closed else "open"})

    def comment(self, number: int, body: str) -> None:
        self._api("POST", f"repos/{self._repo}/issues/{number}/comments", {"body": body})

    def _api(self, method: str, path: str, payload: Mapping[str, object]) -> dict[str, object]:
        for attempt in range(self._attempts):
            try:
                result = self._run(["gh", "api", "--method", method, path, "--input", "-"],
                                   input=json.dumps(payload), capture_output=True, text=True)
            except OSError as error:
                raise AlertsError(f"gh api {method} {path}: {error}") from None
            if result.returncode == 0:
                return json.loads(result.stdout or "{}")
            retry = bool(self.RATE_LIMITED.search(result.stderr)) or (
                method == "PATCH" and bool(self.SERVER_ERROR.search(result.stderr)))
            if not retry or attempt == self._attempts - 1:
                raise AlertsError(f"gh api {method} {path}: {result.stderr.strip()}")
            self._sleep(self._base_delay_s * 2 ** attempt)
        raise AlertsError(f"gh api {method} {path}: no attempts")


class RecordingGitHub:
    """--dry-run: records the writes it would make. Comments of real issues are read through `reader`."""

    def __init__(self, reader: GitHub | None = None) -> None:
        self.actions: list[dict[str, object]] = []
        self._reader = reader
        self._created: set[int] = set()
        self._next = -1

    def issue_comment_bodies(self, number: int) -> list[str]:
        read = [] if self._reader is None or number in self._created else self._reader.issue_comment_bodies(number)
        return read + [str(action["body"]) for action in self.actions
                       if action["action"] == "comment" and action["number"] == number]

    def create_issue(self, title: str, body: str, labels: Sequence[str]) -> int:
        # Negative numbers: a dry run never claims a real issue number.
        number, self._next = self._next, self._next - 1
        self._created.add(number)
        self.actions.append({"action": "create", "number": number, "title": title, "labels": list(labels), "body": body})
        return number

    def edit_issue(self, number: int, body: str, *, closed: bool) -> None:
        self.actions.append({"action": "edit", "number": number, "closed": closed, "body": body})

    def comment(self, number: int, body: str) -> None:
        self.actions.append({"action": "comment", "number": number, "body": body})


# ---------- issue rendering ----------


def _segment_samples(store, alert: GroupAlert) -> tuple[list[float], list[float]]:
    """Pooled raw samples before and after the alert's range, bounded by the series' other alerts."""
    points = judged_points(store.series_points(alert.series.key, limit=4 * DEFAULT_MAX_WINDOW_SIZE))
    bounds = store._db.execute(
        """SELECT MAX(CASE WHEN end_pos < ? THEN end_pos END), MIN(CASE WHEN start_pos > ? THEN start_pos END)
           FROM alerts WHERE series_id = ? AND rule = 'edivisive'""",
        (alert.start_pos, alert.end_pos, alert.series.id)).fetchone()
    lower = bounds[0] if bounds[0] is not None else -math.inf
    upper = bounds[1] if bounds[1] is not None else math.inf
    before = [p for p in points if lower <= p.commit_pos < alert.start_pos][-DEFAULT_MAX_WINDOW_SIZE:]
    after = [p for p in points if alert.end_pos <= p.commit_pos < upper][:DEFAULT_MAX_WINDOW_SIZE]
    return [s for p in before for s in p.samples], [s for p in after for s in p.samples]


def _fmt(value: float | None, unit: str) -> str:
    return "n/a" if value is None else f"{value:.3g} {unit}"


def _stats(samples: Sequence[float], unit: str) -> str:
    summary = perf_stats.summary(samples)
    return " / ".join(_fmt(summary[key], unit) for key in ("p50", "p95", "p99"))


def waterfall_sha(store, config: str, pos: int, *, before: bool) -> str | None:
    """An alert range's end as a commit: the last waterfall point before `pos`, or the first one at or after it.

    Only waterfall runs count: a bisect or try run also stores its build at its commit position, and a range end
    must be a commit the waterfall measured. The issue's compare link and the bisect range (pinpoint_exec.py) both
    come from here."""
    query = ("""SELECT b.sha FROM builds b WHERE b.config = ? AND b.commit_pos < ? AND EXISTS
                (SELECT 1 FROM runs u WHERE u.build_id = b.id AND u.kind = 'waterfall')
                ORDER BY b.commit_pos DESC LIMIT 1""" if before else
             """SELECT b.sha FROM builds b WHERE b.config = ? AND b.commit_pos >= ? AND EXISTS
                (SELECT 1 FROM runs u WHERE u.build_id = b.id AND u.kind = 'waterfall')
                ORDER BY b.commit_pos LIMIT 1""")
    row = store._db.execute(query, (config, pos)).fetchone()
    return None if row is None else row["sha"]


def render_issue(store, group: sqlite3.Row, alerts: Sequence[GroupAlert], owner: str | None, *,
                 repo: str, dashboard_url: str) -> tuple[str, str]:
    top = alerts[0]
    change = top.relative_change
    title = (f"perf: {top.series.story} {top.series.metric} regressed "
             f"{'' if math.isinf(change) else f'{change:+.0%} '}at {group['culprit_sha'][:10]} ({top.series.host_class})")
    jobs = store._db.execute("SELECT id, kind FROM jobs WHERE alert_group_id = ? ORDER BY id",
                             (group["id"],)).fetchall()
    bisects = [job["id"] for job in jobs if job["kind"] == "bisect"]
    bisect = f"[job {bisects[-1]}]({dashboard_url}/jobs/{bisects[-1]})" if bisects else "none"
    traces = store._db.execute(
        f"SELECT url FROM traces WHERE job_id IN ({','.join('?' * len(jobs))}) ORDER BY id LIMIT 4",
        [job["id"] for job in jobs]).fetchall() if jobs else []
    trace_links = ", ".join(f"[{index + 1}]({row['url']})" for index, row in enumerate(traces)) or "none"
    lines = [
        f"Owner: {owner or 'unrouted (no subscription owner)'}",
        f"State: {group['state']}",
        f"Culprit (verified, strict rule): {group['culprit_sha']}",
        f"Alert group: [{group['id']}]({dashboard_url}/alerts/{group['id']})",
        "",
        "| Story | Metric | Host class | Before p50 / p95 / p99 | After p50 / p95 / p99 | Range | Dashboard | Bisect | Traces |",
        "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for alert in alerts:
        before, after = _segment_samples(store, alert)
        good = waterfall_sha(store, alert.series.build_config, alert.start_pos, before=True)
        bad = waterfall_sha(store, alert.series.build_config, alert.end_pos, before=False)
        span = f"{alert.start_pos}..{alert.end_pos}"
        if good and bad:
            span = f"[{span}](https://github.com/{repo}/compare/{good[:12]}...{bad[:12]})"
        lines.append(
            f"| {alert.series.story} | {alert.series.metric} | {alert.series.host_class} "
            f"| {_stats(before, alert.series.unit)} | {_stats(after, alert.series.unit)} | {span} "
            f"| [series]({dashboard_url}/series/{alert.series.key}) | {bisect} | {trace_links} |")
    lines += ["", f"<!-- perf-lab-alerts group={group['id']} -->"]
    return title, "\n".join(lines)


def render_state_comment(change: sqlite3.Row) -> str:
    moved = f"{change['from_state']} -> {change['to_state']}" if change["from_state"] else change["to_state"]
    reason = f": {change['reason']}" if change["reason"] else ""
    return (f"State {moved} by {change['actor']} at {change['at']}{reason}\n\n"
            f"<!-- perf-lab-alerts state-change={change['id']} -->")


# ---------- issue sync ----------


@dataclass
class SyncReport:
    issues_created: list[int] = field(default_factory=list)
    comments: int = 0
    edits: int = 0

    def to_dict(self) -> dict[str, object]:
        return dict(self.__dict__)


def sync_issues(store, subscriptions: Subscriptions, github: GitHub, *, repo: str, dashboard_url: str) -> SyncReport:
    """Opens an issue for each verified group without one, then posts each new state change once.

    Which state changes the issue has is read back from its comments (one marker per sheriff_history
    row). An issue with no marker yet gets one comment for the group's current state.
    """
    report = SyncReport()
    dashboard_url = dashboard_url.rstrip("/")
    groups = store._db.execute(
        "SELECT * FROM alert_groups WHERE culprit_verified = 1 AND culprit_sha IS NOT NULL ORDER BY id").fetchall()
    for group in groups:
        alerts = group_alerts(store, group["id"])
        if not alerts:
            continue
        number = group["issue_number"]
        if number is None and group["state"] in NO_ISSUE_STATES:
            continue
        title, body = render_issue(store, group, alerts, group_owner(subscriptions, alerts),
                                   repo=repo, dashboard_url=dashboard_url)
        created = number is None
        if created:
            number = github.create_issue(title, body, [ISSUE_LABEL])
            store._write(lambda: store._db.execute(
                "UPDATE alert_groups SET issue_number = ?, updated_at = ? WHERE id = ? AND issue_number IS NULL",
                (number, store._now(), group["id"])))
            report.issues_created.append(number)
        history = store._db.execute("SELECT * FROM sheriff_history WHERE group_id = ? ORDER BY id",
                                    (group["id"],)).fetchall()
        bodies = [] if created else github.issue_comment_bodies(number)
        posted = [int(m) for body_text in bodies for m in STATE_MARKER.findall(body_text)]
        pending = [row for row in history if row["id"] > max(posted)] if posted else history[-1:]
        for change in pending:
            github.comment(number, render_state_comment(change))
            report.comments += 1
        closed = group["state"] in CLOSED_STATES
        if pending and (not created or closed):
            github.edit_issue(number, body, closed=closed)
            report.edits += 1
    return report


# ---------- CLI ----------


def _snapshot(db_path: Path, directory: Path) -> Path:
    """A consistent copy of the store (WAL included) for --dry-run, so nothing is written to the real one."""
    copy = directory / "dry-run.sqlite"
    source = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True)
    target = sqlite3.connect(copy)
    try:
        source.backup(target)
    finally:
        source.close()
        target.close()
    return copy


def _open(db: Path, scratch: Path | None):
    if not db.is_file():
        raise AlertsError(f"{db}: no lab store there")
    handle = store_mod.Store(_snapshot(db, scratch) if scratch else db)
    handle.migrate()
    return handle


def main(argv: Sequence[str] | None = None, *, detector: Detector | None = None, github: GitHub | None = None,
         floors: FloorSource | None = None) -> int:
    parser = argparse.ArgumentParser(prog="alerts.py", description=__doc__.split("\n\n")[0])
    parser.add_argument("--subscriptions", type=Path, default=DEFAULT_SUBSCRIPTIONS)
    parser.add_argument("--targets", type=Path, default=DEFAULT_TARGETS)
    commands = parser.add_subparsers(dest="command", required=True)
    detect_cmd = commands.add_parser("detect", help="change points and target_miss on touched series")
    detect_cmd.add_argument("--db", type=Path, required=True)
    detect_cmd.add_argument("--series", action="append", help="a series key (repeat); default every series")
    detect_cmd.add_argument("--dry-run", action="store_true", help="run on a copy of the store")
    sync_cmd = commands.add_parser("sync-issues", help="issues for verified groups, one comment per state change")
    sync_cmd.add_argument("--db", type=Path, required=True)
    sync_cmd.add_argument("--repo", default=DEFAULT_REPO)
    sync_cmd.add_argument("--dashboard-url", required=True)
    sync_cmd.add_argument("--dry-run", action="store_true", help="print the GitHub writes instead of making them")
    groups_cmd = commands.add_parser("groups", help="list alert groups")
    groups_cmd.add_argument("--db", type=Path, required=True)
    groups_cmd.add_argument("--state", default="", help="comma-separated states")
    groups_cmd.add_argument("--json", action="store_true")
    commands.add_parser("check-subscriptions", help="validate subscriptions.json")
    args = parser.parse_args(argv)

    try:
        subscriptions = Subscriptions.load(args.subscriptions)
        if args.command == "check-subscriptions":
            targets = load_targets(args.targets)
            unknown = sorted({t for e in subscriptions.entries for t in e.targets if targets(t) is None})
            if unknown and args.targets.exists():
                raise AlertsError(f"{args.subscriptions}: targets not in {args.targets}: {unknown}")
            print(f"{len(subscriptions.entries)} subscriptions ok")
            return 0
        with tempfile.TemporaryDirectory(prefix="perf-lab-alerts-") as scratch:
            dry = getattr(args, "dry_run", False)
            store = _open(args.db, Path(scratch) if dry else None)
            try:
                if args.command == "detect":
                    report = detect(store, subscriptions, detector or CatapultDetector(), load_targets(args.targets),
                                    keys=args.series, floors=floors or load_floors())
                    print(json.dumps({"dry_run": dry, **report.to_dict()}, indent=2))
                elif args.command == "sync-issues":
                    client = github or GhClient(args.repo)
                    if dry:
                        client = RecordingGitHub(client)
                    report = sync_issues(store, subscriptions, client, repo=args.repo, dashboard_url=args.dashboard_url)
                    output = {"dry_run": dry, **report.to_dict()}
                    if isinstance(client, RecordingGitHub):
                        output["actions"] = client.actions
                    print(json.dumps(output, indent=2))
                else:
                    states = [s for s in args.state.split(",") if s]
                    unknown_states = sorted(set(states) - set(store_mod.ALERT_GROUP_STATES))
                    if unknown_states:
                        raise AlertsError(f"unknown states {unknown_states}")
                    groups = list_groups(store, subscriptions, states)
                    if args.json:
                        print(json.dumps(groups, indent=2))
                    else:
                        for group in groups:
                            print(f"{group['id']}\t{group['state']}\t{group['start_pos']}..{group['end_pos']}\t"
                                  f"{group['owner'] or '-'}\t{len(group['alerts'])} alerts")
            finally:
                store.close()
    except (AlertsError, store_mod.StoreError, sqlite3.Error) as error:
        print(f"alerts.py: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
