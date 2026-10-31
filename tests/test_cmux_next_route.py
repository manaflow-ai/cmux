#!/usr/bin/env python3
"""cmux-next pull requests run the tiers their change can break, and no fewer.

scripts/ci/cmux_next_route.py reads the committed SwiftPM target graph
(Packages/macOS/CmuxNext/ci-target-graph.json). These cases use the real graph,
so a manifest change that moves a dependency changes what they expect only
through the regenerated graph.
"""

from __future__ import annotations

import fnmatch
import importlib.util
import json
import re
import sys
import unittest
from unittest import mock
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

from cmux_next_push_attribution import MAX_COMMENTED_PRS, failed_jobs, last_green, never_passed, should_comment  # noqa: E402
from cmux_next_route import MAX_PRIORITY_SUITES, outputs, route  # noqa: E402

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

    def test_a_diff_past_the_cap_gets_no_priority_shard(self):
        suites = sorted(path.stem for path in (ROOT / PACKAGE / "Tests/CmuxNextAppTests").glob("*Tests.swift"))
        changed = [f"{PACKAGE}/Tests/CmuxNextAppTests/{name}.swift" for name in suites]
        self.assertGreater(len(changed), MAX_PRIORITY_SUITES)
        self.assertEqual(tiers(changed)["swift_priority_filter"], "")
        at_cap = tiers(changed[:MAX_PRIORITY_SUITES])["swift_priority_filter"]
        self.assertEqual(at_cap.count("|") + 1, MAX_PRIORITY_SUITES)

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

    def test_cmux_tui_runs_the_daemon_tier_without_a_mac_compile(self):
        """Rust no Swift compile reads runs the daemon tier only: no fleet Release compile (cmux-next/compile)
        and no scheme compile (#27921, #27815, #28180 held for hours on a compile that changed nothing)."""
        for changed in (["cmux-tui/crates/cmux-app-host/src/lib.rs"],
                        ["cmux-tui/crates/acpmux/src/peer.rs", "cmux-tui/crates/acpmux/tests/durable_agents.rs"],
                        ["cmux-tui/crates/acpmux/Cargo.toml"]):
            with self.subTest(changed=changed):
                result = tiers(changed)
                self.assertEqual(result["daemon"], "true")
                self.assertEqual(result["native"], "false")
                self.assertEqual(result["scheme"], "false")
                self.assertEqual(result["swift_targets"], "")

    def test_a_path_no_mac_build_reads_runs_no_mac_compile(self):
        """#29013 (the Cloud VM image lock and its web test) waited 80 minutes on the fleet Release
        compile (cmux-next/compile) for a compile its diff could not change."""
        for changed in (["images/cmux-vm/inputs.lock.json", "web/scripts/cmux-vm-image/lock.ts",
                         "web/tests/vm-image-cmux-vm-lock.test.ts"],
                        ["images/cmux-vm/guest/vm-agent.ts"], ["services/conversation-sim/audio.ts"],
                        ["vault/cmd/cmux-vault/main.go"], [".claude/settings.json"], [".coderabbit.yaml"]):
            with self.subTest(changed=changed):
                result = tiers(changed)
                for tier in ("native", "scheme", "macos", "swift", "generated", "daemon"):
                    self.assertEqual(result[tier], "false", tier)

    def test_the_selector_lint_table_runs_no_mac_compile(self):
        """#29032 changed only scripts/cmux-next/objc-selector-table.json, which the crash-class lint
        reads on Linux, and waited on the fleet Release compile."""
        for path in ("scripts/cmux-next/objc-selector-table.json", "scripts/cmux-next/check-objc-selectors.py",
                     "scripts/cmux-next/check-objc-selectors.sh"):
            with self.subTest(path=path):
                result = tiers([path])
                for tier in ("native", "scheme", "macos", "swift", "generated", "daemon"):
                    self.assertEqual(result[tier], "false", tier)

    def test_a_path_no_mac_build_reads_beside_swift_keeps_the_swift_tiers(self):
        swift = f"{PACKAGE}/Sources/CmuxNextDaemon/Connection/DaemonEndpoint.swift"
        mixed, alone = tiers(["images/cmux-vm/inputs.lock.json", swift]), tiers([swift])
        for tier in ("native", "scheme", "macos", "swift", "swift_targets", "generated", "daemon", "mac_release"):
            self.assertEqual(mixed[tier], alone[tier], tier)

    def test_no_app_input_is_named_by_a_build_input(self):
        """NO_APP_INPUT holds only paths no Mac compile reads: no Xcode project, Package.swift or
        scripts/ build script names one. A path that becomes a build input must leave the list."""
        import cmux_next_route as route_module
        inputs = [ROOT / "cmux.xcodeproj/project.pbxproj"]
        inputs += [p for p in ROOT.glob("Packages/**/Package.swift") if ".build" not in p.parts]
        inputs += sorted(ROOT.glob("scripts/*.sh")) + sorted(ROOT.glob("scripts/cmux-next/**/*.sh"))
        inputs += [p for p in ROOT.glob("Packages/macOS/CmuxNext/**/*.sh") if ".build" not in p.parts]
        self.assertGreater(len(inputs), 50)
        for pattern in route_module.NO_APP_INPUT:
            prefix = pattern.removesuffix("*")
            named = re.compile(r"(^|[^A-Za-z0-9_.-])" + re.escape(prefix) + ("" if prefix.endswith("/") else r"\b"))
            for path in inputs:
                with self.subTest(pattern=pattern, input=str(path.relative_to(ROOT))):
                    self.assertIsNone(named.search(path.read_text(encoding="utf-8", errors="replace")))

    def test_cmux_tui_a_dev_build_still_bundles_it(self):
        result = tiers(["cmux-tui/crates/acpmux/src/peer.rs"], labels=frozenset({"dev-build"}))
        self.assertEqual(result["scheme"], "true")
        self.assertEqual(result["native"], "false")

    def test_app_ffi_sources_run_the_swift_compiles(self):
        """CCmuxAppFFI links into the app: its crates, and every crate they reach through Cargo path or
        workspace dependencies (check-app-ffi-pin.sh --list-inputs), still run native and scheme."""
        for path in ("cmux-tui/crates/cmux-app-ffi/src/lib.rs", "cmux-tui/crates/cmux-layout-reducer-ffi/src/lib.rs",
                     "cmux-tui/crates/cmux-rd-ffi/src/lib.rs", "cmux-tui/crates/cmux-remote-browser/src/lib.rs",
                     "cmux-tui/rust-toolchain.toml"):
            with self.subTest(path=path):
                result = tiers([path])
                self.assertEqual(result["native"], "true")
                self.assertEqual(result["scheme"], "true")
                self.assertEqual(result["daemon"], "true")

    def test_app_ffi_inputs_match_the_pin_check(self):
        """The router's CCmuxAppFFI crates are the ones check-app-ffi-pin.sh derives."""
        import subprocess
        import cmux_next_route as route_module
        listed = subprocess.run(["bash", str(ROOT / "scripts/cmux-next/check-app-ffi-pin.sh"), "--list-inputs"],
                                check=True, capture_output=True, text=True).stdout.split()
        crates = {p + "/" for p in listed if p.startswith("cmux-tui/crates/")}
        self.assertTrue(crates)
        self.assertLessEqual(crates, set(route_module.app_ffi_inputs(ROOT)))

    def test_rust_an_app_scheme_build_phase_reads_runs_the_scheme_compile(self):
        """The diff sidecar and mobile host phases build crates of their own; those still compile the scheme."""
        for path in ("cmux-tui/crates/cmux-git/src/lib.rs", "cmux-tui/crates/cmux-wg/src/lib.rs", "cmux-tui/Cargo.lock"):
            with self.subTest(path=path):
                result = tiers([path])
                self.assertEqual(result["scheme"], "true")
                self.assertEqual(result["native"], "false")

    def test_a_file_a_test_reads_selects_that_test(self):
        # CmuxNextSettingsTests reads the schema. The schema is also a web-bundle input, but
        # no suite reads a built bundle (BundleInputs), so only the targets that read it run.
        import cmux_next_route as route_module
        path = "schemas/settings/settings-schema.json"
        result = tiers([path])
        selected = result["swift_targets"].split()
        # The targets that ship a bundle are pinned here, so dropping one from the router
        # fails this test instead of moving the expectation with it.
        bundles = {"CmuxNextAgentPane", "CmuxNextPages", "CmuxNextAgentActivity", "CmuxNextPalette"}
        self.assertEqual(set(route_module.BUNDLE_TARGETS), bundles)
        self.assertLessEqual(bundles, set(GRAPH["targets"]))
        self.assertEqual(selected, sorted(graph_readers(path)))
        self.assertIn("CmuxNextSettingsTests", selected)
        for name in ("CmuxNextAppTests", "CmuxNextAgentPaneTests", "CmuxNextDaemonTests", "CmuxNextMobileTests"):
            self.assertNotIn(name, selected)
        self.assertEqual(result["native"], "true", "the compiles still ship the schema's bundles")

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

        # The warm-sources table is read only by its Linux guard test.
        result = tiers([".github/warm-sources.json", "tests/test_ci_warm_sources.py"])
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


class UnreadDocs(unittest.TestCase):
    """A design note under a directory a test reads only through an interpolated literal
    ("plans/cmux-next/\\(name)") needs no Mac tier; one a test or generator names keeps its tiers."""

    @classmethod
    def setUpClass(cls):
        import cmux_next_route as route_module
        cls.route = route_module

    def test_a_design_note_alone_runs_no_mac_tier(self):
        """#28326 at 5d76d56f changed only plans/cmux-next/sidebar-owner.md (+3 lines) and queued the
        fast tier and swift test (CmuxNextActionsTests, CmuxNextAppTests) behind a full Mac queue. Tests
        name the file only in comments; the reads are planURL("plans/cmux-next/\\(name)") helpers."""
        result = tiers(["plans/cmux-next/sidebar-owner.md"])
        self.assertEqual(mac_tiers(result), [])
        self.assertEqual(result["macos"], "false")
        self.assertEqual(result["swift_targets"], "")

    def test_a_note_beside_swift_keeps_the_swift_route(self):
        result = tiers(["plans/cmux-next/sidebar-owner.md", *PR_17470])
        self.assertEqual(result, tiers(PR_17470))

    def test_a_named_doc_keeps_its_tiers(self):
        """actions.md is a generated export (generated_outputs.py) that ActionSurfaceParityTests names."""
        result = tiers(["plans/cmux-next/actions.md"])
        self.assertEqual(result["generated"], "true")
        self.assertIn("CmuxNextActionsTests", result["swift_targets"].split())
        with mock.patch.object(self.route, "generated_output", return_value=False):
            self.assertIn("CmuxNextActionsTests", tiers(["plans/cmux-next/actions.md"])["swift_targets"].split())

    def test_non_doc_files_keep_the_directory_read(self):
        """Only docs are narrowed: a JSON or text file there may be read by a computed name."""
        for path in ("plans/cmux-next/not-a-real-file.json", "plans/cmux-next/notes.txt"):
            with self.subTest(path=path):
                self.assertIn("swift", mac_tiers(tiers([path])))

    def _fixture(self, sources: dict[str, str]) -> tuple[Path, dict]:
        import tempfile
        root = Path(tempfile.mkdtemp(prefix="unread-doc-"))
        for name, text in sources.items():
            (root / "Tests/T").mkdir(parents=True, exist_ok=True)
            (root / "Tests/T" / name).write_text(text, encoding="utf-8")
        graph = {"targets": {"T": {"kind": "test", "path": "Tests/T", "reads": ["plans/x/"]}}}
        self.route.source_literals.cache_clear()
        self.route.generated_output.cache_clear()
        self.addCleanup(self.route.source_literals.cache_clear)
        self.addCleanup(self.route.generated_output.cache_clear)
        return root, graph

    def test_literals_decide_whether_a_doc_is_read(self):
        helper = 'func url(_ n: String) -> URL { URL(fileURLWithPath: "plans/x/\\(n)") }\n'
        cases = (
            ({"A.swift": helper + "/// see plans/x/note.md\n"}, True),
            ({"A.swift": helper, "B.swift": 'let u = url("note.md")\n'}, False),
            ({"A.swift": 'let all = list("plans/x")\n'}, False),
            ({"A.swift": 'let u = URL(fileURLWithPath: "../../plans/x/note.md")\n'}, False),
        )
        for sources, unread in cases:
            with self.subTest(sources=sources):
                root, graph = self._fixture(sources)
                with mock.patch.object(self.route, "generated_output", return_value=False):
                    self.assertEqual(self.route.unread_doc(root, graph, "plans/x/note.md", []), unread)

    def test_a_doc_no_directory_read_covers_routes_as_before(self):
        root, graph = self._fixture({"A.swift": "let a = 1\n"})
        with mock.patch.object(self.route, "generated_output", return_value=False):
            self.assertFalse(self.route.unread_doc(root, graph, "plans/y/note.md", []))
            self.assertFalse(self.route.unread_doc(root, graph, "Packages/iOS/Kit/README.md", []))

    def test_unreadable_sources_or_outputs_keep_the_read(self):
        root, graph = self._fixture({})
        self.assertFalse(self.route.unread_doc(root, graph, "plans/x/note.md", []))
        root, graph = self._fixture({"A.swift": "let a = 1\n"})
        self.assertFalse(self.route.unread_doc(root, graph, "plans/x/note.md", []), "no generated_outputs.py there")


class BundleInputs(unittest.TestCase):
    """A web bundle source (BUNDLE_INPUTS) runs the compiles that ship the bundles, and swift test only for
    the test targets that read the file itself: no suite reads a built bundle's content."""

    @classmethod
    def setUpClass(cls):
        import cmux_next_route as route_module
        cls.route = route_module

    # Page JavaScript a suite runs, and the ways a suite gives the page its own document.
    TALKS_TO_PAGE = re.compile(r"\b(?:evaluateJavaScript|callAsyncJavaScript|waitUntilLoaded|WKUserScript)\b")
    OWN_DOCUMENT = re.compile(r'loadHTMLString|registerBundledRoot|allowFixtureRoot|AgentPageTestRoot'
                              r'|source:\s*\.bundled\(|index\.html|\.html"')
    OPT_IN = re.compile(r"\.enabled\(if:\s*ProcessInfo\.processInfo\.environment\[")

    def test_the_bundle_targets_are_the_ones_the_bundle_build_writes_into(self):
        """BUNDLE_TARGETS is every CmuxNext target build-web-bundles.sh writes a bundle into, each taking it as
        a resource; a new bundle target fails here until the router (and the check below) place it."""
        script = (ROOT / "scripts/cmux-next/build-web-bundles.sh").read_text(encoding="utf-8")
        outputs = dict(re.findall(rf'="{PACKAGE}/Sources/(\w+)/(Resources[^"]*)"', script))
        self.assertEqual(set(outputs), set(self.route.BUNDLE_TARGETS))
        manifest = (ROOT / PACKAGE / "Package.swift").read_text(encoding="utf-8")
        for target, output in outputs.items():
            with self.subTest(target=target):
                start = re.search(rf'\.target\(\s*name:\s*"{target}"', manifest)
                self.assertIsNotNone(start)
                arguments = call_arguments(manifest, start.end())
                resources = re.findall(r'\.(?:copy|process)\("([^"]+)"\)', manifest[start.end():start.end() + 2000])
                self.assertIn("resources", arguments)
                self.assertTrue(any(output == r or output.startswith(r.rstrip("/") + "/") for r in resources),
                                f"{target} does not take {output} as a resource: {resources}")

    def test_no_suite_runs_page_javascript_on_a_built_bundle(self):
        """Why a bundle source runs no swift test. In every test target that links a bundle target, a suite
        that runs page JavaScript loads its own document (a fixture page, loadHTMLString, a scratch root) or is
        an opt-in bench swift test does not run. A suite that needs a built page must route BUNDLE_INPUTS to
        its target again (cmux_next_route.py) before it lands."""
        reaching = graph_dependents(set(self.route.BUNDLE_TARGETS))
        self.assertIn("CmuxNextAppTests", reaching)
        offenders, talking = [], 0
        for name in sorted(reaching):
            for source in sorted((ROOT / GRAPH["targets"][name]["path"]).rglob("*.swift")):
                code = "\n".join(line for line in source.read_text(encoding="utf-8").splitlines()
                                 if not line.lstrip().startswith(("//", "/*", "*")))
                if not self.TALKS_TO_PAGE.search(code):
                    continue
                talking += 1
                if not (self.OWN_DOCUMENT.search(code) or self.OPT_IN.search(code)):
                    offenders.append(str(source.relative_to(ROOT)))
        self.assertGreater(talking, 5, "the scan found no suite that runs page JavaScript")
        self.assertEqual(offenders, [])

    def test_a_bundle_source_alone_runs_the_compiles_but_no_swift_test(self):
        """#28272, #27930: agent pane sources reach all four bundle targets' resources, and no test reads them."""
        for changed in (["webviews/src/agent-session/acpmux/sessionPages.ts", "mux/host/src/acpmux-client.ts"],
                        ["webviews/src/agent-session/acpmux/subagents/SubagentTray.tsx",
                         "scripts/cmux-next/media/states/subagent-tray.json"],
                        ["scripts/cmux-next/build-pages-web.sh"]):
            with self.subTest(changed=changed):
                result = tiers(changed)
                self.assertEqual(result["native"], "true", "the compiles ship the bundles")
                self.assertEqual(result["swift"], "false")
                self.assertEqual(result["generated"], "false")
                self.assertEqual(result["swift_targets"], "")
                self.assertEqual(result["fast_tier"], "false")

    def test_what_still_runs_swift_test(self):
        """A file a test names, a Swift bridge source and a shared fixture keep their suites."""
        cases = {
            # The Swift half of the page bridge: its own target and every test target above it.
            f"{PACKAGE}/Sources/CmuxNextPages/PageSchemeHandler.swift": "CmuxNextPagesTests",
            f"{PACKAGE}/Sources/CmuxNextAgentPane/AgentPaneView.swift": "CmuxNextAgentPaneTests",
            # A webviews fixture an app suite reads (NewTabIntentTableTests).
            "webviews/test/fixtures/new-tab-intents.json": "CmuxNextAppTests",
            # The dev server's entries (PageDevServerTests): a page's main.tsx.
            "webviews/src/pages/settings/main.tsx": "CmuxNextPagesTests",
            # Read by CmuxNextSettingsTests as well as built into the bundles.
            "schemas/settings/settings-schema.json": "CmuxNextSettingsTests",
        }
        for path, target in cases.items():
            with self.subTest(path=path):
                result = tiers([path])
                self.assertEqual(result["swift"], "true")
                self.assertIn(target, result["swift_targets"].split())

    def test_a_pattern_read_selects_only_what_it_matches(self):
        """The graph records a test's `*` literal as a pattern read (ci-target-graph.py glob_read)."""
        graph = json.loads(json.dumps(GRAPH))
        reads = graph["targets"]["CmuxNextPagesTests"]["reads"]
        graph["targets"]["CmuxNextPagesTests"]["reads"] = [
            read for read in reads if read != "webviews/src/pages/"] + ["webviews/src/pages/*/main.tsx"]
        with mock.patch.object(self.route, "load_graph", return_value=graph):
            entry = tiers(["webviews/src/pages/settings/main.tsx"])
            self.assertEqual(entry["swift_targets"].split(), ["CmuxNextPagesTests"])
            inside = tiers(["webviews/src/pages/settings/components/ThemePicker.tsx",
                            "webviews/src/pages/settings/layout.css"])
            self.assertEqual(mac_tiers(inside), [], "a page-internal edit is a web nit: ci-web covers it")
        self.assertTrue(self.route.matches("webviews/src/pages/a/b/main.tsx", "webviews/src/pages/*/main.tsx"),
                        "fnmatch's * crosses /: a pattern read is never narrower than the test")
        self.assertFalse(self.route.matches("webviews/src/pages/a/App.tsx", "webviews/src/pages/*/main.tsx"))

    def test_the_dev_server_test_reads_only_the_page_entries(self):
        """PageDevServerTests names its entries by a pattern, which the graph generator records."""
        spec = importlib.util.spec_from_file_location("ci_target_graph_for_route", ROOT / "scripts/cmux-next/ci-target-graph.py")
        generator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(generator)
        reads = generator.literal_reads(ROOT / PACKAGE / "Tests/CmuxNextPagesTests")
        self.assertIn("webviews/src/pages/*/main.tsx", reads)
        self.assertNotIn("webviews/src/pages/", reads)


class FastTierRoute(unittest.TestCase):
    """The Mac fast tier (fast-tier.json's swift entries) builds the CmuxNext package and runs a few of
    its suites. It runs when that build or those suites can change, and not for a change only the
    daemon or the app scheme sees."""

    def test_package_and_test_inputs_run_it(self):
        for changed in (PR_17470,
                        ["Packages/Shared/CmuxTheme/Package.swift"],
                        ["Packages/Shared/CmuxHomeRender/Sources/CmuxHomeRender/x.swift"],
                        ["scripts/cmux-next/fast-tier.json"],
                        ["scripts/cmux-next/quarantine.json"],
                        [".github/actions/cache-restore/action.yml"],
                        [".xcode-version"]):
            with self.subTest(changed=changed):
                self.assertEqual(tiers(changed)["fast_tier"], "true")

    def test_a_file_its_suites_targets_read_runs_it(self):
        """cmux-tui/spec/ is read by CmuxNextAgentPaneTests, which holds AgentSubagentPanesFocusTests."""
        result = tiers(["cmux-tui/crates/acpmux/src/rpc.rs", "cmux-tui/spec/sdk-schema.json"])
        self.assertEqual(result["swift"], "true")
        self.assertEqual(result["fast_tier"], "true")

    def test_web_bundle_inputs_beside_rust_skip_it(self):
        """#28160 and #28015: acpmux Rust and the pane's protocol types. The fast tier job builds no
        bundle, and no suite reads one (BundleInputs): the daemon tier and the compiles carry them."""
        for changed in (["cmux-tui/crates/acpmux/src/rpc.rs", "webviews/src/agent-session/acpmux/direct.ts",
                         "webviews/src/agent-session/acpmux/protocol/generated/methods.ts"],
                        ["cmux-tui/crates/acpmux/src/lib.rs",
                         "webviews/src/agent-session/acpmux/protocol/generated/types.ts"]):
            with self.subTest(changed=changed):
                result = tiers(changed)
                self.assertEqual(result["fast_tier"], "false")
                self.assertEqual(result["swift"], "false")
                self.assertEqual(result["daemon"], "true")
                self.assertEqual(result["native"], "true")
        # Read only by CmuxNextSettingsTests (no fast tier suite) and a bundle input.
        result = tiers(["schemas/settings/settings-schema.json"])
        self.assertEqual((result["swift"], result["fast_tier"]), ("true", "false"))

    def test_app_ffi_sources_keep_swift_test_but_not_it(self):
        """The package links CCmuxAppFFI as a pinned binary (a URL and checksum in Package.swift), so its
        Rust sources reach the fast tier's build only through a new pin, which runs every tier."""
        self.assertEqual(GRAPH["targets"]["CCmuxAppFFI"]["kind"], "binary")
        result = tiers(["cmux-tui/crates/cmux-app-ffi/src/lib.rs"])
        self.assertEqual(result["native"], "true")
        self.assertEqual(result["swift"], "true")
        self.assertEqual(result["fast_tier"], "false")
        self.assertEqual(tiers([f"{PACKAGE}/Package.swift"])["fast_tier"], "true")

    def test_an_action_only_swift_test_runs_skips_it(self):
        result = tiers([".github/actions/setup-cmux-tui-rust/action.yml"])
        self.assertEqual(result["swift"], "true")
        self.assertEqual(result["fast_tier"], "false")

    def test_every_suite_is_placed_in_a_test_target(self):
        """An unplaced suite makes every test target's reads run the tier (safe, but wide): keep them placed."""
        import cmux_next_route as route_module
        scope = route_module.fast_tier_scope(ROOT, GRAPH)
        self.assertIsNotNone(scope.targets)
        self.assertIn(PACKAGE + "/", scope.packages)

    def test_the_fast_tier_job_builds_no_web_bundle(self):
        """Why a bundle input alone skips it. A fast tier that builds or fetches the bundles reads their
        sources: route BUNDLE_INPUTS to it again before adding such a step."""
        import yaml
        workflow = yaml.load((ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8"), Loader=yaml.BaseLoader)
        job = json.dumps(workflow["jobs"]["fast-tier"])
        runner = (ROOT / "scripts/cmux-next/fast-tier.py").read_text(encoding="utf-8")
        for text in (job, runner):
            for needle in ("build-web-bundles", "fetch-web-bundles", "web-bundle", "webviews"):
                self.assertNotIn(needle, text)

    def test_daemon_or_app_host_only_changes_skip_it(self):
        for changed in (["cmux-tui/crates/acpmux/src/cli/help_examples/session.rs"],
                        ["cmux-tui/crates/acpmux/src/hub/queue.rs", "cmux-tui/crates/acpmux/src/hub/transfer_out.rs"],
                        ["Native/OptChat/optchat-chief/tests/harness.rs"],
                        ["App/main.swift"]):
            with self.subTest(changed=changed):
                result = tiers(changed)
                self.assertEqual(result["macos"], "true")
                self.assertEqual(result["fast_tier"], "false")

    def test_web_and_ci_only_changes_skip_it(self):
        for changed in (["web/app/page.tsx"], ["scripts/ci/cmux_next_route.py"], ["plans/cmux-next/sidebar-owner.md"]):
            with self.subTest(changed=changed):
                self.assertEqual(tiers(changed)["fast_tier"], "false")

    def test_every_tier_runs_it(self):
        self.assertEqual(tiers([], event="push")["fast_tier"], "true")
        self.assertEqual(tiers(["cmux-tui/crates/acpmux/src/hub/queue.rs"], labels=frozenset({"full-ci"}))["fast_tier"], "true")
        self.assertEqual(tiers(["scripts/cmux-next/cef-manifest.json"])["fast_tier"], "true")


class WorkflowRoute(unittest.TestCase):
    """A change to cmux-next.yml runs every tier unless, against its base, it leaves every Mac job and
    every job one needs as it was."""

    HEAD = (ROOT / ".github/workflows/cmux-next.yml").read_text(encoding="utf-8")

    def route_with_base(self, base: str, changed=(".github/workflows/cmux-next.yml",)) -> dict[str, str]:
        return outputs(route(ROOT, "pull_request", list(changed), set(), base))

    def base_without(self, old: str, new: str) -> str:
        self.assertEqual(self.HEAD.count(old), 1, old)
        return self.HEAD.replace(old, new)

    def test_paths_filter_only_runs_no_mac_tier(self):
        """#28459: its cmux-next.yml change was one more `on:` path."""
        result = self.route_with_base(self.base_without("    paths:\n      - App/**\n", "    paths:\n"),
                                      [".github/workflows/cmux-next.yml", "tests/test_intent_familiar_warning.py"])
        for tier in ("macos", "fast_tier", "swift", "native", "full"):
            self.assertEqual(result[tier], "false", tier)

    def test_a_linux_job_no_mac_job_needs_runs_no_mac_tier(self):
        base = self.base_without("    name: cmux-next checks (god files, concurrency, crash safety, l10n)",
                                 "    name: cmux-next checks (old)")
        self.assertEqual(self.route_with_base(base)["macos"], "false")

    def test_a_portable_placement_runner_reads_as_linux_and_no_other_output_does(self):
        """checks takes a free mini through portable placement; it runs no Mac tier there, so an edit to it
        runs none. Any other job output may still name a Mac."""
        import cmux_next_route as route_module
        portable = ("vars.CI_X && needs.portable-placement.outputs.mini_runner || "
                    "needs.portable-placement.outputs.linux_runner || 'blacksmith-16vcpu-ubuntu-2404'")
        self.assertTrue(route_module.linux_values(portable))
        self.assertFalse(route_module.linux_values(portable.replace("portable-placement", "macos-placement")))

    def test_a_swift_change_beside_it_routes_as_without_it(self):
        swift = f"{PACKAGE}/Sources/CmuxNextApp/WorkspaceSpawn.swift"
        result = self.route_with_base(self.base_without("    paths:\n      - App/**\n", "    paths:\n"),
                                      [".github/workflows/cmux-next.yml", swift])
        alone = tiers([swift])
        self.assertEqual(result["full"], "false")
        # The canary gates only a diff of nothing but CmuxNext Swift sources; every other tier is the same.
        for key in ("swift_canary", "swift_canary_targets"):
            result.pop(key), alone.pop(key)
        self.assertEqual(result, alone)

    def test_a_job_a_mac_job_runs_or_needs_runs_every_tier(self):
        """Path routing, placement, the web bundles and the fast tier feed or are Mac jobs WORKFLOW_JOB_TIERS
        does not place: a change to one runs every tier."""
        for old, new in (("    name: cmux-next path routing", "    name: cmux-next path routing (old)"),
                         ("    name: cmux-next web bundles (source-keyed cache)", "    name: old bundles"),
                         ("    name: cmux-next fast tier\n", "    name: old fast tier\n")):
            with self.subTest(job=new):
                self.assertEqual(self.route_with_base(self.base_without(old, new))["full"], "true")
        for job in ("macos-placement", "swift-canary-fleet", "push-head-preflight"):
            with self.subTest(job=job):
                self.assertEqual(self.route_with_base(self.base_with_job_edited(job))["full"], "true")

    def base_with_job_edited(self, job: str) -> str:
        """The head workflow with only `job`'s own timeout-minutes changed: a base that differs in that job."""
        start = re.search(rf"^  {re.escape(job)}:\n", self.HEAD, re.M)
        self.assertIsNotNone(start, job)
        end = re.compile(r"^  [\w-]+:\n", re.M).search(self.HEAD, start.end())
        block = self.HEAD[start.start():end.start() if end else len(self.HEAD)]
        edited, count = re.subn(r"^    timeout-minutes: (\d+)$", lambda m: f"    timeout-minutes: {int(m.group(1)) + 1}",
                                block, count=1, flags=re.M)
        self.assertEqual(count, 1, f"{job} has no job-level timeout-minutes")
        return self.HEAD.replace(block, edited)

    def test_a_change_to_the_swift_test_job_runs_swift_test_on_every_target(self):
        """#5424: a change to how swift test runs ran the daemon suites and every compile too. It runs the
        swift test job on every CmuxNext test target (and the generated-files check it folds in), not the rest."""
        result = self.route_with_base(self.base_with_job_edited("swift-test"))
        for tier in ("swift", "generated", "macos"):
            self.assertEqual(result[tier], "true", tier)
        self.assertEqual((result["swift_targets"], result["swift_filter"]), ("all", ""))
        for tier in ("daemon", "native", "scheme", "mac_release", "fast_tier", "full"):
            self.assertEqual(result[tier], "false", tier)

    def test_a_change_to_one_mac_job_runs_that_job_s_tiers(self):
        cases = {
            "daemon-test": ({"daemon", "generated"}, {"swift", "native", "scheme", "mac_release"}),
            "generated-files": ({"generated"}, {"swift", "daemon", "native", "scheme"}),
            "release-compile": ({"native", "mac_release"}, {"swift", "daemon", "generated", "scheme"}),
            "app-compile-fleet": ({"native"}, {"swift", "daemon", "generated", "scheme", "mac_release"}),
            "cmux-scheme-compile": ({"native", "scheme"}, {"swift", "daemon", "generated", "mac_release"}),
        }
        for job, (run, skip) in cases.items():
            with self.subTest(job=job):
                result = self.route_with_base(self.base_with_job_edited(job))
                self.assertEqual({tier for tier in run | skip if result[tier] == "true"}, run)
                self.assertEqual((result["full"], result["swift_targets"]), ("false", ""))

    def test_a_job_no_pull_request_runs_adds_no_tier(self):
        """#26896 changed only the DEV landing compile, which runs on feat-cmux-next pushes: its pull request
        ran every tier and still never ran that job. The base push runs it."""
        for job in ("dev-landing-compile", "dev-landing-place", "release-compile-fast", "request-nightly-next"):
            with self.subTest(job=job):
                result = self.route_with_base(self.base_with_job_edited(job) if job != "request-nightly-next"
                                              else self.base_without("  request-nightly-next:\n", "  request-nightly-next:\n    continue-on-error: false\n"))
                for tier in ("macos", "swift", "daemon", "native", "full"):
                    self.assertEqual(result[tier], "false", tier)

    def test_jobs_beside_one_another_take_both_tiers(self):
        base = self.base_with_job_edited("swift-test")
        self.HEAD, head = base, self.HEAD  # edit the daemon job on top of the swift test one
        try:
            base = self.base_with_job_edited("daemon-test")
        finally:
            self.HEAD = head
        result = self.route_with_base(base)
        self.assertEqual({tier for tier in ("swift", "daemon", "generated", "native") if result[tier] == "true"},
                         {"swift", "daemon", "generated"})

    def test_a_changed_if_or_an_added_job_runs_every_tier(self):
        """A listed job's `if:` decides when it runs on every route, and a new or removed job is not listed."""
        job = yaml_jobs(self.HEAD)["swift-test"]
        self.assertEqual(self.HEAD.count(f"    if: {job['if']}\n"), 1)
        changed_if = self.HEAD.replace(f"    if: {job['if']}\n", "    if: ${{ needs.path_route.outputs.swift == 'true' }}\n")
        self.assertEqual(self.route_with_base(changed_if)["full"], "true")
        start = self.HEAD.index("  swift-test:\n")
        removed = self.HEAD[:start] + self.HEAD[start:].replace("  swift-test:\n", "  swift-test-old:\n", 1)
        self.assertEqual(self.route_with_base(removed)["full"], "true")

    def test_a_job_change_beside_other_files_keeps_their_tiers(self):
        rust = "cmux-tui/crates/acpmux/src/hub/queue.rs"
        result = self.route_with_base(self.base_with_job_edited("cmux-scheme-compile"),
                                      [".github/workflows/cmux-next.yml", rust])
        alone = tiers([rust])
        self.assertEqual(result["daemon"], alone["daemon"])
        self.assertEqual((result["native"], result["scheme"], result["swift"]), ("true", "true", alone["swift"]))

    def test_the_job_tiers_cover_what_each_job_gates_on(self):
        """Each WORKFLOW_JOB_TIERS job is a Mac job of cmux-next.yml, and its tiers include every tier output
        its `if:` reads, so the tiers a change to it selects make that job run."""
        from cmux_next_route import WORKFLOW_JOB_TIERS, WORKFLOW_TIER_FIELDS, Route, linux_job
        jobs = yaml_jobs(self.HEAD)
        for job, job_tiers in WORKFLOW_JOB_TIERS.items():
            with self.subTest(job=job):
                self.assertIn(job, jobs)
                self.assertFalse(linux_job(jobs[job], ROOT), f"{job} runs only on Linux")
                self.assertTrue(set(job_tiers) <= set(WORKFLOW_TIER_FIELDS) and all(hasattr(Route(), t) for t in job_tiers))
                read = set(re.findall(r"needs\.path_route\.outputs\.(\w+)", str(jobs[job].get("if", ""))))
                self.assertLessEqual(read & set(WORKFLOW_TIER_FIELDS), set(job_tiers))

    def test_never_on_pull_request(self):
        from cmux_next_route import never_on_pull_request
        jobs = yaml_jobs(self.HEAD)
        for job in ("dev-landing-place", "dev-landing-compile", "release-compile-fast", "request-nightly-next",
                    "request-cmux-next-dev-publish", "dev-daily-tree-wait", "dev-daily-place"):
            self.assertTrue(never_on_pull_request(job, jobs), job)
        for job in ("swift-test", "daemon-test", "generated-files", "release-compile", "app-compile-fleet",
                    "cmux-scheme-compile", "fast-tier", "macos-placement", "path_route", "web-bundles"):
            self.assertFalse(never_on_pull_request(job, jobs), job)
        synthetic = {
            "push": {"if": "${{ !cancelled() && github.event_name == 'push' }}"},
            "either": {"if": "${{ github.event_name == 'push' || github.event_name == 'pull_request' }}"},
            "grouped": {"if": "${{ (github.event_name == 'push' && a || inputs.dev_daily == true) && b }}"},
            "half": {"if": "${{ (github.event_name == 'push' || b) && c }}"},
            "after": {"needs": ["push"], "if": "${{ needs.push.result == 'success' }}"},
            "unlisted": {"if": "${{ needs.push.result == 'success' }}"},
            "maybe": {"needs": "push", "if": "${{ always() && needs.push.result != 'success' }}"},
            "none": {}, "nested": {"if": "${{ github.event_name == 'push' && ${{ x }} }}"},
        }
        self.assertEqual({name for name in synthetic if never_on_pull_request(name, synthetic)},
                         {"push", "grouped", "after"})


    def test_top_level_env_runs_every_tier(self):
        base = self.base_without("  CI_CACHE_R2_PUBLIC_URL: ${{ vars.CI_CACHE_R2_PUBLIC_URL || 'https://ci-cache.cmux.com' }}",
                                 "  CI_CACHE_R2_PUBLIC_URL: https://old.example")
        self.assertEqual(self.route_with_base(base)["full"], "true")

    def test_an_unknown_or_unreadable_base_runs_every_tier(self):
        self.assertEqual(self.route_with_base(None)["full"], "true")
        self.assertEqual(self.route_with_base("jobs: [")["full"], "true")
        self.assertEqual(self.route_with_base("name: no jobs\n")["full"], "true")

    def test_linux_runs_on(self):
        from cmux_next_route import linux_runs_on
        linux = ("ubuntu-24.04",
                 "${{ github.repository_owner != 'manaflow-ai' && 'ubuntu-24.04' || vars.CI_CLOUD_OVERFLOW_SAVED && 'blacksmith-16vcpu-ubuntu-2404' || 'blacksmith-4vcpu-ubuntu-2404' }}",
                 "${{ !startsWith(vars.LINUX_RUNNER, 'blacksmith-') && vars.LINUX_RUNNER || 'blacksmith-32vcpu-ubuntu-2404' }}")
        mac = ("macos-26", None, "", "${{ needs.macos-placement.outputs.runner }}",
               "${{ vars.MACOS_RUNNER_26 || 'blacksmith-6vcpu-ubuntu-2404' }}",
               "${{ github.event_name == 'push' && 'ubuntu-24.04' || 'glaeda-gui-std-xcode-26.6' }}",
               "${{ inputs.runner || 'ubuntu-24.04' }}",
               "${{ github.event_name == 'push' && 'ubuntu-24.04' || github.event.inputs.label }}",
               "${{ vars.X && 'ubuntu-24.04' || format('{0}', needs.a.outputs.runner) }}",
               "${{ (vars.X && 'ubuntu-24.04' || needs.a.outputs.runner) }}",
               "blacksmith-${{ vars.LINUX_RUNNER }}")
        for value in linux:
            self.assertTrue(linux_runs_on(value), value)
        for value in mac:
            self.assertFalse(linux_runs_on(value), value)


def yaml_jobs(text: str) -> dict:
    import yaml
    return yaml.load(text, Loader=yaml.BaseLoader)["jobs"]


class RunnerAndScriptRoutes(unittest.TestCase):
    """#5424 fix 3: a pull request of workflows, scripts or tests runs swift test and the daemon suites only
    when a Swift target or one of those jobs reads what it changed."""

    def test_an_unrelated_workflow_runs_no_mac_tier(self):
        result = tiers([".github/workflows/ci-web.yml"])
        for tier in ("macos", "swift", "daemon", "native"):
            self.assertEqual(result[tier], "false", tier)

    def test_a_python_only_script_runs_no_swift_test_or_daemon(self):
        for script in ("scripts/ci/owned_pool_rescue.py", "scripts/cmux-next/gen-layout-grid.py"):
            with self.subTest(script=script):
                result = tiers([script])
                self.assertEqual((result["swift"], result["daemon"], result["full"]), ("false", "false", "false"))

    def test_scripts_the_swift_test_and_daemon_jobs_run_or_tests_read_keep_them(self):
        self.assertEqual(tiers(["scripts/cmux-next/swift-test-with-hang-sampler.sh"])["full"], "true")
        self.assertEqual(tiers(["scripts/cmux-next/tests/bundle-server-helper.test.sh"])["swift"], "true")
        pin = tiers(["scripts/cmux-next/pin-cmux-tui.sh"])
        self.assertEqual((pin["swift"], pin["daemon"]), ("true", "true"))
        self.assertEqual(tiers(["scripts/cmux-next/check-daemon-capabilities.sh"])["daemon"], "true")

    def test_a_script_a_build_phase_runs_keeps_the_compiles_not_swift_test(self):
        for script in ("scripts/build-diff-sidecar.sh", "scripts/cmux-next/build-mobile-host.sh",
                       "scripts/cmux-next/build-web-bundles.sh"):
            with self.subTest(script=script):
                result = tiers([script])
                self.assertEqual((result["native"], result["swift"], result["daemon"]), ("true", "false", "false"))

    def test_a_rust_only_change_runs_the_daemon_tier_not_swift_test(self):
        result = tiers(["cmux-tui/crates/acpmux/src/hub/queue.rs"])
        self.assertEqual((result["daemon"], result["swift"], result["native"]), ("true", "false", "false"))


class PushAttribution(unittest.TestCase):
    def test_repeated_push_failures_edit_the_shared_status_comment(self):
        import cmux_next_push_attribution as attribution
        import pr_status

        comments = [{"id": 1, "user": {"login": pr_status.BOT},
                     "body": pr_status.render({"checks": "Existing check evidence"})},
                    {"id": 2, "user": {"login": pr_status.BOT},
                     "body": "<!-- cmux-next-push-attribution:10 -->\nOld failure"}]
        writes = []

        def api(method, path, payload):
            if method == "GET":
                return comments
            writes.append((method, path))
            number = int(path.rsplit("/", 1)[-1])
            if method == "PATCH":
                next(c for c in comments if c["id"] == number)["body"] = payload["body"]
            elif method == "DELETE":
                comments[:] = [c for c in comments if c["id"] != number]
            else:
                self.fail(f"unexpected timeline comment: {method} {path}")

        real_upsert = pr_status.upsert
        def upsert(*args, **kwargs):
            return real_upsert(*args, **kwargs, api=api, sleep=None)

        with mock.patch.object(attribution, "run_jobs", return_value={"check": "failure"}), \
             mock.patch.object(attribution, "gh_api", side_effect=lambda path: comments if "/comments" in path else {"workflow_runs": []}), \
             mock.patch.object(attribution, "never_passed", return_value=[]), \
             mock.patch.object(attribution, "last_green", return_value="good"), \
             mock.patch.object(attribution, "pull_requests", return_value=[7]), \
             mock.patch.object(pr_status, "upsert", side_effect=upsert):
            for run_id in (11, 12, 12):
                self.assertEqual(attribution.main(["--repo", "o/r", "--run-id", str(run_id),
                                                   "--sha", "head"]), 0)
        self.assertEqual([method for method, _ in writes], ["PATCH", "DELETE", "PATCH"])
        self.assertEqual(len(comments), 1)
        sections = pr_status.parse(comments[0]["body"])
        self.assertEqual(sections["checks"], "Existing check evidence")
        self.assertIn("<!-- cmux-next-push-attribution:12 -->", sections["push-attribution"])

    def test_a_base_tier_run_starts_the_range_at_the_commit_it_tested(self):
        """cmuxterm-hq#5424: the base Mac tier runs in `cmux-next base tier · <sha>` dispatches. Its
        same-tree run's head_sha is the branch tip when it started, not the commit it tested, so the
        range since the last pass starts at the sha in the run's name."""
        import cmux_next_push_attribution as attribution

        tested, newer, red = "a" * 40, "b" * 40, "c" * 40
        runs = [{"id": 30, "head_sha": newer, "status": "completed", "display_title": f"cmux-next base tier · {tested}"},
                {"id": 20, "head_sha": "d" * 40, "status": "completed", "display_title": "cmux-next · " + "d" * 40}]
        self.assertEqual(attribution.tested_sha(runs[0]), tested)
        self.assertEqual(attribution.tested_sha({"head_sha": newer, "display_title": "cmux NEXT DEV daily"}), newer)
        jobs = {40: {"cmux-next daemon tests": "failure"}, 30: {"cmux-next daemon tests": "success"},
                20: {"cmux-next daemon tests": "skipped"}}
        ranges = []
        with mock.patch.object(attribution, "run_jobs", side_effect=lambda repo, run_id: jobs[run_id]), \
             mock.patch.object(attribution, "gh_api", return_value={"workflow_runs": runs}), \
             mock.patch.object(attribution, "pull_requests",
                               side_effect=lambda repo, good, head, branch: ranges.append((good, head)) or []):
            self.assertEqual(attribution.main(["--repo", "o/r", "--run-id", "40", "--sha", red,
                                               "--events", "push,workflow_dispatch"]), 0)
        self.assertEqual(ranges, [(tested, red)])

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
