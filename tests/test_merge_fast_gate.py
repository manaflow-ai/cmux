"""scripts/ci/merge_fast_gate.py against a fake PR: no network, no sleeping."""
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("merge_fast_gate", ROOT / "scripts/ci/merge_fast_gate.py")
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
HEAD = "a" * 40


def check(name, status="COMPLETED", conclusion="SUCCESS"):
    return {"__typename": "CheckRun", "name": name, "status": status, "conclusion": conclusion}


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

    def test_times_out_naming_the_lane_and_refuses_a_moved_head(self):
        with self.assertRaisesRegex(gate.Refused, "still waiting on cmux-next fast tier"):
            run(Reader([check("cmux-next path routing"), check("cmux-next fast tier", "QUEUED", "")]), timeout=60)
        with self.assertRaisesRegex(gate.Refused, "head moved"):
            run(Reader(GREEN, head="b" * 40))


if __name__ == "__main__":
    unittest.main()
