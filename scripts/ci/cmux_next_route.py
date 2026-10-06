#!/usr/bin/env python3
"""Route a feat-cmux-next pull request to the cmux-next checks its change can break.

Every check in .github/workflows/cmux-next.yml has a tier, and a pull request
runs the tiers its changed files reach (docs/ci/cmux-next-tiers.md):

  checks      always: god files, concurrency, crash safety, string tables,
              script tests, package conventions (Linux, about a minute)
  generated   any change to the CmuxNext package or plans/cmux-next: the
              generated action catalog, surfaces and inventory and the CI target
              graph are fresh (a mini; a stale file is fixed by a bot commit)
  native      Swift or app sources: the Release compile
  scheme      app host, Xcode project, webviews or other local packages: the
              Debug compile of the cmux app scheme
  swift       the CmuxNext test targets the change can affect, from the SwiftPM
              target graph (Packages/macOS/CmuxNext/ci-target-graph.json)
  daemon      the daemon, Rust core, FFI or control paths: the same-tree
              cmux-tui fetch and the live-daemon suites

Pushes, dispatches and pull requests labeled `full-ci` (a batch integration
PR) run every tier. A changed file this script cannot place selects every
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
)

GENERATED_INPUTS = (
    PACKAGE,
    "plans/cmux-next/",
    "scripts/cmux-next/regenerate-action-contracts.sh",
    "scripts/cmux-next/check-action-surfaces.sh",
)

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


@dataclass
class Route:
    full: bool = False
    native: bool = False
    webview: bool = False
    scheme: bool = False
    generated: bool = False
    swift: bool = False
    daemon: bool = False
    tests: set[str] = field(default_factory=set)
    reasons: list[str] = field(default_factory=list)

    def everything(self, reason: str) -> None:
        self.full = self.native = self.scheme = self.generated = self.swift = self.daemon = True
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


def route(root: Path, event: str, changed: list[str] | None, labels: set[str]) -> Route:
    result = Route()
    if event != "pull_request":
        result.everything(f"{event}: base coverage runs every tier")
        return result
    if "full-ci" in labels:
        result.everything("labeled full-ci (batch integration PR): every tier")
        return result
    if not changed:
        result.everything("the diff is unknown or empty: every tier")
        return result

    graph = load_graph(root)
    tests = {name for name, target in graph["targets"].items() if target["kind"] == "test"}
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

        if path in FULL_INPUTS:
            result.everything(f"{path} is an input of every package test")
            continue
        if any(matches(path, prefix) for prefix in tree_inputs) or path in DAEMON_PATHS:
            result.daemon = True
            result.reasons.append(f"{path} reaches the daemon")
        if any(matches(path, prefix) for prefix in SWIFT_JOB_INPUTS):
            result.swift = True
            result.reasons.append(f"{path} is a swift test job script")

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
    if result.webview:
        result.scheme = True
    return result


def swift_filter(result: Route) -> str:
    """A `swift test --filter` regex for the selected test targets ('' is all)."""
    if result.full:
        return ""
    return "^(" + "|".join(sorted(result.tests)) + ")\\." if result.tests else ""


def outputs(result: Route) -> dict[str, str]:
    flag = lambda value: "true" if value else "false"  # noqa: E731
    # Any tier that needs a Mac: the placement job places these runs.
    macos = result.native or result.webview or result.swift or result.generated or result.daemon
    return {
        "native": flag(result.native),
        "macos": flag(macos),
        "scheme": flag(result.scheme or result.webview or result.full),
        "generated": flag(result.generated),
        "swift": flag(result.swift),
        "daemon": flag(result.daemon),
        "full": flag(result.full),
        "swift_filter": swift_filter(result),
        "swift_targets": "all" if result.full else " ".join(sorted(result.tests)),
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
            for key in ("generated", "native", "scheme", "swift", "daemon", "full"):
                stream.write(f"| {key} | {values[key]} |\n")
            stream.write(f"\nSwift test targets: {values['swift_targets'] or 'none'}\n\n")
            for reason in dict.fromkeys(result.reasons):
                stream.write(f"- {reason}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
