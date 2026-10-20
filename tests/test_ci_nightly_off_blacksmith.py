#!/usr/bin/env python3
"""Nightly workflows never run on Blacksmith.

User decision 2026-10-19: cmux NIGHTLY, cmux NEXT NIGHTLY and the cmux-tui
nightly build on our own Mac minis (the trusted glaeda pools), and every other
nightly job runs on an ephemeral GitHub-hosted runner. No nightly job may name
a Blacksmith label, and no nightly job may read a repository runner variable
whose value or fallback is Blacksmith (LINUX_RUNNER, MACOS_RUNNER_*, ...),
because setting such a variable would silently move the nightly back.
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


def code_lines(path: Path):
    for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        if line.lstrip().startswith("#"):
            continue
        yield number, line.split(" # ", 1)[0]


class NightlyOffBlacksmithTests(unittest.TestCase):
    def test_nightly_workflows_are_discovered(self) -> None:
        names = {path.name for path in nightly_workflows()}
        for required in ("nightly.yml", "auto-resume-nightly-notarization.yml"):
            self.assertIn(required, names)

    def test_no_nightly_job_names_blacksmith(self) -> None:
        failures = [
            f"{path.name}:{number}: {line.strip()}"
            for path in nightly_workflows()
            for number, line in code_lines(path)
            if BLACKSMITH.search(line)
        ]
        self.assertEqual(failures, [], "nightly workflows must not route to Blacksmith")

    def test_no_nightly_job_reads_a_shared_blacksmith_runner_variable(self) -> None:
        failures = [
            f"{path.name}:{number}: {line.strip()}"
            for path in nightly_workflows()
            for number, line in code_lines(path)
            if SHARED_RUNNER_VARIABLES.search(line)
        ]
        self.assertEqual(failures, [], "a shared runner variable points at Blacksmith; use a literal owned or hosted label")

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
            r"|vars\.(CI_SIDE_LANE_RUNNER|CI_NEXT_DAEMON_POOL|CI_NEXT_PROMOTE_POOL|CI_LIGHT_LANE_RUNNER)\b"
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
    def test_a_schedule_starts_a_nightly_next_at_least_twice_a_day(self) -> None:
        """Pushes alone are not a trigger: a red or cancelled push run asks nothing.

        GitHub runs `schedule` only from the default branch, so the tick
        workflow must exist on main too; it asks for the newest green
        feat-cmux-next commit and can also be started by hand.
        """
        path = WORKFLOWS / "nightly-next-tick.yml"
        self.assertTrue(path.exists(), "nightly-next-tick.yml must exist")
        text = path.read_text(encoding="utf-8")
        crons = re.findall(r"^\s+- cron: \"([^\"]+)\"", text, re.MULTILINE)
        self.assertGreaterEqual(len(crons), 2)
        self.assertIn("workflow_dispatch:", text)
        self.assertIn("scripts/cmux-next/request-nightly-next.sh --tree-ready", text)
        self.assertIn("cancel-in-progress: false", text)

if __name__ == "__main__":
    unittest.main()
