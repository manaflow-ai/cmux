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

    def test_the_six_agent_pane_gaps_are_closed_each_with_why(self):
        self.assertNotIn("reasoned", RECORD)
        self.assertEqual(len(RECORD["closed"]), 6)
        # Until p15-oracle-087 applies the record, every id is still a gap of the baseline.
        pending = {ident for ident in GAPS if ident.startswith("agentPane.")}
        self.assertLessEqual(pending, set(RECORD["closed"]))
        self.assertTrue(all(RECORD["closed"].values()))

    def test_no_closure_leans_on_a_debug_focus_path(self):
        self.assertNotIn("focus_composer", json.dumps(RECORD))
        self.assertNotIn("debug.", (HERE / "agent_pane.py").read_text())


class CheckpointCaptureTests(unittest.TestCase):
    PROBE = agent_pane.CHECKPOINT_PROBE

    def enter(self, describes):
        driver = Driver({"action.describe": describes})
        return agent_pane.CheckpointCapture().enter(driver), driver

    def test_holds_once_the_page_reports_support(self):
        why, driver = self.enter([describe(self.PROBE, ["checkpointCaptureAvailable"]), describe(self.PROBE)])
        self.assertIsNone(why)
        self.assertEqual(driver.calls, [("action.describe", {"action": self.PROBE})] * 2)

    def test_a_chat_without_focus_yet_is_waited_for_by_the_same_poll(self):
        why, driver = self.enter([describe(self.PROBE, ["agentPaneFocused", "checkpointCaptureAvailable"]),
                                  describe(self.PROBE, ["agentPaneFocused"])])
        self.assertIsNone(why)  # the fact this family owns holds; agentPaneFocused is the sweep's (described)
        self.assertEqual({m for m, _ in driver.calls}, {"action.describe"})  # it only reads, never focuses

    def test_a_chat_tab_focus_never_focused_is_named(self):
        why, _ = self.enter([describe(self.PROBE, ["agentPaneFocused", "checkpointCaptureAvailable"])])
        self.assertEqual(why, agent_pane.NOT_FOCUSED)

    def test_no_support_is_the_gap_reason(self):
        why, _ = self.enter([describe(self.PROBE, ["checkpointCaptureAvailable"])])
        self.assertEqual(why, agent_pane.NO_CHECKPOINT_SUPPORT)
        self.assertIn("git.capabilities", why)

    def test_no_describe_answer_is_named(self):
        why, _ = self.enter([{"error": "unreachable", "unreachable": True}])
        self.assertEqual(why, f"{self.PROBE} has no describe answer")

    def test_leave_makes_no_drift(self):
        fixture = agent_pane.CheckpointCapture()
        fixture.enter(Driver({"action.describe": [describe(self.PROBE)]}))
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

    def script(self, describes):
        """Patches the sweep's rpc: describe answers from `describes` (the last repeats); any other method fails."""
        replies = list(describes)

        def rpc(method, params=None, timeout=60):
            self.calls.append(method)
            if method != "action.describe":
                raise AssertionError(f"described only reads, not {method}")
            return replies.pop(0) if len(replies) > 1 else replies[0]

        patcher = mock.patch.object(sweep_mod, "rpc", rpc)
        patcher.start()
        self.addCleanup(patcher.stop)

    def test_a_late_focus_fact_is_waited_for_and_the_wait_recorded(self):
        ident = "agentPane.previousTurn"
        self.script([describe(ident, ["agentPaneFocused"]), describe(ident, ["agentPaneFocused"]), describe(ident)])
        info, waited = self.sweep.described(ident)
        self.assertTrue(info["available"])
        self.assertEqual(self.calls, ["action.describe"] * 3)
        self.assertGreaterEqual(waited, 50)  # two polls of sweep.wait's 50 ms step

    def test_a_chat_that_never_takes_the_keyboard_stays_unavailable(self):
        ident = "agentPane.archiveChat"
        self.script([describe(ident, ["agentPaneFocused"])])
        info, waited = self.sweep.described(ident)
        self.assertFalse(info["available"])
        self.assertEqual(info["missing_context"], ["agentPaneFocused"])
        self.assertGreaterEqual(waited, sweep_mod.CONTEXT_HOLD_S * 1000)
        self.assertEqual(set(self.calls), {"action.describe"})

    def test_an_unavailable_action_with_no_missing_fact_is_not_waited_for(self):
        ident = "debug.only"
        self.script([describe(ident, available=False)])
        info, _ = self.sweep.described(ident)
        self.assertFalse(info["available"])
        self.assertEqual(self.calls, ["action.describe"])

    def test_no_describe_answer_is_none(self):
        self.script([{"error": "unreachable", "unreachable": True}])
        self.assertIsNone(self.sweep.described("x")[0])
        self.assertEqual(self.calls, ["action.describe"])


class LateContextReportTests(unittest.TestCase):
    def report(self, rows):
        session = {"name": "light", "rows": rows, "interactions": [], "summary": {}, "launches": [],
                   "validity": {}, "idle": {"frames": {}}}
        return {"env": {"host": "h", "macos": "26", "sha": "0" * 40}, "sessions": [session]}

    def test_late_and_never_published_contexts_are_listed(self):
        rows = [{"id": "agentPane.previousTurn", "kind": "action", "context_wait_ms": 640.0},
                {"id": "agentPane.archiveChat", "kind": "action", "context_wait_ms": 2001.0,
                 "skipped": "unavailable here: agentPaneFocused", "skip_kind": "gap"},
                {"id": "agentPane.git.commit", "kind": "action", "context_wait_ms": 3.2}]
        with mock.patch.object(sweep_mod, "launch_lines", lambda session: []):
            text = sweep_mod.markdown(self.report(rows))
        self.assertIn("Context published late", text)
        self.assertIn("- agentPane.archiveChat: 2001.0 ms (never; skipped)", text)
        self.assertIn("- agentPane.previousTurn: 640.0 ms", text)
        self.assertNotIn("agentPane.git.commit: 3.2", text)


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
