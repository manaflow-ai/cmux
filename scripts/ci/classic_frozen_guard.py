#!/usr/bin/env python3
"""Fail a pull request that changes a classic-frozen path (.github/classic-frozen.txt) without `classic-migration`.

The files classic cmux customers depend on are frozen until Leo decides the migration. A pull request into
feat-cmux-next or main whose diff touches one of them fails unless it carries the label `classic-migration`, which
is Leo's to add. A rule's scope is `all` (both bases) or `main` (main only). NEXT Cloud backend code goes to
manaflow-ai/cmux-platform.

Leo, 2026-11-04: "is it possible to HARD MARK certain files or whatever as like "classic, don't touch until we
decide to do the migration"".

Also a library: `load(path)` and `frozen(rules, base, paths)` are what leo-workspace's tools read the same file with.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_MANIFEST = ROOT / ".github" / "classic-frozen.txt"
LABEL = "classic-migration"
SCOPES = ("all", "main")


def glob_regex(pattern: str) -> re.Pattern[str]:
    """`**` crosses directories, `*` and `?` stay within one path segment (classic_api_guard.py's globs)."""
    out = []
    i = 0
    while i < len(pattern):
        if pattern.startswith("**/", i):
            out.append("(?:.*/)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        elif pattern[i] == "?":
            out.append("[^/]")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def parse(text: str) -> list[dict]:
    """The manifest's rules, each {glob, scope, reason}. A malformed line raises ValueError (a typo never unfreezes)."""
    rules = []
    for number, raw in enumerate(text.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        parts = line.split(None, 2)
        if len(parts) < 3 or parts[1] not in SCOPES:
            raise ValueError(f"classic-frozen.txt line {number}: want `GLOB all|main REASON`, got {raw!r}")
        rules.append({"glob": parts[0], "scope": parts[1], "reason": parts[2], "re": glob_regex(parts[0])})
    if not rules:
        raise ValueError("classic-frozen.txt has no rules")
    return rules


def load(path: Path = DEFAULT_MANIFEST) -> list[dict]:
    return parse(path.read_text())


def frozen(rules: list[dict], base: str, paths: list[str]) -> list[tuple[str, dict]]:
    """(path, first matching rule) for each changed path frozen into BASE."""
    hits = []
    for path in paths:
        for rule in rules:
            if (rule["scope"] == "all" or base == "main") and rule["re"].match(path):
                hits.append((path, rule))
                break
    return hits


def check(rules: list[dict], base: str, labels: list[str], paths: list[str],
          expected_files: int | None = None, listed_records: int | None = None) -> tuple[int, list[str]]:
    """(exit code, annotation lines). A listing shorter than the PR's changed-file count may hide a frozen path past
    GitHub's 3,000-file end, so it fails too unless the label is on."""
    migration = LABEL in labels
    hits = frozen(rules, base, paths)
    listed = listed_records if listed_records is not None else len(set(paths))
    if expected_files is not None and listed < expected_files and not migration:
        return 1, [f"::error::The changed-file listing has {listed} paths but the pull request changes "
                   f"{expected_files}; a classic-frozen path may be past its end. Split the pull request."]
    if not hits:
        return 0, ["::notice::No classic-frozen path changed (.github/classic-frozen.txt)."]
    lines = [f"{path} (frozen by `{rule['glob']}` {rule['scope']}: {rule['reason']})" for path, rule in hits]
    shown = lines[:20] + ([f"... and {len(lines) - 20} more"] if len(lines) > 20 else [])
    if migration:
        return 0, [f"::notice::classic-migration label: classic-frozen change allowed: {line}" for line in shown]
    out = [f"::error::Classic, frozen: {line}" for line in shown]
    out.append(
        "::error::This pull request changes files classic cmux customers depend on, frozen until Leo decides the "
        f"migration (.github/classic-frozen.txt). Drop those changes: NEXT work skips classic code, and NEXT Cloud "
        f"backend code goes to manaflow-ai/cmux-platform. Only Leo adds the `{LABEL}` label that lets it through."
    )
    return 1, out


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--base", required=True, help="the pull request's base branch")
    parser.add_argument("--paths-file", type=Path, required=True, help="changed paths, one per line")
    parser.add_argument("--labels-json", default="[]", help="the pull request's label names, a JSON list")
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--expected-files", type=int, default=None, help="the pull request's changed_files")
    parser.add_argument("--listed-records", type=int, default=None, help="file records the listing returned")
    args = parser.parse_args(argv)
    try:
        rules = load(args.manifest)
    except (OSError, ValueError) as exc:
        print(f"::error::Could not read the classic-frozen manifest: {exc}")
        return 1
    paths = [line.strip() for line in args.paths_file.read_text().splitlines() if line.strip()]
    try:
        labels = [str(name) for name in json.loads(args.labels_json or "[]")]
    except (ValueError, TypeError) as exc:
        print(f"::error::Could not read the pull request's labels: {exc}")
        return 1
    code, lines = check(rules, args.base, labels, paths, args.expected_files, args.listed_records)
    for line in lines:
        print(line)
    return code


if __name__ == "__main__":
    sys.exit(main())
