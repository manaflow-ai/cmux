#!/usr/bin/env python3
"""Own-branch Linux jobs reach Blacksmith only through the overflow switch; pool pickers only shrink.

CI v2 overflow design (cmuxterm-hq#13993, docs/design/ci-v2.md "Overflow and failure"): Blacksmith is reached
only through CI_OVERFLOW_LINUX and CI_OVERFLOW_MAC. On, the variable holds the overflow label; off, it is
unset, so `vars.CI_OVERFLOW_LINUX || 'cmux-linux'` asks for our pool. A watchdog in cmuxterm-hq sets and
deletes them and logs each flip. A runs-on that picks a Linux pool itself (RUNNER_POOLS.linux*, LINUX_RUNNER,
CI_CLOUD_OVERFLOW_SAVED, CI_TRUSTED_RUNNER) can resolve to Blacksmith while the switch is off: on
2026-11-21 cmux run 44935348793 job 136940670455 ran on blacksmith-4vcpu that way. This counts those
lines; when you move a job behind the switch, lower BASELINE. Jobs that hold only test credentials run on our
pool too (Leo, 2026-11-21: "stop worrying about secrets for awhile"): no GCP identity on a pool VM, every job's
workspace wiped. Jobs that hold a write token, publish or sign (EPHEMERAL) wait for the third separation, no
registration token or JIT config left in a pool VM's metadata. A dispatch input that
picks a runner offers no Blacksmith label, so a dispatch cannot bypass the switch. The cloud overflow probe probes
Blacksmith on purpose and is not counted; the Testbox setup reads the Blacksmith pool because a Testbox is a
Blacksmith product, and is not counted either.
"""

import re
import unittest
from pathlib import Path

WORKFLOWS = Path(__file__).resolve().parents[1] / ".github" / "workflows"
PROBE = "ci-cloud-overflow-probe.yml"
TESTBOX = "cmux-tui-testbox-warmup.yml"
RUNS_ON = re.compile(r"^\s*(?:-\s*)?runs-on:\s*(?P<expr>.+?)\s*$")
PICKER = re.compile(r"RUNNER_POOLS\)\.linux|vars\.LINUX_RUNNER\b|CI_CLOUD_OVERFLOW_SAVED|CI_TRUSTED_RUNNER")
JOB = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
ALLOW_LIST = re.compile(r"contains\(fromJSON\('(\[[^']*\])'\),\s*inputs\.")
SWITCH_AS_LABEL = re.compile(r"vars\.CI_OVERFLOW_LINUX\s*\|\|\s*'cmux-linux'")

# Jobs that hold a write token, publish or sign stay on their base route until separation 2 holds: the pool
# VM still carries its registration token (cmux-pool-reg) and JIT config (cmux-oneshot-jit) in metadata after
# its runners register. They move in a second change once that is cleared.
EPHEMERAL: set[tuple[str, str]] = {
    ("app-ffi-release.yml", "placement"),
    ("ci-compile-attribution.yml", "analyze"),
    ("cloud-journey-prod.yml", "journey"),
    ("cloud-vm-image-roll.yml", "promote"),
    ("cmux-next-dev-daily.yml", "pick-sign-runner"),
    ("cmux-next-media.yml", "hand-off"),
    ("cmux-next.yml", "push-head-preflight"),
    ("cmux-vm.yml", "deploy-preview"),
    ("cmux-vm.yml", "tail-production"),
    ("gateway-e2e.yml", "runner"),
    ("nightly-next-health.yml", "judge"),
    ("nightly-next-health.yml", "start"),
    ("nightly-next-rollback-drill.yml", "order"),
    ("nightly-next-rollback-drill.yml", "publish"),
    ("nightly-next-rollback-drill.yml", "receipt"),
    ("nightly-next-rollback-drill.yml", "start"),
    ("nightly-next-rollback.yml", "rollback"),
    ("nightly-next-verdict.yml", "write"),
}

# Single-line runs-on expressions that pick a Linux pool themselves (594 before this change).
BASELINE = 107


def runs_on_expressions():
    found = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        if path.name in (PROBE, TESTBOX):
            continue
        job = None
        for number, line in enumerate(path.read_text().splitlines(), 1):
            head = JOB.match(line)
            if head:
                job = head.group(1)
            match = RUNS_ON.match(line)
            if match:
                expr = match.group("expr")
                if "}}" in expr:
                    expr = expr[: expr.rindex("}}") + 2]
                found.append((path.name, number, expr, job))
    return found


class OverflowSwitchRoutes(unittest.TestCase):
    def test_linux_pool_pickers_only_shrink(self):
        pickers = [
            f"{n}:{i}" for n, i, e, j in runs_on_expressions() if PICKER.search(e) and (n, j) not in EPHEMERAL
        ]
        self.assertLessEqual(
            len(pickers),
            BASELINE,
            f"{len(pickers)} runs-on pick a Linux pool themselves (baseline {BASELINE}); end the route with "
            "|| vars.CI_OVERFLOW_LINUX || 'cmux-linux' }} instead: " + ", ".join(pickers[-10:]),
        )

    def test_ephemeral_jobs_exist(self):
        jobs = {(n, j) for n, _, _, j in runs_on_expressions()}
        self.assertEqual(sorted(EPHEMERAL - jobs), [], "EPHEMERAL names a job that no longer has a runs-on")

    def test_dispatch_allow_lists_offer_no_blacksmith(self):
        bad = [
            f"{n}:{i}"
            for n, i, e, _ in runs_on_expressions()
            for allowed in ALLOW_LIST.findall(e)
            if re.search(r"blacksmith-[^\"]*ubuntu", allowed)
        ]
        self.assertEqual(bad, [], "a dispatch input reaches Blacksmith around the switch; list only our labels")

    def test_switch_falls_back_to_our_pool(self):
        bad = [
            f"{n}:{i}"
            for n, i, e, _ in runs_on_expressions()
            if "vars.CI_OVERFLOW_LINUX" in e and not SWITCH_AS_LABEL.search(e)
        ]
        self.assertEqual(bad, [], "CI_OVERFLOW_LINUX is the label itself, read as vars.CI_OVERFLOW_LINUX || 'cmux-linux'")

    def test_pr_router_route_reads_the_switch(self):
        text = (WORKFLOWS / "pr-router.yml").read_text()
        self.assertNotIn("RUNNER_POOLS", text)
        self.assertIn("vars.CI_OVERFLOW_LINUX || 'cmux-linux'", text)


if __name__ == "__main__":
    unittest.main()
