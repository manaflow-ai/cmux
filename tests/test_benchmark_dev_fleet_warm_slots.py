#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock
import git_fixture_env  # noqa: F401  (disables git auto maintenance)

ROOT = Path(__file__).resolve().parents[1]
BENCH = ROOT / "scripts" / "benchmark-dev-fleet-warm-slots.py"
SPEC = importlib.util.spec_from_file_location("benchmark_warm_slots", BENCH)
assert SPEC and SPEC.loader
bench = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(bench)


def git(repo: Path, *args: str) -> str:
    result = subprocess.run(["git", "-C", str(repo), *args], check=True, capture_output=True, text=True)
    return result.stdout.strip()


class BenchmarkTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.repo = self.root / "repo"
        self.repo.mkdir()
        git(self.repo, "init", "-q")
        git(self.repo, "config", "user.name", "Benchmark Test")
        git(self.repo, "config", "user.email", "benchmark@example.invalid")
        (self.repo / "Sources").mkdir()
        (self.repo / "Sources/App.swift").write_text("let a = 1\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "base")
        (self.repo / "Sources/App.swift").write_text("let a = 2\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "source only")
        self.source = git(self.repo, "rev-parse", "HEAD")
        (self.repo / "Package.swift").write_text("// swift-tools-version: 6.0\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "graph")
        self.graph = git(self.repo, "rev-parse", "HEAD")
        (self.repo / "README.md").write_text("docs\n")
        git(self.repo, "add", ".")
        git(self.repo, "commit", "-qm", "tip")
        self.main = git(self.repo, "rev-parse", "HEAD")

    def tearDown(self):
        self.temp.cleanup()

    def test_discover_pins_real_source_and_graph_cases(self):
        manifest = bench.discover_history(self.repo, self.main, behind=1, limit=20)
        self.assertEqual(manifest["main_commit"], self.main)
        self.assertEqual(manifest["behind_commit"], self.graph)
        self.assertEqual(manifest["source_only"]["commit"], self.source)
        self.assertEqual(manifest["graph_change"]["commit"], self.graph)
        self.assertIn("source_only_change", manifest["cases"])
        self.assertIn("warmer_interrupted_by_real_work", manifest["cases"])

    def test_wait_for_warmer_ready_uses_pipe_signal(self):
        read_fd, write_fd = os.pipe()
        try:
            os.write(write_fd, b"1")
            self.assertTrue(bench.wait_for_warmer_ready(read_fd, timeout=0.1))
        finally:
            os.close(read_fd)
            os.close(write_fd)

    def test_benchmark_helpers_request_disk_measurement(self):
        helper = self.root / "helper.py"
        state = self.root / "state"
        checkout = self.repo

        with mock.patch.object(bench, "run_helper", return_value={"status": "ok"}) as run:
            bench.warm(helper, state, checkout, "slot", self.main, [])
        warm_argv = run.call_args.args[1]
        self.assertIn("--measure-disk", warm_argv)

        with mock.patch.object(bench, "run_helper", return_value={"status": "ok"}) as run:
            bench.task(helper, state, checkout, "slot", self.main, "task", [])
        task_argv = run.call_args.args[1]
        self.assertIn("--measure-disk", task_argv)

        with mock.patch.object(bench, "run_helper", return_value={"status": "ok"}) as run:
            bench.cleanup(helper, state, "slot")
        cleanup_argv = run.call_args.args[1]
        self.assertIn("--measure-bytes", cleanup_argv)
        self.assertIn("--max-generations", cleanup_argv)

    def test_cold_generation_count_tracks_only_generated_directory_ids(self):
        state = self.root / "state"
        active = state / "case/slots/slot/cache/cold-tasks"
        retired = state / "case/slots/slot/cache/retired-cold-tasks"
        active.mkdir(parents=True)
        retired.mkdir(parents=True)
        (active / ("a" * 32)).mkdir()
        (active / "operator-data").mkdir()
        (retired / ("b" * 32)).mkdir()
        outside = self.root / "outside"
        outside.mkdir()
        (retired / ("c" * 32)).symlink_to(outside, target_is_directory=True)

        symlink_cache = state / "symlinked/slots/slot/cache"
        symlink_cache.mkdir(parents=True)
        outside_namespace = self.root / "outside-namespace"
        (outside_namespace / ("d" * 32)).mkdir(parents=True)
        (symlink_cache / "cold-tasks").symlink_to(
            outside_namespace,
            target_is_directory=True,
        )

        outside_case = self.root / "outside-case"
        (outside_case / "slots/slot/cache/cold-tasks" / ("e" * 32)).mkdir(parents=True)
        (state / "linked-case").symlink_to(outside_case, target_is_directory=True)

        outside_slots = self.root / "outside-slots"
        (outside_slots / "slot/cache/cold-tasks" / ("f" * 32)).mkdir(parents=True)
        slots_parent = state / "linked-slots-case"
        slots_parent.mkdir()
        (slots_parent / "slots").symlink_to(outside_slots, target_is_directory=True)

        outside_slot = self.root / "outside-slot"
        (outside_slot / "cache/cold-tasks" / ("1" * 32)).mkdir(parents=True)
        slot_parent = state / "linked-slot-case/slots"
        slot_parent.mkdir(parents=True)
        (slot_parent / "slot").symlink_to(outside_slot, target_is_directory=True)

        outside_cache = self.root / "outside-cache"
        (outside_cache / "cold-tasks" / ("2" * 32)).mkdir(parents=True)
        cache_parent = state / "linked-cache-case/slots/slot"
        cache_parent.mkdir(parents=True)
        (cache_parent / "cache").symlink_to(outside_cache, target_is_directory=True)

        self.assertEqual(bench.cold_generation_count(state, "cold-tasks"), 1)
        self.assertEqual(bench.cold_generation_count(state, "retired-cold-tasks"), 1)

    def test_event_report_exposes_trial_metrics(self):
        path = self.root / "events.jsonl"
        rows = [
            {
                "event": "warm_finished",
                "receipt": {"wall_seconds": 3.0, "disk_growth_bytes": 20},
            },
            {
                "event": "task_finished",
                "receipt": {
                    "match_class": "exact",
                    "cold_fallback": False,
                    "task_known_to_build_start_seconds": 0.2,
                    "wall_seconds": 4.0,
                    "swift_compile_count": 0,
                    "disk_growth_bytes": 5,
                    "cold_cache_retirement_seconds": 0.001,
                },
            },
            {"event": "cold_task_retired"},
            {"event": "cold_task_reclaimed", "reclaimed_bytes": 4096},
            {"event": "cold_task_cleanup_preempted"},
            {"event": "cold_task_cleanup_failed"},
            {"event": "cold_task_cleanup_deferred"},
            {"event": "lineage_quarantined"},
        ]
        archive = path.with_name("events.jsonl.1")
        archive.write_text(json.dumps(rows[0]) + "\n")
        path.write_text("\n".join(json.dumps(row) for row in rows[1:]) + "\n{\"event\":")
        report = bench.summarize_events(path)
        self.assertEqual(report["tasks"], 1)
        self.assertEqual(report["warms"], 1)
        self.assertEqual(report["useful_warm_hit_percent"], 100.0)
        self.assertEqual(report["warmer_build_seconds"], 3.0)
        self.assertEqual(report["quarantine_count"], 1)
        self.assertEqual(report["disk_growth_bytes"], 25)
        self.assertEqual(report["cold_cache_retirement_seconds"], [0.001])
        self.assertEqual(report["cold_task_retired_count"], 1)
        self.assertEqual(report["cold_task_reclaimed_count"], 1)
        self.assertEqual(report["cold_task_cleanup_preempted_count"], 1)
        self.assertEqual(report["cold_task_cleanup_failed_count"], 1)
        self.assertEqual(report["cold_task_cleanup_deferred_count"], 1)


if __name__ == "__main__":
    unittest.main()
