#!/usr/bin/env python3
"""Pick the Swift test targets a change can break, for the fleet test compile.

fleet/compile-check (.github/workflows/fleet-compile-check.yml) compiles the
app executable, which links no test target. A change can still break a test
target's compile (#23360: a throwing call inside `#expect` without `try`;
#23163: a fake that missed a protocol requirement). This picks what the
advisory fleet-test-compile.yml check builds (`package-test-lane.sh
compile-tests` on a fleet Mac), from the files the change touches; an empty
plan queues no Mac:

  CmuxNext    the test targets that depend on a changed target, from the
              SwiftPM target graph (Packages/macOS/CmuxNext/ci-target-graph.json,
              the same routing scripts/ci/cmux_next_route.py gives the swift
              test tier). A manifest or graph change is every test target.
  packages    each package of the macOS package lane (PACKAGES in
              scripts/ci/package-test-lane.sh) whose directory or local path
              dependencies changed: all its test targets.

Only files inside a package or one of its path dependencies count; a Markdown
file never does. Other local packages (iOS, Shared libraries without a macOS
lane) build in their own jobs, not with a macOS `swift build`.

Prints one line per package: its directory, then the test targets to build,
or the directory alone for every test target of the package.

--skip-package DIR leaves a package out. The pull-request check passes
Packages/macOS/CmuxNext: cmux-next.yml's swift test job already runs `swift
build --build-tests` on every same-repository pull request whose change
reaches a CmuxNext test target (the same route, a superset of these targets),
so compiling them again on a fleet Mac was a second compile of the same tree.
The tip compile and a hand-run `compile-tests` keep CmuxNext.

Usage: compile_test_plan.py --changed-files FILE [--root DIR] [--skip-package DIR ...]
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from cmux_next_route import PACKAGE, closure, load_graph, route  # noqa: E402,F401
from select_package_tests import input_prefixes, package_dirs, under  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
CMUXNEXT = PACKAGE.rstrip("/")
LANE = "scripts/ci/package-test-lane.sh"
LANE_PACKAGES = re.compile(r"^\s*PACKAGES=\(\n(.*?)\n\s*\)", re.S | re.M)


def lane_packages(root: Path) -> list[str]:
    """The packages the macOS package lane tests (its PACKAGES list)."""
    found = LANE_PACKAGES.search((root / LANE).read_text(encoding="utf-8"))
    if not found:
        raise SystemExit(f"no PACKAGES=( ... ) list in {LANE}")
    return [line.strip() for line in found.group(1).splitlines() if line.strip() and not line.strip().startswith("#")]


def cmuxnext_targets(root: Path, changed: list[str]) -> list[str] | None:
    """The CmuxNext test targets `changed` can break; None for every one."""
    result = route(root, "pull_request", changed, set())
    graph = load_graph(root)
    every = sorted(name for name, target in graph["targets"].items() if target["kind"] == "test")
    targets = every if result.full else sorted(result.tests)
    return None if targets == every else targets


def plan(root: Path, changed: list[str], skip: frozenset[str] = frozenset()) -> list[tuple[str, list[str] | None]]:
    """[(package directory, test targets or None for all)] for the changed files, without the `skip` directories."""
    changed = [path for path in changed if path and not path.endswith(".md")]
    dirs = package_dirs(root)
    result: list[tuple[str, list[str] | None]] = []
    for name in [Path(CMUXNEXT).name, *lane_packages(root)]:
        if name not in dirs or dirs[name] in skip or any(directory == dirs[name] for directory, _ in result):
            continue
        prefixes = input_prefixes(root, name, dirs)
        hits = [path for path in changed if any(under(path, prefix) for prefix in prefixes)]
        if not hits:
            continue
        if dirs[name] == CMUXNEXT:
            targets = cmuxnext_targets(root, hits)
            if targets == []:
                continue
            result.append((dirs[name], targets))
        else:
            result.append((dirs[name], None))
    return result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=ROOT)
    parser.add_argument("--changed-files", type=Path, required=True, help="one path per line")
    parser.add_argument("--skip-package", action="append", default=[], metavar="DIR",
                        help="leave this package directory out of the plan (repeatable)")
    args = parser.parse_args(argv)
    skip = frozenset(path.strip("/") for path in args.skip_package)
    unknown = sorted(skip - set(package_dirs(args.root).values()))
    if unknown:
        parser.error(f"--skip-package: not a local package directory: {', '.join(unknown)}")
    changed = args.changed_files.read_text(encoding="utf-8").splitlines()
    for directory, targets in plan(args.root, changed, skip):
        print(" ".join([directory, *(targets or [])]))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
