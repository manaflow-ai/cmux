#!/usr/bin/env python3
"""Test site for the WebKit duplicate prototype (feed.md section 10).

Binds 127.0.0.1 on a random port, prints the port on the first stdout line,
and serves until killed. Every request is counted per method and path
(GET /stats returns the counts), so the prototype can tell whether a restore
hit the network and whether a POST was sent again.
"""

import json
import sys
import threading
import urllib.parse
from http.cookies import SimpleCookie
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HITS = {}
HITS_LOCK = threading.Lock()


def head(title, cookie_header):
    # The inline head script runs before any other page script. It records
    # what the page sees at that moment: sessionStorage (to prove the
    # document-start seed ran first), the agent shim, and service-worker
    # control.
    return f"""<!doctype html>
<html><head><meta charset="utf-8"><title>{title}</title>
<script>
window.__serverSawCookies = {json.dumps(cookie_header)};
(function () {{
  var o = {{}};
  for (var i = 0; i < sessionStorage.length; i++) {{
    var k = sessionStorage.key(i);
    o[k] = sessionStorage.getItem(k);
  }}
  window.__headSS = JSON.stringify(o);
  window.__headShim = (typeof window.__agentShim === 'undefined') ? null : window.__agentShim;
  window.__headSWController = !!(navigator.serviceWorker && navigator.serviceWorker.controller);
  window.addEventListener('pageshow', function (e) {{ window.__persisted = e.persisted; }});
}})();
</script>
</head>"""


class Handler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        sys.stderr.write("server: " + (fmt % args) + "\n")

    def count(self):
        key = f"{self.command} {urllib.parse.urlparse(self.path).path}"
        with HITS_LOCK:
            HITS[key] = HITS.get(key, 0) + 1
            return HITS[key]

    def cookies(self):
        jar = SimpleCookie()
        jar.load(self.headers.get("Cookie", ""))
        return {k: v.value for k, v in jar.items()}

    def send(self, status, body, ctype="text/html; charset=utf-8", headers=()):
        data = body.encode()
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        for k, v in headers:
            self.send_header(k, v)
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        n = self.count()
        path = urllib.parse.urlparse(self.path).path
        cookie_header = self.headers.get("Cookie", "")
        if path == "/page":
            headers = []
            if "sid" not in self.cookies():
                # The agent's session: HttpOnly, so page scripts cannot read it.
                headers.append(("Set-Cookie", "sid=agent-session; Path=/; HttpOnly; SameSite=Lax"))
                headers.append(("Set-Cookie", "pref=dark; Path=/; SameSite=Lax"))
            body = head("page", cookie_header) + f"""<body>
<p id="hit">GET /page #{n}</p>
<input id="q" name="q" type="text">
<input id="q2" name="q2" type="text">
<form id="loginform" method="POST" action="/login">
  <input name="u" value="user"><input name="p" type="password" value="pw">
</form>
<div style="height:6000px">tall</div>
</body></html>"""
            self.send(200, body, headers=headers)
        elif path == "/home":
            self.send(200, head("home", cookie_header) + f"<body><p>home #{n}</p></body></html>")
        elif path == "/form":
            self.send(200, head("form", cookie_header) + """<body>
<form id="f" method="POST" action="/posted"><input name="x" value="1"></form>
</body></html>""")
        elif path == "/whoami":
            self.send(200, json.dumps({"cookie": cookie_header, "cookies": self.cookies()}),
                      ctype="application/json", headers=[("Cache-Control", "no-store")])
        elif path == "/sw.js":
            self.send(200, """
self.addEventListener('install', e => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('fetch', e => {});
""", ctype="application/javascript")
        elif path == "/stats":
            with HITS_LOCK:
                snapshot = dict(HITS)
            self.send(200, json.dumps(snapshot), ctype="application/json", headers=[("Cache-Control", "no-store")])
        else:
            self.send(404, "not found", ctype="text/plain")

    def do_POST(self):
        n = self.count()
        path = urllib.parse.urlparse(self.path).path
        length = int(self.headers.get("Content-Length", "0"))
        self.rfile.read(length)
        cookie_header = self.headers.get("Cookie", "")
        if path == "/login":
            # The user's sign-in: a new HttpOnly session, then a GET redirect.
            self.send(303, "", headers=[
                ("Location", "/home"),
                ("Set-Cookie", "sid=user-session; Path=/; HttpOnly; SameSite=Lax"),
            ])
        elif path == "/posted":
            # A POST result page with no redirect: the history entry is a POST.
            self.send(200, head("posted", cookie_header)
                      + f"<body><script>window.__postCount = {n};</script><p>POST /posted #{n}</p></body></html>")
        else:
            self.send(404, "not found", ctype="text/plain")


def main():
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
