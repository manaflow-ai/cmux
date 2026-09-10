#!/usr/bin/env python3
"""A stand-in for the Cloudflare R2 S3 endpoint used by the uploader tests.

Answers PutObject with the same InternalError body R2 returned on 2026-09-06
for the first ``--fail-first`` requests (or every request with
``--always-fail``), then with 200. Writes its port to ``<state-dir>/port`` and
the running PUT count to ``<state-dir>/put-count`` so a shell test can drive
and inspect it without any network access.
"""
from __future__ import annotations

import argparse
import http.server
import pathlib
import threading

INTERNAL_ERROR = (
    b'<?xml version="1.0" encoding="UTF-8"?><Error><Code>InternalError</Code>'
    b"<Message>We encountered an internal error. Please try again.</Message></Error>"
)


def main() -> int:
    parser = argparse.ArgumentParser(description="Fake R2 endpoint for upload-r2-object.py tests.")
    parser.add_argument("--state-dir", required=True, help="Directory for the port and put-count files")
    parser.add_argument("--fail-first", type=int, default=0, help="Answer this many PUTs with HTTP 500 first")
    parser.add_argument("--always-fail", action="store_true", help="Answer every PUT with HTTP 500")
    args = parser.parse_args()

    state = pathlib.Path(args.state_dir)
    state.mkdir(parents=True, exist_ok=True)
    lock = threading.Lock()
    puts = {"count": 0}

    class Handler(http.server.BaseHTTPRequestHandler):
        def log_message(self, *_args: object) -> None:  # keep the test output readable
            pass

        def do_PUT(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            self.rfile.read(length)
            with lock:
                puts["count"] += 1
                count = puts["count"]
                (state / "put-count").write_text(str(count))
            if args.always_fail or count <= args.fail_first:
                self.send_response(500)
                self.send_header("Content-Type", "application/xml")
                self.send_header("Content-Length", str(len(INTERNAL_ERROR)))
                self.end_headers()
                self.wfile.write(INTERNAL_ERROR)
                return
            self.send_response(200)
            self.send_header("ETag", '"fake-etag"')
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_HEAD(self) -> None:
            self.send_response(404)
            self.send_header("Content-Length", "0")
            self.end_headers()

        do_GET = do_HEAD

    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    (state / "port").write_text(str(server.server_address[1]))
    server.serve_forever()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
