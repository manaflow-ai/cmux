#!/usr/bin/env python3
"""Changes during a monitor notification must survive until its next read."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import FAKE_SURFACE_ID, FAKE_WORKSPACE_ID, FakeCmuxSocket
from test_codex_monitor_memory import append_synchronized_update, wait_for_raw_command


class CodexMonitorWakeupTests(unittest.TestCase):
    def exercise_change_during_notification(self, *, retire_lease: bool) -> None:
        cli = resolve_cmux_cli()
        with tempfile.TemporaryDirectory(prefix="cmux-monitor-wakeup-", dir="/tmp") as td:
            root = Path(td)
            transcript = root / "transcript.jsonl"
            socket_path = root / "socket"
            lease_path = root / "lease.json"
            turn_id = "wakeup-turn"
            session_id = f"wakeup-{os.getpid()}"
            transcript.write_text(json.dumps({
                "type": "event_msg",
                "payload": {"type": "task_started", "turn_id": turn_id},
            }) + "\n")
            first = append_synchronized_update(transcript, turn_id=turn_id, index=1)
            lease = {
                "leaseId": "wakeup-lease", "sessionId": session_id, "turnId": turn_id,
                "workspaceId": FAKE_WORKSPACE_ID, "surfaceId": FAKE_SURFACE_ID,
                "createdAt": time.time(), "retiredAt": None,
            }
            lease_path.write_text(json.dumps(lease))
            changed = threading.Event()

            def change_before_acknowledging(command: str) -> None:
                if not command.startswith("notify_target ") or first not in command or changed.is_set():
                    return
                # The CLI is awaiting this socket reply, so the change happens
                # after its read and before it can start its next wait.
                if retire_lease:
                    lease["retiredAt"] = time.time()
                    replacement = root / "replacement.json"
                    replacement.write_text(json.dumps(lease))
                    replacement.replace(lease_path)
                else:
                    append_synchronized_update(transcript, turn_id=turn_id, index=2)
                changed.set()

            env = os.environ.copy()
            for key in ("CMUX_SOCKET", "CMUX_SOCKET_PASSWORD", "CMUX_SOCKET_CAPABILITY"):
                env.pop(key, None)
            env.update(CMUX_SOCKET_PATH=str(socket_path), CMUX_CLI_SENTRY_DISABLED="1")
            with FakeCmuxSocket(socket_path, None, raw_response_hook=change_before_acknowledging) as server:
                process = subprocess.Popen([
                    cli, "--socket", str(socket_path), "hooks", "codex", "monitor",
                    "--session", session_id, "--turn", turn_id,
                    "--workspace", FAKE_WORKSPACE_ID, "--surface", FAKE_SURFACE_ID,
                    "--transcript", str(transcript), "--lease", str(lease_path),
                ], env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                try:
                    self.assertTrue(changed.wait(timeout=5), "monitor never published its first request")
                    if retire_lease:
                        self.assertEqual(process.wait(timeout=5), 0)
                    else:
                        wait_for_raw_command(server, "memory checkpoint 2")
                        self.assertIsNone(process.poll(), "monitor exited before its turn settled")
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=3)

    def test_transcript_append_during_notification_is_not_lost(self) -> None:
        self.exercise_change_during_notification(retire_lease=False)

    def test_lease_retirement_during_notification_wakes_monitor(self) -> None:
        self.exercise_change_during_notification(retire_lease=True)


if __name__ == "__main__":
    unittest.main()
