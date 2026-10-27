#!/usr/bin/env python3
"""Tests for the session-state gap fixture (p15-oracle-086), against a model of the app's space records and the
sweep's own --plan-only.

Run: python3 -I scripts/cmux-next/oracle/action_fixtures/session_states_test.py (stdlib unittest, no app, Linux too).
The fleet sweep (`every-action-sweep.py --only <the closed ids>`) shows the rows run; here the fixture's logic, its
record and the plan the sweep makes from it are checked.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent))

import action_fixtures  # noqa: E402

FAMILIES = action_fixtures.load_families()
FAMILY = next(f for f in FAMILIES.families if f.name == "session")
session = FAMILY.module
ROOT = HERE.parents[3]
GAPS = HERE.parents[1] / "every-action-gaps.json"
RECORD = action_fixtures.GAP_CLOSURES / "session.json"
SWIFT = ROOT / "Packages/macOS/CmuxNext/Sources"
PROGRAM = ROOT / "plans/cmux-next/chrome-parity/p15-oracle.md"
GAP = lambda why: {"skipped": why, "skip_kind": "gap"}
# The argument gaps of this family's prefixes, as the sweep wrote them before the fixture.
ARGUMENT_GAPS = {"needs a room argument", "needs a sidebar-section argument", "needs a agent-chat argument"}
FAMILY_PREFIX = re.compile(r"^(sidebar|space|workspace|workspaceGroup)\.")


class FakeApp:
    """The app's spaces as action.run sees them: rename resolves a space by name (a target), new makes one that shows
    up `lag` reads later (the daemon's create-profile reply, then the home store's mirror)."""

    def __init__(self, held=False, lag=0, refuse_new=None):
        self.names = ["Default"] + ([session.SPACE] if held else [])
        self.lag, self.refuse_new, self.pending = lag, refuse_new, None
        self.calls = []

    def run(self, action, args=None):
        return {"error": f"the fixture ran {action} with focus"}

    def rpc(self, method, params=None):
        self.calls.append((method, params))
        if method != "action.run":
            return {"error": f"unexpected {method}"}
        action = params["action"]
        if action == "space.new":
            if self.refuse_new:
                return {"error": self.refuse_new}
            self.pending = [params["args"]["name"], self.lag]
            return {}
        if action == "space.rename":
            if self.pending:
                if self.pending[1] <= 0:
                    self.names.append(self.pending[0])
                    self.pending = None
                else:
                    self.pending[1] -= 1
            kind, name = params["target"].split(":", 1)
            ok = kind == "room" and name in self.names and params["args"] == {"name": name}
            return {} if ok else {"error": {"code": "not_found", "message": f"no space {name}"}}
        return {"error": f"unexpected {action}"}

    def wait(self, predicate, seconds):
        for _ in range(20):
            if predicate():
                return True
        return None

    def made(self):
        return [p for m, p in self.calls if p["action"] == "space.new"]


class ScratchSpaceTests(unittest.TestCase):
    def test_a_launch_without_it_makes_it_once_without_focus_and_names_it(self):
        app = FakeApp(lag=3)
        fixture = session.ScratchSpace()
        self.assertEqual(fixture.value(app, {}), ("room:Oracle Space", None))
        self.assertEqual(app.names.count("Oracle Space"), 1)
        self.assertEqual(app.made(), [{"action": "space.new", "args": {"name": "Oracle Space"}}],
                         "a run with focus would show the new space in the base window")
        calls = len(app.calls)
        self.assertEqual(fixture.value(app, {}), ("room:Oracle Space", None))
        self.assertEqual(len(app.calls), calls, "a later row of the launch touched the app")

    def test_a_launch_that_holds_it_makes_none(self):
        app = FakeApp(held=True)
        self.assertEqual(session.ScratchSpace().value(app, {}), ("room:Oracle Space", None))
        self.assertEqual(app.made(), [])

    def test_a_refused_create_is_the_rows_gap_and_the_next_row_tries_again(self):
        app = FakeApp(refuse_new="spaces need profiles-v1")
        fixture = session.ScratchSpace()
        value, why = fixture.value(app, {})
        self.assertIsNone(value)
        self.assertIn("spaces need profiles-v1", why)
        app.refuse_new = None
        self.assertEqual(fixture.value(app, {}), ("room:Oracle Space", None))

    def test_a_space_that_never_appears_is_the_rows_gap(self):
        value, why = session.ScratchSpace().value(FakeApp(lag=1000), {})
        self.assertIsNone(value)
        self.assertIn("did not appear", why)

    def test_the_sweep_gets_one_space_per_launch_and_the_top_section(self):
        app = FakeApp()
        launch = FAMILIES.new_arguments(app, GAP)
        for ident in session.SPACE_MOVES:
            self.assertEqual(launch[(ident, "space")]({}), ("room:Oracle Space", None))
        self.assertEqual(len(app.made()), 1)
        self.assertEqual(launch[("workspaceGroup.addToSection", "section")]({}), ("sidebar-section:sec_top", None))
        relaunch = FAMILIES.new_arguments(app, GAP)
        self.assertEqual(relaunch[("space.switch", "space")]({}), ("room:Oracle Space", None))
        self.assertEqual(len(app.made()), 1, "a relaunch that holds the space made a second one")


class PlanTests(unittest.TestCase):
    SPACE_STEPS = [("space.newWorkspace", {"space": "room:Oracle Space"})] * 3 + [("space.switch", {"space": "room:default"})]

    def test_each_space_move_starts_from_the_space_with_3_workspaces_in_the_base_view(self):
        for ident in session.SPACE_MOVES:
            with self.subTest(ident=ident):
                self.assertEqual(list(FAMILY.prepare[ident][:4]), self.SPACE_STEPS)
        self.assertEqual(FAMILY.prepare["workspace.moveToSpace"][4:], (("workspace.newAtBottom", {}),))
        self.assertEqual(FAMILY.prepare["workspaceGroup.moveToSpace"][4:], (("workspace.newInNewGroup", {}),))
        self.assertEqual(FAMILY.prepare["workspaceGroup.addToSection"], (("workspace.newInNewGroup", {}),))
        for ident in ("space.newWindow", "space.newWorkspace", "space.switch", "workspace.duplicateToSpace"):
            self.assertEqual(len(FAMILY.prepare[ident]), 4, f"{ident} acts on the base, not on a new workspace")

    def test_undo_switches_back_exactly_where_the_action_takes_the_window(self):
        self.assertEqual(FAMILY.undo, {ident: ("space.switch", {"space": "room:default"})
                                       for ident in ("space.newWorkspace", "space.switch", "workspace.duplicateToSpace")})

    def test_every_argument_is_one_a_closed_id_takes(self):
        self.assertEqual(set(FAMILY.arguments), {(i, "space") for i in session.SPACE_MOVES}
                         | {("workspaceGroup.addToSection", "section")})
        self.assertEqual({i for i, _ in FAMILY.arguments}, set(FAMILY.closes))


class RecordTests(unittest.TestCase):
    record = json.loads(RECORD.read_text())

    def test_closed_and_reasoned_ids_are_this_familys_argument_gaps_before_and_after_the_closures_apply(self):
        listed = json.loads(GAPS.read_text())
        gaps, excluded = listed["gaps"], listed["excluded"]
        closed, reasoned = set(self.record["closed"]), set(self.record["reasoned"])
        self.assertFalse(closed & reasoned)
        for ident in sorted(closed | reasoned):
            with self.subTest(ident=ident):
                self.assertNotIn(ident, excluded)
                if ident in gaps:  # before p15-oracle-087 removes the closed ids
                    self.assertIn(gaps[ident], ARGUMENT_GAPS)
        for ident in reasoned:
            self.assertEqual(gaps.get(ident), "needs a agent-chat argument", "a reasoned id is still a gap")
        left = sorted(i for i, why in gaps.items() if FAMILY_PREFIX.match(i) and why in ARGUMENT_GAPS
                      and i not in closed | reasoned)
        self.assertEqual(left, [], "an argument gap of this family neither closed nor reasoned")

    def test_every_id_left_open_moves_to_a_follow_up_the_program_defines(self):
        self.assertEqual(self.record["follow_up"], session.FOLLOW_UP)
        for ident, why in self.record["reasoned"].items():
            with self.subTest(ident=ident):
                self.assertTrue(why.startswith(session.FOLLOW_UP), f"{ident}'s reason does not name its follow-up")
        plan = PROGRAM.read_text()
        number = session.FOLLOW_UP.rsplit("-", 1)[1]
        self.assertRegex(plan, rf"\n\| {number} \| [^\n]*\| MQ-action-gaps \|\n", "the task table has no row for it")
        detail = re.search(rf"\n\*\*{number} [^\n]*\n(.*?)\n\n", plan, re.S)
        self.assertIsNotNone(detail, "the task details have no paragraph for it")
        for ident in [*self.record["reasoned"], "sidebar.chat.togglePin"]:
            self.assertIn(ident.split(".")[-1], detail.group(1), f"{session.FOLLOW_UP} does not take {ident}")
        self.assertIn(f"history chat, {number})", plan, "270 does not point its history chat at the follow-up")

    def test_the_record_names_its_fixture_and_task(self):
        self.assertEqual(self.record["family"], "session")
        self.assertEqual(self.record["task"], "p15-oracle-086")
        self.assertEqual(ROOT / self.record["fixture"], Path(session.__file__))


class CatalogTests(unittest.TestCase):
    """The argument names and ids the fixture writes, read from the Swift that defines them."""

    def read(self, path):
        return (SWIFT / path).read_text()

    def holds(self, pattern, path, what):
        self.assertTrue(re.search(pattern, self.read(path), re.S), f"{path}: {what}")

    def descriptor(self, ident, rest):
        """`ident`'s ActionDescriptor holds `rest` before the next descriptor starts."""
        return rf'id: "{re.escape(ident)}",(?:(?!ActionDescriptor\().)*{rest}'

    def test_the_space_argument_is_named_space_and_takes_a_room(self):
        self.holds(r'static var roomRoom: ActionArgument \{\s*ActionArgument\(name: "space",.*?kind: \.target\(\.profile\)\)',
                   "CmuxNextActions/CatalogArgument+Profiles.swift", "roomRoom is the `space` argument of a room target")
        self.holds(r'case profile = "room"', "CmuxNextActions/ActionTarget.swift", "a room target is `room:`")
        for ident in session.SPACE_MOVES:
            with self.subTest(ident=ident):
                self.holds(self.descriptor(ident, r'CatalogArgument\.roomRoom'),
                           "CmuxNextActions/Catalog/ProfileActionCatalog.swift", f"{ident} takes roomRoom")

    def test_why_the_priority_ids_stay_open_still_holds(self):
        """session.json `reasoned`: a Priority row is a lane of the app's acpmux, which the sweep's launch cannot
        start an agent in, and each restore turns the view off again. When one of these stops holding, close the ids."""
        self.holds(r'stores: \[AgentLaneStore\] = \[\.shared, \.chief\]', "CmuxNextAgentLanes/AgentPriorityChats.swift",
                   "the Priority rows are the app acpmux's lanes")
        self.holds(r'preferences\.priorityViewEnabled \? nil : SidebarPriorityPanel\.unavailableReason',
                   "CmuxNextApp/SidebarSections/SidebarPriorityRowActions.swift", "the row actions need the view on")
        sweep = (HERE.parents[1] / "every-action-sweep.py").read_text()
        self.assertIn('"ACPMUX_AGENT_LAUNCH": "deny"', sweep, "the sweep's acpmux may start an agent now")
        self.assertIn('rpc("settings.set", {"path": path, "value": a})', sweep, "restore_settings no longer puts settings back")

    def test_the_section_argument_and_the_ids_the_fixture_names(self):
        self.holds(self.descriptor("workspaceGroup.addToSection", r'ActionArgument\(name: "section",.*?\.target\(\.sidebarSection\)'),
                   "CmuxNextActions/Catalog/WorkspaceGroupActionCatalog.swift", "Add Group to Section takes `section`")
        self.holds(r'topSectionID = LayoutSectionID\("sec_top"\)', "CmuxNextSidebar/Sections/SidebarLayoutDocument.swift",
                   "the top section is sec_top")
        self.holds(r'defaultProfile: Self = "default"', "CmuxNextDaemon/Wire/StringIDs.swift", "the default room is `default`")


class SweepPlanTests(unittest.TestCase):
    """every-action-sweep.py --plan-only over a catalog of this family's ids, as action.list lists their arguments."""

    def test_the_sweep_plans_the_closed_ids_and_still_skips_the_reasoned_ones(self):
        def target(name, kind):
            return {"name": name, "kind": "target", "target_kind": kind, "required": True}
        actions = [{"id": i, "title": i, "arguments": [target("space", "room")]} for i in session.SPACE_MOVES]
        actions.append({"id": "workspaceGroup.addToSection", "title": "Add Group to Section",
                        "arguments": [target("section", "sidebar-section")]})
        actions += [{"id": i, "title": i, "arguments": [target("chat", "agent-chat")]} for i in self.record_reasoned()]
        with tempfile.TemporaryDirectory() as out:
            catalog = Path(out) / "action-list.json"
            catalog.write_text(json.dumps({"actions": actions}))
            plan_path = Path(out) / "plan.json"
            subprocess.run([sys.executable, "-I", str(HERE.parents[1] / "every-action-sweep.py"), "--plan-only",
                            "--catalog", str(catalog), "--out", out, "--json", str(plan_path)],
                           check=True, capture_output=True, text=True, timeout=120)
            plan = json.loads(plan_path.read_text())
        for entry in plan["sessions"]:
            rows = {row["id"]: row for row in entry["rows"]}
            for ident in FAMILY.closes:
                with self.subTest(session=entry["name"], ident=ident):
                    row = rows[ident]
                    self.assertNotIn("skipped", row)
                    self.assertEqual(row["entry"], "action")
                    name = "section" if ident == "workspaceGroup.addToSection" else "space"
                    self.assertEqual(row["args"], {name: f"<fixture {ident}.{name}>"})
                    self.assertEqual(row["prepare"], [[s, a] for s, a in FAMILY.prepare[ident]])
                    self.assertEqual(row.get("undo"), list(FAMILY.undo[ident]) if ident in FAMILY.undo else None)
            for ident in self.record_reasoned():
                with self.subTest(session=entry["name"], ident=ident):
                    self.assertEqual((rows[ident].get("skipped"), rows[ident].get("skip_kind")),
                                     ("needs a agent-chat argument", "gap"))

    @staticmethod
    def record_reasoned():
        return sorted(json.loads(RECORD.read_text())["reasoned"])


if __name__ == "__main__":
    unittest.main()
