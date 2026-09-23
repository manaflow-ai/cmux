"""Pin: a main push that adds a migration applies it, staging first, then production.

Vercel deploys main on every push, so a migration that only exists in the
manual `workflow_dispatch` path leaves production running code against a
schema that lacks the tables it needs (2026-09-21: every Cloud create answered
503 `vm_cloud_state_unavailable` because `cloud_runtimes` had never been
created). The migration workflow must also run on the push itself.
"""

from __future__ import annotations

import pathlib
import unittest

import yaml

ROOT = pathlib.Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "cloud-vm-migrate.yml"


def load() -> dict:
    with WORKFLOW.open("r", encoding="utf-8") as handle:
        return yaml.safe_load(handle)


class CloudVmMigrateWorkflowTest(unittest.TestCase):
    def test_push_to_main_with_a_migration_triggers_the_workflow(self) -> None:
        on = load()[True] if True in load() else load()["on"]
        self.assertIn("workflow_dispatch", on, "manual dispatch stays available")
        push = on.get("push")
        self.assertIsNotNone(push, "a main push must run the migration workflow")
        self.assertEqual(push.get("branches"), ["main"])
        self.assertIn("web/db/migrations/**", push.get("paths", []))

    def test_push_applies_staging_then_production(self) -> None:
        jobs = load()["jobs"]
        staging = jobs["migrate-staging"]
        production = jobs["migrate-production"]
        self.assertIn("github.event_name == 'push'", staging["if"])
        self.assertIn("github.event_name == 'push'", production["if"])
        self.assertIn("migrate-staging", production["needs"])
        self.assertEqual(production["environment"], "cloud-vm-production")
        # A dispatched staging-only run must still stop before production.
        self.assertIn("inputs.target == 'production'", production["if"])
        self.assertNotIn("inputs.target == 'staging'", production["if"])


if __name__ == "__main__":
    unittest.main()
