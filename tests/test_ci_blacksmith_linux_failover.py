#!/usr/bin/env python3
"""Every Blacksmith Linux runs-on fails over while the overflow switch is on.

When Blacksmith Linux starts no jobs, the overflow switch
(scripts/ci/cloud_overflow_switch.py) writes the CI_CLOUD_OVERFLOW_SAVED record
and points vars.LINUX_RUNNER and vars.CI_TRUSTED_RUNNER at another Blacksmith
Linux size (never GitHub-hosted Ubuntu; Leo, 2026-10-27: "just put it on
blacksmith / 16vcpu blacksmiths do exist").
A runs-on that names a Blacksmith Linux label literally and reads neither
variable never sees that, so its job queued with zero capacity for the whole
outage (2026-10-27). Each such label must sit behind
`vars.CI_CLOUD_OVERFLOW_SAVED && '<FAILOVER_SIZE[label]>' ||` (another
Blacksmith Linux size: 2 goes to 4 or 8, 4 and 8 swap, 16 goes to 8, and the older
pairing of 4 and 8 to 16 and 16 and 32 swapping still counts), or the expression
must read one of the switched variables first. Blacksmith's concurrency is a cap
on vCPUs, so a failover to a smaller size is the one likelier to start
(.github/runners.json linux_sizes; tests/test_ci_blacksmith_linux_sizes.py keeps
32 vCPU out of every route that has no measured reason for it). An unset variable is falsy, so
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
# Each x64 Blacksmith Linux size and the sizes it may fail over to, the first preferred.
FAILOVER_SIZES = {2: (4, 8), 4: (8, 16), 8: (4, 16), 16: (8, 32), 32: (16,)}
FAILOVER_PREFIX = "vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-"


def failovers_for(label: str) -> list[str]:
    """Each text that may come right before `'<label>'`."""
    size = int(re.match(r"blacksmith-(\d+)vcpu", label).group(1))
    return [f"vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-{other}vcpu-ubuntu-2404' || '"
            for other in FAILOVER_SIZES[size]]


def failover_for(label: str) -> str:
    """The preferred text that comes right before `'<label>'`."""
    return failovers_for(label)[0]
# What may come right before a Blacksmith Linux literal without the failover:
# a variable the switch already points at another Blacksmith size, or a fork pull-request
# branch, which picks Blacksmith on purpose and is not the fallback.
# (`!startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER ||` is
# not one: it ignores the switch's Blacksmith failover value.)
SWITCHED = re.compile(r"(?<!&& )vars\.LINUX_RUNNER \|\| '$")
FORK_BRANCH = re.compile(
    r"(?:head\.repo\.full_name != github\.repository"
    r"|!contains\(fromJSON\([\w.]+\), github\.event\.pull_request\.head\.repo\.full_name\)) && '$"
)


def literal_covered(head: str, label: str) -> bool:
    """head is the text up to and including the quote that opens the literal."""
    if SWITCHED.search(head) or FORK_BRANCH.search(head):
        return True
    for failover in failovers_for(label):
        if head.endswith(failover):
            return True
        # A guarded literal (`cond && 'blacksmith-...'`) keeps the guard first:
        # `cond && vars.CI_CLOUD_OVERFLOW_SAVED && '<failover>' || cond && '...'`.
        if re.search(r"(?:\|\||\()\s*(.+?) && " + re.escape(failover[:-1]) + r"\1 && '$", head) is not None:
            return True
    return False


def covered(value: str) -> bool:
    """True when every Blacksmith Linux literal in a runner value fails over."""
    # A bounded workflow_dispatch input is a broker-selected reroute set, not a primary
    # Blacksmith reservation. The workflow defaults to fleet and accepts these labels only
    # when the broker explicitly supplies one after a stalled attempt.
    if "contains(fromJSON(" in value and "inputs.runner) && inputs.runner" in value \
            and "cmux-fleet-linux-x64" in value:
        return True
    if "vars.CI_TRUSTED_RUNNER" in value:
        # The switch points CI_TRUSTED_RUNNER at another Blacksmith size; the labels in its
        # allowlist are double-quoted JSON, not runner literals.
        return True
    if "${{" not in value:
        return LABEL.search(value) is None
    # A failover target is itself a Blacksmith literal; it is the fallback, not a primary,
    # but at least one primary must remain (a lone failover resolves empty when unset).
    primaries = [
        match for match in re.finditer(r"'(" + LABEL.pattern + r")'", value)
        if not value[: match.start() + 1].endswith(FAILOVER_PREFIX[:-len("blacksmith-")])
    ]
    return bool(primaries) and all(
        literal_covered(value[: match.start() + 1], match.group(1)) for match in primaries
    )


def offenders() -> list[str]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        if EXCLUDED_NAME.search(path.name) or path.name in EXCLUDED_FILES:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            code = line.split(" #", 1)[0] if not line.lstrip().startswith("#") else ""
            if not LABEL.search(code) or "runner.name" in code:
                continue
            if not covered(code):
                found.append(f"{path.name}:{number}: {line.strip()[:160]}")
    return found


class BlacksmithLinuxFailoverTest(unittest.TestCase):
    def test_every_blacksmith_linux_label_fails_over(self) -> None:
        self.assertEqual(
            offenders(),
            [],
            "these runner labels name Blacksmith Linux without the overflow failover; write "
            "`vars.CI_CLOUD_OVERFLOW_SAVED && '<another Blacksmith size>' || 'blacksmith-...'` for the final literal",
        )

    def test_no_failover_names_github_hosted_ubuntu(self) -> None:
        hosted = [
            f"{path.name}:{number}"
            for path in sorted(WORKFLOWS.glob("*.yml"))
            for number, line in enumerate(path.read_text().splitlines(), 1)
            if re.search(r"vars\.CI_CLOUD_OVERFLOW_SAVED && '(?:ubuntu|macos)-", line)
        ]
        self.assertEqual(hosted, [], "the overflow failover takes another Blacksmith size, never a GitHub-hosted image"
        )

    def test_checker_flags_a_bare_label(self) -> None:
        self.assertFalse(covered("blacksmith-32vcpu-ubuntu-2404"))
        self.assertFalse(covered("${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertTrue(covered("${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        # The smaller pairings: 4 and 8 swap, 16 goes to 8.
        self.assertTrue(covered("${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-8vcpu-ubuntu-2404' || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertTrue(covered("${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-4vcpu-ubuntu-2404' || 'blacksmith-8vcpu-ubuntu-2404' }}"))
        self.assertTrue(covered("${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-8vcpu-ubuntu-2404' || 'blacksmith-16vcpu-ubuntu-2404' }}"))
        self.assertFalse(covered("${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-2vcpu-ubuntu-2404' || 'blacksmith-16vcpu-ubuntu-2404' }}"))
        # A hosted failover, or the wrong size (the same stalled pool), does not count.
        self.assertFalse(covered("${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'ubuntu-24.04' || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertFalse(covered("${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-4vcpu-ubuntu-2404' || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertTrue(covered("${{ vars.LINUX_RUNNER || 'blacksmith-4vcpu-ubuntu-2404' }}"))
        self.assertTrue(
            covered("${{ x || a == 'pass' && vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-4vcpu-ubuntu-2404' || a == 'pass' && 'blacksmith-2vcpu-ubuntu-2404' || 'macos-26' }}")
        )
        self.assertFalse(covered("${{ x || a == 'pass' && 'blacksmith-2vcpu-ubuntu-2404' || 'macos-26' }}"))
        self.assertFalse(
            covered("${{ contains(vars.LINUX_RUNNER, '32vcpu') && vars.LINUX_RUNNER || 'blacksmith-32vcpu-ubuntu-2404' }}")
        )
        # The switch's failover is a Blacksmith label, so a non-Blacksmith gate alone never moves the job.
        self.assertFalse(
            covered("${{ !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || 'blacksmith-32vcpu-ubuntu-2404' }}")
        )
        self.assertTrue(
            covered("${{ !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || "
                    "vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-32vcpu-ubuntu-2404' }}")
        )
        # A lone failover with no primary resolves empty while the record is unset.
        self.assertFalse(covered("${{ vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-16vcpu-ubuntu-2404' }}"))
        # A Blacksmith literal inside an earlier branch must fail over too, not only the last one.
        self.assertFalse(covered("${{ a && (vars.X || 'blacksmith-16vcpu-ubuntu-2404') || 'blacksmith-6vcpu-macos-15' }}"))
        fork = "github.event_name == 'pull_request' && github.event.pull_request.head.repo.full_name != github.repository"
        self.assertTrue(
            covered("${{ " + fork + " && 'blacksmith-4vcpu-ubuntu-2404' || " + failover_for("blacksmith-32vcpu-ubuntu-2404") + "blacksmith-32vcpu-ubuntu-2404' }}")
        )


if __name__ == "__main__":
    unittest.main()
