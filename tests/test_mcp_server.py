#!/usr/bin/env python3
"""
Smoke tests for the cmux MCP server.

Tests the JSON-RPC 2.0 protocol layer and grouped tool definitions by running
the cmux-mcp binary in --mcp mode via stdin/stdout.

No cmux daemon required — tool *calls* will fail (no socket), but we
verify the command dispatch and error handling work correctly.

Usage:
    python3 tests/test_mcp_server.py [path-to-cmux-binary]
"""

import json
import os
import subprocess
import sys

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

CMUX_BIN = None  # Set in main()


def mcp_session(messages: list[dict]) -> list[dict | None]:
    """Send a sequence of JSON-RPC messages and collect responses."""
    input_text = "\n".join(json.dumps(m) for m in messages) + "\n"

    proc = subprocess.run(
        [CMUX_BIN, "--mcp"],
        input=input_text,
        capture_output=True,
        text=True,
        timeout=10,
    )

    responses = []
    for line in proc.stdout.strip().split("\n"):
        line = line.strip()
        if not line:
            continue
        responses.append(json.loads(line))
    return responses


def init_msg(id=1):
    return {
        "jsonrpc": "2.0",
        "id": id,
        "method": "initialize",
        "params": {
            "protocolVersion": "2025-06-18",
            "capabilities": {},
            "clientInfo": {"name": "test", "version": "1.0"},
        },
    }


def tools_list_msg(id=2):
    return {"jsonrpc": "2.0", "id": id, "method": "tools/list"}


def tools_call_msg(name, arguments=None, id=3):
    return {
        "jsonrpc": "2.0",
        "id": id,
        "method": "tools/call",
        "params": {"name": name, "arguments": arguments or {}},
    }


# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

passed = 0
failed = 0


def check(name, condition, detail=""):
    global passed, failed
    if condition:
        passed += 1
        print(f"  PASS  {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}  {detail}")


def test_initialize():
    """initialize returns correct protocol version, capabilities, serverInfo."""
    print("\n--- test_initialize ---")
    responses = mcp_session([init_msg()])
    check("got 1 response", len(responses) == 1, f"got {len(responses)}")
    if not responses:
        return

    r = responses[0]
    check("jsonrpc is 2.0", r.get("jsonrpc") == "2.0")
    check("id matches", r.get("id") == 1)
    result = r.get("result", {})
    check("protocolVersion present", "protocolVersion" in result)
    check("capabilities.tools present", "tools" in result.get("capabilities", {}))
    si = result.get("serverInfo", {})
    check("serverInfo.name is cmux", si.get("name") == "cmux", f"got {si}")
    check("serverInfo.version present", "version" in si)


def test_tools_list():
    """tools/list returns the 8 grouped tools with correct structure."""
    print("\n--- test_tools_list ---")
    responses = mcp_session([init_msg(1), tools_list_msg(2)])
    check("got 2 responses", len(responses) == 2, f"got {len(responses)}")
    if len(responses) < 2:
        return

    r = responses[1]
    check("id matches", r.get("id") == 2)
    tools = r.get("result", {}).get("tools", [])
    check("8 grouped tools registered", len(tools) == 8, f"got {len(tools)}")

    names = {t["name"] for t in tools}
    expected_names = {
        "cmux_system",
        "cmux_workspace",
        "cmux_window",
        "cmux_pane",
        "cmux_surface",
        "cmux_notification",
        "cmux_tab",
        "cmux_browser",
    }
    check("all tool names present", names == expected_names,
          f"missing={expected_names - names}, extra={names - expected_names}")

    # Each tool should have name, description, inputSchema
    for t in tools:
        has_fields = all(k in t for k in ("name", "description", "inputSchema"))
        if not has_fields:
            check(f"tool {t.get('name')} has required fields", False, str(t.keys()))
            return
    check("all tools have name/description/inputSchema", True)

    # All grouped tools require 'action' param
    for t in tools:
        schema = t.get("inputSchema", {})
        required = schema.get("required") or []
        check(f"{t['name']} requires 'action'", "action" in required,
              f"required={required}")


def test_tool_call_dispatches():
    """tools/call dispatches to backend (will fail with socket error, which is expected)."""
    print("\n--- test_tool_call_dispatches ---")
    tools_to_test = [
        ("cmux_system", {"action": "ping"}),
        ("cmux_system", {"action": "identify"}),
        ("cmux_workspace", {"action": "list"}),
        ("cmux_surface", {"action": "read_text"}),
        ("cmux_surface", {"action": "send_key", "key": "enter"}),
        ("cmux_surface", {"action": "send_text", "text": "hello"}),
        ("cmux_window", {"action": "list"}),
        ("cmux_pane", {"action": "list"}),
        ("cmux_notification", {"action": "list"}),
    ]

    for tool_name, args in tools_to_test:
        label = f"{tool_name}/{args.get('action')}"
        msgs = [init_msg(1), tools_call_msg(tool_name, args, id=2)]
        responses = mcp_session(msgs)
        if len(responses) < 2:
            check(f"{label} got response", False, f"only {len(responses)} responses")
            continue

        r = responses[1]
        has_result = "result" in r
        has_error = "error" in r
        check(f"{label} returns result or error", has_result or has_error, str(r))

        if has_error:
            err_msg = r["error"].get("message", "")
            is_connection_error = any(kw in err_msg.lower() for kw in [
                "failed to connect", "execution failed", "connection refused",
                "socket", "not connected",
            ])
            check(f"{label} error is backend failure (not param error)",
                  is_connection_error, f"error: {err_msg}")


def test_action_validation():
    """Grouped tools validate action names and required params."""
    print("\n--- test_action_validation ---")

    # Missing action
    msgs = [init_msg(1), tools_call_msg("cmux_surface", {}, id=2)]
    responses = mcp_session(msgs)
    if len(responses) >= 2:
        err = responses[1].get("error", {})
        check("missing 'action' returns error", err.get("code") == -32602,
              f"code={err.get('code')}, msg={err.get('message')}")

    # Unknown action
    msgs = [init_msg(1), tools_call_msg("cmux_surface", {"action": "bogus"}, id=2)]
    responses = mcp_session(msgs)
    if len(responses) >= 2:
        err = responses[1].get("error", {})
        check("unknown action returns error", err.get("code") == -32602,
              f"code={err.get('code')}, msg={err.get('message')}")

    # Missing required param: surface.send_text needs 'text'
    msgs = [init_msg(1), tools_call_msg("cmux_surface", {"action": "send_text"}, id=2)]
    responses = mcp_session(msgs)
    if len(responses) >= 2:
        err = responses[1].get("error", {})
        check("missing required 'text' returns error", err.get("code") == -32602,
              f"code={err.get('code')}, msg={err.get('message')}")

    # Missing required param: surface.send_key needs 'key'
    msgs = [init_msg(1), tools_call_msg("cmux_surface", {"action": "send_key"}, id=2)]
    responses = mcp_session(msgs)
    if len(responses) >= 2:
        err = responses[1].get("error", {})
        check("missing required 'key' returns error", err.get("code") == -32602,
              f"code={err.get('code')}, msg={err.get('message')}")

    # Missing required param: surface.close needs 'surface_id'
    msgs = [init_msg(1), tools_call_msg("cmux_surface", {"action": "close"}, id=2)]
    responses = mcp_session(msgs)
    if len(responses) >= 2:
        err = responses[1].get("error", {})
        check("missing required 'surface_id' for close returns error",
              err.get("code") == -32602,
              f"code={err.get('code')}, msg={err.get('message')}")

    # Missing required param: workspace.select needs 'workspace_id'
    msgs = [init_msg(1), tools_call_msg("cmux_workspace", {"action": "select"}, id=2)]
    responses = mcp_session(msgs)
    if len(responses) >= 2:
        err = responses[1].get("error", {})
        check("missing required 'workspace_id' for select returns error",
              err.get("code") == -32602,
              f"code={err.get('code')}, msg={err.get('message')}")


def test_method_not_found():
    """Unknown method returns methodNotFound error."""
    print("\n--- test_method_not_found ---")
    msgs = [
        init_msg(1),
        {"jsonrpc": "2.0", "id": 2, "method": "unknown/method"},
    ]
    responses = mcp_session(msgs)
    check("got 2 responses", len(responses) == 2, f"got {len(responses)}")
    if len(responses) < 2:
        return

    r = responses[1]
    err = r.get("error", {})
    check("error code is -32601 (methodNotFound)", err.get("code") == -32601)


def test_tool_not_found():
    """tools/call with unknown tool returns error."""
    print("\n--- test_tool_not_found ---")
    msgs = [init_msg(1), tools_call_msg("cmux_nonexistent", {"action": "test"}, id=2)]
    responses = mcp_session(msgs)
    if len(responses) < 2:
        check("tool not found response", False, "no response")
        return

    r = responses[1]
    err = r.get("error", {})
    check("returns error for unknown tool", err.get("code") == -32601,
          f"got code={err.get('code')}")


def test_not_initialized():
    """Calling tools/list without initialize returns error."""
    print("\n--- test_not_initialized ---")
    msgs = [tools_list_msg(1)]  # Skip initialize
    responses = mcp_session(msgs)
    check("got 1 response", len(responses) == 1, f"got {len(responses)}")
    if not responses:
        return

    r = responses[0]
    err = r.get("error", {})
    check("returns server error for uninitialized", err.get("code") == -32000,
          f"got code={err.get('code')}, msg={err.get('message')}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    global CMUX_BIN

    if len(sys.argv) > 1:
        CMUX_BIN = sys.argv[1]
    else:
        import glob
        candidates = [
            os.path.expanduser("~/.local/bin/cmux-mcp"),
            *glob.glob(os.path.expanduser(
                "~/Library/Developer/Xcode/DerivedData/GhosttyTabs-*/Build/Products/Debug/cmux"
            )),
            "/Applications/cmux.app/Contents/Resources/bin/cmux",
        ]
        for c in candidates:
            if os.path.isfile(c) and os.access(c, os.X_OK):
                CMUX_BIN = c
                break

    if not CMUX_BIN:
        print("ERROR: cmux binary not found. Pass path as argument.")
        sys.exit(1)

    print(f"Testing MCP server: {CMUX_BIN}")

    test_initialize()
    test_tools_list()
    test_tool_call_dispatches()
    test_action_validation()
    test_method_not_found()
    test_tool_not_found()
    test_not_initialized()

    print(f"\n{'='*50}")
    print(f"Results: {passed} passed, {failed} failed")
    print(f"{'='*50}")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
