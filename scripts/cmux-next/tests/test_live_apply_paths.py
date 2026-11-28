#!/usr/bin/env python3
"""live_apply.py --paths-from (nightly.yml's nightly-next hot-apply skip) and nightly_signer_gaps.py.

    python3 -m unittest scripts/cmux-next/tests/test_live_apply_paths.py
"""
import json
import subprocess
import sys
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent.parent
sys.path.insert(0, str(HERE.parent))
sys.path.insert(0, str(ROOT / "scripts" / "ci"))
import live_apply  # noqa: E402
import nightly_signer_gaps  # noqa: E402

VIEW = "Packages/macOS/CmuxNext/Sources/CmuxNextApp/Home/HomeHostView.swift"


class HotApplyOnlyTests(unittest.TestCase):
    def check(self, files):
        return live_apply.classify_paths(files)

    def test_web_and_docs_are_hot_apply_only(self):
        result = self.check([("M", "webviews/src/a.tsx"), ("M", "docs/x.md"), ("M", ".github/workflows/a.yml")])
        self.assertTrue(result["hot_apply_only"])
        self.assertEqual(result["verdict"], "web-live")

    def test_swift_without_a_diff_needs_a_build(self):
        result = self.check([("M", "webviews/a.ts"), ("M", VIEW)])
        self.assertFalse(result["hot_apply_only"])
        self.assertEqual(result["verdict"], "rebuild")

    def test_rust_strings_and_ios_are_not_hot_apply(self):
        for path in ("cmux-tui/src/main.rs", "Resources/Localizable.xcstrings", "ios/App/X.swift"):
            self.assertFalse(self.check([("M", "webviews/a.ts"), ("M", path)])["hot_apply_only"], path)

    def test_resource_needs_a_build(self):
        self.assertFalse(self.check([("M", "Packages/macOS/CmuxNext/Resources/Info.plist")])["hot_apply_only"])

    def test_empty_list_is_not_proof(self):
        self.assertFalse(self.check([])["hot_apply_only"])

    def test_cli_reads_name_status_on_stdin(self):
        out = subprocess.run([sys.executable, str(HERE.parent / "live_apply.py"), "--paths-from", "-"],
                             input="M\twebviews/a.ts\nD\tdocs/old.md\n", capture_output=True, text=True, check=True)
        self.assertTrue(json.loads(out.stdout)["hot_apply_only"])


class SignerGapTests(unittest.TestCase):
    def run_(self, start, end, branch="nightly-next", status="completed"):
        return {"run_started_at": start, "updated_at": end, "head_branch": branch, "status": status}

    def test_gaps_between_signing_builds(self):
        runs = [
            self.run_("2026-11-28T00:00:00Z", "2026-11-28T00:45:00Z"),
            self.run_("2026-11-28T00:50:00Z", "2026-11-28T00:52:00Z"),  # a skip: not a signing build
            self.run_("2026-11-28T00:30:00Z", "2026-11-28T01:00:00Z", "main"),  # overlaps: merged
            self.run_("2026-11-28T02:00:00Z", "2026-11-28T02:40:00Z"),
            self.run_("2026-11-28T02:45:00Z", "2026-11-28T03:30:00Z"),  # 5 min gap: under the floor
            self.run_("2026-11-28T04:00:00Z", "2026-11-28T05:00:00Z", status="in_progress"),
        ]
        result = nightly_signer_gaps.gaps(runs)
        self.assertEqual(result["builds"], 3)
        self.assertEqual([g["minutes"] for g in result["gaps"]], [60.0])
        self.assertEqual(result["gaps"][0]["after"], "nightly-next")
        self.assertEqual(result["idle_minutes"], 60.0)

    def test_no_builds(self):
        self.assertEqual(nightly_signer_gaps.gaps([])["gaps"], [])


if __name__ == "__main__":
    unittest.main()
