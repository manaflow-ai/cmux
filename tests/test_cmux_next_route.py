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
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from cmux_next_push_attribution import MAX_COMMENTED_PRS, failed_jobs, last_green, should_comment  # noqa: E402
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


def tiers(changed: list[str], event: str = "pull_request", labels: frozenset[str] = frozenset(),
          diff: list[str] | None = None) -> dict[str, str]:
    return outputs(route(ROOT, event, changed, set(labels), diff=diff))


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


class GraphGenerator(unittest.TestCase):
    def test_a_literal_too_long_for_a_path_is_not_a_read(self):
        """macOS stat fails with ENAMETOOLONG on a base64 certificate in a test (run 37411671734)."""
        import importlib.util
        import tempfile
        spec = importlib.util.spec_from_file_location("ci_target_graph", ROOT / "scripts/cmux-next/ci-target-graph.py")
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        # Inside the checkout: reads are repository paths.
        with tempfile.TemporaryDirectory(dir=ROOT) as directory:
            source = Path(directory) / "CertTests.swift"
            source.write_text('let pem = "MIIC' + "A" * 300 + '/b"\nlet plan = "plans/cmux-next/actions.md"\n', encoding="utf-8")
            real_exists = Path.exists

            def exists(path, *args, **kwargs):
                # Python 3.13 (the minis) raises here; 3.14 returns False.
                if any(len(part) > 255 for part in path.parts):
                    raise OSError(63, "File name too long", str(path))
                return real_exists(path, *args, **kwargs)

            with mock.patch.object(Path, "exists", exists):
                self.assertEqual(generator.literal_reads(Path(directory)), ["plans/cmux-next/actions.md"])


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
        # CmuxNextSettingsTests reads the schema. Since the bundles are build output
        # (ce0b9e76a9b) the schema is also a web-bundle input, so the targets that ship
        # a bundle, and the app that embeds them, are selected with it, and nothing else.
        result = tiers(["schemas/settings/settings-schema.json"])
        self.assertEqual(result["swift_targets"].split(), sorted([
            "CmuxNextSettingsTests", "CmuxNextAppTests",
            "CmuxNextAgentPaneTests", "CmuxNextPagesTests", "CmuxNextAgentActivityTests", "CmuxNextPaletteTests",
        ]))

    def test_a_local_package_selects_the_targets_that_use_it(self):
        result = tiers(["Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Thread.swift"])
        self.assertIn("CmuxNextHomeTests", result["swift_targets"].split())
        self.assertIn("CmuxNextAppTests", result["swift_targets"].split())
        self.assertNotIn("CmuxNextDaemonTests", result["swift_targets"].split())

    def test_app_ffi_sources_run_the_pin_check(self):
        """check-app-ffi-pin.sh and the reducer cargo test live in swift test."""
        for path in ("cmux-tui/crates/cmux-layout-reducer/src/lib.rs", "cmux-tui/rust-toolchain.toml",
                     "scripts/cmux-next/build-app-ffi.sh", "cmux-tui/crates/cmux-rd-core/src/lib.rs"):
            with self.subTest(path=path):
                self.assertEqual(tiers([path])["swift"], "true")

    def test_every_routed_input_triggers_the_workflow(self):
        """A path the router acts on but the pull_request paths filter misses never runs."""
        import fnmatch
        import yaml
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8"))
        patterns = workflow[True]["pull_request"]["paths"]
        import cmux_next_route as route_module
        inputs = list(route_module.FULL_INPUTS) + list(route_module.DAEMON_PATHS) + list(route_module.SWIFT_JOB_INPUTS)
        inputs += [p + "x" if p.endswith("/") else p for p in route_module.tree_input_paths(ROOT)]
        for directory in GRAPH["packages"].values():
            inputs.append(directory + "/Sources/x.swift")
        from select_package_tests import input_prefixes, package_dirs
        dirs = package_dirs(ROOT)
        for directory in GRAPH["packages"].values():
            for prefix in input_prefixes(ROOT, Path(directory).name, dirs):
                inputs.append(prefix + "x")
        for target in GRAPH["targets"].values():
            inputs += [read + "x" if read.endswith("/") else read for read in target.get("reads", [])]
        for path in sorted(set(inputs)):
            with self.subTest(path=path):
                self.assertTrue(any(fnmatch.fnmatch(path, pattern.replace("**", "*")) for pattern in patterns), path)

    def test_dev_build_label_keeps_the_scheme_compile(self):
        """The dogfood artifact (#17500) is the scheme compile's app."""
        result = tiers(PR_17470, labels=frozenset({"dev-build"}))
        self.assertEqual(result["scheme"], "true")
        self.assertEqual(result["daemon"], "false")

    def test_web_and_docs_need_no_mac(self):
        result = tiers(["web/app/page.tsx", "docs/cmux-next.md"])
        self.assertEqual(result["macos"], "false")
        self.assertEqual(result["swift"], "false")

    def test_a_web_nit_runs_no_mac_tier(self):
        """A webviews change and its regenerated agent-pane bundle (#18296, one CSS line) need no Mac.

        ci-web type-checks, lints and tests the sources and proves with build-agent-pane-web.sh --check
        that the committed bundle matches them; the bundle is a `.copy` resource, so the app takes any
        file set without a compile.
        """
        for changed in (
            ["webviews/src/agent-session/pane.tsx"],
            ["webviews/src/agent-session/acpmux/composerAttachments.css",
             f"{PACKAGE}/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html"],
            ["Resources/markdown-viewer/webviews-app/index.js", "docs/cmux-next.md"],
        ):
            with self.subTest(changed=changed):
                result = tiers(changed)
                for tier in ("macos", "scheme", "native", "swift", "generated", "daemon"):
                    self.assertEqual(result[tier], "false", tier)

    def test_a_web_change_beside_native_code_keeps_the_mac_tiers(self):
        result = tiers(["webviews/src/agent-session/pane.tsx", f"{PACKAGE}/Sources/CmuxNextAgentPane/AgentPaneView.swift"])
        self.assertEqual(result["native"], "true")
        self.assertEqual(result["scheme"], "true")

    def test_a_web_file_a_swift_test_reads_keeps_that_test(self):
        reads = [read for target in GRAPH["targets"].values() for read in target.get("reads", [])
                 if read.startswith("webviews/") and not read.endswith("/")]
        self.assertTrue(reads, "no Swift test reads a webviews file; pick another fixture")
        self.assertEqual(tiers([reads[0]])["swift"], "true")

    def test_a_ci_only_change_runs_no_mac_tier(self):
        """Workflows, CI scripts, the router and gh-merge-green: actionlint, the CI unit tests and the
        routing replay check them on Linux, and one command reverts them."""
        for changed in (
            [".github/workflows/cmux-next.yml", "scripts/ci/cmux_next_route.py", "tests/test_cmux_next_route.py"],
            ["scripts/gh-merge-green", "scripts/ci/revert_pr.py", "tests/test_gh_merge_green_revert.py"],
            ["scripts/ci/select_package_tests.py", "webviews/src/agent-session/pane.tsx"],
        ):
            with self.subTest(changed=changed):
                result = tiers(changed)
                for tier in ("macos", "scheme", "native", "swift", "generated", "daemon", "full"):
                    self.assertEqual(result[tier], "false", tier)

    def test_ci_files_a_mac_job_consumes_keep_their_tier(self):
        self.assertEqual(tiers(["scripts/ci/xcode-pins.txt"])["full"], "true")
        self.assertEqual(tiers([".github/actions/setup-cmux-tui-rust/action.yml"])["swift"], "true")

    def test_a_doc_a_generator_reads_keeps_the_generated_tier(self):
        """`*.md` looks like docs, but plans/cmux-next/ feeds the action contracts."""
        self.assertEqual(tiers(["plans/cmux-next/actions.md"])["generated"], "true")

    def test_dev_build_label_keeps_the_scheme_compile_for_a_web_change(self):
        result = tiers(["webviews/src/agent-session/pane.tsx"], labels=frozenset({"dev-build"}))
        self.assertEqual(result["scheme"], "true")

    def test_the_app_host_compiles_the_scheme_without_package_tests(self):
        result = tiers(["App/main.swift"])
        self.assertEqual(result["scheme"], "true")
        self.assertEqual(result["swift"], "false")

    def test_action_plans_check_generated_files(self):
        result = tiers(["plans/cmux-next/actions.md"])
        self.assertEqual(result["generated"], "true")
        self.assertIn("CmuxNextActionsTests", result["swift_targets"].split())


class ReleaseCompileTier(unittest.TestCase):
    """A pull request runs the Release compile only where Release can differ from the Debug builds it gets.

    swift test builds the package in Debug with the same Xcode, so a Release-only failure needs a build
    setting, a manifest or a DEBUG conditional. Pushes, dispatches and full-ci always run it.
    """

    def test_a_ui_pr_skips_the_release_compile(self):
        with mock.patch("cmux_next_route.debug_conditional", return_value=False):
            result = tiers(PR_17470)
        self.assertEqual(result["native"], "true")
        self.assertEqual(result["release"], "false")
        # The real WindowManager.swift has a DEBUG conditional, so #17470 itself runs it.
        self.assertEqual(tiers(PR_17470)["release"], "true")

    def test_manifests_and_build_settings_run_it(self):
        for path in ("Packages/Shared/CmuxGhosttyKit/Package.swift", f"{PACKAGE}/Package.swift",
                     "Config/Release.xcconfig", "cmux.xcodeproj/project.pbxproj"):
            with self.subTest(path=path):
                self.assertEqual(tiers([path])["release"], "true")

    def test_its_own_scripts_and_the_cef_shim_run_it(self):
        for path in ("scripts/cmux-next/check-release-compile.sh", "scripts/cmux-next/build-cef-shim.sh",
                     "scripts/cmux-next/ensure-cef.sh", "scripts/cmux-next/cef-manifest.json",
                     f"{PACKAGE}/CEFShim/src/shim_client.mm"):
            with self.subTest(path=path):
                self.assertEqual(tiers([path])["release"], "true")

    def test_a_debug_conditional_in_a_changed_file_runs_it(self):
        changed = f"{PACKAGE}/Sources/CmuxNextApp/WorkspaceSpawn.swift"
        with mock.patch("cmux_next_route.debug_conditional", side_effect=lambda root, path: path == changed):
            self.assertEqual(tiers([changed])["release"], "true")
            self.assertEqual(tiers([f"{PACKAGE}/Sources/CmuxNextApp/AgentTabs+Wiring.swift"])["release"], "false")

    def test_a_removed_debug_conditional_runs_it(self):
        diff = ["--- a/x.swift", "+++ b/x.swift", "@@ -3,3 +2,0 @@", "-#if DEBUG", "-    log()", "-#endif"]
        with mock.patch("cmux_next_route.debug_conditional", return_value=False):
            self.assertEqual(tiers(PR_17470, diff=diff)["release"], "true")
            self.assertEqual(tiers(PR_17470, diff=["+    let debug = true", "-// DEBUG only"])["release"], "false")

    def test_debug_conditional_reads_the_head_file(self):
        import tempfile
        import cmux_next_route
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name, text in {"a.swift": "#if DEBUG\nx()\n#endif\n", "b.swift": "  #elseif !DEBUG && os(macOS)\n",
                               "c.swift": "let DEBUG = 1 // #if DEBUG in a comment\n", "d.md": "#if DEBUG\n"}.items():
                (root / name).write_text(text, encoding="utf-8")
            found = {name: cmux_next_route.debug_conditional(root, name) for name in ("a.swift", "b.swift", "c.swift",
                                                                                      "d.md", "gone.swift")}
        self.assertEqual(found, {"a.swift": True, "b.swift": True, "c.swift": False, "d.md": False,
                                 "gone.swift": False})

    def test_web_only_skips_it(self):
        self.assertEqual(tiers(["web/app/page.tsx"])["release"], "false")


class EveryTier(unittest.TestCase):
    def assert_everything(self, result: dict[str, str]) -> None:
        for key in ("native", "macos", "scheme", "generated", "swift", "daemon", "full", "release"):
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

    def test_a_long_red_range_comments_on_nobody(self):
        """The first push on ae20394 would have named 22 PRs for one known crash."""
        self.assertTrue(should_comment(list(range(MAX_COMMENTED_PRS))))
        self.assertFalse(should_comment(list(range(MAX_COMMENTED_PRS + 1))))
        self.assertFalse(should_comment(list(range(22))))
        self.assertFalse(should_comment([]))

    def test_reporting_jobs_are_not_culprits(self):
        self.assertEqual(failed_jobs({"cmux-next swift test": "failure", "cmux-next push attribution": "failure",
                                      "cmux-next checks": "success"}), ["cmux-next swift test"])


if __name__ == "__main__":
    unittest.main()
