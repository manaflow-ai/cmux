#!/usr/bin/env python3
"""Decide whether a pull request needs the full web complexity scan.

The required `Web complexity` check re-lints the entire production web tree on
every pull request, including ones that touch no web code at all. The policy it
enforces is incremental: findings are grandfathered into
`web/oxlint-complexity-baseline.txt` and that baseline may only shrink. So when
a pull request changes no production web source and no complexity policy,
toolchain, or baseline file, the scan's result cannot differ from the trusted
base it is compared against, and running it is pure cost.

This module answers exactly that question and nothing else. It never decides to
skip when it is unsure: an unreadable, truncated, or unexpected input list
returns "scan".

Security note: the paths handed to this module are candidate-controlled data.
They arrive from the GitHub pull-request files API, not from the candidate tree,
and are only ever compared as strings. Nothing here reads, executes, or resolves
a candidate path on disk.
"""

from __future__ import annotations

import argparse
import re
import sys

# Mirrors SOURCE_EXTENSIONS and EXCLUDED_PREFIXES in web/scripts/check-complexity.mjs.
# tests/test_web_complexity_scope.py asserts these stay in sync with the checker.
SOURCE_EXTENSIONS = re.compile(r"\.(?:js|jsx|mjs|cjs|ts|tsx|mts|cts)$")
EXCLUDED_PREFIXES = (
    ".next/",
    "coverage/",
    "db/migrations/",
    "e2e/",
    "node_modules/",
    "out/",
    "public/",
    "scripts/",
    "tests/",
    "tools/",
)

# Changing any of these can change the verdict for files the pull request did
# not touch, so they always take the conservative full-scan path.
POLICY_FILES = frozenset(
    {
        "web/scripts/check-complexity.mjs",
        "web/oxlint-complexity-baseline.txt",
        "web/.oxlintrc.json",
        "web/package.json",
        "web/bun.lock",
        "web/bunfig.toml",
        ".github/workflows/web-complexity-trusted.yml",
        ".github/workflows/web-complexity.yml",
        "scripts/ci/web_complexity_scope.py",
    }
)


def is_production_source(path: str) -> bool:
    """True when the checker would lint this path as production web source."""
    if not path.startswith("web/"):
        return False
    rest = path[len("web/") :]
    if not rest or rest.startswith("/"):
        return False
    if not SOURCE_EXTENSIONS.search(rest):
        return False
    return not rest.startswith(EXCLUDED_PREFIXES)


def relevant_paths(rows: list[list[str]]) -> list[str]:
    """Every path a row refers to, including the pre-rename name.

    A rename moves a file between production and non-production space, and a
    deletion can strand a grandfathered baseline entry, so both sides of every
    row matter.
    """
    paths: list[str] = []
    for row in rows:
        if len(row) < 2:
            continue
        paths.append(row[1])
        if len(row) > 2 and row[2]:
            paths.append(row[2])
    return paths


def decide(rows: list[list[str]], limit: int) -> tuple[bool, str, list[str]]:
    """Return (needs_scan, reason, matched_paths)."""
    if not rows:
        # An empty diff is indistinguishable here from a failed listing.
        return True, "changed-file list was empty", []
    if len(rows) >= limit:
        return True, f"changed-file list hit the {limit}-file API limit", []

    matched = sorted({p for p in relevant_paths(rows) if p in POLICY_FILES or is_production_source(p)})
    if matched:
        return True, f"{len(matched)} complexity-relevant path(s) changed", matched
    return False, "no production web source or complexity policy file changed", []


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--changed-files", required=True, help="TSV of status\\tfilename\\tprevious_filename")
    parser.add_argument("--limit", type=int, default=3000, help="GitHub's per-pull-request changed-file ceiling")
    args = parser.parse_args(argv)

    try:
        with open(args.changed_files, encoding="utf-8") as handle:
            rows = [line.rstrip("\n").split("\t") for line in handle if line.strip()]
    except OSError as error:
        print(f"Could not read the changed-file list ({error}); running the full scan.", file=sys.stderr)
        print("scan=true")
        return 0

    needs_scan, reason, matched = decide(rows, args.limit)
    print(f"Considered {len(rows)} changed file(s): {reason}.", file=sys.stderr)
    for path in matched[:20]:
        print(f"  selected: {path}", file=sys.stderr)
    if len(matched) > 20:
        print(f"  ... and {len(matched) - 20} more", file=sys.stderr)
    print("scan=true" if needs_scan else "scan=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
