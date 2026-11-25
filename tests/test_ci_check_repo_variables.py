#!/usr/bin/env python3
"""check_repo_variables.py flags the variable values CI's readers ignore.

The cases are values that actually happened or that the readers document as
silently meaning "none": a slot count as a string, a slot label the picker
does not know, an owned or forbidden label in a runner variable. The workflow
must hand it the same runner variables as the health report, so the two
lists cannot drift apart.
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import check_repo_variables as check  # noqa: E402

GOOD_RUNNERS = "LINUX_RUNNER=blacksmith-4vcpu-ubuntu-2404\nMACOS_RUNNER_PR=blacksmith-6vcpu-macos-26\nWINDOWS_RUNNER=\n"
GOOD_SLOTS = '{"glaeda-std-xcode-26.6": 42, "glaeda-light-xcode-26.6": 4, "glaeda-root-std-xcode-26.6": 10}'
# The pools as the writer left them on 2026-11-19 01:49Z: the two declared-hosted pools keep their hosted labels.
GOOD_POOLS = ('{"_updated": "2026-11-19T01:49:43Z", "linux": "blacksmith-2vcpu-ubuntu-2404", '
              '"linux_2": "blacksmith-2vcpu-ubuntu-2404", "linux_16": "blacksmith-16vcpu-ubuntu-2404", '
              '"macos_26": "blacksmith-6vcpu-macos-26", "windows": "blacksmith-4vcpu-windows-2025", '
              '"provenance": "ubuntu-24.04", "macos_intel": "macos-15-intel"}')


def env(**overrides: str) -> dict[str, str]:
    base = {
        "CMUX_CI_RUNNER_VARIABLES": GOOD_RUNNERS,
        "CI_OWNED_POOL_SLOTS": GOOD_SLOTS,
        "CMUX_CI_XCODE_APP_PR": "/Applications/Xcode_26.6.app",
        "RUNNER_POOLS": GOOD_POOLS,
    }
    base.update(overrides)
    return base


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

    def test_a_last_resort_variable_on_the_large_blacksmith_mac_fails(self) -> None:
        # 2026-10-28: MACOS_RUNNER_PR named blacksmith-12vcpu-macos-26, which started nothing from about 02:11Z.
        for name in check.LAST_RESORT_VARIABLES:
            with self.subTest(name=name):
                found = check.problems(env(CMUX_CI_RUNNER_VARIABLES=f"{name}=blacksmith-12vcpu-macos-26\n"))
                self.assertEqual(len(found), 1)
                self.assertIn(f"gh variable set {name}", found[0])
        self.assertEqual(check.problems(env(CMUX_CI_RUNNER_VARIABLES="MACOS_RUNNER_26_LARGE=blacksmith-12vcpu-macos-26\n")), [])

    def test_no_runner_variable_or_undeclared_pool_holds_a_github_hosted_label(self) -> None:
        # 2026-11-18: jobs RUNNER_POOLS had routed to `ubuntu-24.04` sat queued 444 min (Leo: "just dont use
        # github for private"); CI_TRUSTED_RUNNER held the same label.
        for name, label in (("CI_TRUSTED_RUNNER", "ubuntu-24.04"), ("LINUX_RUNNER", "ubuntu-latest"),
                            ("CI_CONTROL_RUNNER", "ubuntu-24.04-arm"), ("WINDOWS_RUNNER", "windows-2025"),
                            ("LINUX_BUILD_RUNNER", "ubuntu-22.04")):
            with self.subTest(name=name, label=label):
                found = check.problems(env(CMUX_CI_RUNNER_VARIABLES=f"{name}={label}\n"))
                self.assertEqual(len(found), 1, found)
                self.assertIn(f"{name}=", found[0])
                self.assertIn("GitHub-hosted", found[0])
        for pool, label in (("linux_2", "ubuntu-24.04"), ("linux_16", "ubuntu-latest"), ("windows", "windows-2025")):
            with self.subTest(pool=pool):
                pools = GOOD_POOLS[:-1] + f', "{pool}": "{label}"}}'  # a later key wins in json.loads
                found = check.problems(env(RUNNER_POOLS=pools))
                self.assertEqual(len(found), 1, found)
                self.assertIn(f"pool `{pool}`", found[0])
        # Blacksmith and owned labels whose names carry an image name are not hosted.
        for label in ("blacksmith-2vcpu-ubuntu-2404", "cmux-gcp-lane-x64", "blacksmith-4vcpu-windows-2025"):
            with self.subTest(label=label):
                self.assertEqual(check.problems(env(CMUX_CI_RUNNER_VARIABLES=f"LINUX_RUNNER={label}\n")), [])

    def test_the_pools_must_be_passed(self) -> None:
        found = check.problems(env(RUNNER_POOLS=""))
        self.assertEqual(len(found), 1)
        self.assertIn("RUNNER_POOLS is empty", found[0])

    def test_nothing_to_check_is_a_failure_not_a_pass(self) -> None:
        self.assertTrue(check.problems(env(CMUX_CI_RUNNER_VARIABLES="")))
        self.assertTrue(check.problems(env(CMUX_CI_RUNNER_VARIABLES="not a pair")))

    def test_a_repeated_name_fails_instead_of_the_last_value_winning(self) -> None:
        # A value with a newline in it can read as a second NAME=value line.
        runners = "MACOS_RUNNER_PR=warp-macos-26-arm64-12x\nMACOS_RUNNER_PR=blacksmith-6vcpu-macos-26\n"
        found = check.problems(env(CMUX_CI_RUNNER_VARIABLES=runners))
        self.assertEqual(len(found), 1)
        self.assertIn("repeats MACOS_RUNNER_PR", found[0])


if __name__ == "__main__":
    unittest.main()
