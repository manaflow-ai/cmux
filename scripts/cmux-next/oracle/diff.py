#!/usr/bin/env python3
"""Compare two oracle runs and report the first divergence of each case.

Usage:
  diff.py A_DIR B_DIR [--out divergence.json] [--expected FILE ...] [--case GLOB ...]
                      [--host-policy same-host|same-arch-any-os] [--arm-pointer POINTER ...]
  diff.py --selftest

A run directory holds the two files the runner writes:

  receipt.json       {"runId", "sha", "host": {"name", "os", "osVersion", "arch", "display"},
                      "cases": {"<suite>/<case>": {"result": "Pass|Failure|Crash|Timeout|Skip|Slow|Flaky",
                                                    "host"?: {...}}}}
  checkpoints.jsonl  one line per checkpoint, snapshots already canonical (normalize.py):
                     {"case", "step", "index", "checkpoint": "before|turn|settled",
                      "snapshot": {...}, "sha256"?: "<canonical hash>"}

Canonical JSON holds finite numbers only: NaN, Infinity or an overflowing float is bad input, because
NaN != NaN would report a snapshot as divergent with itself.

A is the base (or the old arm), B is the head (or the new arm). By default (`same-host`) the two runs
must come from the same host, OS version and display (plans/cmux-next/chrome-parity/p15-oracle.md
section 3F.1, task p15-oracle-008); otherwise the run is refused with `host-mismatch` and exit 3,
because timing, platform and layout values would differ for reasons that are not the change. The
display is the runner's description of the main display (oracle.py host_info: points, pixels,
refresh and the display count; "none" on a host with no display), since window frames, the
windows facet and the backing scale follow it. A field one side did not record is refused too:
same host must be proved, so a receipt written before a field existed does not compare. This is the CQ rule of comparing "(with patch)"
and "(without patch)" under the same config (chromium/src base/test/launcher/test_launcher.cc and
the recipe's retry-without-patch step). Platform parity (3F.4, task p15-oracle-114) passes
`--host-policy same-arch-any-os`, which requires only the same arch; divergence.json records the
policy.

A case is a deterministic step script, so a step is identified by its index: checkpoint (index,
checkpoint) of A is compared with the same of B, and a different step name at one index (an
inserted, removed or reordered step) is a divergence at pointer `/step`. A step name may repeat.
For each case the report keeps only the first divergence: the earliest (index, checkpoint), and
inside it the first differing JSON pointer of a sorted-key walk, with the A and B values there.
Later differences are only counted, because they usually follow from the first one (Blink's
web_tests report the first text-diff hunk the same way). A flaky case is never compared. `Slow` is
an expectation modifier (5x settleMaxMs, section 3E), so a Slow result compares equal to Pass. When
one side is Skip, the result change is the only divergence reported.

`--expected FILE` loads expected differences: either a refactor-switch registry file
(plans/cmux-next/refactor-switches/<name>.json, key `expected_differences`) or a bare JSON list.
This is the FlagExpectations analog of `run_web_tests.py --flag-specific`
(third_party/blink/web_tests/FlagExpectations/). Each entry is
  {"pointer": "/json/pointer", "reason": "...", "case"?: glob, "step"?: glob,
   "checkpoint"?: "before|turn|settled", "task"?: "p15-oracle-NNN"}
A difference at or under `pointer` in a matching case and step is labeled explained with its
reason; it does not count as a divergence.

`--arm-pointer POINTER` (repeatable; `oracle.py diff --switch`, task p15-oracle-111) names a
snapshot value that reads back the refactor switch arm under test, such as
/facets/switches/arms/<key>. A and B are the old and new arm of one build, so that value must
differ wherever both snapshots of a compared checkpoint have it: there the difference is the arm
under test, counted under `readback`, not a divergence. If any such checkpoint holds the same
value on both sides, the arms were not both applied and nothing the run shows is evidence: the
comparison is refused with `arms-read-back-same` and exit 5. A value only one side has is an
ordinary divergence. A flaky case is not checked, as it is not compared.

Exit codes: 0 no unexplained divergence, 1 divergences, 2 bad input (including no cases to
compare), 3 host-mismatch, 4 internal error, 5 arms-read-back-same. Every exit writes --out with
its verdict (pass, divergent, host-mismatch, bad-input, internal-error, arms-read-back-same), so
a reused out path never holds an older run's result. Stdlib only; safe under `python3 -I`.
"""

from __future__ import annotations

import argparse
import contextlib
import fnmatch
import glob
import io
import json
import math
import os
import secrets
import shlex
import sys
import tempfile
import traceback
import unittest
import unittest.mock
from dataclasses import dataclass, field
from typing import Any, Iterator

SCHEMA = "oracle-divergence-v1"
CHECKPOINT_ORDER = {"before": 0, "turn": 1, "settled": 2}
RESULTS = {"Pass", "Failure", "Crash", "Timeout", "Skip", "Slow", "Flaky"}
HOST_KEYS = ("name", "os", "osVersion", "arch", "display")
RULE_KEYS = {"pointer", "reason", "case", "step", "checkpoint", "task"}
EXPLAINED_SAMPLES_PER_RULE = 3
DEFAULT_HOST_POLICY = "same-host"
HOST_POLICIES = {"same-host": HOST_KEYS, "same-arch-any-os": ("arch",)}

EXIT_OK = 0
EXIT_DIVERGENT = 1
EXIT_BAD_INPUT = 2
EXIT_HOST_MISMATCH = 3
EXIT_INTERNAL_ERROR = 4
EXIT_ARMS_SAME = 5
READBACK_SAMPLES = 20


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
    def key(self) -> tuple[int, int]:
        """Identity and order of a checkpoint in its case: (step index, checkpoint order)."""
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


def _decode(text: str, where: str) -> Any:
    """Parse one JSON document; refuse NaN, Infinity and floats that overflow to infinity."""

    def reject_constant(name: str) -> Any:
        raise InputError(f"{where}: {name} is not canonical JSON (finite numbers only)")

    def finite_float(literal: str) -> float:
        value = float(literal)
        if not math.isfinite(value):
            raise InputError(f"{where}: {literal} is not a finite number")
        return value

    try:
        return json.loads(text, parse_constant=reject_constant, parse_float=finite_float)
    except json.JSONDecodeError as exc:
        raise InputError(f"{where}: invalid JSON: {exc}") from exc
    except RecursionError as exc:
        raise InputError(f"{where}: JSON is nested too deeply") from exc


def _load_json(path: str) -> Any:
    try:
        with open(path, encoding="utf-8") as handle:
            text = handle.read()
    except FileNotFoundError as exc:
        raise InputError(f"{path}: not found") from exc
    except (OSError, UnicodeDecodeError) as exc:
        raise InputError(f"{path}: cannot read: {exc}") from exc
    return _decode(text, path)


def _check_host(value: Any, where: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        raise InputError(f"{where}: host must be an object")
    return value


def load_run(path: str) -> Run:
    if not os.path.isdir(path):
        raise InputError(f"{path}: not a run directory")
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
    seen: set[tuple[str, int, str]] = set()
    step_names: dict[tuple[str, int], str] = {}
    try:
        with open(checkpoints_path, encoding="utf-8") as handle:
            for number, text in enumerate(handle, start=1):
                if not text.strip():
                    continue
                where = f"{checkpoints_path}:{number}"
                point = _parse_checkpoint(_decode(text, where), where, number)
                identity = (point.case, point.index, point.checkpoint)
                if identity in seen:
                    raise InputError(f"{where}: duplicate checkpoint {point.case} index {point.index} {point.checkpoint}")
                seen.add(identity)
                named = step_names.setdefault((point.case, point.index), point.step)
                if named != point.step:
                    raise InputError(f"{where}: {point.case} index {point.index} is step {named!r} and {point.step!r}")
                run.checkpoints.setdefault(point.case, []).append(point)
    except FileNotFoundError as exc:
        raise InputError(f"{checkpoints_path}: not found") from exc
    except (OSError, UnicodeDecodeError) as exc:
        raise InputError(f"{checkpoints_path}: cannot read: {exc}") from exc
    for points in run.checkpoints.values():
        points.sort(key=lambda point: point.key)
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


def _object_children(pointer: str, a: dict[str, Any], b: dict[str, Any]) -> Iterator[tuple[str, Any, Any]]:
    for key in sorted(set(a) | set(b)):
        yield f"{pointer}/{_escape(key)}", a.get(key, MISSING), b.get(key, MISSING)


def _array_children(pointer: str, a: list[Any], b: list[Any]) -> Iterator[tuple[str, Any, Any]]:
    for position in range(max(len(a), len(b))):
        left = a[position] if position < len(a) else MISSING
        right = b[position] if position < len(b) else MISSING
        yield f"{pointer}/{position}", left, right


def iter_differences(a: Any, b: Any, pointer: str = "") -> Iterator[tuple[str, Any, Any]]:
    """Yield (pointer, a, b) for each differing leaf, in sorted-key, index order.

    Values are already canonical (normalize.py rounds floats and sorts set-arrays), so equality is
    exact, except that a bool never equals a number (Python's True == 1). The walk keeps its own
    stack, so depth is bounded by memory, not by the interpreter's recursion limit.
    """
    stack: list[Iterator[tuple[str, Any, Any]]] = [iter([(pointer, a, b)])]
    while stack:
        item = next(stack[-1], None)
        if item is None:
            stack.pop()
            continue
        path, left, right = item
        if left is MISSING or right is MISSING:
            yield path, left, right
            continue
        kind = _kind(left)
        if kind != _kind(right):
            yield path, left, right
        elif kind == "object":
            stack.append(_object_children(path, left, right))
        elif kind == "array":
            stack.append(_array_children(path, left, right))
        elif left != right:
            yield path, left, right


def _unescape(token: str) -> str:
    return token.replace("~1", "/").replace("~0", "~")


def resolve_pointer(value: Any, pointer: str) -> Any:
    """The value at an RFC 6901 pointer, or MISSING."""
    if pointer == "":
        return value
    for token in pointer[1:].split("/"):
        token = _unescape(token)
        if isinstance(value, dict):
            value = value.get(token, MISSING)
        elif isinstance(value, list) and token.isdigit() and int(token) < len(value):
            value = value[int(token)]
        else:
            return MISSING
        if value is MISSING:
            return MISSING
    return value


def _under(pointer: str, scope: str) -> bool:
    return pointer == scope or pointer.startswith(scope + "/")


def check_arm_pointer(pointer: str) -> str:
    if not pointer.startswith("/"):
        raise InputError(f"--arm-pointer {pointer!r}: an arm readback is a JSON pointer below the root ('/...')")
    return pointer


def _json_value(value: Any) -> Any:
    return None if value is MISSING else value


def _difference_kind(a: Any, b: Any) -> str:
    if a is MISSING:
        return "missing-in-a"
    if b is MISSING:
        return "missing-in-b"
    return "value"


def host_mismatch(a: dict[str, Any] | None, b: dict[str, Any] | None, keys: tuple[str, ...] = HOST_KEYS) -> list[str]:
    """Return the host fields that differ or are unknown. Unknown is refused: same host must be proved."""
    if a is None or b is None:
        return ["host (not recorded)"]
    problems = []
    for key in keys:
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


def _divergence(step: str, index: int, checkpoint: str | None, pointer: str, kind: str, a: Any, b: Any, lines: dict[str, int | None]) -> dict[str, Any]:
    return {
        "step": step,
        "index": index,
        "checkpoint": checkpoint,
        "pointer": pointer,
        "kind": kind,
        "a": _json_value(a),
        "b": _json_value(b),
        "lines": lines,
    }


def _result_divergence(result_a: str | None, result_b: str | None) -> dict[str, Any]:
    return {
        "step": None,
        "index": None,
        "checkpoint": None,
        "pointer": "/result",
        "kind": "result",
        "a": result_a,
        "b": result_b,
        "lines": {"a": None, "b": None},
    }


def _outcome(result: str | None) -> str | None:
    """The outcome a result stands for: Slow is an expectation modifier (3E), its outcome is Pass."""
    return "Pass" if result == "Slow" else result


def compare_case(case: str, a: Run, b: Run, rules: list[Rule], arm_pointers: tuple[str, ...] = ()) -> CaseReport:
    result_a, result_b = a.results.get(case), b.results.get(case)
    report = CaseReport(case, "equal", result_a, result_b)
    if "Flaky" in (result_a, result_b):
        report.status = "flaky"
        return report
    if result_a == "Skip" and result_b == "Skip":
        report.status = "skipped"
        return report
    if "Skip" in (result_a, result_b):
        # A skipped arm recorded no checkpoints; its missing snapshots only restate the skip.
        report.status = "divergent"
        report.divergent_pointers = 1
        report.first = _result_divergence(result_a, result_b)
        return report

    points_a = {point.key: point for point in a.checkpoints.get(case, [])}
    points_b = {point.key: point for point in b.checkpoints.get(case, [])}
    steps_a = {point.index: point.step for point in points_a.values()}
    steps_b = {point.index: point.step for point in points_b.values()}
    rules = [rule for rule in rules if fnmatch.fnmatchcase(case, rule.case)]
    compared_steps: set[int] = set()
    for key in sorted(set(points_a) | set(points_b)):
        index, _ = key
        left, right = points_a.get(key), points_b.get(key)
        anchor = left or right
        checkpoint = anchor.checkpoint
        lines = {"a": left.line if left else None, "b": right.line if right else None}
        divergent_here = 0
        if index not in compared_steps:
            compared_steps.add(index)
            name_a, name_b = steps_a.get(index), steps_b.get(index)
            if name_a is not None and name_b is not None and name_a != name_b:
                # An inserted, removed or reordered step: the runs stop being the same script here.
                divergent_here += 1
                if report.first is None:
                    report.first = _divergence(name_b, index, None, "/step", "step", name_a, name_b, lines)
        if not (left is not None and right is not None and left.sha256 and left.sha256 == right.sha256):
            names = [point.step for point in (left, right) if point is not None]
            snap_a = left.snapshot if left is not None else MISSING
            snap_b = right.snapshot if right is not None else MISSING
            for pointer, value_a, value_b in iter_differences(snap_a, snap_b):
                if value_a is not MISSING and value_b is not MISSING and any(_under(pointer, p) for p in arm_pointers):
                    # The arm under test; readback_check() proved the two sides differ here.
                    continue
                rule = next(
                    (rule for rule in rules if all(rule.covers(case, name, checkpoint, pointer) for name in names)),
                    None,
                )
                if rule is not None:
                    _note_explained(report, rule, anchor.step, checkpoint, pointer)
                    continue
                divergent_here += 1
                if report.first is None:
                    report.first = _divergence(
                        anchor.step, index, checkpoint, pointer, _difference_kind(value_a, value_b), value_a, value_b, lines
                    )
        if divergent_here:
            report.divergent_checkpoints += 1
            report.divergent_pointers += divergent_here

    if _outcome(result_a) != _outcome(result_b):
        # Same snapshots but a different outcome (a crash after the last checkpoint, a timeout on
        # a settle that still recorded) is a divergence of its own.
        report.divergent_pointers += 1
        if report.first is None:
            report.first = _result_divergence(result_a, result_b)
    if report.first is not None:
        report.status = "divergent"
    elif report.explained:
        report.status = "explained"
    return report


def readback_check(cases: list[str], a: Run, b: Run, arm_pointers: tuple[str, ...]) -> dict[str, Any]:
    """Each compared checkpoint that both sides read the arm back in must show two different arms."""
    same: list[dict[str, Any]] = []
    same_count = differs = 0
    for case in cases:
        results = (a.results.get(case), b.results.get(case))
        if "Flaky" in results or "Skip" in results:
            continue
        points_b = {point.key: point for point in b.checkpoints.get(case, [])}
        for left in a.checkpoints.get(case, []):
            right = points_b.get(left.key)
            if right is None:
                continue
            for pointer in arm_pointers:
                value_a, value_b = resolve_pointer(left.snapshot, pointer), resolve_pointer(right.snapshot, pointer)
                if value_a is MISSING or value_b is MISSING:
                    continue
                if _kind(value_a) == _kind(value_b) and value_a == value_b:
                    same_count += 1
                    if len(same) < READBACK_SAMPLES:
                        same.append({"case": case, "step": left.step, "index": left.index, "checkpoint": left.checkpoint,
                                     "pointer": pointer, "value": value_a, "lines": {"a": left.line, "b": right.line}})
                else:
                    differs += 1
    return {"pointers": list(arm_pointers), "differs": differs, "sameCount": same_count, "same": same}


def _replay_command(case: str, a: Run, b: Run, rules: list[Rule], host_policy: str, arm_pointers: tuple[str, ...] = ()) -> str:
    """The command that reproduces this finding: same runs, same expectations, exactly this case."""
    parts = ["python3", "-I", "scripts/cmux-next/oracle/diff.py", a.path, b.path]
    for source in dict.fromkeys(rule.source for rule in rules):
        parts += ["--expected", source]
    if host_policy != DEFAULT_HOST_POLICY:
        parts += ["--host-policy", host_policy]
    for pointer in arm_pointers:
        parts += ["--arm-pointer", pointer]
    parts += ["--case", glob.escape(case)]
    return shlex.join(parts)


def _finding(report: CaseReport, a: Run, b: Run, replay: str) -> dict[str, Any]:
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
        "replay": replay,
        "confidence": "unconfirmed",
        "checkpoint": first.get("checkpoint"),
        "pointer": first.get("pointer"),
        "a": first.get("a"),
        "b": first.get("b"),
        "count": {"checkpoints": report.divergent_checkpoints, "pointers": report.divergent_pointers},
    }


def _run_header(run: Run) -> dict[str, Any]:
    return {"path": run.path, "runId": run.run_id, "sha": run.sha, "host": run.host}


def diff_runs(
    a: Run,
    b: Run,
    rules: list[Rule],
    case_globs: list[str] | None = None,
    host_policy: str = DEFAULT_HOST_POLICY,
    arm_pointers: list[str] | tuple[str, ...] = (),
) -> tuple[int, dict[str, Any]]:
    """Compare two loaded runs. Raises InputError when nothing is left to compare."""
    if host_policy not in HOST_POLICIES:
        raise InputError(f"host policy {host_policy!r} is not one of {sorted(HOST_POLICIES)}")
    arm_pointers = tuple(dict.fromkeys(check_arm_pointer(pointer) for pointer in arm_pointers))
    host_keys = HOST_POLICIES[host_policy]
    cases = sorted(set(a.results) | set(a.checkpoints) | set(b.results) | set(b.checkpoints))
    if case_globs:
        cases = [case for case in cases if any(fnmatch.fnmatchcase(case, pattern) for pattern in case_globs)]

    mismatched = {}
    for case in cases:
        problems = host_mismatch(a.host_for(case), b.host_for(case), host_keys)
        if problems:
            mismatched[case] = problems
    if not cases:
        problems = host_mismatch(a.host, b.host, host_keys)
        if problems:
            mismatched["*"] = problems
    if mismatched:
        return EXIT_HOST_MISMATCH, {
            "schema": SCHEMA,
            "verdict": "host-mismatch",
            "hostPolicy": host_policy,
            "a": _run_header(a),
            "b": _run_header(b),
            "mismatched": mismatched,
        }
    if not cases:
        scope = f" matching --case {' '.join(case_globs)}" if case_globs else ""
        raise InputError(f"no cases to compare{scope}")

    readback = readback_check(cases, a, b, arm_pointers) if arm_pointers else None
    if readback is not None and readback["sameCount"]:
        return EXIT_ARMS_SAME, {
            "schema": SCHEMA,
            "verdict": "arms-read-back-same",
            "hostPolicy": host_policy,
            "a": _run_header(a),
            "b": _run_header(b),
            "readback": readback,
        }
    reports = [compare_case(case, a, b, rules, arm_pointers) for case in cases]
    summary = {status: 0 for status in ("equal", "explained", "divergent", "flaky", "skipped")}
    for report in reports:
        summary[report.status] += 1
    divergent = [report for report in reports if report.status == "divergent"]
    document = {
        "schema": SCHEMA,
        "verdict": "divergent" if divergent else "pass",
        "hostPolicy": host_policy,
        "a": _run_header(a),
        "b": _run_header(b),
        "summary": {"cases": len(reports), **summary},
        "divergences": [
            _finding(report, a, b, _replay_command(report.case, a, b, rules, host_policy, arm_pointers))
            for report in divergent
        ],
        "cases": [report.to_json() for report in reports],
    }
    if readback is not None:
        document["readback"] = readback
    return (EXIT_DIVERGENT if divergent else EXIT_OK), document


# ---------------------------------------------------------------------------
# CLI


def _write(document: dict[str, Any], out: str | None) -> None:
    """Replace `out` atomically. The temp file is created with the umask's mode, as open() would."""
    if out is None:
        return
    text = json.dumps(document, indent=2, sort_keys=True) + "\n"
    directory = os.path.dirname(os.path.abspath(out))
    os.makedirs(directory, exist_ok=True)
    temp = os.path.join(directory, f".{os.path.basename(out)}.{secrets.token_hex(6)}.tmp")
    descriptor = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o666)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            stream.write(text)
        os.replace(temp, out)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(temp)
        raise


def _failure_document(verdict: str, error: str, a: str | None, b: str | None) -> dict[str, Any]:
    return {"schema": SCHEMA, "verdict": verdict, "error": error, "a": {"path": a}, "b": {"path": b}}


def _print_summary(code: int, document: dict[str, Any]) -> None:
    if code == EXIT_ARMS_SAME:
        readback = document["readback"]
        print(f"arms-read-back-same: {readback['sameCount']} checkpoints show one arm on both sides", file=sys.stderr)
        for item in readback["same"]:
            print(f"  {item['case']} {item['step']} {item['checkpoint']} {item['pointer']}="
                  f"{json.dumps(item['value'], sort_keys=True)}", file=sys.stderr)
        return
    if code == EXIT_HOST_MISMATCH:
        required = ", ".join(HOST_POLICIES[document["hostPolicy"]])
        print(f"host-mismatch ({document['hostPolicy']}): the runs must share {required}", file=sys.stderr)
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
    parser.add_argument(
        "--host-policy",
        choices=sorted(HOST_POLICIES),
        default=DEFAULT_HOST_POLICY,
        help="host fields both runs must share: same-host (default) or same-arch-any-os (platform parity)",
    )
    parser.add_argument(
        "--arm-pointer",
        action="append",
        default=[],
        help="snapshot value that reads back the switch arm: it must differ between A and B (repeatable)",
    )
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
        code, document = diff_runs(run_a, run_b, rules, args.case, args.host_policy, args.arm_pointer)
    except InputError as exc:
        print(f"diff.py: {exc}", file=sys.stderr)
        code, document = EXIT_BAD_INPUT, _failure_document("bad-input", str(exc), args.a, args.b)
    except Exception as exc:  # A bug here must not exit 1, which callers route to owners as a divergence.
        traceback.print_exc()
        code, document = EXIT_INTERNAL_ERROR, _failure_document("internal-error", f"{type(exc).__name__}: {exc}", args.a, args.b)
    try:
        _write(document, args.out)
    except OSError as exc:
        print(f"diff.py: cannot write {args.out}: {exc}", file=sys.stderr)
        with contextlib.suppress(OSError):
            os.unlink(args.out)
        return EXIT_BAD_INPUT
    if code in (EXIT_OK, EXIT_DIVERGENT, EXIT_HOST_MISMATCH, EXIT_ARMS_SAME):
        _print_summary(code, document)
    return code


# ---------------------------------------------------------------------------
# Self test (synthetic runs). Also loaded by selftest.py.

HOST = {"name": "aws-m4pro-5", "os": "macos", "osVersion": "26.1", "arch": "arm64",
        "display": "1920 x 1080 @ 60.00Hz (3840 x 2160 px), 1 display"}


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

    def write_run(
        self,
        name: str,
        cases: dict[str, Any],
        host: dict[str, Any] | None = HOST,
        results: dict[str, str] | None = None,
        case_hosts: dict[str, Any] | None = None,
        reverse_lines: bool = False,
    ) -> str:
        """cases: case -> list of (step, checkpoint, snapshot), index = the step's order of first use,
        or (step, index, checkpoint, snapshot) with an explicit index."""
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
            for point in points:
                if len(point) == 4:
                    step, index, checkpoint, snapshot = point
                else:
                    step, checkpoint, snapshot = point
                    if step not in steps:
                        steps.append(step)
                    index = steps.index(step)
                lines.append(json.dumps({"case": case, "step": step, "index": index, "checkpoint": checkpoint, "snapshot": snapshot}))
        if reverse_lines:
            lines.reverse()
        with open(os.path.join(path, "receipt.json"), "w", encoding="utf-8") as handle:
            json.dump(receipt, handle)
        with open(os.path.join(path, "checkpoints.jsonl"), "w", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + ("\n" if lines else ""))
        return path

    def out_path(self) -> str:
        return os.path.join(self.root.name, f"out-{len(os.listdir(self.root.name))}", "divergence.json")

    def run_quiet(self, argv: list[str]) -> int:
        with contextlib.redirect_stderr(io.StringIO()), contextlib.redirect_stdout(io.StringIO()):
            return main(argv)

    def write_rules(self, rules: Any) -> str:
        path = os.path.join(self.root.name, f"rules-{len(os.listdir(self.root.name))}.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(rules, handle)
        return path

    def run_diff(self, a: str, b: str, *extra: str, out: str | None = None) -> tuple[int, dict[str, Any] | None]:
        out = out or self.out_path()
        code = self.run_quiet([a, b, "--out", out, *extra])
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
        b = self.write_run("b", {"c/x": changed}, reverse_lines=True)
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

    def test_display_mismatch_refused(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})]},
                           host={**HOST, "display": "1600 x 1000 @ 120.00Hz (1600 x 1000 px), 2 displays"})
        code, doc = self.run_diff(a, b)
        self.assertEqual(code, EXIT_HOST_MISMATCH)
        self.assertEqual(len(doc["mismatched"]["c/x"]), 1)
        self.assertTrue(doc["mismatched"]["c/x"][0].startswith("display ("))

    def test_receipt_without_display_refused(self) -> None:
        old = {key: value for key, value in HOST.items() if key != "display"}
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]}, host=old)
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})]})
        code, doc = self.run_diff(a, b)
        self.assertEqual(code, EXIT_HOST_MISMATCH)
        self.assertEqual(doc["mismatched"], {"c/x": ["display (not recorded)"]})
        code, _ = self.run_diff(a, b, "--host-policy", "same-arch-any-os")
        self.assertEqual(code, EXIT_OK)

    def test_paired_shards_on_two_hosts_compare_case_by_case(self) -> None:
        # Shard 0 of both sides ran on one mini, shard 1 of both on another: each case is paired.
        five, six = HOST, {**HOST, "name": "aws-m4pro-6"}
        points = {"c/x": [("s", "settled", {"v": 1})], "c/y": [("s", "settled", {"v": 1})]}
        hosts = {"c/x": five, "c/y": six}
        a = self.write_run("a", points, host=None, case_hosts=hosts)
        b = self.write_run("b", points, host=None, case_hosts=hosts)
        self.assertEqual(self.run_diff(a, b)[0], EXIT_OK)
        crossed = self.write_run("crossed", points, host=None, case_hosts={"c/x": five, "c/y": five})
        code, doc = self.run_diff(a, crossed)
        self.assertEqual(code, EXIT_HOST_MISMATCH)
        self.assertEqual(sorted(doc["mismatched"]), ["c/y"])

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
        code, doc = self.run_diff(a, b)
        self.assertEqual((code, doc["verdict"]), (EXIT_BAD_INPUT, "bad-input"))
        self.assertIn("duplicate checkpoint", doc["error"])
        good = self.write_run("good", {"c/x": [("s", "settled", {"v": 1})]})
        for rules in ([{"pointer": "layout", "reason": "r"}], [{"pointer": "/x"}], [{"pointer": "/x", "reason": "r", "extra": 1}], {"name": "s"}):
            self.assertEqual(self.run_diff(good, b, "--expected", self.write_rules(rules))[0], EXIT_BAD_INPUT)

    def test_unreadable_inputs_exit_2_not_1(self) -> None:
        good = self.write_run("good", {"c/x": [("s", "settled", {"v": 1})]})
        not_a_dir = os.path.join(good, "receipt.json")
        code, doc = self.run_diff(not_a_dir, good)
        self.assertEqual((code, doc["verdict"]), (EXIT_BAD_INPUT, "bad-input"))
        self.assertIn("not a run directory", doc["error"])
        for name in ("checkpoints.jsonl", "receipt.json"):
            broken = self.write_run(f"bytes-{name}", {"c/x": [("s", "settled", {"v": 1})]})
            with open(os.path.join(broken, name), "wb") as handle:
                handle.write(b"\xff\xfe{}\n")
            code, doc = self.run_diff(broken, good)
            self.assertEqual((code, doc["verdict"]), (EXIT_BAD_INPUT, "bad-input"), name)
            self.assertIn("cannot read", doc["error"])

    def test_deep_nesting(self) -> None:
        good = self.write_run("good", {"c/x": [("s", "settled", {"v": 1})]})
        deep = self.write_run("deep", {})
        with open(os.path.join(deep, "checkpoints.jsonl"), "w", encoding="utf-8") as handle:
            nested = "[" * 200_000 + "]" * 200_000
            handle.write(f'{{"case": "c/x", "step": "s", "index": 0, "checkpoint": "settled", "snapshot": {nested}}}\n')
        code, doc = self.run_diff(deep, good)
        self.assertEqual((code, doc["verdict"]), (EXIT_BAD_INPUT, "bad-input"))
        # A loaded snapshot deeper than the recursion limit still walks: the walk keeps its own stack.
        left: Any = 1
        right: Any = 2
        for _ in range(sys.getrecursionlimit() * 3):
            left, right = [left], [right]
        [(pointer, value_a, value_b)] = list(iter_differences(left, right))
        self.assertEqual((pointer.count("/0"), value_a, value_b), (sys.getrecursionlimit() * 3, 1, 2))

    def test_non_finite_numbers_refused(self) -> None:
        good = self.write_run("good", {"c/x": [("s", "settled", {"v": 1})]})
        for literal in ("NaN", "Infinity", "-Infinity", "1e999"):
            run = self.write_run(f"nf-{literal}", {})
            with open(os.path.join(run, "checkpoints.jsonl"), "w", encoding="utf-8") as handle:
                handle.write(f'{{"case": "c/x", "step": "s", "index": 0, "checkpoint": "settled", "snapshot": {{"v": {literal}}}}}\n')
            code, doc = self.run_diff(run, run)
            self.assertEqual((code, doc["verdict"]), (EXIT_BAD_INPUT, "bad-input"), literal)
        receipt = self.write_run("nf-receipt", {"c/x": [("s", "settled", {"v": 1})]})
        with open(os.path.join(receipt, "receipt.json"), "w", encoding="utf-8") as handle:
            handle.write('{"host": {"name": "h", "os": "macos", "osVersion": 1, "arch": NaN}, "cases": {}}')
        self.assertEqual(self.run_diff(receipt, good)[0], EXIT_BAD_INPUT)

    def test_internal_error_exits_4_and_writes_out(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        module = sys.modules[__name__]
        with unittest.mock.patch.object(module, "compare_case", side_effect=RuntimeError("boom")):
            code, doc = self.run_diff(a, a)
        self.assertEqual((code, doc["verdict"]), (EXIT_INTERNAL_ERROR, "internal-error"))
        self.assertIn("boom", doc["error"])

    def test_failed_run_replaces_stale_out(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 2})]})
        out = self.out_path()
        self.assertEqual(self.run_diff(a, b, out=out)[1]["verdict"], "divergent")
        code, doc = self.run_diff(a, os.path.join(self.root.name, "absent"), out=out)
        self.assertEqual((code, doc["verdict"]), (EXIT_BAD_INPUT, "bad-input"))

    def test_write_failure_leaves_no_temp_file(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        parent = os.path.join(self.root.name, "parent")
        out = os.path.join(parent, "divergence.json")
        os.makedirs(os.path.join(out, "occupied"))
        self.assertEqual(self.run_quiet([a, a, "--out", out]), EXIT_BAD_INPUT)
        self.assertEqual(os.listdir(parent), ["divergence.json"])

    def test_out_mode_follows_umask(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        out = self.out_path()
        previous = os.umask(0o022)
        try:
            self.assertEqual(self.run_quiet([a, a, "--out", out]), EXIT_OK)
        finally:
            os.umask(previous)
        self.assertEqual(os.stat(out).st_mode & 0o777, 0o644)

    def test_zero_cases_refused(self) -> None:
        empty_a, empty_b = self.write_run("ea", {}), self.write_run("eb", {})
        code, doc = self.run_diff(empty_a, empty_b)
        self.assertEqual((code, doc["error"]), (EXIT_BAD_INPUT, "no cases to compare"))
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        code, doc = self.run_diff(a, a, "--case", "c/typo*")
        self.assertEqual((code, doc["error"]), (EXIT_BAD_INPUT, "no cases to compare matching --case c/typo*"))

    def test_replay_reproduces_the_finding(self) -> None:
        tricky = "c/x [1] * it's"
        cases_a = {tricky: [("s", "settled", {"early": 1, "late": 1})], "c/x 1 a it's": [("s", "settled", {"v": 1})]}
        cases_b = {tricky: [("s", "settled", {"early": 2, "late": 2})], "c/x 1 a it's": [("s", "settled", {"v": 2})]}
        a, b = self.write_run("a", cases_a), self.write_run("b", cases_b)
        rules = self.write_rules([{"pointer": "/early", "reason": "r"}])
        _, doc = self.run_diff(a, b, "--expected", rules)
        finding = next(item for item in doc["divergences"] if item["journey"] == tricky)
        argv = shlex.split(finding["replay"])
        self.assertEqual(argv[:3], ["python3", "-I", "scripts/cmux-next/oracle/diff.py"])
        self.assertIn(rules, argv)
        _, replayed = self.run_diff(*argv[3:])
        self.assertEqual([item["journey"] for item in replayed["divergences"]], [tricky])
        self.assertEqual(replayed["divergences"][0]["pointer"], "/late")

    def test_slow_is_pass(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})]}, results={"c/x": "Slow"})
        self.assertEqual(self.run_diff(a, b)[0], EXIT_OK)
        crash = self.write_run("crash", {"c/x": [("s", "settled", {"v": 1})]}, results={"c/x": "Crash"})
        self.assertEqual(self.run_diff(b, crash)[0], EXIT_DIVERGENT)

    def test_skip_on_one_side_reports_the_result(self) -> None:
        a = self.write_run("a", {"c/x": [("s", "before", {"v": 1}), ("s", "settled", {"v": 1})]})
        b = self.write_run("b", {"c/x": []}, results={"c/x": "Skip"})
        code, doc = self.run_diff(a, b)
        self.assertEqual(code, EXIT_DIVERGENT)
        [finding] = doc["divergences"]
        self.assertEqual((finding["pointer"], finding["a"], finding["b"]), ("/result", "Pass", "Skip"))
        self.assertEqual(finding["count"], {"checkpoints": 0, "pointers": 1})

    def test_inserted_step(self) -> None:
        a = self.write_run("a", {"c/x": [("s0", "settled", {"v": 0}), ("s1", "settled", {"v": 0})]})
        b = self.write_run("b", {"c/x": [("s0", "settled", {"v": 0}), ("new", "settled", {"v": 1}), ("s1", "settled", {"v": 1})]})
        _, doc = self.run_diff(a, b)
        [finding] = doc["divergences"]
        self.assertEqual((finding["step"], finding["pointer"], finding["a"], finding["b"]), ("new", "/step", "s1", "new"))
        self.assertEqual(doc["cases"][0]["first"]["kind"], "step")

    def test_removed_step(self) -> None:
        a = self.write_run("a", {"c/x": [("s0", "settled", {"v": 0}), ("gone", "settled", {"v": 0}), ("s2", "settled", {"v": 0})]})
        b = self.write_run("b", {"c/x": [("s0", "settled", {"v": 0}), ("s2", "settled", {"v": 0})]})
        _, doc = self.run_diff(a, b)
        [finding] = doc["divergences"]
        self.assertEqual((finding["pointer"], finding["a"], finding["b"]), ("/step", "gone", "s2"))

    def test_reordered_step(self) -> None:
        a = self.write_run("a", {"c/x": [("x", "settled", {"v": 0}), ("y", "settled", {"v": 0})]})
        b = self.write_run("b", {"c/x": [("y", "settled", {"v": 0}), ("x", "settled", {"v": 0})]})
        _, doc = self.run_diff(a, b)
        [finding] = doc["divergences"]
        self.assertEqual((finding["pointer"], finding["a"], finding["b"]), ("/step", "x", "y"))
        self.assertEqual(finding["count"], {"checkpoints": 2, "pointers": 2})

    def test_repeated_step_name(self) -> None:
        a = self.write_run("a", {"c/x": [("split", 0, "settled", {"panes": 2}), ("split", 1, "settled", {"panes": 3})]})
        b = self.write_run("b", {"c/x": [("split", 0, "settled", {"panes": 2}), ("split", 1, "settled", {"panes": 4})]})
        code, doc = self.run_diff(a, b)
        self.assertEqual(code, EXIT_DIVERGENT)
        [finding] = doc["divergences"]
        self.assertEqual((finding["step"], finding["pointer"], finding["b"]), ("split", "/panes", 4))
        self.assertEqual(doc["cases"][0]["first"]["index"], 1)

    def test_one_index_two_step_names_refused(self) -> None:
        a = self.write_run("a", {"c/x": [("s", 0, "before", {}), ("t", 0, "settled", {})]})
        code, doc = self.run_diff(a, a)
        self.assertEqual(code, EXIT_BAD_INPUT)
        self.assertIn("index 0 is step 's' and 't'", doc["error"])

    def test_host_policy_for_platform_parity(self) -> None:
        linux = {"name": "cmux-orchestrator-1", "os": "linux", "osVersion": "7.0", "arch": "arm64", "display": "none"}
        a = self.write_run("a", {"c/x": [("s", "settled", {"v": 1})]})
        b = self.write_run("b", {"c/x": [("s", "settled", {"v": 1})]}, host=linux)
        code, doc = self.run_diff(a, b)
        self.assertEqual((code, doc["hostPolicy"]), (EXIT_HOST_MISMATCH, "same-host"))
        code, doc = self.run_diff(a, b, "--host-policy", "same-arch-any-os")
        self.assertEqual((code, doc["hostPolicy"]), (EXIT_OK, "same-arch-any-os"))
        x86 = self.write_run("x86", {"c/x": [("s", "settled", {"v": 1})]}, host={**linux, "arch": "x86_64"})
        code, doc = self.run_diff(a, x86, "--host-policy", "same-arch-any-os")
        self.assertEqual(code, EXIT_HOST_MISMATCH)
        self.assertEqual(doc["mismatched"], {"c/x": ["arch ('arm64' != 'x86_64')"]})

    ARM = "/facets/switches/arms/browserResize.layerHosting"

    def arm_snapshot(self, arm: Any, value: int = 1) -> dict[str, Any]:
        return {"facets": {"switches": {"arms": {"browserResize.layerHosting": arm}}, "layout": {"v": value}}}

    def test_arm_pointer_differs_and_is_not_a_divergence(self) -> None:
        a = self.write_run("a", {"tabs/x": [("s", "before", self.arm_snapshot("old")), ("s", "settled", self.arm_snapshot("old"))]})
        b = self.write_run("b", {"tabs/x": [("s", "before", self.arm_snapshot("new")), ("s", "settled", self.arm_snapshot("new"))]})
        self.assertEqual(self.run_diff(a, b)[0], EXIT_DIVERGENT)
        code, doc = self.run_diff(a, b, "--arm-pointer", self.ARM)
        self.assertEqual((code, doc["verdict"]), (EXIT_OK, "pass"))
        self.assertEqual(doc["summary"]["equal"], 1)
        self.assertEqual((doc["readback"]["differs"], doc["readback"]["sameCount"]), (2, 0))

    def test_arm_pointer_hides_nothing_else(self) -> None:
        a = self.write_run("a", {"tabs/x": [("s", "settled", self.arm_snapshot("old", 1))]})
        b = self.write_run("b", {"tabs/x": [("s", "settled", self.arm_snapshot("new", 2))]})
        code, doc = self.run_diff(a, b, "--arm-pointer", self.ARM)
        self.assertEqual(code, EXIT_DIVERGENT)
        [finding] = doc["divergences"]
        self.assertEqual(finding["pointer"], "/facets/layout/v")
        self.assertEqual(finding["count"]["pointers"], 1)
        self.assertIn("--arm-pointer", shlex.split(finding["replay"]))

    def test_arms_read_back_same_is_refused(self) -> None:
        a = self.write_run("a", {"tabs/x": [("s", "settled", self.arm_snapshot("old"))],
                                 "tabs/y": [("s", "settled", self.arm_snapshot("old"))]})
        b = self.write_run("b", {"tabs/x": [("s", "settled", self.arm_snapshot("new"))],
                                 "tabs/y": [("s", "settled", self.arm_snapshot("old", 2))]})
        code, doc = self.run_diff(a, b, "--arm-pointer", self.ARM)
        self.assertEqual((code, doc["verdict"]), (EXIT_ARMS_SAME, "arms-read-back-same"))
        self.assertNotIn("cases", doc)
        [same] = doc["readback"]["same"]
        self.assertEqual((same["case"], same["pointer"], same["value"]), ("tabs/y", self.ARM, "old"))

    def test_arm_readback_on_one_side_only_is_a_divergence(self) -> None:
        a = self.write_run("a", {"tabs/x": [("s", "settled", self.arm_snapshot("old"))]})
        b = self.write_run("b", {"tabs/x": [("s", "settled", {"facets": {"switches": {"arms": {}}, "layout": {"v": 1}}})]})
        code, doc = self.run_diff(a, b, "--arm-pointer", self.ARM)
        self.assertEqual(code, EXIT_DIVERGENT)
        self.assertEqual((doc["divergences"][0]["pointer"], doc["cases"][0]["first"]["kind"]), (self.ARM, "missing-in-b"))

    def test_flaky_case_is_not_read_back(self) -> None:
        a = self.write_run("a", {"tabs/x": [("s", "settled", self.arm_snapshot("old"))]}, results={"tabs/x": "Flaky"})
        b = self.write_run("b", {"tabs/x": [("s", "settled", self.arm_snapshot("old"))]})
        code, doc = self.run_diff(a, b, "--arm-pointer", self.ARM)
        self.assertEqual((code, doc["readback"]["sameCount"]), (EXIT_OK, 0))

    def test_arm_pointer_must_be_below_the_root(self) -> None:
        a = self.write_run("a", {"tabs/x": [("s", "settled", self.arm_snapshot("old"))]})
        for pointer in ("", "facets/switches"):
            code, doc = self.run_diff(a, a, "--arm-pointer", pointer)
            self.assertEqual((code, doc["verdict"]), (EXIT_BAD_INPUT, "bad-input"), pointer)

    def test_resolve_pointer(self) -> None:
        value = {"a/b": [{"m~n": 1}], "x": None}
        self.assertEqual(resolve_pointer(value, "/a~1b/0/m~0n"), 1)
        self.assertIsNone(resolve_pointer(value, "/x"))
        for missing in ("/a~1b/1", "/a~1b/z", "/y", "/x/z"):
            self.assertIs(resolve_pointer(value, missing), MISSING, missing)

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
