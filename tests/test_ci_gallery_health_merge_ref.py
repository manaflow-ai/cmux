#!/usr/bin/env python3
"""gallery-health.yml renders a pull request merged with its base, as the other PR gates do.

It checked out pull_request.head.sha, so a branch cut before a base fix kept failing on what base
had already fixed (transcript-density: "Module not found health.ts" after #23333). The merge ref
(GitHub's refs/pull/N/merge, the default checkout of a pull_request event) is what lands.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml


ROOT = Path(__file__).resolve().parents[1]
WORKFLOW = ROOT / ".github" / "workflows" / "gallery-health.yml"


def steps() -> list[dict]:
    workflow = yaml.safe_load(WORKFLOW.read_text(encoding="utf-8"))
    return workflow["jobs"]["health"]["steps"]


def step(name: str) -> dict:
    found = [entry for entry in steps() if entry.get("name") == name]
    if not found:
        raise AssertionError(f"gallery-health.yml has no step named {name!r}")
    return found[0]


class GalleryHealthMergeRef(unittest.TestCase):
    def test_a_pull_request_renders_its_merge_with_base(self) -> None:
        checkout = step("Checkout")
        ref = str((checkout.get("with") or {}).get("ref", ""))
        self.assertNotIn("pull_request.head.sha", ref, "check out the merge ref, not the pull request head")

    def test_the_merge_ref_is_confirmed_on_the_pull_request_head(self) -> None:
        resolve = step("Resolve the head and the merge")
        self.assertIn("github.event.pull_request.head.sha", str(resolve.get("env")))
        self.assertIn("HEAD^2", resolve["run"])

    def test_the_touched_entries_are_the_pull_requests_own_change(self) -> None:
        # The merge's first parent is the base it was merged with: diffing against it is the pull
        # request's change, never base commits the branch has not merged yet.
        run = step("Choose the entries to render")["run"]
        self.assertIn('git diff --name-only HEAD^1 HEAD', run)
        self.assertNotIn("git merge-base", run)

    def test_reports_keep_the_pull_request_head(self) -> None:
        # The artifact names the head the pull request shows, beside the merge commit rendered.
        record = step("Record what was rendered")
        self.assertIn("steps.resolve.outputs.head_sha", str(record.get("env")))
        self.assertIn("health/source.json", record["run"])
        names = [entry.get("name") for entry in steps()]
        self.assertLess(names.index("Record what was rendered"), names.index("Upload the health run"))


if __name__ == "__main__":
    unittest.main()
