#!/usr/bin/env python3
"""The perf lab's SQLite store: one WAL connection, forward-only versioned migrations.

Chromeperf keeps the same split (catapult `dashboard/dashboard/models/graph_data.py`): a
TestMetadata row per series (`test_path` = master/bot/suite/measurement/story) and one Row per
point keyed by revision. Here a series is (story, metric, engine, host class, macOS major,
build config) and a point is one result row ordered by the build's first-parent commit position
(Chromium's Cr-Commit-Position). The features hash, the full macOS build and the safe-mode state
are point metadata on the run, never part of the series key, so a features default flip is a
step inside one series (p12-perf-process.md 3.1).

The store takes plain records, not result-v1 documents: mapping `cmux-perf-result/v1`
(task 001, perf_result.py) onto these records is the ingest's job (task 005).
"""
from __future__ import annotations

import hashlib
import json
import sqlite3
from collections.abc import Callable, Sequence
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

SERIES_KEY_VERSION = "sk1"
ALERT_GROUP_STATES = (
    "new", "triaged", "bisecting", "culprit", "assigned",
    "fixed", "flag-off", "accepted", "invalid", "lab-drift",
)

Migration = tuple[int, str, tuple[str, ...]]

_STATES_SQL = ", ".join(f"'{state}'" for state in ALERT_GROUP_STATES)

MIGRATIONS: tuple[Migration, ...] = (
    (1, "initial lab schema", (
        """CREATE TABLE builds (
            id INTEGER PRIMARY KEY,
            sha TEXT NOT NULL,
            config TEXT NOT NULL CHECK (config IN ('bench', 'bench-checks', 'release', 'debug')),
            commit_pos INTEGER NOT NULL,
            measure_version TEXT NOT NULL,
            artifact_digest TEXT,
            built_at TEXT,
            UNIQUE (sha, config))""",
        """CREATE TABLE hosts (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL UNIQUE,
            host_class TEXT NOT NULL,
            chip TEXT NOT NULL,
            memory_gb INTEGER NOT NULL,
            display_hz INTEGER NOT NULL,
            role TEXT,
            fingerprint TEXT NOT NULL,
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL)""",
        f"""CREATE TABLE alert_groups (
            id INTEGER PRIMARY KEY,
            state TEXT NOT NULL CHECK (state IN ({_STATES_SQL})),
            start_pos INTEGER NOT NULL,
            end_pos INTEGER NOT NULL,
            culprit_sha TEXT,
            culprit_verified INTEGER NOT NULL DEFAULT 0,
            issue_number INTEGER,
            reason TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL)""",
        """CREATE TABLE jobs (
            id INTEGER PRIMARY KEY,
            controller_job_id TEXT UNIQUE,
            kind TEXT NOT NULL CHECK (kind IN ('waterfall', 'bisect', 'verify', 'try', 'aa', 'reference')),
            state TEXT NOT NULL,
            story TEXT,
            host_class TEXT,
            base_sha TEXT,
            head_sha TEXT,
            alert_group_id INTEGER REFERENCES alert_groups (id),
            params_json TEXT NOT NULL DEFAULT '{}',
            result_json TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL)""",
        """CREATE TABLE runs (
            id INTEGER PRIMARY KEY,
            run_uuid TEXT NOT NULL UNIQUE,
            build_id INTEGER NOT NULL REFERENCES builds (id),
            host_id INTEGER NOT NULL REFERENCES hosts (id),
            job_id INTEGER REFERENCES jobs (id),
            story TEXT NOT NULL,
            engine TEXT NOT NULL,
            tier TEXT,
            session TEXT,
            macos_major INTEGER NOT NULL,
            macos_build TEXT NOT NULL,
            features_hash TEXT NOT NULL,
            features_json TEXT NOT NULL DEFAULT '{}',
            safe_mode TEXT NOT NULL,
            attachments_json TEXT NOT NULL DEFAULT '[]',
            started_at TEXT NOT NULL,
            finished_at TEXT)""",
        """CREATE TABLE series (
            id INTEGER PRIMARY KEY,
            series_key TEXT NOT NULL UNIQUE,
            story TEXT NOT NULL,
            metric TEXT NOT NULL,
            engine TEXT NOT NULL,
            host_class TEXT NOT NULL,
            macos_major INTEGER NOT NULL,
            build_config TEXT NOT NULL,
            unit TEXT NOT NULL,
            better TEXT NOT NULL CHECK (better IN ('lower', 'higher')),
            target_ref TEXT)""",
        """CREATE TABLE results (
            id INTEGER PRIMARY KEY,
            run_id INTEGER NOT NULL REFERENCES runs (id),
            series_id INTEGER NOT NULL REFERENCES series (id),
            samples_json TEXT NOT NULL,
            summary_json TEXT,
            UNIQUE (run_id, series_id))""",
        "CREATE INDEX results_by_series ON results (series_id)",
        """CREATE TABLE annotations (
            id INTEGER PRIMARY KEY,
            series_id INTEGER REFERENCES series (id),
            kind TEXT NOT NULL CHECK (kind IN ('features_hash', 'macos_build', 'safe_mode', 'reference_drift', 'note')),
            start_pos INTEGER NOT NULL,
            end_pos INTEGER NOT NULL,
            text TEXT NOT NULL,
            created_by TEXT NOT NULL,
            created_at TEXT NOT NULL)""",
        "CREATE INDEX annotations_by_series ON annotations (series_id, start_pos)",
        """CREATE TABLE alerts (
            id INTEGER PRIMARY KEY,
            series_id INTEGER NOT NULL REFERENCES series (id),
            group_id INTEGER REFERENCES alert_groups (id),
            rule TEXT NOT NULL CHECK (rule IN ('edivisive', 'target_miss', 'harness_broken')),
            start_pos INTEGER NOT NULL,
            end_pos INTEGER NOT NULL,
            median_before REAL,
            median_after REAL,
            is_improvement INTEGER NOT NULL DEFAULT 0,
            created_at TEXT NOT NULL,
            UNIQUE (series_id, rule, start_pos, end_pos))""",
        f"""CREATE TABLE sheriff_history (
            id INTEGER PRIMARY KEY,
            group_id INTEGER NOT NULL REFERENCES alert_groups (id),
            from_state TEXT CHECK (from_state IN ({_STATES_SQL})),
            to_state TEXT NOT NULL CHECK (to_state IN ({_STATES_SQL})),
            actor TEXT NOT NULL,
            reason TEXT,
            at TEXT NOT NULL)""",
        """CREATE TABLE expectations (
            id INTEGER PRIMARY KEY,
            story TEXT NOT NULL,
            host TEXT NOT NULL,
            issue_url TEXT NOT NULL,
            expires_at TEXT NOT NULL,
            created_by TEXT NOT NULL,
            created_at TEXT NOT NULL,
            UNIQUE (story, host))""",
        """CREATE TABLE traces (
            id INTEGER PRIMARY KEY,
            run_id INTEGER REFERENCES runs (id),
            job_id INTEGER REFERENCES jobs (id),
            attempt INTEGER NOT NULL DEFAULT 0,
            kind TEXT NOT NULL CHECK (kind IN ('signpost', 'watchdog', 'daemon')),
            digest TEXT NOT NULL,
            url TEXT NOT NULL,
            bytes INTEGER NOT NULL,
            created_at TEXT NOT NULL)""",
    )),
)


class StoreError(RuntimeError):
    pass


def host_class(*, chip: str, memory_gb: int, display_hz: int) -> str:
    """The host-class part of a series key: chip + memory + display Hz (3.1)."""
    return f"{chip.strip().lower().replace(' ', '-')}/{int(memory_gb)}gb/{int(display_hz)}hz"


def series_key(*, story: str, metric: str, engine: str, host_class: str,
               macos_major: int, build_config: str) -> str:
    """A stable id for one series. Point metadata (features hash, macOS build, safe mode) is not an input."""
    parts = [story, metric, engine, host_class, int(macos_major), build_config]
    canonical = json.dumps(parts, separators=(",", ":"), ensure_ascii=False)
    return f"{SERIES_KEY_VERSION}:{hashlib.sha256(canonical.encode()).hexdigest()[:32]}"


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _stamp(moment: datetime) -> str:
    """UTC ISO-8601, so stored stamps compare as text."""
    return moment.astimezone(timezone.utc).isoformat(timespec="seconds")


@dataclass(frozen=True)
class Build:
    sha: str
    config: str
    commit_pos: int
    measure_version: str
    artifact_digest: str | None = None
    built_at: str | None = None


@dataclass(frozen=True)
class Host:
    name: str
    chip: str
    memory_gb: int
    display_hz: int
    fingerprint: str
    role: str | None = None

    @property
    def host_class(self) -> str:
        return host_class(chip=self.chip, memory_gb=self.memory_gb, display_hz=self.display_hz)


@dataclass(frozen=True)
class Metric:
    name: str
    unit: str
    better: str
    samples: Sequence[float]
    summary: dict[str, float] | None = None
    target_ref: str | None = None


@dataclass(frozen=True)
class Run:
    run_uuid: str
    story: str
    engine: str
    macos_major: int
    macos_build: str
    features_hash: str
    safe_mode: str
    started_at: str
    features: dict[str, object] = field(default_factory=dict)
    attachments: Sequence[object] = ()
    tier: str | None = None
    session: str | None = None
    job_id: int | None = None
    finished_at: str | None = None


@dataclass(frozen=True)
class Point:
    commit_pos: int
    sha: str
    run_uuid: str
    started_at: str
    samples: list[float]
    summary: dict[str, float] | None
    features_hash: str
    macos_build: str
    safe_mode: str


class Store:
    """The lab's only database handle. labd composes one and passes it to every reader and writer."""

    def __init__(self, path: Path | str, *, migrations: Sequence[Migration] = MIGRATIONS,
                 clock: Callable[[], datetime] = utc_now) -> None:
        self._migrations = tuple(sorted(migrations))
        if [version for version, _, _ in self._migrations] != list(range(1, len(self._migrations) + 1)):
            raise StoreError("migration versions must be 1..n with no gaps or repeats")
        self._clock = clock
        self._db = sqlite3.connect(str(path), isolation_level=None)
        self._db.row_factory = sqlite3.Row
        mode = self._db.execute("PRAGMA journal_mode=WAL").fetchone()[0]
        if mode != "wal":
            self._db.close()
            raise StoreError(f"{path}: journal_mode is {mode}, the lab store needs WAL")
        self._db.execute("PRAGMA foreign_keys=ON")
        self._db.execute("PRAGMA busy_timeout=5000")

    def close(self) -> None:
        self._db.close()

    def _now(self) -> str:
        return _stamp(self._clock())

    def _write(self, statements: Callable[[], object]) -> object:
        self._db.execute("BEGIN IMMEDIATE")
        try:
            result = statements()
        except BaseException:
            self._db.execute("ROLLBACK")
            raise
        self._db.execute("COMMIT")
        return result

    def schema_version(self) -> int:
        exists = self._db.execute(
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'schema_version'").fetchone()
        if not exists:
            return 0
        return self._db.execute("SELECT COALESCE(MAX(version), 0) FROM schema_version").fetchone()[0]

    def migrate(self) -> int:
        """Applies each migration newer than the database's version, each in its own transaction."""
        self._db.execute("""CREATE TABLE IF NOT EXISTS schema_version (
            version INTEGER PRIMARY KEY, name TEXT NOT NULL, applied_at TEXT NOT NULL)""")
        current = self.schema_version()
        known = self._migrations[-1][0] if self._migrations else 0
        if current > known:
            raise StoreError(f"database schema {current} is newer than this store ({known}); deploy a newer labd")
        for version, name, statements in self._migrations:
            if version <= current:
                continue

            def apply(version: int = version, name: str = name, statements: tuple[str, ...] = statements) -> None:
                for statement in statements:
                    self._db.execute(statement)
                self._db.execute("INSERT INTO schema_version VALUES (?, ?, ?)", (version, name, self._now()))

            self._write(apply)
        return self.schema_version()

    def _build_id(self, build: Build) -> int:
        self._db.execute(
            """INSERT INTO builds (sha, config, commit_pos, measure_version, artifact_digest, built_at)
               VALUES (?, ?, ?, ?, ?, ?) ON CONFLICT (sha, config) DO NOTHING""",
            (build.sha, build.config, build.commit_pos, build.measure_version, build.artifact_digest, build.built_at))
        return self._db.execute(
            "SELECT id FROM builds WHERE sha = ? AND config = ?", (build.sha, build.config)).fetchone()[0]

    def _host_id(self, host: Host) -> int:
        now = self._now()
        self._db.execute(
            """INSERT INTO hosts (name, host_class, chip, memory_gb, display_hz, role, fingerprint, first_seen, last_seen)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (name) DO UPDATE SET host_class = excluded.host_class, chip = excluded.chip,
                 memory_gb = excluded.memory_gb, display_hz = excluded.display_hz, role = excluded.role,
                 fingerprint = excluded.fingerprint, last_seen = excluded.last_seen""",
            (host.name, host.host_class, host.chip, host.memory_gb, host.display_hz, host.role,
             host.fingerprint, now, now))
        return self._db.execute("SELECT id FROM hosts WHERE name = ?", (host.name,)).fetchone()[0]

    def _series_id(self, run: Run, host: Host, build: Build, metric: Metric) -> int:
        key = series_key(story=run.story, metric=metric.name, engine=run.engine, host_class=host.host_class,
                         macos_major=run.macos_major, build_config=build.config)
        self._db.execute(
            """INSERT INTO series (series_key, story, metric, engine, host_class, macos_major, build_config,
                                   unit, better, target_ref)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (series_key) DO NOTHING""",
            (key, run.story, metric.name, run.engine, host.host_class, run.macos_major, build.config,
             metric.unit, metric.better, metric.target_ref))
        row = self._db.execute("SELECT id, unit, better FROM series WHERE series_key = ?", (key,)).fetchone()
        if (row["unit"], row["better"]) != (metric.unit, metric.better):
            raise StoreError(f"{run.story}/{metric.name}: unit or direction differs from series {key}")
        return row["id"]

    def insert_run(self, run: Run, *, build: Build, host: Host, metrics: Sequence[Metric]) -> int:
        """Stores one story run and its metrics in one transaction; returns the run id."""
        if not metrics:
            raise StoreError(f"{run.run_uuid}: a run needs at least one metric")

        def write() -> int:
            run_id = self._db.execute(
                """INSERT INTO runs (run_uuid, build_id, host_id, job_id, story, engine, tier, session, macos_major,
                                     macos_build, features_hash, features_json, safe_mode, attachments_json,
                                     started_at, finished_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (run.run_uuid, self._build_id(build), self._host_id(host), run.job_id, run.story, run.engine,
                 run.tier, run.session, run.macos_major, run.macos_build, run.features_hash,
                 json.dumps(run.features, sort_keys=True), run.safe_mode, json.dumps(list(run.attachments)),
                 run.started_at, run.finished_at)).lastrowid
            for metric in metrics:
                self._db.execute(
                    "INSERT INTO results (run_id, series_id, samples_json, summary_json) VALUES (?, ?, ?, ?)",
                    (run_id, self._series_id(run, host, build, metric), json.dumps(list(metric.samples)),
                     json.dumps(metric.summary, sort_keys=True) if metric.summary is not None else None))
            return run_id

        return self._write(write)

    def run_metrics(self, run_uuid: str) -> dict[str, list[float]]:
        rows = self._db.execute(
            """SELECT s.metric, r.samples_json FROM results r JOIN runs u ON u.id = r.run_id
               JOIN series s ON s.id = r.series_id WHERE u.run_uuid = ? ORDER BY r.id""", (run_uuid,))
        return {row["metric"]: json.loads(row["samples_json"]) for row in rows}

    def series_points(self, key: str, *, limit: int = 50) -> list[Point]:
        """The newest `limit` points of a series, oldest first, in commit order."""
        rows = self._db.execute(
            """SELECT b.commit_pos, b.sha, u.run_uuid, u.started_at, r.samples_json, r.summary_json,
                      u.features_hash, u.macos_build, u.safe_mode
               FROM results r JOIN series s ON s.id = r.series_id JOIN runs u ON u.id = r.run_id
               JOIN builds b ON b.id = u.build_id
               WHERE s.series_key = ? ORDER BY b.commit_pos DESC, u.started_at DESC, r.id DESC LIMIT ?""",
            (key, limit)).fetchall()
        return [Point(row["commit_pos"], row["sha"], row["run_uuid"], row["started_at"],
                      json.loads(row["samples_json"]),
                      json.loads(row["summary_json"]) if row["summary_json"] is not None else None,
                      row["features_hash"], row["macos_build"], row["safe_mode"]) for row in reversed(rows)]

    def annotate(self, *, kind: str, start_pos: int, end_pos: int, text: str, created_by: str,
                 key: str | None = None) -> int:
        """A dashboard note on one series, or on every series when `key` is None."""
        def write() -> int:
            series_id = None
            if key is not None:
                row = self._db.execute("SELECT id FROM series WHERE series_key = ?", (key,)).fetchone()
                if row is None:
                    raise StoreError(f"no series {key}")
                series_id = row[0]
            return self._db.execute(
                """INSERT INTO annotations (series_id, kind, start_pos, end_pos, text, created_by, created_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?)""",
                (series_id, kind, start_pos, end_pos, text, created_by, self._now())).lastrowid

        return self._write(write)

    def annotations(self, key: str) -> list[sqlite3.Row]:
        return self._db.execute(
            """SELECT a.* FROM annotations a LEFT JOIN series s ON s.id = a.series_id
               WHERE a.series_id IS NULL OR s.series_key = ? ORDER BY a.start_pos, a.id""", (key,)).fetchall()
