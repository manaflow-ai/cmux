from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402
from benches.windowserver import BENCH  # noqa: E402
from importlib.util import module_from_spec, spec_from_file_location  # noqa: E402

_spec = spec_from_file_location("windowserver_harness", BENCH_DIR.parent / "cmux-next" / "windowserver-bench.py")
assert _spec and _spec.loader
_harness = module_from_spec(_spec)
_spec.loader.exec_module(_harness)


def context() -> Context:
    return Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                   timestamp="2026-11-20T00:00:00Z", args={})


class WindowServerTest(unittest.TestCase):
    def test_registered(self) -> None:
        self.assertIs(load_all()["windowserver"], BENCH)

    def test_extract_gpu_is_aggregate_only(self) -> None:
        report = {"phases": [{"phase": "static", "window_server_cpu_percent": 1.0,
                              "classes": {"app": {"cpu_percent": 2.0}, "gpu": {"cpu_percent": 3.0}}}]}
        report["phases"][0]["gpu"] = {"available": True, "device_utilization_percent": 4.0}
        rows = _harness.extract_runs("spinner", report)
        self.assertEqual([row["phase"] for row in rows], ["static"])
        self.assertEqual(rows[0]["gpu"]["device_utilization_percent"], 4.0)

    def test_gpu_stats_accept_numeric_plist_values(self) -> None:
        payload = plist_bytes = b'''<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><array><dict><key>PerformanceStatistics</key><dict><key>Device Utilization %</key><real>12.5</real><key>Renderer Utilization %</key><integer>9</integer><key>In use system memory</key><integer>1048576</integer></dict></dict></array></plist>'''
        import subprocess
        proc = subprocess.CompletedProcess([], 0, stdout=payload, stderr=b"")
        self.assertEqual(_harness.read_gpu_stats(proc)["Device Utilization %"], 12.5)
        summary = _harness.summarize_gpu([_harness.read_gpu_stats(proc)])
        self.assertEqual(summary["in_use_system_memory_mb"], 1.0)

    def test_ingest_shapes_scenarios_and_gpu(self) -> None:
        report = {"schema": "cmux-windowserver/v1", "host": "bench-mac", "runs": [
            {"scenario": "spinner", "phase": "loading", "round": 1, "window_server_cpu_percent": 4.25,
             "app_cpu_percent": 2.0, "cef_gpu_cpu_percent": 1.0,
             "gpu": {"available": True, "device_utilization_percent": 8.5, "renderer_utilization_percent": 4.0}},
            {"scenario": "glass-blur", "phase": "idle", "round": 1, "window_server_cpu_percent": None,
             "gpu": {"available": False}},
        ]}
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "report.json"
            path.write_text(json.dumps(report), encoding="utf-8")
            ctx = context()
            BENCH.ingest(ctx, path)
        rows = {(row["metric"], row["labels"].get("scenario")): row for row in ctx.rows}
        self.assertEqual(rows[("window_server_cpu", "spinner")]["value"], 4.25)
        self.assertEqual(rows[("gpu_device_utilization", "spinner")]["value"], 8.5)
        self.assertTrue(any("GPU counters unavailable" in note for note in ctx.notes))

    def test_bad_schema_raises(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "report.json"
            path.write_text("{}", encoding="utf-8")
            with self.assertRaises(BenchError):
                BENCH.ingest(context(), path)


if __name__ == "__main__":
    unittest.main()
