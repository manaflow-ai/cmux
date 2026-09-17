#!/usr/bin/env python3
"""Exercise Cloud VM resize through the built CLI and an isolated fake socket."""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest


class ResizeSocket:
    def __init__(self, result: dict | None = None, error: dict | None = None) -> None:
        self.result = result or {}
        self.error = error
        self.requests: list[dict] = []
        self.errors: list[Exception] = []
        self.stopped = threading.Event()

    def __enter__(self) -> "ResizeSocket":
        self.root = tempfile.TemporaryDirectory(prefix="vm-resize-", dir="/tmp")
        self.path = str(Path(self.root.name, "socket"))
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(self.path)
        self.listener.listen(1)
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
            raise AssertionError("Resize socket did not finish")
        if self.errors:
            raise AssertionError(f"Resize socket failed: {self.errors}")

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
                            response = {"id": request["id"], "ok": self.error is None}
                            response["result" if self.error is None else "error"] = self.result if self.error is None else self.error
                            stream.write(json.dumps(response).encode() + b"\n")
                        stream.flush()
        except Exception as error:
            self.errors.append(error)


class VMResizeTests(unittest.TestCase):
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
            capture_output=True, text=True, timeout=10, check=False,
        )

    def test_help_documents_all_dimensions_without_a_socket(self) -> None:
        with tempfile.TemporaryDirectory(prefix="vm-resize-help-", dir="/tmp") as root:
            for family in ("vm", "cloud"):
                result = self.run_cli(str(Path(root, "missing")), [family, "resize", "--help"])
                self.assertEqual(result.returncode, 0, result.stderr)
                for option in ("--cpu", "--memory", "--disk", "--json"):
                    self.assertIn(option, result.stdout)

    def test_memory_accepts_whole_gib_without_disk_step_restrictions(self) -> None:
        for option in (["--memory", "5GiB"], ["--memory=5"]):
            with self.subTest(option=option), ResizeSocket({"memory_total_mb": 5120}) as server:
                result = self.run_cli(server.path, ["vm", "resize", "existing-vm", *option, "--json"])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(len(server.requests), 1)
                self.assertEqual(server.requests[0]["method"], "vm.resize")
                self.assertEqual(server.requests[0]["params"], {"id": "existing-vm", "memory_mb": 5120})

    def test_resize_uses_existing_id_and_prints_confirmed_shape(self) -> None:
        confirmed = {"id": "existing-vm", "cpus": 6, "memory_total_mb": 6144, "disk_total_mb": 69632}
        with ResizeSocket(confirmed) as server:
            result = self.run_cli(server.path, [
                "vm", "resize", "existing-vm", "--cpu", "4", "--memory", "4G", "--disk", "64GB",
            ])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(server.requests), 1)
            self.assertEqual(server.requests[0]["method"], "vm.resize")
            self.assertEqual(server.requests[0]["params"], {
                "id": "existing-vm", "cpu": 4, "memory_mb": 4096, "storage_mb": 65536,
            })
            self.assertIn("existing-vm", result.stdout)
            self.assertIn("cpu=6", result.stdout)
            self.assertIn("memory=6 GiB", result.stdout)
            self.assertIn("disk=68 GiB", result.stdout)

    def test_disk_suffix_is_converted_before_sending_the_resize(self) -> None:
        with ResizeSocket({"disk_total_mb": 65536}) as server:
            result = self.run_cli(server.path, ["vm", "resize", "existing-vm", "--disk", "64G", "--json"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(len(server.requests), 1)
            self.assertEqual(server.requests[0]["params"], {"id": "existing-vm", "storage_mb": 65536})

    def test_json_preserves_provider_confirmation(self) -> None:
        confirmed = {"id": "existing-vm", "state": "running", "cpus": 8, "memory_total_mb": 8192, "disk_total_mb": 69632}
        with ResizeSocket(confirmed) as server:
            result = self.run_cli(server.path, ["cloud", "resize", "existing-vm", "--disk=64", "--json"])
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(result.stdout), confirmed)
            self.assertEqual(len(server.requests), 1)

    def test_invalid_arguments_do_not_send_a_resize_request(self) -> None:
        cases = [
            [], ["existing-vm"], ["", "--disk", "64"],
            ["existing-vm", "--disk"], ["existing-vm", "--disk", "66"],
            ["existing-vm", "--disk", "0"], ["existing-vm", "--disk", "260"],
            ["existing-vm", "--disk", "128 GiB"], ["existing-vm", "--disk", "66G"],
            ["existing-vm", "--disk", "260G"],
            ["existing-vm", "--disk", "64.5"], ["existing-vm", "--disk", "64", "extra"],
            ["existing-vm", "--cpu", "0"], ["existing-vm", "--cpu", "33"],
            ["existing-vm", "--cpu", "1.5"], ["existing-vm", "--cpu", "-1"],
            ["existing-vm", "--memory", "0"], ["existing-vm", "--memory", "65"],
            ["existing-vm", "--memory", "4.5"], ["existing-vm", "--unknown", "64"],
        ]
        for arguments in cases:
            with self.subTest(arguments=arguments), ResizeSocket() as server:
                result = self.run_cli(server.path, ["vm", "resize", *arguments])
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertTrue(result.stderr)
                self.assertEqual(server.requests, [])

    def test_failed_resize_exits_unsuccessfully_without_success_output(self) -> None:
        with ResizeSocket(error={"code": "resize_failed", "message": "Provider could not resize this VM"}) as server:
            result = self.run_cli(server.path, ["vm", "resize", "existing-vm", "--disk", "64", "--json"])
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(result.stdout, "")
            self.assertIn("Provider could not resize this VM", result.stderr)
            self.assertEqual(len(server.requests), 1)


if __name__ == "__main__":
    unittest.main()
