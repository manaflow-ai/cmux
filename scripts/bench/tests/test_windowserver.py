from __future__ import annotations

import ast
import json
import threading
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

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
import windowserver_gpu as gpu_module  # noqa: E402


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

    def test_typing_report_cpu_keys_and_gpu(self) -> None:
        for key in ("cpu_pct", "cpu_percent"):
            with self.subTest(key=key):
                gpu = {"available": True, "device_utilization_percent": 4.0}
                row = _harness.extract_runs("typing", {"runs": [{
                    key: {"app": 2.0, "window_server": 3.0}, "gpu": gpu,
                }]})[0]
                self.assertEqual(row["window_server_cpu_percent"], 3.0)
                self.assertEqual(row["app_cpu_percent"], 2.0)
                self.assertEqual(row["gpu"], gpu)

    def test_spinner_labels_only_loading_as_background(self) -> None:
        report = {"phases": [{"phase": phase} for phase in ("static", "loading")]}
        idle = _harness.extract_runs("idle", report)
        spinner = _harness.extract_runs("spinner", report)
        self.assertEqual([(r["surface"], r["visibility"]) for r in idle],
                         [("browser-tabs", "shown"), ("browser-tabs", "shown")])
        self.assertEqual([(r["surface"], r["visibility"]) for r in spinner],
                         [("browser-tabs", "shown"), ("tab-strip", "background-loading-tab")])

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

    def test_agentpane_production_path_samples_gpu_and_cleans_up(self) -> None:
        # Execute the production function without the script's CLI/app startup.
        path = BENCH_DIR.parent / "cmux-next" / "typing-frame-bench.py"
        tree = ast.parse(path.read_text())
        functions = [node for node in tree.body if isinstance(node, ast.FunctionDef)
                     and node.name in ("measure_agentpane", "cpu_share")]
        code = compile(ast.Module(body=functions, type_ignores=[]), str(path), "exec")
        for fail in (False, True):
            with self.subTest(exception=fail):
                sampled = threading.Event()
                samplers = []

                def sample():
                    sampled.set()
                    return {"Device Utilization %": 12.0}

                def sampler():
                    instance = gpu_module.GPUSampler()
                    samplers.append(instance)
                    return instance

                def cpu_seconds(pid):
                    self.assertTrue(sampled.wait(2), "GPU sampling never started in agentpane")
                    return 1.0

                def rpc(method, params=None, **kwargs):
                    params = params or {}
                    if method == "debug.focus":
                        return {"app_active": True}
                    if params.get("action") == "reset_typing" and fail:
                        raise RuntimeError("injected RPC failure")
                    if params.get("action") == "typing_stats":
                        return {"keys": 10, "composer_text": ""}
                    return {}

                namespace = dict(
                    GPUSampler=sampler, WINDOW_SERVER=2, SESSION="test", MODE=None, LOAD={},
                    opts=SimpleNamespace(launch="open", chat_agent="mock", prefill=0, sample=False,
                                         samples=1, interval=0.01, json=None),
                    foreground_activation=lambda: {}, rpc=rpc, wait=lambda fn, *a, **k: fn(),
                    draw_on_input_frames=lambda: None, launch_switch_once=lambda: (True, None),
                    cpu_seconds=cpu_seconds, time=Mock(monotonic=Mock(side_effect=range(100)),
                                                       time=Mock(return_value=1.0)),
                    agent_expected_text=lambda n: "a", SchedProbe=Mock(),
                    agent_typing_verdict=lambda *a: {"observed_keys": 1, "complete": True, "text_exact": True},
                    frame_metrics=lambda value: {}, pct=lambda value: {},
                    frame_timing_validity=lambda *a: {}, results={"runs": []}, note=Mock())
                exec(code, namespace)
                with patch.object(gpu_module, "read_gpu_stats", side_effect=sample):
                    if fail:
                        with self.assertRaisesRegex(RuntimeError, "injected RPC failure"):
                            namespace["measure_agentpane"]("idle", 1, "pane")
                    else:
                        entry = namespace["measure_agentpane"]("idle", 1, "pane")
                        self.assertEqual(entry["gpu"]["device_utilization_percent"], 12.0)
                        normalized = _harness.extract_runs("typing", {"runs": [entry]})[0]
                        self.assertEqual(normalized["gpu"], entry["gpu"])
                        self.assertEqual(normalized["window_server_cpu_percent"], 0.0)
                self.assertEqual(len(samplers), 1)
                self.assertFalse(samplers[0].is_alive())
                self.assertTrue(samplers[0].stop_event.is_set())

    def test_sampler_finish_waits_for_inflight_read_and_discards_it(self) -> None:
        entered, release, finished = threading.Event(), threading.Event(), threading.Event()

        def read():
            entered.set()
            release.wait(2)
            return {"Device Utilization %": 99.0}

        sampler = gpu_module.GPUSampler()
        self.assertEqual(sampler.interval, 1.0)
        with patch.object(gpu_module, "read_gpu_stats", side_effect=read):
            sampler.start()
            self.assertTrue(entered.wait(2))
            worker = threading.Thread(target=lambda: (sampler.finish(), finished.set()))
            worker.start()
            try:
                self.assertTrue(sampler.stop_event.wait(2))
                self.assertFalse(finished.is_set())
            finally:
                release.set()
                worker.join(2)
                sampler.join(2)
        self.assertTrue(finished.is_set())
        self.assertFalse(sampler.is_alive())
        self.assertEqual(sampler.samples, [])

    def test_partial_failure_transports_report_but_fails_ingestion(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            report_path = Path(tmp) / "report.json"
            argv = ["bench", "--app", "/fake.app", "--out", tmp, "--json", str(report_path),
                    "--scenarios", "idle,typing", "--transport-envelope"]
            good = [{"scenario": "idle", "window_server_cpu_percent": 2.0}]
            with patch.object(sys, "argv", argv), patch.object(
                    _harness, "run_scenario", side_effect=[good, RuntimeError("typing failed")]):
                self.assertEqual(_harness.main(), 0)
            report = json.loads(report_path.read_text())
            self.assertEqual(report["verdict"], "failed")
            self.assertEqual(report["harness_exit_code"], 1)
            self.assertEqual(report["failures"][0]["scenario"], "typing")
            self.assertEqual(len(report["runs"]), 1)
            ctx = context()
            with self.assertRaisesRegex(BenchError, "scenario validation failed"):
                BENCH.ingest(ctx, report_path)
            self.assertTrue(ctx.rows, "partial measurements should survive ingestion failure")

    def test_bad_schema_raises(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "report.json"
            path.write_text("{}", encoding="utf-8")
            with self.assertRaises(BenchError):
                BENCH.ingest(context(), path)


if __name__ == "__main__":
    unittest.main()
