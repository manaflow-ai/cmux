#!/usr/bin/env python3
"""Exercise workspace context CLI routing against a socket stub, without a live app."""
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import threading
import unittest


class WorkspaceContextCLITests(unittest.TestCase):
    workspace = "22222222-2222-2222-2222-222222222222"
    window = "11111111-1111-1111-1111-111111111111"

    def invoke(self, arguments, caller=None):
        cli = os.environ["CMUX_CLI_PATH"]
        commands = []
        with tempfile.TemporaryDirectory(prefix="wsctx-", dir="/tmp") as directory:
            path = str(Path(directory) / "socket")
            with socket.socket(socket.AF_UNIX) as server:
                server.bind(path)
                server.listen(1)
                server.settimeout(5)

                def handle():
                    try:
                        connection, _ = server.accept()
                    except TimeoutError:
                        return
                    with connection, connection.makefile("rwb") as stream:
                        while line := stream.readline():
                            request = json.loads(line)
                            commands.append(request)
                            result = {"workspace_id": self.workspace, "workspace_ref": "workspace:2"}
                            stream.write((json.dumps({"id": request["id"], "ok": True, "result": result}) + "\n").encode())
                            stream.flush()

                worker = threading.Thread(target=handle)
                worker.start()
                environment = {key: value for key, value in os.environ.items() if not key.startswith("CMUX_")}
                environment.update(CMUX_SOCKET_PATH=path, CMUX_CLI_SENTRY_DISABLED="1")
                if caller:
                    environment["CMUX_WORKSPACE_ID"] = caller
                    environment["CMUX_SURFACE_ID"] = "33333333-3333-3333-3333-333333333333"
                result = subprocess.run([cli, "--json", "workspace", "set", *arguments], env=environment,
                                        cwd=directory, capture_output=True, text=True, timeout=8)
                worker.join(6)
                self.assertFalse(worker.is_alive())
                return result, commands, directory

    def test_caller_workspace_and_relative_path_with_pr_url(self):
        result, commands, directory = self.invoke(["--directory", "task tree", "--pr", "https://github.com/acme/project/pull/123"], self.workspace)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([request["method"] for request in commands], ["workspace.action"])
        self.assertEqual(commands[-1]["params"], {
            "action": "set_context", "workspace_id": self.workspace,
            "workspace_directory": str(Path(directory).resolve() / "task tree"),
            "pr_number": 123, "pr_url": "https://github.com/acme/project/pull/123",
        })

    def test_explicit_window_ignores_ambient_workspace(self):
        result, commands, _ = self.invoke(["--window", self.window, "--clear-directory", "--clear-pr"], "99999999-9999-9999-9999-999999999999")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([request["method"] for request in commands], ["workspace.current", "workspace.action"])
        params = commands[-1]["params"]
        self.assertEqual(params["workspace_id"], self.workspace)
        self.assertEqual(params["window_id"], self.window)
        self.assertTrue(params["clear_directory"])
        self.assertTrue(params["clear_pull_request"])

    def test_number_url_and_state(self):
        result, commands, _ = self.invoke(["--workspace", self.workspace, "--pr", "#42", "--pr-url", "https://git.example/reviews/42", "--pr-state", "merged"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(commands[-1]["params"]["pr_number"], 42)
        self.assertEqual(commands[-1]["params"]["pr_state"], "merged")

    def test_conflicting_and_incomplete_flags_never_mutate(self):
        for arguments in [["--directory", "/tmp/a", "--clear-directory"],
                          ["--pr", "123"], ["--directory", "/tmp/a", "unexpected"],
                          ["--cwd", "/tmp/a", "--directory", "/tmp/b"],
                          ["--pr", "https://github.com/acme/project/pull/123", "--clear-pr"]]:
            with self.subTest(arguments=arguments):
                result, commands, _ = self.invoke(arguments, self.workspace)
                self.assertNotEqual(result.returncode, 0)
                self.assertFalse(commands)


if __name__ == "__main__":
    unittest.main()
