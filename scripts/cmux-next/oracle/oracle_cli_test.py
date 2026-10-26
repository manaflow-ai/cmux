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


class FlakeTests(unittest.TestCase):
    """p15-oracle-117: `run --repeat 3 --flaky-out` writes (case, step, pointer) lines with samples."""

    def flake_run(self, driver, per_suite=4, **overrides):
        raw = tempfile.TemporaryDirectory()
        self.addCleanup(raw.cleanup)
        tmp = Path(raw.name)
        write_corpus(tmp / "corpus", suites=("alpha",), per_suite=per_suite)
        flaky_out = tmp / "flaky.jsonl"
        receipt, code = run_cases(tmp, driver, repeat=3, flaky_out=flaky_out, **overrides)
        lines = [json.loads(line) for line in flaky_out.read_text().splitlines()] if flaky_out.exists() else []
        return receipt, code, lines

    def test_repeat_three_lists_the_differing_pointer_with_samples(self):
        driver = FakeDriver(value_of=lambda cid, n: f"title-{n % 2}" if cid == "alpha/case-001" else cid)
        receipt, code, lines = self.flake_run(driver)
        self.assertEqual(code, 0)
        self.assertEqual(len(lines), 1, lines)
        line = lines[0]
        self.assertEqual((line["case"], line["kind"], line["step"], line["checkpoint"], line["pointer"]),
                         ("alpha/case-001", "value", "s1", "settled", "/value"))
        self.assertEqual(line["target"], "alpha/case-001/s1#/value")
        self.assertEqual([s["value"] for s in line["samples"]], ["title-0", "title-1"])
        self.assertEqual([[r["iteration"] for r in s["runs"]] for s in line["samples"]], [[0, 2], [1]])
        self.assertEqual(line["proposal"]["action"], "fix-at-source")
        self.assertEqual((line["schema"], line["repeat"], line["run_id"]), ("cmux-oracle-flake-v1", 3, "test-run"))
        self.assertEqual(receipt["nondeterminism"], {"checkpoints": 8, "nondeterministic": 1, "rate": 0.125})
        self.assertEqual(receipt["flaky_out"]["lines"], 1)

    def test_a_known_source_gets_a_rule_with_its_reason(self):
        ids = ["pane_" + "a" * 32, "pane_" + "b" * 32, "pane_" + "c" * 32]
        driver = FakeDriver(value_of=lambda cid, n: ids[n] if cid == "alpha/case-000" else cid)
        _, _, lines = self.flake_run(driver, per_suite=1)
        proposal = lines[0]["proposal"]
        self.assertEqual((proposal["rule"], proposal["action"]), ("id", "annotate-schema"))
        self.assertTrue(proposal["reason"].endswith(oracle.load_sibling("normalize").RULES["id"]))
        self.assertEqual(len(lines[0]["samples"]), 3)

    def test_a_result_change_is_a_status_line(self):
        driver = FakeDriver(script={"alpha/case-002": ["Pass", "Timeout", "Pass"]})
        receipt, code, lines = self.flake_run(driver, retry_limit=0)
        self.assertEqual(code, 0)
        self.assertEqual(receipt["flaky"], ["alpha/case-002"])
        self.assertEqual([(l["kind"], l["pointer"]) for l in lines], [("status", None)])
        self.assertEqual(sorted(s["value"]["status"] for s in lines[0]["samples"]), ["Pass", "Timeout"])

    def test_a_pass_on_retry_with_the_same_snapshot_is_one_status_line(self):
        driver = FakeDriver(script={"alpha/case-003": ["Failure", "Pass"]})
        _, _, lines = self.flake_run(driver)
        self.assertEqual([l["kind"] for l in lines], ["status"])
        phases = sorted(r["phase"] for s in lines[0]["samples"] for r in s["runs"])
        self.assertEqual(phases, ["run", "run", "run", "shard-retry"])

    def test_steady_runs_write_nothing_and_count_zero(self):
        receipt, code, lines = self.flake_run(FakeDriver())
        self.assertEqual((code, lines, receipt["flaky_out"]["lines"]), (0, [], 0))
        self.assertEqual(receipt["nondeterminism"]["nondeterministic"], 0)

    def test_samples_are_kept_only_with_flaky_out(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=1)
            plan = oracle.make_plan(oracle.load_corpus(tmp / "corpus")[0], shard=(0, 1), seed=None, batch_limit=1)
            driver = FakeDriver(value_of=lambda cid, n: n)
            expected = {"alpha/case-000": oracle.PASS_ONLY}
            plain, _ = oracle.execute(plan, options(tmp, repeat=3), driver.open_session, expected)
            kept, _ = oracle.execute(plan, options(tmp, repeat=3, flaky_out=tmp / "f"), driver.open_session, expected)
            self.assertEqual([bool(a.rows) for a in plain], [True, False, False])
            self.assertEqual([bool(a.rows) for a in kept], [True, True, True])

    def test_an_expectations_pointer_line_is_named(self):
        cps = (("s1", "settled", "h1"),)
        first = oracle.Attempt("alpha/a", 0, 0, "run", "Pass", None, cps, "", 0, {},
                               ({"step": "s1", "checkpoint": "settled", "snapshot": {"v": 1, "w": 1}, "sha256": "h1"},))
        second = oracle.Attempt("alpha/a", 1, 0, "run", "Pass", None, (("s1", "settled", "h2"),), "", 0, {},
                                ({"step": "s1", "checkpoint": "settled", "snapshot": {"v": 2, "w": 2}, "sha256": "h2"},))
        rules = [{"pointer": "/v", "reason": "Expectations a.txt:1: alpha/a/s1#/v", "case": "alpha/a", "step": "s1"}]
        lines = oracle.flake_lines("alpha/a", [second, first], oracle.PASS_ONLY, rules, oracle.load_sibling("normalize"))
        self.assertEqual([(l["pointer"], l["expected_by"]) for l in lines],
                         [("/v", rules[0]["reason"]), ("/w", None)])

    def test_a_checkpoint_reached_in_some_runs_only_is_a_missing_line(self):
        both = (("s1", "settled", "h"), ("s2", "settled", "k"))
        row = lambda step, sha: {"step": step, "checkpoint": "settled", "snapshot": {}, "sha256": sha}  # noqa: E731
        first = oracle.Attempt("alpha/a", 0, 0, "run", "Pass", None, both, "", 0, {}, (row("s1", "h"), row("s2", "k")))
        short = oracle.Attempt("alpha/a", 1, 0, "run", "Pass", None, both[:1], "", 0, {}, ())
        lines = oracle.flake_lines("alpha/a", [first, short], oracle.PASS_ONLY, [], oracle.load_sibling("normalize"))
        self.assertEqual([(l["kind"], l["step"]) for l in lines], [("missing", "s2")])
        self.assertEqual(oracle.nondeterministic_checkpoints([first, short]), [])


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
