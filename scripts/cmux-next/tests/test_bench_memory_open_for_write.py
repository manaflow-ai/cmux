#!/usr/bin/env python3
"""The idle disk census names the files each process writes (goal idle-gpu-disk).

A Mac idle run read the acpmux daemon writing 15 MB/h with 10 idle agents while the census, which walked only
the scratch HOME and the account's cmux folders, saw no daemon file change: the writes landed outside those
roots or in files deleted before the window ended. The census now walks the whole scratch (HOME and TMPDIR)
and `/tmp/acpmux-<uid>`, and lists the regular files each process holds open for writing (`lsof -F patn`)."""

from __future__ import annotations

import ctypes
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
if sys.platform == "darwin":
    import bench_memory as bm  # noqa: E402
else:
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import bench_memory as bm  # noqa: E402

LSOF = "\n".join([
    "p110",
    "fcwd", "ar", "tDIR", "n/tmp/scratch/home",
    "f3", "aw", "tREG", "n/tmp/scratch/home/.acpmux/daemon.log",
    "f4", "au", "tREG", "n/tmp/scratch/tmp/acpmux/spool.db-wal",
    "f5", "ar", "tREG", "n/tmp/scratch/home/.acpmux/config.toml",
    "f6", "au", "tunix", "n->0x1234",
    "p100",
    "f7", "au", "tREG", "n/tmp/scratch/home/Library/state/workspace-registry.sqlite3-wal",
    "f8", "aw", "tREG", "n/tmp/scratch/home/.acpmux/daemon.log",
    "p999",
    "f3", "aw", "tREG", "n/elsewhere/not-ours.log",
    "",
])


class OpenForWrite(unittest.TestCase):
    def test_lists_regular_files_open_for_writing_by_kind(self):
        got = bm.parse_open_for_write(LSOF, {110: "acpmux-daemon", 100: "app"})
        self.assertEqual(got, {
            "acpmux-daemon": ["/tmp/scratch/home/.acpmux/daemon.log", "/tmp/scratch/tmp/acpmux/spool.db-wal"],
            "app": ["/tmp/scratch/home/.acpmux/daemon.log",
                    "/tmp/scratch/home/Library/state/workspace-registry.sqlite3-wal"],
        })

    def test_no_processes_runs_nothing(self):
        with mock.patch.object(bm.subprocess, "run") as run:
            self.assertEqual(bm.open_for_write({}), {})
        run.assert_not_called()

    def test_lsof_failure_reads_empty(self):
        with mock.patch.object(bm.subprocess, "run", side_effect=OSError("no lsof")):
            self.assertEqual(bm.open_for_write({110: "acpmux-daemon"}), {})


class Roots(unittest.TestCase):
    def test_roots_cover_the_whole_scratch(self):
        with tempfile.TemporaryDirectory() as scratch:
            home = os.path.join(scratch, "home")
            os.makedirs(os.path.join(home, "Library"))
            os.makedirs(os.path.join(scratch, "tmp"))
            with mock.patch.object(bm, "STORE_HOME", home), mock.patch.object(bm, "saved_state_dir", return_value=None):
                roots = bm.store_roots("/nonexistent/cmux.app")
            real = os.path.realpath(scratch)
            # The scratch, or a root above it (a TMPDIR under /tmp/acpmux-<uid>), is walked: TMPDIR's files too.
            self.assertTrue(any(real == root or real.startswith(root + os.sep) for root in roots), roots)
            self.assertNotIn(os.path.realpath(home), roots)  # nested in the scratch: walked once


if __name__ == "__main__":
    unittest.main()
