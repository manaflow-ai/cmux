#!/usr/bin/env python3
"""The hermetic web fixture server of an oracle case (p15-oracle-222).

Chromium's browser tests never reach the network: each test starts its own `net::EmbeddedTestServer` on
loopback with an OS-chosen port and serves pages from a checked-in directory, plus a few generated handlers
such as `/slow?N` and `/nocontent` (net/test/embedded_test_server/embedded_test_server.h,
net/test/embedded_test_server/default_handlers.cc). This module does the same for a case with
`fixture.web: true` (schemas/oracle/case-v1.schema.json):

- it binds 127.0.0.1 only, on a port the OS picks for each case, so parallel cases never share a server;
- the case writes the origin as `$WEB` (`expand` puts the real origin in), and normalize.py gets it back with
  `--web ORIGIN` (`normalize_args`), so snapshots and baselines never hold the port;
- every response is byte-stable: no Date or Server header, no port or time in a body, so two runs and two
  ports return the same bytes (`digests`, checked against tests/oracle/fixtures/web/responses.json);
- no page names a non-loopback URL; `remote_urls` is the case schema's own `noRemoteUrl` rule.

Routes (pages link to each other with relative URLs only):

    /                       index.html, links to every page
    /<name>.html            a page of tests/oracle/fixtures/web/ (load, other, beforeunload, popup,
                            popup-target, download, crash); the query is ignored, so popup.html?auto works
    /slow.html?ms=N         the headers come after N ms (default 1000, at most 30000): default_handlers.cc /slow
    /status/404, /status/500 give that status with a fixed page; any unknown path gives the same 404 page
                            with `Response.known` false (the bytes do not differ)
    /download/fixture.bin   64 KiB of fixed bytes, Content-Disposition: attachment
    /long-dom.html?n=N      a page of N list items (default 10000, at most 100000)
    /favicon.ico            204 No Content, as default_handlers.cc /nocontent

    python3 -I scripts/cmux-next/oracle/webfixture.py serve [--port 0] [--origin-file F]   # until SIGTERM
    python3 -I scripts/cmux-next/oracle/webfixture.py check                               # no remote URL
    python3 -I scripts/cmux-next/oracle/webfixture.py digests [--write]                   # byte stability
    python3 -I scripts/cmux-next/oracle/webfixture_test.py                                # unit tests

`serve` is for a case whose browser runs in its own network namespace (hermetic_env.py `netns`): start the
server inside the namespace and read the origin from the origin file. Stdlib only, safe under `python3 -I`.
"""

from __future__ import annotations

import argparse
import functools
import hashlib
import http
import http.server
import json
import os
import re
import signal
import socket
import sys
import threading
import urllib.parse
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

TASK = "p15-oracle-222"
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
FIXTURE_DIR = REPO / "tests" / "oracle" / "fixtures" / "web"
DIGESTS_FILE = FIXTURE_DIR / "responses.json"
CASE_SCHEMA = REPO / "schemas" / "oracle" / "case-v1.schema.json"

HOST = "127.0.0.1"
TOKEN = "$WEB"
_TOKEN_RE = re.compile(re.escape(TOKEN) + r"(?![A-Za-z0-9_])")

DEFAULT_SLOW_MS = 1000
MAX_SLOW_MS = 30000
DEFAULT_LONG_DOM_ITEMS = 10000
MAX_LONG_DOM_ITEMS = 100000
ERROR_STATUSES = (404, 500)
DOWNLOAD_BYTES = bytes(range(256)) * 256
HTML = "text/html; charset=utf-8"

# The request targets `digests` fetches: every route once, and HEAD of a page.
ROUTES: Tuple[Tuple[str, str], ...] = (
    ("GET", "/"),
    ("GET", "/index.html"),
    ("GET", "/load.html"),
    ("HEAD", "/load.html"),
    ("GET", "/other.html"),
    ("GET", "/beforeunload.html"),
    ("GET", "/popup.html"),
    ("GET", "/popup.html?auto"),
    ("GET", "/popup-target.html"),
    ("GET", "/download.html"),
    ("GET", "/download/fixture.bin"),
    ("GET", "/crash.html"),
    ("GET", "/slow.html?ms=0"),
    ("GET", "/slow.html?ms=nope"),
    ("GET", "/status/404"),
    ("GET", "/status/500"),
    ("GET", "/missing.html"),
    ("GET", "/long-dom.html"),
    ("GET", "/long-dom.html?n=3"),
    ("GET", "/favicon.ico"),
)


class FixtureError(Exception):
    """The fixture cannot start, or its pages break a rule."""


@dataclass(frozen=True)
class Response:
    status: int
    body: bytes = b""
    content_type: Optional[str] = HTML
    headers: Tuple[Tuple[str, str], ...] = ()
    delay_ms: int = 0
    # False only for the unknown-path fallback: a 404 or 500 of /status/N is a route the fixture serves.
    known: bool = True


def _page(title: str, body: str) -> bytes:
    return (f'<!doctype html>\n<html lang="en">\n<head><meta charset="utf-8"><title>{title}</title></head>\n'
            f"<body>\n{body}</body>\n</html>\n").encode("utf-8")


def _status_page(status: int, known: bool = True) -> Response:
    phrase = http.HTTPStatus(status).phrase
    return Response(status, _page(phrase, f"<h1>{phrase}</h1>\n<p id=\"status\">{status}</p>\n"), known=known)


def _bounded_int(query: str, key: str, default: int, maximum: int) -> Optional[int]:
    """The integer `key` of the query, `default` when absent, None when it is not an integer in 0...maximum."""
    values = [value for name, value in urllib.parse.parse_qsl(query, keep_blank_values=True) if name == key]
    if not values:
        return default
    if len(values) > 1 or not values[0].isascii() or not values[0].isdigit():
        return None
    number = int(values[0])
    return number if number <= maximum else None


def respond(target: str, root: Path = FIXTURE_DIR) -> Response:
    """The response to a GET of `target` (a request target such as /slow.html?ms=5). Pure: no clock, no port."""
    parts = urllib.parse.urlsplit(target)
    path = urllib.parse.unquote(parts.path) or "/"
    if path == "/":
        path = "/index.html"
    if path == "/slow.html":
        ms = _bounded_int(parts.query, "ms", DEFAULT_SLOW_MS, MAX_SLOW_MS)
        if ms is None:
            return _status_page(400)
        return Response(200, _page("Slow", f'<h1>Slow</h1>\n<p id="status">loaded after {ms} ms</p>\n'), delay_ms=ms)
    if path == "/long-dom.html":
        count = _bounded_int(parts.query, "n", DEFAULT_LONG_DOM_ITEMS, MAX_LONG_DOM_ITEMS)
        if count is None:
            return _status_page(400)
        items = "".join(f'<li id="item-{index}">Item {index}</li>\n' for index in range(count))
        return Response(200, _page(f"Long DOM {count}", f'<h1>Long DOM {count}</h1>\n<ol id="items">\n{items}</ol>\n'))
    if path.startswith("/status/"):
        code = path[len("/status/"):]
        if code in {str(status) for status in ERROR_STATUSES}:
            return _status_page(int(code))
        return _status_page(404, known=False)
    if path == "/download/fixture.bin":
        return Response(200, DOWNLOAD_BYTES, "application/octet-stream",
                        (("Content-Disposition", 'attachment; filename="fixture.bin"'),))
    if path == "/favicon.ico":
        return Response(204, content_type=None)
    name = path[1:]
    if name.endswith(".html") and "/" not in name and "\\" not in name and not name.startswith("."):
        page = root / name
        if page.is_file():
            return Response(200, page.read_bytes())
    return _status_page(404, known=False)


class _Server(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self, port: int, root: Path):
        self.root = root
        self.stopping = threading.Event()
        self.log: List[str] = []
        super().__init__((HOST, port), _Handler)


class _Handler(http.server.BaseHTTPRequestHandler):
    # HTTP/1.0: one request per connection, so stop() never waits on an idle keep-alive connection.
    protocol_version = "HTTP/1.0"
    server: _Server

    def send_response(self, code: int, message: Optional[str] = None) -> None:
        # BaseHTTPRequestHandler adds Server (the Python version) and Date; both would break byte stability.
        self.log_request(code)
        self.send_response_only(code, message)

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A002 - the base class's parameter name
        pass

    def do_GET(self) -> None:
        self._serve(send_body=True)

    def do_HEAD(self) -> None:
        self._serve(send_body=False)

    def _serve(self, send_body: bool) -> None:
        self.server.log.append(f"{self.command} {self.path}")
        response = respond(self.path, self.server.root)
        if response.delay_ms and self.server.stopping.wait(response.delay_ms / 1000):
            return
        self.send_response(response.status)
        if response.content_type:
            self.send_header("Content-Type", response.content_type)
        for name, value in response.headers:
            self.send_header(name, value)
        if response.status != 204:
            self.send_header("Content-Length", str(len(response.body)))
            self.send_header("Cache-Control", "no-store")
        self.end_headers()
        if send_body:
            self.wfile.write(response.body)


class WebFixture:
    """One case's server: `with WebFixture() as web: case = web.expand(case)`."""

    def __init__(self, port: int = 0, root: Path = FIXTURE_DIR):
        self.port_request = port
        self.root = root
        self._server: Optional[_Server] = None
        self._thread: Optional[threading.Thread] = None

    def start(self) -> str:
        if self._server is not None:
            raise FixtureError("the web fixture is already running")
        if not self.root.is_dir():
            raise FixtureError(f"no web fixture directory {self.root}")
        try:
            self._server = _Server(self.port_request, self.root)
        except OSError as error:
            raise FixtureError(f"cannot listen on {HOST}:{self.port_request}: {error}") from None
        self._thread = threading.Thread(target=self._server.serve_forever, name="oracle-webfixture", daemon=True)
        self._thread.start()
        return self.origin

    def stop(self) -> None:
        server, thread = self._server, self._thread
        if server is None:
            return
        server.stopping.set()
        server.shutdown()
        server.server_close()
        if thread is not None:
            thread.join()
        self._server = self._thread = None

    def __enter__(self) -> "WebFixture":
        self.start()
        return self

    def __exit__(self, *exc: Any) -> None:
        self.stop()

    def _running(self) -> _Server:
        if self._server is None:
            raise FixtureError("the web fixture is not running")
        return self._server

    @property
    def port(self) -> int:
        return self._running().server_address[1]

    @property
    def origin(self) -> str:
        return f"http://{HOST}:{self.port}"

    @property
    def requests(self) -> Tuple[str, ...]:
        """`METHOD target` of every request so far, in arrival order."""
        return tuple(self._running().log)

    def expand(self, value: Any) -> Any:
        return expand(value, self.origin)

    def normalize_args(self) -> List[str]:
        """normalize.py's arguments that rewrite this origin back to $WEB."""
        return ["--web", self.origin]


def expand(value: Any, origin: str) -> Any:
    """`value` with every `$WEB` token in its strings replaced by `origin`, at any depth."""
    if isinstance(value, str):
        return _TOKEN_RE.sub(lambda _: origin, value)
    if isinstance(value, dict):
        return {key: expand(item, origin) for key, item in value.items()}
    if isinstance(value, list):
        return [expand(item, origin) for item in value]
    return value


@functools.lru_cache(maxsize=1)
def _remote_url_re() -> "re.Pattern[str]":
    schema = json.loads(CASE_SCHEMA.read_text(encoding="utf-8"))
    return re.compile(schema["$defs"]["noRemoteUrl"]["not"]["pattern"])


def remote_urls(text: str) -> List[str]:
    """The non-loopback URLs in `text`, by the case schema's `noRemoteUrl` rule (one rule for cases and pages)."""
    return [match.group(0).strip() for match in _remote_url_re().finditer(text)]


def check(root: Path = FIXTURE_DIR) -> List[str]:
    """Every rule break of the fixture: a remote URL in a page or a generated response."""
    findings = []
    for page in sorted(root.glob("*.html")):
        for url in remote_urls(page.read_text(encoding="utf-8")):
            shown = page.relative_to(REPO) if page.is_relative_to(REPO) else page
            findings.append(f"{shown}: non-loopback URL {url!r}")
    for _, target in ROUTES:
        response = respond(target, root)
        if response.content_type == HTML:
            for url in remote_urls(response.body.decode("utf-8")):
                findings.append(f"{target}: non-loopback URL {url!r}")
    return findings


def fetch_raw(origin: str, method: str, target: str, timeout: float = 10.0) -> bytes:
    """The whole response to one request, status line and headers included."""
    host_port = urllib.parse.urlsplit(origin).netloc
    host, _, port = host_port.rpartition(":")
    with socket.create_connection((host, int(port)), timeout=timeout) as connection:
        connection.sendall(f"{method} {target} HTTP/1.0\r\nHost: {host_port}\r\n\r\n".encode("ascii"))
        chunks = []
        while True:
            chunk = connection.recv(65536)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)


def digests(web: WebFixture) -> Dict[str, str]:
    """sha256 of the raw response to every route of ROUTES."""
    return {f"{method} {target}": hashlib.sha256(fetch_raw(web.origin, method, target)).hexdigest()
            for method, target in ROUTES}


def _serve(args: argparse.Namespace) -> int:
    # Block the signals before the server thread starts, so it inherits the mask and only sigwait sees them.
    signals = {signal.SIGINT, signal.SIGTERM}
    signal.pthread_sigmask(signal.SIG_BLOCK, signals)
    with WebFixture(args.port) as web:
        if args.origin_file:
            temporary = Path(f"{args.origin_file}.tmp")
            temporary.write_text(web.origin + "\n", encoding="utf-8")
            os.replace(temporary, args.origin_file)
        print(web.origin, flush=True)
        signal.sigwait(signals)
    return 0


def main(argv: Sequence[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    serve = commands.add_parser("serve", help="serve until SIGINT or SIGTERM; print the origin")
    serve.add_argument("--port", type=int, default=0, help="0 (the default) lets the OS pick a free port")
    serve.add_argument("--origin-file", help="write the origin here once the server listens")
    commands.add_parser("check", help="refuse a non-loopback URL in a page or a generated response")
    digest = commands.add_parser("digests", help="print the sha256 of every route's raw response")
    digest.add_argument("--write", action="store_true", help=f"write them to {DIGESTS_FILE.relative_to(REPO)}")
    args = parser.parse_args(argv)
    try:
        if args.command == "serve":
            return _serve(args)
        if args.command == "check":
            findings = check()
            for finding in findings:
                print(finding, file=sys.stderr)
            return 1 if findings else 0
        with WebFixture() as web:
            table = digests(web)
        text = json.dumps(table, indent=2, sort_keys=True) + "\n"
        if args.write:
            DIGESTS_FILE.write_text(text, encoding="utf-8")
        sys.stdout.write(text)
        return 0
    except FixtureError as error:
        print(f"webfixture: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
