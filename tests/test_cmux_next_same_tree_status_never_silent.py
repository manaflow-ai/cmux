#!/usr/bin/env python3
"""A pull request's required `cmux-next daemon tests (same-tree)` status always posts or turns something red.

SAME_TREE_STATUS_NEVER_SILENT (2026-11-14, hq#11114). Besides the publish-side notify (#43429, NOTIFY_NEVER_LOST),
two more steps let the status go missing with nothing red:
- cmux#43335 and #43370: the same-tree daemon tests passed, the status POST got HTTP 403 (the workflow token's
  budget), the step warned and passed;
- cmux#43400 and #43027: path routing could not compare the active artifacts runs with the merge tree (fetch
  budget or GitHub API), deferred, and no publish ever ended that wait.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
CMUX_NEXT = ROOT / ".github" / "workflows" / "cmux-next.yml"
PIN = ROOT / "scripts" / "cmux-next" / "pin-cmux-tui.sh"


class SameTreeStatusNeverSilent(unittest.TestCase):
    def test_a_same_tree_status_that_cannot_be_posted_is_red(self):
        jobs = yaml.safe_load(CMUX_NEXT.read_text())["jobs"]
        posts = [step for job in jobs.values() for step in job.get("steps") or []
                 if step.get("name") == "Report the same-tree result on the tested commit"]
        self.assertGreaterEqual(len(posts), 2)
        for step in posts:
            self.assertNotIn("continue-on-error", step)
            self.assertNotIn("::warning::could not post", step["run"])
            self.assertIn("for wait in", step["run"])
            self.assertIn("exit 1", step["run"])

    def test_a_pull_request_never_defers_to_a_publisher_it_could_not_find(self):
        probe = PIN.read_text().split("probe_checkout_tree() {", 1)[1].split("\n}\n", 1)[0]
        # The head's push publishes a merge that keeps the head's tree: read from git, before any API search.
        head_branch = probe.index("rev-parse --verify -q HEAD^2")
        self.assertLess(probe.index("pull_request_base_key"), head_branch)
        self.assertLess(head_branch, probe.index('await_outside_publisher "$key"'))
        self.assertIn('source="commit:$head_sha"', probe)
        # A pull request's merge tree with no publisher it could find is red, never deferred.
        unknown = probe.index('-n "$publisher_unknown" && "${GITHUB_EVENT_NAME:-}" == pull_request')
        self.assertIn("state=failed", probe[unknown:].split("elif", 1)[0])
        self.assertLess(unknown, probe.index('elif [[ -z "$source" && -n "$publisher_unknown" ]]; then'))


if __name__ == "__main__":
    unittest.main()
