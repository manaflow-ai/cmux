#!/usr/bin/env python3
"""Run a test command and fail loudly, naming the hung test, when it stalls.

A test that never finishes used to run until the job's `timeout-minutes`
ceiling, which GitHub reports as "cancelled" with only "The operation was
canceled." in the log. Nothing named the test that hung.

This wrapper runs the command on a pseudo-terminal, so the test process's
stdout is line-buffered and each test's `started` line reaches the log when the
test starts. It streams the output unchanged and follows the Swift Testing and
XCTest progress lines. When the output goes quiet for `--silence-seconds`, or
the command outlives `--timeout-seconds`, it prints the tests that started but
did not finish, samples the test processes' stacks where `sample` exists
(macOS), kills the process group, and exits 124 with an `::error::` annotation
that names the tests and says "timed out". If the runner cancels the step
first, the same in-flight report is printed before exiting.
"""

from __future__ import annotations

import argparse
import dataclasses
import errno
import os
import pty
import re
import select
import shlex
import shutil
import signal
import subprocess
import sys
import tempfile
import termios
import time
from pathlib import Path
from typing import Callable, Optional

# Tests load this file through importlib, which does not put its directory on
# sys.path the way running it as a script does.
sys.path.insert(0, str(Path(__file__).resolve().parent))

from ci_process_tree import process_tree, terminate  # noqa: E402

TIMEOUT_EXIT = 124
ANSI = re.compile(r"\x1b\[[0-?]*[ -/]*[@-~]")

# Swift Testing's console output: a status glyph, `Test` or `Suite`, the name,
# and the event. Match any glyph so SF Symbols output parses the same way.
SWIFT_EVENT = re.compile(r"^\s*\S+\s+(?P<kind>Test|Suite) (?P<rest>.+)$")
SWIFT_STARTED = re.compile(r"^(?P<name>.+) started\.$")
# `with N test cases` belongs to the finish line of a parameterized test, not to
# its name: `✔ Test f(x:) with 3 test cases passed after 0.1 seconds.`
SWIFT_FINISHED = re.compile(
    r"^(?P<name>.+?)(?: with \d+ test cases?)? (?:passed|failed) after "
    r"[0-9.]+ seconds?(?: with .+)?\.$"
)
SWIFT_SKIPPED = re.compile(r"^(?P<name>.+?) skipped(?:: .*|\.)$")
SWIFT_ISSUE = re.compile(r"^.+? recorded an? (?:issue|known issue)\b")
# `◇ Test case passing 1 argument x → 1 to f(x:) started.`
SWIFT_CASE = re.compile(r"^case (?P<detail>passing \d+ arguments? .+)$")
SWIFT_RUN = re.compile(r"^run(?: |$)")

XCTEST_STARTED = re.compile(r"^\s*Test Case '(?P<name>[^']+)' started")
XCTEST_FINISHED = re.compile(r"^\s*Test Case '(?P<name>[^']+)' (?:passed|failed|skipped)\b")

# Process names worth a stack sample: the XCTest bundle runner and the Swift
# Testing helper SwiftPM launches. Everything else in the group is a driver.
TEST_PROCESS = re.compile(r"xctest|swiftpm-testing|PackageTests", re.IGNORECASE)
MAX_SAMPLED_PROCESSES = 4
MAX_SAMPLE_LINES = 4000
MAX_NAMED_TESTS = 5


@dataclasses.dataclass
class Started:
    name: str
    line: int
    at: float
    last_case: Optional[str] = None
    cases_started: int = 0


@dataclasses.dataclass
class InFlight:
    tests: list[Started]
    suites: list[Started]
    xctest_cases: list[Started]
    last_line: str


class TestProgress:
    """Swift Testing and XCTest tests that have started but not finished."""

    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self._tests: list[Started] = []
        self._suites: list[Started] = []
        self._xctest: list[Started] = []
        self._line = 0
        self._last_line = ""

    def feed(self, line: str) -> None:
        line = ANSI.sub("", line).rstrip("\r\n")
        self._line += 1
        if line.strip():
            self._last_line = line.strip()
        xctest = XCTEST_STARTED.match(line)
        if xctest:
            self._xctest.append(Started(xctest["name"], self._line, self._clock()))
            return
        xctest = XCTEST_FINISHED.match(line)
        if xctest:
            _finish(self._xctest, xctest["name"])
            return
        event = SWIFT_EVENT.match(line)
        if not event:
            return
        rest = event["rest"]
        if event["kind"] == "Suite":
            self._suite_event(rest)
        elif not SWIFT_RUN.match(rest) and not SWIFT_ISSUE.match(rest):
            self._test_event(rest)

    def _suite_event(self, rest: str) -> None:
        started = SWIFT_STARTED.match(rest)
        if started:
            self._suites.append(Started(started["name"], self._line, self._clock()))
            return
        finished = SWIFT_FINISHED.match(rest) or SWIFT_SKIPPED.match(rest)
        if finished:
            _finish(self._suites, finished["name"])

    def _test_event(self, rest: str) -> None:
        case = SWIFT_CASE.match(rest)
        if case:
            self._case_event(case["detail"])
            return
        started = SWIFT_STARTED.match(rest)
        if started:
            self._tests.append(Started(started["name"], self._line, self._clock()))
            return
        finished = SWIFT_FINISHED.match(rest) or SWIFT_SKIPPED.match(rest)
        if finished:
            _finish(self._tests, finished["name"])

    def _case_event(self, detail: str) -> None:
        # A case is never a test of its own: the parameterized test's finish
        # line closes it, so case finish lines need no bookkeeping.
        if not detail.endswith(" started."):
            return
        body = detail[: -len(" started.")]
        # The line names its test after " to ", but an argument value can
        # contain " to " too, so match against the tests already in flight.
        owners = [test for test in self._tests if body.endswith(" to " + test.name)]
        owner = max(owners, key=lambda test: (len(test.name), test.line), default=None)
        if owner:
            owner.last_case = body[: -len(" to " + owner.name)]
            owner.cases_started += 1

    def in_flight(self) -> InFlight:
        return InFlight(
            tests=list(self._tests),
            suites=list(self._suites),
            xctest_cases=list(self._xctest),
            last_line=self._last_line,
        )


def _finish(open_items: list[Started], name: str) -> None:
    # Unqualified names can repeat across suites; close the oldest one.
    for index, item in enumerate(open_items):
        if item.name == name:
            del open_items[index]
            return


def format_report(state: InFlight, now: float) -> list[str]:
    lines = []
    if state.tests:
        lines.append(f"Swift Testing tests started but not finished ({len(state.tests)}):")
        for test in state.tests:
            lines.append(
                f"  {test.name}  (started {now - test.at:.0f}s ago, output line {test.line})"
            )
            if test.last_case:
                lines.append(
                    f"    last of {test.cases_started} started case(s): {test.last_case}"
                )
    if state.suites:
        names = ", ".join(suite.name for suite in state.suites)
        lines.append(f"Swift Testing suites still open: {names}")
    if state.xctest_cases:
        lines.append("XCTest cases started but not finished:")
        for case in state.xctest_cases:
            lines.append(
                f"  {case.name}  (started {now - case.at:.0f}s ago, output line {case.line})"
            )
    if not lines:
        lines.append("No Swift Testing or XCTest test was in flight.")
    if state.last_line:
        lines.append(f"Last output line: {state.last_line}")
    return lines


def hung_summary(state: InFlight) -> str:
    """One line naming what was running, for the `::error::` annotation."""
    names = [test.name for test in state.tests] + [case.name for case in state.xctest_cases]
    if not names:
        detail = "no test was in flight"
        if state.last_line:
            detail += f"; last output: {state.last_line[:200]}"
        return detail
    shown = ", ".join(names[:MAX_NAMED_TESTS])
    if len(names) > MAX_NAMED_TESTS:
        shown += f" and {len(names) - MAX_NAMED_TESTS} more"
    summary = f"while running {shown}"
    if len(state.suites) == 1:
        summary += f" (suite {state.suites[0].name})"
    return summary


def escape_annotation(message: str) -> str:
    return message.replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")


def escape_property(value: str) -> str:
    return escape_annotation(value).replace(":", "%3A").replace(",", "%2C")


class Output:
    """The wrapper's stdout, shared by the command's bytes and its own report."""

    def __init__(self) -> None:
        self._stream = sys.stdout.buffer

    def write_bytes(self, data: bytes) -> None:
        try:
            self._stream.write(data)
            self._stream.flush()
        except (BrokenPipeError, ValueError):
            pass

    def line(self, text: str = "") -> None:
        self.write_bytes((text + "\n").encode("utf-8", "replace"))


def sample_stacks(processes: list[tuple[int, str]], seconds: int, out: Output) -> None:
    if seconds <= 0:
        return
    sampler = shutil.which("sample")
    if sampler is None:
        out.line("Stack sampling skipped: `sample` is not available on this host.")
        return
    targets = [process for process in processes if TEST_PROCESS.search(process[1])] or processes
    for pid, name in targets[:MAX_SAMPLED_PROCESSES]:
        with tempfile.TemporaryDirectory(prefix="cmux-hung-test-sample.") as directory:
            report = Path(directory) / "sample.txt"
            try:
                subprocess.run(
                    [sampler, str(pid), str(seconds), "-file", str(report)],
                    check=False,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=seconds + 30,
                )
            except (OSError, subprocess.TimeoutExpired) as error:
                out.line(f"Stack sample of {name} ({pid}) failed: {error}")
                continue
            if not report.is_file():
                out.line(f"Stack sample of {name} ({pid}) produced no report.")
                continue
            out.line(f"::group::Stack sample of {name} ({pid})")
            with report.open(encoding="utf-8", errors="replace") as handle:
                for index, text in enumerate(handle):
                    if index == MAX_SAMPLE_LINES:
                        out.line(f"... truncated after {MAX_SAMPLE_LINES} lines")
                        break
                    out.line(text.rstrip("\n"))
            out.line("::endgroup::")


def child_environment() -> dict[str, str]:
    env = os.environ.copy()
    # On a terminal SwiftPM redraws one progress line and Swift Testing emits
    # color. Keep both line-oriented unless the caller chose otherwise.
    env.setdefault("TERM", "dumb")
    env.setdefault("NO_COLOR", "1")
    return env


def spawn(command: list[str], out: Output) -> tuple[subprocess.Popen, int]:
    """Start the command on a pseudo-terminal so its stdio is line-buffered.

    Through a pipe, the Swift Testing helper's stdout is block-buffered: a
    stalled run's log stops at a buffer boundary, several tests before the one
    that hung, and the last `started` line names a test that already passed.
    """
    try:
        primary, secondary = pty.openpty()
    except OSError as error:
        out.line(
            f"::warning::No pseudo-terminal ({error}); test output is block-buffered, "
            "so a hang report can name a test that already finished."
        )
        primary, secondary = os.pipe()
    else:
        # No output processing: keep "\n" from becoming "\r\n" in the log.
        attributes = termios.tcgetattr(secondary)
        attributes[1] &= ~termios.OPOST
        termios.tcsetattr(secondary, termios.TCSANOW, attributes)
    try:
        process = subprocess.Popen(
            command,
            stdin=subprocess.DEVNULL,
            stdout=secondary,
            stderr=secondary,
            start_new_session=True,
            env=child_environment(),
        )
    except BaseException:
        os.close(primary)
        raise
    finally:
        os.close(secondary)
    return process, primary


class RunnerSignal(Exception):
    def __init__(self, signum: int) -> None:
        super().__init__(signum)
        self.signum = signum


def run(
    command: list[str],
    *,
    label: str,
    silence_seconds: float,
    timeout_seconds: float,
    sample_seconds: int,
    log_path: Optional[Path],
    drain_seconds: float = 2.0,
) -> int:
    out = Output()
    progress = TestProgress()
    log = log_path.open("wb") if log_path else None
    process, fd = spawn(command, out)
    started = last_output = time.monotonic()
    exited_at: Optional[float] = None
    pending = b""
    eof = False

    received_signals: list[int] = []

    def on_signal(signum: int, _frame: object) -> None:
        # Record only. Raising here could interrupt the parser halfway through
        # a line, and the report would then miss the test that line started.
        received_signals.append(signum)

    watched = (signal.SIGHUP, signal.SIGINT, signal.SIGTERM)
    previous = {signum: signal.signal(signum, on_signal) for signum in watched}

    def consume(chunk: bytes) -> None:
        nonlocal pending
        out.write_bytes(chunk)
        if log:
            log.write(chunk)
            log.flush()
        pending += chunk
        *complete, pending = pending.split(b"\n")
        for raw in complete:
            progress.feed(raw.decode("utf-8", "replace"))

    def report(heading: str) -> InFlight:
        if pending:
            progress.feed(pending.decode("utf-8", "replace"))
        state = progress.in_flight()
        out.line()
        out.line(f"::group::{heading}")
        for text in format_report(state, time.monotonic()):
            out.line(text)
        out.line("::endgroup::")
        return state

    try:
        while True:
            if received_signals:
                raise RunnerSignal(received_signals[0])
            now = time.monotonic()
            status = process.poll()
            if status is not None:
                exited_at = exited_at or now
                # A detached descendant can hold the pipe open after the test
                # process exits; it does not extend the step.
                if eof or now - max(exited_at, last_output) >= drain_seconds:
                    return status if status >= 0 else 128 - status
            else:
                if timeout_seconds and now - started >= timeout_seconds:
                    reason = f"timed out after {timeout_seconds:g}s"
                    break
                if silence_seconds and now - last_output >= silence_seconds:
                    reason = f"timed out after {silence_seconds:g}s with no output"
                    break
            if eof:
                time.sleep(0.05)
                continue
            readable, _, _ = select.select([fd], [], [], 0.25)
            if readable:
                try:
                    chunk = os.read(fd, 65536)
                except OSError as error:
                    # A pseudo-terminal reports EIO once every writer closed.
                    if error.errno != errno.EIO:
                        raise
                    chunk = b""
                if chunk:
                    consume(chunk)
                    last_output = time.monotonic()
                else:
                    eof = True
        # The test command stalled.
        # The reason appears once, in the annotation, so a log grep for
        # "timed out" counts one hit per stalled attempt.
        state = report(f"{label}: tests in flight when the watchdog fired")
        tree = process_tree(process.pid)
        sample_stacks(tree, sample_seconds, out)
        terminate(process, tree=tree)
        title = escape_property(f"Hung test in {label}")
        message = escape_annotation(f"{label} {reason}, {hung_summary(state)}")
        out.line(f"::error title={title}::{message}")
        return TIMEOUT_EXIT
    except RunnerSignal as received:
        for signum in watched:
            signal.signal(signum, signal.SIG_IGN)
        name = signal.Signals(received.signum).name
        state = report(f"{label} received {name} from the runner: tests in flight")
        terminate(process, received.signum)
        title = escape_property(f"Cancelled test in {label}")
        message = escape_annotation(
            f"{label} was stopped by {name} (job cancelled or job timeout reached), "
            f"{hung_summary(state)}"
        )
        out.line(f"::error title={title}::{message}")
        return 128 + received.signum
    finally:
        for signum, handler in previous.items():
            signal.signal(signum, handler)
        if log:
            log.close()
        os.close(fd)


def main(argv: Optional[list[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    parser.add_argument(
        "--silence-seconds",
        type=float,
        default=0,
        help="fail when the command writes nothing for this long (0 disables)",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=float,
        default=0,
        help="fail when the command runs longer than this (0 disables)",
    )
    parser.add_argument(
        "--sample-seconds",
        type=int,
        default=3,
        help="seconds of `sample` per test process on a hang (0 disables)",
    )
    parser.add_argument("--label", help="name for the annotation; defaults to the command")
    parser.add_argument("--log", type=Path, help="also write the command's output here")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command:
        parser.error("a command is required after --")
    if args.silence_seconds < 0 or args.timeout_seconds < 0 or args.sample_seconds < 0:
        parser.error("durations must not be negative")
    if not args.silence_seconds and not args.timeout_seconds:
        parser.error("set --silence-seconds, --timeout-seconds, or both")
    if args.log:
        args.log.parent.mkdir(parents=True, exist_ok=True)
    return run(
        command,
        label=args.label or shlex.join(command)[:120],
        silence_seconds=args.silence_seconds,
        timeout_seconds=args.timeout_seconds,
        sample_seconds=args.sample_seconds,
        log_path=args.log,
    )


if __name__ == "__main__":
    raise SystemExit(main())
