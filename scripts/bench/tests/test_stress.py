"""stress: a stress-bench.py report -> rows. The fixture has the harness's report shape with made-up numbers (four
angles measured, memory failed to launch, the scale stress window lost the keyboard)."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.stress import BENCH, METRICS  # noqa: E402

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "stress" / "report.json"


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


def context():
    return Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                   timestamp="2026-11-21T00:00:00Z")


class StressTest(unittest.TestCase):
    def setUp(self):
        self.ctx = context()
        BENCH.ingest(self.ctx, FIXTURE)
        self.rows = self.ctx.rows

    def test_every_metric_per_angle_and_arm(self):
        for angle in ("cpu", "chats", "cli"):
            for arm in ("baseline", "stress"):
                for _, metric, _, _ in METRICS:
                    find(self.rows, metric, angle=angle, arm=arm)

    def test_values_and_units(self):
        cpu = lambda metric, arm="stress": find(self.rows, metric, angle="cpu", arm=arm)  # noqa: E731
        self.assertEqual(cpu("frame_p95")["value"], 33.4)
        self.assertEqual(cpu("frame_p95", "baseline")["value"], 9.1)
        self.assertEqual(cpu("dropped_frames")["unit"], "%")
        self.assertEqual(cpu("input_latency_p95")["value"], 48.0)
        self.assertEqual(cpu("input_latency_p95")["n"], 190)
        self.assertEqual(cpu("frame_p50")["n"], 1200)
        self.assertEqual(cpu("daemon_rtt_p95")["value"], 16.0)
        self.assertEqual(cpu("hangs")["value"], 7.0)
        self.assertEqual(cpu("hangs")["unit"], "count")
        self.assertEqual(find(self.rows, "footprint", angle="chats", arm="stress")["value"], 2100.0)
        self.assertEqual(cpu("app_cpu")["better"], "lower")

    def test_conditions_do_not_judge(self):
        load = find(self.rows, "load_avg_1m", angle="cpu", arm="stress")
        self.assertEqual((load["value"], load["better"]), (96.0, "none"))
        self.assertEqual(find(self.rows, "swap_used", angle="cli", arm="baseline")["better"], "none")

    def test_unfocused_window_has_no_input_rows(self):
        self.assertFalse([r for r in self.rows if r["labels"] == {"angle": "scale", "arm": "stress"}
                          and r["metric"].startswith("input_")])
        find(self.rows, "frame_p95", angle="scale", arm="stress")
        self.assertTrue(any("never had the keyboard" in n for n in self.ctx.notes))

    def test_failures_and_notes(self):
        self.assertFalse([r for r in self.rows if r["labels"].get("angle") == "memory"])
        self.assertTrue(any("memory: no-gui-session" in n for n in self.ctx.notes))
        self.assertTrue(any("chat 11 did not open" in n for n in self.ctx.notes))
        self.assertEqual(self.ctx.host["name"], "cmux20-bench")
        self.assertEqual(self.ctx.host["os"], "macOS 27.0")

    def test_metric_identity_is_unique(self):
        keys = [(r["metric"], tuple(sorted(r["labels"].items()))) for r in self.rows]
        self.assertEqual(len(keys), len(set(keys)))

    def test_rejects_other_reports(self):
        with tempfile.TemporaryDirectory() as tmp:
            other = Path(tmp) / "r.json"
            other.write_text(json.dumps({"runs": []}))
            with self.assertRaises(BenchError):
                BENCH.ingest(context(), other)
            empty = Path(tmp) / "e.json"
            empty.write_text(json.dumps({"stress": {"angles": {"cpu": {"notes": []}}, "failures": []}}))
            with self.assertRaises(BenchError):
                BENCH.ingest(context(), empty)

    def test_dry_run_command(self):
        ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "a" * 40}, host_role="fleet",
                      args={"angles": "cpu,memory", "window": "10"}, dry_run=True, timestamp="2026-11-21T00:00:00Z")
        printed = []
        import builtins
        real = builtins.print
        builtins.print = lambda *a, **k: printed.append(" ".join(str(x) for x in a))
        try:
            with self.assertRaises(BenchError):
                BENCH.run(ctx)
        finally:
            builtins.print = real
        line = "\n".join(printed)
        for part in ("scripts/measure/split-spring.sh", "--class exclusive", "--measurement", "--label bench",
                     "--arg=--suite=stress", "--arg=--angles=cpu,memory", "--arg=--window=10", "--ref " + "a" * 40,
                     "--display"):
            self.assertIn(part, line)

    def test_unknown_angle(self):
        ctx = Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "a" * 40}, host_role="fleet",
                      args={"angles": "cpu,gpu"}, dry_run=True, timestamp="2026-11-21T00:00:00Z")
        with self.assertRaisesRegex(BenchError, "unknown angles"):
            BENCH.run(ctx)


if __name__ == "__main__":
    unittest.main()
