#!/usr/bin/env python3
"""Turn one sanitizer or Miri run of one crate into findings.jsonl and runs.jsonl lines.

cmux-tui/scripts/sanitize.sh calls this after each `cargo nextest run`. Inputs:
the sanitizer runtime's per-process report files (log_path=DIR/report, so
DIR/report.<pid>), the pid of each test process (written by
cmux-tui/sanitize/test-runner.sh) and nextest's libtest-json-plus events, whose
failed-test `stdout` holds the test's output (Miri prints its errors there).

Signatures come from scripts/cmux-next/crash_signature.py: each sanitizer
report and each Miri error gets {kind, process, exception, frames, hash12}.
One crate run writes one findings line per unique hash12, with how often it
was seen, so the lane's queue (Q15) files one task per signature, as
ClusterFuzz files one bug per crash state.

The run itself (nextest exit, failed tests, tests Miri cannot run, report files
no signature could be read from) goes to runs.jsonl, so a red run with no
finding is still visible and never reads as a pass.
"""

from __future__ import annotations

import argparse
import importlib.util
import json
import re
import sys
from dataclasses import dataclass
from pathlib import Path
from types import ModuleType

TOOLS = ("address", "thread", "leak", "miri")
REPO_DIR = Path(__file__).resolve().parents[2]
DEFAULT_SIGNATURE = REPO_DIR / "scripts" / "cmux-next" / "crash_signature.py"
REPORT_SAMPLES = 5
# `unsupported`: every red test hit an operation Miri isolation cannot run
# (sockets, files, processes). No bug was found; the tests stay listed in
# runs.jsonl's `unsupported_tests`.
GREEN_RESULTS = ("pass", "unsupported")

# nextest exit codes (nextest-metadata NextestExitCode).
_EXIT_NO_TESTS = 4
_EXIT_SETUP = 96
_EXIT_BUILD = 101
_EXIT_TEST_LIST = 104

# A rustc-style Miri diagnostic: an `error:` line (at column 0, or after
# libtest's `test NAME ... ` when Miri stops the test mid-line) whose block has
# a source arrow, a note/help line or a backtrace. A test that prints its own
# `error:` text has none of these.
_MIRI_ERROR = re.compile(r"^(?:test \S+ \.\.\. )?error: (?P<headline>[^\n]*)$", re.M)
_MIRI_DIAGNOSTIC_BODY = re.compile(r"^\s*(?:--> |= (?:note|help):|\d+: )", re.M)
_MIRI_ABORTING = "aborting due to"
_MIRI_UNSUPPORTED = "unsupported operation"
_MIRI_FRAME = re.compile(r"^\s*(?P<n>\d+): (?P<function>\S.*?)\s*$")
_MIRI_AT = re.compile(r"^\s*at (?P<file>.+?):\d+:\d+(?:: \d+:\d+)?\s*$")
_MIRI_INSIDE = re.compile(r"inside `(?P<function>[^`]+)` at (?P<file>[^\s:]+)")
_SANITIZER_TEXT = re.compile(r"(?:Address|Leak|Thread)Sanitizer")


@dataclass
class Finding:
    signature: dict
    tests: list[str]
    reports: list[str]
    count: int = 1


@dataclass(frozen=True)
class TestRun:
    """What nextest's libtest-json-plus events say about the run."""

    passed: tuple[str, ...]
    failed: dict[str, str]  # test name -> its output

    def full_name(self, binary_id: str, test: str) -> str:
        """`ws::ws$tests::a` for the runner's (`ws`, `tests::a`): the event's name when one event has that test."""
        names = [name for name in (*self.passed, *self.failed) if name.endswith("$" + test)]
        return names[0] if len(names) == 1 else f"{binary_id}${test}"


def load_signature_module(path: Path) -> ModuleType:
    spec = importlib.util.spec_from_file_location("crash_signature", path)
    if spec is None or spec.loader is None:
        raise ImportError(f"cannot load {path}")
    module = importlib.util.module_from_spec(spec)
    sys.modules["crash_signature"] = module  # dataclasses resolve their module by name
    spec.loader.exec_module(module)
    return module


def read_events(path: Path) -> TestRun:
    """libtest-json-plus events: passed and failed tests; lines that are not JSON are skipped."""
    passed: list[str] = []
    failed: dict[str, str] = {}
    if not path.is_file():
        return TestRun((), {})
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if not isinstance(event, dict) or event.get("type") != "test":
            continue
        name = str(event.get("name", ""))
        if event.get("event") == "ok":
            passed.append(name)
        elif event.get("event") in ("failed", "timeout"):
            failed[name] = str(event.get("stdout") or "")
    return TestRun(tuple(passed), failed)


def read_test_pids(path: Path, events: TestRun) -> dict[str, str]:
    """pid -> test, from test-runner.sh's `PID<TAB>BINARY_ID$TEST` lines."""
    tests: dict[str, str] = {}
    if not path.is_file():
        return tests
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        pid, _, name = line.partition("\t")
        binary_id, sep, test = name.partition("$")
        if pid.isdigit() and sep:
            tests[pid] = events.full_name(binary_id, test)
    return tests


def miri_exception(headline: str) -> str:
    """`Undefined Behavior: memory access failed: alloc7 has been freed` -> `Undefined Behavior: memory access failed`.

    The bug class without the run's allocation ids, borrow tags, addresses,
    thread names and sizes, so the same bug in two runs has one exception.
    """
    parts = headline.split(": ")
    text = ": ".join(parts[:2]) if parts[0] == "Undefined Behavior" and len(parts) > 1 else parts[0]
    text = re.sub(r"`[^`]*`", "_", text)
    text = re.sub(r"\balloc\d+\b", "allocN", text)
    text = re.sub(r"<\d+>", "<N>", text)
    text = re.sub(r"\[0x[0-9a-fA-F]+(?:\.\.0x[0-9a-fA-F]+)?\]|0x[0-9a-fA-F]+", "ADDR", text)
    text = re.sub(r"\d+", "N", text)
    return re.sub(r"\s+", " ", text).strip(" ,.")


def _sysroot_file(path: str, sysroot: str) -> str:
    """Miri's std frames name the toolchain's rust-src; spell them as rustc's own /rustc/ paths."""
    prefix = sysroot.rstrip("/") + "/lib/rustlib/src/rust/"
    return "/rustc/" + path[len(prefix):] if sysroot and path.startswith(prefix) else path


def miri_frames(body: str, frame_type: type, sysroot: str) -> list:
    """The `stack backtrace:` frames of one Miri error (`N: fn` then `at file:line:col`), else its `inside` notes."""
    frames: list = []
    lines = body.splitlines()
    try:
        start = next(i for i, line in enumerate(lines) if line.strip().endswith("stack backtrace:"))
    except StopIteration:
        start = None
    if start is not None:
        for line in lines[start + 1:]:
            frame = _MIRI_FRAME.match(line)
            if frame:
                frames.append(frame_type(function=frame.group("function")))
                continue
            at = _MIRI_AT.match(line)
            if at and frames and not frames[-1].file:
                last = frames[-1]
                frames[-1] = frame_type(function=last.function, file=_sysroot_file(at.group("file"), sysroot))
                continue
            if line.strip():
                break
    if not frames:
        frames = [frame_type(function=m.group("function"), file=_sysroot_file(m.group("file"), sysroot))
                  for m in _MIRI_INSIDE.finditer(body)]
    return frames


def miri_errors(output: str) -> tuple[list[tuple[str, str]], list[str]]:
    """(headline, body) of each Miri bug in one failed test's output, and the headlines of unsupported operations."""
    starts = list(_MIRI_ERROR.finditer(output))
    bugs: list[tuple[str, str]] = []
    unsupported: list[str] = []
    for i, match in enumerate(starts):
        headline = match.group("headline")
        if headline.startswith(_MIRI_ABORTING):
            continue
        end = starts[i + 1].start() if i + 1 < len(starts) else len(output)
        body = output[match.start():end]
        if not _MIRI_DIAGNOSTIC_BODY.search(body):
            continue
        if headline.startswith(_MIRI_UNSUPPORTED):
            unsupported.append(miri_exception(headline))
        else:
            bugs.append((headline, body))
    return bugs, unsupported


def add_finding(findings: dict[str, Finding], signature: dict, test: str | None, report: str) -> None:
    finding = findings.get(signature["hash12"])
    if finding is None:
        findings[signature["hash12"]] = Finding(signature, [test] if test else [], [report])
        return
    finding.count += 1
    if len(finding.reports) < REPORT_SAMPLES and report not in finding.reports:
        finding.reports.append(report)
    if test and len(finding.tests) < REPORT_SAMPLES and test not in finding.tests:
        finding.tests.append(test)


def collect(args: argparse.Namespace) -> int:
    signatures = load_signature_module(Path(args.signature))
    ignore = signatures.IgnoreList.load()
    events = read_events(Path(args.events))
    process = args.crate.replace("-", "_")
    findings: dict[str, Finding] = {}
    unsupported: dict[str, list[str]] = {}
    unparsed: list[str] = []

    if args.tool == "miri":
        for test, output in sorted(events.failed.items()):
            bugs, skipped = miri_errors(output)
            for headline, body in bugs:
                frames = miri_frames(body, signatures.Frame, args.sysroot)
                signature = signatures.make_signature(
                    "miri", process, miri_exception(headline), frames, ignore, args.events, headline)
                add_finding(findings, signature.to_json(), test, args.events)
            if skipped and not bugs:
                unsupported[test] = skipped
    else:
        test_pids = read_test_pids(Path(args.tests), events) if args.tests else {}
        for path in sorted(Path(args.log_dir).glob("report.*")):
            found = signatures.signatures_from_path(path, ignore, process=process)
            if not found and _SANITIZER_TEXT.search(path.read_text(encoding="utf-8", errors="replace")):
                unparsed.append(str(path))
            test = test_pids.get(path.suffix.lstrip("."))
            for signature in found:
                add_finding(findings, signature.to_json(), test, str(path))

    context = {"lane": "sanitizer-rust", "tool": args.tool, "crate": args.crate, "os": args.os,
               "target": args.target, "toolchain": args.toolchain, "commit": args.commit}
    with open(args.out, "a", encoding="utf-8") as out:
        for finding in findings.values():
            record = {**finding.signature, **context, "count": finding.count, "reports": finding.reports}
            if finding.tests:
                record["test"] = finding.tests[0]
                record["tests"] = finding.tests
            out.write(json.dumps(record, sort_keys=True) + "\n")

    failed_tests = sorted(test for test in events.failed if test not in unsupported)
    result = run_result(args.exit, bool(findings), bool(unparsed), failed_tests, unsupported)
    run = {**context, "exit": args.exit, "result": result, "findings": len(findings),
           "passed": len(events.passed), "failed_tests": failed_tests, "unsupported_tests": unsupported,
           "unparsed_reports": unparsed, "log": args.nextest_log}
    with open(args.runs, "a", encoding="utf-8") as runs:
        runs.write(json.dumps(run, sort_keys=True) + "\n")
    print(f"sanitize: {args.tool} {args.crate}: {result} ({len(findings)} findings, {len(failed_tests)} failed, "
          f"{len(unsupported)} unsupported, {len(unparsed)} unparsed, nextest exit {args.exit})", file=sys.stderr)
    return 0 if result in GREEN_RESULTS else 1


def run_result(exit_code: int, findings: bool, unparsed: bool, failed_tests: list[str],
               unsupported: dict[str, list[str]]) -> str:
    """One word for the run; GREEN_RESULTS are green."""
    if findings or unparsed:
        return "findings"
    if exit_code in (_EXIT_BUILD, _EXIT_TEST_LIST, _EXIT_SETUP):
        return "build-failed"
    if exit_code == _EXIT_NO_TESTS:
        return "no-tests"
    if exit_code == 0:
        return "pass"
    if unsupported and not failed_tests:
        return "unsupported"
    return "failed"


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--tool", required=True, choices=TOOLS)
    parser.add_argument("--crate", required=True)
    parser.add_argument("--os", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--commit", required=True)
    parser.add_argument("--sysroot", default="", help="the nightly's sysroot, to name Miri's std frames /rustc/")
    parser.add_argument("--exit", required=True, type=int, help="nextest's exit status")
    parser.add_argument("--log-dir", required=True, help="the sanitizer runtime's log_path directory")
    parser.add_argument("--tests", default="", help="test-runner.sh's pid -> test lines")
    parser.add_argument("--events", required=True, help="nextest libtest-json-plus output")
    parser.add_argument("--nextest-log", required=True)
    parser.add_argument("--out", required=True, help="findings.jsonl (appended)")
    parser.add_argument("--runs", required=True, help="runs.jsonl (appended)")
    parser.add_argument("--signature", default=str(DEFAULT_SIGNATURE), help="crash_signature.py")
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    return collect(parse_args(sys.argv[1:] if argv is None else argv))


if __name__ == "__main__":
    sys.exit(main())
