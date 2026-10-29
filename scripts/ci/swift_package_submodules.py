#!/usr/bin/env python3
"""Print the submodule paths a Swift package reaches through local dependencies.

Follows `.package(path: "...")` from the package's Package.swift through every
local package it reaches, and prints, relative to the repository root, each
submodule (from .gitmodules) one of those paths lies in. Fleet ci-steps check
the ref out with every submodule deinitialized, so run-swift-testing-suites.sh
populates these before `swift test list`.

Usage: swift_package_submodules.py <repo-root> <package-path>
"""

import pathlib
import re
import subprocess
import sys

LOCAL_DEPENDENCY = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"([^"]+)"')


def submodule_paths(root: pathlib.Path) -> list[pathlib.Path]:
    if not (root / ".gitmodules").is_file():
        return []
    listed = subprocess.run(
        ["git", "config", "--file", ".gitmodules", "--get-regexp", r"^submodule\..*\.path$"],
        cwd=root, capture_output=True, text=True, check=False,
    ).stdout
    return [(root / line.split(maxsplit=1)[1]).resolve() for line in listed.splitlines() if " " in line]


def main() -> int:
    root = pathlib.Path(sys.argv[1]).resolve()
    submodules = submodule_paths(root)
    reached: list[pathlib.Path] = []
    pending = [pathlib.Path(sys.argv[2]).resolve()]
    seen: set[pathlib.Path] = set()
    while pending:
        package = pending.pop()
        if package in seen:
            continue
        seen.add(package)
        for submodule in submodules:
            if package == submodule or submodule in package.parents:
                if submodule not in reached:
                    reached.append(submodule)
                break
        manifest = package / "Package.swift"
        if manifest.is_file():
            text = manifest.read_text(encoding="utf-8", errors="replace")
            pending.extend((package / path).resolve() for path in LOCAL_DEPENDENCY.findall(text))
    for submodule in reached:
        print(submodule.relative_to(root))
    return 0


if __name__ == "__main__":
    sys.exit(main())
