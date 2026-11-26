"""Synthetic import contracts, never performance evidence."""
import copy
import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from benchlib.bench import BenchError, Context
from benches.acpmux_duress import BENCH


def report():
    return {
        "schema": "acpmux.duress-bench.v1", "commit": "a" * 40,
        "host": "synthetic", "os": "macos", "memoryMetric": "synthetic Mach metric",
        "removalErrors": [],
        "legs": [{"leg": leg, "setupErrors": {},
                  "liveness": {"polls": 10, "falseDead": 0},
                  "stressors": {"cpuBusyPct": 92, "memUsedPctAtClock": 89, "memUsedPctAtEnd": 88},
                  "ops": [{"op": op, "via": via, "n": 3, "p50Ms": 12,
                           "p95Ms": 20, "p99Ms": 20, "maxMs": 20, "errors": 1}
                          for op in ("ls", "send", "status", "send-far")
                          for via in ("cli", "socket")]}
                 for leg in ("baseline", "rfd0050")],
    }


class AcpmuxDuressImportTest(unittest.TestCase):
    def ingest(self, data):
        self.ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "a" * 40}, host_role="fleet")
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "report.json"
            path.write_text(json.dumps(data))
            BENCH.ingest(self.ctx, path)
        return self.ctx

    def test_rows_retain_source_load_and_failures(self):
        ctx = self.ingest(report())
        rows = [r for r in ctx.rows if r["metric"] == "latency"]
        self.assertEqual(len(rows), 16)
        self.assertEqual(rows[0]["n"], 3)
        self.assertEqual(rows[0]["build"]["sha"], "a" * 40)
        self.assertEqual(rows[0]["host"]["os"], "macos")
        self.assertTrue(all(r["value"] == 1 for r in ctx.rows if r["metric"] == "errors"))
        self.assertEqual(next(r["value"] for r in ctx.rows if r["metric"] == "cpuBusyPct"), 92)

    def test_incomplete_or_stale_report_emits_no_rows(self):
        original = report()
        changes = [
            lambda r: r.update(commit="b" * 40),
            lambda r: r.update(removalErrors=["child remains"]),
            lambda r: r.update(legs=[]),
            lambda r: r["legs"][1].update(setupErrors={"daemon failed": 1}),
            lambda r: r["legs"][1].update(ops=[]),
            lambda r: r["legs"][1]["ops"][0].update(n=0),
            lambda r: r["legs"][1]["ops"][0].update(p99Ms=float("nan")),
            lambda r: r["legs"][1]["stressors"].update(cpuBusyPct=None),
            lambda r: r["legs"][1]["stressors"].update(memUsedPctAtClock=None),
            lambda r: r["legs"][1]["liveness"].update(polls=0),
        ]
        for change in changes:
            with self.subTest(change=change):
                data = copy.deepcopy(original)
                change(data)
                with self.assertRaises(BenchError):
                    self.ingest(data)
                self.assertEqual(self.ctx.rows, [])


if __name__ == "__main__":
    unittest.main()
