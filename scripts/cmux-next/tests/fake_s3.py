#!/usr/bin/env python3
"""A local stand-in for the R2 S3 API that publish-cef-r2.sh talks to (tests only).

  fake_s3.py <root dir> <port file>

Serves http://127.0.0.1:<port>/<bucket>/<key>: GET returns the file at <root>/<bucket>/<key>
(404 when absent); PUT stores the body there, or answers 412 when the object exists and the
request says If-None-Match: *. Writes the chosen port to <port file>, then serves until killed.
It checks only that a SigV4 Authorization header is present.
"""
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def _path(self):
        rel = self.path.split("?", 1)[0].lstrip("/")
        if ".." in rel.split("/") or not rel:
            return None
        return ROOT / rel

    def _signed(self):
        if not (self.headers.get("Authorization") or "").startswith("AWS4-HMAC-SHA256"):
            self.send_response(403)
            self.end_headers()
            return False
        return True

    def do_GET(self):
        if not self._signed():
            return
        path = self._path()
        if path is None or not path.is_file():
            self.send_response(404)
            self.end_headers()
            return
        data = path.read_bytes()
        self.send_response(200)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_PUT(self):
        if not self._signed():
            return
        path = self._path()
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length)
        if path is None:
            self.send_response(400)
        elif path.exists() and self.headers.get("If-None-Match") == "*":
            self.send_response(412)
        else:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(body)
            self.send_response(200)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
Path(sys.argv[2]).write_text(str(server.server_address[1]))
server.serve_forever()
