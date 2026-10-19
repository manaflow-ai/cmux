#!/usr/bin/env python3
"""Process-tree cleanup must not block forever while reaping a child."""

from __future__ import annotations

import pathlib
import subprocess
import sys
import textwrap
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


class ProcessTreeReapingTests(unittest.TestCase):
    def test_kill_reaping_is_bounded_for_non_reapable_roots(self) -> None:
        script = textwrap.dedent(
            f"""
            import os, pathlib, sys, time
            sys.path.insert(0, {str(ROOT / 'scripts/ci')!r})
            import ci_process_tree as tree

            # Keep this fixture from touching the test runner's real process
            # group. It models a child whose waitpid/wait never reports exit.
            tree.process_tree = lambda _pid: [(os.getpid(), "fixture")]
            tree.os.killpg = lambda *_args: None
            tree.signal_pid = lambda *_args: None
            tree.TERM_GRACE_SECONDS = 0.02
            tree.KILL_REAP_SECONDS = 0.02

            class FakeProcess:
                pid = os.getpid()

                def wait(self, timeout=None):
                    if timeout is None:
                        time.sleep(60)
                    raise tree.subprocess.TimeoutExpired("fixture", timeout)

            tree.terminate(FakeProcess())
            print("terminate complete", flush=True)

            tree.os.waitpid = lambda *_args: (0, 0)
            tree.terminate_pid(os.getpid())
            print("terminate_pid complete", flush=True)
            """
        )
        completed = subprocess.run(
            [sys.executable, "-c", script],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=2,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("terminate complete", completed.stdout)
        self.assertIn("terminate_pid complete", completed.stdout)


if __name__ == "__main__":
    unittest.main()
