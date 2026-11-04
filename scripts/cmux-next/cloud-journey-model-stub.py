# The Cloud journey's model stub (cloud-journey.ts --model stub): a stand-in Anthropic Messages endpoint that runs
# on the Cloud machine, so a journey needs no real Claude login. Every /v1/messages answers one fixed, streamed reply
# naming NONCE. With STUB_TOOL=1 the first turn asks for one Bash tool call (echo NONCE-tool) and the reply comes
# after its result. It logs each request's path, the SHA-256 of the credential it got (never the value) and whether
# the tool's result came back with NONCE-tool in it.
#   python3 cloud-journey-model-stub.py NONCE PORT LOGFILE
import hashlib, json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
NONCE, PORT, LOG = sys.argv[1], int(sys.argv[2]), sys.argv[3]
TOOL = os.environ.get("STUB_TOOL") == "1"
def log(rec):
    with open(LOG, "a") as f: f.write(json.dumps(rec) + "\n")
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _json(self, code, body):
        b = json.dumps(body).encode(); self.send_response(code)
        self.send_header("content-type", "application/json"); self.send_header("content-length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self): log({"m": "GET", "p": self.path}); self._json(200, {"data": [], "has_more": False})
    def do_HEAD(self): self.send_response(200); self.end_headers()
    def do_POST(self):
        n = int(self.headers.get("content-length") or 0); raw = self.rfile.read(n) if n else b""
        try: body = json.loads(raw or b"{}")
        except Exception: body = {}
        cred = (self.headers.get("authorization") or "").removeprefix("Bearer ") or self.headers.get("x-api-key") or ""
        msgs = body.get("messages") or []
        results = [c for m in msgs if isinstance(m.get("content"), list) for c in m["content"] if isinstance(c, dict) and c.get("type") == "tool_result"]
        tool_ok = f"{NONCE}-tool" in json.dumps(results)  # the command's own output, not the tool_use that asked for it
        has_tool_result = any(isinstance(m.get("content"), list) and any(isinstance(c, dict) and c.get("type") == "tool_result" for c in m["content"]) for m in msgs)
        tools = [t.get("name") for t in body.get("tools") or [] if isinstance(t, dict)]
        log({"m": "POST", "p": self.path, "stream": bool(body.get("stream")), "model": body.get("model"), "cred_sha256": hashlib.sha256(cred.encode()).hexdigest() if cred else "", "tools": len(tools), "has_bash": "Bash" in tools, "tool_result": has_tool_result, "tool_ok": tool_ok})
        if not self.path.split("?")[0].endswith("/v1/messages"):
            if "count_tokens" in self.path: return self._json(200, {"input_tokens": 10})
            return self._json(200, {})
        model = body.get("model") or "claude-stub"
        want_tool = TOOL and "Bash" in tools and not has_tool_result and len(msgs) <= 2
        if want_tool:
            content = [{"type": "tool_use", "id": "toolu_stub01", "name": "Bash", "input": {"command": f"echo {NONCE}-tool", "description": "stub tool call"}}]
            stop = "tool_use"
        else:
            content = [{"type": "text", "text": f"Stub reply {NONCE}."}]
            stop = "end_turn"
        if not body.get("stream"):
            return self._json(200, {"id": "msg_stub", "type": "message", "role": "assistant", "model": model, "content": content, "stop_reason": stop, "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 5}})
        self.send_response(200); self.send_header("content-type", "text/event-stream"); self.send_header("cache-control", "no-cache"); self.end_headers()
        def ev(t, d): self.wfile.write(f"event: {t}\ndata: {json.dumps(d)}\n\n".encode()); self.wfile.flush()
        ev("message_start", {"type": "message_start", "message": {"id": "msg_stub", "type": "message", "role": "assistant", "model": model, "content": [], "stop_reason": None, "stop_sequence": None, "usage": {"input_tokens": 10, "output_tokens": 1}}})
        for i, c in enumerate(content):
            if c["type"] == "text":
                ev("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "text", "text": ""}})
                ev("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "text_delta", "text": c["text"]}})
            else:
                ev("content_block_start", {"type": "content_block_start", "index": i, "content_block": {"type": "tool_use", "id": c["id"], "name": c["name"], "input": {}}})
                ev("content_block_delta", {"type": "content_block_delta", "index": i, "delta": {"type": "input_json_delta", "partial_json": json.dumps(c["input"])}})
            ev("content_block_stop", {"type": "content_block_stop", "index": i})
        ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 5}})
        ev("message_stop", {"type": "message_stop"})
ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
