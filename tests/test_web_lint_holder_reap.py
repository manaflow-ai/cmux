"""A killed web lint leaves its ~1.9 GB lint tree in the temp folder (acpmux session TMPDIRs grew +39 GB/day on
fs-agent-lane-40, 2026-11-27): the next lint removes holders whose owner is gone, and SIGTERM runs tree_of's cleanup."""
import importlib.util
import os
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SOURCE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("web_lint_prepush_reap", SOURCE / "scripts" / "web_lint_prepush.py")
lint = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = lint
spec.loader.exec_module(lint)


def dead_pid() -> int:
    child = subprocess.Popen([sys.executable, "-c", "pass"])
    child.wait()
    return child.pid


class SweepOrphanHolders(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        patch = mock.patch.object(tempfile, "tempdir", self.tmp.name)
        patch.start()
        self.addCleanup(patch.stop)
        self.root = Path(self.tmp.name)

    def holder(self, name, pid=None, age=0.0):
        path = self.root / (lint.HOLDER_PREFIX + name)
        (path / "tree").mkdir(parents=True)
        (path / "tree" / "file").write_text("x" * 1000)
        if pid is not None:
            (path / lint.HOLDER_OWNER).write_text(str(pid))
        if age:
            old = time.time() - age
            os.utime(path, (old, old))
        return path

    def test_dead_owner_removed_live_owner_kept(self):
        gone = self.holder("dead", pid=dead_pid())
        live = self.holder("live", pid=os.getpid())
        self.assertEqual(lint.sweep_orphan_holders(self.root), 1)
        self.assertFalse(gone.exists())
        self.assertTrue(live.exists())

    def test_holder_without_owner_goes_by_age(self):
        fresh = self.holder("fresh")
        old = self.holder("old", age=3600)
        lint.sweep_orphan_holders(self.root)
        self.assertTrue(fresh.exists())
        self.assertFalse(old.exists())

    def test_other_folders_untouched(self):
        other = self.root / "something-else"
        other.mkdir()
        lint.sweep_orphan_holders(self.root)
        self.assertTrue(other.exists())

    def test_make_holder_records_owner_and_sweeps(self):
        gone = self.holder("dead", pid=dead_pid())
        made = lint.make_holder(self.root)
        self.assertFalse(gone.exists())
        self.assertEqual((made / lint.HOLDER_OWNER).read_text(), str(os.getpid()))

    def test_sigterm_inside_raises_systemexit_and_restores(self):
        before = signal.getsignal(signal.SIGTERM)
        with self.assertRaises(SystemExit):
            with lint.terminate_cleanly():
                os.kill(os.getpid(), signal.SIGTERM)
                time.sleep(1)
        self.assertEqual(signal.getsignal(signal.SIGTERM), before)


if __name__ == "__main__":
    unittest.main()
