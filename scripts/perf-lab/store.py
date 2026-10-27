#!/usr/bin/env python3
"""The perf lab's SQLite store: WAL, one connection per thread, forward-only versioned migrations.

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

import fcntl
import hashlib
import json
import sqlite3
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path

SERIES_KEY_VERSION = "sk1"
ALERT_GROUP_STATES = (
    "new", "triaged", "bisecting", "culprit", "assigned",
    "fixed", "flag-off", "accepted", "invalid", "lab-drift",
)
# What a run was for. Only waterfall runs are series points; bisect, verify, try, A/A and reference
# attempts share a series key on pinpoint hosts with the same host class (3.1, 3.6) but are job data.
RUN_KINDS = ("waterfall", "bisect", "verify", "try", "aa", "reference")

Migration = tuple[int, str, tuple[str, ...]]

_STATES_SQL = ", ".join(f"'{state}'" for state in ALERT_GROUP_STATES)
_KINDS_SQL = ", ".join(f"'{kind}'" for kind in RUN_KINDS)

MIGRATIONS: tuple[Migration, ...] = (
    (1, "initial lab schema", (
        """CREATE TABLE builds (
            id INTEGER PRIMARY KEY,
            sha TEXT NOT NULL,
            config TEXT NOT NULL CHECK (config IN ('bench', 'bench-checks', 'release', 'debug')),
            commit_pos INTEGER NOT NULL,
            artifact_digest TEXT,
            built_at TEXT,
            UNIQUE (sha, config))""",
        """CREATE TABLE hosts (
            id INTEGER PRIMARY KEY,
            name TEXT NOT NULL,
            host_class TEXT NOT NULL,
            chip TEXT NOT NULL,
            memory_gb INTEGER NOT NULL,
            display_hz INTEGER NOT NULL,
            fingerprint TEXT NOT NULL,
            first_seen TEXT NOT NULL,
            last_seen TEXT NOT NULL,
            UNIQUE (name, chip, memory_gb, display_hz, fingerprint))""",
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
        f"""CREATE TABLE jobs (
            id INTEGER PRIMARY KEY,
            controller_job_id TEXT UNIQUE,
            kind TEXT NOT NULL CHECK (kind IN ({_KINDS_SQL})),
            state TEXT NOT NULL,
            story TEXT,
            host_class TEXT,
            base_sha TEXT,
            head_sha TEXT,
            alert_group_id INTEGER REFERENCES alert_groups (id),
            params_json TEXT NOT NULL DEFAULT '{{}}',
            result_json TEXT,
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL)""",
        f"""CREATE TABLE runs (
            id INTEGER PRIMARY KEY,
            run_uuid TEXT NOT NULL UNIQUE,
            content_digest TEXT NOT NULL,
            kind TEXT NOT NULL CHECK (kind IN ({_KINDS_SQL})),
            build_id INTEGER NOT NULL REFERENCES builds (id),
            host_id INTEGER NOT NULL REFERENCES hosts (id),
            job_id INTEGER REFERENCES jobs (id),
            measure_version TEXT NOT NULL,
            story TEXT NOT NULL,
            engine TEXT NOT NULL,
            tier TEXT,
            session TEXT,
            macos_major INTEGER NOT NULL,
            macos_build TEXT NOT NULL,
            features_hash TEXT NOT NULL,
            features_json TEXT NOT NULL DEFAULT '{{}}',
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
    # A sheriff's claim on a group is not a state change, so it lives on the group, not in sheriff_history.
    (2, "sheriff claims", (
        "ALTER TABLE alert_groups ADD COLUMN holder TEXT",
        "ALTER TABLE alert_groups ADD COLUMN held_at TEXT",
    )),
    # A run names its attachments by digest (runs.attachments_json). The bytes of the ones ingest finds next to the
    # results are kept here by that digest, so a reader away from the host that wrote them (the MQ15 queue's
    # `lab.py queue typecheck --latest`) gets them; a trace stays in R2 (traces).
    (3, "attachment bytes", (
        """CREATE TABLE attachments (
            digest TEXT PRIMARY KEY,
            kind TEXT NOT NULL,
            bytes BLOB NOT NULL,
            stored_at TEXT NOT NULL)""",
    )),
    # What each waterfall story run said (harness_alerts.py, task 214): an errored story stores no result row, so
    # its errors live here, one row per (story, host, batch, status). A pass with results also has its results rows.
    (4, "story outcomes", (
        """CREATE TABLE story_outcomes (
            id INTEGER PRIMARY KEY,
            story TEXT NOT NULL,
            host_class TEXT NOT NULL,
            host TEXT NOT NULL,
            batch_pos INTEGER NOT NULL,
            sha TEXT NOT NULL,
            status TEXT NOT NULL CHECK (status IN ('pass', 'error', 'env-invalid')),
            reason TEXT NOT NULL DEFAULT '',
            recorded_at TEXT NOT NULL,
            UNIQUE (story, host_class, host, batch_pos, status))""",
        "CREATE INDEX story_outcomes_by_story ON story_outcomes (story, host_class, batch_pos)",
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


def migration_digest(name: str, statements: Sequence[str]) -> str:
    """What schema_version records per migration, so an edited applied migration is refused."""
    return hashlib.sha256(json.dumps([name, list(statements)]).encode()).hexdigest()


def utc_now() -> datetime:
    return datetime.now(timezone.utc)


def _stamp(moment: datetime) -> str:
    """Fixed-width UTC ISO-8601, so stored stamps compare as text in time order."""
    if moment.tzinfo is None or moment.utcoffset() is None:
        raise StoreError(f"{moment.isoformat()}: a stored time needs a timezone")
    return moment.astimezone(timezone.utc).isoformat(timespec="microseconds")


def _optional_stamp(moment: datetime | None) -> str | None:
    return None if moment is None else _stamp(moment)


@dataclass(frozen=True)
class Build:
    sha: str
    config: str
    commit_pos: int
    artifact_digest: str | None = None
    built_at: datetime | None = None


@dataclass(frozen=True)
class Host:
    name: str
    chip: str
    memory_gb: int
    display_hz: int
    fingerprint: str

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
    kind: str
    measure_version: str
    story: str
    engine: str
    macos_major: int
    macos_build: str
    features_hash: str
    safe_mode: str
    started_at: datetime
    features: dict[str, object] = field(default_factory=dict)
    attachments: Sequence[object] = ()
    tier: str | None = None
    session: str | None = None
    job_id: int | None = None
    finished_at: datetime | None = None


@dataclass(frozen=True)
class Point:
    commit_pos: int
    sha: str
    run_uuid: str
    started_at: str
    measure_version: str
    samples: list[float]
    summary: dict[str, float] | None
    features_hash: str
    macos_build: str
    safe_mode: str
    host_name: str
    host_fingerprint: str


def _content_digest(run: Run, build: Build, host: Host, metrics: Sequence[Metric]) -> str:
    """Identifies one ingest of a run: a replay of the same run is a no-op, a different one is refused."""
    record = {
        "run": {**asdict(run), "started_at": _stamp(run.started_at), "finished_at": _optional_stamp(run.finished_at),
                "attachments": list(run.attachments)},
        "build": {**asdict(build), "built_at": _optional_stamp(build.built_at)},
        "host": asdict(host),
        "metrics": [{**asdict(metric), "samples": list(metric.samples)} for metric in metrics],
    }
    return hashlib.sha256(json.dumps(record, sort_keys=True, default=str).encode()).hexdigest()


class Store:
    """One SQLite connection, owned by the thread that opened it (sqlite3 refuses use from another thread).

    labd opens one Store per thread: WAL lets readers run beside the single writer, and every write takes
    BEGIN IMMEDIATE, so writers in other threads or processes wait on busy_timeout instead of interleaving.
    """

    def __init__(self, path: Path | str, *, migrations: Sequence[Migration] = MIGRATIONS,
                 clock: Callable[[], datetime] = utc_now, busy_timeout_ms: int = 5000) -> None:
        self._migrations = tuple(sorted(migrations))
        if [version for version, _, _ in self._migrations] != list(range(1, len(self._migrations) + 1)):
            raise StoreError("migration versions must be 1..n with no gaps or repeats")
        self._clock = clock
        self._db = sqlite3.connect(str(path), isolation_level=None, timeout=busy_timeout_ms / 1000)
        self._db.row_factory = sqlite3.Row
        # SQLite answers a racing switch into WAL with SQLITE_BUSY and no busy wait; the flock serializes openers.
        with open(f"{path}.open-lock", "a") as guard:
            fcntl.flock(guard, fcntl.LOCK_EX)
            mode = self._db.execute("PRAGMA journal_mode=WAL").fetchone()[0]
        if mode != "wal":
            self._db.close()
            raise StoreError(f"{path}: journal_mode is {mode}, the lab store needs WAL")
        self._db.execute("PRAGMA foreign_keys=ON")

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
        """Applies every migration newer than the database in one write transaction; returns the version.

        The applied versions are read under the write lock, so concurrent migrate() calls (labd and a
        lab.py CLI) apply each migration once and the later callers find it applied.
        """
        def apply() -> int:
            self._db.execute("""CREATE TABLE IF NOT EXISTS schema_version (
                version INTEGER PRIMARY KEY, name TEXT NOT NULL, digest TEXT NOT NULL, applied_at TEXT NOT NULL)""")
            applied = {row["version"]: row for row in self._db.execute("SELECT * FROM schema_version")}
            known = len(self._migrations)
            if applied and max(applied) > known:
                raise StoreError(f"database schema {max(applied)} is newer than this store ({known}); "
                                 "deploy a newer labd")
            for version, name, statements in self._migrations:
                digest = migration_digest(name, statements)
                row = applied.get(version)
                if row is not None:
                    if (row["name"], row["digest"]) != (name, digest):
                        raise StoreError(f"migration {version} ({row['name']}) was applied with other statements; "
                                         "migrations are forward-only, add a new one")
                    continue
                for statement in statements:
                    self._db.execute(statement)
                self._db.execute("INSERT INTO schema_version VALUES (?, ?, ?, ?)",
                                 (version, name, digest, self._now()))
            return known

        return self._write(apply)

    def _build_id(self, build: Build) -> int:
        """One row per (sha, config). A different commit position or artifact digest is an ingest bug: refused."""
        row = self._db.execute(
            "SELECT id, commit_pos, artifact_digest FROM builds WHERE sha = ? AND config = ?",
            (build.sha, build.config)).fetchone()
        if row is None:
            return self._db.execute(
                "INSERT INTO builds (sha, config, commit_pos, artifact_digest, built_at) VALUES (?, ?, ?, ?, ?)",
                (build.sha, build.config, build.commit_pos, build.artifact_digest,
                 _optional_stamp(build.built_at))).lastrowid
        if row["commit_pos"] != build.commit_pos:
            raise StoreError(f"{build.sha} ({build.config}): commit position {build.commit_pos} differs from "
                             f"stored {row['commit_pos']}")
        if None not in (row["artifact_digest"], build.artifact_digest) and row["artifact_digest"] != build.artifact_digest:
            raise StoreError(f"{build.sha} ({build.config}): artifact digest {build.artifact_digest} differs "
                             f"from stored {row['artifact_digest']}")
        self._db.execute(
            "UPDATE builds SET artifact_digest = COALESCE(artifact_digest, ?), built_at = COALESCE(built_at, ?) "
            "WHERE id = ?", (build.artifact_digest, _optional_stamp(build.built_at), row["id"]))
        return row["id"]

    def _host_id(self, host: Host) -> int:
        """One immutable row per host configuration; only last_seen moves, so a run keeps the fingerprint and Hz it had."""
        now = self._now()
        return self._db.execute(
            """INSERT INTO hosts (name, host_class, chip, memory_gb, display_hz, fingerprint, first_seen, last_seen)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?)
               ON CONFLICT (name, chip, memory_gb, display_hz, fingerprint) DO UPDATE SET last_seen = excluded.last_seen
               RETURNING id""",
            (host.name, host.host_class, host.chip, host.memory_gb, host.display_hz, host.fingerprint,
             now, now)).fetchone()[0]

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
        """Stores one story run and its metrics in one transaction; returns the run id.

        The same run_uuid with the same content (an ingest retry or a history re-import) returns the
        stored id and writes nothing; the same run_uuid with other content is refused.
        """
        if not metrics:
            raise StoreError(f"{run.run_uuid}: a run needs at least one metric")
        if run.kind not in RUN_KINDS:
            raise StoreError(f"{run.run_uuid}: run kind {run.kind!r} is not one of {RUN_KINDS}")
        digest = _content_digest(run, build, host, metrics)

        def write() -> int:
            stored = self._db.execute("SELECT id, content_digest FROM runs WHERE run_uuid = ?",
                                      (run.run_uuid,)).fetchone()
            if stored is not None:
                if stored["content_digest"] != digest:
                    raise StoreError(f"{run.run_uuid}: run already stored with other content")
                return stored["id"]
            run_id = self._db.execute(
                """INSERT INTO runs (run_uuid, content_digest, kind, build_id, host_id, job_id, measure_version, story,
                                     engine, tier, session, macos_major, macos_build, features_hash, features_json,
                                     safe_mode, attachments_json, started_at, finished_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (run.run_uuid, digest, run.kind, self._build_id(build), self._host_id(host), run.job_id,
                 run.measure_version, run.story, run.engine, run.tier, run.session, run.macos_major, run.macos_build,
                 run.features_hash, json.dumps(run.features, sort_keys=True), run.safe_mode,
                 json.dumps(list(run.attachments)), _stamp(run.started_at),
                 _optional_stamp(run.finished_at))).lastrowid
            for metric in metrics:
                self._db.execute(
                    "INSERT INTO results (run_id, series_id, samples_json, summary_json) VALUES (?, ?, ?, ?)",
                    (run_id, self._series_id(run, host, build, metric), json.dumps(list(metric.samples)),
                     json.dumps(metric.summary, sort_keys=True) if metric.summary is not None else None))
            return run_id

        return self._write(write)

    def keep_attachment(self, kind: str, data: bytes) -> str:
        """Keeps DATA under its digest ("sha256:<hex>", perf_result.Attachment's form); a second copy is a no-op."""
        digest = f"sha256:{hashlib.sha256(data).hexdigest()}"
        self._write(lambda: self._db.execute(
            "INSERT INTO attachments (digest, kind, bytes, stored_at) VALUES (?, ?, ?, ?) ON CONFLICT (digest) DO NOTHING",
            (digest, kind, data, self._now())))
        return digest

    def attachment(self, digest: str) -> bytes | None:
        row = self._db.execute("SELECT bytes FROM attachments WHERE digest = ?", (digest,)).fetchone()
        return None if row is None else bytes(row["bytes"])

    def latest_run(self, story: str, *, kind: str = "waterfall") -> sqlite3.Row | None:
        """The newest stored run of `story` of `kind`, by mainline commit position, then start time: run_uuid,
        started_at, attachments_json, sha and commit_pos. None when the store has none."""
        return self._db.execute(
            """SELECT u.run_uuid, u.started_at, u.attachments_json, b.sha, b.commit_pos
               FROM runs u JOIN builds b ON b.id = u.build_id WHERE u.story = ? AND u.kind = ?
               ORDER BY b.commit_pos DESC, u.started_at DESC, u.id DESC LIMIT 1""", (story, kind)).fetchone()

    def run_metrics(self, run_uuid: str) -> dict[str, list[float]]:
        rows = self._db.execute(
            """SELECT s.metric, r.samples_json FROM results r JOIN runs u ON u.id = r.run_id
               JOIN series s ON s.id = r.series_id WHERE u.run_uuid = ? ORDER BY r.id""", (run_uuid,))
        return {row["metric"]: json.loads(row["samples_json"]) for row in rows}

    def series_points(self, key: str, *, limit: int = 50) -> list[Point]:
        """The newest `limit` waterfall points of a series, oldest first, in commit order."""
        rows = self._db.execute(
            """SELECT b.commit_pos, b.sha, u.run_uuid, u.started_at, u.measure_version, r.samples_json,
                      r.summary_json, u.features_hash, u.macos_build, u.safe_mode, h.name, h.fingerprint
               FROM results r JOIN series s ON s.id = r.series_id JOIN runs u ON u.id = r.run_id
               JOIN builds b ON b.id = u.build_id JOIN hosts h ON h.id = u.host_id
               WHERE s.series_key = ? AND u.kind = 'waterfall'
               ORDER BY b.commit_pos DESC, u.started_at DESC, r.id DESC LIMIT ?""",
            (key, limit)).fetchall()
        return [Point(row["commit_pos"], row["sha"], row["run_uuid"], row["started_at"], row["measure_version"],
                      json.loads(row["samples_json"]),
                      json.loads(row["summary_json"]) if row["summary_json"] is not None else None,
                      row["features_hash"], row["macos_build"], row["safe_mode"], row["name"], row["fingerprint"])
                for row in reversed(rows)]

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

    # ---------- labd (task 012): the controller's job callback, read endpoints and the nightly backup ----------

    def finish_job(self, controller_job_id: str, *, state: str, result: object = None) -> bool:
        """Records a controller job's end state on the lab job that submitted it; False when no lab job has that id."""
        def write() -> bool:
            return self._db.execute(
                "UPDATE jobs SET state = ?, result_json = ?, updated_at = ? WHERE controller_job_id = ?",
                (state, None if result is None else json.dumps(result, sort_keys=True), self._now(),
                 controller_job_id)).rowcount > 0

        return self._write(write)

    def list_series(self, *, story: str | None = None) -> list[sqlite3.Row]:
        """Every series (one story's with `story`), with its waterfall point count and newest commit position."""
        return self._db.execute(
            """SELECT s.*, COUNT(u.id) AS points, MAX(b.commit_pos) AS newest_pos
               FROM series s LEFT JOIN results r ON r.series_id = s.id
               LEFT JOIN runs u ON u.id = r.run_id AND u.kind = 'waterfall' LEFT JOIN builds b ON b.id = u.build_id
               WHERE ? IS NULL OR s.story = ? GROUP BY s.id ORDER BY s.story, s.metric, s.id""",
            (story, story)).fetchall()

    def jobs(self, *, limit: int = 100) -> list[sqlite3.Row]:
        """The newest `limit` lab jobs, newest first."""
        return self._db.execute("SELECT * FROM jobs ORDER BY updated_at DESC, id DESC LIMIT ?", (limit,)).fetchall()

    def coverage(self) -> list[sqlite3.Row]:
        """Per story, host class and build config: waterfall run count and the newest measured commit."""
        return self._db.execute(
            """SELECT u.story, h.host_class, b.config AS build_config, COUNT(*) AS runs,
                      MAX(b.commit_pos) AS newest_pos, MAX(u.started_at) AS newest_started_at
               FROM runs u JOIN hosts h ON h.id = u.host_id JOIN builds b ON b.id = u.build_id
               WHERE u.kind = 'waterfall' GROUP BY u.story, h.host_class, b.config
               ORDER BY u.story, h.host_class, b.config""").fetchall()

    def backup_to(self, path: Path | str) -> None:
        """A consistent copy of the whole store (WAL included) at `path`, by SQLite's online backup."""
        target = sqlite3.connect(str(path))
        try:
            self._db.backup(target)
        finally:
            target.close()
