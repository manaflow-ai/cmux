#!/usr/bin/env python3
"""Compare two oracle runs and report the first divergence of each case.

Usage:
  diff.py A_DIR B_DIR [--out divergence.json] [--expected FILE ...] [--case GLOB ...]
  diff.py --selftest

A run directory holds the two files the runner writes:

  receipt.json       {"runId", "sha", "host": {"name", "os", "osVersion", "arch"},
                      "cases": {"<suite>/<case>": {"result": "Pass|Failure|Crash|Timeout|Skip|Slow|Flaky",
                                                    "host"?: {...}}}}
  checkpoints.jsonl  one line per checkpoint, snapshots already canonical (normalize.py):
                     {"case", "step", "index", "checkpoint": "before|turn|settled",
                      "snapshot": {...}, "sha256"?: "<canonical hash>"}

A is the base (or the old arm), B is the head (or the new arm). The two runs must come from the
same host and OS (plans/cmux-next/chrome-parity/p15-oracle.md section 3F.1); otherwise the run is
refused with `host-mismatch` and exit 3, because timing and platform values would differ for
reasons that are not the change. This is the CQ rule of comparing "(with patch)" and
"(without patch)" under the same config (chromium/src base/test/launcher/test_launcher.cc and the
recipe's retry-without-patch step).

For each case the report keeps only the first divergence: the earliest (step, checkpoint) in step
order, and inside it the first differing JSON pointer of a sorted-key walk, with the A and B values
there. Later differences are only counted, because they usually follow from the first one (Blink's
web_tests report the first text-diff hunk the same way). A flaky case is never compared.

`--expected FILE` loads expected differences: either a refactor-switch registry file
(plans/cmux-next/refactor-switches/<name>.json, key `expected_differences`) or a bare JSON list.
This is the FlagExpectations analog of `run_web_tests.py --flag-specific`
(third_party/blink/web_tests/FlagExpectations/). Each entry is
  {"pointer": "/json/pointer", "reason": "...", "case"?: glob, "step"?: glob,
   "checkpoint"?: "before|turn|settled", "task"?: "p15-oracle-NNN"}
A difference at or under `pointer` in a matching case and step is labeled explained with its
reason; it does not count as a divergence.

Exit codes: 0 no unexplained divergence, 1 divergences, 2 bad input, 3 host-mismatch.
Stdlib only; safe under `python3 -I`.
"""

from __future__ import annotations

import argparse
import fnmatch
import json
import os
import sys
import tempfile
import unittest
from dataclasses import dataclass, field
from typing import Any, Iterator

SCHEMA = "oracle-divergence-v1"
CHECKPOINT_ORDER = {"before": 0, "turn": 1, "settled": 2}
RESULTS = {"Pass", "Failure", "Crash", "Timeout", "Skip", "Slow", "Flaky"}
HOST_KEYS = ("name", "os", "osVersion", "arch")
RULE_KEYS = {"pointer", "reason", "case", "step", "checkpoint", "task"}
EXPLAINED_SAMPLES_PER_RULE = 3

EXIT_OK = 0
EXIT_DIVERGENT = 1
EXIT_BAD_INPUT = 2
EXIT_HOST_MISMATCH = 3


class InputError(Exception):
    """A run directory or an expectations file is malformed."""


class _Missing:
    """A value that one side does not have (absent key, short list, missing checkpoint)."""

    def __repr__(self) -> str:
        return "<missing>"


MISSING = _Missing()


# ---------------------------------------------------------------------------
# Loading


@dataclass
class Checkpoint:
    case: str
    step: str
    index: int
    checkpoint: str
    snapshot: Any
    sha256: str | None
    line: int

    @property
    def key(self) -> tuple[str, str]:
        return (self.step, self.checkpoint)

    @property
    def order(self) -> tuple[int, int]:
        return (self.index, CHECKPOINT_ORDER[self.checkpoint])


@dataclass
class Run:
    path: str
    run_id: str
    sha: str
    host: dict[str, Any] | None
    results: dict[str, str | None]
    case_hosts: dict[str, dict[str, Any]]
    checkpoints: dict[str, list[Checkpoint]] = field(default_factory=dict)

    def host_for(self, case: str) -> dict[str, Any] | None:
        return self.case_hosts.get(case, self.host)


def _load_json(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError as exc:
        raise InputError(f"{path}: not found") from exc
    except json.JSONDecodeError as exc:
        raise InputError(f"{path}: invalid JSON: {exc}") from exc


def _check_host(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InputError(f"{where}: host must be an object")
    return value


def load_run(path: str) -> Run:
    receipt_path = os.path.join(path, "receipt.json")
    receipt = _load_json(receipt_path)
    if not isinstance(receipt, dict):
        raise InputError(f"{receipt_path}: must be an object")
    host = receipt.get("host")
    if host is not None:
        host = _check_host(host, receipt_path)
    cases = receipt.get("cases", {})
    if not isinstance(cases, dict):
        raise InputError(f"{receipt_path}: cases must be an object")
    results: dict[str, str | None] = {}
    case_hosts: dict[str, dict[str, Any]] = {}
    for case, entry in cases.items():
        if not isinstance(entry, dict):
            raise InputError(f"{receipt_path}: cases[{case!r}] must be an object")
        result = entry.get("result")
        if result is not None and result not in RESULTS:
            raise InputError(f"{receipt_path}: cases[{case!r}].result {result!r} is not one of {sorted(RESULTS)}")
        results[case] = result
        if "host" in entry:
            case_hosts[case] = _check_host(entry["host"], f"{receipt_path}: cases[{case!r}]")

    run = Run(
        path=path,
        run_id=str(receipt.get("runId", os.path.basename(os.path.normpath(path)))),
        sha=str(receipt.get("sha", "")),
        host=host,
        results=results,
        case_hosts=case_hosts,
    )
    checkpoints_path = os.path.join(path, "checkpoints.jsonl")
    try:
        handle = open(checkpoints_path, encoding="utf-8")
    except FileNotFoundError as exc:
        raise InputError(f"{checkpoints_path}: not found") from exc
    seen: set[tuple[str, str, str]] = set()
    with handle:
        for number, text in enumerate(handle, start=1):
            if not text.strip():
                continue
            where = f"{checkpoints_path}:{number}"
            try:
                row = json.loads(text)
            except json.JSONDecodeError as exc:
                raise InputError(f"{where}: invalid JSON: {exc}") from exc
            point = _parse_checkpoint(row, where, number)
            identity = (point.case, point.step, point.checkpoint)
            if identity in seen:
                raise InputError(f"{where}: duplicate checkpoint {point.case} {point.step} {point.checkpoint}")
            seen.add(identity)
            run.checkpoints.setdefault(point.case, []).append(point)
    for points in run.checkpoints.values():
        points.sort(key=lambda point: point.order)
    return run


def _parse_checkpoint(row: Any, where: str, number: int) -> Checkpoint:
    if not isinstance(row, dict):
        raise InputError(f"{where}: must be an object")
    for name in ("case", "step", "checkpoint"):
        if not isinstance(row.get(name), str) or not row[name]:
            raise InputError(f"{where}: {name} must be a non-empty string")
    index = row.get("index")
    if not isinstance(index, int) or isinstance(index, bool) or index < 0:
        raise InputError(f"{where}: index must be a non-negative integer")
    if row["checkpoint"] not in CHECKPOINT_ORDER:
        raise InputError(f"{where}: checkpoint {row['checkpoint']!r} is not one of {list(CHECKPOINT_ORDER)}")
    if "snapshot" not in row:
        raise InputError(f"{where}: snapshot is missing")
    sha256 = row.get("sha256")
    if sha256 is not None and not isinstance(sha256, str):
        raise InputError(f"{where}: sha256 must be a string")
    return Checkpoint(row["case"], row["step"], index, row["checkpoint"], row["snapshot"], sha256, number)


# ---------------------------------------------------------------------------
# Expected differences


@dataclass(frozen=True)
class Rule:
    pointer: str
    reason: str
    case: str = "*"
    step: str = "*"
    checkpoint: str | None = None
    task: str | None = None
    source: str = ""

    def covers(self, case: str, step: str, checkpoint: str, pointer: str) -> bool:
        if not fnmatch.fnmatchcase(case, self.case) or not fnmatch.fnmatchcase(step, self.step):
            return False
        if self.checkpoint is not None and self.checkpoint != checkpoint:
            return False
        return pointer == self.pointer or self.pointer == "" or pointer.startswith(self.pointer + "/")

    def label(self) -> dict[str, Any]:
        out: dict[str, Any] = {"pointer": self.pointer, "reason": self.reason, "source": self.source}
        if self.task:
            out["task"] = self.task
        return out


def load_rules(path: str) -> list[Rule]:
    data = _load_json(path)
    if isinstance(data, dict):
        if "expected_differences" not in data:
            raise InputError(f"{path}: no expected_differences key")
        data = data["expected_differences"]
    if not isinstance(data, list):
        raise InputError(f"{path}: expected_differences must be a list")
    rules = []
    for position, entry in enumerate(data):
        where = f"{path}: expected_differences[{position}]"
        if not isinstance(entry, dict):
            raise InputError(f"{where}: must be an object")
        unknown = set(entry) - RULE_KEYS
        if unknown:
            raise InputError(f"{where}: unknown fields {sorted(unknown)}")
        pointer = entry.get("pointer")
        if not isinstance(pointer, str) or (pointer and not pointer.startswith("/")):
            raise InputError(f"{where}: pointer must be a JSON pointer ('' or starting with '/')")
        reason = entry.get("reason")
        if not isinstance(reason, str) or not reason.strip():
            raise InputError(f"{where}: reason must name why the arms differ")
        checkpoint = entry.get("checkpoint")
        if checkpoint is not None and checkpoint not in CHECKPOINT_ORDER:
            raise InputError(f"{where}: checkpoint {checkpoint!r} is not one of {list(CHECKPOINT_ORDER)}")
        for name in ("case", "step", "task"):
            if name in entry and not isinstance(entry[name], str):
                raise InputError(f"{where}: {name} must be a string")
        rules.append(
            Rule(
                pointer=pointer,
                reason=reason,
                case=entry.get("case", "*"),
                step=entry.get("step", "*"),
                checkpoint=checkpoint,
                task=entry.get("task"),
                source=path,
            )
        )
    return rules


# ---------------------------------------------------------------------------
# Comparison


def _escape(token: str) -> str:
    return token.replace("~", "~0").replace("/", "~1")


def _kind(value: Any) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, (int, float)):
        return "number"
    if isinstance(value, str):
        return "string"
    if isinstance(value, list):
        return "array"
    if isinstance(value, dict):
        return "object"
    return type(value).__name__


def iter_differences(a: Any, b: Any, pointer: str = "") -> Iterator[tuple[str, Any, Any]]:
    """Yield (pointer, a, b) for each differing leaf, in sorted-key, index order.

    Values are already canonical (normalize.py rounds floats and sorts set-arrays), so equality is
    exact, except that a bool never equals a number (Python's True == 1).
    """
    if a is MISSING or b is MISSING:
        yield pointer, a, b
        return
    kind = _kind(a)
    if kind != _kind(b):
        yield pointer, a, b
        return
    if kind == "object":
        for key in sorted(set(a) | set(b)):
            yield from iter_differences(a.get(key, MISSING), b.get(key, MISSING), f"{pointer}/{_escape(key)}")
        return
    if kind == "array":
        for position in range(max(len(a), len(b))):
            left = a[position] if position < len(a) else MISSING
            right = b[position] if position < len(b) else MISSING
            yield from iter_differences(left, right, f"{pointer}/{position}")
        return
    if a != b:
        yield pointer, a, b


def _json_value(value: Any) -> Any:
    return None if value is MISSING else value


def _difference_kind(a: Any, b: Any) -> str:
    if a is MISSING:
        return "missing-in-a"
    if b is MISSING:
        return "missing-in-b"
    return "value"


def host_mismatch(a: dict[str, Any] | None, b: dict[str, Any] | None) -> list[str]:
    """Return the host fields that differ or are unknown. Unknown is refused: same host must be proved."""
    if a is None or b is None:
        return ["host (not recorded)"]
    problems = []
    for key in HOST_KEYS:
        left, right = a.get(key), b.get(key)
        if left is None or right is None:
            problems.append(f"{key} (not recorded)")
        elif left != right:
            problems.append(f"{key} ({left!r} != {right!r})")
    return problems


@dataclass
class CaseReport:
    case: str
    status: str  # equal | divergent | explained | flaky | skipped
    result_a: str | None
    result_b: str | None
    first: dict[str, Any] | None = None
    divergent_checkpoints: int = 0
    divergent_pointers: int = 0
    explained: dict[Rule, dict[str, Any]] = field(default_factory=dict)

    def to_json(self) -> dict[str, Any]:
        out: dict[str, Any] = {
            "case": self.case,
            "status": self.status,
            "result": {"a": self.result_a, "b": self.result_b},
            "divergent_checkpoints": self.divergent_checkpoints,
            "divergent_pointers": self.divergent_pointers,
        }
        if self.first is not None:
            out["first"] = self.first
        if self.explained:
            out["explained"] = list(self.explained.values())
        return out


def _note_explained(report: CaseReport, rule: Rule, step: str, checkpoint: str, pointer: str) -> None:
    entry = report.explained.get(rule)
    if entry is None:
        entry = {**rule.label(), "count": 0, "samples": []}
        report.explained[rule] = entry
    entry["count"] += 1
    if len(entry["samples"]) < EXPLAINED_SAMPLES_PER_RULE:
        entry["samples"].append({"step": step, "checkpoint": checkpoint, "pointer": pointer})


def _divergence(step: str, index: int, checkpoint: str, pointer: str, a: Any, b: Any, lines: dict[str, int | None]) -> dict[str, Any]:
    return {
        "step": step,
        "index": index,
        "checkpoint": checkpoint,
        "pointer": pointer,
        "kind": _difference_kind(a, b),
        "a": _json_value(a),
        "b": _json_value(b),
        "lines": lines,
    }


def compare_case(case: str, a: Run, b: Run, rules: list[Rule]) -> CaseReport:
    result_a, result_b = a.results.get(case), b.results.get(case)
    report = CaseReport(case, "equal", result_a, result_b)
    if "Flaky" in (result_a, result_b):
        report.status = "flaky"
        return report
    if result_a == "Skip" and result_b == "Skip":
        report.status = "skipped"
        return report

    points_a = {point.key: point for point in a.checkpoints.get(case, [])}
    points_b = {point.key: point for point in b.checkpoints.get(case, [])}
    ordered = sorted(
        {**points_b, **points_a}.items(),
        key=lambda item: item[1].order,
    )
    rules = [rule for rule in rules if fnmatch.fnmatchcase(case, rule.case)]
    for key, anchor in ordered:
        left, right = points_a.get(key), points_b.get(key)
        step, checkpoint = key
        if left is not None and right is not None and left.sha256 and left.sha256 == right.sha256:
            continue
        snap_a = left.snapshot if left is not None else MISSING
        snap_b = right.snapshot if right is not None else MISSING
        lines = {"a": left.line if left else None, "b": right.line if right else None}
        divergent_here = 0
        for pointer, value_a, value_b in iter_differences(snap_a, snap_b):
            rule = next((rule for rule in rules if rule.covers(case, step, checkpoint, pointer)), None)
            if rule is not None:
                _note_explained(report, rule, step, checkpoint, pointer)
                continue
            divergent_here += 1
            if report.first is None:
                report.first = _divergence(step, anchor.index, checkpoint, pointer, value_a, value_b, lines)
        if divergent_here:
            report.divergent_checkpoints += 1
            report.divergent_pointers += divergent_here

    if result_a != result_b:
        # Same snapshots but a different outcome (a crash after the last checkpoint, a timeout on
        # a settle that still recorded) is a divergence of its own.
        report.divergent_pointers += 1
        if report.first is None:
            report.first = {
                "step": None,
                "index": None,
                "checkpoint": None,
                "pointer": "/result",
                "kind": "result",
                "a": result_a,
                "b": result_b,
                "lines": {"a": None, "b": None},
            }
    if report.first is not None:
        report.status = "divergent"
    elif report.explained:
        report.status = "explained"
    return report


def _finding(report: CaseReport, a: Run, b: Run) -> dict[str, Any]:
    """The ui-workflow-corpus review-finding shape (plans/cmux-next/ui-workflow-corpus.md), extended."""
    first = report.first or {}
    evidence = []
    for side, run in (("a", a), ("b", b)):
        line = first.get("lines", {}).get(side)
        if line is not None:
            evidence.append(f"{os.path.join(run.path, 'checkpoints.jsonl')}#{line}")
    location = " ".join(str(part) for part in (first.get("step"), first.get("checkpoint")) if part) or "result"
    return {
        "journey": report.case,
        "step": first.get("step"),
        "severity": "S2",
        "expected": f"head equals base at {location} {first.get('pointer')}",
        "observed": f"base {json.dumps(first.get('a'), sort_keys=True)} head {json.dumps(first.get('b'), sort_keys=True)}",
        "source": b.sha,
        "environment": b.run_id,
        "evidence": evidence,
        "replay": f"python3 -I scripts/cmux-next/oracle/diff.py {a.path} {b.path} --case {report.case}",
        "confidence": "unconfirmed",
        "checkpoint": first.get("checkpoint"),
        "pointer": first.get("pointer"),
        "a": first.get("a"),
        "b": first.get("b"),
        "count": {"checkpoints": report.divergent_checkpoints, "pointers": report.divergent_pointers},
    }


def _run_header(run: Run) -> dict[str, Any]:
    return {"path": run.path, "runId": run.run_id, "sha": run.sha, "host": run.host}


def diff_runs(a: Run, b: Run, rules: list[Rule], case_globs: list[str] | None = None) -> tuple[int, dict[str, Any]]:
    cases = sorted(set(a.results) | set(a.checkpoints) | set(b.results) | set(b.checkpoints))
    if case_globs:
        cases = [case for case in cases if any(fnmatch.fnmatchcase(case, glob) for glob in case_globs)]

    mismatched = {}
    for case in cases:
        problems = host_mismatch(a.host_for(case), b.host_for(case))
        if problems:
            mismatched[case] = problems
    if not cases:
        problems = host_mismatch(a.host, b.host)
        if problems:
            mismatched["*"] = problems
    if mismatched:
        return EXIT_HOST_MISMATCH, {
            "schema": SCHEMA,
            "verdict": "host-mismatch",
            "a": _run_header(a),
            "b": _run_header(b),
            "mismatched": mismatched,
        }

    reports = [compare_case(case, a, b, rules) for case in cases]
    summary = {status: 0 for status in ("equal", "explained", "divergent", "flaky", "skipped")}
    for report in reports:
        summary[report.status] += 1
    divergent = [report for report in reports if report.status == "divergent"]
    document = {
        "schema": SCHEMA,
        "verdict": "divergent" if divergent else "pass",
        "a": _run_header(a),
        "b": _run_header(b),
        "summary": {"cases": len(reports), **summary},
        "divergences": [_finding(report, a, b) for report in divergent],
        "cases": [report.to_json() for report in reports],
    }
    return (EXIT_DIVERGENT if divergent else EXIT_OK), document


# ---------------------------------------------------------------------------
# CLI


def _write(document: dict[str, Any], out: str | None) -> None:
    text = json.dumps(document, indent=2, sort_keys=True) + "\n"
    if out is None:
        return
    directory = os.path.dirname(os.path.abspath(out))
    os.makedirs(directory, exist_ok=True)
    handle, temp = tempfile.mkstemp(prefix=".divergence-", dir=directory)
    with os.fdopen(handle, "w", encoding="utf-8") as stream:
        stream.write(text)
    os.replace(temp, out)


def _print_summary(code: int, document: dict[str, Any]) -> None:
    if code == EXIT_HOST_MISMATCH:
        print("host-mismatch: the runs must come from the same host and OS", file=sys.stderr)
        for case, problems in sorted(document["mismatched"].items()):
            print(f"  {case}: {', '.join(problems)}", file=sys.stderr)
        return
    summary = document["summary"]
    print(
        f"{document['verdict']}: {summary['cases']} cases, {summary['divergent']} divergent, "
        f"{summary['explained']} explained, {summary['equal']} equal, {summary['flaky']} flaky, "
        f"{summary['skipped']} skipped"
    )
    for item in document["divergences"]:
        print(
            f"  {item['journey']} step={item['step']} checkpoint={item['checkpoint']} pointer={item['pointer']} "
            f"a={json.dumps(item['a'], sort_keys=True)} b={json.dumps(item['b'], sort_keys=True)} "
            f"(+{item['count']['pointers'] - 1} more in {item['count']['checkpoints']} checkpoints)"
        )


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="First divergence per case between two oracle runs.")
    parser.add_argument("a", nargs="?", help="base run directory (receipt.json, checkpoints.jsonl)")
    parser.add_argument("b", nargs="?", help="head run directory")
    parser.add_argument("--out", help="write divergence.json here")
    parser.add_argument("--expected", action="append", default=[], help="expected_differences file (repeatable)")
    parser.add_argument("--case", action="append", default=[], help="only cases matching this glob (repeatable)")
    parser.add_argument("--selftest", action="store_true", help="run the synthetic-run self tests")
    args = parser.parse_args(argv)
    if args.selftest:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(DiffSelfTest)
        return 0 if unittest.TextTestRunner(verbosity=2).run(suite).wasSuccessful() else 1
    if not args.a or not args.b:
        parser.error("A_DIR and B_DIR are required")
    try:
        rules = [rule for path in args.expected for rule in load_rules(path)]
        run_a, run_b = load_run(args.a), load_run(args.b)
    except InputError as exc:
        print(f"diff.py: {exc}", file=sys.stderr)
        return EXIT_BAD_INPUT
    code, document = diff_runs(run_a, run_b, rules, args.case)
    _write(document, args.out)
    _print_summary(code, document)
    return code


# ---------------------------------------------------------------------------
# Self test (synthetic runs). Also loaded by selftest.py.

HOST = {"name": "aws-m4pro-5", "os": "macos", "osVersion": "26.1", "arch": "arm64"}


def _snapshot(**overrides: Any) -> dict[str, Any]:
    base = {
        "topology": {"workspaces": [{"id": "workspace-1", "title": "one", "panes": 1}]},
        "focus": {"pane": "pane-1"},
        "layout": {"ratio": 0.5},
        "flags": {"zoomed": False},
    }
    for path, value in overrides.items():
        target = base
        parts = path.split("__")
        for part in parts[:-1]:
            target = target[part]
        target[parts[-1]] = value
    return base


class DiffSelfTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = tempfile.TemporaryDirectory(prefix="oracle-diff-")
        self.addCleanup(self.root.cleanup)

    def write_run(self, name: str, cases: dict[str, Any], host: dict[str, Any] | None = HOST, results: dict[str, str] | None = None, case_hosts: dict[str, Any] | None = None) -> str:
        """cases: case -> list of (step, checkpoint, snapshot); index is the step's order."""
        path = os.path.join(self.root.name, name)
        os.makedirs(path)
        receipt: dict[str, Any] = {"runId": name, "sha": f"{name}-sha", "cases": {}}
        if host is not None:
            receipt["host"] = host
        lines = []
        for case, points in cases.items():
            entry: dict[str, Any] = {"result": (results or {}).get(case, "Pass")}
            if case_hosts and case in case_hosts:
                entry["host"] = case_hosts[case]
            receipt["cases"][case] = entry
            steps: list[str] = []
            for step, checkpoint, snapshot in points:
                if step not in steps:
                    steps.append(step)
                lines.append(json.dumps({"case": case, "step": step, "index": steps.index(step), "checkpoint": checkpoint, "snapshot": snapshot}))
        with open(os.path.join(path, "receipt.json"), "w", encoding="utf-8") as handle:
            json.dump(receipt, handle)
        with open(os.path.join(path, "checkpoints.jsonl"), "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + ("\n" if lines else ""))
        return path

    def write_rules(self, rules: Any) -> str:
        path = os.path.join(self.root.name, f"rules-{len(os.listdir(self.root.name))}.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(rules, handle)
        return path

    def run_diff(self, a: str, b: str, *extra: str) -> tuple[int, dict[str, Any] | None]:
        out = os.path.join(self.root.name, f"out-{len(os.listdir(self.root.name))}", "divergence.json")
        code = main([a, b, "--out", out, *extra])
        if not os.path.exists(out):
            return code, None
        with open(out, encoding="utf-8") as handle:
            return code, json.load(handle)

    def three_steps(self, settled_title: str = "one", ratio: float = 0.5) -> list[tuple[str, str, Any]]:
        return [
            ("create", "before", _snapshot()),
            ("create", "settled", _snapshot()),
            ("rename", "turn", _snapshot(topology__workspaces=[{"id": "workspace-1", "title": settled_title, "panes": 1}])),
            ("rename", "settled", _snapshot(topology__workspaces=[{"id": "workspace-1", "title": settled_title, "panes": 1}])),
            ("split", "settled", _snapshot(layout__ratio=ratio, topology__workspaces=[{"id": "workspace-1", "title": settled_title, "panes": 2}])),
        ]

    def test_identical_runs_pass(self) -> None:
        a = self.write_run("a", {"daemon-ops/rename": self.three_steps()})
        b = self.write_run("b", {"daemon-ops/rename": self.three_steps()})
        code, doc = self.run_diff(a, b)
        self.assertEqual(code, EXIT_OK)
        self.assertEqual(doc["verdict"], "pass")
        self.assertEqual(doc["summary"]["equal"], 1)
        self.assertEqual(doc["divergences"], [])

    def test_first_divergence_only_with_counts(self) -> None:
        a = self.write_run("a", {"daemon-ops/rename": self.three_steps()})
        b = self.write_run("b", {"daemon-ops/rename": self.three_steps(settled_title="two", ratio=0.6)})
        code, doc = self.run_diff(a, b)
        self.assertEqual(code, EXIT_DIVERGENT)
        [finding] = doc["divergences"]
        self.assertEqual((finding["step"], finding["checkpoint"]), ("rename", "turn"))
        self.assertEqual(finding["pointer"], "/topology/workspaces/0/title")
        self.assertEqual((finding["a"], finding["b"]), ("one", "two"))
        # rename/turn, rename/settled, split/settled; split has the title and the ratio.
        self.assertEqual(finding["count"], {"checkpoints": 3, "pointers": 4})
        self.assertEqual(finding["confidence"], "unconfirmed")
        self.assertTrue(finding["evidence"][0].endswith("checkpoints.jsonl#3"))

    def test_step_order_beats_file_order(self) -> None:
        points = self.three_steps()
        a = self.write_run("a", {"c/x": points})
        changed = self.three_steps(ratio=0.7)
        changed[0] = ("create", "before", _snapshot(focus__pane="pane-2"))
        b = self.write_run("b", {"c/x": list(reversed(changed))})
        _, doc = self.run_diff(a, b)
        [finding] = doc["divergences"]
        self.assertEqual((finding["step"], finding["checkpoint"], finding["pointer"]), ("create", "before", "/focus/pane"))

    def test_sorted_key_walk_picks_first_pointer(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"zeta": 1, "alpha": {"b": 1, "a": 1}})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"zeta": 2, "alpha": {"b": 2, "a": 1}})]})
        _, doc = self.run_diff(a, b)
        self.assertEqual(doc["divergences"][0]["pointer"], "/alpha/b")

    def test_bool_never_equals_number(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": True})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})]})
        code, doc = self.run_diff(a, b)
        self.assertEqual(code, EXIT_DIVERGENT)
        self.assertEqual(doc["divergences"][0]["pointer"], "/v")

    def test_missing_key_list_item_and_checkpoint(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "before", {"k": 1, "l": [1, 2]}), ("t", "settled", {"k": 1})]})
        b = self.write_run("b", {"c/x": [("s", "before", {"l": [1]}), ]})
        _, doc = self.run_diff(a, b)
        [finding] = doc["divergences"]
        self.assertEqual((finding["pointer"], finding["a"], finding["b"]), ("/k", 1, None))
        case = doc["cases"][0]
        self.assertEqual(case["first"]["kind"], "missing-in-b")
        # /k, /l/1 in s/before and the whole missing t/settled checkpoint.
        self.assertEqual((case["divergent_checkpoints"], case["divergent_pointers"]), (2, 3))

    def test_pointer_escaping(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"a/b": {"m~n": 1}})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"a/b": {"m~n": 2}})]})
        _, doc = self.run_diff(a, b)
        self.assertEqual(doc["divergences"][0]["pointer"], "/a~1b/m~0n")

    def test_expected_differences_are_labeled_not_counted(self) -> None:
        a = self.write_run("a", {"daemon-ops/rename": self.three_steps()})
        b = self.write_run("b", {"daemon-ops/rename": self.three_steps(ratio=0.6)})
        registry = self.write_rules({"name": "layer-hosting", "expected_differences": [
            {"pointer": "/layout", "reason": "new arm rounds ratios at commit", "task": "p03-rendering-001"},
        ]})
        code, doc = self.run_diff(a, b, "--expected", registry)
        self.assertEqual(code, EXIT_OK)
        self.assertEqual(doc["summary"]["explained"], 1)
        [explained] = doc["cases"][0]["explained"]
        self.assertEqual(explained["reason"], "new arm rounds ratios at commit")
        self.assertEqual(explained["count"], 1)
        self.assertEqual(explained["samples"], [{"step": "split", "checkpoint": "settled", "pointer": "/layout/ratio"}])

    def test_expected_difference_then_first_unexplained(self) -> None:
        a = self.write_run("a", {"daemon-ops/rename": self.three_steps()})
        b = self.write_run("b", {"daemon-ops/rename": self.three_steps(settled_title="two", ratio=0.6)})
        rules = self.write_rules([{"pointer": "/topology/workspaces/0/title", "step": "rename", "reason": "rename is optimistic now"}])
        code, doc = self.run_diff(a, b, "--expected", rules)
        self.assertEqual(code, EXIT_DIVERGENT)
        [finding] = doc["divergences"]
        # The title at split is not covered (step scope), and in sorted order /layout comes first.
        self.assertEqual((finding["step"], finding["pointer"]), ("split", "/layout/ratio"))
        self.assertEqual(finding["count"], {"checkpoints": 1, "pointers": 2})
        self.assertEqual(doc["cases"][0]["explained"][0]["count"], 2)

    def test_rule_scope_does_not_cover_sibling_prefix(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"layoutCount": 1})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"layoutCount": 2})]})
        rules = self.write_rules([{"pointer": "/layout", "reason": "r"}])
        code, _ = self.run_diff(a, b, "--expected", rules)
        self.assertEqual(code, EXIT_DIVERGENT)

    def test_rule_case_glob(self) -> None:
        a = self.write_run("a", {"tabs/a": [("s", "settled", {"v": 1})], "other/b": [("s", "settled", {"v": 1})]})
        b = self.write_run("b", {"tabs/a": [("s", "settled", {"v": 2})], "other/b": [("s", "settled", {"v": 2})]})
        rules = self.write_rules([{"pointer": "/v", "case": "tabs/*", "reason": "r"}])
        _, doc = self.run_diff(a, b, "--expected", rules)
        self.assertEqual([item["journey"] for item in doc["divergences"]], ["other/b"])

    def test_flaky_is_never_compared(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]}, results={"c/x": "Flaky"})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 2})]})
        code, doc = self.run_diff(a, b)
        self.assertEqual(code, EXIT_OK)
        self.assertEqual(doc["cases"][0]["status"], "flaky")
        self.assertNotIn("first", doc["cases"][0])

    def test_result_only_divergence(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})]}, results={"c/x": "Crash"})
        code, doc = self.run_diff(a, b)
        self.assertEqual(code, EXIT_DIVERGENT)
        finding = doc["divergences"][0]
        self.assertEqual((finding["pointer"], finding["a"], finding["b"]), ("/result", "Pass", "Crash"))

    def test_case_only_in_one_run(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})], "c/y": [("s", "settled", {"v": 1})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})]})
        _, doc = self.run_diff(a, b)
        [finding] = doc["divergences"]
        self.assertEqual((finding["journey"], finding["pointer"], finding["b"]), ("c/y", "", None))

    def test_case_filter(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})], "c/y": [("s", "settled", {"v": 1})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})], "c/y": [("s", "settled", {"v": 2})]})
        code, doc = self.run_diff(a, b, "--case", "c/x")
        self.assertEqual((code, doc["summary"]["cases"]), (EXIT_OK, 1))

    def test_host_mismatch_refused(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})]}, host={**HOST, "name": "aws-m4pro-6"})
        code, doc = self.run_diff(a, b)
        self.assertEqual(code, EXIT_HOST_MISMATCH)
        self.assertEqual(doc["verdict"], "host-mismatch")
        self.assertNotIn("cases", doc)
        self.assertIn("name ('aws-m4pro-5' != 'aws-m4pro-6')", doc["mismatched"]["c/x"])

    def test_os_version_mismatch_refused(self) -> None:
        a = self.write_run("a", {"c/x": []})
        b = self.write_run("b", {"c/x": []}, host={**HOST, "osVersion": "27.0"})
        code, _ = self.run_diff(a, b)
        self.assertEqual(code, EXIT_HOST_MISMATCH)

    def test_unrecorded_host_refused(self) -> None:
        a = self.write_run("a", {}, host=None)
        b = self.write_run("b", {})
        code, doc = self.run_diff(a, b)
        self.assertEqual(code, EXIT_HOST_MISMATCH)
        self.assertEqual(doc["mismatched"], {"*": ["host (not recorded)"]})

    def test_case_level_host_overrides_run_host(self) -> None:
        other = {**HOST, "name": "aws-m4pro-7"}
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]}, case_hosts={"c/x": other})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})]}, host={**HOST, "name": "aws-m4pro-9"}, case_hosts={"c/x": other})
        code, _ = self.run_diff(a, b)
        self.assertEqual(code, EXIT_OK)

    def test_bad_inputs_exit_2(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        with open(os.path.join(a, "checkpoints.jsonl"), "a", encoding="utf-8") as handle:
            handle.write(json.dumps({"case": "c/x", "step": "s", "index": 0, "checkpoint": "settled", "snapshot": {}}) + "\n")
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})]})
        self.assertEqual(self.run_diff(a, b), (EXIT_BAD_INPUT, None))
        good = self.write_run("good", {"c/x": [("s", "settled", {"v": 1})]})
        for rules in ([{"pointer": "layout", "reason": "r"}], [{"pointer": "/x"}], [{"pointer": "/x", "reason": "r", "extra": 1}], {"name": "s"}):
            self.assertEqual(self.run_diff(good, b, "--expected", self.write_rules(rules))[0], EXIT_BAD_INPUT)

    def test_sha256_shortcut(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})]})
        self.assertEqual(self.run_diff(a, b)[0], EXIT_OK)
        run_a, run_b = load_run(a), load_run(b)
        run_a.checkpoints["c/x"][0].sha256 = run_b.checkpoints["c/x"][0].sha256 = "same"
        run_b.checkpoints["c/x"][0].snapshot = {"v": 3}
        self.assertEqual(diff_runs(run_a, run_b, [])[0], EXIT_OK)


if __name__ == "__main__":
    sys.exit(main())
