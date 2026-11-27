#!/usr/bin/env python3
"""The Copilot Feed bridge forwards Copilot's own payload keys.

Copilot CLI hands `preToolUse` hooks a camelCase payload: `sessionId`, `cwd`,
`toolName` and `toolArgs`. The Feed event built from it must carry the tool
name and arguments, or the Feed shows a bare tool call with no command or
file. Runs the real CLI against a fake app socket and inspects the pushed
frame; the hooks file itself is covered by test_cli_copilot_hooks_file.py.
"""
import json
import tempfile
import unittest
from pathlib import Path

from claude_teams_test_utils import resolve_cmux_cli
from test_codex_feed_hooks import FAKE_SURFACE_ID, FAKE_WORKSPACE_ID, run_feed_hook_optional_frame


class CopilotFeedPayloadTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='cmux-copilot-feed-')
        self.addCleanup(self.temp.cleanup)
        self.cli = str(resolve_cmux_cli())

    def test_pre_tool_use_forwards_tool_name_and_tool_args(self):
        payload = {
            "hook_event_name": "preToolUse",
            "sessionId": "copilot-session-1",
            "timestamp": 1760000000000,
            "cwd": "/tmp/copilot-project",
            "toolName": "shell",
            "toolArgs": {"command": "git status --short", "description": "Check the tree"},
        }
        stdout, frame = run_feed_hook_optional_frame(
            self.cli, Path(self.temp.name) / 'cmux.sock', payload, None, source="copilot")
        self.assertEqual(stdout, {}, 'a telemetry-only event never blocks the tool')
        self.assertIsNotNone(frame, 'the preToolUse event must reach the Feed')
        event = frame["params"]["event"]
        self.assertEqual(event.get("_source"), "copilot", event)
        # The Feed keeps Claude's spelling for the event name and derives its own
        # session id; what must survive untouched is the tool call itself.
        self.assertEqual(event.get("hook_event_name"), "PreToolUse", event)
        self.assertTrue(event.get("session_id"), event)
        self.assertEqual(event.get("workspace_id"), FAKE_WORKSPACE_ID, event)
        self.assertEqual(event.get("surface_id"), FAKE_SURFACE_ID, event)
        self.assertEqual(event.get("cwd"), "/tmp/copilot-project", event)
        self.assertEqual(event.get("tool_name"), "shell", event)
        self.assertEqual(event.get("tool_input"), payload["toolArgs"], event)

    def run_pre_tool_use(self, tool_args):
        payload = {
            "hook_event_name": "preToolUse",
            "sessionId": "copilot-session-1",
            "timestamp": 1760000000000,
            "cwd": "/tmp/copilot-project",
            "toolName": "shell",
            "toolArgs": tool_args,
        }
        stdout, frame = run_feed_hook_optional_frame(
            self.cli, Path(self.temp.name) / 'cmux.sock', payload, None, source="copilot")
        self.assertEqual(stdout, {}, 'a telemetry-only event never blocks the tool')
        self.assertIsNotNone(frame, 'the preToolUse event must reach the Feed')
        return frame["params"]["event"]

    def test_pre_tool_use_decodes_json_string_tool_args(self):
        # Copilot's docs show toolArgs as a JSON-encoded string.
        event = self.run_pre_tool_use(json.dumps({"command": "ls", "description": "List files"}))
        self.assertEqual(event.get("tool_name"), "shell", event)
        self.assertEqual(event.get("tool_input"), {"command": "ls", "description": "List files"}, event)

    def test_pre_tool_use_keeps_non_json_string_tool_args(self):
        event = self.run_pre_tool_use("not json")
        self.assertEqual(event.get("tool_input"), "not json", event)


if __name__ == '__main__':
    unittest.main()
