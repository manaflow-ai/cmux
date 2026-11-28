"""A ready-to-land (or full-ci) re-add on the same head queues behind the in-flight pr-router run, never cancels it.

Leo, 2026-11-21: "de facto, im asking for 99% fewer minutes of ci time, period."

A bot takes ready-to-land off and puts it back on the same head every few minutes. In the shared
`pr-router-{PR}` group each re-add cancelled the in-flight run and its 20-55 min nightly pr build compile
(#47278 head 9b27d460; 15.6 runner-h/day of same-head cancels on the 24 h to 2026-11-27T10Z). The handoff labels
now get a group per head with cancel-in-progress off; CI_PR_ROUTER_HANDOFF_QUEUE=0 restores the old behaviour.
"""
from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROUTER = Path(__file__).resolve().parents[1] / ".github/workflows/pr-router.yml"
VAR = "format('{0}', vars.CI_PR_ROUTER_HANDOFF_QUEUE) != '0'"


class HandoffQueue(unittest.TestCase):
    def setUp(self) -> None:
        self.conc = yaml.safe_load(ROUTER.read_text())["concurrency"]

    def test_ready_to_land_gets_a_group_per_head_behind_the_var(self) -> None:
        group = self.conc["group"]
        self.assertTrue(group.startswith("pr-router-${{ github.event.pull_request.number }}"), group)
        self.assertIn(
            "github.event.label.name == 'ready-to-land' && " + VAR
            + " && format('-land-{0}', github.event.pull_request.head.sha)", group)
        # full-ci keeps its own per-head group (#54957).
        self.assertIn("format('-full-{0}', github.event.pull_request.head.sha)", group)

    def test_handoff_labels_queue_and_everything_else_cancels(self) -> None:
        cancel = self.conc["cancel-in-progress"]
        self.assertIsInstance(cancel, str, "cancel-in-progress must be an expression, not a constant")
        self.assertEqual(
            cancel,
            "${{ !(github.event.action == 'labeled' && contains(fromJSON('[\"full-ci\",\"ready-to-land\"]'), "
            "github.event.label.name) && " + VAR + ") }}")


if __name__ == "__main__":
    unittest.main()
