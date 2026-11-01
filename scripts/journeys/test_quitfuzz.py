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
ext_quitfuzz.PROCESS_SETTLE = 0.0  # judge the fake processes at once


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

    def test_a_pane_created_at_the_end_is_not_a_loss(self):
        # split_right then quit_keep: the acknowledged panes are read just before the end; one more is fine.
        after = {"daemon_state": "connected", "panes": {"ws2": ["p1", "p2", "p3"]}}
        self.assertEqual(oracle("kept", self.kept_app(), after=after), [])
        lost = oracle("kept", self.kept_app(), after={"daemon_state": "connected", "panes": {"ws2": ["p1"]}})
        self.assertTrue(any("lost 1 of 2 panes" in d for _, d in lost))


class Acknowledged(unittest.TestCase):
    BEFORE = {"workspaces": {"ws1": "Home", "ws2": "work"}, "terminals": ["t1", "t2"], "history": {"t1": ["fz7-1"]},
              "panes": {"ws2": ["p1", "p2"]}, "daemon_pid": 50}
    # The daemon dropped ws2 and t2 at the quit and still runs: its own lists after the end no longer have them.
    AFTER_END = {"workspaces": {"ws1": "Home"}, "terminals": ["t1"], "history": {"t1": ["fz7-1", "fz7-2"]},
                 "panes": {}, "daemon_pid": 50}

    def test_what_the_daemon_dropped_at_the_quit_is_still_acknowledged(self):
        ack = ext_quitfuzz.merged(self.BEFORE, self.AFTER_END, closes=False)
        self.assertEqual((sorted(ack["workspaces"]), ack["terminals"]), (["ws1", "ws2"], ["t1", "t2"]))
        self.assertEqual((ack["history"], ack["panes"], ack["daemon_pid"]), ({"t1": ["fz7-1", "fz7-2"]}, {"ws2": ["p1", "p2"]}, 50))
        app = FakeApp(workspaces={"ws1": "Home"}, terminals={"t1": "running"}, daemon_pid=50,
                      history={"t1": ["fz7-1", "fz7-2"]}, processes=[DAEMON, HOLDER])
        text = " ".join(d for _, d in oracle("kept", app, ack=ack))
        self.assertIn("1 acknowledged workspaces are gone", text)
        self.assertIn("1 acknowledged terminals are gone", text)

    def test_a_burst_that_closes_takes_the_lists_after_the_end(self):
        # A close in flight at the end is only in the read before: it must not count as a loss.
        ack = ext_quitfuzz.merged(self.BEFORE, self.AFTER_END, closes=True)
        self.assertEqual((sorted(ack["workspaces"]), ack["terminals"]), (["ws1"], ["t1"]))


if __name__ == "__main__":
    unittest.main()
