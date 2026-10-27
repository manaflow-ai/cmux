#!/usr/bin/env python3
"""Tests for gen_walks.py and minimize.py (p15-oracle-098).

Run: python3 -I scripts/cmux-next/oracle/walks_test.py (stdlib unittest). Offline: the minimizer runs on fake
sessions here; driver_daemon_test.py's live tests run a generated walk on a real cmux-tui.
"""

from __future__ import annotations

import copy
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Callable, Dict, List

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
sys.path.insert(0, str(HERE))

import case_checks  # noqa: E402
import gen_walks as gw  # noqa: E402
import minimize as mz  # noqa: E402
import normalize  # noqa: E402

CASE_SCHEMA = json.loads((REPO / "schemas" / "oracle" / "case-v1.schema.json").read_text(encoding="utf-8"))
CASE_RULES = case_checks.Rules(CASE_SCHEMA)
WALKS = REPO / "tests" / "oracle" / "corpus" / "walks"


def case_problems(case: Dict[str, Any]) -> List[str]:
    """What `oracle.py check` runs on a case: the stdlib schema validator, then the x-oracle checks."""
    return [*normalize.validate(case, CASE_SCHEMA), *(f"{f.pointer}: {f.message}"
                                                      for f in case_checks.check_case(case, CASE_RULES))]


class GenWalksTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.table = gw.load_move_table(gw.DEFAULT_CORPUS, gw.DEFAULT_SOURCE, "daemon")

    def test_the_same_seed_gives_the_same_walk_in_any_process(self):
        self.assertEqual(gw.generate_walk(self.table, 42, 30), gw.generate_walk(self.table, 42, 30))
        outputs = set()
        for hash_seed in ("0", "1", "random"):
            env = {**os.environ, "PYTHONHASHSEED": hash_seed}
            outputs.add(subprocess.run([sys.executable, "-I", str(HERE / "gen_walks.py"), "show", "--seed", "42"],
                                       check=True, capture_output=True, text=True, env=env).stdout)
        self.assertEqual(outputs, {gw.render(gw.generate_walk(self.table, 42, 30))})

    def test_the_generator_is_pinned(self):
        """SplitMix64 of sha256("walks.daemon-ops.0"): a change here moves every walk and every minimized case.
        State 0 gives the reference outputs of Vigna's splitmix64.c."""
        rng = gw.Rng("walks.daemon-ops.0")
        self.assertEqual([rng.next64() for _ in range(3)], PINNED)
        rng.state = 0
        self.assertEqual([rng.next64() for _ in range(2)], [0xE220A8397B1DCDAF, 0x6E789E6AA1B965F4])

    def test_seeds_are_independent(self):
        walks = [gw.generate_walk(self.table, seed, 30) for seed in range(20)]
        self.assertEqual(len({json.dumps(w["steps"]) for w in walks}), 20)
        files, _ = gw.generate(self.table, (0, 3), 30)
        more, _ = gw.generate(self.table, (0, 6), 30)
        for name in ("seed-0000.json", "seed-0001.json", "seed-0002.json"):
            self.assertEqual(files[name], more[name])

    def test_every_walk_is_a_valid_case(self):
        for seed in range(60):
            walk = gw.generate_walk(self.table, seed, 30)
            self.assertEqual(case_problems(walk), [], f"seed {seed}")
            ids = [s["id"] for s in walk["steps"]]
            self.assertEqual(len(ids), len(set(ids)))
            self.assertEqual(sum(1 for i in ids if i.startswith("m")), 30)

    def test_moves_read_only_fixture_steps_and_each_fixture_step_is_needed(self):
        for seed in range(40):
            walk = gw.generate_walk(self.table, seed, 30)
            fixture = [s["id"] for s in walk["steps"] if s["id"].startswith(gw.FIXTURE_PREFIX)]
            moves = [s for s in walk["steps"] if not s["id"].startswith(gw.FIXTURE_PREFIX)]
            read = set()
            for step in moves:
                refs = gw.step_refs(step)
                self.assertTrue(all(r.startswith(gw.FIXTURE_PREFIX) for r in refs), step["id"])
                read |= refs
            self.assertEqual(set(fixture), gw.fixture_closure(read, self.table.fixture), f"seed {seed}")

    def test_a_walk_has_retries_and_every_move_is_an_any_mutation(self):
        steps = [s for seed in range(30) for s in gw.generate_walk(self.table, seed, 30)["steps"]
                 if not s["id"].startswith(gw.FIXTURE_PREFIX)]
        retries = [s for s in steps if "-retry-" in s["id"]]
        self.assertTrue(retries)
        self.assertEqual({s["op"] for s in steps}, {"resource.call"}, "a walk has no restart or kill (crash walks do)")
        keys = {s["args"]["idempotencyKey"] for s in steps if s["op"] == "resource.call" and "-retry-" not in s["id"]}
        self.assertTrue(all(s["args"]["idempotencyKey"] in keys for s in retries), "a retry reuses an earlier key")
        for step in steps:
            if step["op"] == "resource.call":
                self.assertEqual(step["expect"], {"outcome": "any", "receipt": "mutation_result"})
                self.assertEqual(step["checkpoint"], ["settled"])

    def test_exclusions_name_their_reason(self):
        excluded = self.table.excluded
        self.assertIn("session.shutdown", excluded)
        self.assertIn("ends the daemon", excluded["session.shutdown"])
        self.assertIn("browser.activate", excluded)
        moves = {m.operation for m in self.table.moves}
        self.assertFalse(moves & set(excluded))
        coverage = json.loads((gw.DEFAULT_CORPUS / gw.DEFAULT_SOURCE / gw.COVERAGE).read_text(encoding="utf-8"))
        self.assertEqual(moves | set(excluded), set(coverage["operations"]))

    def test_a_walk_with_an_operation_known_to_fail_on_an_arm_gets_that_arm_line(self):
        terminal = next(m for m in self.table.moves if m.known)
        walk = next(gw.generate_walk(self.table, seed, 30) for seed in range(200)
                    if any((s.get("args") or {}).get("method") == terminal.operation
                           for s in gw.generate_walk(self.table, seed, 30)["steps"]))
        lines = gw.walk_known(self.table, walk)
        self.assertTrue(lines)
        self.assertTrue(all(f"walks/{walk['id']}" in line and line.startswith("p") for line in lines), lines)
        self.assertTrue(set(terminal.switches) <= set(walk["switches"]))

    def test_the_checked_in_suite_is_fresh(self):
        args = ["--out", str(WALKS), "--check"]
        self.assertEqual(gw.main(args), 0)

    def test_check_finds_drift_and_write_keeps_minimized_cases(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = Path(tmp) / "corpus" / "walks"
            self.assertEqual(gw.main(["--out", str(out), "--seeds", "0:3"]), 0)
            (out / "min-seed-0001-abcdef.json").write_text("{}\n", encoding="utf-8")
            expectations = Path(tmp) / "Expectations.d" / "walks.txt"
            expectations.write_text(expectations.read_text(encoding="utf-8") + "p15-oracle-098 walks/x [ Skip ]\n",
                                    encoding="utf-8")
            self.assertEqual(gw.main(["--out", str(out), "--seeds", "0:3", "--check"]), 0)
            (out / "seed-0001.json").write_text("{}\n", encoding="utf-8")
            self.assertEqual(gw.main(["--out", str(out), "--seeds", "0:3", "--check"]), 1)
            self.assertEqual(gw.main(["--out", str(out), "--seeds", "0:2"]), 0)
            self.assertEqual(sorted(p.name for p in out.iterdir()),
                             ["coverage.json", "min-seed-0001-abcdef.json", "seed-0000.json", "seed-0001.json"])
            self.assertIn("walks/x [ Skip ]", expectations.read_text(encoding="utf-8"))


PINNED = [9726237798439235416, 8658183530636409091, 494961486071664485]


# --------------------------------------------------------------------------------------------- minimize


def fixture_step(step_id: str) -> Dict[str, Any]:
    return {"id": step_id, "op": "resource.call", "target": {"session": "current"},
            "args": {"method": "workspace.create", "params": {"name": step_id}, "idempotencyKey": f"t.{step_id}"},
            "expect": {"outcome": "ok", "receipt": "mutation_result"}}


def move_step(number: int, reads: str = "fx-a") -> Dict[str, Any]:
    step_id = f"m{number:02d}-workspace-rename"
    return {"id": step_id, "op": "resource.call",
            "target": {"session": "current", "workspace": f"$step:{reads}#/value/workspace_id"},
            "args": {"method": "workspace.rename", "params": {"name": step_id}, "idempotencyKey": f"t.{step_id}"},
            "expect": {"outcome": "any", "receipt": "mutation_result"}, "checkpoint": ["settled"]}


def synthetic_walk(moves: int = 30) -> Dict[str, Any]:
    case = gw.generate_walk(gw.load_move_table(gw.DEFAULT_CORPUS, gw.DEFAULT_SOURCE, "daemon"), 0, 1)
    case["steps"] = [fixture_step("fx-a"), fixture_step("fx-b"),
                     *[move_step(n, "fx-b" if n == 17 else "fx-a") for n in range(1, moves + 1)]]
    return case


class FakeSession:
    """A product whose run of a case is a function of its step ids: `fails` says when, and the settled snapshot of
    each step is `snapshot(step_ids_so_far)`. `random_ids` adds a checklist item whose id is new on every run (from
    the first step on), as a daemon's random ids are."""

    def __init__(self, fails: Callable[[List[str]], bool] = lambda ids: False,
                 snapshot: Callable[[List[str]], Any] = lambda ids: {"n": len(ids)}, flaky_every: int = 0,
                 random_ids: bool = False):
        self.fails, self.snapshot_of, self.flaky_every = fails, snapshot, flaky_every
        self.random_ids = random_ids
        self.runs = 0
        self.roots: List[str] = []

    def daemon_facet(self, ids: List[str], run_key: str) -> Any:
        facet = self.snapshot_of(ids)
        if self.random_ids:
            facet = {**facet, "checklist": [{"items": [{"id": f"item-{run_key}"}]}]}
        return facet

    def run_case(self, case: Dict[str, Any], ctx: Dict[str, Any]) -> Dict[str, Any]:
        self.runs += 1
        self.roots.append(ctx["state_root"])
        ids = [s["id"] for s in case["steps"]]
        checkpoints = [{"step": sid, "checkpoint": "settled",
                        "snapshot": {"facets": {"daemon": self.daemon_facet(ids[: i + 1], ctx["key"])}}}
                       for i, sid in enumerate(ids)]
        failing = self.fails(ids) and not (self.flaky_every and self.runs % self.flaky_every == 0)
        if failing:
            return {"status": "Failure", "step": ids[-1], "message": "fake", "checkpoints": checkpoints}
        return {"status": "Pass", "message": "", "checkpoints": checkpoints}


def has(*parts: str) -> Callable[[List[str]], bool]:
    return lambda ids: all(any(i.startswith(p) for i in ids) for p in parts)


class DdminTests(unittest.TestCase):
    def test_finds_the_one_minimal_pair(self):
        calls = []

        def test(subsets):
            calls.append(len(subsets))
            return [{3, 17} <= subset for subset in subsets]

        kept, tests = mz.ddmin(list(range(40)), test)
        self.assertEqual(kept, [3, 17])
        self.assertLess(tests, 120)

    def test_a_single_cause_and_no_cause(self):
        self.assertEqual(mz.ddmin(list(range(25)), lambda s: [11 in x for x in s])[0], [11])
        self.assertEqual(mz.ddmin([5], lambda s: [True for _ in s])[0], [5])

    def test_split_covers_every_item_once(self):
        for size in range(1, 30):
            for parts in range(1, size + 1):
                chunks = mz.split(list(range(size)), parts)
                self.assertEqual([i for c in chunks for i in c], list(range(size)))
                self.assertLessEqual(max(map(len, chunks)) - min(map(len, chunks)), 1)


class MinimizeTests(unittest.TestCase):
    def setUp(self):
        self.base = Path(tempfile.mkdtemp(prefix="o-"))

    def tearDown(self):
        shutil.rmtree(self.base, ignore_errors=True)

    def prober(self, *sessions, jobs=8):
        return mz.Prober(list(sessions), jobs, self.base / "m00001")

    def test_closure_keeps_what_the_kept_steps_read(self):
        case = synthetic_walk(5)
        kept = mz.candidate(case, frozenset({4}))
        self.assertEqual([s["id"] for s in kept["steps"]], ["fx-a", "m03-workspace-rename"])

    def test_a_failure_minimizes_to_its_two_moves_and_their_fixture(self):
        case = synthetic_walk()
        session = FakeSession(fails=has("m03-", "m17-"))
        outcome = mz.minimize(case, self.prober(session))
        self.assertIsNotNone(outcome.case, outcome.message)
        self.assertEqual([s["id"] for s in outcome.case["steps"]],
                         ["fx-a", "fx-b", "m03-workspace-rename", "m17-workspace-rename"])
        self.assertEqual(case_problems(outcome.case), [])
        self.assertRegex(outcome.case["id"], r"^min-seed-0000-[0-9a-f]{6}$")
        self.assertIn("minimized by", outcome.case["invariants"][-1])
        self.assertEqual(len(set(session.roots)), len(session.roots), "every run has its own state root")

    def test_the_result_does_not_depend_on_parallelism(self):
        case = synthetic_walk()
        one = mz.minimize(case, self.prober(FakeSession(fails=has("m05-", "m22-", "m29-")), jobs=1))
        many = mz.minimize(case, self.prober(FakeSession(fails=has("m05-", "m22-", "m29-")), jobs=32))
        self.assertEqual(one.case, many.case)

    def test_another_failure_on_the_way_is_not_the_original(self):
        """A candidate that fails at another step's kind is not the original failure (without --any)."""
        case = synthetic_walk(10)
        case["steps"][-1] = {**case["steps"][-1], "op": "resource.call",
                             "args": {**case["steps"][-1]["args"], "method": "workspace.close"}}

        def fails(ids):
            return has("m02-")(ids)

        outcome = mz.minimize(case, self.prober(FakeSession(fails=fails)))
        self.assertIsNotNone(outcome.case, outcome.message)
        self.assertIn("workspace.close", outcome.signature.describe())
        self.assertEqual(outcome.case["steps"][-1]["args"]["method"], "workspace.close")
        anything = mz.minimize(case, self.prober(FakeSession(fails=fails)), any_failure=True)
        self.assertEqual([s["id"] for s in anything.case["steps"]], ["fx-a", "m02-workspace-rename"])

    def test_a_flaky_original_is_refused_and_a_passing_one_has_nothing_to_do(self):
        case = synthetic_walk(8)
        flaky = mz.minimize(case, self.prober(FakeSession(fails=has("m04-"), flaky_every=2)), confirm=2)
        self.assertIsNone(flaky.case)
        self.assertIn("flaky", flaky.message)
        passing = mz.minimize(case, self.prober(FakeSession()))
        self.assertIsNone(passing.case)
        self.assertIn("passes", passing.message)

    def test_a_divergence_minimizes_to_the_step_that_makes_it(self):
        case = synthetic_walk()

        def head_snapshot(ids):
            return {"n": len(ids), "renamed": any(i.startswith("m12-") for i in ids)}

        base = FakeSession(snapshot=lambda ids: {"n": len(ids), "renamed": False})
        head = FakeSession(snapshot=head_snapshot)
        outcome = mz.minimize(case, self.prober(base, head))
        self.assertIsNotNone(outcome.case, outcome.message)
        self.assertEqual([s["id"] for s in outcome.case["steps"]], ["fx-a", "m12-workspace-rename"])
        self.assertEqual(outcome.signature.where, "resource.call workspace.rename")
        self.assertEqual(outcome.signature.pointer, "/facets/daemon/renamed")

    @staticmethod
    def renamed_on_head(ids, **extra):
        return {"n": len(ids), "renamed": any(i.startswith("m12-") for i in ids), **extra}

    def test_a_pointer_a_rule_explains_is_not_the_divergence(self):
        """`clock` differs from the first step on and sorts before `renamed`; the Expectations-style rule for the
        original case id (a candidate's min- id matches none) explains it, as it does for `oracle.py diff`."""
        case = synthetic_walk()
        base = FakeSession(snapshot=lambda ids: {"n": len(ids), "renamed": False, "clock": 0})
        head = FakeSession(snapshot=lambda ids: self.renamed_on_head(ids, clock=1))
        rule = mz.diff.Rule(pointer="/facets/daemon/clock", reason="the head reports its own clock",
                            case="walks/seed-0000", source="test")
        raw = mz.minimize(case, self.prober(base, head))
        self.assertEqual(raw.signature.pointer, "/facets/daemon/clock", "without the rule the clock comes first")
        outcome = mz.minimize(case, self.prober(FakeSession(snapshot=base.snapshot_of),
                                                FakeSession(snapshot=head.snapshot_of)), rules=[rule])
        self.assertIsNotNone(outcome.case, outcome.message)
        self.assertEqual(outcome.signature.pointer, "/facets/daemon/renamed")
        self.assertEqual([s["id"] for s in outcome.case["steps"]], ["fx-a", "m12-workspace-rename"])
        self.assertIn("from walks/seed-0000:", outcome.case["invariants"][-1])
        self.assertEqual(mz.origin_id(outcome.case), "walks/seed-0000", "a minimized case keeps its original id")

    def test_a_random_id_on_both_sides_is_noise_and_the_real_divergence_is_kept(self):
        """A checklist id that is new on every run diverges at the first step (and sorts first); the same-side
        control sees it differ between two runs of one binary, so the head-only rename is the signature."""
        case = synthetic_walk()
        base = FakeSession(snapshot=lambda ids: {"n": len(ids), "renamed": False}, random_ids=True)
        head = FakeSession(snapshot=self.renamed_on_head, random_ids=True)
        outcome = mz.minimize(case, self.prober(base, head))
        self.assertIsNotNone(outcome.case, outcome.message)
        self.assertEqual(outcome.signature.pointer, "/facets/daemon/renamed")
        self.assertEqual(outcome.signature.where, "resource.call workspace.rename")
        self.assertEqual([s["id"] for s in outcome.case["steps"]], ["fx-a", "m12-workspace-rename"])

    def test_a_case_whose_every_divergence_is_noise_is_refused(self):
        case = synthetic_walk(6)
        outcome = mz.minimize(case, self.prober(FakeSession(random_ids=True), FakeSession(random_ids=True)), confirm=1)
        self.assertIsNone(outcome.case)
        self.assertIn("noise", outcome.message)
        self.assertIn("/facets/daemon/checklist/N/items/N/id", outcome.message)

    def test_the_cli_rules_are_the_expectations_lines_and_every_expected_file(self):
        root = self.base / "root"
        (root / "Expectations.d").mkdir(parents=True)
        (root / "Expectations.d" / "walks.txt").write_text(
            "p15-oracle-185 walks/seed-0000#/facets/daemon/clock [ Failure ]\n", encoding="utf-8")
        expected = self.base / "switch.json"
        expected.write_text(json.dumps({"expected_differences": [
            {"pointer": "/facets/daemon/order", "reason": "the new arm sorts", "case": "walks/*"}]}), encoding="utf-8")
        rules = mz.load_rules([expected], root, "debug")
        self.assertEqual(sorted(r.pointer for r in rules), ["/facets/daemon/clock", "/facets/daemon/order"])
        self.assertTrue(all(r.covers("walks/seed-0000", "m01", "settled", r.pointer) for r in rules))

    def test_a_result_that_changes_on_one_binary_is_refused(self):
        case = synthetic_walk(8)
        outcome = mz.minimize(case, self.prober(FakeSession(), FakeSession(fails=has("m04-"), flaky_every=2)))
        self.assertIsNone(outcome.case)
        self.assertIn("head gives Failure, Pass on the same binary", outcome.message)

    def test_allow_crashes_keeps_only_entries_for_kept_steps(self):
        case = synthetic_walk(4)
        case["allow_crashes"] = [{"kind": "daemon", "reason": "a planned kill of the case", "steps": ["m02-workspace-rename"]},
                                 {"kind": "holder", "reason": "any holder exit in this case", "max": 1}]
        kept = mz.candidate(case, frozenset({4}))
        self.assertEqual(kept["allow_crashes"], [case["allow_crashes"][1]])

    def test_the_name_is_a_slug_and_stable(self):
        signature = mz.Signature("Failure", "resource.call workspace.rename")
        name = mz.minimized_id("x" * 80, signature)
        self.assertLessEqual(len(name), mz.SLUG_MAX)
        self.assertEqual(name, mz.minimized_id("x" * 80, signature))
        self.assertEqual(mz.minimized_id(name, signature), name)


if __name__ == "__main__":
    unittest.main()
