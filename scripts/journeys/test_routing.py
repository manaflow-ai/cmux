#!/usr/bin/env python3
"""routing_marker (ext_routing.py) names where a typed marker landed: right, wrong, lost or split. No fleet, no app.

    python3 scripts/journeys/test_routing.py
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402
import ext_routing  # noqa: E402
import ext_smoke  # noqa: E402

LINE = "RA1-123456-42"


class App:
    def __init__(self, screens, shown):
        self.screens, self.shown = screens, shown  # {term: text}, {pane: text}

    def screen(self, term):
        return {"text": self.screens.get(term, "")}

    def panes(self):
        return [{"pane": p, "text": t, "focused": p == "p2"} for p, t in self.shown.items()]


class Journey:
    def __init__(self, app):
        self.app = app
        self.smoke_named = {"left": {"pane": "p1", "term": "term_1", "workspace": "w1"},
                            "right": {"pane": "p2", "term": "term_2", "workspace": "w1"}}
        self.smoke_snapshots = {"s": {"terms": ["k1"]}}

    def sub(self, text):
        return text


TERMS = {"k1": ("w1", "p1", True, "term_1"), "k2": ("w1", "p2", True, "term_2")}


class RoutingMarkerTests(unittest.TestCase):
    def setUp(self):
        self._layout, self._focused = ext_smoke._layout, ext_smoke._focused_pane
        ext_smoke._layout = lambda j: (TERMS, {})
        ext_smoke._focused_pane = lambda j: "p2"

    def tearDown(self):
        ext_smoke._layout, ext_smoke._focused_pane = self._layout, self._focused

    def judge(self, screens, shown, on):
        return ext_routing.cond_routing_marker(Journey(App(screens, shown)), {"line": LINE, "on": on}, {})

    def test_right_when_only_the_named_terminal_ran_it_and_its_pane_shows_it(self):
        ok, detail = self.judge({"term_2": f"$ x\n{LINE}\n$"}, {"p2": LINE, "p1": ""}, "right")
        self.assertTrue(ok, detail)
        self.assertEqual(detail["verdict"], "right")

    def test_wrong_names_the_pane_it_landed_in(self):
        ok, detail = self.judge({"term_1": LINE}, {"p1": LINE}, "right")
        self.assertFalse(ok)
        self.assertEqual(detail["verdict"], "wrong")
        self.assertEqual(detail["landed"][0]["name"], "left")

    def test_lost_and_split(self):
        self.assertEqual(self.judge({}, {}, "right")[1]["verdict"], "lost")
        self.assertEqual(self.judge({"term_1": LINE, "term_2": LINE}, {}, "right")[1]["verdict"], "split")

    def test_new_since_snapshot_and_focused(self):
        ok, detail = self.judge({"term_2": LINE}, {"p2": LINE}, "new:s")
        self.assertTrue(ok, detail)
        ok, detail = self.judge({"term_2": LINE}, {"p2": LINE}, "focused")
        self.assertTrue(ok, detail)

    def test_daemon_right_but_app_shows_it_elsewhere_is_no_pass(self):
        ok, detail = self.judge({"term_2": LINE}, {"p1": LINE}, "right")
        self.assertFalse(ok)
        self.assertEqual(detail["verdict"], "right")
        self.assertTrue(any("does not show it" in p for p in detail["problems"]))


if __name__ == "__main__":
    unittest.main()
