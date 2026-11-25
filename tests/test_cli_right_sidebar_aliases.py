#!/usr/bin/env python3
"""Exercise sidebar alias normalization through the built CLI's socket request."""

import os
import shlex
import socketserver
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path


class SidebarHandler(socketserver.StreamRequestHandler):
    def handle(self):
        while line := self.rfile.readline():
            self.server.commands.append(shlex.split(line.decode().strip()))
            self.wfile.write(b"OK\n")
            self.wfile.flush()


class SidebarAliasTests(unittest.TestCase):
    def test_aliases_send_the_canonical_cloud_mode(self):
        cli = os.environ["CMUX_CLI_BIN"]
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        with tempfile.TemporaryDirectory(prefix="sidebar-alias-", dir="/tmp") as root:
            test_home = str(Path(root) / "home")
            Path(test_home).mkdir()
            env.update(HOME=test_home, CFFIXED_USER_HOME=test_home)
            socket_path = str(Path(root) / "s")
            with socketserver.ThreadingUnixStreamServer(socket_path, SidebarHandler) as server:
                server.commands = []
                thread = threading.Thread(target=server.serve_forever, daemon=True)
                thread.start()
                try:
                    for alias in ["devices", "device", "macs", "cloud", "machines", "vms", "DEVICES"]:
                        for prefix, suffix in [([], []), (["set"], []), (["set"], ["--no-focus"])]:
                            args = [*prefix, alias, *suffix]
                            with self.subTest(args=args):
                                server.commands.clear()
                                result = subprocess.run(
                                    [cli, "--socket", socket_path, "right-sidebar", *args],
                                    env=env, capture_output=True, text=True, timeout=15
                                )
                                self.assertEqual(result.returncode, 0, result.stderr)
                                self.assertEqual(server.commands, [["right_sidebar", "set", "machines", *suffix]])
                finally:
                    server.shutdown()
                    thread.join(timeout=5)

    def test_blank_targets_are_rejected_before_the_socket(self):
        cli = os.environ["CMUX_CLI_BIN"]
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        with tempfile.TemporaryDirectory(prefix="sidebar-alias-", dir="/tmp") as root:
            socket_path = str(Path(root) / "s")
            for args, message in [
                (["toggle", "--window", ""], "right-sidebar: --window requires an id"),
                (["toggle", "--window="], "right-sidebar: --window requires an id"),
                (["toggle", "--workspace", " "], "right-sidebar: --workspace requires an id"),
            ]:
                with self.subTest(args=args):
                    result = subprocess.run(
                        [cli, "--socket", socket_path, "right-sidebar", *args],
                        env=env, capture_output=True, text=True, timeout=15
                    )
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(message, result.stderr)


if __name__ == "__main__":
    unittest.main()
