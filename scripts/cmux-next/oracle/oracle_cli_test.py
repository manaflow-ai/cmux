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
import time
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
        run_id="test-run", expectations_root=tmp / "expectations", isolation="none",
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

    def test_the_mcp_product_on_a_tagged_app_launches_as_the_app(self):
        parser = oracle.build_parser()

        def options(product, binary):
            args = parser.parse_args(["run", "--product", product])
            return oracle.options_from_args(args, retry_default=None, out=Path("/tmp/x"), run_id="r", switch=None,
                                            arm=None, switches={}, ref=None, binary=binary)

        fleet = options("mcp", "/Applications/x/cmux DEV tag.app")
        self.assertEqual((fleet.jobs, fleet.batch_limit, fleet.build), (1, 10, "bench"))
        vm = options("mcp", "/tmp/o/cmux-tui")
        self.assertEqual((vm.jobs, vm.batch_limit, vm.build), (oracle.VM_JOBS, 1, "debug"))
        self.assertEqual(options("daemon", "/x/cmux DEV tag.app").jobs, oracle.VM_JOBS)
        self.assertLessEqual({"resource_api", "actions", "mcp", "restart"}, oracle.PRODUCTS["mcp"])


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


class EnvironmentDriver(FakeDriver):
    """Reports `environment` the way driver_daemon.py does, and keeps every session context."""

    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self.contexts = []

    def open_session(self, ctx):
        self.contexts.append(ctx)
        return super().open_session(ctx)

    def run(self, case, ctx, session):
        result = super().run(case, ctx, session)
        result["environment"] = {"env": {"HOME": "$CASE_ROOT/home", "CMUX_TUI_ORACLE_SEED": ctx["case_id"]},
                                 "isolation": self.contexts[0]["isolation"]}
        return result


class IsolationTests(unittest.TestCase):
    NETNS = {"mode": "netns", "kind": "netns", "prefix": ["/usr/bin/unshare", "-rn"], "reason": "t", "uid": 1001,
             "gid": 1002}

    def test_isolation_is_resolved_once_and_every_session_and_receipt_gets_it(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=3)
            cases, _ = oracle.load_corpus(tmp / "corpus")
            driver = EnvironmentDriver()
            probes = []

            def isolate(mode):
                probes.append(mode)
                return dict(self.NETNS)

            receipt, code = oracle.perform_run(options(tmp, isolation="netns"), cases, driver.open_session, None, {},
                                               isolate=isolate)
            self.assertEqual(code, 0)
            self.assertEqual(probes, ["netns"])
            self.assertEqual(len(driver.contexts), 9)
            self.assertTrue(all(ctx["isolation"] == self.NETNS for ctx in driver.contexts))
            self.assertEqual(receipt["isolation"]["kind"], "netns")
            environment = receipt["cases"]["alpha/case-001"]["environment"]
            self.assertEqual(environment["env"]["CMUX_TUI_ORACLE_SEED"], "alpha/case-001")
            self.assertEqual(environment["isolation"]["kind"], "netns")
            written = json.loads((tmp / "out" / "receipt.json").read_text())
            self.assertEqual(written["cases"]["beta/case-002"]["environment"]["isolation"]["uid"], 1001)

    def test_a_refused_isolation_fails_the_run_before_any_session(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=2)
            cases, _ = oracle.load_corpus(tmp / "corpus")
            driver = EnvironmentDriver()

            def refuse(mode):
                raise oracle.UsageError(f"--isolation {mode}: unshare -rn refused")

            with self.assertRaises(oracle.UsageError):
                oracle.perform_run(options(tmp, isolation="netns"), cases, driver.open_session, None, {}, isolate=refuse)
            self.assertEqual(driver.sessions, 0)

    def test_none_needs_no_probe(self):
        resolved = oracle.resolve_isolation("none")
        self.assertEqual((resolved["mode"], resolved["kind"]), ("none", "none"))

    def test_merge_refuses_shards_with_different_isolation(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=4)
            cases, _ = oracle.load_corpus(tmp / "corpus")
            outs = []
            for i, kind in enumerate(("netns", "none")):
                out = tmp / f"s{i}"
                resolved = {**self.NETNS, "kind": kind}
                oracle.perform_run(options(tmp, shard=(i, 2), out=out, run_id=f"s{i}"), cases,
                                   EnvironmentDriver().open_session, None, {}, isolate=lambda _mode, r=resolved: r)
                outs.append(out)
            view, errors = oracle.merge_runs(outs, require_complete=True)
            self.assertTrue(any("different case isolation" in e for e in errors), errors)
            self.assertFalse(view.receipt["ok"])


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

    def test_a_run_without_an_arm_takes_the_registry_defaults_arm(self):
        """A one-arm case (p15-oracle-224's terminal holder crash journeys) is skipped by a NeverFix line of the
        other arm: a default run is [ old ] while every switch defaults to old, so the holder-arm case does not
        run on the per-terminal host arm the daemon runs by default."""
        old, new = {"terminal-holder": {"default": "old"}}, {"terminal-holder": {"default": "new"}}
        self.assertEqual([oracle.expectation_arm(arm, old) for arm in (None, "default", "old", "new", "launch-config")],
                         ["old", "old", "old", "new", None])
        self.assertEqual(oracle.expectation_arm(None, {}), "old", "no switch: every path is the old one")
        self.assertEqual(oracle.expectation_arm(None, new), "new")
        self.assertIsNone(oracle.expectation_arm(None, {**old, "layer-hosting": {"default": "new"}}))
        (self.tmp / "expectations" / "NeverFix.d" / "journeys.txt").write_text(
            "p15-oracle-224 [ old ] journeys/case-001 [ Skip ]\np15-oracle-224 [ new ] journeys/case-002 [ Skip ]\n")
        cases = {c.id: c for c in oracle.load_corpus(self.tmp / "corpus")[0]}

        def skips(arm, registry):
            store = oracle.load_expectations(self.tmp / "expectations", platform="linux", arm=arm, product="daemon",
                                             build="debug", registry=registry)
            return [store.expected(cases[f"journeys/case-00{i}"]).skip for i in (1, 2)]

        self.assertEqual(skips(None, old), [True, False])
        self.assertEqual(skips("default", old), [True, False])
        self.assertEqual(skips("new", old), [False, True])
        self.assertEqual(skips(None, new), [False, True])
        self.assertEqual(skips("launch-config", old), [False, False], "planned arms mix: no arm tag matches")

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

    def test_case_v1_checkpoint_arrays_and_allow_crash_objects(self):
        """case-v1 writes checkpoint as an array and allow_crashes entries as objects (case-example-daemon.json)."""
        case = oracle.Case("daemon-ops/x", "daemon-ops", Path("x"), {
            "requires": ["resource_api", "restart"],
            "allow_crashes": [{"kind": "daemon", "reason": "on purpose", "steps": ["kill"]}, {"kind": "comet"}],
            "steps": [
                {"id": "make", "op": "resource.call", "target": {"session": "current"}, "checkpoint": ["before", "settled"],
                 "args": {"method": "workspace.create", "params": {}, "idempotencyKey": "x.make"}},
                {"id": "bare", "op": "resource.call", "args": {"method": "workspace.create"}},
                {"id": "odd", "op": "snapshot", "checkpoint": ["settled", "turnip"]},
            ],
        })
        errors = oracle.check_case(case, frozenset({"workspace.create"}))
        self.assertEqual(errors, [
            "daemon-ops/x: unknown crash kind 'comet' in allow_crashes",
            "daemon-ops/x: step 'bare' mutates (resource.call workspace.create) without a target",
            "daemon-ops/x: step 'odd' has unknown checkpoint 'turnip'",
        ])

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


class Unreachable(Exception):
    """app_reset.ProductUnreachable's shape: the product is gone."""

    unreachable = True


class Relaunch(Exception):
    """app_reset.NeedsRelaunch's shape: the reset has no action for what the case changed."""

    def __init__(self, reason):
        super().__init__(reason)
        self.relaunch = reason


class ResetSession(FakeSession):
    """A launch-sharing session (task 189): its state is what reset_state returns. A case in `leaks` leaves a key the
    reset cannot remove; `after` maps a case to the case that must run before it in the same launch for it to leak
    (an order-dependent leak); `reset_raises` maps a case to what the reset after it raises (refused, unreachable or
    relaunch); a launch number in `fixture_fails` cannot read its fixture; `reset_s` is how long a reset takes."""

    def __init__(self, driver, number):
        super().__init__(driver, number)
        self.state = {"windows": ["win_1"], "settings": {"ui": {"animations": {"enabled": False}}}}
        self.ran = []
        self.raise_next = None

    def run_case(self, case, ctx):
        cid = ctx["case_id"]
        self.ran.append(cid)
        before = self.driver.after.get(cid)
        if cid in self.driver.leaks or (before is not None and before in self.ran[:-1]):
            self.state = {**self.state, "windows": self.state["windows"] + ["win_" + cid]}
        self.raise_next = self.driver.reset_raises.get(cid)
        return super().run_case(case, ctx)

    def reset_state(self):
        with self.driver.mutex:
            self.driver.resets += 1
        if not self.ran and self.number in self.driver.fixture_fails:
            raise RuntimeError("snapshot.get: unavailable, retry")
        if self.driver.reset_s and self.ran:
            time.sleep(self.driver.reset_s)  # a slow reset, to tell its time from the case's
        kind, self.raise_next = self.raise_next, None
        if kind == "refused":
            raise RuntimeError("action.run: closeTab refused")
        if kind == "unreachable":
            raise Unreachable("snapshot.get: [Errno 61] Connection refused")
        if kind == "relaunch":
            raise Relaunch("no action puts back the pane pane_1 tab order")
        return json.loads(json.dumps(self.state))


class ResetDriver(FakeDriver):
    def __init__(self, leaks=(), after=None, reset_raises=None, fixture_fails=(), reset_s=0.0, **kwargs):
        super().__init__(**kwargs)
        self.leaks = set(leaks)
        self.after = dict(after or {})
        self.reset_raises = dict(reset_raises or {})
        self.fixture_fails = set(fixture_fails)
        self.reset_s = reset_s
        self.resets = 0

    def open_session(self, ctx):
        with self.mutex:
            self.sessions += 1
            return ResetSession(self, self.sessions)


def verdicts(receipt):
    return {cid: (r["result"], r["outcome"]) for cid, r in receipt["cases"].items()}


class ResetCheckTests(unittest.TestCase):
    """Task 189: the reset check between cases, --batch-limit K and --shuffle --seed N."""

    def test_state_differences_name_pointers(self):
        diff = oracle.state_differences
        self.assertEqual(diff({"a": [1, 2]}, {"a": [1, 2]}), [])
        self.assertEqual(diff({"a": [1, 2]}, {"a": [1, 3]}), ["/a/1"])
        self.assertEqual(diff({"a": [1]}, {"a": [1, 2]}), ["/a"])
        self.assertEqual(diff({"a/b": 1, "c": {}}, {"c": {"d": 0}}), ["/a~1b", "/c/d"])
        # RFC 6901: "" is the whole document, "/" the member named "".
        self.assertEqual(diff(1, 1.0), [""])
        self.assertEqual(diff(None, {}), [""])
        self.assertEqual(diff([1], [1, 2]), [""])
        self.assertEqual(diff({"": 1}, {"": 2}), ["/"])

    def test_leaked_state_names_the_leaking_case_and_relaunches(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=6)
            driver = ResetDriver(leaks={"alpha/case-002"})
            receipt, code = run_cases(tmp, driver, batch_limit=10, jobs=1, retry_limit=0)
            self.assertEqual(code, 1)
            self.assertFalse(receipt["ok"])
            self.assertEqual(receipt["leaked_state"], ["alpha/case-002"])
            leak = receipt["cases"]["alpha/case-002"]["leaked_state"][0]
            self.assertEqual(leak["case"], "alpha/case-002")
            self.assertEqual(leak["pointers"], ["/windows"])
            self.assertEqual(leak["launch_order"], ["alpha/case-000", "alpha/case-001", "alpha/case-002"])
            self.assertEqual((leak["iteration"], leak["attempt"], leak["phase"]), (0, 0, "run"))
            # The case's own verdict stays its result; the leak fails the run, not the case's snapshot.
            self.assertEqual(receipt["cases"]["alpha/case-002"]["result"], "Pass")
            # The leaking launch closed after its case; the rest ran on a fresh launch.
            self.assertEqual(driver.sessions, 2)
            self.assertEqual(driver.closed, 2)
            self.assertEqual([log["cases"] for log in receipt["sessions"]],
                             [["alpha/case-000", "alpha/case-001", "alpha/case-002"],
                              ["alpha/case-003", "alpha/case-004", "alpha/case-005"]])
            self.assertEqual([log["end"] for log in receipt["sessions"]], ["leaked", "batch-end"])
            # One fixture read per launch and one reset per case.
            self.assertEqual(driver.resets, 2 + 6)
            events = [json.loads(line) for line in (tmp / "out" / "events.jsonl").read_text().splitlines()]
            mine = next(e for e in events if e["case"] == "alpha/case-002")
            self.assertEqual((mine["session"], mine["position"], mine["leaked_state"]["case"]), (0, 2, "alpha/case-002"))
            index = (tmp / "out" / "index.md").read_text()
            self.assertIn("LeakedState: alpha/case-002 left the product unlike its fixture", index)

    def test_the_last_case_of_a_launch_is_checked_too(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            driver = ResetDriver(leaks={"alpha/case-002"})
            receipt, _ = run_cases(tmp, driver, batch_limit=1, jobs=1, retry_limit=0)
            self.assertEqual(receipt["leaked_state"], ["alpha/case-002"])
            self.assertEqual(driver.sessions, 3)

    def test_a_refused_reset_is_a_leak_with_its_error(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            driver = ResetDriver(reset_raises={"alpha/case-001": "refused"})
            receipt, _ = run_cases(tmp, driver, batch_limit=10, jobs=1, retry_limit=0)
            leak = receipt["cases"]["alpha/case-001"]["leaked_state"][0]
            self.assertIn("closeTab refused", leak["error"])
            self.assertEqual(driver.sessions, 2)

    def test_a_product_lost_in_the_reset_is_a_crash_of_the_case_not_a_leak(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            driver = ResetDriver(reset_raises={"alpha/case-001": "unreachable"})
            receipt, code = run_cases(tmp, driver, batch_limit=10, jobs=1, retry_limit=0)
            self.assertEqual(code, 1)
            case = receipt["cases"]["alpha/case-001"]
            self.assertEqual((case["result"], case["outcome"]), ("Crash", "unexpected"))
            self.assertNotIn("leaked_state", case)
            self.assertEqual(receipt["leaked_state"], [])
            self.assertEqual([log["end"] for log in receipt["sessions"]], ["dirty", "batch-end"])
            events = [json.loads(line) for line in (tmp / "out" / "events.jsonl").read_text().splitlines()]
            mine = next(e for e in events if e["case"] == "alpha/case-001")
            self.assertEqual(mine["step"], "reset")
            self.assertIn("Connection refused", mine["message"])

    def test_a_crash_in_the_reset_is_retried_like_any_crash(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            driver = ResetDriver(reset_raises={"alpha/case-000": "unreachable"})
            receipt, _ = run_cases(tmp, driver, batch_limit=10, jobs=1, retry_limit=1)
            self.assertGreater(receipt["cases"]["alpha/case-000"]["attempts"], 1)

    def test_a_reset_that_asks_for_a_relaunch_is_no_leak(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=4)
            driver = ResetDriver(reset_raises={"alpha/case-001": "relaunch"})
            receipt, code = run_cases(tmp, driver, batch_limit=10, jobs=1, retry_limit=0)
            self.assertEqual((code, receipt["ok"], receipt["leaked_state"]), (0, True, []))
            self.assertEqual(receipt["cases"]["alpha/case-001"]["result"], "Pass")
            logs = receipt["sessions"]
            self.assertEqual([log["end"] for log in logs], ["relaunch", "batch-end"])
            self.assertIn("tab order", logs[0]["reason"])
            self.assertEqual([log["cases"] for log in logs],
                             [["alpha/case-000", "alpha/case-001"], ["alpha/case-002", "alpha/case-003"]])

    def test_an_unreadable_fixture_is_an_infra_error_of_the_launch_not_a_result_of_the_case(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            driver = ResetDriver(fixture_fails={1})
            receipt, code = run_cases(tmp, driver, batch_limit=10, jobs=1, retry_limit=0)
            self.assertEqual(code, 1)
            self.assertEqual(len(receipt["infra_errors"]), 1)
            self.assertIn("session 0: fixture unreadable before alpha/case-000", receipt["infra_errors"][0])
            first = receipt["cases"]["alpha/case-000"]
            self.assertEqual((first["outcome"], first["result"], first["attempts"]), ("not-run", None, 0))
            self.assertEqual([log["end"] for log in receipt["sessions"]], ["fixture-unreadable", "batch-end"])
            self.assertEqual(receipt["sessions"][0]["cases"], [])
            self.assertEqual(receipt["sessions"][1]["cases"], ["alpha/case-001", "alpha/case-002"])
            self.assertNotIn("alpha/case-000", [c for c, *_ in driver.calls])

    def test_a_case_whose_launch_had_no_fixture_runs_on_the_retry(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            driver = ResetDriver(fixture_fails={1})
            receipt, _ = run_cases(tmp, driver, batch_limit=10, jobs=1, retry_limit=1)
            first = receipt["cases"]["alpha/case-000"]
            self.assertEqual((first["result"], first["attempts"]), ("Pass", 1))
            rows = [json.loads(line) for line in (tmp / "out" / "checkpoints.jsonl").read_text().splitlines()]
            self.assertEqual({r["attempt"] for r in rows if r["case"] == "alpha/case-000"}, {1})

    def test_ms_is_the_case_alone_and_the_reset_has_its_own_time(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            receipt, _ = run_cases(tmp, ResetDriver(reset_s=0.3), batch_limit=10, jobs=1, retry_limit=0)
            events = [json.loads(line) for line in (tmp / "out" / "events.jsonl").read_text().splitlines()]
            for event in events:
                self.assertLess(event["ms"], 250, event)
                self.assertGreaterEqual(event["reset_ms"], 300, event)

    def test_a_dirty_case_skips_the_reset_check(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            driver = ResetDriver(dirty={"alpha/case-000"}, leaks={"alpha/case-000"})
            receipt, _ = run_cases(tmp, driver, batch_limit=10, jobs=1, retry_limit=0)
            self.assertEqual(receipt["leaked_state"], [])
            self.assertEqual([log["end"] for log in receipt["sessions"]], ["dirty", "batch-end"])

    def test_sessions_without_reset_state_are_not_checked(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=4)
            receipt, code = run_cases(tmp, FakeDriver(), batch_limit=10, jobs=1)
            self.assertEqual((code, receipt["leaked_state"]), (0, []))
            self.assertEqual(receipt["sessions"][0]["cases"], [f"alpha/case-{i:03d}" for i in range(4)])

    def test_order_is_recorded_and_replays_from_the_seed(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha", "beta"), per_suite=6)
            first, _ = run_cases(tmp, ResetDriver(), batch_limit=4, jobs=1, seed=7, out=tmp / "a")
            again, _ = run_cases(tmp, ResetDriver(), batch_limit=4, jobs=1, seed=7, out=tmp / "b")
            self.assertEqual(first["order"], again["order"])
            self.assertNotEqual(first["order"], sorted(first["order"]))
            self.assertEqual(first["seeds"], {"0": 7})
            ran = [cid for log in first["sessions"] for cid in log["cases"]]
            self.assertEqual(ran, first["order"])
            self.assertTrue(all(len(log["cases"]) <= 4 for log in first["sessions"]))

    def parity_runs(self, tmp, make_driver):
        """K=10 in id order, two shuffle seeds, and K=1: the fleet acceptance run of task 189."""
        configs = {"batched": dict(batch_limit=10), "seed1": dict(batch_limit=10, seed=1),
                   "seed2": dict(batch_limit=10, seed=2), "k1": dict(batch_limit=1)}
        receipts = {}
        for name, extra in configs.items():
            receipts[name], _ = run_cases(tmp, make_driver(), jobs=1, retry_limit=0, out=tmp / name, run_id=name, **extra)
        return receipts

    def order_diff(self, tmp, a, b, *extra):
        out = tmp / f"cmp-{a}-{b}"
        argv = ["diff", "--order-parity", "--out", str(out), "--expectations-root", str(tmp / "expectations"),
                "--base-run", str(tmp / a), "--head-run", str(tmp / b), *extra]
        code = quiet(oracle.main, argv)
        return code, json.loads((out / "comparison.json").read_text())

    def test_two_shuffle_seeds_and_batch_limit_one_give_the_batched_verdicts(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha", "beta"), per_suite=12)
            receipts = self.parity_runs(tmp, lambda: ResetDriver(script={"beta/case-004": ["Failure"]}))
            batched = verdicts(receipts["batched"])
            for name in ("seed1", "seed2", "k1"):
                self.assertEqual(verdicts(receipts[name]), batched, name)
                code, cmp = self.order_diff(tmp, "batched", name)
                self.assertEqual(code, 0, cmp)
                self.assertTrue(cmp["ok"])
                self.assertEqual(cmp["summary"]["equal"], 24)
            self.assertEqual(len(receipts["k1"]["sessions"]), 24)
            self.assertEqual(len(receipts["batched"]["sessions"]), 3)

    def test_an_order_dependent_leak_fails_order_parity(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=6)
            # case-003 leaks only when case-001 ran before it in its launch: batched, never with K=1.
            receipts = self.parity_runs(tmp, lambda: ResetDriver(after={"alpha/case-003": "alpha/case-001"}))
            self.assertEqual(receipts["batched"]["leaked_state"], ["alpha/case-003"])
            self.assertEqual(receipts["k1"]["leaked_state"], [])
            code, cmp = self.order_diff(tmp, "batched", "k1")
            self.assertEqual(code, 1)
            self.assertEqual(cmp["leaks_differ"], ["alpha/case-003"])
            self.assertFalse(cmp["ok"])

    def test_order_parity_refuses_another_config(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            run_cases(tmp, ResetDriver(), out=tmp / "a", run_id="a")
            run_cases(tmp, ResetDriver(), out=tmp / "b", run_id="b", build="bench")
            code, cmp = self.order_diff(tmp, "a", "b")
            self.assertEqual(code, oracle.EXIT_REFUSED)
            self.assertIn("build", cmp["refused"])
            run_cases(tmp, ResetDriver(), out=tmp / "c", run_id="c", seed=3)
            code, cmp = self.order_diff(tmp, "a", "c")
            self.assertEqual(code, 0)
            with self.assertRaises(oracle.UsageError):
                oracle.cmd_diff(oracle.build_parser().parse_args(["diff", "--order-parity", "--base-run", str(tmp / "a")]))

    def test_batch_limit_and_shuffle_arguments(self):
        parser = oracle.build_parser()

        def opts(argv):
            return oracle.options_from_args(parser.parse_args(["run", *argv]), retry_default=None, out=Path("/tmp/x"),
                                            run_id="r", switch=None, arm=None, switches={}, ref=None, binary=None)

        self.assertEqual(opts(["--product", "app"]).batch_limit, 10)
        self.assertEqual(opts(["--product", "app", "--batch-limit", "1"]).batch_limit, 1)
        self.assertEqual(opts(["--product", "daemon"]).batch_limit, 1)
        self.assertEqual(opts(["--seed", "5"]).seed, 5)
        self.assertIsNotNone(opts(["--shuffle"]).seed)
        self.assertIsNone(opts([]).seed)
        with self.assertRaises(oracle.UsageError):
            opts(["--batch-limit", "0"])


if __name__ == "__main__":
    unittest.main()
