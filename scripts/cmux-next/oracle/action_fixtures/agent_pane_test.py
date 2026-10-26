#!/usr/bin/env python3
"""Tests for the agentPane gap fixtures (p15-oracle-085) and the sweep's context wait they rely on.

Run: python3 -I scripts/cmux-next/oracle/action_fixtures/agent_pane_test.py (stdlib unittest, no app, Linux too).
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
ORACLE = HERE.parent
SCRIPTS = ORACLE.parent
REPO = SCRIPTS.parents[1]
sys.path.insert(0, str(ORACLE))

import action_fixtures  # noqa: E402

OUT = tempfile.mkdtemp(prefix="agent-pane-fixture-test-")
CATALOG = SCRIPTS.parent / "fuzz" / "macos-matrix" / "fixtures" / "action-list.json"
sweep_mod = action_fixtures.load_sweep(["--plan-only", "--catalog", str(CATALOG), "--out", OUT])
FAMILIES = action_fixtures.load_families()
FAMILY = next(f for f in FAMILIES.families if f.name == "agentPane")
agent_pane = FAMILY.module
RECORD = json.loads((REPO / "tests" / "oracle" / "gap-closures" / "agentPane.json").read_text())
GAPS = json.loads((SCRIPTS / "every-action-gaps.json").read_text())["gaps"]


def describe(ident, missing=(), available=None):
    """An action.describe reply: available unless `missing` names facts (or `available` says otherwise)."""
    action = {"id": ident, "available": not missing if available is None else available}
    if missing:
        action["missing_context"] = list(missing)
    return {"action": action}


class Driver:
    """The SweepDriver seam with scripted replies: `answers` maps a socket method to a list of replies (the last one
    repeats). `wait` polls like the sweep's, a few times, with no clock."""

    def __init__(self, answers):
        self.answers = {method: list(replies) for method, replies in answers.items()}
        self.calls = []

    def run(self, action, args=None):
        raise AssertionError(f"the fixture runs no action, not {action}")

    def rpc(self, method, params=None):
        self.calls.append((method, params))
        replies = self.answers[method]
        return replies.pop(0) if len(replies) > 1 else replies[0]

    def wait(self, predicate, seconds):
        for _ in range(4):
            value = predicate()
            if value:
                return value
        return None


class RecordTests(unittest.TestCase):
    def test_the_family_loads_with_its_record(self):
        self.assertEqual(FAMILY.closes, tuple(sorted(RECORD["closed"])))
        self.assertEqual(FAMILIES.owners.get("checkpointCaptureAvailable"), "agentPane")
        FAMILIES.check_contexts(sweep_mod.CONTEXT_SETUP)

    def test_closed_and_reasoned_cover_the_agent_pane_gaps_once(self):
        self.assertFalse(set(RECORD["closed"]) & set(RECORD["reasoned"]))
        ours = set(RECORD["closed"]) | set(RECORD["reasoned"])
        self.assertEqual(len(ours), 6)
        # Until p15-oracle-087 applies the record, every id is still a gap of the baseline.
        pending = {ident for ident in GAPS if ident.startswith("agentPane.")}
        self.assertLessEqual(pending, ours)
        self.assertTrue(all(RECORD["closed"].values()) and all(RECORD["reasoned"].values()))


class CheckpointCaptureTests(unittest.TestCase):
    PROBE = agent_pane.CHECKPOINT_PROBE

    def enter(self, describes, focused=None):
        driver = Driver({"debug.agent_pane": [focused or {"pane": "p1", "focused": True}],
                         "action.describe": describes})
        return agent_pane.CheckpointCapture().enter(driver), driver

    def test_holds_once_the_page_reports_support(self):
        why, driver = self.enter([describe(self.PROBE, ["checkpointCaptureAvailable"]), describe(self.PROBE)])
        self.assertIsNone(why)
        self.assertEqual(driver.calls[0], ("debug.agent_pane", {"action": "focus_composer"}))
        self.assertEqual(driver.calls[1], ("action.describe", {"action": self.PROBE}))

    def test_a_chat_without_focus_yet_is_waited_for_by_the_same_poll(self):
        why, _ = self.enter([describe(self.PROBE, ["agentPaneFocused", "checkpointCaptureAvailable"]),
                             describe(self.PROBE, ["agentPaneFocused"])])
        self.assertIsNone(why)  # the fact this family owns holds; agentPaneFocused is the sweep's (described)

    def test_no_support_is_the_gap_reason(self):
        why, _ = self.enter([describe(self.PROBE, ["checkpointCaptureAvailable"])])
        self.assertEqual(why, agent_pane.NO_CHECKPOINT_SUPPORT)
        self.assertIn("git.capabilities", why)

    def test_no_describe_answer_is_named(self):
        why, _ = self.enter([{"error": "unreachable", "unreachable": True}])
        self.assertEqual(why, f"{self.PROBE} has no describe answer")

    def test_a_chat_that_does_not_take_the_keyboard_is_named(self):
        why, driver = self.enter([describe(self.PROBE)], focused={"error": "pane p1 shows no agent tab"})
        self.assertIn("did not take the keyboard", why)
        self.assertEqual([m for m, _ in driver.calls], ["debug.agent_pane"])

    def test_leave_makes_no_drift(self):
        fixture = agent_pane.CheckpointCapture()
        fixture.enter(Driver({"debug.agent_pane": [{}], "action.describe": [describe(self.PROBE)]}))
        self.assertIsNone(fixture.leave(Driver({})))
        self.assertIsNone(fixture.last)


class DescribedTests(unittest.TestCase):
    """Sweep.described: the describe waits for the context facts the session set up, and only for those."""

    def setUp(self):
        patcher = mock.patch.object(sweep_mod, "CONTEXT_HOLD_S", 0.4)
        patcher.start()
        self.addCleanup(patcher.stop)
        self.sweep = sweep_mod.Sweep(None, "light", None)
        self.calls = []

    def script(self, describes, until_nudged=False):
        """Patches the sweep's rpc: describe answers from `describes` (the last repeats), or with `until_nudged` the
        first answer until focus_composer ran and the second after."""
        replies = list(describes)
        nudged = []

        def rpc(method, params=None, timeout=60):
            self.calls.append(method)
            if method == "debug.agent_pane":
                nudged.append(params)
                return {"focused": True}
            if until_nudged:
                return replies[1] if nudged else replies[0]
            return replies.pop(0) if len(replies) > 1 else replies[0]

        patcher = mock.patch.object(sweep_mod, "rpc", rpc)
        patcher.start()
        self.addCleanup(patcher.stop)
        return nudged

    def test_a_late_focus_fact_is_waited_for(self):
        ident = "agentPane.previousTurn"
        self.script([describe(ident, ["agentPaneFocused"]), describe(ident, ["agentPaneFocused"]), describe(ident)])
        info = self.sweep.described(ident, {"context": "chat"})
        self.assertTrue(info["available"])
        self.assertEqual(self.calls.count("action.describe"), 3)

    def test_a_chat_still_unfocused_halfway_takes_the_keyboard(self):
        ident = "agentPane.archiveChat"
        nudged = self.script([describe(ident, ["agentPaneFocused"]), describe(ident)], until_nudged=True)
        info = self.sweep.described(ident, {"context": "chat"})
        self.assertTrue(info["available"])
        self.assertEqual(nudged, [{"action": "focus_composer"}])

    def test_other_contexts_are_never_nudged_and_give_the_last_answer(self):
        ident = "terminal.clear"
        nudged = self.script([describe(ident, ["terminalFocused"])])
        info = self.sweep.described(ident, {"context": "terminal"})
        self.assertFalse(info["available"])
        self.assertEqual(info["missing_context"], ["terminalFocused"])
        self.assertEqual(nudged, [])

    def test_an_unavailable_action_with_no_missing_fact_is_not_waited_for(self):
        ident = "debug.only"
        self.script([describe(ident, available=False)])
        self.assertFalse(self.sweep.described(ident, {"context": None})["available"])
        self.assertEqual(self.calls, ["action.describe"])

    def test_no_describe_answer_is_none(self):
        self.script([{"error": "unreachable", "unreachable": True}])
        self.assertIsNone(self.sweep.described("x", {"context": None}))
        self.assertEqual(self.calls, ["action.describe"])


class PlanTests(unittest.TestCase):
    def test_create_checkpoint_is_planned_with_the_family_context(self):
        sweep = sweep_mod.Sweep(None, "light", None)
        sweep.base = dict(sweep_mod.PLAN_BASE)
        plan, skipped = sweep.plan({"id": "agentPane.createCheckpoint",
                                    "requires": ["agentPaneFocused", "checkpointCaptureAvailable"]})
        self.assertIsNone(skipped)
        self.assertEqual(plan["context"], "chat")
        self.assertEqual(plan["families"], ["checkpointCaptureAvailable"])


if __name__ == "__main__":
    unittest.main()
