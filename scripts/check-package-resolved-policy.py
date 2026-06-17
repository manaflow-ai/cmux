#!/usr/bin/env python3
"""Verify cmux-owned SwiftPM lockfiles are not ignored."""

from __future__ import annotations

from fnmatch import fnmatchcase
from pathlib import Path
import subprocess
import sys


ALLOWED_IGNORED_PREFIXES = (
    "vendor/",
    "ghostty/",
)

XCODE_PACKAGE_RESOLVED = "cmux.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"

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


def package_roots() -> set[str]:
    roots: set[str] = set()
    for manifest in git_ls_files("*Package.swift"):
        if is_allowed_vendor_path(manifest) or has_skipped_part(manifest):
            continue
        roots.add(Path(manifest).parent.as_posix())
    return roots


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
    roots = package_roots()

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

    for lockfile in git_ls_files("*Package.resolved"):
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
