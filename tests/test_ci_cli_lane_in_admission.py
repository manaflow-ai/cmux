#!/usr/bin/env python3
"""The Debug CLI is built once per CI run, by compile admission, which tests it.

A separate cli-pipe-regressions.yml job used to restore packages, resolve, and
build the Debug cmux-cli scheme on its own Mac for three Python CLI tests, while
compile admission built the same binary in the same run. These guards keep the
CLI tests on admission's binary and keep a second CLI build from coming back.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
ADMISSION_JOB = "macos-compile-admission"
SMOKE_STEP = "Run early CLI binary smoke checks"
CLI_TESTS = (
    "tests/test_cli_broken_pipe_writes.py",
    "tests/test_cli_config_doctor.py",
    "tests/test_cli_glaeda_execution.py",
)
# xcodebuild -scheme cmux-cli, not cmux-cli-tests (admission's CLI scheme).
CLI_SCHEME_BUILD = re.compile(r"-scheme[ \t]+[\"']?cmux-cli(?![A-Za-z0-9_-])")

sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import product_input_identity  # noqa: E402


def job_block(text: str, job: str) -> str:
    match = re.search(rf"(?ms)^  {re.escape(job)}:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", text)
    if match is None:
        raise AssertionError(f"job {job} not found")
    return match.group(1)


def step_block(job: str, name: str) -> str:
    match = re.search(
        rf"(?ms)^      - name: {re.escape(name)}\n(.*?)(?=^      - |\Z)", job
    )
    if match is None:
        raise AssertionError(f"step {name!r} not found")
    return match.group(1)


class CliLaneInAdmissionTests(unittest.TestCase):
    def test_no_workflow_builds_the_cmux_cli_scheme(self):
        self.assertFalse((WORKFLOWS / "cli-pipe-regressions.yml").exists())
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            with self.subTest(workflow=path.name):
                match = CLI_SCHEME_BUILD.search(path.read_text(encoding="utf-8"))
                self.assertIsNone(match, match and match.group(0))

    def test_ci_calls_no_separate_cli_workflow(self):
        text = (WORKFLOWS / "ci.yml").read_text(encoding="utf-8")
        self.assertFalse("cli-pipe-regressions" in text, "ci.yml still names cli-pipe-regressions")
        self.assertIsNone(re.search(r"(?m)^  cli:\n", text), "ci.yml still has a `cli` job")
        self.assertIsNone(re.search(r"(?m)^      - cli$", job_block(text, "ci-status")),
                          "ci-status still needs a `cli` job")

    def test_every_product_profile_builds_the_cli_binary(self):
        # Both profiles build cmux-cli-tests, whose host is the Debug cmux CLI
        # at Build/Products/Debug/cmux; reused products restore to that path.
        for profile, schemes in product_input_identity.PRODUCT_PROFILES.items():
            with self.subTest(profile=profile):
                self.assertIn("cmux-cli-tests", schemes)

    def test_admission_runs_for_every_cli_route(self):
        ci = (WORKFLOWS / "ci.yml").read_text(encoding="utf-8")
        self.assertIn("needs.changes.outputs.cli == 'true'", job_block(ci, "macos"))
        admission = job_block((WORKFLOWS / "ci-macos.yml").read_text(encoding="utf-8"), ADMISSION_JOB)
        condition = re.search(r"(?m)^    if: (.*)$", admission).group(1)
        self.assertIn("(inputs.macos == 'true' || inputs.cli == 'true')", condition)
        self.assertIn("|| inputs.cli == 'true')", condition)

    def test_admission_smoke_step_runs_the_cli_tests(self):
        admission = job_block((WORKFLOWS / "ci-macos.yml").read_text(encoding="utf-8"), ADMISSION_JOB)
        step = step_block(admission, SMOKE_STEP)
        # No `if:`: the step runs after a compile and after a product reuse.
        self.assertNotRegex(step, r"(?m)^        if:")
        self.assertIn('"$CMUX_COMPILE_ADMISSION_DERIVED_DATA/Build/Products/Debug/cmux"', step)
        for test in CLI_TESTS:
            with self.subTest(test=test):
                line = rf"(?m)^ +CMUX_CLI_BIN=\"\$CLI_BIN\" python3 {re.escape(test)}$"
                self.assertIsNotNone(re.search(line, step), f"{SMOKE_STEP} does not run {test}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
