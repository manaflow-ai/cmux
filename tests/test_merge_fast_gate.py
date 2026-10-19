"""scripts/ci/merge_fast_gate.py against a fake PR: no network, no sleeping."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("merge_fast_gate", ROOT / "scripts/ci/merge_fast_gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
HEAD = "a" * 40


def check(name, status="COMPLETED", conclusion="SUCCESS", started=None, completed=None):
    return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion,
            "startedAt": started, "completedAt": completed}


class Reader:
    """Returns one rollup per poll; the last one repeats."""

    def __init__(self, *polls, files=("Packages/macOS/CmuxNext/Sources/A.swift",), head=HEAD):
        self.polls, self.files, self.head, self.calls = list(polls), files, head, 0

    def __call__(self, *args):
        self.calls += 1
        rollup = self.polls[min(self.calls, len(self.polls)) - 1]
        return {"headRefOid": self.head, "files": [{"path": f} for f in self.files], "statusCheckRollup": rollup}


class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += seconds


def run(reader, timeout=600, covered=True):
    clock = Clock()
    return gate.run("manaflow-ai/cmux", "42", HEAD, timeout, 30, covered, read=reader, clock=clock, sleep=clock.sleep)


GREEN = [check("cmux-next path routing"), check("cmux-next fast tier"), check("cmux-next Swift canary"),
         check("cmux app scheme compile (Debug)", conclusion="SKIPPED"), check("cmux-next swift test", "IN_PROGRESS", "")]


class FastGate(unittest.TestCase):
    def test_passes_when_the_fast_lanes_are_green_while_the_full_suites_run(self):
        waited, seen, reds = run(Reader(GREEN))
        self.assertEqual(waited, 0)
        self.assertEqual(seen, ["cmux-next Swift canary", "cmux-next fast tier", "cmux-next path routing"])
        self.assertEqual(reds, [])

    def test_waits_for_routing_then_the_fast_tier(self):
        polls = ([], [check("cmux-next path routing", "IN_PROGRESS", "")],
                 [check("cmux-next path routing")], [check("cmux-next path routing"), check("cmux-next fast tier")])
        reader = Reader(*polls)
        waited, seen, _ = run(reader)
        self.assertEqual(reader.calls, 4)
        self.assertEqual(waited, 90)
        self.assertIn("cmux-next fast tier", seen)

    def test_a_change_outside_cmux_next_and_webviews_needs_no_lane(self):
        waited, seen, reds = run(Reader([], files=("docs/README.md",)), covered=False)
        self.assertEqual((waited, seen, reds), (0, [], []))

    def test_a_webviews_change_waits_for_react_apps_check(self):
        reader = Reader([], [check("web / react-apps-check", "IN_PROGRESS", "")], [check("web / react-apps-check")],
                        files=("webviews/src/a.ts",))
        waited, seen, _ = run(reader, covered=False)
        self.assertEqual(seen, ["web / react-apps-check"])
        self.assertEqual(waited, 60)

    def test_completed_reds_in_fast_lanes_and_gating_families_are_reported_pending_ones_are_not(self):
        rollup = GREEN + [check("cmux-next checks (god files, concurrency, crash safety, l10n)", conclusion="FAILURE"),
                          check("app-size", conclusion="FAILURE"), check("render (head, 0)", conclusion="FAILURE"),
                          check("web / Web status", "IN_PROGRESS", "")]
        rollup[1] = check("cmux-next fast tier", conclusion="FAILURE")
        _, _, reds = run(Reader(rollup))
        self.assertEqual(reds, ["app-size", "cmux-next checks (god files, concurrency, crash safety, l10n)", "cmux-next fast tier"])

    def test_a_rerun_replaces_the_earlier_verdict(self):
        rollup = GREEN + [check("cmux-next fast tier", conclusion="FAILURE"), check("cmux-next fast tier")]
        rollup.pop(1)
        _, _, reds = run(Reader(rollup))
        self.assertEqual(reds, [])

    def test_the_latest_started_run_wins_whatever_the_rollup_order(self):
        """The rollup is not ordered by time: an older green listed after a newer red must not hide it."""
        for newer in ("CANCELLED", "FAILURE"):
            with self.subTest(newer=newer):
                rollup = [c for c in GREEN if c["name"] != "cmux-next fast tier"] + [
                    check("cmux-next fast tier", conclusion=newer, started="2026-10-14T10:05:00Z", completed="2026-10-14T10:09:00Z"),
                    check("cmux-next fast tier", started="2026-10-14T09:00:00Z", completed="2026-10-14T09:04:00Z")]
                _, _, reds = run(Reader(rollup))
                self.assertEqual(reds, ["cmux-next fast tier"])
        # Equal start times fall back to completedAt, then list order.
        rollup = [c for c in GREEN if c["name"] != "cmux-next fast tier"] + [
            check("cmux-next fast tier", conclusion="FAILURE", started="2026-10-14T10:00:00Z", completed="2026-10-14T10:09:00Z"),
            check("cmux-next fast tier", started="2026-10-14T10:00:00Z", completed="2026-10-14T10:02:00Z")]
        _, _, reds = run(Reader(rollup))
        self.assertEqual(reds, ["cmux-next fast tier"])

    def test_a_webviews_change_stops_waiting_when_the_web_caller_finished_or_skipped_it(self):
        """No react-apps-check is coming once the caller job "web" finished, or react-apps-check was skipped."""
        for rollup in ([check("web")], [check("web", conclusion="SKIPPED")], [check("web / react-apps-check", conclusion="SKIPPED")]):
            with self.subTest(rollup=rollup):
                waited, _, reds = run(Reader(rollup, files=("webviews/src/a.ts",)), covered=False)
                self.assertEqual((waited, reds), (0, []))
        # A red caller with no react-apps-check is a red, not a pass.
        _, _, reds = run(Reader([check("web", conclusion="FAILURE")], files=("webviews/src/a.ts",)), covered=False)
        self.assertEqual(reds, ["web"])
        # A running caller still waits.
        with self.assertRaisesRegex(gate.Refused, "react-apps-check"):
            run(Reader([check("web", "IN_PROGRESS", "")], files=("webviews/src/a.ts",)), timeout=60, covered=False)

    def test_risk_evidence_is_waited_for_and_a_red_one_refuses(self):
        """Like the full gate (#21692): risk evidence reads only the description, so it is
        never base-red and never waived here; the risk:waived label is its waiver."""
        with self.assertRaisesRegex(gate.Refused, "still waiting on risk evidence"):
            run(Reader(GREEN + [check("risk evidence", "IN_PROGRESS", "")]), timeout=60)
        for conclusion in ("FAILURE", "CANCELLED"):
            with self.subTest(conclusion=conclusion):
                with self.assertRaisesRegex(gate.Refused, "risk evidence"):
                    run(Reader(GREEN + [check("risk evidence", conclusion=conclusion)]))
        _, seen, reds = run(Reader(GREEN + [check("risk evidence")]))
        self.assertIn("risk evidence", seen)
        self.assertEqual(reds, [])

    def test_times_out_naming_the_lane_and_refuses_a_moved_head(self):
        with self.assertRaisesRegex(gate.Refused, "still waiting on cmux-next fast tier"):
            run(Reader([check("cmux-next path routing"), check("cmux-next fast tier", "QUEUED", "")]), timeout=60)
        with self.assertRaisesRegex(gate.Refused, "head moved"):
            run(Reader(GREEN, head="b" * 40))


if __name__ == "__main__":
    unittest.main()
