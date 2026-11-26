#!/usr/bin/env python3
"""Minimal stdio MCP client for `cua-driver mcp`, for scripted dogfood runs.

    from cua import Cua
    with Cua() as c:
        c.call("list_windows", {})
"""
import json, os, subprocess, sys, time

CUA = os.path.expanduser("~/.local/bin/cua-driver")

class Cua:
    def __init__(self, session="pe-dogfood"):
        self.session = session
        self.p = subprocess.Popen([CUA, "mcp"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.n = 0
        self._rpc("initialize", {"protocolVersion": "2025-06-18", "capabilities": {},
                                 "clientInfo": {"name": "pe-dogfood", "version": "1"}})
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})

    def _send(self, msg):
        self.p.stdin.write(json.dumps(msg) + "\n")
        self.p.stdin.flush()

    def _rpc(self, method, params):
        self.n += 1
        rid = self.n
        self._send({"jsonrpc": "2.0", "id": rid, "method": method, "params": params})
        while True:
            line = self.p.stdout.readline()
            if not line:
                raise RuntimeError("cua-driver exited")
            msg = json.loads(line)
            if msg.get("id") == rid:
                if "error" in msg:
                    raise RuntimeError(f"{method}: {msg['error']}")
                return msg["result"]

    def call(self, name, args):
        res = self._rpc("tools/call", {"name": name, "arguments": args})
        if res.get("isError"):
            raise RuntimeError(f"{name}: {json.dumps(res)[:600]}")
        return res

    def text(self, res):
        return "\n".join(c.get("text", "") for c in res.get("content", []) if c.get("type") == "text")

    def close(self):
        try:
            self.p.stdin.close()
            self.p.wait(timeout=5)
        except Exception:
            self.p.kill()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()

if __name__ == "__main__":
    with Cua() as c:
        name = sys.argv[1]
        args = json.loads(sys.argv[2]) if len(sys.argv) > 2 else {}
        r = c.call(name, args)
        print(c.text(r)[:4000])
        sc = r.get("structuredContent")
        if sc is not None:
            print(json.dumps(sc)[:4000])
