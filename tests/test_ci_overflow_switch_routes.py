#!/usr/bin/env python3
"""Own-branch Linux jobs reach Blacksmith only through the overflow switch; pool pickers only shrink.

CI v2 overflow design (cmuxterm-hq#13993, docs/design/ci-v2.md "Overflow and failure"): Blacksmith is reached
only through CI_OVERFLOW_LINUX and CI_OVERFLOW_MAC. On, the variable holds the overflow label; off, it is
unset, so `vars.CI_OVERFLOW_LINUX || 'cmux-linux'` asks for our pool. A watchdog in cmuxterm-hq sets and
deletes them and logs each flip. A runs-on that picks a Linux pool itself (RUNNER_POOLS.linux*, LINUX_RUNNER,
CI_CLOUD_OVERFLOW_SAVED, CI_TRUSTED_RUNNER) can resolve to Blacksmith while the switch is off: on
2026-11-21 cmux run 44935348793 job 136940670455 ran on blacksmith-4vcpu that way. This counts those
lines; when you move a job behind the switch, lower BASELINE. Jobs that hold write tokens or secrets keep an
ephemeral label (tests/test_ci_fork_runner_routing.py) and are most of what is counted. The cloud overflow
probe probes Blacksmith on purpose and is not counted.
"""

import re
import unittest
from pathlib import Path

WORKFLOWS = Path(__file__).resolve().parents[1] / ".github" / "workflows"
PROBE = "ci-cloud-overflow-probe.yml"
RUNS_ON = re.compile(r"^\s*(?:-\s*)?runs-on:\s*(?P<expr>.+?)\s*$")
PICKER = re.compile(r"RUNNER_POOLS\)\.linux|vars\.LINUX_RUNNER\b|CI_CLOUD_OVERFLOW_SAVED|CI_TRUSTED_RUNNER")
JOB = re.compile(r"^  ([A-Za-z0-9_-]+):\s*$")
SWITCH_AS_LABEL = re.compile(r"vars\.CI_OVERFLOW_LINUX\s*\|\|\s*'cmux-linux'")

# Jobs that hold a write token, an environment or secrets and so must run on a one-job VM destroyed after the
# job (tests/test_ci_fork_runner_routing.py). cmux-linux runners are not shown to be one-job, so these keep
# their base route and are not counted. Move one out only once its label is a one-job VM.
EPHEMERAL = {
    ("app-ffi-release.yml", "placement"),
    ("ci-compile-attribution.yml", "analyze"),
    ("ci-fast-guards.yml", "fast-guards"),
    ("cloud-chat-proof.yml", "signin"),
    ("cloud-chief-machine.yml", "check"),
    ("cloud-journey-prod.yml", "journey"),
    ("cloud-newlink-e2e.yml", "create-and-link"),
    ("cloud-surge-proof.yml", "proof"),
    ("cloud-vm-image-roll.yml", "plan"),
    ("cloud-vm-image-roll.yml", "promote"),
    ("cmux-mobile-link-stats.yml", "stats"),
    ("cmux-next-dev-daily.yml", "pick-sign-runner"),
    ("cmux-next-guards.yml", "pinned-asset-store"),
    ("cmux-next-media.yml", "hand-off"),
    ("cmux-next-web-perf.yml", "validate"),
    ("cmux-next.yml", "push-head-preflight"),
    ("cmux-tui-team-signed.yml", "plan"),
    ("cmux-tui-team-signed.yml", "publish-helper"),
    ("cmux-vm.yml", "deploy-preview"),
    ("cmux-vm.yml", "tail-production"),
    ("executor-journey.yml", "journey"),
    ("gateway-e2e.yml", "e2e"),
    ("gateway-e2e.yml", "runner"),
    ("mobile-worker-prod-deploy.yml", "deploy-prod"),
    ("nightly-next-health.yml", "blind"),
    ("nightly-next-health.yml", "judge"),
    ("nightly-next-health.yml", "start"),
    ("nightly-next-rollback-drill.yml", "order"),
    ("nightly-next-rollback-drill.yml", "publish"),
    ("nightly-next-rollback-drill.yml", "receipt"),
    ("nightly-next-rollback-drill.yml", "start"),
    ("nightly-next-rollback.yml", "rollback"),
    ("nightly-next-verdict.yml", "write"),
    ("vm-hassle.yml", "hassle"),
    ("web-complexity.yml", "complexity"),
}

# Single-line runs-on expressions that pick a Linux pool themselves (594 before this change).
BASELINE = 107


def runs_on_expressions():
    found = []
    for path in sorted(WORKFLOWS.glob("*.yml")):
        if path.name == PROBE:
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
