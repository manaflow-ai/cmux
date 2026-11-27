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

import json
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
ACTION = ROOT / ".github" / "actions" / "fleet-client" / "action.yml"
LINUX = "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || 'cmux-linux' }}"

GATEWAY_MAC = frozenset({
    "chief-evals.yml#fleet-ab",
})

PORTABLE_GATEWAYS = {
    "cmux-next-head-compile.yml#compile": "scripts/ci/head_compile.py",
    "cmux-next-ios-energy-nightly.yml#bench": "CMUX_CI_CLIENT",
    "cmux-next-ios-keyboard-motion.yml#bench": "CMUX_CI_CLIENT",
    "cmux-next-iphone-clips.yml#record": "CMUX_CI_CLIENT",
    "cmux-next-perf-bench.yml#bench": "CMUX_CI_CLIENT",
    "cmux-next-perf-budgets.yml#measure": "scripts/cmux-next/perf-cron.py",
    "cmux-next-stress-bench.yml#measure": "CMUX_CI_CLIENT",
    "cmux-next-tab-switch.yml#frames": "CMUX_CI_CLIENT",
    "fleet-compile-check.yml#compile-check": "CMUX_CI_CLIENT",
    "fleet-test-compile.yml#mac-fallback": "CMUX_CI_CLIENT",
    "ios-base-bisect.yml#bisect": "scripts/ci/ios_base_bisect.py",
    "ios-sim-linux-build.yml#build-fleet": "CMUX_CI_CLIENT",
    "screen-stream-eval.yml#eval": "CMUX_CI_CLIENT",
}

MOVED = {
    "cmux-next-tip-test-compile.yml#compile-fleet": "scripts/ci/tip-test-compile.sh",
    "cmux-next-fast-tier-batch.yml#swift-fleet": "CMUX_CI_CLIENT",
    **PORTABLE_GATEWAYS,
}

HISTORICAL = {
    "cmux-next-head-compile.yml#compile": "${{ inputs.head || github.sha }}",
    "ios-base-bisect.yml#bisect": "${{ needs.plan.outputs.red }}",
}
NEEDS_GH = {*HISTORICAL, "ios-sim-linux-build.yml#build-fleet"}


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
                prefix = ".fleet-tooling/" if key in HISTORICAL else ""
                checkout = next(s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")
                                and s.get("with", {}).get("path", "") == prefix.rstrip("/"))
                self.assertIn(".github/actions/fleet-client", checkout["with"]["sparse-checkout"])
                uses = [s.get("uses") for s in steps]
                action = f"./{prefix}.github/actions/fleet-client"
                self.assertIn(action, uses)
                client = uses.index(action)
                self.assertLess(steps.index(checkout), client)
                self.assertEqual(steps[client]["with"]["controller"], "${{ vars.CMUX_FLEET_CONTROLLER }}")
                later = yaml.safe_dump(steps[client + 1:])
                self.assertIn(marker, later, "the fleet step runs after the client is in place")

    def test_replays_bootstrap_from_the_workflow_commit_after_the_target_checkout(self) -> None:
        found = dict(jobs())
        for key, target in HISTORICAL.items():
            with self.subTest(key):
                checkouts = [s["with"] for s in found[key]["steps"]
                             if str(s.get("uses", "")).startswith("actions/checkout")]
                self.assertEqual(checkouts[0]["ref"], target)
                self.assertEqual(checkouts[1]["ref"], "${{ github.workflow_sha }}")
                self.assertEqual(checkouts[1]["path"], ".fleet-tooling")
                self.assertIs(checkouts[1]["persist-credentials"], False)

    def test_checkouts_have_read_permission_and_portable_jobs_leave_the_mac_map(self) -> None:
        routes = json.loads((ROOT / ".github" / "runners.json").read_text())["macos_jobs"]
        found = dict(jobs())
        for key in PORTABLE_GATEWAYS:
            with self.subTest(key):
                document = yaml.safe_load((WORKFLOWS / key.split("#")[0]).read_text())
                permissions = found[key].get("permissions", document.get("permissions", {}))
                self.assertIn(permissions.get("contents"), {"read", "write"})
                self.assertNotIn(key, routes)

    def test_gh_is_installed_before_its_first_use(self) -> None:
        found = dict(jobs())
        for key in NEEDS_GH:
            with self.subTest(key):
                steps = found[key]["steps"]
                prefix = ".fleet-tooling/" if key in HISTORICAL else ""
                command = f"bash {prefix}scripts/ci/nightly-steps/ensure-gh.sh"
                setup = next(i for i, s in enumerate(steps) if s.get("run") == command)
                self.assertEqual(steps[setup]["env"]["GH_PIN_TOKEN"], "${{ github.token }}")
                sparse = next(s["with"]["sparse-checkout"] for s in steps[:setup]
                              if str(s.get("uses", "")).startswith("actions/checkout")
                              and s.get("with", {}).get("path", "") == prefix.rstrip("/"))
                self.assertIn("scripts/ci/nightly-steps/ensure-gh.sh", sparse)
                self.assertIn("scripts/ci/github-release-download.sh", sparse)
                for step in steps[:setup]:
                    self.assertNotIn("gh api", step.get("run", ""))
                self.assertIn(MOVED[key], yaml.safe_dump(steps[setup + 1:]))

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
