#!/usr/bin/env python3
"""
Integration tests for the cmux MCP server redesign.

Validates that all grouped tool actions work correctly via direct socket RPC.
This tests the SAME code path the new MCPBackend.swift will use.

Requires a running cmux instance with socket at /tmp/cmux.sock.

Usage:
    python3 tests/test_mcp_socket_rpc.py
"""

import json
import os
import socket
import sys

SOCKET_PATH = os.environ.get("CMUX_SOCKET_PATH", "/tmp/cmux.sock")

passed = 0
failed = 0
skipped = 0
req_id = 0


def rpc(method, params=None):
    """Send a JSON-RPC request to the cmux socket and return parsed response."""
    global req_id
    req_id += 1
    payload = {"id": req_id, "method": method, "params": params or {}}

    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(5)
    sock.connect(SOCKET_PATH)
    sock.sendall(json.dumps(payload).encode("utf-8") + b"\n")

    data = b""
    while b"\n" not in data:
        chunk = sock.recv(65536)
        if not chunk:
            break
        data += chunk
    sock.close()

    return json.loads(data.decode("utf-8"))


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")


def skip(name, reason=""):
    global skipped
    skipped += 1
    print(f"  SKIP  {name}  {reason}")


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

def test_socket_v2_format():
    """Verify socket uses v2 format (ok/result), NOT JSON-RPC 2.0."""
    print("\n--- test_socket_v2_format ---")
    r = rpc("system.ping")
    check("has 'ok' field", "ok" in r)
    check("ok is True", r.get("ok") is True)
    check("has 'result' field", "result" in r)
    check("no 'jsonrpc' field", "jsonrpc" not in r, f"found jsonrpc={r.get('jsonrpc')}")
    check("result has pong", r.get("result", {}).get("pong") is True)


def test_socket_v2_error_format():
    """Verify error responses use v2 format."""
    print("\n--- test_socket_v2_error_format ---")
    r = rpc("nonexistent.method")
    check("ok is False", r.get("ok") is False)
    check("has 'error' field", "error" in r)
    err = r.get("error", {})
    check("error has 'code'", "code" in err)
    check("error has 'message'", "message" in err)


def test_system_actions():
    """Test system.* methods."""
    print("\n--- test_system_actions ---")

    # ping
    r = rpc("system.ping")
    check("system.ping ok", r.get("ok") is True)

    # identify
    r = rpc("system.identify")
    check("system.identify ok", r.get("ok") is True)
    result = r.get("result", {})
    check("identify has focused", "focused" in result)

    # capabilities
    r = rpc("system.capabilities")
    check("system.capabilities ok", r.get("ok") is True)
    result = r.get("result", {})
    check("capabilities has methods", "methods" in result)
    methods = result.get("methods", [])
    check("methods is non-empty list", len(methods) > 0)


def test_workspace_actions():
    """Test workspace.* methods."""
    print("\n--- test_workspace_actions ---")

    # list
    r = rpc("workspace.list")
    check("workspace.list ok", r.get("ok") is True)

    # current
    r = rpc("workspace.current")
    check("workspace.current ok", r.get("ok") is True)
    result = r.get("result", {})
    ws_ref = result.get("workspace_ref", "")
    check("current has workspace_ref", ws_ref.startswith("workspace:"), f"got {ws_ref}")

    # create + close (create, then immediately close to clean up)
    r = rpc("workspace.create")
    check("workspace.create ok", r.get("ok") is True)
    new_ws = r.get("result", {}).get("workspace_ref", "")
    if new_ws:
        # Switch back to original workspace before closing
        rpc("workspace.select", {"workspace_id": ws_ref})
        r2 = rpc("workspace.close", {"workspace_id": new_ws})
        check("workspace.close ok", r2.get("ok") is True)
    else:
        skip("workspace.close", "no workspace_ref from create")

    # next/previous (just verify they don't error)
    r = rpc("workspace.next")
    check("workspace.next ok", r.get("ok") is True)
    r = rpc("workspace.previous")
    check("workspace.previous ok", r.get("ok") is True)


def test_window_actions():
    """Test window.* methods."""
    print("\n--- test_window_actions ---")

    r = rpc("window.list")
    check("window.list ok", r.get("ok") is True)

    r = rpc("window.current")
    check("window.current ok", r.get("ok") is True)


def test_pane_actions():
    """Test pane.* methods."""
    print("\n--- test_pane_actions ---")

    r = rpc("pane.list")
    check("pane.list ok", r.get("ok") is True)

    r = rpc("pane.surfaces")
    check("pane.surfaces ok", r.get("ok") is True)

    # pane.focus requires pane_id - test with invalid to check error handling
    r = rpc("pane.focus", {})
    check("pane.focus without pane_id fails", r.get("ok") is False)


def test_surface_actions():
    """Test surface.* methods — the most critical group."""
    print("\n--- test_surface_actions ---")

    # list
    r = rpc("surface.list")
    check("surface.list ok", r.get("ok") is True)

    # current
    r = rpc("surface.current")
    check("surface.current ok", r.get("ok") is True)

    # read_text (THE BUG that started all this)
    r = rpc("surface.read_text")
    check("surface.read_text ok", r.get("ok") is True)
    result = r.get("result", {})
    check("read_text has 'text' field", "text" in result)
    check("read_text text is string", isinstance(result.get("text"), str))

    # read_text with specific surface (use current surface dynamically)
    cur = rpc("surface.current")
    cur_ref = cur.get("result", {}).get("surface_ref", "")
    if cur_ref:
        r2 = rpc("surface.read_text", {"surface_id": cur_ref})
        check(f"surface.read_text with surface_id '{cur_ref}' ok", r2.get("ok") is True)
    else:
        skip("surface.read_text with surface_id", "no current surface")

    # send_text requires text param
    r = rpc("surface.send_text", {})
    check("surface.send_text without text fails", r.get("ok") is False)

    # send_key requires key param
    r = rpc("surface.send_key", {})
    check("surface.send_key without key fails", r.get("ok") is False)

    # split requires direction
    r = rpc("surface.split", {})
    check("surface.split without direction fails", r.get("ok") is False)

    # trigger_flash (safe, no side effects)
    r = rpc("surface.trigger_flash")
    check("surface.trigger_flash ok", r.get("ok") is True)

    # health
    r = rpc("surface.health")
    check("surface.health ok", r.get("ok") is True)


def test_notification_actions():
    """Test notification.* methods."""
    print("\n--- test_notification_actions ---")

    # create
    r = rpc("notification.create", {"title": "MCP Test", "body": "Socket RPC test"})
    check("notification.create ok", r.get("ok") is True)

    # list
    r = rpc("notification.list")
    check("notification.list ok", r.get("ok") is True)

    # clear
    r = rpc("notification.clear")
    check("notification.clear ok", r.get("ok") is True)


def test_ref_ids_accepted():
    """Verify socket accepts ref-format IDs (workspace:N, surface:N)."""
    print("\n--- test_ref_ids_accepted ---")

    # Get current IDs first
    r = rpc("system.identify")
    result = r.get("result", {}).get("focused", {})
    ws_ref = result.get("workspace_ref", "")
    surface_ref = result.get("surface_ref", "")

    if ws_ref:
        r = rpc("workspace.select", {"workspace_id": ws_ref})
        check(f"workspace.select with ref '{ws_ref}' ok", r.get("ok") is True)
    else:
        skip("workspace ref test", "no workspace_ref")

    if surface_ref:
        r = rpc("surface.read_text", {"surface_id": surface_ref})
        check(f"surface.read_text with ref '{surface_ref}' ok", r.get("ok") is True)
    else:
        skip("surface ref test", "no surface_ref")


def test_unknown_method():
    """Verify unknown methods return proper error."""
    print("\n--- test_unknown_method ---")
    r = rpc("totally.bogus.method")
    check("unknown method returns ok=false", r.get("ok") is False)
    err = r.get("error", {})
    check("error code is method_not_found", err.get("code") == "method_not_found")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    if not os.path.exists(SOCKET_PATH):
        print(f"ERROR: Socket not found at {SOCKET_PATH}")
        print("Make sure cmux is running.")
        sys.exit(1)

    # Quick connectivity check
    try:
        r = rpc("system.ping")
        if not r.get("ok"):
            print(f"ERROR: Socket ping failed: {r}")
            sys.exit(1)
    except Exception as e:
        print(f"ERROR: Cannot connect to {SOCKET_PATH}: {e}")
        sys.exit(1)

    print(f"Testing direct socket RPC at {SOCKET_PATH}")

    test_socket_v2_format()
    test_socket_v2_error_format()
    test_system_actions()
    test_workspace_actions()
    test_window_actions()
    test_pane_actions()
    test_surface_actions()
    test_notification_actions()
    test_ref_ids_accepted()
    test_unknown_method()

    print(f"\n{'='*50}")
    print(f"Results: {passed} passed, {failed} failed, {skipped} skipped")
    print(f"{'='*50}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
