#!/usr/bin/env python3
from __future__ import annotations

from collections import Counter
import importlib.util
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "scripts/ci/build_graph_health.py"

spec = importlib.util.spec_from_file_location("build_graph_health", SCRIPT)
health = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(health)


class BuildGraphHealthTests(unittest.TestCase):
    def test_classifies_app_cli_and_packages(self):
        self.assertEqual(health.classify_path("Sources/Mobile/Foo.swift"), ("app", "Mobile"))
        self.assertEqual(health.classify_path("Sources/AppDelegate.swift"), ("app", "<root>"))
        self.assertEqual(health.classify_path("CLI/CMUXCLI.swift"), ("cli", "CLI"))
        self.assertEqual(
            health.classify_path("Packages/macOS/CmuxGit/Sources/CmuxGit/Foo.swift"),
            ("package", "macOS/CmuxGit"),
        )
        self.assertEqual(
            health.classify_path("Packages/Shared/CmuxCore/Sources/CmuxCore/Bar.swift"),
            ("package", "Shared/CmuxCore"),
        )

    def test_summary_weights_recent_edits_separately_from_file_count(self):
        files = [
            "Sources/Mobile/A.swift",
            "Sources/Mobile/B.swift",
            "Sources/AppDelegate.swift",
            "Packages/macOS/CmuxGit/Sources/CmuxGit/Git.swift",
            "CLI/CMUXCLI.swift",
        ]
        touches = Counter({
            "Sources/Mobile/A.swift": 5,
            "Sources/AppDelegate.swift": 3,
            "Packages/macOS/CmuxGit/Sources/CmuxGit/Git.swift": 2,
            "CLI/CMUXCLI.swift": 1,
        })
        data = health.summarize(files, touches, commits=7, days=30, top=10)

        self.assertEqual(data["first_parent_commits"], 7)
        self.assertEqual(data["current_swift_files"]["by_owner"]["app"], 3)
        self.assertEqual(data["recent_swift_file_touches"]["total"], 11)
        self.assertEqual(data["recent_swift_file_touches"]["app"], 8)
        self.assertAlmostEqual(data["recent_swift_file_touches"]["app_share"], 8 / 11)
        self.assertEqual(
            data["recent_swift_file_touches"]["top_groups"][0],
            {"name": "app:Mobile", "touches": 5},
        )

    def test_nul_framed_history_preserves_special_pathnames(self):
        commits, touches = health.parse_touch_log(
            "commit:abc123\0\nSources/Mobile/Quote \"Thing\".swift\0"
            "Sources/Mobile/Normal.swift\0commit:def456\0"
            "\nSources/Mobile/Normal.swift\0"
        )
        self.assertEqual(commits, 2)
        self.assertEqual(touches['Sources/Mobile/Quote "Thing".swift'], 1)
        self.assertEqual(touches["Sources/Mobile/Normal.swift"], 2)

    def test_zero_touch_window_is_well_defined(self):
        data = health.summarize(["Sources/Foo.swift"], Counter(), commits=0, days=30, top=5)
        self.assertEqual(data["recent_swift_file_touches"]["total"], 0)
        self.assertEqual(data["recent_swift_file_touches"]["app_share"], 0.0)


if __name__ == "__main__":
    unittest.main()
