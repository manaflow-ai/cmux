#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Run a local feedback upload mock server.")
    parser.add_argument("--url-file", required=True, help="Path where the server writes its endpoint URL.")
    parser.add_argument("--requests-file", required=True, help="JSONL file where received requests are recorded.")
    return parser.parse_args()


def make_handler(requests_file: Path) -> type[BaseHTTPRequestHandler]:
    lock = threading.Lock()

    class FeedbackHandler(BaseHTTPRequestHandler):
        def do_POST(self) -> None:  # noqa: N802
            length = int(self.headers.get("Content-Length") or "0")
            body = self.rfile.read(length)
            record = {
                "method": "POST",
                "path": self.path,
                "content_type": self.headers.get("Content-Type") or "",
                "user_agent": self.headers.get("User-Agent") or "",
                "content_length": len(body),
                "body_text": body.decode("utf-8", errors="replace"),
            }
            with lock:
                with requests_file.open("a", encoding="utf-8") as handle:
                    handle.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
            response = json.dumps({"ok": True, "received": len(body)}, separators=(",", ":")).encode("utf-8")
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(response)))
            self.end_headers()
            self.wfile.write(response)

        def log_message(self, format: str, *args: object) -> None:
            return

    return FeedbackHandler


def main() -> int:
    args = parse_args()
    url_file = Path(args.url_file)
    requests_file = Path(args.requests_file)
    requests_file.parent.mkdir(parents=True, exist_ok=True)
    requests_file.write_text("", encoding="utf-8")
    server = ThreadingHTTPServer(("127.0.0.1", 0), make_handler(requests_file))
    host, port = server.server_address
    url_file.write_text(f"http://{host}:{port}/feedback\n", encoding="utf-8")
    server.serve_forever(poll_interval=0.2)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
