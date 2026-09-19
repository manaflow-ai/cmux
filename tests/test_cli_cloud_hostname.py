#!/usr/bin/env python3
"""Exercise Cloud attach naming with the hostname resolver forbidden.

Uses the built CLI, an isolated home and socket, and a test-only Objective-C
tripwire. No app launch, Cloud allocation, DNS request, or privacy change.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import tempfile
import unittest
import uuid

from test_cli_vm_resize import ResizeSocket


class CloudHostnameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cli = os.environ.get("CMUX_CLI_BIN", "")
        if not cls.cli or not os.access(cls.cli, os.X_OK):
            raise RuntimeError("Set CMUX_CLI_BIN to the built CLI")
        cls.fixture = tempfile.TemporaryDirectory(prefix="cloud-hostname-", dir="/tmp")
        cls.addClassCleanup(cls.fixture.cleanup)
        cls.library = str(Path(cls.fixture.name, "resolver-tripwire.dylib"))
        source = Path(__file__).parent / "fixtures/cloud-hostname-resolver-tripwire.m"
        subprocess.run(["xcrun", "clang", "-dynamiclib", "-framework", "Foundation",
                        str(source), "-o", cls.library], check=True, capture_output=True)

    def test_cloud_attach_does_not_resolve_the_computers_name(self) -> None:
        workspace = str(uuid.uuid4())
        result = {
            "route": "ws://10.0.0.2:1337/v1/link",
            "trusted_carrier": True,
            "wireguard_hub_socket": "/unused/isolated-hub.sock",
            "workspace_id": workspace,
            "window_id": str(uuid.uuid4()),
        }
        with ResizeSocket(result) as server:
            environment = {key: value for key, value in os.environ.items()
                           if not key.startswith(("CMUX", "DYLD_"))}
            environment.update({
                "CFFIXED_USER_HOME": server.root.name,
                "CMUX_CLI_SENTRY_DISABLED": "1",
                "DYLD_INSERT_LIBRARIES": self.library,
                "AppleLanguages": "(en)",
            })
            # A disposable probe client; no remote process is ever launched.
            client = Path(server.root.name, "cmux-tui")
            client.write_text('#!/bin/sh\nprintf \'%s\\n\' \'{"app":"cmux-tui",'
                              '"capabilities":["wireguard-hub"]}\'\n')
            client.chmod(0o700)
            environment["CMUX_TUI_CLIENT"] = str(client)
            completed = subprocess.run(
                [self.cli, "--socket", server.path, "vm", "tui", "hostname-test", "--json"],
                env=environment, stdin=subprocess.DEVNULL, capture_output=True,
                text=True, timeout=30, check=False,
            )
            configs = []
            try:
                for request in server.requests:
                    if request["method"] == "workspace.create":
                        command = shlex.split(request["params"]["initial_command"])
                        config_path = Path(command[command.index("--config") + 1])
                        configs.append(config_path)
                self.assertEqual(completed.returncode, 0, completed.stderr)
                self.assertEqual(len(configs), 1, server.requests)
                config = json.loads(configs[0].read_text())
                raw = socket.gethostname().split(".")[0] or "mac"
                expected = "cmux-" + "".join(c if c.isalnum() or c == "-" else "-"
                                             for c in raw)[:40]
                self.assertEqual(config["deviceName"], expected)
                self.assertNotIn("CMUX_TEST_HOSTNAME_RESOLVER_CALLED", completed.stderr)
            finally:
                for config_path in configs:
                    config_path.unlink(missing_ok=True)


if __name__ == "__main__":
    unittest.main(verbosity=2)
