#!/usr/bin/env python3
"""Bench teardowns let Chromium's `--type=code-sign-clone-cleanup` helper finish. CEF clones the app at each launch
to $TMPDIR/../X/<bundle id>.code_sign_clone/code_sign_clone.*/ (about 1 GB); after a normal quit that helper removes
the clone about 1 s after the app exits. bench_memory.end_bundle and perf-bench procs.Instance.end signalled every
process of the bundle as soon as the app was gone, the helper too, so each launch left its clone until reboot
(29 GB on cmux18, 2026-11-02). Fake process table and signals, no app, no process is started or signalled.
Run: python3 -I scripts/cmux-next/tests/test_teardown_clone_cleanup.py"""
import importlib.util, os, sys, unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", "..", ".."))


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    with mock.patch("ctypes.CDLL"):  # procs.py binds libproc at import; nothing here calls it
        spec.loader.exec_module(module)
    return module


bench_memory = load("bench_memory", os.path.join(REPO, "scripts/cmux-next/bench_memory.py"))
procs = load("procs", os.path.join(REPO, "scripts/perf-bench/procs.py"))

BUNDLE = "/private/tmp/cmux-ci/cmux DEV bfuzz-0123abcd.app"
APP, DAEMON, CLEANUP = 501, 502, 503
SIGTERM, SIGKILL = 15, 9


class FakeHost:
    """The app quits on SIGTERM (cmux's QuitSignal); at its exit Chromium starts the cleanup helper, which exits by
    itself after `cleanup_polls` liveness checks; the daemon ends on SIGTERM. Records every real signal sent."""

    HELPER = (f"{BUNDLE}/Contents/MacOS/cmux DEV --type=code-sign-clone-cleanup "
              "--unique-temp-dir-suffix=Ab12Cd --wait-for-parent-exit")

    def __init__(self, cleanup_polls=3, helper_at_launch=False):
        self.alive = {APP: f"{BUNDLE}/Contents/MacOS/cmux DEV", DAEMON: f"{BUNDLE}/Contents/Resources/bin/cmux-tui --headless"}
        if helper_at_launch:  # a helper started with the app that waits for its exit (--wait-for-parent-exit)
            self.alive[CLEANUP] = self.HELPER
        self.cleanup_polls = cleanup_polls
        self.sent = []

    def table(self):
        return [(pid, 1, cmd) for pid, cmd in sorted(self.alive.items())]

    def kill(self, pid, sig):
        if pid not in self.alive:
            raise ProcessLookupError(pid)
        if sig == 0:
            if pid == CLEANUP and APP not in self.alive:
                self.cleanup_polls -= 1
                if self.cleanup_polls <= 0:
                    del self.alive[CLEANUP]  # it removed the clone and exited
            return
        self.sent.append((pid, sig))
        del self.alive[pid]
        if pid == APP:
            self.alive[CLEANUP] = self.HELPER

    def alive_probe(self, pid):
        try:
            self.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False


class BenchMemoryEndBundle(unittest.TestCase):
    def test_cleanup_helper_is_never_signalled_and_finishes(self):
        host = FakeHost()
        with mock.patch.object(bench_memory, "process_table", host.table), \
                mock.patch.object(bench_memory.os, "kill", host.kill), \
                mock.patch.object(bench_memory.time, "sleep", lambda _s: None):
            bench_memory.end_bundle(BUNDLE)
        self.assertNotIn(CLEANUP, [pid for pid, _ in host.sent], host.sent)
        self.assertEqual(sorted(host.sent), [(APP, SIGTERM), (DAEMON, SIGTERM)])
        self.assertEqual(host.alive, {})

    def test_a_helper_started_with_the_app_is_not_one_of_the_apps(self):
        host = FakeHost(helper_at_launch=True)
        with mock.patch.object(bench_memory, "process_table", host.table), \
                mock.patch.object(bench_memory.os, "kill", host.kill), \
                mock.patch.object(bench_memory.time, "sleep", lambda _s: None):
            bench_memory.end_bundle(BUNDLE)
        self.assertNotIn(CLEANUP, [pid for pid, _ in host.sent], host.sent)
        self.assertEqual(host.alive, {})

    def test_a_cleanup_helper_that_never_exits_is_killed_after_the_bound(self):
        host = FakeHost(cleanup_polls=10 ** 9)
        clock = [0.0]

        def sleep(seconds):
            clock[0] += seconds

        with mock.patch.object(bench_memory, "process_table", host.table), \
                mock.patch.object(bench_memory.os, "kill", host.kill), \
                mock.patch.object(bench_memory.time, "sleep", sleep), \
                mock.patch.object(bench_memory.time, "monotonic", lambda: clock[0]):
            bench_memory.end_bundle(BUNDLE)
        self.assertIn((CLEANUP, SIGTERM), host.sent)
        self.assertEqual(host.alive, {})



class BenchMemoryEndProcesses(unittest.TestCase):
    """end_processes waits once for the whole set and reaps its own exited children: kill(pid, 0) succeeds on an
    unreaped zombie, so a probe-only wait held every exited child for both grace periods (20 s each)."""

    def test_an_exited_child_is_reaped_not_waited_out(self):
        import subprocess, time
        child = subprocess.Popen(["sleep", "30"], start_new_session=True)  # this test's own child, never waited on
        started = time.monotonic()
        bench_memory.end_processes({child.pid})
        elapsed = time.monotonic() - started
        self.assertLess(elapsed, 3, f"the teardown waited {elapsed:.1f} s on a zombie child")
        with self.assertRaises(ChildProcessError):  # reaped: no zombie left behind
            os.waitpid(child.pid, os.WNOHANG)

    def test_one_deadline_for_every_pid(self):
        clock, sent = [0.0], []

        def kill(pid, sig):
            sent.append((pid, sig))  # none of them ever exits

        def sleep(seconds):
            clock[0] += seconds

        with mock.patch.object(bench_memory.os, "kill", kill), \
                mock.patch.object(bench_memory.os, "waitpid", mock.Mock(side_effect=ChildProcessError)), \
                mock.patch.object(bench_memory.time, "sleep", sleep), \
                mock.patch.object(bench_memory.time, "monotonic", lambda: clock[0]):
            bench_memory.end_processes({601, 602, 603}, grace=10, kill_grace=5)
        self.assertLess(clock[0], 16, "each pid got its own grace period")
        self.assertEqual(sorted(sig for _pid, sig in sent if sig), [SIGKILL] * 3 + [SIGTERM] * 3)

class ProcsInstanceEnd(unittest.TestCase):
    def test_main_pid_is_never_the_cleanup_helper(self):
        # A helper of an earlier run (a lower pid) still waiting while the next launch is looked up.
        rows = [(400, 1, FakeHost.HELPER), (APP, 1, f"{BUNDLE}/Contents/MacOS/cmux DEV")]
        with mock.patch.object(procs, "process_table", lambda: rows):
            self.assertEqual(procs.main_pid(BUNDLE), APP)

    def test_cleanup_helper_is_never_signalled_and_finishes(self):
        host = FakeHost()
        with mock.patch.object(procs, "process_table", host.table), \
                mock.patch.object(procs, "_responsible", None), \
                mock.patch.object(procs, "_alive", host.alive_probe), \
                mock.patch.object(procs.os, "kill", host.kill), \
                mock.patch.object(procs.time, "sleep", lambda _s: None):
            procs.Instance(BUNDLE, APP).end(grace=1)
        self.assertNotIn(CLEANUP, [pid for pid, _ in host.sent], host.sent)
        self.assertEqual(host.alive, {})

    def test_a_cleanup_helper_that_never_exits_is_killed_after_the_bound(self):
        host = FakeHost(cleanup_polls=10 ** 9)
        clock = [0.0]

        def sleep(seconds):
            clock[0] += seconds

        with mock.patch.object(procs, "process_table", host.table), \
                mock.patch.object(procs, "_responsible", None), \
                mock.patch.object(procs, "_alive", host.alive_probe), \
                mock.patch.object(procs.os, "kill", host.kill), \
                mock.patch.object(procs.time, "sleep", sleep), \
                mock.patch.object(procs.time, "monotonic", lambda: clock[0]):
            procs.Instance(BUNDLE, APP).end(grace=1)
        self.assertIn((CLEANUP, SIGKILL), host.sent)
        self.assertEqual(host.alive, {})


if __name__ == "__main__":
    unittest.main()
