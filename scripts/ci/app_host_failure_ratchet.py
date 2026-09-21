#!/usr/bin/env python3
"""Gate only complete assertion-only app-host runs against a shrink-only current-main catalog."""

from __future__ import annotations

import argparse
import io
import json
import re
import subprocess
import sys
from pathlib import Path
from typing import Any, Optional

ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
XCTEST_SUMMARY_RE = re.compile(
    r"Executed\s+(?P<tests>\d+)\s+tests?,\s+with\s+"
    r"(?P<failures>\d+)\s+failures?\s+"
    r"\((?P<unexpected>\d+)\s+unexpected\)"
)
SWIFT_SUMMARY_RE = re.compile(
    r"Test run with (?P<tests>\d+) tests?\b[^\n]*?\b(?P<result>passed|failed)\b"
)
XCTEST_ERROR_RE = re.compile(
    r"error:\s+-\[(?P<suite>[^\s\]]+)\s+(?P<test>[^\]]+)\]\s*:"
)
XCTEST_FAILED_RE = re.compile(
    r"Test Case '-\[(?P<suite>[^\s\]]+)\s+(?P<test>[^\]]+)\]' failed"
)
SWIFT_ISSUE_RE = re.compile(r"✘\s+Test\s+(?P<test>.+?)\s+recorded an issue\b")
SWIFT_FAILED_RE = re.compile(r"✘\s+Test\s+(?P<test>.+?)\s+failed(?:\s|\.)")
INCOMPLETE_RE = re.compile(
    r"(?:Restarting after unexpected exit, crash, or test timeout|"
    r"Time limit was exceeded:|"
    r"xcodebuild unit-test batch \d+/\d+ timeout after)",
    re.IGNORECASE,
)
HOST_FAILURE_RE = re.compile(
    r"(?:test runner .*?(?:timed out|hung|failed)|"
    r"Failed to establish communication with the test runner|"
    r"testmanagerd.*invalidated|Couldn't communicate with a helper|"
    r"Fatal error:|Program crashed|\*\*\*\s+Signal\s+\d+\b|"
    r"Idle timed out|Post-test timed out)",
    re.IGNORECASE,
)
HOST_SIGNAL_RE = re.compile(
    r"(?:\*\*\*[^\n]*\bSignal\s+\d+\b|"
    r"(?:received|terminated|killed|stopped|crashed|aborted|exited)[^\n]*"
    r"\bsignal\s+\d+\b|^\s*signal\s+\d+\b|"
    r"(?:\*\*\*[^\n]*|(?:received|terminated|killed|stopped|crashed)[^\n]*)"
    r"\bSIG(?:ABRT|ALRM|BUS|CHLD|CONT|FPE|HUP|ILL|INT|IO|IOT|KILL|PIPE|POLL|"
    r"PROF|QUIT|SEGV|STOP|SYS|TERM|TRAP|TSTP|TTIN|TTOU|URG|USR1|USR2|"
    r"VTALRM|XCPU|XFSZ)\b)",
    re.IGNORECASE | re.MULTILINE,
)

CATEGORIES = {
    "product bug",
    "stale test",
    "test bug",
    "host/display dependency",
    "timeout/hang",
    "crash",
    "unknown",
}


def clean(output: str) -> str:
    return ANSI_RE.sub("", output)


def swift_test_name(value: str) -> str:
    """Match the census identifier normalization for Swift Testing display names."""
    return value.strip().strip('"')


def failure_ids(output: str) -> set[str]:
    ids: set[str] = set()
    for line in io.StringIO(clean(output)):
        if "known issue" in line.lower():
            continue
        # Swift Testing prefixes both individual tests and the aggregate run
        # summary with the same failure glyph. The summary is verdict evidence,
        # never a test identifier.
        if SWIFT_SUMMARY_RE.search(line):
            continue
        match = XCTEST_ERROR_RE.search(line) or XCTEST_FAILED_RE.search(line)
        if match:
            ids.add(f"xctest:{match.group('suite')}/{match.group('test')}")
            continue
        match = SWIFT_ISSUE_RE.search(line) or SWIFT_FAILED_RE.search(line)
        if match:
            ids.add(f"swift:{swift_test_name(match.group('test'))}")
    return ids


def failure_accounting(output: str) -> tuple[bool, str]:
    """Prove every failed-summary unit has matching per-test failure evidence."""
    xctest_summaries = []
    xctest_failure_records = 0
    swift_failed_summaries: list[tuple[str, int]] = []
    swift_issue_records = 0

    for raw_line in io.StringIO(clean(output)):
        if "known issue" in raw_line.lower():
            continue
        if match := XCTEST_SUMMARY_RE.search(raw_line):
            xctest_summaries.append(match)
        if XCTEST_ERROR_RE.search(raw_line):
            xctest_failure_records += 1
        if match := SWIFT_SUMMARY_RE.search(raw_line):
            if match.group("result") == "failed":
                issue_match = re.search(r"\bwith\s+(\d+)\s+issues?\b", raw_line)
                if issue_match is None:
                    return False, "Swift Testing failed summary omitted its issue count"
                swift_failed_summaries.append((raw_line.strip(), int(issue_match.group(1))))
            continue
        if SWIFT_ISSUE_RE.search(raw_line):
            swift_issue_records += 1

    if xctest_summaries:
        # XCTest emits nested suite summaries and can append a later zero-test
        # summary after the real aggregate in mixed XCTest/Swift Testing runs.
        # The strongest failure count is the conservative aggregate candidate:
        # when a complete aggregate exists it dominates nested summaries, while
        # missing aggregate evidence still leaves the parsed record count larger
        # and fails closed.
        reported_xctest_failures = max(
            int(match.group("failures")) for match in xctest_summaries
        )
        if reported_xctest_failures != xctest_failure_records:
            return False, (
                "XCTest summaries report at most "
                f"{reported_xctest_failures} failure(s), but "
                f"{xctest_failure_records} attributable failure record(s) were parsed"
            )

    if swift_failed_summaries:
        expected_issues = sum(count for _, count in swift_failed_summaries)
        if expected_issues != swift_issue_records:
            return False, (
                "Swift Testing failed summary reports "
                f"{expected_issues} issue(s), but "
                f"{swift_issue_records} attributable issue record(s) were parsed"
            )

    return True, "all failed-summary evidence has attributable test records"


def load_catalog_data(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise ValueError("catalog root must be an object")
    if value.get("version") != 1:
        raise ValueError("catalog version must be 1")
    baseline = value.get("baseline_sha")
    if not isinstance(baseline, str) or re.fullmatch(r"[0-9a-f]{40}", baseline) is None:
        raise ValueError("catalog baseline_sha must be a 40-character lowercase SHA")

    failures = value.get("failures")
    if not isinstance(failures, list):
        raise ValueError("catalog failures must be a list")
    seen: set[str] = set()
    for entry in failures:
        if not isinstance(entry, dict):
            raise ValueError("catalog failure entries must be objects")
        identifier = entry.get("id")
        if not isinstance(identifier, str) or not identifier.startswith(("xctest:", "swift:")):
            raise ValueError("catalog failure id must use xctest: or swift:")
        if identifier in seen:
            raise ValueError(f"duplicate catalog failure id: {identifier}")
        seen.add(identifier)
        framework = entry.get("framework")
        if framework not in {"xctest", "swift-testing"}:
            raise ValueError(f"invalid framework for {identifier}")
        if identifier.startswith("xctest:") and framework != "xctest":
            raise ValueError(f"framework/id mismatch for {identifier}")
        if identifier.startswith("swift:") and framework != "swift-testing":
            raise ValueError(f"framework/id mismatch for {identifier}")
        if entry.get("category") not in CATEGORIES:
            raise ValueError(f"invalid category for {identifier}")
        for key in ("issue", "first_seen_run", "last_confirmed_run"):
            if not isinstance(entry.get(key), int) or entry[key] <= 0:
                raise ValueError(f"{identifier} requires positive integer {key}")
    return value


def load_catalog(path: Path) -> dict[str, Any]:
    return load_catalog_data(json.loads(path.read_text(encoding="utf-8")))


def known_ids(catalog: dict[str, Any]) -> set[str]:
    return {entry["id"] for entry in catalog["failures"]}


def evaluate(output: str, *, exit_code: int, catalog: dict[str, Any]) -> tuple[bool, str]:
    output = clean(output)
    if INCOMPLETE_RE.search(output):
        return False, "hard app-host failure: crash/timeout/incomplete execution cannot be catalogued"
    if HOST_FAILURE_RE.search(output) or HOST_SIGNAL_RE.search(output):
        return False, "hard app-host failure: runner/host failure cannot be catalogued"

    xctest = list(XCTEST_SUMMARY_RE.finditer(output))
    swift = list(SWIFT_SUMMARY_RE.finditer(output))
    if not xctest and not swift:
        return False, "no trustworthy XCTest or Swift Testing completion summary"

    executed = sum(int(match.group("tests")) for match in xctest)
    executed += sum(int(match.group("tests")) for match in swift)
    if executed <= 0:
        return False, "test summaries reported zero executed tests"

    summary_failed = any(int(match.group("failures")) > 0 for match in xctest)
    summary_failed = summary_failed or any(match.group("result") == "failed" for match in swift)
    ids = failure_ids(output)

    if not summary_failed:
        if ids:
            return False, "failure evidence appeared despite passing summaries"
        if exit_code != 0:
            return False, f"xcodebuild exited {exit_code} after otherwise passing summaries"
        return True, f"clean app-host run: {executed} summarized test executions"

    if not ids:
        return False, "test summaries failed but no typed test identifier was parsed"
    if exit_code != 65:
        return False, (
            "failed test summaries may be catalogued only for xcodebuild status 65; "
            f"got {exit_code}"
        )

    accounted, accounting_message = failure_accounting(output)
    if not accounted:
        return False, "unparsed app-host failure evidence: " + accounting_message

    unknown = sorted(ids - known_ids(catalog))
    if unknown:
        return False, "new app-host failure(s): " + ", ".join(unknown)

    return True, "known current-main failure(s) only: " + ", ".join(sorted(ids))


def catalog_from_git(ref: str, path: str) -> Optional[dict[str, Any]]:
    proc = subprocess.run(
        ["git", "show", f"{ref}:{path}"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if proc.returncode != 0:
        return None
    return load_catalog_data(json.loads(proc.stdout))


def check_shrink_only(
    current: dict[str, Any],
    base: Optional[dict[str, Any]],
    *,
    base_ref: str,
    baseline_ref: str = "origin/main",
) -> tuple[bool, str]:
    if base is None:
        baseline = current["baseline_sha"]
        ancestry = subprocess.run(
            ["git", "merge-base", "--is-ancestor", baseline, baseline_ref],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        if ancestry.returncode != 0:
            return False, f"initial catalog baseline {baseline} is not an ancestor of {baseline_ref}"
        return True, f"initial catalog bootstrap pinned to {baseline}"

    added = sorted(known_ids(current) - known_ids(base))
    if added:
        return False, "known-failure catalog may only shrink; additions: " + ", ".join(added)
    removed = sorted(known_ids(base) - known_ids(current))
    if removed:
        return True, "known-failure catalog shrank: " + ", ".join(removed)
    return True, "known-failure catalog did not grow"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, nargs="?")
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--exit-code", type=int)
    parser.add_argument("--check-shrink-only", action="store_true")
    parser.add_argument("--base-ref")
    parser.add_argument("--baseline-ref", default="origin/main")
    args = parser.parse_args()

    try:
        catalog = load_catalog(args.catalog)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError) as exc:
        print(f"invalid app-host known-failure catalog: {exc}", file=sys.stderr)
        return 2

    if args.check_shrink_only:
        if not args.base_ref:
            print("--base-ref is required with --check-shrink-only", file=sys.stderr)
            return 2
        try:
            base = catalog_from_git(args.base_ref, str(args.catalog))
            passed, message = check_shrink_only(
                catalog,
                base,
                base_ref=args.base_ref,
                baseline_ref=args.baseline_ref,
            )
        except (json.JSONDecodeError, ValueError) as exc:
            print(f"invalid base app-host known-failure catalog: {exc}", file=sys.stderr)
            return 2
        print(message, file=sys.stdout if passed else sys.stderr)
        return 0 if passed else 1

    if args.output is None or args.exit_code is None:
        print("output and --exit-code are required for verdict mode", file=sys.stderr)
        return 2
    try:
        output = args.output.read_text(encoding="utf-8", errors="replace")
    except OSError as exc:
        print(f"could not read {args.output}: {exc}", file=sys.stderr)
        return 2

    passed, message = evaluate(output, exit_code=args.exit_code, catalog=catalog)
    print(message, file=sys.stdout if passed else sys.stderr)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
