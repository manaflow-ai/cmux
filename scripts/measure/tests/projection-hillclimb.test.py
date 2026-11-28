#!/usr/bin/env python3
"""scripts/measure/projection-scale/hillclimb.py: the ladder walk and scoring, measure.py replaced by a fake cost.
Run: python3 -I scripts/measure/tests/projection-hillclimb.test.py"""

from __future__ import annotations

import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "projection-scale"))
import hillclimb  # noqa: E402


class Fake(hillclimb.Climb):
    """Cost: raw beats level 3 by 20%, read-ahead off costs double; bytes do not matter."""

    def __init__(self, args, cost):
        super().__init__(args)
        self.cost = cost

    def run(self, setting):
        key = tuple(sorted(setting.items()))
        if key not in self.seen:
            self.tries += 1
            self.seen[key] = self.cost(setting)
        return self.seen[key]


def args(out: str, rounds: int = 3) -> SimpleNamespace:
    return SimpleNamespace(tree="t", profile="store-v6-8", steps="rg", rounds=rounds, min_gain=0.03,
                           out=out, bin=None, scratch=None)


class HillClimbTests(unittest.TestCase):
    def test_neighbours_stay_on_the_ladder(self):
        self.assertEqual(hillclimb.neighbours("CMUX_PROJECTION_ZSTD_LEVEL", 3), [1, 6])
        self.assertEqual(hillclimb.neighbours("CMUX_PROJECTION_ZSTD_LEVEL", 0), [-1])
        self.assertEqual(hillclimb.neighbours("CMUX_PROJECTION_READAHEAD_FILES", 1024), [256])

    def test_defaults_are_on_their_ladders(self):
        for knob, value in hillclimb.DEFAULTS.items():
            self.assertIn(value, hillclimb.LADDERS[knob])

    def test_climb_walks_down_the_level_ladder_to_raw(self):
        def cost(s):
            level = {0: 8.0, -1: 8.5, 1: 9.0, 3: 10.0, 6: 11.0, 9: 12.0, 19: 20.0}[s["CMUX_PROJECTION_ZSTD_LEVEL"]]
            return level * (2 if s["CMUX_PROJECTION_READAHEAD_FILES"] == 1 else 1)

        with tempfile.TemporaryDirectory() as out:
            got = Fake(args(out, rounds=10), cost).climb()
        self.assertEqual(got["best"]["CMUX_PROJECTION_ZSTD_LEVEL"], 0)
        self.assertEqual(got["best"]["CMUX_PROJECTION_READAHEAD_FILES"], 256)
        self.assertEqual(got["default_score_s"], 10.0)
        self.assertEqual(got["gain"], 0.2)

    def test_noise_under_min_gain_does_not_move(self):
        with tempfile.TemporaryDirectory() as out:
            got = Fake(args(out), lambda s: 10.0 - 0.01 * s["CMUX_PROJECTION_ZSTD_LEVEL"]).climb()
        self.assertEqual(got["best"], hillclimb.DEFAULTS)

    def test_score_refuses_a_failed_step(self):
        rows = [{"phase": "rg_cold", "wall_s": 1.5, "down_bytes": 10, "rc": 0},
                {"phase": "gitstatus_cold", "wall_s": 2.0, "rc": 1}]
        self.assertEqual(hillclimb.score(rows, ["rg"])[0], 1.5)
        self.assertIsNone(hillclimb.score(rows, ["rg", "gitstatus"])[0])


if __name__ == "__main__":
    unittest.main()
