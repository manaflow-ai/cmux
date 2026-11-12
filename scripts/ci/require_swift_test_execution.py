#!/usr/bin/env python3
"""Validate SwiftPM execution evidence and preserve every discovered test."""

import argparse
import re
import sys
from pathlib import Path


ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
SWIFT_SUMMARY = re.compile(
    r"^\s*(?:[✔✘]\s+)?Test run with (\d+) tests?"
    r"(?: in \d+ suites?)? (passed|failed) after .+\.$"
)
XCTEST_SUMMARY = re.compile(
    r"^\s*Executed (?P<tests>\d+) tests?, with "
    r"(?:(?P<skipped>\d+) tests? skipped and )?(?P<failures>\d+) failures?"
    r" \((?P<unexpected>\d+) unexpected\) in .+ seconds?\s*$"
)
XCTEST_COMPLETION = re.compile(
    r"^\s*Test Suite ['\"](?:All tests|Selected tests)['\"] (passed|failed) at .+$"
)


def execution_count(output: str) -> int:
    swift_count = xctest_count = 0
    xctest_completed = False
    for line in ANSI.sub("", output).splitlines():
        swift = SWIFT_SUMMARY.fullmatch(line)
        if swift:
            if swift[2] == "failed":
                raise ValueError("Swift Testing reported a failed test run")
            swift_count = max(swift_count, int(swift[1]))
        completion = XCTEST_COMPLETION.fullmatch(line)
        if completion:
            if completion[1] == "failed":
                raise ValueError("XCTest reported a failed test run")
            xctest_completed = True
            continue
        xctest = XCTEST_SUMMARY.fullmatch(line)
        if xctest:
            if int(xctest["failures"]) or int(xctest["unexpected"]):
                raise ValueError("XCTest reported test failures")
            # Child-suite summaries can precede a crashed/incomplete run.
            # Count only the summary following the overall completion.
            if xctest_completed:
                executed = int(xctest["tests"]) - int(xctest["skipped"] or 0)
                xctest_count = max(xctest_count, executed)
            xctest_completed = False
        elif line.strip():
            xctest_completed = False
    count = swift_count + xctest_count
    if not count:
        raise ValueError("no completed nonzero Swift test execution was recorded")
    return count


def discovery_filters(output: str) -> list[str]:
    filters = set()
    for line in output.splitlines():
        identifier = line.strip()
        if not identifier:
            continue
        if not re.fullmatch(r"[A-Za-z_][A-Za-z_0-9]*\..+", identifier):
            raise ValueError(f"unrecognized Swift test discovery record: {identifier!r}")
        if "/" in identifier:
            suite, _ = identifier.split("/", 1)
            filters.add("^" + re.escape(suite) + "/")
        else:
            # A top-level @Test has no suite separator. It still must run.
            # Swift Testing may append a source-location component when
            # matching filters, even though `swift test list` omits it.
            filters.add("^" + re.escape(identifier) + "($|/)")
    if not filters:
        raise ValueError("no Swift tests discovered")
    return sorted(filters)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--log", type=Path)
    source.add_argument("--list-filters", type=Path)
    args = parser.parse_args()
    try:
        if args.log:
            print(execution_count(args.log.read_text(encoding="utf-8", errors="replace")))
        else:
            print("\n".join(discovery_filters(args.list_filters.read_text(encoding="utf-8"))))
    except (OSError, ValueError) as error:
        print(f"Swift test execution guard: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
