#!/usr/bin/env python3
"""launch-matrix-growth.py names the process of the tree that spends the idle bursts (RFD 0134 Table 2c)."""
import importlib.util
import json
from pathlib import Path
import unittest

HERE = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location("launch_matrix_growth", HERE.parent / "launch-matrix-growth.py")
lmg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lmg)


def line(minute, cpu, top):
    return "LM-GROWTH " + json.dumps({"minute": minute, "cpu_pct": cpu, "top": top})


def proc(name, cpu, pid=10, written=0.0, threads=()):
    return {"pid": pid, "name": name, "cpu_pct": cpu, "written_mb": written,
            "threads": [{"name": t, "cpu_pct": c} for t, c in threads]}


LOG = [
    "LM host cmux13s",
    'LM-GROWTH {"label": "growth", "minute": 0, "procs": 21}',  # the open line: no cpu_pct, not a minute
    line(1, 2.6, [proc("cmux", 1.5), proc("cmux-tui", 1.0, pid=11)]),
    line(2, 92.0, [proc("cmux-tui", 85.0, pid=11, written=120.0, threads=[("tokio-runtime-worker", 80.0)]),
                   proc("cmux", 5.0)]),
    line(3, 108.0, [proc("cmux-tui", 100.0, pid=11, written=123.0, threads=[("tokio-runtime-worker", 96.0)]),
                    proc("cmux Helper (Renderer)", 6.0, pid=12)]),
    line(4, 3.0, [proc("cmux", 2.0)]),
    "LM-GROWTH not json",
]


class Summary(unittest.TestCase):
    def test_burst_minutes_name_their_top_process_and_thread(self):
        bursts, _, _ = lmg.summarize(LOG)
        self.assertEqual([b["minute"] for b in bursts], [2, 3])
        self.assertEqual({b["process"] for b in bursts}, {"cmux-tui"})
        self.assertEqual(bursts[0]["thread"], "tokio-runtime-worker")
        self.assertAlmostEqual(bursts[1]["share"], 0.926, places=3)

    def test_owners_rank_by_cpu_seconds_and_count_burst_cpu_apart(self):
        _, owners, verdict = lmg.summarize(LOG)
        self.assertEqual(owners[0]["name"], "cmux-tui")
        self.assertEqual(owners[0]["cpu_s"], round((1.0 + 85.0 + 100.0) * 0.6, 1))
        self.assertEqual(owners[0]["burst_cpu_s"], round(185.0 * 0.6, 1))
        self.assertEqual(owners[0]["burst_top_minutes"], [2, 3])
        self.assertEqual(owners[0]["written_mb"], 243.0)
        self.assertEqual(verdict["process"], "cmux-tui")
        self.assertEqual(verdict["burst_minutes"], 2)
        self.assertGreater(verdict["share_of_burst_cpu"], 0.9)

    def test_no_burst_gives_no_verdict(self):
        bursts, owners, verdict = lmg.summarize([line(1, 3.0, [proc("cmux", 3.0)])])
        self.assertEqual(bursts, [])
        self.assertIsNone(verdict)
        self.assertEqual(owners[0]["burst_cpu_s"], 0.0)

    def test_threshold_is_a_flag(self):
        bursts, _, _ = lmg.summarize(LOG, burst_pct=100.0)
        self.assertEqual([b["minute"] for b in bursts], [3])


if __name__ == "__main__":
    unittest.main()
