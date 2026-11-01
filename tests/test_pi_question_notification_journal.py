#!/usr/bin/env python3
"""A Pi question must reach the journal as a question, whatever its punctuation.

Pi's extension marks a reply that ends in `?` or `？` with `notification.type`
"question", then sends it to `cmux hooks pi notification`. A fullwidth question
carried no ASCII `?` for the classifier to find, so it was journaled as a plain
observation, and the routed flag on the Stop that followed suppressed the
fallback too (https://github.com/manaflow-ai/cmux/issues/26838).

This drives the built CLI against a fake socket and reads the journal drafts off
the wire. test_pi_extension_dispatch.py covers what the extension sends.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
from pathlib import Path

from agent_notification_test_utils import journal_draft
from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import FAKE_SURFACE_ID, FAKE_WORKSPACE_ID, FakeCmuxSocket


QUESTION_REQUESTED = "agent.question.requested"
STATE_CHANGED = "agent.state.changed"
CHINESE_QUESTION = "请确认：采用 WAV 还是 AAC？"


def strip_capability_prefix(raw: str) -> str:
    if raw.startswith("_cmux_capability_v1 "):
        parts = raw.split(" ", 2)
        return parts[2] if len(parts) == 3 else raw
    return raw


def journal_drafts(cli_path: str, socket_path: Path, payload: dict) -> list[dict]:
    env = os.environ.copy()
    for key in ("CMUX_SOCKET", "CMUX_SOCKET_CAPABILITY", "CMUX_SOCKET_PATH", "CMUX_SOCKET_PASSWORD"):
        env.pop(key, None)
    env["CMUX_SURFACE_ID"] = FAKE_SURFACE_ID
    env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID
    with FakeCmuxSocket(
        socket_path,
        None,
        surface_delivery_target=(FAKE_WORKSPACE_ID, FAKE_SURFACE_ID),
    ) as fake:
        result = subprocess.run(
            [cli_path, "--socket", str(socket_path), "hooks", "pi", "notification"],
            input=json.dumps(payload, ensure_ascii=False),
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=15,
        )
        if result.returncode != 0:
            raise AssertionError(
                f"hooks pi notification failed exit={result.returncode}\n"
                f"stdout={result.stdout}\nstderr={result.stderr}"
            )
        frames = list(fake.frames)
    drafts = []
    for frame in frames:
        if isinstance(frame, dict) and "raw" in frame:
            draft = journal_draft(strip_capability_prefix(frame["raw"]))
            if draft is not None:
                drafts.append(draft)
    return drafts


def notification_payload(message: str, notification_type: str, **extra: str) -> dict:
    return {
        "session_id": "pi-question-session",
        "cwd": "/tmp/pi-question",
        "turn_id": "pi-question-session:turn-1",
        "message": message,
        "notification": {"type": notification_type},
        **extra,
    }


def expect_notification(
    cli_path: str,
    root: Path,
    name: str,
    payload: dict,
    *,
    kind: str,
    subtitle: str,
    body: str,
) -> None:
    drafts = journal_drafts(cli_path, root / f"{name}.sock", payload)
    kinds = {draft.get("kind") for draft in drafts}
    notifications = [
        notification
        for draft in drafts
        if (notification := (draft.get("attention") or {}).get("notification")) is not None
    ]
    if kinds != {kind}:
        raise AssertionError(f"{name}: expected only {kind}, got {kinds!r}")
    if len(notifications) != 1:
        raise AssertionError(f"{name}: expected one notification, got {notifications!r}")
    if notifications[0].get("subtitle") != subtitle or notifications[0].get("body") != body:
        raise AssertionError(f"{name}: wrong notification {notifications[0]!r}")


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except RuntimeError as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(prefix="cmux-pi-question-", dir="/tmp") as td:
        root = Path(td)
        try:
            expect_notification(
                cli_path,
                root,
                "fullwidth",
                notification_payload(CHINESE_QUESTION, "question"),
                kind=QUESTION_REQUESTED,
                subtitle="Waiting",
                body=CHINESE_QUESTION,
            )
            expect_notification(
                cli_path,
                root,
                "ascii",
                notification_payload("Use WAV or AAC?", "question"),
                kind=QUESTION_REQUESTED,
                subtitle="Waiting",
                body="Use WAV or AAC?",
            )
            # A UI dialog's prompt stays inside Pi: questionAsked never carries prose.
            expect_notification(
                cli_path,
                root,
                "dialog",
                notification_payload(
                    "needs_input",
                    "question",
                    hook_event_name="questionAsked",
                    event="questionAsked",
                ),
                kind=QUESTION_REQUESTED,
                subtitle="Waiting",
                body="Needs input",
            )
            # The mark alone is not a question: the type is what says so.
            expect_notification(
                cli_path,
                root,
                "untyped",
                notification_payload(CHINESE_QUESTION, "observation"),
                kind=STATE_CHANGED,
                subtitle="Attention",
                body=CHINESE_QUESTION,
            )
        except AssertionError as exc:
            print(f"FAIL: {exc}")
            return 1

    print("PASS: Pi questions reach the journal as questions with either question mark")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
