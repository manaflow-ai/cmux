#!/usr/bin/env python3
"""The journeys' invariant cursor (invariants.py), no fleet, no app.

    python3 scripts/journeys/test_invariants.py

A journey fails at the step after which the app's ledger has a new violation, reads every violation exactly once
(a cursor), starts over when a relaunch gives a new ledger, fails when the ring dropped violations it never read,
and is "not run" (NotArmed) when the app does not check its invariants.
"""
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path[:0] = [str(HERE), str(HERE.parent / "cmux-next")]
import driver as D  # noqa: E402
import invariants  # noqa: E402


class Failed(Exception):
    pass


class FakeApp:
    """debug.invariants over a hand-held ledger."""

    def __init__(self, armed=True):
        self.armed, self.pid, self.ledger, self.capacity, self.calls = armed, 100, [], 1024, []

    def add(self, rule, detail="broken", actions=("pane.split",)):
        seq = (self.ledger[-1]["seq"] if self.ledger else 0) + 1
        self.ledger.append({"seq": seq, "id": rule, "host": "app", "subject": {"window": "w1"}, "detail": detail,
                            "trigger": {"kind": "action", "actions": [{"id": a, "origin": "key", "index": seq} for a in actions],
                                        "turn": seq, "frame_seq": None}, "report": f"/tmp/{seq:04d}-{rule}.json"})

    def relaunch(self):
        self.pid, self.ledger = self.pid + 1, []

    def rpc(self, method, params):
        self.calls.append((method, dict(params)))
        if method != "debug.invariants":
            raise KeyError(method)
        if not self.armed:
            return {"armed": False, "mode": "release"}
        since = params.get("since", 0)
        kept = self.ledger[-self.capacity:]
        oldest = kept[0]["seq"] if kept else (self.ledger[-1]["seq"] + 1 if self.ledger else 1)
        last = self.ledger[-1]["seq"] if self.ledger else 0
        return {"armed": True, "mode": "on", "seq": last, "oldest_seq": oldest, "dropped": since < oldest - 1,
                "violations": [v for v in kept if v["seq"] > since]}


class CursorTests(unittest.TestCase):
    def cursor(self, app, from_start=False):
        return invariants.Cursor(app.rpc, lambda: app.pid, from_start=from_start)

    def test_a_violation_after_a_step_fails_that_step_with_its_rule_action_and_report(self):
        app = FakeApp()
        cursor = self.cursor(app)
        invariants.assert_clean(cursor, "step 1 (key)", Failed)
        app.add("W10", "key window model targets none")
        with self.assertRaises(Failed) as caught:
            invariants.assert_clean(cursor, "step 2 (key)", Failed)
        message = str(caught.exception)
        for part in ("step 2 (key)", "W10", "key window model targets none", "pane.split", "/tmp/0001-W10.json"):
            self.assertIn(part, message)
        invariants.assert_clean(cursor, "step 3 (key)", Failed)  # read once: the next step is clean again

    def test_a_later_journey_does_not_inherit_an_earlier_journeys_violations(self):
        app = FakeApp()
        app.add("DP1")
        invariants.assert_clean(self.cursor(app), "step 1", Failed)
        with self.assertRaises(Failed):
            invariants.assert_clean(self.cursor(app, from_start=True), "step 1", Failed)

    def test_a_relaunch_starts_a_new_ledger(self):
        app = FakeApp()
        app.add("W1")
        app.add("W2")
        cursor = self.cursor(app)
        app.relaunch()
        app.add("G1")
        with self.assertRaises(Failed) as caught:
            invariants.assert_clean(cursor, "step 2 (relaunch)", Failed)
        self.assertIn("G1", str(caught.exception))

    def test_a_ring_that_dropped_unread_violations_fails(self):
        app = FakeApp()
        app.capacity = 2
        cursor = self.cursor(app)
        for rule in ("W1", "W2", "W3"):
            app.add(rule)
        with self.assertRaises(Failed) as caught:
            invariants.assert_clean(cursor, "step 1", Failed)
        self.assertIn("dropped", str(caught.exception))

    def test_an_app_that_does_not_check_is_not_armed(self):
        with self.assertRaises(invariants.NotArmed):
            self.cursor(FakeApp(armed=False))

    def test_the_full_check_asks_for_every_rule_and_the_harness_rules(self):
        app = FakeApp()
        cursor = self.cursor(app)
        invariants.assert_clean(cursor, "the last step", Failed, check=True, ipc=True)
        self.assertEqual(app.calls[-1], ("debug.invariants", {"since": 0, "check": True, "ipc": True}))


class DriverTests(unittest.TestCase):
    """The driver's use of the cursor: one per app process, the mode, and a relaunch's read of the old ledger."""

    def journey(self, app, mode="fail"):
        journey = object.__new__(D.Journey)
        journey.app, journey.invariant_mode, journey.invariant_findings = app, mode, []
        journey.invariants = journey.app_cursor()
        return journey

    def test_the_cursor_belongs_to_the_app_process_so_a_violation_between_two_journeys_is_read(self):
        app = FakeApp()
        first = self.journey(app)
        first.read_invariants("the last step (full check)")
        app.add("LO11", "window w2 has 0 workspaces")  # after journey 1's last read, before journey 2's first
        second = self.journey(app)
        self.assertIs(second.invariants, first.invariants)
        with self.assertRaises(D.StepError) as caught:
            second.read_invariants("step 1 (key)")
        self.assertIn("LO11", str(caught.exception))

    def test_shadow_mode_records_each_violation_and_goes_on(self):
        app = FakeApp()
        journey = self.journey(app, mode="shadow")
        app.add("W2", "layout pane_b != model pane_a")
        journey.read_invariants("step 3 (key)")
        journey.read_invariants("step 4 (key)")
        self.assertEqual(len(journey.invariant_findings), 1)
        self.assertIn("W2", journey.invariant_findings[0]["problem"])
        self.assertEqual(journey.invariant_findings[0]["step"], "step 3 (key)")

    def test_a_relaunch_reads_the_old_ledger_before_it_quits(self):
        app = FakeApp()
        journey = self.journey(app)
        app.add("VS2", "pane p1 selects t1, shows -")

        class Quit(Exception):
            pass

        def launch_env():
            raise Quit()

        app.launch_env = launch_env
        with self.assertRaises(D.StepError) as caught:
            journey.step_relaunch({"how": "quit"})
        self.assertIn("before the relaunch", str(caught.exception))
        self.assertEqual(app.calls[-1][1].get("check"), True)


if __name__ == "__main__":
    unittest.main()
