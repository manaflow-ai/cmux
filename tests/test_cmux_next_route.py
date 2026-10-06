#!/usr/bin/env python3
"""cmux-next pull requests run the tiers their change can break, and no fewer.

scripts/ci/cmux_next_route.py reads the committed SwiftPM target graph
(Packages/macOS/CmuxNext/ci-target-graph.json). These cases use the real graph,
so a manifest change that moves a dependency changes what they expect only
through the regenerated graph.
"""

from __future__ import annotations

import json
import sys
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from cmux_next_push_attribution import failed_jobs, last_green  # noqa: E402
from cmux_next_route import outputs, route  # noqa: E402

PACKAGE = "Packages/macOS/CmuxNext"
GRAPH = json.loads((ROOT / PACKAGE / "ci-target-graph.json").read_text(encoding="utf-8"))

# #17470 (a new workspace opens on the New Tab page): its own files.
PR_17470 = [
    f"{PACKAGE}/Sources/CmuxNextApp/AgentTabs+Wiring.swift",
    f"{PACKAGE}/Sources/CmuxNextApp/AppActions+Workspaces.swift",
    f"{PACKAGE}/Sources/CmuxNextApp/Handlers/RoomHandlers.swift",
    f"{PACKAGE}/Sources/CmuxNextApp/Windows/WindowManager.swift",
    f"{PACKAGE}/Sources/CmuxNextApp/WorkspaceSpawn.swift",
    f"{PACKAGE}/Tests/CmuxNextAppTests/WorkspaceSpawnFirstTabTests.swift",
]


def tiers(changed: list[str], event: str = "pull_request", labels: frozenset[str] = frozenset()) -> dict[str, str]:
    return outputs(route(ROOT, event, changed, set(labels)))


class GraphCoversThePackage(unittest.TestCase):
    """The graph names every target directory, so no source falls through it."""

    def test_every_source_and_test_directory_is_a_target(self):
        paths = {target["path"] for target in GRAPH["targets"].values() if target["path"]}
        for kind in ("Sources", "Tests"):
            for directory in sorted((ROOT / PACKAGE / kind).iterdir()):
                if directory.is_dir():
                    with self.subTest(directory=directory.name):
                        self.assertIn(f"{PACKAGE}/{kind}/{directory.name}", paths)

    def test_dependencies_name_known_targets_and_packages(self):
        for name, target in GRAPH["targets"].items():
            with self.subTest(target=name):
                self.assertLessEqual(set(target["targets"]), set(GRAPH["targets"]))
                self.assertLessEqual(set(target["packages"]), set(GRAPH["packages"]))


class PullRequestTiers(unittest.TestCase):
    def test_ui_pr_runs_its_own_tests_without_the_daemon(self):
        result = tiers(PR_17470)
        self.assertEqual(result["swift_targets"], "CmuxNextAppTests")
        self.assertEqual(result["daemon"], "false")
        self.assertEqual(result["scheme"], "false")
        self.assertEqual(result["generated"], "true")
        self.assertEqual(result["native"], "true")
        self.assertEqual(result["swift_filter"], r"^(CmuxNextAppTests)\.")

    def test_a_shared_module_selects_its_dependents(self):
        result = tiers([f"{PACKAGE}/Sources/CmuxNextSidebar/SidebarView.swift"])
        self.assertEqual(result["swift_targets"].split(),
                         ["CmuxNextAppTests", "CmuxNextBridgeTests", "CmuxNextSidebarTests"])
        self.assertEqual(result["daemon"], "false")

    def test_daemon_client_sources_run_the_daemon_tier(self):
        result = tiers([f"{PACKAGE}/Sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift"])
        self.assertEqual(result["daemon"], "true")
        self.assertIn("CmuxNextDaemonTests", result["swift_targets"].split())

    def test_cmux_tui_runs_the_daemon_tier_and_the_scheme_compile(self):
        result = tiers(["cmux-tui/crates/cmux-app-host/src/lib.rs"])
        self.assertEqual(result["daemon"], "true")
        self.assertEqual(result["scheme"], "true")
        self.assertEqual(result["swift_targets"], "")

    def test_a_file_a_test_reads_selects_that_test(self):
        result = tiers(["schemas/settings/settings-schema.json"])
        self.assertEqual(result["swift_targets"], "CmuxNextSettingsTests")

    def test_a_local_package_selects_the_targets_that_use_it(self):
        result = tiers(["Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Thread.swift"])
        self.assertIn("CmuxNextHomeTests", result["swift_targets"].split())
        self.assertIn("CmuxNextAppTests", result["swift_targets"].split())
        self.assertNotIn("CmuxNextDaemonTests", result["swift_targets"].split())

    def test_web_and_docs_need_no_mac(self):
        result = tiers(["web/app/page.tsx", "docs/cmux-next.md"])
        self.assertEqual(result["macos"], "false")
        self.assertEqual(result["swift"], "false")

    def test_webviews_keep_one_scheme_compile(self):
        result = tiers(["webviews/src/agent-session/pane.tsx"])
        self.assertEqual(result["scheme"], "true")
        self.assertEqual(result["native"], "false")
        self.assertEqual(result["swift"], "false")

    def test_the_app_host_compiles_the_scheme_without_package_tests(self):
        result = tiers(["App/main.swift"])
        self.assertEqual(result["scheme"], "true")
        self.assertEqual(result["swift"], "false")

    def test_action_plans_check_generated_files(self):
        result = tiers(["plans/cmux-next/actions.md"])
        self.assertEqual(result["generated"], "true")
        self.assertIn("CmuxNextActionsTests", result["swift_targets"].split())


class EveryTier(unittest.TestCase):
    def assert_everything(self, result: dict[str, str]) -> None:
        for key in ("native", "macos", "scheme", "generated", "swift", "daemon", "full"):
            self.assertEqual(result[key], "true", key)
        self.assertEqual(result["swift_filter"], "")
        self.assertEqual(result["swift_targets"], "all")

    def test_push_runs_every_tier(self):
        self.assert_everything(tiers([], event="push"))

    def test_full_ci_label_runs_every_tier(self):
        self.assert_everything(tiers(PR_17470, labels=frozenset({"full-ci"})))

    def test_the_manifest_runs_every_tier(self):
        self.assert_everything(tiers([f"{PACKAGE}/Package.swift"]))

    def test_an_unplaced_package_file_runs_every_tier(self):
        self.assert_everything(tiers([f"{PACKAGE}/Fixtures/new.json"]))

    def test_an_unknown_diff_runs_every_tier(self):
        self.assert_everything(tiers([]))


class PushAttribution(unittest.TestCase):
    def test_skipped_jobs_do_not_end_the_range(self):
        earlier = [
            ("c3", {"cmux-next swift test": "skipped"}),
            ("c2", {"cmux-next swift test": "failure"}),
            ("c1", {"cmux-next swift test": "success"}),
        ]
        self.assertEqual(last_green(["cmux-next swift test"], earlier), "c1")

    def test_the_range_covers_every_failed_job(self):
        earlier = [
            ("c2", {"cmux-next swift test": "success", "cmux-next generated files": "failure"}),
            ("c1", {"cmux-next swift test": "success", "cmux-next generated files": "success"}),
        ]
        self.assertEqual(last_green(["cmux-next generated files", "cmux-next swift test"], earlier), "c1")

    def test_no_pass_means_no_range(self):
        self.assertIsNone(last_green(["cmux-next swift test"], [("c1", {"cmux-next swift test": "failure"})]))

    def test_reporting_jobs_are_not_culprits(self):
        self.assertEqual(failed_jobs({"cmux-next swift test": "failure", "cmux-next push attribution": "failure",
                                      "cmux-next checks": "success"}), ["cmux-next swift test"])


if __name__ == "__main__":
    unittest.main()
