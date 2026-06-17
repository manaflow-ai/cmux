#!/usr/bin/env python3
"""Verify cmux-owned SwiftPM lockfiles are not ignored."""

from __future__ import annotations

from fnmatch import fnmatchcase
from pathlib import Path
import re
import subprocess
import sys


ALLOWED_IGNORED_PREFIXES = (
    "vendor/",
    "ghostty/",
)

XCODE_PACKAGE_RESOLVED = (
    "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)
PACKAGE_DEPENDENCY_RE = re.compile(r"\.package\(([^)]*)\)", re.DOTALL)
PACKAGE_PATH_ARGUMENT_RE = re.compile(r'\bpath\s*:\s*"([^"]+)"')
PACKAGE_URL_ARGUMENT_RE = re.compile(r'\burl\s*:\s*"[^"]+"')

SKIPPED_DIRS = {
    ".build",
    ".git",
    ".swiftpm",
    ".ci-source-packages",
    "DerivedData",
    "node_modules",
}


def git_ls_files(*args: str) -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", *args],
        check=True,
        stdout=subprocess.PIPE,
        text=True,
    )
    return [line for line in result.stdout.splitlines() if line]


def is_allowed_vendor_path(path: str) -> bool:
    return path.startswith(ALLOWED_IGNORED_PREFIXES)


def has_skipped_part(path: str) -> bool:
    return any(part in SKIPPED_DIRS for part in Path(path).parts)


def tracked_package_manifests(*, include_allowed_vendor: bool) -> dict[str, Path]:
    manifests: dict[str, Path] = {}
    for manifest in git_ls_files("*Package.swift"):
        if has_skipped_part(manifest):
            continue
        if not include_allowed_vendor and is_allowed_vendor_path(manifest):
            continue
        path = Path(manifest)
        manifests[path.parent.as_posix()] = path
    return manifests


def package_graph(manifests: dict[str, Path]) -> dict[str, tuple[bool, list[str]]]:
    root_by_resolved_path = {
        manifest.parent.resolve(): root for root, manifest in manifests.items()
    }
    graph: dict[str, tuple[bool, list[str]]] = {}

    for root, manifest in manifests.items():
        text = manifest.read_text(encoding="utf-8")
        path_dependencies: list[str] = []
        has_url_dependency = False
        for dependency in PACKAGE_DEPENDENCY_RE.findall(text):
            if PACKAGE_URL_ARGUMENT_RE.search(dependency):
                has_url_dependency = True
            path_match = PACKAGE_PATH_ARGUMENT_RE.search(dependency)
            if path_match is None:
                continue
            dependency_root = (manifest.parent / path_match.group(1)).resolve()
            if dependency_root in root_by_resolved_path:
                path_dependencies.append(root_by_resolved_path[dependency_root])
        graph[root] = (has_url_dependency, path_dependencies)

    return graph


def package_roots_requiring_lockfiles() -> set[str]:
    all_manifests = tracked_package_manifests(include_allowed_vendor=True)
    cmux_manifests = tracked_package_manifests(include_allowed_vendor=False)
    graph = package_graph(all_manifests)
    memo: dict[str, bool] = {}

    def has_remote_dependency(root: str, visiting: set[str]) -> bool:
        if root in memo:
            return memo[root]
        if root in visiting:
            return False
        has_url_dependency, path_dependencies = graph.get(root, (False, []))
        visiting.add(root)
        needs_lockfile = has_url_dependency or any(
            has_remote_dependency(dependency, visiting)
            for dependency in path_dependencies
        )
        visiting.remove(root)
        memo[root] = needs_lockfile
        return needs_lockfile

    return {
        root for root in cmux_manifests
        if has_remote_dependency(root, set())
    }


def package_lockfile_path(root: str) -> str:
    if root == ".":
        return "Package.resolved"
    return f"{root}/Package.resolved"


def is_expected_lockfile_path(lockfile: str, roots: set[str]) -> bool:
    if lockfile == XCODE_PACKAGE_RESOLVED:
        return True
    if has_skipped_part(lockfile):
        return False
    return Path(lockfile).parent.as_posix() in roots


def ignores_package_resolved(gitignore: Path) -> bool:
    ignored = False

    for raw_line in gitignore.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue

        is_negated = line.startswith("!")
        pattern = line[1:] if is_negated else line
        pattern = pattern.rstrip("/").lstrip("/")
        if pattern == "Package.resolved" or pattern.endswith("/Package.resolved"):
            ignored = not is_negated
            continue
        if fnmatchcase("Package.resolved", pattern):
            ignored = not is_negated
    return ignored


def main() -> int:
    errors: list[str] = []
    roots = set(tracked_package_manifests(include_allowed_vendor=False))
    tracked_lockfiles = set(git_ls_files("*Package.resolved"))

    for gitignore in sorted(Path(".").rglob(".gitignore")):
        rel = gitignore.as_posix()
        if rel.startswith("./"):
            rel = rel[2:]
        if has_skipped_part(rel):
            continue
        if not ignores_package_resolved(gitignore):
            continue
        if is_allowed_vendor_path(rel):
            continue
        errors.append(
            f"{rel} ignores Package.resolved. cmux-owned SwiftPM lockfiles must be tracked."
        )

    for expected_root in sorted(package_roots_requiring_lockfiles()):
        expected_lockfile = package_lockfile_path(expected_root)
        if expected_lockfile in tracked_lockfiles:
            continue
        errors.append(
            f"Missing Package.resolved for SwiftPM package with remote pins: {expected_lockfile}"
        )

    for lockfile in tracked_lockfiles:
        if is_allowed_vendor_path(lockfile):
            continue
        if is_expected_lockfile_path(lockfile, roots):
            continue
        errors.append(f"Unexpected cmux Package.resolved location: {lockfile}")

    if errors:
        print("Package.resolved policy violations:", file=sys.stderr)
        for error in errors:
            print(f"- {error}", file=sys.stderr)
        return 1

    print("Package.resolved policy OK")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
