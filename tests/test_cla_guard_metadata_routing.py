#!/usr/bin/env python3
"""Pin the CLA metadata route before interpreting its dynamic required name."""
import contextlib
import io
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import yaml

ROOT = Path(__file__).resolve().parents[1]
REQUIRED_CHECK = "CLA policy guard"
METADATA_IF = "${{ !(github.event_name == 'pull_request_target' && github.event.action == 'edited' && !github.event.changes.base && (github.event.changes.body || github.event.changes.title)) }}"
METADATA_NAME = "${{ github.event_name == 'pull_request_target' && github.event.action == 'edited' && !github.event.changes.base && (github.event.changes.body || github.event.changes.title) && 'CLA policy guard metadata (ignored)' || 'CLA policy guard' }}"


def validate_metadata_routing(workflow):
    trigger = workflow.get("on", workflow.get(True))
    assert trigger == {"pull_request_target": {
        "branches": ["main"],
        "types": ["opened", "edited", "reopened", "synchronize", "ready_for_review"],
    }}, "CLA guard trigger contract changed"
    assert "concurrency" not in workflow, "metadata events must not cancel required verdicts"
    job = workflow["jobs"]["validate"]
    assert "concurrency" not in job, "metadata events must not cancel required verdicts"
    assert job["if"] == METADATA_IF, "CLA guard metadata predicate changed"
    assert job["name"] == METADATA_NAME, "CLA guard metadata name changed"


def candidate():
    workflow = yaml.safe_load((ROOT / ".github/workflows/cla-policy-guard.yml").read_text())
    workflow["jobs"]["validate"]["if"] = METADATA_IF
    workflow["jobs"]["validate"]["name"] = METADATA_NAME
    return workflow


class CLAMetadataRoutingTests(unittest.TestCase):
    def test_actual_workflow_contract(self):
        workflow = yaml.safe_load(
            (ROOT / ".github/workflows/cla-policy-guard.yml").read_text())
        job = workflow["jobs"]["validate"]
        # GitHub can make the newest skipped suite authoritative for required
        # checks even when an older suite passed. Always publish this context.
        self.assertEqual(job["name"], REQUIRED_CHECK)
        self.assertNotIn("if", job)
        trigger = workflow.get("on", workflow.get(True))
        self.assertIn("edited", trigger["pull_request_target"]["types"])
        self.assertNotIn("concurrency", workflow)
        self.assertNotIn("concurrency", job)

    def test_rejects_incomplete_or_weakened_contract(self):
        for field, value in (("name", REQUIRED_CHECK), ("name", "${{ github.actor }}"),
                             ("if", "${{ false }}"),
                             ("if", METADATA_IF.replace("!github.event.changes.base", "true"))):
            with self.subTest(field=field, value=value):
                workflow = candidate()
                workflow["jobs"]["validate"][field] = value
                with self.assertRaises(AssertionError):
                    validate_metadata_routing(workflow)
        for level in ("workflow", "job"):
            workflow = candidate()
            target = workflow if level == "workflow" else workflow["jobs"]["validate"]
            target["concurrency"] = {"group": "pr", "cancel-in-progress": True}
            with self.assertRaises(AssertionError):
                validate_metadata_routing(workflow)

    def test_bounded_guard_follows_dynamic_owner_and_fails_closed(self):
        import test_ci_required_checks_are_bounded as bounded
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            workflows = root / ".github/workflows"
            workflows.mkdir(parents=True)
            path = workflows / "cla-policy-guard.yml"
            import test_ci_merge_queue_required_checks as queue
            (workflows / "merge-group-policy-checks.yml").write_text(yaml.safe_dump(queue.expected_bridge()))
            def run(document):
                path.write_text(yaml.safe_dump(document))
                with patch.object(bounded, "ROOT", root), patch.object(bounded, "WORKFLOWS", workflows), \
                     patch.object(bounded, "REQUIRED_CONTEXTS", (REQUIRED_CHECK,)), \
                     contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
                    return bounded.main()
            workflow = candidate()
            self.assertEqual(run(workflow), 0)
            del workflow["jobs"]["validate"]["timeout-minutes"]
            self.assertEqual(run(workflow), 1)
            workflow = candidate()
            workflow["jobs"]["validate"]["if"] = "${{ false }}"
            self.assertEqual(run(workflow), 1)
            workflow["jobs"]["validate"]["name"] = REQUIRED_CHECK
            self.assertEqual(run(workflow), 1)
            del workflow["jobs"]["validate"]["if"]
            self.assertEqual(run(workflow), 0)

    def test_merge_queue_retains_static_policy_bridge(self):
        import test_ci_merge_queue_required_checks as queue
        with tempfile.TemporaryDirectory() as directory:
            workflows = Path(directory)
            (workflows / "cla-policy-guard.yml").write_text(yaml.safe_dump(candidate()))
            (workflows / "merge-group-policy-checks.yml").write_text(yaml.safe_dump(queue.expected_bridge()))
            with patch.object(queue, "WORKFLOWS", workflows):
                names = queue.merge_group_check_names()
            self.assertEqual(names[REQUIRED_CHECK], ["merge-group-policy-checks.yml"])
            self.assertNotIn(METADATA_NAME, names)


if __name__ == "__main__":
    unittest.main()
