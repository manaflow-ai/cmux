#!/usr/bin/env python3
"""Which groups of .github/workflows/swift-linux-packages.yml a pull request's change can fail.

    swift_linux_reach.py --changed FILE [--root DIR] [--github-output PATH]

FILE lists the changed paths (one per line, or NUL-separated), as `git diff --name-only HEAD^1 HEAD`
of the merge commit writes them. Prints one JSON object and, with --github-output, writes `groups` (a
JSON list of the matrix's group names to run) and `listed` (the rows of scripts/ci/swift-linux-packages.txt
the listed group runs: `*` for every row, else their package directories, space-separated).

A group runs when the change touches one of its packages or a package it reaches through
`.package(path:)` dependencies (transitively), or a file every group runs (WHOLE_RUN). Every
other group is skipped, together with every step of it, so the suites a change cannot fail are not
rebuilt and rerun on each head. Before this, a pull request that touched one Shared package ran all
eleven groups: about 3.4 min each, 54k runner-minutes a day at the 11-25 18-24Z rate.

The rule fails open. A file under a package root that belongs to no package, a list or manifest that
does not parse, or any other error runs every group. A push, a dispatch and the base batch never
call this, so they run every group too.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
WORKFLOW = ".github/workflows/swift-linux-packages.yml"
LIST = "scripts/ci/swift-linux-packages.txt"
# Where a package this workflow tests, or a package one of those depends on, can live.
PACKAGE_ROOTS = ("Packages/", "cmux-next-ios/CmuxMobileKit/", "vendor/stack-auth-swift-sdk-prerelease/")
# Every group runs on a change to any of these: the scripts and the workflow every group runs through.
WHOLE_RUN = (
    WORKFLOW,
    "scripts/ci/swift_linux_reach.py",
    "scripts/ci/package-test-lane.sh",
    "scripts/ci/swift-test-debug-info.sh",
    "scripts/ci/swiftpm-binary-module-guard.sh",
)
# The listed group runs every row on a change to the list itself.
LISTED_WHOLE = (LIST,)
# A package whose Linux shape is only some of its targets: only these paths reach its listed row
# (scripts/ci/pr_router.json's `affects` for this workflow names the same paths).
NARROW = {
    "Packages/macOS/CmuxNext": (
        "Packages/macOS/CmuxNext/Package.swift",
        "Packages/macOS/CmuxNext/Package.resolved",
        "Packages/macOS/CmuxNext/Sources/CmuxNextAgentPanePlacement/",
        "Packages/macOS/CmuxNext/Sources/CmuxNextChromiumRuntime/",
        "Packages/macOS/CmuxNext/Sources/CmuxNextHostPressure/",
        "Packages/macOS/CmuxNext/Tests/CmuxNextAgentPanePlacementTests/",
        "Packages/macOS/CmuxNext/Tests/CmuxNextChromiumRuntimeTests/",
        "Packages/macOS/CmuxNext/Tests/CmuxNextHostPressureTests/",
    ),
}
PATH_DEP = re.compile(r'\.package\(\s*(?:name:\s*"[^"]*"\s*,\s*)?path:\s*"([^"]+)"', re.S)


def matrix_groups(root: Path) -> dict[str, list[str]]:
    """Group name -> its package directories, from the workflow's matrix (`listed` has none here)."""
    groups: dict[str, list[str]] = {}
    current = None
    lines = (root / WORKFLOW).read_text().splitlines()
    i = 0
    while i < len(lines):
        line = lines[i]
        start = re.match(r"^\s*- group:\s*(\S+)\s*$", line)
        if start:
            current = start.group(1)
            groups[current] = []
        elif current:
            field = re.match(r"^\s+packages:\s*(.*)$", line)
            if field:
                value = field.group(1).strip()
                if value in (">-", ">", "|", "|-"):
                    indent = None
                    while i + 1 < len(lines):
                        nxt = lines[i + 1]
                        lead = len(nxt) - len(nxt.lstrip())
                        if not nxt.strip() or (indent is not None and lead < indent) or lead <= len(line) - len(line.lstrip()):
                            break
                        indent = lead if indent is None else indent
                        groups[current] += nxt.split()
                        i += 1
                else:
                    groups[current] += value.split()
            elif re.match(r"^\s*steps:\s*$", line):
                break
        i += 1
    if "listed" not in groups or len(groups) < 2:
        raise ValueError(f"{WORKFLOW}: no matrix groups read")
    return groups


def listed_rows(root: Path) -> list[str]:
    rows = []
    for line in (root / LIST).read_text().splitlines():
        if line.strip() and not line.lstrip().startswith("#"):
            rows.append(line.split()[0].rstrip("/"))
    if not rows:
        raise ValueError(f"{LIST}: no rows")
    return rows


def packages(root: Path) -> dict[str, set[str]]:
    """Every package directory under PACKAGE_ROOTS -> the package directories it names by path."""
    found: dict[str, set[str]] = {}
    for top in PACKAGE_ROOTS:
        base = root / top
        if not base.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in (".build", ".git", "node_modules", ".swiftpm")]
            if "Package.swift" in filenames:
                rel = Path(dirpath).relative_to(root).as_posix()
                text = (Path(dirpath) / "Package.swift").read_text(errors="replace")
                deps = {os.path.normpath(os.path.join(rel, m.group(1))) for m in PATH_DEP.finditer(text)}
                found[rel] = deps
    return found


def owner(path: str, pkgs: dict[str, set[str]]) -> str | None:
    """The deepest package directory holding path, or None."""
    best = None
    for p in pkgs:
        if path.startswith(p + "/") and (best is None or len(p) > len(best)):
            best = p
    return best


def reach(changed: list[str], root: Path = ROOT) -> dict:
    groups = matrix_groups(root)
    rows = listed_rows(root)
    names = list(groups)
    if any(f in WHOLE_RUN for f in changed):
        return {"groups": names, "listed": "*", "why": "a file every group runs changed"}
    pkgs = packages(root)
    touched: set[str] = set()
    for f in changed:
        if not f.startswith(PACKAGE_ROOTS):
            continue
        p = owner(f, pkgs)
        if p is None:
            if f.startswith("Packages/macOS/"):
                continue  # no macOS-only package is tested here, and none is a dependency of one that is
            return {"groups": names, "listed": "*", "why": f"{f} belongs to no package"}
        if p in NARROW and not f.startswith(NARROW[p]):
            continue
        touched.add(p)

    memo: dict[str, bool] = {}

    def reached(p: str, seen: frozenset = frozenset()) -> bool:
        if p in memo:
            return memo[p]
        if p in touched:
            memo[p] = True
            return True
        if p in seen:
            return False
        hit = any(reached(d, seen | {p}) for d in pkgs.get(p, ()))
        memo[p] = hit
        return hit

    run = [g for g, dirs in groups.items() if g != "listed" and any(reached(d.rstrip("/")) for d in dirs)]
    if any(f in LISTED_WHOLE for f in changed):
        listed = "*"
    else:
        hit = [r for r in rows if reached(r)]
        listed = " ".join(hit)
    if listed:
        run.insert(0, "listed")
    return {"groups": run, "listed": listed, "why": f"{len(touched)} package(s) touched"}


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--changed", required=True)
    ap.add_argument("--root", default=str(ROOT))
    ap.add_argument("--github-output")
    args = ap.parse_args(argv)
    root = Path(args.root)
    try:
        raw = Path(args.changed).read_text()
        changed = [p for p in re.split(r"[\0\n]", raw) if p.strip()]
        out = reach(changed, root)
    except Exception as err:  # fail open: every group runs
        try:
            names = list(matrix_groups(root))
        except Exception:
            names = []
        out = {"groups": names, "listed": "*", "why": f"error, every group runs: {err}", "all": not names}
    print(json.dumps(out))
    if args.github_output:
        with open(args.github_output, "a", encoding="utf-8") as f:
            f.write(f"groups={json.dumps(out['groups'])}\n")
            f.write(f"listed={out['listed']}\n")
            f.write(f"all={'true' if out.get('all') else 'false'}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
