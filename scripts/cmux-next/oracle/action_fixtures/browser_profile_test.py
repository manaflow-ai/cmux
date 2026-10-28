#!/usr/bin/env python3
"""Tests for the browserProfile gap fixture (p15-oracle-084), against a model of the app's profile records.

Run: python3 -I scripts/cmux-next/oracle/action_fixtures/browser_profile_test.py (stdlib unittest, no app, Linux too).
The fleet sweep (`every-action-sweep.py --only <the closed ids>`) shows the rows run; here the fixture's own logic and
its record are checked.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import action_fixtures  # noqa: E402

FAMILIES = action_fixtures.load_families()
FAMILY = next(f for f in FAMILIES.families if f.name == "browserProfile")
browser_profile = FAMILY.module
GAPS = HERE.parents[1] / "every-action-gaps.json"
GAP = lambda why: {"skipped": why, "skip_kind": "gap"}


# What action.run validates before a handler runs (BrowserProfileActionCatalog, ControlRouter+Validation
# validatedRequest): the arguments each action declares and the target kinds it takes. An argument it does not declare
# is "has no argument", a target it does not take is "does not take a target".
SCHEMA = {
    "browserProfile.new": ({"name", "color", "icon"}, ()),
    "browserProfile.rename": ({"name"}, ("browser-profile",)),
}


class FakeApp:
    """The app's profile records as action.run sees them: the router refuses what the catalog does not declare,
    rename resolves its target profile by name, new makes one that shows up `lag` reads later (the daemon's
    create-browser-profile reply)."""

    def __init__(self, held=False, lag=0, refuse_new=None):
        self.names = ["Default"] + ([browser_profile.NAME] if held else [])
        self.lag, self.refuse_new, self.pending = lag, refuse_new, None
        self.ran = []

    def run(self, action, args=None, target=None):
        self.ran.append(action)
        args = args or {}
        if action not in SCHEMA:
            return {"error": f"unexpected {action}"}
        declared, kinds = SCHEMA[action]
        for name in args:
            if name not in declared:
                return {"error": {"code": "invalid_params", "message": f"{action} has no argument '{name}'"}}
        if target is not None:
            kind = target.split(":", 1)[0]
            if kind not in kinds:
                return {"error": {"code": "invalid_params", "message": f"{action} does not take a {kind} target"}}
        if action == "browserProfile.new":
            if self.refuse_new:
                return {"error": self.refuse_new}
            self.pending = [args["name"], self.lag]
            return {}
        if self.pending:
            if self.pending[1] <= 0:
                self.names.append(self.pending[0])
                self.pending = None
            else:
                self.pending[1] -= 1
        if target is None:
            return {"error": {"code": "invalid_target", "message": "rename needs a browser-profile target"}}
        name = target.split(":", 1)[1]
        if name not in self.names:
            return {"error": {"code": "invalid_target", "message": f"no profile {name}"}}
        if args.get("name") != name:
            return {"error": f"the presence check renamed {name!r} to {args.get('name')!r}"}
        return {}

    def rpc(self, method, params=None):
        return {}

    def wait(self, predicate, seconds):
        for _ in range(20):
            if predicate():
                return True
        return None


class ScratchProfileTests(unittest.TestCase):
    def test_a_launch_without_it_makes_it_once_and_names_it(self):
        app = FakeApp(lag=3)
        fixture = browser_profile.ScratchProfile()
        self.assertEqual(fixture.value(app, {}), ("browser-profile:Oracle Scratch", None))
        self.assertEqual(app.names.count("Oracle Scratch"), 1)
        self.assertEqual(app.ran.count("browserProfile.new"), 1)
        ran = len(app.ran)
        self.assertEqual(fixture.value(app, {}), ("browser-profile:Oracle Scratch", None))
        self.assertEqual(len(app.ran), ran, "a later row of the launch touched the app")

    def test_a_launch_that_holds_it_makes_none(self):
        app = FakeApp(held=True)
        self.assertEqual(browser_profile.ScratchProfile().value(app, {}), ("browser-profile:Oracle Scratch", None))
        self.assertNotIn("browserProfile.new", app.ran)
        self.assertEqual(app.names.count("Oracle Scratch"), 1)

    def test_a_refused_create_is_the_rows_gap_and_the_next_row_tries_again(self):
        app = FakeApp(refuse_new="profiles are read-only")
        fixture = browser_profile.ScratchProfile()
        value, why = fixture.value(app, {})
        self.assertIsNone(value)
        self.assertIn("profiles are read-only", why)
        app.refuse_new = None
        self.assertEqual(fixture.value(app, {}), ("browser-profile:Oracle Scratch", None))

    def test_a_profile_that_never_appears_is_the_rows_gap(self):
        app = FakeApp(lag=1000)
        value, why = browser_profile.ScratchProfile().value(app, {})
        self.assertIsNone(value)
        self.assertIn("did not appear", why)

    def test_the_sweep_gets_one_profile_per_launch_for_every_closed_id(self):
        app = FakeApp()
        launch = FAMILIES.new_arguments(app, GAP)
        for ident in browser_profile.CLOSES:
            self.assertEqual(launch[(ident, "browserProfile")]({}), ("browser-profile:Oracle Scratch", None))
        self.assertEqual(app.ran.count("browserProfile.new"), 1)
        self.assertEqual(launch[("browserProfile.openLink", "url")]({}), ("about:blank", None))


class RecordTests(unittest.TestCase):
    def test_every_closed_id_was_a_browser_profile_argument_gap(self):
        # Holds before and after apply_gap_closures.py drops the closed ids from the baseline: each is
        # still listed with the browser-profile argument reason or gone.
        gaps = json.loads(GAPS.read_text())["gaps"]
        reason = "needs a browser-profile argument"
        for ident in FAMILY.closes:
            with self.subTest(ident=ident):
                self.assertEqual(gaps.get(ident, reason), reason)
        left = sorted(i for i, why in gaps.items() if i.startswith("browserProfile.") and i not in FAMILY.closes)
        self.assertEqual(left, [], "a browserProfile gap this family leaves open")

    def test_every_closed_id_gets_the_profile_and_the_undo_names_its_clear(self):
        self.assertEqual({k for k in FAMILY.arguments if k[1] == "browserProfile"},
                         {(i, "browserProfile") for i in FAMILY.closes})
        for ident, (inverse, args) in FAMILY.undo.items():
            self.assertEqual(inverse, ident.replace(".set", ".clear"))
            self.assertEqual(args, {})


if __name__ == "__main__":
    unittest.main()
