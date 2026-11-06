#!/usr/bin/env python3
"""Validate Cloud golden-path receipts without claiming provider success.

Reads cmux-platform's GoldenPathReceipt (src/server/cloud/GoldenPathProbe.ts:
version 1, probeId, outcome, machineId, stages of machine, folder, readiness,
lease, auth, chat and reconnect) as a JSON object, a JSON array or JSONL. The CLI
row and the platform probe each write one for the same machine, and their stages
merge here. The only other record read is a provider record,
{"machineId": "vm_...", "provider_verified": true}. Anything else blocks as
receipt_shape_unsupported and is never read for evidence.

Fail-closed: a failed stage fails; a missing stage, a `<stage>.not_observable`
failure, missing provider proof or missing ACP session discovery blocks. Success
is exactly True, "ok" or "passed".
"""
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Iterable

SCHEMA = "cmux.cloud-golden-path-receipt/v1"
GOLDEN_PATH_STAGES = ("machine", "folder", "readiness", "lease", "auth", "chat", "reconnect")
_MACHINE_ID = re.compile(r"vm_[a-z0-9]{1,64}")
_MACHINE_KEYS = ("machineId", "machine_id")
_PROVIDER_KEYS = ("provider_verified", "providerVerified")
_DISCOVERY_KEYS = ("discovery", "session_discovery", "session_discovered", "sessionDiscovered", "acp_session")
_EVIDENCE_FLAGS = (
    "ok", "passed", "success", "verified", "found", "discovered", "listed",
    "paused", "resumed", "running", "reconnected", "reply_ok",
)
_TOKEN = re.compile(
    r"(?i)\b(?:cmvm|cmk|crt|crk|cmm|cmj|pck|ssk)_[A-Za-z0-9_-]{8,}"
    r"|\bgh[pousr]_[A-Za-z0-9]{16,}"                      # GitHub tokens
    r"|\bgithub_pat_[A-Za-z0-9_]{16,}"
    r"|\bsk-(?:ant-|proj-)?[A-Za-z0-9_-]{10,}"             # OpenAI / Anthropic keys
    r"|\b(?:sk|rk|pk)_(?:live|test)_[A-Za-z0-9]{10,}"      # Stripe keys
    r"|\bxox[abposr]-[A-Za-z0-9-]{10,}"                   # Slack tokens
    r"|\b(?:AKIA|ASIA)[0-9A-Z]{16}\b"                     # AWS access key ids
    r"|\bglpat-[A-Za-z0-9_-]{16,}"                        # GitLab tokens
    r"|\bAIza[0-9A-Za-z_-]{30,}"                          # Google API keys
    r"|\bnpm_[A-Za-z0-9]{30,}"
    r"|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]+)?"   # JWTs
    r"|\b(?:bearer|basic|token)\s+[A-Za-z0-9._~+/=-]{6,}"
)
# KEY=value, KEY: value and "key": "value" where the key names a credential.
_CREDENTIAL_PAIR = re.compile(
    r"""(?ix)
    (["']?[A-Za-z0-9_.-]*(?:secret|token|password|passwd|credential|private|auth|api[_-]?key)[A-Za-z0-9_.-]*["']?)
    (\s*[:=]\s*)
    ("[^"]*"|'[^']*'|[^\s,;}\]]+)
    """
)

def _clean(value: object, limit: int = 160) -> str:
    text = _TOKEN.sub("[withheld]", " ".join(str(value or "").split()))
    return _CREDENTIAL_PAIR.sub(lambda match: match.group(1) + match.group(2) + "[withheld]", text)[:limit]

def _truthy(value: object) -> bool:
    """Success is exactly True, "ok" or "passed"; anything else is not success."""
    return value is True or (isinstance(value, str) and value in {"ok", "passed"})

def _falsey(value: object) -> bool:
    if value is False:
        return True
    return isinstance(value, str) and value.lower() in {"false", "fail", "failed", "error", "blocked", "timeout", "cancelled"}

def _is_golden_receipt(record: object) -> bool:
    return (
        isinstance(record, dict)
        and record.get("version") == 1
        and isinstance(record.get("stages"), list)
        and all(isinstance(item, dict) and isinstance(item.get("stage"), str) for item in record["stages"])
    )

def _record_machine(value: dict[str, object], inherited: str = "") -> str:
    for key in _MACHINE_KEYS:
        if isinstance(value.get(key), str):
            return value[key]
    return inherited

def _is_provider_record(record: object) -> bool:
    return (
        isinstance(record, dict)
        and any(key in record for key in _PROVIDER_KEYS)
        and bool(_MACHINE_ID.fullmatch(_record_machine(record)))
        and set(record) <= set(_MACHINE_KEYS) | set(_PROVIDER_KEYS)
    )

def _receipt_machine(receipt: dict[str, object]) -> str:
    candidates = [receipt.get("machineId")]
    for item in receipt["stages"]:
        if item.get("stage") in {"machine", "lease"} and isinstance(item.get("value"), dict):
            candidates.append(item["value"].get("machineId"))
    for candidate in candidates:
        if isinstance(candidate, str) and _MACHINE_ID.fullmatch(candidate):
            return candidate
    return ""

def _iso_ms(value: object) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        return int(datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp() * 1000)
    except ValueError:
        return None

def _provider_values(value: object, machine: str) -> Iterable[tuple[str, object]]:
    """(machine the value is about, value) for each provider flag; the nearest machine id wins."""
    if isinstance(value, dict):
        machine = _record_machine(value, machine)
        for key, child in value.items():
            if key in _PROVIDER_KEYS:
                yield machine, child
            yield from _provider_values(child, machine)
    elif isinstance(value, list):
        for child in value:
            yield from _provider_values(child, machine)

def _evidence(value: dict[str, object], keys: tuple[str, ...], state: str | None = None) -> str | None:
    """"ok", "fail" or None (no evidence) for the first of `keys` present in a stage value.

    A nested object needs an explicit positive (a true flag, or `state` equal to the
    expected one); a false flag, a present failure or a different state fails it.
    """
    for key in keys:
        item = value.get(key)
        if item is None:
            continue
        if isinstance(item, dict):
            flags = [item[flag] for flag in _EVIDENCE_FLAGS if flag in item]
            observed = item.get("state")
            if (
                any(not _truthy(flag) for flag in flags)
                or item.get("failure") is not None
                or item.get("error") is not None
                or _falsey(item.get("status"))
                or (state and isinstance(observed, str) and observed.lower() != state)
            ):
                return "fail"
            return "ok" if flags or (state and isinstance(observed, str)) else None
        if _truthy(item):
            return "ok"
        return "fail" if _falsey(item) or item in (0, "") else None
    return None

def _discovery(chat_value: dict[str, object], machine_id: str) -> str | None:
    if not machine_id or _record_machine(chat_value, machine_id) != machine_id:
        return None
    for key in _DISCOVERY_KEYS:
        item = chat_value.get(key)
        if isinstance(item, dict) and _record_machine(item, machine_id) != machine_id:
            return None
    return _evidence(chat_value, _DISCOVERY_KEYS)

def _blocked(blocker: str, **evidence: object) -> dict[str, object]:
    return {
        "schema": SCHEMA,
        "status": "blocked",
        "blockers": [blocker],
        "stages": {},
        "provider_verification": {"observed": False},
        "evidence": evidence,
    }

def normalize(records: list[object]) -> dict[str, object]:
    if not records:
        return _blocked("receipt_empty")
    receipts = [record for record in records if _is_golden_receipt(record)]
    provider_records = [record for record in records if _is_provider_record(record)]
    unsupported = len(records) - len(receipts) - len(provider_records)

    blockers: list[str] = []
    if unsupported:
        blockers.append("receipt_shape_unsupported")
    machine_ids = sorted({_receipt_machine(item) for item in receipts} - {""})
    if len(machine_ids) > 1:
        blockers.append("machine_id_mismatch")
    machine_id = machine_ids[0] if len(machine_ids) == 1 else ""
    if any(not _receipt_machine(item) for item in receipts):
        blockers.append("receipt_machine_id_missing")

    reported_failure = False
    stage_state: dict[str, str] = {}
    stage_ms: dict[str, int] = {}
    failures: list[dict[str, object]] = []
    values: dict[str, list[dict[str, object]]] = {}
    for receipt_value in receipts:
        failure = receipt_value.get("failure")
        failure_code = str(failure.get("code", "")) if isinstance(failure, dict) else ""
        if (receipt_value.get("outcome") != "passed" or failure is not None) and not failure_code.endswith(
            ".not_observable"
        ):
            reported_failure = True
        # A receipt not bound to this machine cannot prove a stage, only fail one.
        bound = bool(machine_id) and _receipt_machine(receipt_value) == machine_id
        for item in receipt_value["stages"]:
            name = _clean(item["stage"], 40)
            started, ended = _iso_ms(item.get("startedAt")), _iso_ms(item.get("endedAt"))
            if started is not None and ended is not None and ended >= started:
                stage_ms[name] = max(stage_ms.get(name, 0), ended - started)
            # Any present, non-null failure (even {}, "" or []) fails the stage, whatever `ok` says.
            if item.get("ok") is True and item.get("failure") is None:
                if bound:
                    stage_state.setdefault(name, "ok")
                    if isinstance(item.get("value"), dict):
                        values.setdefault(name, []).append(item["value"])
                continue
            stage_failure = item.get("failure") if isinstance(item.get("failure"), dict) else {}
            code = str(stage_failure.get("code", ""))
            failures.append({
                "stage": name,
                "probe_id": _clean(receipt_value.get("probeId"), 80),
                "code": _clean(code, 80) or None,
                "message": _clean(stage_failure.get("message")) or None,
            })
            if code.endswith(".not_observable") and stage_state.get(name) != "failed":
                stage_state[name] = "not_observable"
            elif not code.endswith(".not_observable"):
                stage_state[name] = "failed"

    golden_stages = {name: stage_state.get(name, "missing") for name in GOLDEN_PATH_STAGES}
    golden_stages.update({name: state for name, state in stage_state.items() if name not in golden_stages})

    chat_values = values.get("chat", [])
    session_ids = [value.get("session_id") or value.get("sessionId") for value in chat_values]
    session_id = next((_clean(item, 100) for item in session_ids if isinstance(item, str) and item.strip()), "")
    discovery = [_discovery(value, machine_id) for value in chat_values]
    reconnect_values = values.get("reconnect", [])
    pause = [_evidence(value, ("pause", "paused"), "paused") for value in reconnect_values]
    resume = [_evidence(value, ("resume", "resumed"), "running") for value in reconnect_values]
    reconnected = [_evidence(value, ("reconnected",)) for value in reconnect_values]
    explicit_failure = "fail" in discovery + pause + resume + reconnected
    chat_ok = golden_stages["chat"] == "ok"
    reconnect_ok = golden_stages["reconnect"] == "ok"
    continuity = {
        "pause_observed": "ok" in pause and "fail" not in pause,
        "resume_observed": "ok" in resume and "fail" not in resume,
        "reconnect_observed": reconnect_ok and "fail" not in reconnected,
        "explicit_failure": explicit_failure,
    }
    stages = {
        "fresh_cloud_chat_start": chat_ok and all(golden_stages[name] == "ok" for name in ("machine", "folder", "readiness")),
        "acpmux_session_discovery": chat_ok and bool(session_id) and "ok" in discovery and "fail" not in discovery,
        "first_reply": chat_ok,
        "pause_resume_reconnect": reconnect_ok and all(
            continuity[key] for key in ("pause_observed", "resume_observed", "reconnect_observed")
        ),
    }

    provider = [pair for record in receipts for pair in _provider_values(record, _receipt_machine(record))]
    provider += [pair for record in provider_records for pair in _provider_values(record, "")]
    provider_true = bool(machine_id) and any(owner == machine_id and _truthy(value) for owner, value in provider)
    provider_false = any(_falsey(value) for _owner, value in provider)
    provider_detail: dict[str, object] = {"observed": provider_true, "verified": provider_true} if provider else {
        "observed": False
    }
    if provider and not provider_true and any(_truthy(value) for _owner, value in provider):
        provider_detail["unbound"] = True
    if provider_false:
        provider_detail["rejected"] = True

    failed_stages = [name for name, state in golden_stages.items() if state == "failed"]
    if reported_failure or failed_stages or explicit_failure:
        blockers.append("receipt_reports_failure")
    blockers.extend(f"stage_failed_{name}" for name in failed_stages)
    blockers.extend(f"stage_not_observable_{name}" for name, state in golden_stages.items() if state == "not_observable")
    blockers.extend(f"missing_stage_{name}" for name, state in golden_stages.items() if state == "missing")
    if provider_false:
        blockers.append("provider_proof_rejected")
    if not machine_id and "machine_id_mismatch" not in blockers:
        blockers.append("missing_machine_id")
    blockers.extend(f"missing_{stage}" for stage, passed in stages.items() if not passed)
    if not provider_true:
        blockers.append("provider_proof_missing")

    if "receipt_reports_failure" in blockers or "provider_proof_rejected" in blockers:
        status = "fail"
    else:
        status = "blocked" if blockers else "pass"
    probe_ids = [_clean(item.get("probeId"), 80) for item in receipts if item.get("probeId")]
    return {
        "schema": SCHEMA,
        "status": status,
        "request_id": probe_ids[0] if probe_ids else None,
        "probe_ids": probe_ids,
        "machine_id": machine_id or None,
        "session_id": session_id or None,
        "stages": stages,
        "golden_path_stages": golden_stages,
        "stage_ms": stage_ms,
        "failures": failures,
        "provider_verification": provider_detail,
        "continuity": continuity,
        "blockers": blockers,
        "evidence": {"record_count": len(records), "receipt_count": len(receipts), "unsupported_count": unsupported},
    }

def load_receipt(path: Path) -> list[object]:
    text = path.read_text(encoding="utf-8")
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        return [json.loads(line) for line in text.splitlines() if line.strip()]
    return value if isinstance(value, list) else [value]

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--check", action="store_true", help="exit 2 unless the normalized receipt passes")
    args = parser.parse_args(argv)
    try:
        normalized = normalize(load_receipt(args.receipt))
    except (UnicodeDecodeError, ValueError) as error:
        normalized = _blocked("receipt_malformed", error=_clean(f"{type(error).__name__}: {error}"))
    except OSError as error:
        normalized = _blocked("receipt_unreadable", error=_clean(f"{type(error).__name__}: {error}"))
    rendered = json.dumps(normalized, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if normalized["status"] == "pass" or not args.check else 2

if __name__ == "__main__":
    raise SystemExit(main())
