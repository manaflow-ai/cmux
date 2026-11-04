"""adopt_pane keeps evidence when a new terminal's screen stays empty (open-P0 close-then-type, build dd832e31,
STATUS 12261): the run kept no app or daemon log, so the cause could not be proven. On that timeout the step must
write diag-* files (run.py brings back diag-[a-z]+.(json|png|txt)) with the daemon's screen read, the app's
debug.surfaces and debug.daemon_requests, the host's process tree and a sample of the host and of the daemon.

Run: python3 -I scripts/journeys/test_adopt_pane_diag.py (standard library only)."""

import importlib.util
import json
import os
import re
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
RESULT_FILE = re.compile(r"diag-[a-z]+\.(?:json|png|txt)")


def load_ext_window():
    spec = importlib.util.spec_from_file_location("ext_window_under_test", HERE / "ext_window.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StepError(Exception):
    pass


class Done:
    def __init__(self, returncode=0):
        self.returncode, self.stdout, self.stderr = returncode, "", ""


class FakeSubprocess:
    def __init__(self):
        self.calls = []

    def run(self, argv, **_):
        self.calls.append(argv)
        if argv[0] == "/usr/bin/sample":
            Path(argv[argv.index("-file") + 1]).write_text(f"Sampling process {argv[1]}\n")
        return Done()


class Clock:
    def __init__(self):
        self.t = 0.0

    def now(self):
        self.t += 1.0
        return self.t


class AdoptPaneEmptyScreenTest(unittest.TestCase):
    def setUp(self):
        self.ext = load_ext_window()
        self.sub = FakeSubprocess()
        clock = Clock()
        driver = type("D", (), {"StepError": StepError, "now": staticmethod(clock.now), "subprocess": self.sub})
        self.ext.install(driver)
        self.ext.time.sleep = lambda _s: None
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)

    def tearDown(self):
        self.tmp.cleanup()

    def journey(self):
        out = self.out
        rpcs = []

        class App:
            def rpc(self_, method, params=None, timeout=None):
                rpcs.append(method)
                if method == "debug.surfaces":
                    return {"windows": [{"id": "w1", "window": 1, "panes": [
                        {"pane": "old", "focused": False, "kind": "terminal", "workspace": "ws"},
                        {"pane": "new", "focused": True, "kind": "terminal", "workspace": "ws", "host_pid": 4242,
                         "grid": {"window": "w1"}}]}]}
                if method == "debug.layers":
                    return {"windows": [{"id": "w1", "window_number": 1}]}
                if method == "snapshot.get":
                    return {"topology": {"workspaces": [{"id": "ws", "screens": [{"panes": [
                        {"id": "old", "tabs": [{"terminal": "term-old", "selected": True}]},
                        {"id": "new", "tabs": [{"terminal": "term-new", "selected": True}]}]}]}]}}
                if method == "debug.daemon":
                    return {"pid": 777}
                if method == "debug.daemon_requests":
                    return {"in_flight": []}
                raise AssertionError(f"unexpected rpc {method}")

            def screen(self_, term):
                return {"text": "   \n"}

            @staticmethod
            def processes():
                return {4242: {"pid": 4242, "ppid": 1, "pgid": 4242, "tpgid": -1, "tty": "??", "stat": "S",
                               "command": "cmux-tui __terminal-host --bootstrap-stdio"},
                        4243: {"pid": 4243, "ppid": 4242, "pgid": 4243, "tpgid": 4243, "tty": "ttys007",
                               "stat": "Ss+", "command": "-zsh"}}

        class J:
            app = App()
            pane, term, host_pid = "old", "term-old", 1
            ext_panes = {"left": {"pane": "old", "term": "term-old", "host_pid": 1, "window": "w1"}}
            ext_seen = {"old"}
            ext_window = key_window = "w1"
            ext_windows_seen = {"w1"}

        j = J()
        j.out = out
        j.rpcs = rpcs
        return j

    def test_an_empty_screen_timeout_saves_the_host_and_daemon_evidence(self):
        j = self.journey()
        with self.assertRaises(StepError) as raised:
            self.ext.step_adopt_pane(j, {"as": "r7", "timeout": 3})
        self.assertIn("term-new has an empty screen", str(raised.exception))
        files = sorted(p.name for p in self.out.iterdir())
        for name in ("diag-adoptscreen.json", "diag-adoptsurfaces.json", "diag-adoptrequests.json",
                     "diag-adopthosttree.txt", "diag-adopthostsample.txt", "diag-adoptdaemonsample.txt"):
            self.assertIn(name, files, f"adopt_pane kept no {name} (files: {files})")
        for name in files:
            self.assertTrue(RESULT_FILE.fullmatch(name), f"run.py does not bring back {name}")
        samples = [call[1] for call in self.sub.calls if call[0] == "/usr/bin/sample"]
        self.assertEqual(samples, ["4242", "777"], "sample the terminal's host and the daemon")
        tree = (self.out / "diag-adopthosttree.txt").read_text()
        self.assertIn("4242 ", tree)
        self.assertIn("  4243 ", tree, "the shell shows under its host")
        screen = json.loads((self.out / "diag-adoptscreen.json").read_text())
        self.assertEqual((screen["terminal"], screen["host_pid"]), ("term-new", 4242))
        self.assertIn("debug.daemon_requests", j.rpcs)

    def test_a_timeout_with_no_empty_terminal_saves_nothing(self):
        j = self.journey()
        j.ext_seen = {"old", "new"}  # no new pane at all: nothing to diagnose
        with self.assertRaises(StepError):
            self.ext.step_adopt_pane(j, {"as": "r7", "timeout": 3})
        self.assertEqual(list(self.out.iterdir()), [])


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
