#!/usr/bin/env python3
"""Test categories: what a test is for decides when it runs and when it goes.

Leo, 2026-11-22: "we need to get rid of the notion that we run tests indefinitely after they get created. full
stop. we need to be categorizing these better from the get-go ... vacuously true is as good as waste."
Design: cmuxterm-hq docs/design/test-lifecycle.md.

Every test file carries one category line in its first 40 lines (`//` in TS/JS, `#` in Python and shell):

    // test-category: proof owner=NAME review-by=YYYY-MM-DD   showed one PR's behaviour; runs only on pull requests
                                                             that touch it or its direct subject, then ages out
    // test-category: proof owner=NAME review-by=... tier=sampled   a demoted proof: runs only in the nightly sample
    // test-category: guard why=TEXT                         protects a real invariant or a past bug: always runs
    // test-category: contract why=TEXT                      pins an API, protocol or file format: always runs

A file without the line takes its entry in the legacy manifest (webviews/test-categories.json, written by the
categorizing pass and the sweep), else it is `unclassified` and runs as a guard does (what every test did before).
A proof past its review-by runs as tier=sampled until the sweep deletes or re-categorizes it.

    test_lifecycle.py category FILE...                        print each file's resolved category as JSON lines
    test_lifecycle.py filter LIST --tier TIER [--root DIR]    LIST: NUL-separated test files relative to DIR (the
        runner's list); rewrite it to the files TIER runs. TIER: pull_request (CMUX_PR_CHANGED_FILES names the
        change's repo paths), push, nightly, all (no filter). Prints one summary line on stderr.
    test_lifecycle.py lint --base REF [--head REF] [--repo DIR]   fail when the change adds a test file with no
        category line, or a proof with no owner or a review-by not within PROOF_MAX_DAYS
    test_lifecycle.py report [--root DIR]                     counts per category and tier, as JSON
"""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
from pathlib import Path

CATEGORIES = ("proof", "guard", "contract")
UNCLASSIFIED = "unclassified"
PROOF_MAX_DAYS = 90
HEADER_LINES = 40
MANIFEST = "test-categories.json"
LINE_RE = re.compile(r"^\s*(?://|#|\*|/\*)\s*test-category:\s*(?P<cat>[a-z]+)(?P<rest>.*)$")
ATTR_RE = re.compile(r"(?P<key>[a-z-]+)=(?P<value>\S+)")
# Test files the lint covers, by repo path. webviews: the runner's patterns (run-webviews-tests.sh).
TEST_PATTERNS = (
    re.compile(r"^webviews/.*(\.test\.(ts|tsx|js|jsx|mjs)|_test\.(ts|tsx)|\.spec\.(ts|tsx)|_spec\.(ts|tsx))$"),
    re.compile(r"^(tests|scripts/ci/tests|tools/tests)/(.*/)?test_[^/]*\.py$"),
    re.compile(r"^(tests|scripts/ci/tests)/(.*/)?[^/]*\.test\.sh$"),
)
IMPORT_RE = re.compile(r"""(?:from\s+|import\s*\(\s*|import\s+|require\(\s*)["'](\.{1,2}/[^"'?]+)""")
SOURCE_EXTS = ("", ".ts", ".tsx", ".js", ".jsx", ".mjs", "/index.ts", "/index.tsx")


def today() -> dt.date:
    forced = os.environ.get("TEST_LIFECYCLE_TODAY")
    return dt.date.fromisoformat(forced) if forced else dt.datetime.now(dt.timezone.utc).date()


def parse_header(text: str) -> dict | None:
    """The category line of a file's text, or None. An unknown category is returned as is (lint names it)."""
    for line in text.splitlines()[:HEADER_LINES]:
        match = LINE_RE.match(line)
        if not match:
            continue
        entry: dict = {"category": match.group("cat"), "source": "header"}
        rest = match.group("rest")
        why = re.search(r"why=(.*)$", rest)
        if why:
            entry["why"] = why.group(1).strip().rstrip("*/").strip()
            rest = rest[: why.start()]
        for attr in ATTR_RE.finditer(rest):
            entry[attr.group("key").replace("-", "_")] = attr.group("value")
        return entry
    return None


def load_manifest(root: Path) -> dict:
    path = root / MANIFEST
    try:
        data = json.loads(path.read_text())
    except (OSError, ValueError):
        return {}
    files = data.get("files") if isinstance(data, dict) else None
    return files if isinstance(files, dict) else {}


def resolve(root: Path, name: str, manifest: dict, text: str | None = None) -> dict:
    """A file's category, owner, review-by and effective tier (`always`, `touched`, `sampled`)."""
    if text is None:
        try:
            with open(root / name, encoding="utf-8", errors="replace") as handle:
                text = "".join(handle.readline() for _ in range(HEADER_LINES))
        except OSError:
            text = ""
    entry = parse_header(text)
    if entry is None:
        legacy = manifest.get(name)
        entry = dict(legacy, source="manifest") if isinstance(legacy, dict) else {"category": UNCLASSIFIED,
                                                                                   "source": "none"}
    entry["file"] = name
    category = entry.get("category")
    if category != "proof":
        entry["tier"] = "always"
        return entry
    review_by = entry.get("review_by")
    expired = False
    if review_by:
        try:
            expired = dt.date.fromisoformat(review_by) < today()
        except ValueError:
            expired = True
    else:
        expired = True
    entry["expired"] = expired
    entry["tier"] = "sampled" if expired or entry.get("tier") == "sampled" else "touched"
    return entry


def direct_subjects(root: Path, name: str) -> set[str]:
    """The files a test imports by relative path, relative to root: what it is the proof of."""
    try:
        text = (root / name).read_text(errors="replace")
    except OSError:
        return set()
    found = set()
    base = (root / name).parent
    for spec in IMPORT_RE.findall(text):
        for ext in SOURCE_EXTS:
            candidate = (base / (spec + ext)).resolve()
            if candidate.is_file():
                try:
                    found.add(str(candidate.relative_to(root.resolve())))
                except ValueError:
                    pass
                break
    return found


def read_list(path: Path) -> list[str]:
    return [item.decode() for item in path.read_bytes().split(b"\0") if item]


def changed_files(root: Path) -> set[str] | None:
    """The change's files relative to root (webviews/), from CMUX_PR_CHANGED_FILES (repo paths)."""
    listed = os.environ.get("CMUX_PR_CHANGED_FILES")
    if not listed:
        return None
    try:
        lines = Path(listed).read_text().splitlines()
    except OSError:
        return None
    prefix = os.environ.get("CMUX_TEST_LIFECYCLE_PREFIX", root.resolve().name + "/")
    return {line[len(prefix):] if line.startswith(prefix) else line for line in lines if line.strip()}


def runs(entry: dict, tier: str, changed: set[str] | None, root: Path) -> bool:
    if tier == "all":
        return True
    if tier == "nightly":
        return entry["tier"] == "sampled"
    if entry["tier"] == "always":
        return True
    if entry["tier"] == "sampled" or tier != "pull_request":
        return False
    if changed is None:  # no diff to judge by: run it, as before
        return True
    name = entry["file"]
    return name in changed or bool(direct_subjects(root, name) & changed)


def cmd_filter(args: argparse.Namespace) -> int:
    root = Path(args.root)
    path = Path(args.list)
    listed = read_list(path)
    manifest = load_manifest(root)
    changed = changed_files(root) if args.tier == "pull_request" else None
    keep, dropped = [], {"always": 0, "touched": 0, "sampled": 0}
    for name in listed:
        entry = resolve(root, name, manifest)
        if runs(entry, args.tier, changed, root):
            keep.append(name)
        else:
            dropped[entry["tier"] if entry["tier"] in dropped else "sampled"] += 1
    path.write_bytes(b"".join(name.encode() + b"\0" for name in keep))
    print(f"test categories ({args.tier}): {len(keep)} of {len(listed)} files run; skipped "
          f"{dropped['always']} guards, contracts and unclassified (not in this tier), "
          f"{dropped['touched']} live proofs this change leaves alone and {dropped['sampled']} in the nightly sample",
          file=sys.stderr)
    return 0


def cmd_category(args: argparse.Namespace) -> int:
    root = Path(args.root)
    manifest = load_manifest(root)
    for name in args.files:
        print(json.dumps(resolve(root, name, manifest), sort_keys=True))
    return 0


def cmd_report(args: argparse.Namespace) -> int:
    root = Path(args.root)
    manifest = load_manifest(root)
    names = subprocess.run(["git", "ls-files", "--", "."], cwd=root, capture_output=True, text=True,
                           check=True).stdout.split()
    counts: dict[str, int] = {}
    for name in names:
        if not TEST_PATTERNS[0].match("webviews/" + name):
            continue
        entry = resolve(root, name, manifest)
        key = f"{entry['category']}/{entry['tier']}"
        counts[key] = counts.get(key, 0) + 1
    print(json.dumps(counts, indent=2, sort_keys=True))
    return 0


def lint_problems(name: str, text: str, now: dt.date) -> list[str]:
    entry = parse_header(text)
    hint = ("add `// test-category: proof owner=NAME review-by=YYYY-MM-DD` (it showed this change once), "
            "`guard why=...` (a real invariant or past bug) or `contract why=...` (an API or format) in its first "
            f"{HEADER_LINES} lines; docs/design/test-lifecycle.md in cmuxterm-hq")
    if entry is None:
        return [f"{name}: a new test file has no category line: {hint}"]
    category = entry["category"]
    if category not in CATEGORIES:
        return [f"{name}: unknown test category {category!r}: {hint}"]
    problems = []
    if category == "proof":
        if not entry.get("owner"):
            problems.append(f"{name}: a proof test names its owner (owner=NAME)")
        review_by = entry.get("review_by")
        try:
            when = dt.date.fromisoformat(review_by or "")
        except ValueError:
            problems.append(f"{name}: a proof test names a review-by date (review-by=YYYY-MM-DD)")
        else:
            if when < now or when > now + dt.timedelta(days=PROOF_MAX_DAYS):
                problems.append(f"{name}: review-by {review_by} is not within {PROOF_MAX_DAYS} days of {now}")
    elif not entry.get("why"):
        problems.append(f"{name}: a {category} test says what it protects (why=...)")
    return problems


def is_test_path(path: str) -> bool:
    return any(pattern.match(path) for pattern in TEST_PATTERNS)


def cmd_lint(args: argparse.Namespace) -> int:
    repo = Path(args.repo)
    diff = subprocess.run(["git", "diff", "--name-only", "--diff-filter=A", "--no-renames", f"{args.base}...{args.head}"],
                          cwd=repo, capture_output=True, text=True)
    if diff.returncode != 0:
        print(f"test categories: git diff failed: {diff.stderr.strip()}", file=sys.stderr)
        return 2
    added = [path for path in diff.stdout.split() if is_test_path(path)]
    problems = []
    now = today()
    for path in added:
        shown = subprocess.run(["git", "show", f"{args.head}:{path}"], cwd=repo, capture_output=True, text=True)
        problems += lint_problems(path, shown.stdout if shown.returncode == 0 else "", now)
    for problem in problems:
        print(f"::error title=test category::{problem}")
    print(f"test categories: {len(added)} new test files, {len(problems)} problems", file=sys.stderr)
    return 1 if problems else 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("category")
    p.add_argument("files", nargs="+")
    p.add_argument("--root", default=".")
    p.set_defaults(func=cmd_category)
    p = sub.add_parser("filter")
    p.add_argument("list")
    p.add_argument("--tier", required=True, choices=("pull_request", "push", "nightly", "all"))
    p.add_argument("--root", default=".")
    p.set_defaults(func=cmd_filter)
    p = sub.add_parser("lint")
    p.add_argument("--base", required=True)
    p.add_argument("--head", default="HEAD")
    p.add_argument("--repo", default=".")
    p.set_defaults(func=cmd_lint)
    p = sub.add_parser("report")
    p.add_argument("--root", default=".")
    p.set_defaults(func=cmd_report)
    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
