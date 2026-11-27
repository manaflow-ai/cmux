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

    def test_a_refused_group_kill_still_stops_the_strays(self) -> None:
        """cmux-lawrence-2, 2026-10-09: after the group leader exited and was
        reaped in the grace period, killpg(SIGKILL) raised EPERM (macOS; the
        group's remaining members were exiting). hung_test_watchdog.py died
        with a traceback and a hung suite was reported as "exit 1", not as
        timed out. terminate() must treat EPERM like a group that is gone."""
        script = textwrap.dedent(
            f"""
            import os, signal, sys
            sys.path.insert(0, {str(ROOT / 'scripts/ci')!r})
            import ci_process_tree as tree

            # Never touch real processes: record the signals instead.
            sent = []
            def refused_killpg(pgid, signum):
                sent.append(("killpg", signum))
                raise PermissionError(1, "Operation not permitted")
            tree.os.killpg = refused_killpg
            tree.signal_pid = lambda pid, signum: sent.append((pid, signum))
            tree.TERM_GRACE_SECONDS = 0.02
            tree.KILL_REAP_SECONDS = 0.02

            class ExitedProcess:
                pid = 999999

                def wait(self, timeout=None):
                    return 0

            for terminate in (tree.terminate, tree.terminate_pid):
                sent.clear()
                target = ExitedProcess() if terminate is tree.terminate else ExitedProcess.pid
                if terminate is tree.terminate_pid:
                    tree.os.waitpid = lambda *_args: (ExitedProcess.pid, 0)
                terminate(target, tree=[(4242, "sleep")])
                assert (4242, signal.SIGTERM) in sent, sent
                assert (4242, signal.SIGKILL) in sent, sent
                print(terminate.__name__, "complete", flush=True)
            """
        )
        completed = subprocess.run(
            [sys.executable, "-c", script],
            cwd=ROOT,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("terminate complete", completed.stdout)
        self.assertIn("terminate_pid complete", completed.stdout)



# A leader that dies on SIGTERM, with a child in its process group that ignores SIGTERM and closes stdin, stdout and
# stderr, so no pipe or wait on the leader tells its caller it is still there. The child writes its pid to
# $STUBBORN_PID first.
STUBBORN = textwrap.dedent("""
    import os, signal, sys, time
    path = os.environ["STUBBORN_PID"]
    if os.fork() == 0:
        signal.signal(signal.SIGTERM, signal.SIG_IGN)
        with open(path + ".tmp", "w") as out:
            out.write(str(os.getpid()))
        os.replace(path + ".tmp", path)
        for fd in (0, 1, 2):
            os.close(fd)
        time.sleep(60)
        os._exit(0)
    while not os.path.exists(path):
        time.sleep(0.01)
    time.sleep(60)
""")


class BoundedRunTests(unittest.TestCase):
    """ci_process_tree.run_bounded: subprocess.run's shape, but a timeout stops the command's whole tree, not only
    the process it started (cmux#41752 review F1: a timed-out `git submodule update` left its `git clone` running).
    Real processes: a shell that starts a background sleeper and waits on it."""

    def setUp(self) -> None:
        sys.path.insert(0, str(ROOT / "scripts/ci"))
        self.addCleanup(sys.path.remove, str(ROOT / "scripts/ci"))
        import ci_process_tree
        self.tree = ci_process_tree
        import tempfile
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.pid_file = pathlib.Path(tmp.name) / "child.pid"
        self.addCleanup(self.stop_child)

    def child(self) -> int:
        return int(self.pid_file.read_text().strip()) if self.pid_file.exists() else 0

    def stop_child(self) -> None:
        import os
        if self.child():
            try:
                os.kill(self.child(), 9)  # only the sleeper this test started
            except (ProcessLookupError, PermissionError):
                pass

    @staticmethod
    def alive(pid: int) -> bool:
        import os
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        try:
            return pathlib.Path(f"/proc/{pid}/stat").read_text().split()[2] != "Z"
        except (OSError, IndexError):
            return True

    def test_a_timeout_stops_the_grandchild_too(self) -> None:
        run = getattr(self.tree, "run_bounded", None)
        self.assertIsNotNone(run, "ci_process_tree has no run_bounded")
        with self.assertRaises(subprocess.TimeoutExpired):
            run(["sh", "-c", f"sleep 30 & echo $! > {self.pid_file}; wait"], timeout=1)
        self.assertTrue(self.child(), "the sleeper never started")
        self.assertFalse(self.alive(self.child()), "the grandchild outlived the timeout")

    def test_a_child_that_ignores_sigterm_and_closes_its_output_is_killed(self) -> None:
        """The cmux#41767 review's F1 shape: the leader exits on SIGTERM, its child ignores SIGTERM and holds no pipe,
        so nothing waits on it; the group still gets SIGKILL after the grace period."""
        run = getattr(self.tree, "run_bounded", None)
        self.assertIsNotNone(run, "ci_process_tree has no run_bounded")
        import os
        with self.assertRaises(subprocess.TimeoutExpired):
            run([sys.executable, "-I", "-c", STUBBORN], timeout=1, capture_output=True, text=True,
                env={**os.environ, "STUBBORN_PID": str(self.pid_file)})
        self.assertTrue(self.child(), "the stubborn child never started")
        self.assertFalse(self.alive(self.child()), "a child that ignored SIGTERM outlived the timeout")

    def test_a_quick_command_returns_its_status_and_output(self) -> None:
        run = getattr(self.tree, "run_bounded", None)
        self.assertIsNotNone(run, "ci_process_tree has no run_bounded")
        done = run(["sh", "-c", "echo out; echo err >&2; exit 3"], timeout=10, capture_output=True, text=True)
        self.assertEqual((done.returncode, done.stdout, done.stderr), (3, "out\n", "err\n"))


if __name__ == "__main__":
    unittest.main()
