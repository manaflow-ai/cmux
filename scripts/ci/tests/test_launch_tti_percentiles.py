"""launch_tti_check's fixed-slot percentiles (startup-matrix): KIND:FRONT*N plans, nearest-rank p50/p95, rounds over
the load bound left out, and a cell with too few quiet rounds refused rather than posted.

Run: python3 -I scripts/ci/tests/test_launch_tti_percentiles.py"""

import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
try:
    import launch_tti_check as T  # noqa: E402
except ImportError as error:  # relaunch_restore_check needs macOS-only pieces on some hosts
    raise unittest.SkipTest(f"launch_tti_check does not import here: {error}")


def rounds(times, load_per_core=0.2, kind="cold_install", front="terminal"):
    return [{"kind": kind, "front": front, "input_ms": t, "load_1m": load_per_core * 10, "load_per_core": load_per_core}
            for t in times]


class PlanTests(unittest.TestCase):
    def test_star_repeats_a_round(self):
        self.assertEqual(T.parse_plan("cold_install:terminal*20"), [("cold_install", "terminal")] * 20)

    def test_star_mixes_with_plain_items(self):
        self.assertEqual(T.parse_plan("warm:chat,cold_install:terminal*2"),
                         [("warm", "chat"), ("cold_install", "terminal"), ("cold_install", "terminal")])

    def test_star_takes_a_bounded_count(self):
        for bad in ("cold_install:terminal*0", "cold_install:terminal*x", "cold_install:terminal*101"):
            with self.assertRaises(ValueError):
                T.parse_plan(bad)


class PercentileTests(unittest.TestCase):
    def test_nearest_rank_of_twenty(self):
        values = [float(v) for v in range(1, 21)]
        self.assertEqual(T.nearest_rank(values, 50), 10.0)
        self.assertEqual(T.nearest_rank(values, 95), 19.0)
        self.assertIsNone(T.nearest_rank([], 50))

    def test_quiet_rounds_give_p50_and_p95_with_their_load(self):
        cell = T.percentiles(rounds(range(1000, 3000, 100)), 0.5, 5)["cold_install_terminal"]
        self.assertEqual((cell["n"], cell["p50_ms"], cell["p95_ms"], cell["over_load"]), (20, 1900, 2800, 0))
        self.assertEqual(cell["load_per_core_max"], 0.2)
        self.assertNotIn("refused", cell)

    def test_rounds_over_the_bound_are_left_out(self):
        rows = rounds([1000] * 6) + rounds([9000] * 4, load_per_core=1.2)
        cell = T.percentiles(rows, 0.5, 5)["cold_install_terminal"]
        self.assertEqual((cell["n"], cell["over_load"], cell["p95_ms"]), (6, 4, 1000))

    def test_too_few_quiet_rounds_is_refused(self):
        rows = rounds([1000] * 3) + rounds([9000] * 17, load_per_core=0.9)
        cell = T.percentiles(rows, 0.5, 5)["cold_install_terminal"]
        self.assertIsNone(cell["p50_ms"])
        self.assertIsNone(cell["p95_ms"])
        self.assertIn("under 5", cell["refused"])

    def test_a_round_without_a_key_counts_as_unmeasured(self):
        rows = rounds([1000] * 5) + rounds([None])
        cell = T.percentiles(rows, 0.5, 5)["cold_install_terminal"]
        self.assertEqual((cell["n"], cell["unmeasured"]), (5, 1))


if __name__ == "__main__":
    unittest.main()
