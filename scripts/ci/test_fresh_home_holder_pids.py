#!/usr/bin/env python3
"""fresh_home_launch_smoke.holder_pids and own_pids: a run's cleanup stops the cmux-holder processes its app's daemon
started, found by the executable's real path under the run's root, never by name alone. On 2026-11-26 five holders
left by earlier runs held every PTY of a CI Mac (510 shells, kern.tty.ptmx_max 511) and the next launch-tti seed failed
"Device not configured (os error 6)".

No Mac: the process list and libproc's proc_pidpath are replaced. So this proves which pids are picked, NOT that
macOS reports a holder's path this way.
Run: python3 -I scripts/ci/test_fresh_home_holder_pids.py"""
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fresh_home_launch_smoke as M  # noqa: E402


class HolderPids(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="holder-pids-test-"))
        self.addCleanup(shutil.rmtree, self.base, ignore_errors=True)
        self.root = self.base / "cmux-fresh-abc"
        self.other = self.base / "cmux-fresh-xyz"
        exe = "h/Library/Application Support/cmux-tui/host-exe/6ab3/cmux-holder"
        for root in (self.root, self.other):
            (root / exe).parent.mkdir(parents=True)
            (root / exe).write_text("")
        self.mine = str(self.root / exe)
        self.theirs = str(self.other / exe)
        self.processes = [
            (101, "cmux-holder --socket /tmp/cmux-hd-501/c0ea.sock --owner com.cmuxterm.app.nightly:-@99"),
            (102, "cmux-holder --socket /tmp/cmux-hd-501/bff9.sock --owner com.cmuxterm.app.nightly:-@98"),
            (103, "/bin/zsh -l"),
            (104, "cmux-holder --socket /tmp/cmux-hd-501/dead.sock --owner com.cmuxterm.app.nightly:-@97"),
        ]
        self.paths = {101: self.mine, 102: self.theirs, 103: self.mine, 104: None}

    def picked(self, root):
        with mock.patch.object(M, "user_processes", lambda: self.processes), \
                mock.patch.object(M, "executable_path", lambda pid: self.paths[pid]):
            return M.holder_pids(root)

    def test_only_this_runs_holder_is_picked(self):
        self.assertEqual(self.picked(self.root), [101])

    def test_a_root_named_by_another_spelling_still_matches(self):
        # /tmp and /private/tmp on a Mac: the root and the reported path differ but resolve to one folder.
        alias = self.base / "alias"
        alias.symlink_to(self.root)
        self.assertEqual(self.picked(alias), [101])

    def test_a_process_not_named_cmux_holder_is_never_picked_even_under_the_root(self):
        self.assertNotIn(103, self.picked(self.root))

    def test_own_pids_includes_the_holder(self):
        with mock.patch.object(M, "pids_under", lambda root: [7]), \
                mock.patch.object(M, "terminal_host_pids", lambda root: []), \
                mock.patch.object(M, "holder_pids", lambda root: [101]):
            self.assertEqual(M.own_pids(self.root), [7, 101])


if __name__ == "__main__":
    unittest.main()
