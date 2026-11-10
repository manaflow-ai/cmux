#!/usr/bin/env python3
"""tests/ui-structure/thread_structure.py on recorded threads (python3 tests/ui-structure/test_thread_structure.py).

The proof the guard catches #37777 and passes the transcript before it:
  - fixtures/chief-panel-37777-shipped.json, the shipped nightly's Chief panel with #37777 (b266fb6),
    fails on exactly that regression's rules: a column beside the thread, avatars outside it, a
    picture far past bubble size, my bubble off the right edge, one Needs you heading three cards;
  - fixtures/native-*.json, the native transcript (b266fb6^; MessagesLab is unchanged since) read
    through its accessibility tree by ChiefThreadStructureTests.swift at each gallery width, passes.
The normalizer cases build raw accessibility trees of both renderers by hand.
"""
from __future__ import annotations

import importlib.util
import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
_spec = importlib.util.spec_from_file_location("thread_structure", HERE / "thread_structure.py")
ts = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ts)
FIXTURES = HERE / "fixtures"


def load(name: str) -> dict:
    return json.loads((FIXTURES / name).read_text())


def rules(found: list[dict]) -> set[str]:
    return {v["rule"] for v in found}


class ShippedRegression(unittest.TestCase):
    def test_the_shipped_37777_chief_panel_fails_on_exactly_its_regression(self):
        found = ts.check(load("chief-panel-37777-shipped.json"))
        self.assertEqual(rules(found), {"no-side-column", "avatar-inline", "attachment-bubble-size", "sender-aligned", "needs-you-once"})

    def test_the_same_thread_in_the_docked_home_still_fails_its_thread_rules(self):
        # Home may have a list column; its thread may not have loose avatars or a giant picture.
        found = rules(ts.check(load("chief-panel-37777-shipped.json"), surface="home"))
        self.assertNotIn("no-side-column", found)
        self.assertTrue({"avatar-inline", "attachment-bubble-size", "needs-you-once"} <= found)


class NativeTranscript(unittest.TestCase):
    def test_every_native_gallery_variant_passes(self):
        natives = sorted(FIXTURES.glob("native-*.json"))
        self.assertGreaterEqual(len(natives), 3, "the native gallery variants are recorded")
        for path in natives:
            with self.subTest(path.name):
                snap = json.loads(path.read_text())
                self.assertGreaterEqual(len(snap["messages"]), 3)
                self.assertEqual(ts.check(snap), [], path.name)


class Rules(unittest.TestCase):
    def base(self) -> dict:
        return {"surface": "chief-panel", "surface_frame": [0, 0, 600, 800], "thread_frame": [0, 0, 600, 800],
                "messages": [
                    {"frame": [20, 100, 240, 40], "mine": False, "sender": "Chief", "text": "hi", "kind": "text", "tail": True},
                    {"frame": [340, 160, 234, 40], "mine": True, "sender": "You", "text": "yo", "kind": "text", "tail": True},
                ], "avatars": [], "side_elements": []}

    def test_a_good_thread_passes(self):
        self.assertEqual(ts.check(self.base()), [])

    def test_the_bubble_column_follows_the_native_rule(self):
        self.assertAlmostEqual(ts.bubble_max_width(ts.load_spec(), 628), 358.4 + 24)
        self.assertAlmostEqual(ts.bubble_max_width(ts.load_spec(), 1192), 358.4 + 0.654 * 564 + 24)

    def test_a_full_width_card_fails(self):
        snap = self.base()
        snap["thread_frame"] = snap["surface_frame"] = [0, 0, 380, 800]
        snap["messages"][0]["frame"] = [8, 100, 364, 120]
        snap["messages"][1]["frame"] = [200, 240, 154, 40]
        self.assertTrue({"bubble-not-full-width", "bubble-max-width"} <= rules(ts.check(snap)))

    def test_an_inline_avatar_passes_and_a_column_avatar_fails(self):
        snap = self.base()
        snap["messages"][0]["frame"] = [56, 100, 240, 40]
        snap["avatars"] = [{"frame": [20, 112, 28, 28], "label": "CH"}]
        self.assertEqual(ts.check(snap), [])
        snap["avatars"].append({"frame": [20, 400, 28, 28], "label": "AW"})
        self.assertEqual(rules(ts.check(snap)), {"avatar-inline"})

    def test_a_tail_missing_at_a_runs_end_fails(self):
        snap = self.base()
        snap["messages"][0]["tail"] = False
        self.assertEqual(rules(ts.check(snap)), {"tail-on-run-end"})

    def test_no_thread_fails_thread_present(self):
        snap = self.base()
        snap["thread_frame"] = None
        self.assertEqual(rules(ts.check(snap)), {"thread-present"})


def node(role, frame, children=(), **kw):
    return {"role": role, "frame": frame, "children": list(children), **kw}


class Normalize(unittest.TestCase):
    def test_a_native_tree_reads_the_message_elements(self):
        thread = node("AXList", [100, 40, 600, 760], label="Messages", children=[
            node("AXStaticText", [120, 100, 200, 36], role_description="message", title="Chief", value="hello"),
            node("AXStaticText", [470, 160, 204, 36], role_description="message", title="You", value="hi back"),
        ])
        split = node("AXSplitGroup", [0, 40, 700, 760], children=[node("AXGroup", [0, 40, 99, 760]), node("AXGroup", [100, 40, 600, 760], children=[thread])])
        tree = node("AXApplication", None, children=[node("AXWindow", [0, 0, 700, 800], children=[split])])
        snap = ts.normalize(tree, "chief-panel")
        self.assertEqual(snap["thread_frame"], [100, 40, 600, 760])
        self.assertEqual(snap["surface_frame"], [100, 40, 600, 760])
        self.assertEqual([m["mine"] for m in snap["messages"]], [False, True])
        self.assertEqual(ts.check(snap), [])

    def test_a_web_page_with_a_list_column_beside_the_thread_fails(self):
        tiles = [node("AXButton", [10, 60 + 110 * i, 56, 56], children=[node("AXStaticText", [20, 80 + 110 * i, 30, 16], value=l)])
                 for i, l in enumerate(["CC", "CF", "CH"])]
        region = node("AXGroup", [90, 0, 1000, 1300], label="Messages", children=[
            node("AXGroup", [112, 100, 620, 100], children=[node("AXStaticText", [126, 110, 590, 80], value="Needs you: power-cycle the Mac")]),
            node("AXGroup", [112, 260, 620, 100], children=[node("AXStaticText", [126, 270, 590, 80], value="Needs you: power-cycle the Mac")]),
            node("AXGroup", [700, 400, 360, 40], children=[node("AXStaticText", [712, 408, 330, 20], value="mine")]),
        ])
        page = node("AXWebArea", [0, 0, 1090, 1300], children=[*tiles, region])
        tree = node("AXApplication", None, children=[node("AXWindow", [0, 0, 1090, 1300], children=[page])])
        found = rules(ts.check(ts.normalize(tree, "chief-panel")))
        self.assertTrue({"no-side-column", "avatar-inline", "needs-you-once"} <= found, found)


if __name__ == "__main__":
    sys.exit(0 if unittest.main(exit=False).result.wasSuccessful() else 1)
