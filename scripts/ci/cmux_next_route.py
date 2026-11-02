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
  fast_tier   the Mac half of the PR fast tier (scripts/cmux-next/fast-tier.json
              `swift` entries): one `swift build --build-tests` of the CmuxNext
              package and a few of its suites. Only a change to what that build
              or those suites read can change its result: a package target's
              sources, a file read by a test target that holds one of its suites
              (read from fast-tier.json and the target graph), its own registry,
              runner or package, or an input of every tier. The job builds no
              web bundles, so a change only to their sources, or to a file only
              other test targets read, leaves it off, as a daemon-only or
              app-host-only route (cmux-tui Rust, App/) does; swift test, the
              daemon and scheme tiers carry those.

A change to .github/workflows/cmux-next.yml runs every tier, unless `--base-rev`
names the base and the change leaves every job a Mac job runs or needs as it was
(`on:` paths, a Linux-only job): then it is a CI-only file, like the rest of
.github/workflows. A changed job that never runs on a pull request adds no tier, and a
changed Mac job WORKFLOW_JOB_TIERS lists runs only its own tiers. When the base workflow
cannot be read or parsed, every tier runs.

Pushes, dispatches and pull requests labeled `full-ci` run every tier. The
workflow runs the tiers picked here on every same-repository pull request; a
fork pull request runs the heavier Mac tiers only with `full-ci`. A changed file this script cannot place selects every
tier, so an unknown input never skips a check.

Usage: cmux_next_route.py --event NAME [--changed-files FILE] [--labels a,b]
       [--base-rev REV] [--github-output FILE] [--summary FILE]
"""

from __future__ import annotations

import argparse
import fnmatch
import functools
import importlib.util
import json
import re
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
    # Which suites run in which test process, for every target (#26809).
    "scripts/cmux-next/main-thread-heavy-suites.py",
    "scripts/cmux-next/swift-test-shards.py",
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
    PACKAGE + "Tests/CmuxNextAppTests/MarkdownPageFindTests.swift",
    PACKAGE + "Tests/CmuxNextAppTests/FileSourceSwitchTests.swift",
    # The classic import and migration suites start the live daemon too.
    PACKAGE + "Tests/CmuxNextAppTests/ClassicImportTests.swift",
    PACKAGE + "Tests/CmuxNextAppTests/ClassicMigrationTests.swift",
    PACKAGE + "Tests/CmuxNextAppTests/ClassicUpgradeSimulationTests.swift",
    PACKAGE + "Tests/CmuxNextAppTests/ClassicUpgradeHugeSimulationTests.swift",
    PACKAGE + "Tests/CmuxNextAppTests/ClassicUpgradeSimulator.swift",
    PACKAGE + "Sources/CmuxNextApp/Onboarding/AppOnboardingServices+ClassicSessions.swift",
    PACKAGE + "Sources/CmuxNextApp/Onboarding/AppOnboardingServices+ClassicMigration.swift",
)

# The Mac fast tier's own registry and runner (fast-tier.py reads fast-tier.json and quarantine.json).
NO_FAST_TIER_REASON = "(no Mac fast tier)"
FAST_TIER_INPUTS = (
    "scripts/cmux-next/fast-tier.py",
    "scripts/cmux-next/fast-tier.json",
    "scripts/cmux-next/quarantine.json",
    "scripts/cmux-next/fast-tier-cache-key.sh",
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
# runs before every package build). A change to what they are built from changes the
# app the scheme and Release compiles build (`native`), but no swift test suite: the
# targets that ship them take them as `.copy` resources (or one processed .js), which
# no source edit can break, and their suites load fixture pages (AgentPaneView with a
# temporary index.html, loadHTMLString, a scratch page root), never a built page's
# content; the app suites that open a real page assert only the native side
# (DebugSettingsHangWatchTests runs with or without the built page). A bundle source a
# test does read, such as the dev server's entries (PageDevServerTests) or a shared
# fixture (webviews/test/fixtures/new-tab-intents.json), selects that test through the
# graph's reads, like any other file. ci-web type-checks, lints, tests and builds the
# bundles on Linux, as it does for every webviews change that touches nothing else.
BUNDLE_INPUTS = (
    "webviews/src/*", "webviews/scripts/*", "webviews/package.json", "webviews/bun.lock",
    "webviews/reactCompiler.mjs", "webviews/vite.config.ts", "schemas/settings/*",
    # The feature tips' source (webviews/scripts/pages/gen-feature-tips.mjs).
    "release-notes/next/highlights/*",
    "Resources/markdown-viewer/marked.min.js",
    "scripts/build-webviews-app.sh", "scripts/check-webviews-bun-version.sh",
    "scripts/cmux-next/build-agent-pane-web.sh", "scripts/cmux-next/build-pages-web.sh",
    "scripts/cmux-next/build-agent-activity-web.sh", "scripts/cmux-next/build-palette-ranker.sh",
    "scripts/cmux-next/build-optchat-inspector-web.sh",
    "scripts/cmux-next/build-web-bundles.sh", "scripts/cmux-next/web-bundle-key.py",
    # Files outside webviews/ that webviews sources import (web-bundle-key.py --inputs;
    # tests/test_web_bundle_key_inputs.sh keeps this list complete).
    "web/data/model-catalog/*", "Resources/markdown-viewer/viewer-navigation.js", "config/vite-plus/*",
    "schemas/sync-motion/*", "schemas/agent-pane/*",
    # The layout grid the transcript imports (src/agent-session/acpmux/transcriptGrid.ts).
    "schemas/layout-grid/layout-grid.json",
    # The UI font the gallery frame imports (src/gallery/frame/uiFont.ts).
    "Packages/macOS/CmuxNext/Sources/CmuxNextDesign/Resources/Fonts/InterVariable.woff2",
)
BUNDLE_TARGETS = ("CmuxNextAgentPane", "CmuxNextPages", "CmuxNextAgentActivity", "CmuxNextPalette")
BUNDLE_SWIFT_TEST_REASON = "(no swift test suite reads a built bundle; only the tests that read this file run)"
# Committed web bundles that ci-web rebuilds and compares (`--check`) on every pull request,
# and that the app takes as a `.copy` resource: a change to them needs no compile.
CHECKED_WEB_BUNDLES = (
    PACKAGE + "Sources/CmuxNextAgentPane/Resources/agent-pane/*",
)

# CI-only files: workflows, CI scripts, the router and gh-merge-green, the warm-sources table
# (tests/test_ci_warm_sources.py), and their tests. actionlint and the CI unit tests (ci.yml's
# guards) and the routing replay (the checks job) cover them on Linux, and `gh-merge-green
# --revert` undoes one in a command.
# Top-level paths no Mac compile reads: the Cloud VM image (images/), Go and Bun services, the
# agent and review-bot configs. Nothing in cmux.xcodeproj, a Package.swift or a scripts/ build script
# names them (test_no_app_input_is_named_by_a_build_input keeps that true), so a change to one runs no
# Release or scheme compile: #29013 (images/cmux-vm/inputs.lock.json) waited 80 minutes on a fleet
# Release compile its diff could not change. A test target that reads one still runs (consumed()).
NO_APP_INPUT = (
    "images/*", "services/*", "vault/*", "coderouter/*", "agent-chat/*", "markdown-obsidian-parity/*",
    "tests_v2/*", ".agents/*", ".claude/*", ".codex/*", ".greptile/*", ".coderabbit.yaml",
)


def no_app_input(path: str) -> bool:
    return any(fnmatch.fnmatch(path, pattern) for pattern in NO_APP_INPUT)


CI_ONLY = (
    ".github/workflows/*", ".github/warm-sources.json", "scripts/ci/*", "scripts/gh-merge-green",
    "tests/test_cmux_next_route.py", "tests/test_cmux_next_route_replay.py",
    "tests/test_cmux_next_checks_workflow.py", "tests/test_gh_merge_green*.py",
    "tests/test_base_red_excuse.py", "tests/test_test_reds.py", "tests/fixtures/test_reds/*", "tests/test_ci_*.py",
    # The unrecognized-selector lint: cmux-next-crash-class.yml runs it on Linux, and its fleet step
    # wrapper only reads the table. No compile reads any of the three (#29032 changed only the table
    # and waited on the fleet Release compile).
    "scripts/cmux-next/objc-selector-table.json", "scripts/cmux-next/check-objc-selectors.py",
    "scripts/cmux-next/check-objc-selectors.sh",
)
# The CI files that route themselves (the router reads them; the replay checks them).
CI_SELF = (".github/workflows/cmux-next.yml", "scripts/ci/cmux_next_route.py", "scripts/ci/select_package_tests.py")

# These suites already have dedicated workflow steps after the broad package
# pass. Running them in the priority shard would execute the same coverage
# twice and make the job more likely to hit its total deadline.
ISOLATED_PRIORITY_SUITES = frozenset((
    "CmuxNextControlTests", "BranchStateResourcesTests", "CLISurfaceParityTests",
))

# The priority shard only reorders: the broad pass skips its suites and would run them anyway. Past
# this many suites its regex stalls swift-testing's filter (cmux#27236's 378 suites, a 9.7 KB
# `.*(A|B|...)\.`, sat 1500 s in Configuration.TestFilter.apply before any test ran, and the broad
# pass's matching `--skip` stalled the same way), so a diff that wide gets no priority shard.
MAX_PRIORITY_SUITES = 40


def web_fast(path: str) -> bool:
    """Web sources, their checked bundles, docs: ci-web and the checks job cover them all."""
    if any(fnmatch.fnmatch(path, pattern) for pattern in WEBVIEW + CHECKED_WEB_BUNDLES):
        return True
    if no_app_input(path):
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


# A test target's "reads" (ci-target-graph.py) are the repository paths its sources name in string
# literals. A literal built by interpolation counts up to its first `\(`, so a helper such as
# `planURL(_ name:)` returning "plans/cmux-next/\(name)" makes the whole of plans/cmux-next/ a read,
# and every design note there then ran swift test and the generated files job (#28326: one
# sidebar-owner.md edit queued both Mac jobs). A doc under such a directory read is read only when a
# string literal in the target names it, or names the directory itself (a test that lists it).
UNREAD_DOC_REASON = "(no Mac tier)"
DOC_SUFFIXES = (".md", ".mdx", ".html", ".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")
STRING_LITERAL = re.compile(r'"((?:[^"\\\n]|\\.)*)"')
GENERATED_OUTPUTS = "scripts/cmux-next/generated_outputs.py"


@functools.lru_cache(maxsize=None)
def source_literals(directory: Path) -> frozenset[str] | None:
    """The string literals of a target's Swift sources, comment lines left out; None when unreadable."""
    try:
        sources = sorted(directory.rglob("*.swift"))
        if not sources:
            return None
        found: set[str] = set()
        for source in sources:
            for line in source.read_text(encoding="utf-8").splitlines():
                if line.lstrip().startswith(("//", "/*", "*")):
                    continue
                found.update(STRING_LITERAL.findall(line))
        return frozenset(found)
    except (OSError, UnicodeDecodeError):
        return None


@functools.lru_cache(maxsize=None)
def generated_output(root: Path, path: str) -> bool:
    """Whether a generator writes `path` (generated_outputs.py OUTPUTS); True when that cannot be read."""
    try:
        spec = importlib.util.spec_from_file_location("cmux_next_generated_outputs", root / GENERATED_OUTPUTS)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module.output_of(path) is not None
    except (OSError, ImportError, AttributeError, SyntaxError, SystemExit):
        return True


def names(literal: str, name: str) -> bool:
    return literal == name or literal.endswith("/" + name)


def unread_doc(root: Path, graph: dict, path: str, tree_inputs: list[str]) -> bool:
    """A doc (web_fast, a DOC_SUFFIXES file outside Packages/) that test targets read only through a
    directory read whose sources never name it: no Mac tier reads it. A doc no directory read covers
    routes as before."""
    if not path.endswith(DOC_SUFFIXES) or not web_fast(path) or path.startswith("Packages/"):
        return False
    if path in FULL_INPUTS or path in DAEMON_PATHS or path in VENDORED_PINS:
        return False
    if any(matches(path, p) for p in SWIFT_JOB_INPUTS + tuple(tree_inputs)):
        return False
    if any(matches(path, p) for p in GENERATED_INPUTS if not p.endswith("/")) or generated_output(root, path):
        return False
    covered = False
    for target in graph["targets"].values():
        for read in target.get("reads", []):
            if read == path or ("*" in read and matches(path, read)):
                return False
            if not (read.endswith("/") and under(path, read)):
                continue
            covered = True
            literals = source_literals(root / target["path"]) if target.get("path") else None
            if literals is None:
                return False
            directory = read.rstrip("/")
            relative, base = path[len(read):], path.rsplit("/", 1)[-1]
            if any(names(lit, relative) or names(lit, base) or names(lit.rstrip("/"), directory) for lit in literals):
                return False
    return covered


def consumed(path: str, tree_inputs: list[str], read) -> bool:
    """A Mac tier reads this file (a toolchain pin, a job script, a daemon or tree input, a
    generated-file input or a test fixture), whatever its name looks like."""
    if path in FULL_INPUTS and path not in CI_SELF:
        return True
    if path in DAEMON_PATHS or path in FAST_TIER_INPUTS or any(matches(path, p) for p in SWIFT_JOB_INPUTS + tuple(tree_inputs)):
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
    # A CmuxNext package target's sources (or a local package it uses) changed: the package build
    # the Mac fast tier runs can break. A web bundle input alone does not: that job builds no bundle.
    package_build: bool = False
    # A file read by a test target holding a fast tier suite changed.
    fast_reads: bool = False
    # A file under a package a fast tier swift entry builds changed.
    fast_package: bool = False
    # The fast tier's own registry, runner or job action changed.
    fast_registry: bool = False
    vendored_pin: bool = False
    # A change to the swift test job's own steps (WORKFLOW_JOB_TIERS): every test target runs.
    all_tests: bool = False
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

    def macos(self) -> bool:
        """Any tier that needs a Mac: the placement job places these runs."""
        return self.native or self.webview or self.swift or self.generated or self.daemon

    def fast_tier(self) -> bool:
        """The Mac fast tier's package build or suites can change: a package target's sources, a file its
        suites' test targets read, a package it builds, its registry, runner or job action, an input only
        the Mac Release compile sees, or an input of every tier."""
        return (self.full or self.package_build or self.fast_reads or self.fast_package or self.mac_release
                or self.swift_canary or self.fast_registry)


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


import re  # noqa: E402 - the Cargo and Xcode project readers below

CMUX_TUI = "cmux-tui/"
# The routing replay (cmux_next_route_replay.py) accepts dropped native and scheme tiers with this reason.
NO_SWIFT_COMPILE_REASON = "(no Swift compile reads it)"
APP_FFI_CRATE = "cmux-tui/crates/cmux-app-ffi"
APP_PROJECT = "cmux.xcodeproj/project.pbxproj"
CARGO_PATH = re.compile(r'path\s*=\s*"([^"]+)"')
CARGO_WORKSPACE_DEP = re.compile(r'^\s*([A-Za-z0-9_-]+)\s*(?:\.workspace\s*=\s*true|=\s*\{[^}\n]*\bworkspace\s*=\s*true)', re.M)
PHASE_INPUT = re.compile(r'"\$\(SRCROOT\)/(cmux-tui/[^"]+)"')


_READ: dict = {}  # (reader, root) -> its paths, read once a run


def app_ffi_inputs(root: Path) -> list[str]:
    if ("ffi", root) not in _READ:
        _READ["ffi", root] = _app_ffi_inputs(root)
    return _READ["ffi", root]


def scheme_phase_rust_inputs(root: Path) -> list[str]:
    if ("scheme", root) not in _READ:
        _READ["scheme", root] = _scheme_phase_rust_inputs(root)
    return _READ["scheme", root]


def _app_ffi_inputs(root: Path) -> list[str]:
    """The CCmuxAppFFI sources, the only Rust the Swift compiles link: cmux-app-ffi and every crate it
    reaches through Cargo path dependencies (its own or the workspace's), the toolchain and the build
    script, as scripts/cmux-next/check-app-ffi-pin.sh derives them, plus the swift test job's crates. A
    change to one also needs a new pin (Package.swift, which runs every tier)."""
    workspace: dict[str, str] = {}
    try:
        manifest = (root / "cmux-tui/Cargo.toml").read_text(encoding="utf-8")
        for line in manifest.splitlines():
            named = re.match(r'\s*([A-Za-z0-9_-]+)\s*=\s*\{[^}]*\bpath\s*=\s*"([^"]+)"', line)
            if named:
                workspace[named.group(1)] = "cmux-tui/" + named.group(2).strip("/")
    except OSError:
        pass
    seen: set[str] = set()
    pending = [APP_FFI_CRATE]
    while pending:
        crate = pending.pop()
        if crate in seen or not (root / crate / "Cargo.toml").is_file():
            continue
        seen.add(crate)
        text = (root / crate / "Cargo.toml").read_text(encoding="utf-8")
        found = [(Path(crate) / dep).as_posix() for dep in CARGO_PATH.findall(text)]
        found += [workspace[name] for name in CARGO_WORKSPACE_DEP.findall(text) if name in workspace]
        for dep in found:
            resolved = (root / dep).resolve()
            try:
                relative = resolved.relative_to(root.resolve()).as_posix()
            except ValueError:
                continue
            if (resolved / "Cargo.toml").is_file():
                pending.append(relative)
    prefixes = {crate + "/" for crate in seen}
    prefixes |= {p for p in SWIFT_JOB_INPUTS if p.startswith(CMUX_TUI)}
    prefixes |= {"cmux-tui/rust-toolchain.toml", "scripts/cmux-next/build-app-ffi.sh"}
    return sorted(prefixes)


def _scheme_phase_rust_inputs(root: Path) -> list[str]:
    """The cmux-tui files and directories the app scheme's build phases name as inputs (the diff sidecar,
    the mobile host, the CLI resources). The Bundle cmux-tui phase names the whole tree: it bundles the
    same-tree build the daemon tier makes, so that entry adds nothing here."""
    try:
        text = (root / APP_PROJECT).read_text(encoding="utf-8")
    except OSError:
        return [CMUX_TUI]
    found = set()
    for entry in PHASE_INPUT.findall(text):
        found.add(entry + "/" if (root / entry).is_dir() else entry)
    return sorted(found)


def matches(path: str, pattern: str) -> bool:
    """A trailing / is a directory; a `*` is a test target's pattern read (ci-target-graph.py
    glob_read: fnmatch, whose `*` also crosses /, so it matches at least what the test reads)."""
    if "*" in pattern:
        return fnmatch.fnmatchcase(path, pattern + "*" if pattern.endswith("/") else pattern)
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


WORKFLOW = ".github/workflows/cmux-next.yml"
FAST_TIER_REGISTRY = "scripts/cmux-next/fast-tier.json"
FAST_TIER_JOB = "fast-tier"
SUITE_NAME = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


@dataclass(frozen=True)
class FastTierScope:
    """What the Mac fast tier reads besides its registry and every tier's inputs."""
    # Test targets holding its CmuxNext suites; None when one cannot be placed (every test target counts).
    targets: frozenset[str] | None
    # The package directories its swift entries build (`swift build --build-tests --package-path`).
    packages: frozenset[str]


def suite_targets(root: Path, graph: dict, suite: str) -> set[str]:
    """The CmuxNext test targets that declare `suite`: those with a file of that name, else those whose
    sources declare a type so named (an unreadable source counts)."""
    sources = {name: sorted((root / target["path"]).rglob("*.swift"))
               for name, target in graph["targets"].items() if target["kind"] == "test" and target.get("path")}
    found = {name for name, files in sources.items() if any(source.stem == suite for source in files)}
    if found:
        return found
    declared = re.compile(rf"\b(?:class|struct|actor|enum)\s+{re.escape(suite)}\b")
    for name, files in sources.items():
        for source in files:
            try:
                if declared.search(source.read_text(encoding="utf-8")):
                    found.add(name)
                    break
            except (OSError, UnicodeDecodeError):
                found.add(name)
                break
    return found


def fast_tier_job_actions(root: Path) -> frozenset[str] | None:
    """The local actions (`uses: ./...`) the Mac fast tier job runs, from the workflow itself; None when
    it cannot be read (every local action then counts). Read once a run, and only for a changed action."""
    if ("fast-actions", root) not in _READ:
        _READ["fast-actions", root] = _fast_tier_job_actions(root)
    return _READ["fast-actions", root]


def _fast_tier_job_actions(root: Path) -> frozenset[str] | None:
    try:
        import yaml  # noqa: PLC0415 - only the workflow readers need it
        jobs = yaml.load((root / WORKFLOW).read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
        steps = jobs[FAST_TIER_JOB]["steps"]
        return frozenset(step["uses"][2:].rstrip("/") + "/" for step in steps
                         if isinstance(step, dict) and str(step.get("uses", "")).startswith("./"))
    except Exception:  # noqa: BLE001 - unreadable: every local action counts (route below)
        return None


def fast_tier_scope(root: Path, graph: dict) -> FastTierScope:
    """The Mac fast tier's suites and packages (fast-tier.json `swift` entries). A CmuxNext entry whose
    suite no test target declares, or with no plain suite name, makes every test target count."""
    if ("fast", root) not in _READ:
        _READ["fast", root] = _fast_tier_scope(root, graph)
    return _READ["fast", root]


def _fast_tier_scope(root: Path, graph: dict) -> FastTierScope:
    try:
        entries = json.loads((root / FAST_TIER_REGISTRY).read_text(encoding="utf-8"))["entries"]
    except (OSError, ValueError, KeyError, TypeError):
        return FastTierScope(None, frozenset())
    targets: set[str] = set()
    packages: set[str] = set()
    placed = True
    for entry in entries:
        if not isinstance(entry, dict) or entry.get("kind") != "swift":
            continue
        package = str(entry.get("package") or "").strip("/")
        if not package:
            placed = False
            continue
        packages.add(package + "/")
        if package + "/" != PACKAGE:
            continue  # another package: its whole directory is an input (packages)
        suite = str(entry.get("filter") or "")
        found = suite_targets(root, graph, suite) if SUITE_NAME.fullmatch(suite) else set()
        if found:
            targets |= found
        else:
            placed = False
    return FastTierScope(frozenset(targets) if placed else None, frozenset(packages))


# The top-level workflow keys a pull request's Mac jobs never read: `on:` decides which events and
# paths start a run (a pull_request run sees no workflow_dispatch input), `run-name` its title.
QUIET_WORKFLOW_KEYS = ("on", "run-name")
def split_top(text: str, operator: str) -> list[str] | None:
    """`text` split at `operator` outside quotes and parentheses; None when they do not balance."""
    parts, depth, quoted, last, index = [], 0, False, 0, 0
    while index < len(text):
        char = text[index]
        if char == "'":
            quoted = not quoted
        elif not quoted and char == "(":
            depth += 1
        elif not quoted and char == ")":
            depth -= 1
            if depth < 0:
                return None
        elif not quoted and depth == 0 and text.startswith(operator, index):
            parts.append(text[last:index])
            index += len(operator)
            last = index
            continue
        index += 1
    if quoted or depth:
        return None
    return parts + [text[last:]]


def linux_values(expression: str) -> bool:
    """Whether every value an expression can give is a Linux label: `a && b || c` gives b or c, so each
    `||` alternative's last `&&` operand must be a literal naming ubuntu or a variable whose name says
    LINUX (a parenthesised group is read the same way). Anything else may be a Mac."""
    alternatives = split_top(expression.strip(), "||")
    if not alternatives:
        return False
    for alternative in alternatives:
        operands = split_top(alternative.strip(), "&&")
        if not operands:
            return False
        value = operands[-1].strip()
        if value.startswith("(") and value.endswith(")") and split_top(value[1:-1], "||") is not None:
            if not linux_values(value[1:-1]):
                return False
        elif re.fullmatch(r"'[^']*'", value):
            if "ubuntu" not in value:
                return False
        elif not (re.fullmatch(r"vars\.\w+", value) and "LINUX" in value) and value not in PORTABLE_RUNNERS:
            return False
    return True


# Portable placement (scripts/ci/portable_job_placement.py) puts a job that needs neither Linux nor
# Blacksmith on fleet Linux or a free mini. The job runs the same scripts either way, none of the
# app's Mac tiers, so its outputs count as Linux here: an edit to such a job runs no Mac tier.
PORTABLE_RUNNERS = frozenset(
    f"needs.portable-placement.outputs.{output}" for output in ("linux_runner", "mini_runner"))


def linux_runs_on(value) -> bool:
    """Whether a job's runs-on can only be a Linux runner (linux_values for an expression)."""
    if not isinstance(value, str) or not value.strip():
        return False
    text = value.strip()
    if "${{" not in text:
        return "ubuntu" in text
    match = re.fullmatch(r"\$\{\{(.*)\}\}", text, re.S)
    return bool(match) and "${{" not in match.group(1) and linux_values(match.group(1))


def linux_job(job, root: Path | None, seen: frozenset[str] = frozenset()) -> bool:
    """Whether a job runs only on Linux: its runs-on (linux_runs_on), or for a call of a local reusable
    workflow (`uses: ./.github/workflows/X.yml`, read at `root`), every job of that workflow."""
    if not isinstance(job, dict):
        return False
    uses = job.get("uses")
    if uses is None:
        return linux_runs_on(job.get("runs-on"))
    if root is None or not isinstance(uses, str) or not uses.startswith("./.github/workflows/") or uses in seen:
        return False
    try:
        import yaml  # noqa: PLC0415
        called = yaml.load((root / uses[2:]).read_text(encoding="utf-8"), Loader=yaml.BaseLoader)["jobs"]
    except Exception:  # noqa: BLE001 - unreadable: it may run on a Mac
        return False
    return isinstance(called, dict) and bool(called) and all(
        linux_job(inner, root, seen | {uses}) for inner in called.values())


# What a pull request's change to one Mac job of cmux-next.yml runs: that job's own tiers (#5424: a
# change to the DEV compile's steps ran swift test, the daemon suites and every compile). "swift" is
# every CmuxNext test target, and swift test and the daemon suites take "generated" too, so the
# generated-files check they fold in runs as it does on a pull request. Any other job that runs on a
# Mac or that one needs (path routing, placement, the web bundles, the fast tier, the canary) runs
# every tier, and so does a change to a listed job's `if:` (it changes when the job runs, on every
# route), a job added or removed, or a top-level key. A job that never runs on a pull request
# (never_on_pull_request) adds no tier: the pull request cannot run it, and the base push does.
WORKFLOW_JOB_TIERS: dict[str, tuple[str, ...]] = {
    "swift-test": ("swift", "generated"),
    "daemon-test": ("daemon", "generated"),
    "generated-files": ("generated",),
    "release-compile": ("native", "mac_release"),
    "app-compile-fleet": ("native",),
    "cmux-scheme-compile": ("native", "scheme"),
}
# The tiers a Route can take from WORKFLOW_JOB_TIERS (its attribute names; "swift" also sets all_tests).
WORKFLOW_TIER_FIELDS = ("swift", "generated", "daemon", "native", "mac_release", "scheme")
NOT_ON_PULL_REQUEST_REASON = "(it never runs on a pull request; the base push runs it)"
# An `if:` operand that is false on every pull_request run: another event, a branch ref (a pull
# request's github.ref is refs/pull/N/merge) or a dispatch input set to true (a pull request has none).
NEVER_ON_PULL_REQUEST = re.compile(
    r"github\.event_name\s*==\s*'(?:push|workflow_dispatch|schedule)'"
    r"|github\.ref\s*==\s*'refs/heads/[^']*'"
    r"|inputs\.[\w-]+\s*==\s*true")
NEEDS_OPERAND = re.compile(r"needs\.([\w-]+)\.(?:result\s*==\s*'success'|outputs\.[\w-]+\s*==\s*'[^']+')")


def never_on_pull_request(name: str, jobs: dict, seen: frozenset[str] = frozenset()) -> bool:
    """Whether job `name` cannot run on a pull request: its `if:` has a top-level `&&` operand that is
    false there (NEVER_ON_PULL_REQUEST), or that needs a job of its own `needs:` to succeed (or to set an
    output) that cannot run there either. A parenthesised operand counts when each of its `||`
    alternatives has such an operand. Anything else, an unreadable `if:` included, may run."""
    job = jobs.get(name)
    if not isinstance(job, dict) or name in seen:
        return False
    text = str(job.get("if") or "").strip()
    match = re.fullmatch(r"\$\{\{(.*)\}\}", text, re.S)
    needs = job.get("needs", [])
    needs = {needs} if isinstance(needs, str) else set(needs) if isinstance(needs, list) else set()

    def false_on_pr(expression: str) -> bool:
        operands = split_top(expression.strip(), "&&")
        for operand in operands or []:
            operand = operand.strip()
            if NEVER_ON_PULL_REQUEST.fullmatch(operand):
                return True
            need = NEEDS_OPERAND.fullmatch(operand)
            if need and need.group(1) in needs and never_on_pull_request(need.group(1), jobs, seen | {name}):
                return True
            if operand.startswith("(") and operand.endswith(")"):
                alternatives = split_top(operand[1:-1], "||")
                if alternatives and all(false_on_pr(alternative) for alternative in alternatives):
                    return True
        return False

    return bool(text) and "${{" not in (match.group(1) if match else text) and false_on_pr(match.group(1) if match else text)


@dataclass
class WorkflowChange:
    """How a cmux-next.yml change routes: `every` says why it runs every tier (None: it does not);
    otherwise `tiers` are the tiers of the Mac jobs it changed and `skipped` the changed jobs no pull
    request runs."""
    every: str | None
    tiers: dict[str, tuple[str, ...]] = field(default_factory=dict)
    skipped: list[str] = field(default_factory=list)


def workflow_change(base_text: str, head_text: str, root: Path | None = None) -> WorkflowChange:
    """What a cmux-next.yml change runs on a pull request (WORKFLOW_JOB_TIERS): nothing when it leaves
    every Mac job and every job one needs as it was, a changed job's own tiers, or every tier (a parse
    failure included, so an unreadable change runs every tier)."""
    try:
        import yaml  # noqa: PLC0415
        base = yaml.load(base_text, Loader=yaml.BaseLoader)
        head = yaml.load(head_text, Loader=yaml.BaseLoader)
    except Exception as error:  # noqa: BLE001 - any failure to compare runs every tier
        return WorkflowChange(f"the base and head workflows could not be compared ({error.__class__.__name__})")
    if not (isinstance(base, dict) and isinstance(head, dict)
            and isinstance(base.get("jobs"), dict) and isinstance(head.get("jobs"), dict)):
        return WorkflowChange("the base or head workflow has no jobs map")
    top = sorted(key for key in set(base) | set(head)
                 if key != "jobs" and key not in QUIET_WORKFLOW_KEYS and base.get(key) != head.get(key))
    if top:
        return WorkflowChange(f"its top-level {', '.join(top)} changed")
    both = (base["jobs"], head["jobs"])
    reach = {name for jobs in both for name, job in jobs.items() if not linux_job(job, root)}
    pending = list(reach)
    while pending:
        name = pending.pop()
        for jobs in both:
            job = jobs.get(name)
            needs = job.get("needs", []) if isinstance(job, dict) else []
            for need in [needs] if isinstance(needs, str) else needs if isinstance(needs, list) else []:
                if need not in reach:
                    reach.add(need)
                    pending.append(need)
    changed = sorted(name for name in set(both[0]) | set(both[1]) if both[0].get(name) != both[1].get(name))
    result = WorkflowChange(None)
    every = []
    for name in (name for name in changed if name in reach):
        old, new = both[0].get(name), both[1].get(name)
        if not (isinstance(old, dict) and isinstance(new, dict)):
            every.append(name)  # added or removed
        elif never_on_pull_request(name, both[0]) and never_on_pull_request(name, both[1]):
            result.skipped.append(name)
        elif name in WORKFLOW_JOB_TIERS and old.get("if") == new.get("if"):
            result.tiers[name] = WORKFLOW_JOB_TIERS[name]
        else:
            every.append(name)
    if every:
        return WorkflowChange(f"{', '.join(every)} {'runs' if len(every) == 1 else 'run'} on a Mac or "
                              f"feed{'s' if len(every) == 1 else ''} a Mac job")
    return result


def base_workflow_text(root: Path, rev: str) -> str | None:
    """The workflow at `rev`, or None when git cannot show it (every tier then runs for a change to it)."""
    import subprocess  # noqa: PLC0415
    try:
        return subprocess.run(["git", "-C", str(root), "show", f"{rev}:{WORKFLOW}"], check=True,
                              capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.SubprocessError):
        return None


def route(root: Path, event: str, changed: list[str] | None, labels: set[str],
          base_workflow: str | None = None) -> Route:
    """`base_workflow`: the base's cmux-next.yml, for a pull request that changes it (None: every tier)."""
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
    # A change only to `on:` or to Linux jobs no Mac job needs is a CI-only file here (actionlint and
    # the workflow tests check it); one that reaches a Mac job, or that cannot be compared, is not.
    # A change to Mac jobs WORKFLOW_JOB_TIERS lists runs their tiers, and one to jobs no pull request
    # runs adds none (workflow_change).
    quiet_workflow = False
    workflow_tiers: dict[str, tuple[str, ...]] = {}
    if WORKFLOW in changed:
        try:
            head_workflow = (root / WORKFLOW).read_text(encoding="utf-8")
        except OSError:
            head_workflow = None
        change = (WorkflowChange("its base was not read") if base_workflow is None or head_workflow is None
                  else workflow_change(base_workflow, head_workflow, root))
        if change.every:
            result.everything(f"cmux-next workflow changed ({change.every}): run every tier")
            return result
        quiet_workflow = True
        workflow_tiers = change.tiers
        for job in change.skipped:
            result.reasons.append(f"{WORKFLOW} job {job} changed {NOT_ON_PULL_REQUEST_REASON}")
        for job, job_tiers in sorted(workflow_tiers.items()):
            result.reasons.append(f"{WORKFLOW} job {job} changed: its tiers run ({', '.join(job_tiers)})")
        if not workflow_tiers:
            result.reasons.append(f"{WORKFLOW} changed only `on:`, jobs no Mac job runs on or needs, or jobs"
                                  f" no pull request runs: a CI-only file")

    graph = load_graph(root)
    tests = {name for name, target in graph["targets"].items() if target["kind"] == "test"}
    result.priority_suites = priority_suites(root, graph, changed)
    if len(result.priority_suites) > MAX_PRIORITY_SUITES:
        result.reasons.append(f"{len(result.priority_suites)} changed Swift suites: no priority shard"
                              f" (over {MAX_PRIORITY_SUITES}, its filter stalls swift-testing)")
        result.priority_suites = set()
    read = lambda path: any(matches(path, r) for name in tests for r in graph["targets"][name].get("reads", []))  # noqa: E731
    # The fast tiers: a web nit or a CI change lands in minutes. ci-web's bundle --check stands in for
    # the app compile; actionlint, the CI tests and the routing replay check CI changes. A file a Mac
    # tier reads keeps its tier, and a dev-build PR still compiles its dogfood app.
    tree_inputs_early = tree_input_paths(root)
    linux_tests = linux_guard_tests(root)
    unread = {path for path in changed if unread_doc(root, graph, path, tree_inputs_early)}
    for path in sorted(unread):
        result.reasons.append(f"{path} is a doc no test or generator names {UNREAD_DOC_REASON}")
    if "dev-build" not in labels and not workflow_tiers and all(
        (web_fast(path) or ci_only(path) or linux_only_test(path, linux_tests))
        and (path in unread or not consumed(path, tree_inputs_early, read)) for path in changed
    ):
        kinds = sorted({"CI" if ci_only(path) else "Linux-lane test" if linux_only_test(path, linux_tests)
                        else "non-app" if no_app_input(path) else "web" for path in changed})
        result.reasons.append(f"only {' and '.join(kinds)} files changed: Linux checks cover them (no Mac tier)")
        return result
    packages = package_inputs(root, graph)
    tree_inputs = tree_input_paths(root)
    daemon_closure = closure(graph, set(LIVE_DAEMON_SUBJECTS))
    # Targets whose sources (or local packages) changed: the package build itself can change. A web
    # bundle input is none of them: it changes only the resources the bundle targets copy (BUNDLE_INPUTS).
    changed_targets: set[str] = set()
    fast = fast_tier_scope(root, graph)

    for path in changed:
        if path in unread or (quiet_workflow and path == WORKFLOW):
            continue
        if any(under(path, package) for package in fast.packages):
            result.fast_package = True
        actions = fast_tier_job_actions(root) if path.startswith(".github/actions/") else frozenset()
        if path.startswith(".github/actions/") and (actions is None or any(under(path, a) for a in actions)):
            result.fast_registry = True
            result.reasons.append(f"{path} is an action the Mac fast tier job runs")
        if any(fnmatch.fnmatch(path, pattern) for pattern in WEBVIEW):
            result.webview = True
        elif any(fnmatch.fnmatch(path, pattern) for pattern in WEB_ONLY) and not path.startswith(PACKAGE):
            pass
        elif no_app_input(path):
            result.reasons.append(f"{path} is in no Mac build input {NO_SWIFT_COMPILE_REASON}")
        elif path.startswith(CMUX_TUI):
            # Rust: the daemon tier (tree inputs, below) builds and tests it. Only the
            # CCmuxAppFFI sources reach the Swift compiles, and only the app scheme's build
            # phases read the rest of what they name; nothing else needs a Mac compile.
            if any(matches(path, prefix) for prefix in app_ffi_inputs(root)):
                result.native = result.scheme = True
                result.reasons.append(f"{path} is a CCmuxAppFFI source: the Swift compiles run")
            elif "dev-build" in labels or any(matches(path, prefix) for prefix in scheme_phase_rust_inputs(root)):
                # A dev-build PR's dogfood app is the scheme compile's, with this tree bundled.
                result.scheme = True
                result.reasons.append(f"{path} is bundled by the app scheme's build phases {NO_SWIFT_COMPILE_REASON}")
            else:
                result.reasons.append(f"{path} is Rust the daemon tier builds {NO_SWIFT_COMPILE_REASON}")
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
        if path in FAST_TIER_INPUTS:
            result.fast_registry = True
            result.reasons.append(f"{path} is the Mac fast tier's registry or runner")

        if any(fnmatch.fnmatch(path, pattern) for pattern in BUNDLE_INPUTS):
            # The compiles ship the bundles; swift test reads none of their content (BUNDLE_INPUTS).
            shipped = {name for name in BUNDLE_TARGETS if name in graph["targets"]}
            result.native = True
            result.reasons.append(f"{path} is built into the web bundles of {', '.join(sorted(shipped))}"
                                  f" {BUNDLE_SWIFT_TEST_REASON}")

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
                if fast.targets is None or name in fast.targets:
                    result.fast_reads = True

    if result.full:
        return result
    for job_tiers in workflow_tiers.values():
        for tier in job_tiers:
            setattr(result, tier, True)
        result.all_tests |= "swift" in job_tiers
    result.package_build = bool(changed_targets)
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
    if result.macos() and not result.fast_tier():
        result.reasons.append(f"the Mac fast tier's package build reads none of these files {NO_FAST_TIER_REASON}")
    return result


def swift_filter(result: Route) -> str:
    """A `swift test --filter` regex for the selected test targets ('' is all)."""
    if result.full or result.all_tests:
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
    macos = result.macos()
    fast_tier = result.fast_tier()
    return {
        "native": flag(result.native),
        "swift_canary": flag(result.swift_canary),
        "cmuxnext_swift": flag(result.cmuxnext_swift),
        "mac_release": flag(result.mac_release),
        "macos": flag(macos),
        "fast_tier": flag(fast_tier),
        "scheme": flag(result.scheme or result.webview or result.full),
        "generated": flag(result.generated),
        "swift": flag(result.swift),
        "daemon": flag(result.daemon),
        "full": flag(result.full),
        "vendored_pin": flag(result.vendored_pin),
        "swift_filter": swift_filter(result),
        "swift_priority_filter": swift_priority_filter(result),
        "swift_targets": "all" if result.full or result.all_tests else " ".join(sorted(result.tests)),
        "swift_canary_targets": " ".join(sorted(result.swift_canary_targets)),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--event", required=True)
    parser.add_argument("--changed-files", type=Path)
    parser.add_argument("--labels", default="")
    parser.add_argument("--base-rev", help="the pull request's base commit, to compare a change to the workflow")
    parser.add_argument("--github-output", type=Path)
    parser.add_argument("--summary", type=Path)
    args = parser.parse_args(argv)

    changed = None
    if args.changed_files:
        changed = [line for line in args.changed_files.read_text(encoding="utf-8").splitlines() if line]
    labels = {label for label in args.labels.split(",") if label}
    base_workflow = None
    if args.base_rev and changed and WORKFLOW in changed:
        base_workflow = base_workflow_text(args.root, args.base_rev)
    result = route(args.root, args.event, changed, labels, base_workflow)
    values = outputs(result)
    lines = [f"{key}={value}" for key, value in values.items()]
    print("\n".join(lines))
    if args.github_output:
        with args.github_output.open("a", encoding="utf-8") as stream:
            stream.write("\n".join(lines) + "\n")
    if args.summary:
        with args.summary.open("a", encoding="utf-8") as stream:
            stream.write("### cmux-next tiers\n\n| tier | runs |\n| --- | --- |\n")
            for key in ("generated", "native", "swift_canary", "cmuxnext_swift", "mac_release", "scheme", "swift", "daemon", "fast_tier", "full"):
                stream.write(f"| {key} | {values[key]} |\n")
            stream.write(f"\nSwift test targets: {values['swift_targets'] or 'none'}\n\n")
            stream.write(f"Swift canary targets: {values['swift_canary_targets'] or 'none'}\n\n")
            for reason in dict.fromkeys(result.reasons):
                stream.write(f"- {reason}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
