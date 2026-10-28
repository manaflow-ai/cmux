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

SIGNAL = re.compile(r"exited with unexpected signal code (\d+)|died on signal (\d+)|exited with signal (?:code )?(\d+)|"
                    r"\(signal: (\d+)|terminated by signal (\d+)|signal (\d+) \(SIG[A-Z]+\)")
SIGNAL_NAMES = {"SIGABRT": "6", "SIGSEGV": "11", "SIGBUS": "10", "SIGILL": "4", "SIGTRAP": "5", "SIGKILL": "9",
                "SIGFPE": "8"}
CRASH = re.compile(r"exited with unexpected signal|died on signal|exited with signal|\(signal: \d+|terminated by signal|"
                   r"\bEXC_[A-Z_]+|^(?:\S+:\d+: )?Fatal error: |Terminating app due to uncaught exception|"
                   r"terminating due to uncaught exception|Test Case '[^']*' crashed|Thread \d+ Crashed|Restarting after unexpected exit|"
                   r"Fatal Python error|panicked at .* SIGSEGV|\bAborted \(core dumped\)|\bSegmentation fault\b|"
                   r"\bIllegal instruction\b|\bBus error\b|Trace/breakpoint trap")
# Text that names a crash without one having happened.
NOT_CRASH = re.compile(r"^\s*\d+ \| |^\s*\[\d+/\d+\] Compiling|\bwarning:|^[◇✔↪] Test ")
XCTEST_RESTART = re.compile(r"(?:Restarting after unexpected exit, crash, or test timeout in|"
                            r"Test Case '-\[)(\S+)[ .](\w+)\]?'? crashed|"
                            r"Restarting after unexpected exit, crash, or test timeout in (\S+?)\.(\w+)\(\)")
TRUNCATED = re.compile(r"no \"Test run with\" summary line|swift test ended early|reported fewer tests than it ran|"
                       r"swift test stuck|has exceeded the maximum execution time|The operation was canceled|"
                       r"This log was truncated|log (?:is|was) truncated|\bnever finished\b")
# Swift Testing's start line, for naming the test a crash stack runs.
STARTED = re.compile(r"◇ Test (?:case passing .+? to )?(\w+)\((.*?)\) started\.")
# A test's end (Swift Testing; a case of a parameterized test ends with its test), and XCTest's start and end.
FINISHED = re.compile(r"[✔✘] Test (\w+)\(.*?\)(?: with \d+ test cases?)? (?:passed|failed)\b")
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
    for name, number in SIGNAL_NAMES.items():
        if name in text:
            return number
    return None


def read(log: str | None) -> Result:
    """The tests a job log ran, failed and crashed, and whether its per-test results are whole."""
    result = Result()
    if log is None:
        result.truncated.append("its log could not be read")
        return result
    lines = lines_of(log)
    started = {m.group(1) for text in lines for m in [STARTED.search(text)] if m}
    stack: list[str] = []
    signals: list[str] = []
    named: list[str] = []
    crashed = False
    for text in lines:
        if RAN.search(text):
            result.ran = True
        for pattern in FAILED:
            if match := pattern.search(text):
                result.failed.add(match.group(1))
        if match := XCTEST_RESTART.search(text):
            groups = [g for g in match.groups() if g]
            named.append(".".join(groups[:2]))
            crashed = True
        if CRASH.search(text) and not NOT_CRASH.search(text):
            crashed = True
            if number := signal_of(text):
                signals.append(number)
        if crashed and ("$s" in text or re.match(r"^\s*\d+\s+\S+\s+0x[0-9a-f]+ ", text)):
            stack.append(text)
        if TRUNCATED.search(text) and not NOT_CRASH.search(text):
            why = re.sub(r"^##\[error\]|^::error[^:]*::", "", text).strip()
            result.truncated.append(why[:200])
    unfinished = started - {m.group(1) for text in lines for m in [FINISHED.search(text)] if m}
    unfinished |= ({m.group(1) for text in lines for m in [XC_STARTED.search(text)] if m}
                   - {m.group(1) for text in lines for m in [XC_FINISHED.search(text)] if m})
    if unfinished:
        result.truncated.append(f"{len(unfinished)} test(s) started and never finished: "
                                + "; ".join(sorted(unfinished)[:5]))
    running = sum(1 for text in lines if CARGO_RUNNING.match(text))
    if running > sum(1 for text in lines if text.startswith("test result: ")):
        result.truncated.append("a cargo test binary printed no `test result:` line")
    if crashed:
        result.ran = True
        who = named or crashed_tests(stack, started) or ["the test process"]
        signal = f"signal {signals[0]}" if signals else "no signal named"
        result.crashes = [f"{name} crashed ({signal})" for name in dict.fromkeys(who)]
    return result


def classify(head_log: str | None, base_log: str | None, job: str = "", base: str = "the base") -> Verdict | None:
    """The head job's red judged per test against the base job's log; None when the head's log names no failing
    test, crash or cut-short run (a lint or compile red: the caller judges it as before)."""
    head = read(head_log)
    if head_log is None:
        return Verdict(True, [f"{job or 'the job'}: its log could not be read, so no test can be compared with {base}"])
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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    one = sub.add_parser("classify")
    one.add_argument("--head", required=True, type=Path)
    one.add_argument("--base", type=Path)
    one.add_argument("--job", default="")
    one.add_argument("--base-name", default="the base")
    one.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
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
