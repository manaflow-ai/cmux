#!/usr/bin/env python3
"""STRESS-lite set-up keeps the journey's base terminal shown and focused, no fleet, no app.

    python3 scripts/journeys/test_grow_workspaces_focus.py

cmdn-latency step 11 ("the app still types into the base terminal") failed on every round of every build on
2026-11-04 (24 rounds, 07:05Z-12:07Z; DOGFOOD BENCH STATUS 11935): `grow_workspaces` makes 60 workspaces with
`action.run newTab {name}`, and the app shows each new one, so the last (stress-NONCE-59) has the keyboard. The
journey typed its marker there (frame check-35.png of 063893e9-cmux23-1104T115254 shows it) and read the base
terminal. Its docstring said "the journey's terminal stays the shown one". The step now shows the base
terminal's workspace again (`cmux workspace ID focus`) and waits until the base pane has the focus.
"""
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402


class FakeApp:
    """Workspaces with one pane and one terminal each; a newTab is shown and focused, as the app does."""

    def __init__(self, refocus_works=True):
        self.ws = [{"id": "ws_base", "name": "cmdn-base", "pane": "pane_base", "term": "term_base"}]
        self.focused = "pane_base"
        self.refocus_works = refocus_works
        self.calls = []
        self.snapshot_window = None

    def rpc(self, method, params=None, timeout=None):
        self.calls.append(("rpc", method, params))
        if method == "snapshot.get":
            return {"topology": {"workspaces": [
                {"id": w["id"], "name": w["name"], "screens": [{"panes": [{"id": w["pane"], "selected_tab": "t_" + w["id"],
                 "tabs": [{"id": "t_" + w["id"], "selected": True, "terminal": w["term"]}]}]}]} for w in self.ws]}}
        if method == "action.run" and params["action"] == "newTab":
            n = len(self.ws)
            self.ws.append({"id": f"ws_{n}", "name": params["args"]["name"], "pane": f"pane_{n}", "term": f"term_{n}"})
            self.focused = f"pane_{n}"
            return {}
        if method == "debug.surfaces":
            return {"windows": [{"panes": [{"pane": w["pane"], "kind": "terminal", "terminal_id": w["term"],
                                            "focused": w["pane"] == self.focused} for w in self.ws]}]}
        return {}

    def cmux(self, *args, timeout=30):
        self.calls.append(("cmux",) + args)
        if args[:1] == ("workspace",) and args[2:] == ("focus",) and self.refocus_works:
            w = next(w for w in self.ws if w["id"] == args[1])
            self.focused = w["pane"]
        return {}

    def screen(self, term):
        return {"text": D.PROMPT}

    def panes(self):
        return self.rpc("debug.surfaces")["windows"][0]["panes"]


def journey(app):
    j = D.Journey({"id": "grow-test", "steps": []}, app, tempfile.mkdtemp(), None, 0)
    j.term, j.pane, j.host_pid = "term_base", "pane_base", 1
    return j


class GrowWorkspacesKeepsTheBaseTerminal(unittest.TestCase):
    def test_the_base_pane_has_the_focus_after_the_set_up(self):
        app = FakeApp()
        j = journey(app)
        with mock.patch.object(D.time, "sleep", lambda s: None):
            j.step_grow_workspaces({"count": 6, "busy": 2, "settle": 0})
        self.assertEqual(app.focused, "pane_base")
        self.assertIn(("cmux", "workspace", "ws_base", "focus"), app.calls)
        self.assertEqual((j.term, j.pane), ("term_base", "pane_base"))

    def test_a_refocus_that_does_not_take_is_a_step_error(self):
        app = FakeApp(refocus_works=False)
        j = journey(app)
        clock = iter(range(0, 10**6, 5))
        with mock.patch.object(D.time, "sleep", lambda s: None), mock.patch.object(D, "now", lambda: next(clock)):
            with self.assertRaises(D.StepError) as e:
                j.step_grow_workspaces({"count": 4, "busy": 1, "settle": 0})
        self.assertIn("base terminal", str(e.exception))


if __name__ == "__main__":
    unittest.main()
