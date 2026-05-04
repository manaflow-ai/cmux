from __future__ import annotations

import json
import math
import time
import uuid
from datetime import datetime, timezone
from typing import Any

PERMISSION_REPLY_MODES = frozenset({"once", "always", "all", "bypass", "deny"})
EXIT_PLAN_REPLY_MODES = frozenset({"ultraplan", "bypassPermissions", "autoAccept", "manual", "deny"})

ACTIONABLE_WORKSTREAM_KINDS = frozenset({"permissionRequest", "exitPlan", "question"})

HOOK_EVENT_TO_WORKSTREAM_KIND = {
    "PermissionRequest": "permissionRequest",
    "AskUserQuestion": "question",
    "ExitPlanMode": "exitPlan",
    "PreToolUse": "toolUse",
    "PostToolUse": "toolResult",
    "UserPromptSubmit": "userPrompt",
    "SessionStart": "sessionStart",
    "SessionEnd": "sessionEnd",
    "Stop": "stop",
    "SubagentStop": "stop",
    "TodoWrite": "todos",
    "Notification": "toolResult",
}


def feed_wait_timeout(params: dict[str, Any]) -> float:
    if "wait_timeout_seconds" not in params:
        return 0
    try:
        seconds = float(params.get("wait_timeout_seconds"))
    except (TypeError, ValueError):
        raise ValueError("feed.push wait_timeout_seconds must be numeric.")
    if not math.isfinite(seconds) or seconds < 0 or seconds > 120:
        raise ValueError("feed.push wait_timeout_seconds must be between 0 and 120.")
    return seconds


def feed_event_from_params(params: dict[str, Any]) -> dict[str, Any]:
    event = params.get("event")
    if isinstance(event, dict):
        event_dict = dict(event)
    elif all(params.get(key) is not None for key in ("session_id", "hook_event_name", "_source")):
        event_dict = dict(params)
    else:
        raise ValueError("feed.push requires an `event` object.")
    for key in ("session_id", "hook_event_name", "_source"):
        if not isinstance(event_dict.get(key), str) or not event_dict.get(key):
            raise ValueError(f"feed.push event requires {key}.")
    return event_dict


def iso8601_from_timestamp(seconds: float) -> str:
    return (
        datetime.fromtimestamp(float(seconds), tz=timezone.utc)
        .isoformat(timespec="seconds")
        .replace("+00:00", "Z")
    )


def feed_kind(event: dict[str, Any]) -> str:
    hook = str(event.get("hook_event_name") or "")
    return HOOK_EVENT_TO_WORKSTREAM_KIND.get(hook, "toolResult")


def feed_status_for_kind(kind: str) -> str:
    return "pending" if kind in ACTIONABLE_WORKSTREAM_KINDS else "telemetry"


def feed_request_id(event: dict[str, Any]) -> str | None:
    for key in ("request_id", "_opencode_request_id"):
        value = event.get(key)
        if isinstance(value, str) and value:
            return value
    context = event.get("context")
    if isinstance(context, dict):
        value = context.get("request_id")
        if isinstance(value, str) and value:
            return value
    return None


def feed_item_from_event(
    event: dict[str, Any],
    *,
    now: float | None = None,
    item_id: str | None = None,
) -> dict[str, Any]:
    timestamp = time.time() if now is None else now
    iso_timestamp = iso8601_from_timestamp(timestamp)
    request_id = feed_request_id(event)
    kind = feed_kind(event)
    item: dict[str, Any] = {
        "id": item_id or str(uuid.uuid4()),
        "workstream_id": str(event.get("session_id")),
        "source": str(event.get("_source")),
        "kind": kind,
        "created_at": iso_timestamp,
        "updated_at": iso_timestamp,
        "status": feed_status_for_kind(kind),
        "event": dict(event),
    }
    if request_id is not None:
        item["request_id"] = request_id
    cwd = event.get("cwd")
    if isinstance(cwd, str) and cwd:
        item["cwd"] = cwd
    title = event.get("title")
    if not isinstance(title, str) or not title:
        title = event.get("tool_name")
    if isinstance(title, str) and title:
        item["title"] = title
    return item


def resolve_feed_item(
    item: dict[str, Any],
    decision: dict[str, Any],
    *,
    resolved_at: float | None = None,
) -> dict[str, Any]:
    timestamp = time.time() if resolved_at is None else resolved_at
    iso_timestamp = iso8601_from_timestamp(timestamp)
    return {
        **item,
        "status": "resolved",
        "decision": dict(decision),
        "resolved_at": iso_timestamp,
        "updated_at": iso_timestamp,
    }


def expire_feed_item(
    item: dict[str, Any],
    *,
    expired_at: float | None = None,
) -> dict[str, Any]:
    timestamp = time.time() if expired_at is None else expired_at
    iso_timestamp = iso8601_from_timestamp(timestamp)
    return {
        **item,
        "status": "expired",
        "resolved_at": iso_timestamp,
        "updated_at": iso_timestamp,
    }


def feed_permission_decision(mode: str) -> dict[str, Any]:
    if mode not in PERMISSION_REPLY_MODES:
        raise ValueError("feed.permission.reply requires mode in once|always|all|bypass|deny.")
    return {"kind": "permission", "mode": mode}


def feed_question_decision(selections: Any) -> dict[str, Any]:
    if not isinstance(selections, list) or not all(isinstance(item, str) for item in selections):
        raise ValueError("feed.question.reply requires selections: [string].")
    return {"kind": "question", "selections": list(selections)}


def feed_exit_plan_decision(mode: str, feedback: Any) -> dict[str, Any]:
    if mode not in EXIT_PLAN_REPLY_MODES:
        raise ValueError("feed.exit_plan.reply requires mode in ultraplan|bypassPermissions|autoAccept|manual|deny.")
    decision = {"kind": "exit_plan", "mode": mode}
    if isinstance(feedback, str) and feedback:
        decision = {**decision, "feedback": feedback}
    return decision


def feed_decision_stdout(decision: dict[str, Any]) -> str:
    return json.dumps({"decision": decision}, separators=(",", ":"), sort_keys=True)


def feed_reply_response(decision: dict[str, Any]) -> dict[str, Any]:
    stdout = feed_decision_stdout(decision)
    return {
        "delivered": True,
        "decision": dict(decision),
        "stdout": stdout,
        "stdout_decision_json": stdout,
    }


def feed_push_response(
    item: dict[str, Any],
    *,
    wait_timeout_seconds: float,
    decision: dict[str, Any] | None = None,
) -> dict[str, Any]:
    if decision is not None:
        stdout = feed_decision_stdout(decision)
        return {
            "status": "resolved",
            "decision": dict(decision),
            "item_id": item["id"],
            "stdout": stdout,
            "stdout_decision_json": stdout,
        }
    return {
        "status": "acknowledged",
        "item_id": item["id"],
        "wait_timeout_seconds": wait_timeout_seconds,
    }


def feed_timed_out_response(item_id: str) -> dict[str, Any]:
    return {
        "status": "timed_out",
        "item_id": item_id,
    }


def feed_public_item(item: dict[str, Any]) -> dict[str, Any]:
    public = {
        "id": item.get("id"),
        "workstream_id": item.get("workstream_id"),
        "source": item.get("source"),
        "kind": item.get("kind"),
        "created_at": item.get("created_at"),
        "updated_at": item.get("updated_at"),
        "status": item.get("status"),
    }
    for key in ("cwd", "title", "request_id", "decision", "resolved_at"):
        if key in item:
            public[key] = item[key]
    return public
