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

import os
import re
import sys
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from runner_label_policy import (  # noqa: E402
    GUARD_FUNCTION,
    GUARD_SCRIPT,
    PolicyUnreadable,
    _guard_function,
    _shell_local,
    drifted_runner_variables,
    forbidden_reason,
    pool_order_reason,
)


class PolicyIsReadFromTheGuard(unittest.TestCase):
    def test_the_three_patterns_are_still_declared(self) -> None:
        body = _guard_function(GUARD_SCRIPT.read_text(encoding="utf-8"))
        for name in ("fleet", "allowed", "selfhosted", "owned"):
            with self.subTest(pattern=name):
                self.assertTrue(_shell_local(body, name))

    def test_a_renamed_pattern_raises_instead_of_reporting_clean(self) -> None:
        with self.assertRaises(PolicyUnreadable):
            _shell_local("local something_else='x'\n", "fleet")

    def test_an_unreadable_guard_file_or_bad_pattern_raises_policy_unreadable(self) -> None:
        import tempfile

        import runner_label_policy

        good = GUARD_SCRIPT.read_text(encoding="utf-8")
        cases = {
            "missing": None,
            "bad regex": good.replace("local fleet='", "local fleet='(", 1),
            "not utf-8": good.encode("utf-8") + b"\xff\n",
        }
        for label, text in cases.items():
            with self.subTest(case=label), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / "guard.sh"
                if isinstance(text, bytes):
                    path.write_bytes(text)
                elif text is not None:
                    path.write_text(text, encoding="utf-8")
                with mock.patch.object(runner_label_policy, "GUARD_SCRIPT", path):
                    runner_label_policy._patterns.cache_clear()
                    try:
                        with self.assertRaises(PolicyUnreadable):
                            forbidden_reason("warp-macos-26-arm64-12x")
                    finally:
                        runner_label_policy._patterns.cache_clear()

    def test_a_missing_guard_function_raises(self) -> None:
        with self.assertRaises(PolicyUnreadable):
            _guard_function("other_check() {\n  local fleet='x'\n}\n")

    def test_a_same_named_local_outside_the_guard_is_not_the_policy(self) -> None:
        # The guard script is 2000 lines and other functions already use a
        # local named `allowed`. Only the owning function's copy counts.
        source = (
            "earlier_check() {\n  local fleet='nothing-matches-this'\n}\n"
            f"{GUARD_FUNCTION}() {{\n  local fleet='macos-26'\n}}\n"
        )
        self.assertEqual(_shell_local(_guard_function(source), "fleet"), "macos-26")

    def test_a_pattern_built_in_several_steps_raises(self) -> None:
        # Reading only `local fleet='macos-26'` here would silently drop
        # everything appended after it.
        for body in (
            "  local fleet='macos-26'\n  fleet+='|tart-[a-z0-9-]+'\n",
            "  local fleet='macos-26'\n  local fleet='tart-canary'\n",
            "  local fleet='macos-26'\n  fleet='tart-canary'\n",
        ):
            with self.subTest(body=body):
                with self.assertRaises(PolicyUnreadable):
                    _shell_local(body, "fleet")


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
        # Live in MACOS_RUNNER_26 and MACOS_RUNNER_26_LARGE
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
                "CI_HEALTH_REPORT_ISSUE": "cmux-persistent-compile",
                "MACOS_RUNNER_26": "warp-macos-26-arm64-12x",
            }
        )
        self.assertEqual([name for name, _, _ in drifted], ["MACOS_RUNNER_26"])

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
                "MACOS_RUNNER_26": "warp-macos-26-arm64-12x",
                "MACOS_RUNNER_26_LARGE": "warp-macos-26-arm64-12x",
            }
        )
        self.assertEqual(
            [name for name, _, _ in drifted],
            ["MACOS_RUNNER_26", "MACOS_RUNNER_26_LARGE"],
        )

    def test_surrounding_whitespace_does_not_hide_a_bad_label(self) -> None:
        drifted = drifted_runner_variables(
            {"MACOS_RUNNER_15": "  warp-macos-26-arm64-12x  "}
        )
        self.assertEqual(len(drifted), 1)
        self.assertEqual(drifted[0][1], "warp-macos-26-arm64-12x")

    def test_a_non_string_value_is_ignored_rather_than_crashing(self) -> None:
        self.assertEqual(drifted_runner_variables({"MACOS_RUNNER_15": None}), [])


HEALTH_REPORT_WORKFLOW = ROOT / ".github" / "workflows" / "ci-health-report.yml"
NON_LABEL_RUNNER_VARIABLES = {"CI_SEED_KEEP_LOCAL_RUNNERS"}


def reported_runner_variables() -> set[str]:
    text = HEALTH_REPORT_WORKFLOW.read_text(encoding="utf-8")
    return set(re.findall(r"^\s+([A-Z0-9_]+)=\$\{\{ vars\.\1\b", text, re.M))


class TheReportSeesEveryRunnerVariable(unittest.TestCase):
    def test_every_runner_variable_a_workflow_reads_is_reported(self) -> None:
        # The report is passed an explicit list rather than toJSON(vars), which
        # would print every repository variable in a public step log. A list
        # can fall behind; this is what keeps it complete.
        # These hold runner names matched against runner.name, not a runs-on
        # label, so the label policy does not apply to them.
        read = set()
        for path in (ROOT / ".github" / "workflows").glob("*.y*ml"):
            read |= {
                name
                for name in re.findall(r"vars\.([A-Z0-9_]*RUNNER[A-Z0-9_]*)", path.read_text(encoding="utf-8"))
                if name not in NON_LABEL_RUNNER_VARIABLES
            }
        self.assertTrue(read)
        missing = read - reported_runner_variables()
        self.assertEqual(missing, set(), f"add to CMUX_CI_RUNNER_VARIABLES in {HEALTH_REPORT_WORKFLOW.name}")


class SideLaneVariable(unittest.TestCase):
    def test_only_an_owned_side_label_is_allowed_beyond_the_policy(self) -> None:
        # CI_SIDE_LANE_RUNNER is the picker-less side lanes' whole runs-on.
        self.assertEqual(drifted_runner_variables({"CI_SIDE_LANE_RUNNER": "glaeda-side-std-xcode-26.6"}), [])
        self.assertEqual(drifted_runner_variables({"CI_SIDE_LANE_RUNNER": "blacksmith-6vcpu-macos-26"}), [])
        for label in ("glaeda-std-xcode-26.6", "glaeda-side-nonsense", "warp-macos-26-arm64-12x"):
            with self.subTest(label=label):
                self.assertEqual(
                    [name for name, _, _ in drifted_runner_variables({"CI_SIDE_LANE_RUNNER": label})],
                    ["CI_SIDE_LANE_RUNNER"],
                )
        # Other runner variables still may not name one.
        self.assertTrue(drifted_runner_variables({"MACOS_RUNNER_PR": "glaeda-side-std-xcode-26.6"}))


class OwnedPoolLabels(unittest.TestCase):
    OWNED = ("glaeda-std-xcode-26.6", "glaeda-light-xcode-26.6", "glaeda-xl-xcode-26")

    def test_no_runner_variable_may_hold_an_owned_label(self) -> None:
        # MACOS_RUNNER_PR would send every lane, forks' fallbacks included, to
        # the fleet; only the picker may hand one out.
        for label in self.OWNED:
            with self.subTest(label=label):
                self.assertIsNotNone(forbidden_reason(label))
                self.assertEqual(
                    [name for name, _, _ in drifted_runner_variables({"MACOS_RUNNER_PR": label})],
                    ["MACOS_RUNNER_PR"],
                )

    def test_the_pool_order_may_name_owned_and_cloud_pools(self) -> None:
        order = "glaeda-std-xcode-26.6, glaeda-light-xcode-26.6,blacksmith-12vcpu-macos-26,blacksmith-6vcpu-macos-15"
        self.assertIsNone(pool_order_reason(order))
        self.assertIsNone(pool_order_reason(""))
        self.assertEqual(drifted_runner_variables({"CI_PR_POOL_ORDER": order}), [])

    def test_the_pool_order_cannot_smuggle_in_other_fleet_labels(self) -> None:
        for bad in ("tart-canary", "warp-macos-26-arm64-12x", "self-hosted", "glaeda-mini-xcode-26.6", "cmux-macos-26"):
            with self.subTest(label=bad):
                reason = pool_order_reason(f"glaeda-std-xcode-26.6,{bad}")
                self.assertIsNotNone(reason)
                self.assertIn(bad, reason)

    def test_case_does_not_hide_a_fleet_label(self) -> None:
        # GitHub matches runner labels without regard to case.
        for label in ("GLAEDA-std-xcode-26.6", "Glaeda-Light-Xcode-26.6", "Tart-Canary", "WARP-macos-26-arm64-12x"):
            with self.subTest(label=label):
                self.assertIsNotNone(forbidden_reason(label))
        self.assertIn("lowercase", pool_order_reason("GLAEDA-std-xcode-26.6,blacksmith-6vcpu-macos-26"))
        self.assertIsNone(forbidden_reason("blacksmith-6vcpu-macos-26"))

    def test_the_guard_and_the_picker_agree_on_the_owned_shape(self) -> None:
        import pr_runner_pool
        import runner_label_policy

        guard = runner_label_policy._owned_pattern()
        for label in (*self.OWNED, "glaeda-std-xcode", "glaeda-mini-xcode-26.6", "blacksmith-6vcpu-macos-26", "glaeda-std-xcode-26.6.1"):
            with self.subTest(label=label):
                self.assertEqual(bool(guard.fullmatch(label)), pr_runner_pool.persistent(label))


class TheReportParsesItsInput(unittest.TestCase):
    def lines(self, value: str | None) -> list[str]:
        import ci_health_report

        env = {} if value is None else {ci_health_report.RUNNER_VARIABLES_ENV: value}
        with mock.patch.dict(os.environ, env, clear=False):
            if value is None:
                os.environ.pop(ci_health_report.RUNNER_VARIABLES_ENV, None)
            return ci_health_report._runner_variable_drift_lines()

    def test_absent_input_is_not_reported_as_clean(self) -> None:
        self.assertIn("not checked", self.lines(None)[0])

    def test_unset_variables_arrive_empty_and_are_clean(self) -> None:
        self.assertIn(
            "every runner variable holds",
            self.lines("MACOS_RUNNER_15=blacksmith-6vcpu-macos-15\nMACOS_RUNNER_PR=\n")[0],
        )

    def test_a_drifted_value_is_named(self) -> None:
        line = self.lines("MACOS_RUNNER_26=warp-macos-26-arm64-12x\n")[0]
        self.assertIn("MACOS_RUNNER_26", line)
        self.assertIn("1 variable(s)", line)

    def test_a_malformed_line_is_unreadable_not_clean(self) -> None:
        self.assertIn("unreadable", self.lines("MACOS_RUNNER_15\n")[0])


if __name__ == "__main__":
    unittest.main()
