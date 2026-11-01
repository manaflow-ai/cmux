#!/usr/bin/env python3
"""verify.py: culprit verification by the strict rule, ABBA on one pinpoint host, stored on the group.

  python3 -m unittest scripts/perf-lab/tests/test_verify.py
"""
from __future__ import annotations

import importlib.util
import sqlite3
import sys
import tempfile
import unittest
from dataclasses import replace
from datetime import datetime, timezone
from pathlib import Path

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


store = _load("perf_lab_store", LAB / "store.py")
verify = _load("perf_lab_verify", LAB / "verify.py")

NOW = datetime(2026, 10, 25, 12, 0, tzinfo=timezone.utc)
CLASS = "apple-m4/16gb/60hz"
HOSTS = (
    verify.LabHost("cmux15", CLASS, "waterfall"),
    verify.LabHost("cmux17", CLASS, "pinpoint"),
    verify.LabHost("cmux16", CLASS, "pinpoint"),
    verify.LabHost("cmux20-bench", "apple-m4-pro/48gb/120hz", "pinpoint"),
)
PARENT_SHA = "a" * 40
CULPRIT_SHA = "b" * 40

# One sample per attempt, 20 attempts per arm.
BASE = [10 + 0.1 * (i % 7) for i in range(20)]
SLOWER = [x + 0.3 for x in BASE]  # strict DIFFERENT, p ~ 0.0001
# catapult's own example: MWU 0.0195 (two-sided), KS 0.4973 -> floored DIFFERENT, strict UNKNOWN (HT(20) 0.0859).
FLAT = [0.0] * 20
FEW_SLOW = [0.0] * 15 + [1.0] * 5


def request(**changes) -> verify.Request:
    base = verify.Request(group_id=1, parent_sha=PARENT_SHA, culprit_sha=CULPRIT_SHA,
                          story="terminal.key-frame.light", metric="key_to_frame_ms", host_class=CLASS,
                          better="lower")
    return replace(base, **changes)


def runner_for(parent: list[float], culprit: list[float], log: list | None = None):
    """A fake executor: the k-th attempt of each arm returns that arm's k-th sample."""
    seen = {verify.PARENT: 0, verify.CULPRIT: 0}
    values = {verify.PARENT: parent, verify.CULPRIT: culprit}

    def runner(attempt):
        if log is not None:
            log.append(attempt)
        k = seen[attempt.arm]
        seen[attempt.arm] += 1
        return [values[attempt.arm][k]]

    return runner


class PlanTests(unittest.TestCase):
    def test_abba_order_and_counts(self) -> None:
        self.assertEqual("".join(verify.abba(4)), "ABBAABBA")
        self.assertEqual("".join(verify.abba(3)), "ABBAAB")
        order = verify.abba(verify.DEFAULT_ATTEMPTS)
        self.assertEqual(order.count("A"), 20)
        self.assertEqual(order.count("B"), 20)

    def test_one_pinpoint_host_of_the_class(self) -> None:
        plan = verify.plan(request(), HOSTS)
        self.assertEqual(plan.host, "cmux16")
        self.assertEqual({a.host for a in plan.attempts}, {"cmux16"})
        self.assertEqual(len(plan.attempts), 40)
        self.assertEqual({a.sha for a in plan.attempts if a.arm == "A"}, {PARENT_SHA})
        self.assertEqual({a.sha for a in plan.attempts if a.arm == "B"}, {CULPRIT_SHA})
        self.assertEqual(verify.plan(request(), HOSTS, prefer="cmux17").host, "cmux17")
        # A waterfall host is never preferred, even when named.
        self.assertEqual(verify.plan(request(), HOSTS, prefer="cmux15").host, "cmux16")

    def test_no_pinpoint_host_of_the_class(self) -> None:
        with self.assertRaises(verify.VerifyError):
            verify.plan(request(host_class="apple-m6/32gb/120hz"), HOSTS)

    def test_bad_requests(self) -> None:
        with self.assertRaises(verify.VerifyError):
            request(better="faster")
        with self.assertRaises(verify.VerifyError):
            request(culprit_sha=PARENT_SHA)
        with self.assertRaises(verify.VerifyError):
            request(attempts=0)


class JudgeTests(unittest.TestCase):
    def test_strict_different_regression_is_verified_with_magnitude(self) -> None:
        log: list = []
        plan = verify.plan(request(), HOSTS)
        result = verify.run(plan, runner_for(BASE, SLOWER, log))
        self.assertEqual("".join(a.arm for a in log), "".join(verify.abba(20)))
        self.assertTrue(result.verified, result.reason)
        self.assertEqual(result.strict, "different")
        self.assertLessEqual(result.p_value, 0.01)
        self.assertAlmostEqual(result.median_shift, 0.3, places=9)
        self.assertAlmostEqual(result.p99_shift, 0.3, places=9)
        self.assertAlmostEqual(result.median_shift_pct, 100 * 0.3 / result.parent_p50, places=9)
        self.assertGreater(result.magnitude_iqr, 0)
        self.assertEqual((result.parent_attempts, result.culprit_attempts), (20, 20))

    def test_floored_different_but_strict_unknown_is_unverified(self) -> None:
        result = verify.run(verify.plan(request(), HOSTS), runner_for(FLAT, FEW_SLOW))
        self.assertEqual(result.floored, "different")
        self.assertEqual(result.strict, "unknown")
        self.assertAlmostEqual(result.p_value, 0.0195, delta=0.0005)
        self.assertFalse(result.verified)
        self.assertEqual(result.state, "unverified")

    def test_improvement_is_unverified(self) -> None:
        result = verify.run(verify.plan(request(), HOSTS), runner_for(SLOWER, BASE))
        self.assertEqual(result.strict, "different")
        self.assertFalse(result.verified)

    def test_higher_is_better_drop_is_verified(self) -> None:
        result = verify.run(verify.plan(request(better="higher"), HOSTS), runner_for(SLOWER, BASE))
        self.assertTrue(result.verified, result.reason)
        self.assertLess(result.median_shift, 0)

    def test_same_samples_unverified(self) -> None:
        result = verify.run(verify.plan(request(), HOSTS), runner_for(BASE, BASE))
        self.assertEqual(result.strict, "same")
        self.assertFalse(result.verified)

    def test_failed_attempts_measure_nothing(self) -> None:
        result = verify.run(verify.plan(request(), HOSTS), lambda attempt: None)
        self.assertFalse(result.verified)
        self.assertIsNone(result.p_value)
        self.assertEqual((result.parent_attempts, result.culprit_attempts), (0, 0))

    def test_results_off_the_plan_host_are_refused(self) -> None:
        plan = verify.plan(request(attempts=2), HOSTS)
        results = [verify.AttemptResult(a, "cmux17", (1.0,)) for a in plan.attempts]
        with self.assertRaises(verify.VerifyError):
            verify.judge(plan, results)
        with self.assertRaises(verify.VerifyError):
            verify.judge(plan, [verify.AttemptResult(a, plan.host, (1.0,)) for a in plan.attempts[:-1]])


class RecorderTests(unittest.TestCase):
    def setUp(self) -> None:
        self._tmp = tempfile.TemporaryDirectory()
        self.path = Path(self._tmp.name) / "lab.sqlite"
        lab = store.Store(self.path, clock=lambda: NOW)
        lab.migrate()
        lab.close()
        db = sqlite3.connect(self.path)
        db.execute("""INSERT INTO alert_groups (id, state, start_pos, end_pos, created_at, updated_at)
                      VALUES (1, 'bisecting', 100, 108, 'x', 'x')""")
        db.commit()
        db.close()
        self.recorder = verify.GroupRecorder(self.path, clock=lambda: NOW)

    def tearDown(self) -> None:
        self.recorder.close()
        self._tmp.cleanup()

    def group(self) -> sqlite3.Row:
        db = sqlite3.connect(self.path)
        db.row_factory = sqlite3.Row
        try:
            return db.execute("SELECT * FROM alert_groups WHERE id = 1").fetchone()
        finally:
            db.close()

    def history(self) -> list[tuple]:
        db = sqlite3.connect(self.path)
        try:
            return db.execute("SELECT from_state, to_state, actor, reason FROM sheriff_history ORDER BY id").fetchall()
        finally:
            db.close()

    def verify_with(self, parent, culprit, **changes):
        plan = verify.plan(request(**changes), HOSTS)
        job = self.recorder.start(plan)
        result = verify.run(plan, runner_for(parent, culprit))
        self.recorder.finish(job, result)
        return job, result

    def test_verified_culprit_stored_with_magnitude(self) -> None:
        job, result = self.verify_with(BASE, SLOWER)
        group = self.group()
        self.assertEqual((group["state"], group["culprit_sha"], group["culprit_verified"]),
                         ("culprit", CULPRIT_SHA, 1))
        [stored] = self.recorder.verification_of(1)
        self.assertEqual(stored["job_id"], job)
        self.assertEqual(stored["state"], "verified")
        self.assertAlmostEqual(stored["median_shift"], result.median_shift)
        self.assertAlmostEqual(stored["p99_shift"], result.p99_shift)
        self.assertEqual(stored["host"], "cmux16")
        [(from_state, to_state, actor, reason)] = self.history()
        self.assertEqual((from_state, to_state, actor), ("bisecting", "culprit", "perf-lab-verify"))
        self.assertIn("verified", reason)

    def test_unverified_culprit_tells_the_sheriff(self) -> None:
        self.verify_with(FLAT, FEW_SLOW)
        group = self.group()
        self.assertEqual((group["culprit_sha"], group["culprit_verified"]), (CULPRIT_SHA, 0))
        [stored] = self.recorder.verification_of(1)
        self.assertEqual((stored["state"], stored["strict"], stored["floored"]), ("unverified", "unknown", "different"))
        [(_, _, _, reason)] = self.history()
        self.assertIn("unverified", reason)
        self.assertIn("UNKNOWN", reason)

    def test_unverified_second_culprit_keeps_the_verified_one(self) -> None:
        self.verify_with(BASE, SLOWER)
        self.verify_with(FLAT, FEW_SLOW, parent_sha="c" * 40, culprit_sha="d" * 40)
        group = self.group()
        self.assertEqual((group["culprit_sha"], group["culprit_verified"]), (CULPRIT_SHA, 1))
        self.assertEqual([v["state"] for v in self.recorder.verification_of(1)], ["verified", "unverified"])

    def test_restart_reuses_the_unfinished_job_and_finish_is_idempotent(self) -> None:
        plan = verify.plan(request(), HOSTS)
        job = self.recorder.start(plan)
        self.assertEqual(self.recorder.start(plan), job)
        result = verify.run(plan, runner_for(BASE, SLOWER))
        self.recorder.finish(job, result)
        self.recorder.finish(job, result)
        self.assertEqual(len(self.history()), 1)
        other = verify.run(plan, runner_for(FLAT, FEW_SLOW))
        with self.assertRaises(verify.VerifyError):
            self.recorder.finish(job, other)

    def test_unknown_group_refused(self) -> None:
        with self.assertRaises(verify.VerifyError):
            self.recorder.start(verify.plan(request(group_id=99), HOSTS))


if __name__ == "__main__":
    unittest.main()
