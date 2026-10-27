#!/usr/bin/env python3
"""Tests for mutant_catch.py, `oracle.py selftest --mutants` (p15-oracle-115).

Run: python3 -I scripts/cmux-next/oracle/mutant_catch_test.py (stdlib unittest; selftest.py runs it too).
A fake runner stands in for linux_run.sh and fleet.py: it reads the command the backend built and writes the
comparison.json that oracle.compare_views would, so the commands, the judging, the ladder, the gate and the
outputs are tested together without a build.
"""

from __future__ import annotations

import io
import json
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path
from typing import Dict, List, Optional, Sequence

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import mutant_catch as mc  # noqa: E402
import oracle  # noqa: E402
import patch_mutants  # noqa: E402

SHA = "0" * 40


def case(case_id: str, *methods: str, requires: Sequence[str] = ("resource_api",),
         platforms: Sequence[str] = ("linux", "mac")) -> oracle.Case:
    steps = [{"id": f"s{i}", "op": "action.run" if "." not in m else "resource.call",
              "args": {"action": m} if "." not in m else {"method": m}} for i, m in enumerate(methods)]
    data = {"id": case_id.split("/", 1)[1], "steps": steps, "requires": list(requires), "platforms": list(platforms)}
    return oracle.Case(case_id, case_id.split("/", 1)[0], Path(case_id + ".json"), data)


def mutant(mutant_id: str, suite: str = "daemon-ops", exercises: str = "workspace.move") -> patch_mutants.Mutant:
    product, name = mutant_id.split("/")
    return patch_mutants.Mutant(product, name, Path(f"/nowhere/{product}/{name}.patch"), suite, exercises, "a fault")


def comparison(divergent: Sequence[str] = (), compared: int = 2, refused: Optional[str] = None,
               diff_exit: Optional[int] = None) -> Dict[str, object]:
    exit_code = diff_exit if diff_exit is not None else (oracle.DIFF_DIVERGENT if divergent else oracle.DIFF_OK)
    return {"schema": "cmux-oracle-comparison-v1", "divergent": list(divergent), "compared": compared,
            "refused": refused, "diff_exit": None if refused else exit_code}


class FakeRunner:
    """Answers each backend command with a comparison: `verdicts` maps (mutant name, rung label) to a comparison
    dict, `None` (the command wrote nothing), or "build-failed" (the head build receipt is missing)."""

    def __init__(self, verdicts: Dict[tuple, object]) -> None:
        self.verdicts = verdicts
        self.calls: List[List[str]] = []
        self.lock = threading.Lock()  # test bookkeeping across the run's worker threads

    def __call__(self, argv: Sequence[str], log: Path) -> int:
        argv = list(argv)
        with self.lock:
            self.calls.append(argv)
        out = Path(argv[argv.index("--out") + 1])
        patch = argv[argv.index("--mutant" if "--mutant" in argv else "--head-mutant") + 1]
        name = Path(patch).stem
        label = out.name.split("-", 1)[1]
        verdict = self.verdicts.get((name, label), comparison())
        log.write_text("fake runner\nlast line of the log\n", encoding="utf-8")
        if verdict == "build-failed":
            (out / "build-base.json").write_text("{}", encoding="utf-8")
            return 2
        if verdict is None:
            return 3
        target = out / "compare" / "comparison.json" if "--head-mutant" in argv else out / "comparison.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(verdict), encoding="utf-8")
        return 1 if verdict.get("divergent") else 0


def result(product: str, status: str, index: int = 0) -> mc.Result:
    r = mc.Result(mutant(f"{product}/m{index}"), [])
    r.status = status
    return r


class Selection(unittest.TestCase):
    CORPUS = [
        case("daemon-ops/workspace-move-ok", "workspace.create", "workspace.move"),
        case("daemon-ops/workspace-move-error", "workspace.move"),
        case("daemon-ops/tab-pin-ok", "tab.pin"),
        case("e2e/close-pane", "closePane", requires=("actions",), platforms=("mac",)),
        case("daemon-ops/gui-only", "workspace.move", requires=("gui",)),
        case("daemon-ops/mac-only", "workspace.move", platforms=("mac",)),
    ]

    def test_exercise_names_split_the_header(self) -> None:
        self.assertEqual(mc.exercise_names("closePane (layout.splitSizing even)"),
                         frozenset({"closePane", "layout.splitSizing", "even"}))
        self.assertEqual(mc.exercise_names("settings facet; splitRight, splitDown"),
                         frozenset({"settings", "facet", "splitRight", "splitDown"}))

    def test_the_exercising_rung_comes_first_and_holds_only_runnable_callers(self) -> None:
        rungs = mc.ladder(mutant("daemon/move"), self.CORPUS)
        self.assertEqual([r.label for r in rungs], ["exercising", "suite"])
        self.assertEqual(rungs[0].cases, ("daemon-ops/workspace-move-error", "daemon-ops/workspace-move-ok"))
        self.assertEqual((rungs[0].suite, rungs[0].filtered), ("all", True))
        self.assertEqual(rungs[1].cases, ("daemon-ops/tab-pin-ok", "daemon-ops/workspace-move-error",
                                          "daemon-ops/workspace-move-ok"))
        self.assertEqual((rungs[1].suite, rungs[1].filtered, rungs[1].filter_arg()), ("daemon-ops", False, []))

    def test_a_rung_that_repeats_the_one_before_is_left_out(self) -> None:
        corpus = [case("daemon-ops/workspace-move-ok", "workspace.move")]
        self.assertEqual([r.label for r in mc.ladder(mutant("daemon/move"), corpus)], ["exercising"])

    def test_an_app_mutant_finds_its_callers_in_any_suite(self) -> None:
        rungs = mc.ladder(mutant("app/close", suite="actions", exercises="closePane"), self.CORPUS)
        self.assertEqual([(r.label, r.cases) for r in rungs], [("exercising", ("e2e/close-pane",))])

    def test_no_caller_and_an_empty_suite_is_no_rung(self) -> None:
        self.assertEqual(mc.ladder(mutant("app/x", suite="actions", exercises="equalizeSplits"), self.CORPUS), [])

    def test_the_filter_names_each_case_exactly(self) -> None:
        rung = mc.Rung("exercising", "all", ("e2e/a[1]", "e2e/b"), filtered=True)
        self.assertEqual(rung.filter_arg(), ["--filter", "e2e/a[[]1],e2e/b"])

    def test_every_checked_in_daemon_mutant_has_an_exercising_rung(self) -> None:
        mutants, errors = patch_mutants.load()
        self.assertEqual(errors, [])
        cases, case_errors = oracle.load_corpus(oracle.DEFAULT_CORPUS)
        self.assertEqual(case_errors, [])
        for m in mutants:
            if m.product == "daemon":
                rungs = mc.ladder(m, cases)
                self.assertTrue(rungs and rungs[0].label == "exercising", m.id)
                self.assertTrue(all(cid.startswith("daemon-ops/") for cid in rungs[0].cases), m.id)


class Judging(unittest.TestCase):
    def judge(self, document: object) -> mc.Outcome:
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "comparison.json"
            if document is not None:
                path.write_text(json.dumps(document), encoding="utf-8")
            return mc.judge_comparison(path)

    def test_a_divergent_case_is_a_catch(self) -> None:
        outcome = self.judge(comparison(["daemon-ops/a"], compared=3))
        self.assertEqual((outcome.status, outcome.divergent, outcome.compared), (mc.CAUGHT, ("daemon-ops/a",), 3))

    def test_compared_cases_and_no_divergence_survive(self) -> None:
        self.assertEqual(self.judge(comparison()).status, mc.SURVIVED)

    def test_no_evidence_is_unmeasured(self) -> None:
        for name, document in {"missing": None, "refused": comparison(refused="host-mismatch: os"),
                               "nothing compared": comparison(compared=0),
                               "internal error": comparison(diff_exit=oracle.DIFF_INTERNAL),
                               "not an object": [1]}.items():
            with self.subTest(name):
                self.assertEqual(self.judge(document).status, mc.UNMEASURED)


class Measuring(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.out = Path(self.tmp.name)
        self.rungs = [mc.Rung("exercising", "all", ("daemon-ops/a",), True),
                      mc.Rung("suite", "daemon-ops", ("daemon-ops/a", "daemon-ops/b"), False)]

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def measure(self, verdicts: Dict[tuple, object], apply_error: Optional[str] = None) -> tuple:
        runner = FakeRunner(verdicts)
        backend = mc.VmBackend(runner, system="Linux")
        return mc.measure(mutant("daemon/m"), self.rungs, SHA, backend, self.out, apply_error), runner

    def test_the_first_catch_ends_the_search(self) -> None:
        result, runner = self.measure({("m", "exercising"): comparison(["daemon-ops/a"])})
        self.assertEqual((result.status, result.catcher.label, len(runner.calls)), (mc.CAUGHT, "exercising", 1))

    def test_a_larger_rung_runs_when_the_smaller_survives(self) -> None:
        result, runner = self.measure({("m", "suite"): comparison(["daemon-ops/b"])})
        self.assertEqual((result.status, result.catcher.label, len(runner.calls)), (mc.CAUGHT, "suite", 2))
        self.assertEqual([t["status"] for t in result.tried], [mc.SURVIVED, mc.CAUGHT])

    def test_every_rung_surviving_is_a_miss(self) -> None:
        result, _ = self.measure({})
        self.assertEqual(result.status, mc.MISSED)
        self.assertIn("exercising (1 cases)", result.reason)

    def test_an_unmeasured_rung_and_no_catch_is_unmeasured(self) -> None:
        result, _ = self.measure({("m", "exercising"): None})
        self.assertEqual(result.status, mc.UNMEASURED)
        self.assertIn("last line of the log", result.reason)

    def test_an_unmeasured_rung_then_a_catch_is_a_catch(self) -> None:
        result, _ = self.measure({("m", "exercising"): None, ("m", "suite"): comparison(["daemon-ops/a"])})
        self.assertEqual(result.status, mc.CAUGHT)

    def test_a_head_build_failure_is_unviable_and_stops(self) -> None:
        result, runner = self.measure({("m", "exercising"): "build-failed"})
        self.assertEqual((result.status, len(runner.calls)), (mc.UNVIABLE, 1))

    def test_a_patch_that_does_not_apply_runs_nothing(self) -> None:
        result, runner = self.measure({}, apply_error="does not apply at 000000000000")
        self.assertEqual((result.status, runner.calls), (mc.UNVIABLE, []))

    def test_no_rung_is_a_miss_that_names_the_calls(self) -> None:
        result = mc.measure(mutant("daemon/m", exercises="pane.zoom"), [], SHA, mc.VmBackend(FakeRunner({})), self.out)
        self.assertEqual(result.status, mc.MISSED)
        self.assertIn("pane.zoom", result.reason)

    def test_the_daemon_backend_runs_only_on_linux(self) -> None:
        runner = FakeRunner({})
        result = mc.measure(mutant("daemon/m"), self.rungs, SHA, mc.VmBackend(runner, system="Darwin"), self.out)
        self.assertEqual((result.status, runner.calls), (mc.UNMEASURED, []))


class Commands(unittest.TestCase):
    RUNG = mc.Rung("exercising", "all", ("daemon-ops/a", "daemon-ops/b"), True)

    def test_the_vm_command_is_one_linux_run_diff_of_the_sha_against_itself(self) -> None:
        argv = mc.VmBackend(system="Linux").command(mutant("daemon/m"), self.RUNG, SHA, Path("/tmp/x"))
        self.assertEqual(argv[:6], ["bash", str(mc.LINUX_RUN), "diff", SHA, SHA, "--mutant"])
        self.assertEqual(argv[argv.index("--") + 1:],
                         ["--retry-limit", str(oracle.DEFAULT_RETRY_LIMIT), "--filter", "daemon-ops/a,daemon-ops/b"])
        self.assertEqual(argv[argv.index("--suite") + 1], "all")

    def test_the_fleet_command_names_the_patch_in_the_tree(self) -> None:
        app = next(m for m in patch_mutants.load()[0] if m.product == "app")
        argv = mc.FleetBackend().command(app, self.RUNG, SHA, Path("/tmp/x"))
        self.assertEqual(argv[argv.index("--head-mutant") + 1], f"tests/oracle/mutants/app/{app.name}.patch")
        self.assertEqual((argv[argv.index("--base") + 1], argv[argv.index("--head") + 1]), (SHA, SHA))
        self.assertEqual(argv[argv.index("--retry-limit") + 1], str(oracle.DEFAULT_RETRY_LIMIT))
        self.assertEqual(mc.FleetBackend().comparison(Path("/o")), Path("/o/compare/comparison.json"))


class Gate(unittest.TestCase):
    def results(self, daemon: Sequence[str], app: Sequence[str]) -> List[mc.Result]:
        return ([result("daemon", s, i) for i, s in enumerate(daemon)]
                + [result("app", s, i) for i, s in enumerate(app)])

    def verdict(self, results: Sequence[mc.Result], full=("daemon", "app"), subset=False) -> str:
        return mc.verdict_of(mc.requirements(results, full_products=full, subset=subset))

    def test_at_least(self) -> None:
        self.assertEqual([mc.at_least(mc.TOTAL_RATE, 20), mc.at_least(mc.PRODUCT_RATE, 10),
                          mc.at_least(mc.PRODUCT_RATE, 7)], [19, 9, 7])

    def test_nineteen_of_twenty_pass(self) -> None:
        self.assertEqual(self.verdict(self.results([mc.CAUGHT] * 10, [mc.CAUGHT] * 9 + [mc.MISSED])), mc.PASS)

    def test_eighteen_of_twenty_fail(self) -> None:
        self.assertEqual(self.verdict(self.results([mc.CAUGHT] * 9 + [mc.MISSED], [mc.CAUGHT] * 9 + [mc.UNVIABLE])),
                         mc.FAIL)

    def test_a_product_below_nine_of_ten_fails(self) -> None:
        results = self.results([mc.CAUGHT] * 8 + [mc.MISSED] * 2, [mc.CAUGHT] * 10)
        reqs = mc.requirements(results, full_products=("daemon", "app"), subset=False)
        self.assertEqual({r.scope: r.verdict for r in reqs}, {"daemon": mc.FAIL, "app": mc.PASS, "all": mc.FAIL})

    def test_unmeasured_mutants_leave_it_undecided_only_when_they_could_change_it(self) -> None:
        undecided = self.results([mc.CAUGHT] * 10, [mc.CAUGHT] * 8 + [mc.UNMEASURED, mc.MISSED])
        self.assertEqual(self.verdict(undecided), mc.UNDECIDED)
        failed = self.results([mc.CAUGHT] * 10, [mc.CAUGHT] * 7 + [mc.UNMEASURED, mc.MISSED, mc.MISSED])
        self.assertEqual(self.verdict(failed), mc.FAIL)
        passed = self.results([mc.CAUGHT] * 10, [mc.CAUGHT] * 9 + [mc.UNMEASURED])
        self.assertEqual(self.verdict(passed), mc.PASS)

    def test_one_product_is_held_at_nine_of_ten(self) -> None:
        reqs = mc.requirements(self.results([mc.CAUGHT] * 9 + [mc.MISSED], []), full_products=("daemon",),
                               subset=False)
        self.assertEqual([(r.scope, r.need, r.of, r.verdict) for r in reqs], [("daemon", 9, 10, mc.PASS)])

    def test_a_subset_needs_every_mutant(self) -> None:
        self.assertEqual(self.verdict(self.results([mc.CAUGHT, mc.MISSED], []), full=(), subset=True), mc.FAIL)
        self.assertEqual(self.verdict(self.results([mc.CAUGHT], []), full=(), subset=True), mc.PASS)


class EndToEnd(unittest.TestCase):
    """run() over the checked-in mutants and corpus at HEAD, with the fake runner behind both backends."""

    def run_all(self, verdicts: Dict[tuple, object], **kwargs) -> tuple:
        runner = FakeRunner(verdicts)
        backends = {"daemon": mc.VmBackend(runner, system="Linux"), "app": mc.FleetBackend(runner)}
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        out = Path(tmp.name)
        options = dict(ref="HEAD", products=patch_mutants.PRODUCTS, globs=(), root=patch_mutants.DEFAULT_ROOT,
                       corpus=oracle.DEFAULT_CORPUS, out=out, gaps_out=None, jobs=4, dry_run=False,
                       backends=backends, expected_per_product=patch_mutants.EXPECTED_PER_PRODUCT)
        options.update(kwargs)
        lines: List[str] = []
        code, document = mc.run(log=lines.append, **options)
        return code, document, out, runner, lines

    def catch_everything(self) -> Dict[tuple, object]:
        mutants, _ = patch_mutants.load()
        return {(m.name, label): comparison([f"x/{m.name}"]) for m in mutants for label in ("exercising", "suite")}

    def test_the_outputs_name_each_mutant_and_each_gap(self) -> None:
        code, document, out, runner, lines = self.run_all(self.catch_everything())
        statuses = {m["id"]: m["status"] for m in document["mutants"]}
        self.assertEqual(len(statuses), 20)
        # Only the mutants that a case calls ran; the others are corpus gaps with no run.
        ran = {Path(argv[argv.index("--mutant" if "--mutant" in argv else "--head-mutant") + 1]).stem
               for argv in runner.calls}
        for mutant_id, status in statuses.items():
            name = mutant_id.split("/")[1]
            self.assertEqual(status, mc.CAUGHT if name in ran else mc.MISSED, mutant_id)
        self.assertTrue(all(statuses[m] == mc.CAUGHT for m in statuses if m.startswith("daemon/")))
        gaps = [json.loads(line) for line in (out / "corpus-gaps.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(sorted(g["mutant"] for g in gaps), sorted(m for m, s in statuses.items() if s == mc.MISSED))
        for gap in gaps:
            self.assertEqual((gap["queue"], gap["kind"], gap["schema"]), (mc.QUEUE, "corpus-gap", mc.GAP_SCHEMA))
        written = json.loads((out / "mutants.json").read_text(encoding="utf-8"))
        self.assertEqual(written["schema"], mc.SCHEMA)
        self.assertEqual(written["exit"], code)
        missed = sum(s != mc.CAUGHT for s in statuses.values())
        self.assertEqual(code, mc.EXIT_PASS if missed <= 1 else mc.EXIT_FAIL)
        self.assertTrue(any(line.startswith("mutants: ") for line in lines))

    def test_a_missed_daemon_mutant_files_one_corpus_gap(self) -> None:
        verdicts = self.catch_everything()
        verdicts.pop(("workspace-move-lands-left", "exercising"))
        verdicts.pop(("workspace-move-lands-left", "suite"))
        code, document, out, runner, _ = self.run_all(verdicts, products=("daemon",))
        self.assertEqual(code, mc.EXIT_PASS)  # 9/10
        gaps = [json.loads(line) for line in (out / "corpus-gaps.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual([(g["mutant"], g["suite"], g["kind"]) for g in gaps],
                         [("daemon/workspace-move-lands-left", "daemon-ops", "corpus-gap")])
        self.assertEqual(len([a for a in runner.calls if "workspace-move-lands-left" in " ".join(a)]), 2)

    def test_a_selected_subset_needs_every_mutant(self) -> None:
        code, document, _, _, _ = self.run_all({}, globs=("daemon/workspace-*",))
        self.assertEqual([m["id"] for m in document["mutants"]],
                         ["daemon/workspace-move-lands-left", "daemon/workspace-rename-drops-last-char"])
        self.assertEqual((code, document["gate"]["verdict"]), (mc.EXIT_FAIL, mc.FAIL))

    def test_a_dry_run_runs_nothing(self) -> None:
        code, document, out, runner, lines = self.run_all({}, dry_run=True)
        self.assertEqual((code, runner.calls, document["dryRun"]), (mc.EXIT_PASS, [], True))
        self.assertTrue(any("linux_run.sh diff" in line for line in lines))
        self.assertFalse((out / "mutants.json").exists())

    def test_the_cli_refuses_an_out_dir_in_the_checkout(self) -> None:
        err = io.StringIO()
        with redirect_stdout(io.StringIO()), redirect_stderr(err):
            code = mc.main(["--dry-run", "--out", str(oracle.REPO / "oracle-out")], backends={})
        self.assertEqual(code, mc.EXIT_USAGE)
        self.assertIn("outside the checkout", err.getvalue())


if __name__ == "__main__":
    unittest.main()
