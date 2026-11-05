#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""The onboarding suite's agent: an ACP agent with no model that uses two apps in the background.

The installed NIGHTLY's acpmux starts it as the `onbagent` harness. At `session/prompt` it starts
the `cmux-cua` MCP server acpmux gave its session, exactly as a model's harness does, and through
the cmux Computer Use helper:

  click    Calculator: All Clear, 6, x, 7, =; its display must then read 42
  type     TextEdit: a new document, then "cmux onboarding 42" typed into it
  drag     TextEdit: a drag across that line selects it; Cmd-C copies it; the pasteboard must hold it

None of these apps may come to the front: the frontmost app is read before and after each step
(`lsappinfo front`) and any change is a focus steal, which fails the run. A model would choose its
own steps; this agent's are fixed, so a run passes or fails on cmux and the helper, not a model.

It writes $ONB_OUT/agent-result.json and ends the turn with a one-line summary. The MCP plumbing
(Mcp, payload, find, failed) is scripts/cmux-next/cua_v2_probe_agent.py's, copied here so the
matrix runner directory the worker checks holds all the code that runs.
"""
import json, os, re, select, subprocess, sys, threading, time

OUT = os.environ["ONB_OUT"]
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


TYPED = "cmux onboarding 42"


def front():
    out = subprocess.run(["/usr/bin/lsappinfo", "front"], capture_output=True, text=True).stdout.strip()
    name = subprocess.run(["/usr/bin/lsappinfo", "info", "-only", "name", out], capture_output=True, text=True).stdout
    m = re.search(r'"LSDisplayName"="([^"]*)"', name)
    return m.group(1) if m else out


def label_of(node):
    return " ".join(str(node.get(k, "")) for k in ("label", "title", "name", "description", "identifier", "value"))


def element_args(pid, window_id, node):
    if node.get("element_token"):
        return {"pid": pid, "element_token": node["element_token"]}
    return {"pid": pid, "window_id": window_id, "element_index": node["element_index"]}


def addressable(node):
    return isinstance(node, dict) and ("element_token" in node or "element_index" in node)


class Run:
    def __init__(self, mcp):
        self.mcp, self.steps, self.checks = mcp, [], {}
        self.front0 = front()
        self.steals = []

    def call(self, name, args, timeout=60.0):
        res = self.mcp.call(name, args, timeout)
        self.steps.append(strip_images(res))
        now = front()
        if now != self.front0:
            self.steals.append({"after": name, "front": now})
        return res

    def launch(self, app):
        res = self.call("launch_app", {"name": app})
        body = payload(res)
        pid = body.get("pid") or (find(body, lambda n: "pid" in n) or {}).get("pid")
        win = find(body, lambda n: "window_id" in n)
        if pid and not win:
            win = find(payload(self.call("list_windows", {"pid": pid})), lambda n: "window_id" in n)
        if not pid or not win:
            raise RuntimeError(f"launch_app {app}: no pid or window in {json.dumps(body)[:400]}")
        return int(pid), int(win["window_id"])

    def state(self, pid, window_id):
        return payload(self.call("get_window_state", {"pid": pid, "window_id": window_id, "max_elements": 400}))

    def tool_props(self, name):
        tool = next((t for t in self.tools if t.get("name") == name), {})
        return set(((tool.get("inputSchema") or {}).get("properties") or {}).keys())

    def calculator(self):
        pid, win = self.launch("Calculator")
        for want in (r"^all clear$|^clear$|^ac$", r"^6$", r"multiply|^×$|^\*$", r"^7$", r"equals|^=$"):
            node = find(self.state(pid, win), lambda n: addressable(n) and any(
                re.search(want, str(n.get(k, "")).strip(), re.I) for k in ("label", "title", "description", "identifier")))
            if not node:
                raise RuntimeError(f"Calculator has no button matching {want}")
            if failed(self.call("click", element_args(pid, win, node))):
                raise RuntimeError(f"click {want} failed")
        shown = self.state(pid, win)
        self.checks["click"] = bool(find(shown, lambda n: re.fullmatch(r"\s*42\s*", str(n.get("value", ""))) is not None))

    def textedit(self):
        pid, win = self.launch("TextEdit")
        # A new TextEdit can open on its Open panel: Cmd-N gives a document either way.
        self.call("press_key", {"pid": pid, "key": "cmd+n"})
        time.sleep(1)  # the new document's window appears asynchronously; list_windows reads it after
        windows = payload(self.call("list_windows", {"pid": pid}))
        docs = [n for n in (windows if isinstance(windows, list) else windows.get("windows") or []) if "window_id" in n]
        win = int((docs[0] if docs else {"window_id": win})["window_id"])
        state = self.state(pid, win)
        area = find(state, lambda n: addressable(n) and re.search(r"text ?(area|view)", str(n.get("role", "")), re.I))
        args = {"pid": pid, "text": TYPED}
        if area:
            args.update({k: v for k, v in element_args(pid, win, area).items() if k != "pid"})
        if failed(self.call("type_text", args)):
            raise RuntimeError("type_text failed")
        state = self.state(pid, win)
        self.checks["type"] = bool(find(state, lambda n: TYPED in str(n.get("value", ""))))
        # Drag across the typed line (window-local points of the text area's first line), then copy.
        frame = (area or {}).get("frame") or (find(state, lambda n: TYPED in str(n.get("value", ""))) or {}).get("frame") or {}
        x0 = int(frame.get("x", 20)) + 4
        y0 = int(frame.get("y", 60)) + 10
        props = self.tool_props("drag")
        drag = {"pid": pid, "window_id": win}
        if {"from_x", "from_y", "to_x", "to_y"} <= props:
            drag.update(from_x=x0, from_y=y0, to_x=x0 + 400, to_y=y0)
        elif {"start_x", "start_y", "end_x", "end_y"} <= props:
            drag.update(start_x=x0, start_y=y0, end_x=x0 + 400, end_y=y0)
        else:
            drag.update(path=[{"x": x0, "y": y0}, {"x": x0 + 400, "y": y0}])
        if failed(self.call("drag", drag)):
            self.checks["drag"] = False
            return
        self.call("press_key", {"pid": pid, "key": "cmd+c"})
        time.sleep(0.5)  # the pasteboard write lands after the key event; pbpaste reads it after
        pasted = subprocess.run(["/usr/bin/pbpaste"], capture_output=True, text=True).stdout
        self.checks["drag"] = TYPED in pasted
        self.checks["pasteboard"] = pasted[:200]


def act(servers):
    report = {"steps": [], "checks": {}}
    entry = next((s for s in servers or [] if s.get("name") == "cmux-cua"), None)
    if not entry:
        report["error"] = "acpmux gave this session no cmux-cua MCP server"
        return report
    mcp = Mcp(entry, os.path.join(OUT, "agent-mcp-stderr.log"))
    run = Run(mcp)
    try:
        mcp.request("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                   "clientInfo": {"name": "onboarding-agent", "version": "1"}})
        mcp.notify("notifications/initialized")
        run.tools = ((mcp.request("tools/list", {}).get("result") or {}).get("tools") or [])
        report["tools"] = [t.get("name") for t in run.tools]
        perms = payload(run.call("check_permissions", {"prompt": False}))
        report["permissions"] = {k: perms.get(k) for k in ("accessibility", "screen_recording")}
        for name, step in (("calculator", run.calculator), ("textedit", run.textedit)):
            try:
                step()
            except Exception as error:  # the report says which step broke; the other still runs
                report.setdefault("errors", {})[name] = repr(error)
    finally:
        mcp.close()
    report["steps"], report["checks"] = run.steps, run.checks
    report["front"] = run.front0
    report["focus_steals"] = run.steals
    report["ok"] = all(run.checks.get(k) is True for k in ("click", "type", "drag")) and not run.steals
    return report


def handle_prompt(rid, params):
    sid = params.get("sessionId")
    try:
        report = act(servers_by_session.get(sid))
    except Exception as error:
        report = {"ok": False, "error": f"agent failed: {error!r}"}
    tmp = os.path.join(OUT, "agent-result.json.tmp")
    with open(tmp, "w") as f:
        json.dump(report, f, indent=1)
    os.replace(tmp, os.path.join(OUT, "agent-result.json"))
    update(sid, "onboarding-agent " + json.dumps({k: report.get(k) for k in ("ok", "checks", "focus_steals", "errors", "error")})[:2000])
    send({"jsonrpc": "2.0", "id": rid, "result": {"stopReason": "end_turn"}})


def main():
    sessions = 0
    for line in sys.stdin:
        if not line.strip():
            continue
        msg = json.loads(line)
        method, rid, params = msg.get("method"), msg.get("id"), msg.get("params") or {}
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": rid, "result": {
                "protocolVersion": 1, "agentInfo": {"name": "onboarding-agent", "version": "1"},
                "agentCapabilities": {"loadSession": False}, "authMethods": []}})
        elif method == "session/new":
            sessions += 1
            sid = f"onboarding-agent-{os.getpid()}-{sessions}"
            servers_by_session[sid] = params.get("mcpServers")
            send({"jsonrpc": "2.0", "id": rid, "result": {"sessionId": sid}})
        elif method == "session/prompt":
            threading.Thread(target=handle_prompt, args=(rid, params), daemon=True).start()
        elif method is not None and rid is not None and method != "session/cancel":
            send({"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": f"no such method {method}"}})


if __name__ == "__main__":
    main()
