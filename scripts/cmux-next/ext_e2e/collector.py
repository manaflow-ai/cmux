"""Local results collector and test pages for the extension conformance run.

Serves on 127.0.0.1 (and answers localhost, which the pages use as the
cross-origin iframe host). Extensions POST results to /r; the runner reads
them from memory.
"""
import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

PAGE = """<!doctype html>
<meta charset="utf-8">
<title>cxt page</title>
<body style="font: 14px -apple-system, sans-serif; background: #fff; color: #111">
<h1 id="h">cmux conformance page</h1>
<p><a id="link" href="/blank.html?from=link">a link</a> <span id="sel">select me</span></p>
<iframe src="/frame.html?n=same" width="200" height="60"></iframe>
<iframe src="http://localhost:{port}/frame.html?n=cross" width="200" height="60"></iframe>
<script>
const suite = new URLSearchParams(location.search).get("suite") || "page";
function post(api, test, status, detail) {{
  return fetch("/r", {{method: "POST", headers: {{"content-type": "application/json"}},
    body: JSON.stringify({{suite, api, test, status, detail: String(detail).slice(0, 300)}})}});
}}
window.addEventListener("message", async (event) => {{
  if (!event.data || !event.data.cxtWar) return;
  try {{
    const body = await (await fetch(event.data.cxtWar)).text();
    await post("web_accessible_resources", "listed_resource", body.trim() === "cmux war ok" ? "pass" : "fail", body);
  }} catch (error) {{ await post("web_accessible_resources", "listed_resource", "fail", error); }}
  try {{
    const body = await (await fetch(event.data.cxtPrivate)).text();
    await post("web_accessible_resources", "unlisted_resource_denied", "fail", "page read " + body);
  }} catch (error) {{ await post("web_accessible_resources", "unlisted_resource_denied", "pass", error); }}
}});
</script>
"""

FRAME = """<!doctype html><meta charset="utf-8"><title>cxt frame</title><body>frame</body>"""
BLANK = """<!doctype html><meta charset="utf-8"><title>cxt blank</title><body>blank</body>"""


class Collector:
    def __init__(self, run_id, extra_routes=None):
        self.run_id = run_id
        self.results = {}
        self.events = []
        self.lock = threading.Condition()
        self.extra_routes = extra_routes or {}
        collector = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *args):
                pass

            def _send(self, status, body=b"", content_type="text/plain", headers=None):
                if isinstance(body, str):
                    body = body.encode()
                self.send_response(status)
                self.send_header("content-type", content_type)
                self.send_header("access-control-allow-origin", "*")
                self.send_header("access-control-allow-headers", "content-type")
                self.send_header("cache-control", "no-store")
                for key, value in (headers or {}).items():
                    self.send_header(key, value)
                self.send_header("content-length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def do_OPTIONS(self):
                self._send(204)

            def do_POST(self):
                length = int(self.headers.get("content-length") or 0)
                try:
                    payload = json.loads(self.rfile.read(length) or b"{}")
                except ValueError:
                    payload = {}
                collector.record(urlparse(self.path).path, payload)
                self._send(204)

            def do_GET(self):
                url = urlparse(self.path)
                query = parse_qs(url.query)
                path = url.path
                if path in collector.extra_routes:
                    status, body, content_type = collector.extra_routes[path](query)
                    return self._send(status, body, content_type)
                if path == "/page.html":
                    return self._send(200, PAGE.format(port=collector.port), "text/html")
                if path == "/frame.html":
                    return self._send(200, FRAME, "text/html")
                if path in ("/blank.html", "/home.html"):
                    title = "cxt home" if path == "/home.html" else "cxt blank"
                    return self._send(200, BLANK.replace("cxt blank", title), "text/html")
                if path == "/download.bin":
                    return self._send(200, b"cmux" * 4096, "application/octet-stream",
                                      {"content-disposition": "attachment; filename=cxt.bin"})
                if path == "/auth":
                    redirect = (query.get("redirect_uri") or [""])[0]
                    return self._send(302, "", headers={"location": redirect + "?code=cxt"})
                if path == "/dnr/redirect-dst":
                    return self._send(200, "redirect-dst")
                if path.startswith("/dnr/") or path.startswith("/wr-probe") or path.startswith("/mv2-block"):
                    return self._send(200, "not-blocked")
                if path == "/results":
                    return self._send(200, json.dumps(collector.snapshot()), "application/json")
                return self._send(404, "not found")

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        self.url = f"http://127.0.0.1:{self.port}"
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def start(self):
        self.thread.start()
        return self

    def stop(self):
        self.server.shutdown()

    def record(self, path, payload):
        with self.lock:
            payload["at"] = time.time()
            if path == "/r":
                key = (payload.get("suite", "?"), payload.get("api", "?"), payload.get("test", "?"))
                previous = self.results.get(key)
                # A final verdict replaces "pending"; a later pass never hides a fail.
                if previous is None or previous.get("status") == "pending" or payload.get("status") == "fail":
                    self.results[key] = payload
            else:
                self.events.append(dict(payload, kind=path.strip("/")))
            self.lock.notify_all()

    def snapshot(self):
        with self.lock:
            return {"results": [dict(v) for v in self.results.values()], "events": list(self.events)}

    def wait_for(self, predicate, timeout):
        deadline = time.monotonic() + timeout
        with self.lock:
            while not predicate(self):
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return False
                self.lock.wait(remaining)
            return True

    def has_event(self, kind, **fields):
        return any(e.get("kind") == kind and all(e.get(k) == v for k, v in fields.items()) for e in self.events)

    def result(self, suite, api, test):
        with self.lock:
            return self.results.get((suite, api, test))
