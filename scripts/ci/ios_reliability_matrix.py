#!/usr/bin/env python3
"""The iOS connectivity and reliability matrix: test logs in, one table out.

Reads cmux-next-ios/reliability-matrix/cells.json and the logs of the runs that
hold its cells (cargo test for `rust` cells, xcodebuild/swift test for `ios`
cells), and prints a Markdown table: one row per cell, pass / fail / crashed / not run,
with the numbers the cell printed (`MATRIX {json}` lines).

Exit status: 1 when a cell with `gate: true` failed or did not run in a suite
that was given a log; 0 otherwise (failing `gate: false` cells are reported,
not gating).

    ios_reliability_matrix.py --rust cargo.log --ios xcodebuild.log [--json out.json]
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

CELLS = Path(__file__).resolve().parents[2] / "cmux-next-ios" / "reliability-matrix" / "cells.json"

# libtest: `test path::name ... ok` / `... FAILED` / `... ignored`, or with --nocapture the
# test's own output after the dots and its result on a later line.
RUST_START = re.compile(r"^test (?P<name>\S+) \.\.\.(?P<rest>.*)$")
# cargo starts each test binary with `     Running tests/x.rs (target/debug/deps/x-0123abcd)`
# (or `   Doc-tests crate`); libtest then prints `running N tests`.
RUST_BINARY = re.compile(r"^\s*(?:Running (?P<source>.*?)(?: \((?P<path>[^)]*)\))?|Doc-tests (?P<doc>\S+))\s*$")
RUST_RUNNING = re.compile(r"^running \d+ tests?$")
# cargo after a binary that died: `process didn't exit successfully: `...` (signal: 6, SIGABRT...)`.
RUST_SIGNAL = re.compile(r"process didn't exit successfully: .*\(signal: \d+")
# Swift Testing (swift test / xcodebuild): `✔ Test name() passed`, `✘ Test name() failed`,
# and xcodebuild's `Test case 'Suite/name()' passed|failed` (also `Suite.name()`), and
# XCTest's `Test Case '-[Module.Suite name]' passed|failed`.
SWIFT_RESULT = re.compile(
    r"Test (?:[Cc]ase )?['\"]?(?:-\[[\w.]+ (?P<objc>\w+)\]|(?:[\w.]+[/.])?(?P<name>\w+)\((?:[^)]*)\))['\"]? "
    r"(?P<result>passed|failed)"
)
SWIFT_STARTED = re.compile(
    r"Test (?:[Cc]ase )?['\"]?(?:-\[[\w.]+ (?P<objc>\w+)\]|(?:[\w.]+[/.])?(?P<name>\w+)\((?:[^)]*)\))['\"]? started"
)
# The test process died: xcodebuild restarts it (`Restarting after unexpected exit, crash, or
# test timeout in Suite/name(); ...`), Swift prints `Fatal error: ...`, swift test says
# `error: Exited with unexpected signal code 11` / `Exited with signal code 6`.
SWIFT_RESTARTED = re.compile(
    r"Restarting after unexpected exit, crash, or test timeout in (?:-\[[\w.]+ (?P<objc>\w+)\]|(?:[\w.]+[/.])?(?P<name>\w+)\()?"
)
# (Swift's runtime `Fatal error:`, capitalized; a compiler's `fatal error:` is a build that
# failed, whose cells read not run.)
SWIFT_CRASH = re.compile(
    r"Fatal error: |Exited with (?:unexpected )?signal code|Test crashed with signal|terminated due to signal|"
    r"\(signal: \d+|[Tt]est runner (?:crashed|exited)|Early unexpected exit"
)
# How a run that finished ends: xcodebuild's `** TEST SUCCEEDED **` / `** TEST FAILED **`,
# Swift Testing's `Test run with N tests ... passed|failed`, XCTest's `Executed N tests`.
SWIFT_SUMMARY = re.compile(r"\*\* TEST (?:SUCCEEDED|FAILED) \*\*|Test run with \d+ tests?|Executed \d+ tests?")
# A run (or a suite) starting: `swift test` prints XCTest's `Executed 0 tests` summary before
# Swift Testing's `◇ Test run started.`, so only a summary after the last of these, and after the
# last test line, ends the log.
SWIFT_RUN_START = re.compile(r"Test run started|Suite [\w.]+ started|Test Suite '[^']*' started")
MATRIX_LINE = re.compile(r"MATRIX (\{.*\})\s*$")


def _record(results: dict[str, str], name: str, verdict: str) -> None:
    # A parameterized test reports each argument; any failure fails the cell.
    # Keep the short name too (libtest prints module paths).
    for key in {name, name.rsplit("::", 1)[-1]}:
        if results.get(key) != "fail":
            results[key] = verdict


def _binary_key(match: re.Match) -> str:
    """The same test binary across cargo runs (debug, then release with --ignored):
    `target/debug/deps/reliability_matrix-0123abcd` -> `reliability_matrix`."""
    if match["doc"]:
        return "doc:" + match["doc"]
    if match["path"]:
        return re.sub(r"-[0-9a-f]{8,}$", "", Path(match["path"]).name)
    return match["source"] or ""


def parse_rust(log: str) -> dict[str, str]:
    """libtest output, `--nocapture` included: a test's `ok`/`FAILED` can come lines after its
    `test NAME ...` start (alone on its line), and otherwise a started test that is not in the
    `failures:` list passed once its binary printed `test result:`.

    A binary that died (a signal, an abort, no `test result:` before the next binary or the end
    of the log) passed nothing it did not print an explicit `ok` for: its started tests, and every
    test the same binary listed in another run (ignored there, say) without an `ok`, read crashed."""
    results: dict[str, str] = {}
    explicit_pass: set[str] = set()
    members: dict[str, set[str]] = {}
    crashed_binaries: set[str] = set()

    binary = ""
    started: list[str] = []
    failed: set[str] = set()
    pending = ""  # the --nocapture test whose result line has not come yet
    finished = False
    seen = False  # this binary started: its `Running` header or `running N tests`
    output = False  # it printed a test line since `running N tests`
    in_failures = False

    def passed(name: str) -> None:
        explicit_pass.update({name, name.rsplit("::", 1)[-1]})
        _record(results, name, "pass")

    def close(signal: bool = False) -> None:
        nonlocal started, failed, pending, finished, seen, output, in_failures
        if seen and (signal or not finished):
            crashed_binaries.add(binary)
            for name in started:
                if name not in explicit_pass:
                    _record(results, name, "crashed")
        started, failed, pending, finished, seen, output, in_failures = [], set(), "", False, False, False, False

    for line in log.splitlines():
        header = RUST_BINARY.match(line)
        if header:
            close()
            binary = _binary_key(header)
            # A binary that dies before its first line (a timeout at startup) still crashed.
            seen = True
            continue
        if RUST_SIGNAL.search(line):
            # cargo reports the dead binary after it ends, before the next one starts.
            if seen:
                close(signal=True)
            else:
                crashed_binaries.add(binary)
            continue
        if RUST_RUNNING.match(line.strip()):
            # A log without cargo's headers: a second `running N tests` starts the next binary.
            if output:
                close()
            seen = True
            continue
        match = RUST_START.match(line)
        if match:
            seen = output = True
            in_failures = False
            pending = ""
            name, rest = match["name"], match["rest"].strip()
            members.setdefault(binary, set()).add(name)
            if rest == "ok" or rest.startswith("ok "):
                passed(name)
            elif rest.startswith("FAILED"):
                _record(results, name, "fail")
            elif rest.startswith("ignored"):
                _record(results, name, "skip")
            else:
                started.append(name)
                pending = name
            continue
        stripped = line.strip()
        if pending and stripped in ("ok", "FAILED"):
            if stripped == "ok":
                passed(pending)
            else:
                _record(results, pending, "fail")
            started.remove(pending)
            pending = ""
            continue
        if stripped == "failures:":
            in_failures = True
            continue
        if in_failures and line.startswith("    ") and stripped and " " not in stripped:
            failed.add(stripped)
            continue
        if line.startswith("test result:"):
            in_failures = False
            for name in started:
                _record(results, name, "fail" if name in failed else "pass")
            for name in failed:
                _record(results, name, "fail")
            started, failed, pending = [], set(), ""
            finished = True
    close()
    for key in crashed_binaries:
        for name in members.get(key, ()):
            if name not in explicit_pass and results.get(name) != "fail":
                _record(results, name, "crashed")
    return results


def parse_swift(log: str) -> dict[str, str]:
    """Swift Testing and XCTest under xcodebuild or swift test. When the test process died (a
    restart after an unexpected exit, a fatal error, a signal, or no run summary at the end), a
    test the log never reported passed reads crashed, not missing: see `crashed`."""
    results: dict[str, str] = {}
    crashed = False
    summary = False
    for line in log.splitlines():
        match = SWIFT_RESULT.search(line)
        if match:
            _record(results, match["name"] or match["objc"], "pass" if match["result"] == "passed" else "fail")
            summary = False
            continue
        match = SWIFT_RESTARTED.search(line)
        if match:
            crashed = True
            summary = False
            name = match["name"] or match["objc"]
            if name and results.get(name) != "pass":
                _record(results, name, "crashed")
            continue
        match = SWIFT_STARTED.search(line)
        if match:
            name = match["name"] or match["objc"]
            results.setdefault(name, "started")
            summary = False
            continue
        if SWIFT_CRASH.search(line):
            crashed = True
        if SWIFT_SUMMARY.search(line):
            summary = True
        elif SWIFT_RUN_START.search(line):
            summary = False
    if log.strip() and not summary:
        crashed = True
    for name, verdict in list(results.items()):
        if verdict == "started":
            results[name] = "crashed" if crashed else "fail"
    if crashed:
        results["*"] = "crashed"
    return results


def parse_metrics(log: str) -> dict[str, list[dict]]:
    metrics: dict[str, list[dict]] = {}
    for line in log.splitlines():
        match = MATRIX_LINE.search(line)
        if not match:
            continue
        try:
            entry = json.loads(match[1])
        except json.JSONDecodeError:
            continue
        metrics.setdefault(entry.get("cell", ""), []).append(entry)
    return metrics


def numbers(entries: list[dict]) -> str:
    parts = []
    for entry in entries:
        fields = []
        for key, value in entry.items():
            if key in ("cell", "variant") or isinstance(value, (dict, list)):
                continue
            if isinstance(value, float):
                value = f"{value:.1f}"
            text = str(value)
            if len(text) > 40:
                text = text[:37] + "..."
            fields.append(f"{key}={text}")
        parts.append(f"{entry.get('variant', '')}: " + ", ".join(fields))
    return "<br>".join(parts)


def build(cells: list[dict], logs: dict[str, str]) -> list[dict]:
    results = {
        "rust": parse_rust(logs.get("rust", "")),
        "ios": parse_swift(logs.get("ios", "")),
    }
    metrics: dict[str, list[dict]] = {}
    for log in logs.values():
        for cell, entries in parse_metrics(log).items():
            metrics.setdefault(cell, []).extend(entries)
    rows = []
    for cell in cells:
        suite = cell["suite"]
        test = cell["test"]
        if suite not in logs:
            status = "not run"
        else:
            found = results.get(suite, {})
            # A suite whose test process died ("*"): a cell it never reported crashed with it.
            status = found.get(test) or found.get(test.rsplit("::", 1)[-1]) or found.get("*") or "not run"
        rows.append({**cell, "status": status, "numbers": numbers(metrics.get(cell["id"], []))})
    return rows


def table(rows: list[dict]) -> str:
    mark = {"pass": "pass", "fail": "**fail**", "crashed": "**crashed**", "skip": "skipped", "not run": "not run"}
    out = [
        "| Axis | Case | Result | Gate | Asserts | Numbers | Test |",
        "| --- | --- | --- | --- | --- | --- | --- |",
    ]
    for row in rows:
        out.append(
            "| {axis} | {case} | {result} | {gate} | {asserts} | {numbers} | `{test}` ({suite}) |".format(
                axis=row["axis"],
                case=row["case"],
                result=mark.get(row["status"], row["status"]),
                gate="yes" if row.get("gate") else "no",
                asserts=row["asserts"],
                numbers=row["numbers"] or "",
                test=row["test"],
                suite=row["suite"],
            )
        )
    counts: dict[str, int] = {}
    for row in rows:
        counts[row["status"]] = counts.get(row["status"], 0) + 1
    out.append("")
    out.append("Cells: " + ", ".join(f"{key} {value}" for key, value in sorted(counts.items())))
    return "\n".join(out)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--rust", type=Path, help="cargo test log (rust cells)")
    parser.add_argument("--ios", type=Path, help="xcodebuild or swift test log (ios cells)")
    parser.add_argument("--cells", type=Path, default=CELLS)
    parser.add_argument("--json", type=Path, help="write the rows as JSON here")
    args = parser.parse_args(argv)
    cells = json.loads(args.cells.read_text())["cells"]
    logs = {}
    for suite, path in (("rust", args.rust), ("ios", args.ios)):
        if path is not None:
            logs[suite] = path.read_text(errors="replace") if path.exists() else ""
    rows = build(cells, logs)
    print(table(rows))
    if args.json:
        args.json.write_text(json.dumps(rows, indent=2) + "\n")
    gated = [row for row in rows if row.get("gate") and row["suite"] in logs and row["status"] != "pass"]
    for row in gated:
        print(f"::error::gating cell {row['id']} ({row['test']}): {row['status']}", file=sys.stderr)
    return 1 if gated else 0


if __name__ == "__main__":
    sys.exit(main())
