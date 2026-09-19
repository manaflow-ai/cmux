"""Exercise the real MCP client's admission contract against a synthetic UDS daemon.

No real helper is launched, no TCC API is invoked, and no personal state is read.
The Swift tests separately exercise the host's verified readiness publication.
"""

from contextlib import contextmanager
import json
import os
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading


class AdmissionDaemon(socketserver.ThreadingUnixStreamServer):
    daemon_threads = True

    def __init__(self, path):
        self.ready = threading.Event()
        self.probed = threading.Event()
        self.functional_calls = []
        self.failures = []
        super().__init__(str(path), AdmissionHandler)

    def result(self, request):
        method = request["method"]
        if method == "session_begin":
            return {"profile": "native"}
        if method == "session_end":
            return {}
        if method == "list":
            return {"profile": "native", "tools": [
                {"name": name, "description": "Synthetic fixture", "input_schema": {"type": "object"}}
                for name in ("check_permissions", "get_screen_size")
            ]}
        if method == "permissions_status":
            self.probed.set()
            return {"accessibility": True, "screen_recording": True,
                    "external_permission_ready": self.ready.is_set()}
        if method == "call" and request["name"] == "check_permissions":
            value = {"accessibility": True, "screen_recording": True,
                     "source": {"attribution": "driver-daemon"}}
        elif method == "call" and request["name"] == "get_screen_size":
            if not self.ready.is_set():
                raise AssertionError("MCP dispatched a functional tool before host completion")
            self.functional_calls.append(request["name"])
            value = {"width": 1440, "height": 900}
        else:
            raise AssertionError(f"Unexpected fixture request: {method}")
        return {"content": [{"type": "text", "text": json.dumps(value)}],
                "structuredContent": value, "isError": False}


class AdmissionHandler(socketserver.StreamRequestHandler):
    def handle(self):
        for line in self.rfile:
            try:
                envelope = json.loads(line)
                assert envelope["auth_token"] == "synthetic-admission-token"
                assert "host_auth_token" not in envelope, "Agent received a host capability"
                result = self.server.result(envelope["request"])
                response = {"ok": True, "result": result}
            except Exception as error:
                self.server.failures.append(str(error))
                response = {"ok": False, "error": str(error)}
            self.wfile.write((json.dumps(response) + "\n").encode())
            self.wfile.flush()


@contextmanager
def proxy(binary, socket_path, root, send, read):
    env = {
        "PATH": os.defpath,
        "HOME": str(root),
        "TMPDIR": str(root),
        "CMUX_CUA_MCP_FORCE_PROXY": "1",
        "CMUX_CUA_EXTERNAL_PERMISSION_FLOW": "1",
        "CMUX_CUA_SOCKET_AUTH_TOKEN": "synthetic-admission-token",
        "CMUX_CUA_STATE_DIR": str(root / "state"),
        "CMUX_CUA_TELEMETRY_ENABLED": "false",
        "CMUX_CUA_UPDATE_CHECK": "false",
    }
    process = subprocess.Popen(
        [str(binary), "mcp", "--socket", str(socket_path)],
        env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL, text=True,
    )
    try:
        send(process, {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2024-11-05", "capabilities": {},
            "clientInfo": {"name": "synthetic-admission-test", "version": "1"},
        }})
        assert "result" in read(process)
        send(process, {"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}})
        yield process
    finally:
        process.terminate()
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=5)
        process.stdin.close()
        process.stdout.close()


def call(send, process, name):
    send(process, {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
                   "params": {"name": name, "arguments": {}}})


def run_admission_contract(binary, send, read):
    # /tmp keeps the synthetic UDS comfortably below macOS's path-length limit.
    with tempfile.TemporaryDirectory(prefix="cu-admit-", dir="/tmp") as directory:
        root = Path(directory)
        socket_path = root / "fixture.sock"
        with AdmissionDaemon(socket_path) as daemon:
            thread = threading.Thread(target=daemon.serve_forever, daemon=True)
            thread.start()
            try:
                for empty_directory in (False, True):
                    if empty_directory:
                        (root / "state").mkdir()
                    daemon.ready.clear()
                    daemon.probed.clear()
                    daemon.functional_calls.clear()
                    with proxy(binary, socket_path, root, send, read) as process:
                        send(process, {"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
                        assert read(process)["result"]["tools"]
                        call(send, process, "check_permissions")
                        assert read(process)["result"]["structuredContent"]["accessibility"]
                        assert not daemon.probed.is_set(), "Permission reporting was gated"
                        call(send, process, "get_screen_size")
                        assert daemon.probed.wait(timeout=10), "MCP never consulted host readiness"
                        assert not daemon.functional_calls
                        daemon.ready.set()
                        response = read(process)
                        assert response["result"]["structuredContent"]["width"] == 1440
                        assert daemon.functional_calls == ["get_screen_size"]
                    assert not (root / "state").exists() or not list((root / "state").iterdir())

                # Verify the real bounded setup-required error, not a copy of its predicate.
                daemon.ready.clear()
                daemon.functional_calls.clear()
                with proxy(binary, socket_path, root, send, read) as process:
                    call(send, process, "get_screen_size")
                    response = read(process, timeout=70)
                    assert response["result"]["isError"]
                    assert "onboarding is still in progress" in json.dumps(response)
                    assert not daemon.functional_calls
                assert not daemon.failures, daemon.failures
            finally:
                daemon.shutdown()
                thread.join(timeout=5)
        socket_path.unlink()
        with proxy(binary, socket_path, root, send, read) as process:
            call(send, process, "get_screen_size")
            response = read(process, timeout=20)
            assert response["result"]["isError"]
            assert "runtime is not listening" in json.dumps(response)
            assert "onboarding is still in progress" not in json.dumps(response)
    print("PASS: real MCP admission preserves host completion, TCC reporting, and unavailable-runtime errors")
