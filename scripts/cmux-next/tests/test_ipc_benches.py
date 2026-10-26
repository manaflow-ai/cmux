#!/usr/bin/env python3
"""split-latency-bench.py --streams and bench-typing.py --flood (p05-ipc-005), without an app or a Mac.

1. split-latency-bench against a fake daemon (JSON lines on a Unix socket): without `attach-streams-v1` each view
   costs 1 handshake round trip, 3 requests and 1 connection (today's TerminalAttachment); with it the view is a
   stream on the control connection (attach-surface carries `stream`, cancel-stream after): 0, 1 and 0, and the
   daemon accepts no connection for it.
2. bench-typing's flow matching: a key is matched to its daemon write by the flow id's pid, the echo is the typed
   terminal's own (a flooder's output on another terminal never counts), and a probe row whose output mark came
   before the typed echo left the daemon is dropped as unscoped.
3. The shared distribution is nearest-rank p50/p95/p99/max; flow files with a cut last line and a dropped count
   parse; the tag's bundle resolves from --app, then $NX_APP.

Runs anywhere with python3 (Linux too): python3 -I scripts/cmux-next/tests/test_ipc_benches.py
"""
import importlib.util
import json
import os
import shutil
import socket
import sys
import tempfile
import threading
import unittest

HERE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, HERE)


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


split_bench = load("split_latency_bench", "split-latency-bench.py")
typing_bench = load("bench_typing", "bench-typing.py")
import bench_tagged  # noqa: E402


class FakeDaemon:
    """Just enough of cmux-tui for split-latency-bench: one workspace with one pane, split, attach, close."""

    def __init__(self, capabilities):
        self.capabilities = capabilities
        self.dir = tempfile.mkdtemp(prefix="ipc-bench-")
        self.path = os.path.join(self.dir, "d.sock")
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(self.path)
        self.server.listen(16)
        self.accepted = 0
        self.attaches = []  # (connection number, stream or None)
        self.subscribers = []
        self.connections = []
        self.surfaces = 0
        self.lock = threading.Lock()
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with self.lock:
                self.accepted += 1
                number = self.accepted
                self.connections.append(conn)
            threading.Thread(target=self.serve, args=(conn, number), daemon=True).start()

    def write(self, conn, obj):
        conn.sendall((json.dumps(obj) + "\n").encode())

    def serve(self, conn, number):
        buf = b""
        while True:
            try:
                chunk = conn.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buf += chunk
            while b"\n" in buf:
                raw, buf = buf.split(b"\n", 1)
                self.handle(conn, number, json.loads(raw))

    def handle(self, conn, number, m):
        cmd, rid = m.get("cmd"), m.get("id")
        ok = lambda data=None: self.write(conn, {"id": rid, "ok": True, "data": data or {}})
        if cmd == "identify":
            ok({"capabilities": self.capabilities})
        elif cmd == "subscribe":
            with self.lock:
                self.subscribers.append(conn)
            ok()
        elif cmd == "list-workspaces":
            ok({"workspaces": [{"id": "ws1", "screens": [{"panes": [{"id": "p1"}]}]}]})
        elif cmd == "split":
            with self.lock:
                self.surfaces += 1
                surface = f"s{self.surfaces}"
                subscribers = list(self.subscribers)
            ok({"surface": surface})
            for sub in subscribers:
                self.write(sub, {"event": "pane-added"})
                self.write(sub, {"event": "layout-changed"})
        elif cmd == "set-client-info":
            ok()
        elif cmd == "attach-surface":
            stream = m.get("stream")
            with self.lock:
                self.attaches.append((number, stream))
            ok()
            event = {"event": "output", "data": "prompt$ "}
            if stream is not None:
                event["stream"] = stream
            self.write(conn, event)
        elif cmd == "cancel-stream":
            ok()
        elif cmd == "close-surface":
            ok()
        elif cmd == "server-stats":
            with self.lock:
                ok({"connections": {"accepted": self.accepted}})
        else:
            self.write(conn, {"id": rid, "error": {"code": "unknown", "message": cmd}})

    def close(self):
        for conn in self.connections:
            conn.close()
        self.server.close()
        shutil.rmtree(self.dir, ignore_errors=True)


def bench_args(**overrides):
    args = split_bench.parse_args(["--socket", "unused", "--runs", "3", "--streams"])
    args.__dict__.update(overrides)
    return args


class SplitStreamsTests(unittest.TestCase):
    def run_bench(self, capabilities):
        daemon = FakeDaemon(capabilities)
        self.addCleanup(daemon.close)
        args = bench_args()
        args.socket = daemon.path
        lines = []
        rows, info = split_bench.bench(daemon.path, args, log=lines.append)
        return daemon, rows, info

    def test_per_view_connection_baseline(self):
        daemon, rows, info = self.run_bench(["terminal-placement-env-v1"])
        self.assertEqual(len(rows), 3)
        self.assertIn("not advertised", info["streams"])
        for row in rows:
            self.assertEqual((row["attach_handshake_rtts"], row["view_requests"], row["view_connections"]), (1, 3, 1))
            self.assertIsNone(row["stream"])
            self.assertIsNotNone(row["first_content_after_attach"])
        # The control connection, the subscriber, and one per view.
        self.assertEqual(daemon.accepted, 2 + 3)
        self.assertTrue(all(stream is None and number > 2 for number, stream in daemon.attaches))

    def test_streams_use_the_control_connection(self):
        daemon, rows, info = self.run_bench([split_bench.STREAMS_CAPABILITY])
        self.assertEqual(info["streams"], "on")
        for row in rows:
            self.assertEqual((row["attach_handshake_rtts"], row["view_requests"], row["view_connections"]), (0, 1, 0))
            self.assertIsNotNone(row["first_content_after_attach"])
        self.assertEqual([row["stream"] for row in rows], [1, 2, 3])
        self.assertEqual(daemon.accepted, 2)
        self.assertEqual(daemon.attaches, [(1, 1), (1, 2), (1, 3)])

    def test_summary_has_tail_percentiles(self):
        _, rows, _ = self.run_bench([split_bench.STREAMS_CAPABILITY])
        stats = split_bench.summarize(rows, "t", log=lambda _: None)
        self.assertEqual(set(stats["attach_reply"]), {"n", "p50", "p95", "p99", "max"})
        self.assertEqual(stats["view_connections"]["max"], 0)

    def test_ssh_needs_a_host(self):
        with self.assertRaises(SystemExit):
            split_bench.parse_args(["--socket", "s", "--machine", "ssh"])


PID = 4242
TYPED, FLOODER = "aa" * 16, "bb" * 16


def flow(index, pid=PID):
    return (pid << 32) | index


class FloodMatchingTests(unittest.TestCase):
    def test_echo_is_the_typed_terminal_and_unscoped_marks_drop(self):
        ms = 1_000_000
        keys = [1000 * ms, 1200 * ms]
        writes = [
            {"hop": "daemon.send.write", "flow": flow(7), "terminal": TYPED, "t_ns": keys[0] + 2 * ms},
            {"hop": "daemon.send.write", "flow": flow(8), "terminal": TYPED, "t_ns": keys[1] + 3 * ms},
            {"hop": "daemon.send.write", "flow": flow(9, pid=1), "terminal": TYPED, "t_ns": keys[1] + 4 * ms},
        ]
        # The typed terminal's echoes; a flooder's output is under another terminal and never consulted.
        echoes = {TYPED: [keys[0] + 4 * ms, keys[1] + 5 * ms], FLOODER: [keys[0] + 2 * ms + 1]}
        matched = typing_bench.match_keys(keys, writes, echoes, PID)
        self.assertEqual([(m["row"], m["echo_ns"]) for m in matched], [(7, keys[0] + 4 * ms), (8, keys[1] + 5 * ms)])
        rows = [
            # Decoded at 6 ms, after the daemon's echo at 4 ms: kept.
            {"index": "7", "complete": "1", "output_decoded_ms": "6.0", "contents_ms": "9.0"},
            # Decoded at 3 ms, before the typed echo left the daemon at 5 ms: a flooder's output took the mark.
            {"index": "8", "complete": "1", "output_decoded_ms": "3.0", "contents_ms": "4.0"},
        ]
        series, dropped = typing_bench.key_series(matched, rows)
        self.assertEqual(dropped, 1)
        self.assertEqual(series["key_to_daemon_write_ms"], [2.0, 3.0])
        self.assertEqual(series["key_to_daemon_echo_ms"], [4.0, 5.0])
        self.assertEqual(series["key_to_app_echo_ms"], [6.0])
        self.assertEqual(series["key_to_frame_ms"], [9.0])

    def test_echo_after_the_next_key_is_not_this_keys(self):
        keys = [100, 200]
        writes = [{"flow": flow(1), "terminal": TYPED, "t_ns": 110}]
        matched = typing_bench.match_keys(keys, writes, {TYPED: [250]}, PID)
        self.assertIsNone(matched[0]["echo_ns"])

    def test_read_flows_sums_drops_and_skips_a_cut_line(self):
        folder = tempfile.mkdtemp(prefix="flows-")
        self.addCleanup(shutil.rmtree, folder, True)
        with open(os.path.join(folder, "flows-1.jsonl"), "w") as f:
            f.write(json.dumps({"hop": "daemon.send.write", "flow": 1, "terminal": TYPED, "t_ns": 5}) + "\n")
            f.write(json.dumps({"dropped": 3}) + "\n")
            f.write('{"hop": "daemon.output.att')
        with open(os.path.join(folder, "flows-2.jsonl"), "w") as f:
            f.write(json.dumps({"hop": "daemon.output.attach", "flow": 0, "terminal": TYPED, "t_ns": 9}) + "\n")
        records, dropped = typing_bench.read_flows(folder, lambda r: True)
        self.assertEqual(dropped, 3)
        self.assertEqual([r["t_ns"] for r in records], [5, 9])

    def test_flood_needs_a_launch(self):
        with self.assertRaises(SystemExit):
            typing_bench.parse_args(["--flood", "10"])
        args = typing_bench.parse_args(["--tag", "ipc-base", "--flood", "10", "--stress"])
        self.assertTrue(args.launched)
        self.assertEqual((args.samples, args.interval), (120, 0.15))


class SharedTests(unittest.TestCase):
    def test_distribution_is_nearest_rank(self):
        stats = bench_tagged.distribution(list(range(1, 101)) + [None])
        self.assertEqual(stats, {"n": 100, "p50": 50, "p95": 95, "p99": 99, "max": 100})
        self.assertIsNone(bench_tagged.distribution([None]))

    def test_resolve_app(self):
        self.assertEqual(bench_tagged.resolve_app("t", "/x/cmux DEV t.app", {}), "/x/cmux DEV t.app")
        self.assertEqual(bench_tagged.resolve_app("t", None, {"NX_APP": "/y/cmux DEV t.app"}), "/y/cmux DEV t.app")
        with self.assertRaises(SystemExit):
            bench_tagged.resolve_app(None, None, {})

    def test_daemon_socket_found_and_timeout(self):
        folder = tempfile.mkdtemp(prefix="tmpdir-")
        self.addCleanup(shutil.rmtree, folder, True)
        with self.assertRaises(SystemExit):
            bench_tagged.daemon_socket("t", timeout=0, temp_dir=folder)
        os.makedirs(os.path.join(folder, "cmux-tui-501"))
        path = os.path.join(folder, "cmux-tui-501", "cmux-app-t.sock")
        open(path, "w").close()
        self.assertEqual(bench_tagged.daemon_socket("t", timeout=0, temp_dir=folder), path)


if __name__ == "__main__":
    unittest.main()
