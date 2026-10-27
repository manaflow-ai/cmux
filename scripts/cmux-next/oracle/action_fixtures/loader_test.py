#!/usr/bin/env python3
"""Tests for the shared sweep setup (p15-oracle-046): the per-family loader and the sweep's use of it.

Run: python3 -I scripts/cmux-next/oracle/action_fixtures/loader_test.py (stdlib unittest, no app, Linux too).
`--plan-only` itself is checked by diffing two checkouts' plans (the task's acceptance); here the sweep is imported
through action_fixtures.load_sweep as the oracle imports it, and its families are swapped for test ones.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
ORACLE = HERE.parent
SCRIPTS = ORACLE.parent
sys.path.insert(0, str(ORACLE))

import action_fixtures  # noqa: E402

OUT = tempfile.mkdtemp(prefix="action-fixtures-test-")
CATALOG = SCRIPTS.parent / "fuzz" / "macos-matrix" / "fixtures" / "action-list.json"
SWEEP_ARGV = ["--plan-only", "--catalog", str(CATALOG), "--out", OUT]
sweep_mod = action_fixtures.load_sweep(SWEEP_ARGV)

FAMILY = """
FAMILY = "{name}"
LOG = []


class Context:
    def __init__(self):
        self.made = False

    def enter(self, driver):
        LOG.append("enter")
        if {refuse!r}:
            return "the setup did not hold"
        if not self.made:
            driver.run("splitRight", {{}})
            self.made = True
        return None

    def leave(self, driver):
        LOG.append("leave")
        self.made = False
        return {leave_note!r}


CONTEXTS = {{"{context}": Context}}
PREPARE = {prepare!r}
CLOSES = ("{context}Action",)
"""


# A ContextFixture as a dataclass under postponed annotations, this package's own style.
DATACLASS_FAMILY = """
from __future__ import annotations

from dataclasses import dataclass, field
from typing import ClassVar, Optional

FAMILY = "dc"


@dataclass
class Context:
    made: bool = False
    notes: list = field(default_factory=list)
    KIND: ClassVar[str] = "dc"

    def enter(self, driver) -> Optional[str]:
        return None

    def leave(self, driver) -> Optional[str]:
        return None


CONTEXTS = {"dcLayout": Context}
"""


# ARGUMENTS and UNDO: one factory behind two keys, one that gives no value.
ARGUMENT_FAMILY = """
FAMILY = "arg"
MADE = []


class Thing:
    def __init__(self):
        MADE.append(self)
        self.name = None

    def value(self, driver, base):
        if self.name is None:
            driver.run("thing.make", {})
            self.name = f"thing:{len(MADE)}"
        return self.name, None


class NoPage:
    def value(self, driver, base):
        return None, "no page"


ARGUMENTS = {("x.a", "thing"): Thing, ("x.b", "thing"): Thing, ("x.b", "url"): NoPage}
UNDO = {"x.a": ("x.unset", {})}
"""


def write_family(directory, file="fam.py", name="fam", context="famLayout", prepare=None, refuse=False, leave_note=None):
    """A test family in `directory`, and its gap-closures record (<name>.json, `closed` = its CLOSES) beside it."""
    text = FAMILY.format(name=name, context=context, prepare=prepare or {}, refuse=refuse, leave_note=leave_note)
    (Path(directory) / file).write_text(textwrap.dedent(text))
    write_closures(directory, name, [f"{context}Action"])


def write_closures(directory, name, ids):
    record = {"family": name, "closed": {ident: "the test family sets it up" for ident in ids}, "reasoned": {}}
    (Path(directory) / f"{name}.json").write_text(json.dumps(record))


def load(directory):
    """The families of `directory`, their gap-closures records read from the same directory."""
    return action_fixtures.load_families(Path(directory), Path(directory))


class LoaderTests(unittest.TestCase):
    def setUp(self):
        self.dir = Path(tempfile.mkdtemp(prefix="families-"))

    def test_checked_in_families_load(self):
        families = action_fixtures.load_families()
        self.assertEqual(len(families.families), len(action_fixtures.family_paths()))

    def test_test_modules_and_init_are_not_families(self):
        write_family(self.dir)
        (self.dir / "fam_test.py").write_text("raise SystemExit('a test is not a family')\n")
        (self.dir / "__init__.py").write_text("")
        self.assertEqual([p.name for p in action_fixtures.family_paths(self.dir)], ["fam.py"])

    def test_family_contexts_prepare_and_closes(self):
        write_family(self.dir, prepare={"x.move": [("newSurface", {})]})
        families = load(self.dir)
        self.assertEqual(families.contexts, frozenset({"famLayout"}))
        self.assertEqual(families.owners, {"famLayout": "fam"})
        self.assertEqual(families.families[0].closes, ("famLayoutAction",))
        merged = families.merged_prepare({"tab.moveToNewColumn": [("newSurface", {})]})
        self.assertEqual(merged["x.move"], [("newSurface", {})])
        self.assertEqual(merged["tab.moveToNewColumn"], [("newSurface", {})])

    def test_new_contexts_are_fresh_per_call(self):
        write_family(self.dir)
        families = load(self.dir)
        self.assertIsNot(families.new_contexts()["famLayout"], families.new_contexts()["famLayout"])

    def test_a_context_two_families_claim_is_refused(self):
        write_family(self.dir, "a.py", "a")
        write_family(self.dir, "b.py", "b")
        with self.assertRaisesRegex(action_fixtures.FixtureError, "famLayout.*also family 'a'"):
            load(self.dir)

    def test_a_family_name_used_twice_is_refused(self):
        write_family(self.dir, "a.py", "same", "aLayout")
        write_family(self.dir, "b.py", "same", "bLayout")
        with self.assertRaisesRegex(action_fixtures.FixtureError, "FAMILY 'same'"):
            load(self.dir)

    def test_a_prepare_id_two_families_claim_is_refused(self):
        write_family(self.dir, "a.py", "a", "aLayout", prepare={"x.move": [("newSurface", {})]})
        write_family(self.dir, "b.py", "b", "bLayout", prepare={"x.move": [("newColumn", {})]})
        with self.assertRaisesRegex(action_fixtures.FixtureError, "PREPARE 'x.move' is also family 'a'"):
            load(self.dir)

    def test_a_prepare_id_the_sweep_has_is_refused(self):
        write_family(self.dir, prepare={"column.moveLeft": [("newColumn", {})]})
        with self.assertRaisesRegex(action_fixtures.FixtureError, "column.moveLeft"):
            load(self.dir).merged_prepare(sweep_mod.PREPARE)

    def test_a_context_the_sweep_sets_up_is_refused(self):
        write_family(self.dir, context="terminalFocused")
        with self.assertRaisesRegex(action_fixtures.FixtureError, "terminalFocused"):
            load(self.dir).check_contexts(sweep_mod.CONTEXT_SETUP)

    def test_a_family_that_does_not_import_is_an_error(self):
        (self.dir / "broken.py").write_text("import no_such_module_anywhere\n")
        with self.assertRaisesRegex(action_fixtures.FixtureError, "broken.py: does not import"):
            load(self.dir)

    def test_a_dataclass_family_under_postponed_annotations_loads(self):
        # dataclasses look the class's module up in sys.modules: load_module registers it before running it.
        (self.dir / "dc.py").write_text(DATACLASS_FAMILY)
        families = load(self.dir)
        self.assertEqual(families.contexts, frozenset({"dcLayout"}))
        self.assertFalse(families.new_contexts()["dcLayout"].made)
        self.assertIs(sys.modules["action_fixtures.dc"], families.families[0].module)

    def test_a_family_that_fails_to_import_is_not_left_registered(self):
        (self.dir / "gone.py").write_text("raise RuntimeError('half run')\n")
        with self.assertRaisesRegex(action_fixtures.FixtureError, "gone.py: does not import"):
            load(self.dir)
        self.assertNotIn("action_fixtures.gone", sys.modules)

    def test_closes_is_its_gap_closures_record(self):
        write_family(self.dir)
        write_closures(self.dir, "fam", ["famLayoutAction", "otherAction"])
        with self.assertRaisesRegex(action_fixtures.FixtureError, r"only in fam.json \['otherAction'\]"):
            load(self.dir)
        write_closures(self.dir, "fam", [])
        with self.assertRaisesRegex(action_fixtures.FixtureError, r"only in CLOSES \['famLayoutAction'\]"):
            load(self.dir)
        (self.dir / "fam.json").unlink()
        with self.assertRaisesRegex(action_fixtures.FixtureError, "CLOSES names ids but fam.json is not in"):
            load(self.dir)
        (self.dir / "fam.json").write_text("[]")
        with self.assertRaisesRegex(action_fixtures.FixtureError, "not a gap-closures record"):
            load(self.dir)

    def test_a_family_with_no_closes_needs_no_record_and_a_record_needs_closes(self):
        (self.dir / "prep.py").write_text("FAMILY = 'prep'\nPREPARE = {'x.move': [('newSurface', {})]}\n")
        self.assertEqual(load(self.dir).families[0].closes, ())
        write_closures(self.dir, "prep", ["x.move"])
        with self.assertRaisesRegex(action_fixtures.FixtureError, r"only in prep.json \['x.move'\]"):
            load(self.dir)

    def test_family_arguments_share_one_fixture_per_factory_per_launch(self):
        (self.dir / "arg.py").write_text(ARGUMENT_FAMILY)
        families = load(self.dir)
        self.assertEqual(set(families.argument_keys()), {("x.a", "thing"), ("x.b", "thing"), ("x.b", "url")})
        driver = FakeDriver()
        gap = lambda why: {"skipped": why, "skip_kind": "gap"}
        launch = families.new_arguments(driver, gap)
        self.assertEqual(launch[("x.a", "thing")]({}), ("thing:1", None))
        self.assertEqual(launch[("x.b", "thing")]({}), ("thing:1", None))  # the same fixture: made once
        self.assertEqual(launch[("x.b", "url")]({}), (None, gap("no page")))
        self.assertEqual(driver.ran, ["thing.make"])
        relaunch = families.new_arguments(driver, gap)
        self.assertEqual(relaunch[("x.a", "thing")]({}), ("thing:2", None))  # a relaunch's own fixture
        self.assertEqual(driver.ran, ["thing.make", "thing.make"])

    def test_family_undo_merges_into_the_sweep_undo(self):
        (self.dir / "arg.py").write_text(ARGUMENT_FAMILY)
        merged = load(self.dir).merged_undo(sweep_mod.UNDO)
        self.assertEqual(merged["x.a"], ("x.unset", {}))
        self.assertEqual(merged["browserFit"], sweep_mod.FIT_OFF)
        with self.assertRaisesRegex(action_fixtures.FixtureError, "UNDO 'x.a' is already undone"):
            load(self.dir).merged_undo({"x.a": ("other", {})})

    def test_an_argument_the_sweep_fills_is_refused(self):
        (self.dir / "fit.py").write_text("FAMILY = 'fit'\nARGUMENTS = {('browserFit', 'fit'): dict}\n")
        with self.assertRaisesRegex(action_fixtures.FixtureError, "browserFit.fit is filled by the sweep"):
            load(self.dir).check_arguments(sweep_mod.ARGUMENT_FIXTURES)

    def test_an_argument_or_undo_two_families_claim_is_refused(self):
        (self.dir / "a.py").write_text(ARGUMENT_FAMILY)
        (self.dir / "b.py").write_text("FAMILY = 'b'\nARGUMENTS = {('x.a', 'thing'): dict}\n")
        with self.assertRaisesRegex(action_fixtures.FixtureError, "ARGUMENTS 'x.a.thing' is also family 'arg'"):
            load(self.dir)
        (self.dir / "b.py").write_text("FAMILY = 'b'\nUNDO = {'x.a': ('x.unset', {})}\n")
        with self.assertRaisesRegex(action_fixtures.FixtureError, "UNDO 'x.a' is also family 'arg'"):
            load(self.dir)

    def test_malformed_families_are_refused(self):
        cases = {
            "FAMILY = 'Bad-Name'\nCONTEXTS = {'k': dict}\n": "FAMILY",
            "FAMILY = 'f'\nCONTEXTS = {'k': 3}\n": "CONTEXTS",
            "FAMILY = 'f'\nPREPARE = {'x': [('a',)]}\n": "PREPARE 'x' step",
            "FAMILY = 'f'\nPREPARE = {'x': 'newSurface'}\n": "PREPARE 'x' is a list",
            "FAMILY = 'f'\nCONTEXTS = {'k': dict}\nCLOSES = ('a', 'a')\n": "CLOSES names an id twice",
            "FAMILY = 'f'\n": "CONTEXTS, PREPARE, ARGUMENTS or UNDO",
            "FAMILY = 'f'\nARGUMENTS = {'x.url': dict}\n": "ARGUMENTS maps",
            "FAMILY = 'f'\nARGUMENTS = {('x', 'url'): 'about:blank'}\n": "ARGUMENTS maps",
            "FAMILY = 'f'\nUNDO = [('x', ('y', {}))]\n": "UNDO maps",
            "FAMILY = 'f'\nUNDO = {'x': ('y',)}\n": "UNDO 'x' step",
        }
        for text, words in cases.items():
            with self.subTest(text=text):
                path = self.dir / "f.py"
                path.write_text(text)
                with self.assertRaisesRegex(action_fixtures.FixtureError, words):
                    load(self.dir)


class LoadSweepTests(unittest.TestCase):
    def test_one_module_per_configuration(self):
        self.assertIs(action_fixtures.load_sweep(SWEEP_ARGV), sweep_mod)
        with self.assertRaisesRegex(action_fixtures.FixtureError, "already loaded"):
            action_fixtures.load_sweep(["--app", "-", "--tag", "x", "--out", OUT])

    def test_the_oracle_gets_the_sweep_setup_where_it_is(self):
        for name in ("Sweep", "App", "TagTeardown", "PREPARE", "CONTEXT_SETUP", "skip_reason", "argument_values"):
            self.assertTrue(hasattr(sweep_mod, name), name)
        self.assertIs(sweep_mod.action_fixtures, action_fixtures)


class FakeDriver:
    def __init__(self):
        self.ran = []

    def run(self, action, args=None):
        self.ran.append(action)
        return {"ok": True}

    def rpc(self, method, params=None):
        return {}

    def wait(self, predicate, seconds):
        return predicate()


class SweepFamilyTests(unittest.TestCase):
    """The sweep with one test family in place of the checked-in ones."""

    def use(self, **family):
        directory = tempfile.mkdtemp(prefix="families-")
        write_family(directory, **family)
        families = load(directory)
        module = families.families[0].module
        patcher = mock.patch.object(sweep_mod, "FAMILIES", families)
        patcher.start()
        self.addCleanup(patcher.stop)
        sweep = sweep_mod.Sweep(None, "light", None)
        sweep.base = dict(sweep_mod.PLAN_BASE)
        sweep.driver = FakeDriver()
        return sweep, module

    def test_a_family_context_is_planned_not_a_gap(self):
        sweep, _ = self.use()
        plan, skipped = sweep.plan({"id": "famLayoutAction", "requires": ["famLayout"]})
        self.assertIsNone(skipped)
        self.assertEqual(plan["families"], ["famLayout"])
        self.assertIsNone(plan["context"])
        self.assertEqual(sweep_mod.plan_row(sweep, {"id": "famLayoutAction", "requires": ["famLayout"]})["families"],
                         ["famLayout"])

    def test_an_unknown_context_is_still_a_gap(self):
        sweep, _ = self.use()
        _, skipped = sweep.plan({"id": "x", "requires": ["famLayout", "otherLayout"]})
        self.assertEqual(skipped["skip_kind"], "gap")
        self.assertIn("otherLayout", skipped["skipped"])

    def test_enter_then_leave_once_last_first(self):
        sweep, module = self.use()
        self.assertIsNone(sweep.enter_contexts(["famLayout"]))
        self.assertIsNone(sweep.enter_contexts(["famLayout"]))  # the key-not-routed retry's second ready()
        self.assertEqual(sweep.driver.ran, ["splitRight"])  # the fixture kept what its first enter made
        self.assertEqual(sweep.entered, ["famLayout"])
        self.assertEqual(sweep.leave_contexts(), [])
        self.assertEqual(sweep.leave_contexts(), [])  # nothing entered: nothing left
        self.assertEqual(module.LOG, ["enter", "enter", "leave"])

    def test_a_context_that_does_not_hold_names_its_family_and_is_still_left(self):
        sweep, module = self.use(refuse=True)
        self.assertEqual(sweep.enter_contexts(["famLayout"]), "famLayout (fam fixture): the setup did not hold")
        sweep.leave_contexts()
        self.assertEqual(module.LOG, ["enter", "leave"])

    def test_a_leave_note_is_drift(self):
        sweep, _ = self.use(leave_note="the layout stayed")
        sweep.enter_contexts(["famLayout"])
        self.assertEqual(sweep.leave_contexts(), ["leave famLayout: the layout stayed"])

    def test_a_family_argument_fills_required_and_optional_arguments_and_its_undo_is_planned(self):
        directory = Path(tempfile.mkdtemp(prefix="families-"))
        (directory / "arg.py").write_text(ARGUMENT_FAMILY)
        families = load(directory)
        with mock.patch.object(sweep_mod, "FAMILIES", families), mock.patch.object(sweep_mod, "SweepDriver", FakeDriver):
            sweep = sweep_mod.Sweep(None, "light", None)
        sweep.base = dict(sweep_mod.PLAN_BASE)
        thing = {"name": "thing", "kind": "target", "target_kind": "thing", "required": True}
        url = {"name": "url", "kind": "string", "required": False}
        note = {"name": "note", "kind": "string", "required": False}
        plan, skipped = sweep.plan({"id": "x.a", "arguments": [thing, note]})
        self.assertIsNone(skipped)
        self.assertEqual(plan["args"], {"thing": "thing:1"})  # an optional argument no fixture fills stays unset
        _, skipped = sweep.plan({"id": "x.b", "arguments": [thing, url]})
        self.assertEqual(skipped, {"skipped": "no page", "skip_kind": "gap"})
        # Without the family the same row is the gap it was.
        self.assertEqual(sweep_mod.argument_values({"id": "x.a", "arguments": [thing]}, {}, sweep_mod.ARGUMENT_FIXTURES)[1],
                         {"skipped": "needs a thing argument", "skip_kind": "gap"})


class BrowserProfilePlanTests(unittest.TestCase):
    """The checked-in browserProfile family (p15-oracle-084) in --plan-only, over its actions as action.list lists
    them (BrowserProfileActionCatalog.swift; the checked-in fixture catalog predates them)."""

    def test_every_closed_id_is_planned_with_the_scratch_profile(self):
        profile = {"name": "browserProfile", "kind": "target", "target_kind": "browser-profile", "required": True}
        url = {"name": "url", "kind": "string", "required": False}
        arguments = {"browserProfile.newTab": [profile, url], "browserProfile.openLink": [profile, url]}
        ids = json.loads((action_fixtures.GAP_CLOSURES / "browserProfile.json").read_text())["closed"]
        catalog = {"actions": [{"id": ident, "arguments": arguments.get(ident, [profile]), "requires": []} for ident in ids]}
        out = tempfile.mkdtemp(prefix="plan-only-")
        path = os.path.join(out, "catalog.json")
        with open(path, "w") as f:
            json.dump(catalog, f)
        subprocess.run([sys.executable, "-I", str(SCRIPTS / "every-action-sweep.py"), "--plan-only", "--catalog", path,
                        "--out", out, "--sessions", "light"], check=True, capture_output=True, text=True)
        with open(os.path.join(out, "every-action-plan.json")) as f:
            rows = {r["id"]: r for r in json.load(f)["sessions"][0]["rows"]}
        self.assertEqual(set(rows), set(ids))
        for ident, row in rows.items():
            with self.subTest(ident=ident):
                self.assertNotIn("skipped", row)
                self.assertEqual(row["args"]["browserProfile"], f"<fixture {ident}.browserProfile>")
        self.assertEqual(rows["browserProfile.openLink"]["args"]["url"], "<fixture browserProfile.openLink.url>")
        self.assertNotIn("url", rows["browserProfile.newTab"]["args"])
        self.assertEqual(rows["browserProfile.moveTab"]["prepare"], [["openBrowser.chromium", {"url": "about:blank"}]])
        self.assertEqual(rows["browserProfile.setSpaceDefault"]["undo"], ["browserProfile.clearSpaceDefault", {}])


class PlanOnlyTests(unittest.TestCase):
    def run_plan(self, *extra):
        out = tempfile.mkdtemp(prefix="plan-only-")
        subprocess.run([sys.executable, "-I", str(SCRIPTS / "every-action-sweep.py"), "--plan-only", "--catalog",
                        str(CATALOG), "--out", out, *extra], check=True, capture_output=True, text=True)
        with open(os.path.join(out, "every-action-plan.json")) as f:
            return json.load(f)

    def test_plan_only_needs_no_app_and_is_stable(self):
        first, second = self.run_plan(), self.run_plan()
        self.assertEqual(first, second)
        self.assertEqual([s["name"] for s in first["sessions"]], ["light", "stress"])
        rows = {r["id"]: r for r in first["sessions"][0]["rows"]}
        self.assertEqual(len(rows), first["actions"])
        self.assertEqual(rows["closeWorkspace"]["expect"], {"action": "workspace-", "key": "workspace-"})
        self.assertEqual(rows["closeWorkspace"]["entry"], "key")

    def test_plan_only_takes_the_run_selection(self):
        plan = self.run_plan("--only", "closeWorkspace,openFolder", "--sessions", "light")
        self.assertEqual([r["id"] for r in plan["sessions"][0]["rows"]], ["closeWorkspace", "openFolder"])
        self.assertEqual(plan["sessions"][0]["rows"][1]["skip_kind"], "excluded")

    def test_plan_only_needs_a_catalog(self):
        done = subprocess.run([sys.executable, "-I", str(SCRIPTS / "every-action-sweep.py"), "--plan-only", "--out", OUT],
                              capture_output=True, text=True)
        self.assertEqual(done.returncode, 2)
        self.assertIn("--plan-only needs --catalog", done.stderr)


if __name__ == "__main__":
    unittest.main()
