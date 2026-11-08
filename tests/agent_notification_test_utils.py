"""Decode notification candidates from the actual hook wire protocol.

These are producer-contract views, not a simulated admission gate. The Swift
behavior suites execute reconciliation and durable notification admission.
"""
from __future__ import annotations

import json


def journal_draft(command: str) -> dict | None:
    prefix = "agent_journal_append "
    if not command.startswith(prefix):
        return None
    return json.loads(command[len(prefix):])


def notification_view(command: str) -> dict | None:
    draft = journal_draft(command)
    if draft is None:
        return None
    attention = draft.get("attention") or {}
    notification = attention.get("notification")
    if not isinstance(notification, dict):
        return None
    return {
        "kind": draft["kind"],
        "source": draft["source"],
        "workspace_id": draft.get("workspace_id"),
        "surface_id": draft.get("surface_id"),
        "title": notification["title"],
        "subtitle": notification["subtitle"],
        "body": notification["body"],
        "category": notification["category"],
        "pending_work": draft["pending_work"],
        "request_identity": attention.get("requestIdentity"),
    }


def resolution_view(command: str) -> dict | None:
    draft = journal_draft(command)
    if draft is None or draft["kind"] != "agent.attention.resolved" or draft.get("declared_phase") != "running":
        return None
    return {
        "workspace_id": draft.get("workspace_id"),
        "surface_id": draft.get("surface_id"),
        "request_identity": (draft.get("attention") or {}).get("requestIdentity"),
    }


def message_presentations(commands: list[str]) -> list[str]:
    result = []
    for command in commands:
        view = notification_view(command)
        if view is None:
            continue
        assert view["kind"] == "agent.message.published", "Explicit messages must not mutate lifecycle"
        assert view["category"] == "other" and not view["pending_work"]
        result.append(
            f"notify_target_async {view['workspace_id']} {view['surface_id']} "
            f"{view['title']}|{view['subtitle']}|{view['body']}"
        )
    return result
