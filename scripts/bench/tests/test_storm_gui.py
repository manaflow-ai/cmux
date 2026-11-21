"""storm-gui: an acpmux-429-storm-gui.sh output line -> rows."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.storm_gui import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "storm-gui"


class StormGuiTest(unittest.TestCase):
    def ingest(self):
        ctx = Context(bench=BENCH, build={"channel": "nightly"}, host_role="fleet", timestamp="2026-11-19T00:00:00Z")
        BENCH.ingest(ctx, FIXTURES / "sample.log")
        return ctx

    def test_rows(self):
        ctx = self.ingest()
        got = {r["metric"]: r["value"] for r in ctx.rows}
        self.assertEqual(got["lost"], 0.0)
        self.assertEqual(got["pane_missing"], 1.0)
        self.assertEqual(got["model_requests_in_storm"], 38.0)
        self.assertEqual(got["first_reply_after_lift"], 11.9)
        self.assertEqual(got["notice_missing"], 0.0)
        self.assertEqual({r["labels"]["retry_after"] for r in ctx.rows}, {"none"})
        self.assertEqual(ctx.host.get("name"), "cmux12")

    def test_not_a_log(self):
        ctx = Context(bench=BENCH, build={"channel": "local"}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.ingest(ctx, Path(__file__))

    def test_needs_a_published_app(self):
        ctx = Context(bench=BENCH, build={"channel": "sha", "sha": "d" * 40}, host_role="fleet")
        with self.assertRaises(BenchError):
            BENCH.harness_args(ctx)
        ctx = Context(bench=BENCH, build={"channel": "nightly"}, host_role="fleet", args={"storm": "300"})
        self.assertEqual(sorted(BENCH.harness_args(ctx)), ["app=nightly", "storm=300"])


if __name__ == "__main__":
    unittest.main()
