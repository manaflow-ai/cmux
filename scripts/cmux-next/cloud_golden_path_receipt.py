#!/usr/bin/env python3
"""Validate Cloud golden-path receipts without claiming provider success.

Input is a JSON object, a JSON array or JSONL of two record kinds, checked
against an exact schema:

- cmux-platform#915's GoldenPathReceipt (src/server/cloud/GoldenPathProbe.ts):
  exactly version (1), probeId, startedAt, endedAt, outcome ("passed" or
  "failed"), machineId (vm_ + lowercase base36), stages and an optional failure. Each stage
  has exactly stage (machine, folder, readiness, lease, auth, chat or
  reconnect), requestId, startedAt, endedAt, ok (bool), an optional value
  object and an optional failure {code, message, retryable, details?}.
- a provider record: exactly {"machineId": "vm_...", "provider_verified": bool}.

Evidence is read only from these keys in a stage's value, the names the CLI row's
writer (cmuxterm-hq tools/cloud-golden-path/golden_path.py, #7402 at 8a0ff8ba) and
the platform runner (cmux-platform#927 scripts/golden-path-probe.ts) write:
- chat: session_id_chars (positive int), session_id_sha256 (12 lowercase hex) and
  session_discovered (bool); reply_ms, discovery_ms and ms are numbers;
- reconnect: pause {state, ms}, resume {state, ms}, link {dropped_while_paused,
  back, back_ms}, second_reply {ok, ms}, reconnected (bool) and ms;
- lease: {machineId, connectionMachine (vm_ ids), generation (int)};
- auth: {allowed (bool)}.
Other value keys are ignored. A record with any unknown top-level or stage key,
alias, wrong type or missing field is receipt_shape_unsupported and supplies no
evidence. An ok lease or auth stage counts only with its evidence: lease for the
receipt's own machine, auth allowed.

A receipt with a non-"passed" outcome or any failure proves nothing positive,
except that a receipt whose only failures are gaps, `<stage>.not_observable` or
`<stage>.no_route` (the CLI row cannot see lease or auth, and has no folder route
on a Nightly without --from-folder), still contributes its ok stages. A gap stage
stays blocked unless another receipt for the same machine has it ok, so a lone
receipt with one never passes. Failed stages always fail.

Every receipt for one machine merges. A pass needs all seven stages ok, ACP
session discovery, pause/resume/reconnect, and provider_verified for that
machine. Output carries only allowlisted values (stage names, ids matching
strict patterns, failure codes, numbers and booleans) and never echoes other
input text.
"""
from __future__ import annotations

import argparse
import json
import math
import re
from datetime import datetime
from pathlib import Path

SCHEMA = "cmux.cloud-golden-path-receipt/v1"
STAGES = ("machine", "folder", "readiness", "lease", "auth", "chat", "reconnect")
MAX_DEPTH = 32
MAX_LINE_BYTES = 64 * 1024
MAX_FILE_BYTES = 1024 * 1024

_MACHINE_ID = re.compile(r"vm_[0-9a-z]{1,64}")
# A UUID (#915), or a slug a known writer names, such as the CLI row's start-matrix-golden-path. Any other slug may
# be a credential (sk-ant-abc123), so it is never echoed.
_PROBE_ID = re.compile(
    r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}"
    r"|(?=[a-z0-9-]{1,64}\Z)(?:start-matrix-|golden-path-)[a-z0-9-]*"
)
_FAILURE_CODE = re.compile(r"[a-z_]+\.[a-z_]+")
_SHA256_PREFIX = re.compile(r"[0-9a-f]{12}")
_RECEIPT_KEYS = {"version", "probeId", "startedAt", "endedAt", "outcome", "machineId", "stages"}
_STAGE_KEYS = {"stage", "requestId", "startedAt", "endedAt", "ok"}
_FAILURE_KEYS = {"code", "message", "retryable"}
MAX_NUMBER = 2 ** 53

def _number(value: object) -> bool:
    """A finite int or float with abs at most 2**53; never raises (a huge int cannot become a float)."""
    if type(value) is int:
        return -MAX_NUMBER <= value <= MAX_NUMBER
    if type(value) is float:
        return math.isfinite(value) and abs(value) <= MAX_NUMBER
    return False

def _amount(value: object) -> bool:
    """A duration or a count: a _number that is not negative."""
    return _number(value) and value >= 0

def _whole(value: object) -> bool:
    return type(value) is int and 0 <= value <= MAX_NUMBER

def _flag(value: object) -> bool:
    return type(value) is bool

def _text(value: object) -> bool:
    return isinstance(value, str)

def _machine(value: object) -> bool:
    return isinstance(value, str) and bool(_MACHINE_ID.fullmatch(value))

def _object(rules: dict[str, object]):
    return lambda value: isinstance(value, dict) and _rules_ok(value, rules)

def _rules_ok(value: dict[str, object], rules: dict[str, object]) -> bool:
    """Each of RULES' keys that VALUE carries is well-formed; other keys are ignored, never read."""
    return all(rule(value[key]) for key, rule in rules.items() if key in value)

_VALUE_RULES = {
    "chat": {
        "session_id_chars": lambda value: _whole(value) and value > 0,
        "session_id_sha256": lambda value: isinstance(value, str) and bool(_SHA256_PREFIX.fullmatch(value)),
        "session_discovered": _flag, "reply_ms": _amount, "discovery_ms": _amount, "ms": _amount,
    },
    "reconnect": {
        "pause": _object({"state": _text, "ms": _amount}),
        "resume": _object({"state": _text, "ms": _amount}),
        "link": _object({"dropped_while_paused": _flag, "back": _flag, "back_ms": _amount}),
        "second_reply": _object({"ok": _flag, "ms": _amount}),
        "reconnected": _flag, "ms": _amount,
    },
    "lease": {"machineId": _machine, "connectionMachine": _machine, "generation": _whole},
    "auth": {"allowed": _flag},
}
# Stages an ok record proves only with their evidence (_proof "ok").
_EVIDENCED = ("lease", "auth")

GAP_REASONS = ("not_observable", "no_route")

def _gap(stage: str, code: object) -> str | None:
    """The gap reason when CODE is exactly `<stage>.not_observable` or `<stage>.no_route` for STAGE itself, else
    None: a gap code naming another stage is a real failure."""
    for reason in GAP_REASONS:
        if code == f"{stage}.{reason}":
            return reason
    return None

# The evidence an ok stage must carry: every path, and the value it must hold (PRESENT: any well-formed value, the
# schema checks its type; SAME_MACHINE: the receipt's own machineId). A missing path proves nothing; a path with
# any other value says the opposite and fails.
PRESENT = object()
SAME_MACHINE = object()
REQUIRED_EVIDENCE: dict[str, dict[tuple[str, ...], object]] = {
    "chat": {
        ("session_id_chars",): PRESENT,
        ("session_id_sha256",): PRESENT,
        ("session_discovered",): True,
    },
    "reconnect": {
        ("pause", "state"): "paused",
        ("resume", "state"): "running",
        ("link", "dropped_while_paused"): True,
        ("link", "back"): True,
        ("second_reply", "ok"): True,
        ("reconnected",): True,
    },
    "lease": {("machineId",): SAME_MACHINE, ("connectionMachine",): PRESENT, ("generation",): PRESENT},
    "auth": {("allowed",): True},
}
_MISSING = object()

def _at(value: object, path: tuple[str, ...]) -> object:
    for key in path:
        if not isinstance(value, dict) or key not in value:
            return _MISSING
        value = value[key]
    return value

def _proof(stage: str, value: dict[str, object], machine: str) -> str | None:
    """"ok" when VALUE holds every REQUIRED_EVIDENCE path of STAGE as required, "fail" when any present path holds
    another value, else None (a path is missing)."""
    rules = REQUIRED_EVIDENCE.get(stage)
    if rules is None:
        return None
    missing = False
    for path, want in rules.items():
        found = _at(value, path)
        if found is _MISSING:
            missing = True
        elif want is SAME_MACHINE:
            if found != machine:
                return "fail"
        elif want is not PRESENT and not (type(found) is type(want) and found == want):
            return "fail"
    return None if missing else "ok"

def _depth_ok(value: object) -> bool:
    stack = [(value, 1)]
    while stack:
        item, depth = stack.pop()
        if isinstance(item, (dict, list)):
            if depth > MAX_DEPTH:
                return False
            stack.extend((child, depth + 1) for child in (item.values() if isinstance(item, dict) else item))
    return True

def _keys_ok(value: object, required: set[str], optional: set[str] = set()) -> bool:
    return isinstance(value, dict) and required <= set(value) <= required | optional

def _time_ms(value: object) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)
    except (ValueError, OverflowError, OSError):
        return None

def _failure_ok(value: object, *, receipt_level: bool = False) -> bool:
    required = _FAILURE_KEYS | ({"stage"} if receipt_level else set())
    return (
        _keys_ok(value, required, {"details"})
        and isinstance(value["code"], str)
        and isinstance(value["message"], str)
        and type(value["retryable"]) is bool
        and isinstance(value.get("details", {}), dict)
        and (not receipt_level or value["stage"] in STAGES)
    )

def _stage_ok(value: object) -> bool:
    if not (
        _keys_ok(value, _STAGE_KEYS, {"value", "failure"})
        and value["stage"] in STAGES
        and isinstance(value["requestId"], str)
        and _time_ms(value["startedAt"]) is not None
        and _time_ms(value["endedAt"]) is not None
        and type(value["ok"]) is bool
        and ("failure" not in value or _failure_ok(value["failure"]))
        # ok:true beside a failure, gap or not, is a contradiction; a gap stage is ok:false.
        and not (value["ok"] and "failure" in value)
    ):
        return False
    if "value" not in value:
        return True
    stage_value = value["value"]
    return isinstance(stage_value, dict) and _rules_ok(stage_value, _VALUE_RULES.get(value["stage"], {}))

def _is_receipt(value: object) -> bool:
    return (
        _keys_ok(value, _RECEIPT_KEYS, {"failure"})
        and type(value["version"]) is int
        and value["version"] == 1
        and isinstance(value["probeId"], str)
        and _time_ms(value["startedAt"]) is not None
        and _time_ms(value["endedAt"]) is not None
        and value["outcome"] in ("passed", "failed")
        and isinstance(value["machineId"], str)
        and bool(_MACHINE_ID.fullmatch(value["machineId"]))
        and isinstance(value["stages"], list)
        and all(_stage_ok(item) for item in value["stages"])
        and ("failure" not in value or _failure_ok(value["failure"], receipt_level=True))
        and _depth_ok(value)
    )

def _is_provider(value: object) -> bool:
    return (
        _keys_ok(value, {"machineId", "provider_verified"})
        and isinstance(value["machineId"], str)
        and bool(_MACHINE_ID.fullmatch(value["machineId"]))
        and type(value["provider_verified"]) is bool
    )

def _probe_id(value: object) -> str | None:
    return value if isinstance(value, str) and _PROBE_ID.fullmatch(value) else None

def _failure_entry(stage: str, failure: dict[str, object] | None, probe: object) -> dict[str, object]:
    code = failure.get("code") if failure else None
    message = failure.get("message") if failure else None
    return {
        "stage": stage,
        "code": code if isinstance(code, str) and _FAILURE_CODE.fullmatch(code) else None,
        "probe_id": _probe_id(probe),
        "message_length": len(message) if isinstance(message, str) else 0,
    }

def _blocked(blocker: str) -> dict[str, object]:
    return {"schema": SCHEMA, "status": "blocked", "blockers": [blocker], "evidence": {}}

def normalize(records: list[object]) -> dict[str, object]:
    """The normalized verdict for RECORDS; a value no check can convert blocks as receipt_malformed, never raises."""
    try:
        return _normalize(records)
    except (ValueError, OverflowError, TypeError, RecursionError):
        return _blocked("receipt_malformed")

def _normalize(records: list[object]) -> dict[str, object]:
    if not records:
        return _blocked("receipt_empty")
    receipts = [record for record in records if _is_receipt(record)]
    providers = [record for record in records if _is_provider(record)]
    unsupported = len(records) - len(receipts) - len(providers)

    blockers: list[str] = []
    if unsupported:
        blockers.append("receipt_shape_unsupported")
    machines = {record["machineId"] for record in receipts + providers}
    if len(machines) > 1:
        blockers.append("machine_id_mismatch")
    machine_id = next(iter(machines)) if len(machines) == 1 and receipts else None

    ok_ms: dict[str, int] = {}
    tried_ms: dict[str, int] = {}
    failures: list[dict[str, object]] = []
    ok_by: list[set[str]] = []                    # per receipt: the stages it proves
    gaps: list[tuple[int, str, str]] = []         # (receipt, stage, reason) failed as a gap
    failed: set[str] = set()
    values: dict[str, list[dict[str, object]]] = {"chat": [], "reconnect": []}
    negative = False
    reported_failure = False

    for index, record in enumerate(receipts):
        real_failure = False
        stage_gaps: set[tuple[str, str]] = set()  # (stage, reason) of this receipt's own gap stages
        ok_here: dict[str, list[dict[str, object]]] = {}
        failed_here: set[str] = set()
        for item in record["stages"]:
            name = item["stage"]
            took = max(0, _time_ms(item["endedAt"]) - _time_ms(item["startedAt"]))
            tried_ms[name] = max(tried_ms.get(name, 0), took)
            if item["ok"]:
                ok_ms[name] = max(ok_ms.get(name, 0), took)
                value = item.get("value", {})
                proof = _proof(name, value, record["machineId"])
                if proof == "fail":
                    negative = True
                if name not in _EVIDENCED or proof == "ok":
                    ok_here.setdefault(name, []).append(value)
                continue
            stage_failure = item.get("failure")
            reason = _gap(name, stage_failure.get("code") if stage_failure else None)
            failed_here.add(name)
            failures.append(_failure_entry(name, stage_failure, record["probeId"]))
            if reason:
                gaps.append((index, name, reason))
                stage_gaps.add((name, reason))
            else:
                failed.add(name)
                real_failure = True
        receipt_failure = record.get("failure")
        if receipt_failure is not None:
            name = receipt_failure["stage"]
            if name not in failed_here:
                failures.append(_failure_entry(name, receipt_failure, record["probeId"]))
            # A receipt-level gap must repeat one of this receipt's own gap stage failures exactly.
            if (name, _gap(name, receipt_failure["code"])) not in stage_gaps:
                failed.add(name)
                real_failure = True
        clean = record["outcome"] == "passed" and receipt_failure is None and not failed_here
        gaps_only = bool(failed_here) and not real_failure
        if not (clean or gaps_only):
            # A failed or contradicted receipt proves nothing positive.
            reported_failure = True
            ok_here = {}
        ok_by.append(set(ok_here))
        for name in values:
            values[name].extend(ok_here.get(name, []))

    def state(name: str) -> str:
        if name in failed:
            return "failed"
        proven = any(name in proved for proved in ok_by)
        # A gap is cleared only by another receipt for the machine that has the stage ok.
        if all(any(name in proved for other, proved in enumerate(ok_by) if other != index)
               for index, gap, _reason in gaps if gap == name) and proven:
            return "ok"
        return next((reason for _index, gap, reason in gaps if gap == name), "missing")

    stages = {name: state(name) for name in STAGES}
    # A stage's ms is its ok run's where one counted, else its slowest try.
    stage_ms = {name: ok_ms[name] if stages[name] == "ok" else tried_ms[name] for name in tried_ms}
    chat_ok = stages["chat"] == "ok"
    provider_true = bool(machine_id) and any(
        record["provider_verified"] is True and record["machineId"] == machine_id for record in providers
    )
    provider_false = any(record["provider_verified"] is False for record in providers)
    checks = {
        "fresh_cloud_chat_start": chat_ok and all(stages[name] == "ok" for name in ("machine", "folder", "readiness")),
        "acpmux_session_discovery": chat_ok and not negative and any(
            _proof("chat", value, machine_id) == "ok" for value in values["chat"]
        ),
        "first_reply": chat_ok,
        "pause_resume_reconnect": stages["reconnect"] == "ok" and not negative and any(
            _proof("reconnect", value, machine_id) == "ok" for value in values["reconnect"]
        ),
        "provider_verified": provider_true,
    }

    if reported_failure or negative:
        blockers.append("receipt_reports_failure")
    blockers.extend(f"stage_failed_{name}" for name in STAGES if stages[name] == "failed")
    blockers.extend(f"stage_{stages[name]}_{name}" for name in STAGES if stages[name] in GAP_REASONS)
    blockers.extend(f"missing_stage_{name}" for name in STAGES if stages[name] == "missing")
    if provider_false:
        blockers.append("provider_proof_rejected")
    if not machine_id and "machine_id_mismatch" not in blockers:
        blockers.append("missing_machine_id")
    blockers.extend(f"missing_{name}" for name, passed in checks.items() if not passed and name != "provider_verified")
    if not provider_true:
        blockers.append("provider_proof_missing")

    if "receipt_reports_failure" in blockers or provider_false:
        status = "fail"
    else:
        status = "blocked" if blockers else "pass"
    return {
        "schema": SCHEMA,
        "status": status,
        "machine_id": machine_id,
        "probe_ids": [probe for probe in (_probe_id(record["probeId"]) for record in receipts) if probe],
        "golden_path_stages": stages,
        "stage_ms": stage_ms,
        "checks": checks,
        "failures": failures,
        "blockers": blockers,
        "evidence": {
            "record_count": len(records),
            "receipt_count": len(receipts),
            "provider_record_count": len(providers),
            "unsupported_count": unsupported,
        },
    }

def load_receipt(path: Path) -> list[object]:
    """Records from a receipt file; ValueError when it is too big, too deep or not JSON."""
    with path.open("rb") as stream:
        data = stream.read(MAX_FILE_BYTES + 1)
    if len(data) > MAX_FILE_BYTES:
        raise ValueError("receipt file too large")
    text = data.decode("utf-8")
    lines = [line for line in text.splitlines() if line.strip()]
    if any(len(line.encode("utf-8")) > MAX_LINE_BYTES for line in lines):
        raise ValueError("receipt line too large")
    try:
        try:
            values = [json.loads(text)]
        except json.JSONDecodeError:
            values = [json.loads(line) for line in lines]
    except RecursionError as error:
        raise ValueError("receipt nested too deeply") from error
    if not all(_depth_ok(value) for value in values):
        raise ValueError("receipt nested too deeply")
    if len(values) == 1 and isinstance(values[0], list):
        return values[0]
    return values

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--check", action="store_true", help="exit 2 unless the normalized receipt passes")
    args = parser.parse_args(argv)
    try:
        normalized = normalize(load_receipt(args.receipt))
    except (ValueError, OverflowError, RecursionError):  # UnicodeDecodeError and JSONDecodeError are ValueErrors.
        normalized = _blocked("receipt_malformed")
    except OSError:
        normalized = _blocked("receipt_unreadable")
    rendered = json.dumps(normalized, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if normalized["status"] == "pass" or not args.check else 2

if __name__ == "__main__":
    raise SystemExit(main())
