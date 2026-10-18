#!/usr/bin/env python3
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "ci"))
from vercel_merge_gate import requires_vercel


class VercelMergeGateTests(unittest.TestCase):
    def test_non_web_changes_are_advisory(self):
        self.assertFalse(requires_vercel("manaflow-ai/cmuxterm-hq", ["build-fleet/mini-ops/runner.py"]))
        self.assertFalse(requires_vercel("manaflow-ai/cmux", ["docs/README.md", "CLAUDE.md"]))

    def test_web_changes_still_require_vercel(self):
        for path in ("admin/src/app.tsx", "dashboard/server.ts", "web/app/page.tsx", "vercel.json"):
            with self.subTest(path=path):
                self.assertTrue(requires_vercel("manaflow-ai/cmuxterm-hq", [path]))

    def test_unknown_history_fails_open(self):
        self.assertTrue(requires_vercel("manaflow-ai/cmuxterm-hq", []))


if __name__ == "__main__":
    unittest.main()
