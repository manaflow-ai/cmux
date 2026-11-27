#!/usr/bin/env python3
"""tests/group_reaper.py: a test killed before its tearDown still leaves no detached group or temp dir behind."""

import importlib.util
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
# By path: `python3 -I` puts no script folder on sys.path.
_spec = importlib.util.spec_from_file_location("process_gone", ROOT / "tests" / "process_gone.py")
process_gone = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(process_gone)

# A "test" that starts two detached groups (one named directly, one through a pid file, as web-overlay.sh writes
# dev-server.pid), prints their ids, and is then SIGKILLed: no tearDown runs.
KILLED_TEST = r"""
import importlib.util, os, signal, subprocess, sys
spec = importlib.util.spec_from_file_location("group_reaper", sys.argv[1])
group_reaper = importlib.util.module_from_spec(spec); spec.loader.exec_module(group_reaper)
tmp = sys.argv[2]
reaper = group_reaper.Reaper()
a = subprocess.Popen(["sleep", "300"], start_new_session=True)
b = subprocess.Popen(["sleep", "300"], start_new_session=True)
open(os.path.join(tmp, "b.pid"), "w").write("%d\n" % b.pid)
reaper.group(a.pid)
reaper.pidfile(os.path.join(tmp, "b.pid"))
reaper.remove(tmp)
print(a.pid, b.pid, flush=True)
os.kill(os.getpid(), signal.SIGKILL)
"""


class GroupReaperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp(prefix="group-reaper-"))
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_a_killed_test_leaves_no_group_and_no_temp_dir(self):
        work = self.tmp / "work"
        work.mkdir()
        run = subprocess.run([sys.executable, "-I", "-c", KILLED_TEST, str(ROOT / "tests" / "group_reaper.py"), str(work)],
                             capture_output=True, text=True, timeout=60)
        self.assertEqual(run.returncode, -9, run.stderr)
        a, b = (int(x) for x in run.stdout.split())
        self.assertTrue(process_gone.group_died(a, within=15), "the group named directly is killed")
        self.assertTrue(process_gone.group_died(b, within=15), "the group its pid file names is killed")
        for _ in range(150):
            if not work.exists():
                break
            time.sleep(0.1)
        self.assertFalse(work.exists(), "the temp dir is removed")

    def test_close_kills_and_waits(self):
        spec = importlib.util.spec_from_file_location("group_reaper", ROOT / "tests" / "group_reaper.py")
        group_reaper = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(group_reaper)
        reaper = group_reaper.Reaper()
        child = subprocess.Popen(["sleep", "300"], start_new_session=True)
        reaper.group(child.pid)
        reaper.close()
        self.assertEqual(child.wait(timeout=15), -9)


if __name__ == "__main__":
    unittest.main()
