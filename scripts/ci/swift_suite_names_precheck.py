#!/usr/bin/env python3
"""Refuse CMUX_SWIFT_TEST_SUITES names a package's test sources never mention, before the build.

run-swift-testing-suites.sh checks each requested suite against `swift test list`,
which comes only after the package builds (11 to 58 minutes on the fleet). A typo,
or a suite of another package, wasted the whole build slot first. This scan reads
the package's test sources and refuses a name only when it is clearly not there:
the name (its last dotted part, for Target.Suite) appears nowhere in them as a
word. Attributes on their own lines, nested types, `@Suite("display name")`,
extensions and top-level `@Test` functions all keep the name in the source, so
they pass. When the scan cannot tell (no test sources found), every name passes.
The post-build check against `swift test list` stays the authority.

For a refused name it also says which other package under Packages/ declares a
type of that name.

Usage: swift_suite_names_precheck.py <package-path> <name>...
Exit 0: every name may be a suite. Exit 2: at least one is not (message on stderr).
"""

from __future__ import annotations

import pathlib
import re
import sys

SKIP_DIRS = {".build", ".swiftpm", ".git"}
# A target's own `path:` (testTarget(name:, path: "Tests/X")); `.package(path:)` is a dependency.
TARGET_PATH = re.compile(r'(?<!\.package\()\bpath:\s*"([^"]+)"')
DEPENDENCY_PATH = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"([^"]+)"')


def swift_files(root: pathlib.Path):
    if not root.is_dir():
        return
    stack = [root]
    while stack:
        directory = stack.pop()
        try:
            entries = list(directory.iterdir())
        except OSError:
            continue
        for entry in entries:
            if entry.is_dir() and not entry.is_symlink():
                if entry.name not in SKIP_DIRS:
                    stack.append(entry)
            elif entry.suffix == ".swift":
                yield entry


def test_roots(package: pathlib.Path) -> list[pathlib.Path]:
    """Tests/ plus any target path Package.swift names outside it."""
    roots = [package / "Tests"]
    manifest = package / "Package.swift"
    try:
        text = manifest.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return roots
    dependencies = set(DEPENDENCY_PATH.findall(text))
    for path in TARGET_PATH.findall(text):
        if path in dependencies or path.startswith("Sources"):
            continue
        candidate = package / path
        if not any(candidate == root or root in candidate.parents for root in roots):
            roots.append(candidate)
    return roots


def word(name: str) -> re.Pattern[str]:
    return re.compile(r"(?<![A-Za-z0-9_])" + re.escape(name) + r"(?![A-Za-z0-9_])")


def missing_names(package: pathlib.Path, names: list[str]) -> list[str] | None:
    """Names whose last dotted part no test source mentions; None when there is nothing to scan."""
    wanted = {name: name.rsplit(".", 1)[-1] for name in names}
    patterns = {short: word(short) for short in set(wanted.values())}
    unseen = set(patterns)
    scanned = 0
    for root in test_roots(package):
        for path in swift_files(root):
            scanned += 1
            try:
                text = path.read_text(encoding="utf-8", errors="replace")
            except OSError:
                return None  # an unreadable source could hold the suite
            unseen = {short for short in unseen if not patterns[short].search(text)}
            if not unseen:
                return []
    if scanned == 0:
        return None
    return [name for name, short in wanted.items() if short in unseen]


def packages_root(package: pathlib.Path) -> pathlib.Path | None:
    for directory in (package, *package.parents):
        if (directory / "Packages").is_dir():
            return directory / "Packages"
    return None


def owning_packages(package: pathlib.Path, short: str) -> list[str]:
    """Other packages under Packages/ whose tests declare a type named short."""
    root = packages_root(package)
    if root is None:
        return []
    declared = re.compile(
        r"\b(?:struct|class|actor|enum|extension)\s+" + re.escape(short) + r"(?![A-Za-z0-9_])")
    found: list[str] = []
    for manifest in sorted(root.rglob("Package.swift")):
        other = manifest.parent
        if SKIP_DIRS & set(other.relative_to(root).parts) or other == package:
            continue
        for path in swift_files(other / "Tests"):
            try:
                if declared.search(path.read_text(encoding="utf-8", errors="replace")):
                    found.append(str(other.relative_to(root.parent)))
                    break
            except OSError:
                continue
    return found


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print("usage: swift_suite_names_precheck.py <package-path> <name>...", file=sys.stderr)
        return 64
    given, names = argv[0], argv[1:]
    package = pathlib.Path(given).resolve()
    missing = missing_names(package, names)
    if not missing:
        return 0
    for name in missing:
        message = f"CMUX_SWIFT_TEST_SUITES names {name}, which is not a suite of {given}"
        owners = owning_packages(package, name.rsplit(".", 1)[-1])
        if owners:
            message += f" ({name.rsplit('.', 1)[-1]} is in {', '.join(owners)})"
        print(message + "; no test source of the package mentions it, so nothing was built", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
