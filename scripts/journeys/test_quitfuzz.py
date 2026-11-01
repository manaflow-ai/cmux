"""The action fuzzer's quit oracle (ext_quitfuzz.py) on fake app and daemon reads: no fleet, no app."""
import sys
import types
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import ext_quitfuzz  # noqa: E402


class StepError(Exception):
    pass


ext_quitfuzz.install(types.SimpleNamespace(StepError=StepError, now=lambda: 0.0))


class FakeApp:
    def __init__(self, workspaces, terminals, daemon_pid, history, processes, alive=()):
        self.pid = 100
        self.sessions = ["cmux-app-t"]
        self.workspaces, self.terminals, self.history = workspaces, terminals, history
        self._daemon_pid, self.processes, self._alive = daemon_pid, processes, set(alive)

    def cmux(self, *args):
        if args[:2] == ("workspace", "list"):
            return [{"id": w, "name": n} for w, n in self.workspaces.items()]
        if args[:2] == ("terminal", "list"):
            return [{"id": t, "lifecycle": life} for t, life in self.terminals.items()]
        if args[0] == "terminal" and args[2:4] == ("history", "read"):
            return {"rows": [{"runs": [{"text": line}]} for line in self.history.get(args[1], [])]}
        raise StepError(f"unexpected {args}")

    def screen(self, term):
        return {"text": ""}

    def daemon_pid(self):
        return self._daemon_pid

    def bundle_processes(self, app_pid):
        return self.processes

    def alive(self, pid):
        return pid in self._alive


def journey(app):
    return types.SimpleNamespace(app=app, nonce="7")


DAEMON = {"pid": 50, "ppid": 1, "rss_kb": 1, "command": "/A.app/Contents/Resources/bin/cmux-tui --headless --session cmux-app-t --socket s"}
HOLDER = {"pid": 60, "ppid": 1, "rss_kb": 1, "command": "cmux-tui __holder --socket h"}
ACK = {"workspaces": {"ws1": "Home", "ws2": "work"}, "terminals": ["t1", "t2"], "history": {"t1": ["fz7-1", "fz7-2"]},
       "panes": {"ws2": ["p1", "p2"]}, "daemon_pid": 50}
AFTER = {"daemon_state": "connected", "panes": {"ws2": ["p1", "p2"]}}


def oracle(expect, app, ack=ACK, after=AFTER):
    fuzz = types.SimpleNamespace(j=journey(app))
    return ext_quitfuzz.oracle(fuzz, {"a": "x", "expect": expect, "ack": ack}, after)


class QuitOracle(unittest.TestCase):
    def kept_app(self, **changes):
        base = dict(workspaces={"ws1": "Home", "ws2": "work"}, terminals={"t1": "running", "t2": "running"},
                    daemon_pid=50, history={"t1": ["fz7-1", "fz7-2", "fz7-3"]}, processes=[DAEMON, HOLDER])
        base.update(changes)
        return FakeApp(**base)

    def test_keep_with_everything_back_is_clean(self):
        self.assertEqual(oracle("kept", self.kept_app()), [])

    def test_keep_that_ended_the_daemon_is_red(self):
        app = self.kept_app(daemon_pid=51, processes=[dict(DAEMON, pid=51), HOLDER])
        self.assertTrue(any("daemon changed" in d for _, d in oracle("kept", app)))

    def test_a_lost_workspace_terminal_or_scrollback_line_is_red(self):
        found = oracle("kept", self.kept_app(workspaces={"ws1": "Home"}, terminals={"t1": "running", "t2": "exited"},
                                             history={"t1": ["fz7-2"]}))
        text = " ".join(d for _, d in found)
        self.assertIn("workspaces are gone", text)
        self.assertIn("terminals are gone or ended", text)
        self.assertIn("lost 1 scrollback lines", text)

    def test_a_restart_must_not_leave_the_old_daemon_or_two_holders(self):
        app = self.kept_app(daemon_pid=52, processes=[dict(DAEMON, pid=52), HOLDER, dict(HOLDER, pid=61)], alive={50})
        text = " ".join(d for _, d in oracle("restarted", app))
        self.assertIn("2 holders run", text)
        self.assertIn("old daemon 50 still runs", text)

    def test_end_everything_keeps_only_home(self):
        app = self.kept_app(daemon_pid=52, workspaces={"ws1": "Home", "ws2": "work"}, terminals={},
                            processes=[dict(DAEMON, pid=52)])
        self.assertTrue(any("End Everything kept 1 workspaces" in d for _, d in oracle("ended_everything", app)))
        app.workspaces = {"ws1": "Home"}
        self.assertEqual(oracle("ended_everything", app), [])

    def test_end_sessions_keeps_the_layout(self):
        app = self.kept_app(daemon_pid=52, processes=[dict(DAEMON, pid=52)])
        self.assertEqual(oracle("ended_keep_layout", app), [])
        lost = oracle("ended_keep_layout", app, after={"daemon_state": "connected", "panes": {"ws2": ["p1"]}})
        self.assertTrue(any("kept 1 of 2 panes" in d for _, d in lost))


if __name__ == "__main__":
    unittest.main()
