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


class GateLimitUnderLoadTest(unittest.TestCase):
    """2026-11-10: at load average 300-770 on 18 cores every gate ran to its 600 s and was refused, with nothing
    wrong in the push. The limit refuses a hang; a gate that shares each core with many others gets longer."""

    def setUp(self):
        import importlib.util
        spec = importlib.util.spec_from_file_location("prepush_gate_under_test", GATE)
        self.gate = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = self.gate  # dataclasses look their module up by name
        self.addCleanup(sys.modules.pop, spec.name, None)
        spec.loader.exec_module(self.gate)

    def test_an_idle_mac_keeps_the_limit(self):
        self.assertEqual(self.gate.loaded_limit(600.0, 4.0, 18), 600.0)
        self.assertEqual(self.gate.loaded_limit(600.0, 18.0, 18), 600.0)

    def test_a_loaded_mac_gets_the_limit_times_its_load_per_core(self):
        self.assertEqual(self.gate.loaded_limit(600.0, 54.0, 18), 1800.0)

    def test_the_limit_never_passes_its_ceiling(self):
        self.assertEqual(self.gate.loaded_limit(600.0, 770.0, 18), self.gate.GATE_LIMIT_MAX_SECONDS)

    def test_a_set_limit_is_used_as_given(self):
        old = os.environ.get("CMUX_NEXT_GATE_LIMIT_SECONDS")
        os.environ["CMUX_NEXT_GATE_LIMIT_SECONDS"] = "2"
        try:
            self.assertEqual(self.gate.gate_limit(), 2.0)
        finally:
            if old is None:
                del os.environ["CMUX_NEXT_GATE_LIMIT_SECONDS"]
            else:
                os.environ["CMUX_NEXT_GATE_LIMIT_SECONDS"] = old


if __name__ == "__main__":
    unittest.main()
