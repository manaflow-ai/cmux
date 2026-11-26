"""claude_login_cache.connect/disconnect: the proof's Claude connection, added from stdin and removed with its item."""
import json
import subprocess
import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts/cmux-next"))
import claude_login_cache  # noqa: E402

TOKEN = "sk-ant-oat01-" + "x" * 40


class ConnectTests(unittest.TestCase):
    def test_connect_sends_the_token_on_stdin_only_and_reads_the_id(self):
        answer = {"connection": {"id": "c-1", "serves_cloud": True},
                  "keychain": {"service": "cmux-model-key", "account": "claude-token-0a1b2c3d"}}
        done = subprocess.CompletedProcess([], 0, json.dumps(answer), "")
        with patch.object(claude_login_cache.subprocess, "run", return_value=done) as run:
            code, err, added = claude_login_cache.connect("/cmux", {}, TOKEN, "proof t")
        words = run.call_args.args[0]
        self.assertEqual(words[1:4], ["cloud", "connect", "claude"])
        self.assertIn("--token-stdin", words)
        self.assertFalse(any(TOKEN in w for w in words))
        self.assertEqual(run.call_args.kwargs["input"], TOKEN)
        self.assertEqual((code, added), (0, {"id": "c-1", "account": "claude-token-0a1b2c3d", "serves_cloud": True}))

    def test_connect_failure_adds_nothing(self):
        done = subprocess.CompletedProcess([], 2, "", "refused")
        with patch.object(claude_login_cache.subprocess, "run", return_value=done):
            self.assertEqual(claude_login_cache.connect("/cmux", {}, TOKEN, "l"), (2, "refused", None))

    def test_disconnect_names_the_keychain_item(self):
        done = subprocess.CompletedProcess([], 0, "{}", "")
        with patch.object(claude_login_cache.subprocess, "run", return_value=done) as run:
            claude_login_cache.disconnect("/cmux", {}, {"id": "c-1", "account": "claude-token-0a1b2c3d"})
            claude_login_cache.disconnect("/cmux", {}, {"id": "c-2", "account": None})
        self.assertEqual(run.call_args_list[0].args[0][1:],
                         ["cloud", "connections", "--remove", "c-1", "--keychain-account", "claude-token-0a1b2c3d"])
        self.assertEqual(run.call_args_list[1].args[0][1:], ["cloud", "connections", "--remove", "c-2"])


if __name__ == "__main__":
    unittest.main()
