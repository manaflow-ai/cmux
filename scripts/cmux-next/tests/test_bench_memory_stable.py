#!/usr/bin/env python3
"""bench_memory --stable waits for a still footprint before a sample (goal memory-per-chat).

A perf-idle-ab run (cmux22, 2026-11-18, 3 rounds a build) read the empty launch at 868, 925 and 1063 MB for one
build: in some rounds the sample came while the built-in extension's renderer still loaded its lists (peak 1.1 GB,
settling near 80 MB), and the chats-over-empty ratio swung 1.29-1.46x with it. Off macOS the libproc and libSystem
handles are stubs; the wait itself is pure."""

from __future__ import annotations

import ctypes
import sys
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
if sys.platform == "darwin":
    import bench_memory as bm  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import bench_memory as bm  # noqa: E402


class StableTests(unittest.TestCase):
    def wait(self, reads, pct=1, limit=180):
        it = iter(reads)
        slept = []
        return bm.wait_still(lambda: next(it), pct, 5, limit, sleep=slept.append), slept

    def test_a_loading_helper_is_waited_out(self):
        got, slept = self.wait([1060.0, 990.0, 930.0, 926.0])
        self.assertTrue(got["still"])
        self.assertEqual(got["waited_s"], 15)
        self.assertEqual(slept, [5, 5, 5])

    def test_a_still_app_costs_one_wait(self):
        got, _ = self.wait([925.0, 924.0])
        self.assertEqual((got["still"], got["waited_s"]), (True, 5))

    def test_the_wait_ends_at_its_limit(self):
        got, slept = self.wait([1000.0 + 50 * i for i in range(10)], limit=20)
        self.assertFalse(got["still"])
        self.assertEqual(len(slept), 4)

    def test_is_still_needs_two_reads(self):
        self.assertFalse(bm.is_still([900.0], 1))
        self.assertTrue(bm.is_still([900.0, 905.0], 1))
        self.assertFalse(bm.is_still([900.0, 1000.0], 1))


if __name__ == "__main__":
    unittest.main()
