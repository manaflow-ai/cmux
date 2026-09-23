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
import json
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
            continue  # decide() already refuses a listing containing these
        paths.append(row[1])
        if len(row) > 2 and row[2]:
            paths.append(row[2])
    return paths


def decide(rows: list[list[str]], limit: int, expected_count: int | None = None) -> tuple[bool, str, list[str]]:
    """Return (needs_scan, reason, matched_paths).

    Every branch that is not "I read a complete listing and understood every
    row" must return True. A row this function cannot parse is a listing it
    cannot vouch for, and vouching for a listing is the only thing that lets
    the required check be skipped.
    """
    if not rows:
        # An empty diff is indistinguishable here from a failed listing.
        return True, "changed-file list was empty", []

    malformed = sum(1 for row in rows if len(row) < 2)
    if malformed:
        return True, f"{malformed} unparseable row(s) in the changed-file list", []

    if len(rows) >= limit:
        return True, f"changed-file list hit the {limit}-file API limit", []

    # GitHub reports the pull request's own file count. Anything short means a
    # partial read: a dropped page, a stopped paginator, or a changed cap.
    if expected_count is not None and len(rows) != expected_count:
        return True, f"listed {len(rows)} file(s) but the pull request reports {expected_count}", []

    matched = sorted({p for p in relevant_paths(rows) if p in POLICY_FILES or is_production_source(p)})
    if matched:
        return True, f"{len(matched)} complexity-relevant path(s) changed", matched
    return False, "no production web source or complexity policy file changed", []


def decide_compare(response: dict, base: str, expected_count: int) -> tuple[bool, str, list[str]]:
    """Trust a three-dot listing only when it equals the current-base tree diff."""
    if not isinstance(base, str) or not re.fullmatch(r"[0-9a-f]{40}", base) or not isinstance(expected_count, int):
        return True, "missing immutable comparison metadata", []
    if not isinstance(response, dict) or response.get("merge_base_commit", {}).get("sha") != base:
        return True, "comparison is not based on the trusted revision", []
    files = response.get("files")
    if not isinstance(files, list) or any(not isinstance(row, dict) for row in files):
        return True, "comparison has no complete file list", []
    rows = []
    for row in files:
        name = row.get("filename")
        previous = row.get("previous_filename", "")
        if not isinstance(name, str) or not name or not isinstance(previous, str):
            return True, "comparison contains malformed paths", []
        rows.append([row.get("status", ""), name, previous])
    return decide(rows, 300, expected_count)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--compare-json")
    parser.add_argument("--trusted-base")
    parser.add_argument("--changed-files", help="TSV of status\\tfilename\\tprevious_filename")
    parser.add_argument("--limit", type=int, default=300, help="GitHub's compare-endpoint changed-file ceiling")
    parser.add_argument(
        "--expected-count",
        type=int,
        default=None,
        help="github.event.pull_request.changed_files; a short listing means a partial read",
    )
    args = parser.parse_args(argv)

    if args.compare_json:
        try:
            with open(args.compare_json, encoding="utf-8") as handle:
                response = json.load(handle)
            scan, reason, _ = decide_compare(response, args.trusted_base, args.expected_count)
        except (OSError, ValueError, TypeError, AttributeError):
            scan, reason = True, "unreadable comparison"
        print(reason, file=sys.stderr)
        print("scan=true" if scan else "scan=false")
        return 0

    try:
        # surrogateescape so a non-UTF-8 byte in a filename cannot turn a
        # decision into a traceback. Such a path will not match any policy file
        # or production extension, and a listing containing one still gets
        # classified rather than crashing the step.
        with open(args.changed_files, encoding="utf-8", errors="surrogateescape") as handle:
            rows = [line.rstrip("\n").split("\t") for line in handle if line.strip()]
    except (OSError, ValueError) as error:
        print(f"Could not read the changed-file list ({error}); running the full scan.", file=sys.stderr)
        print("scan=true")
        return 0

    needs_scan, reason, matched = decide(rows, args.limit, args.expected_count)
    print(f"Considered {len(rows)} changed file(s): {reason}.", file=sys.stderr)
    for path in matched[:20]:
        print(f"  selected: {path}", file=sys.stderr)
    if len(matched) > 20:
        print(f"  ... and {len(matched) - 20} more", file=sys.stderr)
    print("scan=true" if needs_scan else "scan=false")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
