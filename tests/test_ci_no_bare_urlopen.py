#!/usr/bin/env python3
"""No bare urlopen in scripts/ci: an HTTP call goes through scripts/ci/deadline_http.py.

urlopen(timeout=T) bounds each socket wait, not the call (Codex review of #40530), and running it on a
thread joined with a bound lets the abandoned call send its write after the caller timed out (Codex review
of #40574, F1 and F2). deadline_http.request() runs on the caller's thread against one deadline, so nothing
is sent after it and no answer past it succeeds. This file holds the detector for the class and the
transport's own tests.

LEGACY is the urlopen calls that were there when the detector came in, per file. Those scripts set a
per-wait timeout and act on no whole-call deadline; they move to deadline_http one by one, and the list
only shrinks: a file not listed, or a listed file with more calls than its count, fails; a listed file with
fewer calls fails too, until its count is lowered.
"""

from __future__ import annotations

import ast
import socket
import sys
import tempfile
import threading
import time
import unittest
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CI = ROOT / "scripts" / "ci"
sys.path.insert(0, str(CI))

import deadline_http  # noqa: E402

# The one module allowed to open HTTP connections itself (it never calls urlopen either).
TRANSPORT = "deadline_http.py"
LEGACY = {
    "actions_artifact_prune.py": 1,
    "asc_developer_id_app.py": 1,
    "auto_triage.py": 1,
    "base_red_excuse.py": 1,
    "ci_health_report.py": 1,
    "ci_timing_readout.py": 1,
    "cleanup-stale-runs.py": 1,
    "cloud_overflow_switch.py": 1,
    "cmux_binaries_prune.py": 1,
    "cmux_tui_artifacts_retry.py": 1,
    "cmux_tui_superseded_push.py": 1,
    "fast_linux_gate.py": 1,
    "finalize-release.py": 1,
    "guard_attribution.py": 1,
    "hosted_light_rescue.py": 1,
    "hosted_queue_wait.py": 1,
    "ios_internal_builder.py": 1,
    "ios_internal_notes.py": 1,
    "job_reuse.py": 2,
    "manual_dispatch_guard.py": 1,
    "media_app_cache.py": 1,
    "next_macos_cascade.py": 1,
    "nightly_builder.py": 1,
    "nightly_ghostty_helper_reuse.py": 1,
    "nightly_next_artifact_check.py": 1,
    "nightly_next_canary_mode.py": 2,
    "nightly_next_feed_watch.py": 2,
    "nightly_next_launch_smoke.py": 1,
    "nightly_next_live_feed_check.py": 3,
    "nightly_next_ring.py": 1,
    "nightly_next_train.py": 1,
    "nightly_publish_guard.py": 1,
    "nightly_sign_yield.py": 2,
    "nightly_version.py": 1,
    "notify-indexnow.py": 1,
    "owned_pool_rescue.py": 1,
    "poll-notary-submission.py": 1,
    "pr_red_checks_comment.py": 1,
    "pr_status.py": 1,
    "publish-nightly-next-r2.py": 3,
    "queue_janitor.py": 1,
    "r2-canary-cloudflare.py": 1,
    "required_status_checks.py": 1,
    "seed_derived_data.py": 1,
    "simple_pool_picker.py": 1,
    "stable_next.py": 2,
    "stop_if_publish_doomed.py": 1,
    "submodule_forward_only.py": 1,
    "sync_labels.py": 1,
    "test_reds.py": 1,
    "triage-radar.py": 1,
    "update-release-tag.py": 1,
    "warm_model_refit.py": 1,
    "web_test_failure_census.py": 1,
}


def urlopen_calls(path: Path) -> list[int]:
    """The lines of PATH that call urlopen (urllib.request.urlopen, an imported urlopen, any x.urlopen)."""
    tree = ast.parse(path.read_text(encoding="utf-8"), filename=str(path))
    lines = []
    for node in ast.walk(tree):
        if isinstance(node, ast.Call):
            func = node.func
            name = func.id if isinstance(func, ast.Name) else func.attr if isinstance(func, ast.Attribute) else None
            if name == "urlopen":
                lines.append(node.lineno)
    return sorted(lines)


class NoBareUrlopen(unittest.TestCase):
    def test_every_http_call_in_scripts_ci_goes_through_deadline_http(self):
        problems = []
        seen = set()
        for path in sorted(CI.rglob("*.py")):
            relative = path.relative_to(CI).as_posix()
            if relative == TRANSPORT:
                continue
            lines = urlopen_calls(path)
            if not lines:
                continue
            seen.add(relative)
            allowed = LEGACY.get(relative, 0)
            where = ", ".join(f"scripts/ci/{relative}:{line}" for line in lines)
            if len(lines) > allowed:
                problems.append(f"bare urlopen at {where}: call deadline_http.request() instead")
            elif len(lines) < allowed:
                problems.append(f"scripts/ci/{relative} has {len(lines)} urlopen calls, LEGACY says {allowed}: "
                                f"lower its count in tests/test_ci_no_bare_urlopen.py")
        for relative in sorted(set(LEGACY) - seen):
            problems.append(f"scripts/ci/{relative} has no urlopen call left: drop it from LEGACY")
        self.assertEqual(problems, [], "\n".join(problems))

    def test_the_transport_itself_never_calls_urlopen(self):
        self.assertEqual(urlopen_calls(CI / TRANSPORT), [])

    def test_the_detector_sees_each_spelling(self):
        with tempfile.TemporaryDirectory() as directory:
            sample = Path(directory) / "sample.py"
            sample.write_text("import urllib.request\nfrom urllib.request import urlopen\n"
                              "urllib.request.urlopen('x')\nurlopen('y')\nopener=urllib.request.urlopen\n")
            self.assertEqual(urlopen_calls(sample), [3, 4])


class Server:
    """An HTTP server on 127.0.0.1 that answers each connection with ANSWER (bytes, or a callable of the
    request), a byte every GAP seconds (0: all at once), then holds the connection open HOLD seconds, and
    keeps the requests it received. `accepted` counts the connections it took, in order; `completed` the
    answers it finished on its own (the last byte sent and the hold over), after which it closed the connection."""

    def __init__(self, answer, gap: float = 0, hold: float = 0):
        self.answer, self.gap, self.hold = answer, gap, hold
        self.requests: list[tuple[float, bytes]] = []
        self.accepted = 0
        self.completed = 0
        self.done = threading.Event()
        self.listener = socket.socket()
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen()
        self.listener.settimeout(0.05)
        self.port = self.listener.getsockname()[1]
        self.url = f"http://127.0.0.1:{self.port}"
        self.thread = threading.Thread(target=self.serve, name="test-server", daemon=True)
        self.thread.start()

    def serve(self) -> None:
        while not self.done.is_set():
            try:
                conn, _ = self.listener.accept()
            except OSError:
                continue
            self.accepted += 1
            threading.Thread(target=self.answer_one, args=(conn,), name="test-server-answer", daemon=True).start()

    def answer_one(self, conn: socket.socket) -> None:
        with conn:
            try:
                conn.settimeout(1)
                data = conn.recv(65536)
                if not data:
                    return
                self.requests.append((time.monotonic(), data))
                answer = self.answer(data) if callable(self.answer) else self.answer
                if not self.gap:
                    conn.sendall(answer)
                    if not self.done.wait(self.hold):
                        self.completed += 1
                    return
                for byte in answer:
                    if self.done.wait(self.gap):
                        return
                    conn.sendall(bytes([byte]))
                self.completed += 1
            except OSError:
                return

    def stop(self) -> None:
        self.done.set()
        self.thread.join(2)
        self.listener.close()


class Transport(unittest.TestCase):
    BOUND = 0.2
    OK = b'HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 12\r\n\r\n{"ok": true}'

    def serve(self, answer, gap: float = 0, hold: float = 0) -> Server:
        server = Server(answer, gap, hold)
        self.addCleanup(server.stop)
        return server

    def held_lookup(self) -> threading.Event:
        """Every name lookup waits until the returned event is set (at the latest at cleanup), then resolves."""
        real = socket.getaddrinfo
        release = threading.Event()

        def lookup(*args, **kwargs):
            release.wait(60)
            return real(*args, **kwargs)

        socket.getaddrinfo = lookup
        self.addCleanup(setattr, socket, "getaddrinfo", real)
        self.addCleanup(release.set)
        return release

    def assert_nothing_reached(self, server: Server) -> None:
        """No call reached SERVER: a probe of our own, connected after them, is the first connection it took. The
        listener takes connections in order, so any earlier connect is counted by the time the probe is answered."""
        with socket.create_connection(("127.0.0.1", server.port), timeout=10) as probe:
            probe.sendall(b"GET /probe HTTP/1.0\r\n\r\n")
            while probe.recv(65536):
                pass
        self.assertEqual(server.accepted, 1, server.requests)

    @staticmethod
    def manual_clock(start: float = 1000.0):
        """A clock that moves only when the test moves it: (clock, advance)."""
        now = [start]

        def advance(seconds: float) -> None:
            now[0] += seconds

        return (lambda: now[0]), advance

    def test_a_fast_answer_returns_status_body_and_headers(self):
        server = self.serve(self.OK)
        status, body, headers = deadline_http.request(server.url + "/x", self.BOUND)
        self.assertEqual((status, body), (200, b'{"ok": true}'))
        self.assertEqual(headers["content-type"], "application/json")
        self.assertEqual(headers.get("Content-Type"), "application/json")  # any case

    def test_an_error_status_is_an_answer(self):
        server = self.serve(b"HTTP/1.1 403 Forbidden\r\nX-RateLimit-Remaining: 0\r\nContent-Length: 4\r\n\r\nnope")
        status, body, headers = deadline_http.request(server.url, self.BOUND)
        self.assertEqual((status, body, headers.get("x-ratelimit-remaining")), (403, b"nope", "0"))

    def test_raise_errors_raises_the_http_error_with_its_body_and_headers(self):
        server = self.serve(b"HTTP/1.1 429 Too Many\r\nRetry-After: 7\r\nContent-Length: 4\r\n\r\nslow")
        with self.assertRaises(urllib.error.HTTPError) as raised:
            deadline_http.request(server.url, self.BOUND, raise_errors=True)
        self.assertEqual(raised.exception.code, 429)
        self.assertEqual(raised.exception.headers.get("Retry-After"), "7")
        self.assertEqual(raised.exception.read(), b"slow")

    def test_trickled_headers_end_at_the_deadline(self):
        # A header byte every 30 ms (each socket wait well under the bound), about 30 s for all of them.
        slow = b"HTTP/1.1 204 No Content\r\nX-Trickle: " + b"a" * 1000 + b"\r\nContent-Length: 0\r\n\r\n"
        server = self.serve(slow, 0.03)
        deadline = deadline_http.Deadline(self.BOUND)
        with self.assertRaises(deadline_http.RequestTimeout) as raised:
            deadline_http.request(server.url, deadline=deadline)
        # At the deadline, not before it ...
        self.assertGreaterEqual(time.monotonic(), deadline.at)
        self.assertNotIsInstance(raised.exception, deadline_http.Stalled)
        # ... and not at the end of the answer: the server was still trickling the headers.
        self.assertEqual(server.completed, 0)

    def test_a_trickled_body_ends_at_the_deadline(self):
        slow = b"HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n" + b"b" * 40
        server = self.serve(slow[:-2], hold=2)  # the headers at once; the body's last bytes never come
        with self.assertRaises(deadline_http.RequestTimeout):
            deadline_http.request(server.url, self.BOUND)

    def test_a_lookup_past_the_deadline_sends_nothing(self):
        server = self.serve(self.OK)
        release = self.held_lookup()
        before = set(threading.enumerate())
        request = urllib.request.Request(server.url, data=b"{}", method="POST")
        with self.assertRaises(deadline_http.RequestTimeout):
            deadline_http.request(request, self.BOUND)
        # The lookup the call abandoned now finishes; whatever the call left running ends before the check.
        release.set()
        for thread in set(threading.enumerate()) - before:
            if not thread.name.startswith("test-server"):
                thread.join(10)
                self.assertFalse(thread.is_alive(), thread.name)
        self.assert_nothing_reached(server)

    def test_one_deadline_shared_by_calls_counts_time_already_spent(self):
        server = self.serve(self.OK)
        clock, advance = self.manual_clock()
        deadline = deadline_http.Deadline(self.BOUND, clock=clock)
        advance(self.BOUND * 1.1)  # earlier calls spent all of it
        with self.assertRaises(deadline_http.RequestTimeout):
            deadline_http.request(server.url, deadline=deadline)
        self.assert_nothing_reached(server)

    def test_a_followed_redirect_drops_the_unredirected_token(self):
        target = self.serve(self.OK)
        origin = self.serve(f"HTTP/1.1 302 Found\r\nLocation: {target.url}/blob\r\nContent-Length: 0\r\n\r\n".encode())
        request = urllib.request.Request(origin.url + "/zip")
        request.add_unredirected_header("Authorization", "Bearer secret")
        status, body, _ = deadline_http.request(request, self.BOUND)
        self.assertEqual((status, body), (200, b'{"ok": true}'))
        self.assertIn(b"Bearer secret", origin.requests[0][1])
        self.assertNotIn(b"secret", target.requests[0][1])

    def test_a_redirect_not_followed_is_returned_with_its_location(self):
        origin = self.serve(b"HTTP/1.1 302 Found\r\nLocation: http://127.0.0.1:9/blob\r\nContent-Length: 0\r\n\r\n")
        status, _, headers = deadline_http.request(origin.url, self.BOUND, follow_redirects=False)
        self.assertEqual((status, headers["location"]), (302, "http://127.0.0.1:9/blob"))

    def test_a_body_over_the_cap_is_refused(self):
        server = self.serve(self.OK)
        with self.assertRaisesRegex(ValueError, "over 4 bytes"):
            deadline_http.request(server.url, self.BOUND, max_bytes=4)

    def test_a_slow_start_of_the_lookup_thread_counts_against_the_deadline(self):
        # The time left is read at the wait, not before the thread starts (Codex review of #40631, P2; the class of
        # #40574's F2): a start that takes most of the bound must not buy the lookup a fresh bound.
        # On a manual clock: the start takes 0.8 of the bound, so the wait on the lookup gets the 0.2 left.
        server = self.serve(self.OK)
        self.held_lookup()
        clock, advance = self.manual_clock()
        real_start, real_join = threading.Thread.start, threading.Thread.join
        waits: list[float | None] = []

        def start(thread):
            if thread.name == "deadline-http-resolve":
                advance(0.8 * self.BOUND)
            return real_start(thread)

        def join(thread, timeout=None):
            if thread.name == "deadline-http-resolve":
                waits.append(timeout)
            return real_join(thread, timeout)

        threading.Thread.start, threading.Thread.join = start, join
        self.addCleanup(setattr, threading.Thread, "join", real_join)
        self.addCleanup(setattr, threading.Thread, "start", real_start)
        with self.assertRaises(deadline_http.RequestTimeout):
            deadline_http.request(server.url, deadline=deadline_http.Deadline(self.BOUND, clock=clock))
        self.assertEqual(len(waits), 1, waits)
        self.assertAlmostEqual(waits[0], 0.2 * self.BOUND)

    def test_a_stream_gives_status_and_headers_before_the_body(self):
        # The headers and the body's first bytes at once; the rest never comes (the server holds the connection
        # far past the deadline).
        server = self.serve(b"HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-39/90\r\n"
                            b"Content-Length: 40\r\n\r\n" + b"c" * 8, hold=30)
        deadline = deadline_http.Deadline(self.BOUND)
        with deadline_http.stream(server.url, deadline=deadline) as answer:
            self.assertEqual((answer.status, answer.headers.get("content-range")), (206, "bytes 0-39/90"))
            self.assertEqual(answer.read(8), b"c" * 8)
            with self.assertRaises(deadline_http.RequestTimeout) as raised:
                answer.read(1)
        # The read ended at the deadline, not before it, and not when the server let go of the connection.
        self.assertGreaterEqual(time.monotonic(), deadline.at)
        self.assertNotIsInstance(raised.exception, deadline_http.Stalled)
        self.assertEqual(server.completed, 0)

    def test_a_trickled_stream_body_ends_at_the_deadline_mid_stream(self):
        # A byte every 10 ms, under the stall, about 30 s for the whole body: only the whole-call deadline ends it,
        # partway through the body.
        deadline = deadline_http.Deadline(1.0)
        server = self.serve(b"HTTP/1.1 200 OK\r\nContent-Length: 3000\r\n\r\n" + b"d" * 3000, gap=0.01)
        received = 0
        with self.assertRaises(deadline_http.RequestTimeout) as raised:
            with deadline_http.stream(server.url, deadline=deadline, stall=0.5) as answer:
                self.assertEqual(answer.status, 200)
                while answer.read(1):
                    received += 1
        # At the deadline, not before it (nor at a stall), and mid-stream: not at the end of the body.
        self.assertGreaterEqual(time.monotonic(), deadline.at)
        self.assertNotIsInstance(raised.exception, deadline_http.Stalled)
        self.assertGreater(received, 0)
        self.assertLess(received, 3000)
        self.assertEqual(server.completed, 0)

    def test_a_stream_that_goes_silent_ends_at_its_stall(self):
        # The deadline and the server's hold are far past the stall: Stalled (raised only when the stall bounded the
        # wait that ran out) with the server still holding the connection is the stall ending the read.
        server = self.serve(b"HTTP/1.1 200 OK\r\nContent-Length: 40\r\n\r\n" + b"e" * 4, hold=30)
        with deadline_http.stream(server.url, 20.0, stall=self.BOUND) as answer:
            self.assertEqual(answer.read(4), b"e" * 4)
            with self.assertRaises(deadline_http.Stalled):
                answer.read(1)
        self.assertEqual(server.completed, 0)

    def test_a_headers_only_stream_closes_without_reading_the_body(self):
        # A probe of a big download: status and headers, then out, never waiting for the body. The body never comes
        # and the server holds the connection past the deadline: closing returns while it still holds it, with no
        # RequestTimeout, so nothing waited on the body.
        server = self.serve(b"HTTP/1.1 200 OK\r\nContent-Length: 999999\r\n\r\n" + b"f" * 4, hold=30)
        with deadline_http.stream(server.url, 20.0) as answer:
            self.assertEqual((answer.status, answer.headers.get("Content-Length")), (200, "999999"))
        self.assertEqual(server.completed, 0)

    def test_a_stream_returns_a_redirect_not_followed_then_streams_its_location(self):
        # The release-asset shape: the token request answers with a redirect, the signed URL is streamed.
        target = self.serve(self.OK)
        origin = self.serve(f"HTTP/1.1 302 Found\r\nLocation: {target.url}/blob\r\nContent-Length: 0\r\n\r\n".encode())
        request = urllib.request.Request(origin.url + "/asset")
        request.add_unredirected_header("Authorization", "Bearer secret")
        with deadline_http.stream(request, self.BOUND, follow_redirects=False) as answer:
            self.assertEqual(answer.status, 302)
            location = answer.headers["location"]
        with deadline_http.stream(location, self.BOUND) as answer:
            self.assertEqual((answer.status, answer.read()), (200, b'{"ok": true}'))
        self.assertEqual(target.requests[0][1].count(b"secret"), 0)

    def test_a_stream_error_status_is_an_answer_or_with_raise_errors_an_http_error(self):
        server = self.serve(b"HTTP/1.1 503 Busy\r\nRetry-After: 3\r\nContent-Length: 4\r\n\r\nbusy")
        with deadline_http.stream(server.url, self.BOUND) as answer:
            self.assertEqual((answer.status, answer.headers.get("Retry-After"), answer.read()), (503, "3", b"busy"))
        with self.assertRaises(urllib.error.HTTPError) as raised:
            with deadline_http.stream(server.url, self.BOUND, raise_errors=True):
                self.fail("an error status entered the block")
        self.assertEqual((raised.exception.code, raised.exception.headers.get("Retry-After")), (503, "3"))
        self.assertEqual(raised.exception.read(), b"busy")


if __name__ == "__main__":
    unittest.main()
