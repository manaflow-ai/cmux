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

    test_reds.py runner --job JOB.json [--annotations ANNOTATIONS.json] [--log LOG]

says whether a failed job lost its runner (lost_runner: infra, no verdict, re-run it; exit 0) or has a verdict (exit 1).
`classify` prints one line per reason and exits 0 when the job's red is the base's, 1 when it is the head's own and 2
when the log names no failing test, crash or cut-short run (not a test red: the caller judges it as before).

Gallery health (scripts/gallery-matrix/health.ts) is judged the same way, per state, from the health.json a shard
writes: a broken state (it errors, never readies, or its play cannot reach it) or one over its ready-time budget
is the base's only when the same state is red the same way on the base (any budget miss is one kind; a broken
state's reason is its kind, numbers aside). A render that crashed, or a shard with no whole health.json, is the
head's own. gallery-health.yml replays a pull request's red states on the base it merged with and asks:

    test_reds.py gallery --head HEAD/health.json --entries               the entries of those states
    test_reds.py gallery --head HEAD/health.json --states                the red states (entry#variant) it replays
    test_reds.py gallery --head HEAD/health.json --base BASE/health.json [--base ...] [--annotate] [--json]

with the same exit codes (`--entries` and `--states` exit 1 when the head's red is its own whatever the base shows).
"""
from __future__ import annotations

import argparse
import copy
import importlib.util
import json
import os
import re
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path
from urllib.error import URLError
from urllib.request import urlopen

# Each line of `gh run view --log` or of the job-logs endpoint starts with its time.
STAMP = re.compile(r"^(?:[^\t]*\t[^\t]*\t)?﻿?\d{4}-\d\d-\d\dT[\d:.]+Z ?")
# A terminal escape: a CSI sequence (colour, cursor) or an OSC one (a hyperlink, a title), as base_red_excuse reads them.
ANSI = re.compile(r"\x1b(?:\[[0-?]*[ -/]*[@-~]|\][^\x07]*(?:\x07|\x1b\\))")

FAILED = (
    # Swift Testing: `name()`, or a display name (`@Test("A capped plan …")` prints `✘ Test "A capped plan …"`).
    re.compile(r"✘ Test (\"[^\"\n]*\"|.+?\)) (?:recorded an issue|failed)"),
    re.compile(r"Test Case '-\[(\S+ \S+)\]' failed"),  # XCTest
    re.compile(r"^test (\S+) \.\.\. FAILED$"),  # cargo test
    re.compile(r"^(?:FAIL|ERROR): (\S+ \([^)]+\))"),  # unittest
    re.compile(r"^FAILED (\S+::\S+)"),  # pytest
)
# Where a display-named Swift Testing failure recorded its issue: `✘ Test "name" recorded an issue [with N
# arguments ...] at <File>.swift:<line>:<col>: <expectation text>`. A `@Test("...")` name prints with no suite,
# and suites run interleaved (three were open at once in
# tests/fixtures/test_reds/26346-head-run-40620080851.log), so the enclosing suite cannot be read from the line;
# the issue's file can, and two suites with the same display name are in different files. The source location is
# the FIRST ` at <file>.swift:<line>:<col>` after the optional `with N arguments ...` clause, which is where
# Swift Testing prints it: the expectation text follows on the same line and can quote another location
# ("raised at Other.swift:14:2"), so scanning greedily to the last one records the wrong file and a shared base
# red then reads as the head's own. The arguments clause is skipped non-greedily, since an argument value may
# hold a `.swift:` of its own (cmux#35902). The filename class takes `/` so a module-relative location
# (`Package/CloudPlanTests.swift`) records its file instead of nothing (cmux#35961).
ISSUE_SITE = re.compile(r'✘ Test ("[^"\n]*") recorded an issue(?: with \d+ argument.*?)? at '
                        r'([\w/+.-]+\.swift):\d+:\d+')
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
# A harness's `--- ` section heading names what follows, never a crash itself: fresh_home_launch_smoke.py prints
# "--- the app's errors in the system log (an uncaught exception or assertion names itself here)" above every failed
# launch's log, and a relaunch over its time budget read as "the test process crashed" (cmuxterm-hq#7285, run
# 42053582212). Only that harness's known headings are exempt; any other line, `--- ` or not, still counts.
HEADING = re.compile(r"^--- (?:the app's errors in the system log \(an uncaught exception or assertion names itself "
                     r"here\)|app output \(last \d+ lines\))$")
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
# A pass whose line another stream cut into: Swift Testing prints ✔ only for a test that passed, so
# "✔ Test aFailureNothingRetriesShowsAtOnceswift runtime: backtrace-on-crash ..." (run 41665450504, the helper killed
# with the rest of the line unwritten) is that test's pass. spliced_pass matches a started name followed by anything
# but more of a test name and its "(": foo is not taken for fooBar().
def spliced_pass(name: str, text: str) -> bool:
    return re.search(rf"✔ Test {re.escape(name)}(?!\w*\()", text) is not None


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
        self.passed: set = set()
        self.messages: dict = {}
        # A display-named failure's issue files (ISSUE_SITE): {'"a name"': {"ATests.swift"}}. Empty for a test
        # whose name already says its suite (`a()`, `Suite.test()`), and for a log that prints no issue line.
        self.sites: dict = {}
        self.crashes: list = []
        self.truncated: list = []
        # The runner lines that report more failures than its parsers name (unnamed_failures): with any, no failure of
        # this log can be told from another, so its per-test results are not whole and a reason says so in truncated
        # (read(); #41222's review F1: one reading every consumer goes through, never a check per consumer).
        self.unnamed: list = []
        # read_bun's failures, each once per result that failed it (a `(fail)` line, an unhandled error): a test that
        # fails twice is not one that fails once (failed_tests).
        self.counts: Counter = Counter()
        # (step, attempt, kind, what) of each record read_bun kept: every bun failure and unnamed marker carries the step
        # (its index among the steps read) and the attempt there that made it, so no reader can mix two of them up.
        self.records: list = []


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


# Tokens that differ run to run in the same error (2026-11-04: the same release-notary red on a PR and on the base
# named /tmp/tmp.Pw5bL0wmeb on one side and another mktemp name on the other). volatile() masks them before two
# errors are compared; it never decides on its own that a red is the base's, only that two lines say the same thing.
# A temp dir named for its run: mktemp's tmp.XXXXXXXXXX and Python's tmpXXXXXXXX under /tmp or $RUNNER_TEMP, a UUID
# under $RUNNER_TEMP, macOS's /var/folders/XX/YYYY/T root; the runner's checkout root; an ISO time. Only names shaped
# like these: /tmp/release-notes.md and /tmp/appcast.xml stay two errors. Numbers are left to the caller
# (base_red_excuse masks every digit of an error line; a test's message keeps its numbers, so a timing or count
# that changed is still a different failure). Hex ids and UUIDs outside a temp dir are compared as they are: a
# missing artifact deadbeef1 is not a missing artifact abcdef12 (base_red_excuse's mask_shas masks only commit shas
# for the same reason).
_TEMP_ROOT = r"(?:(?<![\w.])/tmp|(?:/[^/\s'\"]+)*/_temp)"
_TEMP_NAME = (r"(?:tmp\.[A-Za-z0-9]{6,}|tmp[a-z0-9_]{8}|"
              r"[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})(?![\w-])")
VOLATILE = (
    (re.compile(r"(?:/private)?/var/folders/[^/\s'\"]+/[^/\s'\"]+/T(?=/|\b)"), "<tmp>"),
    (re.compile(_TEMP_ROOT + "/" + _TEMP_NAME), "<tmp>"),
    (re.compile(r"(?:/[^/\s'\"]+)*/_temp(?=/)"), "<runner-temp>"),
    (re.compile(r"(?:/home/runner/work|(?:/[^/\s'\"]+)*/_work)/[^/\s'\"]+/[^/\s'\"]+(?=/)"), "<workspace>"),
    (re.compile(r"\b\d{4}-\d\d-\d\d[T ]\d\d:\d\d(?::\d\d(?:[.,]\d+)?)?(?:Z|[+-]\d\d:?\d\d)?"), "<time>"),
)


def volatile(text: str) -> str:
    """TEXT with its run-to-run tokens masked (VOLATILE), for comparing one error with another."""
    for pattern, mask in VOLATILE:
        text = pattern.sub(mask, text)
    return text


def same_error(head: str | None, base: str | None) -> bool:
    """Whether two printed errors say the same thing once their run-to-run tokens are masked."""
    return bool(head) and bool(base) and volatile(head) == volatile(base)


def plain(log: str) -> str:
    """LOG without its terminal escapes (ANSI): what a log reader hands every parser (#41329's review F2: a summary
    matched on the raw line missed `\x1b[31mFAILED\x1b[0m`)."""
    return ANSI.sub("", log)


def log_lines(log: str) -> list[str]:
    """Every line of a job log with its timestamp and colours removed, the runner's step echoes included."""
    # Swift Testing prefixes some event lines with a zero-width space (U+200B) when another writer's output
    # shares the stream ("\u200b✔ Suite \"x\" passed"); left in, the anchored suite patterns miss the line and
    # a suite that passed reads as never finished (https://github.com/manaflow-ai/cmux/pull/35296).
    return [STAMP.sub("", ANSI.sub("", line)).lstrip("\u200b").rstrip() for line in log.splitlines()]


def lines_of(log: str) -> list[str]:
    """What the job's steps printed: log_lines without the runner's echo of each step's script (echoed)."""
    lines = log_lines(log)
    skip = echoed(lines)
    return [text for n, text in enumerate(lines) if n not in skip]


class Steps(str):
    """A log already split into its steps' sections (a FailedView's text: base_red_excuse.failed_view placed each
    section and judged it failed). Its text is the sections joined, so any reader of a str reads it; the readers of
    steps (step_sections) read each section as one step and never judge pass or fail again on it (#41329's review
    follow-up F3: the joined failed sections were split by their echoes again, a failed section with no `##[error]`
    read as passing, and its unnamed bun count went)."""
    sections: tuple

    def __new__(cls, sections):
        made = super().__new__(cls, "\n".join(sections))
        made.sections = tuple(sections)
        return made


def step_sections(log: str) -> list[tuple[bool, list[str]]]:
    """(whether a step that passed printed it, its lines_of) of each step of LOG, in order; the lines before the first
    step's echo are a section of their own. A Steps text is read as it was split: each section a step, none passed."""
    if isinstance(log, Steps):
        return [(False, lines_of(section)) for section in log.sections]
    lines = log_lines(log)
    skip = echoed(lines)
    passed = passed_steps(lines, skip)
    found: list[tuple[bool, list[str]]] = [(False, [])]
    for n, text in enumerate(lines):
        if n in skip:
            if ECHO_START.match(text):
                found.append((n in passed, []))
            continue
        found[-1][1].append(text)
    return found


def unjudged(log: str) -> Steps:
    """LOG split into its steps at each step's echo, none judged passed: a log whose lines no reader could place on
    its steps (base_red_excuse's UNPLACED) has no step known to have passed, so every step's lines are read, each
    as its own step (#41329's review follow-up F3)."""
    raw = log.splitlines()
    lines = log_lines(log)
    starts = [n for n in sorted(echoed(lines)) if ECHO_START.match(lines[n])]
    bounds = [0] + starts + [len(raw)]
    return Steps(["\n".join(raw[a:b]) for a, b in zip(bounds, bounds[1:]) if b > a])


def step_lines(log: str) -> list[tuple[bool, str]]:
    """lines_of, each with whether a step that passed printed it (step_sections)."""
    return [(passing, text) for passing, section in step_sections(log) for text in section]


def red_steps(log: str) -> list[list[str]]:
    """The lines of each step of LOG that did not pass (step_sections)."""
    return [section for passing, section in step_sections(log) if not passing]


def red_lines(log: str) -> list[str]:
    """What the job's steps that did not pass printed: lines_of without every line of a step that passed. The source
    every reader of a red's tests reads (parse_log, failed_in), so no reader sees a passing step's lines (#41244's
    review F1 at 0a9fdca7: read_bun was handed them before the filter, and a filter inside each reader left the next
    reader to skip it)."""
    return [text for section in red_steps(log) for text in section]


# A crash-class rule's failure line (cmux-next-crash-class.yml; crash_class_fast_gate.py lists the prefixes):
# `objc-selectors: <file>:<line>: super.<sel> (<Class> call:<sel>/<n>): probe needed; run ...` and
# `cef-objc-contract: <detail>`. The rule is a named failure the way a test is, so a base red there is excused.
CRASH_RULES = ("objc-selectors", "cef-objc-contract")
CRASH_RULE = re.compile(r"^(?:##\[error\])?(" + "|".join(CRASH_RULES) + r"): (.+?)\s*$")
CRASH_RULE_SITE = re.compile(r"^(\S+?:\d+): (.+?)(?:: probe needed.*|; .*)?$")


def crash_rule_failure(text: str) -> str | None:
    """The failure key of a crash-class rule line: `rule file:line detail` (rule, site, selector) when the line
    carries a site, else `rule detail`; the trailing advice (`probe needed; run ...`) is not part of the key."""
    if not (match := CRASH_RULE.match(text)):
        return None
    rule, detail = match.groups()
    if site := CRASH_RULE_SITE.match(detail):
        return f"{rule} {site.group(1)} {site.group(2)}"
    return f"{rule} {detail}"


def is_crash_rule_failure(name: str) -> bool:
    """Whether a failure name came from crash_rule_failure (a rule line, not a test)."""
    return name.split(" ", 1)[0] in CRASH_RULES


# A check script's failure line that names what failed, read as a named failure the way a crash-class rule's is
# (2026-11-11, cmux#41205 at ba8ff399): scripts/cmux-next/check-spawn-owner.py prints one line per file over its
# baseline, `check-spawn-owner: PATH has N spawn line(s) with no owner (a new file|baseline M).`, and no test name,
# so a base red there had no identity to compare. The key is the whole line's content: the file, its count, its row.
CHECK_RULES = ("check-spawn-owner",)
CHECK_RULE_LINE = (r"(check-spawn-owner): (cmux-tui/crates/[\w.+-]+/\S+\.rs) has (\d+) spawn line\(s\) with no owner "
                   r"\((a new file|baseline \d+)\)\.")
CHECK_RULE = re.compile(rf"^(?:##\[error\])?{CHECK_RULE_LINE}$")
# The same line quoted after a test's assertion (`AssertionError: 1 != 0 : check-spawn-owner: ...`).
CHECK_RULE_QUOTED = re.compile(rf"(?:^|: ){CHECK_RULE_LINE}$")


def check_rule_key(match: re.Match) -> str:
    rule, path, count, row = match.groups()
    return f"{rule} {path}: {count} spawn line(s) with no owner ({row})"


def check_rule_failure(text: str) -> str | None:
    """The failure key of a check rule's own line (CHECK_RULE), at the start of the line; None for any other line."""
    return check_rule_key(match) if (match := CHECK_RULE.match(text)) else None


def is_rule_failure(name: str) -> bool:
    """Whether a failure name is a rule's line (a crash-class rule or a check rule), not a test's."""
    return name.split(" ", 1)[0] in CRASH_RULES + CHECK_RULES


def failed_names(lines: list[str]) -> set[str]:
    """The failing tests LINES name: each FAILED pattern's, an xcresult `FAILED:` line's and the names under
    xcodebuild's `Failing tests:` (XCRESULT_FAILED). LINES are a step's output (lines_of), never its echoed script."""
    found: set[str] = set()
    listing = False
    for text in lines:
        if text.startswith(TAP_MARKER):
            continue  # structured diagnostics are data, never another raw failure/runtime line
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
        if rule := crash_rule_failure(text) or check_rule_failure(text):
            found.add(rule)
        if match := SUITE_FAILED.search(text):
            found.add(match.group(1).strip('"'))
        if match := XCRESULT_FAILED.match(text):
            found.add(f"{match.group(1)}.{match.group(2)}")
    return found


# A runner's own word that tests failed, whatever names them: a whole-log comparison (base_red_excuse.py's unplaced
# one) that reads such a line and no failing test from the same runner has nothing to tell one failure from another,
# so it must not stand (cmux#41158's review F1: two different bun failures, no name read, the same `expect()`
# headline, were one red). Bun's (its ` N fail` count, the wrapper's `FAIL file` line, a `(fail)` result) are told
# apart from the others, whose names failed_names reads.
BUN_FAILED_COUNT = re.compile(r"^\s*[1-9]\d* fail$")
FAILURE_MARKERS = (
    re.compile(r"^test result: FAILED\."),  # cargo test
    re.compile(r"^FAILED \((?:failures|errors)=\d"),  # unittest
    re.compile(r"^=+ .*\b\d+ failed\b.*=+$"),  # pytest
    re.compile(r"Executed \d+ tests?, with [1-9]\d* failures?"),  # XCTest
    re.compile(r"^✘ Test run with \d+ tests?\b.*\bfailed\b"),  # Swift Testing
)
# Each runner's reported failure total, where its summary counts what failed_names names one line per (#41166's
# review F2: a log with one parsed name and one unparsed failure counted as fully identified, since an unnamed failure
# was recorded only when no name at all was read). Per invocation: each summary is compared with the lines its own
# runner's pattern named since that runner's previous summary, so a run that names more never covers one that names
# fewer:
# - cargo `test result: FAILED. X passed; N failed;` per test binary, against its `test NAME ... FAILED` lines;
# - unittest `FAILED (failures=N, errors=M, unexpected successes=K)` (each a test or subtest, none of them named by
#   anything but a `FAIL:` / `ERROR:` line; an unexpected success is named by none), against those lines;
# - pytest's closing `N failed, M error(s)` (`rerun`s are attempts, never counted), against its `FAILED a::b` lines
#   (an `ERROR a::b` is named by none);
# - Swift Testing's `Test run with ... with N issues` (less `including K known issues`): its summary counts issues,
#   never tests, and each issue prints one `✘ Test|Suite X recorded an issue` line, which are counted;
# - bun's ` N fail` per invocation (the wrapper's retry is its own invocation), against the failures read_bun keeps
#   from that invocation: each `(fail)` result and unhandled error, and each recap `(fail)` line that names one no
#   result did. Never against the recap's lines: two recap lines of one title are one identity once read_bun reads
#   them, so `2 fail` beside them names one failure (#41222's review F1). An attempt the wrapper's retry supersedes
#   is dropped with its count, as read_bun drops its failures (#41222's review F2).
# XCTest's `Executed N tests, with M failures` counts assertion failures, once per enclosing suite as well, so no total
# of its can be set against names: an XCTest summary is unnamed only when nothing XCTest (`Test Case '-[...]' failed`,
# an xcresult `FAILED:` line, xcodebuild's `Failing tests:` list) named a failure; likewise a summary line whose count
# cannot be read.
CARGO_FAILED_TOTAL = re.compile(r"^test result: FAILED\. \d+ passed; (\d+) failed\b")
UNITTEST_FAILED_TOTAL = re.compile(r"^FAILED \(([^)]*)\)$")
UNITTEST_COUNTED = re.compile(r"\b(failures|errors|unexpected successes)=(\d+)")
PYTEST_TOTAL = re.compile(r"^=+ (.*?) =+$")
PYTEST_COUNTED = re.compile(r"\b(\d+) (failed|errors?)\b")
SWIFT_ISSUES = re.compile(r"^✘ Test run with \d+ tests?\b.*\bwith (\d+) issues?\b(?:.*?\bincluding (\d+) known issues?)?")
SWIFT_ISSUE_LINE = re.compile(r"✘ (?:Test|Suite) .* recorded an issue\b")


def unnamed_failures(lines: list[str], steps: list[list[str]] | None = None) -> list[str]:
    """The runner lines of LINES (a step's output, lines_of) that report more failures than that runner's lines name
    (see above), each summary against the names its runner printed since its previous summary: a failure no parser
    names, which no comparison can tell from another."""
    bun = Result()
    read_bun(lines, bun, steps)
    return runner_unnamed(lines) + bun.unnamed


UNNAMED_WHY = "its log reports more failing tests than it names"


def unnamed_why(unnamed: list[str]) -> str:
    """The truncated reason read() gives a log with UNNAMED failures (unnamed_failures)."""
    return f"{UNNAMED_WHY} ({unnamed[0][:200]}), so no failure can be told from another"


def runner_unnamed(lines: list[str]) -> list[str]:
    """unnamed_failures of every runner but bun, whose count read_bun sets against the identities it keeps."""
    found: list[str] = []
    since = Counter()  # per runner, the lines it named since its last summary
    xc_family = 0  # XCTest, xcresult `FAILED:` and xcodebuild listing names, anywhere in LINES
    xc_summaries: list[str] = []
    listing = False
    for text in lines:
        if text.startswith(TAP_MARKER):
            continue
        if listing:
            if XCODEBUILD_FAILED.match(text):
                xc_family += 1
                continue
            listing = False
        if text.strip() == XCODEBUILD_FAILING:
            listing = True
            continue
        if FAILED[0].search(text) and SWIFT_ISSUE_LINE.search(text) or \
                SUITE_FAILED.search(text) and SWIFT_ISSUE_LINE.search(text):
            since["swift"] += 1
        for runner, n in (("cargo", 2), ("unittest", 3), ("pytest", 4)):
            if FAILED[n].search(text):
                since[runner] += 1
        if FAILED[1].search(text) or XCRESULT_FAILED.match(text):
            xc_family += 1
        reported, runner = None, ""
        if FAILURE_MARKERS[0].search(text):
            runner, match = "cargo", CARGO_FAILED_TOTAL.match(text)
            reported = int(match.group(1)) if match else None
        elif (match := UNITTEST_FAILED_TOTAL.match(text)) and (FAILURE_MARKERS[1].search(text)
                                                              or UNITTEST_COUNTED.search(match.group(1))):
            counts = UNITTEST_COUNTED.findall(match.group(1))
            runner, reported = "unittest", sum(int(n) for _, n in counts) if counts else None
        elif (match := PYTEST_TOTAL.match(text)) and PYTEST_COUNTED.search(match.group(1)):
            runner, reported = "pytest", sum(int(n) for n, _ in PYTEST_COUNTED.findall(match.group(1)))
        elif FAILURE_MARKERS[4].search(text):
            match = SWIFT_ISSUES.match(text)
            runner, reported = "swift", int(match.group(1)) - int(match.group(2) or 0) if match else None
        elif FAILURE_MARKERS[3].search(text):
            xc_summaries.append(text)
        if runner:
            # A count that cannot be read is unnamed unless its runner named something since its last summary.
            if (reported is None and not since[runner]) or (reported is not None and reported > since[runner]):
                found.append(text)
            since[runner] = 0
    if not xc_family:
        found.extend(xc_summaries)
    return found


def failed_tests(lines: list[str], unnamed: list | None = None, steps: list[list[str]] | None = None) -> Counter:
    """The failing tests LINES name, counted, by the one parser every reader shares: failed_names' (once per line that
    names one; an xcresult `FAILED:` line and an entry under xcodebuild's `Failing tests:` are two lines, each
    counted: cmux#41158's review F2) and read_bun's `FILE > TEST` (once per result that failed it). LINES are a
    step's output (lines_of). With UNNAMED, each runner line that reports more failures than that runner's lines name
    (unnamed_failures) is added to it."""
    counted: Counter = Counter()
    listing = False
    for text in lines:
        if text.startswith(TAP_MARKER):
            continue
        if listing:
            if match := XCODEBUILD_FAILED.match(text):
                counted[match.group(1)] += 1
                continue
            listing = False
        if text.strip() == XCODEBUILD_FAILING:
            listing = True
            continue
        counted.update(failed_names([text]))
    bun = Result()
    read_bun(lines, bun, steps)  # STEPS: LINES split by step, so no bun state crosses one
    if unnamed is not None:
        unnamed.extend(runner_unnamed(lines) + bun.unnamed)
    counted.update(bun.counts)
    return counted


def failed_in(log: str, unnamed: list | None = None) -> Counter:
    """failed_tests of LOG's steps that did not pass, each read as its own step (red_steps)."""
    steps = red_steps(log)
    return failed_tests([text for section in steps for text in section], unnamed, steps)


def issue_sites(lines: list[str]) -> dict:
    """The files each display-named failure in LINES recorded an issue in (ISSUE_SITE)."""
    found: dict = {}
    for text in lines:
        if match := ISSUE_SITE.search(text):
            found.setdefault(match.group(1), set()).add(match.group(2))
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


def read_bun(lines: list[str], result: Result, steps: list[list[str]] | None = None) -> None:
    """`bun test`'s failures into `result`: each named `FILE > TEST` under its file's header (webviews_test_results.py's
    names), or `TEST` when the recap is all that names it, with its diagnostics (bun_diagnostic, or its timeout; every
    distinct one when the name fails more than once) as its message. An unhandled error between tests is a failure
    named by its headline, with its whole block and location as its diagnostic. Each bun invocation is whole only once
    it prints its ` N fail` count: one that started (`bun test v…`, a file header or a result) and reached the next
    invocation (`bun test v…`, the wrapper's retry) or the log's end with no count was cut short, wherever it sits in
    the log. Each ` N fail` above the failures its invocation kept goes to `result.unnamed` (unnamed_failures), as
    does the wrapper's `FAIL file` when no attempt of its step named a failure. A recap title is counted as often as
    the recap lists it, less the results of its invocation that named it (#41222's review F1 at 6719ba22).

    Every record is made in one step and one attempt and carries both (BunAttempt; Result.records): no state crosses a
    step (STEPS: each step's lines, already split; LINES alone is one step) or an attempt. An attempt is one file's
    run (run-webviews-tests.sh runs one file per process), from its `bun test v…` line, its file header or the
    wrapper's retry; the retry supersedes every earlier attempt of its file in the step, every kind of record with it:
    named failures, recap titles, unhandled errors, counts, diagnostics, passes, ` N fail` markers, and whether it
    named anything (#41222's review F2; #41329's review F1 and the follow-up: recap titles were bare names a
    `FILE > ` filter missed; a `(fail)` in one step set a global flag that hid another step's `FAIL file`). A
    cut-short attempt's note stays on purpose: a run killed before its count is never a base red. LINES hold no
    passing step's output: the caller filters at the source (red_lines)."""
    attempts: list[BunAttempt] = []
    for step, section in enumerate(steps if steps is not None else [lines]):
        _read_bun_step(section, step, attempts, result)
    kept = [attempt for attempt in attempts if not attempt.superseded]
    diagnostics: dict = {}  # name: its distinct diagnostics, over the attempts that count
    for attempt in kept:
        result.failed |= attempt.failed
        result.counts.update(attempt.counts)
        result.passed |= attempt.passed
        result.unnamed.extend(attempt.marked)
        result.records += [(attempt.step, attempt.number, "failed", name) for name in sorted(attempt.counts.elements())]
        result.records += [(attempt.step, attempt.number, "unnamed", line) for line in attempt.marked]
        for name, found in attempt.diagnostics.items():
            mine = diagnostics.setdefault(name, [])
            mine.extend(message for message in found if message not in mine)
    for attempt in kept:
        # A `FAIL file` is unnamed unless the file's last attempt that counts named a failure: the one in its own
        # step, else anywhere; never another file's or an earlier run's (#41329's follow-up F2: a global flag let one
        # `(fail)` name every file). A file no header names (run-webviews-tests.sh prints `FAIL file` and the file's
        # results under its own group, no `file:` line) is named when an attempt of its step named a failure.
        for line in attempt.fail_files:
            of = BUN_PACKAGE.sub("", BUN_RESULT.match(line).group(2))
            # The runs of the file printed before this line: in its step (up to its attempt), else anywhere.
            runs = ([other for other in kept if other.file == of and other.step == attempt.step
                     and other.number <= attempt.number]
                    or [other for other in kept if other.file == of and other.step < attempt.step])
            named = runs[-1].named if runs else any(other.named for other in kept if other.step == attempt.step)
            if not named:
                result.unnamed.append(line)
                result.records.append((attempt.step, attempt.number, "unnamed", line))
    for name, found in diagnostics.items():
        if found:
            # Like web_failures: several diagnostics for one name are all compared, none dropped, in sorted order so
            # head and base compare whatever order their runs printed them in.
            result.messages[name] = "\n--- repeated failure ---\n".join(sorted(found))


class BunAttempt:
    """One attempt's records (read_bun): made in step STEP, its NUMBER-th attempt there, of FILE ("" before a header)."""

    def __init__(self, step: int, number: int):
        self.step, self.number, self.file, self.superseded, self.named = step, number, "", False, False
        self.failed: set = set()
        self.counts: Counter = Counter()
        self.diagnostics: dict = {}
        self.passed: set = set()
        self.marked: list = []  # its ` N fail` lines that count more failures than it kept
        self.fail_files: list = []  # the wrapper's `FAIL file` lines printed after it


def _read_bun_step(lines: list[str], step: int, attempts: list, result: Result) -> None:
    """read_bun's reading of one step's LINES, its attempts appended to ATTEMPTS."""
    file, said, where, last, recap, unhandled, open_run = "", [], "", None, False, False, False
    results: Counter = Counter()  # this invocation's `(fail)` results by title (bun's `describe > test`)
    recapped: Counter = Counter()  # this invocation's recap lines by title
    kept = 0  # the failures this invocation recorded under an identity (fail, counted): what its ` N fail` must match
    block = False  # reading the assertion block under an `error:` line, up to its stack or annotation
    run_file = ""  # the file of the run that just ended, for run-webviews-tests.sh's retry
    added = None  # the diagnostic the last result line added, which its timeout note replaces
    pending = False  # an unhandled error whose block is being read: recorded when it ends
    mine: list[BunAttempt] = []

    def begin() -> BunAttempt:
        mine.append(BunAttempt(step, len(mine)))
        attempts.append(mine[-1])
        return mine[-1]

    begin()

    def fail(name: str, message: str, counted: bool = True) -> str | None:
        nonlocal kept
        attempt = mine[-1]
        attempt.failed.add(name)
        result.ran = True
        if counted:
            attempt.counts[name] += 1
            kept += 1
        if message and message not in attempt.diagnostics.setdefault(name, []):
            attempt.diagnostics[name].append(message)
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

    def recap_failures() -> None:
        """Each recap title as often as the recap lists it beyond its invocation's results, as `TEST` (no file)."""
        for title, listed in recapped.items():
            for _ in range(listed - results[title]):
                fail(title, "")
        results.clear()
        recapped.clear()

    def end_run(why: str) -> None:
        nonlocal open_run
        if open_run:
            result.truncated.append(f"a bun test run printed no ` N pass` / ` N fail` summary before {why}")
        open_run = False

    for text in lines:
        if SWIFT_TEST_SUMMARY_FIXTURE.search(text):
            continue
        if BUN_RUN.match(text) or text == WEB_RETRY:
            recap_failures()
        if BUN_RUN.match(text) or BUN_FILE.match(text) or text == WEB_RETRY or BUN_TEST.match(text) or \
                BUN_UNHANDLED.match(text) or BUN_COUNT.match(text):
            flush()
        if BUN_RUN.match(text):
            end_run("the next bun test run started")
            begin()
            open_run = result.ran = True  # a started run is tests, whatever the job is named
            kept = 0
        elif BUN_RECAP.match(text):
            recap, last = True, None
        elif match := BUN_FILE.match(text):
            file, said, where, last, recap, open_run = BUN_PACKAGE.sub("", match.group(1)), [], "", None, False, True
            run_file, block, result.ran = file, False, True
            if mine[-1].file and mine[-1].file != file:
                begin()  # a second file in one invocation: its own attempt
            mine[-1].file = file
        elif text == WEB_RETRY and run_file:
            end_run("the wrapper ran its file again")
            # run-webviews-tests.sh ran a red file again, alone: only that run counts (webviews_test_results.py).
            # Every earlier attempt of the file in this step goes, every kind of its records with it.
            for attempt in mine:
                if attempt.file == run_file:
                    attempt.superseded = True
            begin()
            kept = 0
        elif text == WEB_RETRY:
            begin()
            kept = 0
        elif match := BUN_TEST.match(text):
            result.ran, open_run, last = True, True, None
            name = match.group(2)
            mine[-1].named = mine[-1].named or match.group(1) == "fail"
            added = None
            if match.group(1) == "pass" and not recap:
                mine[-1].passed.add(f"{file} > {name}" if file else name)
            if match.group(1) == "fail" and not recap:
                last = f"{file} > {name}" if file else name
                added = fail(last, bun_diagnostic(said, where))
                results[name] += 1
            elif match.group(1) == "fail":
                recapped[name] += 1  # counted at the run's end (recap_failures), beyond what its results named
            said, where, block = [], "", False
        elif BUN_UNHANDLED.match(text):
            unhandled = mine[-1].named = True
        elif BUN_COUNT.match(text):
            # Its run's end, whatever block it follows: an assertion block never holds the count (unnamed_failures).
            if unhandled:
                fail(f"{file} > unhandled error" if file else "unhandled error", "")
            recap_failures()
            if int(text.split()[0]) > kept:
                mine[-1].marked.append(text)
            file, said, where, last, recap, unhandled, open_run = "", [], "", None, False, False, False
            block, kept = False, 0
        elif (match := BUN_RESULT.match(text)) and match.group(1) == "FAIL":
            mine[-1].fail_files.append(text)
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
                mine[-1].diagnostics[last].remove(added)
            added = None
            fail(last, f"timed out after {match.group(1)}ms", counted=False)  # the same result, its diagnostic
    flush()
    recap_failures()
    end_run("the log ended")


# Each log is parsed once per process (2026-11-06, cmux#36356 at 2c9f6957). base_red_excuse.py's window compares the
# head's log with up to BASE_WINDOW base logs and re-classifies the whole window each time it grows, and classify,
# classify_any, observations and flaky_failures each read the head again: 50 reads of 6 logs. A `cmux-next daemon
# tests` log is 20 to 27 MB, about 3 s a read, so that judge spent 110 s of CPU in read() alone and merge_hold's 120 s
# bound on the classifier refused the merge three times. A read depends only on the log's text and BUN, so its result
# is kept by text: each caller gets its own copy, and at most KEEP_PARSED texts are kept (the window's logs, which
# the judge holds anyway, plus the head), the oldest dropped first.
KEEP_PARSED = 16
_parsed: dict = {}


def _kept(kind: str, text: str, extra, parse):
    key = (kind, text, extra)
    if key not in _parsed:
        if len(_parsed) >= KEEP_PARSED:
            _parsed.pop(next(iter(_parsed)))
        _parsed[key] = parse()
    return copy.deepcopy(_parsed[key])


def read(log: str | None, bun: bool = True) -> Result:
    """The tests a job log ran, failed and crashed, and whether its per-test results are whole. `bun=False` leaves
    bun's own output to the caller (web_failures parses it itself). Parsed once per text (KEEP_PARSED)."""
    if not log or log.isspace():  # never kept: an unread or empty log is no work to save
        return parse_log(log, bun)
    return _kept("read", log, (bun, log.sections if isinstance(log, Steps) else None), lambda: parse_log(log, bun))


def parse_log(log: str | None, bun: bool = True) -> Result:
    """read(), uncached."""
    result = Result()
    if log is None or not log.strip():
        result.truncated.append("its log could not be read" if log is None else "its log is empty")
        return result
    # The lines once, filtered at the source (step_lines): no echo, no TAP marker, and LINES holds nothing a step that
    # passed printed. Every reader below reads LINES alone (#41244's review F1 at 0a9fdca7: read_bun was handed every
    # line before the passing-step filter, so a passing step's `(fail)` and ` 2 fail` called the whole job cut short,
    # and a filter inside each reader left the next reader to skip it). The one reader of a passing step's lines is
    # the crash scan, by rule: a segfault there is still a crash (a signal someone sent, SHELL_SIGNAL, is the step's).
    sections = [(passing, [text for text in section if not text.startswith(TAP_MARKER)])
                for passing, section in step_sections(log)]
    shown = [(passing, text) for passing, section in sections for text in section]
    lines = [text for passing, text in shown if not passing]
    started = {m.group(1) for text in lines for m in [STARTED.search(text)] if m}
    stack: list[str] = []
    signals: list[str] = []
    named: list[str] = []
    crashed = False
    for passing, text in shown:
        if SWIFT_TEST_SUMMARY_FIXTURE.search(text):
            continue
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
        killed = SHELL_SIGNAL.search(text) and not passing
        runtime = HELPER_KILLED.search(text) or killed or (
            (CRASH.search(text) or CRASH_AT_START.search(text) or SIGNALED.search(text)) and not TEST_LINE.search(text) and not HEADING.match(text))
        if runtime:
            crashed = True
            if number := signal_of(text):
                signals.append(number)
        if crashed and ("$s" in text or re.match(r"^\s*\d+\s+\S+\s+0x[0-9a-f]+ ", text)):
            stack.append(text)
    for text in lines:
        if SWIFT_TEST_SUMMARY_FIXTURE.search(text):
            continue
        if RAN.search(text) or UNITTEST_LINE.match(text) or BUN_STARTED.match(text) or BUN_RESULT.match(text):
            result.ran = True
        if (match := BUN_RESULT.match(text)) and match.group(1) == "TIMEOUT":
            result.truncated.append(f"{match.group(2)} timed out (killed at the wrapper's hard limit)")
        if TRUNCATED.search(text) or NO_RESULT.search(text):
            why = re.sub(r"^##\[error\]|^::error[^:]*::", "", text).strip()
            result.truncated.append(why[:200])
    real = [text for text in lines if not SWIFT_TEST_SUMMARY_FIXTURE.search(text)]
    if names := failed_names(real):
        result.failed |= names
        result.ran = True
    result.sites = issue_sites(real)
    unfinished = started - {m.group(1) for text in lines for m in [FINISHED.search(text)] if m}
    # Each cut-into pass closes one start, the longest name it fits (fooBar(), not foo() too); a run's own
    # summary ("✔ Test run with 1 test ...") is never one, so it does not close a test named run().
    for text in lines:
        if unfinished and "✔ Test " in text and not FINISHED.search(text) and not RUN_ENDED.search(text):
            if fits := [name for name in unfinished if spliced_pass(name, text)]:
                unfinished.discard(max(fits, key=len))
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
        read_bun(lines, result, [section for passing, section in sections if not passing])
    # A failure no parser names (unnamed_failures), read here, in the reading every consumer goes through (classify,
    # classify_any, judge()'s read_head, next_batch's expand_job), never per consumer (#41222's review F1).
    result.unnamed = runner_unnamed(real) + result.unnamed
    if result.unnamed:
        result.truncated.append(unnamed_why(result.unnamed))
    if crashed:
        who = named or crashed_tests(stack, started) or ["the test process"]
        signal = f"signal {signals[0]}" if signals else "no signal named"
        result.crashes = [f"{name} crashed ({signal})" for name in dict.fromkeys(who)]
    return result


# A job the runner went away under (2026-11-03: cmux#33162's `web / react-apps-base-check (3)`, job 126154996598, on a
# Blacksmith runner): GitHub fails it about 10 minutes later with this failure annotation, keeps no log (its logs
# endpoint answers BlobNotFound) and leaves the step it was in "in_progress". Its red is the infrastructure's, not a
# verdict about the change: like a cancelled job it has nothing to compare, is never the PR's own red, and needs a
# re-run (ci-failure-attribution.yml re-runs it once; cmuxterm-hq's next-autoland rerun_infra once a head).
LOST_RUNNER = re.compile(r"lost communication with the server|The runner has received a shutdown signal|"
                         r"The hosted runner encountered an error")
BLOB_NOT_FOUND = re.compile(r"\bBlobNotFound\b|The specified blob does not exist")


def lost_runner(job, annotations=(), log=None):
    """Why failed JOB (an Actions job or check run) is infra and no verdict, or None. ANNOTATIONS are its check run's
    annotations (dicts with "message" and "annotation_level", or plain messages); LOG, when the caller read it, is
    its log text or the error its read gave. Any one is enough: a failure annotation that says the runner was lost;
    a job that completed with a step still unfinished and no step failed (the runner stopped reporting mid-step); or
    a log GitHub never stored (BlobNotFound) with no step failed. A job with a failed step keeps its verdict."""
    if (job or {}).get("conclusion") != "failure":
        return None
    for note in annotations or ():
        if isinstance(note, dict):
            if (note.get("annotation_level") or "failure") != "failure":
                continue
            message = str(note.get("message") or "")
        else:
            message = str(note)
        if LOST_RUNNER.search(message):
            return "its runner was lost: " + " ".join(message.split())[:200]
    steps = [step for step in (job or {}).get("steps") or [] if isinstance(step, dict)]
    if any(step.get("conclusion") == "failure" for step in steps):
        return None
    unfinished = [step for step in steps if step.get("status") != "completed"
                  and (step.get("status") == "in_progress" or step.get("started_at"))]
    if unfinished:
        said = unfinished[0].get("name")  # step-name: display
        return (f"it completed with step {said!r} still {unfinished[0].get('status')} and no "
                "step failed: its runner stopped reporting mid-step")
    if isinstance(log, str) and BLOB_NOT_FOUND.search(log):
        return "GitHub stored no log for it (BlobNotFound) and no step failed: its runner went away"
    return None


def is_test_red(found: Result, job: str = "") -> bool:
    """Whether this classifier owns the job's red: its log shows tests running, or the job is a test job by name.
    A compile or lint job that prints `Fatal error:` keeps the caller's own comparison."""
    return found.ran or bool(re.search(r"\btests?\b", job, re.I))


TAP_GROUP = "TAP final named results"
TAP_MARKER = "tap-test/v1 "


def exported_observations(lines: list[str]) -> list[dict] | None:
    """The runner's last whole export group wins over displayed excerpts. Conflicting duplicate ids are discarded."""
    complete = None
    pending, conflicts, inside = {}, set(), False
    for line in lines:
        if line in {"##[group]" + TAP_GROUP, "::group::" + TAP_GROUP}:
            pending, conflicts, inside = {}, set(), True
        elif inside and line in {"##[endgroup]", "::endgroup::"}:
            complete = [pending[name] for name in sorted(pending) if name not in conflicts]
            inside = False
        elif inside and line.startswith(TAP_MARKER):
            try:
                row = json.loads(line[len(TAP_MARKER):])
            except ValueError:
                continue
            if (not isinstance(row, dict) or row.get("schema") != "tap-test/v1"
                    or not all(isinstance(row.get(key), str) for key in ("file", "test", "outcome", "signature"))
                    or not row["file"] or not row["test"].startswith(row["file"] + " > ")
                    or row["outcome"] not in {"pass", "fail"}):
                continue
            observed = {key: row[key] for key in ("test", "outcome", "signature")}
            if row["test"] in pending and pending[row["test"]] != observed:
                conflicts.add(row["test"])
            pending[row["test"]] = observed
    return [] if inside else complete


def observations(log: str | None) -> list[dict]:
    """Positive named results from a whole run; absence, skips and infrastructure losses are never passes.

    Signatures use the classifier's Bun diagnostics, Swift issue lines or pytest's failure summary. Other readers
    can still contribute a score, but an empty diagnostic cannot excuse a future failure of that test. Read once
    per text, like read().
    """
    if not log:
        return _observations(log)
    return _kept("observations", log, None, lambda: _observations(log))


def _observations(log: str | None) -> list[dict]:
    lines = lines_of(log or "")
    exported = exported_observations(lines)
    if exported is not None:
        return exported
    found = read(log)
    if found.crashes or found.truncated or any(LOST_RUNNER.search(line) or BLOB_NOT_FOUND.search(line) for line in lines):
        return []
    passed = set(found.passed)
    patterns = (
        re.compile(r"^✔ Test (.+?\))(?: with \d+ test cases?)? passed\b"),
        re.compile(r"^Test Case '-\[(\S+ \S+)\]' passed\b"),
        re.compile(r"^test (\S+) \.\.\. ok$"),
        re.compile(r"^(\S+ \([^)]+\)) \.\.\. ok$"),
        re.compile(r"^(\S+::\S+) PASSED(?: |$)"),
    )
    signatures: dict[str, list[str]] = {}
    for line in lines:
        if SWIFT_TEST_SUMMARY_FIXTURE.search(line):
            continue
        for pattern in patterns:
            if match := pattern.search(line):
                passed.add(match.group(1))
        # Final Swift failure lines include durations; only issue lines are a stable diagnostic. Pytest's short
        # summary includes the error. A bare FAILED marker from cargo/unittest is not an error signature.
        for pattern in (FAILED[0], FAILED[4]):
            if (match := pattern.search(line)) and ("recorded an issue" in line or line.startswith("FAILED ")):
                signatures.setdefault(match.group(1), []).append(line)
    suites = {m.group(1).strip('"') for line in lines for m in [SUITE_FAILED.search(line)] if m}
    failures = {name for name in found.failed if name not in suites and not is_rule_failure(name)}
    return [{"test": name, "outcome": "fail" if name in failures else "pass",
             "signature": (found.messages.get(name) or "\n".join(sorted(set(signatures.get(name, [])))))
             if name in failures else ""} for name in sorted(passed | failures)]


TAP_STATE_URL = "https://raw.githubusercontent.com/manaflow-ai/cmux/ci-test-health/tap-tests.json"
TAP_MIN_OBSERVATIONS = 8
TAP_MIN_FLIP_RATE = 0.2
TAP_MAX_AGE = timedelta(hours=48)
# Keep the consumer bound to the producer's public snapshot limits. A bounded
# list prevents malformed state from turning into an unbounded comparison,
# while the byte cap keeps one diagnostic cheap to inspect.
TAP_MAX_QUARANTINE_SIGNATURES = 32
TAP_MAX_SIGNATURE_BYTES = 4096


def load_flake_state(path: str | Path | None = None, *, fetch: bool = False) -> dict:
    """Read one public reconciler snapshot per invocation. TAP_TESTS_STATE=off disables the supplement.

    Callers that already have HQ's state pass it to classify directly. CLI callers fetch the public mirror once,
    with a bounded deadline and no credentials; unavailable/invalid state keeps the deterministic comparison.
    """
    selected = str(path) if path is not None else os.environ.get("TAP_TESTS_STATE", "")
    if selected.lower() in {"off", "0", "false"}:
        return {}
    try:
        if selected:
            state = json.loads(Path(selected).read_text())
        elif fetch:
            with urlopen(TAP_STATE_URL, timeout=5) as response:
                state = json.load(response)
        else:
            return {}
    except (OSError, ValueError, TypeError, URLError):
        return {}
    return state if isinstance(state, dict) and state.get("schema") == "tap-tests/v1" else {}


def canonical_job(job: str) -> str:
    """A matrix shard shares its test history with the other shards, never with another workflow."""
    return re.sub(r" \(\d+(?:/\d+)?\)$", "", job.rsplit(" / ", 1)[-1])


def _tap_time(value) -> datetime | None:
    try:
        when = datetime.fromisoformat(value.replace("Z", "+00:00"))
        return when.astimezone(timezone.utc) if when.tzinfo else None
    except (AttributeError, TypeError, ValueError):
        return None


def _tap_quarantine_signatures(value) -> list[str] | None:
    """Validate the producer-owned diagnostic binding for a quarantine row."""
    if not isinstance(value, list) or not value or len(value) > TAP_MAX_QUARANTINE_SIGNATURES:
        return None
    for signature in value:
        if not isinstance(signature, str) or not signature:
            return None
        try:
            if len(signature.encode("utf-8")) > TAP_MAX_SIGNATURE_BYTES:
                return None
        except UnicodeEncodeError:
            return None
    return value


def flaky_failures(head_log: str | None, job: str, workflow: str, state: dict | None,
                   *, now: datetime | None = None) -> dict[str, str]:
    """Matching recent quarantined base flakes, with an issue and enough measured flips; never a blanket waiver."""
    if not isinstance(state, dict) or state.get("schema") != "tap-tests/v1" or not workflow or not job:
        return {}
    now = now or datetime.now(timezone.utc)
    generated = _tap_time(state.get("generated_at"))
    if generated is None or not timedelta(0) <= now - generated <= TAP_MAX_AGE:
        return {}
    tests = state.get("tests")
    if not isinstance(tests, list):
        return {}
    matching: dict[str, list[dict]] = {}
    for row in tests:
        if (isinstance(row, dict) and row.get("workflow") == workflow and row.get("job") == canonical_job(job)
                and isinstance(row.get("test"), str)):
            matching.setdefault(row["test"], []).append(row)
    known = {}
    for observed in observations(head_log):
        name, signature = observed["test"], observed["signature"]
        rows = matching.get(name, [])
        if observed["outcome"] != "fail" or not signature or len(rows) != 1:
            continue
        row = rows[0]
        observed_at = _tap_time(row.get("last_observed_at"))
        if observed_at is None or not timedelta(0) <= now - observed_at <= TAP_MAX_AGE:
            continue
        counts = [row.get(key) for key in ("observations", "passes", "failures", "flips")]
        if any(type(value) is not int or value < 0 for value in counts):
            continue
        count, passes, failures, flips = counts
        if (count < TAP_MIN_OBSERVATIONS or passes + failures != count or not passes or failures < 2
                or not 2 <= flips < count):
            continue
        # Recompute instead of trusting a rounded, corrupt or hand-edited score in the JSON.
        rate = flips / (count - 1)
        quarantine = row.get("quarantine")
        historical_signatures = row.get("failure_signatures")
        quarantine_signatures = _tap_quarantine_signatures(
            quarantine.get("signatures") if isinstance(quarantine, dict) else None)
        if (rate < TAP_MIN_FLIP_RATE or not isinstance(historical_signatures, list)
                or not all(isinstance(value, str) and value for value in historical_signatures)
                or quarantine_signatures is None or signature not in quarantine_signatures):
            continue
        if not isinstance(quarantine, dict):
            continue
        until, issue = _tap_time(quarantine.get("until")), quarantine.get("issue", "")
        if until is None or not now < until <= now + timedelta(days=7) or not isinstance(issue, str) or not re.fullmatch(
                r"https://github\.com/manaflow-ai/cmux/issues/[1-9]\d*", issue):
            continue
        known[name] = f"base flake {flips}/{count - 1} flips, quarantine {issue} until {quarantine['until']}"
    return known


def classify(head_log: str | None, base_log: str | None, job: str = "", base: str = "the base",
             *, flake_state: dict | None = None, workflow: str = "") -> Verdict | None:
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
    flaky = flaky_failures(head_log, job, workflow, flake_state) if not (head.crashes or head.truncated) else {}
    new = sorted(head.failed - seen - flaky.keys())
    # A failure whose log prints its error (bun's) fails the same way only with the same error on both sides: an
    # assertion on the base does not excuse a TypeError on the head. Names with no error printed compare by name.
    differ = [name for name in sorted(head.failed & seen)
              if (head.messages.get(name) or base_result.messages.get(name))
              and not same_error(head.messages.get(name), base_result.messages.get(name)) and name not in flaky]
    if base_log is None and head.failed - flaky.keys():
        reasons.append(f"no {base} log to compare {len(head.failed)} failing test(s) with")
    elif new:
        named = [f"{name} ({head.messages[name]})" if head.messages.get(name) else name for name in new]
        reasons.append(f"{len(new)} failing test(s) pass or do not run on {base}: {'; '.join(named)[:600]}")
    if differ:
        said = [f"{name} ({head.messages.get(name) or 'no error read'} here; "
                f"{base_result.messages.get(name) or 'no error read'} on {base})" for name in differ]
        reasons.append(f"{len(differ)} test(s) fail differently on {base}: {'; '.join(said)[:600]}")
    # A display name says nothing about its suite, so the same one in two suites is two tests: compare the files
    # their issues name, and call it the head's own when neither side's files are the other's. The same test
    # failing at another line, or at a second expectation, still overlaps; with no file on a side, the name alone
    # decides, as before (cmux#35902).
    elsewhere = [name for name in sorted(head.failed & seen)
                 if head.sites.get(name) and base_result.sites.get(name)
                 and not (head.sites[name] & base_result.sites[name])
                 and name not in flaky and name not in differ]
    if elsewhere:
        said = [f"{name} (here in {', '.join(sorted(head.sites[name]))}; "
                f"on {base} in {', '.join(sorted(base_result.sites[name]))})" for name in elsewhere]
        reasons.append(f"{len(elsewhere)} display-named test(s) fail in different files on {base}, so the name is "
                       f"two tests, not one red: {'; '.join(said)[:600]}")
    shared = sorted(head.failed & seen - set(differ) - set(elsewhere) - flaky.keys())
    shared += [f"{name} ({why})" for name, why in sorted(flaky.items())]
    return Verdict(bool(reasons), reasons, shared)


def tap_flaky_names(log_dir: Path, state: dict, *, workflow: str, job: str) -> list[str]:
    """Names safe for guards_new_reds.py --flaky, from retained final head attempts and exact base signatures."""
    if os.environ.get("TAP_CI_ENABLED", "1") == "0" or not state:
        return []
    spec = importlib.util.spec_from_file_location("tap_web_results", Path(__file__).with_name("webviews_test_results.py"))
    exporter = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(exporter)
    try:
        records = exporter.tap_observations(log_dir / "summary", log_dir=log_dir)
        log = "\n".join(["::group::" + TAP_GROUP,
                         *(TAP_MARKER + json.dumps(row, ensure_ascii=True) for row in records), "::endgroup::"])
    except OSError:
        return []
    return sorted(flaky_failures(log, job, workflow, state))



def classify_any(head_log: str | None, bases: list, job: str = "", *, flake_state: dict | None = None,
                 workflow: str = "") -> Verdict | None:
    """classify against several base logs (BASES: [(label, log)], newest first): a head failing test is the base's
    when it fails the same way on any one of them (base_red_excuse.py's window). A crash or a cut-short head run is
    the head's whatever the bases show, judged as classify judges it against the newest. shared names, for each test,
    the first base it failed on: `name (label)`."""
    verdicts = [(label, classify(head_log, log, job, label)) for label, log in bases] or [("", classify(head_log, None, job))]
    first = verdicts[0][1]
    head = read(head_log)
    if first is None or len(verdicts) == 1 or head_log is None or head.crashes or head.truncated:
        if first is not None and flake_state:
            label, text = bases[0] if bases else ("the base", None)
            return classify(head_log, text, job, label, flake_state=flake_state, workflow=workflow)
        return first
    on: dict = {}
    for label, verdict in verdicts:
        for name in verdict.shared:
            on.setdefault(name, label)
    for name, why in flaky_failures(head_log, job, workflow, flake_state).items():
        on.setdefault(name, why)
    new = sorted(head.failed - on.keys())
    labels = ", ".join(label for label, _ in verdicts)
    reasons = [f"{len(new)} failing test(s) pass, do not run or fail differently on each of {labels}: "
               f"{'; '.join(new)[:600]}"] if new else []
    return Verdict(bool(new), reasons, [f"{name} ({on[name]})" for name in sorted(on)])

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
# A base replay's log is two runs (2026-11-08, ci-web.yml react-apps-base-check): first the merge parent's run of the
# head's red files, then, after this line, the files it charged re-run alone on the head, and guards_new_reds.py's
# verdict again with that re-run (a test that passed alone there is a warning now, no longer charged). Only the part
# after the line is the head's: a file that timed out on the merge parent (cmux#34111's replay (2), whose base run
# timed out transcript-toggle-round-trip-browser) is the base's, never a cut-short head run; and only its verdict is
# final. A replay with no such line (no head re-run) holds no run of the head at all.
WEB_HEAD_RERUN = "re-running alone on the head:"
# guards_new_reds.py's closing line of a compare: its charged-test verdict is whole only once this is printed. A
# replay whose last compare (after its head re-run, or its only one) printed none ended before it judged anything:
# its charged tests, or the head re-run's failures, are no verdict to compare with the base (review follow-up (1)
# on #38380), so the replay is the head's own.
# The whole line, anchored at both ends: a log cut off after "red on the base too" printed no verdict (review F1 on
# #38434). A runner copied from before guards_new_reds.py counted flakes prints no flaky count.
WEB_VERDICT = re.compile(r"^\d+ webview test steps red on this change, \d+ red on the base too, "
                         r"(?:\d+ flaky on the base, )?\d+ fixed$")
NO_WEB_VERDICT = "its replay printed no final charged-test verdict (guards_new_reds.py's closing line)"


def web_head_part(log: str | None) -> str:
    """The part of a webview test job's log that ran the head: all of a head shard's; of a base replay's (it prints
    guards_new_reds.py's WEB_CHARGED verdicts), only what follows its last WEB_HEAD_RERUN line, and nothing when it
    re-ran nothing on the head."""
    if not log:
        return ""
    raw = log.splitlines()
    texts = log_lines(log)
    if not any(WEB_CHARGED.match(text) for text in texts):
        return log
    rerun = max((n for n, text in enumerate(texts) if text == WEB_HEAD_RERUN), default=None)
    return "" if rerun is None else "\n".join(raw[rerun + 1:])


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
    if any(WEB_CHARGED.match(text) for text in texts):
        # A base replay: only its head re-run, and the verdict after it, are the head's (web_head_part).
        rerun = max((n for n, text in enumerate(texts) if text == WEB_HEAD_RERUN), default=None)
        if not any(WEB_VERDICT.match(text) for text in texts[(rerun or -1) + 1:]):
            found.truncated.append(NO_WEB_VERDICT)
        if rerun is None:
            for text in texts:
                if match := WEB_CHARGED.match(text):
                    (found.charged if match.group(1) == "error" else found.shared).add(
                        match.group(2) + (f" > {match.group(3)}" if match.group(3) else ""))
            return found
        texts = lines_of(web_head_part(log))
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


def web_head(head_logs: list, job: str = "", base: str = "the base"):
    """The head side of a red webview test job, for classify_web and classify_web_window: (names, head failures,
    reasons that make it the head's own whatever the base shows), a Verdict when no base can matter (an unreadable
    head log), or None when the red job's log names no failing webview test."""
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
        # A named test the final verdict cleared (a warning: red on the merge parent too, flaky there, or passed alone
        # on the head) is not the change's, though its file is charged for another test (review F2 on #38380).
        names = sorted(set(names) | {name for name in head.failed if name.split(" > ", 1)[0] in files
                                     and not (" > " in name and name in red.shared)})
    reasons = sorted(red.crashed | head.crashed)
    reasons += [f"{name} timed out (a cut-short run is never a base red)"
                for name in sorted(red.timed_out | head.timed_out)]
    reasons += sorted(set(red.truncated + head.truncated))
    return names, head, reasons


def web_compare(names: list, head: WebFailures, base_logs: list, base: str) -> tuple[list, list, list]:
    """(new, differ, shared): which of NAMES the base logs do not fail, fail with another error, or fail the same
    way as the head."""
    seen = merged_web(base_logs)
    new, differ, shared = [], [], []
    for name in names:
        if name not in seen.failed:
            new.append(name)
            continue
        mine, theirs = head.failed.get(name, ""), seen.failed[name]
        if not same_error(mine, theirs):
            differ.append(f"{name} ({mine or 'no error read'} here; {theirs or 'no error read'} on {base})")
            continue
        shared.append(name)
    return new, differ, shared


def classify_web(head_logs: list, base_logs: list, job: str = "", base: str = "the base") -> Verdict | None:
    """A red webview test job (a head shard, or the base replay that charged tests to the change) judged per test
    against every base job that ran those tests: own unless each test the head is red on fails on the base too with
    the same error. head_logs: the red job's log first, then the logs of the head's other jobs that ran the same
    files (where each failure's error is printed); base_logs: the base's red webview test jobs. None when the red job's
    log names no failing webview test (not a webview test red: the caller judges it as before). A file that timed out
    or crashed, an unreadable log, or a test whose error is printed on only one side is the head's own."""
    got = web_head(head_logs, job, base)
    if got is None or isinstance(got, Verdict):
        return got
    names, head, reasons = got
    if any(log is None for log in base_logs) or not base_logs:
        reasons.append(f"no readable {base} webview test log to compare {len(names)} failing test(s) with")
        return Verdict(True, reasons)
    new, differ, shared = web_compare(names, head, base_logs, base)
    if new:
        reasons.append(f"{len(new)} failing test(s) pass or do not run on {base}: {'; '.join(new)[:600]}")
    if differ:
        reasons.append(f"{len(differ)} test(s) fail differently on {base}: {'; '.join(differ)[:600]}")
    return Verdict(bool(reasons), reasons, shared)


def classify_web_window(head_logs: list, windows, job: str = "", base: str = "the base") -> Verdict | None:
    """classify_web against a window of base verdicts: WINDOWS yields (label, that base run's red webview test job
    logs), newest first, and is read only while a head test is still unmatched. A failing test is the base's when one
    base run of the window fails it with the same error; each run is compared alone, since two runs' different errors
    for one test joined (merged_web) match neither. Crashes, timeouts and cut-short head runs are the head's own before
    any base log is read. Shared names carry the label of the run that matched them."""
    got = web_head(head_logs, job, base)
    if got is None or isinstance(got, Verdict):
        return got
    names, head, reasons = got
    if reasons:
        return Verdict(True, reasons)
    left, shared, labels, newest = list(names), [], [], None
    for label, base_logs in windows:
        labels.append(label)
        if not base_logs or any(log is None for log in base_logs):
            return Verdict(True, [f"no readable {base} webview test log in {label} to compare "
                                  f"{len(left)} failing test(s) with"])
        new, differ, matched = web_compare(left, head, base_logs, label)
        if newest is None:  # the newest run's word on each test, named when none of the window matches it
            newest = dict(zip(new, new)) | dict(zip([name for name in left if name not in new and name not in matched],
                                                    differ))
        shared += [f"{name} ({label})" for name in matched]
        left = [name for name in left if name not in matched]
        if not left:
            return Verdict(False, [], shared)
    if not labels:
        return Verdict(True, [f"no {base} webview test verdict to compare {len(names)} failing test(s) with"])
    new = [name for name in left if newest.get(name) == name]
    differ = [newest[name] for name in left if newest.get(name) != name]
    if new:
        reasons.append(f"{len(new)} failing test(s) pass or do not run on {', '.join(labels)}: {'; '.join(new)[:600]}")
    if differ:
        reasons.append(f"{len(differ)} test(s) fail on none of {', '.join(labels)} the same way; on {labels[0]}: "
                       f"{'; '.join(differ)[:600]}")
    return Verdict(True, reasons, shared)


# A head shard GitHub cancelled or timed out mid-run (cmux#39676, 2026-11-09: `web / react-apps-check (1)` ran 31 min,
# its retries spent the time budget, and jobs 129249378930 and 129359593602 were cancelled) never printed its closing
# summary or a red file's `##[group]FAIL` log: run-webviews-tests.sh keeps each red file's raw log for that summary. Its
# live `START` / `PASS` / `FAIL` / `TIMEOUT` lines still name every file it judged. So a cancelled shard is judged per
# file (claude-sr2-coord, 2026-11-09: "a timed-out/cancelled shard whose failing files also fail the same way on base is
# classified as base red, not 'no verdict'"): the files whose last result is FAIL, and any file it started and never
# finished (the one running at the cancel), each red on a base webview run of the window. It is never excused when it
# names no such file (a shard cancelled while green has no failure to share), when a file timed out on its own or the
# run crashed (both the head's whatever the base shows), or when any one file is not red on the base. A file that
# failed and then passed its retry is a pass, as the runner counts it. The files the cancel kept from running are not
# judged at all: they are named in the audit line, and the merged head's own push runs them.
def web_cut_short(log: str | None) -> tuple[list[str], list[str], list[str]] | None:
    """(red files: each file whose last live result is FAIL, then each started and never finished; files that timed
    out alone; crashes) from a head shard's cut-short log, or None when the log is unreadable."""
    if log is None:
        return None
    last: dict[str, str] = {}
    pending: dict[str, int] = {}
    for text in lines_of(log):
        if WEB_SUMMARY.match(text):
            continue
        if match := BUN_STARTED.match(text):
            pending[match.group(1)] = pending.get(match.group(1), 0) + 1
        elif match := BUN_RESULT.match(text):
            name = match.group(2)
            last[name] = match.group(1)
            if pending.get(name, 0):
                pending[name] -= 1
    found = web_failures(log)
    red = sorted(name for name, result in last.items() if result == "FAIL")
    red += sorted(name for name, count in pending.items() if count and name not in red)
    timed_out = sorted({name for name, result in last.items() if result == "TIMEOUT"} | found.timed_out)
    return red, timed_out, sorted(found.crashed)


def web_base_red_files(base_logs: list) -> set[str]:
    """The webview test files the base logs name as red: failed (any of their tests, or the file) or timed out."""
    seen = merged_web(base_logs)
    return {name.split(" > ", 1)[0] for name in seen.failed} | set(seen.timed_out)


def classify_web_cut_short(head_log: str | None, windows, job: str = "", base: str = "the base") -> Verdict | None:
    """A cancelled or timed-out head shard judged per file (the rule above) against WINDOWS, which yields (label, that
    base run's red webview test job logs) newest first, read only while a head file is unmatched: shared when every
    red file is red on some run of the window. None when the log names no red file (no failure to compare: the caller
    refuses it as no verdict). A crash, a file that timed out alone, or an unreadable log is the head's own."""
    got = web_cut_short(head_log)
    if got is None:
        return Verdict(True, [f"{job or 'the job'}: its log could not be read, so no file can be compared with {base}"])
    red, timed_out, crashed = got
    reasons = crashed + [f"{name} timed out (a cut-short file is never a base red)" for name in timed_out]
    if reasons:
        return Verdict(True, reasons)
    if not red:
        return None
    left, shared, labels = list(red), [], []
    for label, base_logs in windows:
        labels.append(label)
        if not base_logs or any(log is None for log in base_logs):
            return Verdict(True, [f"no readable {base} webview test log in {label} to compare {len(left)} red "
                                  "file(s) with"])
        on_base = web_base_red_files(base_logs)
        shared += [f"{name} ({label})" for name in left if name in on_base]
        left = [name for name in left if name not in on_base]
        if not left:
            return Verdict(False, [], shared)
    if not labels:
        return Verdict(True, [f"no {base} webview test verdict to compare {len(red)} red file(s) with"])
    return Verdict(True, [f"{len(left)} red file(s) pass or do not run on {', '.join(labels)}: "
                          f"{'; '.join(left)[:600]}"], shared)


# A coalesced feat-cmux-next web run (cmux-next-web.yml runs its web checks at most once every 30 minutes, on the
# newest push, routed from the last run's commit) covers several commits. When its webview tests go red, its
# `web bisect` job (scripts/ci/web_coalesce.py bisect) re-runs only the new red files, only on those commits, and
# prints one line a file. bisect_report reads them, so a reader of push verdicts (HQ's base-red-watch) still names the
# first red commit and its pull request rather than the run's whole range:
#   web bisect: first red at SHA (#N|a direct push) after GREEN_SHA: FILE[ (TESTS)]
#   web bisect: red before the range at BASE_SHA: FILE       (red at the run before: not this range's)
#   web bisect: flaky on the base: FILE                      (flips by itself on the base, or no input changed)
#   web bisect: unresolved between LO_SHA and HI_SHA: FILE   (first red somewhere in (LO, HI])
BISECT_LINE = re.compile(
    r"web bisect: (?:first red at (?P<first>[0-9a-f]{40}) \((?:#(?P<pr>\d+)|a direct push)\) after (?P<green>[0-9a-f]{40})"
    r"|red before the range at (?P<base>[0-9a-f]{40})|(?P<flaky>flaky on the base)"
    r"|unresolved between (?P<lo>[0-9a-f]{40}) and (?P<hi>[0-9a-f]{40})): (?P<file>\S+?)(?: \(.*\))?$")


def bisect_report(log: str | None) -> dict[str, dict]:
    """{webview test file: {"kind": first|base|flaky|unresolved, "first_red", "green", "pr"}} from a `web bisect` job's
    log (its echoed script is never read). first: FIRST_RED is the file's first red commit, GREEN the commit before
    it, PR its pull request number or None for a direct push. unresolved: the first red is after GREEN, at or before
    FIRST_RED. base and flaky name no commit of the range."""
    found: dict[str, dict] = {}
    for text in lines_of(log or ""):
        match = BISECT_LINE.search(text)
        if not match:
            continue
        if match["first"]:
            got = {"kind": "first", "first_red": match["first"], "green": match["green"],
                   "pr": int(match["pr"]) if match["pr"] else None}
        elif match["base"]:
            got = {"kind": "base", "first_red": None, "green": None, "pr": None}
        elif match["flaky"]:
            got = {"kind": "flaky", "first_red": None, "green": None, "pr": None}
        else:
            got = {"kind": "unresolved", "first_red": match["hi"], "green": match["lo"], "pr": None}
        found.setdefault(match["file"], got)
    return found


# Gallery health's health.json: a shard's broken states and its states over their ready-time budget.
GALLERY_KEYS = ("fresh", "known", "slow")
# A render the browser lost: a crash, never a state the base can share.
GALLERY_CRASH = re.compile(r"\bcrash|Target (?:page, context or browser )?(?:has been )?closed|"
                           r"browser has (?:been )?(?:disconnected|closed)|\bsignal\b|\bSIG[A-Z]+\b", re.I)
GALLERY_SLOW = "over its ready-time budget"
# A state past its layout-shift baseline (shift-baseline.ts); older checkers wrote no `shifted` list.
GALLERY_SHIFT = "past its layout-shift baseline"


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
    for item in found.get("shifted") or []:
        result.failed.add(f"{item.get('state', '')}: {GALLERY_SHIFT}")
    for item in found.get("geometry") or []:
        for violation in item.get("violations") or []:
            result.failed.add(f"{item.get('state', '')}: breaks {violation.get('key', '')}")
    return result


def gallery_states(text: str | None) -> list[str]:
    """The head's red states (`entry#variant`): the only states the base replays, every case of each."""
    return sorted({name.split(": ", 1)[0] for name in gallery_read(text).failed})


def gallery_entries(text: str | None) -> list[str]:
    """The gallery entries (`entry` of `entry#variant`) of the head's red states: what the base's manifest names."""
    return sorted({state.rsplit("#", 1)[0] for state in gallery_states(text)})


def gallery_classify(head_text: str | None, base_text, base: str = "the base") -> Verdict | None:
    """A gallery health shard's red judged per state against the same states rendered on the base; None when the
    head's shard is whole and has nothing red. `base_text` may be several base renders: a state red the same way
    in any of them is the base's. The head keeps a state red only when every retry shows it, so a base render that
    had to show it every time too would call a state that flakes on the base the head's own."""
    head = gallery_read(head_text)
    if not head.failed and not head.crashes and not head.truncated:
        return None
    reasons = list(head.crashes)
    if head.truncated:
        reasons.append(f"gallery health: per-state results are not whole ({head.truncated[0]})")
    renders = base_text if isinstance(base_text, (list, tuple)) else [base_text]
    seen = Result()
    for text in renders or [None]:
        found = gallery_read(text, keep_known=True)
        seen.truncated.extend(found.truncated)
        seen.failed |= found.failed
    if seen.truncated:
        reasons.append(f"no whole base result on {base} to compare {len(head.failed)} red state(s) with "
                       f"({seen.truncated[0]})")
    elif new := sorted(head.failed - seen.failed):
        reasons.append(f"{len(new)} red state(s) render or are red another way on {base}: {'; '.join(new)[:600]}")
    return Verdict(bool(reasons), reasons, sorted(head.failed & seen.failed) if not seen.truncated else [])


def gallery_main(args) -> int:
    read_text = lambda path: path.read_text(errors="replace") if path and path.is_file() else None
    head = read_text(args.head)
    if args.entries or args.states:
        found = gallery_read(head)
        if found.crashes or found.truncated:
            print("own red: " + "; ".join(found.crashes + found.truncated[:1]), file=sys.stderr)
            return 1
        print(",".join(gallery_states(head) if args.states else gallery_entries(head)))
        return 0 if found.failed else 2
    verdict = gallery_classify(head, [read_text(path) for path in args.base or []] or None, args.base_name)
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
    one.add_argument("--workflow", default="", help="workflow name, for the measured base-flake supplement")
    one.add_argument("--flake-state", help="tap-tests/v1 JSON; default: public reconciler snapshot, or TAP_TESTS_STATE")
    one.add_argument("--json", action="store_true")
    tap = sub.add_parser("tap-flaky", help="signature-matched quarantines from a retained webview head-log artifact")
    tap.add_argument("--log-dir", required=True, type=Path)
    tap.add_argument("--workflow", required=True)
    tap.add_argument("--job", required=True)
    tap.add_argument("--flake-state", help="tap-tests/v1 JSON; default: public reconciler snapshot or TAP_TESTS_STATE")
    gallery = sub.add_parser("gallery", help="a gallery health shard's health.json against the base's")
    gallery.add_argument("--head", required=True, type=Path)
    gallery.add_argument("--base", type=Path, action="append", help="a base render's health.json; repeat for several")
    gallery.add_argument("--base-name", default="the base")
    gallery.add_argument("--entries", action="store_true", help="print the entries to replay on the base")
    gallery.add_argument("--states", action="store_true", help="print the red states (entry#variant) to replay on the base")
    gallery.add_argument("--annotate", action="store_true", help="GitHub annotations: base reds warn, own reds fail")
    gallery.add_argument("--json", action="store_true")
    runner = sub.add_parser("runner", help="whether a failed job's red is a lost runner (infra, no verdict)")
    runner.add_argument("--job", required=True, type=Path, help="the job as the Actions jobs API gives it")
    runner.add_argument("--annotations", type=Path, help="its check run's annotations (JSON list)")
    runner.add_argument("--log", type=Path, help="its log, or what its read answered")
    args = parser.parse_args(argv)
    if args.command == "tap-flaky":
        for name in tap_flaky_names(args.log_dir, load_flake_state(args.flake_state, fetch=True),
                                   workflow=args.workflow, job=args.job):
            print(name)
        return 0
    if args.command == "gallery":
        return gallery_main(args)
    if args.command == "runner":
        job = json.loads(args.job.read_text())
        notes = json.loads(args.annotations.read_text()) if args.annotations else ()
        why = lost_runner(job, notes, args.log.read_text(errors="replace") if args.log else None)
        name = job.get("name") or job.get("id")
        if why:
            print(f"infra, not a verdict: '{name}' (job {job.get('id')}) {why}; never the PR's own red; re-run it")
            return 0
        print(f"a verdict: '{name}' (job {job.get('id')}) is {job.get('conclusion')}, not a lost runner")
        return 1
    head = args.head.read_text(errors="replace")
    base = args.base.read_text(errors="replace") if args.base else None
    verdict = classify(head, base, args.job, args.base_name, workflow=args.workflow,
                       flake_state=load_flake_state(args.flake_state, fetch=bool(args.workflow)))
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
