#!/usr/bin/env python3
"""Validate SwiftPM execution evidence and preserve every discovered test."""

import argparse
import re
import sys
from pathlib import Path


ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
SWIFT_SUMMARY = re.compile(
    r"^\s*(?:[✔✘━]\s+)?Test run with (\d+) tests?"
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
# Swift Testing names each test it skips (a disabled trait, or its suite's), and the suite whose own trait
# skipped it ("➜ Suite SidebarMultiViewHomeTests skipped: "the drag tests need a display""). Its run summary
# still counts skipped tests ("Test run with 2 tests in 1 suite passed"), so a run of skips reads as a pass.
SWIFT_SKIPPED_TEST = re.compile(r"^\s*\S+ Test (?P<name>.+?) skipped(?:: (?P<reason>.*))?\s*$")
SWIFT_SKIPPED_SUITE = re.compile(r"^\s*\S+ Suite (?P<name>\S+) skipped(?:: (?P<reason>.*))?\s*$")


def skip_report(output: str) -> tuple[int, int, list[str]]:
    """(tests that ran, tests skipped, the skipped suites and the skipped tests by reason) of a run that
    execution_count accepts. A Swift Testing test counts once whether its own trait or its suite's skipped it."""
    ran = execution_count(output)
    swift_skipped = xctest_skipped = 0
    reasons: list[str] = []
    test_reasons: dict[str, int] = {}
    xctest_completed = False
    for line in ANSI.sub("", output).splitlines():
        suite = SWIFT_SKIPPED_SUITE.fullmatch(line)
        if suite:
            reasons.append(f"suite {suite['name']}: {suite['reason'] or 'no reason given'}")
            continue
        test = SWIFT_SKIPPED_TEST.fullmatch(line)
        if test:
            swift_skipped += 1
            test_reasons[test["reason"] or "no reason given"] = test_reasons.get(test["reason"] or "no reason given", 0) + 1
            continue
        if XCTEST_COMPLETION.fullmatch(line):
            xctest_completed = True
            continue
        xctest = XCTEST_SUMMARY.fullmatch(line)
        if xctest and xctest_completed:
            xctest_skipped = max(xctest_skipped, int(xctest["skipped"] or 0))
        xctest_completed = False if line.strip() else xctest_completed
    reasons += [f"{count} test{'s' if count != 1 else ''}: {reason}" for reason, count in test_reasons.items()]
    if xctest_skipped:
        reasons.append(f"{xctest_skipped} XCTest test{'s' if xctest_skipped != 1 else ''}")
    # execution_count counted Swift Testing's skipped tests as run (its summary does)
    return max(0, ran - swift_skipped), swift_skipped + xctest_skipped, reasons


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
    parser.add_argument("--skip-report", type=Path,
                        help="with --log: write 'RAN SKIPPED', then the skipped suites and the skips by reason")
    args = parser.parse_args()
    try:
        if args.log:
            output = args.log.read_text(encoding="utf-8", errors="replace")
            print(execution_count(output))
            if args.skip_report:
                ran, skipped, reasons = skip_report(output)
                args.skip_report.write_text("\n".join([f"{ran} {skipped}", *reasons]) + "\n", encoding="utf-8")
        else:
            print("\n".join(discovery_filters(args.list_filters.read_text(encoding="utf-8"))))
    except (OSError, ValueError) as error:
        print(f"Swift test execution guard: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
