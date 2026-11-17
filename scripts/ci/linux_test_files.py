#!/usr/bin/env python3
"""Plan a linux-tests.yml run: the test files an agent named, grouped by the bun package they belong to.

    linux_test_files.py plan --root CHECKOUT --files "webviews/test/a.test.tsx web/lib/x.test.ts"

Writes one line per package to stdout, `PACKAGE<TAB>FILE FILE ...`, with each
file relative to its package (the directory holding the nearest package.json
with a bun.lock). A path with no package prefix is read as relative to
webviews/, where most of these tests live. Every path must name an existing
test file inside the checkout; anything else is refused before a runner
installs a thing.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import sys

TEST_NAME = re.compile(r"(?:\.test|_test|\.spec|_spec)\.(?:ts|tsx|js|jsx|mjs)$")
SAFE_PATH = re.compile(r"[A-Za-z0-9._@+/-]+")
DEFAULT_PACKAGE = "webviews"


class PlanError(ValueError):
    pass


OTHER_RUNNERS = ("vitest", "jest", "@playwright/test", "mocha")


def package_of(root: Path, path: Path) -> Path | None:
    """The nearest directory above path, up to and including root, with a package.json and a bun.lock."""
    for parent in path.parents:
        if parent != root and root not in parent.parents:
            return None
        if (parent / "package.json").is_file() and (parent / "bun.lock").is_file():
            return parent
        if parent == root:
            return None
    return None


def other_runner(package: Path) -> str | None:
    """The test runner a package uses instead of bun test, from its test script and dependencies."""
    try:
        manifest = json.loads((package / "package.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    script = str((manifest.get("scripts") or {}).get("test") or "")
    deps = {**(manifest.get("dependencies") or {}), **(manifest.get("devDependencies") or {})}
    for runner in OTHER_RUNNERS:
        if runner in script or (runner in deps and "bun test" not in script):
            return runner
    return None


def plan(root: Path, files: str) -> dict[str, list[str]]:
    root = root.resolve()
    names = files.split()
    if not names:
        raise PlanError("no test files given")
    grouped: dict[str, list[str]] = {}
    for name in names:
        if not SAFE_PATH.fullmatch(name) or name.startswith("/") or ".." in name.split("/"):
            raise PlanError(f"{name!r}: give a relative path inside the repository")
        if not TEST_NAME.search(name):
            raise PlanError(f"{name}: not a test file name (*.test.ts, *_test.tsx, *.spec.ts, ...)")
        path = root / name
        if not path.is_file() and (root / DEFAULT_PACKAGE / name).is_file():
            path = root / DEFAULT_PACKAGE / name
        if not path.is_file():
            raise PlanError(f"{name}: no such file at this commit")
        path = path.resolve()
        if root not in path.parents:
            raise PlanError(f"{name}: resolves outside the checkout")
        package = package_of(root, path)
        if package is None:
            raise PlanError(f"{name}: not inside a bun package (a directory with package.json and bun.lock)")
        runner = other_runner(package)
        if runner:
            raise PlanError(f"{name}: its package tests with {runner}, not bun test; this lane runs bun test only")
        key = package.relative_to(root).as_posix() or "."
        relative = path.relative_to(package).as_posix()
        if relative not in grouped.setdefault(key, []):
            grouped[key].append(relative)
    return dict(sorted(grouped.items()))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    planned = sub.add_parser("plan")
    planned.add_argument("--root", type=Path, required=True)
    planned.add_argument("--files", required=True)
    args = parser.parse_args(argv)
    try:
        grouped = plan(args.root, args.files)
    except PlanError as error:
        print(f"::error::{error}", file=sys.stderr)
        return 2
    for package, files in grouped.items():
        print(f"{package}\t{' '.join(files)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
