#!/usr/bin/env python3
"""Tiny live-reload dev server for the tmux + proxied browser demo.

Standard library only. It serves:

  GET  /            the bench page (the browser's viewport, the tmux size, the hop)
  GET  /events      Server-Sent Events: "reload" when a file in --root changes,
                    "size" when the terminal size file changes
  POST /viewport    the page reports innerWidth/innerHeight/devicePixelRatio; the
                    server prints one line per change, so the tmux pane shows
                    the browser size next to its own size
  GET  /hop         JSON: the request's peer address and the headers a proxy
                    adds or strips (Via, Forwarded, Proxy-*), so the page can
                    show whether it came through the workspace proxy
  GET  /healthz     "ok"

The server binds 127.0.0.1 by default: the browser pane must reach it through
the workspace route (plans/cmux-next/workspace-proxy-DESIGN.md), never through
a LAN address.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import threading
import time
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

PAGE = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>cmux proxy demo</title>
<style>
 :root { color-scheme: dark; font: 14px/1.4 ui-monospace, Menlo, monospace; }
 body { margin: 0; background: #0d1117; color: #c9d1d9; }
 main { padding: 16px; }
 h1 { font: 600 16px system-ui; margin: 0 0 12px; }
 .grid { display: grid; grid-template-columns: max-content 1fr; gap: 4px 16px; }
 .k { color: #8b949e; } .ok { color: #3fb950; } .bad { color: #f85149; }
 #edges { position: fixed; inset: 0; pointer-events: none; outline: 2px dashed #388bfd; outline-offset: -2px; }
 #corner { position: fixed; right: 0; bottom: 0; background: #388bfd; color: #fff; padding: 2px 6px; }
</style></head>
<body><div id="edges"></div><main>
<h1>tmux + proxied browser bench</h1>
<div class="grid">
 <span class="k">viewport</span><span id="vp">?</span>
 <span class="k">device px</span><span id="dp">?</span>
 <span class="k">terminal</span><span id="term">?</span>
 <span class="k">route</span><span id="hop">?</span>
 <span class="k">live reload</span><span id="lr">connecting</span>
 <span class="k">served at</span><span id="served">__STARTED__</span>
</div>
<p class="k">The dashed outline is the page's viewport. If it is cut off or leaves a gap
inside the pane, the browser view and the pane disagree about size.</p>
</main><div id="corner">0x0</div>
<script>
const $ = (id) => document.getElementById(id);
let last = "";
function report() {
  const w = innerWidth, h = innerHeight, r = devicePixelRatio;
  const key = w + "x" + h + "@" + r;
  $("vp").textContent = w + " x " + h + " css px";
  $("dp").textContent = Math.round(w * r) + " x " + Math.round(h * r) + " (dpr " + r + ")";
  $("corner").textContent = w + "x" + h;
  if (key === last) return;
  last = key;
  fetch("/viewport", {method: "POST", headers: {"content-type": "application/json"},
    body: JSON.stringify({w, h, dpr: r, outerW: outerWidth, outerH: outerHeight, t: Date.now()})}).catch(() => {});
}
new ResizeObserver(report).observe(document.documentElement);
addEventListener("resize", report);
report();
fetch("/hop").then(r => r.json()).then(j => {
  $("hop").textContent = j.summary;
  $("hop").className = j.proxied ? "ok" : "bad";
});
function connect() {
  const es = new EventSource("/events");
  es.addEventListener("open", () => { $("lr").textContent = "connected"; $("lr").className = "ok"; });
  es.addEventListener("reload", () => location.reload());
  es.addEventListener("size", (e) => { $("term").textContent = e.data; });
  es.addEventListener("error", () => { $("lr").textContent = "reconnecting"; $("lr").className = "bad"; });
}
connect();
</script></body></html>
"""

PROXY_HEADERS = ("via", "forwarded", "x-forwarded-for", "proxy-connection", "proxy-authorization")


class State:
    def __init__(self, root: Path, size_file: Path | None) -> None:
        self.root = root
        self.size_file = size_file
        self.generation = 0
        self.size_text = ""
        self.cond = threading.Condition()
        self.last_viewport: str | None = None
        self.started = time.strftime("%H:%M:%S")

    def bump(self, size_text: str | None = None) -> None:
        with self.cond:
            self.generation += 1
            if size_text is not None:
                self.size_text = size_text
            self.cond.notify_all()


def snapshot(root: Path) -> dict[str, float]:
    out: dict[str, float] = {}
    for path in root.rglob("*"):
        if path.is_file() and not any(part.startswith(".") for part in path.parts):
            try:
                out[str(path)] = path.stat().st_mtime
            except OSError:
                pass
    return out


def watch(state: State, interval: float) -> None:
    files = snapshot(state.root)
    size = read_size(state.size_file)
    if size:
        state.bump(size)
    while True:
        time.sleep(interval)
        now = snapshot(state.root)
        if now != files:
            files = now
            with state.cond:
                state.generation += 1
                state.reload_generation = state.generation  # type: ignore[attr-defined]
                state.cond.notify_all()
        new_size = read_size(state.size_file)
        if new_size and new_size != state.size_text:
            state.bump(new_size)


def read_size(path: Path | None) -> str:
    if path is None:
        return ""
    try:
        return path.read_text().strip()
    except OSError:
        return ""


def owner_in_netstat(text: str, peer: str, peer_port: int) -> str | None:
    """process:pid of the socket whose local address is peer.peer_port in
    macOS `netstat -anv -p tcp` output."""
    import re

    pattern = re.compile(
        r"^tcp\S*\s+\d+\s+\d+\s+(?P<local>\S+)\s+\S+\s+ESTABLISHED\s+\d+\s+\d+\s+\d+\s+\d+\s+"
        r"(?P<proc>.+?):(?P<pid>\d+)\s+[0-9a-f]{5}\s"
    )
    want = f"{peer}.{peer_port}"
    for line in text.splitlines():
        m = pattern.match(line)
        if m and m["local"] == want:
            return f"{m['proc']}:{m['pid']}"
    return None


def peer_owner(peer: str, peer_port: int, server_port: int) -> str | None:
    """name:pid of the process that owns the client end of a loopback
    connection. Through the workspace proxy, the session daemon (`cmux` or
    `cmux-tui`) connects to its own loopback, so it owns the peer socket; a
    direct browser connection is owned by a Chromium network helper. macOS:
    libproc (macsockets.py; netstat prints nothing under Python). Linux:
    /proc (linuxsockets.py)."""
    if not peer.startswith("127.") and peer not in ("::1", "::ffff:127.0.0.1"):
        return None
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    try:
        import linuxsockets
        import macsockets
    except ImportError:
        return None
    if macsockets.available():
        found = macsockets.connection_owner(peer_port, server_port)
    elif linuxsockets.available():
        found = linuxsockets.connection_owner(peer_port, server_port)
    else:
        return None
    return f"{found[1]}:{found[0]}" if found else None


def is_daemon(name: str) -> bool:
    """A cmux session daemon: `cmux` (the app's bundled CLI name) or any
    `cmux-tui*` binary (a pushed build such as cmux-tui-nightly-eeb26d8 on a
    Mac mini). Process names are cut at 16 bytes by the kernel."""
    return name == "cmux" or name.startswith("cmux-tui")


def hop_summary(peer: str, headers: dict[str, str], owner: str | None = None) -> dict[str, object]:
    """Describe how a request reached the server.

    A request from the cmux workspace proxy arrives from 127.0.0.1 (the daemon
    connects to its own loopback) with no proxy headers: the proxy strips them.
    Any proxy header that survives is a leak and is shown. `owner` is the
    process:pid that opened the connection, when known.
    """
    seen = {k: v for k, v in headers.items() if k.lower() in PROXY_HEADERS}
    loopback = peer.startswith("127.") or peer in ("::1", "::ffff:127.0.0.1")
    owner_name = (owner or "").rpartition(":")[0]
    via_daemon = is_daemon(owner_name)
    if seen:
        summary = "proxy headers reached the server: " + ", ".join(sorted(seen))
    elif not loopback:
        summary = f"non-loopback peer {peer}"
    elif owner is None:
        summary = f"loopback peer {peer}, no proxy headers"
    elif via_daemon:
        summary = f"through the workspace proxy: opened by {owner}"
    else:
        summary = f"direct, not proxied: opened by {owner}"
    return {"peer": peer, "loopback": loopback, "leaked": sorted(seen), "summary": summary, "owner": owner,
            "proxied": loopback and not seen and (owner is None or via_daemon)}


def make_handler(state: State):
    class Handler(BaseHTTPRequestHandler):
        server_version = "cmux-proxy-demo/1"
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt: str, *args: object) -> None:
            if self.path.startswith(("/events", "/viewport")):
                return
            sys.stderr.write(f"{time.strftime('%H:%M:%S')} {self.address_string()} {fmt % args}\n")

        def _send(self, status: int, body: bytes, ctype: str) -> None:
            self.send_response(status)
            self.send_header("content-type", ctype)
            self.send_header("content-length", str(len(body)))
            self.send_header("cache-control", "no-store")
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:  # noqa: N802
            if self.path in ("/", "/index.html"):
                index = state.root / "index.html"
                body = index.read_bytes() if index.is_file() else PAGE.replace("__STARTED__", state.started).encode()
                self._send(HTTPStatus.OK, body, "text/html; charset=utf-8")
            elif self.path == "/healthz":
                self._send(HTTPStatus.OK, b"ok", "text/plain")
            elif self.path == "/hop":
                peer, peer_port = self.client_address[0], self.client_address[1]
                info = hop_summary(peer, dict(self.headers.items()), peer_owner(peer, peer_port, self.server.server_address[1]))
                self._send(HTTPStatus.OK, json.dumps(info).encode(), "application/json")
            elif self.path == "/events":
                self._events()
            else:
                self._send(HTTPStatus.NOT_FOUND, b"not found", "text/plain")

        def do_POST(self) -> None:  # noqa: N802
            if self.path != "/viewport":
                self._send(HTTPStatus.NOT_FOUND, b"not found", "text/plain")
                return
            length = min(int(self.headers.get("content-length") or 0), 4096)
            try:
                data = json.loads(self.rfile.read(length) or b"{}")
                line = f"{data['w']}x{data['h']} css @dpr {data['dpr']}"
            except (ValueError, KeyError, TypeError):
                self._send(HTTPStatus.BAD_REQUEST, b"bad viewport", "text/plain")
                return
            if line != state.last_viewport:
                state.last_viewport = line
                sys.stderr.write(f"{time.strftime('%H:%M:%S')} browser viewport {line}\n")
            self._send(HTTPStatus.NO_CONTENT, b"", "text/plain")

        def _events(self) -> None:
            self.send_response(HTTPStatus.OK)
            self.send_header("content-type", "text/event-stream")
            self.send_header("cache-control", "no-store")
            self.end_headers()
            reload_seen = getattr(state, "reload_generation", 0)
            seen = -1
            try:
                while True:
                    with state.cond:
                        if seen == state.generation:
                            state.cond.wait(timeout=15)
                        gen = state.generation
                        size = state.size_text
                        reload_gen = getattr(state, "reload_generation", 0)
                    if gen == seen:
                        self.wfile.write(b": ping\n\n")
                    else:
                        if reload_gen != reload_seen:
                            reload_seen = reload_gen
                            self.wfile.write(b"event: reload\ndata: 1\n\n")
                        if size:
                            self.wfile.write(f"event: size\ndata: {size}\n\n".encode())
                        seen = gen
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                return

    return Handler


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0, help="0 picks a free port")
    parser.add_argument("--root", type=Path, default=Path.cwd())
    parser.add_argument("--size-file", type=Path, default=None,
                        help="file the tmux size monitor writes (shown on the page)")
    parser.add_argument("--port-file", type=Path, default=None, help="write the bound port here")
    parser.add_argument("--poll", type=float, default=0.3)
    args = parser.parse_args(argv)

    state = State(args.root.resolve(), args.size_file)
    httpd = ThreadingHTTPServer((args.host, args.port), make_handler(state))
    httpd.daemon_threads = True
    port = httpd.server_address[1]
    if args.port_file:
        args.port_file.write_text(f"{port}\n")
    threading.Thread(target=watch, args=(state, args.poll), daemon=True).start()
    sys.stderr.write(f"serving {state.root} on http://{args.host}:{port}/ (pid {os.getpid()})\n")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
