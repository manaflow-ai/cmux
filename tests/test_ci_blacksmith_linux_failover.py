#!/usr/bin/env python3
"""Every Blacksmith Linux runs-on fails over while the overflow switch is on.

When Blacksmith Linux starts no jobs, the overflow switch
(scripts/ci/cloud_overflow_switch.py) writes the CI_CLOUD_OVERFLOW_SAVED record
and points vars.LINUX_RUNNER and vars.CI_TRUSTED_RUNNER at the hosted fallback.
A runs-on that names a Blacksmith Linux label literally and reads neither
variable never sees that, so its job queued with zero capacity for the whole
outage (2026-10-27). Each such label must sit behind
`vars.CI_CLOUD_OVERFLOW_SAVED && 'ubuntu-24.04' ||`, or the expression must
read one of the switched variables first. An unset variable is falsy, so
healthy routing still takes the Blacksmith label.

Nightly, notarization, dev-daily and release/publish workflows are sequenced
separately and are not checked here.
"""

from __future__ import annotations

import re
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"

EXCLUDED_NAME = re.compile(
    r"nightly|notarization|^cmux-next-dev-daily\.yml$|release|publish|testflight|app-?store|homebrew"
)
EXCLUDED_FILES = {
    # Blacksmith Testbox setup: the box exists only on Blacksmith.
    "cmux-tui-testbox-warmup.yml",
    # The probe that detects the outage must target Blacksmith itself.
    "ci-cloud-overflow-probe.yml",
}
# x64 Blacksmith Linux labels; -arm labels are a different pool.
LABEL = re.compile(r"blacksmith-\d+vcpu-ubuntu-2404(?![-\w])")
RUNNER_KEY = re.compile(
    r"^\s*(?:-\s+)?(runs-on|runs_on|runner|linux_runner|DAEMON_POOL|CMUX_NEXT_RUNNER|os):\s*(.*)$"
)
FAILOVER = "vars.CI_CLOUD_OVERFLOW_SAVED && 'ubuntu-24.04' || '"


def covered(value: str) -> bool:
    """True when every literal Blacksmith Linux fallback in value fails over."""
    if "vars.CI_TRUSTED_RUNNER" in value:
        return True
    if re.search(r"vars\.LINUX_RUNNER\s*\|\|", value) and "contains(vars.LINUX_RUNNER, '32vcpu')" not in value:
        return True
    # The last literal is the fallback the switch must reach; earlier ones are
    # branches (fork pull requests) that pick Blacksmith on purpose.
    last = list(re.finditer(r"'(" + LABEL.pattern + r")'", value))
    if not last:
        return False
    head = value[: last[-1].start() + 1]
    if head.endswith(FAILOVER):
        return True
    # A guarded literal (`cond && 'blacksmith-...'`) keeps the guard first:
    # `cond && vars.CI_CLOUD_OVERFLOW_SAVED && 'ubuntu-24.04' || cond && '...'`.
    return re.search(r"\|\|\s*(.+?) && " + re.escape(FAILOVER[:-1]) + r"\1 && '$", head) is not None


def offenders() -> list[str]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        if EXCLUDED_NAME.search(path.name) or path.name in EXCLUDED_FILES:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            match = RUNNER_KEY.match(line)
            if not match or not LABEL.search(match.group(2)) or "runner.name" in line:
                continue
            if not covered(match.group(2)):
                found.append(f"{path.name}:{number}: {line.strip()[:160]}")
    return found


class BlacksmithLinuxFailoverTest(unittest.TestCase):
    def test_every_blacksmith_linux_label_fails_over(self) -> None:
        self.assertEqual(
            offenders(),
            [],
            "these runner labels name Blacksmith Linux without the overflow failover; write "
            "`vars.CI_CLOUD_OVERFLOW_SAVED && 'ubuntu-24.04' || 'blacksmith-...'` for the final literal",
        )

    def test_checker_flags_a_bare_label(self) -> None:
        self.assertFalse(covered("blacksmith-32vcpu-ubuntu-2404"))
        self.assertFalse(covered("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertTrue(covered("${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertTrue(covered("${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertTrue(
            covered("${{ x || a == 'pass' && vars.CI_CLOUD_OVERFLOW_SAVED && 'ubuntu-24.04' || a == 'pass' && 'blacksmith-2vcpu-ubuntu-2404' || 'macos-26' }}")
        )
        self.assertFalse(covered("${{ x || a == 'pass' && 'blacksmith-2vcpu-ubuntu-2404' || 'macos-26' }}"))
        self.assertFalse(
            covered("${{ contains(vars.LINUX_RUNNER, '32vcpu') && vars.LINUX_RUNNER || 'blacksmith-32vcpu-ubuntu-2404' }}")
        )


if __name__ == "__main__":
    unittest.main()
