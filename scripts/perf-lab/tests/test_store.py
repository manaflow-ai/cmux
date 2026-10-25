#!/usr/bin/env python3
"""store.py: forward-only migrations, the series key and run/series reads on a temp WAL database.

  python3 -m unittest scripts/perf-lab/tests/test_store.py
"""
from __future__ import annotations

import importlib.util
import random
import sqlite3
import sys
import tempfile
import unittest
from datetime import datetime, timezone
from pathlib import Path

_SPEC = importlib.util.spec_from_file_location("perf_lab_store", Path(__file__).resolve().parent.parent / "store.py")
store = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = store
_SPEC.loader.exec_module(store)

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
HOST = store.Host(name="cmux15", chip="Apple M4 Pro", memory_gb=24, display_hz=120, fingerprint="fp-1",
                  role="waterfall")
KEY_PARTS = dict(story="terminal.key-frame.light", metric="key_to_frame_ms", engine="webkit",
                 host_class=HOST.host_class, macos_major=26, build_config="bench")


def build(pos: int) -> store.Build:
    return store.Build(sha=f"{pos:040x}", config="bench", commit_pos=pos, measure_version="m1")


def run(uuid: str, *, features_hash: str = "f0", macos_build: str = "26.1 (25B78)", started_at: str = "") -> store.Run:
    return store.Run(run_uuid=uuid, story=KEY_PARTS["story"], engine="webkit", macos_major=26,
                     macos_build=macos_build, features_hash=features_hash, safe_mode="off",
                     started_at=started_at or NOW.isoformat(), features={"motion.pane.holdContent": "default"})


def metric(name: str, samples: list[float], unit: str = "ms") -> store.Metric:
    return store.Metric(name=name, unit=unit, better="lower", samples=samples)


class StoreTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / "lab.sqlite"
        self.store = self.open()
        self.store.migrate()

    def tearDown(self) -> None:
        self.store.close()
        self._tmp.cleanup()

    def open(self, migrations=store.MIGRATIONS) -> store.Store:
        return store.Store(self.path, migrations=migrations, clock=lambda: NOW)

    def schema(self) -> list[tuple]:
        db = sqlite3.connect(self.path)
        try:
            return db.execute("SELECT type, name, sql FROM sqlite_master ORDER BY name").fetchall()
        finally:
            db.close()


class MigrationTests(StoreTestCase):
    def test_rerun_is_a_no_op(self) -> None:
        before = self.schema()
        self.assertEqual(self.store.migrate(), len(store.MIGRATIONS))
        self.store.close()
        self.store = self.open()
        self.assertEqual(self.store.migrate(), len(store.MIGRATIONS))
        self.assertEqual(self.schema(), before)
        db = sqlite3.connect(self.path)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM schema_version").fetchone()[0], len(store.MIGRATIONS))
        db.close()

    def test_creates_every_lab_table_in_wal_mode(self) -> None:
        tables = {name for kind, name, _ in self.schema() if kind == "table"}
        self.assertLessEqual({"builds", "hosts", "runs", "results", "series", "annotations", "alerts",
                              "alert_groups", "jobs", "sheriff_history", "expectations", "traces",
                              "schema_version"}, tables)
        db = sqlite3.connect(self.path)
        self.assertEqual(db.execute("PRAGMA journal_mode").fetchone()[0], "wal")
        db.close()

    def test_applies_only_newer_migrations_and_refuses_a_newer_database(self) -> None:
        self.store.insert_run(run("r1"), build=build(1), host=HOST, metrics=[metric("a", [1.0])])
        newer = (*store.MIGRATIONS, (2, "run notes", ("ALTER TABLE runs ADD COLUMN note TEXT",)))
        self.store.close()
        self.store = self.open(newer)
        self.assertEqual(self.store.migrate(), 2)
        self.assertEqual(self.store.migrate(), 2)
        self.assertEqual(self.store.run_metrics("r1"), {"a": [1.0]})
        self.store.close()
        self.store = self.open()
        with self.assertRaisesRegex(store.StoreError, "newer than this store"):
            self.store.migrate()

    def test_refuses_gaps_in_migration_versions(self) -> None:
        with self.assertRaises(store.StoreError):
            self.open((*store.MIGRATIONS, (3, "gap", ())))


class SeriesKeyTests(StoreTestCase):
    def test_key_is_deterministic_and_covers_every_component(self) -> None:
        key = store.series_key(**KEY_PARTS)
        self.assertEqual(key, store.series_key(**dict(reversed(list(KEY_PARTS.items())))))
        self.assertRegex(key, r"^sk1:[0-9a-f]{32}$")
        changed = dict(story="x", metric="x", engine="chromium", host_class="apple-m4/16gb/60hz",
                       macos_major=27, build_config="bench-checks")
        for part, value in changed.items():
            self.assertNotEqual(store.series_key(**{**KEY_PARTS, part: value}), key, part)

    def test_features_hash_and_macos_build_are_point_metadata(self) -> None:
        self.store.insert_run(run("r1", features_hash="f0", macos_build="26.1 (25B78)"),
                              build=build(10), host=HOST, metrics=[metric("key_to_frame_ms", [4.0])])
        self.store.insert_run(run("r2", features_hash="f1", macos_build="26.2 (25C5)"),
                              build=build(11), host=HOST, metrics=[metric("key_to_frame_ms", [6.0])])
        points = self.store.series_points(store.series_key(**KEY_PARTS))
        self.assertEqual([(p.features_hash, p.macos_build, p.samples) for p in points],
                         [("f0", "26.1 (25B78)", [4.0]), ("f1", "26.2 (25C5)", [6.0])])
        db = sqlite3.connect(self.path)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM series").fetchone()[0], 1)
        db.close()


class RunTests(StoreTestCase):
    def test_insert_and_read_a_run_with_three_metrics(self) -> None:
        metrics = [metric("key_to_frame_ms", [4.1, 4.3, 5.0]), metric("dropped_frames", [0.0, 1.0], unit="count"),
                   metric("main_turn_ms", [2.0, 2.5, 3.0, 9.0])]
        run_id = self.store.insert_run(run("r1"), build=build(1), host=HOST, metrics=metrics)
        self.assertIsInstance(run_id, int)
        self.assertEqual(self.store.run_metrics("r1"), {m.name: list(m.samples) for m in metrics})

    def test_last_50_points_of_a_series_in_commit_order(self) -> None:
        positions = list(range(100, 160))
        random.Random(7).shuffle(positions)
        for pos in positions:
            self.store.insert_run(run(f"r{pos}"), build=build(pos), host=HOST,
                                  metrics=[metric("key_to_frame_ms", [float(pos)])])
        points = self.store.series_points(store.series_key(**KEY_PARTS))
        self.assertEqual([p.commit_pos for p in points], list(range(110, 160)))
        self.assertEqual([p.samples for p in points], [[float(pos)] for pos in range(110, 160)])

    def test_a_failed_run_writes_nothing(self) -> None:
        self.store.insert_run(run("r1"), build=build(1), host=HOST, metrics=[metric("key_to_frame_ms", [4.0])])
        with self.assertRaisesRegex(store.StoreError, "unit or direction"):
            self.store.insert_run(run("r2"), build=build(2), host=HOST,
                                  metrics=[metric("other", [1.0]), metric("key_to_frame_ms", [4.0], unit="s")])
        self.assertEqual(self.store.run_metrics("r2"), {})
        db = sqlite3.connect(self.path)
        self.assertEqual(db.execute("SELECT COUNT(*) FROM builds").fetchone()[0], 1)
        db.close()


class AnnotationTests(StoreTestCase):
    def test_annotations_on_one_series_and_on_all(self) -> None:
        self.store.insert_run(run("r1"), build=build(1), host=HOST, metrics=[metric("key_to_frame_ms", [4.0])])
        key = store.series_key(**KEY_PARTS)
        self.store.annotate(kind="features_hash", start_pos=1, end_pos=1, text="f0 -> f1", created_by="labd", key=key)
        self.store.annotate(kind="reference_drift", start_pos=0, end_pos=2, text="ref moved", created_by="labd")
        self.assertEqual([row["kind"] for row in self.store.annotations(key)], ["reference_drift", "features_hash"])
        with self.assertRaises(store.StoreError):
            self.store.annotate(kind="note", start_pos=1, end_pos=1, text="x", created_by="t", key="sk1:missing")


if __name__ == "__main__":
    unittest.main()
