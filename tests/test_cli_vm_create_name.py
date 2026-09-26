#!/usr/bin/env python3
"""Verify create-time naming against an isolated socket, without allocating VMs."""

from __future__ import annotations

import os
import subprocess
import unittest

from test_cli_vm_resize import ResizeSocket


class VMCreateNameTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cli = os.environ.get("CMUX_CLI_BIN", "")
        if not cls.cli or not os.access(cls.cli, os.X_OK):
            raise RuntimeError("Set CMUX_CLI_BIN to the built CLI")

    def create(self, server: ResizeSocket, name: str | None) -> None:
        environment = {key: value for key, value in os.environ.items() if not key.startswith("CMUX")}
        environment.update({"CMUX_CLI_SENTRY_DISABLED": "1", "AppleLanguages": "(en)"})
        arguments = [self.cli, "--socket", server.path, "vm", "new", "--detach"]
        if name is not None:
            arguments += ["--name", name]
        # The CLI exits once the socket fixture answers; the job-level timeout
        # bounds a hang instead of a wall-clock ceiling on shared CI.
        result = subprocess.run(arguments, env=environment, stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, check=False)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_named_create_uses_one_request_when_backend_accepts_name(self) -> None:
        with ResizeSocket({"id": "named", "provider": "freestyle", "image": "test", "displayName": "Build box"}) as server:
            self.create(server, "Build box")
            self.assertEqual([r["method"] for r in server.requests], ["vm.create"])
            self.assertEqual(server.requests[0]["params"]["display_name"], "Build box")

    def test_older_backend_keeps_the_existing_rename_fallback(self) -> None:
        with ResizeSocket({"id": "named", "provider": "freestyle", "image": "test"}) as server:
            self.create(server, "Build box")
            self.assertEqual([r["method"] for r in server.requests], ["vm.create", "vm.rename"])
            self.assertEqual(server.requests[1]["params"], {"id": "named", "display_name": "Build box"})

    def test_unnamed_create_does_not_rename(self) -> None:
        with ResizeSocket({"id": "unnamed", "provider": "freestyle", "image": "test"}) as server:
            self.create(server, None)
            self.assertEqual([r["method"] for r in server.requests], ["vm.create"])
            self.assertNotIn("display_name", server.requests[0]["params"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
