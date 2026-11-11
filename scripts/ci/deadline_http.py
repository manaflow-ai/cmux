#!/usr/bin/env python3
"""One HTTP call that ends by a deadline, as a whole, on the caller's thread.

urllib's urlopen(timeout=T) bounds each socket wait, not the call: a server that sends a byte every few
seconds holds it as long as it likes (Codex review of #40530: a 204 after 0.293 s with a 0.1 s timeout).
Running urlopen on a thread joined with a bound (#40574) ends the wait but not the call: the abandoned
thread can still finish its name lookup and send a POST after the caller timed out, so the next kick
dispatched the Mac work twice (Codex review of #40574, F1), and join(bound) restarted the clock after the
thread started, so a call could succeed past its bound (F2).

request() takes one monotonic deadline before anything else, and every step reads the time left from it:
the name lookup is checked against it, the connect, the TLS handshake, each send and each receive wait at
most what is left, and a send never starts once nothing is left. So nothing is written after the
deadline, and an answer that ends after it is a RequestTimeout, never a success.

stream() is the same call for a body too big to hold in memory (an artifact, a DMG): it yields the answer's
status and headers before the body, and each read of the body waits at most what is left of the same
deadline. A download that used urlopen(timeout=T) as a stall bound passes stall=T as well: then each wait
also ends after T seconds of silence (Stalled, a RequestTimeout), so a dead range is retried as before
while the whole call still ends by the deadline.

getaddrinfo takes no timeout, so the name lookup runs on a daemon thread the caller waits on for the time
left; past it the call raises RequestTimeout (Codex review of #40631, F2: a 663 ms lookup against a 100 ms
deadline). That thread is safe to abandon, unlike #40574's request thread: a lookup sends nothing, so all
it can leave behind is an address no one reads.

Bytes already buffered can finish an answer with no further receive, so the deadline is checked once
more before any answer is returned (Codex review of #40631, F1: a buffered 204 read after a pause
succeeded at 1.28 s against a 1 s deadline), and by stream() before its status and headers and after each
read of the body.

tests/test_ci_no_bare_urlopen.py fails on any other urlopen call in scripts/ci outside the legacy list
there; every new caller comes through here.
"""

from __future__ import annotations

import contextlib
import functools
import http.client
import io
import select
import socket
import ssl
import threading
import time
import urllib.error
import urllib.request
from typing import Callable, Iterator


# A socket wait that ran out. Before Python 3.10 (the builder Macs' /usr/bin/python3 can be 3.9) socket.timeout is
# an OSError of its own, not a TimeoutError; from 3.10 it is TimeoutError.
_SOCKET_TIMEOUT = (TimeoutError, socket.timeout)


class RequestTimeout(TimeoutError):
    """A call that did not finish by its deadline. It ran on the caller's thread and stopped at the
    deadline: nothing was sent after it. A write sent before it (a dispatch, a cancel) may have reached
    the server, so the caller treats it as unknown, never as done and never as refused."""


class Stalled(RequestTimeout):
    """A stream() call whose server sent nothing for its STALL seconds, before the deadline."""


class AnswerTooLarge(ValueError):
    """An answer whose body ran past the caller's max_bytes."""


class Deadline:
    """A deadline on the monotonic clock, taken once."""

    def __init__(self, seconds: float, clock: Callable[[], float] = time.monotonic):
        self.clock = clock
        self.at = clock() + seconds
        self.seconds = seconds

    def left(self, what: str) -> float:
        """The time left, or RequestTimeout naming WHAT when none is."""
        left = self.at - self.clock()
        if left <= 0:
            raise RequestTimeout(f"{what}: past the {self.seconds:g} s deadline")
        return left


def _wait(deadline: Deadline, stall: float | None, what: str) -> tuple[float, bool]:
    """(seconds one socket wait may block, whether STALL bounds it): what is left of DEADLINE, or STALL when
    that is shorter. RequestTimeout naming WHAT when nothing is left."""
    left = deadline.left(what)
    if stall is not None and stall < left:
        return stall, True
    return left, False


def _timed_out(what: str, deadline: Deadline, stall: float | None, stalled: bool) -> RequestTimeout:
    if stalled:
        return Stalled(f"{what}: nothing for {stall:g} s")
    return RequestTimeout(f"{what}: past the {deadline.seconds:g} s deadline")


def _resolve(host: str, port: int, deadline: Deadline) -> list:
    """socket.getaddrinfo for HOST, waited on for the time left on DEADLINE (see the module docstring)."""
    deadline.left(f"resolving {host}")  # no lookup starts once nothing is left
    found: dict[str, object] = {}

    def lookup() -> None:
        try:
            # Read at call time, so a test can slow the lookup down.
            found["infos"] = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)
        except BaseException as error:  # noqa: BLE001 - handed to the caller below
            found["error"] = error

    thread = threading.Thread(target=lookup, name="deadline-http-resolve", daemon=True)
    thread.start()
    # The time left is read here, at the wait: a thread that was slow to start has spent part of it.
    thread.join(max(deadline.at - deadline.clock(), 0))
    if thread.is_alive():
        raise RequestTimeout(f"resolving {host}: past the {deadline.seconds:g} s deadline")
    if "error" in found:
        raise found["error"]
    return found["infos"]


def _connect(address: tuple[str, int], deadline: Deadline, source_address=None,
             stall: float | None = None) -> socket.socket:
    """socket.create_connection, with the lookup checked against DEADLINE and each connect bounded by it
    (and by STALL)."""
    host, port = address
    infos = _resolve(host, port, deadline)
    error: OSError | None = None
    for family, kind, proto, _, sockaddr in infos:
        sock = socket.socket(family, kind, proto)
        stalled = False
        try:
            if source_address:
                sock.bind(source_address)
            # The time left is read at the connect, after the socket's setup.
            wait, stalled = _wait(deadline, stall, f"connecting to {host}")
            sock.settimeout(wait)
            sock.connect(sockaddr)
            return sock
        except RequestTimeout:
            sock.close()
            raise
        except _SOCKET_TIMEOUT:
            sock.close()
            raise _timed_out(f"connecting to {host}", deadline, stall, stalled) from None
        except OSError as failed:
            sock.close()
            error = failed
    raise error or OSError(f"getaddrinfo returned nothing for {host}")


class _DeadlineReader(socket.SocketIO):
    """The socket's read side for the response: each receive waits at most the time left (and STALL)."""

    def __init__(self, sock: socket.socket, deadline: Deadline, stall: float | None = None):
        super().__init__(sock, "rb")
        self._deadline, self._stall = deadline, stall

    def readinto(self, buffer) -> int:
        wait, stalled = _wait(self._deadline, self._stall, "reading the answer")
        self._sock.settimeout(wait)
        try:
            return super().readinto(buffer)
        except _SOCKET_TIMEOUT:
            raise _timed_out("reading the answer", self._deadline, self._stall, stalled) from None


class _SockView:
    """What HTTPResponse sees of the socket: makefile() gives it the deadline reader."""

    def __init__(self, sock: socket.socket, deadline: Deadline, stall: float | None = None):
        self._sock, self._deadline, self._stall = sock, deadline, stall

    def makefile(self, mode: str = "rb", *args, **kwargs):
        # As socket.makefile does: the reader holds the socket open until it closes, so urllib closing
        # the connection after the headers does not cut the body off.
        self._sock._io_refs += 1
        return io.BufferedReader(_DeadlineReader(self._sock, self._deadline, self._stall))


class _DeadlineMixin:
    _deadline: Deadline
    _stall: float | None

    def _bind_deadline(self, deadline: Deadline, stall: float | None = None) -> None:
        self._deadline, self._stall = deadline, stall
        self._create_connection = lambda address, _timeout=None, source=None: _connect(address, deadline, source,
                                                                                       stall)
        self.response_class = lambda sock, *args, **kwargs: http.client.HTTPResponse(
            _SockView(sock, deadline, stall), *args, **kwargs)

    def send(self, data) -> None:
        if self.sock is None:
            self.connect()
        # Never start a write past the deadline: a timed-out call sends nothing after it.
        wait, stalled = _wait(self._deadline, self._stall, "sending the request")
        self.sock.settimeout(wait)
        try:
            super().send(data)
        except _SOCKET_TIMEOUT:
            raise _timed_out("sending the request", self._deadline, self._stall, stalled) from None


class DeadlineHTTPConnection(_DeadlineMixin, http.client.HTTPConnection):
    def __init__(self, host, *, deadline: Deadline, stall: float | None = None, **kwargs):
        super().__init__(host, **kwargs)
        self._bind_deadline(deadline, stall)


class DeadlineHTTPSConnection(_DeadlineMixin, http.client.HTTPSConnection):
    def __init__(self, host, *, deadline: Deadline, stall: float | None = None, **kwargs):
        super().__init__(host, **kwargs)
        self._bind_deadline(deadline, stall)

    def connect(self) -> None:
        http.client.HTTPConnection.connect(self)
        server_hostname = self._tunnel_host or self.host
        sock = self._context.wrap_socket(self.sock, server_hostname=server_hostname,
                                         do_handshake_on_connect=False)
        # The handshake, step by step, so a server that trickles it is cut at the deadline too.
        sock.setblocking(False)
        while True:
            try:
                sock.do_handshake()
                break
            except ssl.SSLWantReadError:
                wanted = ([sock], [])
            except ssl.SSLWantWriteError:
                wanted = ([], [sock])
            wait, stalled = _wait(self._deadline, self._stall, f"TLS with {server_hostname}")
            if not any(select.select(*wanted, [], wait)):
                sock.close()
                raise _timed_out(f"TLS with {server_hostname}", self._deadline, self._stall, stalled)
        sock.setblocking(True)
        self.sock = sock


class _HTTPHandler(urllib.request.HTTPHandler):
    def __init__(self, deadline: Deadline, stall: float | None = None):
        super().__init__()
        self._deadline, self._stall = deadline, stall

    def http_open(self, req):
        return self.do_open(functools.partial(DeadlineHTTPConnection, deadline=self._deadline, stall=self._stall),
                            req)


class _HTTPSHandler(urllib.request.HTTPSHandler):
    def __init__(self, deadline: Deadline, stall: float | None = None):
        super().__init__()
        self._deadline, self._stall = deadline, stall

    def https_open(self, req):
        return self.do_open(functools.partial(DeadlineHTTPSConnection, deadline=self._deadline, stall=self._stall),
                            req, context=self._context)


class Headers(dict):
    """An answer's headers, keyed lowercase; get() and `in` take any case."""

    def get(self, key, default=None):
        return super().get(key.lower(), default)

    def __getitem__(self, key):
        return super().__getitem__(key.lower())

    def __contains__(self, key):
        return super().__contains__(key.lower())


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None


def _start(req: urllib.request.Request | str, seconds: float | None,
           deadline: Deadline | None) -> tuple[urllib.request.Request, Deadline]:
    if deadline is None:
        if seconds is None:
            raise TypeError("request() needs seconds or a deadline")
        deadline = Deadline(seconds)
    if isinstance(req, str):
        req = urllib.request.Request(req)
    return req, deadline


def _open(req: urllib.request.Request, deadline: Deadline, follow_redirects: bool, stall: float | None = None):
    """The answer of one call, its body unread: urllib's response, or its HTTPError for an error status."""
    handlers = [_HTTPHandler(deadline, stall), _HTTPSHandler(deadline, stall)]
    if not follow_redirects:
        handlers.append(_NoRedirect())
    opener = urllib.request.build_opener(*handlers)
    try:
        try:
            # urllib's own timeout is unused: the connection reads the time left from DEADLINE.
            return opener.open(req, timeout=max(deadline.at - deadline.clock(), 0.001))
        except urllib.error.HTTPError as error:
            return error
    except urllib.error.URLError as error:
        # urllib wraps an error of the request's send in URLError; a timeout stays a RequestTimeout.
        if isinstance(error.reason, RequestTimeout):
            raise error.reason from None
        raise


def _http_error(req: urllib.request.Request, status: int, response, raw, body: bytes) -> urllib.error.HTTPError:
    return urllib.error.HTTPError(req.full_url, status, getattr(response, "reason", "") or "", raw, io.BytesIO(body))


def _headers(raw) -> Headers:
    return Headers({k.lower(): v for k, v in (raw or {}).items()})


def request(req: urllib.request.Request | str, seconds: float | None = None, *, deadline: Deadline | None = None,
            follow_redirects: bool = True, max_bytes: int | None = None,
            raise_errors: bool = False) -> tuple[int, bytes, Headers]:
    """One HTTP call that ends within SECONDS (or by DEADLINE, the caller's own, shared by several calls):
    (status, body, headers), or RequestTimeout. An HTTP error status is an answer, returned like a success,
    or with raise_errors raised as urllib's HTTPError (its body read, its headers as urllib has them).
    With follow_redirects=False a redirect is an answer too (its Location in the headers). A redirect that
    is followed drops headers added with add_unredirected_header, so a token stays on its host. A body over
    MAX_BYTES raises ValueError."""
    req, deadline = _start(req, seconds, deadline)
    with _open(req, deadline, follow_redirects) as response:
        if max_bytes is None:
            body = response.read()
        else:
            body = response.read(max_bytes + 1)
            if len(body) > max_bytes:
                raise AnswerTooLarge(f"{req.get_method()} {req.full_url}: answered over {max_bytes} bytes")
        status = response.status
        raw = response.headers
    # The answer may have finished from bytes already buffered, with no receive left to check the time.
    deadline.left("reading the answer")
    if raise_errors and status >= 400:
        raise _http_error(req, status, response, raw, body)
    return status, body, _headers(raw)


class Stream:
    """An answer whose body is read as it comes: status and headers at once, then read(n), each wait of
    which ends by the call's deadline (and its stall)."""

    def __init__(self, response, deadline: Deadline):
        self._response, self._deadline = response, deadline
        self.status: int = response.status
        self.reason: str = getattr(response, "reason", "") or ""
        self.headers = _headers(response.headers)

    def read(self, size: int | None = -1) -> bytes:
        data = self._response.read() if size is None or size < 0 else self._response.read(size)
        # A read served from bytes already buffered waits on no receive: past the deadline it is no answer.
        self._deadline.left("reading the answer")
        return data


@contextlib.contextmanager
def stream(req: urllib.request.Request | str, seconds: float | None = None, *, deadline: Deadline | None = None,
           stall: float | None = None, follow_redirects: bool = True,
           raise_errors: bool = False) -> Iterator[Stream]:
    """request() for a body too big to hold: `with stream(req, seconds) as answer:` gives answer.status and
    answer.headers before the body, and answer.read(n) reads it as it comes. Every wait of the call, the
    body's reads too, ends by the one deadline (SECONDS, or DEADLINE shared with other calls): a body still
    coming at the deadline raises RequestTimeout from read(). With STALL, each wait also ends after STALL
    seconds of silence (Stalled). With raise_errors an error status raises urllib's HTTPError, its body
    read, as request() does; otherwise it is an answer like any other."""
    req, deadline = _start(req, seconds, deadline)
    with _open(req, deadline, follow_redirects, stall) as response:
        if raise_errors and response.status >= 400:
            body = response.read()
            deadline.left("reading the answer")
            raise _http_error(req, response.status, response, response.headers, body)
        # The status and headers may have come from bytes already buffered, as in request().
        deadline.left("reading the answer")
        yield Stream(response, deadline)
