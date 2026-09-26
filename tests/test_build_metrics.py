#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import json
from pathlib import Path
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/build_metrics.py"

spec = importlib.util.spec_from_file_location("build_metrics", SCRIPT)
build_metrics = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(build_metrics)


SAMPLE = """SwiftDriver Bonsplit normal arm64 com.apple.xcode.tools.swift.compiler (in target 'Bonsplit' from project 'Bonsplit')
Cache hit

Cache miss
SwiftCompile normal arm64 Compiling\\ Foo.swift /repo/Sources/Foo.swift (in target 'cmux' from project 'cmux')
Cache miss

SwiftCompile normal arm64 Compiling\\ Bar.swift /repo/Sources/Bar.swift (in target 'cmux' from project 'cmux')
SwiftEmitModule normal arm64 Emitting\\ module\\ for\\ cmux (in target 'cmux' from project 'cmux')

CodeSign /tmp/cmux.app (in target 'cmux' from project 'cmux')

Build Timing Summary
CompileSwiftSources (8 tasks) | 12.500 seconds
Ld (1 task) | 2.250 seconds
** BUILD SUCCEEDED **
"""


class BuildMetricsTests(unittest.TestCase):
    def test_parse_log_attributes_cache_and_swift_work(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "cmux-build.log"
            path.write_text(SAMPLE)
            parsed = build_metrics.parse_log(path)

        self.assertEqual(parsed["cache_hits"], 1)
        self.assertEqual(parsed["cache_misses"], 2)
        self.assertEqual(parsed["swift_compile_events"], 2)
        self.assertEqual(parsed["swift_emit_module_events"], 1)
        self.assertEqual(parsed["targets"]["Bonsplit"]["cache_hits"], 1)
        self.assertEqual(parsed["targets"]["cmux"]["cache_misses"], 2)
        self.assertEqual(parsed["targets"]["cmux"]["swift_compile_events"], 2)
        self.assertEqual(
            parsed["timing_summary_seconds"],
            {"CompileSwiftSources": 12.5, "Ld": 2.25},
        )

    def test_aggregate_orders_hot_targets_first(self):
        schemes = [
            {
                "cache_hits": 2,
                "cache_misses": 3,
                "swift_compile_events": 4,
                "swift_emit_module_events": 1,
                "timing_summary_seconds": {"CompileSwiftSources": 5.0},
                "targets": {
                    "Small": {
                        "cache_hits": 2,
                        "cache_misses": 0,
                        "swift_compile_events": 1,
                        "swift_emit_module_events": 0,
                    },
                    "cmux": {
                        "cache_hits": 0,
                        "cache_misses": 3,
                        "swift_compile_events": 3,
                        "swift_emit_module_events": 1,
                    },
                },
            },
            {
                "cache_hits": 1,
                "cache_misses": 1,
                "swift_compile_events": 2,
                "swift_emit_module_events": 0,
                "timing_summary_seconds": {"CompileSwiftSources": 2.0},
                "targets": {
                    "cmux": {
                        "cache_hits": 1,
                        "cache_misses": 1,
                        "swift_compile_events": 2,
                        "swift_emit_module_events": 0,
                    }
                },
            },
        ]
        aggregate = build_metrics.aggregate(schemes)
        self.assertEqual(aggregate["cache_hits"], 3)
        self.assertEqual(aggregate["cache_misses"], 4)
        self.assertEqual(aggregate["timing_summary_seconds"]["CompileSwiftSources"], 7.0)
        self.assertEqual(next(iter(aggregate["targets"])), "cmux")
        self.assertEqual(aggregate["targets"]["cmux"]["swift_compile_events"], 5)

    def test_ci_wires_advisory_receipt_and_timing_summary(self):
        compile_script = (ROOT / "scripts/ci/compile-app-host-test-product.sh").read_text()
        workflow = (ROOT / ".github/workflows/ci-macos.yml").read_text()
        self.assertIn("-showBuildTimingSummary", compile_script)
        self.assertIn("python3 scripts/ci/build_metrics.py", workflow)
        self.assertIn("xcode-build-metrics-${{ github.run_id }}-${{ github.run_attempt }}", workflow)
        self.assertIn("steps.hosted-compile.outcome != 'skipped'", workflow)
        self.assertIn("--compile-outcome \"$HOSTED_COMPILE_OUTCOME\"", workflow)
        self.assertIn("steps.build-metrics.outcome == 'success'", workflow)
        self.assertIn("continue-on-error: true", workflow)

    def test_receipt_discovers_logs_and_activity_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            derived = Path(directory)
            (derived / "cmux-build.log").write_text(SAMPLE)
            activity = derived / "Logs" / "Build"
            activity.mkdir(parents=True)
            (activity / "one.xcactivitylog").write_bytes(b"abc")

            receipt = build_metrics.build_receipt(
                derived,
                42.5,
                compile_outcome="failure",
            )

        self.assertEqual(receipt["schema_version"], 1)
        self.assertEqual(receipt["compile_wall_seconds"], 42.5)
        self.assertEqual(receipt["compile_outcome"], "failure")
        self.assertEqual(receipt["derived_data_log_count"], 1)
        self.assertEqual(receipt["activity_logs"], [{"name": "one.xcactivitylog", "bytes": 3}])
        json.dumps(receipt)


if __name__ == "__main__":
    unittest.main()
