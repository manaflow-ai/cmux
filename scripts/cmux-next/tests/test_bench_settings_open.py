#!/usr/bin/env python3
"""bench-settings-open.py counts only real opens. 2026-11-16: on a build where Cmd-W after Cmd-, closed
Home's dock tab instead of Settings, every other "warm open" re-selected the Settings tab that was still
open (3 ms) and the warm median read 8 ms; the real reopens took 27 ms. An open of a Settings tab already
open (`already_open`) is reported apart, never in the warm numbers."""

from __future__ import annotations

import importlib.util
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent


def load_bench():
    spec = importlib.util.spec_from_file_location("bench_settings_open", HERE / "bench-settings-open.py")
    module = importlib.util.module_from_spec(spec)
    saved = sys.argv
    sys.argv = saved[:1]
    try:
        spec.loader.exec_module(module)
    finally:
        sys.argv = saved
    return module


def opened(visible, already=None):
    result = {"tab_ms": visible, "visible_ms": visible, "gap_ms": 0.0}
    if already is not None:
        result["already_open"] = already
    return result


class SplitOpensTests(unittest.TestCase):
    def test_an_open_of_a_settings_tab_already_open_is_not_a_warm_open(self):
        bench = load_bench()
        runs = [[opened(180.0, False), opened(3.0, True), opened(27.0, False), opened(4.0, True)]]
        cold, warm, refocused = bench.split_opens(runs)
        self.assertEqual([o["visible_ms"] for o in cold], [180.0])
        self.assertEqual([o["visible_ms"] for o in warm], [27.0])
        self.assertEqual([o["visible_ms"] for o in refocused], [3.0, 4.0])

    def test_a_build_without_the_field_counts_every_open(self):
        bench = load_bench()
        runs = [[opened(180.0), opened(25.0), opened(26.0)]]
        cold, warm, refocused = bench.split_opens(runs)
        self.assertEqual(len(cold), 1)
        self.assertEqual(len(warm), 2)
        self.assertEqual(refocused, [])

    def test_a_cold_open_of_a_tab_already_open_is_not_cold(self):
        bench = load_bench()
        cold, warm, refocused = bench.split_opens([[opened(2.0, True), opened(25.0, False)]])
        self.assertEqual(cold, [])
        self.assertEqual([o["visible_ms"] for o in warm], [25.0])
        self.assertEqual(len(refocused), 1)


if __name__ == "__main__":
    unittest.main()
