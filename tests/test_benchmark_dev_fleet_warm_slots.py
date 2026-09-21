#!/usr/bin/env python3
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

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
                },
            },
            {"event": "lineage_quarantined"},
        ]
        path.write_text("\n".join(json.dumps(row) for row in rows) + "\n")
        report = bench.summarize_events(path)
        self.assertEqual(report["tasks"], 1)
        self.assertEqual(report["warms"], 1)
        self.assertEqual(report["useful_warm_hit_percent"], 100.0)
        self.assertEqual(report["warmer_build_seconds"], 3.0)
        self.assertEqual(report["quarantine_count"], 1)
        self.assertEqual(report["disk_growth_bytes"], 25)


if __name__ == "__main__":
    unittest.main()
