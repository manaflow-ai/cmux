#!/usr/bin/env python3
"""bench_power.py guard (msg 2654): with --sample-idle, the app's stacks are sampled inside the
idle window, not after it. The 20-hidden-tabs app energy rises for a while and drops; a sample
taken after the window showed the app idle. The sample is kept only when the app is above 1 mW."""

from __future__ import annotations

import os
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
import bench_power as bp  # noqa: E402


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


class GuardTests(unittest.TestCase):
    def setUp(self):
        self.clock = FakeClock()
        self.started_at: list[float] = []
        self.app_energy_nj = 0
        self.folder = tempfile.mkdtemp()
        self.cwd = os.getcwd()
        os.chdir(self.folder)
        clock, started = self.clock, self.started_at
        test = self

        class FakeSample:
            def __init__(self, argv, **_kwargs):
                started.append(clock.now)
                Path(argv[argv.index("-file") + 1]).write_text("sample")

            def wait(self, timeout=None):
                return 0

        self.saved = (bp.time, bp.subprocess.Popen, bp.bm.owned, bp.counters, bp.powermetrics)
        bp.time = clock
        bp.subprocess.Popen = FakeSample
        bp.bm.owned = lambda pid, bundle: {pid: ("app", "cmux")}
        # (energy nJ, CPU ns, wakeups, footprint bytes); energy grows by the window's mW.
        bp.counters = lambda pid: (int(test.app_energy_nj * clock.now), 0, 0, 0)
        bp.powermetrics = lambda seconds: None

    def tearDown(self):
        bp.time, bp.subprocess.Popen, bp.bm.owned, bp.counters, bp.powermetrics = self.saved
        os.chdir(self.cwd)

    def measure(self, mw: float):
        self.app_energy_nj = mw * 1e6  # 1 mW = 1e6 nJ/s
        return bp.measure(42, "/Apps/cmux.app", "tabs20-hidden", 60, sample_idle=True)

    def test_the_sample_starts_inside_the_window(self):
        self.measure(4.0)
        self.assertEqual(len(self.started_at), 1, "no stack sample was taken")
        self.assertLess(self.started_at[0], 60, "the sample started after the measured window")

    def test_a_high_window_keeps_its_sample(self):
        self.measure(4.0)
        self.assertTrue(Path(self.folder, "app-tabs20-hidden.sample").exists())

    def test_a_normal_window_drops_its_sample(self):
        self.measure(0.2)
        self.assertFalse(Path(self.folder, "app-tabs20-hidden.sample").exists())


if __name__ == "__main__":
    unittest.main()
