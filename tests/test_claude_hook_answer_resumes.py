#!/usr/bin/env python3
"""Successful blocking-tool completions resume Claude's persisted lifecycle."""

import json
import os
from pathlib import Path
import subprocess
import unittest
import uuid

from fake_socket_env import cli_environment
from test_claude_hook_clear_running_status import (
    HookSocketServer,
    resolve_cmux_cli,
    run_claude_hook,
    stored_lifecycle,
)
from test_claude_wrapper_hooks import generated_claude_hook_settings


class ClaudeHookAnswerResumesTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(os.environ.get("CMUX_CLI_BIN"), "Set CMUX_CLI_BIN to the built CLI")
        self.cli = resolve_cmux_cli()
        self.workspace, self.surface, self.session = (str(uuid.uuid4()) for _ in range(3))
        self.server = HookSocketServer(self.workspace, self.surface)
        self.server.__enter__()
        self.addCleanup(self.server.__exit__, None, None, None)
        self.state = Path(self.server.root.name) / "sessions.json"
        self.env = {
            key: value for key, value in cli_environment(home=self.server.root.name).items()
            if not key.lower().startswith("cmux_")
        }
        self.env.update({
            "CMUX_SOCKET_PATH": self.server.socket_path,
            "CMUX_SOCKET": self.server.socket_path,
            "CMUX_WORKSPACE_ID": self.workspace,
            "CMUX_SURFACE_ID": self.surface,
            "CMUX_CLAUDE_PID": str(os.getpid()),
            "CMUX_CLAUDE_HOOK_STATE_PATH": str(self.state),
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
            "XDG_CONFIG_HOME": str(Path(self.server.root.name) / ".config"),
        })
        self.payload = {
            "session_id": self.session,
            "turn_id": "turn-1",
            "cwd": self.server.root.name,
        }
        self.invoke("session-start", source="startup")
        self.invoke("prompt-submit")
        self.assertEqual(stored_lifecycle(self.state, self.session), "running")

    def invoke(self, command, **fields):
        start = len(self.server.commands)
        run_claude_hook(
            self.cli, self.server.socket_path, command,
            {**self.payload, **fields}, self.env,
        )
        self.server.drain()
        self.last_commands = self.server.commands[start:]

    def feed_events(self):
        """Return app Feed events emitted by the most recent hook invocation."""
        requests = [json.loads(line) for line in self.last_commands if line.startswith("{")]
        return [request["params"]["event"] for request in requests
                if request.get("method") == "feed.push"]

    def assert_no_completion_effects(self):
        self.assertEqual(self.feed_events(), [])
        self.assertFalse(any(line.startswith(("agent_journal_append ", "set_status ",
                                              "clear_notifications "))
                             for line in self.last_commands), self.last_commands)

    def assert_completion_effects(self):
        events = self.feed_events()
        self.assertEqual(len(events), 1, events)
        self.assertEqual(events[0]["hook_event_name"], "PostToolUse")
        journals = [json.loads(line.removeprefix("agent_journal_append "))
                    for line in self.last_commands if line.startswith("agent_journal_append ")]
        self.assertTrue(any(event.get("native_event") == "PostToolUse"
                            and event.get("declared_phase") == "running" for event in journals), journals)
        self.assertTrue(any(line.startswith("set_status claude_code ")
                            and "--icon=bolt.fill" in line for line in self.last_commands), self.last_commands)

    def block(self, tool):
        self.invoke(
            "pre-tool-use", hook_event_name="PreToolUse", tool_name=tool,
            permission_mode="bypassPermissions",
        )
        self.assertEqual(stored_lifecycle(self.state, self.session), "needsInput")

    def complete(self, tool):
        self.invoke("post-tool-use", hook_event_name="PostToolUse", tool_name=tool)

    def test_question_completion_resumes(self):
        self.block("AskUserQuestion")
        self.complete("AskUserQuestion")
        self.assertEqual(stored_lifecycle(self.state, self.session), "running")
        self.assert_completion_effects()

    def test_plan_completion_resumes(self):
        self.block("ExitPlanMode")
        self.complete("ExitPlanMode")
        self.assertEqual(stored_lifecycle(self.state, self.session), "running")
        self.assert_completion_effects()

    def test_unrelated_completion_preserves_waiting(self):
        self.block("AskUserQuestion")
        before = self.state.read_bytes()
        self.complete("Read")
        self.assertEqual(stored_lifecycle(self.state, self.session), "needsInput")
        self.assertEqual(self.state.read_bytes(), before)
        self.assert_no_completion_effects()

    def test_late_completion_does_not_reopen_stopped_turn(self):
        for tool in ("AskUserQuestion", "ExitPlanMode"):
            with self.subTest(tool=tool):
                self.invoke("prompt-submit")
                self.block(tool)
                self.invoke("stop", last_assistant_message="Synthetic completed turn")
                record = json.loads(self.state.read_text())["sessions"][self.session]
                self.assertTrue(record["turnSettled"])
                self.assertEqual(record["agentLifecycle"], "idle")
                before = self.state.read_bytes()
                self.complete(tool)
                self.assertEqual(self.state.read_bytes(), before)
                self.assert_no_completion_effects()

    def test_stale_turn_completion_preserves_waiting(self):
        self.block("AskUserQuestion")
        before = self.state.read_bytes()
        self.invoke(
            "post-tool-use", hook_event_name="PostToolUse",
            tool_name="AskUserQuestion", turn_id="superseded-turn",
        )
        self.assertEqual(self.state.read_bytes(), before)
        self.assert_no_completion_effects()
        self.complete("AskUserQuestion")
        self.assertEqual(stored_lifecycle(self.state, self.session), "running")

    def test_suppressed_nested_completion_preserves_waiting(self):
        self.block("AskUserQuestion")
        before = self.state.read_bytes()
        self.env["CMUX_AGENT_HOOK_SUPPRESS_VISIBLE_MUTATIONS"] = "1"
        self.complete("AskUserQuestion")
        self.assertEqual(self.state.read_bytes(), before)
        self.assert_no_completion_effects()

    def test_superseded_session_completion_preserves_waiting(self):
        old_session = self.session
        self.session = str(uuid.uuid4())
        self.payload["session_id"] = self.session
        self.invoke("session-start", source="clear")
        self.invoke("prompt-submit")
        self.block("AskUserQuestion")
        before = self.state.read_bytes()
        self.invoke("post-tool-use", hook_event_name="PostToolUse",
                    tool_name="AskUserQuestion", session_id=old_session)
        self.assertEqual(self.state.read_bytes(), before)
        self.assert_no_completion_effects()

    def test_generated_settings_register_queued_completions(self):
        result = subprocess.run(
            [self.cli, "hooks", "claude", "inject-settings"], env=self.env,
            capture_output=True, text=True, timeout=30, check=True,
        )
        self.assertEqual(result.stdout, generated_claude_hook_settings())
        groups = json.loads(result.stdout)["hooks"]["PostToolUse"]
        completions = [group for group in groups
                       if group.get("matcher") == "AskUserQuestion|ExitPlanMode"]
        self.assertEqual(len(completions), 1)
        self.assertEqual(len(completions[0]["hooks"]), 1)
        self.assertIn("hooks enqueue claude post-tool-use", completions[0]["hooks"][0]["command"])
        self.assertEqual(sum(group.get("matcher") == "PushNotification" for group in groups), 1)


if __name__ == "__main__":
    unittest.main()
