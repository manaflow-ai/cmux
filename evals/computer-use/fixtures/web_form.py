# SPDX-License-Identifier: MIT
"""A local web page fixture: serves one form and records each submission.

  python3 web_form.py --port 8765 --state /tmp/web.json

GET / shows the form; POST /submit appends the fields to state["submissions"].
"""

from __future__ import annotations

import argparse
import json
import os
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PAGE = """<!doctype html>
<html><head><meta charset="utf-8"><title>CU Eval Order Form</title>
<style>body{font:16px system-ui;margin:2rem;max-width:32rem}label{display:block;margin:.6rem 0}
input,select{font:inherit;padding:.3rem;width:100%}button{font:inherit;padding:.4rem 1rem}</style>
</head><body>
<h1>Order a sticker pack</h1>
<form method="post" action="/submit">
<label>Full name <input name="full_name" autocomplete="off"></label>
<label>Quantity <input name="quantity" type="number" min="1" max="20" value="1"></label>
<label>Color <select name="color"><option>red</option><option>green</option><option>blue</option></select></label>
<label><input type="checkbox" name="gift" value="yes" style="width:auto"> This is a gift</label>
<button type="submit">Place order</button>
</form></body></html>"""

DONE = """<!doctype html><html><head><meta charset="utf-8"><title>Order placed</title></head>
<body style="font:16px system-ui;margin:2rem"><h1>Order placed</h1></body></html>"""


def make_handler(state_path: str):
    def write(state):
        tmp = state_path + ".tmp"
        with open(tmp, "w") as f:
            json.dump(state, f, indent=1)
        os.replace(tmp, state_path)

    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *_):
            pass

        def _send(self, body: str, code=200):
            data = body.encode()
            self.send_response(code)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):
            if self.path in ("/", "/index.html"):
                self._send(PAGE)
            elif self.path == "/healthz":
                self._send("ok")
            else:
                self._send("not found", 404)

        def do_POST(self):
            if self.path != "/submit":
                return self._send("not found", 404)
            n = int(self.headers.get("Content-Length") or 0)
            fields = dict(urllib.parse.parse_qsl(self.rfile.read(n).decode()))
            with open(state_path) as f:
                state = json.load(f)
            state["submissions"].append(fields)
            write(state)
            self._send(DONE)

    write({"submissions": []})
    return Handler


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, default=8765)
    p.add_argument("--state", required=True)
    a = p.parse_args()
    ThreadingHTTPServer(("127.0.0.1", a.port), make_handler(a.state)).serve_forever()


if __name__ == "__main__":
    main()
