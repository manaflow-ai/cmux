#!/usr/bin/env python3
"""The kit job's Instant list bench stays on push/dispatch lanes, never pull requests.

The benches are advisory measurements and add 3-10 minutes to a pull request without
changing its verdict. They remain on feat-cmux-next pushes and dispatch/nightly runs,
where the trend is recorded without charging every PR. The setup steps still survive
an earlier red step on those measurement lanes, so their numbers are not lost when a
required check fails first.

  python3 tests/test_ios_kit_bench_runs_after_red_step.py
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

from runs_on_labels import resolve_labels
from test_ci_same_repo_linux_owned_first import same_repository

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

    def test_pull_requests_skip_the_advisory_bench(self) -> None:
        # The bench adds 3-10 minutes to a PR without changing its verdict. Push and dispatch/nightly runs retain the
        # measurement, and !cancelled() keeps it available after a required step fails on those lanes.
        by_id = {step.get("id"): step for step in steps()}
        for bench in BENCH_IDS:
            condition = str(by_id[bench].get("if", ""))
            self.assertIn("!cancelled()", condition, f"{bench}: {condition}")
            self.assertIn("github.event_name != 'pull_request'", condition, f"{bench}: {condition}")
            self.assertNotIn("success()", condition, f"{bench}: {condition}")

    def test_a_red_lint_still_fails_the_job(self) -> None:
        # The lint keeps its teeth: it is not advisory, only no longer in the bench's way.
        lint = next(step for step in steps() if step.get("name") == "Connection notices")
        self.assertNotIn("continue-on-error", lint)
        self.assertEqual(lint["env"]["LINT_RESULT"], "${{ needs.connection-notices.outputs.lint_result }}")
        self.assertIn('test "$LINT_RESULT" = success', lint["run"])
        jobs = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))["jobs"]
        linux = jobs["connection-notices"]
        # The unprivileged lint runs on owned Linux for same-repository PRs.
        self.assertEqual(resolve_labels(same_repository(linux["runs-on"], "pull_request")), {"cmux-linux"})
        self.assertEqual(linux["needs"], "runner")
        self.assertIn(linux["if"].removeprefix("${{ ").removesuffix(" }}"), jobs["kit-tests"]["if"])
        check = next(step for step in linux["steps"] if step.get("name") == "Connection notices")
        self.assertTrue(check["continue-on-error"])
        self.assertEqual(linux["outputs"]["lint_result"], "${{ steps." + check["id"] + ".outcome }}")
        self.assertIn("check-connection-notices.py", check["run"])
        self.assertIn("!cancelled()", jobs["kit-tests"]["if"])


class KitTestsRunAfterARedLint(unittest.TestCase):
    # A red Connection notices (it reads webviews/ too) skipped every kit test on base from 2026-11-25: a web-only
    # finding in GitHubConnectCard.tsx hid 22 simulator reds in the kit's own code. The tests now run after it.
    TESTS = (
        "swift test (macOS)",
        "swift test (macOS, measured suites alone)",
        "xcodebuild test (iOS simulator)",
        "xcodebuild test (iOS simulator, Mac fallback)",
    )

    def test_the_kit_tests_run_after_a_red_step(self) -> None:
        by_name = {step.get("name"): step for step in steps()}
        for name in self.TESTS:
            self.assertIn(name, by_name, f"the kit job has no step named {name!r}")
            self.assertTrue(survives_a_red_step(by_name[name]), f"{name!r} is skipped after a red lint step")


if __name__ == "__main__":
    unittest.main()
