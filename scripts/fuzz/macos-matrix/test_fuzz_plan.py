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
           "arguments": [], "targets": [], "surfaces": {"mcp": "offered"}, "bound": True,
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
                                    "unbound.thing": "not-bound"})


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

    def test_uncovered_listed(self):
        eligible, excluded = fuzz.classify_actions(CATALOG)
        cov = fuzz.Coverage(eligible, excluded)
        cov.record("workspace.new", "ok")
        s = cov.summary()
        self.assertEqual(s["actions_covered"], 1)
        self.assertEqual(len(s["actions_uncovered"]), len(ELIGIBLE) - 1)


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
