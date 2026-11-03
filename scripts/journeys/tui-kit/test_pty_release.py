#!/usr/bin/env python3
"""pty_release.py's parts that need no app: the lsof field parser and the process tree. No fleet.

    python3 scripts/journeys/tui-kit/test_pty_release.py
"""
import os
import subprocess
import sys
import unittest
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pty_release  # noqa: E402


class Done:
    def __init__(self, out):
        self.stdout, self.returncode = out, 0


class Parse(unittest.TestCase):
    def test_lsof_fields_count_fds_per_process(self):
        out = "p100\ncShell\nf3\nf4\np200\nccmux\nf7\n"
        with mock.patch.object(subprocess, "run", return_value=Done(out)):
            self.assertEqual(pty_release.ptmx_holders(), {100: ("Shell", 2), 200: ("cmux", 1)})

    def test_tree_is_the_root_and_its_descendants(self):
        table = "  1     0\n 10     1\n 11    10\n 12    11\n 20     1\n"
        with mock.patch.object(subprocess, "run", return_value=Done(table)):
            self.assertEqual(pty_release.tree(10), {10, 11, 12})
            self.assertEqual(pty_release.tree(None), set())

    def test_a_sample_splits_the_daemon_tree_from_the_rest(self):
        with mock.patch.object(pty_release, "ptmx_holders", return_value={11: ("host", 3), 99: ("other", 2)}), \
                mock.patch.object(pty_release, "tree", return_value={10, 11}):
            s = pty_release.sample("x", None, 10)
        self.assertEqual((s["total"], s["daemon_tree"]), (5, 3))
        self.assertEqual(s["by_command"], {"host": 3, "other": 2})
        self.assertEqual(s["tree_by_pid"], {"11": ["host", 3]})


class Verdict(unittest.TestCase):
    def base(self, **kw):
        r = {"made": 50, "closes": [{"ok": True}] * 50,
             "samples": [{"at": "start", "daemon_tree": 1, "total": 9},
                         {"at": "before burst (50 tabs open)", "daemon_tree": 51, "total": 59},
                         {"at": "10 s after the burst", "t_s": 10.1, "daemon_tree": 1, "total": 9}],
             "fast": [{"t_s": 0.02, "daemon_tree": 40}, {"t_s": 1.03, "daemon_tree": 1}]}
        r.update(kw)
        return pty_release.verdict(r)

    def test_released_within_a_second_is_no_leak(self):
        v = self.base()
        self.assertEqual((v["count"], v["rise"], v["leak_suspect"]), ("daemon_tree", 50, False))
        self.assertEqual(v["at_1s"]["t_s"], 1.03)  # the real time of the sample, not its name

    def test_the_60_s_sample_shows_a_late_release(self):
        r = {"made": 50, "closes": [{"ok": True}] * 50,
             "samples": [{"at": "start", "daemon_tree": 1, "total": 9},
                         {"at": "before burst (50 tabs open)", "daemon_tree": 51, "total": 59},
                         {"at": "10 s after the burst", "t_s": 10.1, "daemon_tree": 51, "total": 59},
                         {"at": "60 s after the burst", "t_s": 60.0, "daemon_tree": 1, "total": 9}],
             "fast": [{"t_s": 1.03, "daemon_tree": 51}]}
        v = pty_release.verdict(r)
        self.assertEqual((v["at_10s"]["released"], v["at_60s"]["released"]), (0, 50))
        self.assertTrue(v["leak_suspect"])

    def test_kept_ptys_are_a_leak(self):
        v = self.base(fast=[{"t_s": 0.02, "daemon_tree": 51}, {"t_s": 1.2, "daemon_tree": 50}])
        self.assertTrue(v["leak_suspect"])

    def test_a_count_that_did_not_rise_is_not_measured_and_no_close_is_not_measured(self):
        flat = [{"at": "start", "daemon_tree": 1, "total": 9}, {"at": "before burst (50 tabs open)", "daemon_tree": 1, "total": 9}]
        self.assertIn("not_measured", self.base(samples=flat))
        self.assertIn("not_measured", self.base(closes=[{"ok": False}] * 50))


if __name__ == "__main__":
    unittest.main()
