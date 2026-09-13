#!/usr/bin/env python3
"""Exercise real CLI output paths when their pipe consumer disappears (#5750)."""

from __future__ import annotations

import json
import os
from pathlib import Path
import select
import socket
import subprocess
import tempfile
import threading
import unittest

from test_cli_socket_operation_deadline import FakeUnixServer

# Darwin exposes this socket option in sys/socket.h, but Python does not.
DARWIN_SO_NOSIGPIPE = 0x1022


class BrokenPipeWritesTests(unittest.TestCase):
    def setUp(self) -> None:
        self.cli = os.environ["CMUX_CLI_BIN"]
        self.root = tempfile.TemporaryDirectory(prefix="cmux-broken-pipe-")
        self.addCleanup(self.root.cleanup)
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("CMUX_", "SENTRY_")) and key != "CODEX_HOME"
        }
        self.env.update({
            "CFFIXED_USER_HOME": self.root.name,
            "XDG_CONFIG_HOME": self.root.name,
            "CMUX_CLI_SENTRY_DISABLED": "1",
            "CMUX_CLAUDE_HOOK_SENTRY_DISABLED": "1",
        })

    def run_cli(
        self, *args: str, closed: str | None = None, socket_stream: bool = False,
    ) -> subprocess.CompletedProcess:
        outputs = {"stdout": subprocess.PIPE, "stderr": subprocess.PIPE}
        write_fd = None
        if closed:
            if socket_stream:
                reader, writer = socket.socketpair()
                read_fd, write_fd = reader.detach(), writer.detach()
            else:
                read_fd, write_fd = os.pipe()
            os.close(read_fd)
            outputs[closed] = write_fd
        try:
            return subprocess.run(
                [self.cli, *args], cwd=self.root.name, env=self.env,
                stdin=subprocess.DEVNULL, timeout=15, **outputs,
            )
        finally:
            if write_fd is not None:
                os.close(write_fd)

    @staticmethod
    def responder(method: str, result: dict):
        def serve(conn: socket.socket, _stop: threading.Event) -> None:
            conn.settimeout(5)
            with conn.makefile("rb") as stream:
                for line in stream:
                    request = json.loads(line)
                    response = {"id": request["id"], "ok": True, "result": result}
                    if request["method"] != method:
                        response = {
                            "id": request["id"], "ok": False,
                            "error": {"code": "internal_error", "message": "Unexpected test RPC"},
                        }
                    conn.sendall(json.dumps(response).encode() + b"\n")
        return serve

    def test_codex_hook_arguments_survive_closed_stdout(self) -> None:
        args = ("hooks", "codex", "inject-args")
        normal = self.run_cli(*args)
        self.assertEqual(normal.returncode, 0, normal.stderr)
        self.assertTrue(normal.stdout.endswith(b"\0"), normal.stdout)
        self.assertIn(b"hooks", normal.stdout.split(b"\0"))
        closed = self.run_cli(*args, closed="stdout")
        self.assertEqual(closed.returncode, 0, closed.stderr)
        self.assertEqual(closed.stderr, b"")

    def test_vm_prompt_survives_closed_stderr(self) -> None:
        with FakeUnixServer(self.responder("vm.cloud_prompt", {
            "prompt": "test cloud prompt", "skill_path": "/test/skill.md",
        })) as server:
            args = ("--socket", server.path, "vm", "prompt")
            normal = self.run_cli(*args)
            self.assertEqual(normal.returncode, 0, normal.stderr)
            self.assertEqual(normal.stdout, b"test cloud prompt\n")
            self.assertEqual(normal.stderr, b"skill: /test/skill.md\n")
            closed = self.run_cli(*args, closed="stderr")
            self.assertEqual(closed.returncode, 0, closed.stdout)
            self.assertEqual(closed.stdout, normal.stdout)

    def test_vault_warning_survives_closed_stderr(self) -> None:
        with FakeUnixServer(self.responder("vault.sessions", {
            "sessions": [], "errors": ["test unavailable session"],
        })) as server:
            args = ("--socket", server.path, "vault", "sessions")
            normal = self.run_cli(*args)
            self.assertEqual(normal.returncode, 0, normal.stderr)
            self.assertEqual(normal.stderr, b"warning: test unavailable session\n")
            closed = self.run_cli(*args, closed="stderr")
            self.assertEqual(closed.returncode, 0, closed.stdout)
            self.assertEqual(closed.stdout, normal.stdout)

    def test_closed_stderr_preserves_command_failure(self) -> None:
        args = ("--socket", str(Path(self.root.name) / "missing.sock"), "ping")
        normal = self.run_cli(*args)
        self.assertEqual(normal.returncode, 1, normal.stderr)
        self.assertIn(b"Socket not found", normal.stderr)
        closed = self.run_cli(*args, closed="stderr")
        self.assertEqual(closed.returncode, normal.returncode)
        self.assertEqual(closed.stdout, normal.stdout)

    def test_socket_backed_stdout_does_not_signal(self) -> None:
        result = self.run_cli("--version", closed="stdout", socket_stream=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, b"")

    def test_socket_backed_stderr_preserves_command_failure(self) -> None:
        result = self.run_cli(
            "--socket", str(Path(self.root.name) / "missing.sock"), "ping",
            closed="stderr", socket_stream=True,
        )
        self.assertEqual(result.returncode, 1, result.stdout)

    def test_stdout_socket_options_are_not_changed_for_other_writers(self) -> None:
        reader, writer = socket.socketpair()
        with reader, writer:
            original = writer.getsockopt(socket.SOL_SOCKET, DARWIN_SO_NOSIGPIPE)
            result = subprocess.run(
                [self.cli, "--version"], cwd=self.root.name, env=self.env,
                stdin=subprocess.DEVNULL, stdout=writer, stderr=subprocess.PIPE, timeout=15,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(writer.getsockopt(socket.SOL_SOCKET, DARWIN_SO_NOSIGPIPE), original)
            self.assertTrue(reader.recv(4096).startswith(b"cmux "))

    def test_consumer_closes_during_large_stdout_write(self) -> None:
        with FakeUnixServer(self.responder("vm.cloud_prompt", {"prompt": "x" * 262_144})) as server:
            with subprocess.Popen(
                [self.cli, "--socket", server.path, "vm", "prompt"],
                cwd=self.root.name, env=self.env, stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            ) as process:
                try:
                    ready, _, _ = select.select([process.stdout], [], [], 15)
                    self.assertTrue(ready, "CLI did not start writing stdout")
                    self.assertEqual(os.read(process.stdout.fileno(), 16), b"x" * 16)
                    process.stdout.close()
                    process.wait(timeout=15)
                    self.assertEqual(process.returncode, 0, process.stderr.read())
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait()

    def run_socket_disconnect(self) -> subprocess.CompletedProcess:
        def disconnect(conn: socket.socket, _stop: threading.Event) -> None:
            # Read one byte to prove a request has started, then tear down its
            # reader while a request larger than the send buffer is in flight.
            conn.settimeout(5)
            if conn.recv(1):
                conn.shutdown(socket.SHUT_RDWR)

        with FakeUnixServer(disconnect) as server:
            return self.run_cli(
                "--socket", server.path, "send",
                "--workspace", "11111111-1111-1111-1111-111111111111",
                "--surface", "22222222-2222-2222-2222-222222222222",
                "x" * 196_608,
            )

    def test_socket_peer_closes_during_request_write(self) -> None:
        result = self.run_socket_disconnect()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"Failed to write to socket", result.stderr)
        self.assertRegex(result.stderr, rb"errno (32|54)")

    def test_socket_disconnect_is_filtered_before_sentry_capture(self) -> None:
        # The DEBUG capture probe is downstream of classification, before SDK
        # startup. An actionable control proves an absent probe is meaningful.
        self.env.pop("CMUX_CLI_SENTRY_DISABLED")
        self.env.pop("CMUX_CLAUDE_HOOK_SENTRY_DISABLED")
        self.env["CMUX_BUNDLE_ID"] = "com.cmuxterm.app.debug.cli-pipe-regressions"
        probe = Path(self.root.name) / "capture.txt"
        self.env["CMUX_CLI_SENTRY_CAPTURE_PROBE_PATH"] = str(probe)
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
            listener.bind(("127.0.0.1", 0))
            port = listener.getsockname()[1]
        control = self.run_cli("--socket", f"127.0.0.1:{port}", "ping")
        self.assertEqual(control.returncode, 1, control.stderr)
        self.assertIn(b"Missing relay auth metadata", control.stderr)
        self.assertTrue(probe.exists(), "Actionable control did not reach the DEBUG capture probe")
        probe.unlink()

        result = self.run_socket_disconnect()
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertRegex(result.stderr, rb"errno (32|54)")
        self.assertFalse(probe.exists(), "Expected disconnect reached Sentry capture")

    def test_child_processes_keep_default_sigpipe(self) -> None:
        for mode in ("spawn", "spawn-stderr", "exec"):
            with self.subTest(mode=mode):
                result = self.run_cli("__sigpipe-probe", mode)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), {
                    "signal": "default", "stdout_nosigpipe": 0, "stderr_nosigpipe": 0,
                })


if __name__ == "__main__":
    unittest.main(verbosity=2)
