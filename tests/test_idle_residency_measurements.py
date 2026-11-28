#!/usr/bin/env python3
"""Offline replay and process-census regression fixtures; no live daemon required."""
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
from types import SimpleNamespace

ROOT = Path(__file__).resolve().parents[1]


def module(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT / path)
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


replay = module("idle_replay", "scripts/measure/idle-replay.py")
residents = module("idle_residents", "scripts/measure/idle-residents.py")
MIN = 60_000


class ReplayTests(unittest.TestCase):
    def test_actual_adaptive_policy(self):
        cases = [([], 0, 2 * MIN), ([], 1, 15_000),
                 ([MIN], 0, 30 * MIN), ([11 * MIN], 0, 15_000),
                 ([10 * MIN], 0, 30 * MIN),
                 ([MIN, 30 * MIN], 0, 30 * MIN),
                 ([MIN] * 30 + [20 * MIN] * 20, 0, 15_000)]
        for history, pending, expected in cases:
            with self.subTest(history=history, pending=pending):
                self.assertEqual(replay.adaptive_v1({"history": history,
                    "bg_notifying_count": pending, "wait_pending": True}), expected)
        self.assertEqual(replay.adaptive_v1({"history": []}, base=MIN), MIN)

    def capture(self, folder, **metadata):
        doc = {"sessionId": "chat", "peer": "host", "turns": [
            {"startedAt": MIN, "endedAt": 2 * MIN},
            {"startedAt": 12 * MIN, "endedAt": 13 * MIN}]}
        doc.update(metadata)
        Path(folder, "chat.json").write_text(json.dumps(doc))

    def test_saved_capture_never_grows_with_wall_clock(self):
        with tempfile.TemporaryDirectory() as folder:
            self.capture(folder, observedAt=120 * MIN, open=True)
            first = replay.run(folder, 1000, 400, 120 * MIN, 10)
            later = replay.run(folder, 1000, 400, 1560 * MIN, 10)
            self.assertEqual(first, later)
            self.assertEqual(first["gaps"], 2)
            self.assertEqual(first["idle_session_hours"], 1.9)
            self.assertEqual(first["adaptive_v1_missing_background_counts"], 2)
            self.assertEqual(sum(r["family"] == "adaptive-v1" for r in first["dynamic"]), 1)
            clipped = replay.gaps(replay.load(folder), 20 * MIN)
            self.assertEqual(clipped[-1]["g"], 7 * MIN)

    def test_legacy_and_closed_captures_have_no_trailing_gap(self):
        with tempfile.TemporaryDirectory() as folder:
            for meta in ({}, {"observedAt": 120 * MIN, "open": False}):
                self.capture(folder, **meta)
                gaps = replay.gaps(replay.load(folder), 1560 * MIN)
                self.assertEqual([g["g"] for g in gaps], [10 * MIN])

    def test_active_and_idle_spans_union_per_session(self):
        sessions = [{"host": "h", "id": "a", "observedAt": 10 * MIN,
                     "open": True, "turns": [
                         {"startedAt": MIN, "endedAt": 3 * MIN},
                         {"startedAt": 4 * MIN, "endedAt": 7 * MIN},
                         {"startedAt": 6 * MIN}]},
                    {"host": "h", "id": "b", "observedAt": 10 * MIN,
                     "open": True, "turns": [{"startedAt": 2 * MIN}]}]
        table = replay.residents_at(replay.gaps(sessions, 100 * MIN), sessions, 100 * MIN)
        for t, expected in [(MIN, 1), (2 * MIN, 2), (3 * MIN, 2),
                            (6 * MIN, 2), (9 * MIN, 2), (10 * MIN, 0)]:
            self.assertEqual(replay.count_at(table, "h", t), expected)
        self.assertEqual(replay.count_at(table, "absent", MIN), 0)

    def test_load_keeps_single_running_turn_and_distinct_missing_ids(self):
        with tempfile.TemporaryDirectory() as folder:
            for name in ("a", "b"):
                Path(folder, name + ".json").write_text(json.dumps({"peer": "h",
                    "observedAt": 4 * MIN, "turns": [{"startedAt": MIN}]}))
            sessions = replay.load(folder)
            self.assertEqual(len(sessions), 2)
            table = replay.residents_at([], sessions, 10 * MIN)
            self.assertEqual(replay.count_at(table, "h", 2 * MIN), 2)

    def test_collection_records_observation_not_later_replay_time(self):
        listing = {"sessions": [{"qualifiedSessionId": "h/chat", "status": "ready"}]}
        history = json.dumps({"sessionId": "chat", "turns": [{"startedAt": MIN}]})
        with tempfile.TemporaryDirectory() as folder:
            with patch.object(replay.time, "time", return_value=120), patch.object(
                    replay.subprocess, "run", side_effect=[
                        SimpleNamespace(stdout=json.dumps(listing)), SimpleNamespace(stdout=history)]):
                replay.collect(folder, None, ["h"], 1)
            saved = json.loads(Path(folder, "h_chat.json").read_text())
            self.assertEqual(saved["observedAt"], 120_000)
            self.assertIs(saved["open"], True)
        with tempfile.TemporaryDirectory() as folder:
            ls = Path(folder, "ls.json")
            ls.write_text(json.dumps(listing))
            with patch.object(replay.subprocess, "run", return_value=SimpleNamespace(stdout=history)):
                replay.collect(folder, str(ls), ["h"], 1)
            self.assertIsNone(json.loads(Path(folder, "h_chat.json").read_text())["observedAt"])


class CensusTests(unittest.TestCase):
    def census(self, parent, record_sid="chat", harness_sid="chat"):
        table = {10: (1, 1_000_000, "acpmux __agent-host", 1),
                 20: (parent, 10_000_000, "codex", 2),
                 30: (20, 3_000_000, "mcp serve", 3),
                 40: (30, 2_000_000, "worker", 4)}
        records = {10: {"session_id": record_sid, "harness_pid": 20}}
        return residents.process_rows(table, {"chat": {"status": "running"}}, records,
            5 * MIN, identify=lambda pid: harness_sid if pid == 20 else None)

    def test_detached_harness_and_descendants_are_counted(self):
        row, = self.census(1)
        self.assertEqual((row["session"], row["procs"], row["rss_mb"], row["cpu_s"]),
                         ("chat", 4, 16, 10.0))
        self.assertEqual(row["pin"], "none")
        self.assertIsNone(row["idle_s"])

    def test_record_and_child_do_not_double_count(self):
        self.assertEqual(self.census(10), self.census(1))

    def test_stale_pid_with_wrong_session_is_not_adopted(self):
        row, = self.census(1, harness_sid="another")
        self.assertEqual((row["procs"], row["rss_mb"]), (1, 1))
        self.assertIsNone(row["session"])

    def test_host_records_only_expose_identity_fields(self):
        with tempfile.TemporaryDirectory() as folder:
            Path(folder, "valid.json").write_text(json.dumps({"host_pid": 10,
                "harness_pid": 20, "session_id": "chat", "token": "private"}))
            Path(folder, "broken.json").write_text("{")
            self.assertEqual(residents.host_records(folder),
                {10: {"harness_pid": 20, "session_id": "chat"}})


if __name__ == "__main__":
    unittest.main()
