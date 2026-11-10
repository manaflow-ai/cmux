#!/usr/bin/env python3
"""deadline_http against urllib's urlopen: one table of server behaviors, run through both.

deadline_http replaces urlopen in scripts/ci, so a caller written against urlopen's outcomes (HTTPError for an
error status, URLError for a connect that failed, the next resolved address after one that failed) must get
the same outcome from it. Two regressions got past its own tests because nothing compared the two (Codex review
of #40714): a 503 with a truncated body raised IncompleteRead, not HTTPError, so github_release_download skipped
its fallback (F1), and a connect that stalled on the first resolved address raised at once, where
socket.create_connection tries the next one (F2).

Each row is a local server behavior. Each runs through urlopen and through deadline_http.request and stream,
with and without raise_errors, and each outcome is compared as a class: the status, the body (or the partial
body), and the exception type urlopen raises (HTTPError, URLError, IncompleteRead, a reset). The only allowed
difference is the bound: a row marked bounded ends in RequestTimeout within deadline_http's bound, where urlopen
ran past it, and says whether the request was sent (Codex review of #40718, F1: a POST whose answer timed out
may have been applied, so only sent=False is safe to retry).

Run: python3 tests/test_deadline_http_conformance.py
"""

from __future__ import annotations

import dataclasses
import http.client
import os
import socket
import struct
import sys
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts" / "ci"))

import deadline_http as dh  # noqa: E402

HOST = "conformance.test"  # resolved only by the patched getaddrinfo below
STALL = 0.5  # urlopen's timeout, and stream()'s stall: each socket wait
BOUND = 5.0  # deadline_http's whole-call bound, unless a row sets its own
SLACK = 0.75  # how far past its bound a bounded call may end (thread and scheduler noise)
MODES = ("request", "request raise_errors", "stream", "stream raise_errors")


class Server:
    """A raw HTTP server on 127.0.0.1 whose answer per path is scripted below. It counts the requests that
    reached it per path, so a test can tell whether a call sent anything."""

    def __init__(self) -> None:
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(64)
        self.sock.settimeout(0.1)
        self.port = self.sock.getsockname()[1]
        self.hits: dict[str, int] = {}
        self.lock = threading.Lock()
        self.stopping = False
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def hits_on(self, path: str) -> int:
        with self.lock:
            return self.hits.get(path, 0)

    def close(self) -> None:
        self.stopping = True
        self.thread.join(2)
        self.sock.close()

    def _serve(self) -> None:
        while not self.stopping:
            try:
                conn, _ = self.sock.accept()
            except (socket.timeout, OSError):
                continue
            threading.Thread(target=self._handle, args=(conn,), daemon=True).start()

    def _handle(self, conn: socket.socket) -> None:
        conn.settimeout(5)
        try:
            data = b""
            while b"\r\n\r\n" not in data:
                chunk = conn.recv(4096)
                if not chunk:
                    return
                data += chunk
            head, _, body = data.partition(b"\r\n\r\n")
            lines = head.decode("iso-8859-1").split("\r\n")
            path = lines[0].split(" ")[1]
            length = 0
            for line in lines[1:]:
                name, _, value = line.partition(":")
                if name.strip().lower() == "content-length":
                    length = int(value.strip())
            while len(body) < length:
                chunk = conn.recv(4096)
                if not chunk:
                    break
                body += chunk
            with self.lock:
                self.hits[path] = self.hits.get(path, 0) + 1
            self._answer(path, conn)
        except OSError:
            pass
        finally:
            with _quiet():
                conn.close()

    @staticmethod
    def _answer(path: str, conn: socket.socket) -> None:
        def whole(status: str, body: bytes, extra: str = "") -> bytes:
            return (f"HTTP/1.1 {status}\r\nContent-Length: {len(body)}\r\nConnection: close\r\n{extra}\r\n"
                    .encode() + body)

        def reset() -> None:
            conn.setsockopt(socket.SOL_SOCKET, socket.SO_LINGER, struct.pack("ii", 1, 0))

        if path == "/ok":
            conn.sendall(whole("200 OK", b"ok body"))
        elif path == "/final":
            conn.sendall(whole("200 OK", b"final body"))
        elif path == "/truncated-503":
            conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 100\r\nConnection: close\r\n\r\n"
                         b"partial 503 body")
        elif path == "/truncated-200":
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\npartial 200 body")
        elif path == "/reset-503-body":
            conn.sendall(b"HTTP/1.1 503 Service Unavailable\r\nContent-Length: 100\r\nConnection: close\r\n\r\n"
                         b"partial")
            time.sleep(0.3)  # the headers are read before the reset
            reset()
        elif path == "/redirect-301":
            conn.sendall(whole("301 Moved Permanently", b"moved", "Location: /final\r\n"))
        elif path == "/redirect-302":
            conn.sendall(whole("302 Found", b"moved", "Location: /final\r\n"))
        elif path == "/missing-404":
            conn.sendall(whole("404 Not Found", b"no such thing"))
        elif path == "/chunked":
            conn.sendall(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
                         b"6\r\nhello \r\n5\r\nworld\r\n0\r\n\r\n")
        elif path == "/reset-mid-headers":
            conn.sendall(b"HTTP/1.1 200 OK\r\nContent-")
            time.sleep(0.1)
            reset()
        elif path == "/slow-answer":
            time.sleep(BOUND)  # the request arrived; the answer comes after every bound in the row
            with _quiet():
                conn.sendall(whole("201 Created", b"created"))
        else:
            conn.sendall(whole("500 Internal Server Error", b"unscripted path " + path.encode()))


class _quiet:
    def __enter__(self):
        return self

    def __exit__(self, kind, *_):
        return kind is not None and issubclass(kind, OSError)


class Blackhole:
    """A 127.0.0.1 port whose connects hang: a listener with a full accept queue drops new SYNs, so a connect
    waits for its timeout. Nothing connects, so nothing can be sent there."""

    def __init__(self) -> None:
        self.sock = socket.socket()
        self.sock.bind(("127.0.0.1", 0))
        self.sock.listen(0)
        self.port = self.sock.getsockname()[1]
        self.fillers: list[socket.socket] = []
        for _ in range(64):
            filler = socket.socket()
            filler.settimeout(0.3)
            try:
                filler.connect(("127.0.0.1", self.port))
            except socket.timeout:
                filler.close()
                return  # the queue is full: this connect hung, as every later one will
            self.fillers.append(filler)
        self.close()
        raise AssertionError("could not fill a listener's accept queue: this host does not blackhole connects")

    def close(self) -> None:
        for filler in self.fillers:
            filler.close()
        self.sock.close()


def _unused_port() -> int:
    probe = socket.socket()
    probe.bind(("127.0.0.1", 0))
    port = probe.getsockname()[1]
    probe.close()
    return port


@dataclasses.dataclass(frozen=True)
class Row:
    name: str
    path: str
    first: str | None = None  # an address tried before the server's: "refused" or "blackhole"
    only_blackhole: bool = False  # every resolved address hangs
    lookup_delay: float = 0.0
    bound: float = BOUND
    follow: bool = True
    method: str = "GET"
    bounded: tuple[str, ...] = ()  # modes that end in RequestTimeout within the bound, where urlopen ran past it
    sent: bool | None = None  # what a bounded RequestTimeout says of the request
    compare_body: bool = True  # False where a reset makes how much of the body came a race


ROWS = (
    Row("truncated 503 error body", "/truncated-503"),
    Row("503 body cut by a reset", "/reset-503-body", compare_body=False),
    Row("truncated 200 body", "/truncated-200"),
    Row("first address refuses", "/ok", first="refused"),
    Row("first address blackholed", "/ok", first="blackhole", bound=1.5,
        # request() has no stall: its one bound is spent on the first address (urlopen gives each its timeout).
        bounded=("request", "request raise_errors"), sent=False),
    Row("every address blackholed (connect stall)", "/ok", only_blackhole=True, bound=1.5, bounded=MODES, sent=False),
    Row("301 followed", "/redirect-301"),
    Row("302 followed", "/redirect-302"),
    Row("302 not followed", "/redirect-302", follow=False),
    Row("slow lookup within the bound", "/ok", lookup_delay=0.3),
    Row("slow lookup past the bound", "/ok", lookup_delay=1.2, bound=0.4, bounded=MODES, sent=False),
    Row("404 with a body", "/missing-404"),
    Row("chunked body", "/chunked"),
    Row("reset mid-headers", "/reset-mid-headers"),
    Row("POST answered after the bound", "/slow-answer", method="POST", bound=1.0, bounded=MODES, sent=True),
)


@dataclasses.dataclass(frozen=True)
class Outcome:
    raised: str | None  # None: the call returned an answer
    status: int | None = None
    body: bytes | None = None

    def __str__(self) -> str:
        what = self.raised or "answer"
        status = f" {self.status}" if self.status is not None else ""
        body = f" {self.body!r}" if self.body is not None else ""
        return f"{what}{status}{body}"


def _name(error: BaseException) -> str:
    if isinstance(error, dh.RequestTimeout):
        return "RequestTimeout"
    if isinstance(error, urllib.error.HTTPError):
        return "HTTPError"
    if isinstance(error, urllib.error.URLError):
        reason = error.reason
        return f"URLError({_name(reason) if isinstance(reason, BaseException) else type(reason).__name__})"
    if isinstance(error, ConnectionResetError):  # http.client's RemoteDisconnected is one
        return "ConnectionResetError"
    if isinstance(error, http.client.IncompleteRead):
        return "IncompleteRead"
    return type(error).__name__


def _body(read) -> tuple[bytes | None, str | None]:
    """(the body as far as it came, what cut it short or None)."""
    try:
        return read(), None
    except http.client.IncompleteRead as cut:
        return cut.partial, "IncompleteRead"
    except (http.client.HTTPException, OSError) as error:
        return None, _name(error)


@dataclasses.dataclass(frozen=True)
class Reference:
    """urlopen's outcome: OUTCOME, and for an HTTPError what cut its body short (BODY_FAILED)."""

    outcome: Outcome
    body_failed: str | None = None


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _make_request(server: Server, row: Row) -> urllib.request.Request:
    data = b'{"body": "x"}' if row.method == "POST" else None
    return urllib.request.Request(f"http://{HOST}:{server.port}{row.path}", data=data, method=row.method)


def run_urlopen(server: Server, row: Row) -> Reference:
    handlers = [urllib.request.ProxyHandler({})] + ([] if row.follow else [_NoRedirect()])
    opener = urllib.request.build_opener(*handlers)
    try:
        response = opener.open(_make_request(server, row), timeout=STALL)
    except urllib.error.HTTPError as error:
        body, failed = _body(error.read)
        return Reference(Outcome("HTTPError", error.code, body), failed)
    except Exception as error:  # noqa: BLE001 - the outcome under test
        return Reference(Outcome(_name(error)))
    with response:
        body, failed = _body(response.read)
        if failed:
            return Reference(Outcome(failed, None, body))
        return Reference(Outcome(None, response.status, body))


def expected(reference: Reference, mode: str) -> Outcome:
    """What deadline_http in MODE must give for urlopen's REFERENCE. urlopen raises HTTPError for an error
    status (and, with no redirect handler, for a redirect); deadline_http returns both as answers, and raises
    HTTPError only for an error status with raise_errors. stream() without raise_errors hands the body to the
    caller to read, as urlopen's HTTPError does, so a body cut short fails that read the same way."""
    outcome = reference.outcome
    if outcome.raised != "HTTPError":
        return outcome
    if mode.endswith("raise_errors") and outcome.status >= 400:
        return outcome
    if mode == "stream" and reference.body_failed:
        return Outcome(reference.body_failed, None, outcome.body)
    return Outcome(None, outcome.status, outcome.body)


def run_deadline_http(server: Server, row: Row, mode: str) -> tuple[Outcome, BaseException | None]:
    req = _make_request(server, row)
    raise_errors = mode.endswith("raise_errors")
    try:
        if mode.startswith("request"):
            status, body, _ = dh.request(req, row.bound, follow_redirects=row.follow, raise_errors=raise_errors)
            return Outcome(None, status, body), None
        with dh.stream(req, row.bound, stall=STALL, follow_redirects=row.follow, raise_errors=raise_errors) as answer:
            body, failed = _body(answer.read)
            if failed:
                return Outcome(failed, None, body), None
            return Outcome(None, answer.status, body), None
    except urllib.error.HTTPError as error:
        body, _ = _body(error.read)
        return Outcome("HTTPError", error.code, body), error
    except Exception as error:  # noqa: BLE001 - the outcome under test
        return Outcome(_name(error), None, getattr(error, "partial", None)), error


TABLE: list[str] = []


class ConformanceTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        # No proxy from the environment: both clients go straight to the local server.
        cls.env = mock.patch.dict(os.environ, {"no_proxy": "*", "NO_PROXY": "*"})
        cls.env.start()
        for name in ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "all_proxy", "ALL_PROXY"):
            os.environ.pop(name, None)
        cls.server = Server()
        cls.blackhole = Blackhole()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.close()
        cls.blackhole.close()
        cls.env.stop()
        if TABLE:
            print("\nrow | mode | urlopen | deadline_http | verdict", file=sys.stderr)
            print("\n".join(TABLE), file=sys.stderr)

    def _addresses(self, row: Row) -> list[tuple[str, int]]:
        live = ("127.0.0.1", self.server.port)
        hole = ("127.0.0.1", self.blackhole.port)
        if row.only_blackhole:
            return [hole, hole]
        if row.first == "refused":
            return [("127.0.0.1", _unused_port()), live]
        if row.first == "blackhole":
            return [hole, live]
        return [live]

    def _resolving(self, row: Row):
        real = socket.getaddrinfo
        addresses = self._addresses(row)

        def getaddrinfo(host, port, *args, **kwargs):
            if host != HOST:
                return real(host, port, *args, **kwargs)
            time.sleep(row.lookup_delay)
            return [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", address) for address in addresses]

        return mock.patch.object(socket, "getaddrinfo", getaddrinfo)

    def test_the_table(self) -> None:
        for row in ROWS:
            with self._resolving(row):
                reference = run_urlopen(self.server, row)
                for mode in MODES:
                    before = self.server.hits_on(row.path)
                    started = time.monotonic()
                    got, error = run_deadline_http(self.server, row, mode)
                    took = time.monotonic() - started
                    time.sleep(0.05)  # a request in flight reaches the server's count
                    reached = self.server.hits_on(row.path) - before
                    want = expected(reference, mode)
                    with self.subTest(row=row.name, mode=mode):
                        verdict = "FAIL"
                        try:
                            self._check(row, mode, want, got, error, took, reached)
                            verdict = "same" if mode not in row.bounded else "bounded"
                        finally:
                            TABLE.append(f"{row.name} | {mode} | {reference.outcome} | {got}"
                                         + (f" sent={getattr(error, 'sent', 'missing')}"
                                            if isinstance(error, dh.RequestTimeout) else "")
                                         + f" | {verdict}")

    def _check(self, row: Row, mode: str, want: Outcome, got: Outcome, error, took: float, reached: int) -> None:
        if mode in row.bounded:
            self.assertEqual(got.raised, "RequestTimeout", f"want a RequestTimeout within {row.bound} s, got {got}")
            self.assertLessEqual(took, row.bound + SLACK)
            self.assertIs(getattr(error, "sent", None), row.sent, f"RequestTimeout.sent for {row.name}")
            # sent says what the server saw: a POST that reached it, or nothing at all.
            self.assertEqual(reached, 1 if row.sent else 0)
            return
        self.assertEqual(got.raised, want.raised, f"urlopen: {want}; deadline_http: {got}")
        self.assertEqual(got.status, want.status, f"urlopen: {want}; deadline_http: {got}")
        if row.compare_body and want.body is not None:
            self.assertEqual(got.body, want.body, f"urlopen: {want}; deadline_http: {got}")
        if row.first == "blackhole" and got.raised is None:
            self.assertEqual(reached, 1, "the request went once, to the address that answered")


class DeadlineAcrossAddressesTest(unittest.TestCase):
    """The connect loop moves on after a stall, but never past the deadline, and a stall sends nothing."""

    @classmethod
    def setUpClass(cls) -> None:
        cls.blackhole = Blackhole()

    @classmethod
    def tearDownClass(cls) -> None:
        cls.blackhole.close()

    def _connect(self, addresses, seconds: float, stall: float | None):
        infos = [(socket.AF_INET, socket.SOCK_STREAM, socket.IPPROTO_TCP, "", a) for a in addresses]
        with mock.patch.object(socket, "getaddrinfo", lambda *a, **k: infos):
            return dh._connect((HOST, 80), dh.Deadline(seconds), None, stall)

    def test_the_deadline_ends_the_walk(self) -> None:
        hole = ("127.0.0.1", self.blackhole.port)
        started = time.monotonic()
        with self.assertRaises(dh.RequestTimeout) as raised:
            self._connect([hole] * 5, 1.0, 0.4)  # 0.4 + 0.4 + what is left: never five stalls
        self.assertLessEqual(time.monotonic() - started, 1.0 + SLACK)
        self.assertIs(getattr(raised.exception, "sent", None), False)

    def test_each_address_gets_the_time_left(self) -> None:
        hole = ("127.0.0.1", self.blackhole.port)
        started = time.monotonic()
        with self.assertRaises(dh.Stalled) as raised:
            self._connect([hole, hole], 5.0, 0.3)
        took = time.monotonic() - started
        self.assertGreaterEqual(took, 0.55, "the second address got its own stall bound")
        self.assertLess(took, 2.0)
        self.assertIs(getattr(raised.exception, "sent", None), False)


if __name__ == "__main__":
    unittest.main()
