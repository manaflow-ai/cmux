#!/usr/bin/env python3
"""pinpoint.py: the pure Pinpoint job core, driven by a fake executor.

  python3 -m unittest scripts/perf-lab/tests/test_pinpoint.py
"""
from __future__ import annotations

import importlib.util
import json
import random
import sys
import unittest
from pathlib import Path
from unittest import mock

LAB = Path(__file__).resolve().parent.parent


def _load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


pinpoint = _load("perf_lab_pinpoint", LAB / "pinpoint.py")
verify = _load("perf_lab_verify", LAB / "verify.py")
perf_stats = pinpoint.perf_stats

CLASS = "apple-m4/16gb/60hz"


def sha(i: int) -> str:
    return f"{i:040x}"


def commits(n: int, *, tip_every: int = 0, stored=lambda i, tip: False) -> tuple:
    out = []
    for i in range(n):
        tip = bool(tip_every) and (i % tip_every == 0 or i == n - 1)
        out.append(pinpoint.Commit(sha(i), batch_tip=tip, stored_build=stored(i, tip)))
    return tuple(out)


def bisect_job(range_, **changes) -> pinpoint.Job:
    fields = dict(kind=pinpoint.BISECT, mode=pinpoint.PERFORMANCE, story="terminal.key-frame.light",
                  metric="key_to_frame_ms", host_class=CLASS, good=range_[0].change, bad=range_[-1].change,
                  magnitude=None, better="lower", commits=range_)
    fields.update(changes)
    return pinpoint.Job(**fields)


def jitter(index: int) -> float:
    """The same small spread on every commit, so equal levels compare as identical samples."""
    return 0.1 * (index % 7)


class FakeExecutor:
    """Builds and runs synchronously; level(commit index) is the metric's level at that commit."""

    def __init__(self, range_, level, *, unbuildable=(), unmeasurable=(), noise=None, failing=None):
        self.position = {c.change: i for i, c in enumerate(range_)}
        self.level = level
        self.unbuildable = {sha(i) for i in unbuildable}
        self.unmeasurable = {sha(i) for i in unmeasurable}
        self.noise = noise
        self.failing = failing  # failing(commit index, attempt index): the attempt measured nothing
        self.builds: list[str] = []
        self.runs: list = []

    def build(self, change) -> bool:
        self.builds.append(change.sha)
        return change.sha not in self.unbuildable

    def attempt(self, change, index):
        if change.sha in self.unmeasurable:
            return pinpoint.Attempt(change, index, measurable=False)
        i = self.position[change]
        if self.failing and self.failing(i, index):
            return pinpoint.Attempt(change, index, failed=True)
        spread = self.noise(i, index) if self.noise else jitter(index)
        return pinpoint.Attempt(change, index, values=(self.level(i) + spread,))

    def answer(self, state, actions):
        """Do one step's actions; the Done result, if any."""
        for action in actions:
            if isinstance(action, pinpoint.Done):
                return action.result
            if isinstance(action, pinpoint.Build):
                state.record_build(action.change, self.build(action.change))
            else:
                self.runs.append(action)
                for k in range(action.start, action.start + action.count):
                    state.record_attempt(self.attempt(action.change, k))
        return None

    def run(self, state):
        """run_to_end, keeping every action for the assertions."""
        for _ in range(10_000):
            actions = pinpoint.step(state)
            if not actions:
                raise AssertionError("step() is waiting with no work outstanding")
            result = self.answer(state, actions)
            if result is not None:
                return result
        raise AssertionError("no result")


def step_at(*steps: int, size: float = 3.0):
    return lambda i: 10.0 + size * sum(i >= s for s in steps)


def culprit_shas(result) -> list:
    return [c.change.sha for c in result.culprits]


class BisectTests(unittest.TestCase):
    def test_one_step_among_64_commits_is_found(self) -> None:
        range_ = commits(64)
        fake = FakeExecutor(range_, step_at(37))
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(result.outcome, pinpoint.CULPRITS)
        self.assertEqual(culprit_shas(result), [sha(37)])
        culprit = result.culprits[0]
        self.assertEqual(culprit.parent.sha, sha(36))
        self.assertEqual(culprit.commits, (sha(37),))
        self.assertEqual(culprit.comparison.floored, perf_stats.DIFFERENT)
        # Binary search: the two ends plus about log2(62) midpoints, each built once.
        self.assertLessEqual(len(fake.builds), 2 + 7)
        self.assertEqual(len(fake.builds), len(set(fake.builds)))
        self.assertEqual(result.builds, len(fake.builds))

    def test_noise_range_ends_same_with_no_culprit(self) -> None:
        range_ = commits(64)
        rng = random.Random(6)  # a seed whose first comparisons are UNKNOWN
        draws: dict = {}

        def noise(i, k):
            return draws.setdefault((i, k), rng.gauss(0, 1.0))

        fake = FakeExecutor(range_, lambda i: 10.0, noise=noise)
        result = fake.run(pinpoint.JobState(bisect_job(range_, magnitude=1.0)))
        self.assertEqual(result.outcome, pinpoint.NO_CULPRIT)
        self.assertEqual(result.culprits, ())
        (comparison,) = result.comparisons
        self.assertEqual((comparison.verdict, comparison.raw), (perf_stats.SAME, perf_stats.SAME))
        self.assertEqual(fake.builds, [sha(0), sha(63)])
        # UNKNOWN at 10 and 20 attempts; SAME at 40.
        self.assertEqual([r.start + r.count for r in fake.runs], [10, 10, 20, 20, 40, 40])

    def test_two_regressions_give_two_culprits(self) -> None:
        range_ = commits(64)
        fake = FakeExecutor(range_, step_at(20, 45))
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(result.outcome, pinpoint.CULPRITS)
        self.assertEqual(culprit_shas(result), [sha(20), sha(45)])

    def test_improvement_direction_shift_is_same(self) -> None:
        range_ = commits(64)
        faster = FakeExecutor(range_, step_at(37, size=-3.0))
        result = faster.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(result.outcome, pinpoint.NO_CULPRIT)
        (comparison,) = result.comparisons
        self.assertEqual(comparison.raw, perf_stats.DIFFERENT)
        self.assertEqual(comparison.verdict, perf_stats.SAME)

        # The same drop is a regression for a higher-is-better metric.
        fps = FakeExecutor(range_, step_at(37, size=-3.0))
        result = fps.run(pinpoint.JobState(bisect_job(range_, better="higher")))
        self.assertEqual(culprit_shas(result), [sha(37)])

    def test_unbuildable_midpoint_is_skipped(self) -> None:
        range_ = commits(64)
        first_midpoint = 31  # the median of commits 1..62
        fake = FakeExecutor(range_, step_at(37), unbuildable=[first_midpoint])
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(culprit_shas(result), [sha(37)])
        self.assertEqual(fake.builds[2], sha(first_midpoint))
        self.assertEqual(fake.builds[3], sha(32))  # the next candidate in the same range
        self.assertEqual(fake.builds.count(sha(first_midpoint)), 1)
        self.assertIn((sha(first_midpoint), pinpoint.UNBUILDABLE), result.skipped)
        self.assertNotIn(sha(first_midpoint), [r.change.sha for r in fake.runs])

    def test_unbuildable_culprit_gives_a_range(self) -> None:
        range_ = commits(64)
        fake = FakeExecutor(range_, step_at(37), unbuildable=[37])
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        (culprit,) = result.culprits
        self.assertEqual((culprit.parent.sha, culprit.change.sha), (sha(36), sha(38)))
        self.assertEqual(culprit.commits, (sha(37), sha(38)))

    def test_not_measurable_good_end_narrows_the_range(self) -> None:
        range_ = commits(64)
        fake = FakeExecutor(range_, step_at(37), unmeasurable=range(0, 3))
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(culprit_shas(result), [sha(37)])
        self.assertEqual(result.skipped, tuple((sha(i), pinpoint.NOT_MEASURABLE) for i in range(3)))
        self.assertEqual(result.comparisons[0].parent.sha, sha(3))

    def test_capability_boundary_is_bisected_not_walked(self) -> None:
        # The story's capability lands at `capability`; every older commit is not measurable.
        for capability, regression in ((58, 60), (40, 50)):
            range_ = commits(64)
            fake = FakeExecutor(range_, step_at(regression), unmeasurable=range(capability))
            result = fake.run(pinpoint.JobState(bisect_job(range_)))
            self.assertEqual(result.outcome, pinpoint.CULPRITS)
            self.assertEqual([c.commits for c in result.culprits], [(sha(regression),)])
            self.assertFalse(result.build_limit_hit)
            self.assertEqual(result.comparisons[0].parent.sha, sha(capability))
            self.assertEqual(result.skipped[-1], (sha(capability - 1), pinpoint.NOT_MEASURABLE))
            # O(log n): the ends, about log2(62) probes for the boundary and log2 of the rest for the step.
            self.assertLessEqual(len(fake.builds), 2 + 2 * 6)
            self.assertEqual(len(fake.builds), len(set(fake.builds)))

    def test_boundary_probes_prefer_batch_tips_and_stored_builds(self) -> None:
        range_ = commits(64, tip_every=8, stored=lambda i, tip: tip)
        fake = FakeExecutor(range_, step_at(60), unmeasurable=range(58))
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual([c.commits for c in result.culprits], [(sha(60),)])
        probed = [int(r.change.sha, 16) for r in fake.runs if r.start == 0]
        # The boundary search runs over tips 8..56 (all free), then inside the last batch.
        self.assertTrue({8, 16, 24, 32, 40, 48, 56} & set(probed))
        self.assertTrue(all(int(s, 16) > 56 for s in fake.builds))

    def test_unbuildable_ends_narrow_the_range(self) -> None:
        range_ = commits(64)
        fake = FakeExecutor(range_, step_at(37), unbuildable=[0, 1, 63])
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(culprit_shas(result), [sha(37)])
        self.assertEqual((result.comparisons[0].parent.sha, result.comparisons[-1].change.sha), (sha(2), sha(62)))

    def test_not_measurable_midpoint_is_skipped(self) -> None:
        range_ = commits(64)
        fake = FakeExecutor(range_, step_at(37), unmeasurable=[31])
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(culprit_shas(result), [sha(37)])
        self.assertEqual(result.skipped, ((sha(31), pinpoint.NOT_MEASURABLE),))

    def test_unmeasurable_when_nothing_is_left(self) -> None:
        range_ = commits(3)
        fake = FakeExecutor(range_, step_at(1), unbuildable=[0, 1])
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(result.outcome, pinpoint.UNMEASURABLE)
        self.assertEqual(result.culprits, ())

    def test_batch_tips_first_then_inside_the_batch(self) -> None:
        range_ = commits(64, tip_every=8, stored=lambda i, tip: tip)
        fake = FakeExecutor(range_, step_at(37))
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(culprit_shas(result), [sha(37)])
        measured = [r.change.sha for r in fake.runs if r.start == 0]
        tips = {c.sha for c in range_ if c.batch_tip}
        # Tips 32 and 40 bracket the step; every tip is measured before any commit inside that batch.
        first_inside = next(k for k, s in enumerate(measured) if s not in tips)
        self.assertTrue(all(s in tips for s in measured[:first_inside]))
        self.assertTrue(all(s not in tips for s in measured[first_inside:]))
        self.assertIn(sha(32), measured[:first_inside])
        self.assertIn(sha(40), measured[:first_inside])
        self.assertTrue(all(int(s, 16) in range(33, 40) for s in measured[first_inside:]))
        # Stored tip builds are free: only the commits inside the batch were built.
        self.assertTrue(all(s not in tips for s in fake.builds))

    def test_two_speculation_levels_only_with_stored_builds(self) -> None:
        for stored, added in ((lambda i, tip: True, [15, 31, 47]), (lambda i, tip: i in (0, 63), [31])):
            range_ = commits(64, stored=stored)
            fake = FakeExecutor(range_, step_at(37))
            state = pinpoint.JobState(bisect_job(range_))
            actions = pinpoint.step(state)
            while state.changes == [range_[0].change, range_[-1].change]:
                fake.answer(state, actions)
                actions = pinpoint.step(state)
            # The first DIFFERENT (good vs bad) added its speculation in one step.
            self.assertEqual([int(c.sha, 16) for c in state.changes[1:-1]], added)

    def test_max_builds_stops_with_a_range_culprit(self) -> None:
        range_ = commits(64)
        fake = FakeExecutor(range_, step_at(37))
        with mock.patch.object(pinpoint, "MAX_BUILDS", 4):
            result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertTrue(result.build_limit_hit)
        self.assertEqual(result.builds, 4)
        self.assertEqual(len(fake.builds), 4)
        (culprit,) = result.culprits
        self.assertGreater(len(culprit.commits), 1)
        self.assertIn(sha(37), culprit.commits)

    def test_functional_mode_bisects_the_failure_rate(self) -> None:
        range_ = commits(32)

        class Flaky(FakeExecutor):
            def attempt(self, change, index):
                return pinpoint.Attempt(change, index, failed=self.position[change] >= 21)

        fake = Flaky(range_, lambda i: 0.0)
        result = fake.run(pinpoint.JobState(bisect_job(range_, mode=pinpoint.FUNCTIONAL)))
        self.assertEqual(culprit_shas(result), [sha(21)])

        fixed = Flaky(range_, lambda i: 0.0)
        fixed.attempt = lambda change, index: pinpoint.Attempt(change, index, failed=fixed.position[change] < 21)
        self.assertEqual(fixed.run(pinpoint.JobState(bisect_job(range_, mode=pinpoint.FUNCTIONAL))).outcome,
                         pinpoint.NO_CULPRIT)


class FailureTests(unittest.TestCase):
    """Performance mode compares the failure rate first, as catapult job_state._Compare."""

    def test_story_that_breaks_from_a_commit_on_is_the_culprit(self) -> None:
        range_ = commits(64)
        fake = FakeExecutor(range_, lambda i: 10.0, failing=lambda i, k: i >= 37)
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(result.outcome, pinpoint.CULPRITS)
        (culprit,) = result.culprits
        self.assertEqual(culprit.commits, (sha(37),))
        self.assertEqual(culprit.comparison.basis, pinpoint.FAILURES)
        self.assertEqual((culprit.comparison.failures_parent, culprit.comparison.failures_change), (0, 10))
        # No UNKNOWN loop: every Change kept its 10 attempts.
        self.assertTrue(all(r.start + r.count == pinpoint.MIN_ATTEMPTS for r in fake.runs))

    def test_failure_rate_step_with_the_same_values_is_the_culprit(self) -> None:
        range_ = commits(64)
        fake = FakeExecutor(range_, lambda i: 10.0, failing=lambda i, k: i >= 37 and k % 2 == 0)
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(culprit_shas(result), [sha(37)])
        self.assertEqual(result.culprits[0].comparison.basis, pinpoint.FAILURES)

    def test_midpoint_that_fails_every_attempt_does_not_hide_the_step(self) -> None:
        range_ = commits(64)
        fake = FakeExecutor(range_, step_at(37), failing=lambda i, k: i == 31)
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(result.outcome, pinpoint.CULPRITS)
        # 31 breaks the story (a functional culprit); 32 fixes it, and the values still find 37.
        self.assertEqual(culprit_shas(result), [sha(31), sha(37)])
        self.assertEqual([c.comparison.basis for c in result.culprits], [pinpoint.FAILURES, pinpoint.VALUES])
        self.assertLessEqual(max(r.start + r.count for r in fake.runs), 20)

    def test_fewer_failures_is_not_a_culprit(self) -> None:
        range_ = commits(64)
        fake = FakeExecutor(range_, lambda i: 10.0, failing=lambda i, k: i < 37)
        result = fake.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(result.outcome, pinpoint.NO_CULPRIT)


def verify_job(**changes) -> pinpoint.Job:
    range_ = commits(2)
    return bisect_job(range_, **{"kind": pinpoint.VERIFY, "commits": (), **changes})


def sampled(parent: list, culprit: list):
    """An attempt callback: attempt k of each arm returns that arm's k-th sample."""
    samples = {sha(0): parent, sha(1): culprit}
    return lambda change, index: pinpoint.Attempt(change, index, values=(samples[change.sha][index],))


class VerifyTests(unittest.TestCase):
    BASE = [10 + 0.1 * (i % 7) for i in range(20)]

    def run_verify(self, parent, culprit, **changes):
        state = pinpoint.JobState(verify_job(**changes))
        runs = []

        def attempt(change, index):
            runs.append((change.sha, index))
            return sampled(parent, culprit)(change, index)

        result = pinpoint.run_to_end(state, lambda change: True, attempt)
        return result, runs

    def test_verify_runs_20_attempts_each_and_finishes(self) -> None:
        state = pinpoint.JobState(verify_job())
        builds = pinpoint.step(state)
        self.assertEqual([type(a) for a in builds], [pinpoint.Build, pinpoint.Build])
        for action in builds:
            state.record_build(action.change, True)
        runs = pinpoint.step(state)
        self.assertEqual([(r.start, r.count) for r in runs], [(0, 20), (0, 20)])

    def test_verify_unknown_stays_unknown_at_20(self) -> None:
        # FLAT vs FEW_SLOW at 20 attempts: floored DIFFERENT, strict UNKNOWN (test_verify.py).
        result, runs = self.run_verify([0.0] * 20, [0.0] * 15 + [1.0] * 5)
        self.assertEqual(len(runs), 40)
        self.assertEqual(result.outcome, pinpoint.UNRESOLVED)
        self.assertEqual(result.comparisons[0].strict, perf_stats.UNKNOWN)
        self.assertEqual(result.comparisons[0].floored, perf_stats.DIFFERENT)

    def test_verify_verdict_equals_verify_judge(self) -> None:
        rng = random.Random(15)
        cases = [
            (self.BASE, [x + 0.3 for x in self.BASE]),  # a regression
            (self.BASE, [x - 0.3 for x in self.BASE]),  # an improvement
            ([0.0] * 20, [0.0] * 15 + [1.0] * 5),  # floored DIFFERENT, strict UNKNOWN
            (self.BASE, list(self.BASE)),  # no change
            ([10.0] * 20, [10.0] * 10 + [12.0] * 5 + [8.0] * 5),  # a spread change, same median
        ] + [([rng.gauss(10, 1) for _ in range(20)], [rng.gauss(10.5, 1) for _ in range(20)]) for _ in range(8)]
        host = verify.LabHost("cmux17", CLASS, "pinpoint")
        for parent, culprit in cases:
            for better in ("lower", "higher"):
                with self.subTest(parent=parent[:3], culprit=culprit[:3], better=better):
                    result, _ = self.run_verify(parent, culprit, better=better)
                    (comparison,) = result.comparisons
                    request = verify.Request(1, sha(0), sha(1), "terminal.key-frame.light", "key_to_frame_ms",
                                             CLASS, better)
                    plan = verify.plan(request, [host])
                    arms = {verify.PARENT: iter(parent), verify.CULPRIT: iter(culprit)}
                    judged = verify.judge(plan, [verify.AttemptResult(a, a.host, (next(arms[a.arm]),))
                                                 for a in plan.attempts])
                    self.assertEqual(comparison.verdict == perf_stats.DIFFERENT, judged.verified)
                    self.assertEqual(result.outcome == pinpoint.CULPRITS, judged.verified)
                    self.assertEqual((comparison.strict, comparison.floored), (judged.strict, judged.floored))
                    self.assertAlmostEqual(comparison.p_value, judged.p_value)
                    self.assertEqual((comparison.median_parent, comparison.median_change),
                                     (judged.parent_p50, judged.culprit_p50))

    def test_attempts_are_checked(self) -> None:
        for bad in (0, -1, pinpoint.MAX_ATTEMPTS + 1, 2.5, True):
            with self.assertRaises(pinpoint.PinpointError):
                verify_job(attempts=bad)
        self.assertEqual(verify_job().initial_attempts(), pinpoint.VERIFY_ATTEMPTS)
        self.assertEqual(verify_job(attempts=8).initial_attempts(), 8)
        self.assertEqual(verify_job(kind=pinpoint.TRY).initial_attempts(), pinpoint.MIN_ATTEMPTS)


class AttemptGrowthTests(unittest.TestCase):
    def test_unknown_doubles_attempts_10_to_160(self) -> None:
        always_unknown = perf_stats.ComparisonResults(perf_stats.UNKNOWN, 0.03, 0.01, 0.5)

        def compare(values_a, values_b, attempt_count, mode, magnitude):
            return perf_stats.Comparison(always_unknown, always_unknown, 0.03, 0.03)

        range_ = commits(2)
        job = bisect_job(range_, kind=pinpoint.TRY, commits=())
        fake = FakeExecutor(range_, lambda i: 10.0)
        result = fake.run(pinpoint.JobState(job, compare=compare))
        totals = {}
        for run in fake.runs:
            totals.setdefault(run.change.sha, []).append(run.start + run.count)
        self.assertEqual(totals[sha(0)], [10, 20, 40, 80, 160])
        self.assertEqual(totals[sha(1)], [10, 20, 40, 80, 160])
        self.assertEqual(result.outcome, pinpoint.UNRESOLVED)
        self.assertEqual(result.comparisons[0].attempts_change, pinpoint.MAX_ATTEMPTS)

    def test_bisect_takes_the_floored_verdict_try_the_strict_one(self) -> None:
        # [0]*10 vs [0]*6+[1]*4: p 0.0336, floored DIFFERENT (<= 0.05), strict UNKNOWN (> 0.01).
        range_ = commits(2)

        class Pattern(FakeExecutor):
            def attempt(self, change, index):
                value = 1.0 if self.position[change] == 1 and index % 10 >= 6 else 0.0
                return pinpoint.Attempt(change, index, values=(value,))

        bisect = Pattern(range_, None)
        result = bisect.run(pinpoint.JobState(bisect_job(range_)))
        self.assertEqual(culprit_shas(result), [sha(1)])
        self.assertEqual(result.comparisons[0].attempts_change, 10)
        self.assertEqual(result.comparisons[0].strict, perf_stats.UNKNOWN)

        try_ = Pattern(range_, None)
        result = try_.run(pinpoint.JobState(bisect_job(range_, kind=pinpoint.TRY, commits=())))
        self.assertGreater(result.comparisons[0].attempts_change, 10)
        self.assertEqual(result.comparisons[0].verdict, result.comparisons[0].strict)


class ContractTests(unittest.TestCase):
    def test_step_never_repeats_outstanding_work(self) -> None:
        range_ = commits(8)
        state = pinpoint.JobState(bisect_job(range_))
        first = pinpoint.step(state)
        self.assertEqual([type(a) for a in first], [pinpoint.Build, pinpoint.Build])
        self.assertEqual(pinpoint.step(state), [])
        state.record_build(range_[0].change, True)
        (run,) = pinpoint.step(state)
        self.assertEqual((run.change, run.start, run.count), (range_[0].change, 0, pinpoint.MIN_ATTEMPTS))
        self.assertEqual(pinpoint.step(state), [])

    def test_results_for_unknown_work_are_refused(self) -> None:
        range_ = commits(8)
        state = pinpoint.JobState(bisect_job(range_))
        with self.assertRaises(pinpoint.PinpointError):
            state.record_build(range_[3].change, True)
        pinpoint.step(state)
        with self.assertRaises(pinpoint.PinpointError):
            state.record_attempt(pinpoint.Attempt(range_[0].change, 0, values=(1.0,)))

    def test_a_build_result_counts_once(self) -> None:
        range_ = commits(8)
        state = pinpoint.JobState(bisect_job(range_))
        pinpoint.step(state)
        state.record_build(range_[0].change, False)
        for ok in (False, True):
            with self.assertRaises(pinpoint.PinpointError):
                state.record_build(range_[0].change, ok)
        state.record_build(range_[-1].change, True)
        with self.assertRaises(pinpoint.PinpointError):
            state.record_build(range_[-1].change, True)

    def test_state_round_trips_mid_job_without_repeating_work(self) -> None:
        range_ = commits(64, tip_every=8, stored=lambda i, tip: i == 24)
        level = step_at(37)
        expected = FakeExecutor(range_, level, unmeasurable=range(3)).run(pinpoint.JobState(bisect_job(range_)))

        fake = FakeExecutor(range_, level, unmeasurable=range(3))
        state = pinpoint.JobState(bisect_job(range_))
        issued: list = []  # every Build and attempt any step() returned, before and after the restart

        def issue(actions) -> None:
            for action in actions:
                if isinstance(action, pinpoint.Build):
                    issued.append(("build", action.change.sha))
                elif isinstance(action, pinpoint.Run):
                    issued.extend(("run", action.change.sha, k) for k in range(action.start, action.start + action.count))

        lost: list = []  # the last action of each step: in flight when the executor dies
        for _ in range(4):
            actions = pinpoint.step(state)
            issue(actions)
            lost.extend(actions[-1:])
            self.assertIsNone(fake.answer(state, actions[:-1]))

        saved = json.loads(json.dumps(state.to_dict()))
        restored = pinpoint.JobState.from_dict(saved)
        self.assertEqual(json.loads(json.dumps(restored.to_dict())), saved)
        outstanding = restored.outstanding()
        self.assertTrue(outstanding)
        self.assertEqual(outstanding, state.outstanding())
        self.assertEqual(sorted(map(repr, outstanding)), sorted(repr(a) for a in lost if a.change in restored.changes))

        # The resumed executor answers the outstanding work, then steps on; nothing is issued twice.
        self.assertIsNone(fake.answer(restored, outstanding))
        result = None
        for _ in range(10_000):
            actions = pinpoint.step(restored)
            issue(actions)
            result = fake.answer(restored, actions)
            if result is not None:
                break
        self.assertEqual(len(issued), len(set(issued)))
        self.assertEqual(result.to_json(), expected.to_json())
        finished = pinpoint.JobState.from_dict(json.loads(json.dumps(restored.to_dict())))
        self.assertEqual(pinpoint.step(finished), [pinpoint.Done(result)])

    def test_bad_saved_state_is_refused(self) -> None:
        range_ = commits(8)
        saved = pinpoint.JobState(bisect_job(range_)).to_dict()
        for broken in ({**saved, "version": 99}, {k: v for k, v in saved.items() if k != "tracked"},
                       {**saved, "changes": [0, 99]}):
            with self.assertRaises(pinpoint.PinpointError):
                pinpoint.JobState.from_dict(broken)

    def test_job_definition_is_checked(self) -> None:
        range_ = commits(4)
        with self.assertRaises(pinpoint.PinpointError):
            bisect_job(range_, kind="nightly")
        with self.assertRaises(pinpoint.PinpointError):
            bisect_job(range_, commits=range_[1:])
        with self.assertRaises(pinpoint.PinpointError):
            bisect_job(range_, kind=pinpoint.TRY)
        with self.assertRaises(pinpoint.PinpointError):
            bisect_job(range_, bad=range_[0].change, commits=())

    def test_result_serializes(self) -> None:
        range_ = commits(16)
        result = FakeExecutor(range_, step_at(5)).run(pinpoint.JobState(bisect_job(range_)))
        self.assertIn(sha(5), result.to_json())

    def test_deps_make_distinct_changes(self) -> None:
        base = pinpoint.Change(sha(1))
        pinned = pinpoint.Change(sha(1), (("ghostty", "f" * 40),))
        self.assertNotEqual(base, pinned)
        self.assertEqual(pinned.label(), f"{sha(1)[:12]} ghostty@{'f' * 12}")


if __name__ == "__main__":
    unittest.main()
