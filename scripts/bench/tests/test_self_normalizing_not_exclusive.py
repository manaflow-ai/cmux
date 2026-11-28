"""Detector: a self-normalizing bench (a ratio of two arms run interleaved on one host) is never queued as an
exclusive measurement. Host load hits both arms of a pair alike and cancels, so a quiet host buys nothing and the
exclusive queue only delays it (G9's trace step waited 150+ minutes behind 65 measurements). cmuxterm-hq
docs/handbook/self-normalizing-metric-queued-exclusive.md."""
from __future__ import annotations

import contextlib
import io
import sys
import unittest
from pathlib import Path

BENCH_DIR = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(BENCH_DIR))

from benchlib.bench import BenchError, Context  # noqa: E402
from benchlib.registry import load_all  # noqa: E402

REF = "a" * 40


def context(bench, **args):
    return Context(bench=bench, build={"channel": "nightly", "version": "1", "sha": REF}, host_role="fleet",
                   host={"name": "fleet", "role": "fleet", "os": "", "chip": ""}, args={"ref": REF, **args},
                   dry_run=True)


def dry_run_command(bench) -> str:
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        try:
            bench.run(context(bench))
        except BenchError:
            pass
    return out.getvalue()


class SelfNormalizingNeverExclusive(unittest.TestCase):
    def test_every_self_normalizing_bench_queues_shared_with_no_measurement_slot(self):
        flagged = [b for b in load_all().values() if b.self_normalizing]
        self.assertTrue(flagged, "terminal-throughput-quick at least")
        for bench in flagged:
            with self.subTest(bench=bench.name):
                cmd = dry_run_command(bench)
                self.assertIn("dry run: cmux-ci run --class", cmd, "its run() reaches fleet_step")
                self.assertNotIn("--class exclusive", cmd)
                self.assertNotIn("--measurement", cmd)

    def test_the_paired_terminal_ratio_is_flagged(self):
        bench = load_all()["terminal-throughput-quick"]
        self.assertTrue(bench.self_normalizing)
        cmd = dry_run_command(bench)
        self.assertIn("--class isolated", cmd)
        self.assertIn("--display", cmd)

    def test_fleet_step_refuses_an_exclusive_or_measurement_step_for_one(self):
        bench = load_all()["terminal-throughput-quick"]
        for kwargs in ({}, {"step_class": "exclusive", "measurement": False}, {"step_class": "light"}):
            with self.subTest(**kwargs), self.assertRaisesRegex(BenchError, "never queues as an exclusive"):
                context(bench).fleet_step(bench.harness, **kwargs)

    def test_other_benches_keep_the_exclusive_default(self):
        bench = next(b for b in load_all().values() if not b.self_normalizing and "fleet" in b.hosts)
        out = io.StringIO()
        with contextlib.redirect_stdout(out), self.assertRaises(BenchError):
            context(bench).fleet_step("scripts/measure/x.sh")
        self.assertIn("--class exclusive --measurement", out.getvalue())


if __name__ == "__main__":
    unittest.main()
