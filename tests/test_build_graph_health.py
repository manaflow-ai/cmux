#!/usr/bin/env python3
from __future__ import annotations

from collections import Counter
import importlib.util
from pathlib import Path
import unittest
from unittest import mock


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

    def test_requested_ref_drives_tree_inventory(self):
        with mock.patch.object(
            health,
            "git",
            return_value="Sources/App.swift\0Packages/macOS/CmuxGit/Foo.swift\0",
        ) as git:
            files = health.tracked_swift_files("abc123")

        self.assertEqual(
            files,
            ["Sources/App.swift", "Packages/macOS/CmuxGit/Foo.swift"],
        )
        git.assert_called_once_with(
            "ls-tree",
            "-r",
            "-z",
            "--name-only",
            "abc123",
            "--",
            "*.swift",
        )

    def test_recent_window_is_anchored_to_selected_commit_time(self):
        commit = "a" * 40
        with mock.patch.object(
            health,
            "git",
            return_value="commit:abc123\0\nSources/App.swift\0",
        ) as git:
            commits, touches = health.recent_touch_counts(
                30,
                commit,
                30 * 24 * 60 * 60,
            )

        self.assertEqual(commits, 1)
        self.assertEqual(touches["Sources/App.swift"], 1)
        args = git.call_args.args
        self.assertIn("--since=1970-01-01T00:00:00+00:00", args)
        self.assertIn(commit, args)
        self.assertLess(args.index("--no-renames"), args.index(commit))
        self.assertLess(args.index(commit), args.index("--"))

    def test_history_commit_count_uses_the_same_commit_anchored_window(self):
        """Count every first-parent commit, including non-Swift repository work."""
        commit = "c" * 40
        with mock.patch.object(health, "git", return_value="12\n") as git:
            count = health.history_commit_count(
                30,
                commit,
                30 * 24 * 60 * 60,
            )

        self.assertEqual(count, 12)
        git.assert_called_once_with(
            "rev-list",
            "--first-parent",
            "--count",
            "--since=1970-01-01T00:00:00+00:00",
            commit,
        )

    def test_ref_resolution_returns_commit_and_timestamp(self):
        commit = "b" * 40
        with mock.patch.object(
            health,
            "git",
            side_effect=[commit + "\n", "1790000000\n"],
        ) as git:
            resolved = health.resolve_ref("origin/main")

        self.assertEqual(resolved, (commit, 1790000000))
        self.assertEqual(
            git.call_args_list,
            [
                mock.call(
                    "rev-parse",
                    "--verify",
                    "--end-of-options",
                    "origin/main^{commit}",
                ),
                mock.call("show", "-s", "--format=%ct", commit),
            ],
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
        data = health.summarize(
            files,
            touches,
            source_commits=7,
            history_commits=11,
            days=30,
            top=10,
        )

        self.assertEqual(data["first_parent_commits"], 11)
        self.assertEqual(data["first_parent_source_commits"], 7)
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
        data = health.summarize(
            ["Sources/Foo.swift"],
            Counter(),
            source_commits=0,
            history_commits=3,
            days=30,
            top=5,
        )
        self.assertEqual(data["recent_swift_file_touches"]["total"], 0)
        self.assertEqual(data["recent_swift_file_touches"]["app_share"], 0.0)


if __name__ == "__main__":
    unittest.main()
