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

    def test_app_label_does_not_resolve_the_computers_name(self) -> None:
        root = Path(__file__).resolve().parents[1]
        temporary = Path(self.fixture.name)
        # Compile only the label owner and its app caller; no app target or UI.
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors",
            "-emit-library", "-emit-module", "-module-name", "CmuxFoundation",
            "-emit-module-path", str(temporary / "CmuxFoundation.swiftmodule"),
            str(root / "Packages/macOS/CmuxFoundation/Sources/CmuxFoundation/RemoteClientDeviceName.swift"),
            "-o", str(temporary / "libCmuxFoundation.dylib"),
        ], check=True, capture_output=True)
        fixture = temporary / "cloud-hostname"
        subprocess.run([
            "xcrun", "swiftc", "-swift-version", "6", "-warnings-as-errors",
            "-I", str(temporary), "-L", str(temporary), "-lCmuxFoundation",
            "-Xlinker", "-rpath", "-Xlinker", str(temporary),
            str(root / "Sources/Cloud/CloudTuiClientPaths.swift"),
            str(root / "tests/fixtures/CloudHostnameFixture.swift"), "-o", str(fixture),
        ], check=True, capture_output=True)
        environment = {**os.environ, "DYLD_INSERT_LIBRARIES": self.library}
        result = subprocess.run([str(fixture)], env=environment, capture_output=True,
                                text=True, timeout=10, check=True)
        samples = json.loads(result.stdout)
        self.assertEqual([sample["phase"] for sample in samples], ["cold", "warm"])
        self.assertEqual(samples[0]["name"], samples[1]["name"])
        self.assertTrue(samples[0]["name"].startswith("cmux-"))
        self.assertIn("CMUX_TEST_HOSTNAME_TRIPWIRE_INSTALLED", result.stderr)
        self.assertNotIn("CMUX_TEST_HOSTNAME_RESOLVER_CALLED", result.stderr)
        print("app_hostname_timing=" + json.dumps([
            {key: sample[key] for key in ("phase", "duration_ms")} for sample in samples
        ]))

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
                           if not key.startswith("CMUX") and key != "DYLD_INSERT_LIBRARIES"}
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
                self.assertIn("CMUX_TEST_HOSTNAME_TRIPWIRE_INSTALLED", completed.stderr)
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
