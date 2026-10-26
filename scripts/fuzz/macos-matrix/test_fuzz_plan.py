#!/usr/bin/env python3
"""Offline tests for fuzz.py's schema-driven plan: no VM, no app.

Run: python3 -m unittest scripts/fuzz/macos-matrix/test_fuzz_plan.py
"""

from __future__ import annotations

import itertools
import json
import os
import random
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fuzz  # noqa: E402


def action(ident: str, **kw) -> dict:
    row = {"id": ident, "title": ident, "cli_name": ident.replace(".", " "), "category": "workspace",
           "arguments": [], "targets": [], "requires": [], "surfaces": {"mcp": "offered"}, "bound": True,
           "debug_only": False, "destructive": False, "waits_for_person": False}
    row.update(kw)
    return row


CATALOG = [
    action("workspace.new"),
    action("workspace.close", destructive=True, targets=["workspace"],
           arguments=[{"name": "confirm", "kind": "bool", "required": False}]),
    action("pane.resize", targets=["pane"], arguments=[
        {"name": "direction", "kind": "enum", "required": True,
         "choices": [{"value": "left", "title": "Left"}, {"value": "right", "title": "Right"}]},
        {"name": "amount", "kind": "int", "required": False, "min": 1, "max": 40}]),
    action("tab.rename", targets=["tab"], arguments=[{"name": "title", "kind": "string", "required": True}]),
    action("tab.moveToWorkspace", arguments=[
        {"name": "workspace", "kind": "target", "required": True, "target_kind": "workspace"}]),
    action("browser.open", arguments=[{"name": "url", "kind": "string", "required": False}]),
    action("app.pickFolder", waits_for_person=True),
    action("debug.crash", debug_only=True),
    action("app.quit", surfaces={"mcp": "endsApp"}),
    action("cloud.vm.start", category="cloud"),
    action("update.check"),
    action("unbound.thing", bound=False),
    action("sidebar.section.addGroup", arguments=[
        {"name": "section", "kind": "target", "required": True, "target_kind": "sidebar-section"}]),
    action("cloudMove", category="workspace", unavailable_reason="Sign in to use cmux Cloud."),
]
ELIGIBLE = {"workspace.new", "workspace.close", "pane.resize", "tab.rename", "tab.moveToWorkspace",
            "browser.open", "app.pickFolder"}


def plan(seed: int, catalog: list[dict], walk: int = 300) -> tuple[int, list[dict]]:
    eligible, _ = fuzz.classify_actions(catalog)
    prefix_len, steps = fuzz.plan_run(seed, eligible, tour=True, coverage=True, count=walk)
    return prefix_len, list(steps)


class EligibilityTests(unittest.TestCase):
    def test_excludes_with_reasons(self):
        eligible, excluded = fuzz.classify_actions(CATALOG)
        self.assertEqual({a["id"] for a in eligible}, ELIGIBLE)
        self.assertEqual(excluded, {"debug.crash": "debug-only", "app.quit": "ends-app",
                                    "cloud.vm.start": "category:cloud", "update.check": "skip-word:update",
                                    "unbound.thing": "not-bound",
                                    "sidebar.section.addGroup": "unresolvable-target:sidebar-section",
                                    "cloudMove": "unavailable-in-build"})


class PlanTests(unittest.TestCase):
    def test_same_seed_same_plan_whatever_the_list_order(self):
        shuffled = list(CATALOG)
        random.Random(99).shuffle(shuffled)
        self.assertEqual(plan(7, CATALOG), plan(7, shuffled))

    def test_other_seed_other_plan(self):
        self.assertNotEqual(plan(7, CATALOG)[1], plan(8, CATALOG)[1])

    def test_lazy_walk_is_a_prefix_of_a_longer_walk(self):
        _, short = plan(7, CATALOG, walk=50)
        eligible, _ = fuzz.classify_actions(CATALOG)
        _, endless = fuzz.plan_run(7, eligible, tour=True, coverage=True, count=None)
        self.assertEqual(short, list(itertools.islice(endless, len(short))))

    def test_coverage_pass_runs_every_eligible_action_once_after_the_tour(self):
        prefix_len, steps = plan(7, CATALOG)
        self.assertEqual(prefix_len, len(fuzz.TOUR) + len(ELIGIBLE))
        self.assertTrue(all(s["kind"] == "palette" for s in steps[:len(fuzz.TOUR)]))
        ids = [s["id"] for s in steps[len(fuzz.TOUR):prefix_len]]
        self.assertEqual(sorted(ids), sorted(ELIGIBLE))

    def test_coverage_arguments_follow_the_schema(self):
        prefix_len, steps = plan(3, CATALOG)
        by_id = {s["id"]: s for s in steps[len(fuzz.TOUR):prefix_len]}
        args = {k: dict(v["args"]) for k, v in by_id.items()}
        self.assertEqual(args["workspace.close"]["confirm"], "true")
        self.assertIn(args["pane.resize"]["direction"], ("left", "right"))
        if "amount" in args["pane.resize"]:
            self.assertTrue(1 <= int(args["pane.resize"]["amount"]) <= 40)
        self.assertIn("title", args["tab.rename"])
        self.assertEqual(args["tab.moveToWorkspace"]["workspace"]["kind"], "workspace")
        self.assertIs(by_id["app.pickFolder"]["wait"], False)
        for s in by_id.values():
            if "target" in s:
                self.assertIn(s["target"]["kind"], {"workspace", "pane", "tab"})

    def test_every_planned_step_is_json(self):
        _, steps = plan(11, CATALOG, walk=2000)
        json.dumps(steps)
        kinds = {s["kind"] for s in steps}
        self.assertTrue({"action", "palette", "key", "click"} <= kinds)


class CliArgsTests(unittest.TestCase):
    def test_arguments_go_by_exact_name_and_targets_resolve(self):
        step = {"kind": "action", "id": "tab.moveToWorkspace",
                "args": [["workspace", {"kind": "workspace", "n": 5}], ["title", "a b"]],
                "target": {"kind": "tab", "n": 1}, "wait": False}
        live = {"workspace": "workspace:ws_2", "tab": "tab:tab_9"}
        self.assertEqual(fuzz.action_cli_args(step, lambda pick: live[pick["kind"]]),
                         ["--target", "tab:tab_9", "--arg", "workspace=workspace:ws_2", "--arg", "title=a b",
                          "--no-wait"])

    def test_unresolved_target_argument_is_left_out(self):
        step = {"kind": "action", "id": "x", "args": [["workspace", {"kind": "workspace", "n": 0}]]}
        self.assertEqual(fuzz.action_cli_args(step, lambda pick: None), [])

    def test_old_steps_keep_their_flags(self):
        step = {"kind": "action", "id": "x", "args": ["--direction", "left"]}
        self.assertEqual(fuzz.action_cli_args(step, lambda pick: None), ["--direction", "left"])

    def test_list_ids_takes_a_list_or_an_object_holding_one(self):
        self.assertEqual(fuzz.list_ids([{"id": "ws_1"}, {"x": 1}]), ["ws_1"])
        self.assertEqual(fuzz.list_ids({"windows": [{"id": 3}]}), ["3"])
        self.assertEqual(fuzz.list_ids("nope"), [])


class OutcomeTests(unittest.TestCase):
    def cp(self, rc: int, err: str = "") -> subprocess.CompletedProcess:
        return subprocess.CompletedProcess([], rc, "", err)

    def test_outcomes(self):
        self.assertEqual(fuzz.action_outcome(self.cp(0)), "ok")
        self.assertEqual(fuzz.action_outcome(self.cp(124, "timeout")), "timeout")
        self.assertEqual(fuzz.action_outcome(self.cp(1, 'warn\n{"code": "unavailable", "message": "m"}\n')),
                         "error:unavailable")
        self.assertEqual(fuzz.action_outcome(self.cp(2, "not json")), "rc:2")

    def test_coverage_summary(self):
        eligible, excluded = fuzz.classify_actions(CATALOG)
        cov = fuzz.Coverage(eligible, excluded)
        for a in sorted(ELIGIBLE):
            cov.record(a, "ok")
        cov.record("pane.resize", "error:invalid_params")
        s = cov.summary()
        self.assertEqual(s["actions_covered"], s["actions_eligible"])
        self.assertEqual(s["actions_known"], len(CATALOG))
        self.assertEqual(s["actions_uncovered"], [])
        self.assertEqual(s["action_outcomes"]["pane.resize"],
                         {"runs": 2, "outcomes": {"error:invalid_params": 1, "ok": 1}})

    def test_a_refused_only_action_stays_uncovered(self):
        eligible, excluded = fuzz.classify_actions(CATALOG)
        cov = fuzz.Coverage(eligible, excluded)
        for a in sorted(ELIGIBLE):
            cov.record(a, "ok")
        cov.runs.pop("tab.rename")
        cov.runs.pop("pane.resize")
        cov.record("tab.rename", "error:invalid_params")
        cov.record("tab.rename", "error:unavailable")
        cov.record("pane.resize", "error:transport")
        cov.record("browser.open", "error:operation_failed")  # the handler ran and failed: covered
        s = cov.summary()
        self.assertEqual(s["actions_covered"], len(ELIGIBLE) - 2)
        self.assertEqual(sorted(s["actions_uncovered"]), ["pane.resize", "tab.rename"])
        self.assertEqual(s["actions_refused"], {"pane.resize": ["error:transport"],
                                                "tab.rename": ["error:invalid_params", "error:unavailable"]})

    def test_reached_handler(self):
        for outcome in ("ok", "timeout", "error:operation_failed", "error:js_error", "error:daemon_error"):
            self.assertTrue(fuzz.reached_handler(outcome), outcome)
        for outcome in ("error:invalid_params", "error:confirmation_required", "error:feature.disabled",
                        "error:unavailable", "error:not_found", "error:transport", "rc:2"):
            self.assertFalse(fuzz.reached_handler(outcome), outcome)

    def test_uncovered_listed(self):
        eligible, excluded = fuzz.classify_actions(CATALOG)
        cov = fuzz.Coverage(eligible, excluded)
        cov.record("workspace.new", "ok")
        s = cov.summary()
        self.assertEqual(s["actions_covered"], 1)
        self.assertEqual(len(s["actions_uncovered"]), len(ELIGIBLE) - 1)


class TimeBoundTests(unittest.TestCase):
    def gates(self, prefix_len: int, minutes: float, coverage_minutes: float, at: list[float]) -> list[str]:
        """The gate of step i at minute at[i] after the loop's start."""
        run_end, prefix_end = fuzz.run_deadlines(0.0, minutes, coverage_minutes)
        out = []
        for i, t in enumerate(at):
            gate = fuzz.step_gate(i, prefix_len, t * 60, run_end, prefix_end)
            out.append(gate)
            if gate == "stop":
                break
        return out

    def test_minutes_bounds_the_whole_run_coverage_pass_included(self):
        # --minutes 20 with the default --coverage-minutes 60: the run ends at minute 20, in the pass.
        self.assertEqual(self.gates(10, 20, 60, [0, 5, 19.9, 20]), ["run", "run", "run", "stop"])
        self.assertEqual(fuzz.run_deadlines(100.0, 20, 60), (100.0 + 1200, 100.0 + 1200))

    def test_coverage_bound_inside_minutes_skips_the_rest_of_the_pass_then_walks(self):
        # Pass bounded at 5 of 20 minutes: steps 2..3 of the pass are skipped, the walk runs to minute 20.
        self.assertEqual(self.gates(4, 20, 5, [0, 4, 5, 6, 7, 19, 20]),
                         ["run", "run", "skip", "skip", "run", "run", "stop"])

    def test_no_minutes_no_run_bound(self):
        self.assertEqual(fuzz.run_deadlines(0.0, 0, 60), (None, 3600.0))
        self.assertEqual(self.gates(1, 0, 60, [0, 59, 61, 600]), ["run", "run", "run", "run"])

    def test_replay_has_no_prefix_so_only_minutes_bounds_it(self):
        # A replay runs with prefix_len 0: the coverage bound never skips a replayed step.
        self.assertEqual(self.gates(0, 0, 60, [0, 61, 120, 600]), ["run", "run", "run", "run"])
        self.assertEqual(self.gates(0, 20, 60, [0, 19, 20]), ["run", "run", "stop"])


FIXTURE = os.path.join(HERE, "fixtures", "action-list.json")
CONTROL_CATALOG = os.path.join(HERE, "..", "..", "..", "Packages", "macOS", "CmuxNext", "Sources", "CmuxNextControl",
                               "ControlCatalog.swift")


def control_action_json_keys() -> set[str]:
    """The keys ControlActionInfo.json(contextMask:debugActionsAvailable:) writes, read from its source."""
    import re
    with open(CONTROL_CATALOG) as f:
        src = f.read()
    body = src[src.index("func json(contextMask: UInt32, debugActionsAvailable: Bool)"):src.index("func contextGap(")]
    keys = set(re.findall(r'^\s*"([a-z_]+)": ', body, re.M))
    keys |= set(re.findall(r'members\["([a-z_]+)"\]', body))
    keys |= {"missing_context", "available_with_target", "context_reason"}  # merged from contextGap
    return keys


class ActionListFixtureTests(unittest.TestCase):
    """fixtures/action-list.json: real catalog actions in ControlActionInfo.json's shape (the arguments
    as ControlArgumentInfo.json writes them)."""

    def setUp(self):
        with open(FIXTURE) as f:
            self.actions = fuzz.checked_action_list(json.load(f))

    def test_fixture_has_the_wire_shape(self):
        keys = control_action_json_keys()
        self.assertTrue(set(fuzz.ACTION_LIST_KEYS) <= keys, set(fuzz.ACTION_LIST_KEYS) - keys)
        for a in self.actions:
            self.assertEqual(set(a) - keys, set(), a["id"])
            for arg in a["arguments"]:
                self.assertTrue({"name", "title", "kind", "required"} <= set(arg), a["id"])
                self.assertIn(arg["kind"], ("string", "int", "bool", "enum", "target"))

    def test_classification(self):
        eligible, excluded = fuzz.classify_actions(self.actions)
        self.assertEqual(excluded, {
            "cloudMove": "unavailable-in-build",
            "macScreen.open": "not-bound",
            "openDebugSettings": "debug-only",
            "palette.checkForUpdates": "skip-word:update",
            "quit": "ends-app",
            "quitKeepSessions": "ends-app",
            "sidebar.priority.snooze": "unresolvable-target:agent-chat",
            "workspaceGroup.addToSection": "unresolvable-target:sidebar-section",
        })
        self.assertEqual(len(eligible) + len(excluded), len(self.actions))

    def test_coverage_plan_follows_the_real_schemas(self):
        eligible, _ = fuzz.classify_actions(self.actions)
        by_id = {a["id"]: a for a in eligible}
        for seed in range(20):
            prefix_len, steps = fuzz.plan_run(seed, eligible, tour=False, coverage=True, count=0)
            planned = list(steps)
            self.assertEqual(prefix_len, len(eligible))
            self.assertEqual(sorted(s["id"] for s in planned), sorted(by_id))
            for s in planned:
                a = by_id[s["id"]]
                schema = {arg["name"]: arg for arg in a["arguments"]}
                given = dict(s["args"])
                for name, arg in schema.items():
                    if arg["required"]:
                        self.assertIn(name, given, (seed, a["id"]))
                for name, value in given.items():
                    arg = schema[name]
                    if arg["kind"] == "int":
                        self.assertTrue(arg["min"] <= int(value) <= arg["max"], (seed, a["id"], value))
                    elif arg["kind"] == "enum":
                        self.assertIn(value, [c["value"] for c in arg["choices"]], (seed, a["id"]))
                    elif arg["kind"] == "bool":
                        self.assertIn(value, ("true", "false"))
                    elif arg["kind"] == "target":
                        self.assertEqual(value["kind"], arg["target_kind"])
                if a["destructive"]:
                    self.assertEqual(given["confirm"], "true", a["id"])
                if a["requires"]:
                    self.assertIn("target", s, (seed, a["id"]))  # the target stands in for the focused context
                if a["waits_for_person"]:
                    self.assertIs(s["wait"], False)

    def test_action_surfaces_json_is_refused(self):
        surfaces = os.path.join(HERE, "..", "..", "..", "plans", "cmux-next", "action-surfaces.json")
        with open(surfaces) as f:
            with self.assertRaises(ValueError):
                fuzz.checked_action_list(json.load(f))
        with tempfile.TemporaryDirectory() as d:
            r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "fuzz.py"), "--plan-only", surfaces,
                                "--out", d], capture_output=True, text=True)
            self.assertEqual(r.returncode, 2)
            self.assertIn("not a `cmux --json action list` reply", r.stderr)


class PlanOnlyTests(unittest.TestCase):
    def test_plan_only_is_reproducible(self):
        with tempfile.TemporaryDirectory() as d:
            src = os.path.join(d, "actions.json")
            with open(src, "w") as f:
                json.dump({"actions": CATALOG}, f)
            runs = []
            for n in range(2):
                out = os.path.join(d, f"out{n}")
                r = subprocess.run([sys.executable, "-I", os.path.join(HERE, "fuzz.py"), "--plan-only", src,
                                    "--seed", "7", "--steps", "100", "--out", out],
                                   capture_output=True, text=True, check=True)
                with open(os.path.join(out, "plan.jsonl")) as f:
                    runs.append((json.loads(r.stdout), f.read()))
            self.assertEqual(runs[0], runs[1])
            info = runs[0][0]
            self.assertEqual(info["actions_planned_in_coverage"], info["actions_eligible"])
            self.assertEqual(info["steps"], len(fuzz.TOUR) + len(ELIGIBLE) + 100)


if __name__ == "__main__":
    unittest.main()
