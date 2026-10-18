#!/usr/bin/env python3
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "ci"))
from vercel_merge_gate import is_vercel_status, requires_vercel


class VercelMergeGateTests(unittest.TestCase):
    def test_non_web_changes_are_advisory(self):
        self.assertFalse(requires_vercel("manaflow-ai/cmuxterm-hq", ["build-fleet/mini-ops/runner.py"]))
        self.assertFalse(requires_vercel("manaflow-ai/cmux", ["docs/README.md", "CLAUDE.md"]))

    def test_web_changes_still_require_vercel(self):
        for path in (
            "admin/src/app.tsx",
            "agent-chat/src/app.tsx",
            "dashboard/server.ts",
            "services/preview/vercel.json",
            "web/app/page.tsx",
            "webviews/vite.config.mjs",
            "vercel.json",
        ):
            with self.subTest(path=path):
                self.assertTrue(requires_vercel("manaflow-ai/cmuxterm-hq", [path]))

    def test_unknown_history_fails_open(self):
        self.assertTrue(requires_vercel("manaflow-ai/cmuxterm-hq", []))

    def test_vercel_status_variants_are_recognized(self):
        for name in ("Vercel", "Vercel Preview", "vercel-preview", "Vercel/Preview", "Vercel – cmux"):
            with self.subTest(name=name):
                self.assertTrue(is_vercel_status(name))
        for name in ("Vercelish", "Vercel Agent Review", "Vercel Code Review"):
            with self.subTest(name=name):
                self.assertFalse(is_vercel_status(name))


if __name__ == "__main__":
    unittest.main()
