#!/usr/bin/env python3
"""check_repo_variables.py flags the variable values CI's readers ignore.

The cases are values that actually happened or that the readers document as
silently meaning "none": a slot count as a string, a slot label the picker
does not know, an owned or forbidden label in a runner variable. The workflow
must hand it the same runner variables as the health report, so the two
lists cannot drift apart.
"""

from __future__ import annotations

import re
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import check_repo_variables as check  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"
GOOD_RUNNERS = "LINUX_RUNNER=blacksmith-4vcpu-ubuntu-2404\nMACOS_RUNNER_PR=blacksmith-6vcpu-macos-26\nWINDOWS_RUNNER=\n"
GOOD_SLOTS = '{"glaeda-std-xcode-26.6": 42, "glaeda-light-xcode-26.6": 4, "glaeda-root-std-xcode-26.6": 10}'


def env(**overrides: str) -> dict[str, str]:
    base = {
        "CMUX_CI_RUNNER_VARIABLES": GOOD_RUNNERS,
        "CI_OWNED_POOL_SLOTS": GOOD_SLOTS,
        "CMUX_CI_XCODE_APP_PR": "/Applications/Xcode_26.6.app",
    }
    base.update(overrides)
    return base


def runner_block(workflow: str) -> list[str]:
    text = (WORKFLOWS / workflow).read_text(encoding="utf-8")
    return re.findall(r"^\s+([A-Z0-9_]+=\$\{\{ vars\.[^\n]*)$", text, re.M)


class Values(unittest.TestCase):
    def test_good_values_pass(self) -> None:
        self.assertEqual(check.problems(env()), [])
        self.assertEqual(check.problems(env(CI_OWNED_POOL_SLOTS="")), [])

    def test_slot_values_the_picker_reads_as_zero_fail(self) -> None:
        for value in ('{"glaeda-std-xcode-26.6": "42"}', "forty", '{"glaeda-std-xcode": 4}', "[4]"):
            with self.subTest(value=value):
                found = check.problems(env(CI_OWNED_POOL_SLOTS=value))
                self.assertTrue(found)
                self.assertIn("set-owned-slots.sh", found[0])

    def test_runner_labels_the_guard_refuses_fail(self) -> None:
        for label in ("warp-macos-26-arm64-12x", "glaeda-std-xcode-26.6"):
            with self.subTest(label=label):
                found = check.problems(env(CMUX_CI_RUNNER_VARIABLES=f"MACOS_RUNNER_PR={label}\n"))
                self.assertEqual(len(found), 1)
                self.assertIn("MACOS_RUNNER_PR", found[0])

    def test_nothing_to_check_is_a_failure_not_a_pass(self) -> None:
        self.assertTrue(check.problems(env(CMUX_CI_RUNNER_VARIABLES="")))
        self.assertTrue(check.problems(env(CMUX_CI_RUNNER_VARIABLES="not a pair")))

    def test_a_repeated_name_fails_instead_of_the_last_value_winning(self) -> None:
        # A value with a newline in it can read as a second NAME=value line.
        runners = "MACOS_RUNNER_PR=warp-macos-26-arm64-12x\nMACOS_RUNNER_PR=blacksmith-6vcpu-macos-26\n"
        found = check.problems(env(CMUX_CI_RUNNER_VARIABLES=runners))
        self.assertEqual(len(found), 1)
        self.assertIn("repeats MACOS_RUNNER_PR", found[0])


class Wiring(unittest.TestCase):
    def test_same_runner_variables_as_the_health_report(self) -> None:
        mine = runner_block("ci-repo-variables.yml")
        self.assertTrue(mine)
        self.assertEqual(mine, runner_block("ci-health-report.yml"))

    def test_scheduled_and_reads_the_slots(self) -> None:
        text = (WORKFLOWS / "ci-repo-variables.yml").read_text(encoding="utf-8")
        self.assertIn("schedule:", text)
        self.assertIn("CI_OWNED_POOL_SLOTS: ${{ vars.CI_OWNED_POOL_SLOTS }}", text)
        self.assertIn("run: python3 scripts/ci/check_repo_variables.py", text)


if __name__ == "__main__":
    unittest.main()
