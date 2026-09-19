#!/usr/bin/env python3
"""
Regression: a retained Codex transcript monitor must not retain one parser tail
per filesystem wake.

This is an integration test around the real CLI monitor.  It uses only the
repository fake socket and synthetic JSONL rows, so no account or transcript
data is involved.
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
WRITE_INTERVAL_SECONDS = 0.15
IDLE_CONTROL_SECONDS = 2.0
MAX_LATE_GROWTH_KB = 16 * 1024
MAX_IDLE_GROWTH_KB = 8 * 1024


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


def test_codex_monitor_rss_reaches_a_plateau(cli_path: str, root: Path) -> None:
    """Verify bounded monitor RSS after synchronized synthetic transcript wakes."""
    socket_path = root / "cmux-monitor-memory.sock"
    state_dir = root / "hook-state-memory"
    transcript_path = root / "codex-session-memory.jsonl"
    state_dir.mkdir()
    transcript_path.write_text(
        json.dumps(
            {
                "type": "event_msg",
                "payload": {"type": "task_started", "turn_id": "synthetic-one-turn"},
            }
        )
        + "\n",
        encoding="utf-8",
    )

    session_id = f"codex-monitor-memory-session-{os.getpid()}"
    turn_id = "synthetic-one-turn"
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
    ):
        try:
            run_codex_hook(cli_path, socket_path, "session-start", hook_payload, environment)
            monitor_counts: list[int] = []
            for _ in range(3):
                run_codex_hook(cli_path, socket_path, "prompt-submit", hook_payload, environment)
                monitor_counts.append(
                    len(wait_for_monitor_pids(session_id, present=True, timeout=5))
                )
            if monitor_counts != [1, 1, 1]:
                raise AssertionError(
                    "same-turn prompt submissions must retain one monitor: "
                    f"counts={monitor_counts}"
                )

            monitor_pids = wait_for_monitor_pids(session_id, present=True, timeout=5)
            if len(monitor_pids) != 1:
                raise AssertionError(f"expected one synthetic monitor, saw {monitor_pids}")
            monitor_pid = monitor_pids[0]

            baseline_kb = monitor_rss_kb(monitor_pid)
            time.sleep(IDLE_CONTROL_SECONDS)
            idle_before_kb = monitor_rss_kb(monitor_pid)
            if idle_before_kb - baseline_kb > MAX_IDLE_GROWTH_KB:
                raise AssertionError(
                    "monitor RSS grew while the transcript was idle: "
                    f"baseline={baseline_kb} idle_before={idle_before_kb}"
                )

            samples: list[int] = []
            row = json.dumps(
                {
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
            ) + "\n"
            for index in range(TRANSCRIPT_WRITES):
                with transcript_path.open("a", encoding="utf-8") as transcript:
                    transcript.write(row)
                time.sleep(WRITE_INTERVAL_SECONDS)
                if index in (19, 39, 59):
                    # Leave a full parser window after each checkpoint so
                    # coalesced filesystem events have time to be consumed.
                    time.sleep(IDLE_CONTROL_SECONDS)
                    samples.append(monitor_rss_kb(monitor_pid))

            time.sleep(IDLE_CONTROL_SECONDS)
            idle_after_kb = monitor_rss_kb(monitor_pid)
            late_growth_kb = samples[-1] - samples[0]
            if late_growth_kb > MAX_LATE_GROWTH_KB:
                raise AssertionError(
                    "monitor RSS did not plateau after transcript-tail warm-up: "
                    f"samples={samples} late_growth_kb={late_growth_kb}"
                )
            if idle_after_kb - samples[-1] > MAX_IDLE_GROWTH_KB:
                raise AssertionError(
                    "monitor RSS grew during the post-write idle control: "
                    f"after_writes={samples[-1]} idle_after={idle_after_kb}"
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

    with tempfile.TemporaryDirectory(prefix="cmux-codex-monitor-memory-", dir="/tmp") as td:
        try:
            test_codex_monitor_rss_reaches_a_plateau(cli_path, Path(td))
        except Exception as exc:
            print(f"FAIL: {exc}")
            return 1

    print("PASS: Codex monitor RSS reaches a bounded plateau")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
