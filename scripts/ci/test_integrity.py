#!/usr/bin/env python3
"""Fail a change that removes or weakens executable tests.

This is intentionally a diff check rather than a coverage guess.  It catches
test files deleted from a change, assertion counts that shrink in a test file,
and newly added skip/ignore markers.  Assertion replacements with the same
count are allowed, so normal expectation updates do not create a false alarm.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


TEST_FILE = re.compile(
    r"(?:^|/)(?:tests?|cmuxTests?)(?:/|$)|"
    r"(?:^|/)(?:test_[^/]+|[^/]+_test|[^/]+\.(?:test|spec)|test(?:[-.]|$)[^/]*)\.[^/]+$|"
    r"(?:^|/)[^/]*Tests?(?:/|\.[^/]+$)",
    re.IGNORECASE,
)
ASSERTION = re.compile(
    r"\b(?:assert\w*|"
    r"expect|require|check|XCTAssert\w*|assert_(?:eq|ne|same|is|in|false|true)|"
    r"pytest\.raises|pytest\.fail|self\.fail)\b|\b(?:toBe|toEqual|toHave\w*)\s*\(",
    re.IGNORECASE,
)
SKIP = re.compile(
    r"(?:pytest\.(?:mark\.)?(?:skip|xfail)|unittest\.skip|skipTest|XCTSkip|"
    r"test\.skip|describe\.skip|it\.skip|#\[ignore\]|@Disabled|@Ignore)",
    re.IGNORECASE,
)
TEST_DEF = re.compile(r"^\s*(?:def\s+test\w*|async\s+def\s+test\w*|(?:it|test)\s*\()", re.IGNORECASE)


@dataclass(frozen=True)
class Finding:
    kind: str
    path: str
    detail: str


def is_test_path(path: str) -> bool:
    return bool(TEST_FILE.search(path))


def is_guard_path(path: str) -> bool:
    return path == "scripts/ci/test_integrity.py"


def _sections(diff: str) -> list[tuple[str, list[str], list[str]]]:
    """Return (path, removed, added) for each unified-diff file section."""
    sections: list[tuple[str, list[str], list[str]]] = []
    path = ""
    removed: list[str] = []
    added: list[str] = []
    for line in diff.splitlines():
        if line.startswith("diff --git "):
            if path:
                sections.append((path, removed, added))
            path = ""
            removed, added = [], []
        elif line.startswith("+++ b/"):
            path = line[6:]
        elif line.startswith("--- ") or line.startswith("@@") or line.startswith("index "):
            continue
        elif line.startswith("-"):
            removed.append(line[1:])
        elif line.startswith("+"):
            added.append(line[1:])
    if path:
        sections.append((path, removed, added))
    return sections


def analyze(name_status: str, diff: str) -> list[Finding]:
    findings: list[Finding] = []
    statuses: dict[str, str] = {}
    for row in name_status.splitlines():
        fields = row.split("\t")
        if len(fields) >= 2:
            status, path = fields[0][0], fields[-1]
            statuses[path] = status
            if status == "D" and is_test_path(path):
                findings.append(Finding("deleted-test-file", path, "test file was deleted"))
            elif status == "R" and is_test_path(fields[1]) and not is_test_path(path):
                findings.append(Finding("deleted-test-file", fields[1], f"test file renamed to {path}"))

    for path, removed, added in _sections(diff):
        if is_guard_path(path) or not is_test_path(path):
            continue
        old_assertions = sum(len(ASSERTION.findall(line)) for line in removed)
        new_assertions = sum(len(ASSERTION.findall(line)) for line in added)
        if old_assertions > new_assertions:
            findings.append(Finding(
                "weakened-assertions", path,
                f"removed {old_assertions} assertion line(s), added {new_assertions}",
            ))
        old_skips = sum(bool(SKIP.search(line)) for line in removed)
        new_skips = [line.strip() for line in added if SKIP.search(line)]
        if len(new_skips) > old_skips:
            findings.append(Finding("new-skip", path, new_skips[0][:200]))
        removed_defs = sum(bool(TEST_DEF.search(line)) for line in removed)
        added_defs = sum(bool(TEST_DEF.search(line)) for line in added)
        if removed_defs > added_defs and old_assertions == 0:
            findings.append(Finding(
                "deleted-test-case", path,
                f"removed {removed_defs} test definition(s), added {added_defs}",
            ))
    return findings


def _git(*args: str) -> str:
    return subprocess.check_output(["git", *args], text=True, stderr=subprocess.STDOUT)


def resolve_base(explicit: str | None) -> str:
    base = explicit or os.environ.get("TEST_INTEGRITY_BASE_SHA") or os.environ.get("GITHUB_BASE_SHA")
    if base:
        try:
            _git("cat-file", "-e", f"{base}^{{commit}}")
            return base
        except subprocess.CalledProcessError:
            pass
    for candidate in ("HEAD^1", "HEAD~1"):
        try:
            return _git("rev-parse", candidate).strip()
        except subprocess.CalledProcessError:
            continue
    raise SystemExit("test-integrity: no base commit available; set TEST_INTEGRITY_BASE_SHA")


def run(base: str) -> list[Finding]:
    name_status = _git("diff", "--name-status", "--find-renames", base, "HEAD", "--")
    diff = _git("diff", "--unified=0", "--find-renames", base, "HEAD", "--")
    return analyze(name_status, diff)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--base", help="base commit (defaults to TEST_INTEGRITY_BASE_SHA/GITHUB_BASE_SHA)")
    parser.add_argument("--json", action="store_true", help="emit machine-readable findings")
    parser.add_argument("--strict", action="store_true", help="return failure when findings exist")
    parser.add_argument("--allow-all", action="store_true",
                        help="record findings but accept an explicitly approved change")
    args = parser.parse_args(argv)
    base = resolve_base(args.base)
    findings = run(base)
    payload = {"base": base, "head": _git("rev-parse", "HEAD").strip(), "findings": [asdict(f) for f in findings]}
    if args.json:
        print(json.dumps(payload, sort_keys=True))
    elif findings:
        summary = os.environ.get("GITHUB_STEP_SUMMARY")
        if summary:
            with open(summary, "a", encoding="utf-8") as handle:
                handle.write("## Test integrity findings\n\n")
                for finding in findings:
                    handle.write(f"- `{finding.kind}`: `{finding.path}` — {finding.detail}\n")
        for finding in findings:
            print(f"::warning file={finding.path},title=Test integrity::{finding.detail}")
            print(f"{finding.kind}: {finding.path}: {finding.detail}", file=sys.stderr)
    if findings and args.allow_all:
        print("test-integrity: findings explicitly approved by the trusted workflow")
        return 0
    if findings:
        print(f"test-integrity: {len(findings)} finding(s); restore coverage or remove the weakening", file=sys.stderr)
        return 1 if args.strict else 0
    print("test-integrity: no deleted or weakened tests")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
