#!/usr/bin/env python3
"""An acknowledged viewer replaces its launcher's active-session boundary.

Run against a freshly built candidate CLI. All socket/state/config data are
isolated. The real user's cmux socket and Claude configuration are never used.
"""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest
import uuid

from fake_socket_env import cli_environment
from test_claude_hook_clear_running_status import HookSocketServer, resolve_cmux_cli, run_claude_hook


class ViewerActiveSessionTests(unittest.TestCase):
    def test_acknowledged_worker_stop_is_not_rejected_as_launcher_session(self):
        cli = resolve_cmux_cli()
        workspace, surface, launcher, worker, attachment = [str(uuid.uuid4()) for _ in range(5)]
        with tempfile.TemporaryDirectory(prefix="cmux-viewer-active-") as directory:
            home = Path(directory)
            config = home / ".claude"
            (config / "sessions").mkdir(parents=True)
            pid = os.getpid()
            # Match the real parent process generation, with the same UTC
            # procStart representation used by Claude's session registry.
            started = subprocess.check_output(
                ["ps", "-p", str(pid), "-o", "lstart="],
                env={**os.environ, "TZ": "UTC", "LC_ALL": "C"}, text=True,
            ).strip()
            (config / "sessions" / f"{pid}.json").write_text(json.dumps({
                "kind": "bg", "pid": pid, "sessionId": worker,
                "jobId": worker[:8], "procStart": started, "pidDomain": "darwin",
            }))
            state_path = home / "hooks.json"
            now = time.time()
            state_path.write_text(json.dumps({
                "version": 1,
                "sessions": {launcher: {
                    "sessionId": launcher, "workspaceId": workspace, "surfaceId": surface,
                    "pid": pid, "startedAt": now, "updatedAt": now,
                }},
                "activeSessionsBySurface": {surface: {"sessionId": launcher, "updatedAt": now}},
                "activeSessionsByWorkspace": {workspace: {"sessionId": launcher, "updatedAt": now}},
            }))
            with HookSocketServer(workspace, surface) as server:
                env = cli_environment(server.socket_path, home=directory)
                env.update(CLAUDE_CONFIG_DIR=str(config), CMUX_CLAUDE_HOOK_STATE_PATH=str(state_path),
                           CMUX_CLAUDE_PID=str(pid), CMUX_WORKSPACE_ID=workspace, CMUX_SURFACE_ID=surface)
                admitted = subprocess.run(
                    [cli, "--socket", server.socket_path, "__claude-viewer", "attached"],
                    input=json.dumps({"attach_id": attachment, "job_id": worker[:8], "viewer_pid": pid}),
                    env=env, capture_output=True, text=True, timeout=8,
                )
                self.assertEqual(admitted.returncode, 0, admitted.stderr)
                state = json.loads(state_path.read_text())
                self.assertEqual(state["activeSessionsBySurface"][surface]["sessionId"], worker)
                self.assertEqual(state["activeSessionsByWorkspace"][workspace]["sessionId"], worker)
                server.commands.clear()
                run_claude_hook(cli, server.socket_path, "stop", {
                    "session_id": worker, "hook_event_name": "Stop", "cwd": directory,
                    "last_assistant_message": "isolated test completion",
                }, env)
                self.assertFalse(any("superseded-stale" in command for command in server.commands))
                self.assertTrue(any("agent.turn.completed" in command for command in server.commands))


if __name__ == "__main__":
    unittest.main()
