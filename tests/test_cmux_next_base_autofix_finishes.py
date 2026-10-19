#!/usr/bin/env python3
"""cmux-next base autofix lands its repairs while feat-cmux-next keeps moving.

2026-10-19: the settings exports went stale on feat-cmux-next (defaults-snapshot red on every PR) because
each push cancelled the running Mac export job and the autofix job, and autofix refused to push once the
base had moved. With merges minutes apart, 8 runs in a row were cancelled and the repair never landed.
"""
from __future__ import annotations

from pathlib import Path
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
DOC = yaml.safe_load((ROOT / ".github/workflows/cmux-next-base-autofix.yml").read_text())


class BaseAutofixFinishes(unittest.TestCase):
    def test_a_running_regeneration_or_repair_finishes(self):
        # A newer push still replaces a pending run, so at most one waits.
        for job in ("action-exports", "autofix"):
            with self.subTest(job=job):
                self.assertFalse(DOC["jobs"][job]["concurrency"]["cancel-in-progress"])

    def test_the_repair_is_reapplied_on_a_moved_base(self):
        push = next(step for step in DOC["jobs"]["autofix"]["steps"] if step.get("name") == "Push the repairs")
        script = push["run"]
        self.assertIn("git cherry-pick", script)
        self.assertIn("for attempt in", script)
        self.assertNotIn("exit 1\n          fi\n          # A plain push", script)


if __name__ == "__main__":
    unittest.main()
