"""interactive-lateness: a saved probe line becomes rows; a live run on this host prints rows."""
from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.interactive_lateness import BENCH  # noqa: E402

# Run A on Leo's Mac as RFD 0072 records it (2026-11-23 10:11Z), in the probe's schema.
LINE = {"schema": "interactive-lateness/v1", "label": "before", "os": "macOS 26.1",
        "lateness_ms": {"wakes": 5196, "p50": 1.61, "p95": 2.54, "p99": 2.74, "max": 10.9, "over_5ms_pct": 0.17,
                        "over_16ms_pct": 0.0},
        "cpu": {"busy_pct": 91.3}, "memory": {"pressure_level": 2, "free_pct": 40},
        "swap": {"used_mb": 23450.0, "swapout_mb_per_min": 12.5}, "thermal": {}, "hid_idle_s": 0.0,
        "errors": {"thermal": "example"}}


def ctx() -> Context:
    return Context(bench=BENCH, build={"channel": "nightly", "version": None, "sha": None}, host_role="local-readonly",
                   host={"name": "test", "role": "local-readonly", "os": "", "chip": ""},
                   timestamp="2026-11-23T00:00:00Z")


class InteractiveLatenessTest(unittest.TestCase):
    def test_ingest_run_a(self):
        c = ctx()
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "a.json"
            p.write_text(json.dumps(LINE) + "\n")
            BENCH.ingest(c, p)
        rows = {r["metric"]: r for r in c.rows}
        self.assertEqual(rows["lateness_p50"]["value"], 1.61)
        self.assertEqual(rows["lateness_p50"]["n"], 5196)
        self.assertEqual(rows["cpu_busy"]["value"], 91.3)
        self.assertEqual(rows["memory_free"]["better"], "higher")
        self.assertEqual(rows["swapout_rate"]["labels"], {"label": "before", "window": "per_min"})
        self.assertEqual(c.host["os"], "macOS 26.1")
        self.assertTrue(any("thermal: example" in n for n in c.notes))

    def test_rejects_other_schema(self):
        with tempfile.TemporaryDirectory() as tmp:
            p = Path(tmp) / "x.json"
            p.write_text('{"schema": "other"}\n')
            with self.assertRaises(BenchError):
                BENCH.ingest(ctx(), p)

    def test_live_run_here(self):
        c = ctx()
        c.args = {"seconds": "0.3", "label": "t"}
        BENCH.run(c)
        self.assertIn("lateness_p50", {r["metric"] for r in c.rows})


if __name__ == "__main__":
    unittest.main()
