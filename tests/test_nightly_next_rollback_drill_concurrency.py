#!/usr/bin/env python3
"""The rollback drill serializes publishes per drill feed, not per run.

A per-run concurrency group (`github.run_id`) lets a manual or retried publish start while an
earlier run's pull is still pending, so it overwrites the drill feed and receipt.json and the
publish-to-pull binding breaks (#39377). One group for the whole drill feed queues them instead.
"""

from __future__ import annotations

import unittest
from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[1]
DRILL = ROOT / ".github" / "workflows" / "nightly-next-rollback-drill.yml"


class RollbackDrillConcurrencyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.workflow = yaml.safe_load(DRILL.read_text(encoding="utf-8"))
        # PyYAML parses the bare key `on` as boolean True; read whichever form is present.
        self.assertIn("concurrency", self.workflow)

    def test_concurrency_group_is_per_drill_feed_not_per_run(self) -> None:
        group = self.workflow["concurrency"]["group"]
        self.assertNotIn("run_id", group, "a per-run group lets publishes overlap a pending pull")
        self.assertEqual(group, "nightly-next-rollback-drill")

    def test_concurrency_never_cancels_an_in_flight_drill(self) -> None:
        self.assertIs(self.workflow["concurrency"]["cancel-in-progress"], False)


if __name__ == "__main__":
    unittest.main()
