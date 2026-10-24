#!/usr/bin/env python3
"""Tests for the tmux + proxied browser demo.

Run: python3 -I scripts/cmux-next/proxy-demo/test_proxy_demo.py
Unit tests always run; the tmux test needs tmux on PATH (skipped otherwise).
"""

from __future__ import annotations

import http.client
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

import devserver  # noqa: E402
import ports  # noqa: E402
import demo  # noqa: E402
import macsockets  # noqa: E402
import linuxsockets  # noqa: E402
import socket  # noqa: E402
import struct  # noqa: E402

LSOF = """p100
cpython3
f3
n127.0.0.1:8000
p200
cnode
f20
n*:5173
f21
n[::1]:5174
p300
cother
f4
n127.0.0.1:9999
"""


class ParseTests(unittest.TestCase):
    def test_lsof_filters_by_pid_and_normalizes_hosts(self) -> None:
        got = ports.parse_lsof(LSOF, {100, 200})
        self.assertEqual(
            [(l.port, l.host, l.pid, l.command) for l in got],
            [(5173, "0.0.0.0", 200, "node"), (5174, "::1", 200, "node"), (8000, "127.0.0.1", 100, "python3")],
        )

    def test_netstat_darwin_reads_owner_pid(self) -> None:
        text = (
            "tcp4       0      0  127.0.0.1.56567        *.*                    LISTEN                 0            0  131072  131072           Python:73602  00000 00000006 000000001bbcb3db 00000000 00000800      1      0 000000\n"
            "tcp46      0      0  *.51142                *.*                    LISTEN                 0            0  131072  131072         rapportd:726    00100 00000006 000000001ba6f5cc 00000000 00080800      1      0 000000\n"
            "tcp4       0 130168  100.82.214.112.52891   100.120.48.119.4016    ESTABLISHED            0       202620  131396  131396          2.1.305:69973  00102 00000000 000000001bbd96f6 00000081 04000900      2      0 000000\n"
        )
        got = ports.parse_netstat_darwin(text)
        self.assertEqual([(l.port, l.host, l.pid) for l in got], [(51142, "0.0.0.0", 726), (56567, "127.0.0.1", 73602)])
        self.assertEqual(ports.parse_netstat_darwin(text, {73602})[0].command, "Python")

    def test_ss_reads_owner_pid(self) -> None:
        text = 'LISTEN 0 5 127.0.0.1:8000 0.0.0.0:* users:(("python3",pid=42,fd=3))\nLISTEN 0 511 [::]:5173 [::]:* users:(("node",pid=7,fd=20))\n'
        got = ports.parse_ss(text, {42, 7})
        self.assertEqual([(l.port, l.host, l.pid, l.command) for l in got], [(5173, "::", 7, "node"), (8000, "127.0.0.1", 42, "python3")])

    def test_descendants_walks_the_tree_and_survives_cycles(self) -> None:
        children = ports.parse_ps("1 0\n10 1\n11 10\n12 11\n20 1\n10 12\n")
        self.assertEqual(ports.descendants([10], children), {10, 11, 12})

    def test_tmux_clients_map_tty_to_session(self) -> None:
        self.assertEqual(
            ports.parse_tmux_clients("/dev/ttys004 demo\n/dev/ttys009 other session\n"),
            {"/dev/ttys004": "demo", "/dev/ttys009": "other session"},
        )

    def test_pick_prefers_http_ports_of_the_dev_server(self) -> None:
        listeners = [ports.Listener(9229, "127.0.0.1", 5, "node"), ports.Listener(5173, "127.0.0.1", 5, "node")]
        self.assertEqual(demo.pick_port(listeners).port, 5173)
        self.assertIsNone(demo.pick_port([]))


class HopTests(unittest.TestCase):
    def test_loopback_peer_without_proxy_headers_is_proxied(self) -> None:
        info = devserver.hop_summary("127.0.0.1", {"Host": "localhost:1"})
        self.assertTrue(info["proxied"])

    def test_owner_in_netstat_finds_client_end(self) -> None:
        text = (
            "tcp4       0      0  127.0.0.1.54663        127.0.0.1.57987        ESTABLISHED         1238          223  407744  146988           Python:28071  00002 00000004 000000001bc5a801 00000080 01000800      2      0 000000\n"
            "tcp4       0      0  127.0.0.1.57987        127.0.0.1.54663        ESTABLISHED          550          593  408128  146988             cmux:19566  00002 00000000 000000001bc5a800 00000081 04000900      3      0 000000\n"
        )
        self.assertEqual(devserver.owner_in_netstat(text, "127.0.0.1", 57987), "cmux:19566")
        self.assertIsNone(devserver.owner_in_netstat(text, "127.0.0.1", 1))

    def test_owner_names_the_hop(self) -> None:
        self.assertTrue(devserver.hop_summary("127.0.0.1", {}, "cmux-tui:4242")["proxied"])
        self.assertTrue(devserver.hop_summary("127.0.0.1", {}, "cmux:19566")["proxied"])
        # Seen on the Mac mini, 2026-10-21: a pushed build keeps its file name.
        self.assertTrue(devserver.hop_summary("127.0.0.1", {}, "cmux-tui-nightly:75986")["proxied"])
        direct = devserver.hop_summary("127.0.0.1", {}, "Chromium Helper:99")
        self.assertFalse(direct["proxied"])
        self.assertIn("direct", direct["summary"])

    def test_proxy_header_that_reaches_the_server_is_a_leak(self) -> None:
        info = devserver.hop_summary("127.0.0.1", {"Proxy-Authorization": "x", "Via": "1.1 cmux"})
        self.assertFalse(info["proxied"])
        self.assertEqual(info["leaked"], ["Proxy-Authorization", "Via"])


class DevServerTests(unittest.TestCase):
    def test_serves_page_viewport_and_live_reload(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = devserver.State(root, None)
            httpd = devserver.ThreadingHTTPServer(("127.0.0.1", 0), devserver.make_handler(state))
            httpd.daemon_threads = True
            port = httpd.server_address[1]
            threading.Thread(target=httpd.serve_forever, daemon=True).start()
            threading.Thread(target=devserver.watch, args=(state, 0.05), daemon=True).start()
            try:
                conn = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                conn.request("GET", "/")
                self.assertIn(b"tmux + proxied browser bench", conn.getresponse().read())
                conn.request("POST", "/viewport", body=json.dumps({"w": 800, "h": 600, "dpr": 2}),
                             headers={"content-type": "application/json"})
                self.assertEqual(conn.getresponse().status, 204)

                events = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
                events.request("GET", "/events")
                stream = events.getresponse()
                time.sleep(0.2)
                (root / "app.js").write_text("console.log(1)")
                deadline = time.time() + 5
                buf = b""
                while b"event: reload" not in buf and time.time() < deadline:
                    buf += stream.fp.readline()
                self.assertIn(b"event: reload", buf)
            finally:
                httpd.shutdown()


class LinuxSocketsTests(unittest.TestCase):
    def test_parses_proc_net_tcp(self) -> None:
        text = (
            "  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode\n"
            "   0: 0100007F:D9B4 0100007F:DA31 01 00000000:00000000 00:00000000 00000000  1000        0 41234 1 0 20 4 30 10 -1\n"
            "   1: 0100007F:DA31 00000000:0000 0A 00000000:00000000 00:00000000 00000000  1000        0 41000 1 0 100 0 0 10 0\n"
        )
        self.assertEqual(linuxsockets.parse_proc_net_tcp(text), [(0xD9B4, 0xDA31, 41234, "01"), (0xDA31, 0, 41000, "0A")])


class MacSocketsTests(unittest.TestCase):
    def test_parses_socket_fdinfo_offsets(self) -> None:
        raw = bytearray(macsockets.SOCKET_FDINFO_SIZE)
        struct.pack_into("<i", raw, macsockets.OFF_KIND, macsockets.SOCKINFO_TCP)
        struct.pack_into("<i", raw, macsockets.OFF_FAMILY, macsockets.AF_INET)
        struct.pack_into("<h", raw, macsockets.OFF_OPTIONS, macsockets.SO_ACCEPTCONN)
        struct.pack_into(">H", raw, macsockets.OFF_LPORT, 54663)  # network order in an int
        raw[macsockets.OFF_LADDR + 12 : macsockets.OFF_LADDR + 16] = bytes([127, 0, 0, 1])
        sock = macsockets.parse_socket_fdinfo(1, 3, bytes(raw))
        self.assertEqual((sock.listening, sock.local_host, sock.local_port), (True, "127.0.0.1", 54663))
        struct.pack_into("<i", raw, macsockets.OFF_KIND, 3)  # SOCKINFO_UN
        self.assertIsNone(macsockets.parse_socket_fdinfo(1, 3, bytes(raw)))

    @unittest.skipUnless(macsockets.available(), "macOS only")
    def test_reads_own_listener_and_connection_owner(self) -> None:
        server = socket.socket()
        server.bind(("127.0.0.1", 0))
        server.listen()
        port = server.getsockname()[1]
        client = socket.create_connection(("127.0.0.1", port))
        try:
            mine = macsockets.tcp_sockets(os.getpid())
            self.assertIn(port, [s.local_port for s in mine if s.listening])
            owner = macsockets.connection_owner(client.getsockname()[1], port)
            self.assertEqual(owner[0], os.getpid())
        finally:
            client.close()
            server.close()


@unittest.skipUnless(shutil.which("tmux"), "tmux not installed")
class TmuxPortDiscoveryTests(unittest.TestCase):
    """A server in a tmux pane is not a child of the terminal: find it anyway."""

    def test_finds_server_started_in_a_tmux_pane(self) -> None:
        session = f"cmux-ports-test-{uuid.uuid4().hex[:8]}"
        with tempfile.TemporaryDirectory() as tmp:
            port_file = Path(tmp) / "port"
            cmd = f"{sys.executable} -I {HERE / 'devserver.py'} --root {tmp} --port-file {port_file}"
            subprocess.run(["tmux", "new-session", "-d", "-s", session, cmd], check=True)
            try:
                deadline = time.time() + 10
                while not (port_file.exists() and port_file.read_text().strip()) and time.time() < deadline:
                    time.sleep(0.1)
                want = int(port_file.read_text())
                started = time.time()
                result = ports.find(ports.parse_args(["--tmux-session", session]))
                elapsed = time.time() - started
                self.assertIn(want, [l["port"] for l in result["listeners"]])
                # libproc on the session's pids: well under a second even at
                # load average 140 (lsof took about 5 s, 2026-10-21).
                self.assertLess(elapsed, 2.0, "port discovery must be fast enough to poll")
            finally:
                subprocess.run(["tmux", "kill-session", "-t", f"={session}"], check=False)


@unittest.skipUnless(shutil.which("tmux"), "tmux not installed")
class TmuxUpTests(unittest.TestCase):
    def test_builds_server_and_size_monitor_panes(self) -> None:
        session = f"cmux-up-test-{uuid.uuid4().hex[:8]}"
        with tempfile.TemporaryDirectory() as tmp:
            env = dict(os.environ, CMUX_DEMO_NO_ATTACH="1")
            proc = subprocess.run(["sh", str(HERE / "tmux-up.sh"), session, f"{tmp}/state", f"{tmp}/site"],
                                  env=env, capture_output=True, text=True, timeout=20)
            try:
                self.assertEqual(proc.returncode, 0, proc.stderr)
                panes = subprocess.run(["tmux", "list-panes", "-t", f"{session}:", "-F", "#{pane_index}"],
                                       capture_output=True, text=True).stdout.split()
                self.assertEqual(panes, ["0", "1"])
                size = subprocess.run(["tmux", "show-options", "-v", "-t", session, "window-size"],
                                      capture_output=True, text=True).stdout.strip()
                self.assertEqual(size, "latest")
                hooks = subprocess.run(["tmux", "show-hooks", "-w", "-t", f"{session}:"], capture_output=True, text=True).stdout
                self.assertIn("window-resized", hooks, "the monitor pane must keep its height after a resize")
            finally:
                subprocess.run(["tmux", "kill-session", "-t", f"={session}"], check=False)


if __name__ == "__main__":
    os.environ.setdefault("PYTHONDONTWRITEBYTECODE", "1")
    unittest.main(verbosity=2)
