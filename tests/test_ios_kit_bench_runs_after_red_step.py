#!/usr/bin/env python3
"""The kit job's Instant list bench still runs when an earlier step of the job is red, except on a pull request.

The bench steps of .github/workflows/cmux-next-ios-kit.yml are advisory and run with
`!cancelled()`, so a red test step never hides their numbers. The steps they build
on (Xcode, Rust, the cargo cache, CmuxMobileLinkFFI.xcframework) had no condition,
though, so a red lint step before them skipped all four and the bench then had
nothing to build with: it printed no INSTANTPERF line. From 2026-11-22 the
`Connection notices` step was red on feat-cmux-next for over a day (run
45149422676, three findings in files no iPhone bench reads), and every kit run in
that time read "no measurement" for the iPhone speed checks.

  python3 tests/test_ios_kit_bench_runs_after_red_step.py
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github/workflows/cmux-next-ios-kit.yml"
BENCH_IDS = ("bench-macos", "bench-ios")
# What the bench builds with: `swift test` and `xcodebuild test` need the selected
# Xcode and link CmuxMobileLinkFFI.xcframework, which the pinned Rust builds.
SETUP = (
    "Select Xcode",
    "Set up pinned Rust",
    "Cache cargo",
    "Build CmuxMobileLinkFFI.xcframework",
)


def steps() -> list[dict]:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return workflow["jobs"]["kit-tests"]["steps"]


def survives_a_red_step(step: dict) -> bool:
    """True when the step runs after an earlier step failed (it is not left to `success()`)."""
    condition = str(step.get("if", ""))
    return "!cancelled()" in condition or "always()" in condition


class BenchRunsAfterARedStep(unittest.TestCase):
    def test_the_bench_steps_run_after_a_red_step(self) -> None:
        by_id = {step.get("id"): step for step in steps()}
        for bench in BENCH_IDS:
            self.assertIn(bench, by_id, f"the kit job has no step with id {bench}")
            self.assertTrue(survives_a_red_step(by_id[bench]), f"{bench} is skipped after a red step")

    def test_what_the_bench_builds_with_runs_after_a_red_step(self) -> None:
        all_steps = steps()
        names = [step.get("name") for step in all_steps]
        first_bench = min(i for i, step in enumerate(all_steps) if step.get("id") in BENCH_IDS)
        for name in SETUP:
            self.assertIn(name, names, f"the kit job has no step named {name!r}")
            index = names.index(name)
            self.assertLess(index, first_bench, f"{name!r} runs after the bench it sets up")
            self.assertTrue(
                survives_a_red_step(all_steps[index]),
                f"{name!r} is skipped when an earlier step (a lint) is red, so the bench "
                "has nothing to build with and prints no INSTANTPERF line",
            )

    def test_a_red_pull_request_does_not_wait_for_the_advisory_bench(self) -> None:
        # On a pull request the red step is already the verdict; the advisory bench (3-10 min on a Mac) is skipped so
        # the red check reports at once (goal ios-ci-under-5min). Base pushes and dispatches still bench after a red.
        by_id = {step.get("id"): step for step in steps()}
        for bench in BENCH_IDS:
            condition = str(by_id[bench].get("if", ""))
            self.assertIn("github.event_name != 'pull_request' || success()", condition, f"{bench}: {condition}")

    def test_a_red_lint_still_fails_the_job(self) -> None:
        # The lint keeps its teeth: it is not advisory, only no longer in the bench's way.
        lint = next(step for step in steps() if step.get("name") == "Connection notices")
        self.assertNotIn("continue-on-error", lint)


if __name__ == "__main__":
    unittest.main()
