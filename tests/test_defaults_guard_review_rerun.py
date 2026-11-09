"""main no longer carries the cmux-next defaults guard workflows (#30608 removed feat-cmux-next's copies)."""

from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github/workflows"
REMOVED = ("cmux-next-defaults-guard.yml", "cmux-next-defaults-guard-review.yml")


class DefaultsGuardRemoved(unittest.TestCase):
    def test_defaults_guard_workflows_are_absent(self):
        for name in REMOVED:
            with self.subTest(name=name):
                self.assertFalse((WORKFLOWS / name).exists(), name)

    def test_no_workflow_runs_the_defaults_guard(self):
        for workflow in sorted(WORKFLOWS.glob("*.y*ml")):
            with self.subTest(workflow=workflow.name):
                text = workflow.read_text()
                self.assertNotIn("defaults_guard.py", text)
                self.assertNotIn("defaults guard", text.lower())


if __name__ == "__main__":
    unittest.main()
