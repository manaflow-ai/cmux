import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).parents[1] / "check-pr-split.py"
SPEC = importlib.util.spec_from_file_location("check_pr_split", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC and SPEC.loader
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


class CheckPrSplitTests(unittest.TestCase):
    def test_classifies_known_surfaces_and_reports_unknown_paths(self):
        classified, unknown = MODULE.classify_paths(
            [
                "webviews/src/agent-session/acpmux/Composer.tsx",
                "webviews/src/agent-session/acpmux/summary/SummaryCard.tsx",
                ".github/workflows/cmux-next-split-guard.yml",
                "docs/example.md",
            ]
        )
        self.assertEqual(classified[0].surfaces, ("composer",))
        self.assertEqual(classified[1].surfaces, ("summary-card",))
        self.assertEqual(classified[2].surfaces, ("ci",))
        self.assertEqual(unknown, ("docs/example.md",))

    def test_triggers_mixed_ui_ci_and_native_webview_changes(self):
        metrics = MODULE.build_metrics(
            merge_base="base",
            head="head",
            commit_count=3,
            paths=[
                "Packages/macOS/CmuxNext/Sources/CmuxNextSettings/SidebarSectionsSetting.swift",
                "webviews/src/agent-session/acpmux/SessionSidebar.tsx",
                ".github/workflows/cmux-next-split-guard.yml",
            ],
        )
        self.assertEqual(
            MODULE.findings(metrics),
            ["production-ui-and-workflow-ci", "native-settings-and-webview-ui"],
        )

    def test_size_thresholds_are_strictly_greater_than_limits(self):
        paths = [f"webviews/src/agent-session/acpmux/Composer{i}.tsx" for i in range(40)]
        metrics = MODULE.build_metrics(merge_base="base", head="head", commit_count=25, paths=paths)
        self.assertEqual(MODULE.findings(metrics), [])
        metrics = MODULE.build_metrics(merge_base="base", head="head", commit_count=26, paths=paths)
        self.assertIn("commits>25 (26)", MODULE.findings(metrics))

    def test_advisory_mode_reports_but_does_not_block(self):
        with tempfile.TemporaryDirectory() as directory:
            repo = Path(directory)
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            (repo / "webviews").mkdir()
            (repo / "webviews/Composer.tsx").write_text("export {}\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "base"],
                check=True,
            )
            (repo / "docs.md").write_text("unknown\n", encoding="utf-8")
            subprocess.run(["git", "-C", str(repo), "add", "."], check=True)
            subprocess.run(
                ["git", "-C", str(repo), "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "commit", "-qm", "change"],
                check=True,
            )
            result = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--repo",
                    str(repo),
                    "--base",
                    "HEAD^",
                    "--head",
                    "HEAD",
                    "--mode",
                    "advisory",
                ],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0)
            self.assertIn("unclassified-paths", result.stdout)
            payload = json.loads(next(line.split(" ", 1)[1] for line in result.stdout.splitlines() if line.startswith("SPLIT_GUARD_JSON ")))
            self.assertEqual(payload["unknown_paths"], ["docs.md"])


if __name__ == "__main__":
    unittest.main()
