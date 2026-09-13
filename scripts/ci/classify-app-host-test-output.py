#!/usr/bin/env python3

import re
import sys
from pathlib import Path


SUMMARY_RE = re.compile(
    r"Executed\s+(?P<tests>\d+)\s+tests?,\s+"
    r"with\s+(?P<failures>\d+)\s+failures?\s+"
    r"\((?P<unexpected>\d+)\s+unexpected\)"
)
SWIFT_SUMMARY_RE = re.compile(
    r"Test run with (?P<tests>\d+) tests?\b[^\n]*?\b(?P<result>passed|failed)\b"
)
ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")


def classify(output: str) -> tuple[bool, str]:
    output = ANSI_RE.sub("", output)
    summaries = list(SUMMARY_RE.finditer(output))
    swift_summaries = list(SWIFT_SUMMARY_RE.finditer(output))
    if not summaries and not swift_summaries:
        return False, "no trustworthy XCTest summary was found"

    unexpected = sum(int(match.group("unexpected")) for match in summaries)
    if unexpected:
        return False, f"{unexpected} unexpected failure(s) found across all XCTest summaries"

    if any(int(match.group("failures")) for match in summaries):
        return False, "XCTest failures were reported, including ordinary assertion failures"

    if any(match.group("result") == "failed" for match in swift_summaries):
        return False, "Swift Testing reported a failed test run"
    if "Test run started." in output and not swift_summaries:
        return False, "Swift Testing started without a completed test-run summary"

    executed = sum(int(match.group("tests")) for match in summaries + swift_summaries)
    if executed == 0:
        return False, "no tests were executed"

    return True, "completed test summaries reported no failures"


def main() -> int:
    if len(sys.argv) != 2:
        print(f"usage: {Path(sys.argv[0]).name} <xcodebuild-output>", file=sys.stderr)
        return 2

    output_path = Path(sys.argv[1])
    try:
        output = output_path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        print(f"could not read {output_path}: {error}", file=sys.stderr)
        return 2

    passed, message = classify(output)
    print(message, file=sys.stderr if not passed else sys.stdout)
    return 0 if passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
