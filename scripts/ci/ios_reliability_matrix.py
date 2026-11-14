#!/usr/bin/env python3
"""The iOS connectivity and reliability matrix: test logs in, one table out.

Reads cmux-next-ios/reliability-matrix/cells.json and the logs of the runs that
hold its cells (cargo test for `rust` cells, xcodebuild/swift test for `ios`
cells), and prints a Markdown table: one row per cell, pass / fail / not run,
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
# Swift Testing (swift test / xcodebuild): `✔ Test name() passed`, `✘ Test name() failed`,
# and XCTest-style `Test case 'Suite/name()' passed|failed`.
SWIFT_RESULT = re.compile(
    r"(?:Test (?:case )?['\"]?(?:[\w.]+/)?(?P<name>\w+)\((?:[^)]*)\)['\"]? (?P<result>passed|failed))"
)
MATRIX_LINE = re.compile(r"MATRIX (\{.*\})\s*$")


def _record(results: dict[str, str], name: str, verdict: str) -> None:
    # A parameterized test reports each argument; any failure fails the cell.
    # Keep the short name too (libtest prints module paths).
    for key in {name, name.rsplit("::", 1)[-1]}:
        if results.get(key) != "fail":
            results[key] = verdict


def parse_rust(log: str) -> dict[str, str]:
    """libtest output, `--nocapture` included: a test's `ok`/`FAILED` can come lines after its
    `test NAME ...` start, so a started test that is not in the `failures:` list passed once its
    binary printed `test result:`."""
    results: dict[str, str] = {}
    started: list[str] = []
    failed: set[str] = set()
    in_failures = False
    for line in log.splitlines():
        match = RUST_START.match(line)
        if match:
            in_failures = False
            name, rest = match["name"], match["rest"].strip()
            if rest.startswith("ok"):
                _record(results, name, "pass")
            elif rest.startswith("FAILED"):
                _record(results, name, "fail")
            elif rest.startswith("ignored"):
                _record(results, name, "skip")
            else:
                started.append(name)
            continue
        if line.strip() == "failures:":
            in_failures = True
            continue
        if in_failures and line.startswith("    ") and line.strip() and " " not in line.strip():
            failed.add(line.strip())
            continue
        if line.startswith("test result:"):
            in_failures = False
            for name in started:
                _record(results, name, "fail" if name in failed else "pass")
            for name in failed:
                _record(results, name, "fail")
            started, failed = [], set()
    # A binary that never finished (crash, timeout): its started tests did not pass.
    for name in started:
        _record(results, name, "fail")
    return results


def parse_swift(log: str) -> dict[str, str]:
    results: dict[str, str] = {}
    for line in log.splitlines():
        match = SWIFT_RESULT.search(line)
        if match:
            _record(results, match["name"], "pass" if match["result"] == "passed" else "fail")
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
            status = results.get(suite, {}).get(test) or results.get(suite, {}).get(test.rsplit("::", 1)[-1]) or "not run"
        rows.append({**cell, "status": status, "numbers": numbers(metrics.get(cell["id"], []))})
    return rows


def table(rows: list[dict]) -> str:
    mark = {"pass": "pass", "fail": "**fail**", "skip": "skipped", "not run": "not run"}
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
