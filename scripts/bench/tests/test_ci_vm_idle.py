"""ci-vm-idle registration and synthetic capture contract."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.ci_vm_idle import BENCH  # noqa: E402

FIX = Path(__file__).resolve().parent / "fixtures" / "ci-vm-idle"
INPUT = FIX / "input"


def ingest(path: Path) -> Context:
    ctx = Context(bench=BENCH, build={"channel": "other", "version": None, "sha": None},
                  host_role="anywhere", host={"name": "capture", "role": "anywhere", "os": "Linux", "chip": "x86_64"})
    BENCH.ingest(ctx, path)
    return ctx


class CiVmIdleBenchTest(unittest.TestCase):
    def test_fixture_report_maps_hours_and_usd_to_schema_units(self):
        ctx = ingest(FIX / "report.json")
        rows = {(r["labels"]["pool"], r["metric"]): r for r in ctx.rows}
        self.assertEqual(len(rows), 6)
        self.assertEqual(rows[("persistent", "running_vm_seconds")]["value"], 86400.0)
        self.assertEqual(rows[("persistent", "idle_vm_seconds")]["value"], 83700.0)
        self.assertEqual(rows[("persistent", "idle_list_cents")]["value"], 2325.0)
        self.assertEqual(rows[("jit", "running_vm_seconds")]["value"], 3600.0)
        self.assertEqual(rows[("jit", "idle_vm_seconds")]["value"], 1800.0)
        self.assertEqual(rows[("jit", "idle_list_cents")]["value"], 100.0)
        self.assertEqual(rows[("jit", "idle_list_cents")]["unit"], "count")

    def test_actual_harness_merges_overlapping_job_intervals(self):
        report = json.loads((FIX / "report.json").read_text())
        ctx = Context(bench=BENCH, build={"channel": "other", "version": None, "sha": None},
                      host_role="anywhere", args={"input": str(INPUT)},
                      host={"name": "capture", "role": "anywhere", "os": "Linux", "chip": "x86_64"})
        BENCH.run(ctx)
        rows = {(r["labels"]["pool"], r["metric"]): r["value"] for r in ctx.rows}
        # Two overlapping persistent jobs occupy 45 minutes, not one hour.
        self.assertEqual(rows[("persistent", "idle_vm_seconds")], report["pools"]["persistent"]["idle_vm_hours"] * 3600)
        self.assertEqual(rows[("jit", "idle_vm_seconds")], 1800.0)

    def test_malformed_pool_does_not_publish_partial_rows(self):
        doc = json.loads((FIX / "report.json").read_text())
        del doc["pools"]["jit"]
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "bad.json"
            path.write_text(json.dumps(doc))
            ctx = Context(bench=BENCH, build={"channel": "other", "version": None, "sha": None}, host_role="anywhere")
            with self.assertRaises(BenchError):
                BENCH.ingest(ctx, path)
            self.assertEqual(ctx.rows, [])


if __name__ == "__main__":
    unittest.main()
