#!/usr/bin/env python3
"""Tests for the canvas gap fixture (p15-oracle-083).

Run: python3 -I scripts/cmux-next/oracle/action_fixtures/canvas_test.py (stdlib unittest, no app).
A fake driver stands in for the app's socket: panes, splits, the canvas toggle and the registry context.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[3]
sys.path.insert(0, str(HERE))

import canvas  # noqa: E402


class FakeApp:
    """The socket surface the fixture uses. `refuse` maps an action id to the error its action.run answers."""

    def __init__(self, panes: int = 1, refuse: dict | None = None, stale_reads: int = 0) -> None:
        self.panes = panes
        self.canvas = False
        self.refuse = refuse or {}
        self.ran: list[str] = []
        # Reads that still answer the previous state (the store and catalog apply after the reply).
        self.stale_reads = stale_reads
        self.stale = 0
        self.shown_before = False
        self.panes_before = panes

    def run(self, action, args=None):
        self.ran.append(action)
        if action in self.refuse:
            return {"error": {"code": "refused", "message": self.refuse[action]}}
        self.shown_before, self.panes_before, self.stale = self.canvas, self.panes, self.stale_reads
        if action.startswith("split"):
            self.panes += 1
        elif action == canvas.TOGGLE:
            self.canvas = not self.canvas
        return {"ok": True}

    def rpc(self, method, params=None):
        stale = self.stale > 0
        if stale:
            self.stale -= 1
        if method == "action.describe":
            assert params == {"action": canvas.PROBE}
            shown = self.shown_before if stale else self.canvas
            return {"action": {"id": canvas.PROBE, "available": shown}}
        if method == "debug.pane_chrome":
            assert params == {"after": "sync"}
            count = self.panes_before if stale else self.panes
            return {"windows": [{"panes": [{"pane": f"p{i}", "cell": [0, 0, 1, 1]} for i in range(count)]}]}
        raise AssertionError(f"unexpected rpc {method}")

    def wait(self, predicate, seconds):
        for _ in range(10):  # the fake's bounded poll: no clock
            value = predicate()
            if value:
                return value
        return None


class EnterLeaveTests(unittest.TestCase):
    def test_enter_splits_three_times_then_shows_a_canvas(self):
        app = FakeApp()
        self.assertIsNone(canvas.CONTEXTS["canvasLayout"].enter(app))
        self.assertEqual(app.ran, ["splitRight", "splitDown", "splitRight", "toggleCanvasLayout"])
        self.assertEqual(app.panes, 4)
        self.assertTrue(app.canvas)

    def test_enter_waits_for_the_store_and_catalog(self):
        app = FakeApp(stale_reads=3)
        self.assertIsNone(canvas.enter(app))
        self.assertTrue(app.canvas)

    def test_leave_turns_the_canvas_off(self):
        app = FakeApp()
        canvas.enter(app)
        self.assertIsNone(canvas.CONTEXTS["canvasLayout"].leave(app))
        self.assertFalse(app.canvas)
        self.assertEqual(app.ran[-1], "toggleCanvasLayout")

    def test_leave_without_a_canvas_runs_nothing(self):
        app = FakeApp()
        self.assertIsNone(canvas.leave(app))
        self.assertEqual(app.ran, [])

    def test_a_refused_split_is_the_rows_gap_reason(self):
        app = FakeApp(refuse={"splitDown": "the pane is too small to split"})
        reason = canvas.enter(app)
        self.assertEqual(reason, "setup splitDown failed: refused: the pane is too small to split")
        self.assertFalse(app.canvas)
        self.assertNotIn("toggleCanvasLayout", app.ran)

    def test_a_canvas_left_from_before_is_reported_not_toggled_off(self):
        app = FakeApp()
        app.canvas = True
        self.assertIn("already shows", canvas.enter(app))
        self.assertEqual(app.ran, [])

    def test_a_toggle_that_shows_nothing_is_reported(self):
        app = FakeApp()
        app.run = lambda action, args=None: {"ok": True} if action == canvas.TOGGLE else FakeApp.run(app, action, args)
        self.assertEqual(canvas.enter(app), "toggleCanvasLayout showed no canvas")

    def test_a_failed_leave_is_drift(self):
        app = FakeApp()
        canvas.enter(app)
        app.refuse[canvas.TOGGLE] = "busy"
        self.assertEqual(canvas.leave(app), "toggleCanvasLayout off failed: refused: busy")


class ClosureListTests(unittest.TestCase):
    def setUp(self):
        self.closures = json.loads((ROOT / "tests/oracle/gap-closures/canvas.json").read_text())
        self.gaps = json.loads((ROOT / "scripts/cmux-next/every-action-gaps.json").read_text())

    def test_closures_name_the_fixture_and_its_ids(self):
        self.assertEqual(self.closures["family"], canvas.FAMILY)
        self.assertEqual(self.closures["context"], canvas.CONTEXT)
        self.assertEqual(ROOT / self.closures["fixture"], HERE / "canvas.py")
        self.assertEqual(sorted(self.closures["closed"]), sorted(canvas.CLOSES))
        self.assertEqual(self.closures["reasoned"], {})

    def test_every_canvas_layout_gap_is_closed(self):
        wanted = sorted(i for i, why in self.gaps["gaps"].items() if canvas.CONTEXT in why)
        self.assertEqual(len(wanted), 13)
        self.assertEqual(sorted(canvas.CLOSES), wanted)

    def test_prepare_only_names_closed_ids(self):
        self.assertLessEqual(set(canvas.PREPARE), set(canvas.CLOSES))


# The arrange commands refuse ("nothing to arrange") when no pane moves. A port of CanvasArranger.frames
# (Packages/macOS/CmuxNext/Sources/CmuxNextLayout/Canvas/CanvasArranger.swift) checks that each one moves a pane
# of the fixture's layout, whatever the pane ids' order and the split divider's width.
GAP = 16.0


def arranged(command, frames, reference):
    panes = sorted(frames.items())

    def changed(fn):
        return {p: fn(f) for p, f in panes if fn(f) != f}

    if command == "canvasAlignLeft":
        x = min(f[0] for _, f in panes)
        return changed(lambda f: (x, f[1], f[2], f[3]))
    if command == "canvasAlignRight":
        x = max(f[0] + f[2] for _, f in panes)
        return changed(lambda f: (x - f[2], f[1], f[2], f[3]))
    if command == "canvasAlignTop":
        y = min(f[1] for _, f in panes)
        return changed(lambda f: (f[0], y, f[2], f[3]))
    if command == "canvasAlignBottom":
        y = max(f[1] + f[3] for _, f in panes)
        return changed(lambda f: (f[0], y - f[3], f[2], f[3]))
    if command == "canvasEqualizeWidths":
        return changed(lambda f: (f[0], f[1], frames[reference][2], f[3]))
    if command == "canvasEqualizeHeights":
        return changed(lambda f: (f[0], f[1], f[2], frames[reference][3]))
    if command in ("canvasDistributeHorizontally", "canvasDistributeVertically"):
        axis = 0 if command == "canvasDistributeHorizontally" else 1
        ordered = sorted(panes, key=lambda pf: (pf[1][axis], pf[0]))
        cursor, moved = ordered[0][1][axis] + ordered[0][1][axis + 2], {}
        for pane, frame in ordered[1:]:
            new = list(frame)
            new[axis] = cursor + GAP
            cursor = new[axis] + new[axis + 2]
            if tuple(new) != frame:
                moved[pane] = tuple(new)
        return moved
    if command == "canvasTidy":
        ox, oy = min(f[0] for _, f in panes), min(f[1] for _, f in panes)
        mid = lambda f: (f[1] + f[3] / 2, f[0] + f[2] / 2)  # noqa: E731
        rows, bottom = [], float("-inf")
        for pane, frame in sorted(panes, key=lambda pf: (*mid(pf[1]), pf[0])):
            if not rows or mid(frame)[0] >= bottom:
                rows.append([(pane, frame)])
                bottom = frame[1] + frame[3]
            else:
                rows[-1].append((pane, frame))
                bottom = max(bottom, frame[1] + frame[3])
        moved, y = {}, oy
        for row in rows:
            x, height = ox, 0.0
            for pane, frame in sorted(row, key=lambda pf: (mid(pf[1])[1], pf[0])):
                new = (x, y, frame[2], frame[3])
                if new != frame:
                    moved[pane] = new
                x, height = new[0] + new[2] + GAP, max(height, new[3])
            y += height + GAP
        return moved
    raise AssertionError(command)


def layout(divider, ids):
    """The fixture's A | (B / (C | D)) in a 1600 x 900 view, panes `divider` points apart; `ids` orders A..D."""
    w, h, d = 1600.0, 900.0, divider
    half_w, half_h = (w - d) / 2, (h - d) / 2
    quarter = (half_w - d) / 2
    right = half_w + d
    a, b, c, dd = ids
    return {a: (0.0, 0.0, half_w, h), b: (right, 0.0, half_w, half_h),
            c: (right, half_h + d, quarter, half_h), dd: (right + quarter + d, half_h + d, quarter, half_h)}, dd


ARRANGE = [i for i in canvas.CLOSES if not i.startswith(("canvasZoom", "canvasOverview"))]


class ArrangeMovesTests(unittest.TestCase):
    def test_every_arrange_command_moves_a_pane_of_the_fixture(self):
        self.assertEqual(len(ARRANGE), 9)
        for divider in (0.0, 1.0, 16.0):
            for ids in ((1, 2, 3, 4), (4, 3, 2, 1), (2, 1, 4, 3)):
                frames, focused = layout(divider, ids)
                for command in ARRANGE:
                    with self.subTest(command=command, divider=divider, ids=ids):
                        self.assertTrue(arranged(command, frames, focused), f"{command} moves nothing")

    def test_the_port_matches_the_swift_tests(self):
        # CanvasArrangeActionTests.tidyPacksPanesIntoARowAtTheGap.
        frames = {1: (40.0, 60.0, 400.0, 300.0), 2: (900.0, 120.0, 300.0, 200.0)}
        self.assertEqual(arranged("canvasTidy", frames, 1), {2: (456.0, 60.0, 300.0, 200.0)})


if __name__ == "__main__":
    unittest.main()
