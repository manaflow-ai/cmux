"""typing: a composer-typing.bench.ts log (load modes, Actions time stamps) -> rows; invalid loads get no timing row."""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benches.typing import BENCH  # noqa: E402

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "typing"


def find(rows, metric, **labels):
    got = [r for r in rows if r["metric"] == metric and all(r["labels"].get(k) == v for k, v in labels.items())]
    assert len(got) == 1, (metric, labels, len(got))
    return got[0]


def context(**args):
    return Context(bench=BENCH, build={"channel": "sha", "version": None, "sha": "d" * 40}, host_role="fleet",
                   timestamp="2026-11-17T00:00:00Z", args=args)


class TypingTest(unittest.TestCase):
    def test_valid_load_rows(self):
        ctx = context()
        BENCH.ingest(ctx, FIXTURES / "composer-typing.log")
        chromium = {"engine": "chromium", "load": "L1", "transcript_rows": "60"}
        self.assertEqual(find(ctx.rows, "valid", **chromium)["value"], 1)
        self.assertEqual(find(ctx.rows, "target_met", **chromium)["value"], 0)
        paint = find(ctx.rows, "keydown_to_paint", **chromium)
        self.assertEqual((paint["n"], paint["value"]), (4, 7.5))  # median of 4, 6, 9, 20
        self.assertEqual(find(ctx.rows, "keydown_to_paint_p95_ms", **chromium)["value"], 18.5)
        self.assertEqual(find(ctx.rows, "keydown_to_paint_p99_ms", **chromium)["value"], 19.7)
        self.assertEqual(find(ctx.rows, "frames_over_16ms", **chromium)["value"], 1)
        self.assertEqual(find(ctx.rows, "keydown_to_frame", **chromium)["n"], 4)

    def test_invalid_load_keeps_its_error_and_no_timing_row(self):
        ctx = context()
        BENCH.ingest(ctx, FIXTURES / "composer-typing.log")
        webkit = [r for r in ctx.rows if r["labels"].get("engine") == "webkit"]
        self.assertEqual(sorted(r["metric"] for r in webkit), ["target_met", "valid"])
        self.assertEqual(find(ctx.rows, "valid", engine="webkit", load="L3")["value"], 0)
        self.assertTrue(any("webkit/L3: invalid; requested stream rate" in n for n in ctx.notes))

    def test_not_a_log(self):
        with self.assertRaises(BenchError):
            BENCH.ingest(context(), Path(__file__))

    def test_legacy_modes_are_refused(self):
        path = BENCH_DIR / "tests" / "fixtures" / "typing" / "legacy.tmp"
        path.write_text('COMPOSER-TYPING [{"engine": "chromium", "mode": "idle", "to_frame_p95": 3}]\n')
        try:
            with self.assertRaises(BenchError):
                BENCH.ingest(context(), path)
        finally:
            path.unlink()

    def test_command_runs_the_bench_on_linux_with_its_args(self):
        cmd = BENCH.command(context(modes="L0,L1", engines="chromium", keys="300"))
        self.assertEqual(cmd[:4], ["cmux-ci", "test", "--setup", "playwright"])
        script = cmd[-1]
        self.assertIn("bun bench/composer-typing.bench.ts --mode L0,L1 --engines chromium --lengths 60 --keys 300 "
                      "--gap 20", script)
        self.assertIn('tee "${FAST_CHECKS_OUT:-/tmp}/composer-typing.log"', script)
        self.assertTrue((BENCH_DIR.parents[1] / BENCH.harness).exists())


if __name__ == "__main__":
    unittest.main()
