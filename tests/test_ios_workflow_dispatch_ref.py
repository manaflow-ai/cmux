#!/usr/bin/env python3
"""Regression coverage for manual iOS workflow revision resolution."""

from __future__ import annotations

import json
import os
import re
import subprocess
import tempfile
import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "test-ios.yml"


def job_block(name: str) -> str:
    text = WORKFLOW.read_text(encoding="utf-8")
    marker = f"  {name}:\n"
    start = text.index(marker)
    match = re.search(r"(?m)^  [A-Za-z0-9_-]+:\n", text[start + len(marker) :])
    if match is None:
        return text[start:]
    return text[start : start + len(marker) + match.start()]


class IOSWorkflowDispatchRefTests(unittest.TestCase):
    def test_requested_family_matrix_is_selected_on_linux(self) -> None:
        jobs = yaml.safe_load(WORKFLOW.read_text())["jobs"]
        detect = jobs["detect-ios-changes"]
        self.assertIn("LINUX_RUNNER", detect["runs-on"])
        selector = next(step for step in detect["steps"] if step.get("id") == "families")
        self.assertEqual(selector["env"]["DEVICE_FAMILY"], "${{ inputs.device_family }}")
        self.assertEqual(
            detect["outputs"]["device_families"], "${{ steps.families.outputs.json }}"
        )
        self.assertEqual(jobs["ios-simulator"]["needs"], "detect-ios-changes")
        self.assertEqual(
            jobs["ios-simulator"]["strategy"]["matrix"]["family"],
            "${{ fromJSON(needs.detect-ios-changes.outputs.device_families) }}",
        )
        # Matrix membership is the admission decision. In particular, an empty
        # request must not select both families and then skip both test steps.
        simulator_steps = jobs["ios-simulator"]["steps"]
        run_tests = next(step for step in simulator_steps if step.get("name") == "Run iOS simulator tests")
        self.assertNotIn("if", run_tests)
        for step in simulator_steps:
            self.assertNotIn("inputs.device_family", step.get("if", ""))
            self.assertNotEqual(step.get("name"), "Skip unrequested family")
        for requested, expected in (
            (None, ["iphone", "ipad"]),
            ("", ["iphone", "ipad"]),
            ("both", ["iphone", "ipad"]),
            ("iphone", ["iphone"]),
            ("ipad", ["ipad"]),
            ("invalid", None),
            ('["iphone"]', None),
        ):
            with self.subTest(requested=requested), tempfile.TemporaryDirectory() as directory:
                output = Path(directory) / "output"
                env = {key: value for key, value in os.environ.items() if key != "DEVICE_FAMILY"}
                env["GITHUB_OUTPUT"] = str(output)
                if requested is not None:
                    env["DEVICE_FAMILY"] = requested
                result = subprocess.run(
                    ["bash", "-e", "-c", selector["run"]],
                    env=env, capture_output=True, text=True,
                )
                if expected is None:
                    self.assertNotEqual(result.returncode, 0)
                    self.assertFalse(output.exists())
                else:
                    self.assertEqual(result.returncode, 0, result.stderr)
                    key, value = output.read_text().strip().split("=", 1)
                    self.assertEqual(key, "json")
                    self.assertEqual(json.loads(value), expected)

    def test_run_name_identifies_the_requested_workload(self) -> None:
        run_name = yaml.safe_load(WORKFLOW.read_text())["run-name"]
        for field in ("ref", "test_filter", "swift_package", "device_family", "ios_version"):
            self.assertIn(f"inputs.{field}", run_name)
        self.assertIn("github.ref_name", run_name)

    def test_manual_ref_is_resolved_once_to_a_full_commit_sha(self) -> None:
        detect = job_block("detect-ios-changes")
        workflow = WORKFLOW.read_text(encoding="utf-8")

        self.assertIn(
            "description: Branch, tag, full SHA, or short SHA to test",
            workflow,
        )
        self.assertIn("target_sha: ${{ steps.target.outputs.sha }}", detect)
        self.assertIn("ref: ${{ github.ref }}", detect)
        self.assertIn("fetch-depth: ${{ github.event_name == 'pull_request' && '0' || '1' }}", detect)
        self.assertIn("id: target", detect)
        self.assertIn("GITHUB_TOKEN: ${{ github.token }}", detect)
        self.assertIn("REQUESTED_REF: ${{ inputs.ref }}", detect)
        self.assertIn("DEFAULT_SHA: ${{ github.sha }}", detect)
        self.assertIn(
            'f"https://api.github.com/repos/{repository}/commits/{encoded_ref}"',
            detect,
        )
        self.assertIn('urllib.parse.quote(requested_ref, safe="")', detect)
        self.assertIn('echo "sha=$target_sha" >> "$GITHUB_OUTPUT"', detect)
        self.assertIn(r'^[0-9a-f]{40}$', detect)

    def test_paid_and_downstream_jobs_checkout_only_the_resolved_sha(self) -> None:
        workflow = WORKFLOW.read_text(encoding="utf-8")
        resolved_ref = "ref: ${{ needs.detect-ios-changes.outputs.target_sha }}"

        self.assertNotIn("ref: ${{ inputs.ref || github.ref", workflow)
        for job in ("package-conventions-lint", "mobile-core-package", "ios-simulator"):
            with self.subTest(job=job):
                self.assertIn(resolved_ref, job_block(job))

        # The routing job checks out the workflow revision itself; every other
        # checkout is pinned to the one resolved 40-character commit SHA.
        self.assertEqual(workflow.count(resolved_ref), 3)


if __name__ == "__main__":
    unittest.main()
