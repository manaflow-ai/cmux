#!/usr/bin/env python3
"""Leased icons stay independent for two foreground processes in one workspace.

Run against an explicitly selected tagged Debug socket. Synthetic processes
register the same provider key, as two Claude tabs do; no real agent is started.
"""
import json
import os
from pathlib import Path
import shlex
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid


def request(socket_path, method, params=None):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.settimeout(30)
        connection.connect(socket_path)
        connection.sendall((json.dumps({"id": str(uuid.uuid4()), "method": method, "params": params or {}}) + "\n").encode())
        response = b""
        while b"\n" not in response:
            chunk = connection.recv(65536)
            if not chunk:
                raise RuntimeError("Socket closed before replying")
            response += chunk
        return json.loads(response.split(b"\n")[0])


def call(socket_path, method, params=None):
    response = request(socket_path, method, params)
    if not response.get("ok"):
        raise RuntimeError(json.dumps(response))
    return response["result"]


def fixture(output):
    target = os.environ["CMUX_SOCKET_PATH"]
    workspace = os.environ["CMUX_WORKSPACE_ID"]
    surface = os.environ["CMUX_SURFACE_ID"]
    pid = os.getpid()
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as connection:
        connection.connect(target)
        connection.sendall(f"set_agent_pid claude_code {pid} --tab={workspace} --panel={surface}\n".encode())
        if not connection.recv(65536).startswith(b"OK"):
            raise RuntimeError("Fixture registration failed")
    env = dict(os.environ, LC_ALL="C", LANG="C", TZ="UTC")
    started = " ".join(subprocess.check_output(["/bin/ps", "-p", str(pid), "-o", "lstart="], env=env, text=True).split())
    Path(output).write_text(json.dumps({"workspace": workspace, "surface": surface, "pid": pid, "start": started}))
    print("Surface icon multi-tab regression fixture ready", flush=True)
    while True:
        signal.pause()


def main():
    target = os.environ.get("CMUX_SOCKET_PATH", "")
    if not target.startswith("/tmp/cmux-debug-") or not target.endswith(".sock"):
        raise RuntimeError("Set CMUX_SOCKET_PATH to an explicit tagged Debug socket")
    workspace = None
    with tempfile.TemporaryDirectory(prefix="cmux-icon-multitab-") as temporary:
        root = Path(temporary)
        command = lambda name: f"/usr/bin/python3 -I {shlex.quote(str(Path(__file__).resolve()))} --fixture {shlex.quote(str(root / name))}"
        leases = {}
        try:
            created = call(target, "workspace.create", {"focus": False, "initial_command": command("a.json")})
            workspace = created["workspace_id"]
            listing = call(target, "surface.list", {"workspace_id": workspace})
            pane = listing["surfaces"][0]["pane_id"]
            call(target, "surface.create", {"workspace_id": workspace, "pane_id": pane, "focus": False, "initial_command": command("b.json")})
            deadline = time.monotonic() + 30
            while not all((root / name).exists() for name in ["a.json", "b.json"]):
                if time.monotonic() >= deadline:
                    raise RuntimeError("Fixtures did not become ready")
                time.sleep(0.05)
            rows = [json.loads((root / name).read_text()) for name in ["a.json", "b.json"]]
            assert rows[0]["surface"] != rows[1]["surface"]
            # The UI snapshot is also a barrier after queued provider registration.
            focus = call(target, "surface.current")["surface_id"]
            asset = {"frames": [{"svg": '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 28 28"><rect x="4" y="4" width="20" height="20" fill="#d77757"/></svg>', "duration_ms": 100}], "loop": False, "static_frame": 0}
            results = []
            for index, row in enumerate(rows):
                params = {"workspace_id": workspace, "surface_id": row["surface"], "owner_id": f"multi-tab-{index}", "expected_agent_pid": row["pid"], "expected_process_start": row["start"], "ttl_seconds": 30, "asset": asset}
                response = request(target, "surface.icon.set", params)
                results.append(response)
                if response.get("ok"):
                    leases[index] = response["result"]
            assert all(response.get("ok") for response in results), f"Two tabs must both accept independent leases: {results}"
            assert leases[0]["lease_token"] != leases[1]["lease_token"]
            print("PASS two tabs in one workspace acquired independent leases")
            mismatch = request(target, "surface.icon.set", {"workspace_id": workspace, "surface_id": rows[1]["surface"], "owner_id": "wrong-tab", "expected_agent_pid": rows[0]["pid"], "expected_process_start": rows[0]["start"], "asset": asset})
            assert not mismatch.get("ok") and mismatch["error"]["code"] == "ownership_mismatch", mismatch
            print("PASS a process in tab A cannot decorate tab B")
            first = leases[0]
            call(target, "surface.icon.clear", {"workspace_id": workspace, "surface_id": rows[0]["surface"], "owner_id": "multi-tab-0", "lease_token": first["lease_token"], "expected_revision": first["revision"]})
            second = leases[1]
            renewed = call(target, "surface.icon.set", {"workspace_id": workspace, "surface_id": rows[1]["surface"], "owner_id": "multi-tab-1", "expected_agent_pid": rows[1]["pid"], "expected_process_start": rows[1]["start"], "lease_token": second["lease_token"], "expected_revision": second["revision"]})
            assert renewed["revision"] == second["revision"] + 1
            assert call(target, "surface.current")["surface_id"] == focus
            print("PASS clearing tab A leaves tab B renewable and preserves focus")
        finally:
            if workspace:
                call(target, "workspace.close", {"workspace_id": workspace, "force": True})
    return 0


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--fixture":
        fixture(sys.argv[2])
    else:
        raise SystemExit(main())
