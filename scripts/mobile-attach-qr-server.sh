#!/usr/bin/env bash
# Tiny HTTP server that regenerates the mobile attach QR on every page hit
# so the QR you see is always linked to the currently-running Mac instance.
# Defaults to 127.0.0.1:17321 to match the existing tools/cmux-tag-opener
# pattern. Stop with Ctrl-C.

set -euo pipefail

PORT="${PORT:-17321}"
TAG="${CMUX_TAG:-mobile}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi

export TAG SCRIPT_DIR

exec python3 - "$PORT" <<'PYEOF'
import http.server
import json
import os
import socketserver
import subprocess
import sys
import threading
import time

PORT = int(sys.argv[1])
TAG = os.environ["TAG"]
SCRIPT_DIR = os.environ["SCRIPT_DIR"]
QR_SCRIPT = os.path.join(SCRIPT_DIR, "mobile-attach-qr.sh")
OUT_DIR = f"/tmp/cmux-mobile-attach-qr-{TAG}"

_LOCK = threading.Lock()
_LAST_GEN_TS = 0.0
# Don't shell out more often than this — protects the Mac socket from
# accidental load if a browser hammers refresh.
MIN_REGEN_INTERVAL_SECONDS = 2.0


def regenerate(force: bool = False) -> tuple[bool, str]:
    global _LAST_GEN_TS
    now = time.time()
    with _LOCK:
        if not force and now - _LAST_GEN_TS < MIN_REGEN_INTERVAL_SECONDS:
            return True, "cached"
        env = os.environ.copy()
        env["CMUX_TAG"] = TAG
        try:
            subprocess.run(
                [QR_SCRIPT, "--tag", TAG],
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=True,
                timeout=15,
            )
        except subprocess.CalledProcessError as exc:
            return False, exc.stderr.decode("utf-8", errors="replace")
        except subprocess.TimeoutExpired:
            return False, "regenerate timed out"
        _LAST_GEN_TS = now
        return True, "regenerated"


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:
        # Stay quiet — the cmux helper pane is the visible signal.
        return

    def do_GET(self):
        path = self.path.split("?", 1)[0]
        if path in ("/", "/index.html"):
            self._serve_qr_page()
            return
        if path == "/healthz":
            self._send(200, "text/plain", b"ok")
            return
        if path == "/ticket.json":
            self._serve_ticket_json()
            return
        self._send(404, "text/plain", b"not found")

    def _serve_qr_page(self) -> None:
        ok, msg = regenerate()
        html_path = os.path.join(OUT_DIR, "index.html")
        if not ok or not os.path.exists(html_path):
            body = (
                "<html><body><h1>QR generation failed</h1>"
                f"<pre>{msg}</pre></body></html>"
            ).encode("utf-8")
            self._send(500, "text/html; charset=utf-8", body)
            return
        with open(html_path, "rb") as fh:
            html = fh.read()
        # Inject a meta refresh + a small banner + an "Open cmux DEV <tag>"
        # button that hits the CMUX Tag Opener at 127.0.0.1:17320.
        marker = b"</head>"
        injection = (
            b'<meta http-equiv="refresh" content="45">\n'
            b'<style>'
            b'.qr-fresh-banner{position:fixed;top:8px;right:12px;'
            b'background:#16a34a;color:#fff;padding:4px 10px;border-radius:8px;'
            b'font:600 12px/1.2 -apple-system,system-ui,sans-serif;}'
            b'.qr-open-tag{position:fixed;top:8px;left:12px;display:inline-block;'
            b'background:#1f2937;color:#fff;padding:6px 14px;border-radius:8px;'
            b'font:600 13px/1.2 -apple-system,system-ui,sans-serif;'
            b'text-decoration:none;border:1px solid #374151;}'
            b'.qr-open-tag:hover{background:#111827;}'
            b'.qr-open-tag code{background:rgba(255,255,255,0.12);padding:1px 5px;'
            b'border-radius:4px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;}'
            b'</style>\n'
        )
        if marker in html:
            html = html.replace(marker, injection + marker, 1)
        tag_bytes = TAG.encode("utf-8")
        body_marker = b"<body"
        banner = (
            b'<a class="qr-open-tag" href="http://127.0.0.1:17320/' + tag_bytes
            + b'" target="_blank" rel="noopener">Open <code>cmux DEV '
            + tag_bytes + b'</code></a>'
            + b'<div class="qr-fresh-banner">live, regenerates every 45s</div>'
        )
        if body_marker in html:
            insert_at = html.find(b">", html.find(body_marker)) + 1
            html = html[:insert_at] + banner + html[insert_at:]
        self._send(200, "text/html; charset=utf-8", html)

    def _serve_ticket_json(self) -> None:
        ok, msg = regenerate()
        path = os.path.join(OUT_DIR, "attach-ticket.raw.json")
        if not ok or not os.path.exists(path):
            self._send(500, "application/json", json.dumps({"error": msg}).encode())
            return
        with open(path, "rb") as fh:
            self._send(200, "application/json", fh.read())

    def _send(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)


class ThreadingServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


# Generate once at startup so the first request is instant.
regenerate(force=True)

with ThreadingServer(("127.0.0.1", PORT), Handler) as httpd:
    print(f"mobile QR server: http://127.0.0.1:{PORT}/  (tag={TAG})")
    print(f"  health:  http://127.0.0.1:{PORT}/healthz")
    print(f"  ticket:  http://127.0.0.1:{PORT}/ticket.json")
    print("Ctrl-C to stop.")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        print("\nstopping QR server")
PYEOF
