#!/usr/bin/env python3
"""Blacksmith is reached through the overflow switch, and the count of direct routes only shrinks.

CI v2 overflow design (cmuxterm-hq#13993, docs/design/ci-v2.md "Overflow and failure"):
Blacksmith is reached only through two repository variables, CI_OVERFLOW_LINUX and
CI_OVERFLOW_MAC. The value 'on' means overflow is on; anything else, unset included,
means off. A watchdog in cmuxterm-hq flips them. A runs-on that names a Blacksmith label
without reading either variable bypasses the switch, so this ratchet counts those and
lets the count fall, never rise. When you move a job behind the switch, lower BASELINE.

Jobs that hold signing keys, App keys or other secrets keep an ephemeral label
(tests/test_ci_fork_runner_routing.py) and are the bulk of what is counted.
The cloud overflow probe probes Blacksmith on purpose and is not counted.
"""

import re
import unittest
from pathlib import Path

WORKFLOWS = Path(__file__).resolve().parents[1] / ".github" / "workflows"
PROBE = "ci-cloud-overflow-probe.yml"
RUNS_ON = re.compile(r"^\s*(?:-\s*)?runs-on:\s*(?P<expr>.+?)\s*$")
SWITCH = re.compile(r"vars\.CI_OVERFLOW_(?:LINUX|MAC)\b")
SWITCH_ON = re.compile(r"vars\.CI_OVERFLOW_(?:LINUX|MAC)\s*==\s*'on'")

# Runs-on expressions naming a Blacksmith label without the switch, after this change.
BASELINE = 231
# Runs-on expressions whose route is our Linux pool ('cmux-linux') with no overflow clause: a job there waits for
# our pool even while the watchdog has turned Linux overflow on. Shapes the codemod left (a parenthesized input
# fallback) are counted here; the count only shrinks.
OURS_WITHOUT_OVERFLOW_BASELINE = 3


def runs_on_expressions():
    """(workflow, line number, expression) for each single-line runs-on, trailing comment dropped."""
    found = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        if path.name == PROBE:
            continue
        for number, line in enumerate(path.read_text().splitlines(), 1):
            match = RUNS_ON.match(line)
            if not match:
                continue
            expr = match.group("expr")
            if "}}" in expr:
                expr = expr[: expr.rindex("}}") + 2]
            found.append((path.name, number, expr))
    return found


class OverflowSwitchRoutes(unittest.TestCase):
    def test_direct_blacksmith_routes_only_shrink(self):
        direct = [
            f"{name}:{number}"
            for name, number, expr in runs_on_expressions()
            if "blacksmith-" in expr and not SWITCH.search(expr)
        ]
        self.assertLessEqual(
            len(direct),
            BASELINE,
            f"{len(direct)} runs-on expressions name Blacksmith without CI_OVERFLOW_LINUX/CI_OVERFLOW_MAC "
            f"(baseline {BASELINE}); read the switch instead: vars.CI_OVERFLOW_LINUX == 'on' && 'blacksmith-...' || '<ours>'",
        )

    def test_our_linux_pool_has_the_overflow_clause(self):
        missing = [
            f"{name}:{number}"
            for name, number, expr in runs_on_expressions()
            if "'cmux-linux'" in expr and "vars.CI_OVERFLOW_LINUX" not in expr
        ]
        self.assertLessEqual(
            len(missing),
            OURS_WITHOUT_OVERFLOW_BASELINE,
            f"{len(missing)} runs-on route to cmux-linux with no overflow clause (baseline "
            f"{OURS_WITHOUT_OVERFLOW_BASELINE}): end it with "
            "|| vars.CI_OVERFLOW_LINUX == 'on' && 'blacksmith-4vcpu-ubuntu-2404' || 'cmux-linux' }}: " + ", ".join(missing),
        )

    def test_switch_compares_with_on(self):
        for name, number, expr in runs_on_expressions():
            for match in SWITCH.finditer(expr):
                self.assertTrue(
                    SWITCH_ON.match(expr, match.start()),
                    f"{name}:{number} reads {match.group(0)} without == 'on'; only 'on' turns overflow on",
                )


if __name__ == "__main__":
    unittest.main()
