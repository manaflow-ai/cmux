#!/usr/bin/env python3
"""Every pull_request workflow has a per-PR concurrency group that cancels an older run on a newer push.

On 2026-11-19 cmux had 2,500 queued runs against 118 in progress while Blacksmith's Linux labels stalled, and a run
a newer push has replaced still waits for a runner unless its workflow's group replaces it. A workflow-level
`concurrency` whose group names the pull request (its number, or the ref) and whose cancel-in-progress is true for
pull_request events keeps one run per PR per workflow. Push, dispatch and schedule runs are not touched: they
may keep their own groups and never cancel. The exceptions below say why their in-progress PR runs must finish.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
WORKFLOWS = ROOT / ".github" / "workflows"
# workflow file -> why a newer push does not cancel its in-progress run
EXEMPT = {
    "backend.yml": "deploy, smoke and rollback sequences finish; pending runs are still replaced per PR and action",
    "repair-nightly-appcast-content-types.yml": "a nightly appcast repair is never cancelled",
}
PER_PR = ("github.event.pull_request.number", "github.ref", "github.head_ref")


def pr_workflows() -> list[tuple[str, dict]]:
    found = []
    for path in sorted(WORKFLOWS.glob("*.y*ml")):
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
        if not isinstance(doc, dict):
            continue
        on = doc.get("on", doc.get(True))  # YAML 1.1 reads a bare `on:` key as True
        events = set(on) if isinstance(on, dict) else set(on if isinstance(on, list) else [on])
        if "pull_request" in events:
            found.append((path.name, doc))
    return found


def problem(doc: dict) -> str | None:
    conc = doc.get("concurrency")
    if not isinstance(conc, dict):
        return "no workflow-level concurrency mapping"
    group = str(conc.get("group", ""))
    if not any(term in group for term in PER_PR):
        return f"group {group!r} does not name the pull request"
    cancel = conc.get("cancel-in-progress")
    if cancel is not True and "pull_request" not in str(cancel):
        return f"cancel-in-progress {cancel!r} is not true for pull_request events"
    return None


class PullRequestWorkflowConcurrency(unittest.TestCase):
    def test_every_pull_request_workflow_cancels_a_superseded_run(self):
        found = pr_workflows()
        self.assertGreater(len(found), 40, "too few pull_request workflows found; did the scan break?")
        for name, doc in found:
            if name in EXEMPT:
                continue
            with self.subTest(workflow=name):
                self.assertIsNone(problem(doc))

    def test_exemptions_still_exist_and_still_need_it(self):
        names = {name: doc for name, doc in pr_workflows()}
        for name in EXEMPT:
            with self.subTest(workflow=name):
                self.assertIn(name, names, "an exempt workflow is gone or no longer runs on pull_request: drop it")
                self.assertIsNotNone(problem(names[name]), "an exempt workflow now passes: drop its exemption")

    def test_the_rule_catches_a_missing_or_non_cancelling_group(self):
        self.assertIsNotNone(problem({}))
        self.assertIsNotNone(problem({"concurrency": {"group": "x-${{ github.run_id }}", "cancel-in-progress": True}}))
        self.assertIsNotNone(problem({"concurrency": {"group": "x-${{ github.ref }}", "cancel-in-progress": False}}))
        self.assertIsNone(problem({"concurrency": {
            "group": "x-${{ github.event.pull_request.number || github.ref }}",
            "cancel-in-progress": "${{ github.event_name == 'pull_request' }}"}}))


if __name__ == "__main__":
    unittest.main()
