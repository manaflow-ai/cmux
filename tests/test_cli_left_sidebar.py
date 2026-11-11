#!/usr/bin/env python3
"""Exercise `cmux left-sidebar` argument handling through the built CLI's socket request."""

import json
import os
import shlex
import socketserver
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

WINDOW_ID = "22222222-2222-2222-2222-222222222222"
WORKSPACE_ID = "11111111-1111-1111-1111-111111111111"


class SidebarHandler(socketserver.StreamRequestHandler):
    def handle(self):
        while line := self.rfile.readline():
            text = line.decode().strip()
            if text.startswith("{"):
                # Handle resolution never runs for the UUID targets used here.
                self.server.v2_requests.append(json.loads(text))
                reply = {"ok": False, "error": {"code": "unexpected", "message": "unexpected v2 request"}}
                self.wfile.write(json.dumps(reply).encode() + b"\n")
            else:
                command = shlex.split(text)
                self.server.commands.append(command)
                reply = '{"visible":true}' if "mode" in command else "OK"
                self.wfile.write(reply.encode() + b"\n")
            self.wfile.flush()


class LeftSidebarCLITests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.cli = os.environ["CMUX_CLI_BIN"]
        cls.env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        cls.root = tempfile.TemporaryDirectory(prefix="left-sidebar-", dir="/tmp")
        home = Path(cls.root.name) / "home"
        home.mkdir()
        cls.env.update(HOME=str(home), CFFIXED_USER_HOME=str(home))
        cls.socket_path = str(Path(cls.root.name) / "s")
        cls.server = socketserver.ThreadingUnixStreamServer(cls.socket_path, SidebarHandler)
        cls.server.commands = []
        cls.server.v2_requests = []
        cls.thread = threading.Thread(target=cls.server.serve_forever, daemon=True)
        cls.thread.start()

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()
        cls.server.server_close()
        cls.thread.join(timeout=5)
        cls.root.cleanup()

    def run_cli(self, *args):
        self.server.commands.clear()
        self.server.v2_requests.clear()
        return subprocess.run(
            [self.cli, "--socket", self.socket_path, "left-sidebar", *args],
            env=self.env, capture_output=True, text=True, timeout=15,
        )

    def test_actions_send_the_v1_command(self):
        for action in ["toggle", "show", "hide", "focus", "SHOW"]:
            with self.subTest(action=action):
                result = self.run_cli(action)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(self.server.commands, [["left_sidebar", action.lower()]])
                self.assertEqual(result.stdout, "")

    def test_mode_prints_the_state_reply(self):
        result = self.run_cli("mode")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.commands, [["left_sidebar", "mode"]])
        self.assertEqual(json.loads(result.stdout), {"visible": True})

    def test_targets_are_forwarded(self):
        for args in [
            ["hide", "--window", WINDOW_ID, "--workspace", WORKSPACE_ID],
            ["hide", f"--window={WINDOW_ID}", f"--workspace={WORKSPACE_ID}"],
        ]:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(
                    self.server.commands,
                    [["left_sidebar", "hide", f"--tab={WORKSPACE_ID}", f"--window={WINDOW_ID}"]],
                )

    def test_global_window_is_a_target_not_a_focus(self):
        args = ["--socket", self.socket_path, "--window", WINDOW_ID, "left-sidebar", "hide"]
        self.server.commands.clear()
        self.server.v2_requests.clear()
        result = subprocess.run([self.cli, *args], env=self.env, capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.server.v2_requests, [])
        self.assertEqual(self.server.commands, [["left_sidebar", "hide", f"--window={WINDOW_ID}"]])

    def test_rejected_input_never_reaches_the_socket(self):
        cases = [
            ([], "requires a subcommand"),
            (["state"], "Unknown left-sidebar command 'state'"),
            (["set", "files"], "Unknown left-sidebar command 'set'"),
            (["files"], "Unknown left-sidebar command 'files'"),
            (["toggle", "extra"], "left-sidebar toggle received unexpected arguments"),
            (["show", "--no-focus"], "left-sidebar: unknown flag '--no-focus'"),
            (["hide", "--window"], "left-sidebar: --window requires an id"),
            (["hide", "--workspace"], "left-sidebar: --workspace requires an id"),
            (["hide", "--window", ""], "left-sidebar: --window requires an id"),
            (["hide", "--window="], "left-sidebar: --window requires an id"),
            (["hide", "--workspace", "  "], "left-sidebar: --workspace requires an id"),
        ]
        for args, message in cases:
            with self.subTest(args=args):
                result = self.run_cli(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)
                self.assertEqual(self.server.commands, [])
                self.assertEqual(self.server.v2_requests, [])


class LeftSidebarReplyPrefixTests(unittest.TestCase):
    def test_translated_errors_keep_the_error_marker(self):
        # The CLI treats a socket reply as a failure only when it starts with
        # "ERROR:", so translations must keep that marker untranslated.
        catalog = Path(__file__).resolve().parents[1] / "Resources" / "Localizable.xcstrings"
        strings = json.loads(catalog.read_text())["strings"]
        keys = [key for key in strings if key.startswith("leftSidebar.remote.error.")]
        self.assertTrue(keys)
        for key in keys:
            for locale, entry in strings[key]["localizations"].items():
                with self.subTest(key=key, locale=locale):
                    self.assertTrue(entry["stringUnit"]["value"].startswith("ERROR: "))


if __name__ == "__main__":
    unittest.main()
