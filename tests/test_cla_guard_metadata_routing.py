#!/usr/bin/env python3
"""The CLA guard cancels stale runs without hiding an unsafe head."""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import yaml

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_CHECK = "CLA policy guard"
METADATA = "${{ github.event_name == 'pull_request_target' && github.event.action == 'edited' && !github.event.changes.base && (github.event.changes.body || github.event.changes.title) }}"
VALIDATE = "${{ !(github.event_name == 'pull_request_target' && github.event.action == 'edited' && !github.event.changes.base && (github.event.changes.body || github.event.changes.title)) }}"
GROUP = "cla-policy-${{ github.event.pull_request.number }}"


def load() -> dict:
    workflow = yaml.safe_load((ROOT / ".github/workflows/cla-policy-guard.yml").read_text())
    return workflow if isinstance(workflow, dict) else {}


def validate_metadata_routing(workflow: dict) -> None:
    trigger = workflow.get("on", workflow.get(True))
    assert trigger == {"pull_request_target": {
        "branches": ["main"],
        "types": ["opened", "edited", "reopened", "synchronize", "ready_for_review"],
    }}, "CLA guard trigger contract changed"
    assert workflow["concurrency"] == {"group": GROUP, "cancel-in-progress": True}
    jobs = workflow["jobs"]
    assert set(jobs) == {"validate", "metadata"}
    assert jobs["validate"]["name"] == REQUIRED_CHECK
    assert jobs["validate"]["if"] == VALIDATE
    assert jobs["metadata"]["name"] == REQUIRED_CHECK
    assert jobs["metadata"]["if"] == METADATA
    assert jobs["metadata"]["steps"][1]["name"] == "Confirm exact-head guard success"
    assert "check-runs?check_name=CLA%20policy%20guard" in jobs["metadata"]["steps"][1]["run"]


def candidate() -> dict:
    workflow = load()
    workflow["jobs"]["validate"]["if"] = "false"
    return workflow


class CLAMetadataRoutingTests(unittest.TestCase):
    def test_actual_workflow_contract(self):
        validate_metadata_routing(load())

    def test_rejects_incomplete_or_weakened_contract(self):
        for field, value in (("name", REQUIRED_CHECK), ("name", "${{ github.actor }}"),
                             ("if", "${{ false }}"), ("if", METADATA)):
            with self.subTest(field=field, value=value):
                workflow = candidate()
                workflow["jobs"]["validate"][field] = value
                with self.assertRaises(AssertionError):
                    validate_metadata_routing(workflow)
        workflow = candidate()
        workflow["concurrency"]["cancel-in-progress"] = False
        with self.assertRaises(AssertionError):
            validate_metadata_routing(workflow)

    def test_bounded_guard_follows_dynamic_owner_and_fails_closed(self):
        import test_ci_required_checks_are_bounded as bounded
        import test_ci_merge_queue_required_checks as queue

        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workflows = root / ".github/workflows"
            workflows.mkdir(parents=True)
            (workflows / "cla-policy-guard.yml").write_text(yaml.safe_dump(load()))
            (workflows / "merge-group-policy-checks.yml").write_text(yaml.safe_dump(queue.expected_bridge()))

            def run(document):
                (workflows / "cla-policy-guard.yml").write_text(yaml.safe_dump(document))
                with patch.object(bounded, "ROOT", root), patch.object(bounded, "WORKFLOWS", workflows), \
                     patch.object(bounded, "REQUIRED_CONTEXTS", (REQUIRED_CHECK,)), \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    return bounded.main()

            self.assertEqual(run(load()), 0)
            workflow = load()
            del workflow["jobs"]["metadata"]["timeout-minutes"]
            self.assertEqual(run(workflow), 1)


if __name__ == "__main__":
    unittest.main()
