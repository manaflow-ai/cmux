#!/usr/bin/env python3
"""store.py: forward-only migrations, the series key and run/series reads on a temp WAL database.

  python3 -m unittest scripts/perf-lab/tests/test_store.py
"""
from __future__ import annotations

import importlib.util
import random
import sqlite3
import subprocess
import sys
import tempfile
import threading
import unittest
from dataclasses import replace
from datetime import datetime, timedelta, timezone
from pathlib import Path

STORE_PY = Path(__file__).resolve().parent.parent / "store.py"
_SPEC = importlib.util.spec_from_file_location("perf_lab_store", STORE_PY)
store = importlib.util.module_from_spec(_SPEC)
sys.modules[_SPEC.name] = store
_SPEC.loader.exec_module(store)

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
HOST = store.Host(name="cmux15", chip="Apple M4 Pro", memory_gb=24, display_hz=120, fingerprint="fp-1")
KEY_PARTS = dict(story="terminal.key-frame.light", metric="key_to_frame_ms", engine="webkit",
                 host_class=HOST.host_class, macos_major=26, build_config="bench")
KEY = store.series_key(**KEY_PARTS)

# Each child opens the store, waits for the parent's go file so all of them race, then migrates.
MIGRATE_CHILD = """
import importlib.util, sys, time
from pathlib import Path
spec = importlib.util.spec_from_file_location("perf_lab_store", sys.argv[1])
store = importlib.util.module_from_spec(spec); sys.modules[spec.name] = store; spec.loader.exec_module(store)
go = Path(sys.argv[3])
while not go.exists():
    time.sleep(0.001)
handle = store.Store(sys.argv[2])
print(handle.migrate())
handle.close()
"""


def build(pos: int, **changes) -> store.Build:
    return replace(store.Build(sha=f"{pos:040x}", config="bench", commit_pos=pos), **changes)


def run(uuid: str, *, kind: str = "waterfall", features_hash: str = "f0", macos_build: str = "26.1 (25B78)",
        started_at: datetime = NOW, measure_version: str = "m1") -> store.Run:
    return store.Run(run_uuid=uuid, kind=kind, measure_version=measure_version, story=KEY_PARTS["story"],
                     engine="webkit", macos_major=26, macos_build=macos_build, features_hash=features_hash,
                     safe_mode="off", started_at=started_at, features={"motion.pane.holdContent": "default"})


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

    def query(self, sql: str, *args) -> list[tuple]:
        db = sqlite3.connect(self.path)
        try:
            return db.execute(sql, args).fetchall()
        finally:
            db.close()

    def schema(self) -> list[tuple]:
        return self.query("SELECT type, name, sql FROM sqlite_master ORDER BY name")


class MigrationTests(StoreTestCase):
    def test_rerun_is_a_no_op(self) -> None:
        before = self.schema()
        self.assertEqual(self.store.migrate(), len(store.MIGRATIONS))
        self.store.close()
        self.store = self.open()
        self.assertEqual(self.store.migrate(), len(store.MIGRATIONS))
        self.assertEqual(self.schema(), before)
        self.assertEqual(self.query("SELECT COUNT(*) FROM schema_version"), [(len(store.MIGRATIONS),)])

    def test_concurrent_migrate_from_several_processes_applies_each_migration_once(self) -> None:
        for trial in range(5):
            with self.subTest(trial=trial), tempfile.TemporaryDirectory() as tmp:
                path, go = Path(tmp) / "lab.sqlite", Path(tmp) / "go"
                children = [subprocess.Popen([sys.executable, "-c", MIGRATE_CHILD, str(STORE_PY), str(path), str(go)],
                                             stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                            for _ in range(4)]
                go.touch()
                outputs = [child.communicate(timeout=60) for child in children]
                for child, (out, err) in zip(children, outputs):
                    self.assertEqual((child.returncode, out.strip()), (0, str(len(store.MIGRATIONS))), err)
                db = sqlite3.connect(path)
                self.assertEqual(db.execute("SELECT COUNT(*) FROM schema_version").fetchone()[0],
                                 len(store.MIGRATIONS))
                db.close()

    def test_a_second_handle_migrating_after_the_first_is_a_no_op(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "lab.sqlite"
            first, second = store.Store(path), store.Store(path)
            self.assertEqual(second.schema_version(), 0)
            self.assertEqual(first.migrate(), len(store.MIGRATIONS))
            self.assertEqual(second.migrate(), len(store.MIGRATIONS))
            first.close()
            second.close()

    def test_creates_every_lab_table_in_wal_mode(self) -> None:
        tables = {name for kind, name, _ in self.schema() if kind == "table"}
        self.assertLessEqual({"builds", "hosts", "runs", "results", "series", "annotations", "alerts",
                              "alert_groups", "jobs", "sheriff_history", "traces", "schema_version"}, tables)
        self.assertNotIn("expectations", tables)
        self.assertEqual(self.query("PRAGMA journal_mode"), [("wal",)])

    def test_applies_only_newer_migrations_and_refuses_a_newer_database(self) -> None:
        self.store.insert_run(run("r1"), build=build(1), host=HOST, metrics=[metric("a", [1.0])])
        next_version = len(store.MIGRATIONS) + 1
        newer = (*store.MIGRATIONS, (next_version, "run notes", ("ALTER TABLE runs ADD COLUMN note TEXT",)))
        self.store.close()
        self.store = self.open(newer)
        self.assertEqual(self.store.migrate(), next_version)
        self.assertEqual(self.store.migrate(), next_version)
        self.assertEqual(self.store.run_metrics("r1"), {"a": [1.0]})
        self.store.close()
        self.store = self.open()
        with self.assertRaisesRegex(store.StoreError, "newer than this store"):
            self.store.migrate()

    def test_refuses_an_applied_migration_whose_statements_changed(self) -> None:
        version, name, statements = store.MIGRATIONS[0]
        edited = ((version, name, (*statements, "CREATE INDEX runs_by_story ON runs (story)")),
                  *store.MIGRATIONS[1:])
        self.store.close()
        self.store = self.open(edited)
        with self.assertRaisesRegex(store.StoreError, "forward-only"):
            self.store.migrate()
        self.assertEqual(self.query("SELECT name FROM sqlite_master WHERE name = 'runs_by_story'"), [])

    def test_refuses_gaps_in_migration_versions(self) -> None:
        with self.assertRaises(store.StoreError):
            self.open((*store.MIGRATIONS, (len(store.MIGRATIONS) + 2, "gap", ())))


class SeriesKeyTests(StoreTestCase):
    def test_key_is_deterministic_and_covers_every_component(self) -> None:
        self.assertEqual(KEY, store.series_key(**dict(reversed(list(KEY_PARTS.items())))))
        self.assertRegex(KEY, r"^sk1:[0-9a-f]{32}$")
        changed = dict(story="x", metric="x", engine="chromium", host_class="apple-m4/16gb/60hz",
                       macos_major=27, build_config="bench-checks")
        for part, value in changed.items():
            self.assertNotEqual(store.series_key(**{**KEY_PARTS, part: value}), KEY, part)

    def test_features_hash_and_macos_build_are_point_metadata(self) -> None:
        self.store.insert_run(run("r1", features_hash="f0", macos_build="26.1 (25B78)"),
                              build=build(10), host=HOST, metrics=[metric("key_to_frame_ms", [4.0])])
        self.store.insert_run(run("r2", features_hash="f1", macos_build="26.2 (25C5)"),
                              build=build(11), host=HOST, metrics=[metric("key_to_frame_ms", [6.0])])
        points = self.store.series_points(KEY)
        self.assertEqual([(p.features_hash, p.macos_build, p.samples) for p in points],
                         [("f0", "26.1 (25B78)", [4.0]), ("f1", "26.2 (25C5)", [6.0])])
        self.assertEqual(self.query("SELECT COUNT(*) FROM series"), [(1,)])


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
        points = self.store.series_points(KEY)
        self.assertEqual([p.commit_pos for p in points], list(range(110, 160)))
        self.assertEqual([p.samples for p in points], [[float(pos)] for pos in range(110, 160)])

    def test_series_points_hold_only_waterfall_runs(self) -> None:
        self.store.insert_run(run("w1"), build=build(10), host=HOST, metrics=[metric("key_to_frame_ms", [4.0])])
        self.store.insert_run(run("w2"), build=build(12), host=HOST, metrics=[metric("key_to_frame_ms", [4.0])])
        for kind in ("bisect", "verify", "try", "aa", "reference"):
            self.store.insert_run(run(f"{kind}1", kind=kind), build=build(11), host=HOST,
                                  metrics=[metric("key_to_frame_ms", [9.0])])
        self.assertEqual([p.run_uuid for p in self.store.series_points(KEY)], ["w1", "w2"])
        with self.assertRaisesRegex(store.StoreError, "run kind"):
            self.store.insert_run(run("x", kind="pinpoint"), build=build(1), host=HOST,
                                  metrics=[metric("key_to_frame_ms", [1.0])])

    def test_repeats_at_one_commit_order_by_time_across_utc_offsets(self) -> None:
        later = datetime(2026, 10, 25, 13, 30, tzinfo=timezone(timedelta(hours=2)))  # 11:30 UTC
        earlier = datetime(2026, 10, 25, 11, 0, tzinfo=timezone.utc)
        latest = datetime(2026, 10, 25, 11, 45, 30, 250000, tzinfo=timezone.utc)
        for uuid, started in (("late", later), ("latest", latest), ("early", earlier)):
            self.store.insert_run(run(uuid, started_at=started), build=build(5), host=HOST,
                                  metrics=[metric("key_to_frame_ms", [1.0])])
        points = self.store.series_points(KEY)
        self.assertEqual([p.run_uuid for p in points], ["early", "late", "latest"])
        self.assertEqual(points[1].started_at, "2026-10-25T11:30:00.000000+00:00")
        with self.assertRaisesRegex(store.StoreError, "timezone"):
            self.store.insert_run(run("naive", started_at=datetime(2026, 10, 25, 11, 0)), build=build(5),
                                  host=HOST, metrics=[metric("key_to_frame_ms", [1.0])])

    def test_a_failed_run_writes_nothing(self) -> None:
        self.store.insert_run(run("r1"), build=build(1), host=HOST, metrics=[metric("key_to_frame_ms", [4.0])])
        with self.assertRaisesRegex(store.StoreError, "unit or direction"):
            self.store.insert_run(run("r2"), build=build(2), host=HOST,
                                  metrics=[metric("other", [1.0]), metric("key_to_frame_ms", [4.0], unit="s")])
        self.assertEqual(self.store.run_metrics("r2"), {})
        self.assertEqual(self.query("SELECT COUNT(*) FROM builds"), [(1,)])

    def test_replaying_a_run_is_a_no_op_and_a_changed_replay_is_refused(self) -> None:
        metrics = [metric("key_to_frame_ms", [4.0])]
        run_id = self.store.insert_run(run("r1"), build=build(1), host=HOST, metrics=metrics)
        self.assertEqual(self.store.insert_run(run("r1"), build=build(1), host=HOST, metrics=metrics), run_id)
        with self.assertRaisesRegex(store.StoreError, "already stored with other content"):
            self.store.insert_run(run("r1"), build=build(1), host=HOST, metrics=[metric("key_to_frame_ms", [5.0])])
        self.assertEqual(self.query("SELECT COUNT(*) FROM runs"), [(1,)])
        self.assertEqual(self.query("SELECT COUNT(*) FROM results"), [(1,)])


class BuildTests(StoreTestCase):
    def test_measure_version_belongs_to_the_run(self) -> None:
        self.store.insert_run(run("old", measure_version="m1"), build=build(5), host=HOST,
                              metrics=[metric("key_to_frame_ms", [4.0])])
        self.store.insert_run(run("remeasured", measure_version="m2"), build=build(5), host=HOST,
                              metrics=[metric("key_to_frame_ms", [4.0])])
        self.assertEqual([(p.run_uuid, p.measure_version) for p in self.store.series_points(KEY)],
                         [("old", "m1"), ("remeasured", "m2")])

    def test_a_different_commit_position_for_a_known_build_is_refused(self) -> None:
        self.store.insert_run(run("r1"), build=build(5), host=HOST, metrics=[metric("key_to_frame_ms", [4.0])])
        with self.assertRaisesRegex(store.StoreError, "commit position 999 differs from stored 5"):
            self.store.insert_run(run("r2"), build=build(5, commit_pos=999), host=HOST,
                                  metrics=[metric("key_to_frame_ms", [4.0])])
        self.assertEqual(self.query("SELECT commit_pos FROM builds"), [(5,)])

    def test_artifact_digest_is_recorded_once_and_a_different_one_is_refused(self) -> None:
        self.store.insert_run(run("r1"), build=build(5), host=HOST, metrics=[metric("key_to_frame_ms", [4.0])])
        self.store.insert_run(run("r2"), build=build(5, artifact_digest="sha256:a", built_at=NOW), host=HOST,
                              metrics=[metric("key_to_frame_ms", [4.0])])
        self.assertEqual(self.query("SELECT artifact_digest, built_at FROM builds"),
                         [("sha256:a", "2026-10-25T12:00:00.000000+00:00")])
        with self.assertRaisesRegex(store.StoreError, "artifact digest sha256:b differs"):
            self.store.insert_run(run("r3"), build=build(5, artifact_digest="sha256:b"), host=HOST,
                                  metrics=[metric("key_to_frame_ms", [4.0])])


class HostTests(StoreTestCase):
    def test_a_run_keeps_the_host_fingerprint_and_hz_it_was_measured_with(self) -> None:
        self.store.insert_run(run("a"), build=build(1), host=HOST, metrics=[metric("key_to_frame_ms", [4.0])])
        self.store.insert_run(run("b"), build=build(2), host=replace(HOST, fingerprint="fp-2"),
                              metrics=[metric("key_to_frame_ms", [4.0])])
        self.store.insert_run(run("c"), build=build(3), host=replace(HOST, fingerprint="fp-3", display_hz=60),
                              metrics=[metric("key_to_frame_ms", [4.0])])
        self.assertEqual([(p.run_uuid, p.host_name, p.host_fingerprint) for p in self.store.series_points(KEY)],
                         [("a", "cmux15", "fp-1"), ("b", "cmux15", "fp-2")])
        sixty = store.series_key(**{**KEY_PARTS, "host_class": "apple-m4-pro/24gb/60hz"})
        self.assertEqual([p.host_fingerprint for p in self.store.series_points(sixty)], ["fp-3"])
        self.assertEqual(self.query(
            "SELECT h.fingerprint, h.display_hz FROM runs u JOIN hosts h ON h.id = u.host_id WHERE u.run_uuid = 'a'"),
            [("fp-1", 120)])


class ThreadingTests(StoreTestCase):
    def test_one_store_per_thread_writes_concurrently_without_loss(self) -> None:
        errors: list[BaseException] = []

        def writer(thread: int) -> None:
            handle = self.open()
            try:
                for i in range(25):
                    pos = thread * 100 + i
                    handle.insert_run(run(f"t{thread}-{i}"), build=build(pos), host=HOST,
                                      metrics=[metric("key_to_frame_ms", [float(pos)])])
            except BaseException as error:  # surfaced to the test thread below
                errors.append(error)
            finally:
                handle.close()

        threads = [threading.Thread(target=writer, args=(t,)) for t in range(4)]
        for thread in threads:
            thread.start()
        for thread in threads:
            thread.join()
        self.assertEqual(errors, [])
        self.assertEqual(self.query("SELECT COUNT(*) FROM runs"), [(100,)])

    def test_a_store_refuses_use_from_another_thread(self) -> None:
        caught: list[BaseException] = []
        thread = threading.Thread(target=lambda: self._call_series_points(caught))
        thread.start()
        thread.join()
        self.assertEqual([type(error) for error in caught], [sqlite3.ProgrammingError])

    def _call_series_points(self, caught: list[BaseException]) -> None:
        try:
            self.store.series_points(KEY)
        except BaseException as error:
            caught.append(error)


class AnnotationTests(StoreTestCase):
    def test_annotations_on_one_series_and_on_all(self) -> None:
        self.store.insert_run(run("r1"), build=build(1), host=HOST, metrics=[metric("key_to_frame_ms", [4.0])])
        self.store.annotate(kind="features_hash", start_pos=1, end_pos=1, text="f0 -> f1", created_by="labd", key=KEY)
        self.store.annotate(kind="reference_drift", start_pos=0, end_pos=2, text="ref moved", created_by="labd")
        self.assertEqual([row["kind"] for row in self.store.annotations(KEY)], ["reference_drift", "features_hash"])
        with self.assertRaises(store.StoreError):
            self.store.annotate(kind="note", start_pos=1, end_pos=1, text="x", created_by="t", key="sk1:missing")


if __name__ == "__main__":
    unittest.main()
