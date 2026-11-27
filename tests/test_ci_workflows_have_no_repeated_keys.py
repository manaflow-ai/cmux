#!/usr/bin/env python3
"""Every workflow parses with no key given twice in one mapping.

GitHub and plain PyYAML keep the last of two repeated keys, so a second `environment:` or `env:` under one job
silently replaces the first. The workflow guards that load workflows with tests/workflow_jobs.py refuse such a file
whole ("unreadable YAML"), and the single-host fallback scan in the push gate then refuses every push, whatever it
changes. #58713 left both ci-web.yml (webviews-test-history) and cmux-tui-spec.yml with the job's
next-cache-writer environment block written twice.
"""
from __future__ import annotations

import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "tests"))

import workflow_jobs  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"


class WorkflowsHaveNoRepeatedKeys(unittest.TestCase):
    def test_every_workflow_loads_without_a_repeated_key(self) -> None:
        repeated = []
        for path in sorted([*WORKFLOWS.glob("*.yml"), *WORKFLOWS.glob("*.yaml")]):
            try:
                workflow_jobs.document(path)
            except ValueError as error:
                repeated.append(f"{path.relative_to(ROOT)}: {error}")
        self.assertEqual(repeated, [], "drop the second copy of each repeated key")

    def test_the_loader_refuses_a_repeated_job_key(self) -> None:
        source = "jobs:\n  a:\n    environment: one\n    environment: two\n    runs-on: x\n"
        with self.assertRaisesRegex(ValueError, "repeated key 'environment'"):
            workflow_jobs.document(source)


if __name__ == "__main__":
    unittest.main()
