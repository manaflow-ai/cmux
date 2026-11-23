#!/usr/bin/env python3
"""lan-dial (scripts/lan-dial): the relay protocol end to end, the way launchd runs it, with no Mac.

A Unix listener here stands in for launchd's inetdCompatibility socket: for each connection it starts
`sh relay.sh` with the accepted socket as stdin and stdout. In place of Apple's /usr/bin/nc the relay execs
`lan_dial.py --via direct connect` (LAN_DIAL_NC), which bridges stdio to TCP the same way. The Mac run, where the
relay is a real launchd job and the peer a real LAN machine, is scripts/measure/lan-dial-demo.sh.
"""

from __future__ import annotations

import errno
import http.server
import os
import plistlib
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[1]
LAN_DIAL = ROOT / "scripts/lan-dial"
sys.path.insert(0, str(LAN_DIAL))
import lan_dial  # noqa: E402


class FakeLaunchd:
    """An inetd-style listener on a Unix socket: one `SHELL relay.sh` per connection, stdin/stdout the socket."""

    def __init__(self, path: Path, shell: str) -> None:
        self.path = path
        self.shell = shell
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(path))
        self.server.listen(16)
        self.children: list[subprocess.Popen] = []
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self) -> None:
        env = dict(os.environ, LAN_DIAL_NC=sys.executable,
                   LAN_DIAL_NC_FLAGS=f"{LAN_DIAL / 'lan_dial.py'} --via direct connect")
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                self.children.append(subprocess.Popen([self.shell, str(LAN_DIAL / "relay.sh")], stdin=conn,
                                                      stdout=conn, stderr=subprocess.DEVNULL, env=env))

    def close(self) -> None:
        self.server.close()
        for child in self.children:
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()


class BannerEcho:
    """A TCP server that greets first (as sshd does), then echoes until the caller closes its side."""

    def __init__(self) -> None:
        self.server = socket.create_server(("127.0.0.1", 0))
        self.port = self.server.getsockname()[1]
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self) -> None:
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            threading.Thread(target=self.one, args=(conn,), daemon=True).start()

    @staticmethod
    def one(conn: socket.socket) -> None:
        with conn:
            conn.sendall(b"HELLO lan-dial\n")
            while True:
                data = conn.recv(65536)
                if not data:
                    return
                conn.sendall(data)


def recv_all(sock: socket.socket) -> bytes:
    sock.settimeout(10)
    data = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            return data
        data += chunk


class RelayProtocolTest(unittest.TestCase):
    shell = "sh"

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="lan-dial-"))
        self.sock = self.tmp / "relay.sock"
        self.launchd = FakeLaunchd(self.sock, shutil.which(self.shell) or self.skipTest(f"no {self.shell}"))
        self.peer = BannerEcho()

    def tearDown(self) -> None:
        self.launchd.close()
        self.peer.server.close()
        shutil.rmtree(self.tmp, ignore_errors=True)

    def raw(self, line: bytes) -> bytes:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as s:
            s.connect(str(self.sock))
            s.sendall(line)
            s.shutdown(socket.SHUT_WR)
            return recv_all(s)

    def test_stream_after_ok_is_the_peers_both_ways(self) -> None:
        with lan_dial.via_relay("127.0.0.1", self.peer.port, sock=self.sock) as s:
            payload = os.urandom(200_000)
            s.sendall(payload)
            s.shutdown(socket.SHUT_WR)
            data = recv_all(s)
        # The banner the peer sent before anything was asked is not eaten by the relay's request read.
        self.assertEqual(data, b"HELLO lan-dial\n" + payload)

    def test_bytes_sent_with_the_request_line_reach_the_peer(self) -> None:
        answer = self.raw(f"CONNECT 127.0.0.1 {self.peer.port}\nearly bytes".encode())
        self.assertTrue(answer.startswith(b"OK\nHELLO lan-dial\n"), answer)
        self.assertTrue(answer.endswith(b"early bytes"), answer)

    def test_crlf_request_line(self) -> None:
        self.assertTrue(self.raw(f"CONNECT 127.0.0.1 {self.peer.port}\r\n".encode()).startswith(b"OK\n"))

    def test_bad_requests_get_err_and_nothing_runs(self) -> None:
        for line, said in [
            (b"CONNECT -oProxyCommand=x 22\n", b"ERR not a host"),
            (b"CONNECT 127.0.0.1 70000\n", b"ERR not a port"),
            (b"CONNECT 127.0.0.1 022\n", b"ERR not a port"),
            (b"CONNECT 127.0.0.1 22x\n", b"ERR not a port"),
            (b"CONNECT a;b 22\n", b"ERR not a host"),
            (b"CONNECT $(id) 22\n", b"ERR not a host"),
            (b"CONNECT * 22\n", b"ERR not a host"),
            (b"GET / HTTP/1.0\n", b"ERR expected"),
            (b"CONNECT 127.0.0.1\n", b"ERR expected"),
        ]:
            with self.subTest(line=line):
                self.assertTrue(self.raw(line).startswith(said), self.raw(line))
        with self.assertRaisesRegex(lan_dial.DialError, "relay: ERR not a port"):
            lan_dial.via_relay("127.0.0.1", 70000, sock=self.sock)

    def test_peer_down_is_eof_after_ok(self) -> None:
        closed = socket.create_server(("127.0.0.1", 0))
        port = closed.getsockname()[1]
        closed.close()
        receipt_sock = lan_dial.via_relay("127.0.0.1", port, sock=self.sock)
        with receipt_sock:
            self.assertEqual(recv_all(receipt_sock), b"")

    def test_auto_takes_the_relay_when_privacy_refuses_the_direct_dial(self) -> None:
        home = self.tmp / "home"
        home.mkdir()
        shutil.copy(LAN_DIAL / "relay.sh", home / "relay.sh")
        refused = OSError(errno.EHOSTUNREACH, "No route to host")
        env = {"LAN_DIAL_HOME": str(home), "LAN_DIAL_SOCKET": str(self.sock)}
        with mock.patch.dict(os.environ, env), mock.patch.object(lan_dial, "is_macos", return_value=True), \
                mock.patch.object(lan_dial, "direct", side_effect=refused) as direct, \
                mock.patch.object(lan_dial, "up", side_effect=AssertionError("relay already answers")), \
                mock.patch.object(lan_dial, "_relay_preferred", False):
            for _ in range(2):
                with lan_dial.dial("127.0.0.1", self.peer.port) as s:
                    self.assertEqual(s.family, socket.AF_UNIX)
                    s.shutdown(socket.SHUT_WR)
                    self.assertEqual(recv_all(s), b"HELLO lan-dial\n")
            # After the first refusal the process goes straight to the relay.
            self.assertEqual(direct.call_count, 1)

    def test_auto_does_not_hide_a_plain_refusal(self) -> None:
        with mock.patch.object(lan_dial, "is_macos", return_value=True), \
                mock.patch.object(lan_dial, "direct", side_effect=ConnectionRefusedError(errno.ECONNREFUSED, "x")), \
                mock.patch.object(lan_dial, "_relay_preferred", False):
            with self.assertRaises(ConnectionRefusedError):
                lan_dial.dial("127.0.0.1", 9)

    def test_http_get_through_the_relay(self) -> None:
        class Handler(http.server.BaseHTTPRequestHandler):
            def do_GET(self) -> None:  # noqa: N802
                body = f"stats for {self.path}".encode()
                self.send_response(200)
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *args) -> None:
                pass

        class Server(http.server.ThreadingHTTPServer):
            def server_bind(self) -> None:  # no getfqdn (a Local Network prompt on a Mac)
                self.socket.bind(self.server_address)
                self.server_address = self.socket.getsockname()
                self.server_name, self.server_port = self.server_address[:2]

        server = Server(("127.0.0.1", 0), Handler)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            with mock.patch.dict(os.environ, {"LAN_DIAL_SOCKET": str(self.sock)}), \
                    mock.patch.object(lan_dial, "status_current", return_value=True):
                body = lan_dial.http_get(f"http://127.0.0.1:{server.server_port}/stats", via="relay")
            self.assertEqual(body, b"stats for /stats")
        finally:
            server.shutdown()
            server.server_close()


class RelayProtocolBashTest(RelayProtocolTest):
    """macOS's /bin/sh is bash; Linux's is dash. Both must read the request line without eating the stream."""

    shell = "bash"


class PlistTest(unittest.TestCase):
    def test_plist_is_socket_activated_owner_only_and_rooted_on_apples_sh(self) -> None:
        state = Path("/Users/runner/.local/state/cmux/lan-dial")
        plist = plistlib.loads(lan_dial.plist_bytes(state, state / "relay.sock"))
        self.assertEqual(plist["ProgramArguments"], ["/bin/sh", str(state / "relay.sh")])
        self.assertEqual(plist["inetdCompatibility"], {"Wait": False})
        listener = plist["Sockets"]["Listeners"]
        self.assertEqual(listener["SockPathMode"], 0o600)
        self.assertEqual(listener["SockPathName"], str(state / "relay.sock"))
        # stderr must not go to the socket, where it would land in the caller's stream.
        self.assertEqual(plist["StandardErrorPath"], str(state / "relay.log"))

    def test_domains(self) -> None:
        with mock.patch.object(os, "getuid", return_value=0):
            self.assertEqual(lan_dial.domains(), ["system"])
        with mock.patch.object(os, "getuid", return_value=501):
            self.assertEqual(lan_dial.domains(), ["gui/501", "user/501"])

    def test_up_off_macos_says_why(self) -> None:
        with mock.patch.object(lan_dial, "is_macos", return_value=False):
            with self.assertRaisesRegex(OSError, "macOS launchd job"):
                lan_dial.up()


if __name__ == "__main__":
    unittest.main()
