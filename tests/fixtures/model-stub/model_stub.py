#!/usr/bin/env python3
"""The shared model stub: a stand-in model endpoint for agent tests, so no test needs a real model login.

One small server that speaks the two wire formats the harnesses use:
  - Anthropic Messages (POST /v1/messages, streamed or not, plus /v1/messages/count_tokens), for Claude Code
    with ANTHROPIC_BASE_URL=http://127.0.0.1:PORT;
  - OpenAI Responses (POST /v1/responses, streamed or not), for Codex with a model provider whose base_url is
    http://127.0.0.1:PORT/v1.
GET /v1/models answers both shapes, plus Codex's {"models": [...]}. Standard library only, Python 3.9+, so it runs
on a runner, a Cloud machine or a Mac as it is.

A script says what the model does. It is JSON: {"version": 1, "steps": [...]}. A request's step is the number of
tool results already in its conversation, so the reply never depends on server state, and a retried request gets
the same answer. Past the last step the last step repeats. A step is one of:
  {"text": "..."}                    a text reply that ends the turn;
  {"shell": "echo hi"}               one shell tool call, sent as the shell tool the client offered: Claude Code's
                                     Bash, or Codex's exec_command, shell or local_shell;
  {"tool": {"name": N, "input": {...}}}  one call to a named tool, verbatim (for OpenAI, "arguments" may stand in
                                     for "input").
Text and commands are templates: {{nonce}} is --nonce, {{result.N}} is the text of the conversation's Nth tool
result (from 0, trimmed), and {{result.N~REGEX}} is the first group of REGEX (case-insensitive, dot matches
newline) in that text, or "" when it does not match (a REGEX cannot end in "}"). {{prompt}} and {{prompt~REGEX}}
are the same for the text of the conversation's last user message (not its tool results), so a test can ask for an
exact reply ("Reply with exactly PONG-7") and get it back: {{prompt~exactly (PONG-\\S+)}}. In a tool step's input every
string is filled in on its own. Without --script the stub replies "Stub reply {{nonce}}.". A request that offers no
tools (Claude Code's title and topic side requests) always gets a short text reply and is logged with "side": true,
so it never takes a script step.

Every request is one JSON line in --log: the protocol, path, model, whether it streamed, the step it got, the tool
names offered and the SHA-256 of the credential it carried (Authorization bearer or x-api-key, never the value), so
a test can prove a forwarded login reached the harness without the test ever holding a real one. GET /__stub/info
returns the version and the nonce; GET /__stub/log returns the log rows.

  python3 model_stub.py [--host 127.0.0.1] [--port 0] [--script FILE] [--nonce N] [--log FILE] [--ready-file FILE]

It prints one line, {"port": P, "url": "http://HOST:P", "version": V}, once it listens (and writes it to
--ready-file). Scripts the tests share are in this directory (*.json).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

# Bump on any change a script or a test could notice (wire shapes, template grammar, log fields).
STUB_VERSION = 2  # 2: {{prompt}} templates

DEFAULT_SCRIPT: dict[str, Any] = {"version": 1, "steps": [{"text": "Stub reply {{nonce}}."}]}
# Codex's exec_command result starts with a header (Chunk ID, Wall time, exit code, token count) before "Output:";
# {{result.N}} is the command's own output, as it is for Claude Code's Bash.
_CODEX_EXEC_HEADER = re.compile(r"\A(?:(?:Chunk ID|Wall time|Process exited|Process running|Original token count)[^\n]*\n)+Output:\n")
_TEMPLATE = re.compile(r"\{\{\s*(nonce|(?:prompt|result\.(\d+))(?:~(.*?))?)\s*\}\}", re.S)


class Results(list):
    """A conversation's tool result texts, in order, with the text of its last user message as .prompt."""

    def __init__(self, items: list[str] = (), prompt: str = "") -> None:
        super().__init__(items)
        self.prompt = prompt


def load_script(path: str | None) -> dict[str, Any]:
    if not path:
        return DEFAULT_SCRIPT
    with open(path, encoding="utf-8") as f:
        script = json.load(f)
    if script.get("version") != 1 or not isinstance(script.get("steps"), list) or not script["steps"]:
        raise ValueError(f"{path}: a script is {{\"version\": 1, \"steps\": [...]}} with at least one step")
    for i, step in enumerate(script["steps"]):
        if not isinstance(step, dict) or len({"text", "shell", "tool"} & step.keys()) != 1:
            raise ValueError(f"{path}: step {i} must have exactly one of text, shell or tool")
        if "tool" in step and not (isinstance(step["tool"], dict) and isinstance(step["tool"].get("name"), str)):
            raise ValueError(f"{path}: step {i}: a tool step is {{\"tool\": {{\"name\": ..., \"input\": {{...}}}}}}")
        if ("text" in step and not isinstance(step["text"], str)) or ("shell" in step and not isinstance(step["shell"], str)):
            raise ValueError(f"{path}: step {i}: text and shell are strings")
        for m in _TEMPLATE.finditer(json.dumps(step)):
            if m.group(3) is not None:
                try:
                    re.compile(json.loads(f'"{m.group(3)}"'))
                except (re.error, ValueError) as e:
                    raise ValueError(f"{path}: step {i}: bad template regex {m.group(3)!r}: {e}") from None
    return script


def render(template: str, nonce: str, results: list[str]) -> str:
    def sub(m: re.Match[str]) -> str:
        if m.group(1) == "nonce":
            return nonce
        if m.group(2) is None:
            text = getattr(results, "prompt", "").strip()
        else:
            n = int(m.group(2))
            text = results[n].strip() if n < len(results) else ""
        if m.group(3) is None:
            return text
        found = re.search(m.group(3), text, re.I | re.S)
        return (found.group(1) if found and found.groups() else found.group(0) if found else "").strip()

    return _TEMPLATE.sub(sub, template)


def render_value(value: Any, nonce: str, results: list[str]) -> Any:
    """A tool input with every string filled in on its own (so a result's quotes and newlines stay data)."""
    if isinstance(value, str):
        return render(value, nonce, results)
    if isinstance(value, list):
        return [render_value(v, nonce, results) for v in value]
    if isinstance(value, dict):
        return {k: render_value(v, nonce, results) for k, v in value.items()}
    return value


def _text_of(content: Any) -> str:
    """A tool result's text, whatever shape the client sent it in."""
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return "\n".join(_text_of(c.get("text", c.get("content", "")) if isinstance(c, dict) else c) for c in content)
    if isinstance(content, dict):
        return _text_of(content.get("text", content.get("output", content.get("content", ""))))
    return "" if content is None else str(content)


def anthropic_results(body: dict[str, Any]) -> Results:
    out, prompt = [], ""
    for m in body.get("messages") or []:
        if not isinstance(m, dict):
            continue
        content = m.get("content")
        if isinstance(content, list):
            out += [_text_of(c.get("content")) for c in content if isinstance(c, dict) and c.get("type") == "tool_result"]
        if m.get("role") == "user":
            text = content if isinstance(content, str) else "\n".join(
                c.get("text", "") for c in content or [] if isinstance(c, dict) and c.get("type") == "text")
            if text.strip():
                prompt = text
    return Results(out, prompt)


def openai_results(body: dict[str, Any]) -> Results:
    items = body.get("input")
    if isinstance(items, str):
        return Results([], items)
    if not isinstance(items, list):
        return Results()
    out, prompt = [], ""
    for it in items:
        if isinstance(it, dict) and it.get("role") == "user":
            content = it.get("content")
            text = content if isinstance(content, str) else "\n".join(
                c.get("text", "") for c in content or [] if isinstance(c, dict) and c.get("type") in ("input_text", "text"))
            if text.strip():
                prompt = text
        if isinstance(it, dict) and it.get("type") in ("function_call_output", "local_shell_call_output", "custom_tool_call_output"):
            raw = it.get("output")
            # Codex sends some outputs as a JSON string {"output": "...", "metadata": {...}}.
            # Any other JSON (a command that printed JSON) stays the text it is.
            if isinstance(raw, str) and raw.startswith("{"):
                try:
                    parsed = json.loads(raw)
                except ValueError:
                    parsed = None
                if isinstance(parsed, dict) and isinstance(parsed.get("output"), str):
                    raw = parsed["output"]
            out.append(_CODEX_EXEC_HEADER.sub("", _text_of(raw), count=1))
    return Results(out, prompt)


def tool_names(body: dict[str, Any]) -> list[str]:
    names = []
    for t in body.get("tools") or []:
        if isinstance(t, dict):
            names.append(t.get("name") or (t.get("function") or {}).get("name") or t.get("type") or "")
    return names


def credential_sha256(headers: Any) -> str:
    auth = headers.get("authorization") or ""
    cred = auth[7:] if auth.lower().startswith("bearer ") else auth
    cred = cred or headers.get("x-api-key") or ""
    return hashlib.sha256(cred.encode()).hexdigest() if cred else ""


def anthropic_tool_call(step: dict[str, Any], offered: list[str], nonce: str, results: list[str]) -> dict[str, Any]:
    if "tool" in step:
        t = step["tool"]
        return {"name": t["name"], "input": render_value(t.get("input", t.get("arguments", {})), nonce, results)}
    return {"name": "Bash", "input": {"command": render(step["shell"], nonce, results), "description": "model stub step"}}


def openai_tool_call(step: dict[str, Any], offered: list[str], nonce: str, results: list[str]) -> dict[str, Any]:
    """{"kind": "function_call", "name", "arguments": str} or {"kind": "local_shell_call", "command": [...]}."""
    if "tool" in step:
        t = step["tool"]
        args = render_value(t.get("arguments", t.get("input", {})), nonce, results)
        return {"kind": "function_call", "name": t["name"], "arguments": json.dumps(args)}
    cmd = render(step["shell"], nonce, results)
    if "exec_command" in offered:
        return {"kind": "function_call", "name": "exec_command", "arguments": json.dumps({"cmd": cmd})}
    if "shell_command" in offered:
        return {"kind": "function_call", "name": "shell_command", "arguments": json.dumps({"command": cmd})}
    if "shell" in offered:
        return {"kind": "function_call", "name": "shell", "arguments": json.dumps({"command": ["bash", "-lc", cmd]})}
    if "local_shell" in offered:
        return {"kind": "local_shell_call", "command": ["bash", "-lc", cmd]}
    raise ValueError(f"a shell step, but the client offered no shell tool (offered: {', '.join(offered) or 'none'})")


class Stub:
    def __init__(self, script: dict[str, Any], nonce: str, log_path: str | None):
        self.script, self.nonce, self.log_path = script, nonce, log_path
        self.rows: list[dict[str, Any]] = []
        self.lock = threading.Lock()

    def step(self, results: list[str], offered: list[str]) -> tuple[int, dict[str, Any]]:
        if not offered:
            return -1, {"text": "Stub side reply."}
        steps = self.script["steps"]
        i = min(len(results), len(steps) - 1)
        return i, steps[i]

    def log(self, row: dict[str, Any]) -> None:
        row = {"t": round(time.time(), 3), **row}
        with self.lock:
            self.rows.append(row)
            if self.log_path:
                with open(self.log_path, "a", encoding="utf-8") as f:
                    f.write(json.dumps(row) + "\n")


def make_handler(stub: Stub) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *args: Any) -> None:  # the JSON log is the record
            pass

        def _json(self, code: int, body: Any) -> None:
            data = json.dumps(body).encode()
            self.send_response(code)
            self.send_header("content-type", "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _sse_start(self) -> None:
            self.send_response(200)
            self.send_header("content-type", "text/event-stream")
            self.send_header("cache-control", "no-cache")
            self.send_header("connection", "close")
            self.end_headers()
            self.close_connection = True

        def _sse(self, event: str, data: dict[str, Any]) -> None:
            self.wfile.write(f"event: {event}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()

        def do_HEAD(self) -> None:
            self.send_response(200)
            self.send_header("content-length", "0")
            self.end_headers()

        def do_GET(self) -> None:
            path = self.path.split("?")[0]
            if path == "/__stub/info":
                return self._json(200, {"version": STUB_VERSION, "nonce": stub.nonce, "steps": len(stub.script["steps"])})
            if path == "/__stub/log":
                with stub.lock:
                    return self._json(200, {"rows": list(stub.rows)})
            stub.log({"protocol": "-", "method": "GET", "path": path, "cred_sha256": credential_sha256(self.headers)})
            if path.endswith("/models"):
                model = {"id": "stub-model", "object": "model", "type": "model", "display_name": "Model stub", "created": 0, "owned_by": "stub"}
                # "data" is the Anthropic and OpenAI list; "models" is Codex's (empty: it keeps its fallback model metadata).
                return self._json(200, {"object": "list", "data": [model], "has_more": False, "first_id": "stub-model", "last_id": "stub-model",
                                        "models": []})
            return self._json(200, {})

        def do_POST(self) -> None:
            if self.headers.get("transfer-encoding") and not self.headers.get("content-length"):
                self.close_connection = True
                return self._json(411, {"error": {"type": "invalid_request_error", "message": "the model stub needs a content-length"}})
            n = int(self.headers.get("content-length") or 0)
            raw = self.rfile.read(n) if n else b""
            try:
                body = json.loads(raw or b"{}")
            except ValueError:
                body = {}
            if not isinstance(body, dict):
                body = {}
            path = self.path.split("?")[0]
            row = {"method": "POST", "path": path, "model": body.get("model"), "stream": bool(body.get("stream")),
                   "cred_sha256": credential_sha256(self.headers), "tools": tool_names(body)}
            if path.endswith("/messages/count_tokens"):
                stub.log({"protocol": "anthropic", **row})
                return self._json(200, {"input_tokens": 10})
            try:
                if path.endswith("/messages"):
                    return self.anthropic(body, row)
                if path.endswith("/responses"):
                    return self.openai(body, row)
            except (BrokenPipeError, ConnectionResetError):  # the client hung up: nothing to answer
                return
            except Exception as e:  # a script that does not fit the request: a 400 (no retry loop), never a dropped connection
                stub.log({"protocol": "anthropic" if path.endswith("/messages") else "openai", **row, "error": str(e)})
                kind = {"type": "error", "error": {"type": "invalid_request_error", "message": f"model stub: {e}"}} if path.endswith("/messages") else {"error": {"type": "invalid_request_error", "message": f"model stub: {e}"}}
                return self._json(400, kind)
            stub.log({"protocol": "-", **row})
            return self._json(404, {"error": {"type": "not_found_error", "message": f"the model stub does not serve {path}"}})

        def anthropic(self, body: dict[str, Any], row: dict[str, Any]) -> None:
            results = anthropic_results(body)
            i, step = stub.step(results, row["tools"])
            content, stop = self.anthropic_content(i, step, row["tools"], results)
            stub.log({"protocol": "anthropic", **row, "tool_results": len(results), "step": i, **({"side": True} if i < 0 else {})})
            model = body.get("model") or "stub-model"
            usage = {"input_tokens": 10, "output_tokens": 5, "cache_creation_input_tokens": 0, "cache_read_input_tokens": 0}
            msg = {"id": f"msg_stub_{uuid.uuid4().hex[:12]}", "type": "message", "role": "assistant", "model": model}
            if not body.get("stream"):
                return self._json(200, {**msg, "content": content, "stop_reason": stop, "stop_sequence": None, "usage": usage})
            self._sse_start()
            self._sse("message_start", {"type": "message_start", "message": {**msg, "content": [], "stop_reason": None, "stop_sequence": None, "usage": {**usage, "output_tokens": 1}}})
            for idx, c in enumerate(content):
                if c["type"] == "text":
                    self._sse("content_block_start", {"type": "content_block_start", "index": idx, "content_block": {"type": "text", "text": ""}})
                    self._sse("content_block_delta", {"type": "content_block_delta", "index": idx, "delta": {"type": "text_delta", "text": c["text"]}})
                else:
                    self._sse("content_block_start", {"type": "content_block_start", "index": idx, "content_block": {"type": "tool_use", "id": c["id"], "name": c["name"], "input": {}}})
                    self._sse("content_block_delta", {"type": "content_block_delta", "index": idx, "delta": {"type": "input_json_delta", "partial_json": json.dumps(c["input"])}})
                self._sse("content_block_stop", {"type": "content_block_stop", "index": idx})
            self._sse("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 5}})
            self._sse("message_stop", {"type": "message_stop"})

        def anthropic_content(self, i: int, step: dict[str, Any], offered: list[str], results: list[str]) -> tuple[list[dict[str, Any]], str]:
            if "text" in step:
                return [{"type": "text", "text": render(step["text"], stub.nonce, results)}], "end_turn"
            call = anthropic_tool_call(step, offered, stub.nonce, results)
            return [{"type": "tool_use", "id": f"toolu_stub{i:02d}{uuid.uuid4().hex[:8]}", **call}], "tool_use"

        def openai_item(self, i: int, step: dict[str, Any], offered: list[str], results: list[str]) -> dict[str, Any]:
            if "text" in step:
                text = render(step["text"], stub.nonce, results)
                return {"type": "message", "id": f"msg_stub_{uuid.uuid4().hex[:8]}", "role": "assistant", "status": "completed",
                        "content": [{"type": "output_text", "text": text, "annotations": []}]}
            call = openai_tool_call(step, offered, stub.nonce, results)
            call_id = f"call_stub{i:02d}{uuid.uuid4().hex[:8]}"
            if call["kind"] == "function_call":
                return {"type": "function_call", "id": f"fc_stub_{uuid.uuid4().hex[:8]}", "call_id": call_id, "name": call["name"],
                        "arguments": call["arguments"], "status": "completed"}
            return {"type": "local_shell_call", "id": f"lsh_stub_{uuid.uuid4().hex[:8]}", "call_id": call_id, "status": "completed",
                    "action": {"type": "exec", "command": call["command"], "env": {}}}

        def openai(self, body: dict[str, Any], row: dict[str, Any]) -> None:
            results = openai_results(body)
            i, step = stub.step(results, row["tools"])
            item = self.openai_item(i, step, row["tools"], results)
            stub.log({"protocol": "openai", **row, "tool_results": len(results), "step": i, **({"side": True} if i < 0 else {})})
            rid = f"resp_stub_{uuid.uuid4().hex[:12]}"
            usage = {"input_tokens": 10, "input_tokens_details": {"cached_tokens": 0}, "output_tokens": 5,
                     "output_tokens_details": {"reasoning_tokens": 0}, "total_tokens": 15}
            response = {"id": rid, "object": "response", "created_at": int(time.time()), "model": body.get("model") or "stub-model",
                        "status": "completed", "output": [item], "usage": usage, "error": None, "incomplete_details": None}
            if not body.get("stream"):
                return self._json(200, response)
            self._sse_start()
            seq = iter(range(1_000_000))

            def ev(kind: str, data: dict[str, Any]) -> None:
                self._sse(kind, {"type": kind, "sequence_number": next(seq), **data})

            ev("response.created", {"response": {**response, "status": "in_progress", "output": [], "usage": None}})
            ev("response.in_progress", {"response": {**response, "status": "in_progress", "output": [], "usage": None}})
            if item["type"] == "message":
                text = item["content"][0]["text"]
                ev("response.output_item.added", {"output_index": 0, "item": {**item, "status": "in_progress", "content": []}})
                part = {"type": "output_text", "text": "", "annotations": []}
                ev("response.content_part.added", {"item_id": item["id"], "output_index": 0, "content_index": 0, "part": part})
                ev("response.output_text.delta", {"item_id": item["id"], "output_index": 0, "content_index": 0, "delta": text})
                ev("response.output_text.done", {"item_id": item["id"], "output_index": 0, "content_index": 0, "text": text})
                ev("response.content_part.done", {"item_id": item["id"], "output_index": 0, "content_index": 0, "part": {**part, "text": text}})
            elif item["type"] == "function_call":
                ev("response.output_item.added", {"output_index": 0, "item": {**item, "arguments": "", "status": "in_progress"}})
                ev("response.function_call_arguments.delta", {"item_id": item["id"], "output_index": 0, "delta": item["arguments"]})
                ev("response.function_call_arguments.done", {"item_id": item["id"], "output_index": 0, "arguments": item["arguments"]})
            else:
                ev("response.output_item.added", {"output_index": 0, "item": {**item, "status": "in_progress"}})
            ev("response.output_item.done", {"output_index": 0, "item": item})
            ev("response.completed", {"response": response})

    return Handler


def serve(script: dict[str, Any], nonce: str, host: str = "127.0.0.1", port: int = 0, log_path: str | None = None) -> tuple[ThreadingHTTPServer, Stub]:
    """Start the stub on a thread (for tests in Python); returns the server (server_address has the port) and the stub."""
    stub = Stub(script, nonce, log_path)
    server = ThreadingHTTPServer((host, port), make_handler(stub))
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server, stub


def main(argv: list[str]) -> int:
    p = argparse.ArgumentParser(description="A stand-in Anthropic Messages and OpenAI Responses endpoint for tests.")
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=0)
    p.add_argument("--script")
    p.add_argument("--nonce", default="")
    p.add_argument("--log")
    p.add_argument("--ready-file")
    a = p.parse_args(argv)
    nonce = a.nonce or uuid.uuid4().hex[:12]
    stub = Stub(load_script(a.script), nonce, a.log)
    server = ThreadingHTTPServer((a.host, a.port), make_handler(stub))
    server.daemon_threads = True
    ready = json.dumps({"port": server.server_address[1], "url": f"http://{a.host}:{server.server_address[1]}", "version": STUB_VERSION, "nonce": nonce})
    if a.ready_file:  # whole or absent: a poller never reads half a line
        tmp = f"{a.ready_file}.{os.getpid()}.tmp"
        with open(tmp, "w", encoding="utf-8") as f:
            f.write(ready + "\n")
        os.replace(tmp, a.ready_file)
    print(ready, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
