#!/usr/bin/env python3
"""Decide whether the iOS simulator app build is affected by a file list.

The app project owns the local ``ios/CmuxiOS`` package.  Its Package.swift
path dependencies form a transitive closure.  A PR that only edits another
local package still runs the lightweight package lane, while the Xcode app
build can be omitted when no app input is reachable.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


_PATH_DEPENDENCY = re.compile(r"\.package\(\s*(?:name:\s*\"[^\"]*\"\s*,\s*)?path:\s*\"([^\"]+)\"")
_PROJECT_PACKAGE = re.compile(
    r"(?ms)XCLocalSwiftPackageReference[^=]*=\s*\{.*?"
    r"\brelativePath\s*=\s*\"?([^\";\n]+)\"?\s*;"
)
_PACKAGE_ROOTS = ("Packages/", "vendor/")
_DOC_ROOTS = ("docs/",)


def _package_dependencies(manifest: Path) -> list[str]:
    text = manifest.read_text(encoding="utf-8")
    # URL dependencies are intentionally ignored. Only local path dependencies
    # can add repository files to the app input closure.
    return _PATH_DEPENDENCY.findall(text)


def package_closure(root: Path) -> frozenset[str]:
    """Return package directories reachable from the Xcode app project."""
    project = root / "ios/cmux-ios.xcodeproj/project.pbxproj"
    text = project.read_text(encoding="utf-8")
    relative_paths = [value.strip().strip('"') for value in _PROJECT_PACKAGE.findall(text)]
    if not relative_paths:
        raise ValueError(f"no local Swift package references in {project}")

    roots: list[str] = []
    for relative in relative_paths:
        candidate = (project.parent.parent / relative).resolve()
        try:
            path = candidate.relative_to(root.resolve()).as_posix()
        except ValueError as error:
            raise ValueError(f"Xcode package path escapes repository: {relative}") from error
        if not (root / path / "Package.swift").is_file():
            raise ValueError(f"missing package manifest: {path}/Package.swift")
        roots.append(path)

    visited: set[str] = set()
    pending = roots[:]
    while pending:
        directory = pending.pop()
        if directory in visited:
            continue
        visited.add(directory)
        manifest = root / directory / "Package.swift"
        for relative in _package_dependencies(manifest):
            candidate = (manifest.parent / relative).resolve()
            try:
                dependency = candidate.relative_to(root.resolve()).as_posix()
            except ValueError as error:
                raise ValueError(f"package dependency escapes repository: {directory} -> {relative}") from error
            if not (root / dependency / "Package.swift").is_file():
                raise ValueError(f"missing package manifest: {dependency}/Package.swift")
            pending.append(dependency)
    return frozenset(visited)


def _under(path: str, directory: str) -> bool:
    return path == directory or path.startswith(directory + "/")


def affected(root: Path, changed: list[str]) -> tuple[bool, str]:
    """Return ``(run, reason)``. Unknown inputs fail open to a build."""
    if not changed:
        return True, "no changed-file list"
    try:
        closure = package_closure(root)
    except (OSError, ValueError) as error:
        return True, f"could not derive package closure: {error}"

    # The Xcode project, app shell, workflow and build helpers are direct app
    # inputs.  A package diff can be narrowed when documentation is mixed into
    # it, since docs do not alter the package graph or compiled sources.
    package_changes = [
        path for path in changed
        if any(_under(path, prefix.rstrip("/")) for prefix in _PACKAGE_ROOTS)
    ]
    non_package_changes = [path for path in changed if path not in package_changes]
    if not package_changes:
        return True, "a direct iOS/Xcode or CI input changed"
    if any(not any(_under(path, prefix.rstrip("/")) for prefix in _DOC_ROOTS)
           for path in non_package_changes):
        return True, "a direct iOS/Xcode or CI input changed"

    for path in package_changes:
        if path.endswith("/Package.swift") or path.endswith("/Package.resolved"):
            # A manifest in the closure can add an edge or alter products.
            if any(_under(path, directory) for directory in closure):
                return True, f"dependency manifest changed in closure: {path}"
        if any(_under(path, directory) for directory in closure):
            return True, f"app dependency changed: {path}"

    return False, "all changed packages are outside the Xcode app dependency closure"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--changed-files", type=Path, required=True)
    args = parser.parse_args()
    changed = [line.strip().replace("\\", "/") for line in args.changed_files.read_text(encoding="utf-8").splitlines() if line.strip()]
    run, reason = affected(args.root.resolve(), changed)
    print(f"run={str(run).lower()}")
    print(f"reason={reason}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
