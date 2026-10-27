#!/usr/bin/env python3
"""Nightly runners: owned minis first, then literal Blacksmith labels.

The app compile takes the trusted owned minis on attempt 1. Signing,
notarization, verification and the other macOS jobs take a literal Blacksmith
label (Blacksmith is trusted like GitHub-hosted, release signing included),
never a GitHub-hosted Mac. Leo, 2026-10-27: "THE GITHUB HOSTED MACS / ARE THE
SLOWEST THINGS / THEY PREVIOUSLY WREN'T EVEN UNDER CONSIDERATINO". Shared
runner variables remain forbidden because they can silently move a job onto a
single-host queue or a reused machine.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

BLACKSMITH = re.compile(r"blacksmith", re.IGNORECASE)
# Repository variables that route to Blacksmith pools today (docs/ci-runners.md).
SHARED_RUNNER_VARIABLES = re.compile(
    r"vars\.(LINUX_RUNNER|LINUX_ARM64_RUNNER|LINUX_RUNNER_DARWIN_CROSS|WINDOWS_RUNNER"
    r"|MACOS_RUNNER_[A-Z0-9_]+|CI_NIGHTLY_DECIDE_RUNNER|CI_TRUSTED_RUNNER)\b"
)
# The cmux-tui nightly calls the shared package builder, which keeps its own
# fallbacks for other callers; the nightly must override every runner input.
TUI_NIGHTLY_RUNNER_INPUTS = (
    "macos_runner",
    "macos_retry_runner",
    "linux_runner",
    "linux_arm64_runner",
    "windows_runner",
)


def nightly_workflows() -> list[Path]:
    paths = set(WORKFLOWS.glob("*nightly*.yml")) | set(WORKFLOWS.glob("*notarization*.yml"))
    return sorted(paths)


# Jobs in a nightly file that are not part of any nightly build. nightly.yml
# `refresh-test-compilation-cache` warms the pull-request admission cache on the
# Blacksmith pools that admission reads (tests/test_seed_derived_data.py pins
# its pools to seed-derived-data.yml). It runs only from the main schedule
# while CI_PR_POOL_OWNED != '1', or on a seed_only dispatch, never on a
# nightly-next push, and nothing in the nightly needs it.
NOT_NIGHTLY_JOBS = {"nightly.yml": ("refresh-test-compilation-cache",)}
JOB_HEADER = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")


def code_lines(path: Path):
    skipped = NOT_NIGHTLY_JOBS.get(path.name, ())
    current_job = None
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        header = JOB_HEADER.match(line)
        if header:
            current_job = header.group(1)
        elif line and not line.startswith(" "):
            current_job = None
        if current_job in skipped:
            continue
        if line.lstrip().startswith("#"):
            continue
        yield number, line.split(" # ", 1)[0]


class NightlyOffBlacksmithTests(unittest.TestCase):
    def test_nightly_workflows_are_discovered(self) -> None:
        names = {path.name for path in nightly_workflows()}
        for required in ("nightly.yml", "auto-resume-nightly-notarization.yml"):
            self.assertIn(required, names)

    def test_blacksmith_is_named_only_as_a_literal_runner_label(self) -> None:
        failures = [
            f"{path.name}:{number}: {line.strip()}"
            for path in nightly_workflows()
            for number, line in code_lines(path)
            if BLACKSMITH.search(line)
            and not ("runs-on:" in line and re.search(r"'blacksmith-\d+vcpu-[a-z0-9-]+'", line))
        ]
        self.assertEqual(failures, [], "a nightly job names Blacksmith only as a literal runs-on label")

    def test_no_nightly_job_reads_a_shared_blacksmith_runner_variable(self) -> None:
        failures = [
            f"{path.name}:{number}: {line.strip()}"
            for path in nightly_workflows()
            for number, line in code_lines(path)
            if SHARED_RUNNER_VARIABLES.search(line)
        ]
        self.assertEqual(failures, [], "a shared runner variable points at Blacksmith; use a literal owned or Blacksmith label")

    def test_nightlies_skip_the_benchmark_mini(self) -> None:
        """cmux11s is the dedicated benchmark mini (since 2026-10-20, a153).

        Its runners are off and must stay idle, so no nightly job may name it or
        any pool it carries: the std PR/side/session pools and the shared
        side-lane or daemon variables (which an operator may point at a std
        pool). Nightly macOS work uses only the cmux15 trusted tuple or the
        light side lane (light-class minis; cmux11s is std class).
        """
        forbidden = re.compile(
            r"cmux11s|glaeda-(side-|root-|gui-|session-|aws-)?std-xcode"
            r"|vars\.(CI_SIDE_LANE_RUNNER|CI_NEXT_DAEMON_POOL|CI_NEXT_PROMOTE_POOL|CI_PIN_DAEMON_POOL|CI_LIGHT_LANE_RUNNER)\b"
        )
        allowed = ("vars.CI_SEED_TRUSTED_POOL", "vars.CI_NIGHTLY_NEXT_TRUSTED_POOL")
        failures = []
        for path in nightly_workflows():
            for number, line in code_lines(path):
                if forbidden.search(line) and not any(name in line for name in allowed):
                    failures.append(f"{path.name}:{number}: {line.strip()}")
        self.assertEqual(failures, [], "nightly jobs must never reach the benchmark mini cmux11s")

    @unittest.skipUnless((WORKFLOWS / "cmux-tui-nightly.yml").exists(), "no cmux-tui nightly on this branch")
    def test_tui_nightly_overrides_every_package_builder_runner(self) -> None:
        text = (WORKFLOWS / "cmux-tui-nightly.yml").read_text(encoding="utf-8")
        block = text[text.index("uses: ./.github/workflows/cmux-tui-build-package.yml"):]
        block = block[: block.index("\n  publish-npm:")]
        for name in TUI_NIGHTLY_RUNNER_INPUTS:
            with self.subTest(input=name):
                match = re.search(rf"^\s+{name}: (.+)$", block, re.MULTILINE)
                self.assertIsNotNone(match, f"cmux-tui nightly must pass {name}")
                self.assertNotRegex(match.group(1), BLACKSMITH)

    def test_compiles_stay_on_the_owned_trusted_minis(self) -> None:
        text = (WORKFLOWS / "nightly.yml").read_text(encoding="utf-8")
        job = text[text.index("\n  build-nightly-app:"):]
        runs_on = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1)
        self.assertIn("vars.CI_NIGHTLY_TRUSTED_RUNNER", runs_on)
        if "vars.CI_NIGHTLY_NEXT_TRUSTED_POOL" in text:
            self.assertIn("vars.CI_NIGHTLY_NEXT_TRUSTED_RUNNER", runs_on)
            self.assertIn("glaeda-trusted-next-nightly", runs_on)

    def test_promotion_requests_never_wait_on_blacksmith(self) -> None:
        """The jobs that start a NEXT nightly are part of the nightly path.

        A feat-cmux-next push asks main to promote nightly-next from
        cmux-next.yml and cmux-tui-artifacts.yml (`request-nightly-next`). On
        Blacksmith those requests queued behind its pool like the nightly's own
        jobs, so no nightly started. They must run on GitHub-hosted Linux.
        """
        for name in ("cmux-next.yml", "cmux-tui-artifacts.yml"):
            text = (WORKFLOWS / name).read_text(encoding="utf-8")
            if "\n  request-nightly-next:" not in text:
                continue
            job = text[text.index("\n  request-nightly-next:") + 1:]
            following = re.search(r"\n  [A-Za-z0-9_-]+:\n", job[1:])
            job = job[: following.start() + 1] if following else job
            runs_on = re.search(r"^    runs-on: (.+)$", job, re.MULTILINE).group(1)
            with self.subTest(workflow=name):
                self.assertNotRegex(runs_on.split(" # ", 1)[0], BLACKSMITH)
                self.assertNotRegex(runs_on, SHARED_RUNNER_VARIABLES)

    @unittest.skipUnless((WORKFLOWS / "cmux-next.yml").exists(), "no cmux-next on this branch")
    def test_finished_push_runs_start_a_nightly_next_with_a_thirty_minute_catch_up(self) -> None:
        """Every finished feat-cmux-next push run asks for a NEXT nightly.

        A push whose own request was cancelled by the next push, or whose
        request waited on a stalled pool, asked for nothing. The tick closes
        that gap from events, not a clock (user decision 2026-10-20: no GitHub
        cron on the nightly path; the dedicated builder is cmux22,
        plans/cmux-next/nightly-builder-DESIGN.md). It starts when a
        cmux-next or cmux-tui artifacts push run on feat-cmux-next completes,
        whatever its conclusion, and can be started by hand. GitHub runs
        `workflow_run` only from the default branch, so the file must exist
        on main too.
        """
        path = WORKFLOWS / "nightly-next-tick.yml"
        self.assertTrue(path.exists(), "nightly-next-tick.yml must exist")
        text = path.read_text(encoding="utf-8")
        self.assertRegex(text, r"(?m)^\s+schedule:\s*$")
        self.assertRegex(text, r'(?m)^\s+- cron: "7,37 \* \* \* \*"$')
        self.assertIn("workflow_run:", text)
        workflows = re.search(r"(?m)^\s+workflows: \[(.+)\]$", text)
        self.assertIsNotNone(workflows, "workflow_run must name its workflows")
        self.assertIn('"cmux-next"', workflows.group(1))
        self.assertIn('"cmux-tui artifacts"', workflows.group(1))
        self.assertRegex(text, r"(?m)^\s+branches: \[feat-cmux-next\]$")
        self.assertRegex(text, r"(?m)^\s+types: \[completed\]$")
        self.assertIn("github.event.workflow_run.event == 'push'", text)
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("scripts/cmux-next/request-nightly-next.sh --tree-ready", text)
        self.assertIn("cancel-in-progress: false", text)

    def test_no_workflow_reads_the_retired_decide_runner_variable(self) -> None:
        """CI_NIGHTLY_DECIDE_RUNNER named a Blacksmith pool and is deleted."""
        for path in sorted(WORKFLOWS.glob("*.yml")):
            with self.subTest(workflow=path.name):
                self.assertNotIn("CI_NIGHTLY_DECIDE_RUNNER", path.read_text(encoding="utf-8"))


if __name__ == "__main__":
    unittest.main()
