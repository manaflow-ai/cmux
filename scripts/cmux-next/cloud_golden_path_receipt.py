#!/usr/bin/env python3
"""Validate the app-side Cloud golden-path receipt without claiming provider success.

The receipt may be a single JSON object, a JSON array, or JSONL emitted by the
cmux Cloud probe and the fleet pause/resume harness. This adapter only reports
pass when the receipt explicitly proves every app-side stage and includes an
explicit provider verification flag. A successful chat reply by itself is
therefore blocked rather than promoted to provider success.
"""
from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Iterable

SCHEMA = "cmux.cloud-golden-path-receipt/v1"
_VM_ID = re.compile(r"\bvm_[0-9a-f]{1,64}\b")
_SECRET = re.compile(
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
    r"|\b(?:api[_-]?key|access[_-]?token|secret|password|passwd)\s*[:=]\s*\S+"
)

def _norm(value: object) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value).lower())

def _clean(value: object, limit: int = 160) -> str:
    text = " ".join(str(value or "").split())
    return _SECRET.sub("[withheld]", text)[:limit]

def _truthy(value: object) -> bool:
    """Success is exactly True, "ok" or "passed"; anything else is not success."""
    return value is True or (isinstance(value, str) and value in {"ok", "passed"})

def _falsey(value: object) -> bool:
    if value is False:
        return True
    if isinstance(value, str):
        return _norm(value) in {"false", "fail", "failed", "error", "blocked", "timeout", "timedout", "cancelled"}
    return False

def _walk(value: object, path: tuple[str, ...] = ()) -> Iterable[tuple[tuple[str, ...], object]]:
    yield path, value
    if isinstance(value, dict):
        for key, child in value.items():
            yield from _walk(child, path + (str(key),))
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from _walk(child, path + (str(index),))

def _dicts(records: list[object]) -> Iterable[dict[str, object]]:
    for record in records:
        for _path, value in _walk(record):
            if isinstance(value, dict):
                yield value

def _field_values(records: list[object], aliases: set[str]) -> list[object]:
    values: list[object] = []
    for record in records:
        for path, value in _walk(record):
            if path and _norm(path[-1]) in aliases:
                values.append(value)
    return values

def _first_text(records: list[object], aliases: set[str]) -> str:
    for value in _field_values(records, aliases):
        if isinstance(value, str) and value.strip():
            return _clean(value)
    return ""

def _first_id(records: list[object], aliases: set[str], pattern: re.Pattern[str] | None = None) -> str:
    for value in _field_values(records, aliases):
        if isinstance(value, str) and value.strip():
            text = _clean(value)
            if not pattern or pattern.fullmatch(text):
                return text
    if pattern:
        for _path, value in (item for record in records for item in _walk(record)):
            if isinstance(value, str):
                match = pattern.search(value)
                if match:
                    return match.group(0)
    return ""

def _statuses(records: list[object]) -> list[str]:
    values: list[str] = []
    for value in _field_values(records, {"status", "outcome", "verdict", "result", "state"}):
        if isinstance(value, str):
            values.append(_norm(value))
    return values

def _entry_name(entry: dict[str, object]) -> str:
    for key in ("stage", "step", "event", "action", "name", "type", "probe"):
        value = entry.get(key)
        if isinstance(value, str):
            return _norm(value)
    return ""

def _entry_state(entry: dict[str, object]) -> str | None:
    """"ok" or "fail" from the entry's own evidence, None when it proves neither.

    A nonzero exit, a false success flag, a failing status or a failure object
    fails the entry; success needs explicit evidence (exit 0, a true flag or an
    ok status). A bare name, or a `started` record, proves nothing.
    """
    failed = False
    succeeded = False
    for key in ("exit", "exit_code", "exitcode", "returncode"):
        value = entry.get(key)
        if isinstance(value, int) and not isinstance(value, bool):
            if value == 0:
                succeeded = True
            else:
                failed = True
    for key in ("ok", "passed", "success", "verified", "ready"):
        if key in entry:
            if _truthy(entry[key]):
                succeeded = True
            else:
                failed = True
    for key in ("outcome", "status", "verdict", "result"):
        value = entry.get(key)
        if isinstance(value, str):
            if _falsey(value):
                failed = True
            elif _truthy(value):
                succeeded = True
    if entry.get("failure") or entry.get("error"):
        failed = True
    if failed:
        return "fail"
    return "ok" if succeeded else None

def _named_state(records: list[object], tokens: tuple[str, ...]) -> str | None:
    """"fail" if any matching named entry failed, else "ok" if one succeeded."""
    states = [
        _entry_state(entry)
        for entry in _dicts(records)
        if _entry_name(entry) and any(token in _entry_name(entry) for token in tokens)
    ]
    if "fail" in states:
        return "fail"
    return "ok" if "ok" in states else None

def _named_failures(records: list[object]) -> bool:
    return any(_entry_name(entry) and _entry_state(entry) == "fail" for entry in _dicts(records))

def _explicit_true(records: list[object], aliases: set[str]) -> bool:
    return any(_truthy(value) for value in _field_values(records, aliases))

def _explicit_false(records: list[object], aliases: set[str]) -> bool:
    return any(_falsey(value) for value in _field_values(records, aliases))

def _continuity(records: list[object]) -> tuple[bool, dict[str, object]]:
    pause_aliases = {"pauselanded", "pauseobserved", "pausecompleted", "paused", "pauseok"}
    resume_aliases = {"resumereachedrunning", "resumeobserved", "resumecompleted", "resumed", "resumeok"}
    reconnect_aliases = {
        "reconnected", "reconnectobserved", "reconnectcompleted", "sessionreconnected",
        "continuityok", "reconnectok",
    }
    pause = _explicit_true(records, pause_aliases)
    resume = _explicit_true(records, resume_aliases)
    reconnect = _explicit_true(records, reconnect_aliases)
    round_values: list[bool] = []
    for entry in _dicts(records):
        rounds = entry.get("rounds")
        if not isinstance(rounds, list) or not rounds:
            continue
        for round_item in rounds:
            if not isinstance(round_item, dict):
                round_values.append(False)
                continue
            nested = [round_item]
            resume_value = round_item.get("resume")
            chat_value = round_item.get("chat")
            resume_observed = _explicit_true(nested, resume_aliases) or (
                isinstance(resume_value, dict) and _truthy(resume_value.get("running"))
            )
            reconnect_observed = _explicit_true(nested, reconnect_aliases) or (
                isinstance(chat_value, dict) and _truthy(chat_value.get("reply_ok"))
            )
            round_values.append(
                _explicit_true(nested, pause_aliases)
                and resume_observed
                and reconnect_observed
            )
    # Every round of every merged record counts: one failed round fails continuity.
    rounds_failed = not all(round_values)
    if round_values and not rounds_failed:
        pause = resume = reconnect = True
    named_failures = _named_state(records, ("pause", "resume", "reconnect", "continuity")) == "fail"
    explicit_failure = (
        _explicit_false(records, pause_aliases | resume_aliases | reconnect_aliases)
        or named_failures
        or rounds_failed
    )
    return (
        pause and resume and reconnect and not explicit_failure,
        {
            "pause_observed": pause,
            "resume_observed": resume,
            "reconnect_observed": reconnect,
            "explicit_failure": explicit_failure,
            "rounds": len(round_values),
            "rounds_failed": rounds_failed,
        },
    )

_PROVIDER_ALIASES = {"providerverified", "providersuccess", "modelverified", "providerproofverified"}
_MACHINE_KEYS = ("machineId", "machine_id", "machine")

def _own_machine(value: dict[str, object], inherited: str) -> str:
    for key in _MACHINE_KEYS:
        if isinstance(value.get(key), str):
            return value[key]
    return inherited

def _bound_fields(value: object, aliases: set[str], machine: str) -> Iterable[tuple[str, object]]:
    """(machine the value is about, value) for each field in `aliases`; the nearest machine id wins."""
    if isinstance(value, dict):
        machine = _own_machine(value, machine)
        for key, child in value.items():
            if _norm(key) in aliases:
                yield machine, child
            yield from _bound_fields(child, aliases, machine)
    elif isinstance(value, list):
        for child in value:
            yield from _bound_fields(child, aliases, machine)

def _provider_proof(
    records: list[object], sources: list[tuple[object, str]] | None = None, machine_id: str | None = None,
) -> tuple[bool, bool, dict[str, object]]:
    """Provider proof; with `machine_id`, only proof about that machine counts as verified."""
    if machine_id is None:
        found = [("", value) for value in _field_values(records, _PROVIDER_ALIASES)]
    else:
        found = [
            pair for source, inherited in (sources or []) for pair in _bound_fields(source, _PROVIDER_ALIASES, inherited)
        ]
    verified = any(_truthy(value) and (machine_id is None or (machine_id and owner == machine_id)) for owner, value in found)
    rejected = any(_falsey(value) for _owner, value in found)
    if not found:
        return verified, rejected, {"observed": False}
    detail: dict[str, object] = {"observed": verified, "verified": verified}
    if machine_id is not None and not verified and any(_truthy(value) for _owner, value in found):
        detail["unbound"] = True
    if rejected:
        detail["rejected"] = True
    return verified, rejected, detail

def _status(blockers: list[str]) -> str:
    if "receipt_reports_failure" in blockers or "provider_proof_rejected" in blockers:
        return "fail"
    return "blocked" if blockers else "pass"

# cmux-platform's GoldenPathReceipt (src/server/cloud/GoldenPathProbe.ts). The CLI row and the
# platform probe each write one for the same machine; their stages merge here.
GOLDEN_PATH_STAGES = ("machine", "folder", "readiness", "lease", "auth", "chat", "reconnect")
_GOLDEN_MACHINE_ID = re.compile(r"vm_[a-z0-9]{1,64}")

def _is_golden_receipt(record: object) -> bool:
    return (
        isinstance(record, dict)
        and record.get("version") == 1
        and isinstance(record.get("stages"), list)
        and all(isinstance(item, dict) and isinstance(item.get("stage"), str) for item in record["stages"])
    )

def _iso_ms(value: object) -> int | None:
    if not isinstance(value, str):
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    return int(parsed.timestamp() * 1000)

_EVIDENCE_FLAGS = (
    "ok", "passed", "success", "verified", "found", "discovered", "listed",
    "paused", "resumed", "running", "reconnected", "reply_ok",
)

def _evidence(value: dict[str, object], keys: tuple[str, ...], state: str | None = None) -> str | None:
    """"ok", "fail" or None (no evidence) for the first of `keys` present in a stage value.

    A nested object needs an explicit positive (a true flag, or `state` equal to the
    expected one); a false flag, a failing status or a different state fails it.
    """
    for key in keys:
        if key not in value or value[key] is None:
            continue
        item = value[key]
        if isinstance(item, dict):
            flags = [item[flag] for flag in _EVIDENCE_FLAGS if flag in item]
            observed = item.get("state")
            if (
                _entry_state(item) == "fail"
                or any(not _truthy(flag) for flag in flags)
                or (state and isinstance(observed, str) and _norm(observed) != state)
            ):
                return "fail"
            if any(_truthy(flag) for flag in flags) or (state and isinstance(observed, str)):
                return "ok"
            return None
        if _truthy(item):
            return "ok"
        if _falsey(item) or item in (0, ""):
            return "fail"
        return None
    return None

def _bound_discovery(chat_value: dict[str, object], machine_id: str) -> str | None:
    if not machine_id or _own_machine(chat_value, machine_id) != machine_id:
        return None
    keys = ("discovery", "session_discovery", "session_discovered", "sessionDiscovered", "acp_session")
    for key in keys:
        item = chat_value.get(key)
        if isinstance(item, dict) and _own_machine(item, machine_id) != machine_id:
            return None
    return _evidence(chat_value, keys)

def _golden_machine_id(receipt_value: dict[str, object]) -> str:
    candidates = [receipt_value.get("machineId")]
    for item in receipt_value["stages"]:
        if item.get("stage") in {"machine", "lease"} and isinstance(item.get("value"), dict):
            candidates.append(item["value"].get("machineId"))
    for candidate in candidates:
        if isinstance(candidate, str) and _GOLDEN_MACHINE_ID.fullmatch(candidate):
            return candidate
    return ""

def _normalize_golden(records: list[object]) -> dict[str, object]:
    receipts = [record for record in records if _is_golden_receipt(record)]
    blockers: list[str] = []
    machine_ids = sorted({_golden_machine_id(item) for item in receipts} - {""})
    if len(machine_ids) > 1:
        blockers.append("machine_id_mismatch")
    machine_id = machine_ids[0] if len(machine_ids) == 1 else ""
    if any(not _golden_machine_id(item) for item in receipts):
        blockers.append("receipt_machine_id_missing")

    reported_failure = False
    stage_state: dict[str, str] = {}
    stage_ms: dict[str, int] = {}
    failures: list[dict[str, object]] = []
    values: dict[str, list[dict[str, object]]] = {}
    for receipt_value in receipts:
        failure = receipt_value.get("failure")
        failure_code = str(failure.get("code", "")) if isinstance(failure, dict) else ""
        if receipt_value.get("outcome") != "passed" and not failure_code.endswith(".not_observable"):
            reported_failure = True
        bound = bool(machine_id) and _golden_machine_id(receipt_value) == machine_id
        for item in receipt_value["stages"]:
            name = _clean(item["stage"], 40)
            # ok:true next to a failure object is a contradiction, so it fails.
            ok = item.get("ok") is True and not item.get("failure")
            started, ended = _iso_ms(item.get("startedAt")), _iso_ms(item.get("endedAt"))
            if started is not None and ended is not None and ended >= started:
                stage_ms[name] = max(stage_ms.get(name, 0), ended - started)
            if ok:
                # A receipt not bound to this machine cannot prove a stage, only fail one.
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
            if code.endswith(".not_observable"):
                if stage_state.get(name) != "failed":
                    stage_state[name] = "not_observable"
            else:
                stage_state[name] = "failed"

    golden_stages = {name: stage_state.get(name, "missing") for name in GOLDEN_PATH_STAGES}
    for name in sorted(set(stage_state) - set(GOLDEN_PATH_STAGES)):
        golden_stages[name] = stage_state[name]

    chat_values = values.get("chat", [])
    session_id = _first_text(chat_values, {"sessionid", "acpsessionid"})
    discovery = [_bound_discovery(value, machine_id) for value in chat_values]
    reconnect_values = values.get("reconnect", [])
    pause = [_evidence(value, ("pause", "paused"), "paused") for value in reconnect_values]
    resume = [_evidence(value, ("resume", "resumed"), "running") for value in reconnect_values]
    reconnected = [_evidence(value, ("reconnected",)) for value in reconnect_values]
    explicit_failure = "fail" in discovery + pause + resume + reconnected
    chat_ok = golden_stages["chat"] == "ok"
    reconnect_ok = golden_stages["reconnect"] == "ok"
    continuity_detail = {
        "pause_observed": "ok" in pause and "fail" not in pause,
        "resume_observed": "ok" in resume and "fail" not in resume,
        "reconnect_observed": reconnect_ok and "fail" not in reconnected,
        "explicit_failure": explicit_failure,
    }
    stages = {
        "fresh_cloud_chat_start": all(golden_stages[name] == "ok" for name in ("machine", "folder", "readiness"))
        and chat_ok,
        "acpmux_session_discovery": chat_ok and bool(session_id) and "ok" in discovery and "fail" not in discovery,
        "first_reply": chat_ok,
        "pause_resume_reconnect": reconnect_ok and all(
            continuity_detail[key] for key in ("pause_observed", "resume_observed", "reconnect_observed")
        ),
    }

    provider_sources = [
        (record, _golden_machine_id(record) if _is_golden_receipt(record) else "") for record in records
    ]
    provider_true, provider_false, provider_detail = _provider_proof(records, provider_sources, machine_id)
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

    probe_ids = [_clean(item.get("probeId"), 80) for item in receipts if item.get("probeId")]
    return {
        "schema": SCHEMA,
        "status": _status(blockers),
        "request_id": probe_ids[0] if probe_ids else None,
        "probe_ids": probe_ids,
        "machine_id": machine_id or None,
        "session_id": session_id or None,
        "stages": stages,
        "golden_path_stages": golden_stages,
        "stage_ms": stage_ms,
        "failures": failures,
        "provider_verification": provider_detail,
        "continuity": continuity_detail,
        "blockers": blockers,
        "evidence": {"record_count": len(records), "receipt_count": len(receipts)},
    }

def normalize(records: list[object]) -> dict[str, object]:
    if not records:
        return {
            "schema": SCHEMA,
            "status": "blocked",
            "blockers": ["receipt_empty"],
            "stages": {},
            "provider_verification": {"observed": False},
        }
    if any(_is_golden_receipt(record) for record in records):
        return _normalize_golden(records)

    machine_id = _first_id(records, {"machineid", "machine"}, _VM_ID)
    session_id = _first_text(records, {"sessionid", "acpsessionid", "session"})
    reply = _first_text(records, {"reply", "replytext", "firstreply", "firstreplytext"})
    request_id = _first_text(records, {"requestid", "probeid", "runid"})
    start_state = _named_state(records, ("startchat", "startsession", "newchat", "cloudchat"))
    start = start_state != "fail" and (
        start_state == "ok"
        or any(isinstance(value, dict) for value in _field_values(records, {"firstchat", "startchat"}))
        or (bool(_first_text(records, {"route"})) and bool(machine_id))
    )
    discovery_state = _named_state(
        records,
        ("sessiondiscover", "sessionlist", "acpsession", "listsessions", "attachsession", "startsession"),
    )
    session_discovery = (
        bool(session_id)
        and discovery_state != "fail"
        and (
            discovery_state == "ok"
            or bool(_first_text(records, {"sessiondiscovered", "sessiondiscovery", "acpsession"}))
            or any(isinstance(value, dict) for value in _field_values(records, {"turn", "acpsession"}))
        )
    )
    reply_state = _named_state(records, ("firstreply", "reply", "assistantmessage"))
    first_reply = reply_state != "fail" and (
        reply_state == "ok"
        or bool(reply)
        or _explicit_true(records, {"replyok"})
    )
    continuity, continuity_detail = _continuity(records)

    provider_true, provider_false, provider_detail = _provider_proof(records)

    stages = {
        "fresh_cloud_chat_start": start,
        "acpmux_session_discovery": session_discovery,
        "first_reply": first_reply,
        "pause_resume_reconnect": continuity,
    }
    blockers: list[str] = []
    failures = [status for status in _statuses(records) if status in {"fail", "failed", "error", "timeout", "timedout", "cancelled"}]
    if failures or bool(continuity_detail["explicit_failure"]) or _named_failures(records):
        blockers.append("receipt_reports_failure")
    if provider_false:
        blockers.append("provider_proof_rejected")
    if not machine_id:
        blockers.append("missing_machine_id")
    for stage, passed in stages.items():
        if not passed:
            blockers.append(f"missing_{stage}")
    if not provider_true:
        blockers.append("provider_proof_missing")

    return {
        "schema": SCHEMA,
        "status": _status(blockers),
        "request_id": request_id or None,
        "machine_id": machine_id or None,
        "session_id": session_id or None,
        "stages": stages,
        "provider_verification": provider_detail,
        "continuity": continuity_detail,
        "blockers": blockers,
        "evidence": {"record_count": len(records)},
    }

def load_receipt(path: Path) -> list[object]:
    text = path.read_text(encoding="utf-8")
    try:
        value = json.loads(text)
    except json.JSONDecodeError:
        values = []
        for line in text.splitlines():
            if line.strip():
                values.append(json.loads(line))
        return values
    return value if isinstance(value, list) else [value]

def _unreadable(blocker: str, error: Exception) -> dict[str, object]:
    return {
        "schema": SCHEMA,
        "status": "blocked",
        "blockers": [blocker],
        "stages": {},
        "provider_verification": {"observed": False},
        "evidence": {"error": _clean(f"{type(error).__name__}: {error}")},
    }

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--check", action="store_true", help="exit 2 unless the normalized receipt passes")
    args = parser.parse_args(argv)
    try:
        normalized = normalize(load_receipt(args.receipt))
    except (UnicodeDecodeError, ValueError) as error:
        normalized = _unreadable("receipt_malformed", error)
    except OSError as error:
        normalized = _unreadable("receipt_unreadable", error)
    rendered = json.dumps(normalized, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if normalized["status"] == "pass" or not args.check else 2

if __name__ == "__main__":
    raise SystemExit(main())
