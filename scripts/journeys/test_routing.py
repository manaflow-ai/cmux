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


    def test_unjudged_when_the_harness_cannot_name_one_expected_terminal(self):
        j = Journey(App({"term_2": LINE}, {"p2": LINE}))
        j.smoke_snapshots = {"s": {"terms": []}}  # two new terminals since the snapshot
        ok, detail = ext_routing.cond_routing_marker(j, {"line": LINE, "on": "new:s"}, {})
        self.assertFalse(ok)
        self.assertEqual(detail["verdict"], "unjudged")

    def test_in_new_workspace_refuses_a_new_terminal_in_an_old_workspace(self):
        j = Journey(App({"term_2": LINE}, {"p2": LINE}))
        j.smoke_snapshots = {"s": {"terms": ["k1"], "workspaces": ["w1"]}}
        ok, detail = ext_routing.cond_routing_marker(j, {"line": LINE, "on": "new:s", "in_new_workspace": True}, {})
        self.assertFalse(ok)
        self.assertEqual(detail["verdict"], "right")
        self.assertTrue(any("made no new workspace" in p for p in detail["problems"]))


class WorkspaceKeyMapTests(unittest.TestCase):
    """routing_map_workspace_keys takes the app's own digit of each workspace: Cmd-1 is Home here, Cmd-2 the
    slot's first workspace, Cmd-3 and Cmd-4 the journey's; a digit that changes nothing maps nothing."""

    def test_maps_by_what_the_window_shows_after_each_digit(self):
        shown = {"page": None, "selected": "ws_f2"}
        effect = {1: ("home", None), 2: (None, "ws_slot"), 3: (None, "ws_f1"), 4: (None, "ws_f2")}
        pressed = []

        class Fake:
            smoke_named = {"f1": {"workspace": "ws_f1"}, "f2": {"workspace": "ws_f2"}}
            key_window = "win1"

            class app:
                @staticmethod
                def rpc(method, params=None):
                    assert method == "debug.windows"
                    return {"windows": [{"id": "win1", "open": True, "visible": True, "shown_page": shown["page"],
                                         "selected": shown["selected"]}]}

            def topology(self):
                return {"workspaces": [{"id": w, "key": w} for w in ("ws_slot", "ws_f1", "ws_f2")]}

        def key(j, step):
            digit = int(step["key"])
            pressed.append(digit)
            page, sel = effect.get(digit, (shown["page"], shown["selected"]))
            shown["page"], shown["selected"] = page, (sel or shown["selected"])
            return {}
        saved = ext_smoke.step_smoke_key
        ext_smoke.step_smoke_key = key
        try:
            rec = ext_routing.step_routing_map_workspace_keys(Fake(), {"names": ["f1", "f2"]})
        finally:
            ext_smoke.step_smoke_key = saved
        self.assertEqual(rec["digits"], {"f1": 3, "f2": 4})
        self.assertEqual(pressed[:4], [1, 2, 3, 4])


if __name__ == "__main__":
    unittest.main()
