#!/usr/bin/env python3

import argparse
import io
import re
import sys
from pathlib import Path
from typing import Dict, Optional


SUMMARY_RE = re.compile(
    r"Executed\s+(?P<tests>\d+)\s+tests?,\s+"
    r"with\s+(?P<failures>\d+)\s+failures?\s+"
    r"\((?P<unexpected>\d+)\s+unexpected\)"
)
SWIFT_SUMMARY_RE = re.compile(
    r"Test run with (?P<tests>\d+) tests?\b[^\n]*?\b(?P<result>passed|failed)\b"
)

_ANSI_RE = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")
_COMPILE_ERROR_RE = re.compile(
    r"(?:\berror:\s+|Build input files cannot be found|"
    r"cannot find .* in scope|Testing cancelled because the build failed|"
    r"(?:CompileSwift|SwiftCompile).*failed)"
)
_APP_HOST_FAILURE_RE = re.compile(
    r"(?:test runner .*?(?:timed out|hung|failed)|"
    r"unexpected exit|communication with the test runner|"
    r"testmanagerd.*invalidated|Couldn't communicate with a helper|"
    r"Fatal error:|Program crashed|\*\*\*\s+Signal\s+\d+\b|"
    r"Idle timed out|Post-test timed out)",
    re.IGNORECASE,
)
_APP_HOST_SIGNAL_RE = re.compile(
    r"(?:\*\*\*[^\n]*\bSignal\s+\d+\b|"
    r"(?:received|terminated|killed|stopped|crashed|aborted|exited)[^\n]*"
    r"\bsignal\s+\d+\b|^\s*signal\s+\d+\b|"
    r"(?:\*\*\*[^\n]*|(?:received|terminated|killed|stopped|crashed)[^\n]*)"
    r"\bSIG(?:ABRT|ALRM|BUS|CHLD|CONT|FPE|HUP|ILL|INT|IO|IOT|KILL|PIPE|POLL|"
    r"PROF|QUIT|SEGV|STOP|SYS|TERM|TRAP|TSTP|TTIN|TTOU|URG|USR1|USR2|"
    r"VTALRM|XCPU|XFSZ)\b)",
    re.IGNORECASE,
)
_ASSERTION_RE = re.compile(
    r"(?:✘ Test .* recorded an issue|Expectation failed|"
    r"XCTAssert.*failed|Test run with .* failed|"
    r"Executed \d+ tests?,\s+with [1-9]\d* failures?)",
    re.IGNORECASE,
)


def _clean_line(line: str) -> str:
    """Remove terminal formatting and bound one causal log line."""
    return " ".join(_ANSI_RE.sub("", line).split())[:500]


def diagnose(output: str, exit_code: Optional[int] = None) -> Dict[str, object]:
    """Return a non-gating diagnosis for hosted test output."""
    xctest_executed = 0
    swift_executed = 0
    xctest_summary_count = 0
    swift_summary_count = 0
    xctest_unexpected = 0
    swift_failed = False
    compile_line: Optional[str] = None
    app_host_line: Optional[str] = None
    assertion_line: Optional[str] = None
    last_line: Optional[str] = None
    for raw_line in io.StringIO(output):
        last_line = raw_line.rstrip("\r\n")
        xctest_match = SUMMARY_RE.search(raw_line)
        if xctest_match:
            xctest_summary_count += 1
            xctest_executed += int(xctest_match.group("tests"))
            xctest_unexpected += int(xctest_match.group("unexpected"))
        swift_match = SWIFT_SUMMARY_RE.search(raw_line)
        if swift_match:
            swift_summary_count += 1
            swift_executed += int(swift_match.group("tests"))
            swift_failed = swift_failed or swift_match.group("result") == "failed"
        if compile_line is None and _COMPILE_ERROR_RE.search(raw_line):
            cleaned = _clean_line(raw_line)
            if (
                "command line" not in cleaned.lower()
                and "fatal error:" not in cleaned.lower()
                and "program crashed" not in cleaned.lower()
            ):
                compile_line = cleaned
        if app_host_line is None and (
            _APP_HOST_FAILURE_RE.search(raw_line) or _APP_HOST_SIGNAL_RE.search(raw_line)
        ):
            app_host_line = _clean_line(raw_line)
        if assertion_line is None and _ASSERTION_RE.search(raw_line):
            assertion_line = _clean_line(raw_line)

    executed = xctest_executed + swift_executed

    failed = xctest_unexpected > 0 or swift_failed or assertion_line is not None
    nonzero = exit_code is not None and exit_code != 0
    if executed == 0:
        if compile_line:
            category = "pre-test build/setup failure"
            first_causal_line = compile_line
        elif app_host_line:
            category = "pre-test app-host failure"
            first_causal_line = app_host_line
        else:
            category = "pre-test incomplete run"
            first_causal_line = _clean_line(last_line) if last_line else None
    elif app_host_line:
        category = "post-test app-host failure"
        first_causal_line = app_host_line
    elif failed:
        category = "test assertion failure"
        first_causal_line = assertion_line
    elif nonzero:
        category = "post-test app-host failure"
        first_causal_line = app_host_line
    else:
        category = "tests passed"
        first_causal_line = None

    return {
        "category": category,
        "executed_tests": executed,
        "summary_count": xctest_summary_count + swift_summary_count,
        "first_causal_line": first_causal_line,
    }


def classify(output: str) -> tuple[bool, str]:
    """Require completed XCTest or Swift Testing summaries without failures."""
    output = _ANSI_RE.sub("", output)
    summaries = list(SUMMARY_RE.finditer(output))
    swift_summaries = list(SWIFT_SUMMARY_RE.finditer(output))
    if not summaries and not swift_summaries:
        diagnosis = diagnose(output)
        return False, f"{diagnosis['category']}: no trustworthy XCTest summary was found"

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
        diagnosis = diagnose(output)
        return False, f"{diagnosis['category']}: test summaries reported zero executed tests"

    return True, "completed test summaries reported no failures"


def main() -> int:
    """Print either the gate result or an explicit non-gating diagnosis."""
    parser = argparse.ArgumentParser(
        description="Classify or diagnose hosted app-host test output."
    )
    parser.add_argument("output", type=Path)
    parser.add_argument("--suite", default="")
    parser.add_argument("--exit-code", type=int)
    parser.add_argument("--diagnose", action="store_true")
    args = parser.parse_args()

    output_path = args.output
    try:
        output = output_path.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        print(f"could not read {output_path}: {error}", file=sys.stderr)
        return 2

    if not args.diagnose:
        passed, message = classify(output)
        print(message, file=sys.stderr if not passed else sys.stdout)
        return 0 if passed else 1

    diagnosis = diagnose(output, args.exit_code)
    details = [
        f"category={diagnosis['category']}",
        f"executed_tests={diagnosis['executed_tests']}",
        f"summaries={diagnosis['summary_count']}",
    ]
    if args.suite:
        details.insert(0, f"suite={args.suite}")
    if diagnosis["first_causal_line"]:
        details.append(f"first_causal_line={diagnosis['first_causal_line']}")
    print("Test execution diagnosis: " + "; ".join(details))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
