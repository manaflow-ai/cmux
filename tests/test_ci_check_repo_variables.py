#!/usr/bin/env python3
"""check_repo_variables.py flags the variable values CI's readers ignore.

The cases are values that actually happened or that the readers document as
silently meaning "none": a slot count as a string, a slot label the picker
does not know, an owned or forbidden label in a runner variable. The workflow
must hand it the same runner variables as the health report, so the two
lists cannot drift apart.
"""

from __future__ import annotations

import json

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
    """The CMUX_CI_RUNNER_VARIABLES lines (ci-repo-variables.yml also passes runs_on_values.py its own block)."""
    text = (WORKFLOWS / workflow).read_text(encoding="utf-8")
    text = text[text.index("CMUX_CI_RUNNER_VARIABLES: |"):]
    text = text[:text.index("run:")]
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

    def test_daemon_tests_never_share_the_pull_request_side_label(self) -> None:
        side = "CI_SIDE_LANE_RUNNER=glaeda-side-std-xcode-26.6\n"
        found = check.problems(env(CMUX_CI_RUNNER_VARIABLES=GOOD_RUNNERS + side, CI_NEXT_DAEMON_POOL="glaeda-side-std-xcode-26.6"))
        self.assertEqual(len(found), 1)
        self.assertIn("CI_NEXT_DAEMON_POOL", found[0])
        for pool in ("glaeda-side-light-xcode-26.6", ""):
            with self.subTest(pool=pool):
                self.assertEqual(check.problems(env(CMUX_CI_RUNNER_VARIABLES=GOOD_RUNNERS + side, CI_NEXT_DAEMON_POOL=pool)), [])

    def test_pin_daemon_tests_never_share_the_side_lane_or_the_promotion_pool(self) -> None:
        # 2026-10-21: cmux-tui-pin-* pushes (one per merged pull request) take
        # CI_PIN_DAEMON_POOL, else CI_LIGHT_LANE_RUNNER. On the side label they
        # flooded pull request lanes; on CI_NEXT_DAEMON_POOL they would stall
        # the nightly-next promotion.
        side, light, daemon = "glaeda-side-std-xcode-26.6", "glaeda-side-light-xcode-26.6", "glaeda-daemon-xcode-26.6"
        runners = f"{GOOD_RUNNERS}CI_SIDE_LANE_RUNNER={side}\n"
        failing = [
            ("pin pool is the daemon pool", {"CI_PIN_DAEMON_POOL": daemon, "CI_NEXT_DAEMON_POOL": daemon}, "CI_PIN_DAEMON_POOL"),
            ("pin pool is the side lane", {"CI_PIN_DAEMON_POOL": side, "CI_NEXT_DAEMON_POOL": daemon}, "CI_PIN_DAEMON_POOL"),
            ("no pin pool, light lane is the side lane", {"CI_PIN_DAEMON_POOL": "", "light": side}, "CI_LIGHT_LANE_RUNNER"),
        ]
        for why, values, name in failing:
            with self.subTest(why):
                light_line = f"CI_LIGHT_LANE_RUNNER={values.pop('light', light)}\n"
                found = check.problems(env(CMUX_CI_RUNNER_VARIABLES=runners + light_line, **values))
                pin_found = [problem for problem in found if "pin" in problem]
                self.assertEqual(len(pin_found), 1, found)
                self.assertIn(name, pin_found[0])
        passing = [
            ("distinct pin pool", {"CI_PIN_DAEMON_POOL": "glaeda-pin-xcode-26.6", "CI_NEXT_DAEMON_POOL": light}),
            ("no pin pool, light lane distinct", {"CI_PIN_DAEMON_POOL": "", "CI_NEXT_DAEMON_POOL": daemon}),
            ("nothing set", {}),
        ]
        for why, values in passing:
            with self.subTest(why):
                light_line = f"CI_LIGHT_LANE_RUNNER={light}\n"
                self.assertEqual(check.problems(env(CMUX_CI_RUNNER_VARIABLES=runners + light_line, **values)), [])
            with self.subTest(why, warnings=True):
                self.assertEqual(check.warnings(env(CMUX_CI_RUNNER_VARIABLES=runners + light_line, **values)), [])
        # claude-sr2, 2026-10-21: until promotion gets its own label, the
        # light lane may serve both the promotion's daemon tests and the pin
        # pushes (CI_PIN_DAEMON_POOL unset): a warning, not a failure.
        shared = env(CMUX_CI_RUNNER_VARIABLES=runners + f"CI_LIGHT_LANE_RUNNER={light}\n",
                     CI_PIN_DAEMON_POOL="", CI_NEXT_DAEMON_POOL=light)
        self.assertEqual(check.problems(shared), [])
        warned = check.warnings(shared)
        self.assertEqual(len(warned), 1, warned)
        self.assertIn("CI_LIGHT_LANE_RUNNER", warned[0])
        self.assertIn("CI_NEXT_DAEMON_POOL", warned[0])
        self.assertIn(light, warned[0])
        # A pin pool that is set never falls back to a warning.
        self.assertTrue(check.problems(env(CMUX_CI_RUNNER_VARIABLES=runners + f"CI_LIGHT_LANE_RUNNER={light}\n",
                                           CI_PIN_DAEMON_POOL=light, CI_NEXT_DAEMON_POOL=light)))
        # Empties are ignored: no pin pool and no light lane is not a match.
        self.assertEqual(check.problems(env(CMUX_CI_RUNNER_VARIABLES=GOOD_RUNNERS + "CI_LIGHT_LANE_RUNNER=\n",
                                            CI_PIN_DAEMON_POOL="", CI_NEXT_DAEMON_POOL="")), [])

    def test_a_recorded_failover_never_excuses_a_hosted_mac(self) -> None:
        # The overflow switch's record excuses its own failover values, but a
        # GitHub-hosted Mac is never one (tests/test_ci_no_github_hosted_macos.py).
        record = json.dumps({"changed": {"MACOS_RUNNER_15": {"before": None, "after": "macos-15"}}})
        found = check.problems(env(CMUX_CI_RUNNER_VARIABLES=GOOD_RUNNERS + "MACOS_RUNNER_15=macos-15\n",
                                   CI_CLOUD_OVERFLOW_SAVED=record))
        self.assertTrue(any("MACOS_RUNNER_15" in problem for problem in found), found)

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
        self.assertIn("CI_NEXT_DAEMON_POOL: ${{ vars.CI_NEXT_DAEMON_POOL }}", text)
        self.assertIn("CI_PIN_DAEMON_POOL: ${{ vars.CI_PIN_DAEMON_POOL }}", text)
        self.assertIn("run: python3 scripts/ci/check_repo_variables.py", text)


if __name__ == "__main__":
    unittest.main()
