#!/usr/bin/env python3
"""Decide whether one app-host xcodebuild batch passed, and report what failed.

The batch passes only when every test that ran passed and the app host never
crashed or restarted. Assertion failures are *not* tolerated: XCTest reports
plain assertion failures as "(0 unexpected)" on the CI runners, and the old
"expected failures" classification let hundreds of failing tests through on
main (issue #12232, run 33534585558 was green with 186 failing XCTest cases).

The report lists every failed XCTest case and Swift Testing test with the first
recorded message, plus every app-host crash with the test that was in flight,
so triage never needs the 60 MB raw log.

Usage:
    classify-app-host-test-output.py <xcodebuild-output>
        [--label TEXT] [--summary-markdown PATH] [--summary-json PATH]

Exit status 0 when the batch passed, 1 when it failed, 2 on usage errors.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from dataclasses import asdict, dataclass, field
from pathlib import Path


SUMMARY_RE = re.compile(
    r"Executed\s+(?P<tests>\d+)\s+tests?,\s+"
    r"with\s+(?P<failures>\d+)\s+failures?\s+"
    r"\((?P<unexpected>\d+)\s+unexpected\)"
)
XCTEST_STARTED_RE = re.compile(r"Test Case '-\[(\S+) (\S+)\]' started\.")
XCTEST_FAILED_RE = re.compile(r"Test Case '-\[(\S+) (\S+)\]' failed \(")
XCTEST_ISSUE_RE = re.compile(r"(?:^|: )error: -\[(\S+) (\S+)\] : (.*)$")
SWIFT_TESTING_STARTED_RE = re.compile(r"◇ Test (?:case .*? to )?(.+?) started\.")
SWIFT_TESTING_FAILED_RE = re.compile(r"✘ Test (?:case .*? to )?(.+?) failed after ")
SWIFT_TESTING_ISSUE_RE = re.compile(r"✘ Test (?:case .*? to )?(.+?) recorded an issue at (\S+): (.*)$")
SWIFT_TESTING_RUN_RE = re.compile(
    r"Test run with (\d+) tests? in (\d+) suites? (passed|failed) after "
)
RESTART_MARKER = "Restarting after unexpected exit, crash, or test timeout"
CRASH_RE = re.compile(r"\*\*\* Program crashed: (.*?)\s*\*\*\*")
FATAL_RE = re.compile(r"Fatal error: (.*)$")
# xcodebuild's own restart line and NSLog echo lines repeat the fatal message;
# only the first occurrence per crash is kept.
APP_HOST_LOG_PREFIX_RE = re.compile(
    r"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+[+-]\d{4} [^\[]*\[\d+:\d+\] "
)


@dataclass
class FailedTest:
    framework: str
    suite: str
    name: str
    message: str


@dataclass
class Crash:
    kind: str
    in_flight_xctest: str
    in_flight_swift_testing: str


@dataclass
class BatchReport:
    label: str
    passed: bool = False
    reasons: list[str] = field(default_factory=list)
    xctest_summaries: int = 0
    xctest_failure_count: int = 0
    xctest_unexpected_count: int = 0
    swift_testing_runs: int = 0
    failed_tests: list[FailedTest] = field(default_factory=list)
    crashes: list[Crash] = field(default_factory=list)
    restarts: int = 0


def strip_log_prefixes(line: str) -> str:
    line = line.rstrip("\r\n")
    # GitHub job logs prefix every line with an ISO timestamp.
    if len(line) > 29 and line[4] == "-" and line[10] == "T" and line[28] == " ":
        line = line[29:]
    return line


def classify(output: str, label: str = "app-host batch") -> BatchReport:
    report = BatchReport(label=label)
    xctest_issue: dict[tuple[str, str], str] = {}
    swift_issue: dict[str, str] = {}
    seen_failed: set[tuple[str, str, str]] = set()
    last_xctest = ""
    last_swift = ""
    pending_fatal = ""
    swift_run_failed = False

    for raw in output.splitlines():
        line = strip_log_prefixes(raw)
        if not line:
            continue

        match = SUMMARY_RE.search(line)
        if match:
            report.xctest_summaries += 1
            report.xctest_failure_count += int(match.group("failures"))
            report.xctest_unexpected_count += int(match.group("unexpected"))
            continue

        match = XCTEST_STARTED_RE.search(line)
        if match:
            last_xctest = f"{match.group(1)}/{match.group(2)}"
            continue

        match = XCTEST_ISSUE_RE.search(line)
        if match:
            xctest_issue.setdefault((match.group(1), match.group(2)), match.group(3).strip())
            continue

        match = XCTEST_FAILED_RE.search(line)
        if match:
            key = ("xctest", match.group(1), match.group(2))
            if key not in seen_failed:
                seen_failed.add(key)
                suite = match.group(1).split(".")[-1]
                report.failed_tests.append(
                    FailedTest(
                        framework="XCTest",
                        suite=suite,
                        name=match.group(2),
                        message=xctest_issue.get((match.group(1), match.group(2)), ""),
                    )
                )
            continue

        match = SWIFT_TESTING_STARTED_RE.search(line)
        if match:
            last_swift = match.group(1)
            continue

        match = SWIFT_TESTING_ISSUE_RE.search(line)
        if match:
            swift_issue.setdefault(match.group(1), f"{match.group(2)}: {match.group(3).strip()}")
            continue

        match = SWIFT_TESTING_RUN_RE.search(line)
        if match:
            report.swift_testing_runs += 1
            if match.group(3) == "failed":
                swift_run_failed = True
            continue

        match = SWIFT_TESTING_FAILED_RE.search(line)
        if match:
            name = match.group(1)
            key = ("swift-testing", "", name)
            if key not in seen_failed:
                seen_failed.add(key)
                issue = swift_issue.get(name, "")
                suite = issue.split(":")[0].rsplit("/", 1)[-1] if issue else ""
                report.failed_tests.append(
                    FailedTest(framework="Swift Testing", suite=suite, name=name, message=issue)
                )
            continue

        match = FATAL_RE.search(line)
        if match and not APP_HOST_LOG_PREFIX_RE.match(line):
            pending_fatal = match.group(1).strip()
            continue

        match = CRASH_RE.search(line)
        if match:
            kind = match.group(1).strip()
            if pending_fatal:
                kind = f"{kind} ({pending_fatal})"
                pending_fatal = ""
            report.crashes.append(
                Crash(kind=kind, in_flight_xctest=last_xctest, in_flight_swift_testing=last_swift)
            )
            continue

        if RESTART_MARKER in line:
            report.restarts += 1
            continue

    if report.xctest_summaries == 0 and report.swift_testing_runs == 0:
        report.reasons.append("no XCTest or Swift Testing run summary was found")
    if report.xctest_failure_count or report.xctest_unexpected_count:
        report.reasons.append(
            f"XCTest reported {report.xctest_failure_count} failure(s) "
            f"({report.xctest_unexpected_count} unexpected)"
        )
    if swift_run_failed:
        report.reasons.append("a Swift Testing run reported failures")
    failed_xctest = sum(1 for test in report.failed_tests if test.framework == "XCTest")
    failed_swift = len(report.failed_tests) - failed_xctest
    if report.failed_tests:
        report.reasons.append(
            f"{failed_xctest} XCTest case(s) and {failed_swift} Swift Testing test(s) failed"
        )
    if report.crashes:
        report.reasons.append(f"the app host crashed {len(report.crashes)} time(s)")
    if report.restarts:
        report.reasons.append(f"xcodebuild restarted the app host {report.restarts} time(s)")
    report.passed = not report.reasons
    return report


def render_markdown(report: BatchReport) -> str:
    status = "passed" if report.passed else "FAILED"
    lines = [f"### {report.label}: {status}", ""]
    if report.reasons:
        lines.append("Failure reasons:")
        lines.extend(f"- {reason}" for reason in report.reasons)
        lines.append("")
    lines.append(
        f"XCTest summaries: {report.xctest_summaries}, "
        f"Swift Testing runs: {report.swift_testing_runs}, "
        f"failed tests: {len(report.failed_tests)}, "
        f"crashes: {len(report.crashes)}, restarts: {report.restarts}"
    )
    lines.append("")
    if report.failed_tests:
        lines.append("| Framework | Suite | Test | First message |")
        lines.append("| --- | --- | --- | --- |")
        for test in report.failed_tests:
            message = test.message.replace("|", "\\|").replace("\n", " ")
            if len(message) > 220:
                message = message[:217] + "..."
            lines.append(f"| {test.framework} | {test.suite} | `{test.name}` | {message} |")
        lines.append("")
    if report.crashes:
        lines.append("| Crash | In-flight XCTest case | In-flight Swift Testing test |")
        lines.append("| --- | --- | --- |")
        for crash in report.crashes:
            lines.append(
                f"| {crash.kind} | `{crash.in_flight_xctest}` | `{crash.in_flight_swift_testing}` |"
            )
        lines.append("")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("output", type=Path)
    parser.add_argument("--label", default="app-host batch")
    parser.add_argument("--summary-markdown", type=Path)
    parser.add_argument("--summary-json", type=Path)
    args = parser.parse_args()

    try:
        output = args.output.read_text(encoding="utf-8", errors="replace")
    except OSError as error:
        print(f"could not read {args.output}: {error}", file=sys.stderr)
        return 2

    report = classify(output, label=args.label)
    markdown = render_markdown(report)
    if args.summary_markdown:
        args.summary_markdown.parent.mkdir(parents=True, exist_ok=True)
        with args.summary_markdown.open("a", encoding="utf-8") as handle:
            handle.write(markdown + "\n")
    if args.summary_json:
        args.summary_json.parent.mkdir(parents=True, exist_ok=True)
        args.summary_json.write_text(json.dumps(asdict(report), indent=2) + "\n", encoding="utf-8")

    stream = sys.stdout if report.passed else sys.stderr
    print(markdown, file=stream)
    return 0 if report.passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
