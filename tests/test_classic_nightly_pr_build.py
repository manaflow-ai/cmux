#!/usr/bin/env python3
"""The classic NIGHTLY's Release compile runs on the pull request path.

classic-pr-build.yml must compile what nightly.yml compiles, for each
architecture it ships, route Swift the way ci.yml's release_build area does,
and stay advisory.
"""

from __future__ import annotations

import re
import subprocess
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts/ci"))

import classic_nightly_pr_build as build  # noqa: E402

WORKFLOW = (ROOT / ".github/workflows/classic-pr-build.yml").read_text()
SCRIPT = (ROOT / "scripts/ci/classic-nightly-release-compile.sh").read_text()
NIGHTLY = (ROOT / ".github/workflows/nightly.yml").read_text()


def nightly_build_settings() -> set[str]:
    step = NIGHTLY.split("- name: Build nightly app (Release)", 1)[1].split("\n      - name:", 1)[0]
    return set(re.findall(r"\b([A-Z_]+)=", step.split("xcodebuild", 1)[1]))


class ClassicNightlyPrBuildTest(unittest.TestCase):
    def test_script_passes_every_nightly_build_setting(self) -> None:
        compile_part = SCRIPT.split("xcodebuild", 1)[1]
        for setting in nightly_build_settings():
            self.assertIn(f"{setting}=", compile_part, setting)
        self.assertIn("-scheme cmux -configuration Release", SCRIPT)
        self.assertIn("CMUX_SKIP_ZIG_BUILD=1", SCRIPT)
        self.assertIn("run-xcodebuild-with-diagnostics.sh", SCRIPT)
        self.assertIn("download-prebuilt-ghosttykit.sh", SCRIPT)

    def test_script_syntax(self) -> None:
        subprocess.run(["bash", "-n", str(ROOT / "scripts/ci/classic-nightly-release-compile.sh")], check=True)

    def test_workflow_compiles_shipped_nightly_archs_as_fleet_jobs(self) -> None:
        # The matrix follows the archs NIGHTLY ships, read from nightly.yml,
        # so a change there fails here instead of drifting silently.
        step = NIGHTLY.split("- name: Build nightly app (Release)", 1)[1]
        shipped = re.search(r'^\s*archs="([^"]+)"', step, re.M).group(1).split()
        matrix = re.search(r"^\s*arch: \[([^\]]+)\]", WORKFLOW, re.M).group(1)
        self.assertEqual([a.strip() for a in matrix.split(",")], shipped)
        self.assertEqual(list(build.ARCHS), shipped)
        self.assertIn("--script scripts/ci/classic-nightly-release-compile.sh", WORKFLOW)
        self.assertIn("--arg=--archs --arg=\"$ARCH\"", WORKFLOW)

    def test_every_job_is_advisory(self) -> None:
        names = re.findall(r"^    name: (.+)$", WORKFLOW, re.M)
        self.assertEqual(len(names), 3)
        for name in names:
            self.assertTrue(name.endswith("(advisory)"), name)

    def test_gateway_jobs_are_fleet_clients(self) -> None:
        # The gateway runner's hook refuses any job whose id does not end in
        # -fleet (run 45709828984: "refused: the gateway runner takes only thin
        # cmux-ci client jobs" for the job id `swift`).
        jobs = re.findall(r"^  ([A-Za-z0-9_-]+):\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", WORKFLOW.split("\njobs:\n", 1)[1], re.M | re.S)
        gateway = [job for job, body in jobs if "CI_EVAL_STEP_GATEWAY" in body]
        self.assertTrue(gateway)
        for job in gateway:
            self.assertTrue(job.endswith("-fleet"), job)

    def test_gateway_job_keeps_the_runner_fallback_reachable(self) -> None:
        match = re.search(r"(?ms)^  app-compile-fleet:\n(.*?)(?=^  [A-Za-z0-9_-]+:\n|\Z)", WORKFLOW)
        self.assertIsNotNone(match)
        self.assertIn("if: ${{ needs.route.outputs.swift == 'true' }}", match.group(1))
        self.assertIn("vars.CI_EVAL_STEP_GATEWAY || vars.CI_OVERFLOW_LINUX || 'cmux-linux'", match.group(1))

    def test_helper_check_matches_nightly_build(self) -> None:
        self.assertIn("cargo build -p cmux-tui --bin cmux-tui --release --locked", NIGHTLY)
        self.assertIn("cargo check -p cmux-tui --bin cmux-tui --release --locked", WORKFLOW)

    def test_route(self) -> None:
        self.assertEqual(build.route(["Sources/AppDelegate.swift"]), {"swift": True, "helpers": False})
        self.assertEqual(build.route(["cmux-tui/src/main.rs"])["helpers"], True)
        self.assertEqual(build.route(["docs/ci/merge-main.md"]), {"swift": False, "helpers": False})
        self.assertTrue(build.route([build.WORKFLOW])["swift"])

    def test_workflow_paths_cover_route_inputs(self) -> None:
        paths = set(re.findall(r'^      - "([^"]+)"$', WORKFLOW, re.M))
        for root in build.HELPER_INPUTS:
            self.assertTrue(root in paths or f"{root}/**" in paths, root)
        for path in ("Sources/**", "Packages/**", "cmux.xcodeproj/**", "cmux-tui/**", "ghostty"):
            self.assertIn(f'- "{path}"', WORKFLOW)

    def test_keys_ignore_docs_and_cover_shipped_archs(self) -> None:
        keys = build.keys("HEAD")
        self.assertEqual(set(keys), {*build.ARCHS, "helpers"})
        self.assertTrue(keys["helpers"].startswith("classic-nightly-pr-build-v1-helpers-"))
        self.assertIn("docs", build.SWIFT_KEY_IGNORED)


if __name__ == "__main__":
    unittest.main()
