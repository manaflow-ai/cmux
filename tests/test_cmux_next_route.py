#!/usr/bin/env python3
"""cmux-next pull requests run the tiers their change can break, and no fewer.

scripts/ci/cmux_next_route.py reads the committed SwiftPM target graph
(Packages/macOS/CmuxNext/ci-target-graph.json). These cases use the real graph,
so a manifest change that moves a dependency changes what they expect only
through the regenerated graph.
"""

from __future__ import annotations

import fnmatch
import json
import re
import sys
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from cmux_next_push_attribution import MAX_COMMENTED_PRS, failed_jobs, last_green, never_passed, should_comment  # noqa: E402
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


def call_arguments(text: str, index: int) -> str:
    """The top-level arguments of the call open at INDEX (just inside its parenthesis), up to the parenthesis
    that closes it. String literals ("...", \"\"\"...\"\"\", raw #"..."#) are kept whole at the top level;
    comments (//, nested /* */) and everything inside a nested call, array or closure become spaces, so
    `path:` matches only the target's own argument."""
    out: list[str] = []
    depth = 0
    closers = {"(": ")", "[": "]", "{": "}"}
    while index < len(text):
        if text.startswith("//", index):
            newline = text.find("\n", index)
            index = len(text) if newline < 0 else newline
            continue
        if text.startswith("/*", index):
            nesting, index = 1, index + 2
            while index < len(text) and nesting:
                if text.startswith("/*", index):
                    nesting, index = nesting + 1, index + 2
                elif text.startswith("*/", index):
                    nesting, index = nesting - 1, index + 2
                else:
                    index += 1
            out.append(" ")
            continue
        literal = re.match(r'(#*)("""|")', text[index:])
        if literal:
            hashes, quote = literal.groups()
            close = quote + hashes
            cursor = index + len(literal.group(0))
            while cursor < len(text) and not text.startswith(close, cursor):
                cursor += 2 if (text[cursor] == "\\" and not hashes) else 1
            cursor = min(len(text), cursor + len(close))
            out.append(text[index:cursor] if depth == 0 else " ")
            index = cursor
            continue
        char = text[index]
        if char in closers:
            depth += 1
        elif char in ")]}":
            if depth == 0:
                return "".join(out)
            depth -= 1
        elif depth == 0:
            out.append(char)
        index += 1
    return "".join(out)


def manifest_target_paths() -> set[str]:
    """The path of each target Package.swift declares: its own `path:` when it sets one
    (CmuxNextTestExitTrace lives in Tests/Support), else Tests/<name> for a test target and
    Sources/<name> otherwise."""
    manifest = (ROOT / PACKAGE / "Package.swift").read_text(encoding="utf-8")
    paths = set()
    for start in re.finditer(r'\.(target|testTarget|executableTarget)\(\s*name:\s*"([^"]+)"', manifest):
        # Only the target's own top-level `path:` argument: the last target in the list must not read one further
        # down (the package dependencies' `.package(path:)` follow it since #24978), nor one in a nested call.
        own = re.search(r'\bpath:\s*"([^"]+)"', call_arguments(manifest, start.end()))
        kind, name = start.groups()
        default = f"{'Tests' if kind == 'testTarget' else 'Sources'}/{name}"
        paths.add(f"{PACKAGE}/{own.group(1) if own else default}")
    return paths


def tiers(changed: list[str], event: str = "pull_request", labels: frozenset[str] = frozenset()) -> dict[str, str]:
    return outputs(route(ROOT, event, changed, set(labels)))


def graph_dependencies(name: str) -> set[str]:
    """Every target `name` depends on, directly or not, read straight from the graph."""
    found: set[str] = set()
    pending = list(GRAPH["targets"][name]["targets"])
    while pending:
        dependency = pending.pop()
        if dependency not in found:
            found.add(dependency)
            pending.extend(GRAPH["targets"][dependency]["targets"])
    return found


def graph_dependents(changed_targets: set[str]) -> set[str]:
    """The test targets a change to `changed_targets` can break: each test target that is
    one of them or depends on one of them. Expectations come from the regenerated graph,
    so a new target or dependency (#22683's CmuxNextChiefViewsTests) moves them with it."""
    return {
        name for name, target in GRAPH["targets"].items()
        if target["kind"] == "test" and (name in changed_targets or graph_dependencies(name) & changed_targets)
    }


def graph_readers(path: str) -> set[str]:
    """The test targets whose sources name `path` (the graph's `reads`; a trailing / is a directory)."""
    return {
        name for name, target in GRAPH["targets"].items()
        if target["kind"] == "test" and any(
            path.startswith(read) if read.endswith("/") else path == read for read in target.get("reads", [])
        )
    }


class GraphCoversThePackage(unittest.TestCase):
    """The graph names every target directory, so no source falls through it."""

    def test_every_source_and_test_directory_is_a_target(self):
        paths = {target["path"] for target in GRAPH["targets"].values() if target["path"]}
        # The graph is bot-only (#21946): a pull request that adds a target to the
        # manifest cannot add it to the graph, and the base autofix regenerates the
        # graph after the merge. Such a pull request routes every tier, so a target
        # the manifest declares is covered until then. A directory the manifest does
        # not declare still fails.
        declared = manifest_target_paths()
        for kind in ("Sources", "Tests"):
            for directory in sorted((ROOT / PACKAGE / kind).iterdir()):
                # A folder with no Swift sources (a fixture another language reads) is not a target.
                if directory.is_dir() and any(directory.rglob("*.swift")):
                    with self.subTest(directory=directory.name):
                        path = f"{PACKAGE}/{kind}/{directory.name}"
                        if path not in paths and path in declared:
                            continue
                        self.assertIn(path, paths)

    def test_the_manifest_reader_finds_the_graph_targets(self):
        """The allowance above reads target names from the manifest text; it must see every
        graph target whose directory still exists, or it could let a stray directory through."""
        declared = manifest_target_paths()
        for name, target in GRAPH["targets"].items():
            if target["path"] and (ROOT / target["path"]).is_dir():
                with self.subTest(target=name):
                    self.assertIn(target["path"], declared)

    def test_dependencies_name_known_targets_and_packages(self):
        for name, target in GRAPH["targets"].items():
            with self.subTest(target=name):
                self.assertLessEqual(set(target["targets"]), set(GRAPH["targets"]))
                self.assertLessEqual(set(target["packages"]), set(GRAPH["packages"]))


class ManifestReader(unittest.TestCase):
    def path_of(self, manifest: str) -> str | None:
        start = re.search(r'\.target\(\s*name:\s*"T"', manifest)
        own = re.search(r'\bpath:\s*"([^"]+)"', call_arguments(manifest, start.end()))
        return own.group(1) if own else None

    def test_a_path_after_the_call_is_not_the_target_s(self):
        self.assertIsNone(self.path_of('.target(name: "T", dependencies: ["A"])\n] + [x]\n.package(path: "../Other")'))

    def test_the_target_s_own_path_is_read(self):
        self.assertEqual(self.path_of('.target(name: "T", path: "Tests/Support/T")'), "Tests/Support/T")

    def test_a_nested_path_argument_is_not_the_target_s(self):
        self.assertEqual(self.path_of('.target(name: "T", resources: [helper(path: "Nested")], path: "Actual")'), "Actual")
        self.assertIsNone(self.path_of('.target(name: "T", resources: [.copy(path: "Nested")])'))

    def test_parentheses_in_strings_and_comments_do_not_end_the_call(self):
        manifest = ('.target(name: "T", /* ) /* nested ) */ ) */ swiftSettings: [.define("A)")],\n'
                    '  // a comment )\n  exclude: [#"raw ) \\"#, """\n  ) multi\n  """], path: "Real")\n'
                    '.package(path: "../Other")')
        self.assertEqual(self.path_of(manifest), "Real")


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


class MacReleaseInputs(unittest.TestCase):
    """mac_release: what the Mac Release compile (the package through xcodebuild) sees and the fleet SwiftPM compile check does not."""

    def test_package_sources_stay_on_the_compile_check(self):
        for changed in ([f"{PACKAGE}/Sources/CmuxNextApp/WorkspaceSpawn.swift"],
                        [f"{PACKAGE}/Sources/CmuxNextApp/Resources/Localizable.xcstrings"],
                        # The Xcode app target is not in this compile (the scheme compile builds it).
                        ["App/main.swift"], ["cmux.xcodeproj/project.pbxproj"]):
            with self.subTest(changed=changed):
                self.assertEqual(outputs(route(ROOT, "pull_request", changed, set()))["mac_release"], "false")

    def test_inputs_only_xcodebuild_sees_need_the_mac(self):
        for changed in ([f"{PACKAGE}/Package.swift"], [f"{PACKAGE}/Package.resolved"],
                        ["Packages/Shared/CmuxTheme/Package.swift"], [f"{PACKAGE}/Sources/CmuxNextApp/Info.plist"],
                        [f"{PACKAGE}/Sources/CmuxNextApp/Resources/Media.xcassets/Contents.json"],
                        ["scripts/ci/xcode-pins.txt"], ["scripts/cmux-next/check-release-compile.sh"],
                        ["scripts/cmux-next/lib/fleet-only.sh"], ["scripts/cmux-next/stale-pcm-retry-needed.sh"]):
            with self.subTest(changed=changed):
                self.assertEqual(outputs(route(ROOT, "pull_request", changed, set()))["mac_release"], "true")

    def test_every_tier_includes_it(self):
        self.assertEqual(outputs(route(ROOT, "push", [], set()))["mac_release"], "true")
        source = f"{PACKAGE}/Sources/CmuxNextApp/WorkspaceSpawn.swift"
        self.assertEqual(outputs(route(ROOT, "pull_request", [source], {"full-ci"}))["mac_release"], "true")


class PullRequestTiers(unittest.TestCase):
    def test_changed_swift_suite_is_prioritized(self):
        result = tiers([f"{PACKAGE}/Tests/CmuxNextAppTests/CloudAPIClientRunTests.swift"])
        self.assertEqual(result["swift_priority_filter"], r".*(CloudAPIClientRunTests)\.")

    def test_changed_swift_source_prioritizes_its_matching_suite(self):
        result = tiers([f"{PACKAGE}/Sources/CmuxNextApp/CloudStartSessionAsks.swift"])
        self.assertEqual(result["swift_priority_filter"], r".*(CloudStartSessionAsksTests)\.")

    def test_nested_changed_swift_suite_is_prioritized(self):
        result = tiers([f"{PACKAGE}/Sources/CmuxNextPopups/WebAuth/WebAuthCallback.swift"])
        self.assertEqual(result["swift_priority_filter"], r".*(WebAuthCallbackTests)\.")

    def test_isolated_suites_are_left_to_their_dedicated_steps(self):
        result = tiers([f"{PACKAGE}/Tests/CmuxNextControlTests/CLISurfaceParityTests.swift"])
        self.assertEqual(result["swift_priority_filter"], "")

    def test_cloud_bring_back_stays_prioritized_for_new_cases(self):
        result = tiers([f"{PACKAGE}/Tests/CmuxNextAppTests/CloudBringBackTests.swift"])
        self.assertEqual(result["swift_priority_filter"], r".*(CloudBringBackTests)\.")

    def test_ui_pr_runs_its_own_tests_without_the_daemon(self):
        result = tiers(PR_17470)
        self.assertEqual(result["swift_targets"], "CmuxNextAppTests")
        self.assertEqual(result["daemon"], "false")
        self.assertEqual(result["scheme"], "false")
        self.assertEqual(result["generated"], "true")
        self.assertEqual(result["native"], "true")
        self.assertEqual(result["swift_filter"], r"^(CmuxNextAppTests)\.")

    def test_a_shared_module_selects_its_dependents(self):
        path = f"{PACKAGE}/Sources/CmuxNextSidebar/SidebarView.swift"
        result = tiers([path])
        selected = result["swift_targets"].split()
        self.assertEqual(selected, sorted(graph_dependents({"CmuxNextSidebar"}) | graph_readers(path)))
        # CmuxNextChiefViewsTests (#22683) reaches the sidebar through CmuxNextChiefViews.
        for name in ("CmuxNextAppTests", "CmuxNextChiefViewsTests", "CmuxNextKeepAwakeTests", "CmuxNextWorkspaceNamingTests"):
            self.assertIn(name, selected)
        for name in ("CmuxNextDaemonTests", "CmuxNextDesignTests"):
            self.assertNotIn(name, selected)
        self.assertEqual(result["daemon"], "false")

    def test_every_target_selects_the_tests_that_reach_it(self):
        """A source file in any target selects exactly the test targets that are it, depend on
        it, or read the file, so no target in the graph is under- or over-routed."""
        for name, target in sorted(GRAPH["targets"].items()):
            if not target["path"]:
                continue
            path = f"{target['path']}/RouteProbe.swift"
            with self.subTest(target=name):
                result = tiers([path])
                self.assertEqual(result["full"], "false", path)
                self.assertEqual(result["swift_targets"].split(), sorted(graph_dependents({name}) | graph_readers(path)))

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
        # (ce0b9e76a9b) the schema is also a web-bundle input, so the test targets that
        # depend on a target shipping a bundle are selected with it, and nothing else.
        # The graph names those dependents (#23260, #22683 and #21818 each added one).
        import cmux_next_route as route_module
        path = "schemas/settings/settings-schema.json"
        result = tiers([path])
        selected = result["swift_targets"].split()
        # The targets that ship a bundle are pinned here, so dropping one from the router
        # fails this test instead of moving the expectation with it.
        bundles = {"CmuxNextAgentPane", "CmuxNextPages", "CmuxNextAgentActivity", "CmuxNextPalette"}
        self.assertEqual(set(route_module.BUNDLE_TARGETS), bundles)
        self.assertLessEqual(bundles, set(GRAPH["targets"]))
        self.assertEqual(selected, sorted(graph_dependents(bundles) | graph_readers(path)))
        for name in ("CmuxNextSettingsTests", "CmuxNextAppTests", "CmuxNextAgentPaneTests", "CmuxNextPagesTests", "CmuxNextPaletteTests"):
            self.assertIn(name, selected)
        for name in ("CmuxNextDaemonTests", "CmuxNextMobileTests"):
            self.assertNotIn(name, selected)

    def test_a_local_package_selects_the_targets_that_use_it(self):
        result = tiers(["Packages/Shared/CmuxHomeCore/Sources/CmuxHomeCore/Thread.swift"])
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

    def test_a_ci_only_change_runs_no_mac_tier(self):
        """Workflows, CI scripts, the router and gh-merge-green: actionlint, the CI unit tests and the
        routing replay check them on Linux, and one command reverts them."""
        result = tiers(["scripts/ci/cmux_next_route.py", "tests/test_cmux_next_route.py"])
        for tier in ("macos", "scheme", "native", "swift", "generated", "daemon", "full"):
            self.assertEqual(result[tier], "false", tier)

        result = tiers([".github/workflows/cmux-next.yml", "scripts/ci/cmux_next_route.py"])
        for tier in ("macos", "scheme", "native", "swift", "generated", "daemon", "full"):
            self.assertEqual(result[tier], "true", tier)

        result = tiers(["scripts/ci/select_package_tests.py", "webviews/src/agent-session/pane.tsx"])
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

    def test_a_vendored_pin_bump_marks_every_tier_for_the_batch(self):
        # The GhosttyNextKit binary pin and the CEF pin change code no app diff
        # shows (classic's #19672 passed on macos-26 and crashed on macOS 27).
        # A pin bump marks every tier for the batch integration run. Ordinary
        # pull requests still keep the Swift suite on the batch cadence.
        for pin in ("Packages/Shared/CmuxGhosttyKit/Package.swift", "scripts/cmux-next/cef-manifest.json"):
            result = tiers([pin])
            self.assert_everything(result)
            self.assertEqual(result["vendored_pin"], "true", pin)
        self.assertEqual(tiers(PR_17470)["vendored_pin"], "false")
        self.assertEqual(tiers([], event="push")["vendored_pin"], "false")
        workflow = (ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8")
        self.assertIn("vendored_pin: ${{ steps.route.outputs.vendored_pin }}", workflow)
        swift_test = workflow[workflow.index("\n  swift-test:\n"):workflow.index("\n  daemon-test:\n")]
        # Swift runs on a same-repository PR (#22303), a fork PR labeled full-ci and
        # dispatches; a feat-cmux-next push skips it (push CI is the app build).
        condition = next(line for line in swift_test.splitlines() if line.startswith("    if: "))
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", condition)
        self.assertIn("contains(github.event.pull_request.labels.*.name, 'full-ci')", condition)
        self.assertIn("github.ref == 'refs/heads/feat-cmux-next'", condition)
        self.assertIn("    continue-on-error: false\n", swift_test)
        self.assertIn("    name: cmux-next swift test\n", swift_test)


MAC_TIERS = ("full", "native", "scheme", "generated", "swift", "daemon", "mac_release", "swift_canary")


def mac_tiers(result: dict[str, str]) -> list[str]:
    return [key for key in MAC_TIERS if result.get(key) == "true"]


class LinuxLaneTests(unittest.TestCase):
    """A tests/test_*.py whose registry lane is linux-guard, and that no Mac tier reads, needs no Mac tier."""

    @classmethod
    def setUpClass(cls):
        import cmux_next_route as route_module
        cls.route = route_module
        graph = route_module.load_graph(ROOT)
        tests = [name for name, target in graph["targets"].items() if target["kind"] == "test"]
        cls.read = staticmethod(lambda path: any(route_module.matches(path, r) for name in tests
                                                 for r in graph["targets"][name].get("reads", [])))
        cls.tree_inputs = route_module.tree_input_paths(ROOT)
        cls.linux = route_module.linux_guard_tests(ROOT)
        # A linux-guard test the CI-only patterns do not already cover: the new fast path is what skips it.
        cls.sample = next(path for path in sorted(cls.linux)
                          if not route_module.ci_only(path) and not route_module.web_fast(path)
                          and not route_module.consumed(path, cls.tree_inputs, cls.read))

    def test_the_allowlist_comes_from_the_registry(self):
        from test_execution_registry import load_registry
        entries = load_registry(ROOT / "tests/test-execution.toml")
        expected = {e["path"] for e in entries if e.get("lane") == "linux-guard" and str(e["path"]).startswith("tests/test_")}
        self.assertEqual(set(self.linux), expected)
        self.assertGreater(len(self.linux), 100)

    def test_a_linux_guard_test_alone_skips_the_mac_tiers(self):
        result = tiers([self.sample])
        self.assertEqual(mac_tiers(result), [], self.sample)
        self.assertEqual(tiers([self.sample, "tests/test-execution.toml"])["native"], "false")

    def test_a_test_moved_off_linux_guard_routes_to_mac_again(self):
        from test_execution_registry import load_registry
        entries = [dict(e, lane="macos-shell") if e["path"] == self.sample else e
                   for e in load_registry(ROOT / "tests/test-execution.toml")]
        with mock.patch("test_execution_registry.load_registry", return_value=entries):
            self.assertIn("native", mac_tiers(tiers([self.sample])))

    def test_an_unreadable_registry_allowlists_nothing(self):
        with mock.patch("test_execution_registry.load_registry", side_effect=ValueError("bad registry")):
            self.assertEqual(self.route.linux_guard_tests(ROOT), frozenset())
            self.assertIn("native", mac_tiers(tiers([self.sample])))
            self.assertIn("native", mac_tiers(tiers(["tests/test-execution.toml"])))

    def test_a_linux_guard_test_a_mac_tier_reads_keeps_its_tier(self):
        with mock.patch.object(self.route, "SWIFT_JOB_INPUTS", self.route.SWIFT_JOB_INPUTS + (self.sample,)):
            self.assertIn("swift", mac_tiers(tiers([self.sample])))

    def test_no_allowlisted_test_is_a_mac_input(self):
        """Over the real registry: every linux-guard test the fast path lets skip is read by no Mac tier."""
        for path in sorted(self.linux):
            with self.subTest(path=path):
                if self.route.consumed(path, self.tree_inputs, self.read):
                    self.assertNotEqual(mac_tiers(tiers([path])), [], path)
                    continue
                self.assertNotIn(path, self.route.FULL_INPUTS + self.route.DAEMON_PATHS)
                for pattern in (self.route.SWIFT_JOB_INPUTS + self.route.GENERATED_INPUTS
                                + self.route.BUNDLE_INPUTS + self.route.MAC_RELEASE_INPUTS + tuple(self.tree_inputs)):
                    self.assertFalse(self.route.matches(path, pattern) or fnmatch.fnmatch(path, pattern),
                                     f"{path} matches Mac input {pattern}")
                self.assertEqual(mac_tiers(tiers([path])), [], path)

    def test_an_unknown_path_still_routes_to_mac(self):
        for path in ("newdir/tool.py", "tests/helper_not_registered.py", "tests/test_not_in_registry_xyz.py"):
            with self.subTest(path=path):
                self.assertIn("native", mac_tiers(tiers([path])))

    def test_a_linux_guard_test_with_another_file_still_compiles(self):
        for other in ("scripts/cmux-next/new-step.sh", "Resources/new.json",
                      f"{PACKAGE}/Sources/CmuxNextApp/AgentTabs+Wiring.swift"):
            with self.subTest(other=other):
                self.assertIn("native", mac_tiers(tiers([self.sample, other])))


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

    def test_a_job_that_never_passed_does_not_hide_the_others_range(self):
        """The checks job ran on pushes from 10-19, red on the base; swift test's culprits still count."""
        earlier = [("c1", {"cmux-next swift test": "success", "cmux-next checks": "failure"})]
        failed = ["cmux-next checks", "cmux-next swift test"]
        self.assertEqual(never_passed(failed, earlier), ["cmux-next checks"])
        attributable = [name for name in failed if name not in never_passed(failed, earlier)]
        self.assertEqual(last_green(attributable, earlier), "c1")

    def test_a_long_red_range_comments_on_nobody(self):
        """The first push on ae20394 would have named 22 PRs for one known crash."""
        self.assertTrue(should_comment(list(range(MAX_COMMENTED_PRS))))
        self.assertFalse(should_comment(list(range(MAX_COMMENTED_PRS + 1))))
        self.assertFalse(should_comment(list(range(22))))
        self.assertFalse(should_comment([]))

    def test_reporting_jobs_are_not_culprits(self):
        self.assertEqual(failed_jobs({"cmux-next swift test": "failure", "cmux-next push attribution": "failure",
                                      "cmux-next checks": "success"}), ["cmux-next swift test"])


class RouteLabels(unittest.TestCase):
    """The route step reads the push's labels from the event and the live ones only on a re-run.

    Every push read issues/N/labels; the event already carries them. A re-run keeps its event, so
    adding full-ci or dev-build and re-running still routes on the live labels.
    """

    def run_route(self, attempt: str) -> tuple[str, list[str]]:
        import os
        import subprocess
        import tempfile
        import yaml
        workflow = yaml.safe_load((ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8"))
        step = next(s for s in workflow["jobs"]["path_route"]["steps"] if s.get("id") == "route")
        with tempfile.TemporaryDirectory() as tmp:
            repo, bin_dir = Path(tmp) / "repo", Path(tmp) / "bin"
            (repo / "scripts/ci").mkdir(parents=True)
            (repo / "scripts/cmux-next").mkdir(parents=True)
            bin_dir.mkdir()
            (repo / "scripts/ci/cmux_next_route.py").write_text(
                "import sys, pathlib\n"
                "args = sys.argv[1:]\n"
                "pathlib.Path(sys.argv[0]).with_name('labels.txt').write_text(args[args.index('--labels') + 1])\n")
            (repo / "scripts/cmux-next/cmux-tui-tree-inputs.txt").write_text("tree cmux-tui\n")
            gh_log = Path(tmp) / "gh.log"
            (bin_dir / "gh").write_text(f'#!/usr/bin/env bash\necho "$*" >> {gh_log}\necho dev-build\n')
            (bin_dir / "gh").chmod(0o755)
            git = ["git", "-C", str(repo), "-c", "user.name=t", "-c", "user.email=t@example.com"]
            subprocess.run(["git", "init", "-q", str(repo)], check=True)
            subprocess.run([*git, "add", "-A"], check=True)
            subprocess.run([*git, "commit", "-qm", "base"], check=True)
            (repo / "webviews.txt").write_text("x\n")
            subprocess.run([*git, "add", "-A"], check=True)
            subprocess.run([*git, "commit", "-qm", "head"], check=True)
            out = Path(tmp) / "out"
            env = {**os.environ, "PATH": f"{bin_dir}:{os.environ['PATH']}", "EVENT_NAME": "pull_request",
                   "PR_NUMBER": "7", "GITHUB_REPOSITORY": "o/r", "GITHUB_RUN_ATTEMPT": attempt,
                   "EVENT_LABELS": "full-ci,risk:low", "RUNNER_TEMP": tmp, "GITHUB_OUTPUT": str(out),
                   "GITHUB_STEP_SUMMARY": str(Path(tmp) / "summary"), "DEV_DAILY": "false",
                   "DEV_DAILY_SHA": "", "SAME_TREE_SHA": "", "GH_TOKEN": "t"}
            result = subprocess.run(["bash", "-e", "-c", step["run"]], cwd=repo, env=env,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            labels = (repo / "scripts/ci/labels.txt").read_text()
            return labels, gh_log.read_text().splitlines() if gh_log.exists() else []

    def test_a_first_attempt_routes_on_the_event_labels(self):
        labels, gh_calls = self.run_route("1")
        self.assertEqual(labels, "full-ci,risk:low")
        self.assertEqual(gh_calls, [])

    def test_a_rerun_routes_on_the_live_labels(self):
        labels, gh_calls = self.run_route("2")
        self.assertEqual(labels, "dev-build")
        self.assertEqual(len(gh_calls), 1)
        self.assertIn("issues/7/labels", gh_calls[0])


if __name__ == "__main__":
    unittest.main()
