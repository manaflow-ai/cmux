#!/usr/bin/env python3
"""`cmux sessions list` finds a Claude transcript in any project folder.

The CLI looks only in the project folders that can hold an entry for the
session. These cases pin what it must find and what it must refuse. They do
not measure cost: the app-host and package tests count file checks.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


WORKSPACE_ID = "33B0D372-292E-42BF-97B6-E37CCA79AB84"
TRANSCRIPT_LINE = '{"type":"user","message":{"role":"user","content":"hello"}}\n'


class SessionsListClaudeTranscriptScanTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cli = os.environ["CMUX_CLI_BIN"]

    def setUp(self) -> None:
        self.root = tempfile.TemporaryDirectory(prefix="cmux-sessions-scan-")
        self.home = Path(self.root.name).resolve()
        self.state = self.home / "state"
        self.config = self.home / "claude-config"
        self.projects = self.config / "projects"
        self.state.mkdir()
        self.projects.mkdir(parents=True)
        # Folders that belong to other work, each with a transcript of its own.
        for index in range(4):
            folder = self.projects / f"-tmp-other-{index}"
            folder.mkdir()
            (folder / f"other-{index}.jsonl").write_text(TRANSCRIPT_LINE)

    def tearDown(self) -> None:
        self.root.cleanup()

    def write_records(self, session_ids: list[str]) -> None:
        sessions = {}
        for index, session_id in enumerate(session_ids):
            # The recorded cwd is not where the session started, so the folder
            # named after it holds nothing and the CLI has to look elsewhere.
            cwd = str(self.home / f"moved-here-{index}")
            sessions[session_id] = {
                "sessionId": session_id,
                "workspaceId": WORKSPACE_ID,
                "surfaceId": f"A2AECAA9-EE1C-4999-B7A9-{index:012d}",
                "cwd": cwd,
                "startedAt": 1_781_996_800.0,
                "updatedAt": 1_781_996_867.0 + index,
                "launchCommand": {
                    "launcher": "claude",
                    "executablePath": "/usr/local/bin/claude",
                    "arguments": ["/usr/local/bin/claude"],
                    "workingDirectory": cwd,
                    "environment": {"CLAUDE_CONFIG_DIR": str(self.config)},
                    "source": "environment",
                },
            }
        (self.state / "claude-hook-sessions.json").write_text(
            json.dumps({"version": 1, "sessions": sessions})
        )

    def restorable_by_session(self) -> dict[str, bool]:
        environment = {k: v for k, v in os.environ.items() if not k.startswith("CMUX")}
        environment.pop("CLAUDE_CONFIG_DIR", None)
        environment.update({
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_AGENT_HOOK_STATE_DIR": str(self.state),
            "HOME": str(self.home),
            "CFFIXED_USER_HOME": str(self.home),
        })
        result = subprocess.run(
            [self.cli, "sessions", "list", "--agent", "claude", "--json"],
            env=environment, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30, check=False,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        sessions = json.loads(result.stdout)["sessions"]
        return {session["session_id"]: session["hook_record_restorable"] for session in sessions}

    def test_transcript_in_another_project_folder_is_found(self) -> None:
        session_id = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"
        folder = self.projects / "-tmp-started-here"
        folder.mkdir()
        (folder / f"{session_id}.jsonl").write_text(TRANSCRIPT_LINE)
        self.write_records([session_id])

        self.assertEqual(self.restorable_by_session(), {session_id: True})

    def test_nested_transcript_in_another_project_folder_is_found(self) -> None:
        session_id = "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
        messages = self.projects / "-tmp-started-here" / session_id / "messages"
        messages.mkdir(parents=True)
        (messages / f"{session_id}.jsonl").write_text(TRANSCRIPT_LINE)
        self.write_records([session_id])

        self.assertEqual(self.restorable_by_session(), {session_id: True})

    def test_transcript_in_a_symlinked_project_folder_is_found(self) -> None:
        session_id = "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"
        elsewhere = self.home / "elsewhere"
        elsewhere.mkdir()
        (elsewhere / f"{session_id}.jsonl").write_text(TRANSCRIPT_LINE)
        (self.projects / "-tmp-linked").symlink_to(elsewhere, target_is_directory=True)
        self.write_records([session_id])

        self.assertEqual(self.restorable_by_session(), {session_id: True})

    def test_workflow_folder_in_another_project_folder_resolves_to_its_sibling(self) -> None:
        workflow = "aaaaaaaa-1111-4111-8111-aaaaaaaaaaaa"
        resumable = "bbbbbbbb-2222-4222-8222-bbbbbbbbbbbb"
        folder = self.projects / "-tmp-started-here"
        (folder / workflow / "subagents").mkdir(parents=True)
        (folder / f"{resumable}.jsonl").write_text(TRANSCRIPT_LINE)
        self.write_records([workflow])

        self.assertEqual(self.restorable_by_session(), {resumable: True})

    def test_sessions_without_a_transcript_are_not_restorable(self) -> None:
        found = "ffffffff-ffff-4fff-8fff-ffffffffffff"
        empty = "11111111-1111-4111-8111-111111111111"
        never_written = [f"stale-{index}" for index in range(6)]
        folder = self.projects / "-tmp-started-here"
        folder.mkdir()
        (folder / f"{found}.jsonl").write_text(TRANSCRIPT_LINE)
        (folder / f"{empty}.jsonl").write_text("")
        # A file in projects/ that is not a folder holds no session.
        (self.projects / f"{never_written[0]}.jsonl").write_text(TRANSCRIPT_LINE)
        self.write_records([found, empty, *never_written])

        expected = {found: True, empty: False}
        expected.update({session_id: False for session_id in never_written})
        self.assertEqual(self.restorable_by_session(), expected)


if __name__ == "__main__":
    unittest.main()
