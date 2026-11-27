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

import re
import tempfile
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
    "ios-base-bisect.yml#bisect",
    "ios-sim-linux-build.yml#build-fleet",
    "ios-sim-linux-build.yml#shots-fleet",  # #57700 took it by vars.CI_EVAL_STEP_GATEWAY; #54437 froze it to the label
    "screen-stream-eval.yml#eval",
})

MOVED = {
    "chief-evals.yml#fleet-ab": "scripts/measure/chief-evals.sh",
    "cmux-next-tip-test-compile.yml#compile-fleet": "scripts/ci/tip-test-compile.sh",
}


# The gateway runner's job-started hook names a job by its calling workflow file plus its job id and takes any id
# ending in -fleet. A gateway job in a reusable workflow (on: workflow_call) is named by its caller's file, so its
# id must end in -fleet. cmuxterm-hq#26191: #55354 made cmux-next-fast-tier-batch.yml and
# cmux-next-tip-test-compile.yml reusable from cmux-next-post-merge.yml; the hook refused "cmux-next-post-merge.yml
# swift" and "... compile" on every batch until #56548 renamed them swift-fleet and compile-fleet.
# A repository variable can name the gateway too (vars.*GATEWAY).
GATEWAY_VAR = re.compile(r"vars\.\w*GATEWAY\b")
# Known: ci-macos.yml (called from ci.yml) takes vars.CI_SWIFT_PACKAGE_TESTS_STEP_GATEWAY on pull requests when
# that opt-in variable is set (hq#794); its id has about 70 references, so its rename is its own change.
REUSABLE_GATEWAY_KNOWN = frozenset({"ci-macos.yml#swift-package-tests"})


def reusable(document: dict) -> bool:
    triggers = document.get(True, document.get("on")) or {}  # PyYAML reads a bare `on` as True
    return isinstance(triggers, dict) and "workflow_call" in triggers


def reusable_gateway_jobs_the_hook_refuses(root: Path = WORKFLOWS) -> list[str]:
    refused = []
    for path in sorted(root.glob("*.y*ml")):
        document = yaml.safe_load(path.read_text(encoding="utf-8")) or {}
        if not reusable(document):
            continue
        for name, job in (document.get("jobs") or {}).items():
            runs_on = yaml.safe_dump((job or {}).get("runs-on", ""))
            if ("glaeda-gateway" in runs_on or GATEWAY_VAR.search(runs_on)) and not name.endswith("-fleet"):
                refused.append(f"{path.name}#{name}")
    return refused


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

    def test_a_gateway_job_in_a_reusable_workflow_ends_in_fleet(self) -> None:
        refused = set(reusable_gateway_jobs_the_hook_refuses())
        self.assertEqual(sorted(refused - REUSABLE_GATEWAY_KNOWN), [],
                         "the gateway hook names these by their caller's file and refuses them: end the job id in -fleet")
        self.assertEqual(sorted(REUSABLE_GATEWAY_KNOWN - refused), [], "renamed: drop it from REUSABLE_GATEWAY_KNOWN")

    def test_the_reusable_check_sees_the_jobs_hq_26191_broke(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            call = "on:\n  workflow_call:\njobs:\n"
            (root / "fast-tier.yml").write_text(call + "  swift:\n    runs-on: ${{ vars.CI_COMPILE_CHECK_GATEWAY }}\n")
            (root / "tip.yml").write_text(call + "  compile:\n    runs-on: glaeda-gateway-xcode-26.6\n")
            (root / "ok.yml").write_text(call + "  swift-fleet:\n    runs-on: glaeda-gateway-xcode-26.6\n")
            (root / "direct.yml").write_text("on:\n  workflow_dispatch:\njobs:\n  bench:\n    runs-on: glaeda-gateway-xcode-26.6\n")
            self.assertEqual(reusable_gateway_jobs_the_hook_refuses(root), ["fast-tier.yml#swift", "tip.yml#compile"])

    def test_moved_jobs_run_on_linux_with_the_checked_client(self) -> None:
        found = dict(jobs())
        for key, marker in MOVED.items():
            with self.subTest(key):
                job = found[key]
                self.assertEqual(job["runs-on"], LINUX)
                steps = job["steps"]
                checkouts = [s for s in steps if str(s.get("uses", "")).startswith("actions/checkout")]
                uses = [str(s.get("uses", "")) for s in steps]
                client = next(i for i, u in enumerate(uses) if u.endswith("/.github/actions/fleet-client"))
                prefix = uses[client].removesuffix("/.github/actions/fleet-client").removeprefix(".").strip("/")
                # The checkout that supplies the action: path matches the step's prefix ("" is the workspace).
                source = next(s for s in checkouts if str(s["with"].get("path", "")).strip("/") == prefix)
                self.assertIn(".github/actions/fleet-client", source["with"]["sparse-checkout"])
                if any("inputs.sha" in str(s["with"].get("ref", "")) for s in checkouts):
                    # A bisect probe tests a commit that may predate the action: load it from the workflow's own
                    # commit, or every probe of an older commit fails before any suite runs.
                    self.assertEqual(source["with"]["ref"], "${{ github.workflow_sha }}")
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
        # #60339 spells the name "CMUX_CI_"CLIENT so a guard reading the literal misses it; key on the write itself.
        self.assertLess(run.index('if [[ "$ok" != 1'), run.index('>> "$GITHUB_ENV"'))
        self.assertNotIn("exit 0", run)
        # No controller, fetch failed, and (#60339) the installed client is not executable or fails --help.
        self.assertEqual(run.count("exit 1"), 4)
        self.assertNotIn("::warning", run)
        self.assertIn('"CMUX_CI_"CONTROLLER "$CONTROLLER" >> "$GITHUB_ENV"', run)


if __name__ == "__main__":
    unittest.main()
