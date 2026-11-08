#!/usr/bin/env python3
"""Exercise the real Bun/bwrap runner's deadline and lifecycle cleanup."""

import ctypes
import json
import os
import select
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MCP = ROOT / "cmux-tui/bindings/typescript/code-mode/mcp.mjs"
RUNNER = ROOT / "scripts/cmux-next/cmux-code-mode-runner"
# MCP buffers console output until execution finishes. A catalog-allowed socket
# request proves the script reached its body before we cancel or close the server.
SPIN = r'''
import { createConnection } from "node:net";
await new Promise((resolve, reject) => {
  const socket = createConnection(process.env.CMUX_TUI_SOCKET);
  socket.on("error", reject);
  socket.on("connect", () => socket.write(JSON.stringify({
    protocol: "cmux.protocol/2", type: "request", id: "ready",
    operation: "workspace.list", params: {}
  }) + "\n"));
  socket.once("data", () => { socket.destroy(); resolve(); });
});
console.log("READY");
for (;;) {}
'''


# CI installs these dependencies; missing dependencies there must fail, not skip.
@unittest.skipUnless(
    (shutil.which("bun") and shutil.which("bwrap"))
    or os.environ.get("GITHUB_ACTIONS") == "true",
    "bun and bwrap are required",
)
class CodeModeCancellationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        # A failed startup can lose the MCP parent before ready() records its
        # descendants. Adopt those children in this dedicated test process so
        # even the broken baseline cannot leak a sandbox out of teardown.
        cls.libc = ctypes.CDLL(None, use_errno=True)
        previous = ctypes.c_int()
        if cls.libc.prctl(37, ctypes.byref(previous), 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "PR_GET_CHILD_SUBREAPER")
        cls.previous_subreaper = previous.value
        if cls.libc.prctl(36, 1, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "PR_SET_CHILD_SUBREAPER")

    @classmethod
    def tearDownClass(cls):
        if cls.libc.prctl(36, cls.previous_subreaper, 0, 0, 0) != 0:
            raise OSError(ctypes.get_errno(), "restore child subreaper")

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="cmux-code-mode-test-")
        self.addCleanup(self.temp.cleanup)
        self.directory = Path(self.temp.name)
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.addCleanup(self.server.close)
        self.socket_path = self.directory / "target.sock"
        self.server.bind(str(self.socket_path))
        self.server.listen()
        self.server.settimeout(8)
        self.process = None
        self.owned = {}
        self.addCleanup(self.cleanup_processes)
        # A test belongs to its fake owner, never to the agent running the test.
        self.env = {
            key: value for key, value in os.environ.items()
            if not key.startswith(("ACPMUX_", "CMUX_CLOUD_", "CMUX_CODE_MODE_"))
        }
        self.env.update(CMUX_TUI_SOCKET=str(self.socket_path), TMPDIR=self.temp.name)

    def start(self, command, **env):
        self.process = subprocess.Popen(
            command, cwd=ROOT, env={**self.env, **env},
            stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            start_new_session=True,
        )
        self.record_descendants(self.process.pid)
        return self.process

    def record_descendants(self, pid):
        """Only follow children of the process this test started; never scan ps."""
        if pid not in self.owned:
            try:
                self.owned[pid] = os.pidfd_open(pid)
            except ProcessLookupError:
                return
        try:
            children = Path(f"/proc/{pid}/task/{pid}/children").read_text().split()
        except FileNotFoundError:
            return
        for child in children:
            self.record_descendants(int(child))

    def cleanup_processes(self):
        if self.process is not None:
            if self.process.poll() is None:
                self.record_descendants(self.process.pid)
                self.process.kill()
            self.process.wait(timeout=5)
            # The MCP's own children now belong to this test process, even if
            # it exited before the readiness handshake. No global process scan.
            children = Path(f"/proc/{os.getpid()}/task/{os.getpid()}/children").read_text().split()
            for child in children:
                self.record_descendants(int(child))
            # pidfds cannot accidentally signal a reused PID. These are only
            # children this test started or adopted as their nearest subreaper.
            for fd in reversed(list(self.owned.values())):
                try:
                    signal.pidfd_send_signal(fd, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + 5
            for fd in self.owned.values():
                select.select([fd], [], [], max(0, deadline - time.monotonic()))
            for pid in self.owned:
                try:
                    os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    pass
            for stream in (self.process.stdin, self.process.stdout, self.process.stderr):
                stream.close()
        for fd in self.owned.values():
            os.close(fd)

    def ready(self):
        # run.ts eagerly opens its SDK connection as well as the script's
        # readiness connection. Wait for data on either without assuming order.
        connections = {}
        deadline = time.monotonic() + 8
        while True:
            readable, _, _ = select.select(
                [self.server, *connections], [], [], max(0, deadline - time.monotonic())
            )
            self.assertTrue(readable, "sandbox did not send its readiness request")
            for stream in readable:
                if stream is self.server:
                    connection, _ = self.server.accept()
                    self.addCleanup(connection.close)
                    connections[connection] = b""
                    continue
                chunk = stream.recv(4096)
                if not chunk:
                    del connections[stream]
                    stream.close()
                    continue
                connections[stream] += chunk
                if b"\n" not in connections[stream]:
                    continue
                self.assertEqual(json.loads(connections[stream])["id"], "ready")
                self.record_descendants(self.process.pid)
                self.assertGreater(len(self.owned), 2, "runner and sandbox were not observed")
                stream.sendall(b'{"type":"response","id":"ready"}\n')
                return

    def send(self, message):
        self.process.stdin.write(json.dumps(message).encode() + b"\n")
        self.process.stdin.flush()

    def execute(self, script=SPIN, **arguments):
        self.send({
            "jsonrpc": "2.0", "id": "spin", "method": "tools/call",
            "params": {"name": "cmux_exec", "arguments": {"script": script, **arguments}},
        })

    def result(self):
        readable, _, _ = select.select([self.process.stdout], [], [], 8)
        self.assertTrue(readable, "cmux_exec did not return within 8 seconds")
        line = self.process.stdout.readline()
        self.assertTrue(line, "MCP exited without an execution result")
        response = json.loads(line)
        self.assertNotIn("error", response, response)
        self.assertTrue(response["result"]["isError"], response)
        return json.loads(response["result"]["content"][0]["text"])

    def assert_cleaned(self):
        deadline = time.monotonic() + 5
        for pid, fd in self.owned.items():
            if pid == self.process.pid:
                continue
            readable, _, _ = select.select([fd], [], [], max(0, deadline - time.monotonic()))
            self.assertTrue(readable, f"owned code-mode descendant {pid} survived cleanup")
        self.assertEqual(list(self.directory.glob("cmux-code-mode-proxy.*")), [])

    def owner_event_kills_script(self, kind, message):
        owner_path = self.directory / "owner.sock"
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as owner:
            owner.bind(str(owner_path))
            owner.listen()
            owner.settimeout(5)
            script = self.directory / "spin.ts"
            script.write_text(SPIN)
            self.start(
                [str(RUNNER), str(script)],
                ACPMUX_SOCKET=str(owner_path), ACPMUX_SESSION_ID="owner",
                CMUX_CODE_MODE_TIMEOUT_MS="60000",
            )
            connection, _ = owner.accept()
            with connection:
                connection.settimeout(5)
                data = b""
                while not data.endswith(b"\n"):
                    chunk = connection.recv(4096)
                    self.assertTrue(chunk, "runner closed before attaching to its owner")
                    data += chunk
                request = json.loads(data)
                self.assertEqual(request["method"], "_acpmux/attach")
                self.assertEqual(request["params"]["sessionId"], "owner")
                connection.sendall(json.dumps({
                    "jsonrpc": "2.0", "id": request["id"],
                    "result": {
                        "session": {
                            "sessionId": "owner", "status": "running", "state": "running",
                            "turn": {"turnId": "turn-1"},
                        },
                        "events": [],
                    },
                }).encode() + b"\n")
                self.ready()
                connection.sendall(json.dumps({
                    "jsonrpc": "2.0", "method": "_acpmux/event",
                    "params": {
                        "sessionId": "owner", "kind": kind, "msg": message,
                        "seq": 1, "dir": "internal",
                    },
                }).encode() + b"\n")
                self.process.wait(timeout=8)
                self.assertEqual(self.process.returncode, 130)
                self.assert_cleaned()

    def test_turn_end_kills_running_script(self):
        self.owner_event_kills_script("turn_end", {"turnId": "turn-1"})

    def test_turn_cancellation_kills_running_script(self):
        self.owner_event_kills_script("stopping", {"turnId": "turn-1"})

    def test_session_closed_kills_running_script(self):
        self.owner_event_kills_script("status", {"status": "closed"})

    def test_bundled_mcp_loads_shared_supervisor(self):
        resources = self.directory / "App/Contents/Resources"
        code_mode = resources / "code-mode"
        sdk_mode = code_mode / "sdk/code-mode"
        sdk_mode.mkdir(parents=True)
        shutil.copyfile(MCP, code_mode / "mcp.mjs")
        for name in ("supervise.mjs", "owner-lifecycle.mjs"):
            shutil.copyfile(MCP.parent / name, sdk_mode / name)
        shutil.copyfile(ROOT / "cmux-tui/spec/resource-operations-v2.json",
                        code_mode / "resource-operations-v2.json")
        self.start([shutil.which("bun"), str(code_mode / "mcp.mjs")])
        request = {"jsonrpc": "2.0", "id": "tools", "method": "tools/list"}
        stdout, stderr = self.process.communicate(json.dumps(request).encode() + b"\n", timeout=8)
        self.assertEqual(self.process.returncode, 0, stderr.decode())
        tools = json.loads(stdout)["result"]["tools"]
        execute = next(tool for tool in tools if tool["name"] == "cmux_exec")
        self.assertEqual(execute["inputSchema"]["properties"]["timeout_ms"]["default"], 30000)

    def test_successful_script_exits_and_cleans_up(self):
        script = self.directory / "success.ts"
        script.write_text('console.log("DONE");')
        self.start([str(RUNNER), str(script)])
        stdout, stderr = self.process.communicate(timeout=8)
        self.assertEqual(self.process.returncode, 0, stderr.decode())
        self.assertIn(b"DONE", stdout)
        self.assert_cleaned()

    def test_direct_runner_kills_cpu_spin_at_limit(self):
        script = self.directory / "spin.ts"
        script.write_text(SPIN)
        self.start([str(RUNNER), str(script)], CMUX_CODE_MODE_TIMEOUT_MS="5000")
        self.ready()
        self.process.wait(timeout=8)
        self.assertEqual(self.process.returncode, 124)
        self.assert_cleaned()
        self.assertIn(b"READY", self.process.stdout.read())

    def test_mcp_timeout_override_kills_cpu_spin(self):
        self.start([shutil.which("bun"), str(MCP)])
        self.execute(timeout_ms=5000)
        self.ready()
        result = self.result()
        self.assertTrue(result["timedOut"], result)
        self.assertIn("READY", result["stdout"])
        self.assert_cleaned()

    def test_cancel_returns_and_leaves_no_descendants(self):
        self.start([shutil.which("bun"), str(MCP)])
        self.execute()
        self.ready()
        self.send({
            "jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": {"requestId": "spin"},
        })
        self.assertTrue(self.result()["cancelled"])
        self.assert_cleaned()

    def test_cancel_unresolved_promise_leaves_no_descendants(self):
        # The production leak: Bun spun after a cancelled unresolved top-level
        # promise and the old teardown killed only its MCP server.
        self.start([shutil.which("bun"), str(MCP)])
        self.execute(script=SPIN.replace("for (;;) {}", "await new Promise(() => {});"))
        self.ready()
        self.send({
            "jsonrpc": "2.0", "method": "notifications/cancelled",
            "params": {"requestId": "spin"},
        })
        self.assertTrue(self.result()["cancelled"])
        self.assert_cleaned()

    def test_input_end_kills_running_script(self):
        self.start([shutil.which("bun"), str(MCP)])
        self.execute()
        self.ready()
        self.process.stdin.close()
        self.process.wait(timeout=8)
        self.assertEqual(self.process.returncode, 0)
        self.assert_cleaned()

    def test_server_stop_kills_running_script(self):
        self.start([shutil.which("bun"), str(MCP)])
        self.execute()
        self.ready()
        self.process.terminate()
        self.process.wait(timeout=8)
        self.assert_cleaned()


if __name__ == "__main__":
    unittest.main()
