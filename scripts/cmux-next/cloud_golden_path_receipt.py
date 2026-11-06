#!/usr/bin/env python3
"""Validate Cloud golden-path receipts without claiming provider success.

Input is a JSON object, a JSON array or JSONL of two record kinds, checked
against an exact schema:

- cmux-platform#915's GoldenPathReceipt (src/server/cloud/GoldenPathProbe.ts):
  exactly version (1), probeId, startedAt, endedAt, outcome ("passed" or
  "failed"), machineId (vm_ + hex), stages and an optional failure. Each stage
  has exactly stage (machine, folder, readiness, lease, auth, chat or
  reconnect), requestId, startedAt, endedAt, ok (bool), an optional value
  object and an optional failure {code, message, retryable, details?}.
- a provider record: exactly {"machineId": "vm_...", "provider_verified": bool}.

Evidence is read only from these keys in a stage's value: chat's session_id
(string) and session_discovered (bool), and reconnect's paused, resumed and
reconnected (bools). A record with any unknown key, alias, wrong type or
missing field is receipt_shape_unsupported and supplies no evidence. A receipt
whose outcome is not "passed", or that carries a receipt-level failure, proves
nothing positive; its failed stages still fail or block.

Every receipt for one machine merges. A pass needs all seven stages ok, ACP
session discovery, pause/resume/reconnect, and provider_verified for that
machine. Output carries only allowlisted values (stage names, ids matching
strict patterns, failure codes, numbers and booleans) and never echoes other
input text.
"""
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from pathlib import Path

SCHEMA = "cmux.cloud-golden-path-receipt/v1"
STAGES = ("machine", "folder", "readiness", "lease", "auth", "chat", "reconnect")
MAX_DEPTH = 32
MAX_LINE_BYTES = 64 * 1024
MAX_FILE_BYTES = 1024 * 1024

_MACHINE_ID = re.compile(r"vm_[0-9a-f]{1,64}")
_PROBE_ID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
_FAILURE_CODE = re.compile(r"[a-z_]+\.[a-z_]+")
_RECEIPT_KEYS = {"version", "probeId", "startedAt", "endedAt", "outcome", "machineId", "stages"}
_STAGE_KEYS = {"stage", "requestId", "startedAt", "endedAt", "ok"}
_FAILURE_KEYS = {"code", "message", "retryable"}
_VALUE_TYPES = {
    "chat": {"session_id": str, "session_discovered": bool},
    "reconnect": {"paused": bool, "resumed": bool, "reconnected": bool},
}

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
    ):
        return False
    if "value" not in value:
        return True
    stage_value = value["value"]
    return isinstance(stage_value, dict) and all(
        type(stage_value[key]) is kind
        for key, kind in _VALUE_TYPES.get(value["stage"], {}).items()
        if key in stage_value
    )

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

    state: dict[str, str] = {}
    stage_ms: dict[str, int] = {}
    failures: list[dict[str, object]] = []
    positive: dict[str, list[dict[str, object]]] = {"chat": [], "reconnect": []}
    negative = False
    reported_failure = False

    def mark(stage: str, code: object) -> None:
        nonlocal reported_failure
        if isinstance(code, str) and code.endswith(".not_observable"):
            if state.get(stage) != "failed":
                state[stage] = "not_observable"
        else:
            state[stage] = "failed"
            reported_failure = True

    for record in receipts:
        receipt_failure = record.get("failure")
        # A failed or contradicted receipt proves nothing positive.
        clean = record["outcome"] == "passed" and receipt_failure is None
        if record["outcome"] != "passed" and receipt_failure is None:
            reported_failure = True
        failed_here: set[str] = set()
        for item in record["stages"]:
            name = item["stage"]
            stage_ms[name] = max(stage_ms.get(name, 0), max(0, _time_ms(item["endedAt"]) - _time_ms(item["startedAt"])))
            value = item.get("value", {})
            if any(value.get(key) is False for key in _VALUE_TYPES.get(name, {})):
                negative = True
            if item["ok"] and "failure" not in item:
                if clean:
                    state.setdefault(name, "ok")
                    if name in positive:
                        positive[name].append(value)
                continue
            failure = item.get("failure")
            failures.append(_failure_entry(name, failure, record["probeId"]))
            failed_here.add(name)
            mark(name, failure.get("code") if failure else None)
        if receipt_failure is not None:
            name = receipt_failure["stage"]
            if name not in failed_here:
                failures.append(_failure_entry(name, receipt_failure, record["probeId"]))
            mark(name, receipt_failure["code"])

    stages = {name: state.get(name, "missing") for name in STAGES}
    chat_ok = stages["chat"] == "ok"
    provider_true = bool(machine_id) and any(
        record["provider_verified"] is True and record["machineId"] == machine_id for record in providers
    )
    provider_false = any(record["provider_verified"] is False for record in providers)
    checks = {
        "fresh_cloud_chat_start": chat_ok and all(stages[name] == "ok" for name in ("machine", "folder", "readiness")),
        "acpmux_session_discovery": chat_ok and not negative and any(
            isinstance(value.get("session_id"), str) and value["session_id"].strip() != ""
            and value.get("session_discovered") is True
            for value in positive["chat"]
        ),
        "first_reply": chat_ok,
        "pause_resume_reconnect": stages["reconnect"] == "ok" and not negative and any(
            all(value.get(key) is True for key in ("paused", "resumed", "reconnected"))
            for value in positive["reconnect"]
        ),
        "provider_verified": provider_true,
    }

    if reported_failure or negative:
        blockers.append("receipt_reports_failure")
    blockers.extend(f"stage_failed_{name}" for name in STAGES if stages[name] == "failed")
    blockers.extend(f"stage_not_observable_{name}" for name in STAGES if stages[name] == "not_observable")
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
    except (ValueError, RecursionError):  # UnicodeDecodeError and JSONDecodeError are ValueErrors.
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
