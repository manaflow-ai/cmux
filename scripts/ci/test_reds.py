#!/usr/bin/env python3
"""Whether a red test job is the base's or the pull request's own, judged per test.

The one classifier every "red on the base, so not ours" decision uses for a job that runs tests: cmux's
gh-merge-green excuse (scripts/ci/base_red_excuse.py), the next-batch queue, HQ's next-autoland and
leo-workspace's lane tools load this file from feat-cmux-next rather than keep a copy.

Why per test (2026-10-28): cmux#26346 landed while its own `cmux-next swift test` job was red. The job was red
on the base too, so the red read as a base red, but on the pull request the test helper had died on signal 6
in the Chief's first-open intro (an NSStackView exception, the crash users then hit at launch), and the base's
red was other tests. A job-level comparison hid a real crash. So:

1. Each failing test is compared, not the job. A test that fails on the head and passes or does not run on the
   base is the head's own red.
2. A test that crashed (a signal, an abort, an EXC_* exception, a Swift `Fatal error`, an uncaught exception,
   XCTest's "crashed" and restart lines) is the head's own red whatever the base shows: a crash on both sides
   is still a crash this head ships with.
3. A head whose per-test results cannot be read (the log is cut, the run ended early, the watchdog stopped it,
   or a summary counts fewer tests than ran) is the head's own red: an unreadable red fails closed.
4. No base log, or one that names no failing test while the head's does, excuses nothing.

It reads Swift Testing, XCTest, xcodebuild and xcresult, cargo test, unittest, pytest and `bun test` output (a bun
failure is `FILE > TEST`; a bun run that printed no closing ` N pass` / ` N fail` counts after its last result was cut
short). It reads only what the steps printed, never the runner's echo of a step's script (echoed).

    test_reds.py classify --head HEAD.log [--base BASE.log] [--job NAME] [--base-name feat-cmux-next] [--json]

prints one line per reason and exits 0 when the job's red is the base's, 1 when it is the head's own and 2 when
the log names no failing test, crash or cut-short run (not a test red: the caller judges it as before).

Gallery health (scripts/gallery-matrix/health.ts) is judged the same way, per state, from the health.json a shard
writes: a broken state (it errors, never readies, or its play cannot reach it) or one over its ready-time budget
is the base's only when the same state is red the same way on the base (any budget miss is one kind; a broken
state's reason is its kind, numbers aside). A render that crashed, or a shard with no whole health.json, is the
head's own. gallery-health.yml replays a pull request's red entries on the base it merged with and asks:

    test_reds.py gallery --head HEAD/health.json --entries               the entries to replay on the base
    test_reds.py gallery --head HEAD/health.json --base BASE/health.json [--annotate] [--json]

with the same exit codes (`--entries` exits 1 when the head's red is its own whatever the base shows).
"""
from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

# Each line of `gh run view --log` or of the job-logs endpoint starts with its time.
STAMP = re.compile(r"^(?:[^\t]*\t[^\t]*\t)?﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ?")
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

FAILED = (
    re.compile(r"✘ Test (.+?\)) (?:recorded an issue|failed)"),  # Swift Testing
    re.compile(r"Test Case '-\[(\S+ \S+)\]' failed"),  # XCTest
    re.compile(r"^test (\S+) \.\.\. FAILED$"),  # cargo test
    re.compile(r"^(?:FAIL|ERROR): (\S+ \([^)]+\))"),  # unittest
    re.compile(r"^FAILED (\S+::\S+)"),  # pytest
)
# Swift Testing emits type suites without quotes and custom suite names in quotes.
SUITE_FAILED = re.compile(r'✘ Suite ("[^"]+"|\S+) (?:recorded an issue|failed)\b')
# A failed test case read from an xcresult bundle (`xcresulttool get test-results tests`, as the iOS kit job prints
# it): `FAILED: <scheme> / <target> / <suite> / <test>()`, named `<suite>.<test>()` like xcodebuild's own
# `Failing tests:` list (`\t<suite>.<test>()` lines under it, up to a blank line).
XCRESULT_FAILED = re.compile(r"^FAILED: (?:.+ / )?([^/]+?) / ([^/]+?\(.*\))$")
XCODEBUILD_FAILING = "Failing tests:"
XCODEBUILD_FAILED = re.compile(r"^\s+(\S+\.\S+\(.*\))$")
# The runner echoes each step before running it: `##[group]Run <first line>`, the step's script (or nothing for an
# action), then its `shell:` line and its `with:` / `env:` blocks, then `##[endgroup]`. That is the step's source,
# not its output: a script that prints, greps or filters test names, or has an `echo "::error::..."` branch, puts
# them in every run's log, green or red (2026-10-30: cmux#28145 excused because base run 41138142557 echoed the
# kit step's script). A group is an echo only when it closes before any other group opens and ends in the runner's
# settings block: from its first `shell:`, `with:` or `env:` line to its `##[endgroup]`, every line is one of those or
# an indented value under them. A step's own `::group::Run ...` output does not end that way, so it is read.
ECHO_START = re.compile(r"^(?:﻿)?##\[group\]Run ")
ECHO_SETTINGS = re.compile(r"^(?:shell: \S.*|with:|env:)$")
ECHO_VALUE = re.compile(r"^  \S")
GROUP_EDGE = re.compile(r"^##\[(?:group|endgroup)\]")
# A line that says the job ran tests at all.
RAN = re.compile(r"[◇✔✘] (?:Test|Suite) |Test Case '-\[|Test Suite '|^test \S+ \.\.\. |^running \d+ tests?$|"
                 r"^Ran \d+ tests? in |^=+ (?:test session starts|FAILURES)|Executed \d+ tests?")

SIGNAL = re.compile(r"(?i:exited with unexpected signal code (\d+)|died on signal (\d+)|exited with signal (?:code )?(\d+)|"
                    r"\(signal: (\d+)|terminated by signal (\d+)|signal (\d+) \(SIG[A-Z]+\))")
SIGNAL_NAMES = {"SIGABRT": "6", "SIGSEGV": "11", "SIGBUS": "10", "SIGILL": "4", "SIGTRAP": "5", "SIGKILL": "9",
                "SIGFPE": "8"}
# What a tool or the runtime prints when a test process dies: matched anywhere in a line.
CRASH = re.compile(r"exited with unexpected signal code|died on signal \d|Terminating app due to uncaught exception|"
                   r"terminating due to uncaught exception|Restarting after unexpected exit, crash, or test timeout|"
                   r"Test Case '[^']*' crashed|Fatal Python error|process didn't exit successfully: .*\(signal: \d+",
                   re.I)
# Crash words a test's own assertion text may quote: a crash only at the start of a line (after an optional
# `file:line: `, `##[error]` or a shell's `script: line N: PID `), never in a test's result line.
CRASH_AT_START = re.compile(r"^(?:##\[error\]|::error[^:]*::)?(?:error: )?(?:\S+:\d+: )?(?:\S+: line \d+: +)?(?:\d+ +)?"
                            r"(?:Fatal error: |Thread \d+ Crashed|Exception Type: +EXC_|Abort(?:ed|\s+trap)\b|"
                            r"Segmentation fault|Illegal instruction|Bus error|Trace/breakpoint trap|"
                            r"(?:the )?(?:swift test run|test process|test helper) (?:exited|terminated) (?:with|by) signal)")
# A shell's report of a child it lost to a signal: `script: line N: PID Killed  cmd` (bash), or the same
# without the line (`PID Terminated`).
SHELL_SIGNAL = re.compile(r"^(?:\S+: line \d+: +)?\d+ +(Killed|Terminated|Hangup|Interrupt|Quit|User defined signal \d)"
                          r"(?::? \d+)? +\S")
SHELL_SIGNAL_NUMBERS = {"Killed": "9", "Terminated": "15", "Hangup": "1", "Interrupt": "2", "Quit": "3"}
# Such a report is a signal someone sent (a test that kills its own children, `timeout`), not a fault. It is a crash
# only in a step that failed or never finished: a step that printed no error and was followed by the next step passed,
# so a kill inside it is that test's own doing, not the job's red (2026-10-31: cmuxterm-hq's
# scripts/test-reload-cloud-terminate-app.sh kills the children it starts and passes, and every red in its Fleet
# tests job read as "the test process crashed (signal 9)"). A fault (`Segmentation fault`, a signal code from SwiftPM,
# an exit status of 128 + N) is a crash wherever it is.
STEP_ERROR = re.compile(r"^(?:##\[error\]|::error)")
# Actions may preserve only the shell status when a process dies after printing its test summary.
# A 128 + signal status is still an abnormal end; a complete summary cannot excuse it as a base red.
# Match the runner annotation, never a test name or an assertion quoting the diagnostic.
PROCESS_EXIT = re.compile(r"^(?:##\[error\]|::error[^:]*::)\s*Process completed with exit code (\d{1,3})\.?$")
# A signal or Mach exception named by a tool, the runtime or a crash report: a crash unless a test's own line
# quotes it.
SIGNALED = re.compile(r"(?:exited|terminated|killed|died) (?:with|by|on) (?:unexpected )?signal\b|\(signal: \d+|"
                      r"\bEXC_[A-Z][A-Z_]+\b|\b[Uu]ncaught (?:exception|signal)\b")
# SwiftPM's line for a killed test helper: it can land in the middle of a test's result line when output interleaves.
HELPER_KILLED = re.compile(r"Process '[^']+' exited with unexpected signal code \d+|"
                           r"^(?:##\[error\])?error: exited with unexpected signal code \d+", re.I)
# A test's own result and progress lines carry assertion text and arguments, never a runtime diagnostic.
TEST_LINE = re.compile(r"^[◇✔✘↪] (?:Test|Suite) |^Test Case '-\[")
XCTEST_RESTART = re.compile(r"(?:Restarting after unexpected exit, crash, or test timeout in|"
                            r"Test Case '-\[)(\S+)[ .](\w+)\]?'? crashed|"
                            r"Restarting after unexpected exit, crash, or test timeout in (\S+?)\.(\w+)\(\)")
# What the CI wrapper or GitHub prints when a run's results are cut short: an error line, never test output.
TRUNCATED = re.compile(r"^(?:##\[error\]|::error[^:]*::)\s*(?:no \"Test run with\" summary line|"
                       r"swift test ended early|reported fewer tests than it ran|swift test stuck|.*\bnever finished\b|"
                       r"The job running on runner .* has exceeded the maximum execution time|"
                       r"The operation was canceled|.*\blog (?:is|was) truncated|"
                       # the hang watchdog (hung_test_watchdog.py) and run_with_timeout.py
                       r".*\b(?:timed out after|made no progress|stopped by SIG[A-Z]+|stalled|[Hh]ung test|"
                       r"[Cc]ancelled test|[Tt]imeout))|^This log was truncated", re.I)
# package-test-lane.sh suite: a suite the lane named whose tests did not run (all skipped, or skipped for a missing
# same-tree cmux-tui) is no result: never a base red, whatever the base shows.
NO_RESULT = re.compile(r"^(?:##\[error\]|::error[^:]*::)\s*.*\brequired tests did not run\b")
# scripts/ci/run-webviews-tests.sh: one `START file` and one `PASS|FAIL|TIMEOUT file ...` line per Bun test file.
# A TIMEOUT is a file the wrapper killed at its hard limit: cut short. Bun's own panic is a crash.
BUN_STARTED = re.compile(r"^START (\S+\.[cm]?[jt]sx?) \(hard limit")
BUN_RESULT = re.compile(r"^(PASS|FAIL|TIMEOUT) (\S+\.[cm]?[jt]sx?)(?: |$)")
BUN_PANIC = re.compile(r"^(?:panic\((?:main thread|thread \d+)\)|oh no: Bun has crashed)")
# The shell self-test keeps a Swift crash report and its `signal 5` fixture in source lines.
SWIFT_TEST_SUMMARY_FIXTURE = re.compile(r"swift-test-summary\.test\.sh:\d+:")
# `bun test` itself (a raw run, or a file's log inside run-webviews-tests.sh): a header per file (`::group::FILE:` in
# Actions, which the job log shows as `##[group]FILE:`), a `(pass)` or `(fail) <describe> > <test> [1.23ms]` line per
# test, the failure's `error:` printed above its line and a timeout note below it, a closing recap of the failures
# (`N tests failed:`, with no headers) and the ` N pass` / ` N fail` counts that end each run.
BUN_FILE = re.compile(r"^(?:##\[group\]|::group::)?(\S+\.(?:test|spec)\.[cm]?[jt]sx?):$")
# A header's path from wherever bun ran (the repo root, the package, `./`): relative to its package, as
# webviews_test_results.py names it.
BUN_PACKAGE = re.compile(r"^(?:\./)*(?:\S*?/)?(?:webviews|web)/|^(?:\./)+")
BUN_ABSOLUTE = re.compile(r"(?<![\w.])/[^\s'\"()]*?/(?:webviews|web)/")
BUN_RUN = re.compile(r"^bun test v\d")
BUN_TEST = re.compile(r"^\((pass|fail)\) (.+?)(?: \[[0-9.]+m?s\])?$")
# A stack frame of the failure: `at <anonymous> (/abs/webviews/test/x.test.ts:12:5)`.
BUN_AT = re.compile(r"^\s*at .*?\(?(\S+\.[cm]?[jt]sx?):(\d+):\d+\)?$")
# A failure's headline: `error: ...` (an assertion or a thrown Error), or a native exception bun prints by its class
# (`TypeError: ...`, `ReferenceError: ...`), kept with that class.
BUN_ERROR = re.compile(r"^(?:error: (.+)|((?:[A-Z]\w*)?Error(?: \[[\w-]+\])?: .+))$")
BUN_RULE = re.compile(r"^-{5,}$")  # the rules around an unhandled error
BUN_TIMED_OUT = re.compile(r"^\s*\^ this test timed out after (\d+)ms")
BUN_UNHANDLED = re.compile(r"^# Unhandled error between tests")
BUN_RECAP = re.compile(r"^\d+ tests? failed:$")
BUN_COUNT = re.compile(r"^\s*\d+ fail$")
RUN_STARTED = re.compile(r"^◇ Test run started\.")
RUN_ENDED = re.compile(r"^[✔✘━] Test run with \d+ tests?")
RUN_COUNT = re.compile(r"^[✔✘━] Test run with (\d{1,9}) tests?")
# A unittest run (verbose `name (module.Class...) ... ok` lines, or a FAIL/ERROR block) ends with `Ran N tests`.
UNITTEST_LINE = re.compile(r"^(?:FAIL|ERROR): \w+ \([\w.]+\)|^\w+ \([\w.]+\)(?: \.\.\.|$)")
XC_SUITE_STARTED = re.compile(r"^\s*Test Suite '.+' started at ")
XC_SUITE_ENDED = re.compile(r"^\s*Test Suite '.+' (?:passed|failed) at ")
SUITE_STARTED = re.compile(r"^◇ Suite (.+?) started\.")
# Known-issue suites use the same ━ completion marker as their tests and run summary.
SUITE_ENDED = re.compile(r"^[✔✘━] Suite (.+?) (?:passed|failed)\b")
# Swift Testing's start line, for naming the test a crash stack runs.
STARTED = re.compile(r"◇ Test (?:case passing .+? to )?(\w+)\((.*?)\) started\.")
# A test's end (Swift Testing; a case of a parameterized test ends with its test), and XCTest's start and end.
# ━ is a test that passed with a known issue (withKnownIssue): it finished.
FINISHED = re.compile(r"[✔✘━] Test (\w+)\(.*?\)(?: with \d+ test cases?)? (?:passed|failed)\b")
XC_STARTED = re.compile(r"Test Case '-\[(\S+ \S+)\]' started")
XC_FINISHED = re.compile(r"Test Case '-\[(\S+ \S+)\]' (?:passed|failed|skipped)")
CARGO_RUNNING = re.compile(r"^running \d+ tests?$")
MANGLED = re.compile(r"\$s([0-9]+)(\w+)")
DIGITS = "0123456789"
LETTERS = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ"


# Plain classes, not dataclasses: consumers load this file with exec or importlib without registering it in
# sys.modules, where a dataclass's string annotations cannot be resolved.
class Result:
    """What one job log says about its tests: ran, failed (names), messages (a failed name's error, where the log
    prints one), crashes ("<who> crashed (signal N)") and truncated (why the per-test results are incomplete)."""

    def __init__(self):
        self.ran = False
        self.failed: set = set()
        self.messages: dict = {}
        self.crashes: list = []
        self.truncated: list = []


class Verdict:
    """own: the head's own red. reasons: why (first the crashes, then truncation, then the new failures).
    shared: failing tests the base fails too."""

    def __init__(self, own: bool, reasons: list, shared: list = ()):
        self.own, self.reasons, self.shared = own, reasons, list(shared)


def echoed(lines: list[str]) -> set[int]:
    """The indexes of LINES (one per line of the log, timestamps and colours removed) that are the runner's echo of a
    step (ECHO_START): its source, never its output."""
    found: set[int] = set()
    at = 0
    while at < len(lines):
        if ECHO_START.match(lines[at]):
            end = next((n for n in range(at + 1, len(lines)) if GROUP_EDGE.match(lines[n])), None)
            first = None if end is None else next(
                (n for n in range(at + 1, end) if ECHO_SETTINGS.match(lines[n])), None)
            if (first is not None and lines[end].startswith("##[endgroup]")
                    and all(ECHO_SETTINGS.match(lines[n]) or ECHO_VALUE.match(lines[n]) for n in range(first, end))):
                found.update(range(at, end + 1))
                at = end + 1
                continue
        at += 1
    return found


def passed_steps(lines: list[str], skip: set[int] | None = None) -> set[int]:
    """The indexes of LINES (log_lines) inside a step that passed: from a step's echo (echoed) to the next step's, with
    no error line between. The last step (no step after it) never passed: it may be the one that died."""
    skip = echoed(lines) if skip is None else skip
    starts = [n for n in sorted(skip) if ECHO_START.match(lines[n])]
    found: set[int] = set()
    for start, end in zip(starts, starts[1:]):
        if not any(STEP_ERROR.match(lines[n]) for n in range(start, end) if n not in skip):
            found.update(range(start, end))
    return found


def log_lines(log: str) -> list[str]:
    """Every line of a job log with its timestamp and colours removed, the runner's step echoes included."""
    return [STAMP.sub("", ANSI.sub("", line)).rstrip() for line in log.splitlines()]


def lines_of(log: str) -> list[str]:
    """What the job's steps printed: log_lines without the runner's echo of each step's script (echoed)."""
    lines = log_lines(log)
    skip = echoed(lines)
    return [text for n, text in enumerate(lines) if n not in skip]


def failed_names(lines: list[str]) -> set[str]:
    """The failing tests LINES name: each FAILED pattern's, an xcresult `FAILED:` line's and the names under
    xcodebuild's `Failing tests:` (XCRESULT_FAILED). LINES are a step's output (lines_of), never its echoed script."""
    found: set[str] = set()
    listing = False
    for text in lines:
        if listing:
            if match := XCODEBUILD_FAILED.match(text):
                found.add(match.group(1))
                continue
            listing = False
        if text.strip() == XCODEBUILD_FAILING:
            listing = True
            continue
        for pattern in FAILED:
            if match := pattern.search(text):
                found.add(match.group(1))
        if match := SUITE_FAILED.search(text):
            found.add(match.group(1).strip('"'))
        if match := XCRESULT_FAILED.match(text):
            found.add(f"{match.group(1)}.{match.group(2)}")
    return found


def _words(text: str, words: list[str]) -> None:
    """Swift's mangling words of a literal identifier part: runs that start at a non-digit and end before an
    uppercase letter that follows a non-uppercase one, or at `_`; two characters or more."""
    start = None
    for i in range(len(text) + 1):
        c = text[i] if i < len(text) else ""
        if start is not None and (c in ("_", "") or (c.isupper() and not text[i - 1].isupper())):
            if i - start >= 2:
                words.append(text[start:i])
            start = None
        if start is None and c and not c.isdigit() and c != "_":
            start = i


def _identifier(text: str, at: int, words: list[str]) -> tuple[str, int] | None:
    """One mangled identifier at `at` (a literal, or `0` and word substitutions): (name, end)."""
    if at >= len(text) or text[at] not in DIGITS:
        return None
    subst = text[at] == "0"
    if subst:
        at += 1
    out = ""
    while True:
        while subst and at < len(text) and text[at] in LETTERS:
            index = ord(text[at].lower()) - ord("a")
            if text[at].isupper():
                subst = False
            if index >= len(words):
                return None
            out += words[index]
            at += 1
        if at < len(text) and text[at] == "0":
            at += 1
            break
        match = re.match(r"[0-9]+", text[at:])
        if not match:
            return (out, at) if out else None
        size = int(match.group())
        at += len(match.group())
        part = text[at:at + size]
        if len(part) < size:
            return None
        _words(part, words)
        out += part
        at += size
        if not subst:
            break
    return out, at


def demangle_test(symbol: str) -> tuple[str, str] | None:
    """(type, member) from a mangled Swift symbol in a *Tests module: `$s16CmuxNextAppTests015HomeChiefRosterD0V35no
    SegmentedControlFloatsOverTheChatyyF` is ("HomeChiefRosterTests", "noSegmentedControlFloatsOverTheChat")."""
    try:
        return _demangle_test(symbol)
    except (ValueError, IndexError, OverflowError):
        return None


def _demangle_test(symbol: str) -> tuple[str, str] | None:
    match = MANGLED.match(symbol)
    if not match:
        return None
    words: list[str] = []
    module = _identifier(symbol, 2, words)
    if not module or not module[0].endswith("Tests"):
        return None
    kind = _identifier(symbol, module[1], words)
    if not kind or kind[1] >= len(symbol) or symbol[kind[1]] not in "VCO":
        return None
    member = _identifier(symbol, kind[1] + 1, words)
    return kind[0], member[0] if member else ""


def crashed_tests(stack: list[str], started: set[str]) -> list[str]:
    """`Type.test` (or `Type`) for the test frames of a crash stack: the member that is a started test names it."""
    found: list[str] = []
    types: list[str] = []
    for text in stack:
        for symbol in re.findall(r"\$s\d+\w+", text):
            name = demangle_test(symbol)
            if not name:
                continue
            kind, member = name
            if member in started:
                who = f"{kind}.{member}"
                if who not in found:
                    found.append(who)
            elif kind not in types:
                types.append(kind)
    return found or types[:1]


def signal_of(text: str) -> str | None:
    if match := SIGNAL.search(text):
        return next(group for group in match.groups() if group)
    if match := SHELL_SIGNAL.search(text):
        return SHELL_SIGNAL_NUMBERS.get(match.group(1))
    if match := re.search(r"Abort trap: (\d+)", text):
        return match.group(1)
    for name, number in SIGNAL_NAMES.items():
        if name in text:
            return number
    if re.search(r"\bAbort(?:ed|\s+trap)\b", text):
        return "6"
    return None


def bun_diagnostic(said: list, where: str = "") -> str:
    """A bun failure's error, compared across runs: its whole assertion block (the `error:` line and the Expected /
    Received lines under it) as printed, but for the checkout's path and spacing, and the test file's line it failed at.
    (The runner's own `[1.23ms]` is on the result line, never here.)"""
    said = " / ".join(" ".join(BUN_ABSOLUTE.sub("", part).split()) for part in said)
    return f"{said} at {where}" if said and where else said


def read_bun(lines: list[str], result: Result) -> None:
    """`bun test`'s failures into `result`: each named `FILE > TEST` under its file's header (webviews_test_results.py's
    names), or `TEST` when the recap is all that names it, with its diagnostics (bun_diagnostic, or its timeout; every
    distinct one when the name fails more than once) as its message. An unhandled error between tests is a failure
    named by its headline, with its whole block and location as its diagnostic. Each bun invocation is whole only once it prints its ` N fail` count: one that started
    (`bun test v…`, a file header or a result) and reached the next invocation (`bun test v…`, the wrapper's retry) or
    the log's end with no count was cut short, wherever it sits in the log."""
    file, said, where, last, recap, unhandled, open_run = "", [], "", None, False, False, False
    block = False  # reading the assertion block under an `error:` line, up to its stack or annotation
    run_file = ""  # the file of the run that just ended, for run-webviews-tests.sh's retry
    diagnostics: dict = {}  # name: its distinct diagnostics
    added = None  # the diagnostic the last result line added, which its timeout note replaces
    pending = False  # an unhandled error whose block is being read: recorded when it ends

    def fail(name: str, message: str) -> str | None:
        result.failed.add(name)
        result.ran = True
        if message and message not in diagnostics.setdefault(name, []):
            diagnostics[name].append(message)
            return message
        return None

    def flush() -> None:
        """Record the unhandled error being read, named by its headline, with its whole block as its diagnostic."""
        nonlocal pending, said, where, block
        if pending:
            headline = bun_diagnostic(said[:1])  # the checkout's path differs from run to run
            fail(f"{file} > unhandled error: {headline}" if file else f"unhandled error: {headline}",
                 bun_diagnostic(said, where))
            pending, said, where, block = False, [], "", False

    def end_run(why: str) -> None:
        nonlocal open_run
        if open_run:
            result.truncated.append(f"a bun test run printed no ` N pass` / ` N fail` summary before {why}")
        open_run = False

    for text in lines:
        if SWIFT_TEST_SUMMARY_FIXTURE.search(text):
            continue
        if BUN_RUN.match(text) or BUN_FILE.match(text) or text == WEB_RETRY or BUN_TEST.match(text) or \
                BUN_UNHANDLED.match(text) or BUN_COUNT.match(text):
            flush()
        if BUN_RUN.match(text):
            end_run("the next bun test run started")
            open_run = result.ran = True  # a started run is tests, whatever the job is named
        elif BUN_RECAP.match(text):
            recap, last = True, None
        elif match := BUN_FILE.match(text):
            file, said, where, last, recap, open_run = BUN_PACKAGE.sub("", match.group(1)), [], "", None, False, True
            run_file, block, result.ran = file, False, True
        elif text == WEB_RETRY and run_file:
            end_run("the wrapper ran its file again")
            # run-webviews-tests.sh ran a red file again, alone: only that run counts (webviews_test_results.py).
            for name in [name for name in result.failed if name.startswith(run_file + " > ")]:
                result.failed.discard(name)
                diagnostics.pop(name, None)
        elif match := BUN_TEST.match(text):
            result.ran, open_run, last = True, True, None
            name = match.group(2)
            added = None
            if match.group(1) == "fail" and not recap:
                last = f"{file} > {name}" if file else name
                added = fail(last, bun_diagnostic(said, where))
            elif match.group(1) == "fail" and not any(key == name or key.endswith(" > " + name) for key in result.failed):
                last = name  # failed before its file's header printed
                fail(last, "")
            said, where, block = [], "", False
        elif BUN_UNHANDLED.match(text):
            unhandled = True
        elif match := BUN_ERROR.match(text):
            headline = match.group(1) or match.group(2)
            if unhandled:
                said, where, block, pending, unhandled = [headline], "", True, True, False
            elif not said:
                said, block = [headline], True
            else:
                block = False  # a later error of the same test: the first one names it
        elif block and (text.lstrip().startswith("at ") or text.startswith(("##[error]", "::error"))
                        or BUN_RULE.match(text)):
            block = False  # the stack, GitHub's annotation repeating the block, or an unhandled error's closing rule
            if (match := BUN_AT.match(text)) and not where and BUN_PACKAGE.sub("", match.group(1)) == file:
                where = f"{file}:{match.group(2)}"
        elif block and text.strip():
            said.append(text.strip())
        elif (match := BUN_AT.match(text)) and said and not where and BUN_PACKAGE.sub("", match.group(1)) == file:
            where = f"{file}:{match.group(2)}"
        elif (match := BUN_TIMED_OUT.match(text)) and last:
            # A timeout is the test's diagnostic, whatever its run printed before bun stopped it; a repeated failure
            # of the same name keeps its own.
            if added is not None:
                diagnostics[last].remove(added)
            added = None
            fail(last, f"timed out after {match.group(1)}ms")
        elif BUN_COUNT.match(text):
            if unhandled:
                fail(f"{file} > unhandled error" if file else "unhandled error", "")
            file, said, where, last, recap, unhandled, open_run = "", [], "", None, False, False, False
            block = False
    flush()
    end_run("the log ended")
    for name, found in diagnostics.items():
        if found:
            # Like web_failures: several diagnostics for one name are all compared, none dropped, in sorted order so
            # head and base compare whatever order their runs printed them in.
            result.messages[name] = "\n--- repeated failure ---\n".join(sorted(found))


def read(log: str | None, bun: bool = True) -> Result:
    """The tests a job log ran, failed and crashed, and whether its per-test results are whole. `bun=False` leaves
    bun's own output to the caller (web_failures parses it itself)."""
    result = Result()
    if log is None or not log.strip():
        result.truncated.append("its log could not be read" if log is None else "its log is empty")
        return result
    every = log_lines(log)
    skip = echoed(every)
    passed = passed_steps(every, skip)
    kept = [n for n in range(len(every)) if n not in skip]
    lines = [every[n] for n in kept]
    started = {m.group(1) for text in lines for m in [STARTED.search(text)] if m}
    stack: list[str] = []
    signals: list[str] = []
    named: list[str] = []
    crashed = False
    for at, text in enumerate(lines):
        if SWIFT_TEST_SUMMARY_FIXTURE.search(text):
            continue
        if RAN.search(text) or UNITTEST_LINE.match(text) or BUN_STARTED.match(text) or BUN_RESULT.match(text):
            result.ran = True
        if (match := BUN_RESULT.match(text)) and match.group(1) == "TIMEOUT":
            result.truncated.append(f"{match.group(2)} timed out (killed at the wrapper's hard limit)")
        if BUN_PANIC.match(text):
            crashed = True
        if match := XCTEST_RESTART.search(text):
            groups = [g for g in match.groups() if g]
            named.append(".".join(groups[:2]))
            crashed = True
        exited = PROCESS_EXIT.match(text)
        signal_exit = int(exited.group(1)) - 128 if exited else 0
        if 1 <= signal_exit <= 64:
            crashed = True
            signals.append(str(signal_exit))
        killed = SHELL_SIGNAL.search(text) and kept[at] not in passed
        runtime = HELPER_KILLED.search(text) or killed or (
            (CRASH.search(text) or CRASH_AT_START.search(text) or SIGNALED.search(text)) and not TEST_LINE.search(text))
        if runtime:
            crashed = True
            if number := signal_of(text):
                signals.append(number)
        if crashed and ("$s" in text or re.match(r"^\s*\d+\s+\S+\s+0x[0-9a-f]+ ", text)):
            stack.append(text)
        if TRUNCATED.search(text) or NO_RESULT.search(text):
            why = re.sub(r"^##\[error\]|^::error[^:]*::", "", text).strip()
            result.truncated.append(why[:200])
    if names := failed_names([text for text in lines if not SWIFT_TEST_SUMMARY_FIXTURE.search(text)]):
        result.failed |= names
        result.ran = True
    unfinished = started - {m.group(1) for text in lines for m in [FINISHED.search(text)] if m}
    unfinished |= ({m.group(1) for text in lines for m in [XC_STARTED.search(text)] if m}
                   - {m.group(1) for text in lines for m in [XC_FINISHED.search(text)] if m})
    if unfinished:
        result.truncated.append(f"{len(unfinished)} test(s) started and never finished: "
                                + "; ".join(sorted(unfinished)[:5]))
    runs = sum(1 for text in lines if RUN_STARTED.search(text))
    if runs > sum(1 for text in lines if RUN_ENDED.search(text)):
        result.truncated.append(f"{runs - sum(1 for text in lines if RUN_ENDED.search(text))} Swift Testing run(s) "
                                "started and printed no `Test run with` summary")
    finished = [m.group(1) for text in lines for m in [FINISHED.search(text)] if m]
    counted = sum(int(m.group(1)) for text in lines for m in [RUN_COUNT.search(text)] if m)
    if runs and counted < len(finished):
        # A summary counts every test of its run (skipped ones too), so it is never below the tests that ended.
        result.truncated.append(f"the summaries count {counted} tests but {len(finished)} finished")
    xc_suites = (sum(1 for text in lines if XC_SUITE_STARTED.search(text))
                 - sum(1 for text in lines if XC_SUITE_ENDED.search(text)))
    if xc_suites > 0:
        result.truncated.append(f"{xc_suites} XCTest suite(s) started and never finished")
    suites = ({m.group(1) for text in lines for m in [SUITE_STARTED.search(text)] if m}
              - {m.group(1) for text in lines for m in [SUITE_ENDED.search(text)] if m})
    if suites:
        result.truncated.append(f"{len(suites)} suite(s) started and never finished: " + "; ".join(sorted(suites)[:5]))
    last_end = max((n for n, text in enumerate(lines) if re.match(r"^=+ .*\bin [\d.]+s\b.*=+$", text)), default=-1)
    if any(re.match(r"^=+ test session starts =+$", text) for text in lines[last_end + 1:]):
        result.truncated.append("a pytest session printed no closing summary")
    # Per invocation: unittest activity after the last `Ran N tests` line is a run that never ended.
    last_ran = max((n for n, text in enumerate(lines) if re.match(r"^Ran \d+ tests? in ", text)), default=-1)
    if any(UNITTEST_LINE.match(text) for text in lines[last_ran + 1:]):
        result.truncated.append("a unittest run printed no `Ran N tests` line")
    running = sum(1 for text in lines if CARGO_RUNNING.match(text))
    if running > sum(1 for text in lines if text.startswith("test result: ")):
        result.truncated.append("a cargo test binary printed no `test result:` line")
    if bun:
        read_bun(lines, result)
    if crashed:
        who = named or crashed_tests(stack, started) or ["the test process"]
        signal = f"signal {signals[0]}" if signals else "no signal named"
        result.crashes = [f"{name} crashed ({signal})" for name in dict.fromkeys(who)]
    return result


def is_test_red(found: Result, job: str = "") -> bool:
    """Whether this classifier owns the job's red: its log shows tests running, or the job is a test job by name.
    A compile or lint job that prints `Fatal error:` keeps the caller's own comparison."""
    return found.ran or bool(re.search(r"\btests?\b", job, re.I))


def classify(head_log: str | None, base_log: str | None, job: str = "", base: str = "the base") -> Verdict | None:
    """The head job's red judged per test against the base job's log; None when the head's log names no failing
    test, crash or cut-short run (a lint or compile red: the caller judges it as before)."""
    head = read(head_log)
    if head_log is None:
        return Verdict(True, [f"{job or 'the job'}: its log could not be read, so no test can be compared with {base}"])
    if not is_test_red(head, job):
        return None
    if not head.failed and not head.crashes and not head.truncated:
        # Its tests (if any) passed: the red is a lint, compile or other step the caller judges as before.
        return None
    reasons = list(head.crashes)
    if head.truncated:
        reasons.append(f"{job or 'the job'}: per-test results are not whole ({head.truncated[0]})")
    base_result = read(base_log) if base_log is not None else Result()
    seen = base_result.failed
    new = sorted(head.failed - seen)
    # A failure whose log prints its error (bun's) fails the same way only with the same error on both sides: an
    # assertion on the base does not excuse a TypeError on the head. Names with no error printed compare by name.
    differ = [name for name in sorted(head.failed & seen)
              if (head.messages.get(name) or base_result.messages.get(name))
              and head.messages.get(name) != base_result.messages.get(name)]
    if base_log is None and head.failed:
        reasons.append(f"no {base} log to compare {len(head.failed)} failing test(s) with")
    elif new:
        named = [f"{name} ({head.messages[name]})" if head.messages.get(name) else name for name in new]
        reasons.append(f"{len(new)} failing test(s) pass or do not run on {base}: {'; '.join(named)[:600]}")
    if differ:
        said = [f"{name} ({head.messages.get(name) or 'no error read'} here; "
                f"{base_result.messages.get(name) or 'no error read'} on {base})" for name in differ]
        reasons.append(f"{len(differ)} test(s) fail differently on {base}: {'; '.join(said)[:600]}")
    return Verdict(bool(reasons), reasons, sorted(head.failed & seen - set(differ)))


# The webview tests (scripts/ci/run-webviews-tests.sh, bun), judged per test across jobs. One test file runs in
# a head shard (`react-apps-check (N)`) and, when red, is replayed on the merge parent by `react-apps-base-check (N)`,
# while the base's own push runs it in whichever shard it falls in; a per-job comparison never matches those names
# (2026-10-29: agent-pane-no-capsules, red on the base as `react-apps-check (1)`, charged to a PR as
# `react-apps-base-check (4)`). So a test is named by its file and its title (webviews_test_results.py's `FILE >
# TEST`, or `FILE` for a file that failed naming no test), and compared with its error (the bun `error:` line and the
# test file's line it failed at) against every base job that ran it.
WEB_FILE = r"(test/\S+?\.[cm]?[jt]sx?)"
WEB_GROUP = re.compile(r"^##\[group\](FAIL|TIMEOUT) " + WEB_FILE + r"\b")  # a red file's log, run-webviews-tests.sh
WEB_SUMMARY = re.compile(r"^(FAIL|TIMEOUT) " + WEB_FILE + r" \(limit")  # its line in the run's closing list
WEB_FAIL = re.compile(r"^\(fail\) (.+?)(?: \[[0-9.]+m?s\])?$")
WEB_ERROR = re.compile(r"^error: (.+)$")
WEB_AT = re.compile(r"\bat .*?/webviews/" + WEB_FILE + r":(\d+):\d+\)?$")
WEB_RETRY = "--- retry, alone ---"
# guards_new_reds.py --label "Webview test": the tests a base replay charged to the change (errors) or found red on
# the merge parent too (warnings), as GitHub prints the annotations.
WEB_CHARGED = re.compile(r"^##\[(error|warning)\]" + WEB_FILE + r"(?: > (.+))?$")


class WebFailures:
    """What one webview test job log says: failed ({`FILE > TEST` or `FILE`: error, "" when none was printed}),
    timed_out and crashed files, and charged/shared (a base replay's guards_new_reds verdicts, by name)."""

    def __init__(self):
        self.failed: dict = {}
        self.timed_out: set = set()
        self.crashed: set = set()
        self.charged: set = set()
        self.shared: set = set()
        self.truncated: list = []


def web_failures(log: str | None) -> WebFailures:
    """The webview tests a job log names as failed, with each one's diagnostic. A retry's alone attempt supplies
    its failing names and errors, matching webviews_test_results.py; runtime failures remain unconditionally own."""
    found = WebFailures()
    if not log:
        return found
    current = None  # the red file whose log this is
    error: list[str] = []
    where = ""
    in_stack = False
    summary = False
    grouped = False
    pending: dict[str, int] = {}

    def diagnostic():
        said = "\n".join(error)
        return f"{said} at {where}" if said and where else said

    def end_file():
        if current and error:
            said = diagnostic()
            if current in found.failed and found.failed[current] != said:
                said = "\n--- repeated failure ---\n".join(sorted({found.failed[current], said}))
            found.failed[current] = said

    texts = lines_of(log)
    for text in texts:
        if match := BUN_STARTED.match(text):
            name = match.group(1)
            pending[name] = pending.get(name, 0) + 1
            summary = False
        elif (match := BUN_RESULT.match(text)) and not WEB_SUMMARY.match(text):
            name = match.group(2)
            if pending.get(name, 0):
                pending[name] -= 1
        if match := WEB_GROUP.match(text):
            end_file()
            current, error, where, in_stack = match.group(2), [], "", False
            grouped = True
            if match.group(1) == "TIMEOUT":
                found.timed_out.add(current)
            continue
        if text.startswith("### webviews tests:"):
            end_file()
            current = None
            summary = True
            continue
        if match := WEB_SUMMARY.match(text):
            name = match.group(2)
            if match.group(1) == "TIMEOUT":
                found.timed_out.add(name)
            elif not any(key == name or key.startswith(name + " > ") for key in found.failed):
                found.failed[name] = ""  # a red file that named no test (it did not load)
            continue
        if match := WEB_CHARGED.match(text):
            (found.charged if match.group(1) == "error" else found.shared).add(
                match.group(2) + (f" > {match.group(3)}" if match.group(3) else ""))
            continue
        if current is None:
            continue
        if "... output truncated;" in text:
            found.truncated.append(f"{current}: its diagnostic was truncated")
        if text == "##[endgroup]":
            end_file()
            current = None
        elif text == WEB_RETRY:
            # The base replay runs a file alone. Compare the final alone attempt, as
            # webviews_test_results.py does, without letting an earlier error overwrite it.
            found.failed = {key: value for key, value in found.failed.items()
                            if key != current and not key.startswith(current + " > ")}
            error, where, in_stack = [], "", False
        elif match := WEB_ERROR.match(text):
            error.append(match.group(1).strip())
            in_stack = False
        elif (match := WEB_AT.search(text)) and match.group(1) == current and not where:
            where = f"{match.group(1)}:{match.group(2)}"
            in_stack = True
        elif text.lstrip().startswith("at "):
            in_stack = True
        elif match := WEB_FAIL.match(text):
            key = f"{current} > {match.group(1)}"
            said = diagnostic()
            if key in found.failed and found.failed[key] != said:
                # Multiple diagnostics for one title must not silently overwrite a new red.
                said = "\n--- repeated failure ---\n".join(sorted({found.failed[key], said}))
            found.failed[key] = said
            error, where, in_stack = [], "", False
        elif text.startswith("(pass) "):
            end_file()  # an unhandled error is not the passing test's diagnostic
            error, where, in_stack = [], "", False
        elif error and not in_stack and text.strip():
            error.append(text.strip())
    end_file()
    if (grouped or pending) and not summary:
        found.truncated.append("its webview run printed no closing summary")
    unfinished = sorted(name for name, count in pending.items() if count)
    if unfinished:
        found.truncated.append("webview files started and never finished: " + "; ".join(unfinished))
    # Keep the common runtime and cut-short detection; Bun assertion titles can quote
    # crash words, so result lines are not runtime diagnostics.
    runtime = read("\n".join(text for text in texts if not WEB_FAIL.match(text)
                             and not text.startswith("(pass) ")), bun=False)
    found.crashed.update(runtime.crashes)
    found.truncated.extend(runtime.truncated)

    return found


def merged_web(logs: list) -> WebFailures:
    out = WebFailures()
    for log in logs:
        got = web_failures(log)
        for key, said in got.failed.items():
            if key in out.failed and out.failed[key] != said:
                said = "\n--- repeated failure ---\n".join(sorted({out.failed[key], said}))
            out.failed[key] = said
        out.timed_out |= got.timed_out
        out.crashed |= got.crashed
        out.charged |= got.charged
        out.shared |= got.shared
        out.truncated.extend(got.truncated)
    return out


def classify_web(head_logs: list, base_logs: list, job: str = "", base: str = "the base") -> Verdict | None:
    """A red webview test job (a head shard, or the base replay that charged tests to the change) judged per test
    against every base job that ran those tests: own unless each test the head is red on fails on the base too with
    the same error. head_logs: the red job's log first, then the logs of the head's other jobs that ran the same
    files (where each failure's error is printed); base_logs: the base's red webview test jobs. None when the red job's
    log names no failing webview test (not a webview test red: the caller judges it as before). A file that timed out
    or crashed, an unreadable log, or a test whose error is printed on only one side is the head's own."""
    if not head_logs or any(log is None for log in head_logs):
        return Verdict(True, [f"{job or 'the job'}: its log could not be read, so no test can be compared with {base}"])
    red = web_failures(head_logs[0])
    names = sorted(red.charged) if red.charged else sorted(red.failed)
    if not names and not red.timed_out and not red.crashed and not red.truncated:
        return None
    # A replay's own log holds the merge parent's runs of those files, never the head's: the head's errors come from
    # the head's other jobs then.
    head = merged_web([log for log in (head_logs[1:] if red.charged else head_logs) if log is not None])
    if red.charged:
        files = {name.split(" > ", 1)[0] for name in red.charged}
        # Replay annotations need not name an unhandled error that the head emitted
        # outside a test. Every head diagnostic in the charged files must be compared.
        names = sorted(set(names) | {name for name in head.failed if name.split(" > ", 1)[0] in files})
    reasons = sorted(red.crashed | head.crashed)
    reasons += [f"{name} timed out (a cut-short run is never a base red)"
                for name in sorted(red.timed_out | head.timed_out)]
    reasons += sorted(set(red.truncated + head.truncated))
    if any(log is None for log in base_logs) or not base_logs:
        reasons.append(f"no readable {base} webview test log to compare {len(names)} failing test(s) with")
        return Verdict(True, reasons)
    seen = merged_web(base_logs)
    new, differ, shared = [], [], []
    for name in names:
        if name not in seen.failed:
            new.append(name)
            continue
        mine, theirs = head.failed.get(name, ""), seen.failed[name]
        if not mine or not theirs or mine != theirs:
            differ.append(f"{name} ({mine or 'no error read'} here; {theirs or 'no error read'} on {base})")
            continue
        shared.append(name)
    if new:
        reasons.append(f"{len(new)} failing test(s) pass or do not run on {base}: {'; '.join(new)[:600]}")
    if differ:
        reasons.append(f"{len(differ)} test(s) fail differently on {base}: {'; '.join(differ)[:600]}")
    return Verdict(bool(reasons), reasons, shared)


# Gallery health's health.json: a shard's broken states and its states over their ready-time budget.
GALLERY_KEYS = ("fresh", "known", "slow")
# A render the browser lost: a crash, never a state the base can share.
GALLERY_CRASH = re.compile(r"\bcrash|Target (?:page, context or browser )?(?:has been )?closed|"
                           r"browser has (?:been )?(?:disconnected|closed)|\bsignal\b|\bSIG[A-Z]+\b", re.I)
GALLERY_SLOW = "over its ready-time budget"


def gallery_read(text: str | None, keep_known: bool = False) -> Result:
    """The red states a gallery health shard wrote (`state: kind`, numbers masked), its crashes and whether it is
    whole. `keep_known` counts the allowlist's states too: on the base they are broken the same way."""
    result = Result()
    if text is None or not text.strip():
        result.truncated.append("its health.json is missing (the render was cut short or never ran)"
                                if text is None else "its health.json is empty")
        return result
    try:
        found = json.loads(text)
    except ValueError as error:
        result.truncated.append(f"its health.json is not JSON ({error})")
        return result
    if not isinstance(found, dict):
        result.truncated.append("its health.json is not a verdict")
        return result
    if found.get("error"):
        result.truncated.append(str(found["error"])[:200])
        return result
    if not all(isinstance(found.get(key), list) for key in GALLERY_KEYS):
        result.truncated.append("its health.json has no verdict (" + ", ".join(GALLERY_KEYS) + ")")
        return result
    result.ran = True
    broken = found["fresh"] + (found["known"] if keep_known else [])
    for item in broken:
        state, reason = str(item.get("state", "")), str(item.get("reason", ""))
        if reason.startswith("did not render:") and GALLERY_CRASH.search(reason):
            result.crashes.append(f"{state} crashed ({reason[:200]})")
        result.failed.add(f"{state}: {re.sub(r'[0-9]+', '#', reason)}")
    for item in found["slow"]:
        result.failed.add(f"{item.get('state', '')}: {GALLERY_SLOW}")
    return result


def gallery_entries(text: str | None) -> list[str]:
    """The gallery entries (`entry` of `entry#variant`) of the head's red states: what the base replays."""
    return sorted({name.split(": ", 1)[0].rsplit("#", 1)[0] for name in gallery_read(text).failed})


def gallery_classify(head_text: str | None, base_text: str | None, base: str = "the base") -> Verdict | None:
    """A gallery health shard's red judged per state against the same states rendered on the base; None when the
    head's shard is whole and has nothing red."""
    head = gallery_read(head_text)
    if not head.failed and not head.crashes and not head.truncated:
        return None
    reasons = list(head.crashes)
    if head.truncated:
        reasons.append(f"gallery health: per-state results are not whole ({head.truncated[0]})")
    seen = gallery_read(base_text, keep_known=True)
    if seen.truncated:
        reasons.append(f"no whole base result on {base} to compare {len(head.failed)} red state(s) with "
                       f"({seen.truncated[0]})")
    elif new := sorted(head.failed - seen.failed):
        reasons.append(f"{len(new)} red state(s) render or are red another way on {base}: {'; '.join(new)[:600]}")
    return Verdict(bool(reasons), reasons, sorted(head.failed & seen.failed) if not seen.truncated else [])


def gallery_main(args) -> int:
    read_text = lambda path: path.read_text(errors="replace") if path and path.is_file() else None
    head = read_text(args.head)
    if args.entries:
        found = gallery_read(head)
        if found.crashes or found.truncated:
            print("own red: " + "; ".join(found.crashes + found.truncated[:1]), file=sys.stderr)
            return 1
        print(",".join(gallery_entries(head)))
        return 0 if found.failed else 2
    verdict = gallery_classify(head, read_text(args.base) if args.base else None, args.base_name)
    if args.json:
        print(json.dumps(None if verdict is None else
                         {"own": verdict.own, "reasons": verdict.reasons, "shared": verdict.shared}))
    elif verdict is None:
        print("not a gallery red: the shard has no broken or over-budget state")
    else:
        if args.annotate:
            # Base reds are warnings (the rulebook); the head's own reds stay failures.
            for name in verdict.shared:
                print(f"::warning title=gallery health: base red::{name} (red the same way on {args.base_name})")
            for reason in verdict.reasons:
                print(f"::error title=gallery health::{reason}")
        if verdict.own:
            print("own red: " + "\n  ".join([""] + verdict.reasons).lstrip("\n "))
        else:
            print(f"base red: every red state is red the same way on {args.base_name}: " + "; ".join(verdict.shared)[:600])
    return 2 if verdict is None else (1 if verdict.own else 0)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    one = sub.add_parser("classify")
    one.add_argument("--head", required=True, type=Path)
    one.add_argument("--base", type=Path)
    one.add_argument("--job", default="")
    one.add_argument("--base-name", default="the base")
    one.add_argument("--json", action="store_true")
    gallery = sub.add_parser("gallery", help="a gallery health shard's health.json against the base's")
    gallery.add_argument("--head", required=True, type=Path)
    gallery.add_argument("--base", type=Path)
    gallery.add_argument("--base-name", default="the base")
    gallery.add_argument("--entries", action="store_true", help="print the entries to replay on the base")
    gallery.add_argument("--annotate", action="store_true", help="GitHub annotations: base reds warn, own reds fail")
    gallery.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.command == "gallery":
        return gallery_main(args)
    head = args.head.read_text(errors="replace")
    base = args.base.read_text(errors="replace") if args.base else None
    verdict = classify(head, base, args.job, args.base_name)
    if args.json:
        print(json.dumps(None if verdict is None else
                         {"own": verdict.own, "reasons": verdict.reasons, "shared": verdict.shared}))
    elif verdict is None:
        print("not a test red: the log names no failing test, crash or cut-short run")
    elif verdict.own:
        print("own red: " + "\n  ".join([""] + verdict.reasons).lstrip("\n "))
    else:
        print("base red: every failing test fails on the base too: " + "; ".join(verdict.shared)[:600])
    return 2 if verdict is None else (1 if verdict.own else 0)


if __name__ == "__main__":
    raise SystemExit(main())
