#!/usr/bin/env python3
"""MQ-13 and RUN-5 (plans/cmux-next/chrome-parity/p02-threads.md): daemon blocking sites.

Every daemon process started with CMUX_DAEMON_BLOCKING_REPORT=<dir> appends one JSON
line per new (site, kind) to <dir>/blocking-<pid>.jsonl
(cmux-tui/crates/cmux-threads/src/blocking/report.rs). This script runs the suites with
that set and groups the lines into the MQ-13 list: one task per (location, kind, thread).

  daemon-blocking-sweep.py suites [--out DIR] [-p PKG ...] [-- CARGO_TEST_ARGS]
      cargo test in record mode, then in panic mode (Debug): the record run lists the
      sites, the panic run is RUN-5 (tests pass, 0 blocking panics).
  daemon-blocking-sweep.py bench [--out DIR] [-- PERF_ARGS]
      scripts/measure/perf-10x-lifecycle.sh part=daemon (Release: record only) with the
      report set; fleet only (cmux-ci run --class exclusive --measurement).
  daemon-blocking-sweep.py summarize DIR
      Group an existing report directory.

Sites in test files (tests/, *_tests.rs, tests.rs) are the detector's own fixtures and are
listed apart; every other site is one MQ-13 task.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TUI = ROOT / "cmux-tui"
DEFAULT_PACKAGES = ("cmux-tui-core", "cmux-tui")
PANIC_LINE = re.compile(r"cmux_threads: blocking call \(([a-z-]+)\) at (\S+) on thread '([^']*)'")


def is_fixture(file: str, thread: str) -> bool:
    """A test's own disallowed thread, not a daemon thread: the site is in a test file, or
    the thread is one a test made. Daemon threads are always named through
    cmux_threads::spawn (MQ-12); libtest names its threads after the test path."""
    path = file.replace("\\", "/")
    name = path.rsplit("/", 1)[-1]
    in_test_file = "/tests/" in path or path.startswith("tests/") or name == "tests.rs" or name.endswith("_tests.rs")
    test_thread = thread == "<unnamed>" or "::" in thread or "test" in thread
    return in_test_file or test_thread


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


def group(lines: list[dict]) -> list[dict]:
    """One row per (location, kind, thread): the MQ-13 task key."""
    rows: dict[tuple, dict] = {}
    pids: dict[tuple, set] = defaultdict(set)
    for line in lines:
        location = f'{line["file"]}:{line["line"]}:{line["column"]}'
        key = (location, line["kind"], line["thread"])
        row = rows.setdefault(
            key,
            {
                "location": location,
                "kind": line["kind"],
                "thread": line["thread"],
                "fixture": is_fixture(line["file"], line["thread"]),
                "modes": [],
                "overflow": False,
            },
        )
        if line["mode"] not in row["modes"]:
            row["modes"].append(line["mode"])
        row["overflow"] = row["overflow"] or bool(line.get("overflow"))
        pids[key].add(line["pid"])
    for key, row in rows.items():
        row["processes"] = len(pids[key])
    return sorted(rows.values(), key=lambda row: (row["fixture"], -row["processes"], row["location"], row["kind"]))


def summarize(directory: Path) -> list[dict]:
    rows = group(read_reports(directory))
    (directory / "sites.json").write_text(json.dumps(rows, indent=1) + "\n", encoding="utf-8")
    for row in rows:
        tag = "MQ-13-fixture" if row["fixture"] else "MQ-13"
        print(
            f'{tag} site={row["location"]} kind={row["kind"]} thread={row["thread"]} '
            f'processes={row["processes"]} modes={",".join(row["modes"])}'
        )
    tasks = sum(1 for row in rows if not row["fixture"])
    print(f"MQ-13 dir={directory} tasks={tasks} fixtures={len(rows) - tasks}")
    return rows


def blocking_panics(log: str) -> list[tuple[str, str, str]]:
    """Panic-mode panics outside the fixtures' own deliberate ones, deduplicated."""
    seen = dict.fromkeys(PANIC_LINE.findall(log))
    return [panic for panic in seen if not is_fixture(panic[1].rsplit(":", 2)[0], panic[2])]


def run_logged(command: list[str], env: dict, cwd: Path, log_path: Path) -> tuple[int, str]:
    print("+ " + " ".join(command), flush=True)
    result = subprocess.run(command, cwd=cwd, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    log_path.write_text(result.stdout, encoding="utf-8")
    return result.returncode, result.stdout


def suites(out: Path, packages: list[str], cargo_args: list[str]) -> int:
    command = ["cargo", "test", "--no-fail-fast"]
    for package in packages:
        command += ["-p", package]
    command += cargo_args
    status = 0
    for mode in ("record", "panic"):
        report = fresh_report_dir(out / mode)
        env = dict(os.environ, CMUX_DAEMON_BLOCKING=mode, CMUX_DAEMON_BLOCKING_REPORT=str(report))
        code, log = run_logged(command, env, TUI, out / f"{mode}.log")
        rows = summarize(report)
        passed, failed = test_totals(log)
        print(f"SUITE mode={mode} cargo_exit={code} passed={passed} failed={failed}")
        if mode == "panic":
            panics = blocking_panics(log)
            for kind, location, thread in panics:
                print(f"RUN-5 blocking-panic site={location} kind={kind} thread={thread}")
            outside = [row for row in rows if not row["fixture"]]
            verdict = "pass" if code == 0 and not panics and not outside else "fail"
            print(
                f"RUN-5 {verdict} packages={','.join(packages)} cargo_exit={code} passed={passed} "
                f"failed={failed} blocking_panics={len(panics)} sites={len(outside)} log={out / 'panic.log'}"
            )
            status = 0 if verdict == "pass" else 1
    return status


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


def bench(out: Path, perf_args: list[str]) -> int:
    report = fresh_report_dir(out / "bench")
    env = dict(os.environ, CMUX_DAEMON_BLOCKING_REPORT=str(report))
    command = [str(ROOT / "scripts/measure/perf-10x-lifecycle.sh"), "part=daemon", *perf_args]
    code, log = run_logged(command, env, ROOT, out / "bench.log")
    for line in log.splitlines():
        if line.startswith("LIFECYCLE"):
            print(line)
    rows = summarize(report)
    sites = sum(1 for row in rows if not row["fixture"])
    print(f"RUN-5 bench sites={sites} bench_exit={code}")
    return code or (1 if sites else 0)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    commands = parser.add_subparsers(dest="command", required=True)
    run = commands.add_parser("suites")
    run.add_argument("--out", type=Path, default=TUI / "target" / "blocking-sweep")
    run.add_argument("-p", "--package", action="append", dest="packages")
    run.add_argument("rest", nargs=argparse.REMAINDER)
    measure = commands.add_parser("bench")
    measure.add_argument("--out", type=Path, default=ROOT / ".build" / "blocking-sweep")
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
        return suites(out, args.packages or list(DEFAULT_PACKAGES), rest)
    return bench(out, rest)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
