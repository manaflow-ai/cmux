#!/usr/bin/env python3
"""
Regression: a codex PermissionRequest feed hook raises the
"Agent Needs Permission"-gated notification, acknowledged before the hook
returns, and codex tool completion clears it.

https://github.com/manaflow-ai/cmux/issues/9592: the feed bridge normalized
codex PermissionRequest to non-actionable PreToolUse telemetry and never
raised any notification, leaving a blocked codex seat silent indefinitely.
These tests exercise the actual CLI delivery path (`cmux hooks feed`)
against a fake socket: classification-only coverage cannot catch a broken
or misrouted notify/clear dispatch.
"""

from __future__ import annotations

import json
import os
import subprocess
import tempfile
import time
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import (
    FAKE_SURFACE_ID,
    FAKE_WORKSPACE_ID,
    FakeCmuxSocket,
)

EXPECTED_NOTIFY_COMMAND = (
    f"notify_target_async {FAKE_WORKSPACE_ID} {FAKE_SURFACE_ID} "
    "Codex|Permission|shell needs approval|c=needs-permission;p=0"
)
EXPECTED_CLEAR_COMMAND = (
    f"clear_notifications --tab={FAKE_WORKSPACE_ID} --panel={FAKE_SURFACE_ID}"
)


def codex_payload(event: str) -> dict:
    return {
        "session_id": "codex-permission-prompt",
        "turn_id": "turn-1",
        "cwd": "/tmp/project",
        "hook_event_name": event,
        "tool_name": "shell",
        "tool_input": {"command": "printf hi"},
    }


def strip_capability_prefix(raw: str) -> str:
    if raw.startswith("_cmux_capability_v1 "):
        parts = raw.split(" ", 2)
        return parts[2] if len(parts) == 3 else raw
    return raw


def run_feed_hook_capture(
    cli_path: str,
    socket_path: Path,
    event: str,
    raw_response_delay: float = 0,
) -> tuple[dict, list, float]:
    """Runs `cmux hooks feed --source codex` and returns (stdout JSON,
    ordered received frames, elapsed seconds)."""
    env = os.environ.copy()
    for key in ("CMUX_SOCKET", "CMUX_SOCKET_CAPABILITY", "CMUX_SOCKET_PATH", "CMUX_SOCKET_PASSWORD"):
        env.pop(key, None)
    env["CMUX_SURFACE_ID"] = FAKE_SURFACE_ID
    env["CMUX_WORKSPACE_ID"] = FAKE_WORKSPACE_ID
    with FakeCmuxSocket(socket_path, None, raw_response_delay=raw_response_delay) as fake:
        started = time.monotonic()
        result = subprocess.run(
            [
                cli_path,
                "--socket",
                str(socket_path),
                "hooks",
                "feed",
                "--source",
                "codex",
                "--event",
                event,
            ],
            input=json.dumps(codex_payload(event)),
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=15,
        )
        elapsed = time.monotonic() - started
        if result.returncode != 0:
            raise AssertionError(
                f"hooks feed failed exit={result.returncode}\n"
                f"stdout={result.stdout}\nstderr={result.stderr}"
            )
        # The feed frame is one-way telemetry on its own connection; give the
        # fake a moment to drain it after the hook exits.
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            if any(frame.get("method") == "feed.push" for frame in fake.frames):
                break
            time.sleep(0.05)
        stdout = json.loads(result.stdout.strip() or "{}")
        return stdout, list(fake.frames), elapsed


def raw_commands(frames: list) -> list[str]:
    return [
        strip_capability_prefix(frame["raw"])
        for frame in frames
        if isinstance(frame, dict) and "raw" in frame
    ]


def frame_index(frames: list, predicate) -> int:
    for index, frame in enumerate(frames):
        if predicate(frame):
            return index
    return -1


def test_permission_request_sends_gated_notification_before_feed_push(
    cli_path: str, root: Path
) -> None:
    stdout, frames, _ = run_feed_hook_capture(
        cli_path, root / "cmux-notify.sock", "PermissionRequest"
    )
    if stdout != {}:
        raise AssertionError(f"PermissionRequest must stay non-blocking: {stdout!r}")
    commands = raw_commands(frames)
    if EXPECTED_NOTIFY_COMMAND not in commands:
        raise AssertionError(
            f"missing gated permission notification, got raw commands {commands!r}"
        )
    notify_index = frame_index(
        frames,
        lambda frame: "raw" in frame
        and strip_capability_prefix(frame["raw"]) == EXPECTED_NOTIFY_COMMAND,
    )
    feed_index = frame_index(frames, lambda frame: frame.get("method") == "feed.push")
    if feed_index == -1:
        raise AssertionError(f"missing feed.push telemetry frame: {frames!r}")
    if notify_index > feed_index:
        raise AssertionError(
            f"notification must precede telemetry (notify at {notify_index}, "
            f"feed.push at {feed_index}): {frames!r}"
        )


def test_post_tool_use_clears_pane_before_feed_push(cli_path: str, root: Path) -> None:
    stdout, frames, _ = run_feed_hook_capture(
        cli_path, root / "cmux-clear.sock", "PostToolUse"
    )
    if stdout != {}:
        raise AssertionError(f"PostToolUse must stay non-blocking: {stdout!r}")
    commands = raw_commands(frames)
    if EXPECTED_CLEAR_COMMAND not in commands:
        raise AssertionError(
            f"missing resolved-approval clear, got raw commands {commands!r}"
        )
    clear_index = frame_index(
        frames,
        lambda frame: "raw" in frame
        and strip_capability_prefix(frame["raw"]) == EXPECTED_CLEAR_COMMAND,
    )
    feed_index = frame_index(frames, lambda frame: frame.get("method") == "feed.push")
    if feed_index == -1:
        raise AssertionError(f"missing feed.push telemetry frame: {frames!r}")
    if clear_index > feed_index:
        raise AssertionError(
            f"clear must precede telemetry (clear at {clear_index}, "
            f"feed.push at {feed_index}): {frames!r}"
        )


def test_pre_tool_use_sends_no_attention_command(cli_path: str, root: Path) -> None:
    """Pre-tool events have no ordering guarantee against PermissionRequest,
    so they must neither notify nor clear (a start-time clear could erase a
    just-raised prompt while the agent is still blocked)."""
    _, frames, _ = run_feed_hook_capture(
        cli_path, root / "cmux-pretool.sock", "PreToolUse"
    )
    offenders = [
        command
        for command in raw_commands(frames)
        if command.startswith("notify_target_async") or command.startswith("clear_notifications")
    ]
    if offenders:
        raise AssertionError(f"PreToolUse must not touch notifications: {offenders!r}")


def test_permission_notification_is_acknowledged_before_hook_returns(
    cli_path: str, root: Path
) -> None:
    """A one-way write would let the hook exit before the app processed the
    notification, so the CLI must await the app's acknowledgement. With the
    fake delaying its OK by 0.5s, a fire-and-forget regression returns
    almost instantly; the awaited transport cannot."""
    delay = 0.5
    stdout, frames, elapsed = run_feed_hook_capture(
        cli_path, root / "cmux-ack.sock", "PermissionRequest", raw_response_delay=delay
    )
    if stdout != {}:
        raise AssertionError(f"PermissionRequest must stay non-blocking: {stdout!r}")
    if EXPECTED_NOTIFY_COMMAND not in raw_commands(frames):
        raise AssertionError(f"missing gated permission notification: {frames!r}")
    if elapsed < delay - 0.1:
        raise AssertionError(
            f"hook returned in {elapsed:.2f}s without awaiting the delayed "
            f"({delay}s) notification acknowledgement"
        )


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(
        prefix="cmux-codex-permission-prompt-", dir="/tmp"
    ) as td:
        root = Path(td)
        try:
            test_permission_request_sends_gated_notification_before_feed_push(cli_path, root)
            test_post_tool_use_clears_pane_before_feed_push(cli_path, root)
            test_pre_tool_use_sends_no_attention_command(cli_path, root)
            test_permission_notification_is_acknowledged_before_hook_returns(cli_path, root)
        except Exception as exc:
            print(f"FAIL: {exc}")
            return 1

    print("PASS: codex permission prompts notify, acknowledge, and clear")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
