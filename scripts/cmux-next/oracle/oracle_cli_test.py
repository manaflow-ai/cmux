#!/usr/bin/env python3
"""Unit tests for oracle.py: shards, retries, flaky handling, batches, shuffle and comparison.

Run: python3 -I scripts/cmux-next/oracle/oracle_cli_test.py (stdlib unittest; selftest.py,
task 019, runs it too). A fake driver stands in for the products through the driver protocol.
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

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import oracle  # noqa: E402


class FakeSession:
    def __init__(self, driver: "FakeDriver", number: int) -> None:
        self.driver = driver
        self.number = number

    def run_case(self, case, ctx):
        return self.driver.run(case, ctx, self.number)

    def close(self) -> None:
        self.driver.closed += 1


class FakeDriver:
    """`script` maps a case id to the statuses of its successive runs (the last one repeats)."""

    def __init__(self, script=None, hash_of=None, dirty=(), raises=()):
        self.script = script or {}
        self.hash_of = hash_of or (lambda cid, n: "h-" + cid)
        self.dirty = set(dirty)
        self.raises = set(raises)
        self.calls = []
        self.sessions = 0
        self.closed = 0
        self.count = {}
        self.mutex = threading.Lock()  # test-only bookkeeping across the runner's worker threads

    def open_session(self, ctx):
        with self.mutex:
            self.sessions += 1
            return FakeSession(self, self.sessions)

    def run(self, case, ctx, session):
        cid = ctx["case_id"]
        with self.mutex:
            n = self.count.get(cid, 0)
            self.count[cid] = n + 1
            self.calls.append((cid, ctx["phase"], ctx["attempt"], session, ctx))
        if cid in self.raises and n == 0:
            raise RuntimeError("driver lost the app")
        statuses = self.script.get(cid, ["Pass"])
        status = statuses[min(n, len(statuses) - 1)]
        return {
            "status": status,
            "checkpoints": [{"step": "s1", "checkpoint": "settled", "hash": self.hash_of(cid, n)}],
            "session_dirty": cid in self.dirty,
        }


def write_corpus(root: Path, suites=("alpha", "beta", "gamma"), per_suite=40, extra=None) -> Path:
    for suite in suites:
        for i in range(per_suite):
            path = root / suite / f"case-{i:03d}.json"
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(json.dumps({"id": f"{suite}/case-{i:03d}", "steps": [{"id": "s1", "op": "snapshot"}]}))
    for cid, data in (extra or {}).items():
        path = root / f"{cid}.json"
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(data))
    return root


def options(tmp: Path, **overrides) -> oracle.RunOptions:
    base = dict(
        product="daemon", suites=("all",), filters=(), shard=(0, 1), jobs=4, batch_limit=1, repeat=1,
        retry_limit=3, seed=None, platform="linux", build="debug", switch=None, arm=None, switches={},
        ref=None, tag=None, binary=None, corpus=tmp / "corpus", out=tmp / "out", state_base=Path("/tmp/o"),
        run_id="test-run",
    )
    base.update(overrides)
    return oracle.RunOptions(**base)


def quiet(fn, *args, **kwargs):
    with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        return fn(*args, **kwargs)


class ShardTests(unittest.TestCase):
    def test_shards_cover_each_case_once(self):
        ids = [f"suite{i % 7}/case-{i}" for i in range(2000)]
        for total in range(1, 9):
            shards = [{cid for cid in ids if oracle.shard_of(cid, total) == i} for i in range(total)]
            self.assertEqual(sum(len(s) for s in shards), len(ids))
            self.assertEqual(set().union(*shards), set(ids))

    def test_shard_argument(self):
        self.assertEqual(oracle.parse_shard("3/4"), (3, 4))
        for bad in ("4/4", "-1/4", "1", "a/b", "0/0"):
            with self.assertRaises(oracle.UsageError):
                oracle.parse_shard(bad)

    def test_dry_run_over_four_shards_merges_to_the_selection(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            corpus = write_corpus(tmp / "corpus")
            outs = []
            for i in range(4):
                out = tmp / f"shard{i}"
                code = quiet(oracle.main, ["run", "--dry-run", "--shard", f"{i}/4", "--corpus", str(corpus),
                                           "--out", str(out), "--run-id", f"dry{i}"])
                self.assertEqual(code, 0)
                outs.append(str(out))
            receipts = [json.loads((Path(o) / "receipt.json").read_text()) for o in outs]
            ids = [cid for r in receipts for cid in r["order"]]
            self.assertEqual(len(ids), 120)
            self.assertEqual(len(set(ids)), 120)
            self.assertEqual(quiet(oracle.main, ["merge", *outs, "--out", str(tmp / "merged")]), 0)
            merged = json.loads((tmp / "merged" / "receipt.json").read_text())
            self.assertEqual(len(merged["cases"]), 120)
            # A gap and an overlap are refused.
            self.assertEqual(quiet(oracle.main, ["merge", *outs[:3], "--out", str(tmp / "gap")]), 1)
            self.assertEqual(quiet(oracle.main, ["merge", outs[0], outs[0], outs[1], outs[2], outs[3],
                                                 "--out", str(tmp / "dup")]), 1)

    def test_merge_refuses_different_configs(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            corpus = write_corpus(tmp / "corpus", per_suite=5)
            a, b = tmp / "a", tmp / "b"
            quiet(oracle.main, ["run", "--dry-run", "--shard", "0/2", "--corpus", str(corpus), "--out", str(a)])
            quiet(oracle.main, ["run", "--dry-run", "--shard", "1/2", "--seed", "7", "--corpus", str(corpus), "--out", str(b)])
            self.assertEqual(quiet(oracle.main, ["merge", str(a), str(b), "--out", str(tmp / "m")]), 1)


class SelectionTests(unittest.TestCase):
    def test_requires_and_platforms_pick_the_product(self):
        with tempfile.TemporaryDirectory() as raw:
            corpus = write_corpus(Path(raw) / "corpus", suites=("alpha",), per_suite=2, extra={
                "alpha/gui": {"requires": ["gui"], "steps": [{"id": "s1", "op": "snapshot"}]},
                "alpha/mac-only": {"platforms": ["mac"], "steps": [{"id": "s1", "op": "snapshot"}]},
            })
            cases, errors = oracle.load_corpus(corpus)
            self.assertEqual(errors, [])
            selected, na = oracle.select_cases(cases, suites=["all"], filters=[], product="daemon", platform="linux")
            self.assertEqual(sorted(c.id for c in na), ["alpha/gui", "alpha/mac-only"])
            selected, na = oracle.select_cases(cases, suites=["alpha"], filters=[], product="app", platform="mac")
            self.assertEqual(na, [])

    def test_shuffle_is_seeded_and_keeps_the_set(self):
        with tempfile.TemporaryDirectory() as raw:
            cases, _ = oracle.load_corpus(write_corpus(Path(raw) / "corpus"))
            a = oracle.make_plan(cases, shard=(0, 1), seed=1, batch_limit=1)
            b = oracle.make_plan(cases, shard=(0, 1), seed=1, batch_limit=1)
            c = oracle.make_plan(cases, shard=(0, 1), seed=2, batch_limit=1)
            self.assertEqual([x.id for x in a.order], [x.id for x in b.order])
            self.assertNotEqual([x.id for x in a.order], [x.id for x in c.order])
            self.assertEqual(sorted(x.id for x in a.order), sorted(x.id for x in c.order))

    def test_retry_default_is_zero_for_filtered_runs(self):
        parser = oracle.build_parser()

        def retry(argv):
            args = parser.parse_args(["run", *argv])
            return oracle.options_from_args(args, retry_default=None, out=Path("/tmp/x"), run_id="r", switch=None,
                                            arm=None, switches={}, ref=None, binary=None).retry_limit

        self.assertEqual(retry([]), 3)
        self.assertEqual(retry(["--suite", "all"]), 3)
        self.assertEqual(retry(["--suite", "daemon-ops"]), 0)
        self.assertEqual(retry(["--filter", "daemon-ops/*"]), 0)
        self.assertEqual(retry(["--suite", "daemon-ops", "--retry-limit", "2"]), 2)


class RunTests(unittest.TestCase):
    def run_cases(self, driver, tmp, lookup=None, **overrides):
        cases, errors = oracle.load_corpus(tmp / "corpus")
        self.assertEqual(errors, [])
        return oracle.perform_run(options(tmp, **overrides), cases, driver.open_session, lookup, {})

    def test_pass_on_retry_is_flaky_and_does_not_fail_the_run(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=5)
            driver = FakeDriver(script={"alpha/case-001": ["Failure", "Pass"]})
            receipt, code = self.run_cases(driver, tmp)
            self.assertEqual(code, 0)
            self.assertEqual(receipt["flaky"], ["alpha/case-001"])
            self.assertIn("pass-on-retry", receipt["cases"]["alpha/case-001"]["reasons"][0])
            phases = {p for cid, p, *_ in driver.calls if cid == "alpha/case-001"}
            self.assertEqual(phases, {"run", "shard-retry"})

    def test_whole_shard_retry_then_alone_retries(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=4)
            driver = FakeDriver(script={"beta/case-002": ["Crash"]})
            receipt, code = self.run_cases(driver, tmp, batch_limit=3, jobs=2)
            self.assertEqual(code, 1)
            self.assertEqual(receipt["unexpected"], ["beta/case-002"])
            mine = [(p, a, s) for cid, p, a, s, _ in driver.calls if cid == "beta/case-002"]
            self.assertEqual([p for p, _, _ in mine], ["run", "shard-retry", "alone-retry", "alone-retry"])
            self.assertEqual([a for _, a, _ in mine], [0, 1, 2, 3])
            # The whole shard reran once; alone retries got their own sessions.
            self.assertEqual(sum(1 for _, p, *_ in driver.calls if p == "shard-retry"), 12)
            alone_sessions = [s for p, _, s in mine if p == "alone-retry"]
            self.assertEqual(len(set(alone_sessions)), 2)
            for s in alone_sessions:
                self.assertEqual([cid for cid, _, _, sess, _ in driver.calls if sess == s], ["beta/case-002"])

    def test_no_retries_when_limit_is_zero(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=2)
            driver = FakeDriver(script={"alpha/case-000": ["Failure", "Pass"]})
            receipt, code = self.run_cases(driver, tmp, retry_limit=0)
            self.assertEqual(code, 1)
            self.assertEqual(receipt["flaky"], [])
            self.assertEqual(driver.count["alpha/case-000"], 1)

    def test_hash_change_in_the_shard_retry_is_flaky(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            driver = FakeDriver(script={"alpha/case-000": ["Failure"]},
                                hash_of=lambda cid, n: f"{cid}-{n}" if cid == "alpha/case-001" else cid)
            receipt, _ = self.run_cases(driver, tmp)
            self.assertIn("alpha/case-001", receipt["flaky"])
            self.assertNotIn("alpha/case-002", receipt["flaky"])

    def test_repeat_difference_is_flaky(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            driver = FakeDriver(hash_of=lambda cid, n: f"{cid}-{n}" if cid == "alpha/case-000" else cid)
            receipt, code = self.run_cases(driver, tmp, repeat=2)
            self.assertEqual(code, 0)
            self.assertEqual(receipt["flaky"], ["alpha/case-000"])
            self.assertIn("repeat-differs", receipt["cases"]["alpha/case-000"]["reasons"][0])

    def test_batches_share_a_session_and_dirty_sessions_are_replaced(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=25)
            driver = FakeDriver()
            self.run_cases(driver, tmp, batch_limit=10, jobs=1)
            self.assertEqual(driver.sessions, 3)
            self.assertEqual(driver.closed, 3)
            driver = FakeDriver(dirty={"alpha/case-002"}, raises={"alpha/case-015"})
            receipt, _ = self.run_cases(driver, tmp, batch_limit=10, jobs=1, retry_limit=0)
            self.assertEqual(driver.sessions, 5)
            self.assertEqual(receipt["cases"]["alpha/case-015"]["status"], "Crash")

    def test_expectations_skip_slow_and_several_results(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=4)
            table = {"alpha/case-000": ["Skip"], "alpha/case-001": ["Slow"], "alpha/case-002": ["Pass", "Failure"],
                     "alpha/case-003": ["Failure"]}
            driver = FakeDriver(script={"alpha/case-003": ["Pass"]})
            receipt, code = self.run_cases(driver, tmp, lookup=lambda cid: table.get(cid, ()))
            self.assertNotIn("alpha/case-000", driver.count)
            self.assertEqual(receipt["cases"]["alpha/case-000"]["outcome"], "skipped")
            slow = [ctx for cid, _, _, _, ctx in driver.calls if cid == "alpha/case-001"][0]
            self.assertEqual(slow["timeout_multiplier"], 5)
            self.assertEqual(receipt["flaky"], ["alpha/case-002"])
            self.assertEqual(receipt["unexpected_passes"], ["alpha/case-003"])
            self.assertEqual(driver.count["alpha/case-003"], 1)
            self.assertEqual(code, 0)

    def test_state_roots_are_unique_and_short(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=10)
            driver = FakeDriver(script={"alpha/case-000": ["Failure"]})
            self.run_cases(driver, tmp)
            roots = [ctx["state_root"] for *_, ctx in driver.calls]
            self.assertEqual(len(roots), len(set(roots)))
            self.assertTrue(all(len(r) <= len("/tmp/o/xxxxxx/xxxxxx") for r in roots))

    def test_out_dir_inside_the_checkout_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=1)
            with self.assertRaises(oracle.UsageError):
                self.run_cases(FakeDriver(), tmp, out=oracle.REPO / "oracle-out")


class CompareTests(unittest.TestCase):
    def two_runs(self, tmp, base_driver, head_driver, **overrides):
        cases, _ = oracle.load_corpus(tmp / "corpus")
        oracle.perform_run(options(tmp, out=tmp / "base", run_id="b", **overrides), cases, base_driver.open_session, None, {})
        oracle.perform_run(options(tmp, out=tmp / "head", run_id="h", **overrides), cases, head_driver.open_session, None, {})

    def diff(self, tmp, *extra):
        code = quiet(oracle.main, ["diff", "--base-run", str(tmp / "base"), "--head-run", str(tmp / "head"),
                                   "--out", str(tmp / "cmp"), *extra])
        return code, json.loads((tmp / "cmp" / "comparison.json").read_text())

    def test_flaky_never_passes_the_comparison(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=5)
            self.two_runs(tmp, FakeDriver(), FakeDriver(script={"alpha/case-003": ["Failure", "Pass"]}))
            code, cmp = self.diff(tmp)
            self.assertEqual(code, 0)
            self.assertEqual(cmp["verdicts"]["alpha/case-003"]["verdict"], "flaky")
            self.assertEqual(cmp["flaky_excluded"], ["alpha/case-003"])
            self.assertEqual(cmp["counts"]["match"], 4)
            self.assertEqual(cmp["compared"], 4)

    def test_flaky_with_a_different_hash_is_still_flaky_not_match(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            self.two_runs(tmp, FakeDriver(script={"alpha/case-000": ["Timeout", "Pass"]}), FakeDriver(), repeat=1)
            verdicts = oracle.compare(oracle.merge_runs([tmp / "base"], require_complete=True)[0],
                                      oracle.merge_runs([tmp / "head"], require_complete=True)[0])
            self.assertEqual(verdicts["alpha/case-000"]["verdict"], "flaky")

    def test_all_flaky_comparison_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            flaky = {"alpha/case-000": ["Failure", "Pass"], "alpha/case-001": ["Failure", "Pass"]}
            self.two_runs(tmp, FakeDriver(), FakeDriver(script=flaky))
            code, cmp = self.diff(tmp)
            self.assertEqual(code, 1)
            self.assertEqual(cmp["refused"], "nothing compared")
            self.assertEqual(cmp["compared"], 0)

    def test_divergence_by_hash_and_by_status(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            head = FakeDriver(script={"alpha/case-002": ["Failure"]},
                              hash_of=lambda cid, n: "other" if cid == "alpha/case-001" else "h-" + cid)
            self.two_runs(tmp, FakeDriver(), head, retry_limit=0)
            code, cmp = self.diff(tmp)
            self.assertEqual(code, 1)
            self.assertEqual(cmp["divergent"], ["alpha/case-001", "alpha/case-002"])
            self.assertEqual(cmp["verdicts"]["alpha/case-001"]["first"]["index"], 0)
            self.assertEqual(cmp["verdicts"]["alpha/case-002"]["first"]["status"], ["Pass", "Failure"])

    def test_sharded_runs_compare_after_merge(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=10)
            cases, _ = oracle.load_corpus(tmp / "corpus")
            argv = ["diff"]
            for side in ("base", "head"):
                for i in range(4):
                    out = tmp / f"{side}{i}"
                    oracle.perform_run(options(tmp, shard=(i, 4), out=out, run_id=f"{side}{i}"), cases,
                                       FakeDriver().open_session, None, {})
                    argv += [f"--{side}-run", str(out)]
            code = quiet(oracle.main, argv + ["--out", str(tmp / "cmp")])
            cmp = json.loads((tmp / "cmp" / "comparison.json").read_text())
            self.assertEqual(code, 0)
            self.assertEqual(cmp["counts"], {"match": 30})
            self.assertTrue(cmp["complete"])


class CheckTests(unittest.TestCase):
    def test_semantic_rules_name_the_step(self):
        case = oracle.Case("alpha/bad", "alpha", Path("x"), {
            "requires": ["telepathy"],
            "allow_crashes": ["renderer"],
            "steps": [
                {"id": "open", "op": "action.run", "args": {"url": "https://example.com/x"}},
                {"id": "open", "op": "snapshot", "checkpoint": "settled"},
                {"id": "local", "op": "snapshot", "args": {"url": "http://127.0.0.1:8080/"}},
                {"id": "make", "op": "resource.call", "args": {"operation": "workspace.create"}},
            ],
        })
        errors = oracle.check_case(case, frozenset({"workspace.create"}))
        text = "\n".join(errors)
        self.assertIn("duplicate step id 'open'", text)
        self.assertIn("step 'open' mutates (action.run)", text)
        self.assertIn("step 'make' mutates (resource.call workspace.create)", text)
        self.assertIn("https://example.com/x", text)
        self.assertNotIn("127.0.0.1", text)
        self.assertIn("telepathy", text)

    def test_mutation_classes_come_from_the_resource_spec(self):
        mutations = oracle.mutation_operations()
        if oracle.RESOURCE_OPERATIONS.is_file():
            self.assertIn("workspace.create", mutations)
            self.assertNotIn("workspace.list", mutations)


if __name__ == "__main__":
    unittest.main()
