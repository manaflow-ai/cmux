#!/usr/bin/env python3
"""Serve flat browser UI-test fixtures from outside the XCTest sandbox."""

from __future__ import annotations

import argparse
import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from socketserver import TCPServer
from urllib.parse import unquote, urlparse


STRICT_CSP = "default-src 'none'; script-src 'nonce-cmux-fixture'; object-src 'none'"


class LoopbackHTTPServer(ThreadingHTTPServer):
    """HTTP server that binds loopback without a reverse-DNS lookup."""

    def server_bind(self) -> None:
        """Bind directly and retain the numeric host and assigned port."""

        # HTTPServer.server_bind() performs a reverse-DNS lookup for server_name.
        # That lookup can hang on hosted macOS runners even though loopback bind
        # already succeeded, so bind directly and keep the numeric host name.
        TCPServer.server_bind(self)
        self.server_name = self.server_address[0]
        self.server_port = self.server_address[1]


def parse_args() -> argparse.Namespace:
    """Parse fixture-server command-line arguments."""

    parser = argparse.ArgumentParser()
    parser.add_argument("fixture_directory", type=Path)
    parser.add_argument("--strict-csp-fixture", required=True)
    parser.add_argument("--port", type=int, default=0)
    parser.add_argument("--configuration-file", type=Path)
    return parser.parse_args()


def make_handler(fixture_root: Path, strict_csp_fixture: str) -> type[BaseHTTPRequestHandler]:
    """Create a request handler restricted to flat files under fixture_root."""

    class FixtureHandler(BaseHTTPRequestHandler):
        """Serve one validated HTML fixture per loopback request."""

        def do_GET(self) -> None:  # noqa: N802 - BaseHTTPRequestHandler API
            """Serve a flat fixture and attach strict CSP to the named page."""

            fixture_name = unquote(urlparse(self.path).path).lstrip("/")
            if not fixture_name or "/" in fixture_name or "\\" in fixture_name:
                self.send_error(404)
                return

            fixture_path = (fixture_root / fixture_name).resolve()
            if fixture_path.parent != fixture_root or not fixture_path.is_file():
                self.send_error(404)
                return

            body = fixture_path.read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", "text/html; charset=utf-8")
            if fixture_name == strict_csp_fixture:
                self.send_header("Content-Security-Policy", STRICT_CSP)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, format: str, *args: object) -> None:  # noqa: A002 - BaseHTTPRequestHandler API
            """Suppress per-request stderr noise in hosted test logs."""

            pass

    return FixtureHandler


def main() -> None:
    """Validate fixtures, start the server, and publish its configuration."""

    args = parse_args()
    fixture_root = args.fixture_directory.resolve()
    if not fixture_root.is_dir():
        raise SystemExit(f"fixture directory does not exist: {fixture_root}")
    strict_csp_path = (fixture_root / args.strict_csp_fixture).resolve()
    if strict_csp_path.parent != fixture_root or not strict_csp_path.is_file():
        raise SystemExit(f"strict-CSP fixture does not exist: {strict_csp_path}")
    if not 0 <= args.port <= 65535:
        raise SystemExit(f"port is outside 0...65535: {args.port}")

    handler = make_handler(fixture_root, args.strict_csp_fixture)
    server = LoopbackHTTPServer(("127.0.0.1", args.port), handler)
    if args.configuration_file is not None:
        configuration = {
            "base_url": f"http://127.0.0.1:{server.server_port}/",
            "strict_csp_fixture": args.strict_csp_fixture,
        }
        args.configuration_file.write_text(json.dumps(configuration) + "\n", encoding="utf-8")
    print(f"READY {server.server_port}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    main()
