#!/usr/bin/env python3
"""bench_memory's launch_state and Chief wait (goal ram-baseline): an idle launch lands in one of two
states, the Chief up (about +145 MB: its acpmux daemon, router, __agent-host, cmux mcp serve,
optchat-chief, a second WebContent) or not with an agent page on screen. A median of both is their mix,
so each sample says which state it measured, and --chief-steady waits (bounded) for the Chief's
processes to stop changing before the window. Off macOS the libproc handles are stubs."""

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

CHIEF = {"pid": 8, "kind": "tui-daemon", "command": "bin/cmux-tui __agent-host optchat-chief"}
APP = {"pid": 1, "kind": "app", "command": "Contents/MacOS/cmux NEXT"}
PAGES = [{"origin": "cmux-page://cmux.agent", "hidden": False}, {"origin": "cmux-page://cmux.agent", "hidden": True},
         {"origin": "about:", "hidden": False}]


class LaunchState(unittest.TestCase):
    def test_chief_up(self):
        got = bm.launch_state({"processes": [APP, CHIEF], "attribution": {"pages": PAGES[1:]}}, None)
        self.assertEqual(got, {"chief_up": True, "chief_processes": 1, "visible_agent_pages": 0})

    def test_agent_page_visible(self):
        before = {"chief_processes": 0, "steady": True, "waited_s": 10.0}
        got = bm.launch_state({"processes": [APP], "attribution": {"pages": PAGES}}, before)
        self.assertEqual(got["visible_agent_pages"], 1)
        self.assertFalse(got["chief_up"])
        self.assertFalse(got["chief_changed_in_window"])

    def test_chief_started_in_window(self):
        before = {"chief_processes": 0, "steady": False, "waited_s": 60.0}
        got = bm.launch_state({"processes": [APP, CHIEF]}, before)
        self.assertTrue(got["chief_changed_in_window"])
        self.assertIsNone(got["visible_agent_pages"])  # no attribution, no page list


class ChiefSteady(unittest.TestCase):
    def run_wait(self, counts, bound):
        clock = [0.0]
        seq = iter(counts)
        last = [0]

        def count(*_):
            last[0] = next(seq, last[0])
            return last[0]

        def sleep(s):
            clock[0] += s
        with mock.patch.object(bm, "chief_processes", side_effect=count), \
             mock.patch.object(bm.time, "monotonic", side_effect=lambda: clock[0]), \
             mock.patch.object(bm.time, "sleep", side_effect=sleep):
            return bm.wait_chief_steady(1, "/b", bound)

    def test_settles(self):
        got = self.run_wait([0, 0, 2, 2, 3], bound=60)  # starts at 4 s, last change at 6 s
        self.assertEqual(got["chief_processes"], 3)
        self.assertTrue(got["steady"])
        self.assertLessEqual(got["waited_s"], 18)

    def test_bounded(self):
        got = self.run_wait(list(range(100)), bound=30)  # changes every read: gives up at the bound
        self.assertFalse(got["steady"])
        self.assertLessEqual(got["waited_s"], 32)


if __name__ == "__main__":
    unittest.main()
