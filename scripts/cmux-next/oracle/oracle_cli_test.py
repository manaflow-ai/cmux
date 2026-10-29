#!/usr/bin/env python3
"""Unit and end-to-end tests for oracle.py: shards, retries, flaky handling, batches, shuffle,
the run directory format, and the comparison through the real diff.py and baselines.py.

Run: python3 -I scripts/cmux-next/oracle/oracle_cli_test.py (stdlib unittest; selftest.py,
task 019, runs it too). A fake driver stands in for the products through the driver protocol.
The Expectations tests run when expectations.py (p15-oracle-015) is beside this file.
"""

from __future__ import annotations

import hashlib
import io
import json
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import unittest.mock
from contextlib import redirect_stderr, redirect_stdout
from dataclasses import replace
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import driver_app  # noqa: E402
import oracle  # noqa: E402
import switches  # noqa: E402 - the ArmNotApplied a driver raises

HAS_EXPECTATIONS = (HERE / "expectations.py").is_file()
EXAMPLE_SNAPSHOT_TEXT = (oracle.REPO / "schemas" / "oracle" / "fixtures" / "snapshot-example.json").read_text(
    encoding="utf-8")


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
    reported per case run, `launch_hits` once per session (its first case), `readback` the arms
    every case reads back; a case in `wrong_arms` raises switches.ArmNotApplied.
    """

    def __init__(self, script=None, value_of=None, dirty=(), raises=(), hits=None, launch_hits=None, readback=None,
                 wrong_arms=()):
        self.script = script or {}
        self.value_of = value_of or (lambda cid, n: "v-" + cid)
        self.dirty = set(dirty)
        self.raises = set(raises)
        self.hits = hits
        self.launch_hits = launch_hits
        self.readback = readback
        self.wrong_arms = set(wrong_arms)
        self.launched = set()
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
        if cid in self.wrong_arms:
            raise switches.ArmNotApplied(["f6=new: snapshot.switches read back app.f6=old"], {"f6": "old"})
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
        if self.readback is not None:
            result["switch_readback"] = self.readback
        with self.mutex:
            first_of_session = session not in self.launched
            self.launched.add(session)
        if self.launch_hits is not None and first_of_session:
            result["launch_switch_hits"] = self.launch_hits
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


class SwitchArmReceiptTests(unittest.TestCase):
    """p15-oracle-049: the receipt logs each arm read back, and an arm-not-applied stops the run."""

    def setUp(self):
        raw = tempfile.TemporaryDirectory()
        self.addCleanup(raw.cleanup)
        self.tmp = Path(raw.name)
        write_corpus(self.tmp / "corpus", per_suite=4)

    def test_the_readback_is_logged_per_case_and_per_run(self):
        driver = FakeDriver(hits={"f6": {"new": 1}}, launch_hits={"f6": {"new": 2}}, readback={"f6": "new"})
        receipt, code = run_cases(self.tmp, driver, switch="f6", arm="new", batch_limit=4, jobs=1)
        self.assertEqual(code, 0, receipt)
        self.assertEqual(receipt["switch_readback"], {"f6": {"new": 12}})
        self.assertEqual(receipt["cases"]["alpha/case-000"]["switch_readback"], {"f6": "new"})
        self.assertTrue(receipt["arm_applied"])
        self.assertIsNone(receipt["arm_not_applied"])
        # 3 launches of 4 cases each: launch hits count with the case hits.
        self.assertEqual(receipt["launch_switch_hits"], {"f6": {"new": 6}})
        self.assertEqual(receipt["switch_hits"], {"f6": {"new": 18}})
        on_disk = json.loads((self.tmp / "out" / "receipt.json").read_text())
        self.assertEqual(on_disk["switch_readback"], {"f6": {"new": 12}})
        self.assertEqual(on_disk["cases"]["beta/case-003"]["switch_readback"], {"f6": "new"})

    def test_a_launch_only_site_exercises_the_arm(self):
        driver = FakeDriver(launch_hits={"f6": {"new": 1}}, readback={"f6": "new"})
        receipt, code = run_cases(self.tmp, driver, switch="f6", arm="new", batch_limit=12, jobs=1)
        self.assertEqual(code, 0, receipt)
        self.assertTrue(receipt["arm_exercised"])

    def test_another_arm_read_back_fails_the_run(self):
        driver = FakeDriver(hits={"f6": {"new": 1}}, readback={"f6": "old"})
        receipt, code = run_cases(self.tmp, driver, switch="f6", arm="new")
        self.assertEqual(code, 1)
        self.assertFalse(receipt["arm_applied"])
        driver = FakeDriver(hits={"f6": {"new": 1}})
        receipt, code = run_cases(self.tmp, driver, switch="f6", arm="new")
        self.assertFalse(receipt["arm_applied"], "no readback proves no arm")

    def test_a_malformed_readback_is_a_crash(self):
        result = oracle.coerce_result({"status": "Pass", "switch_readback": {"f6": 1}})
        self.assertEqual(result["status"], "Crash")
        self.assertIn("malformed switch_readback", result["message"])

    def test_one_arm_mismatch_stops_the_run_with_no_retry(self):
        driver = FakeDriver(wrong_arms={"alpha/case-000"})
        receipt, code = run_cases(self.tmp, driver, switch="f6", arm="new", batch_limit=4, jobs=1, retry_limit=3)
        self.assertEqual(code, 1)
        self.assertEqual(driver.sessions, 1, "one launch, no relaunch per case")
        self.assertEqual([(cid, phase) for cid, phase, *_ in driver.calls], [("alpha/case-000", "run")])
        self.assertEqual(receipt["arm_not_applied"], {
            "verdict": "arm-not-applied", "case": "alpha/case-000", "phase": "run",
            "problems": ["f6=new: snapshot.switches read back app.f6=old"], "readback": {"f6": "old"}})
        self.assertEqual(receipt["counts"], {"not-run": 12})
        self.assertEqual(receipt["switch_readback"], {"f6": {"old": 1}})
        self.assertFalse(receipt["arm_applied"])
        self.assertFalse(receipt["ok"])
        self.assertIn("arm-not-applied at alpha/case-000", (self.tmp / "out" / "index.md").read_text())

    def test_parallel_batches_stop_too(self):
        driver = FakeDriver(wrong_arms={f"{s}/case-{i:03d}" for s in ("alpha", "beta", "gamma") for i in range(4)})
        receipt, code = run_cases(self.tmp, driver, batch_limit=1, jobs=4, retry_limit=3)
        self.assertEqual(code, 1)
        self.assertTrue(all(phase == "run" for _, phase, *_ in driver.calls), "no retry phase ran")
        self.assertLessEqual(len(driver.calls), 4, "only batches already running reach a case")
        self.assertEqual(receipt["arm_not_applied"]["verdict"], "arm-not-applied")

    def test_the_merge_keeps_the_refusal_and_sums_the_readback(self):
        outs = []
        for i in range(2):
            out = self.tmp / f"s{i}"
            driver = FakeDriver(readback={"f6": "new"}, hits={"f6": {"new": 1}},
                                wrong_arms={"gamma/case-003"} if i == 1 else ())
            run_cases(self.tmp, driver, shard=(i, 2), out=out, run_id=f"r{i}", switch="f6", arm="new", jobs=1)
            outs.append(out)
        view, errors = oracle.merge_runs(outs, require_complete=True)
        self.assertEqual(errors, [])
        self.assertEqual(view.receipt["arm_not_applied"]["case"], "gamma/case-003")
        self.assertFalse(view.receipt["ok"])
        side = oracle.Side("new", "f6", "new", {"f6": "new"}, None, None)
        self.assertIn("arm-not-applied: the new side f6=new: snapshot.switches read back app.f6=old",
                      oracle.side_refusal(view.receipt, side))

    def test_an_unknown_switch_aborts_before_any_product_starts(self):
        opened = []
        with self.assertRaisesRegex(oracle.UsageError, r"unknown switch: ghost: no .*ghost\.json; nothing ran"):
            oracle.run_one(options(self.tmp, switch="ghost", arm="new", switches={"ghost": "new"}),
                           open_session=lambda ctx: opened.append(ctx))
        self.assertEqual(opened, [])


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
            self.assertEqual(set(receipt["host"]), {"name", "os", "osVersion", "arch", "display"})
            self.assertEqual(receipt["cases"]["alpha/case-000"]["result"], "Pass")
            rows = [json.loads(line) for line in (tmp / "out" / "checkpoints.jsonl").read_text().splitlines()]
            self.assertEqual(len(rows), 4)
            row = rows[1]
            self.assertEqual({k: row[k] for k in ("case", "suite", "step", "index", "checkpoint", "attempt", "result")},
                             {"case": "alpha/case-000", "suite": "alpha", "step": "s1", "index": 0,
                              "checkpoint": "settled", "attempt": 0, "result": "Pass"})
            self.assertEqual(row["sha256"], oracle.snapshot_sha256(row["snapshot"]))


def profile(*displays):
    return {"SPDisplaysDataType": [{"_name": "Apple M4 Pro", "spdisplays_ndrvs": list(displays)}]}


MAIN = {"_name": "Display", "_spdisplays_pixels": "3840 x 2160", "_spdisplays_resolution": "1920 x 1080 @ 60.00Hz",
        "spdisplays_main": "spdisplays_yes"}
SIDE = {"_name": "Virtual", "_spdisplays_pixels": "1920 x 1200", "_spdisplays_resolution": "1920 x 1200 @ 120.00Hz"}


class DisplayTests(unittest.TestCase):
    """The receipt's host.display (task 008): what diff.py's same-host policy compares."""

    def on_mac(self, value):
        with unittest.mock.patch.object(oracle.sys, "platform", "darwin"):
            return oracle.display_info(lambda: value)

    def test_main_display_with_points_pixels_and_count(self):
        self.assertEqual(self.on_mac(profile(MAIN)), "1920 x 1080 @ 60.00Hz (3840 x 2160 px), 1 display")
        self.assertEqual(self.on_mac(profile(SIDE, MAIN)), "1920 x 1080 @ 60.00Hz (3840 x 2160 px), 2 displays")

    def test_a_second_display_changes_the_value(self):
        self.assertNotEqual(self.on_mac(profile(MAIN)), self.on_mac(profile(MAIN, SIDE)))

    def test_no_display_is_none_and_unknown_is_not_recorded(self):
        self.assertEqual(self.on_mac(profile()), "none")
        self.assertIsNone(self.on_mac(None))
        self.assertIsNone(self.on_mac(profile(SIDE, dict(SIDE, _name="other"))))  # two displays, none main
        self.assertIsNone(self.on_mac(profile({"spdisplays_main": "spdisplays_yes"})))

    def test_off_macos_is_none_without_reading(self):
        def unread():
            raise AssertionError("read the display profile off macOS")
        with unittest.mock.patch.object(oracle.sys, "platform", "linux"):
            self.assertEqual(oracle.display_info(unread), "none")


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
        # run_one checks each switch's key in the product catalog before anything starts;
        # the registry's app key is in this test's catalog, not in the checkout's.
        catalog = self.tmp / "RefactorSwitches.swift"
        catalog.write_text(f'public enum RefactorSwitchKey: String {{\n    case layerHosting = "{APP_KEY}"\n}}\n')
        roots = oracle.switch_roots
        patch = mock.patch.object(oracle, "switch_roots",
                                  lambda registry: replace(roots(registry), app_catalog=catalog))
        patch.start()
        self.addCleanup(patch.stop)

    def argv(self, *extra):
        return ["diff", "--switch", SWITCH, "--switch-registry", str(self.registry), "--corpus", str(self.tmp / "corpus"),
                "--expectations-root", str(self.tmp / "expectations"), "--out", str(self.tmp / "cmp"), "--jobs", "4",
                "--ref", "0" * 40, "--isolation", "none", *extra]

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


class EngineSession(FakeSession):
    """One launch of EngineDriver's app, with the engine its browser tabs take and the run's engine arm."""

    def __init__(self, driver: "EngineDriver", number: int, engine: str, arm) -> None:
        super().__init__(driver, number)
        self.engine = engine
        self.arm = arm

    def run_case(self, case, ctx):
        return self.driver.run_engine(case, ctx, self)


def tagged_sha256(text: str) -> str:
    return "sha256:" + hashlib.sha256(text.encode("utf-8")).hexdigest()


class EngineDriver(FakeDriver):
    """The app as driver_app.AppSession sees it: a schema-valid snapshot (schemas/oracle/fixtures/snapshot-example.json)
    canonicalized by the real normalize.py, on an engine arm without the tabs' engine (driver_app.ENGINE_DROP) and
    with the raw tabs' engines as `engines`, unless `keeps_engine`. The default-engine tab takes the launch's engine
    (the arm's, else the app default chromium) unless `ignores_engine`, and with `pinned_webkit` each case also has
    a WebKit tab in a pane of its own (misc/_tuning.json: TabLifecycle.newBrowser engine webkit), so the chromium
    arm's panes hold both engines and their set order would follow the engine. The daemon and the app settings
    hash each arm's own config, as the real arms do. `differs` gives those cases another load state on the WebKit
    arm (an engine defect)."""

    canonicalize = None

    def __init__(self, ignores_engine=False, differs=(), keeps_engine=False, pinned_webkit=True):
        super().__init__()
        self.ignores_engine = ignores_engine
        self.differs = set(differs)
        self.keeps_engine = keeps_engine
        self.pinned_webkit = pinned_webkit
        self.engines = []
        self.cases = {}
        if EngineDriver.canonicalize is None:
            EngineDriver.canonicalize = staticmethod(driver_app.normalize_canonicalizer()[0])

    def open_session(self, ctx):
        with self.mutex:
            self.sessions += 1
            self.engines.append(ctx.get("engine"))
            engine = "chromium" if self.ignores_engine else ctx.get("engine") or "chromium"
            return EngineSession(self, self.sessions, engine, ctx.get("engine"))

    def snapshot(self, engine, case_id):
        doc = json.loads(EXAMPLE_SNAPSHOT_TEXT)
        facets = doc["facets"]
        tab = facets["tabs"]["panes"][0]["tabs"][0]

        def pane(number, kind, name, load):
            tab_id = f"tab_{number + 16:032x}"
            return {"pane": f"pane_{number:032x}", "selected": tab_id,
                    "tabs": [{**tab, "tab": tab_id, "engine": kind, "url": f"$WEB/{name}.html", "loadState": load}]}

        load = "failed" if engine == "webkit" and case_id in self.differs else "finished"
        panes = [pane(0xa2, oracle.ENGINE_READBACK[engine], "b", load)]
        if self.pinned_webkit:
            panes.insert(0, pane(0xa1, "webkit", "a", "finished"))
        facets["tabs"]["panes"] = panes
        facets["daemon"]["settings"].update(effective_sha256=tagged_sha256("effective " + engine),
                                            file_sha256=tagged_sha256("file " + engine))
        facets["settings"]["effectiveSha256"] = tagged_sha256("app " + engine)
        if engine == "webkit":
            facets["settings"]["nonDefaultKeys"].append("browser.defaultEngine")
        facets["liveObjects"]["cefBrowsers"] = 1 if engine == "chromium" else 0
        return doc

    def run_engine(self, case, ctx, session):
        with self.mutex:
            self.cases[ctx["case_id"]] = case
        raw = [self.snapshot(session.engine, ctx["case_id"]) for _ in range(2)]
        drop = (driver_app.ENGINE_DROP,) if session.arm is not None and not self.keeps_engine else ()
        paths = driver_app.OraclePaths(Path("/tmp/o/engine-parity-test"))
        values = EngineDriver.canonicalize(raw, paths, ["s1/before", "s1/settled"], drop)
        rows = [{"step": "s1", "checkpoint": cp, "snapshot": value} for cp, value in zip(("before", "settled"), values)]
        if session.arm is not None:
            for row, snapshot in zip(rows, raw):
                row["engines"] = driver_app.tab_engines(snapshot)
        return {"status": "Pass", "checkpoints": rows}


class EngineParityTests(unittest.TestCase):
    """Engine parity (p15-oracle-113): `--engine` arms, the readback check, the engine-neutral canonicalization and
    the tests/oracle/engine-parity.json differences, through the real normalize.py and diff.py."""

    def setUp(self):
        self.raw = tempfile.TemporaryDirectory()
        self.addCleanup(self.raw.cleanup)
        self.tmp = Path(self.raw.name)
        pinned = {"id": "browser/pinned", "requires": ["chromium"], "environment": {"engine": "chromium"},
                  "steps": [{"id": "s1", "op": "snapshot"}]}
        none = {"id": "browser/no-engine", "environment": {"engine": "none"}, "steps": [{"id": "s1", "op": "snapshot"}]}
        write_corpus(self.tmp / "corpus", suites=("browser",), per_suite=2,
                     extra={"browser/pinned": pinned, "browser/no-engine": none})

    def run_arm(self, label, engine, driver, product="app"):
        cases, _ = oracle.load_corpus(self.tmp / "corpus")
        receipt, _ = quiet(oracle.perform_run, options(self.tmp, product=product, engine=engine, out=self.tmp / label,
                                                       run_id=label), cases, driver.open_session, None, {})
        return receipt

    def diff(self, *extra):
        argv = ["diff", "--out", str(self.tmp / "cmp"), "--expectations-root", str(self.tmp / "expectations"),
                "--base-run", str(self.tmp / "webkit"), "--head-run", str(self.tmp / "chromium"), *extra]
        code = quiet(oracle.main, argv)
        return code, json.loads((self.tmp / "cmp" / "comparison.json").read_text())

    def arms(self, webkit=None, chromium=None):
        self.run_arm("webkit", "webkit", webkit or EngineDriver())
        self.run_arm("chromium", "chromium", chromium or EngineDriver())

    def rows(self, label):
        return [json.loads(line) for line in (self.tmp / label / "checkpoints.jsonl").read_text().splitlines()]

    def test_parse_engines(self):
        self.assertEqual(oracle.parse_engines("webkit,chromium"), ("webkit", "chromium"))
        self.assertEqual(oracle.parse_engines(" chromium , webkit "), ("chromium", "webkit"))
        for text in ("webkit", "webkit,webkit", "webkit,gecko", "webkit,chromium,webkit", ""):
            with self.assertRaises(oracle.UsageError, msg=text):
                oracle.parse_engines(text)

    def test_the_arm_sets_the_launch_engine_and_a_pinned_case_runs_on_it(self):
        driver = EngineDriver()
        receipt = self.run_arm("webkit", "webkit", driver)
        self.assertEqual(set(driver.engines), {"webkit"})
        self.assertEqual(receipt["config"]["engine"], "webkit")
        self.assertEqual(driver.cases["browser/pinned"]["environment"]["engine"], "webkit")
        self.assertEqual(driver.cases["browser/no-engine"]["environment"]["engine"], "none")
        self.assertNotIn("environment", driver.cases["browser/case-000"])
        on_disk = json.loads((self.tmp / "corpus" / "browser" / "pinned.json").read_text())
        self.assertEqual(on_disk["environment"]["engine"], "chromium", "the corpus file is never changed")
        default = EngineDriver()
        self.assertIsNone(self.run_arm("default", None, default)["config"]["engine"])
        self.assertEqual(default.cases["browser/pinned"]["environment"]["engine"], "chromium")

    def test_an_engine_arm_needs_a_product_that_draws_browser_tabs(self):
        parser = oracle.build_parser()
        args = parser.parse_args(["run", "--product", "daemon", "--engine", "webkit"])
        with self.assertRaises(oracle.UsageError):
            oracle.options_from_args(args, retry_default=None, out=Path("/tmp/x"), run_id="r", switch=None, arm=None,
                                     switches={}, ref=None, binary=None, engine=args.engine)
        for argv in (["--engine", "webkit,chromium", "--product", "daemon"],
                     ["--engine", "webkit,chromium", "--base-run", "a", "--head-run", "b"],
                     ["--engine", "webkit,chromium", "--switch", "x"],
                     ["--engine", "webkit"]):
            with self.assertRaises(oracle.UsageError, msg=argv):
                oracle.cmd_diff(parser.parse_args(["diff", "--out", str(self.tmp / "refused"), *argv]))

    def test_mixed_engine_panes_pass_and_every_arm_difference_is_explained(self):
        self.arms()
        code, cmp = self.diff()
        self.assertEqual(code, 0, cmp)
        self.assertTrue(cmp["ok"])
        self.assertEqual(cmp["divergent"], [])
        self.assertEqual(cmp["compared"], 4)
        parity = cmp["engine_parity"]
        self.assertEqual(parity["engines"], {"base": "webkit", "head": "chromium"})
        self.assertEqual(parity["readback"], {"base": {"webkit": 16}, "head": {"cef": 8, "webkit": 8}})
        report = json.loads(Path(cmp["divergence"]).read_text())
        explained = {e["pointer"] for case in report["cases"] for e in case.get("explained") or ()}
        self.assertEqual(explained, {"/facets/daemon/settings/effective_sha256", "/facets/daemon/settings/file_sha256",
                                     "/facets/settings/effectiveSha256", "/facets/settings/nonDefaultKeys",
                                     "/facets/liveObjects/cefBrowsers"})
        for label in ("webkit", "chromium"):
            tabs = [tab for row in self.rows(label) for tab in oracle.browser_tabs(row["snapshot"])]
            self.assertTrue(tabs)
            self.assertTrue(all("engine" not in tab and "loadState" in tab for tab in tabs), label)
            urls = [[p["tabs"][0]["url"] for p in row["snapshot"]["facets"]["tabs"]["panes"]] for row in self.rows(label)]
            self.assertEqual({tuple(u) for u in urls}, {("$WEB/a.html", "$WEB/b.html")}, label)

    def test_an_arm_canonicalized_with_the_engine_is_refused(self):
        # Kept through canonicalization, the engine orders the chromium arm's panes cef first: no later drop
        # can undo that, so the comparison is refused instead of reporting a false pane divergence.
        self.arms(chromium=EngineDriver(keeps_engine=True))
        urls = [p["tabs"][0]["url"] for p in self.rows("chromium")[0]["snapshot"]["facets"]["tabs"]["panes"]]
        self.assertEqual(urls, ["$WEB/b.html", "$WEB/a.html"])
        code, cmp = self.diff()
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertTrue(cmp["refused"].startswith("engine-not-neutral: side head checkpoint browser/"), cmp["refused"])

    def test_any_other_tab_difference_is_a_divergence(self):
        self.arms(webkit=EngineDriver(differs={"browser/pinned"}))
        code, cmp = self.diff()
        self.assertEqual(code, 1)
        self.assertEqual(cmp["divergent"], ["browser/pinned"])
        report = json.loads(Path(cmp["divergence"]).read_text())
        self.assertTrue(report["divergences"][0]["pointer"].startswith("/facets/tabs/panes/"), report["divergences"][0])

    def test_an_arm_that_reads_back_the_other_engine_is_refused(self):
        self.arms(webkit=EngineDriver(ignores_engine=True, pinned_webkit=False),
                  chromium=EngineDriver(pinned_webkit=False))
        code, cmp = self.diff()
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertTrue(cmp["refused"].startswith("engine-not-exercised: side base (--engine webkit)"), cmp["refused"])
        self.assertFalse(cmp["ok"])
        self.assertIsNone(cmp["diff_exit"])

    def test_a_pinned_webkit_tab_alone_does_not_exercise_the_arm(self):
        self.arms(webkit=EngineDriver(ignores_engine=True))
        code, cmp = self.diff()
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertTrue(cmp["refused"].startswith("engine-not-exercised: both arms read back the same"), cmp["refused"])

    def test_an_engine_arm_against_the_default_engine_is_refused(self):
        self.run_arm("webkit", "webkit", EngineDriver())
        self.run_arm("chromium", None, EngineDriver())
        code, cmp = self.diff()
        self.assertEqual(code, oracle.EXIT_REFUSED)
        self.assertIn("one side ran the app's default engine", cmp["refused"])

    def test_one_engine_on_both_sides_is_an_ordinary_comparison(self):
        self.run_arm("webkit", "chromium", EngineDriver())
        self.run_arm("chromium", "chromium", EngineDriver())
        code, cmp = self.diff()
        self.assertEqual(code, 0, cmp)
        self.assertIsNone(cmp["engine_parity"])

    def test_the_engine_parity_file_is_diff_py_rules_each_with_a_reason_and_task(self):
        diff = oracle.require_sibling("diff", "p15-oracle-014")
        rules = diff.load_rules(str(oracle.ENGINE_PARITY_FILE))
        self.assertTrue(rules)
        for rule in rules:
            self.assertTrue(rule.pointer.startswith("/facets/"), rule.pointer)
            self.assertTrue(rule.task, rule.pointer)
            self.assertNotEqual(rule.pointer.split("/")[2], "tabs", "the tabs' engine is dropped, not explained")


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


# Task 183: registry switches with their planned arm unlike the default (motion's planned arm is its default).
SWITCH_REGISTRY = {
    "cef-helper": {"default": "old", "planned": "new"},
    "discard": {"default": "old", "planned": "new"},
    "holder": {"default": "old", "planned": "new"},
    "intents": {"default": "new", "planned": "old"},
    "motion": {"default": "new", "planned": "new"},
    "overlay": {"default": "old", "planned": "new"},
}


def planned_app_key(name: str) -> str:
    return f"oracle.test.{name}"


def write_planned_registry(root: Path, entries=None) -> Path:
    root.mkdir(parents=True, exist_ok=True)
    for name, entry in (entries or SWITCH_REGISTRY).items():
        (root / f"{name}.json").write_text(json.dumps({"name": name, "expected_differences": [],
                                                       "app_key": planned_app_key(name), **entry}))
    return root


def write_planned_catalog(path: Path) -> Path:
    """A RefactorSwitchKey enum with every SWITCH_REGISTRY app key: run_one checks each requested switch's
    key in the product catalog before anything starts (p15-oracle-049)."""
    cases = "".join(f'    case k{index} = "{planned_app_key(name)}"\n' for index, name in enumerate(SWITCH_REGISTRY))
    path.write_text(f"public enum RefactorSwitchKey: String {{\n{cases}}}\n")
    return path


class PlannedArmSession:
    def __init__(self, driver: "PlannedArmDriver", arms):
        self.driver = driver
        self.arms = arms

    def run_case(self, case, ctx):
        planted = all(self.arms[name] == SWITCH_REGISTRY[name]["planned"] for name in self.driver.culprits)
        value = "interaction" if self.driver.culprits and planted and ctx["case_id"] == self.driver.case else "v"
        return {
            "status": "Pass",
            "checkpoints": [{"step": "s1", "checkpoint": "settled", "snapshot": {"value": value}}],
            "switch_readback": dict(self.arms),
        }

    def close(self) -> None:
        pass


class PlannedArmDriver:
    """A product that reads its switches once per launch (the frozen value of p15-oracle-180) and reports
    the arms it read back. `ignore` names switches it never applies (it reads back their default); the
    case `case` diverges when every switch of `culprits` runs its planned arm (a planted interaction)."""

    def __init__(self, culprits=(), ignore=(), case="alpha/case-001"):
        self.culprits = tuple(culprits)
        self.ignore = set(ignore)
        self.case = case
        self.launches = []

    def open_session(self, ctx):
        asked = ctx["switches"]
        arms = {name: entry["default"] if name in self.ignore else asked.get(name, entry["default"])
                for name, entry in SWITCH_REGISTRY.items()}
        self.launches.append(dict(asked))
        return PlannedArmSession(self, arms)


def read_back_arms(receipt):
    """{name: [arms read back]} of a receipt's switch_readback counters."""
    counts = receipt["switch_readback"]
    return {name: oracle.arms_seen(counts, name) for name in counts if oracle.arms_seen(counts, name)}


class SwitchArmTests(unittest.TestCase):
    """Task 183: `--arm launch-config` receipts list every arm read back; `bisect-switches` names the
    smallest set, the same for a seed every time."""

    def setUp(self):
        raw = tempfile.TemporaryDirectory()
        self.addCleanup(raw.cleanup)
        catalog = write_planned_catalog(Path(raw.name) / "RefactorSwitches.swift")
        roots = oracle.switch_roots
        patch = mock.patch.object(oracle, "switch_roots",
                                  lambda registry: replace(roots(registry), app_catalog=catalog))
        patch.start()
        self.addCleanup(patch.stop)

    def planned(self):
        return oracle.resolve_switches(SWITCH_REGISTRY, None, "launch-config")

    def test_launch_config_sets_every_switch_to_its_planned_arm(self):
        self.assertEqual(self.planned(), {name: entry["planned"] for name, entry in SWITCH_REGISTRY.items()})
        with self.assertRaisesRegex(oracle.UsageError, "without a planned arm: holder"):
            oracle.resolve_switches({"holder": {"default": "old"}}, None, "launch-config")

    def test_launch_config_receipt_lists_every_arm_read_back(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            receipt, code = run_cases(tmp, PlannedArmDriver(), arm="launch-config", switches=self.planned())
            self.assertEqual(code, 0)
            self.assertEqual(read_back_arms(receipt), {name: [arm] for name, arm in self.planned().items()})
            self.assertEqual(receipt["arms_read_back"], {"ok": True, "missing": [], "wrong": {}})
            self.assertEqual(receipt["arm"], "launch-config")
            # The all-default side asks for nothing, so it has nothing to check, and still lists what it read.
            receipt, code = run_cases(tmp, PlannedArmDriver(), out=tmp / "default", arm="default")
            self.assertEqual(code, 0)
            self.assertIsNone(receipt["arms_read_back"])
            self.assertEqual(read_back_arms(receipt)["holder"], ["old"])

    def test_a_switch_the_product_did_not_apply_fails_the_run_and_the_diff(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            run_cases(tmp, PlannedArmDriver(), out=tmp / "base", run_id="b", arm="default")
            receipt, code = run_cases(tmp, PlannedArmDriver(ignore={"holder"}), out=tmp / "head", run_id="h",
                                      arm="launch-config", switches=self.planned())
            self.assertEqual(code, 1)
            self.assertFalse(receipt["ok"])
            self.assertEqual(receipt["arms_read_back"]["wrong"], {"holder": ["old"]})
            code = quiet(oracle.main, ["diff", "--base-run", str(tmp / "base"), "--head-run", str(tmp / "head"),
                                       "--out", str(tmp / "cmp"), "--expectations-root", str(tmp / "expectations")])
            comparison = json.loads((tmp / "cmp" / "comparison.json").read_text())
            self.assertEqual(code, oracle.EXIT_REFUSED)
            self.assertEqual(comparison["refused"], "arms-not-read-back: side b; holder read back old")

    def test_a_driver_that_reads_back_nothing_is_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=1)
            receipt, code = run_cases(tmp, FakeDriver(), arm="launch-config", switches={"holder": "new"})
            self.assertEqual(code, 1)
            self.assertEqual(receipt["arms_read_back"], {"ok": False, "missing": ["holder"], "wrong": {}})

    def test_sides_that_read_back_the_same_arms_are_refused(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            run_cases(tmp, PlannedArmDriver(), out=tmp / "base", run_id="b", arm="default")
            # motion's planned arm is its default: asking for it explicitly reads back what all-default does.
            run_cases(tmp, PlannedArmDriver(), out=tmp / "head", run_id="h", switches={"motion": "new"})
            code = quiet(oracle.main, ["diff", "--base-run", str(tmp / "base"), "--head-run", str(tmp / "head"),
                                       "--out", str(tmp / "cmp"), "--expectations-root", str(tmp / "expectations")])
            comparison = json.loads((tmp / "cmp" / "comparison.json").read_text())
            self.assertEqual(code, oracle.EXIT_REFUSED)
            self.assertTrue(comparison["refused"].startswith("arms-read-back-same: both sides read back"))

    def test_merged_shards_union_their_read_back_arms(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", per_suite=4)
            outs = []
            for i in range(2):
                outs.append(tmp / f"s{i}")
                run_cases(tmp, PlannedArmDriver(), shard=(i, 2), out=outs[-1], run_id=f"r{i}", arm="launch-config",
                          switches=self.planned())
            view, errors = oracle.merge_runs(outs, require_complete=True)
            self.assertEqual(errors, [])
            self.assertEqual(read_back_arms(view.receipt), {name: [arm] for name, arm in self.planned().items()})
            self.assertTrue(view.receipt["arms_read_back"]["ok"])
            self.assertTrue(view.receipt["ok"])

    def test_malformed_switch_readback_is_a_crash(self):
        result = oracle.coerce_result({"status": "Pass", "checkpoints": [], "switch_readback": {"holder": 1}})
        self.assertEqual(result["status"], "Crash")
        self.assertIn("switch_readback", result["message"])

    def test_explicit_switch_sets(self):
        self.assertEqual(oracle.resolve_switches(SWITCH_REGISTRY, None, None, "overlay=new, holder=new"),
                         {"holder": "new", "overlay": "new"})
        for text, error in (("holder", "NAME=old"), ("ghost=new", "ghost"), ("holder=new,holder=old", "twice"),
                            (",", "needs NAME=ARM")):
            with self.assertRaisesRegex(oracle.UsageError, error):
                oracle.resolve_switches(SWITCH_REGISTRY, None, None, text)
        with self.assertRaisesRegex(oracle.UsageError, "explicit set"):
            oracle.resolve_switches(SWITCH_REGISTRY, None, "launch-config", "holder=new")
        side = oracle.Side("probe-000", None, None, {"overlay": "new", "holder": "new"}, "abc", None)
        self.assertEqual(oracle.side_run_args(side), ["--switches", "holder=new,overlay=new"])
        self.assertEqual(oracle.side_arm(side), "-")
        launch = oracle.Side("launch-config", None, "launch-config", self.planned(), "abc", None)
        self.assertEqual(oracle.side_run_args(launch), [])

    def bisect(self, tmp, driver, *extra, out="bisect"):
        argv = ["bisect-switches", "alpha/case-001", "--corpus", str(tmp / "corpus"),
                "--switch-registry", str(tmp / "registry"), "--expectations-root", str(tmp / "expectations"), "--state-base", "/tmp/o", "--isolation", "none",
                "--out", str(tmp / out), *extra]
        args = oracle.build_parser().parse_args(argv)
        code = quiet(oracle.bisect_switches, args, open_session=driver.open_session)
        return code, json.loads((tmp / out / "bisect.json").read_text())

    def test_bisect_names_a_planted_two_switch_interaction(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=3)
            write_planned_registry(tmp / "registry")
            code, found = self.bisect(tmp, PlannedArmDriver(culprits=("holder", "overlay")), "--seed", "7")
            self.assertEqual(code, 1)
            self.assertEqual((found["verdict"], found["switches"], found["minimality"]),
                             ("found", {"holder": "new", "overlay": "new"}, "smallest"))
            self.assertEqual(found["seed"], 7)
            self.assertEqual(found["inert"], ["motion"])
            self.assertEqual(found["probes"][0]["switches"], {k: v for k, v in self.planned().items() if k != "motion"})
            # Every probe ran its set at the planned arm and read it back; the default run asked for nothing.
            for probe in found["probes"]:
                receipt = json.loads((Path(probe["run"]) / "receipt.json").read_text())
                self.assertTrue(receipt["arms_read_back"]["ok"], probe)
                self.assertEqual(receipt["config"]["switches"], probe["switches"])
            # The same seed probes the same sets in the same order.
            code, again = self.bisect(tmp, PlannedArmDriver(culprits=("holder", "overlay")), "--seed", "7", out="again")
            self.assertEqual(code, 1)
            self.assertEqual([(p["switches"], p["verdict"]) for p in again["probes"]],
                             [(p["switches"], p["verdict"]) for p in found["probes"]])
            self.assertEqual(again["order"], found["order"])
            # Another seed takes another path to the same pair.
            code, other = self.bisect(tmp, PlannedArmDriver(culprits=("holder", "overlay")), "--seed", "8", out="other")
            self.assertEqual((code, other["switches"]), (1, {"holder": "new", "overlay": "new"}))

    def test_bisect_without_a_divergence_is_not_reproducible(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            write_planned_registry(tmp / "registry")
            code, found = self.bisect(tmp, PlannedArmDriver(), "--seed", "3")
            self.assertEqual(code, 0)
            self.assertEqual((found["verdict"], found["switches"], len(found["probes"])), ("not-reproducible", {}, 1))

    def test_bisect_stops_on_a_probe_whose_arms_did_not_read_back(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            write_planned_registry(tmp / "registry")
            code, found = self.bisect(tmp, PlannedArmDriver(culprits=("holder",), ignore={"discard"}), "--seed", "3")
            self.assertEqual(code, oracle.EXIT_REFUSED)
            self.assertEqual(found["verdict"], "unreliable")
            self.assertIn("arms-not-read-back", found["reason"])

    def test_bisect_refuses_a_selection_of_its_own(self):
        with tempfile.TemporaryDirectory() as raw:
            tmp = Path(raw)
            write_corpus(tmp / "corpus", suites=("alpha",), per_suite=2)
            write_planned_registry(tmp / "registry")
            with self.assertRaisesRegex(oracle.UsageError, "no --suite"):
                self.bisect(tmp, PlannedArmDriver(), "--suite", "alpha")
            args = oracle.build_parser().parse_args(
                ["bisect-switches", "alpha/*", "--corpus", str(tmp / "corpus"), "--switch-registry", str(tmp / "registry"),
                 "--isolation", "none", "--out", str(tmp / "glob")])
            with self.assertRaisesRegex(oracle.UsageError, "selects 2 cases"):
                quiet(oracle.bisect_switches, args, open_session=PlannedArmDriver().open_session)


if __name__ == "__main__":
    unittest.main()
