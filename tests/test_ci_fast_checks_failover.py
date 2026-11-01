#!/usr/bin/env python3
"""fast-checks.yml takes its Blacksmith Linux size from the linux runner pool.

On 2026-10-27 the 32 vCPU Blacksmith Linux label started no job for the
organization for a while, and fast-checks.yml named blacksmith-32vcpu-ubuntu-2404
directly. A first fix chose 16 vCPU while the overflow switch's record was set,
but the switch trips only when every probed size stalls, so one stalled size
still held every run. The job now reads fromJSON(vars.RUNNER_POOLS).linux: the
pool (.github/runners.json) declares the sizes, and scripts/ci/runner_pools.py
moves it off a size the probe saw stall. The audited pool tries fleet Linux before Blacksmith: no job
runs on GitHub-hosted Ubuntu, so it never names vars.LINUX_RUNNER (which the
switch may point at hosted Linux) or a hosted label. Sticky disks work on every
Blacksmith Linux size, so the cache steps stay as they are.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

WORKFLOW = Path(__file__).resolve().parents[1] / ".github" / "workflows" / "fast-checks.yml"
POOL = "|| fromJSON(vars.RUNNER_POOLS).linux }}"

FORK_BRANCH = re.compile(r"github\.repository_owner != 'manaflow-ai' && 'ubuntu-[0-9.]+' \|\|")
BLACKSMITH_LINUX = re.compile(r"blacksmith-\d+vcpu-ubuntu-\d+(-arm)?")
HOSTED = re.compile(r"ubuntu-(latest|slim|\d)")


def runs_on_lines() -> list[str]:
    text = WORKFLOW.read_text(encoding="utf-8")
    return [line for line in text.splitlines() if re.match(r"^\s*runs-on\s*:", line)]


class FastChecksFailoverTests(unittest.TestCase):
    def test_the_label_comes_from_the_linux_pool(self) -> None:
        lines = runs_on_lines()
        self.assertEqual(len(lines), 1)
        line = lines[0].rstrip()
        self.assertTrue(line.endswith(POOL), line.strip())
        # Past the re-dispatch input, no size is written down.
        self.assertNotRegex(line.split("inputs.runner ||")[-1], BLACKSMITH_LINUX)

    def test_the_linux_pool_is_fleet_then_bounded_blacksmith(self) -> None:
        import json
        runners = json.loads((WORKFLOW.parents[1] / "runners.json").read_text(encoding="utf-8"))
        members = runners["pools"]["linux"]["members"]
        self.assertGreaterEqual(len(members), 2)
        self.assertEqual(members[0], "cmux-fleet-linux-x64")
        for label in members[1:]:
            self.assertRegex(label, r"^blacksmith-\d+vcpu-ubuntu-2404$")
        self.assertEqual(runners["pools"]["linux_ephemeral"]["members"], members[1:])

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
