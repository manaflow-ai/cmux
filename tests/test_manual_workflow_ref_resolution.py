#!/usr/bin/env python3
"""Contract tests for shared manual-workflow ref resolution."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
RESOLVER = ROOT / ".github" / "workflows" / "resolve-dispatch-ref.yml"
TARGETS = {
    ".github/workflows/ios-screenshots.yml": ("screenshots",),
    ".github/workflows/perf-activation.yml": ("activation-session-benchmark",),
    ".github/workflows/iroh-release-gate.yml": ("tailscale-version-skew", "simulator-e2e"),
    ".github/workflows/reload-build.yml": ("build",),
    ".github/workflows/test-depot.yml": ("tests",),
    ".github/workflows/test-e2e.yml": ("e2e",),
}


def job_block(workflow: str, name: str) -> str:
    marker = f"  {name}:\n"
    start = workflow.index(marker)
    match = re.search(r"(?m)^  [A-Za-z0-9_-]+:\n", workflow[start + len(marker) :])
    if match is None:
        return workflow[start:]
    return workflow[start : start + len(marker) + match.start()]


class ManualWorkflowRefResolutionTests(unittest.TestCase):
    def test_shared_resolver_normalizes_refs_to_full_commit_sha(self) -> None:
        resolver = RESOLVER.read_text(encoding="utf-8")

        self.assertIn("workflow_call:", resolver)
        self.assertIn("contents: read", resolver)
        self.assertIn("blacksmith-4vcpu-ubuntu-2404", resolver)
        self.assertIn("REQUESTED_REF: ${{ inputs.ref }}", resolver)
        self.assertIn("DEFAULT_SHA: ${{ github.sha }}", resolver)
        self.assertIn('urllib.parse.quote(requested_ref, safe="")', resolver)
        self.assertIn(
            'f"https://api.github.com/repos/{repository}/commits/{encoded_ref}"',
            resolver,
        )
        self.assertIn(r'^[0-9a-f]{40}$', resolver)
        self.assertIn("value: ${{ jobs.resolve.outputs.sha }}", resolver)

    def test_manual_macos_workflows_resolve_before_checkout(self) -> None:
        resolved_ref = "ref: ${{ needs.resolve-ref.outputs.sha }}"
        resolver_call = "uses: ./.github/workflows/resolve-dispatch-ref.yml"

        for relative_path, jobs in TARGETS.items():
            with self.subTest(workflow=relative_path):
                workflow = (ROOT / relative_path).read_text(encoding="utf-8")
                self.assertIn(resolver_call, workflow)
                self.assertIn("ref: ${{ inputs.ref }}", job_block(workflow, "resolve-ref"))
                self.assertIn("short SHA", workflow)
                for job in jobs:
                    block = job_block(workflow, job)
                    self.assertIn("resolve-ref", block)
                    self.assertIn(resolved_ref, block)
                self.assertNotIn("ref: ${{ inputs.ref || github.ref }}", workflow)

    def test_cloud_machine_workflow_is_intentionally_outside_this_batch(self) -> None:
        # Editing cloud-machine-tests.yml self-triggers its macOS PR job. Keep
        # this migration off that paid lane until its own routing is fixed.
        workflow = (ROOT / ".github/workflows/cloud-machine-tests.yml").read_text(
            encoding="utf-8"
        )
        self.assertIn("ref: ${{ inputs.ref || github.ref }}", workflow)


if __name__ == "__main__":
    unittest.main()
