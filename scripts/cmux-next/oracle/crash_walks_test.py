#!/usr/bin/env python3
"""Offline tests of crash_walks.py (p15-oracle-207): no daemon, no SDK, no build.

Run: python3 -I scripts/cmux-next/oracle/crash_walks_test.py   (or crash_walks.py --selftest)
The live test is `crash_walks.py run --binary CMUX_TUI --seeds 5000 --arms old,new` on the VM.
"""

from __future__ import annotations

import json
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Mapping, Optional

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
if str(HERE) not in sys.path:
    sys.path.insert(0, str(HERE))

import case_checks  # noqa: E402
import crash_walks as cw  # noqa: E402

CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"
DAEMON_OPS = REPO / "tests" / "oracle" / "corpus" / "daemon-ops"
CLASSES = {"workspace.create": "mutation", "tab.create_terminal": "mutation", "workspace.rename": "mutation",
           "workspace.list": "read", "session.snapshot": "read", "workspace.close": "mutation"}


def call(step_id: str, name: str, *, params: Optional[Dict[str, Any]] = None, key: Optional[str] = None,
         target: Optional[Dict[str, Any]] = None, outcome: str = "ok") -> Dict[str, Any]:
    args: Dict[str, Any] = {"method": name, "params": params or {}}
    if key:
        args["idempotencyKey"] = key
    return {"id": step_id, "op": "resource.call", "target": target or dict(cw.SELECTORS), "args": args,
            "expect": {"outcome": outcome, **({"error": "validation.invalid"} if outcome == "error" else {})}}


def walk_case(case_id: str, steps: List[Dict[str, Any]], **extra: Any) -> Dict[str, Any]:
    return {"id": case_id, "suite": "walks", "requires": ["resource_api"], "platforms": ["linux", "mac"],
            "fixture": {"seed": f"walks.{case_id}", "network": "offline", "clock": "virtual"}, "steps": steps,
            **extra}


def sample_walk() -> cw.Walk:
    ws = "$step:ws#/value/workspace_id"
    return cw.Walk("walks/sample", walk_case("sample", [
        call("ws", "workspace.create", params={"initial_content": "terminal"}, key="k.ws"),
        call("list", "workspace.list"),
        call("rename", "workspace.rename", params={"name": "a"}, key="k.rename",
             target={**cw.SELECTORS, "workspace": ws}),
        call("bad", "workspace.rename", params={"name": ""}, outcome="error",
             target={**cw.SELECTORS, "workspace": ws}),
        call("rename-2", "workspace.rename", params={"name": "b"}, key="k.rename-2",
             target={**cw.SELECTORS, "workspace": ws}),
    ]))


def schema_errors(case: Mapping[str, Any]) -> List[str]:
    import jsonschema  # noqa: PLC0415 - optional: the corpus check (oracle.py check) has its own validator

    schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
    validator = jsonschema.Draft202012Validator(schema)
    return [f"{'/'.join(map(str, e.absolute_path))}: {e.message}" for e in validator.iter_errors(case)]


def has_jsonschema() -> bool:
    try:
        import jsonschema  # noqa: F401,PLC0415
    except ImportError:
        return False
    return True


class PlanTests(unittest.TestCase):
    def test_the_same_seed_gives_the_same_crash_walk(self) -> None:
        walks = [sample_walk()]
        self.assertEqual(cw.plan(7, walks, CLASSES), cw.plan(7, walks, CLASSES))
        points = {cw.plan(seed, walks, CLASSES) for seed in range(200)}
        self.assertGreater(len({p.index for p in points}), 1)
        self.assertEqual({p.fault for p in points}, {cw.SIGKILL, cw.OWNER_PANIC, cw.HOST_ABORT})

    def test_the_plan_does_not_depend_on_the_order_walks_are_found(self) -> None:
        other = cw.Walk("walks/other", walk_case("other", [call("only", "workspace.create", key="k")]))
        a = cw.plan(3, sorted([sample_walk(), other], key=lambda w: w.id), CLASSES)
        walks, _ = self.loaded_from_files([other.case, sample_walk().case])
        self.assertEqual(a, cw.plan(3, walks, CLASSES))

    def loaded_from_files(self, cases: List[Mapping[str, Any]]):
        with tempfile.TemporaryDirectory() as tmp:
            for case in reversed(cases):
                Path(tmp, f"{case['id']}.json").write_text(json.dumps(case), encoding="utf-8")
            return cw.load_walks([Path(tmp)], "linux")

    def test_a_kill_follows_an_acknowledged_mutation(self) -> None:
        walk = sample_walk()
        self.assertEqual(cw.kill_candidates(walk.steps, CLASSES), [0, 2, 3, 4])
        for seed in range(100):
            point = cw.plan(seed, [walk], CLASSES)
            self.assertEqual(CLASSES[cw.method(walk.steps[point.index])], "mutation")
            self.assertEqual(point.after, walk.steps[point.index]["id"])

    def test_reads_are_kill_points_only_in_a_walk_without_mutations(self) -> None:
        steps = [call("a", "workspace.list"), call("b", "session.snapshot")]
        self.assertEqual(cw.kill_candidates(steps, CLASSES), [0, 1])

    def test_a_kill_point_has_the_daemon_running(self) -> None:
        steps = [call("a", "workspace.create", key="a"), {"id": "k", "op": "kill", "target": {"process": "daemon"}},
                 {"id": "r", "op": "restart", "target": {"process": "daemon"}}, call("b", "workspace.create", key="b"),
                 {**call("end", "workspace.create", key="e"), "ends": "daemon"}]
        self.assertEqual(cw.running_after(steps), [True, False, True, True, False])
        self.assertEqual(cw.kill_candidates(steps, CLASSES), [0, 3])
        self.assertIsNone(cw.running_after([steps[1], steps[0]]))

    def test_host_abort_needs_exactly_one_terminal(self) -> None:
        one = [call("ws", "workspace.create", params={"initial_content": "terminal"})]
        self.assertTrue(cw.terminal_count_is_one(one))
        self.assertFalse(cw.terminal_count_is_one(one * 2))
        self.assertFalse(cw.terminal_count_is_one([*one, call("s", "pane.split")]))
        self.assertFalse(cw.terminal_count_is_one([*one, call("c", "workspace.close")]))
        self.assertFalse(cw.terminal_count_is_one([call("ws", "workspace.create")]))
        walk = cw.Walk("walks/two", walk_case("two", [*one, call("t", "tab.create_terminal", key="t")]))
        for seed in range(100):
            point = cw.plan(seed, [walk], CLASSES)
            if point.index == 1:
                self.assertNotEqual(point.fault, cw.HOST_ABORT)

    def test_a_restricted_fault_set_is_honored(self) -> None:
        for seed in range(100):
            self.assertEqual(cw.plan(seed, [sample_walk()], CLASSES, (cw.SIGKILL,)).fault, cw.SIGKILL)
        with self.assertRaises(cw.CrashWalkError):
            cw.plan(0, [], CLASSES)

    def test_a_walk_with_an_expectation_is_left_out(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "Expectations.d").mkdir()
            (root / "Expectations.d" / "walks.txt").write_text(
                "p15-oracle-999 [ new ] walks/sample [ Failure ]\n", encoding="utf-8")
            expected = cw.expected_cases(root)
            self.assertIn("p15-oracle-999", expected["walks/sample"])
            Path(tmp, "sample.json").write_text(json.dumps(sample_walk().case), encoding="utf-8")
            walks, skipped = cw.load_walks([Path(tmp, "sample.json")], "linux", expected)
        self.assertEqual(walks, [])
        self.assertIn("expected", skipped["walks/sample"])
        self.assertIn("daemon-ops/credential-rotate-ok", cw.expected_cases())

    def test_unusable_cases_are_left_out_with_a_reason(self) -> None:
        self.assertIn("git_repo", cw.usable({**walk_case("g", []), "requires": ["git_repo"]}, "linux"))
        self.assertIn("daemon driver", cw.usable(walk_case("k", [{"id": "x", "op": "key"}]), "linux"))
        self.assertIn("crash case", cw.usable({**walk_case("c", []), "suite": "crash"}, "linux"))
        self.assertIn("not on mac", cw.usable({**walk_case("l", []), "platforms": ["linux"]}, "mac"))
        self.assertIsNone(cw.usable(sample_walk().case, "linux"))


class CaseTests(unittest.TestCase):
    def point(self, index: int, fault: str = cw.SIGKILL) -> cw.KillPoint:
        walk = sample_walk()
        return cw.KillPoint(1, walk.id, index, walk.steps[index]["id"], fault)

    def test_the_crash_steps_follow_the_kill_point(self) -> None:
        case = cw.crash_case(sample_walk(), self.point(2), CLASSES)
        ids = [step["id"] for step in case["steps"]]
        self.assertEqual(ids, ["ws", "list", "rename", cw.ACKED, cw.KILL, cw.RECOVER, cw.RECOVERED, cw.REPLAY])
        steps = {step["id"]: step for step in case["steps"]}
        self.assertEqual(steps[cw.RECOVERED]["expect"]["result"], f"$step:{cw.ACKED}#")
        self.assertIn("/session/generation", steps[cw.RECOVERED]["expect"]["resultExcept"])
        self.assertTrue(steps[cw.ACKED]["readOnly"] and steps[cw.RECOVERED]["readOnly"])
        self.assertEqual(steps[cw.REPLAY]["args"]["idempotencyKey"], "k.rename")
        self.assertEqual(steps[cw.REPLAY]["expect"]["result"], "$step:rename#")
        self.assertEqual(steps[cw.KILL]["args"], {"signal": "KILL"})
        self.assertEqual(steps[cw.RECOVER]["waitFor"]["equals"], "running")
        self.assertIn(cw.HOLDER_SWITCH, case["switches"])
        self.assertEqual(case["allow_crashes"][-1]["steps"], [cw.KILL])

    def test_the_replay_is_the_last_acknowledged_mutation_with_a_key(self) -> None:
        # Kill after the failing call: the last acknowledged success is `rename`.
        case = cw.crash_case(sample_walk(), self.point(3), CLASSES)
        replay = next(step for step in case["steps"] if step["id"] == cw.REPLAY)
        self.assertEqual(replay["expect"]["result"], "$step:rename#")

    def test_host_abort_kills_the_terminal_host_then_the_owner(self) -> None:
        case = cw.crash_case(sample_walk(), self.point(0, cw.HOST_ABORT), CLASSES)
        ids = [step["id"] for step in case["steps"]]
        self.assertEqual(ids[1:4], [cw.ACKED, cw.ABORT, cw.KILL])
        abort = case["steps"][2]
        self.assertEqual((abort["target"], abort["args"]), ({"process": "holder"}, {"signal": "ABRT"}))
        self.assertEqual({e["kind"] for e in case["allow_crashes"]}, {"daemon", "holder"})

    def test_kept_steps_bring_what_they_reference(self) -> None:
        walk = sample_walk()
        self.assertEqual(cw.closure(walk.steps, [4]), [0, 4])
        case = cw.crash_case(walk, self.point(4), CLASSES, keep=[1])
        self.assertEqual([s["id"] for s in case["steps"][:3]], ["ws", "list", "rename-2"])

    def test_a_kill_point_on_another_walk_is_refused(self) -> None:
        point = cw.KillPoint(1, "walks/else", 0, "ws", cw.SIGKILL)
        with self.assertRaises(cw.CrashWalkError):
            cw.crash_case(sample_walk(), point, CLASSES)

    def test_the_walks_allow_crashes_keep_only_kept_steps(self) -> None:
        walk = cw.Walk("walks/k", walk_case("k", [
            call("a", "workspace.create", key="a"), {"id": "k", "op": "kill", "target": {"process": "daemon"}},
            {"id": "r", "op": "restart", "target": {"process": "daemon"}}, call("b", "workspace.create", key="b"),
        ], allow_crashes=[{"kind": "daemon", "reason": "the walk kills it", "steps": ["k"]}]))
        point = cw.KillPoint(1, walk.id, 3, "b", cw.SIGKILL)
        kept = cw.crash_case(walk, point, CLASSES, keep=[])
        self.assertEqual([e["steps"] for e in kept["allow_crashes"]], [[cw.KILL]])
        whole = cw.crash_case(walk, point, CLASSES)
        self.assertEqual([e["steps"] for e in whole["allow_crashes"]], [["k"], [cw.KILL]])

    @unittest.skipUnless(has_jsonschema(), "jsonschema is not installed")
    def test_crash_cases_of_the_daemon_ops_walks_are_valid_case_v1(self) -> None:
        walks, _ = cw.load_walks([DAEMON_OPS], "linux")
        self.assertGreater(len(walks), 100)
        classes = cw.operation_classes()
        rules = case_checks.Rules(json.loads(CASE_SCHEMA.read_text(encoding="utf-8")))
        by_id = {walk.id: walk for walk in walks}
        faults = set()
        for seed in range(300):
            point = cw.plan(seed, walks, classes)
            faults.add(point.fault)
            case = cw.crash_case(by_id[point.walk], point, classes)
            self.assertEqual(schema_errors(case), [], point)
            self.assertEqual(case_checks.check_case(case, rules), [], point)
        self.assertEqual(faults, set(cw.FAULTS))


class DdminTests(unittest.TestCase):
    def test_it_finds_the_two_steps_that_fail_together(self) -> None:
        asked: List[List[int]] = []

        def fails(subset: List[int]) -> bool:
            asked.append(subset)
            return {3, 7} <= set(subset)

        self.assertEqual(cw.ddmin(list(range(10)), fails), [3, 7])
        self.assertLess(len(asked), 60)

    def test_the_empty_prefix_is_asked_first(self) -> None:
        asked: List[List[int]] = []
        self.assertEqual(cw.ddmin(list(range(30)), lambda s: asked.append(s) or True), [])
        self.assertEqual(asked, [[]])

    def test_the_result_is_one_minimal(self) -> None:
        def fails(subset: List[int]) -> bool:
            return len(set(subset) & {1, 4, 9, 12}) >= 3

        found = cw.ddmin(list(range(16)), fails)
        self.assertTrue(fails(found))
        for item in found:
            self.assertFalse(fails([i for i in found if i != item]))

    def test_minimize_reduces_a_crash_walk_to_the_step_that_matters(self) -> None:
        walk = sample_walk()
        point = cw.KillPoint(1, walk.id, 4, "rename-2", cw.SIGKILL)
        runs: List[Dict[str, Any]] = []

        def run(case: Dict[str, Any]) -> Dict[str, Any]:
            runs.append(case)
            ids = {step["id"] for step in case["steps"]}
            failing = "bad" in ids
            return {"status": "Failure" if failing else "Pass", "step": cw.RECOVERED if failing else None}

        failure = cw.Failure.of({"status": "Failure", "step": cw.RECOVERED})
        kept, case = cw.minimize(walk, point, CLASSES, failure, run)
        self.assertEqual(kept, [3])
        self.assertEqual([s["id"] for s in case["steps"][:3]], ["ws", "bad", "rename-2"])
        self.assertEqual(failure.kind, "crash")

    def test_one_cause_is_one_signature(self) -> None:
        failure = cw.Failure("Failure", cw.RECOVERED)
        a = cw.signature(failure, 'result differs at /terminals/1/cwd: null, not "/tmp/o/a/000012"; I6: x 3566547')
        b = cw.signature(failure, 'result differs at /terminals/0/cwd: null, not "/tmp/o/b/000058"')
        self.assertEqual(a, b)
        self.assertNotEqual(a, cw.signature(failure, "result differs at /workspaces/0/name: null, not \"a\""))

    def test_another_failure_does_not_count(self) -> None:
        failure = cw.Failure("Failure", cw.RECOVERED)
        self.assertNotEqual(cw.Failure.of({"status": "Crash", "step": cw.RECOVERED}), failure)
        self.assertNotEqual(cw.Failure.of({"status": "Failure", "step": cw.REPLAY}), failure)
        self.assertIsNone(cw.Failure.of({"status": "Skip"}))
        self.assertEqual(cw.Failure("Timeout", "ws").kind, "walk")


class CorpusTests(unittest.TestCase):
    def test_write_case_records_the_kill_point_and_coverage(self) -> None:
        walk = sample_walk()
        point = cw.KillPoint(4, walk.id, 2, "rename", cw.OWNER_PANIC)
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp)
            case = cw.crash_case(walk, point, CLASSES)
            cw.write_case(out, point, case, walk, {"arm": "new", "status": "Failure"})
            self.assertEqual(json.loads((out / "s4-owner-panic.json").read_text()), case)
            records = cw.read_kill_points(out)
            self.assertEqual(records["s4-owner-panic"]["after"], "rename")
            self.assertEqual(records["s4-owner-panic"]["found"]["arm"], "new")
            coverage = json.loads((out / "coverage.json").read_text())
            self.assertEqual(coverage["faults"][cw.OWNER_PANIC], ["s4-owner-panic"])
            self.assertIn(cw.HOST_ABORT, coverage["excluded"])
            self.assertEqual(coverage["missing"], [cw.SIGKILL])

    def test_the_checked_in_crash_cases_are_their_kill_points(self) -> None:
        """Each generated case of tests/oracle/corpus/crash is what its recorded kill point builds today."""
        records = cw.read_kill_points(cw.CRASH_DIR)
        if not records:
            self.skipTest("no crash corpus")
        walks, _ = cw.load_walks([DAEMON_OPS, cw.CORPUS / "walks"], "linux")
        by_id = {walk.id: walk for walk in walks}
        classes = cw.operation_classes()
        for case_id, record in records.items():
            point = cw.KillPoint(**{key: record[key] for key in ("seed", "walk", "index", "after", "fault")})
            on_disk = json.loads((cw.CRASH_DIR / f"{case_id}.json").read_text(encoding="utf-8"))
            if "found" in record:
                continue  # a minimized failure keeps the steps ddmin left
            self.assertIn(point.walk, by_id, case_id)
            self.assertEqual(on_disk, cw.crash_case(by_id[point.walk], point, classes), case_id)


def main() -> int:
    suite = unittest.defaultTestLoader.loadTestsFromModule(sys.modules[__name__])
    return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1


if __name__ == "__main__":
    sys.exit(main())
