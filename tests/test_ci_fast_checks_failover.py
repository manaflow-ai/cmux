#!/usr/bin/env python3
"""fast-checks.yml fails over with the Blacksmith overflow switch.

On 2026-10-27 Blacksmith Linux started no job for the organization for a while.
ci-cloud-overflow-probe.yml pointed LINUX_RUNNER at GitHub-hosted Linux and wrote
CI_CLOUD_OVERFLOW_SAVED, but fast-checks.yml named blacksmith-32vcpu-ubuntu-2404
directly, so its runs got no runner at all. While the record is set these jobs
take LINUX_RUNNER, which the switch has pointed at its failover; an unset record
is falsy, so healthy routing is unchanged. No literal GitHub-hosted label is named
(tests/test_ci_self_hosted_guard.sh).
Sticky disks exist only on Blacksmith, so fast checks skip them (and the
sanitizer that works inside the mounted checkout) elsewhere.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

WORKFLOWS = Path(__file__).resolve().parents[1] / ".github" / "workflows"
LABEL = re.compile(r"'blacksmith-[0-9]+vcpu-ubuntu-2404'")
FAILOVER = "vars.CI_CLOUD_OVERFLOW_SAVED && vars.LINUX_RUNNER || 'blacksmith-"
ON_BLACKSMITH = "if: startsWith(runner.name, 'blacksmith-')"


def runs_on_lines(name: str) -> list[str]:
    text = (WORKFLOWS / name).read_text(encoding="utf-8")
    return [line for line in text.splitlines() if re.match(r"^\s*runs-on\s*:", line)]


class FastChecksFailoverTests(unittest.TestCase):
    def test_literal_linux_labels_fail_over_while_the_record_is_set(self) -> None:
        for name in ("fast-checks.yml",):
            literal = [line for line in runs_on_lines(name) if LABEL.search(line)]
            self.assertTrue(literal, name)
            for line in literal:
                self.assertIn(FAILOVER, line, f"{name}: {line.strip()}")
                # The failover term sits right before the Blacksmith fallback, after the fork check.
                self.assertTrue(line.rstrip().endswith("' }}"), line)

    def test_fast_checks_mounts_sticky_disks_only_on_blacksmith(self) -> None:
        text = (WORKFLOWS / "fast-checks.yml").read_text(encoding="utf-8")
        for step in ("Mount warm checkout", "Sanitize persistent checkout metadata",
                     "Mount package and compilation caches"):
            body = re.search(rf"- name: {re.escape(step)}\n((?:[ ]{{8}}[^\n]*\n)+)", text)
            self.assertIsNotNone(body, step)
            self.assertIn(ON_BLACKSMITH, body.group(1), step)
        self.assertEqual(text.count("useblacksmith/stickydisk"), 2)


if __name__ == "__main__":
    unittest.main()
