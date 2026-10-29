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
RUN_STARTED = re.compile(r"^◇ Test run started\.")
RUN_ENDED = re.compile(r"^[✔✘━] Test run with \d+ tests?")
RUN_COUNT = re.compile(r"^[✔✘━] Test run with (\d{1,9}) tests?")
# A unittest run (verbose `name (module.Class...) ... ok` lines, or a FAIL/ERROR block) ends with `Ran N tests`.
UNITTEST_LINE = re.compile(r"^(?:FAIL|ERROR): \w+ \([\w.]+\)|^\w+ \([\w.]+\)(?: \.\.\.|$)")
XC_SUITE_STARTED = re.compile(r"^\s*Test Suite '.+' started at ")
XC_SUITE_ENDED = re.compile(r"^\s*Test Suite '.+' (?:passed|failed) at ")
SUITE_STARTED = re.compile(r"^◇ Suite (.+?) started\.")
SUITE_ENDED = re.compile(r"^[✔✘] Suite (.+?) (?:passed|failed)\b")
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
    """What one job log says about its tests: ran, failed (names), crashes ("<who> crashed (signal N)") and
    truncated (why the per-test results are incomplete)."""

    def __init__(self):
        self.ran = False
        self.failed: set = set()
        self.crashes: list = []
        self.truncated: list = []


class Verdict:
    """own: the head's own red. reasons: why (first the crashes, then truncation, then the new failures).
    shared: failing tests the base fails too."""

    def __init__(self, own: bool, reasons: list, shared: list = ()):
        self.own, self.reasons, self.shared = own, reasons, list(shared)


def lines_of(log: str) -> list[str]:
    return [STAMP.sub("", ANSI.sub("", line)).rstrip() for line in log.splitlines()]


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


def read(log: str | None) -> Result:
    """The tests a job log ran, failed and crashed, and whether its per-test results are whole."""
    result = Result()
    if log is None or not log.strip():
        result.truncated.append("its log could not be read" if log is None else "its log is empty")
        return result
    lines = lines_of(log)
    started = {m.group(1) for text in lines for m in [STARTED.search(text)] if m}
    stack: list[str] = []
    signals: list[str] = []
    named: list[str] = []
    crashed = False
    for text in lines:
        if RAN.search(text) or UNITTEST_LINE.match(text) or BUN_STARTED.match(text) or BUN_RESULT.match(text):
            result.ran = True
        if (match := BUN_RESULT.match(text)) and match.group(1) == "TIMEOUT":
            result.truncated.append(f"{match.group(2)} timed out (killed at the wrapper's hard limit)")
        if BUN_PANIC.match(text):
            crashed = True
        for pattern in FAILED:
            if match := pattern.search(text):
                result.failed.add(match.group(1))
                result.ran = True
        if match := XCTEST_RESTART.search(text):
            groups = [g for g in match.groups() if g]
            named.append(".".join(groups[:2]))
            crashed = True
        runtime = HELPER_KILLED.search(text) or SHELL_SIGNAL.search(text) or (
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
    seen = read(base_log).failed if base_log is not None else set()
    new = sorted(head.failed - seen)
    if base_log is None and head.failed:
        reasons.append(f"no {base} log to compare {len(head.failed)} failing test(s) with")
    elif new:
        reasons.append(f"{len(new)} failing test(s) pass or do not run on {base}: {'; '.join(new)[:600]}")
    return Verdict(bool(reasons), reasons, sorted(head.failed & seen))


# The webview tests (scripts/cmux-next/run-webviews-tests.sh, bun), judged per test across jobs. One test file runs in
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


def web_failures(log: str | None) -> WebFailures:
    """The webview tests a job log names as failed, with each one's error. A red file's log is read in full (both
    runs, the retry's too: any run a test fails in is evidence it fails there)."""
    found = WebFailures()
    if not log:
        return found
    current = None  # the red file whose log this is
    error = where = ""
    for text in lines_of(log):
        if match := WEB_GROUP.match(text):
            current, error, where = match.group(2), "", ""
            if match.group(1) == "TIMEOUT":
                found.timed_out.add(current)
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
        if text.startswith("### webviews tests:"):
            current = None
            continue
        if BUN_PANIC.match(text):
            found.crashed.add(current)
        if text == WEB_RETRY:
            error = where = ""
        elif match := WEB_ERROR.match(text):
            error, where = match.group(1).strip(), ""
        elif (match := WEB_AT.search(text)) and match.group(1) == current and not where:
            where = f"{match.group(1)}:{match.group(2)}"
        elif match := WEB_FAIL.match(text):
            key = f"{current} > {match.group(1)}"
            said = f"{error} at {where}" if error and where else error
            if said or key not in found.failed:
                found.failed[key] = said
            error = where = ""
        elif text.startswith("(pass) "):
            error = where = ""
    return found


def merged_web(logs: list) -> WebFailures:
    out = WebFailures()
    for log in logs:
        got = web_failures(log)
        for key, said in got.failed.items():
            if said or key not in out.failed:
                out.failed[key] = said
        out.timed_out |= got.timed_out
        out.crashed |= got.crashed
        out.charged |= got.charged
        out.shared |= got.shared
    return out


def classify_web(head_logs: list, base_logs: list, job: str = "", base: str = "the base") -> Verdict | None:
    """A red webview test job (a head shard, or the base replay that charged tests to the change) judged per test
    against every base job that ran those tests: own unless each test the head is red on fails on the base too with
    the same error. head_logs: the red job's log first, then the logs of the head's other jobs that ran the same
    files (where each failure's error is printed); base_logs: the base's red webview test jobs. None when the red job's
    log names no failing webview test (not a webview test red: the caller judges it as before). A file that timed out
    or crashed, an unreadable log, or a test whose error is printed on only one side is the head's own."""
    if not head_logs or head_logs[0] is None:
        return Verdict(True, [f"{job or 'the job'}: its log could not be read, so no test can be compared with {base}"])
    red = web_failures(head_logs[0])
    names = sorted(red.charged) if red.charged else sorted(red.failed)
    if not names and not red.timed_out and not red.crashed:
        return None
    # A replay's own log holds the merge parent's runs of those files, never the head's: the head's errors come from
    # the head's other jobs then.
    head = merged_web([log for log in (head_logs[1:] if red.charged else head_logs) if log is not None])
    reasons = [f"{name} crashed" for name in sorted(red.crashed)]
    reasons += [f"{name} timed out (a cut-short run is never a base red)" for name in sorted(red.timed_out)]
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
        if " > " in name and (not mine or not theirs or mine != theirs):
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
