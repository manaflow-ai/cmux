#!/usr/bin/env python3
"""idle_cpu.py's daemon restart with a peer batch owed (--peer-rows, --restart-at): the run that shows the
agent page's #254 loop on a build without the fix (sessionPages.ts readOwedTo) and none on one with it.
Run: python3 -I scripts/cmux-next/tests/test_idle_cpu_owed_restart.py (not a CI job)."""
import ctypes, os, signal, sys, unittest
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
if sys.platform == "darwin":
    import idle_cpu  # noqa: E402
else:  # bench_memory loads macOS's libproc at import; these tests need none of it
    with mock.patch.object(ctypes, "CDLL", mock.MagicMock()):
        import idle_cpu  # noqa: E402


class Ops:
    """Every step the restart takes, recorded in order."""

    def __init__(self, new_pid=202, listed=40):
        self.steps, self.new_pid, self.listed = [], new_pid, listed

    def show_chat(self):
        self.steps.append("show")

    def add_peer(self):
        self.steps.append("add")

    def remove_peer(self):
        self.steps.append("remove")

    def listed_rows(self):
        return self.listed

    def renderers(self):
        return [11, 12]

    def signal(self, pids, number):
        self.steps.append(("signal", tuple(pids), number))

    def settle(self, seconds):
        self.steps.append(("settle", seconds))

    def daemon_pid(self):
        return 101

    def kill(self, pid):
        self.steps.append(("kill", pid))

    def wait_new_daemon(self, old, seconds):
        self.steps.append(("wait", old))
        return self.new_pid


class OwedRestart(unittest.TestCase):
    def test_the_daemon_dies_while_every_page_is_frozen_with_a_batch_unread(self):
        ops = Ops()
        report = idle_cpu.owed_restart(ops, cycles=2)
        stop = ("signal", (11, 12), signal.SIGSTOP)
        cont = ("signal", (11, 12), signal.SIGCONT)
        steps = ops.steps
        # The batches before the freeze push the old run's positions past any the new run reaches.
        # A hidden page drops list notices and reads anew (sessionPages.ts invalidate), so it never owes a batch:
        # the chat is shown first (cmux20-bench, 2026-11-24: with only onboarding shown, no arm read in a loop).
        self.assertEqual(steps[:steps.index(stop)], ["show", "add", "remove", "add", "remove", "add"])
        frozen = steps[steps.index(stop) + 1:steps.index(cont)]
        # Frozen: one more batch (the one owed), time to send it, then the daemon is killed.
        self.assertEqual(frozen[:2], ["remove", "add"])
        self.assertEqual(frozen[-1], ("kill", 101))
        self.assertEqual(steps[-1], ("wait", 101))
        self.assertEqual(report, {"old_pid": 101, "new_pid": 202, "peer_rows": 40, "batches": 3, "frozen": 2})

    def test_the_pages_resume_even_when_the_kill_fails(self):
        ops = Ops()
        ops.kill = mock.Mock(side_effect=ProcessLookupError)
        with self.assertRaises(ProcessLookupError):
            idle_cpu.owed_restart(ops, cycles=0)
        self.assertEqual(ops.steps[-1], ("signal", (11, 12), signal.SIGCONT))

    def test_too_few_rows_for_a_batch_is_refused(self):
        # A peer's rows come as one batch only above PEER_ROW_BATCH_MIN (acpmux hub/peers.rs): fewer prove nothing.
        with self.assertRaises(RuntimeError):
            idle_cpu.owed_restart(Ops(listed=idle_cpu.PEER_ROW_BATCH_MIN), cycles=0)

    def test_no_new_daemon_is_an_error(self):
        with self.assertRaises(RuntimeError):
            idle_cpu.owed_restart(Ops(new_pid=None), cycles=0)

    def test_args_need_more_rows_than_a_batch_and_a_restart_inside_the_idle(self):
        args = idle_cpu.parse_args(["--app", "/x.app", "--minutes", "6", "--chats", "1", "--peer-rows", "40", "--restart-at", "2"])
        self.assertEqual((args.peer_rows, args.restart_at), (40, 2.0))
        for bad in (["--peer-rows", "32", "--restart-at", "2"], ["--peer-rows", "40", "--restart-at", "7"],
                    ["--restart-at", "2"], ["--peer-rows", "40", "--restart-at", "2", "--chats", "0"]):
            with self.assertRaises(SystemExit), mock.patch("sys.stderr"):
                idle_cpu.check_args(idle_cpu.parse_args(["--app", "/x.app", "--minutes", "6", "--chats", "1", *bad]))


class LiveDaemon(unittest.TestCase):
    def ops(self, status_pid, owned):
        ops = idle_cpu.LiveOwedOps(1, "/b.app", "/s.sock", None, 40)
        ops._rpc = lambda *a, **k: {"pid": status_pid}
        ops._owned = lambda: owned
        return ops

    def test_the_daemon_is_the_one_serving_the_apps_socket_among_several(self):
        # cmux20-bench, 2026-11-24: the app ran 3 acpmux daemons (its own, Chief's, ...); a name count refused the run.
        owned = {7: ("acpmux-daemon", "/b.app/Contents/Resources/bin/acpmux daemon run"),
                 8: ("acpmux-daemon", "/b.app/Contents/Resources/bin/acpmux daemon run"), 9: ("acpmux-daemon", "x")}
        self.assertEqual(self.ops(8, owned).daemon_pid(), 8)

    def test_a_socket_served_by_no_daemon_of_the_app_is_refused(self):
        with self.assertRaises(RuntimeError):
            self.ops(5, {8: ("acpmux-daemon", "x")}).daemon_pid()
        with self.assertRaises(RuntimeError):   # the acpmux inside cmux-tui: killing it ends the terminals too
            self.ops(8, {8: ("tui-daemon", "/b.app/Contents/Resources/bin/cmux acp daemon run")}).daemon_pid()


if __name__ == "__main__":
    unittest.main()
