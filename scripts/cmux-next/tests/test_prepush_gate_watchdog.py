#!/usr/bin/env python3
"""prepush-gate.py never hangs a push: past its wall-clock limit it prints every thread's stack and refuses.

2026-10-28: pushes by a786, a796 and a808 hung inside the gate for 28-30 minutes (a child process that never
answered; the arch ratchet's cat-file pipe deadlock was one). A hang already blocks the push, so refusing it
with the stacks loosens no check and leaves the evidence. The test puts a `git` that never answers first on
PATH and requires the gate to exit inside the limit plus a margin.

  python3 scripts/cmux-next/tests/test_prepush_gate_watchdog.py
"""
from __future__ import annotations

import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

GATE = Path(__file__).resolve().parents[1] / "prepush-gate.py"
REPO = Path(__file__).resolve().parents[3]  # the checkout: the gate loads push_range.py from it


class GateWatchdogTest(unittest.TestCase):
    def test_a_child_that_never_answers_refuses_the_push_with_the_stacks(self):
        with tempfile.TemporaryDirectory() as tmp:
            fake = Path(tmp) / "bin"
            fake.mkdir()
            git = fake / "git"
            git.write_text("#!/bin/sh\nexec sleep 600\n")
            git.chmod(0o755)
            env = dict(os.environ, PATH=f"{fake}:{os.environ.get('PATH', '')}", CMUX_NEXT_GATE_LIMIT_SECONDS="2")
            env.pop("GITHUB_ACTIONS", None)
            child = subprocess.Popen([sys.executable, "-I", str(GATE), "--repo", str(REPO), "--base", "A", "--head", "B"],
                                     env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                                     start_new_session=True)
            try:
                out, err = child.communicate(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, 9)
                child.communicate()
                self.fail("prepush-gate hung past 30 s with a 2 s limit")
            finally:
                try:
                    os.killpg(child.pid, 9)  # the fake git this test started still sleeps in the child's own group
                except OSError:
                    pass
        self.assertNotEqual(child.returncode, 0, "a gate that ran out of time must refuse the push")
        self.assertIn("ran past its 2s limit", err)
        self.assertIn("Thread", err, "the stacks of every thread name where it hung")


if __name__ == "__main__":
    unittest.main()
