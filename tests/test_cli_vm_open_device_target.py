#!/usr/bin/env python3
"""`cmux vm open` must accept the device addresses that `cmux vm tree` prints.

Another Mac signed into the same account is addressed as
`device:<uuid>@<tag>` (see SurfaceMachineID). The tree prints
`cmux vm open device:<uuid>@<tag>/<workspace>/<terminal>[/<tab>]` for each of
its terminals, and the CLI must parse that address exactly as printed: the
colon inside the device id is part of the machine, not the start of a
`:desktop` / `:port/<n>` selector. The built CLI runs against a fake socket that
plays the app's `surface.catalog` / `surface.project` side, so the assertion is
on the request the CLI sends, not on a live device link.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest

DEVICE = "device:692bcbc8-462d-4432-aa00-ce5600ab2386@issue-8001-devices-sidebar"
REMOTE_WORKSPACE = "83652D32-B1E7-4397-9750-5A0553E8AE9B"
TERMINAL = "6C272F23-5E1F-45DB-A7DB-874F94C34E86"
LOCAL_WORKSPACE = "35623490-556B-4918-8529-C2621348A870"
RESOURCE = f"{DEVICE}/terminal/{TERMINAL}"

WORKSPACE_ROW = {"focused": False, "id": REMOTE_WORKSPACE, "index": 0, "name": "~"}
CATALOG = {
    "cloud_states": {},
    "projections": [],
    "machines": [
        {
            "id": DEVICE,
            "kind": "device",
            "link_state": "connected",
            "local": False,
            "name": "cmux’s Mac mini (2) (issue-8001-devices-sidebar)",
            "remote_workspaces": [WORKSPACE_ROW],
        }
    ],
    "resources": [
        {
            "id": RESOURCE,
            "key": TERMINAL,
            "kind": "terminal",
            "machine": DEVICE,
            "title": "~",
            "detail": "/Users/cmux",
            "open": False,
            "open_surface_ids": [],
            "open_workspace_ids": [],
            "remote_workspace": WORKSPACE_ROW,
            "remote_views": [
                {"focused": False, "index": 0, "tab_id": TERMINAL, "workspace": WORKSPACE_ROW}
            ],
        }
    ],
}
PROJECTED = {
    "panel_id": "80D1B122-F887-4A44-9E15-4D6FDFA12C4D",
    "surface_id": "80D1B122-F887-4A44-9E15-4D6FDFA12C4D",
    "workspace_id": LOCAL_WORKSPACE,
    "resource": RESOURCE,
    "remote_workspace_id": REMOTE_WORKSPACE,
    "remote_tab_id": TERMINAL,
    "reused": False,
}


class DeviceOpenSocket:
    """Answers `surface.catalog` and `surface.project` like the app would for a
    connected Mac; every other method gets an empty result so the CLI's
    bookkeeping calls never mask the assertion."""

    def __init__(self) -> None:
        self.requests: list[dict] = []
        self.errors: list[Exception] = []
        self.stopped = threading.Event()

    def __enter__(self) -> "DeviceOpenSocket":
        self.root = tempfile.TemporaryDirectory(prefix="vm-open-device-", dir="/tmp")
        self.path = str(Path(self.root.name, "socket"))
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(2)
        self.listener.settimeout(0.1)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()
        return self

    def __exit__(self, *_args: object) -> None:
        self.stopped.set()
        self.thread.join(timeout=2)
        self.listener.close()
        self.root.cleanup()
        if self.thread.is_alive():
            raise AssertionError("Device open socket did not finish")
        if self.errors:
            raise AssertionError(f"Device open socket failed: {self.errors}")

    def result(self, request: dict) -> dict:
        method = request.get("method")
        if method == "surface.catalog":
            return CATALOG
        if method == "surface.project":
            return PROJECTED
        return {}

    def serve(self) -> None:
        try:
            while not self.stopped.is_set():
                try:
                    connection, _ = self.listener.accept()
                except socket.timeout:
                    continue
                connection.settimeout(5)
                with connection, connection.makefile("rwb") as stream:
                    for raw in stream:
                        if raw.startswith(b"auth "):
                            stream.write(b"OK\n")
                        else:
                            request = json.loads(raw)
                            self.requests.append(request)
                            response = {"id": request["id"], "ok": True, "result": self.result(request)}
                            stream.write(json.dumps(response).encode() + b"\n")
                        stream.flush()
        except Exception as error:  # noqa: BLE001 - surfaced by __exit__
            self.errors.append(error)

    def project_requests(self) -> list[dict]:
        return [request.get("params") or {} for request in self.requests if request.get("method") == "surface.project"]


class VMOpenDeviceTargetTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cli = os.environ.get("CMUX_CLI_BIN", "")
        if not cls.cli or not os.access(cls.cli, os.X_OK):
            raise RuntimeError("Set CMUX_CLI_BIN to the built CLI")

    def run_cli(self, path: str, args: list[str]) -> subprocess.CompletedProcess[str]:
        environment = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
        environment.update({
            "CMUX_SOCKET_PATH": path,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "AppleLanguages": "(en)",
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
        })
        return subprocess.run(
            [self.cli, "--socket", path, *args],
            env=environment, stdin=subprocess.DEVNULL,
            capture_output=True, text=True, timeout=30, check=False,
        )

    def assert_projected(self, server: DeviceOpenSocket, completed: subprocess.CompletedProcess[str]) -> dict:
        self.assertEqual(
            completed.returncode, 0,
            f"vm open rejected the device address\nstdout: {completed.stdout}\nstderr: {completed.stderr}",
        )
        self.assertNotIn("Usage:", completed.stderr)
        catalog_machines = [
            (request.get("params") or {}).get("machine")
            for request in server.requests if request.get("method") == "surface.catalog"
        ]
        self.assertIn(DEVICE, catalog_machines, f"catalog was not asked for the device: {server.requests}")
        projected = server.project_requests()
        self.assertEqual(len(projected), 1, f"expected one surface.project call: {server.requests}")
        params = projected[0]
        self.assertEqual(params.get("resource"), RESOURCE)
        self.assertEqual(params.get("remote_workspace_id"), REMOTE_WORKSPACE)
        self.assertEqual(params.get("workspace_id"), LOCAL_WORKSPACE)
        return params

    def test_tree_address_with_tab_opens_the_device_terminal(self) -> None:
        # Exactly what `cmux vm tree` prints for a terminal on another Mac.
        target = f"{DEVICE}/{REMOTE_WORKSPACE}/{TERMINAL}/{TERMINAL}"
        with DeviceOpenSocket() as server:
            completed = self.run_cli(server.path, ["vm", "open", target, "--workspace", LOCAL_WORKSPACE, "--focus", "false"])
            params = self.assert_projected(server, completed)
        self.assertEqual(params.get("remote_tab_id"), TERMINAL)
        self.assertEqual(params.get("focus"), False)

    def test_terminal_address_without_tab_opens_the_device_terminal(self) -> None:
        target = f"{DEVICE}/{REMOTE_WORKSPACE}/{TERMINAL}"
        with DeviceOpenSocket() as server:
            completed = self.run_cli(server.path, ["vm", "open", target, "--workspace", LOCAL_WORKSPACE])
            self.assert_projected(server, completed)

    def test_workspace_name_resolves_on_the_device(self) -> None:
        # The remote workspace may be named instead of addressed by id.
        target = f"{DEVICE}/~/{TERMINAL}"
        with DeviceOpenSocket() as server:
            completed = self.run_cli(server.path, ["vm", "open", target, "--workspace", LOCAL_WORKSPACE])
            self.assert_projected(server, completed)

    def test_unknown_terminal_on_the_device_is_reported_not_a_usage_error(self) -> None:
        target = f"{DEVICE}/{REMOTE_WORKSPACE}/deadbeef"
        with DeviceOpenSocket() as server:
            completed = self.run_cli(server.path, ["vm", "open", target, "--workspace", LOCAL_WORKSPACE])
            self.assertNotEqual(completed.returncode, 0)
            self.assertNotIn("Usage:", completed.stderr, completed.stderr)
            self.assertIn("deadbeef", completed.stderr)
            self.assertEqual(server.project_requests(), [])


if __name__ == "__main__":
    unittest.main()
