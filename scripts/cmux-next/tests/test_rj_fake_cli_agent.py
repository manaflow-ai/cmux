#!/usr/bin/env python3
"""rj_fake_cli_agent.py: the restore journey's stand-in for the claude and codex CLIs reports the
flags a person gave it. After a reboot the respawned shell puts the cmux shims first on PATH, so
the resume runs through a shim that folds its hook arguments in and names the arguments it was
given in CMUX_TUI_AGENT_ARGS; the reported flags are those, not the shim's hook arguments."""

import json
import os
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

AGENT = Path(__file__).resolve().parent.parent / "rj_fake_cli_agent.py"


def start(provider, argv, account, log, env_extra=None):
    """Run the stand-in with `argv`, end its input at once, and return its start event."""
    env = {"PATH": os.environ.get("PATH", "/usr/bin:/bin"), "RJ_AGENT_LOG": str(log),
           ("CLAUDE_CONFIG_DIR" if provider == "claude" else "CODEX_HOME"): str(account), **(env_extra or {})}
    subprocess.run([sys.executable, "-I", str(AGENT), provider, *argv], env=env, input=b"", capture_output=True, timeout=30)
    events = [json.loads(line) for line in log.read_text().splitlines()]
    return [e for e in events if e["event"] == "start"][-1]


class FakeCliAgentTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.account = self.root / "account"
        self.account.mkdir()
        (self.account / "rj-login").touch()
        self.log = self.root / "agents.jsonl"

    def tearDown(self):
        self.tmp.cleanup()

    def test_direct_run_reports_its_own_flags(self):
        first = start("codex", ["-m", "gpt-5.5", "--search"], self.account, self.log)
        self.assertEqual(first["flags"], "-m gpt-5.5 --search")
        self.assertFalse(first["resumed"])

    def test_a_shim_run_reports_the_flags_the_shim_was_given(self):
        session = start("codex", ["-m", "gpt-5.5", "--search"], self.account, self.log)["session"]
        hooks = ["--enable", "hooks", "-c", 'hooks.SessionStart=[{hooks=[{type="command",command="x"}]}]']
        given = ["resume", session, "-m", "gpt-5.5", "--search"]
        resumed = start("codex", hooks + given, self.account, self.log,
                        {"CMUX_TUI_AGENT_ARGS": json.dumps(given)})
        self.assertTrue(resumed["resumed"])
        self.assertEqual(resumed["session"], session)
        self.assertEqual(resumed["flags"], "-m gpt-5.5 --search")

    def test_a_claude_shim_run_drops_its_settings_file(self):
        session = start("claude", ["--model", "claude-sonnet-5-5"], self.account, self.log)["session"]
        given = ["--resume", session, "--model", "claude-sonnet-5-5"]
        resumed = start("claude", ["--settings", "/tmp/claude-settings/x.json"] + given, self.account, self.log,
                        {"CMUX_TUI_AGENT_ARGS": json.dumps(given)})
        self.assertEqual(resumed["session"], session)
        self.assertEqual(resumed["flags"], "--model claude-sonnet-5-5")


if __name__ == "__main__":
    unittest.main()
