#!/usr/bin/env python3
"""Route a feat-cmux-next pull request to the cmux-next checks its change can break.

Every check in .github/workflows/cmux-next.yml has a tier, and a pull request
runs the tiers its changed files reach (docs/ci/cmux-next-tiers.md):

  checks      always: god files, concurrency, crash safety, string tables,
              script tests, package conventions (Linux, about a minute)
  generated   any change to the CmuxNext package, plans/cmux-next or a settings
              export: the generated action catalog, surfaces and inventory, the
              CI target graph and the settings exports are fresh (a mini; a
              stale file is fixed by a bot commit)
  native      Swift or app sources: the Release compile
  canary      changed CmuxNext Swift targets type-check on a warm mini; this
              is the pull-request gate for small package-only Swift diffs
  scheme      app host, Xcode project, webviews or other local packages: the
              Debug compile of the cmux app scheme
  swift       the CmuxNext test targets the change can affect, from the SwiftPM
              target graph (Packages/macOS/CmuxNext/ci-target-graph.json)
  daemon      the daemon, Rust core, FFI or control paths: the same-tree
              cmux-tui fetch and the live-daemon suites

Pushes, dispatches and pull requests labeled `full-ci` run every tier. The
workflow runs the tiers picked here on every same-repository pull request; a
fork pull request runs the heavier Mac tiers only with `full-ci`. A changed file this script cannot place selects every
tier, so an unknown input never skips a check.

Usage: cmux_next_route.py --event NAME [--changed-files FILE] [--labels a,b]
       [--github-output FILE] [--summary FILE]
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from select_package_tests import input_prefixes, package_dirs, under  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
PACKAGE = "Packages/macOS/CmuxNext/"
GRAPH = PACKAGE + "ci-target-graph.json"
TREE_INPUTS = "scripts/cmux-next/cmux-tui-tree-inputs.txt"

# Inputs of every package test: the manifest, the graph, the test runner and
# the workflow. A change selects every tier.
FULL_INPUTS = (
    PACKAGE + "Package.swift",
    PACKAGE + "Package.resolved",
    GRAPH,
    ".github/workflows/cmux-next.yml",
    "scripts/ci/cmux_next_route.py",
    "scripts/ci/select_package_tests.py",
    "scripts/cmux-next/ci-target-graph.py",
    "scripts/cmux-next/swift-test-with-hang-sampler.sh",
    "scripts/cmux-next/compile-string-catalogs.sh",
    "scripts/select-ci-xcode.sh",
    "scripts/ci/xcode-pins.txt",
    ".xcode-version",
)

# The binary pins NEXT vendors: GhosttyNextKit's checksum and CEF's manifest.
# A bump changes code no app diff shows (classic's #19672 passed on macOS 26
# and crashed on macOS 27), so it runs every tier and swift test on its PR.
VENDORED_PINS = (
    "Packages/Shared/CmuxGhosttyKit/Package.swift",
    "scripts/cmux-next/cef-manifest.json",
)

# The live-daemon suites (they skip without the same-tree cmux-tui) test these
# targets and everything they depend on.
LIVE_DAEMON_SUBJECTS = ("CmuxNextDaemon", "CmuxNextMobile")
# Control forwards CLI verbs to cmux-tui: its own sources reach the daemon.
DAEMON_DIRECT_TARGETS = ("CmuxNextControl", "CmuxNextDaemonTests", "CmuxNextMobileTests", "CmuxNextControlTests")
DAEMON_PATHS = (
    "plans/cmux-next/daemon-capabilities.json",
    "scripts/cmux-next/pin-cmux-tui.sh",
    "scripts/cmux-next/check-daemon-capabilities.sh",
    "scripts/cmux-next/cmux-tui.pin",
    PACKAGE + "Tests/CmuxNextAppTests/FirstLaunchTests.swift",
    # The classic import and migration suites start the live daemon too.
    PACKAGE + "Tests/CmuxNextAppTests/ClassicImportTests.swift",
    PACKAGE + "Tests/CmuxNextAppTests/ClassicMigrationTests.swift",
    PACKAGE + "Tests/CmuxNextAppTests/ClassicUpgradeSimulationTests.swift",
    PACKAGE + "Tests/CmuxNextAppTests/ClassicUpgradeHugeSimulationTests.swift",
    PACKAGE + "Tests/CmuxNextAppTests/ClassicUpgradeSimulator.swift",
    PACKAGE + "Sources/CmuxNextApp/Onboarding/AppOnboardingServices+ClassicSessions.swift",
    PACKAGE + "Sources/CmuxNextApp/Onboarding/AppOnboardingServices+ClassicMigration.swift",
)

# Scripts the swift test job runs before the package tests.
SWIFT_JOB_INPUTS = (
    "scripts/cmux-next/bundle-server-helper.sh",
    "scripts/sign-cmux-bundle-helpers.sh",
    "scripts/cmux-next/check-app-personalities.sh",
    "scripts/cmux-next/check-app-ffi-pin.sh",
    "scripts/cmux-next/tests/bundle-server-helper.test.sh",
    "scripts/cmux-next/tests/sign-cmux-bundle-helpers.test.sh",
    "tests/test_check_app_personalities.sh",
    ".github/actions/setup-cmux-tui-rust/",
    # check-app-ffi-pin.sh's sources (the pinned CCmuxAppFFI release) and the
    # sidebar layout reducer's cargo test.
    "cmux-tui/crates/cmux-app-ffi/",
    "cmux-tui/crates/cmux-focus-core/",
    "cmux-tui/crates/cmux-layout-reducer/",
    "cmux-tui/crates/cmux-layout-reducer-ffi/",
    "cmux-tui/crates/cmux-rd-core/",
    "cmux-tui/crates/cmux-rd-proto/",
    "cmux-tui/crates/cmux-rd-ffi/",
    "cmux-tui/rust-toolchain.toml",
    "scripts/cmux-next/build-app-ffi.sh",
)

# Keep the per-PR route narrow. App-host, manifest, resource and toolchain edits
# are covered by the batch Release cadence and the base-push backstop.
CANARY_SWIFT_PREFIXES = (
    PACKAGE + "Sources/",
)

GENERATED_INPUTS = (
    PACKAGE,
    "plans/cmux-next/",
    "scripts/cmux-next/regenerate-action-contracts.sh",
    "scripts/cmux-next/check-action-surfaces.sh",
    "scripts/cmux-next/judge-action-exports.sh",
    # The settings exports (regenerate-settings-exports.sh; the generated
    # files job exports them fresh and compares). The CmuxNextSettings sources
    # and the export tests are under PACKAGE.
    # (The defaults snapshot and defaults_guard.py are checked on Linux.)
    "schemas/settings/settings-schema.json",
    "docs/mdm/",
    "scripts/cmux-next/regenerate-settings-exports.sh",
    "scripts/cmux-next/check-settings-exports.sh",
    "scripts/cmux-next/settings-exports.txt",
)

# The PR's Mac Release compile (check-release-compile.sh) builds the CmuxNext package, scheme
# CmuxNextApp, with xcodebuild: not the Xcode app target (App/, Resources/, cmux.xcodeproj and its
# build phases are the scheme compile's). The fleet Release compile check (cmux-next/compile)
# builds the same package sources with SwiftPM and compiles its string catalogs. What
# only xcodebuild sees: how it resolves the package graph (every local package's Package.swift and
# Package.resolved), actool on package asset catalogs, package plists, xcconfigs and entitlements,
# and the Xcode pin and the compile scripts. A same-repository pull request runs the Mac Release
# compile only when it changes one of these. Xcode's own Swift (26.6) against the check's
# toolchain, -O codegen and tests are caught after the merge by the base push's Mac Release
# compile.
MAC_RELEASE_INPUTS = (
    "Packages/*/Package.swift", "Packages/*/Package.resolved", "Packages/*.xcassets/*",
    "Packages/*.plist", "Packages/*.xcconfig", "Packages/*.entitlements",
    # check-release-compile.sh and what it sources or runs. (scripts/ci/ files are CI-only: the
    # router sends them to the Linux CI tests, never to a Mac tier, before and after this.)
    "scripts/cmux-next/check-release-compile.sh", "scripts/cmux-next/release-derived-data-path.sh",
    "scripts/cmux-next/lib/*", "scripts/cmux-next/stale-pcm-retry-needed.sh",
    "scripts/cmux-next/clear-stale-scheme-build-state.sh",
    "scripts/select-ci-xcode.sh", ".xcode-version",
)


def mac_release_input(path: str) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in MAC_RELEASE_INPUTS)


# The path classes of the original routing: these never need a Mac.
WEB_ONLY = (
    "web/*", "workers/*", "config/vite-plus/*", "docs/*", "design/*", "plans/*",
    "*.md", "*.mdx", "*.txt", "README", "README.*", "package.json", "bun.lock",
    "biome.json", "bunfig.toml", ".npmrc", ".vercelignore", "vercel.json",
)
WEBVIEW = (
    "webviews/*", "Resources/markdown-viewer/webviews-app/*",
    "scripts/build-webviews-app.sh", "scripts/check-webviews-react-compiler.mjs",
)

# The web bundles are build output since cx-vn5 (scripts/cmux-next/build-web-bundles.sh
# runs before every package build). A change to what they are built from is a
# change to the targets that ship them: their tests read the built pages, as they
# read the committed copies before.
BUNDLE_INPUTS = (
    "webviews/src/*", "webviews/scripts/*", "webviews/package.json", "webviews/bun.lock",
    "webviews/reactCompiler.mjs", "webviews/vite.config.ts", "schemas/settings/*",
    "Resources/markdown-viewer/marked.min.js",
    "scripts/build-webviews-app.sh", "scripts/check-webviews-bun-version.sh",
    "scripts/cmux-next/build-agent-pane-web.sh", "scripts/cmux-next/build-pages-web.sh",
    "scripts/cmux-next/build-agent-activity-web.sh", "scripts/cmux-next/build-palette-ranker.sh",
    "scripts/cmux-next/build-optchat-inspector-web.sh",
    "scripts/cmux-next/build-web-bundles.sh", "scripts/cmux-next/web-bundle-key.py",
    # Files outside webviews/ that webviews sources import (web-bundle-key.py --inputs;
    # tests/test_web_bundle_key_inputs.sh keeps this list complete).
    "web/data/model-catalog/*", "Resources/markdown-viewer/viewer-navigation.js", "config/vite-plus/*",
    "schemas/sync-motion/*",
    # The UI font the gallery frame imports (src/gallery/frame/uiFont.ts).
    "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/Fonts/InterVariable.woff2",
)
BUNDLE_TARGETS = ("CmuxNextAgentPane", "CmuxNextPages", "CmuxNextAgentActivity", "CmuxNextPalette")
# Committed web bundles that ci-web rebuilds and compares (`--check`) on every pull request,
# and that the app takes as a `.copy` resource: a change to them needs no compile.
CHECKED_WEB_BUNDLES = (
    PACKAGE + "Sources/CmuxNextAgentPane/Resources/agent-pane/*",
)

# CI-only files: workflows, CI scripts, the router and gh-merge-green, and their tests. actionlint
# and the CI unit tests (ci.yml's guards) and the routing replay (the checks job) cover them on
# Linux, and `gh-merge-green --revert` undoes one in a command.
CI_ONLY = (
    ".github/workflows/*", "scripts/ci/*", "scripts/gh-merge-green",
    "tests/test_cmux_next_route.py", "tests/test_cmux_next_route_replay.py",
    "tests/test_cmux_next_checks_workflow.py", "tests/test_gh_merge_green*.py",
    "tests/test_base_red_excuse.py", "tests/test_test_reds.py", "tests/fixtures/test_reds/*", "tests/test_ci_*.py",
)
# The CI files that route themselves (the router reads them; the replay checks them).
CI_SELF = (".github/workflows/cmux-next.yml", "scripts/ci/cmux_next_route.py", "scripts/ci/select_package_tests.py")

# These suites already have dedicated workflow steps after the broad package
# pass. Running them in the priority shard would execute the same coverage
# twice and make the job more likely to hit its total deadline.
ISOLATED_PRIORITY_SUITES = frozenset((
    "CmuxNextControlTests", "BranchStateResourcesTests", "CLISurfaceParityTests",
))


def web_fast(path: str) -> bool:
    """Web sources, their checked bundles, docs: ci-web and the checks job cover them all."""
    if any(fnmatch.fnmatch(path, pattern) for pattern in WEBVIEW + CHECKED_WEB_BUNDLES):
        return True
    return any(fnmatch.fnmatch(path, pattern) for pattern in WEB_ONLY) and not path.startswith(PACKAGE)


def ci_only(path: str) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in CI_ONLY)


# The Python test registry. A tests/test_*.py file whose lane there is linux-guard runs only on
# Linux (scripts/ci/run_python_test_lane.py; the macOS lanes are ci-macos.yml's), so a change to it
# needs no Mac tier unless a Mac tier reads it (consumed()). Its lane is read from the registry,
# never from a list here: a file moved to a macOS lane routes to the Mac tiers again. No cmux-next
# Mac tier reads the registry itself.
REGISTRY = "tests/test-execution.toml"
LINUX_LANE = "linux-guard"


def linux_guard_tests(root: Path) -> frozenset[str]:
    """The registry's linux-guard test files; none when it or its reader cannot be read, so they keep their tiers."""
    try:
        from test_execution_registry import load_registry  # noqa: PLC0415 - a copied router may come without it
        entries = load_registry(root / REGISTRY)
    except (ImportError, OSError, ValueError, SyntaxError):
        return frozenset()
    return frozenset(str(entry.get("path")) for entry in entries
                     if entry.get("lane") == LINUX_LANE and fnmatch.fnmatch(str(entry.get("path")), "tests/test_*.py"))


def linux_only_test(path: str, linux_tests: frozenset[str]) -> bool:
    return path in linux_tests or (path == REGISTRY and bool(linux_tests))


def consumed(path: str, tree_inputs: list[str], read) -> bool:
    """A Mac tier reads this file (a toolchain pin, a job script, a daemon or tree input, a
    generated-file input or a test fixture), whatever its name looks like."""
    if path in FULL_INPUTS and path not in CI_SELF:
        return True
    if path in DAEMON_PATHS or any(matches(path, p) for p in SWIFT_JOB_INPUTS + tuple(tree_inputs)):
        return True
    if any(matches(path, p) for p in GENERATED_INPUTS) and not any(fnmatch.fnmatch(path, b) for b in CHECKED_WEB_BUNDLES):
        return True
    return read(path)


@dataclass
class Route:
    full: bool = False
    native: bool = False
    swift_canary: bool = False
    # Any .swift file under the CmuxNext package (Sources or Tests): the PR runs the Release compile.
    cmuxnext_swift: bool = False
    # An input only the Mac Release compile sees changed (MAC_RELEASE_INPUTS): a same-repository
    # pull request runs it. Every tier sets it.
    mac_release: bool = False
    webview: bool = False
    scheme: bool = False
    generated: bool = False
    swift: bool = False
    daemon: bool = False
    vendored_pin: bool = False
    tests: set[str] = field(default_factory=set)
    # Suites named by changed Swift files get a first, narrow invocation so a
    # later broad target run cannot hide the PR's own signal.
    priority_suites: set[str] = field(default_factory=set)
    swift_canary_targets: set[str] = field(default_factory=set)
    reasons: list[str] = field(default_factory=list)

    def everything(self, reason: str) -> None:
        self.full = self.native = self.scheme = self.generated = self.swift = self.daemon = True
        self.mac_release = True
        self.reasons.append(reason)


def load_graph(root: Path) -> dict:
    return json.loads((root / GRAPH).read_text(encoding="utf-8"))


def tree_input_paths(root: Path) -> list[str]:
    """The v2 cmux-tui tree key's inputs (the classic ghostty gitlink is v1 only)."""
    paths = []
    for line in (root / TREE_INPUTS).read_text(encoding="utf-8").splitlines():
        parts = line.split()
        if len(parts) != 2 or line.startswith("#") or parts == ["gitlink", "ghostty"]:
            continue
        paths.append(parts[1] + ("/" if parts[0] == "tree" else ""))
    return paths


def matches(path: str, pattern: str) -> bool:
    return under(path, pattern) if pattern.endswith("/") else path == pattern


def closure(graph: dict, start: set[str]) -> set[str]:
    """`start` and every target they depend on."""
    seen: set[str] = set()
    pending = list(start)
    while pending:
        name = pending.pop()
        if name in seen:
            continue
        seen.add(name)
        pending.extend(graph["targets"][name]["targets"])
    return seen


def package_inputs(root: Path, graph: dict) -> dict[str, set[str]]:
    """Local package name -> its directory and its transitive path dependencies."""
    dirs = package_dirs(root)
    result = {}
    for name, directory in graph["packages"].items():
        key = Path(directory).name
        result[name] = input_prefixes(root, key, dirs) if key in dirs else {directory.rstrip("/") + "/"}
    return result


def owning_target(graph: dict, path: str) -> str | None:
    best = None
    for name, target in graph["targets"].items():
        prefix = target["path"]
        if prefix and under(path, prefix + "/") and (best is None or len(prefix) > len(graph["targets"][best]["path"])):
            best = name
    return best


def priority_suites(root: Path, graph: dict, changed: list[str]) -> set[str]:
    """Find test suites whose Swift source or test file changed in this diff."""
    test_dirs = [root / target["path"] for target in graph["targets"].values()
                 if target["kind"] == "test" and target.get("path")]
    names: set[str] = set()
    for path in changed:
        if not path.startswith(PACKAGE) or not path.endswith(".swift"):
            continue
        stem = Path(path).stem
        candidate = stem if stem.endswith("Tests") else stem + "Tests"
        if candidate in ISOLATED_PRIORITY_SUITES:
            continue
        if any((directory / f"{candidate}.swift").is_file() or
               any(directory.rglob(f"{candidate}.swift")) for directory in test_dirs):
            names.add(candidate)
    return names


def route(root: Path, event: str, changed: list[str] | None, labels: set[str]) -> Route:
    result = Route()
    mac_inputs = [path for path in changed or [] if mac_release_input(path)]
    if mac_inputs:
        result.mac_release = True
        more = f" and {len(mac_inputs) - 3} more" if len(mac_inputs) > 3 else ""
        result.reasons.append(f"{', '.join(mac_inputs[:3])}{more} only the Mac Release compile sees: it runs")
    # Release-only optimizer crashes (cx-ebm.59.5) are invisible to the Debug tiers, so a PR that
    # changes any CmuxNext package Swift file runs the Release compile, whatever else it changes.
    result.cmuxnext_swift = any(path.startswith(PACKAGE) and path.endswith(".swift") for path in changed or [])
    if result.cmuxnext_swift and event == "pull_request":
        result.reasons.append("a CmuxNext package Swift file changed: the Release compile runs")
    if event != "pull_request":
        result.everything(f"{event}: base coverage runs every tier")
        return result
    if "full-ci" in labels:
        result.everything("labeled full-ci (batch integration PR): every tier")
        return result
    if not changed:
        result.everything("the diff is unknown or empty: every tier")
        return result

    # The workflow defines the native build and its routing contract. A change
    # to it must exercise the release compile even though other CI-only files
    # can stay on the Linux fast tier.
    if ".github/workflows/cmux-next.yml" in changed:
        result.everything("cmux-next workflow changed: run every tier")
        return result

    graph = load_graph(root)
    tests = {name for name, target in graph["targets"].items() if target["kind"] == "test"}
    result.priority_suites = priority_suites(root, graph, changed)
    read = lambda path: any(matches(path, r) for name in tests for r in graph["targets"][name].get("reads", []))  # noqa: E731
    # The fast tiers: a web nit or a CI change lands in minutes. ci-web's bundle --check stands in for
    # the app compile; actionlint, the CI tests and the routing replay check CI changes. A file a Mac
    # tier reads keeps its tier, and a dev-build PR still compiles its dogfood app.
    tree_inputs_early = tree_input_paths(root)
    linux_tests = linux_guard_tests(root)
    if "dev-build" not in labels and all(
        (web_fast(path) or ci_only(path) or linux_only_test(path, linux_tests))
        and not consumed(path, tree_inputs_early, read) for path in changed
    ):
        kinds = sorted({"CI" if ci_only(path) else "Linux-lane test" if linux_only_test(path, linux_tests) else "web"
                        for path in changed})
        result.reasons.append(f"only {' and '.join(kinds)} files changed: Linux checks cover them (no Mac tier)")
        return result
    packages = package_inputs(root, graph)
    tree_inputs = tree_input_paths(root)
    daemon_closure = closure(graph, set(LIVE_DAEMON_SUBJECTS))
    changed_targets: set[str] = set()

    for path in changed:
        if any(fnmatch.fnmatch(path, pattern) for pattern in WEBVIEW):
            result.webview = True
        elif any(fnmatch.fnmatch(path, pattern) for pattern in WEB_ONLY) and not path.startswith(PACKAGE):
            pass
        elif not path.startswith("Packages/"):
            # App host, Xcode project, CLI, resources and build scripts: only
            # the app scheme compiles them.
            result.native = result.scheme = True
        if any(matches(path, prefix) for prefix in GENERATED_INPUTS):
            result.generated = True

        if path in VENDORED_PINS:
            result.vendored_pin = True
            result.everything(f"{path} is a vendored binary pin")
            continue
        if path in FULL_INPUTS:
            result.everything(f"{path} is an input of every package test")
            continue
        if any(matches(path, prefix) for prefix in tree_inputs) or path in DAEMON_PATHS:
            result.daemon = True
            result.reasons.append(f"{path} reaches the daemon")
        if any(matches(path, prefix) for prefix in SWIFT_JOB_INPUTS):
            result.swift = True
            result.reasons.append(f"{path} is a swift test job script")

        if any(fnmatch.fnmatch(path, pattern) for pattern in BUNDLE_INPUTS):
            shipped = {name for name in BUNDLE_TARGETS if name in graph["targets"]}
            changed_targets |= shipped
            result.native = True
            result.reasons.append(f"{path} is built into the web bundles of {', '.join(sorted(shipped))}")

        owner = owning_target(graph, path)
        if owner is not None:
            changed_targets.add(owner)
            result.native = True
            # An executable target (the server helper) is bundled by the app
            # scheme's build phases, not linked into CmuxNextApp.
            if graph["targets"][owner]["kind"] == "executable":
                result.scheme = True
        elif path.startswith(PACKAGE) and not path.endswith(".md"):
            result.everything(f"{path} is in the CmuxNext package but in no target")
            continue
        for name, prefixes in packages.items():
            if any(under(path, prefix) for prefix in prefixes):
                users = {t for t, target in graph["targets"].items() if name in target["packages"]}
                changed_targets |= users
                result.native = result.scheme = True
                result.reasons.append(f"{path} is in local package {name}, used by {', '.join(sorted(users))}")
        for name in tests:
            if any(matches(path, read) for read in graph["targets"][name].get("reads", [])):
                result.tests.add(name)
                result.reasons.append(f"{path} is read by {name}")

    if result.full:
        return result
    for name in tests:
        if name in changed_targets or closure(graph, {name}) & changed_targets:
            result.tests.add(name)
    if changed_targets & daemon_closure or changed_targets & set(DAEMON_DIRECT_TARGETS):
        result.daemon = True
        result.reasons.append(
            "changed targets reach the live-daemon suites: "
            + ", ".join(sorted(changed_targets & (daemon_closure | set(DAEMON_DIRECT_TARGETS))))
        )
    if result.tests:
        result.swift = True
        result.generated = True
    if result.swift and changed_targets and all(canary_swift_path(path) for path in changed):
        result.swift_canary_targets = canary_targets(graph, changed_targets)
        result.swift_canary = bool(result.swift_canary_targets)
        if result.swift_canary:
            result.reasons.append(
                "small CmuxNext Swift-only diff: the canary gates this pull request"
            )
    if result.webview:
        result.scheme = True
    if "dev-build" in labels and result.native:
        # The dogfood artifact a dev-build PR publishes is the scheme compile's app.
        result.scheme = True
        result.reasons.append("labeled dev-build: the scheme compile builds the dogfood app")
    return result


def swift_filter(result: Route) -> str:
    """A `swift test --filter` regex for the selected test targets ('' is all)."""
    if result.full:
        return ""
    return "^(" + "|".join(sorted(result.tests)) + ")\\." if result.tests else ""


def swift_priority_filter(result: Route) -> str:
    """A regex matching only suites named by changed Swift files."""
    # SwiftPM names a suite as Target.Suite.Test; unlike the target filter,
    # this shard must allow the target prefix before the changed suite.
    return ".*(" + "|".join(sorted(result.priority_suites)) + ")\\." if result.priority_suites else ""


def canary_swift_path(path: str) -> bool:
    return path.endswith(".swift") and any(path.startswith(prefix) for prefix in CANARY_SWIFT_PREFIXES)


def canary_targets(graph: dict, changed_targets: set[str]) -> set[str]:
    """Return buildable production targets affected by changed package targets.

    Test sources remain covered by the normal swift-test tier. Mapping a test
    target to its direct production targets keeps this lane a short module
    type-check instead of rebuilding and linking every test bundle.
    """
    targets: set[str] = set()
    for name in changed_targets:
        target = graph["targets"].get(name)
        if not target:
            continue
        if target["kind"] in {"regular", "executable"}:
            targets.add(name)
    return targets


def outputs(result: Route) -> dict[str, str]:
    flag = lambda value: "true" if value else "false"  # noqa: E731
    # Any tier that needs a Mac: the placement job places these runs.
    macos = result.native or result.webview or result.swift or result.generated or result.daemon
    return {
        "native": flag(result.native),
        "swift_canary": flag(result.swift_canary),
        "cmuxnext_swift": flag(result.cmuxnext_swift),
        "mac_release": flag(result.mac_release),
        "macos": flag(macos),
        "scheme": flag(result.scheme or result.webview or result.full),
        "generated": flag(result.generated),
        "swift": flag(result.swift),
        "daemon": flag(result.daemon),
        "full": flag(result.full),
        "vendored_pin": flag(result.vendored_pin),
        "swift_filter": swift_filter(result),
        "swift_priority_filter": swift_priority_filter(result),
        "swift_targets": "all" if result.full else " ".join(sorted(result.tests)),
        "swift_canary_targets": " ".join(sorted(result.swift_canary_targets)),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--event", required=True)
    parser.add_argument("--changed-files", type=Path)
    parser.add_argument("--labels", default="")
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args(argv)

    changed = None
    if args.changed_files:
        changed = [line for line in args.changed_files.read_text(encoding="utf-8").splitlines() if line]
    labels = {label for label in args.labels.split(",") if label}
    result = route(args.root, args.event, changed, labels)
    values = outputs(result)
    lines = [f"{key}={value}" for key, value in values.items()]
    print("\n".join(lines))
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as stream:
            stream.write("\n".join(lines) + "\n")
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as stream:
            stream.write("### cmux-next tiers\n\n| tier | runs |\n| --- | --- |\n")
            for key in ("generated", "native", "swift_canary", "cmuxnext_swift", "mac_release", "scheme", "swift", "daemon", "full"):
                stream.write(f"| {key} | {values[key]} |\n")
            stream.write(f"\nSwift test targets: {values['swift_targets'] or 'none'}\n\n")
            stream.write(f"Swift canary targets: {values['swift_canary_targets'] or 'none'}\n\n")
            for reason in dict.fromkeys(result.reasons):
                stream.write(f"- {reason}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
