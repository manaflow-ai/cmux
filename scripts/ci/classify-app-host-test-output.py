#!/usr/bin/env python3

import re
import sys
from pathlib import Path


SUMMARY_RE = re.compile(
    r"Executed\s+(?P<tests>\d+)\s+tests?,\s+"
    r"with\s+(?P<failures>\d+)\s+failures?\s+"
    r"\((?P<unexpected>\d+)\s+unexpected\)"
)


def classify(output: str) -> tuple[bool, str]:
    summaries = list(SUMMARY_RE.finditer(output))
    if not summaries:
        return False, "no trustworthy XCTest summary was found"

    unexpected = sum(int(match.group("unexpected")) for match in summaries)
    if unexpected:
        return False, f"{unexpected} unexpected failure(s) found across all XCTest summaries"

    return True, f"{len(summaries)} XCTest summary(ies) contained no unexpected failures"


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
