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


if __name__ == "__main__":
    unittest.main()
