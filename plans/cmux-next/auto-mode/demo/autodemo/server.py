"""The store over HTTP: one JSON route per store call, a bearer token, held requests for
`wait`, `events?wait=` and `assignments`."""

import json
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

from .store import Refused, Store


def make_handler(store, token):
    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            pass

        def setup(self):
            BaseHTTPRequestHandler.setup(self)
            self.t_accept = time.monotonic()
            self.t_lock = self.t_held = 0.0

        def _send(self, status, body, raw=False):
            data = body if raw else json.dumps(body).encode()
            self.send_response(status)
            # Where this request's time went, for a slow call's log line on the other side.
            now = time.monotonic()
            self.send_header("x-auto-ms", "since_accept=%d lock_wait=%d held=%d" % (
                (now - self.t_accept) * 1000, self.t_lock * 1000, self.t_held * 1000))
            self.t_accept = now
            self.send_header("content-type", "application/octet-stream" if raw else "application/json")
            self.send_header("content-length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def _body(self):
            length = int(self.headers.get("content-length") or 0)
            return self.rfile.read(length) if length else b""

        def _json(self):
            raw = self._body()
            try:
                return json.loads(raw) if raw else {}
            except ValueError:
                raise Refused(400, "invalid_request", "the body is not JSON")

        def _route(self, method):
            url = urlparse(self.path)
            parts = [p for p in url.path.split("/") if p]
            query = {k: v[0] for k, v in parse_qs(url.query).items()}
            if parts == ["health"]:
                return self._send(200, {"ok": True})
            given = self.headers.get("authorization") or ""
            if token and given != "Bearer " + token and query.get("token") != token:
                self._body()
                return self._send(401, {"error": {"code": "unauthorized", "message": "wrong token"}})
            try:
                answer = self._call(method, parts, query)
            except Refused as refused:
                return self._send(refused.status, refused.body())
            if isinstance(answer, bytes):
                return self._send(200, answer, raw=True)
            return self._send(200, answer)

        def _call(self, method, parts, query):
            s = store
            # Blobs never touch the chats: no lock.
            if parts[:1] == ["blobs"]:
                if method == "POST" and parts == ["blobs", "missing"]:
                    return s.missing_blobs(self._json().get("shas") or [])
                if method == "PUT" and len(parts) == 2:
                    return s.put_blob(parts[1], self._body())
                if method == "GET" and len(parts) == 2:
                    return s.blob(parts[1])
            body = self._json() if method in ("POST", "PUT") else {}
            asked = time.monotonic()
            with s.cv:
                got = time.monotonic()
                self.t_lock = got - asked
                try:
                    return self._locked(s, method, parts, query, body)
                finally:
                    self.t_held = time.monotonic() - got

        def _locked(self, s, method, parts, query, body):
            if True:
                s.tick()
                if parts == ["status"]:
                    return s.status()
                if parts == ["assignments"]:
                    return s.assignments(query.get("machine") or "", int(query.get("wait_ms") or 0))
                if parts == ["chats"]:
                    return s.create(body) if method == "POST" else s.list()
                if len(parts) >= 2 and parts[0] == "chats":
                    chat, rest = parts[1], parts[2:]
                    if not rest:
                        return s.put(chat, body) if method == "PUT" else s.get(chat)
                    if rest == ["wait"]:
                        return s.wait(chat, int(query.get("after") or 0), int(query.get("timeout_ms") or 20000))
                    if rest == ["lease"]:
                        return s.lease(chat, body)
                    if rest == ["keep"]:
                        return s.keep(chat, body.get("keep"))
                    if rest == ["events"]:
                        if method == "POST":
                            return s.append_events(chat, body)
                        return s.events(chat, int(query.get("after") or 0), int(query.get("wait_ms") or 0))
                    if rest == ["snapshot"]:
                        return s.post_snapshot(chat, body) if method == "POST" else s.snapshot(chat)
                    if rest == ["inbox"]:
                        if method == "POST":
                            return s.post_inbox(chat, body)
                        return s.inbox(chat, int(query.get("after") or 0))
                    if rest == ["inbox", "ack"]:
                        return s.ack_inbox(chat, body)
                    if rest == ["assignment", "ack"]:
                        return s.ack_assignment(chat, body)
            raise Refused(404, "not_found", "no such route")

        def do_GET(self):
            self._route("GET")

        def do_POST(self):
            self._route("POST")

        def do_PUT(self):
            self._route("PUT")

    return Handler


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    request_queue_size = 64


def serve(root, host, port, token, lease_ms, wake_cmd=None):
    """Runs the store. Returns (server, store); the caller calls server.serve_forever()."""
    store = Store(root, lease_ms=lease_ms, wake_cmd=wake_cmd)
    server = Server((host, port), make_handler(store, token))

    def alarm():
        while True:
            time.sleep(0.5)
            with store.cv:
                store.tick()

    threading.Thread(target=alarm, daemon=True).start()
    return server, store
