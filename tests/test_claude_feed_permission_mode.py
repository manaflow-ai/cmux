#!/usr/bin/env python3
"""Claude's PermissionRequest hook does not wait on the Feed when nobody is asked.

In `auto`, `dontAsk` and `bypassPermissions` mode Claude Code does not ask the
user through this hook, so a Feed card for the request can't be answered and
the hook would hold every tool call until its deadline (#40375). The hook
answers `{}` at once and pushes nothing, since Claude's own PreToolUse hook
already reports the call. Runs the real CLI against a fake app socket.
"""
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import FAKE_SURFACE_ID, FAKE_WORKSPACE_ID, FakeCmuxSocket


def permission_request(permission_mode, tool_name="Bash"):
    payload = {
        "session_id": "claude-permission-mode-session",
        "cwd": "/tmp/claude-project",
        "hook_event_name": "PermissionRequest",
        "tool_name": tool_name,
        "tool_input": {"command": "rm -f /tmp/claude-project/scratch.txt"},
    }
    if permission_mode is not None:
        payload["permission_mode"] = permission_mode
    return payload


def run_claude_feed_hook(cli_path, socket_path, payload):
    """Run `hooks feed --source claude`; return its stdout and the feed.push frame, if any.

    The fake socket answers the delivery-target lookup an approval needs before
    it is pushed, so a blocking request reaches `feed.push` like in the app.
    """
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
            [cli_path, "--socket", str(socket_path), "hooks", "feed", "--source", "claude",
             "--event", payload["hook_event_name"]],
            input=json.dumps(payload),
            capture_output=True,
            text=True,
            check=False,
            env=env,
            timeout=30,
        )
    if result.returncode != 0:
        raise AssertionError(f"hooks feed failed exit={result.returncode}\nstderr={result.stderr}")
    stdout = json.loads(result.stdout.strip() or "{}")
    frame = next((f for f in fake.frames if f.get("method") == "feed.push"), None)
    return stdout, frame


class ClaudeFeedPermissionModeTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cmux-claude-mode-')
        self.addCleanup(self.temp.cleanup)
        self.cli = str(resolve_cmux_cli())

    def socket(self, name):
        return Path(self.temp.name) / f'{name}.sock'

    def test_unprompted_modes_answer_at_once_and_push_nothing(self):
        for mode in ("auto", "dontAsk", "bypassPermissions"):
            with self.subTest(mode=mode):
                stdout, frame = run_claude_feed_hook(self.cli, self.socket(mode), permission_request(mode))
                self.assertEqual(stdout, {}, 'no decision, so Claude decides on its own')
                self.assertIsNone(frame, 'PreToolUse already reports this call')

    def test_prompted_modes_still_wait_for_a_feed_decision(self):
        for mode in ("default", "acceptEdits", "plan", None, ""):
            with self.subTest(mode=mode):
                _, frame = run_claude_feed_hook(self.cli, self.socket(f'prompted-{mode}'), permission_request(mode))
                self.assertIsNotNone(frame, 'a prompted mode still pushes the approval')
                params = frame["params"]
                self.assertGreater(params.get("wait_timeout_seconds", 0), 0, frame)
                self.assertEqual(params["event"].get("hook_event_name"), "PermissionRequest", frame)

    def test_questions_still_wait_in_auto_mode(self):
        # AskUserQuestion goes to the user in every mode.
        _, frame = run_claude_feed_hook(
            self.cli, self.socket('ask'), permission_request("auto", tool_name="AskUserQuestion")
        )
        self.assertIsNotNone(frame, 'questions still reach the Feed')
        params = frame["params"]
        self.assertGreater(params.get("wait_timeout_seconds", 0), 0, frame)
        self.assertEqual(params["event"].get("hook_event_name"), "AskUserQuestion", frame)


if __name__ == '__main__':
    unittest.main()
