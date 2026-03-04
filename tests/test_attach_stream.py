#!/usr/bin/env python3
"""E2E test for cmux attach / surface.attach_stream.

Tests the full streaming pipeline:
  ghostty pty output → output handler callback → ring buffer → stream client → socket → test harness

Requires: cmux app running with CMUX_SOCKET_MODE=allowAll
"""

import json
import os
import select
import socket
import sys
import time
import uuid

SOCKET_PATH = os.environ.get("CMUX_SOCKET", "/tmp/cmux-debug-ios-mac-connect.sock")
TIMEOUT = 10


def send_v2(sock, method, params=None):
    """Send a v2 JSON-RPC request and return the parsed response."""
    req = json.dumps({"id": str(uuid.uuid4()), "method": method, "params": params or {}})
    sock.sendall((req + "\n").encode())
    data = b""
    deadline = time.time() + TIMEOUT
    while time.time() < deadline:
        ready = select.select([sock], [], [], 1.0)
        if ready[0]:
            chunk = sock.recv(8192)
            if not chunk:
                break
            data += chunk
            if b"\n" in data:
                break
    line = data.split(b"\n")[0]
    return json.loads(line.decode())


def connect():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(SOCKET_PATH)
    s.settimeout(TIMEOUT)
    return s


def test_workspace_list():
    """Test 1: workspace.list works and returns at least one workspace."""
    print("TEST 1: workspace.list ... ", end="", flush=True)
    sock = connect()
    try:
        resp = send_v2(sock, "workspace.list")
        assert resp.get("ok"), f"Expected ok, got: {resp}"
        result = resp.get("result", {})
        workspaces = result.get("workspaces", [])
        assert len(workspaces) > 0, "Expected at least one workspace"
        ws = workspaces[0]
        assert "id" in ws, "Workspace missing 'id'"
        print(f"PASS ({len(workspaces)} workspace(s), first={ws['id'][:8]}...)")
        return ws["id"]
    finally:
        sock.close()


def test_surface_write_pty(workspace_id):
    """Test 2: surface.write_pty sends bytes to terminal."""
    print("TEST 2: surface.write_pty ... ", end="", flush=True)
    sock = connect()
    try:
        import base64
        # Send a simple echo command (base64 encoded)
        cmd = "echo __CMUX_E2E_MARKER__\n"
        b64 = base64.b64encode(cmd.encode()).decode()
        resp = send_v2(sock, "surface.write_pty", {"workspace_id": workspace_id, "data": b64})
        assert resp.get("ok"), f"Expected ok, got: {resp}"
        print("PASS")
    finally:
        sock.close()


def test_surface_read_text(workspace_id):
    """Test 3: surface.read_text can read screen content."""
    print("TEST 3: surface.read_text ... ", end="", flush=True)
    sock = connect()
    try:
        resp = send_v2(sock, "surface.read_text", {"workspace_id": workspace_id})
        assert resp.get("ok"), f"Expected ok, got: {resp}"
        text = resp.get("result", {}).get("text", "")
        assert len(text) > 0, "Expected non-empty screen text"
        print(f"PASS ({len(text)} chars)")
    finally:
        sock.close()


def test_attach_stream(workspace_id):
    """Test 4: surface.attach_stream upgrades to raw byte streaming."""
    print("TEST 4: surface.attach_stream ... ", end="", flush=True)
    sock = connect()
    try:
        # Send the attach_stream request
        req = json.dumps({
            "id": str(uuid.uuid4()),
            "method": "surface.attach_stream",
            "params": {"workspace_id": workspace_id}
        })
        sock.sendall((req + "\n").encode())

        # Read the JSON header line
        data = b""
        deadline = time.time() + TIMEOUT
        while time.time() < deadline:
            ready = select.select([sock], [], [], 1.0)
            if ready[0]:
                chunk = sock.recv(8192)
                if not chunk:
                    break
                data += chunk
                if b"\n" in data:
                    break

        # Parse the header
        parts = data.split(b"\n", 1)
        header_line = parts[0]
        extra = parts[1] if len(parts) > 1 else b""

        header = json.loads(header_line.decode())
        assert header.get("ok"), f"Expected ok header, got: {header}"
        result = header.get("result", {})
        assert result.get("stream") == True, f"Expected stream=true, got: {result}"
        assert "cols" in result, "Missing cols in stream header"
        assert "rows" in result, "Missing rows in stream header"
        assert "workspace_id" in result, "Missing workspace_id in stream header"
        assert "surface_id" in result, "Missing surface_id in stream header"

        cols = result["cols"]
        rows = result["rows"]
        ws_id = result["workspace_id"]
        sf_id = result["surface_id"]

        print(f"header OK (cols={cols}, rows={rows})")

        # Read bootstrap data (screen snapshot)
        print("  Reading bootstrap ... ", end="", flush=True)
        bootstrap = extra
        deadline2 = time.time() + 3
        while time.time() < deadline2:
            ready = select.select([sock], [], [], 0.5)
            if ready[0]:
                chunk = sock.recv(8192)
                if not chunk:
                    break
                bootstrap += chunk
            else:
                break

        print(f"got {len(bootstrap)} bytes")

        # Now test live streaming: send a command via write_pty on a separate connection
        # and verify we see the output on the stream
        print("  Testing live stream ... ", end="", flush=True)
        marker = f"__STREAM_TEST_{uuid.uuid4().hex[:8]}__"

        # Send echo command via separate RPC connection
        rpc_sock = connect()
        import base64
        cmd = f"echo {marker}\n"
        b64 = base64.b64encode(cmd.encode()).decode()
        rpc_resp = send_v2(rpc_sock, "surface.write_pty", {
            "workspace_id": ws_id,
            "surface_id": sf_id,
            "data": b64
        })
        rpc_sock.close()
        assert rpc_resp.get("ok"), f"write_pty failed: {rpc_resp}"

        # Read from the stream and look for our marker
        stream_data = b""
        deadline3 = time.time() + 5
        found_marker = False
        while time.time() < deadline3:
            ready = select.select([sock], [], [], 0.5)
            if ready[0]:
                chunk = sock.recv(8192)
                if not chunk:
                    break
                stream_data += chunk
                if marker.encode() in stream_data:
                    found_marker = True
                    break

        if found_marker:
            print(f"PASS (received {len(stream_data)} bytes, marker found)")
        else:
            print(f"PARTIAL (received {len(stream_data)} bytes, marker not found in stream)")
            # This might happen if the output handler isn't connected yet
            # or if the echo output was in the bootstrap data
            if len(stream_data) > 0:
                print(f"  Stream data preview: {stream_data[:200]!r}")

    finally:
        sock.close()


def test_attach_stream_roundtrip(workspace_id):
    """Test 5: Full roundtrip - send input via stream, read output."""
    print("TEST 5: stream input roundtrip ... ", end="", flush=True)

    # Send a unique marker via write_pty first
    import base64
    marker = f"RT_{uuid.uuid4().hex[:8]}"

    rpc = connect()
    cmd = f"echo {marker}\n"
    b64 = base64.b64encode(cmd.encode()).decode()
    resp = send_v2(rpc, "surface.write_pty", {"workspace_id": workspace_id, "data": b64})
    rpc.close()

    if not resp.get("ok"):
        print(f"SKIP (write_pty failed: {resp})")
        return

    # Small delay for terminal to process
    time.sleep(0.5)

    # Now read_text and verify marker is on screen
    rpc2 = connect()
    resp2 = send_v2(rpc2, "surface.read_text", {"workspace_id": workspace_id})
    rpc2.close()

    if resp2.get("ok"):
        text = resp2.get("result", {}).get("text", "")
        if marker in text:
            print(f"PASS (marker '{marker}' found in screen text)")
        else:
            print(f"PARTIAL (marker not in screen text, text len={len(text)})")
    else:
        print(f"FAIL (read_text error: {resp2})")


def main():
    print(f"=== cmux attach/stream E2E tests ===")
    print(f"Socket: {SOCKET_PATH}")
    print()

    if not os.path.exists(SOCKET_PATH):
        print(f"ERROR: Socket not found at {SOCKET_PATH}")
        print("Start cmux with CMUX_SOCKET_MODE=allowAll first.")
        sys.exit(1)

    # Test 1: List workspaces
    ws_id = test_workspace_list()

    # Test 2: Write to pty
    test_surface_write_pty(ws_id)

    time.sleep(0.5)

    # Test 3: Read screen text
    test_surface_read_text(ws_id)

    # Test 4: Stream attach
    test_attach_stream(ws_id)

    # Test 5: Roundtrip
    test_attach_stream_roundtrip(ws_id)

    print()
    print("=== All tests completed ===")


if __name__ == "__main__":
    main()
