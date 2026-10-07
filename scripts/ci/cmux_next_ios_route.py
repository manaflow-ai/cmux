#!/usr/bin/env python3
"""Pick the cmux-next iOS jobs a change needs (.github/workflows/cmux-next-ios.yml).

Packages: the Packages/ roots in scripts/cmux-next/mobile-scan-roots.txt whose
tests a change can affect. A package is selected when it, a package it depends
on by path (transitively, as scripts/ci/select_package_tests.py resolves it),
or a repository file its tests read (a `schemas/<dir>` literal in its tests or
manifest) changed. A change to the workflow or to a script its package job
runs selects every package. Paths outside those inputs select nothing.

Backend: the protocol vitest (backend/packages/protocol) runs when backend/ or
schemas/mobile-rpc/ changed; the API vitest runs when schemas/mobile-rpc/
changed (backend.yml already runs it for every backend/ change).

Without --changed-files (a push, a dispatch, an unknown diff) every job runs.

Usage: cmux_next_ios_route.py [--root DIR] [--changed-files FILE] [--github-output FILE]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from select_package_tests import input_prefixes, package_dirs, under  # noqa: E402

ROOTS_FILE = "scripts/cmux-next/mobile-scan-roots.txt"
# The package job itself: a change here can change any package's outcome.
GLOBAL_INPUTS = (
    ".github/workflows/cmux-next-ios.yml",
    "scripts/ci/cmux_next_ios_route.py",
    "scripts/ci/select_package_tests.py",
    "scripts/ci/hung_test_watchdog.py",
    "scripts/select-ci-xcode.sh",
    "scripts/ci/xcode-pins.txt",
    ".xcode-version",
    ROOTS_FILE,
)
SCHEMA_READ = re.compile(r'"(?:\.\./)*(schemas/[A-Za-z0-9_.-]+)')


def mobile_packages(root: Path) -> list[str]:
    """Package names of the Packages/ roots in mobile-scan-roots.txt, in file order."""
    names = []
    for raw in (root / ROOTS_FILE).read_text(encoding="utf-8").splitlines():
        entry = raw.strip()
        if entry and not entry.startswith("#") and entry.startswith("Packages/"):
            names.append(Path(entry).name)
    return names


def read_prefixes(root: Path, directory: str) -> set[str]:
    """Repository directories a package's tests or manifest name in string literals."""
    found = set()
    package = root / directory
    sources = [package / "Package.swift", *sorted((package / "Tests").rglob("*.swift"))]
    for path in sources:
        if path.is_file():
            for match in SCHEMA_READ.findall(path.read_text(encoding="utf-8", errors="replace")):
                found.add(match.rstrip("/") + "/")
    return found


def select_packages(root: Path, changed: list[str] | None) -> list[str]:
    packages = mobile_packages(root)
    if changed is None or any(path in GLOBAL_INPUTS for path in changed):
        return packages
    dirs = package_dirs(root)
    missing = [name for name in packages if name not in dirs]
    if missing:
        raise SystemExit(f"{ROOTS_FILE} names packages that are not under Packages/*/: {', '.join(missing)}")
    selected = []
    for name in packages:
        prefixes = input_prefixes(root, name, dirs) | read_prefixes(root, dirs[name])
        if any(under(path, prefix) for path in changed for prefix in prefixes):
            selected.append(name)
    return selected


def route(root: Path, changed: list[str] | None) -> dict[str, object]:
    def touched(*prefixes: str) -> bool:
        return changed is None or any(path.startswith(prefixes) for path in changed)

    return {
        "packages": select_packages(root, changed),
        "protocol": touched("backend/", "schemas/mobile-rpc/", ".github/workflows/cmux-next-ios.yml"),
        "api": touched("schemas/mobile-rpc/", ".github/workflows/cmux-next-ios.yml"),
    }


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", default=".")
    parser.add_argument("--changed-files", help="one path per line; omit when the diff is unknown")
    parser.add_argument("--github-output", help="append packages=, package_count=, protocol=, api= here")
    args = parser.parse_args(argv)
    root = Path(args.root)
    changed = None
    if args.changed_files:
        changed = [line for line in Path(args.changed_files).read_text(encoding="utf-8").splitlines() if line]
    result = route(root, changed)
    lines = [
        f"packages={json.dumps(result['packages'])}",
        f"package_count={len(result['packages'])}",
        f"protocol={'true' if result['protocol'] else 'false'}",
        f"api={'true' if result['api'] else 'false'}",
    ]
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as out:
            out.write("\n".join(lines) + "\n")
    print("\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
