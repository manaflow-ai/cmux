#!/usr/bin/env python3
"""MQ-13 and RUN-5 (plans/cmux-next/chrome-parity/p02-threads.md): daemon blocking sites.

Every daemon process started with CMUX_DAEMON_BLOCKING_REPORT=<dir> appends one JSON
line per (site, kind, thread) to <dir>/blocking-<pid>.jsonl
(cmux-tui/crates/cmux-threads/src/blocking/report.rs). This script runs the suites with
that set and groups the lines into the MQ-13 list: one task per (location, kind, thread
class), where digits in a thread name are an instance number (surface-N-host).

  daemon-blocking-sweep.py suites [--out DIR] [-p PKG ...] [--binary-timeout S] [-- CARGO_TEST_ARGS]
      cargo test in record mode, then in panic mode (Debug): the record run lists the
      sites, the panic run is RUN-5 (no failure panic mode adds, 0 blocking panics, 0
      sites). A test that fails in both modes is an environment or base failure and is
      listed apart.
  daemon-blocking-sweep.py bench [--out DIR] [--against SHA | --base REF] [--noise F] [-- PERF_ARGS]
      scripts/measure/perf-10x-lifecycle.sh part=daemon against=<base> (Release: record
      only) with the report set; RUN-5 bench: 0 sites, every op's p95 no worse than the
      base's beyond the noise band, and under the PL-daemon 2 ms target. Fleet only
      (cmux-ci run --class exclusive --measurement).
  daemon-blocking-sweep.py summarize DIR
      Group an existing report directory.

A site in test code (a file under tests/, a *_tests.rs or tests.rs file, or a line inside
a #[cfg(test)] module) is the detector's own fixture and is listed apart; every other
site is one MQ-13 task, whatever thread it ran on. An unnamed thread is not a fixture: a
daemon thread that disallows blocking without a name is an MQ-12 defect of its own.
"""

from __future__ import annotations

import argparse
import functools
import json
import os
import re
import subprocess
import threading
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TUI = ROOT / "cmux-tui"
DEFAULT_PACKAGES = ("cmux-tui-core", "cmux-tui")
DEFAULT_BASE = "origin/feat-cmux-next"
# A p95 more than this fraction over the base's is a regression: the 5 % CV band of
# plans/cmux-next/chrome-parity/p12-perf-process.md (Noise, item 9).
DEFAULT_NOISE = 0.05
# PL-daemon: every daemon op under 2 ms p95 (p02-threads.md, RUN-5).
DAEMON_P95_TARGET_MS = 2.0
PANIC_LINE = re.compile(r"cmux_threads: blocking call \(([a-z-]+)\) at (\S+) on thread '([^']*)'")
RUNNING = re.compile(r"^\s*Running (.+?) \((.+)\)\s*$")
NO_RESULT = "<no test result: crashed, killed or hung>"
DEFAULT_BINARY_TIMEOUT = 900
FAILED_TEST = re.compile(r"^test (\S+) \.\.\. FAILED$")
CFG_TEST = re.compile(r"^\s*#\[cfg\(test\)\]")
INLINE_MOD = re.compile(r"^\s*(?:pub(?:\([^)]*\))?\s+)?mod\s+\w+\s*\{")
ATTRIBUTE_OR_COMMENT = re.compile(r"^\s*(?:#\[|//|$)")
LIFECYCLE_DAEMON = re.compile(r'^LIFECYCLE-DAEMON (against|ref) op="([^"]+)" n=\d+ p50=[\d.]+ p95=([\d.]+)')


def is_test_file(file: str) -> bool:
    path = file.replace("\\", "/")
    name = path.rsplit("/", 1)[-1]
    return "/tests/" in path or path.startswith("tests/") or name == "tests.rs" or name.endswith("_tests.rs")


def source_path(file: str) -> Path:
    """A Location file is relative to the cargo workspace (cmux-tui/) or absolute."""
    path = Path(file)
    return path if path.is_absolute() else TUI / path


@functools.cache
def cfg_test_ranges(path: Path) -> tuple[tuple[int, int], ...]:
    """1-based inclusive line ranges of the inline #[cfg(test)] modules of a source file."""
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError):
        return ()
    ranges = []
    index = 0
    while index < len(lines):
        if not CFG_TEST.match(lines[index]):
            index += 1
            continue
        start = index + 1
        while start < len(lines) and not INLINE_MOD.match(lines[start]) and ATTRIBUTE_OR_COMMENT.match(lines[start]):
            start += 1
        if start >= len(lines) or not INLINE_MOD.match(lines[start]):
            index += 1
            continue
        end = module_end(lines, start)
        ranges.append((index + 1, end + 1))
        index = end + 1
    return tuple(ranges)


def module_end(lines: list[str], start: int) -> int:
    """The index of the line that closes the block opened on lines[start]."""
    depth = 0
    for index in range(start, len(lines)):
        for brace in braces(lines[index]):
            depth += 1 if brace == "{" else -1
            if depth == 0:
                return index
    return len(lines) - 1


def braces(line: str) -> str:
    """The braces of one line, outside strings, char literals and // comments."""
    code = re.sub(r'"(?:\\.|[^"\\])*"', '""', line)
    code = re.sub(r"'(?:\\.|[^'\\])'", "''", code)
    return re.sub(r"[^{}]", "", code.split("//", 1)[0])


def is_fixture(file: str, line: int) -> bool:
    """Whether a site is in test code: the detector's own fixtures, not a daemon task."""
    if is_test_file(file):
        return True
    return any(start <= line <= end for start, end in cfg_test_ranges(source_path(file)))


def read_reports(directory: Path) -> list[dict]:
    lines = []
    for path in sorted(directory.glob("blocking-*.jsonl")):
        for number, text in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
            if not text.strip():
                continue
            try:
                lines.append(json.loads(text))
            except json.JSONDecodeError:
                # A process killed mid-write leaves a torn last line; say so and go on.
                print(f"MQ-13 torn line {path.name}:{number}", file=sys.stderr)
    return lines


def thread_class(name: str) -> str:
    """A thread's type, as Chrome's ThreadType names it: one instance number is not a new
    thread. `surface-12-host` and `surface-3-host` are both `surface-N-host`."""
    return re.sub(r"\d+", "N", name)


def group(lines: list[dict]) -> list[dict]:
    """One row per (location, kind, thread class): the MQ-13 task key."""
    rows: dict[tuple, dict] = {}
    pids: dict[tuple, set] = defaultdict(set)
    names: dict[tuple, set] = defaultdict(set)
    for line in lines:
        location = f'{line["file"]}:{line["line"]}:{line["column"]}'
        key = (location, line["kind"], thread_class(line["thread"]))
        row = rows.setdefault(
            key,
            {
                "location": location,
                "kind": line["kind"],
                "thread": key[2],
                "fixture": is_fixture(line["file"], line["line"]),
                "modes": [],
                "overflow": False,
            },
        )
        if line["mode"] not in row["modes"]:
            row["modes"].append(line["mode"])
        row["overflow"] = row["overflow"] or bool(line.get("overflow"))
        pids[key].add(line["pid"])
        names[key].add(line["thread"])
    for key, row in rows.items():
        row["processes"] = len(pids[key])
        row["thread_names"] = len(names[key])
    return sorted(rows.values(), key=lambda row: (row["fixture"], -row["processes"], row["location"], row["kind"], row["thread"]))


def summarize(directory: Path) -> list[dict]:
    rows = group(read_reports(directory))
    (directory / "sites.json").write_text(json.dumps(rows, indent=1) + "\n", encoding="utf-8")
    for row in rows:
        tag = "MQ-13-fixture" if row["fixture"] else "MQ-13"
        overflow = " overflow" if row["overflow"] else ""
        print(
            f'{tag} site={row["location"]} kind={row["kind"]} thread={row["thread"]} '
            f'processes={row["processes"]} modes={",".join(row["modes"])}{overflow}'
        )
    tasks = sum(1 for row in rows if not row["fixture"])
    print(f"MQ-13 dir={directory} tasks={tasks} fixtures={len(rows) - tasks}")
    return rows


def blocking_panics(log: str) -> list[tuple[str, str, str]]:
    """Panic-mode panics outside the fixtures' own deliberate ones, deduplicated."""
    seen = dict.fromkeys(PANIC_LINE.findall(log))
    outside = []
    for panic in seen:
        file, line, _column = panic[1].rsplit(":", 2)
        if not is_fixture(file, int(line)):
            outside.append(panic)
    return outside


def binary_label(match: re.Match) -> str:
    """`tests/cli.rs (cli)` for `Running tests/cli.rs (target/debug/deps/cli-0123456789abcdef)`."""
    name = re.sub(r"-[0-9a-f]{16}$", "", Path(match.group(2)).name)
    return f"{match.group(1)} ({name})"


def failed_tests(log: str) -> set[tuple[str, str]]:
    """(test binary, test name) of every failed test in a cargo test log. A binary that
    printed no `test result:` line crashed, was killed or hung: it counts as one failure,
    NO_RESULT, since its own tests never said so."""
    binary = None
    finished = True
    failed = set()
    for line in log.splitlines():
        if match := RUNNING.match(line):
            if not finished:
                failed.add((binary, NO_RESULT))
            binary, finished = binary_label(match), False
        elif match := FAILED_TEST.match(line):
            failed.add((binary or "?", match.group(1)))
        elif line.startswith("test result: "):
            finished = True
    if not finished:
        failed.add((binary, NO_RESULT))
    return failed


def stop_test_binary(path: str, limit: int) -> None:
    """Ends a test binary that ran past its limit, and the daemons it started, so cargo
    reports it failed and goes on (--no-fail-fast)."""
    pids = subprocess.run(["pgrep", "-f", path], capture_output=True, text=True, check=False).stdout.split()
    for pid in pids:
        # A daemon stays up on SIGTERM (docs/cloud-guest-upgrades.md); these are test daemons.
        subprocess.run(["pkill", "-KILL", "-P", pid], check=False)
        subprocess.run(["kill", "-TERM", pid], check=False)
    print(f"SWEEP stopped {path} after {limit} s ({len(pids)} processes)", flush=True)


def run_suite(command: list[str], env: dict, cwd: Path, log_path: Path, binary_timeout: int) -> tuple[int, str]:
    """cargo test, logged, with each test binary stopped after `binary_timeout` seconds: in
    panic mode a daemon thread that panics can leave a test waiting for a reply forever."""
    print("+ " + " ".join(command), flush=True)
    lines: list[str] = []
    watchdog: threading.Timer | None = None
    with subprocess.Popen(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True) as cargo:
        assert cargo.stdout is not None
        for line in cargo.stdout:
            lines.append(line)
            if match := RUNNING.match(line.rstrip("\n")):
                if watchdog:
                    watchdog.cancel()
                watchdog = threading.Timer(binary_timeout, stop_test_binary, (match.group(2), binary_timeout))
                watchdog.daemon = True
                watchdog.start()
            elif line.startswith("test result: ") and watchdog:
                watchdog.cancel()
        if watchdog:
            watchdog.cancel()
    log = "".join(lines)
    log_path.write_text(log, encoding="utf-8")
    return cargo.returncode, log


def run_logged(command: list[str], env: dict, cwd: Path, log_path: Path) -> tuple[int, str]:
    print("+ " + " ".join(command), flush=True)
    result = subprocess.run(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log_path.write_text(result.stdout, encoding="utf-8")
    return result.returncode, result.stdout


def run5_suites_verdict(record_log: str, panic_log: str, panic_rows: list[dict]) -> dict:
    """RUN-5: panic mode adds no failure, panics nowhere outside test code, reaches no site."""
    record_failed = failed_tests(record_log)
    panic_failed = failed_tests(panic_log)
    panics = blocking_panics(panic_log)
    sites = [row for row in panic_rows if not row["fixture"]]
    added = sorted(panic_failed - record_failed)
    return {
        "verdict": "pass" if not added and not panics and not sites else "fail",
        "panic_only_failures": added,
        "shared_failures": sorted(panic_failed & record_failed),
        "blocking_panics": panics,
        "sites": sites,
    }


def suites(out: Path, packages: list[str], cargo_args: list[str], binary_timeout: int) -> int:
    command = ["cargo", "test", "--no-fail-fast"]
    for package in packages:
        command += ["-p", package]
    command += cargo_args
    logs: dict[str, str] = {}
    rows: dict[str, list[dict]] = {}
    for mode in ("record", "panic"):
        report = fresh_report_dir(out / mode)
        env = dict(os.environ, CMUX_DAEMON_BLOCKING=mode, CMUX_DAEMON_BLOCKING_REPORT=str(report))
        code, logs[mode] = run_suite(command, env, TUI, out / f"{mode}.log", binary_timeout)
        rows[mode] = summarize(report)
        passed, failed = test_totals(logs[mode])
        print(f"SUITE mode={mode} cargo_exit={code} passed={passed} failed={failed}")
    result = run5_suites_verdict(logs["record"], logs["panic"], rows["panic"])
    for binary, test in result["shared_failures"]:
        print(f"RUN-5 shared-failure binary={binary} test={test}")
    for binary, test in result["panic_only_failures"]:
        print(f"RUN-5 panic-only-failure binary={binary} test={test}")
    for kind, location, thread in result["blocking_panics"]:
        print(f"RUN-5 blocking-panic site={location} kind={kind} thread={thread}")
    record_tasks = sum(1 for row in rows["record"] if not row["fixture"])
    print(
        f"RUN-5 {result['verdict']} packages={','.join(packages)} "
        f"panic_only_failures={len(result['panic_only_failures'])} "
        f"shared_failures={len(result['shared_failures'])} blocking_panics={len(result['blocking_panics'])} "
        f"sites={len(result['sites'])} mq13_tasks={record_tasks} log={out / 'panic.log'}"
    )
    return 0 if result["verdict"] == "pass" else 1


def fresh_report_dir(directory: Path) -> Path:
    """A report directory with no lines from an earlier run."""
    directory.mkdir(parents=True, exist_ok=True)
    for stale in directory.glob("blocking-*.jsonl"):
        stale.unlink()
    return directory


def test_totals(log: str) -> tuple[int, int]:
    """Passed and failed tests over every `test result:` line of a cargo test log."""
    passed = sum(int(n) for n in re.findall(r"^test result: \w+\. (\d+) passed", log, re.M))
    failed = sum(int(n) for n in re.findall(r"^test result: .*?; (\d+) failed", log, re.M))
    return passed, failed


def lifecycle_p95(log: str) -> dict[str, dict[str, float]]:
    """p95 ms per op for the `against` and `ref` binaries of perf-10x-lifecycle.sh."""
    p95: dict[str, dict[str, float]] = {"against": {}, "ref": {}}
    for line in log.splitlines():
        if match := LIFECYCLE_DAEMON.match(line):
            p95[match.group(1)][match.group(2)] = float(match.group(3))
    return p95


def run5_bench_verdict(p95: dict[str, dict[str, float]], sites: int, noise: float) -> tuple[str, list[str]]:
    """RUN-5 bench: 0 sites, each op's p95 within the noise band of the base's, under 2 ms."""
    problems = []
    if not p95["ref"]:
        problems.append("no ref LIFECYCLE-DAEMON lines")
    for op, ref in sorted(p95["ref"].items()):
        against = p95["against"].get(op)
        if against is None:
            problems.append(f'op="{op}" has no base measurement')
        elif ref > against * (1 + noise):
            problems.append(f'op="{op}" regressed ref_p95={ref:.2f} against_p95={against:.2f}')
        if ref >= DAEMON_P95_TARGET_MS:
            problems.append(f'op="{op}" over target ref_p95={ref:.2f} target={DAEMON_P95_TARGET_MS:.2f}')
    if sites:
        problems.append(f"sites={sites}")
    return ("pass" if not problems else "fail"), problems


def merge_base(base: str) -> str:
    result = subprocess.run(["git", "merge-base", "HEAD", base], cwd=ROOT, capture_output=True, text=True, check=False)
    if result.returncode != 0:
        raise SystemExit(f"daemon-blocking-sweep: no merge base with {base}: {result.stderr.strip()}")
    return result.stdout.strip()


def bench(out: Path, against: str, noise: float, perf_args: list[str]) -> int:
    head = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True, check=True).stdout.strip()
    if against == head:
        raise SystemExit("daemon-blocking-sweep: the base is HEAD; pass --against or --base with an earlier commit")
    report = fresh_report_dir(out / "bench")
    env = dict(os.environ, CMUX_DAEMON_BLOCKING_REPORT=str(report))
    command = [str(ROOT / "scripts/measure/perf-10x-lifecycle.sh"), "part=daemon", f"against={against}", *perf_args]
    code, log = run_logged(command, env, ROOT, out / "bench.log")
    for line in log.splitlines():
        if line.startswith("LIFECYCLE"):
            print(line)
    rows = summarize(report)
    sites = sum(1 for row in rows if not row["fixture"])
    verdict, problems = run5_bench_verdict(lifecycle_p95(log), sites, noise)
    if code:
        verdict = "fail"
        problems.append(f"bench_exit={code}")
    for problem in problems:
        print(f"RUN-5 bench-problem {problem}")
    print(f"RUN-5 bench {verdict} against={against} ref={head} noise={noise:.2f} sites={sites} bench_exit={code}")
    return 0 if verdict == "pass" else 1


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("suites")
    run.add_argument("--out", type=Path, default=TUI / "target" / "blocking-sweep")
    run.add_argument("-p", "--package", action="append", dest="packages")
    run.add_argument(
        "--binary-timeout",
        type=int,
        default=DEFAULT_BINARY_TIMEOUT,
        help=f"seconds before a test binary is stopped as hung (default {DEFAULT_BINARY_TIMEOUT})",
    )
    run.add_argument("rest", nargs=argparse.REMAINDER)
    measure = commands.add_parser("bench")
    measure.add_argument("--out", type=Path, default=ROOT / ".build" / "blocking-sweep")
    measure.add_argument("--against", help="the base commit (default: the merge base with --base)")
    measure.add_argument("--base", default=DEFAULT_BASE, help=f"the base branch (default {DEFAULT_BASE})")
    measure.add_argument("--noise", type=float, default=DEFAULT_NOISE, help="allowed p95 rise over the base, as a fraction")
    measure.add_argument("rest", nargs=argparse.REMAINDER)
    read = commands.add_parser("summarize")
    read.add_argument("directory", type=Path)
    args = parser.parse_args(argv)
    if args.command == "summarize":
        summarize(args.directory)
        return 0
    rest = args.rest[1:] if args.rest[:1] == ["--"] else args.rest
    out = args.out.resolve()
    out.mkdir(parents=True, exist_ok=True)
    if args.command == "suites":
        return suites(out, args.packages or list(DEFAULT_PACKAGES), rest, args.binary_timeout)
    return bench(out, args.against or merge_base(args.base), args.noise, rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
