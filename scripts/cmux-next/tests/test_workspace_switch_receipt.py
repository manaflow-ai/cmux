#!/usr/bin/env python3
"""Portable behavior checks for async workspace-switch artifacts and summaries."""
from __future__ import annotations

import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import bench_workspace_switch as bench
import workspace_switch_receipt as receipts


def ready_pane():
    return {"pane": "p1", "workspace": "w1", "visible": True, "selected_tab": "t1", "shown_tab": "t1",
            "window_drawable": True, "content_installed": True, "content_in_window": True, "content_visible": True,
            "blank": False, "collapsed": False, "foreign_pages": 0, "phase": "painted"}


def measured_report():
    report = receipts.receipt("a" * 40, "test", {"refresh_hz": 60}, {"runs": 1})
    report["runs"] = [{"scenario": scenario, "iteration": 1, "cache_state": cache,
                       "first_visible_ms": 20, "settled_ms": 120, "settled_violations": [],
                       "frames": receipts.frame_metrics({"frames": 24, "refresh_ms": 16.667,
                           "p50_ms": 16.667, "p95_ms": 17, "p99_ms": 18, "missed": 0})}
                      for scenario, cache in receipts.CACHE_STATES.items()]
    return report


class WorkspaceReceiptTests(unittest.TestCase):
    def test_missing_or_wrong_content_cannot_count_as_visible(self):
        for field, bad in (("workspace", "other"), ("shown_tab", "stale"), ("window_drawable", False),
                           ("content_visible", False), ("collapsed", True), ("foreign_pages", 1), ("phase", "loading")):
            with self.subTest(field=field):
                pane = ready_pane()
                pane[field] = bad
                ready, violations = receipts.visible_state({"windows": [{"panes": [pane]}]}, "w1")
                self.assertFalse(ready)
                self.assertTrue(violations)
        self.assertFalse(receipts.visible_state({}, "w1")[0])
        self.assertTrue(receipts.visible_state({"windows": [{"panes": [ready_pane()]}]}, "w1")[0])

    def test_frame_budget_uses_measured_refresh_and_unknown_stays_null(self):
        metrics = receipts.frame_metrics({"frames": 10, "refresh_ms": 8, "p50_ms": 8,
                                         "p95_ms": 12, "p99_ms": 20, "missed": 2})
        self.assertEqual(metrics["overrun_ms"], {"p50": 0, "p95": 4, "p99": 12})
        self.assertEqual(metrics["dropped_frames_proxy"], 2)
        for frames in ({}, {"frames": 0, "refresh_ms": 16.667}, {"frames": 10, "refresh_ms": 0}):
            self.assertIsNone(receipts.frame_metrics(frames)["dropped_frames_proxy"])
            self.assertIsNone(receipts.frame_metrics(frames)["overrun_ms"]["p50"])

    def test_exact_fingerprint_changes_with_source_display_or_parameters(self):
        original = receipts.receipt("a" * 40, "test", {"hz": 60}, {"runs": 3})
        same = receipts.receipt("a" * 40, "test", {"hz": 60}, {"runs": 3})
        self.assertEqual(original["fingerprint"], same["fingerprint"])
        for sha, display, parameters in (("b" * 40, {"hz": 60}, {"runs": 3}),
                                         ("a" * 40, {"hz": 120}, {"runs": 3}),
                                         ("a" * 40, {"hz": 60}, {"runs": 4})):
            self.assertNotEqual(original["fingerprint"], receipts.receipt(sha, "test", display, parameters)["fingerprint"])

    def test_slow_or_invariant_failed_receipt_warns_but_cli_exits_zero(self):
        report = measured_report()
        report["runs"][1].update(first_visible_ms=900, settled_ms=1500, settled_violations=["blank"])
        report["runs"][1]["frames"]["dropped_frames_proxy"] = 12
        found = receipts.warnings(report)
        self.assertTrue(any("first visible" in item for item in found))
        self.assertTrue(any("settled content invariant" in item for item in found))
        self.assertTrue(any("missed-vsync" in item for item in found))
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "receipt.json"
            receipts.write_report(report, path)
            completed = subprocess.run([sys.executable, receipts.__file__, "--summary", str(path)], capture_output=True, text=True)
            strict = subprocess.run([sys.executable, receipts.__file__, "--summary", str(path), "--strict-invariants"],
                                    capture_output=True, text=True)
        self.assertEqual(completed.returncode, 0)
        self.assertIn("::warning", completed.stderr)
        self.assertIn("explicit previsit simulation", completed.stdout)
        self.assertEqual(strict.returncode, 1)
        self.assertIn("content invariant", strict.stderr)

    def test_strict_invariants_preserves_unknown_timeout_state(self):
        report = measured_report()
        report["runs"][0].update(first_visible_ms=None, settled_ms=None, settled_violations=["no visible panes"])
        self.assertEqual(receipts.invariant_failures(report), [])
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "receipt.json"
            receipts.write_report(report, path)
            completed = subprocess.run(
                [sys.executable, receipts.__file__, "--summary", str(path), "--strict-invariants"],
                capture_output=True,
                text=True,
            )
        self.assertEqual(completed.returncode, 0)
        self.assertIn("unknown", completed.stdout)

    def test_roundtrip_receipt_preserves_provenance_and_cache_states(self):
        report = measured_report()
        self.assertEqual(receipts.warnings(report), [])
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "nested/receipt.json"
            receipts.write_report(report, path)
            loaded = json.loads(path.read_text())
        self.assertEqual(loaded["schema_version"], 1)
        self.assertEqual(loaded["source_sha"], "a" * 40)
        self.assertEqual(loaded["measurement_semantics"], "surface_readiness_rpc_upper_bound")
        self.assertEqual([row["cache_state"] for row in loaded["runs"]], ["new_workspace", "parked_revisit", "explicit_previsit"])

    def test_unknown_frames_and_timeouts_never_become_healthy_zeroes(self):
        report = measured_report()
        report["runs"][0].update(first_visible_ms=None, settled_ms=None, frames=receipts.frame_metrics({}))
        self.assertIn("unknown", receipts.summarize(report))
        self.assertTrue(any("no usable display-frame" in item for item in receipts.warnings(report)))
        self.assertTrue(any("timed out" in item for item in receipts.warnings(report)))

    def test_skip_capacity_is_an_explicit_artifact_and_exits_zero(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "receipt.json"
            self.assertEqual(receipts.main(["--skip-reason", "GUI busy", "--sha", "a" * 40, "--out", str(path)]), 0)
            report = json.loads(path.read_text())
            self.assertEqual(receipts.main(["--summary", str(path), "--strict-invariants"]), 0)
        self.assertEqual(report["status"], "skipped")
        self.assertEqual(report["runs"], [])
        self.assertEqual(report["warnings"], [])
        self.assertEqual(receipts.invariant_failures(report), [])
        self.assertIn("Skipped: GUI busy", receipts.summarize(report))

    def test_non_mac_driver_writes_skip_without_loading_native_libraries(self):
        with tempfile.TemporaryDirectory() as temporary, patch.object(bench.sys, "platform", "linux"):
            path = Path(temporary) / "receipt.json"
            code = bench.main(["--tag", "test", "--app", "/nonexistent", "--sha", "a" * 40, "--out", str(path)])
            report = json.loads(path.read_text())
        self.assertEqual(code, 0)
        self.assertEqual(report["status"], "skipped")

    def test_missing_receipt_warns_without_failing_summary(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = receipts.main(["--summary", "/nonexistent/workspace-switch-receipt.json"])
        self.assertEqual(code, 0)
        self.assertIn("Not measured", out.getvalue())
        self.assertIn("not passing performance evidence", err.getvalue())

    def test_cold_measurement_rejects_previous_workspace_until_new_content_settles(self):
        clock = SimpleNamespace(now=0.0)
        def sleep(delay):
            clock.now += delay
        def surfaces():
            pane = ready_pane()
            pane["workspace"] = "old" if clock.now < 0.06 else "new"
            pane["content_visible"] = clock.now >= 0.08
            return {"windows": [{"panes": [pane]}]}
        native = SimpleNamespace(refused=lambda response: None, result=lambda response: response["result"])
        control = SimpleNamespace(call=lambda *a, **kw: {"result": {"frames": 20, "refresh_ms": 16.667, "missed": 0}})
        fake_bench = SimpleNamespace(control=control, surfaces=surfaces,
            topology=lambda: {"focus": {"workspace": "old" if clock.now < 0.06 else "new"}})
        args = SimpleNamespace(deadline=1, stable_ms=100, poll_ms=20, frame_window_ms=400)
        with patch.dict(sys.modules, {"bench_tab_switch": native}), patch.object(bench.time, "monotonic", lambda: clock.now), \
                patch.object(bench.time, "sleep", sleep):
            row = bench.measure(fake_bench, lambda: {}, None, args, "cold", 1, previous="old")
        self.assertEqual(row["workspace"], "new")
        self.assertGreaterEqual(row["first_visible_ms"], 80)
        self.assertGreaterEqual(row["settled_ms"], 180)
        self.assertEqual(row["settled_violations"], [])
        self.assertGreater(row["transient_violation_count"], 0)

    def test_bench_timeout_records_unknown_latency_and_final_violation(self):
        clock = SimpleNamespace(now=0.0)
        def sleep(delay):
            clock.now += delay
        native = SimpleNamespace(refused=lambda response: None, result=lambda response: response["result"])
        fake_bench = SimpleNamespace(control=SimpleNamespace(call=lambda *a, **kw: {"result": {}}), surfaces=lambda: {})
        args = SimpleNamespace(deadline=0.1, stable_ms=100, poll_ms=20, frame_window_ms=400)
        with patch.dict(sys.modules, {"bench_tab_switch": native}), patch.object(bench.time, "monotonic", lambda: clock.now), \
                patch.object(bench.time, "sleep", sleep):
            row = bench.measure(fake_bench, lambda: {}, "new", args, "warm", 1)
        self.assertEqual(row["status"], "timeout")
        self.assertIsNone(row["first_visible_ms"])
        self.assertIsNone(row["settled_ms"])
        self.assertEqual(row["settled_violations"], ["no visible panes"])


if __name__ == "__main__":
    unittest.main()
