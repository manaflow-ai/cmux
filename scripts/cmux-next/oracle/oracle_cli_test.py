#!/usr/bin/env python3
"""Unit and end-to-end tests for oracle.py: shards, retries, flaky handling, batches, shuffle,
the run directory format, and the comparison through the real diff.py and baselines.py.

Run: python3 -I scripts/cmux-next/oracle/oracle_cli_test.py (stdlib unittest; selftest.py,
task 019, runs it too). A fake driver stands in for the products through the driver protocol.
The Expectations tests run when expectations.py (p15-oracle-015) is beside this file.
"""

from __future__ import annotations

import io
import json
import subprocess
import sys
import tempfile
import threading
import unittest
from contextlib import redirect_stderr, redirect_stdout
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import oracle  # noqa: E402

HAS_EXPECTATIONS = (HERE / "expectations.py").is_file()


class FakeSession:
    def __init__(self, driver: "FakeDriver", number: int) -> None:
        self.driver = driver
        self.number = number

    def run_case(self, case, ctx):
        return self.driver.run(case, ctx, self.number)

    def close(self) -> None:
        self.driver.closed += 1


class FakeDriver:
    """`script` maps a case id to the statuses of its successive runs (the last one repeats).

    `value_of(cid, n)` is the snapshot value of the n-th run of a case; `hits` are switch hits
    reported per case run.
    """

    def __init__(self, script=None, value_of=None, dirty=(), raises=(), hits=None):
        self.script = script or {}
        self.value_of = value_of or (lambda cid, n: "v-" + cid)
        self.dirty = set(dirty)
        self.raises = set(raises)
        self.hits = hits
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
        result = {
            "status": status,
            "checkpoints": [
                {"step": "s1", "checkpoint": "before", "snapshot": {"topology": {"panes": 1}}},
                {"step": "s1", "checkpoint": "settled", "snapshot": {"topology": {"panes": 1}, "value": self.value_of(cid, n)}},
            ],
            "session_dirty": cid in self.dirty,
        }
        if self.hits is not None:
            result["switch_hits"] = self.hits
        return result


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
        run_id="test-run", expectations_root=tmp / "expectations",
    )
    base.update(overrides)
    return oracle.RunOptions(**base)


def quiet(fn, *args, **kwargs):
    with redirect_stdout(io.StringIO()), redirect_stderr(io.StringIO()):
        return fn(*args, **kwargs)


def run_cases(tmp, driver, expectation=None, **overrides):
    cases, errors = oracle.load_corpus(tmp / "corpus")
    assert errors == [], errors
    return oracle.perform_run(options(tmp, **overrides), cases, driver.open_session, expectation, {})


def attempt(status, cps, iteration=0, n=0):
    return oracle.Attempt("alpha/a", iteration, n, "run", status, None, cps, "", 0, {})


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
            # Totals follow the merged cases, not shard 0.
            self.assertEqual(merged["counts"], {"planned": 120})
            self.assertEqual(merged["batches"], 120)
            self.assertEqual(merged["shards"], [0, 1, 2, 3])
            self.assertEqual(sorted(r["runId"] for r in merged["shard_runs"]), ["dry0", "dry1", "dry2", "dry3"])
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
            quiet(oracle.main, ["run", "--dry-run", "--shard", "1/2", "--repeat", "2", "--corpus", str(corpus), "--out", str(b)])
            self.assertEqual(quiet(oracle.main, ["merge", str(a), str(b), "--out", str(tmp / "m")]), 1)

    def test_shuffled_shards_without_a_seed_still_merge(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            corpus = write_corpus(tmp / "corpus", per_suite=10)
            outs = []
            for i in range(4):
                out = tmp / f"s{i}"
                quiet(oracle.main, ["run", "--dry-run", "--shuffle", "--shard", f"{i}/4", "--corpus", str(corpus), "--out", str(out)])
                outs.append(str(out))
            self.assertEqual(quiet(oracle.main, ["merge", *outs, "--out", str(tmp / "m")]), 0)
            merged = json.loads((tmp / "m" / "receipt.json").read_text())
            self.assertEqual(len(merged["seeds"]), 4)
            self.assertTrue(all(isinstance(s, int) for s in merged["seeds"].values()))

    def test_merged_totals_and_switch_hits_are_summed(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=8)
            outs = []
            for i in range(3):
                out = tmp / f"s{i}"
                driver = FakeDriver(script={"alpha/case-000": ["Failure"]}, hits={"f6": {"new": 1}})
                run_cases(tmp, driver, shard=(i, 3), out=out, run_id=f"r{i}", switch="f6", arm="new", retry_limit=0)
                outs.append(out)
            view, errors = oracle.merge_runs(outs, require_complete=True)
            self.assertEqual(errors, [])
            self.assertEqual(view.receipt["switch_hits"], {"f6": {"new": 24}})
            self.assertTrue(view.receipt["arm_exercised"])
            self.assertEqual(sum(view.receipt["counts"].values()), 24)
            self.assertEqual(view.receipt["unexpected"], ["alpha/case-000"])
            self.assertFalse(view.receipt["ok"])


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


class ClassifyTests(unittest.TestCase):
    def test_unexpected_failures_with_different_hashes_are_flaky(self):
        cps = lambda h: (("s1", "settled", h),)  # noqa: E731
        base = oracle.classify([attempt("Failure", cps("h1")), attempt("Failure", cps("h2"), n=1),
                                attempt("Failure", cps("h3"), n=2)], oracle.PASS_ONLY)
        self.assertEqual(base["outcome"], "flaky")
        self.assertEqual(base["result"], "Flaky")
        self.assertIn("nondeterministic", base["reasons"][0])
        steady = oracle.classify([attempt("Failure", cps("h1")), attempt("Failure", cps("h1"), n=1)], oracle.PASS_ONLY)
        self.assertEqual(steady["outcome"], "unexpected")
        self.assertEqual(steady["result"], "Failure")

    def test_retry_with_another_failure_status_is_flaky(self):
        result = oracle.classify([attempt("Failure", ()), attempt("Crash", (), n=1)], oracle.PASS_ONLY)
        self.assertTrue(result["flaky"])

    def test_malformed_driver_results_are_crashes(self):
        self.assertEqual(oracle.coerce_result({"status": "Pass", "checkpoints": [{"step": "s", "checkpoint": "settled"}]})["status"], "Crash")
        self.assertEqual(oracle.coerce_result({"status": "Pass", "checkpoints": [
            {"step": "s", "checkpoint": "settled", "snapshot": {"x": float("nan")}}]})["status"], "Crash")
        self.assertEqual(oracle.coerce_result({"status": "Fine"})["status"], "Crash")


class RunTests(unittest.TestCase):
    def test_pass_on_retry_is_flaky_and_does_not_fail_the_run(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=5)
            driver = FakeDriver(script={"alpha/case-001": ["Failure", "Pass"]})
            receipt, code = run_cases(tmp, driver)
            self.assertEqual(code, 0)
            self.assertEqual(receipt["flaky"], ["alpha/case-001"])
            self.assertEqual(receipt["cases"]["alpha/case-001"]["result"], "Flaky")
            self.assertIn("pass-on-retry", receipt["cases"]["alpha/case-001"]["reasons"][0])
            phases = {p for cid, p, *_ in driver.calls if cid == "alpha/case-001"}
            self.assertEqual(phases, {"run", "shard-retry"})

    def test_whole_shard_retry_then_alone_retries(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=4)
            driver = FakeDriver(script={"beta/case-002": ["Crash"]})
            receipt, code = run_cases(tmp, driver, batch_limit=3, jobs=2)
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
            receipt, code = run_cases(tmp, driver, retry_limit=0)
            self.assertEqual(code, 1)
            self.assertEqual(receipt["flaky"], [])
            self.assertEqual(driver.count["alpha/case-000"], 1)

    def test_snapshot_change_in_the_shard_retry_is_flaky(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            driver = FakeDriver(script={"alpha/case-000": ["Failure"]},
                                value_of=lambda cid, n: f"{cid}-{n}" if cid == "alpha/case-001" else cid)
            receipt, _ = run_cases(tmp, driver)
            self.assertIn("alpha/case-001", receipt["flaky"])
            self.assertNotIn("alpha/case-002", receipt["flaky"])

    def test_repeat_difference_is_flaky(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            driver = FakeDriver(value_of=lambda cid, n: f"{cid}-{n}" if cid == "alpha/case-000" else cid)
            receipt, code = run_cases(tmp, driver, repeat=2)
            self.assertEqual(code, 0)
            self.assertEqual(receipt["flaky"], ["alpha/case-000"])
            self.assertIn("repeat-differs", receipt["cases"]["alpha/case-000"]["reasons"][0])

    def test_batches_share_a_session_and_dirty_sessions_are_replaced(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=25)
            driver = FakeDriver()
            run_cases(tmp, driver, batch_limit=10, jobs=1)
            self.assertEqual(driver.sessions, 3)
            self.assertEqual(driver.closed, 3)
            driver = FakeDriver(dirty={"alpha/case-002"}, raises={"alpha/case-015"})
            receipt, _ = run_cases(tmp, driver, batch_limit=10, jobs=1, retry_limit=0)
            self.assertEqual(driver.sessions, 5)
            self.assertEqual(receipt["cases"]["alpha/case-015"]["status"], "Crash")

    def test_expected_skip_slow_and_several_results(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=4)
            table = {
                "alpha/case-000": oracle.Expected(frozenset({"Pass"}), skip=True),
                "alpha/case-001": oracle.Expected(frozenset({"Pass"}), slow=True),
                "alpha/case-002": oracle.Expected(frozenset({"Pass", "Failure"})),
                "alpha/case-003": oracle.Expected(frozenset({"Failure"})),
            }
            driver = FakeDriver(script={"alpha/case-003": ["Pass"]})
            receipt, code = run_cases(tmp, driver, expectation=lambda c: table.get(c.id, oracle.PASS_ONLY))
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
            run_cases(tmp, driver)
            roots = [ctx["state_root"] for *_, ctx in driver.calls]
            self.assertEqual(len(roots), len(set(roots)))
            self.assertTrue(all(len(r) <= len("/tmp/o/xxxxxx/xxxxxx") for r in roots))

    def test_out_dir_inside_the_checkout_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=1)
            with self.assertRaises(oracle.UsageError):
                run_cases(tmp, FakeDriver(), out=oracle.REPO / "oracle-out")

    def test_run_directory_is_the_diff_py_format(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            run_cases(tmp, FakeDriver(), ref="abc123")
            receipt = json.loads((tmp / "out" / "receipt.json").read_text())
            self.assertEqual(receipt["sha"], "abc123")
            self.assertEqual(set(receipt["host"]), {"name", "os", "osVersion", "arch"})
            self.assertEqual(receipt["cases"]["alpha/case-000"]["result"], "Pass")
            rows = [json.loads(line) for line in (tmp / "out" / "checkpoints.jsonl").read_text().splitlines()]
            self.assertEqual(len(rows), 4)
            row = rows[1]
            self.assertEqual({k: row[k] for k in ("case", "suite", "step", "index", "checkpoint", "attempt", "result")},
                             {"case": "alpha/case-000", "suite": "alpha", "step": "s1", "index": 0,
                              "checkpoint": "settled", "attempt": 0, "result": "Pass"})
            self.assertEqual(row["sha256"], oracle.snapshot_sha256(row["snapshot"]))


class CompareTests(unittest.TestCase):
    """`oracle.py diff` through the real diff.py (p15-oracle-014)."""

    def two_runs(self, tmp, base_driver, head_driver, base_extra=None, **overrides):
        cases, _ = oracle.load_corpus(tmp / "corpus")
        oracle.perform_run(options(tmp, out=tmp / "base", run_id="b", **{**overrides, **(base_extra or {})}), cases,
                           base_driver.open_session, None, {})
        oracle.perform_run(options(tmp, out=tmp / "head", run_id="h", **overrides), cases, head_driver.open_session, None, {})

    def diff(self, tmp, *extra, base=("base",), head=("head",)):
        argv = ["diff", "--out", str(tmp / "cmp"), "--expectations-root", str(tmp / "expectations"), *extra]
        argv += [a for b in base for a in ("--base-run", str(tmp / b))]
        argv += [a for h in head for a in ("--head-run", str(tmp / h))]
        code = quiet(oracle.main, argv)
        return code, json.loads((tmp / "cmp" / "comparison.json").read_text())

    def test_flaky_never_passes_the_comparison(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=5)
            self.two_runs(tmp, FakeDriver(), FakeDriver(script={"alpha/case-003": ["Failure", "Pass"]}))
            code, cmp = self.diff(tmp)
            self.assertEqual(code, 0)
            self.assertEqual(cmp["flaky_excluded"], ["alpha/case-003"])
            self.assertEqual(cmp["summary"]["equal"], 4)
            self.assertEqual(cmp["compared"], 4)

    def test_nondeterministic_failures_are_flaky_not_match(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            noisy = lambda cid, n: f"h{n}" if cid == "alpha/case-000" else cid  # noqa: E731
            script = {"alpha/case-000": ["Failure"]}
            self.two_runs(tmp, FakeDriver(script=script, value_of=noisy), FakeDriver(script=script, value_of=noisy))
            code, cmp = self.diff(tmp)
            self.assertEqual(cmp["flaky_excluded"], ["alpha/case-000"])
            self.assertEqual(cmp["summary"]["equal"], 1)
            self.assertEqual(code, 0)

    def test_all_flaky_comparison_is_not_a_pass(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            flaky = {"alpha/case-000": ["Failure", "Pass"], "alpha/case-001": ["Failure", "Pass"]}
            self.two_runs(tmp, FakeDriver(), FakeDriver(script=flaky))
            code, cmp = self.diff(tmp)
            self.assertEqual(code, oracle.EXIT_REFUSED)
            self.assertEqual(cmp["refused"], "nothing compared")
            self.assertEqual(cmp["compared"], 0)
            self.assertFalse(cmp["ok"])

    def test_divergence_by_snapshot_and_by_result(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            head = FakeDriver(script={"alpha/case-002": ["Failure"]},
                              value_of=lambda cid, n: "other" if cid == "alpha/case-001" else "v-" + cid)
            self.two_runs(tmp, FakeDriver(), head, retry_limit=0)
            code, cmp = self.diff(tmp)
            self.assertEqual(code, 1)
            self.assertEqual(cmp["divergent"], ["alpha/case-001", "alpha/case-002"])
            report = json.loads(Path(cmp["divergence"]).read_text())
            self.assertEqual(report["verdict"], "divergent")
            first = {d["journey"]: d for d in report["divergences"]}
            self.assertEqual((first["alpha/case-001"]["checkpoint"], first["alpha/case-001"]["pointer"]), ("settled", "/value"))
            self.assertEqual((first["alpha/case-001"]["a"], first["alpha/case-001"]["b"]), ("v-alpha/case-001", "other"))
            self.assertEqual(first["alpha/case-002"]["pointer"], "/result")

    def test_all_match_runs_from_two_hosts_are_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            self.two_runs(tmp, FakeDriver(), FakeDriver())
            path = tmp / "base" / "receipt.json"
            receipt = json.loads(path.read_text())
            receipt["host"]["name"] = "another-host"
            path.write_text(json.dumps(receipt))
            code, cmp = self.diff(tmp)
            self.assertEqual(code, oracle.EXIT_REFUSED)
            self.assertTrue(cmp["refused"].startswith("host-mismatch"))
            self.assertFalse(cmp["ok"])

    def test_sharded_runs_compare_after_merge(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=10)
            cases, _ = oracle.load_corpus(tmp / "corpus")
            for side in ("base", "head"):
                for i in range(4):
                    oracle.perform_run(options(tmp, shard=(i, 4), out=tmp / f"{side}{i}", run_id=f"{side}{i}"), cases,
                                       FakeDriver().open_session, None, {})
            code, cmp = self.diff(tmp, base=[f"base{i}" for i in range(4)], head=[f"head{i}" for i in range(4)])
            self.assertEqual(code, 0)
            self.assertEqual(cmp["summary"]["equal"], 30)
            self.assertTrue(cmp["complete"])
            self.assertTrue(cmp["ok"])
            # One shard of four is refused unless the person asks for a partial compare.
            code, cmp = self.diff(tmp, base=["base1"], head=["head1"])
            self.assertEqual(code, oracle.EXIT_REFUSED)
            self.assertIn("incomplete", cmp["refused"])
            code, cmp = self.diff(tmp, "--partial", base=["base1"], head=["head1"])
            self.assertEqual(code, 0)
            self.assertTrue(cmp["partial"])
            self.assertEqual(cmp["shards"], [1])

    def test_different_shard_totals_or_seeds_are_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=4)
            self.two_runs(tmp, FakeDriver(), FakeDriver(), base_extra={"shard": (0, 1)}, shard=(0, 1))
            cases, _ = oracle.load_corpus(tmp / "corpus")
            for i in range(2):
                oracle.perform_run(options(tmp, shard=(i, 2), out=tmp / f"h{i}", run_id=f"h{i}"), cases,
                                   FakeDriver().open_session, None, {})
            code, cmp = self.diff(tmp, head=["h0", "h1"])
            self.assertEqual(code, oracle.EXIT_REFUSED)
            self.assertIn("shard totals differ", cmp["refused"])
            self.two_runs(tmp, FakeDriver(), FakeDriver(), base_extra={"seed": 1}, seed=2)
            code, cmp = self.diff(tmp)
            self.assertEqual(code, oracle.EXIT_REFUSED)
            self.assertIn("seeds differ", cmp["refused"])

    def test_bad_diff_py_input_is_a_usage_error(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=1)
            self.two_runs(tmp, FakeDriver(), FakeDriver())
            (tmp / "head" / "checkpoints.jsonl").write_text('{"case": "alpha/case-000"}\n')
            code = quiet(oracle.main, ["diff", "--base-run", str(tmp / "base"), "--head-run", str(tmp / "head"),
                                       "--out", str(tmp / "cmp")])
            self.assertEqual(code, 2)


SWITCH = "layer-hosting"
APP_KEY = "browserResize.layerHosting"


class ArmSession:
    def __init__(self, driver: "ArmDriver", ctx) -> None:
        self.driver = driver
        self.arm = ctx["switches"].get(SWITCH)

    def run_case(self, case, ctx):
        return self.driver.run(case, ctx, self.arm)

    def close(self) -> None:
        pass


class ArmDriver:
    """A product that applies the switch arm it is launched with and counts its site hits.

    Each knob breaks one thing the switch diff must catch: `readback` overrides the arm the
    product reports, `facet_arm` the arm its snapshots show, `hits` the site counts per arm
    (`{arm: {other_arm: n}}`), `value_of(cid, arm)` the compared value.
    """

    def __init__(self, readback=None, facet_arm=None, hits=None, value_of=None, unexercised=()):
        self.readback = readback or {}
        self.facet_arm = facet_arm or {}
        self.hits = hits
        self.value_of = value_of or (lambda cid, arm: "v-" + cid)
        self.unexercised = set(unexercised)
        self.order = []
        self.mutex = threading.Lock()  # test-only bookkeeping across the runner's worker threads

    def open_session(self, ctx):
        return ArmSession(self, ctx)

    def run(self, case, ctx, arm):
        cid = ctx["case_id"]
        with self.mutex:
            self.order.append((arm, cid))
        shown = self.facet_arm.get(arm, arm)
        snapshot = {"facets": {"switches": {"arms": {APP_KEY: shown},
                                            "hits": [{"switch": SWITCH, "site": "BrowserPaneView.resize", "hit": arm == "new",
                                                      "count": 1}]},
                               "layout": {"value": self.value_of(cid, arm)}}}
        hits = self.hits[arm] if self.hits is not None else {arm: 1}
        return {
            "status": "Pass",
            "checkpoints": [{"step": "s1", "checkpoint": "settled", "snapshot": snapshot}],
            "switch_readback": {SWITCH: self.readback.get(arm, arm)},
            "switch_hits": {} if cid in self.unexercised else {SWITCH: hits},
        }


def write_registry(root: Path, expected_differences=()) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    (root / f"{SWITCH}.json").write_text(json.dumps({
        "name": SWITCH, "owner": "p03-rendering", "plan": "plans/cmux-next/chrome-parity/p15-oracle.md", "read": "launch",
        "app_key": APP_KEY, "default": "old", "planned": "new", "created": "2026-10-20", "expires": "2026-11-03",
        "suites": ["tabs", "layout"], "expected_differences": list(expected_differences),
    }))
    return root


class SwitchDiffTests(unittest.TestCase):
    """`oracle.py diff --switch` (p15-oracle-111): one build, two arms, refused unless both arms ran."""

    def setUp(self):
        raw = tempfile.TemporaryDirectory()
        self.addCleanup(raw.cleanup)
        self.tmp = Path(raw.name)
        tabs = {f"tabs/t{i}": {"id": f"tabs/t{i}", "switches": [SWITCH], "steps": [{"id": "s1", "op": "snapshot"}]}
                for i in range(6)}
        write_corpus(self.tmp / "corpus", suites=("layout", "other"), per_suite=4, extra=tabs)
        self.registry = write_registry(self.tmp / "switches")

    def argv(self, *extra):
        return ["diff", "--switch", SWITCH, "--switch-registry", str(self.registry), "--corpus", str(self.tmp / "corpus"),
                "--expectations-root", str(self.tmp / "expectations"), "--out", str(self.tmp / "cmp"), "--jobs", "4",
                "--ref", "0" * 40, *extra]

    def diff(self, driver, *extra):
        args = oracle.build_parser().parse_args(self.argv(*extra))
        code = quiet(oracle.diff_switch, args, self.tmp / "cmp", driver.open_session)
        return code, json.loads((self.tmp / "cmp" / "comparison.json").read_text())

    def divergences(self):
        text = (self.tmp / "cmp" / "divergences.jsonl").read_text()
        return [json.loads(line) for line in text.splitlines() if line.strip()]

    def test_both_arms_applied_and_exercised_pass(self):
        driver = ArmDriver()
        code, cmp = self.diff(driver, "--shards", "3")
        self.assertEqual(code, 0, cmp["refused"])
        self.assertTrue(cmp["ok"])
        # The registry's suites only: tabs (6) and layout (4), never `other`.
        self.assertEqual(cmp["compared"], 10)
        self.assertEqual(cmp["shards"], [0, 1, 2])
        self.assertTrue(cmp["complete"])
        block = cmp["switch"]
        self.assertEqual((block["name"], block["refusals"], block["suites_not_run"]), (SWITCH, [], []))
        self.assertEqual(block["arms"]["old"]["readback"], ["old"])
        self.assertEqual(block["arms"]["new"]["readback"], ["new"])
        self.assertEqual(block["readback_snapshots"], 10)
        self.assertEqual(self.divergences(), [])
        # Shard by shard, arm old then arm new, so the two arms of a case run back to back.
        arms = [arm for arm, _ in driver.order]
        shard_runs = [arm for i, arm in enumerate(arms) if i == 0 or arms[i - 1] != arm]
        self.assertEqual(shard_runs, ["old", "new"] * 3)
        for arm in oracle.ARMS:
            self.assertEqual(sorted(p.name for p in (self.tmp / "cmp" / arm).iterdir()), ["shard-0", "shard-1", "shard-2"])

    def test_a_product_that_ignores_the_switch_is_refused(self):
        code, cmp = self.diff(ArmDriver(readback={"new": "old"}, facet_arm={"new": "old"}))
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertTrue(cmp["refused"].startswith("arms-read-back-same"), cmp["refused"])
        self.assertIn("arm-not-applied: layer-hosting read back old on the new arm", cmp["switch"]["refusals"])
        self.assertFalse(cmp["ok"])
        self.assertEqual(self.divergences(), [])

    def test_snapshots_that_read_back_one_arm_are_refused_by_diff_py(self):
        # The receipts look right, but the facet shows the same arm on both sides.
        code, cmp = self.diff(ArmDriver(facet_arm={"new": "old"}))
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertTrue(cmp["refused"].startswith("arms-read-back-same: 10 snapshots"), cmp["refused"])
        self.assertEqual(cmp["diff_exit"], oracle.DIFF_ARMS_SAME)

    def test_zero_hits_on_an_arm_is_not_exercised(self):
        code, cmp = self.diff(ArmDriver(hits={"old": {"old": 1}, "new": {}}))
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertEqual(cmp["refused"], "arm-not-exercised: 0 hits of layer-hosting on the new arm")

    def test_hits_of_the_other_arm_are_not_applied(self):
        code, cmp = self.diff(ArmDriver(hits={"old": {"old": 1}, "new": {"new": 1, "old": 1}}))
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertTrue(cmp["refused"].startswith("arm-not-applied: the new arm ran 10 old-arm site hits"), cmp["refused"])

    def test_a_listed_case_with_no_hits_is_not_exercised(self):
        code, cmp = self.diff(ArmDriver(unexercised={"tabs/t3"}))
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertIn("1 cases that list layer-hosting had 0 hits on the old arm: tabs/t3", cmp["refused"])
        self.assertEqual(cmp["switch"]["arms"]["new"]["unexercised_cases"], ["tabs/t3"])

    def test_divergence_goes_to_divergences_jsonl(self):
        value_of = lambda cid, arm: f"{cid}-{arm}" if cid == "tabs/t2" else cid  # noqa: E731
        code, cmp = self.diff(ArmDriver(value_of=value_of))
        self.assertEqual(code, 1)
        self.assertEqual(cmp["divergent"], ["tabs/t2"])
        [row] = self.divergences()
        self.assertEqual((row["journey"], row["pointer"], row["a"], row["b"]),
                         ("tabs/t2", "/facets/layout/value", "tabs/t2-old", "tabs/t2-new"))
        self.assertEqual((row["switch"], row["a_label"], row["b_label"]), (SWITCH, f"{SWITCH}=old", f"{SWITCH}=new"))
        self.assertIn("--arm-pointer", row["replay"])

    def test_expected_differences_explain_the_intended_change(self):
        write_registry(self.registry, [{"pointer": "/facets/layout/value", "case": "tabs/*", "reason": "new arm resizes in one commit"}])
        value_of = lambda cid, arm: f"{cid}-{arm}" if cid.startswith("tabs/") else cid  # noqa: E731
        code, cmp = self.diff(ArmDriver(value_of=value_of))
        self.assertEqual(code, 0, cmp["refused"])
        self.assertEqual(len(cmp["explained"]), 10)  # the hits facet differs by arm in every case
        report = json.loads(Path(cmp["divergence"]).read_text())
        reasons = {e["reason"] for c in report["cases"] if c["case"].startswith("tabs/") for e in c["explained"]}
        self.assertIn("new arm resizes in one commit", reasons)

    def test_worker_shard_runs_compare_through_base_and_head_runs(self):
        cases, _ = oracle.load_corpus(self.tmp / "corpus")
        driver = ArmDriver()
        for arm in oracle.ARMS:
            for i in range(2):
                oracle.perform_run(
                    options(self.tmp, suites=("tabs", "layout"), shard=(i, 2), out=self.tmp / f"{arm}{i}", run_id=f"{arm}{i}",
                            switch=SWITCH, arm=arm, switches={SWITCH: arm}, ref="0" * 40, corpus=self.tmp / "corpus"),
                    cases, driver.open_session, None, {})
        runs = [a for arm, flag in (("old", "--base-run"), ("new", "--head-run")) for i in range(2)
                for a in (flag, str(self.tmp / f"{arm}{i}"))]
        code, cmp = self.diff(driver, *runs)
        self.assertEqual(code, 0, cmp["refused"])
        self.assertEqual(cmp["compared"], 10)
        # The arms swapped are not an old/new pair.
        swapped = [a.replace("--base-run", "--x").replace("--head-run", "--base-run").replace("--x", "--head-run") for a in runs]
        self.assertEqual(quiet(oracle.main, self.argv(*swapped)), 2)

    def test_arms_of_two_builds_are_refused(self):
        cases, _ = oracle.load_corpus(self.tmp / "corpus")
        driver = ArmDriver()
        for arm, ref in (("old", "0" * 40), ("new", "1" * 40)):
            oracle.perform_run(options(self.tmp, suites=("tabs", "layout"), out=self.tmp / arm, run_id=arm, switch=SWITCH,
                                       arm=arm, switches={SWITCH: arm}, ref=ref, corpus=self.tmp / "corpus"),
                               cases, driver.open_session, None, {})
        code, cmp = self.diff(driver, "--base-run", str(self.tmp / "old"), "--head-run", str(self.tmp / "new"))
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertTrue(cmp["refused"].startswith("arms-differ-beyond-switch: ref"), cmp["refused"])

    def test_a_narrower_suite_is_recorded(self):
        code, cmp = self.diff(ArmDriver(), "--suite", "tabs")
        self.assertEqual(code, 0, cmp["refused"])
        self.assertEqual(cmp["switch"]["suites_not_run"], ["layout"])

    def test_shards_and_shard_are_exclusive(self):
        self.assertEqual(quiet(oracle.main, self.argv("--shards", "2", "--shard", "1/2")), 2)
        self.assertEqual(quiet(oracle.main, ["diff", "--shards", "2", "--base-run", "x", "--head-run", "y",
                                             "--out", str(self.tmp / "c2")]), 2)


class BaselineTests(unittest.TestCase):
    """End to end: oracle.py run -> oracle.py rebaseline (baselines.py) -> oracle.py diff --baselines."""

    def test_run_rebaseline_then_diff_against_baselines(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("journeys", "daemon-ops"), per_suite=3)
            root = tmp / "baselines"
            run_cases(tmp, FakeDriver(), out=tmp / "golden", run_id="g")
            proc = subprocess.run([sys.executable, "-I", str(HERE / "oracle.py"), "rebaseline", "--run", str(tmp / "golden"),
                                   "--root", str(root)], check=False, capture_output=True, text=True)
            self.assertEqual(proc.returncode, 0, proc.stderr + proc.stdout)
            report = json.loads(proc.stdout)
            self.assertEqual(sorted(report["written"]), [f"journeys/case-{i:03d}" for i in range(3)])
            self.assertEqual(report["refused"], [])
            self.assertTrue((root / "journeys" / "case-000.expected.jsonl").is_file())
            self.assertFalse((root / "daemon-ops").exists())

            run_cases(tmp, FakeDriver(value_of=lambda cid, n: "changed" if cid == "journeys/case-001" else "v-" + cid),
                      out=tmp / "head", run_id="h")
            code = quiet(oracle.main, ["diff", "--head-run", str(tmp / "head"), "--baselines", "--baselines-root", str(root),
                                       "--expectations-root", str(tmp / "expectations"), "--out", str(tmp / "cmp")])
            cmp = json.loads((tmp / "cmp" / "comparison.json").read_text())
            self.assertEqual(code, 1)
            self.assertEqual(cmp["divergent"], ["journeys/case-001"])
            self.assertEqual(cmp["summary"]["equal"], 2)
            self.assertEqual(cmp["summary"]["cases"], 3)  # differential suites have no baseline

    def test_flaky_and_timeout_cases_are_not_rebaselined(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("journeys",), per_suite=3)
            run_cases(tmp, FakeDriver(script={"journeys/case-000": ["Failure", "Pass"], "journeys/case-001": ["Timeout"]}),
                      out=tmp / "run")
            proc = subprocess.run([sys.executable, "-I", str(HERE / "oracle.py"), "rebaseline", "--run", str(tmp / "run"),
                                   "--root", str(tmp / "baselines")], check=False, capture_output=True, text=True)
            report = json.loads(proc.stdout)
            self.assertEqual(report["written"], ["journeys/case-002"])
            self.assertEqual(sorted(r["case"] for r in report["refused"]), ["journeys/case-000", "journeys/case-001"])

    def test_no_baselines_yet_is_refused_not_passed(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("journeys",), per_suite=2)
            run_cases(tmp, FakeDriver(), out=tmp / "head")
            code = quiet(oracle.main, ["diff", "--head-run", str(tmp / "head"), "--baselines", "--baselines-root",
                                       str(tmp / "empty"), "--out", str(tmp / "cmp")])
            cmp = json.loads((tmp / "cmp" / "comparison.json").read_text())
            self.assertEqual(code, oracle.EXIT_REFUSED)
            self.assertEqual(sorted(cmp["not_comparable"]), ["journeys/case-000", "journeys/case-001"])

    def test_unclassified_suite_is_a_usage_error_not_a_traceback(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("nosuchsuite",), per_suite=1)
            run_cases(tmp, FakeDriver(), out=tmp / "head")
            code = quiet(oracle.main, ["diff", "--head-run", str(tmp / "head"), "--baselines", "--out", str(tmp / "cmp")])
            self.assertEqual(code, 2)


@unittest.skipUnless(HAS_EXPECTATIONS, "expectations.py (p15-oracle-015) is not beside oracle.py")
class ExpectationTests(unittest.TestCase):
    """Against the expectations.py API of p15-oracle-015."""

    def setUp(self):
        self.raw = tempfile.TemporaryDirectory()
        self.addCleanup(self.raw.cleanup)
        self.tmp = Path(self.raw.name)
        write_corpus(self.tmp / "corpus", suites=("journeys",), per_suite=6)
        (self.tmp / "expectations" / "Expectations.d").mkdir(parents=True)
        (self.tmp / "expectations" / "NeverFix.d").mkdir(parents=True)
        (self.tmp / "expectations" / "Expectations.d" / "journeys.txt").write_text(
            "p15-oracle-015 journeys/case-000 [ Skip ]\n"
            "p15-oracle-015 journeys/case-001 [ Slow ]\n"
            "p15-oracle-015 journeys/case-002 [ Pass Failure ]\n"
            "p15-oracle-015 [ mac ] journeys/case-003 [ Crash ]\n"
            "p15-oracle-015 journeys/case-004#/value [ Failure ]\n"
        )
        (self.tmp / "expectations" / "NeverFix.d" / "journeys.txt").write_text("p15-oracle-015 journeys/case-005 [ Skip ]\n")

    def store(self, platform="linux"):
        return oracle.load_expectations(self.tmp / "expectations", platform=platform, arm=None, product="daemon", build="debug")

    def test_resolution_skip_neverfix_slow_flaky_and_tags(self):
        cases = {c.id: c for c in oracle.load_corpus(self.tmp / "corpus")[0]}
        linux = self.store()
        self.assertTrue(linux.expected(cases["journeys/case-000"]).skip)
        self.assertTrue(linux.expected(cases["journeys/case-005"]).skip)
        self.assertTrue(linux.expected(cases["journeys/case-001"]).slow)
        self.assertTrue(linux.expected(cases["journeys/case-002"]).declared_flaky)
        self.assertEqual(linux.expected(cases["journeys/case-003"]).results, frozenset({"Pass"}))
        self.assertEqual(self.store("mac").expected(cases["journeys/case-003"]).results, frozenset({"Crash"}))
        # A pointer line never sets the case result; the rest of the snapshot stays strict.
        self.assertEqual(linux.expected(cases["journeys/case-004"]).results, frozenset({"Pass"}))
        self.assertEqual([r["pointer"] for r in linux.pointer_rules()], ["/value"])

    def test_pointer_scoped_line_excuses_only_its_value(self):
        tmp = self.tmp
        expectation = self.store().expected
        cases, _ = oracle.load_corpus(tmp / "corpus")
        oracle.perform_run(options(tmp, out=tmp / "base", run_id="b"), cases, FakeDriver().open_session, expectation, {})
        head = FakeDriver(value_of=lambda cid, n: "known-wrong" if cid in ("journeys/case-004", "journeys/case-003") else "v-" + cid)
        oracle.perform_run(options(tmp, out=tmp / "head", run_id="h"), cases, head.open_session, expectation, {})
        code = quiet(oracle.main, ["diff", "--base-run", str(tmp / "base"), "--head-run", str(tmp / "head"),
                                   "--expectations-root", str(tmp / "expectations"), "--out", str(tmp / "cmp")])
        cmp = json.loads((tmp / "cmp" / "comparison.json").read_text())
        self.assertEqual(cmp["explained"], ["journeys/case-004"])
        self.assertEqual(cmp["divergent"], ["journeys/case-003"])
        self.assertEqual(code, 1)

    def test_check_lints_expectations(self):
        (self.tmp / "expectations" / "Expectations.d" / "journeys.txt").write_text("journeys/case-001 [ Failure ]\n")
        out = io.StringIO()
        with redirect_stdout(out):
            code = oracle.main(["check", "--corpus", str(self.tmp / "corpus"), "--expectations-root", str(self.tmp / "expectations")])
        self.assertEqual(code, 1)
        self.assertIn("bug-id", out.getvalue())


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

    def test_unclassified_suite_is_a_check_error(self):
        with tempfile.TemporaryDirectory() as raw:
            corpus = write_corpus(Path(raw) / "corpus", suites=("nosuchsuite",), per_suite=1)
            out = io.StringIO()
            with redirect_stdout(out), redirect_stderr(io.StringIO()):
                code = oracle.main(["check", "--corpus", str(corpus), "--expectations-root", str(Path(raw) / "none")])
            self.assertEqual(code, 1)
            self.assertIn("suite nosuchsuite: unknown suite", out.getvalue())


if __name__ == "__main__":
    unittest.main()
