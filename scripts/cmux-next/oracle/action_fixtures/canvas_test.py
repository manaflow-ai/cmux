#!/usr/bin/env python3
"""Tests for the canvas-layout gap fixture (p15-oracle-083).

Run: python3 -I scripts/cmux-next/oracle/action_fixtures/canvas_test.py (stdlib unittest, no app, Linux too).
A fake app answers action.run, action.describe and debug.pane_chrome the way the canvas handlers do: the canvas
context follows toggleCanvasLayout, and the panes the build makes reach their frames after a few reads.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ORACLE = HERE.parent
SCRIPTS = ORACLE.parent
REPO = SCRIPTS.parents[1]
sys.path.insert(0, str(ORACLE))

import action_fixtures  # noqa: E402
from action_fixtures import canvas  # noqa: E402

GAPS = SCRIPTS / "every-action-gaps.json"
CATALOG = REPO / "scripts" / "fuzz" / "macos-matrix" / "fixtures" / "action-list.json"

BASE = [0, 0, 600, 800]
# The settled cells after BUILD: B (a third, top), C (a third, bottom), D (two thirds, full height).
BUILT = [BASE, [608, 0, 400, 396], [608, 404, 400, 396], [1016, 0, 800, 800]]


class FakeApp:
    """The control calls the fixture makes. `moving`: reads of debug.pane_chrome before the built panes stop."""

    def __init__(self, moving=2, refuse=None, sticky=False, cells=None):
        self.canvas = False
        self.built = 0
        self.moving = moving
        self.refuse = refuse or set()
        self.sticky = sticky  # the canvas ignores toggleCanvasLayout
        self.cells = cells
        self.calls = []

    def __call__(self, method, params=None):
        params = params or {}
        self.calls.append((method, params.get("action")))
        if method == "action.run":
            return self.run(params)
        if method == "action.describe":
            return {"action": {"id": params["action"], "available": self.canvas,
                               **({} if self.canvas else {"context_reason": "needs canvasLayout"})}}
        if method == "debug.pane_chrome":
            return {"windows": [{"panes": [{"pane": f"p{i}", "cell": c} for i, c in enumerate(self.read_cells())]}]}
        return {"error": {"code": "not_found", "message": method}}

    def run(self, params):
        action = params["action"]
        assert params.get("focus") is True, params
        if action in self.refuse:
            return {"error": {"code": "refused", "message": f"{action} refused"}}
        if action == canvas.TOGGLE:
            if not self.sticky:
                self.canvas = not self.canvas
        else:
            self.built += 1
        return {"ok": True}

    def read_cells(self):
        if self.cells is not None:
            return self.cells
        if self.built < len(canvas.BUILD):
            return [BASE]
        if self.moving:
            self.moving -= 1
            step = self.moving % 7 + 1  # mid-animation: every read differs from the one before
            return [BASE] + [[x + step, y, w - step, h] for x, y, w, h in BUILT[1:]]
        return BUILT

    def actions(self):
        return [a for m, a in self.calls if m == "action.run"]


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def pause(self, seconds):
        self.now += seconds


def driver(app):
    clock = Clock()
    return canvas.RpcDriver(app, clock=clock, pause=clock.pause)


class CanvasLayoutTests(unittest.TestCase):
    def test_enter_builds_the_seed_waits_for_it_then_shows_the_canvas(self):
        app = FakeApp(moving=3)
        context = canvas.CanvasLayout()
        self.assertIsNone(context.enter(driver(app)))
        self.assertTrue(app.canvas)
        self.assertTrue(context.made)
        self.assertEqual(app.actions(), [a for a, _ in canvas.BUILD] + [canvas.TOGGLE])
        # The toggle came only after two equal reads of the settled cells.
        toggle = app.calls.index(("action.run", canvas.TOGGLE))
        reads = [i for i, (m, _) in enumerate(app.calls) if m == "debug.pane_chrome"]
        self.assertGreaterEqual(len(reads), 5)
        self.assertLess(reads[-1], toggle)

    def test_a_second_enter_before_leave_keeps_the_layout(self):
        app = FakeApp()
        context = canvas.CanvasLayout()
        d = driver(app)
        context.enter(d)
        ran = list(app.actions())
        self.assertIsNone(context.enter(d))
        self.assertEqual(app.actions(), ran)
        app.canvas = False  # the canvas went (a sample turned it off): the second enter shows it again
        self.assertIsNone(context.enter(d))
        self.assertEqual(app.actions(), ran + [canvas.TOGGLE])
        self.assertTrue(app.canvas)

    def test_leave_shows_the_daemon_layout_and_enter_builds_again_after_it(self):
        app = FakeApp()
        context = canvas.CanvasLayout()
        d = driver(app)
        context.enter(d)
        self.assertIsNone(context.leave(d))
        self.assertFalse(app.canvas)
        self.assertFalse(context.made)
        self.assertIsNone(context.leave(d))  # nothing shows: nothing to do
        self.assertEqual(app.actions().count(canvas.TOGGLE), 2)
        app.built = 0  # the sweep's close_new closed what enter made
        self.assertIsNone(context.enter(d))
        self.assertEqual(app.actions().count("newColumn"), 4)

    def test_a_canvas_left_from_before_goes_first(self):
        app = FakeApp()
        app.canvas = True
        self.assertIsNone(canvas.CanvasLayout().enter(driver(app)))
        self.assertEqual(app.actions()[0], canvas.TOGGLE)
        self.assertEqual(app.actions()[-1], canvas.TOGGLE)
        self.assertTrue(app.canvas)

    def test_a_failed_build_step_is_named_and_shows_no_canvas(self):
        app = FakeApp(refuse={"newRow"})
        context = canvas.CanvasLayout()
        why = context.enter(driver(app))
        self.assertIn("setup newRow failed", why)
        self.assertFalse(app.canvas)
        self.assertFalse(context.made)
        self.assertIsNone(context.leave(driver(app)))

    def test_a_seed_with_one_width_names_it(self):
        same = [[0, 0, 400, 800], [408, 0, 400, 396], [408, 404, 400, 396]]
        why = canvas.CanvasLayout().enter(driver(FakeApp(cells=same)))
        self.assertIn("share one width", why)

    def test_cells_that_never_settle_are_named(self):
        why = canvas.CanvasLayout().enter(driver(FakeApp(moving=10_000)))
        self.assertIn("did not settle", why)

    def test_no_cells_is_named(self):
        why = canvas.CanvasLayout().enter(driver(FakeApp(cells=[])))
        self.assertIn("no pane cells", why)

    def test_a_context_that_does_not_follow_the_toggle_is_named(self):
        why = canvas.CanvasLayout().enter(driver(FakeApp(sticky=True)))
        self.assertIn("canvasLayout is still off after toggleCanvasLayout", why)

    def test_missing_spread_names_each_shared_measure(self):
        self.assertEqual(canvas.missing_spread([tuple(c) for c in BUILT]), [])
        self.assertEqual(canvas.missing_spread([(0, 0, 10, 10), (20, 0, 10, 10)]),
                         ["top edge", "bottom edge", "width", "height"])

    def test_pane_cells_round_and_skip_malformed_cells(self):
        reply = {"windows": [{"panes": [{"pane": "a", "cell": [0.4, 1.6, 10.2, 9.5]}, {"pane": "b"},
                                        {"pane": "c", "cell": [1, 2]}]}, {"panes": [{"cell": [5, 5, 5, 5]}]}]}

        class One:
            def rpc(self, method, params=None):
                return reply
        self.assertEqual(canvas.pane_cells(One()), [(0, 2, 10, 10)])

    def test_reply_error_reads_errors_and_refusals(self):
        self.assertIsNone(canvas.reply_error({"ok": True}))
        self.assertEqual(canvas.reply_error({"error": {"code": "x", "message": "y"}}), "x: y")
        self.assertEqual(canvas.reply_error({"refused_action": "canvasTidy"}), "refused: canvasTidy")
        self.assertEqual(canvas.reply_error(None), "no reply")


class OracleSetupTests(unittest.TestCase):
    def test_setup_and_teardown_drive_the_same_context(self):
        app = FakeApp(moving=0)
        canvas.setup(app)
        self.assertTrue(app.canvas)
        canvas.teardown(app)
        self.assertFalse(app.canvas)

    def test_a_setup_that_does_not_hold_raises(self):
        with self.assertRaisesRegex(canvas.FixtureSetupError, "setup column.widthOneThird failed"):
            canvas.setup(FakeApp(refuse={"column.widthOneThird"}))

    def test_a_teardown_that_cannot_turn_the_canvas_off_raises(self):
        app = FakeApp(sticky=True)
        app.canvas = True
        with self.assertRaisesRegex(canvas.FixtureSetupError, "still on"):
            canvas.teardown(app)

    def test_rpc_driver_sends_args_only_when_given(self):
        sent = []
        d = canvas.RpcDriver(lambda m, p: sent.append((m, p)))
        d.run("canvasZoomIn")
        d.run("x", {"n": 1})
        d.rpc("action.describe")
        self.assertEqual(sent, [("action.run", {"action": "canvasZoomIn", "focus": True}),
                                ("action.run", {"action": "x", "focus": True, "args": {"n": 1}}),
                                ("action.describe", {})])

    def test_rpc_driver_wait_is_bounded(self):
        clock = Clock()
        d = canvas.RpcDriver(lambda m, p: None, clock=clock, pause=clock.pause)
        self.assertIsNone(d.wait(lambda: False, 1.0))
        self.assertGreaterEqual(clock.now, 1.0)
        self.assertLess(clock.now, 1.2)
        self.assertEqual(d.wait(lambda: "yes", 1.0), "yes")


class FamilyTests(unittest.TestCase):
    def setUp(self):
        self.families = action_fixtures.load_families()
        self.family = next(f for f in self.families.families if f.name == canvas.FAMILY)

    def test_the_family_loads_with_its_closures(self):
        self.assertEqual(self.families.owners[canvas.CONTEXT], "canvas")
        self.assertEqual(self.family.path.stem, canvas.FAMILY)  # driver_app imports action_fixtures.<setup>
        self.assertEqual(dict(self.family.prepare), {"canvasZoomReset": (("canvasZoomIn", {}),)})

    def test_closes_every_canvas_layout_gap(self):
        # Holds before and after p15-oracle-087 applies the gap closures to every-action-gaps.json: each closed id
        # is still listed with the canvasLayout reason or gone, and no canvasLayout gap is left outside CLOSES.
        self.assertEqual(len(set(canvas.CLOSES)), 13)
        self.assertEqual(sorted(self.family.closes), sorted(canvas.CLOSES))
        gaps = json.loads(GAPS.read_text())["gaps"]
        reason = f"needs context the sweep does not set up: {canvas.CONTEXT}"
        for ident in canvas.CLOSES:
            with self.subTest(ident=ident):
                self.assertEqual(gaps.get(ident, reason), reason)
        stray = sorted(i for i, why in gaps.items() if why.endswith(f": {canvas.CONTEXT}") and i not in canvas.CLOSES)
        self.assertEqual(stray, [])

    def test_the_sweep_plans_the_canvas_rows_with_the_family(self):
        # The checked-in catalog has no canvas rows yet: plan each id as action.list gives it (requires canvasLayout,
        # a pane target), through the sweep loaded as the oracle loads it.
        sweep_mod = action_fixtures.load_sweep(["--plan-only", "--catalog", str(CATALOG), "--out",
                                                tempfile.mkdtemp(prefix="canvas-plan-")])
        sweep = sweep_mod.Sweep(None, "light", None)
        sweep.base = dict(sweep_mod.PLAN_BASE)
        for ident in canvas.CLOSES:
            with self.subTest(ident=ident):
                action = {"id": ident, "requires": [canvas.CONTEXT], "targets": ["pane"]}
                plan, skipped = sweep.plan(action)
                self.assertIsNone(skipped)
                self.assertEqual(plan["families"], [canvas.CONTEXT])
                row = sweep_mod.plan_row(sweep, action)
                prepare = [step for step, _ in row["prepare"]]
                self.assertEqual(prepare, ["canvasZoomIn"] if ident == "canvasZoomReset" else [])


if __name__ == "__main__":
    unittest.main()
