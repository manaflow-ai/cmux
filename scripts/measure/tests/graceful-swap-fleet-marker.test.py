#!/usr/bin/env python3
"""graceful-swap-fleet.py names why a save drew nothing from the chat pages' DOM: no GSW marker in the edit's element
means the component never re-rendered, a marker means it drew out of the watched rect. Compiles no_change_cause and
marker_dom alone from the source, so the test needs none of the fleet script's imports."""
import ast
import os
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SOURCE = open(os.path.join(HERE, "..", "graceful-swap-fleet.py"), encoding="utf-8").read()


def methods():
    tree = ast.parse(SOURCE)
    markers = next(n for n in tree.body if isinstance(n, ast.Assign) and getattr(n.targets[0], "id", "") == "MARKERS")
    fns = [n for n in ast.walk(tree) if isinstance(n, ast.FunctionDef) and n.name in ("no_change_cause", "marker_dom")]
    scope = {"log": lambda text: None}
    exec(compile(ast.Module(body=[markers, *fns], type_ignores=[]), "graceful-swap-fleet.py", "exec"), scope)
    return type("Fleet", (), {"no_change_cause": scope["no_change_cause"], "marker_dom": scope["marker_dom"]})


class Fake(methods()):
    def __init__(self, foot_texts, rows=5):
        self.foot_texts, self.rows = foot_texts, rows
        self.chats = {"a": {"pane": "pa"}, "b": {"pane": "pb"}}
        self.results = {"latency": {}}

    def page_sources(self):
        return {"a": 1, "b": 1}

    def overlay_status(self):
        return "on"

    def timing_lines(self):
        return self.rows

    def dev_log_tail(self):
        return ""

    def rpc(self, method, params, timeout):
        assert params["selector"] == ".acpmux-composer-foot"
        text = self.foot_texts[{"pa": "a", "pb": "b"}[params["pane"]]]
        return {"elements": [] if text is None else [{"text": text}]}


class MarkerCause(unittest.TestCase):
    """Step 61294ed3 (2026-11-28): the pages took the save, nothing drew, and the cause could not say why."""

    def test_not_rerendered(self):
        cause = Fake({"a": "GT m1 Normal", "b": "GT m1 Normal"}).no_change_cause("composer", 0)
        self.assertIn("did not re-render", cause)

    def test_drew_out_of_sight(self):
        fleet = Fake({"a": "GT m1 NormalGSW", "b": "GT m1 Normal"})
        cause = fleet.no_change_cause("composer", 0)
        self.assertIn("holds the GSW marker in chat-a", cause)
        self.assertEqual(fleet.results["latency"]["composer-cause"]["marker"]["b"]["marker"], False)

    def test_no_element_is_named(self):
        self.assertIn("not on the page", Fake({"a": None, "b": None}).no_change_cause("composer", 0))

    def test_settings_has_no_marker_read(self):
        fleet = Fake({"a": "", "b": ""})
        self.assertEqual(fleet.marker_dom("settings"), {})
        self.assertNotIn("marker", fleet.no_change_cause("settings", 0).split("watched region")[1])


if __name__ == "__main__":
    unittest.main()
