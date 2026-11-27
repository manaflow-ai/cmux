#!/usr/bin/env python3
"""The update harness's cleanup (update-harness/run.py end_tag) ends the tag with the TagTeardowns it kept for the whole
run, then every session process the run started (agent harnesses and hosts, terminal counters) by its recorded pid and
identity, and deletes acpmux_home only when none of them runs. A cancellation during the daemon handoff (the old
daemons exited, so a teardown cannot find the detached hosts) must not orphan them nor delete the home under them.
Run: python3 -I scripts/cmux-next/tests/test_update_harness_cleanup.py"""
import importlib.util, os, subprocess, sys, tempfile, unittest

HERE = os.path.dirname(os.path.abspath(__file__))
HARNESS = os.path.join(HERE, "..", "update-harness")
spec = importlib.util.spec_from_file_location("update_harness_run", os.path.join(HARNESS, "run.py"))
run = importlib.util.module_from_spec(spec)
spec.loader.exec_module(run)
Owned = sys.modules["sessions"].Owned
TagTeardown = sys.modules["tag_teardown"].TagTeardown


class LostTeardown:
    """A TagTeardown whose daemons exited before it ran: it ends nothing."""

    def __init__(self, app):
        self.app = app
        self.ended = 0

    def end(self):
        self.ended += 1


class CleanupTests(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="update-harness-cleanup-")
        self.app = os.path.join(self.dir, "cmux DEV t.app")
        os.makedirs(self.app)
        self.home = os.path.join(self.dir, "acpmux-home")
        os.makedirs(os.path.join(self.home, "sessions"))
        self.started = []
        self.lines = []

    def tearDown(self):
        for process in self.started:
            if process.poll() is None:
                process.kill()  # only what this test started
            process.wait()
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)

    def log(self, *parts):
        self.lines.append(" ".join(map(str, parts)))

    def start(self):
        process = subprocess.Popen(["sleep", "60"], start_new_session=True)
        self.started.append(process)
        return process

    def test_teardown_that_lost_the_daemons_still_ends_recorded_sessions_before_deleting_home(self):
        harness, counter = self.start(), self.start()
        owned = Owned(TagTeardown._table)
        owned.add(harness.pid)
        owned.add(counter.pid)
        self.assertEqual(owned.alive(), sorted([harness.pid, counter.pid]))
        teardown = LostTeardown(self.app)
        left = run.end_tag([teardown, LostTeardown(os.path.join(self.dir, "missing.app"))], owned, self.home, True, self.log)
        self.assertEqual(left, [])
        self.assertEqual(teardown.ended, 1)
        self.assertEqual(harness.wait(5), -15)
        self.assertEqual(counter.wait(5), -15)
        self.assertFalse(os.path.exists(self.home))

    def test_home_is_kept_while_a_recorded_session_process_runs(self):
        class Stuck:
            def end(self, log):
                return [4242]
        left = run.end_tag([LostTeardown(self.app)], Stuck(), self.home, True, self.log)
        self.assertEqual(left, [4242])
        self.assertTrue(os.path.isdir(self.home))

    def test_a_reused_pid_is_never_signalled(self):
        rows = {7: (1, "Sat Oct 24 10:00:00 2026", "python3 fake_agent.py")}
        owned = Owned(lambda: rows)
        owned.add(7)
        rows[7] = (1, "Sat Oct 24 11:00:00 2026", "-zsh")  # another process got the pid
        self.assertEqual(owned.alive(), [])
        self.assertEqual(owned.end(self.log, grace=0), [])
        self.assertEqual(self.lines, [])


OLD, NEW = "Sat Oct 24 10:00:00 2026", "Sat Oct 24 10:05:00 2026"
DAEMON = "/app/Contents/Resources/bin/cmux-tui --headless --session cmux-app-t --socket /tmp/s.sock"


class TerminalHandoffTests(unittest.TestCase):
    """--handoff passes a terminal only through a replacement cmux-tui daemon: if acpmux hands off but cmux-tui keeps
    its original daemon, the original socket still lists the terminal, and that must not certify the handoff."""

    def setUp(self):
        self.dir = tempfile.mkdtemp(prefix="update-harness-handoff-")
        self.sessions = sys.modules["sessions"]
        self.saved = self.sessions.wait_path
        # One look, no waiting (wait_path watches with kqueue).
        self.sessions.wait_path = lambda path, predicate, timeout: predicate(path) or None

    def tearDown(self):
        self.sessions.wait_path = self.saved
        self.sessions.subprocess = subprocess
        import shutil
        shutil.rmtree(self.dir, ignore_errors=True)

    def terminal(self, daemons):
        terminal = self.sessions.Terminal(os.path.join(self.dir, "cmux DEV t.app"), self.dir, lambda *_: None, "cmux-app-t")
        terminal.socket, terminal.term, terminal.pid = "/tmp/s.sock", "term_1", os.getpid()
        terminal.daemon_pids, terminal.daemon_ids = [10], {(10, OLD)}
        # `ps` as the harness runs it, answering whichever columns are asked (pid, [lstart,] command).
        def ps(argv, **_):
            columns = argv[2]
            rows = [f"{pid} {start} {command}" if "lstart" in columns else f"{pid} {command}" for pid, command, start in daemons]
            return subprocess.CompletedProcess(argv, 0, "\n".join(rows) + "\n", "")
        self.sessions.subprocess = type("FakeSubprocess", (), {"run": staticmethod(ps)})
        terminal.list_quietly = lambda: '{"terminals": ["term_1"]}' if terminal.socket else ""
        with open(terminal.file, "w") as f:
            f.write(f"100.0 {os.getpid()}\n101.0 {os.getpid()}\n103.0 {os.getpid()}\n")
        return terminal

    def test_handoff_without_a_replacement_daemon_fails(self):
        terminal = self.terminal([(10, DAEMON, OLD)])
        record = terminal.check("/app", 100.5, 102.0, handoff=True)
        # The original daemon still lists the terminal: that lookup must not count.
        self.assertFalse(record["same_terminal_listed"])
        self.assertFalse(record["replacement_daemon"])
        self.assertFalse(run.terminal_survived(record, True))

    def test_handoff_through_a_replacement_daemon_on_the_same_socket_passes(self):
        # The real handoff: the new daemon binds the session's same socket path after the old one exits.
        terminal = self.terminal([(11, DAEMON, NEW)])
        record = terminal.check("/app", 100.5, 102.0, handoff=True)
        self.assertEqual(record["socket_after"], record["socket_before"])
        self.assertTrue(record["replacement_daemon"])
        self.assertEqual(record["replacement_daemon_pid"], 11)
        self.assertTrue(run.terminal_survived(record, True))

    def test_a_reused_pid_with_another_start_is_a_replacement(self):
        terminal = self.terminal([(10, DAEMON, NEW)])
        self.assertTrue(run.terminal_survived(terminal.check("/app", 100.5, 102.0, handoff=True), True))


if __name__ == "__main__":
    unittest.main()
