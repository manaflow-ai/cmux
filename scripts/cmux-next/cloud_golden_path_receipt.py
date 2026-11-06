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
from pathlib import Path
from typing import Iterable

SCHEMA = "cmux.cloud-golden-path-receipt/v1"
_VM_ID = re.compile(r"\bvm_[0-9a-f]{1,64}\b")
_SECRET = re.compile(
    r"(?i)\b(?:cmvm|cmk|crt|crk|cmm|cmj|pck|ssk)_[A-Za-z0-9_-]{8,}"
    r"|\bsk-(?:ant-)?[A-Za-z0-9_-]{10,}"
    r"|\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}(?:\.[A-Za-z0-9_-]+)?"
    r"|\bbearer\s+[A-Za-z0-9._~+/=-]+"
)

def _norm(value: object) -> str:
    return re.sub(r"[^a-z0-9]", "", str(value).lower())

def _clean(value: object, limit: int = 160) -> str:
    text = " ".join(str(value or "").split())
    return _SECRET.sub("[withheld]", text)[:limit]

def _truthy(value: object) -> bool:
    if value is True:
        return True
    if isinstance(value, str):
        return _norm(value) in {"true", "ok", "pass", "passed", "success", "succeeded", "running", "ready"}
    return False

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

def _entry_ok(entry: dict[str, object]) -> bool:
    for key in ("ok", "passed", "success", "verified", "ready"):
        if key in entry:
            return _truthy(entry[key])
    for key in ("outcome", "status", "verdict", "result"):
        if key in entry and isinstance(entry[key], str):
            return not _falsey(entry[key])
    return True

def _has_named_entry(records: list[object], tokens: tuple[str, ...]) -> bool:
    return any(
        _entry_name(entry)
        and any(token in _entry_name(entry) for token in tokens)
        and _entry_ok(entry)
        for entry in _dicts(records)
    )

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
    for entry in _dicts(records):
        rounds = entry.get("rounds")
        if not isinstance(rounds, list) or not rounds:
            continue
        round_values = []
        for round_item in rounds:
            if not isinstance(round_item, dict):
                round_values.append(False)
                continue
            nested = [round_item]
            round_values.append(
                _explicit_true(nested, pause_aliases)
                and _explicit_true(nested, resume_aliases)
                and _explicit_true(nested, reconnect_aliases)
            )
        if all(round_values):
            pause = resume = reconnect = True
    named_failures = any(
        not _entry_ok(entry)
        for entry in _dicts(records)
        if any(token in _entry_name(entry) for token in ("pause", "resume", "reconnect", "continuity"))
    )
    explicit_failure = (
        _explicit_false(records, pause_aliases | resume_aliases | reconnect_aliases)
        or named_failures
    )
    return (
        pause and resume and reconnect and not explicit_failure,
        {
            "pause_observed": pause,
            "resume_observed": resume,
            "reconnect_observed": reconnect,
            "explicit_failure": explicit_failure,
        },
    )

def normalize(records: list[object]) -> dict[str, object]:
    if not records:
        return {
            "schema": SCHEMA,
            "status": "blocked",
            "blockers": ["receipt_empty"],
            "stages": {},
            "provider_verification": {"observed": False},
        }

    machine_id = _first_id(records, {"machineid", "machine"}, _VM_ID)
    session_id = _first_text(records, {"sessionid", "acpsessionid", "session"})
    reply = _first_text(records, {"reply", "replytext", "firstreply", "firstreplytext"})
    request_id = _first_text(records, {"requestid", "probeid", "runid"})
    start = (
        _has_named_entry(records, ("startchat", "startsession", "newchat", "cloudchat"))
        or (bool(_first_text(records, {"route"})) and bool(machine_id))
    )
    session_discovery = (
        bool(session_id)
        and (
            _has_named_entry(
                records,
                ("sessiondiscover", "sessionlist", "acpsession", "listsessions", "attachsession", "startsession"),
            )
            or bool(_first_text(records, {"sessiondiscovered", "sessiondiscovery", "acpsession"}))
        )
    )
    first_reply = bool(reply) or _has_named_entry(records, ("firstreply", "reply", "assistantmessage"))
    continuity, continuity_detail = _continuity(records)

    provider_values = _field_values(records, {
        "providerverified", "providersuccess", "modelverified", "providerproofverified",
    })
    provider_true = any(_truthy(value) for value in provider_values)
    provider_false = any(_falsey(value) for value in provider_values)
    if not provider_values:
        provider_detail: dict[str, object] = {"observed": False}
    else:
        provider_detail = {"observed": provider_true, "verified": provider_true}
        if provider_false:
            provider_detail["rejected"] = True

    stages = {
        "fresh_cloud_chat_start": start,
        "acpmux_session_discovery": session_discovery,
        "first_reply": first_reply,
        "pause_resume_reconnect": continuity,
    }
    blockers: list[str] = []
    failures = [status for status in _statuses(records) if status in {"fail", "failed", "error", "timeout", "timedout", "cancelled"}]
    if failures or bool(continuity_detail["explicit_failure"]):
        blockers.append("receipt_reports_failure")
    if provider_false:
        blockers.append("provider_proof_rejected")
    for stage, passed in stages.items():
        if not passed:
            blockers.append(f"missing_{stage}")
    if not provider_true:
        blockers.append("provider_proof_missing")

    if "receipt_reports_failure" in blockers or "provider_proof_rejected" in blockers:
        status = "fail"
    elif blockers:
        status = "blocked"
    else:
        status = "pass"

    return {
        "schema": SCHEMA,
        "status": status,
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

def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", required=True, type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--check", action="store_true", help="exit 2 unless the normalized receipt passes")
    args = parser.parse_args(argv)
    normalized = normalize(load_receipt(args.receipt))
    rendered = json.dumps(normalized, indent=2, sort_keys=True) + "\n"
    if args.out:
        args.out.parent.mkdir(parents=True, exist_ok=True)
        args.out.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if normalized["status"] == "pass" or not args.check else 2

if __name__ == "__main__":
    raise SystemExit(main())
