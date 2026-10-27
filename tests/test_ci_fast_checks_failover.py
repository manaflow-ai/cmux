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
        for line in runs_on_lines():
            self.assertNotIn("LINUX_RUNNER", line, line.strip())
            # The only hosted label allowed is the fork branch that predates this change.
            hosted = re.findall(r"'ubuntu-[0-9.]+'", line)
            self.assertLessEqual(len(hosted), 1, line.strip())
            if hosted:
                self.assertIn("github.repository_owner != 'manaflow-ai' && 'ubuntu-", line)


if __name__ == "__main__":
    unittest.main()
