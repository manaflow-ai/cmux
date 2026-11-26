"""Fast-checks coalescing must preserve distinct commands and tested trees."""

from pathlib import Path
import re
import unittest


WORKFLOW = Path(__file__).resolve().parents[1] / ".github/workflows/fast-checks.yml"


class FastChecksConcurrencyTest(unittest.TestCase):
    def test_dispatches_share_only_the_exact_check_key(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        match = re.search(
            r"(?ms)^concurrency:\n(?P<body>(?:^  .*\n)+?)(?=^\S|\Z)", text
        )
        self.assertIsNotNone(match, "fast-checks must coalesce duplicate dispatches")
        body = match.group("body")
        self.assertIn("inputs.tested_sha || inputs.source_sha", body)
        for field in ("inputs.command", "inputs.directory", "inputs.setup"):
            self.assertIn(field, body)
        self.assertIn("cancel-in-progress: false", body)

    def test_workflow_remains_dispatch_only(self) -> None:
        text = WORKFLOW.read_text(encoding="utf-8")
        trigger = text.split("on:", 1)[1].split("# Same read-only", 1)[0]
        self.assertIn("workflow_dispatch:", trigger)
        self.assertNotRegex(trigger, r"(?m)^\s+(push|pull_request|schedule):")


if __name__ == "__main__":
    unittest.main()
