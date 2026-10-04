#!/usr/bin/env python3
"""Scripted Anthropic Messages endpoint for the remote-floor probes.

The first model call of a conversation answers with one tool_use from
FAKE_TOOL_NAME and FAKE_TOOL_INPUT (JSON). A call whose last user message
carries a tool_result answers with the text "done". Every other request
(title, token count, model list) gets a minimal valid reply. No secrets:
any API key is accepted. Prints "listening <port>" when ready.
"""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

TOOL_NAME = os.environ.get("FAKE_TOOL_NAME", "Bash")
TOOL_INPUT = json.loads(os.environ.get("FAKE_TOOL_INPUT", '{"command": "true"}'))
LOG = os.environ.get("FAKE_MODEL_LOG")
# A secret the probe planted in a file; the log records whether any request
# body carried it back to the model (a read or an @path expansion leaked it).
SECRET = os.environ.get("FAKE_SECRET")
# Strings planted in user skills, commands, agents and hooks; the log records
# which ones reached the model (the definition was loaded).
SENTINELS = [x for x in os.environ.get("FAKE_SENTINELS", "").split(",") if x]


def has_tool_result(body):
    messages = body.get("messages") or []
    if not messages:
        return False
    content = messages[-1].get("content")
    if isinstance(content, list):
        return any(isinstance(b, dict) and b.get("type") == "tool_result" for b in content)
    return False


def offers_tool(body):
    return any(t.get("name") == TOOL_NAME for t in body.get("tools") or [])


def blocks_for(body):
    if offers_tool(body) and not has_tool_result(body):
        return [{"type": "tool_use", "id": "toolu_probe_1", "name": TOOL_NAME, "input": TOOL_INPUT}], "tool_use"
    return [{"type": "text", "text": "done"}], "end_turn"


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def _json(self, code, payload):
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self._json(200, {"data": [], "has_more": False})

    def do_HEAD(self):
        self.send_response(200)
        self.send_header("content-length", "0")
        self.end_headers()

    def do_POST(self):
        length = int(self.headers.get("content-length") or 0)
        body = json.loads(self.rfile.read(length) or b"{}")
        if LOG:
            with open(LOG, "a") as log:
                log.write(json.dumps({"path": self.path, "tools": [t.get("name") for t in body.get("tools") or []],
                                      "tool_result": has_tool_result(body),
                                      "secret_seen": bool(SECRET) and SECRET in json.dumps(body),
                                      "sentinels": [x for x in SENTINELS if x in json.dumps(body)]}) + "\n")
        if "count_tokens" in self.path:
            self._json(200, {"input_tokens": 1})
            return
        blocks, stop = blocks_for(body)
        model = body.get("model", "claude-fake")
        usage = {"input_tokens": 1, "output_tokens": 1}
        if not body.get("stream"):
            self._json(200, {"id": "msg_probe", "type": "message", "role": "assistant", "model": model,
                             "content": blocks, "stop_reason": stop, "stop_sequence": None, "usage": usage})
            return
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.send_header("connection", "close")
        self.end_headers()

        def event(name, payload):
            self.wfile.write(f"event: {name}\ndata: {json.dumps(payload)}\n\n".encode())

        event("message_start", {"type": "message_start", "message": {
            "id": "msg_probe", "type": "message", "role": "assistant", "model": model, "content": [],
            "stop_reason": None, "stop_sequence": None, "usage": usage}})
        for index, block in enumerate(blocks):
            if block["type"] == "tool_use":
                event("content_block_start", {"type": "content_block_start", "index": index, "content_block": {
                    "type": "tool_use", "id": block["id"], "name": block["name"], "input": {}}})
                event("content_block_delta", {"type": "content_block_delta", "index": index, "delta": {
                    "type": "input_json_delta", "partial_json": json.dumps(block["input"])}})
            else:
                event("content_block_start", {"type": "content_block_start", "index": index,
                                              "content_block": {"type": "text", "text": ""}})
                event("content_block_delta", {"type": "content_block_delta", "index": index,
                                              "delta": {"type": "text_delta", "text": block["text"]}})
            event("content_block_stop", {"type": "content_block_stop", "index": index})
        event("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None},
                                "usage": {"output_tokens": 1}})
        event("message_stop", {"type": "message_stop"})
        self.wfile.flush()
        self.close_connection = True


def main():
    server = ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1]) if len(sys.argv) > 1 else 0), Handler)
    print(f"listening {server.server_address[1]}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
