#!/usr/bin/env python3
"""A job that only drives the build fleet runs on Linux, not on a gateway Mac.

A gateway job runs the fleet client (`cmux-ci run ... --script ...`) and waits while a fleet Mac does the work;
holding a Mac mini for that wait buys nothing (Leo, 2026-11-26: "How about freeing up the Mac's from doing things
that don't need Mac's asap?"). The moved jobs fetch the controller's client with .github/actions/fleet-client
(sha256-checked against the controller's manifest) and keep the same "no client, no verdict" path.

GATEWAY_MAC is the jobs still on a glaeda-gateway label. It only shrinks: a new job on a gateway label fails here,
and a listed job that left the label must leave the list.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
ACTION = ROOT / ".github" / "actions" / "fleet-client" / "action.yml"
LINUX = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-linux' }}"

GATEWAY_MAC = frozenset({
    "cmux-next-fast-tier-batch.yml#swift-fleet",  # private fallback only
    "cmux-next-head-compile.yml#compile",
    "cmux-next-ios-energy-nightly.yml#bench",
    "cmux-next-ios-keyboard-motion.yml#bench",
    "cmux-next-iphone-clips.yml#record",
    "cmux-next-perf-bench.yml#bench",
    "cmux-next-perf-budgets.yml#measure",
    "cmux-next-stress-bench.yml#measure",
    "cmux-next-tab-switch.yml#frames",
    "fleet-compile-check.yml#compile-check",
    "fleet-test-compile.yml#mac-fallback",
    "ios-base-bisect.yml#bisect",
    "ios-sim-linux-build.yml#build-fleet",
    "screen-stream-eval.yml#eval",
})

MOVED = {
    "chief-evals.yml#fleet-ab": "scripts/measure/chief-evals.sh",
    "cmux-next-tip-test-compile.yml#compile-fleet": "scripts/ci/tip-test-compile.sh",
}


def jobs():
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        for name, job in (document.get("jobs") or {}).items():
            if isinstance(job, dict):
                yield f"{path.name}#{name}", job


def on_gateway(job: dict) -> bool:
    return "glaeda-gateway" in yaml.safe_dump(job.get("runs-on", ""))


class GatewayJobsOnLinuxTests(unittest.TestCase):
    def test_no_new_job_holds_a_gateway_mac_and_the_list_only_shrinks(self) -> None:
        gateway = {key for key, job in jobs() if on_gateway(job)}
        self.assertEqual(sorted(gateway - GATEWAY_MAC), [],
                         "a new job on a glaeda-gateway label: a job that only runs the fleet client runs on cmux-linux "
                         "with .github/actions/fleet-client")
        self.assertEqual(sorted(GATEWAY_MAC - gateway), [], "left the gateway label: drop it from GATEWAY_MAC")

    def test_moved_jobs_run_on_linux_with_the_checked_client(self) -> None:
        found = dict(jobs())
        for key, marker in MOVED.items():
            with self.subTest(key):
                job = found[key]
                self.assertEqual(job["runs-on"], LINUX)
                steps = job["steps"]
                checkout = next(s for s in steps if str(s.get("uses", "")).startswith("actions/checkout"))
                self.assertIn(".github/actions/fleet-client", checkout["with"]["sparse-checkout"])
                uses = [s.get("uses") for s in steps]
                self.assertIn("./.github/actions/fleet-client", uses)
                client = uses.index("./.github/actions/fleet-client")
                self.assertEqual(steps[client]["with"]["controller"], "${{ vars.CMUX_FLEET_CONTROLLER }}")
                later = yaml.safe_dump(steps[client + 1:])
                self.assertIn(marker, later, "the fleet step runs after the client is in place")

    def test_batch_swift_reads_public_results_before_using_a_private_gateway(self) -> None:
        found = dict(jobs())
        read = found["cmux-next-fast-tier-batch.yml#swift-results"]
        self.assertEqual(read["runs-on"], LINUX)
        self.assertNotIn("./.github/actions/fleet-client", yaml.safe_dump(read["steps"]))
        self.assertIn("--registry scripts/cmux-next/fast-tier.json", read["steps"][-1]["run"])
        report = found["cmux-next-fast-tier-batch.yml#swift-fleet"]
        self.assertEqual(report["needs"], "swift-results")
        self.assertIn("!cancelled()", report["if"])
        self.assertIn("needs.swift-results.result != 'skipped'", report["if"])
        fallback = report["steps"][-2]["with"]["sparse-checkout"].splitlines()
        self.assertIn("Packages/**/Tests/**/*.swift", fallback)
        self.assertIn("scripts/ci/display-suites.txt", fallback)
        self.assertEqual(report["runs-on"], "${{ needs.swift-results.outputs.verdict == 'unavailable' "
                         "&& 'glaeda-gateway-xcode-26.6' || 'cmux-linux' }}")
        self.assertEqual(report["steps"][-1]["if"], "needs.swift-results.outputs.verdict == 'unavailable'")

    def test_the_action_checks_every_file_and_exports_the_client_only_when_whole(self) -> None:
        text = ACTION.read_text(encoding="utf-8")
        run = yaml.safe_load(text)["runs"]["steps"][0]["run"]
        self.assertIn("/v1/client/manifest", run)
        self.assertIn("hashlib.sha256(data).hexdigest() != digest", run)
        # The exports come last, after the fetch succeeded; every failure path exits red before them (at least as
        # strict as the gateway Mac, whose client was always installed: no silent no-verdict green).
        self.assertLess(run.index('if [[ "$ok" != 1'), run.index("CMUX_CI_CLIENT="))
        self.assertNotIn("exit 0", run)
        self.assertEqual(run.count("exit 1"), 2)
        self.assertNotIn("::warning", run)
        self.assertIn("CMUX_CI_CONTROLLER=", run)


if __name__ == "__main__":
    unittest.main()
