#!/usr/bin/env python3
"""A job that publishes one of main's required checks has a literal name.

GitHub posts a skipped job's `name:` unevaluated. A required gate named by a `${{ }}`
expression and skipped by its `if:` (backend-migrations' clean-plan skip) reports as the raw
expression, never as the required context, so the base refuses every such PR
(cmux#54576 at 64df778, "required check 'backend migrations applied' has not reported").
"""

from __future__ import annotations

import sys
import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
from required_status_checks import REQUIRED_CHECKS  # noqa: E402

WORKFLOWS = ROOT / ".github" / "workflows"


def offenders(document: dict) -> list[str]:
    """Jobs with an `if:` whose expression name can evaluate to a required check."""
    found = []
    for job_id, job in (document.get("jobs") or {}).items():
        if not isinstance(job, dict) or "if" not in job:
            continue
        name = str(job.get("name", job_id))
        if "${{" in name and any(f"'{check}'" in name for check in REQUIRED_CHECKS):
            found.append(job_id)
    return found


class RequiredCheckNamesLiteral(unittest.TestCase):
    def test_every_workflow_names_its_required_gate_literally(self) -> None:
        bad = []
        for path in sorted(WORKFLOWS.glob("*.y*ml")):
            document = yaml.safe_load(path.read_text(encoding="utf-8"))
            if isinstance(document, dict):
                bad += [f"{path.name}:{job}" for job in offenders(document)]
        self.assertEqual(bad, [], "a skippable job names a required check by expression")

    def test_an_expression_named_skippable_gate_is_caught(self) -> None:
        document = {"jobs": {"gate": {
            "if": "always()",
            "name": "${{ github.event.action == 'edited' && 'x' || 'backend migrations applied' }}",
        }}}
        self.assertEqual(offenders(document), ["gate"])

    def test_a_literal_name_passes(self) -> None:
        document = {"jobs": {"gate": {"if": "always()", "name": "backend migrations applied"}}}
        self.assertEqual(offenders(document), [])


if __name__ == "__main__":
    unittest.main()
