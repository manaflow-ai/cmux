#!/usr/bin/env python3
"""pinpoint.py: the pure Pinpoint job core, driven by a fake executor.

  python3 -m unittest scripts/perf-lab/tests/test_pinpoint.py
"""
from __future__ import annotations

import importlib.util
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

    def __init__(self, range_, level, *, unbuildable=(), unmeasurable=(), noise=None):
        self.position = {c.change: i for i, c in enumerate(range_)}
        self.level = level
        self.unbuildable = {sha(i) for i in unbuildable}
        self.unmeasurable = {sha(i) for i in unmeasurable}
        self.noise = noise
        self.builds: list[str] = []
        self.runs: list = []

    def build(self, change) -> bool:
        self.builds.append(change.sha)
        return change.sha not in self.unbuildable

    def attempt(self, change, index):
        if change.sha in self.unmeasurable:
            return pinpoint.Attempt(change, index, measurable=False)
        i = self.position[change]
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
