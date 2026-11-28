#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The scripted agent of cua-helper-v2-live.py: an ACP agent (stdio JSON-RPC) with no model.

The tagged app's acpmux daemon starts it as the `cuaprobe` harness (config.json in the run's
ACPMUX_HOME). At `session/new` it keeps the `mcpServers` acpmux gives it. At `session/prompt` it
starts the `cmux-cua` server from that list exactly as an agent does (for the helper v2 that is
`acpmux cua-mcp`, a descendant of the daemon), and calls the helper's tools over MCP:

  tools/list; check_permissions {"prompt": false} (a read, it changes nothing);
  then, only when Accessibility and Screen Recording are both granted: list_windows of the test
  window's pid, ONE get_window_state (the screenshot) and ONE click on the window's checkbox.

It writes everything to $CUA_PROBE_OUT/agent-result.json (the screenshot to screenshot.png) and
answers the prompt with a one-line summary. The test window's state file is $CUA_PROBE_TARGET.
"""
import base64, json, os, select, subprocess, sys, threading, time

OUT = os.environ["CUA_PROBE_OUT"]
TARGET = os.environ["CUA_PROBE_TARGET"]
TITLE = os.environ.get("CUA_PROBE_TITLE", "")
lock = threading.Lock()
servers_by_session = {}


def send(obj):
    with lock:
        sys.stdout.write(json.dumps(obj) + "\n")
        sys.stdout.flush()


def update(sid, text):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": sid, "update": {
        "sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}}}})


class Mcp:
    """One MCP stdio server, started from an ACP mcpServers entry."""

    def __init__(self, entry, log_path):
        env = dict(os.environ)
        for pair in entry.get("env") or []:
            env[pair["name"]] = pair["value"]
        self.log = open(log_path, "ab")
        self.proc = subprocess.Popen([entry["command"], *entry.get("args", [])], env=env,
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.log)
        self.next_id = 1
        self.buffer = b""

    def request(self, method, params, timeout=60.0):
        rid = self.next_id
        self.next_id += 1
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "id": rid, "method": method, "params": params}) + "\n").encode())
        self.proc.stdin.flush()
        deadline = time.time() + timeout
        while time.time() < deadline:
            while b"\n" in self.buffer:
                line, self.buffer = self.buffer.split(b"\n", 1)
                if not line.strip():
                    continue
                reply = json.loads(line)
                if reply.get("id") == rid:
                    return reply
            ready, _, _ = select.select([self.proc.stdout], [], [], max(0.0, deadline - time.time()))
            if not ready:
                break
            chunk = os.read(self.proc.stdout.fileno(), 1 << 22)
            if not chunk:
                return {"error": {"message": f"the MCP server exited (code {self.proc.poll()})"}}
            self.buffer += chunk
        return {"error": {"message": f"no reply to {method} in {timeout:g} s"}}

    def notify(self, method):
        self.proc.stdin.write((json.dumps({"jsonrpc": "2.0", "method": method}) + "\n").encode())
        self.proc.stdin.flush()

    def call(self, name, arguments, timeout=60.0):
        started = time.time()
        reply = self.request("tools/call", {"name": name, "arguments": arguments}, timeout)
        return {"tool": name, "arguments": arguments, "seconds": round(time.time() - started, 3), "reply": reply}

    def close(self):
        try:
            self.proc.stdin.close()
            self.proc.wait(10)
        except (OSError, subprocess.TimeoutExpired):
            self.proc.terminate()
            self.proc.wait(5)
        self.log.close()


def payload(call):
    """The tool's JSON payload: structuredContent, else the first text content parsed as JSON."""
    result = (call.get("reply") or {}).get("result") or {}
    if isinstance(result.get("structuredContent"), (dict, list)):
        return result["structuredContent"]
    for item in result.get("content") or []:
        if item.get("type") == "text":
            try:
                return json.loads(item["text"])
            except (ValueError, TypeError):
                return {"text": item.get("text")}
    return {}


def failed(call):
    reply = call.get("reply") or {}
    return "error" in reply or bool((reply.get("result") or {}).get("isError"))


def find(node, predicate):
    if isinstance(node, dict):
        if predicate(node):
            return node
        values = node.values()
    elif isinstance(node, list):
        values = node
    else:
        return None
    for value in values:
        hit = find(value, predicate)
        if hit is not None:
            return hit
    return None


def strip_images(call):
    """The call with base64 image data replaced by its length (the PNG is saved separately)."""
    text = json.dumps(call)
    value = json.loads(text)
    for item in ((value.get("reply") or {}).get("result") or {}).get("content") or []:
        if item.get("type") == "image" and isinstance(item.get("data"), str):
            item["data"] = f"<{len(item['data'])} base64 chars, saved>"
    structured = ((value.get("reply") or {}).get("result") or {}).get("structuredContent")
    if isinstance(structured, dict):
        for key in ("screenshot", "screenshot_base64", "image"):
            if isinstance(structured.get(key), str) and len(structured[key]) > 512:
                structured[key] = f"<{len(structured[key])} base64 chars, saved>"
    return value


def probe(servers):
    report = {"mcp_servers": servers, "steps": []}
    entry = next((s for s in servers or [] if s.get("name") == "cmux-cua"), None)
    report["cua_server"] = entry
    if not entry:
        report["error"] = "acpmux gave this session no cmux-cua MCP server"
        return report
    report["bridge_is_acpmux_cua_mcp"] = os.path.basename(entry.get("command", "")) == "acpmux" and entry.get("args") == ["cua-mcp"]
    mcp = Mcp(entry, os.path.join(OUT, "bridge-stderr.log"))
    report["bridge_pid"] = mcp.proc.pid
    report["probe_pid"] = os.getpid()
    report["probe_ppid"] = os.getppid()
    try:
        init = mcp.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                          "clientInfo": {"name": "cua-v2-probe", "version": "1"}})
        report["initialize"] = init
        mcp.notify("notifications/initialized")
        listed = mcp.request("tools/list", {})
        report["tools"] = [t.get("name") for t in ((listed.get("result") or {}).get("tools") or [])]
        if "error" in listed:
            report["tools_list_error"] = listed["error"]
        perms = mcp.call("check_permissions", {"prompt": False})
        report["steps"].append(perms)
        granted = payload(perms)
        report["permissions"] = {"accessibility": granted.get("accessibility"),
                                 "screen_recording": granted.get("screen_recording"),
                                 "source": granted.get("source")}
        missing = [name for name, key in (("Accessibility", "accessibility"), ("Screen Recording", "screen_recording"))
                   if granted.get(key) is not True]
        report["missing_grants"] = missing
        if failed(perms) or missing:
            report["skipped"] = "screenshot and click skipped: " + (
                "check_permissions failed" if failed(perms) else "missing " + " and ".join(missing))
            return report
        with open(TARGET) as f:
            target = json.load(f)
        pid = target["pid"]
        windows = mcp.call("list_windows", {"pid": pid})
        report["steps"].append(windows)
        window = find(payload(windows), lambda n: n.get("title") == TITLE and "window_id" in n) or \
            find(payload(windows), lambda n: "window_id" in n)
        if not window:
            report["error"] = "list_windows found no window of the test window's pid"
            return report
        window_id = int(window["window_id"])
        report["window"] = window
        shot = mcp.call("get_window_state", {"pid": pid, "window_id": window_id, "max_elements": 200})
        report["steps"].append(strip_images(shot))
        image = next((c for c in ((shot.get("reply") or {}).get("result") or {}).get("content") or [] if c.get("type") == "image"), None)
        if image:
            with open(os.path.join(OUT, "screenshot.png"), "wb") as f:
                f.write(base64.b64decode(image["data"]))
            report["screenshot"] = {"path": os.path.join(OUT, "screenshot.png"), "mime": image.get("mimeType"),
                                    "bytes": os.path.getsize(os.path.join(OUT, "screenshot.png"))}
        if failed(shot):
            report["error"] = "get_window_state failed"
            return report
        state = payload(shot)
        checkbox = find(state, lambda n: any("cua-probe-target" in str(n.get(k, "")) for k in ("label", "title", "name", "description", "value", "text"))
                        and ("element_token" in n or "element_index" in n))
        if checkbox and checkbox.get("element_token"):
            arguments = {"pid": pid, "element_token": checkbox["element_token"]}
        elif checkbox and "element_index" in checkbox:
            arguments = {"pid": pid, "window_id": window_id, "element_index": checkbox["element_index"]}
        else:
            # No AX row for the checkbox: click its pixel centre in the screenshot (window-local pixels).
            width = state.get("screenshot_width") or state.get("width") or 720
            height = state.get("screenshot_height") or state.get("height") or 412
            scale = width / 360.0
            arguments = {"pid": pid, "window_id": window_id, "x": round(52 * scale), "y": round(height - 90 * scale)}
        report["click_target"] = {"checkbox_row": checkbox, "arguments": arguments}
        click = mcp.call("click", arguments)
        report["steps"].append(click)
        deadline = time.time() + 10
        after = None
        while time.time() < deadline:
            with open(TARGET) as f:
                after = json.load(f)
            if after.get("clicks", 0) >= 1:
                break
            time.sleep(0.1)  # a bounded wait for the test window's own state file
        report["window_after_click"] = after
        report["click_landed"] = bool(after and after.get("clicks", 0) >= 1)
        return report
    finally:
        mcp.close()
        report["bridge_exit"] = mcp.proc.returncode


def handle_prompt(rid, params):
    sid = params.get("sessionId")
    try:
        report = probe(servers_by_session.get(sid))
    except Exception as error:  # the report says what broke; the turn still ends
        report = {"error": f"probe failed: {error!r}"}
    with open(os.path.join(OUT, "agent-result.json.tmp"), "w") as f:
        json.dump(report, f, indent=1)
    os.replace(os.path.join(OUT, "agent-result.json.tmp"), os.path.join(OUT, "agent-result.json"))
    summary = {k: report.get(k) for k in ("bridge_is_acpmux_cua_mcp", "tools", "permissions", "missing_grants",
                                          "skipped", "click_landed", "error")}
    update(sid, "cua-v2-probe " + json.dumps(summary)[:2000])
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


def main():
    sessions = 0
    for line in sys.stdin:
        if not line.strip():
            continue
        msg = json.loads(line)
        method, rid, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
        if method is None:
            continue
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": 1, "agentInfo": {"name": "cua-v2-probe", "version": "1"},
                "agentCapabilities": {"loadSession": False}, "authMethods": []}})
        elif method == "session/new":
            sessions += 1
            sid = f"cua-v2-probe-{os.getpid()}-{sessions}"
            servers_by_session[sid] = params.get("mcpServers")
            send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": sid}})
        elif method == "session/prompt":
            threading.Thread(target=handle_prompt, args=(rid, params), daemon=True).start()
        elif method == "session/cancel":
            pass
        elif rid is not None:
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"no such method {method}"}})


if __name__ == "__main__":
    main()
