#!/usr/bin/env python3
"""
Regression: one retained Codex transcript monitor must reach a bounded RSS
plateau as synchronized transcript updates are processed.

The test drives the real CLI monitor against FakeCmuxSocket. Each synthetic
update includes a large assistant row plus a unique request_user_input marker.
The notification for that marker is the parser-progress signal before the next
write, so checkpoints do not depend on fixed sleeps or scheduler timing.
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import (
    FAKE_SURFACE_ID,
    FAKE_WORKSPACE_ID,
    FakeCmuxSocket,
    monitor_pids_for_session,
    wait_for_monitor_pids,
)


TRANSCRIPT_WRITES = 60
TRANSCRIPT_MESSAGE_BYTES = 30_000
CHECKPOINT_WRITES = {20, 40, 60}
MAX_LATE_GROWTH_KB = 16 * 1024


def monitor_rss_kb(pid: int) -> int:
    """Return the monitor's current resident set size in KiB."""
    result = subprocess.run(
        ["ps", "-axo", "pid=,rss=,command="],
        capture_output=True,
        text=True,
        check=False,
        timeout=10,
    )
    if result.returncode != 0:
        raise AssertionError(f"ps failed: {result.stderr}")
    for line in result.stdout.splitlines():
        fields = line.strip().split(maxsplit=2)
        if len(fields) >= 2 and fields[0] == str(pid):
            return int(fields[1])
    raise AssertionError(f"monitor pid {pid} disappeared while sampling RSS")


def wait_for_raw_command(
    server: FakeCmuxSocket,
    needle: str,
    *,
    timeout: float = 5.0,
) -> None:
    """Wait on the notification emitted by the transcript parser."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if any(needle in frame.get("raw", "") for frame in list(server.frames)):
            return
        time.sleep(0.02)
    raise AssertionError(f"monitor did not publish parser checkpoint {needle!r}")


def run_codex_hook(
    cli_path: str,
    socket_path: Path,
    subcommand: str,
    payload: dict[str, str],
    environment: dict[str, str],
) -> None:
    """Run one Codex hook against the isolated fake socket."""
    result = subprocess.run(
        [cli_path, "--socket", str(socket_path), "hooks", "codex", subcommand],
        input=json.dumps(payload),
        capture_output=True,
        text=True,
        check=False,
        env=environment,
        timeout=10,
    )
    if result.returncode != 0:
        raise AssertionError(
            f"hooks codex {subcommand} failed with exit={result.returncode}: "
            f"{result.stderr.strip()}"
        )


def append_synchronized_update(
    transcript_path: Path,
    *,
    turn_id: str,
    index: int,
) -> str:
    """Append one large parse workload plus a unique observable checkpoint."""
    question = f"memory checkpoint {index}"
    assistant_row = {
        "type": "response_item",
        "payload": {
            "type": "message",
            "role": "assistant",
            "content": [
                {
                    "type": "output_text",
                    "text": "synthetic " + "x" * TRANSCRIPT_MESSAGE_BYTES,
                }
            ],
        },
    }
    checkpoint_row = {
        "type": "event_msg",
        "payload": {
            "type": "request_user_input",
            "call_id": f"memory-checkpoint-{index}",
            "turn_id": turn_id,
            "questions": [
                {
                    "id": f"memory-{index}",
                    "header": "Memory",
                    "question": question,
                    "options": [
                        {
                            "label": "Continue",
                            "description": "Synthetic monitor progress marker",
                        }
                    ],
                }
            ],
        },
    }
    with transcript_path.open("a", encoding="utf-8") as transcript:
        transcript.write(json.dumps(assistant_row) + "\n")
        transcript.write(json.dumps(checkpoint_row) + "\n")
        transcript.flush()
        os.fsync(transcript.fileno())
    return question


def test_codex_monitor_rss_reaches_a_plateau(cli_path: str, root: Path) -> None:
    """Verify one monitor stops accumulating parser temporaries across wakes."""
    socket_path = root / "cmux-monitor-memory.sock"
    state_dir = root / "hook-state-memory"
    transcript_path = root / "codex-session-memory.jsonl"
    state_dir.mkdir()
    turn_id = "synthetic-one-turn"
    transcript_path.write_text(
        json.dumps(
            {
                "type": "event_msg",
                "payload": {"type": "task_started", "turn_id": turn_id},
            }
        )
        + "\n",
        encoding="utf-8",
    )

    session_id = f"codex-monitor-memory-session-{os.getpid()}"
    hook_payload = {
        "session_id": session_id,
        "turn_id": turn_id,
        "cwd": str(root),
        "transcript_path": str(transcript_path),
    }
    environment = os.environ.copy()
    for key in ("CMUX_SOCKET", "CMUX_SOCKET_CAPABILITY", "CMUX_SOCKET_PASSWORD"):
        environment.pop(key, None)
    environment.update(
        {
            "CMUX_SOCKET_PATH": str(socket_path),
            "CMUX_SURFACE_ID": FAKE_SURFACE_ID,
            "CMUX_WORKSPACE_ID": FAKE_WORKSPACE_ID,
            "CMUX_AGENT_HOOK_STATE_DIR": str(state_dir),
            "CMUX_CLI_SENTRY_DISABLED": "1",
        }
    )

    monitor_pid: int | None = None
    with FakeCmuxSocket(
        socket_path,
        None,
        surface_delivery_target=(FAKE_WORKSPACE_ID, FAKE_SURFACE_ID),
    ) as server:
        try:
            run_codex_hook(
                cli_path, socket_path, "session-start", hook_payload, environment
            )
            monitor_counts: list[int] = []
            for _ in range(3):
                run_codex_hook(
                    cli_path, socket_path, "prompt-submit", hook_payload, environment
                )
                monitor_counts.append(
                    len(wait_for_monitor_pids(session_id, present=True, timeout=5))
                )
            if monitor_counts != [1, 1, 1]:
                raise AssertionError(
                    "same-turn prompt submissions must retain one monitor: "
                    f"counts={monitor_counts}"
                )

            monitor_pids = wait_for_monitor_pids(
                session_id, present=True, timeout=5
            )
            if len(monitor_pids) != 1:
                raise AssertionError(
                    f"expected one synthetic monitor, saw {monitor_pids}"
                )
            monitor_pid = monitor_pids[0]
            baseline_kb = monitor_rss_kb(monitor_pid)

            samples: list[int] = []
            for index in range(1, TRANSCRIPT_WRITES + 1):
                question = append_synchronized_update(
                    transcript_path,
                    turn_id=turn_id,
                    index=index,
                )
                wait_for_raw_command(server, question)

                if index in CHECKPOINT_WRITES:
                    current_pids = monitor_pids_for_session(session_id)
                    if current_pids != [monitor_pid]:
                        raise AssertionError(
                            "single monitor identity changed during memory run: "
                            f"expected={[monitor_pid]} current={current_pids}"
                        )
                    samples.append(monitor_rss_kb(monitor_pid))

            if len(samples) != len(CHECKPOINT_WRITES):
                raise AssertionError(f"missing RSS checkpoints: {samples}")
            late_growth_kb = samples[-1] - samples[0]
            if late_growth_kb > MAX_LATE_GROWTH_KB:
                raise AssertionError(
                    "monitor RSS kept growing after transcript-tail warm-up: "
                    f"baseline={baseline_kb} samples={samples} "
                    f"late_growth_kb={late_growth_kb}"
                )

            run_codex_hook(cli_path, socket_path, "stop", hook_payload, environment)
            wait_for_monitor_pids(session_id, present=False, timeout=30)
        finally:
            for pid in monitor_pids_for_session(session_id):
                subprocess.run(["/bin/kill", str(pid)], check=False)


def main() -> int:
    """Run the isolated monitor memory regression and report its result."""
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    with tempfile.TemporaryDirectory(
        prefix="cmux-codex-monitor-memory-", dir="/tmp"
    ) as td:
        try:
            test_codex_monitor_rss_reaches_a_plateau(cli_path, Path(td))
        except Exception as exc:
            print(f"FAIL: {exc}")
            return 1

    print("PASS: Codex monitor RSS reaches a bounded plateau")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
