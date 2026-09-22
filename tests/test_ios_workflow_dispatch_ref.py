#!/usr/bin/env python3
"""Regression coverage for manual iOS workflow revision resolution."""

from __future__ import annotations

import re
import unittest
from pathlib import Path


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

        self.assertNotIn("inputs.ref || github.ref", workflow)
        for job in ("package-conventions-lint", "mobile-core-package", "ios-simulator"):
            with self.subTest(job=job):
                self.assertIn(resolved_ref, job_block(job))

        # The routing job checks out the workflow revision itself; every other
        # checkout is pinned to the one resolved 40-character commit SHA.
        self.assertEqual(workflow.count(resolved_ref), 3)


if __name__ == "__main__":
    unittest.main()
