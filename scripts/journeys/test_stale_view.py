#!/usr/bin/env python3
"""A failed app text check whose daemon check passed keeps the stale view's state, no fleet, no app.

    python3 -I scripts/journeys/test_stale_view.py

v2.2.7-opt (job ef0b040d): a new terminal's view kept its first, cut line while the daemon's screen had the shell's
output (load-first-prompt-key step 4, select-copy). The expect step now saves debug.surfaces, debug.action_budget,
debug.main_budget (diag-staleview.json) and a 3 s sample of the app (diag-stalesample.txt) at that failure, so a stuck
main thread, a paused pane and a dropped stream can be told apart.
"""
import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402


class App:
    def __init__(self):
        self.calls = []
        self.pid = 4242

    def rpc(self, method, params=None, timeout=None):
        self.calls.append(method)
        return {"method": method}


def journey(app):
    j = D.Journey.__new__(D.Journey)
    j.app, j.pane, j.term = app, "pane_1", "term_1"
    j.out = Path(tempfile.mkdtemp())
    j.marks, j.evidence = {}, []
    return j


class StaleView(unittest.TestCase):
    def setUp(self):
        self.sampled = []
        self.real_run = D.subprocess.run

        def fake_run(argv, **kw):
            if argv and argv[0] == "/usr/bin/sample":
                self.sampled.append(argv)
                Path(argv[argv.index("-file") + 1]).write_text("Call graph:\n")
                return D.subprocess.CompletedProcess(argv, 0, "", "")
            return self.real_run(argv, **kw)
        D.subprocess.run = fake_run

    def tearDown(self):
        D.subprocess.run = self.real_run

    def test_an_app_text_fail_with_the_daemon_ahead_saves_the_state_and_a_sample(self):
        j = journey(App())
        j.evaluate = lambda name, want, cache: (name == "daemon_line", {})
        with self.assertRaises(D.StepError):
            j.step_expect({"timeout": 0.1, "all": [{"daemon_line": "x"}, {"app_text_line": "x"}]})
        dump = json.loads((j.out / "diag-staleview.json").read_text())
        self.assertEqual(set(dump) >= {"surfaces", "action_budget", "main_budget", "sample"}, True, dump.keys())
        self.assertEqual(dump["surfaces"]["method"], "debug.surfaces")
        self.assertEqual(self.sampled[0][1:3], ["4242", "3"], "a 3 s sample of the app's pid")
        self.assertTrue((j.out / "diag-stalesample.txt").exists())

    def test_nothing_is_saved_when_the_daemon_is_behind_too(self):
        j = journey(App())
        j.evaluate = lambda name, want, cache: (False, {})
        with self.assertRaises(D.StepError):
            j.step_expect({"timeout": 0.1, "all": [{"daemon_line": "x"}, {"app_text_line": "x"}]})
        self.assertFalse((j.out / "diag-staleview.json").exists())
        self.assertEqual(self.sampled, [])


if __name__ == "__main__":
    unittest.main()
