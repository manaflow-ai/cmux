#!/usr/bin/env python3
"""Pick the Swift packages whose tests a change can affect.

A package's tests can change outcome only when the package, a package it
depends on by path (transitively), one of its declared extra inputs, or the
test job itself changes. Everything else in the repository is either known not
to reach package tests (app sources, app tests, web, docs, other workflows and
scripts) or unknown, and an unknown path selects every package.
"""

from __future__ import annotations

import argparse
import re
import sys
from functools import lru_cache
from pathlib import Path

PATH_DEPENDENCY = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*",\s*)?path:\s*"([^"]+)"')

# Inputs outside a package's own directory and its path dependencies.
EXTRA_INPUTS = {
    "CmuxCommandPalette": ("Native/CommandPaletteNucleoFFI/",),
}

# The job itself: its workflow, the scripts its test steps call, and the pinned
# toolchain and GhosttyKit revision. A change to any of these selects everything.
GLOBAL_INPUTS = (
    ".github/workflows/ci.yml",
    ".github/workflows/ci-macos.yml",
    "scripts/build-ghostty-cli-helper.sh",
    "scripts/ci/release-build-archs.sh",
    "scripts/ci/ci_process_tree.py",
    "scripts/ci/hung_test_watchdog.py",
    "scripts/ci/require_swift_test_execution.py",
    "scripts/ci/run-swift-testing-suites.sh",
    "scripts/ci/run_with_timeout.py",
    "scripts/ci/select_package_tests.py",
    "scripts/ci/verify-binary-archs.sh",
    "scripts/download-prebuilt-ghosttykit.sh",
    "scripts/install-rust-ci.sh",
    "scripts/install-zig-ci.sh",
    "scripts/ghostty-zig-version.sh",
    "scripts/ghosttykit-checksums.txt",
    "scripts/validate-xcframework-archive.py",
    "scripts/select-ci-xcode.sh",
    ".xcode-version",
    "ghostty",
)

# Paths that cannot reach a package test. Anything not listed here, not under
# Packages/, and not a path dependency selects every package.
UNRELATED_PREFIXES = (
    "Sources/",
    "CLI/",
    "TunnelExtension/",
    "Resources/",
    "cmuxTests/",
    "cmuxUITests/",
    "cmux.xcodeproj/",
    "cmux.xcworkspace/",
    "ios/",
    "web/",
    "docs/",
    "skills/",
    "tests/",
    "daemon/",
    "cmux-tui/",
    "Examples/",
    ".github/",
    "scripts/",
    "workers/",
    "tests_v2/",
)
UNRELATED_SUFFIXES = (".md",)


def package_dirs(root: Path) -> dict[str, str]:
    """Package name -> repository-relative directory, for Packages/<group>/<name>."""
    return {
        manifest.parent.name: manifest.parent.relative_to(root).as_posix()
        for manifest in sorted(root.glob("Packages/*/*/Package.swift"))
    }


def path_dependencies(root: Path, directory: str) -> set[str]:
    """Repository-relative directories the package at `directory` depends on by path."""
    manifest = root / directory / "Package.swift"
    found = set()
    for relative in PATH_DEPENDENCY.findall(manifest.read_text(encoding="utf-8")):
        resolved = (root / directory / relative).resolve()
        try:
            found.add(resolved.relative_to(root.resolve()).as_posix())
        except ValueError:
            continue
    return found


def input_prefixes(root: Path, name: str, dirs: dict[str, str]) -> set[str]:
    """Every directory prefix whose contents feed `name`'s tests."""
    prefixes: set[str] = set()
    pending = [dirs[name]]
    while pending:
        directory = pending.pop()
        prefix = directory.rstrip("/") + "/"
        if prefix in prefixes:
            continue
        prefixes.add(prefix)
        if (root / directory / "Package.swift").is_file():
            pending.extend(path_dependencies(root, directory))
    dependency_names = {Path(prefix).name for prefix in prefixes}
    for owner, extra in EXTRA_INPUTS.items():
        if owner in dependency_names:
            prefixes.update(extra)
    return prefixes


def under(path: str, prefix: str) -> bool:
    """True for a file below the directory `prefix`, or for the directory itself,
    which is how a submodule's revision change appears in a diff."""
    return path.startswith(prefix) or path == prefix.rstrip("/")


def select(root: Path, packages: list[str], changed: list[str] | None) -> list[str]:
    """`changed` is None when the diff is unknown, which selects everything."""
    dirs = package_dirs(root)
    missing = [name for name in packages if name not in dirs]
    if missing:
        raise SystemExit(f"package not found under Packages/*/: {', '.join(missing)}")
    if changed is None:
        return packages

    inputs = {name: input_prefixes(root, name, dirs) for name in packages}
    known = set().union(*inputs.values()) if inputs else set()
    for path in changed:
        if path in GLOBAL_INPUTS:
            print(f"{path} is an input of the package test job; selecting every package", file=sys.stderr)
            return packages
        if path.startswith("Packages/") or any(under(path, prefix) for prefix in known):
            continue
        if path.startswith(UNRELATED_PREFIXES) or path.endswith(UNRELATED_SUFFIXES):
            continue
        print(f"{path} is not a known package input; selecting every package", file=sys.stderr)
        return packages
    return [
        name
        for name in packages
        if any(under(path, prefix) for path in changed for prefix in inputs[name])
    ]


@lru_cache(maxsize=1)
def routed_input_prefixes(root: Path) -> frozenset[str]:
    """Known package inputs, including transitive local dependencies outside Packages/."""
    dirs = package_dirs(root)
    return frozenset(
        prefix for name in dirs for prefix in input_prefixes(root, name, dirs)
    )


def is_routed_input(path: str, root: Path) -> bool:
    """Inputs eligible to start the targeted PR lane, excluding global sweeps.

    Use the same dependency graph as selection: a vendor submodule revision or
    source change can affect package tests just as a change inside Packages/ can.
    """
    return path.startswith("Packages/") or any(
        under(path, prefix) for prefix in routed_input_prefixes(root)
    )


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".")
    parser.add_argument("--changed-files", help="one path per line; omit when the diff is unknown")
    parser.add_argument("--routed-inputs-only", action="store_true",
                        help="select only inputs eligible for the targeted PR lane")
    parser.add_argument("packages", nargs="+")
    args = parser.parse_args(argv)

    changed = None
    if args.changed_files:
        changed = [line for line in Path(args.changed_files).read_text(encoding="utf-8").splitlines() if line]
    if args.routed_inputs_only:
        if changed is None:
            parser.error("--routed-inputs-only requires --changed-files")
        changed = [path for path in changed if is_routed_input(path, Path(args.root))]
    # The list has historical duplicates; keep the first of each.
    packages = list(dict.fromkeys(args.packages))
    for name in select(Path(args.root), packages, changed):
        print(name)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
