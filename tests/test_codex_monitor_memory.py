#!/usr/bin/env python3
"""
Regression: a retained Codex transcript monitor must release parser temporaries
between transcript updates.

The test drives the real CLI monitor against FakeCmuxSocket and synthetic JSONL.
Each large assistant append is paired with a unique request_user_input marker;
the test waits until the monitor publishes that marker before the next append,
so every RSS checkpoint follows a known completed monitor wake instead of a
fixed timing delay.
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
)


TRANSCRIPT_WRITES = 60
TRANSCRIPT_MESSAGE_BYTES = 30_000
CHECKPOINT_INTERVAL = 20
MAX_LATE_GROWTH_KB = 16 * 1024
POLL_INTERVAL_SECONDS = 0.02


def monitor_rss_kb(pid: int) -> int:
    """Return the monitor's resident set size in KiB."""
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


def wait_for_monitor_count(
    session_id: str,
    expected_count: int,
    *,
    timeout: float = 5,
) -> list[int]:
    """Wait until the synthetic session has exactly the expected monitor count."""
    deadline = time.monotonic() + timeout
    last: list[int] = []
    while time.monotonic() < deadline:
        last = monitor_pids_for_session(session_id)
        if len(last) == expected_count:
            return last
        time.sleep(POLL_INTERVAL_SECONDS)
    raise AssertionError(
        f"expected {expected_count} monitor(s) for {session_id}, saw {last}"
    )


def wait_for_monitor_marker(
    fake: FakeCmuxSocket,
    marker: str,
    *,
    session_id: str,
    monitor_pid: int,
    timeout: float = 10,
) -> None:
    """Wait for the monitor to publish one unique transcript marker."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        for frame in list(fake.frames):
            raw = frame.get("raw") if isinstance(frame, dict) else None
            if isinstance(raw, str) and marker in raw:
                return
        if monitor_pid not in monitor_pids_for_session(session_id):
            raise AssertionError(
                f"monitor pid {monitor_pid} exited before publishing {marker}"
            )
        time.sleep(POLL_INTERVAL_SECONDS)
    raise AssertionError(f"monitor did not publish transcript marker {marker}")


def run_codex_hook(
    cli_path: str,
    socket_path: Path,
    subcommand: str,
    payload: dict[str, str],
    environment: dict[str, str],
) -> None:
    """Run one Codex lifecycle hook against the isolated fake socket."""
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


def test_codex_monitor_rss_reaches_a_plateau(cli_path: str, root: Path) -> None:
    """Verify repeated transcript parses stop adding retained RSS after warm-up."""
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

    with FakeCmuxSocket(
        socket_path,
        None,
        surface_delivery_target=(FAKE_WORKSPACE_ID, FAKE_SURFACE_ID),
    ) as fake:
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
                    len(wait_for_monitor_count(session_id, 1, timeout=5))
                )
            if monitor_counts != [1, 1, 1]:
                raise AssertionError(
                    "same-turn prompt submissions must retain one monitor: "
                    f"counts={monitor_counts}"
                )

            monitor_pids = wait_for_monitor_count(session_id, 1, timeout=5)
            monitor_pid = monitor_pids[0]
            samples: list[int] = []

            for index in range(TRANSCRIPT_WRITES):
                marker = f"cmux-memory-sync-{index:03d}"
                assistant_row = json.dumps(
                    {
                        "type": "response_item",
                        "payload": {
                            "type": "message",
                            "role": "assistant",
                            "content": [
                                {
                                    "type": "output_text",
                                    "text": (
                                        f"synthetic {index:03d} "
                                        + "x" * TRANSCRIPT_MESSAGE_BYTES
                                    ),
                                }
                            ],
                        },
                    }
                )
                marker_row = json.dumps(
                    {
                        "type": "event_msg",
                        "payload": {
                            "type": "request_user_input",
                            "turn_id": turn_id,
                            "call_id": marker,
                            "questions": [{"question": marker}],
                        },
                    }
                )
                with transcript_path.open("a", encoding="utf-8") as transcript:
                    transcript.write(assistant_row + "\n")
                    transcript.write(marker_row + "\n")

                wait_for_monitor_marker(
                    fake,
                    marker,
                    session_id=session_id,
                    monitor_pid=monitor_pid,
                )

                if (index + 1) % CHECKPOINT_INTERVAL == 0:
                    current_pids = wait_for_monitor_count(session_id, 1, timeout=5)
                    if current_pids != [monitor_pid]:
                        raise AssertionError(
                            "single monitor changed during transcript updates: "
                            f"expected={monitor_pid} saw={current_pids}"
                        )
                    samples.append(monitor_rss_kb(monitor_pid))

            if len(samples) != 3:
                raise AssertionError(f"expected three RSS checkpoints, saw {samples}")
            late_growth_kb = samples[-1] - samples[0]
            if late_growth_kb > MAX_LATE_GROWTH_KB:
                raise AssertionError(
                    "monitor RSS did not plateau after transcript-tail warm-up: "
                    f"samples={samples} late_growth_kb={late_growth_kb}"
                )

            run_codex_hook(cli_path, socket_path, "stop", hook_payload, environment)
            wait_for_monitor_count(session_id, 0, timeout=30)
        finally:
            for pid in monitor_pids_for_session(session_id):
                subprocess.run(["/bin/kill", str(pid)], check=False)


def main() -> int:
    """Run the isolated monitor memory regression."""
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
