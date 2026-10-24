"""perf100 local pages: five deterministic tabs served from 127.0.0.1 (no network).

  static   a long article (text and boxes), nothing runs after load
  timer    the same page plus a 1 s timer that updates one line (a typical idle web app)
  list     a 2,000-row table
  canvas   a canvas drawn once
  form     inputs and buttons

Each page is on its own host name (`pN.localhost`), so site isolation gives each its own
renderer, as distinct real sites would.
"""
from __future__ import annotations

import http.server
import random
import threading

KINDS = ("static", "timer", "list", "canvas", "form")


def _body(kind: str, seed: int) -> str:
    rng = random.Random(seed)
    words = "cmux terminal agent browser pane tab workspace render memory disk idle budget".split()
    para = lambda: " ".join(rng.choice(words) for _ in range(60))  # noqa: E731
    if kind == "static":
        return "".join(f"<div class=card><h3>Section {i}</h3><p>{para()}</p></div>" for i in range(60))
    if kind == "timer":
        return ("<p id=clock>0</p>" + "".join(f"<p>{para()}</p>" for i in range(30)) +
                "<script>let n=0;setInterval(()=>{document.getElementById('clock').textContent=++n},1000)</script>")
    if kind == "list":
        rows = "".join(f"<tr><td>{i}</td><td>{rng.choice(words)}</td><td>{rng.randint(0, 99999)}</td></tr>"
                       for i in range(2000))
        return f"<table>{rows}</table>"
    if kind == "canvas":
        return ("<canvas id=c width=800 height=500></canvas><script>const g=document.getElementById('c')"
                f".getContext('2d');let s={seed};for(let i=0;i<400;i++){{s=(s*1103515245+12345)%2147483648;"
                "g.fillStyle='hsl('+(s%360)+',60%,60%)';g.fillRect(s%780,(s>>8)%480,20,20)}</script>")
    return "".join(f"<label>Field {i} <input name=f{i} value='{rng.choice(words)}'></label><br>" for i in range(40)) + \
        "<button>Save</button>"


def serve(seed: int) -> tuple[list[str], http.server.ThreadingHTTPServer]:
    """Starts the server; returns the five URLs (seeded order) and the server."""

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            host = (self.headers.get("Host") or "p0").split(".")[0]
            index = int("".join(ch for ch in host if ch.isdigit()) or 0) % len(KINDS)
            kind = KINDS[index]
            page = (f"<!doctype html><html><head><meta charset=utf-8><title>perf100 {kind}</title>"
                    "<style>body{font:15px -apple-system,sans-serif;max-width:800px;margin:30px auto}"
                    ".card{border:1px solid #ccc;border-radius:8px;padding:10px;margin:10px 0}</style></head>"
                    f"<body><h1>perf100 {kind}</h1>{_body(kind, seed + index)}</body></html>").encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            self.send_header("Content-Length", str(len(page)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(page)

        def log_message(self, *_args):
            pass

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    port = server.server_address[1]
    order = list(range(len(KINDS)))
    random.Random(seed).shuffle(order)
    return [f"http://p{i}.localhost:{port}/" for i in order], server
