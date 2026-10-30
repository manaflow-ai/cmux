#!/usr/bin/env python3
"""fast-checks.yml fails over to another Blacksmith Linux size with the overflow switch.

On 2026-10-27 the 32 vCPU Blacksmith Linux label started no job for the
organization for a while. ci-cloud-overflow-probe.yml wrote
CI_CLOUD_OVERFLOW_SAVED, but fast-checks.yml named blacksmith-32vcpu-ubuntu-2404
directly, so its runs waited on that label. While the record is set the job takes
blacksmith-16vcpu-ubuntu-2404 instead; an unset record is falsy, so healthy
routing is unchanged. The failover stays on Blacksmith: no job runs on
GitHub-hosted Ubuntu, so it never names vars.LINUX_RUNNER (which the switch may
point at hosted Linux) or a hosted label. Sticky disks work on every Blacksmith
Linux size, so the cache steps stay as they are.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "fast-checks.yml"
FAILOVER = ("vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-16vcpu-ubuntu-2404'"
            " || 'blacksmith-32vcpu-ubuntu-2404' }}")

FORK_BRANCH = re.compile(r"github\.repository_owner != 'manaflow-ai' && 'ubuntu-[0-9.]+' \|\|")
BLACKSMITH_LINUX = re.compile(r"blacksmith-\d+vcpu-ubuntu-\d+(-arm)?")
HOSTED = re.compile(r"ubuntu-(latest|slim|\d)")


def runs_on_lines() -> list[str]:
    text = WORKFLOW.read_text(encoding="utf-8")
    return [line for line in text.splitlines() if re.match(r"^\s*runs-on\s*:", line)]


class FastChecksFailoverTests(unittest.TestCase):
    def test_blacksmith_linux_label_fails_over_to_another_blacksmith_size(self) -> None:
        lines = [line for line in runs_on_lines() if "blacksmith-32vcpu-ubuntu-2404" in line]
        self.assertTrue(lines)
        for line in lines:
            self.assertTrue(line.rstrip().endswith(FAILOVER), line.strip())

    def test_failover_never_reaches_github_hosted_linux(self) -> None:
        lines = runs_on_lines()
        self.assertTrue(lines)
        for line in lines:
            self.assertNotIn("LINUX_RUNNER", line, line.strip())
            # The fork branch is the one hosted label allowed; every other
            # ubuntu image named must be a Blacksmith label.
            rest = FORK_BRANCH.sub("", line, count=1)
            rest = BLACKSMITH_LINUX.sub("", rest)
            self.assertNotRegex(rest, HOSTED, line.strip())

    def test_a_broker_redispatch_may_name_only_a_listed_blacksmith_linux_label(self) -> None:
        # HQ's lane-gh broker dispatches a run again with `runner` when the first waited on a label that started
        # nothing (Leo, 2026-10-28: "just pin the set of the shit that isn't hilariously slow").
        text = WORKFLOW.read_text(encoding="utf-8")
        self.assertRegex(text, r"\n      runner:\n(?:        .*\n)*?        default: ''\n")
        line = next(line for line in runs_on_lines() if "inputs.runner" in line)
        listed = re.search(r"contains\(fromJSON\('(\[[^']*\])'\), inputs\.runner\) && inputs\.runner \|\|", line)
        self.assertIsNotNone(listed, line.strip())
        import json
        labels = json.loads(listed.group(1))
        self.assertTrue(labels)
        for label in labels:
            self.assertRegex(label, r"^blacksmith-\d+vcpu-ubuntu-2404$")

    def test_the_hosted_check_catches_hosted_labels(self) -> None:
        for bad in ("runs-on: ubuntu-latest",
                    "runs-on: ${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'ubuntu-latest' || 'blacksmith-32vcpu-ubuntu-2404' }}",
                    'runs-on: "ubuntu-24.04"',
                    "runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'ubuntu-22.04' }}"):
            rest = BLACKSMITH_LINUX.sub("", FORK_BRANCH.sub("", bad, count=1))
            self.assertRegex(rest, HOSTED, bad)


if __name__ == "__main__":
    unittest.main()
