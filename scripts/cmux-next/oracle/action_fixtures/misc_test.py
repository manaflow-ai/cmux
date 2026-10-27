#!/usr/bin/env python3
"""Tests for the misc gap fixtures (p15-oracle-087): paletteOpen, homeChannelsEnabled and textBoxFocused.

Run: python3 -I scripts/cmux-next/oracle/action_fixtures/misc_test.py (stdlib unittest, no app, Linux too).
A fake app answers action.run, action.describe and debug.key the way the handlers do: the palette fact follows
Command Palette and the palette's Escape, Channels follows Enable and Disable Channels, and a terminal's TextBox
has the keyboard after Focus TextBox (a second Focus TextBox gives the keyboard back to the terminal). Each fact can
be published a few describes late, as the registry context follows the view a turn later.
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
sys.path.insert(0, str(ORACLE))

import action_fixtures  # noqa: E402
from action_fixtures import misc  # noqa: E402

GAPS = SCRIPTS / "every-action-gaps.json"
CLOSURES = HERE.parents[3] / "tests" / "oracle" / "gap-closures" / "misc.json"
CATALOG = SCRIPTS.parent / "fuzz" / "macos-matrix" / "fixtures" / "action-list.json"
PROBE_FACT = {probe: fact for fact, probe in misc.PROBES.items()}


class FakeApp:
    """`lag`: describes that still answer the old value after a change. `refuse`: actions that fail."""

    def __init__(self, lag=0, refuse=(), palette=False, channels=False):
        self.facts = {misc.PALETTE_FACT: palette, misc.CHANNELS_FACT: channels, misc.TEXTBOX_FACT: False}
        self.shown = dict(self.facts)  # what describe answers
        self.pending = {}  # fact -> describes left before `shown` follows `facts`
        self.lag, self.refuse = lag, set(refuse)
        self.ran, self.tabs = [], 0

    def set(self, fact, value):
        self.facts[fact] = value
        self.pending[fact] = self.lag

    def run(self, action, args=None, target=None):
        self.ran.append(action)
        if action in self.refuse:
            return {"error": {"code": "refused", "message": f"{action} refused"}}
        if action == "commandPalette":
            self.set(misc.PALETTE_FACT, True)
        elif action == "home.enableChannels":
            self.set(misc.CHANNELS_FACT, True)
        elif action == "home.disableChannels":
            self.set(misc.CHANNELS_FACT, False)
        elif action == "newSurface":
            self.tabs += 1
            self.set(misc.TEXTBOX_FACT, False)  # the new tab's terminal has the keyboard, its box is hidden
        elif action == "focusTextBoxInput":
            self.set(misc.TEXTBOX_FACT, not self.facts[misc.TEXTBOX_FACT])
        else:
            return {"error": f"unexpected {action}"}
        return {"ok": True}

    def rpc(self, method, params=None):
        params = params or {}
        if method == "action.describe":
            fact = PROBE_FACT[params["action"]]
            if self.pending.get(fact, 0) > 0:
                self.pending[fact] -= 1
            else:
                self.shown[fact] = self.facts[fact]
            held = self.shown[fact]
            return {"action": {"id": params["action"], "available": held, **({} if held else {"missing_context": [fact]})}}
        if method == "debug.key" and params == {"key": "escape", "target": "palette"}:
            self.set(misc.PALETTE_FACT, False)
            return {"ok": True}
        return {"error": {"code": "not_found", "message": method}}

    def wait(self, predicate, seconds):
        for _ in range(int(seconds / 0.05) + 1):  # the sweep's bounded poll, without the sleeps
            value = predicate()
            if value:
                return value
        return None


class PaletteOpenTests(unittest.TestCase):
    def test_enter_opens_the_palette_and_waits_for_the_fact(self):
        app = FakeApp(lag=3)
        self.assertIsNone(misc.PaletteOpen().enter(app))
        self.assertEqual(app.ran, ["commandPalette"])
        self.assertTrue(app.shown[misc.PALETTE_FACT])

    def test_an_open_palette_is_not_opened_again(self):
        # A second Command Palette would switch pages in place; the retry's enter keeps the open one.
        app = FakeApp(palette=True)
        self.assertIsNone(misc.PaletteOpen().enter(app))
        self.assertEqual(app.ran, [])

    def test_a_fact_that_never_comes_is_named(self):
        app = FakeApp(lag=10_000)
        self.assertIn("paletteOpen is still off", misc.PaletteOpen().enter(app))

    def test_a_refused_open_is_named(self):
        app = FakeApp(refuse={"commandPalette"})
        self.assertIn("commandPalette failed: refused", misc.PaletteOpen().enter(app))

    def test_leave_closes_a_palette_the_restore_left_open(self):
        app = FakeApp(lag=2)
        context = misc.PaletteOpen()
        context.enter(app)
        self.assertIsNone(context.leave(app))
        self.assertFalse(app.facts[misc.PALETTE_FACT])
        app = FakeApp()
        self.assertIsNone(misc.PaletteOpen().leave(app))  # closed already: nothing to do
        self.assertEqual(app.ran, [])


class HomeChannelsTests(unittest.TestCase):
    def test_enter_enables_channels_and_leave_disables_them(self):
        app = FakeApp(lag=2)
        context = misc.HomeChannels()
        self.assertIsNone(context.enter(app))
        self.assertTrue(context.enabled)
        self.assertIsNone(context.leave(app))
        self.assertEqual(app.ran, ["home.enableChannels", "home.disableChannels"])
        self.assertFalse(app.facts[misc.CHANNELS_FACT])

    def test_a_session_with_channels_on_keeps_them(self):
        app = FakeApp(channels=True)
        context = misc.HomeChannels()
        self.assertIsNone(context.enter(app))
        self.assertIsNone(context.leave(app))
        self.assertEqual(app.ran, [])
        self.assertTrue(app.facts[misc.CHANNELS_FACT])

    def test_a_late_write_is_still_turned_off(self):
        # The setting write lands after the wait gave up: leave still disables what enter enabled.
        app = FakeApp(lag=10_000)
        context = misc.HomeChannels()
        self.assertIn("homeChannelsEnabled is still off", context.enter(app))
        context.leave(app)
        self.assertEqual(app.ran, ["home.enableChannels", "home.disableChannels"])


class TextBoxFocusTests(unittest.TestCase):
    def test_enter_makes_a_terminal_and_gives_its_box_the_keyboard(self):
        app = FakeApp(lag=2)
        context = misc.TextBoxFocus()
        self.assertIsNone(context.enter(app))
        self.assertEqual(app.ran, ["newSurface", "focusTextBoxInput"])
        self.assertTrue(context.made)
        self.assertEqual(app.tabs, 1)

    def test_a_second_enter_keeps_the_tab_and_the_keyboard(self):
        # The key-not-routed retry enters again before leave: no second tab, and no Focus TextBox while the box has
        # the keyboard (it would hand the keyboard back to the terminal), even when the fact is published late.
        app = FakeApp(lag=2)
        context = misc.TextBoxFocus()
        context.enter(app)
        app.pending[misc.TEXTBOX_FACT] = 2
        self.assertIsNone(context.enter(app))
        self.assertEqual(app.ran, ["newSurface", "focusTextBoxInput"])
        self.assertTrue(app.facts[misc.TEXTBOX_FACT])

    def test_a_second_enter_after_the_box_lost_the_keyboard_focuses_it_again(self):
        app = FakeApp()
        context = misc.TextBoxFocus()
        context.enter(app)
        app.set(misc.TEXTBOX_FACT, False)  # the measured Shift-Tab's restore pressed Escape
        self.assertIsNone(context.enter(app))
        self.assertEqual(app.ran, ["newSurface", "focusTextBoxInput", "focusTextBoxInput"])
        self.assertEqual(app.tabs, 1)

    def test_leave_forgets_the_tab_for_close_new(self):
        app = FakeApp()
        context = misc.TextBoxFocus()
        context.enter(app)
        self.assertIsNone(context.leave(app))
        self.assertFalse(context.made)
        context.enter(app)
        self.assertEqual(app.tabs, 2)

    def test_a_refused_new_terminal_makes_nothing(self):
        app = FakeApp(refuse={"newSurface"})
        context = misc.TextBoxFocus()
        self.assertIn("newSurface failed", context.enter(app))
        self.assertFalse(context.made)


class FamilyTests(unittest.TestCase):
    def setUp(self):
        self.families = action_fixtures.load_families()
        self.family = next(f for f in self.families.families if f.name == misc.FAMILY)

    def test_the_family_owns_its_three_contexts_with_its_closures(self):
        for fact in misc.PROBES:
            self.assertEqual(self.families.owners[fact], misc.FAMILY)
        self.assertEqual(sorted(self.family.closes), sorted(json.loads(CLOSURES.read_text())["closed"]))

    def test_its_closed_ids_are_no_gaps_and_its_reasoned_ids_are(self):
        record = json.loads(CLOSURES.read_text())
        gaps = json.loads(GAPS.read_text())["gaps"]
        self.assertEqual(sorted(set(record["closed"]) & set(gaps)), [])
        for ident, why in record["reasoned"].items():
            with self.subTest(ident=ident):
                self.assertEqual(gaps.get(ident), why)

    def test_the_sweep_plans_each_closed_row_with_the_family(self):
        # textBoxFocused was CONTEXT_SETUP's (mapped to the omnibar, which never gives a TextBox the keyboard); it is
        # the family's now, and each closed row plans with its context as action.list gives it.
        sweep_mod = action_fixtures.load_sweep(["--plan-only", "--catalog", str(CATALOG), "--out",
                                                tempfile.mkdtemp(prefix="misc-plan-")])
        self.assertNotIn(misc.TEXTBOX_FACT, sweep_mod.CONTEXT_SETUP)
        sweep = sweep_mod.Sweep(None, "light", None)
        sweep.base = dict(sweep_mod.PLAN_BASE)
        requires = {"commandPaletteNext": misc.PALETTE_FACT, "commandPalettePrevious": misc.PALETTE_FACT,
                    "home.channels": misc.CHANNELS_FACT, "cycleTextBoxSubmitAction": misc.TEXTBOX_FACT}
        self.assertEqual(sorted(requires), sorted(misc.CLOSES))
        for ident, fact in requires.items():
            with self.subTest(ident=ident):
                plan, skipped = sweep.plan({"id": ident, "requires": [fact]})
                self.assertIsNone(skipped)
                self.assertEqual(plan["families"], [fact])
                self.assertIsNone(plan["context"])


if __name__ == "__main__":
    unittest.main()
