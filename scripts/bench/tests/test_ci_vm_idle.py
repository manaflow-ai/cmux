"""ci-vm-idle registration and synthetic capture contract."""
from __future__ import annotations

import json
import subprocess
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
HARNESS = BENCH_DIR.parents[1] / "scripts" / "measure" / "ci-vm-idle.py"


def ingest(path: Path) -> Context:
    ctx = Context(bench=BENCH, build={"channel": "other", "version": None, "sha": None},
                  host_role="anywhere", host={"name": "capture", "role": "anywhere", "os": "Linux", "chip": "x86_64"})
    BENCH.ingest(ctx, path)
    return ctx


def write_capture(root: Path, snapshots: list[tuple[str, list[dict]]], prices: dict[str, float], jobs: list[dict]) -> None:
    (root / "snapshots").mkdir(parents=True)
    for index, (generated_at, rows) in enumerate(snapshots):
        (root / "snapshots" / f"{index}.json").write_text(json.dumps({"generated_at": generated_at, "rows": rows}))
    (root / "prices.json").write_text(json.dumps(prices))
    (root / "jobs.jsonl").write_text("".join(json.dumps(job) + "\n" for job in jobs))


def vm(name: str, shape: str, status: str, created: str, *, start: str = "", stop: str = "") -> dict:
    return {
        "name": name,
        "machine_type": shape,
        "zone": "us-central1-a",
        "status": status,
        "created": created,
        "last_start": start,
        "last_stop": stop,
        "last_suspended": "",
    }


def run_capture(root: Path) -> dict:
    result = subprocess.run([sys.executable, str(HARNESS), str(root)], check=True, capture_output=True, text=True)
    return json.loads(result.stdout)


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

    def test_packed_and_one_shot_slots_resolve_to_exact_inventory_name(self):
        """A slot suffix must prefer the exact VM name over its shorter numeric prefix."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            generated = ("2026-11-22T00:00:00Z", "2026-11-23T01:00:00Z")
            exact = "cmux-runner-pool-hc1a-0001-2"
            shorter = "cmux-runner-pool-hc1a-0001"
            rows = [vm(exact, "n2-standard-16", "RUNNING", "2026-11-20T00:00:00Z", start=generated[0]),
                    vm(shorter, "e2-standard-16", "RUNNING", "2026-11-20T00:00:00Z", start=generated[0])]
            write_capture(root, [(generated[0], rows), (generated[1], rows)],
                          {"n2-standard-16/us-central1": 1.0, "e2-standard-16/us-central1": 10.0}, [
                              {"runner_name": exact, "at": "2026-11-22T09:00:00Z", "seconds": 600},
                              {"runner_name": exact + "-3", "at": "2026-11-22T10:00:00Z", "seconds": 600},
                              {"runner_name": "cmux-oneshot-hc1a-0001-2-abcd", "at": "2026-11-22T11:00:00Z", "seconds": 1200},
                              {"runner_name": "cmux-oneshot-hc1a-0001-2-3-beef", "at": "2026-11-22T12:00:00Z", "seconds": 1200},
                          ])
            report = run_capture(root)
        persistent = report["pools"]["persistent"]
        self.assertEqual(persistent["running_vm_hours"], 48.0)
        self.assertEqual(persistent["idle_vm_hours"], 47.0)
        # All four jobs belong to the $1 VM, leaving the $10 VM idle for 24 hours.
        self.assertEqual(persistent["idle_list_usd"], 263.0)

    def test_resized_vm_prices_only_the_shape_intervals_and_does_not_replay(self):
        """A stopped VM resized in place contributes each shape only for its own running span."""
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            name = "cmux-runner-pool-resize-0001"
            created = "2026-11-20T00:00:00Z"
            snapshots = [
                ("2026-11-22T00:00:00Z", [vm(name, "n2-standard-16", "RUNNING", created, start="2026-11-22T00:00:00Z")]),
                ("2026-11-22T12:00:00Z", [vm(name, "n2-standard-16", "RUNNING", created, start="2026-11-22T00:00:00Z")]),
                # The resized shape appears in the next capture while stopped. Its start/stop fields are
                # stale observations from the prior shape, so the old shape must not replay them.
                ("2026-11-22T13:00:00Z", [vm(name, "n2-standard-32", "TERMINATED", created,
                                               start="2026-11-22T00:00:00Z", stop="2026-11-22T13:00:00Z")]),
                ("2026-11-23T01:00:00Z", [vm(name, "n2-standard-32", "RUNNING", created,
                                               start="2026-11-22T14:00:00Z", stop="2026-11-22T13:00:00Z")]),
            ]
            write_capture(root, snapshots,
                          {"n2-standard-16/us-central1": 1.0, "n2-standard-32/us-central1": 3.0}, [])
            report = run_capture(root)
        persistent = report["pools"]["persistent"]
        self.assertEqual(persistent["running_vm_hours"], 23.0)
        self.assertEqual(persistent["idle_vm_hours"], 23.0)
        self.assertEqual(persistent["idle_list_usd"], 45.0)


if __name__ == "__main__":
    unittest.main()
