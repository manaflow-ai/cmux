#!/usr/bin/env python3
"""The runner label policy must stay the guard's policy, not a second copy of it.

`scripts/ci/runner_label_policy.py` reads its patterns out of
`tests/test_ci_self_hosted_guard.sh`. That read is the whole design: a private
copy would go stale the first time somebody widened the guard's allow-list, and
a stale copy reports "no drift" forever, which is worse than not running.

So the cases here are the ones that would catch the read breaking, plus the
label that motivated the module: `warp-macos-26-arm64-12x`, which the guard
rejects in a workflow file and which sat in two repository variables for three
days because nothing reads variable values.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from runner_label_policy import (  # noqa: E402
    GUARD_SCRIPT,
    PolicyUnreadable,
    _shell_local,
    drifted_runner_variables,
    forbidden_reason,
)


class PolicyIsReadFromTheGuard(unittest.TestCase):
    def test_the_three_patterns_are_still_declared(self) -> None:
        source = GUARD_SCRIPT.read_text(encoding="utf-8")
        for name in ("fleet", "allowed", "selfhosted"):
            with self.subTest(pattern=name):
                self.assertTrue(_shell_local(source, name))

    def test_a_renamed_pattern_raises_instead_of_reporting_clean(self) -> None:
        with self.assertRaises(PolicyUnreadable):
            _shell_local("local something_else='x'\n", "fleet")


class ApprovedLabelsPass(unittest.TestCase):
    def test_every_label_the_repository_actually_uses(self) -> None:
        for label in (
            "blacksmith-6vcpu-macos-15",
            "blacksmith-6vcpu-macos-26",
            "blacksmith-12vcpu-macos-26",
            "blacksmith-4vcpu-ubuntu-2404",
            "warp-macos-15-arm64-6x",
            "ubuntu-24.04-arm",
            "macos-15",
        ):
            with self.subTest(label=label):
                self.assertIsNone(forbidden_reason(label))

    def test_an_unset_variable_is_not_drift(self) -> None:
        self.assertIsNone(forbidden_reason(""))


class ForbiddenLabelsAreCaught(unittest.TestCase):
    def test_the_label_that_motivated_this_module(self) -> None:
        # Live in MACOS_RUNNER_26_RELEASE and MACOS_RUNNER_26_NIGHTLY_BUILD
        # from 2026-09-20. It matches the guard's `macos-26` fleet pattern and
        # is absent from the allow-list, which only carries the 6x macOS 15 Warp
        # label, so the guard would reject it on sight in a workflow file.
        self.assertIsNotNone(forbidden_reason("warp-macos-26-arm64-12x"))

    def test_fleet_and_self_hosted_labels(self) -> None:
        for label in (
            "tart-macos-15",
            "cmux-persistent-compile",
            "macfleet",
            "mac-mini-3",
            "self-hosted",
        ):
            with self.subTest(label=label):
                self.assertIsNotNone(forbidden_reason(label))

    def test_an_approved_label_does_not_mask_a_forbidden_one(self) -> None:
        # Stripping the allow-list first is what lets blacksmith-6vcpu-macos-26
        # through; it must not also launder a fleet label sitting beside it.
        self.assertIsNotNone(
            forbidden_reason("blacksmith-6vcpu-macos-26,cmux-persistent-compile")
        )


class DriftReportingOverVariables(unittest.TestCase):
    def test_only_runner_variables_are_inspected(self) -> None:
        drifted = drifted_runner_variables(
            {
                "CI_HEALTH_REPORT_ISSUE": "tart-macos-15",
                "MACOS_RUNNER_26_RELEASE": "warp-macos-26-arm64-12x",
            }
        )
        self.assertEqual([name for name, _, _ in drifted], ["MACOS_RUNNER_26_RELEASE"])

    def test_clean_configuration_reports_nothing(self) -> None:
        self.assertEqual(
            drifted_runner_variables(
                {
                    "MACOS_RUNNER_15": "blacksmith-6vcpu-macos-15",
                    "LINUX_RUNNER": "blacksmith-4vcpu-ubuntu-2404",
                    "MACOS_RUNNER_PR": "",
                }
            ),
            [],
        )

    def test_findings_are_sorted_so_two_reports_diff_cleanly(self) -> None:
        drifted = drifted_runner_variables(
            {
                "MACOS_RUNNER_26_RELEASE": "warp-macos-26-arm64-12x",
                "MACOS_RUNNER_26_NIGHTLY_BUILD": "warp-macos-26-arm64-12x",
            }
        )
        self.assertEqual(
            [name for name, _, _ in drifted],
            ["MACOS_RUNNER_26_NIGHTLY_BUILD", "MACOS_RUNNER_26_RELEASE"],
        )

    def test_surrounding_whitespace_does_not_hide_a_bad_label(self) -> None:
        drifted = drifted_runner_variables(
            {"MACOS_RUNNER_15": "  warp-macos-26-arm64-12x  "}
        )
        self.assertEqual(len(drifted), 1)
        self.assertEqual(drifted[0][1], "warp-macos-26-arm64-12x")

    def test_a_non_string_value_is_ignored_rather_than_crashing(self) -> None:
        self.assertEqual(drifted_runner_variables({"MACOS_RUNNER_15": None}), [])


if __name__ == "__main__":
    unittest.main()
