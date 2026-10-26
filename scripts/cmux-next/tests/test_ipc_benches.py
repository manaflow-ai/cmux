#!/usr/bin/env python3
"""split-latency-bench.py --streams and bench-typing.py --flood (p05-ipc-005), without an app or a Mac.

1. split-latency-bench against a fake daemon (JSON lines on a Unix socket). The bench's reference view: without
   `attach-streams-v1` it costs 1 handshake round trip, 3 requests and 1 connection; with it the control connection
   advertises the capability in set-client-info (the fake refuses `stream` on a connection that did not) and the view
   is a stream on it: 0, 1 and 0. The IPC-2 verdict comes from the app's own counts only: a fake app that opens a
   connection per view while the capability is advertised fails it. --socket mode runs with no sw_vers on PATH.
2. bench-typing's join: keys meet their daemon writes by flow id (row base + i), so a write that lands after the
   next key still belongs to its own key; rows that do not fit refuse the join; the echo is the typed terminal's
   own record in the key's window (write to next write); a write without a terminal id refuses the echo series; the
   app series are withheld when another terminal output anything in the phase.
3. The shared distribution is nearest-rank p50/p95/p99/max; host_block never raises; flow files with a cut last
   line and a dropped count parse; the tag's bundle resolves from --app, then $NX_APP.

Runs anywhere with python3 (Linux too): python3 -I scripts/cmux-next/tests/test_ipc_benches.py
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from unittest import mock

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

    def __init__(self, capabilities, grant_reply_lists=True, grants=None):
        self.capabilities = capabilities
        self.grant_reply_lists = grant_reply_lists
        self.grants = grants  # the capabilities set-client-info grants (default: what was asked and is advertised)
        self.advertised = {}  # connection number -> capabilities its set-client-info advertised
        self.on_split = []  # callbacks run after a split's reply (a fake app attaching its view)
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
            for callback in self.on_split:
                callback(surface)
        elif cmd == "set-client-info":
            asked = [c for c in (m.get("capabilities") or []) if c in self.capabilities]
            if self.grants is not None:
                asked = [c for c in asked if c in self.grants]
            with self.lock:
                self.advertised[number] = set(asked)
            ok({"capabilities": asked} if self.grant_reply_lists else None)
        elif cmd == "attach-surface":
            stream = m.get("stream")
            with self.lock:
                negotiated = split_bench.STREAMS_CAPABILITY in self.advertised.get(number, set())
            if stream is not None and not negotiated:
                self.write(conn, {"id": rid, "error": {"code": "invalid_params",
                                                        "message": "stream needs attach-streams-v1 in set-client-info"}})
                return
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


class FakeApp:
    """The app's side for one fake daemon: on each split it attaches a view of the new surface the way today's
    TerminalAttachment does (a new connection, identify + set-client-info, attach-surface) or, with `streams`,
    sends only attach-surface on its one control line; it counts what it opened and wrote as debug.daemon.wire."""

    def __init__(self, daemon, streams):
        self.daemon, self.streams = daemon, streams
        self.opened = 0
        self.lines = 0
        self.views = []
        daemon.on_split.append(self.attach)

    def attach(self, surface):
        if self.streams:
            self.lines += 1  # attach-surface with a stream on the already negotiated control connection
            return
        conn = split_bench.Conn(self.daemon.path)
        self.opened += 1
        conn.send({"cmd": "identify"})
        conn.send({"cmd": "set-client-info", "name": "app", "kind": "app"})
        conn.send({"cmd": "attach-surface", "surface": surface, "mode": "bytes"})
        self.lines += 3
        self.views.append(conn)

    def wire(self):
        return {"lines_written": self.lines, "connections": {"opened": {"control": 1, "terminal_attach": self.opened}},
                "bridge_spawns": {"terminal_attach": 0}}

    def close(self):
        for conn in self.views:
            conn.close()


def bench_args(**overrides):
    args = split_bench.parse_args(["--socket", "unused", "--runs", "3", "--streams"])
    args.__dict__.update(overrides)
    return args


class SplitStreamsTests(unittest.TestCase):
    def run_bench(self, capabilities, app=None, **daemon_options):
        daemon = FakeDaemon(capabilities, **daemon_options)
        self.addCleanup(daemon.close)
        fake_app = None
        overrides = {}
        if app is not None:
            fake_app = FakeApp(daemon, streams=app == "streams")
            self.addCleanup(fake_app.close)
            overrides = {"app_census": True, "settle": 0.2}
        args = bench_args(**overrides)
        args.socket = daemon.path
        lines = []
        rows, info = split_bench.bench(daemon.path, args, log=lines.append,
                                       app_wire=fake_app.wire if fake_app else None,
                                       app_absent=None if fake_app else "--socket: no app is attached")
        return daemon, rows, info

    def test_per_view_connection_baseline(self):
        daemon, rows, info = self.run_bench(["terminal-placement-env-v1"])
        self.assertEqual(len(rows), 3)
        self.assertIn("not advertised", info["streams"])
        for row in rows:
            self.assertEqual((row["bench_view_attach_handshake_rtts"], row["bench_view_requests"],
                              row["bench_view_connections"]), (1, 3, 1))
            self.assertIsNone(row["stream"])
            self.assertIsNotNone(row["first_content_after_attach"])
        # The control connection, the subscriber, and one per view.
        self.assertEqual(daemon.accepted, 2 + 3)
        self.assertTrue(all(stream is None and number > 2 for number, stream in daemon.attaches))
        # No app: the bench's own view never becomes an IPC-2 verdict.
        self.assertEqual(info["ipc2"]["measured"], False)

    def test_streams_are_negotiated_on_the_control_connection(self):
        for lists in (True, False):
            with self.subTest(reply_lists_capabilities=lists):
                daemon, rows, info = self.run_bench([split_bench.STREAMS_CAPABILITY], grant_reply_lists=lists)
                self.assertEqual(info["streams"], "on")
                self.assertEqual(daemon.advertised[1], {split_bench.STREAMS_CAPABILITY})
                for row in rows:
                    self.assertEqual((row["bench_view_attach_handshake_rtts"], row["bench_view_requests"],
                                      row["bench_view_connections"]), (0, 1, 0))
                    self.assertIsNotNone(row["first_content_after_attach"])
                self.assertEqual([row["stream"] for row in rows], [1, 2, 3])
                self.assertEqual(daemon.accepted, 2)
                self.assertEqual(daemon.attaches, [(1, 1), (1, 2), (1, 3)])

    def test_a_stream_on_an_unnegotiated_connection_is_refused(self):
        daemon = FakeDaemon([split_bench.STREAMS_CAPABILITY])
        self.addCleanup(daemon.close)
        ctl = split_bench.Conn(daemon.path)
        self.addCleanup(ctl.close)
        ctl.reply(ctl.send({"cmd": "identify"}))
        view = split_bench.open_view(daemon.path, ctl, "s1", 1, timeout=2)
        self.assertIsNotNone(view["refused"])

    def test_a_daemon_that_does_not_grant_streams_keeps_per_view_connections(self):
        daemon, rows, info = self.run_bench([split_bench.STREAMS_CAPABILITY], grants=[])
        self.assertIn("did not grant", info["streams"])
        self.assertTrue(all(row["stream"] is None and row["bench_view_connections"] == 1 for row in rows))
        self.assertEqual(daemon.accepted, 2 + 3)

    def test_ipc2_is_the_apps_view_not_the_benchs(self):
        # The daemon advertises streams and the bench's own view uses them (0/1/0), but the app still opens a
        # connection per view: IPC-2 fails, from the app's count and from the daemon's census.
        daemon, rows, info = self.run_bench([split_bench.STREAMS_CAPABILITY], app="per-view")
        for row in rows:
            self.assertEqual(row["bench_view_connections"], 0)
            self.assertEqual(row["app_view_connections"], 1)
            self.assertEqual(row["app_view_attach_handshake_rtts"], 1)
            self.assertEqual(row["app_view_lines_written"], 3)
            self.assertEqual(row["app_connections_per_view"], 1)
        self.assertEqual(info["ipc2"]["measured"], True)
        self.assertEqual(info["ipc2"]["source"], "app debug.daemon.wire")
        self.assertEqual(info["ipc2"]["app_view_connections_max"], 1)
        self.assertFalse(info["ipc2"]["pass"])

    def test_ipc2_passes_when_the_app_view_is_a_stream(self):
        _, rows, info = self.run_bench([split_bench.STREAMS_CAPABILITY], app="streams")
        self.assertTrue(all(row["app_view_connections"] == 0 and row["app_connections_per_view"] == 0 for row in rows))
        self.assertTrue(info["ipc2"]["pass"])

    def test_summary_has_tail_percentiles(self):
        _, rows, _ = self.run_bench([split_bench.STREAMS_CAPABILITY])
        stats = split_bench.summarize(rows, "t", log=lambda _: None)
        self.assertEqual(set(stats["attach_reply"]), {"n", "p50", "p95", "p99", "max"})
        self.assertEqual(stats["bench_view_connections"]["max"], 0)

    def test_socket_mode_runs_without_sw_vers(self):
        daemon = FakeDaemon(["terminal-placement-env-v1"])
        self.addCleanup(daemon.close)
        empty = tempfile.mkdtemp(prefix="no-sw-vers-")
        self.addCleanup(shutil.rmtree, empty, True)
        out = io.StringIO()
        with mock.patch.dict(os.environ, {"PATH": empty}), contextlib.redirect_stdout(out):
            code = split_bench.main(["--socket", daemon.path, "--runs", "1", "--streams"])
        self.assertEqual(code, 0)
        self.assertIn("== host ", out.getvalue())

    def test_ssh_needs_a_host(self):
        with self.assertRaises(SystemExit):
            split_bench.parse_args(["--socket", "s", "--machine", "ssh"])


PID = 4242
TYPED, FLOODER = "aa" * 16, "bb" * 16


def flow(index, pid=PID):
    return (pid << 32) | index


MS = 1_000_000


def write(row, t_ns, terminal=TYPED, pid=PID):
    return {"hop": "daemon.send.write", "flow": flow(row, pid=pid), "terminal": terminal, "t_ns": t_ns}


class FloodMatchingTests(unittest.TestCase):
    def test_echo_is_the_typed_terminals_and_series_by_row(self):
        keys = [1000 * MS, 1200 * MS]
        writes = [write(7, keys[0] + 2 * MS), write(8, keys[1] + 3 * MS), write(9, keys[1] + 4 * MS, pid=1)]
        joined = typing_bench.join_writes(keys, writes, PID, base=7)
        # A flooder's output is under another terminal and never consulted.
        echoes = {TYPED: [keys[0] + 4 * MS, keys[1] + 5 * MS], FLOODER: [keys[0] + 2 * MS + 1]}
        typing_bench.place_echoes(joined, echoes)
        self.assertEqual([(e["row"], e["echo_ns"]) for e in joined], [(7, keys[0] + 4 * MS), (8, keys[1] + 5 * MS)])
        rows = [{"index": "7", "complete": "1", "output_decoded_ms": "6.0", "contents_ms": "9.0"},
                {"index": "8", "complete": "1", "output_decoded_ms": "7.0", "contents_ms": "8.0"}]
        series, counts = typing_bench.key_series(joined, rows)
        self.assertEqual(series["key_to_daemon_write_ms"], [2.0, 3.0])
        self.assertEqual(series["key_to_daemon_echo_ms"], [4.0, 5.0])
        self.assertEqual(series["key_to_app_echo_ms"], [6.0, 7.0])
        self.assertEqual(series["key_to_frame_ms"], [9.0, 8.0])
        self.assertEqual(counts["missed_write"], 0)

    def test_a_write_after_the_next_key_stays_with_its_own_key(self):
        # Key 0's write is slow: it lands 250 ms later, after key 1 (150 ms) was sent and written. A join by time
        # would give it to key 1 and drop key 1's real write; by flow id key 0 keeps its 250 ms.
        keys = [0, 150 * MS]
        writes = [write(1, 160 * MS), write(0, 250 * MS)]
        joined = typing_bench.join_writes(keys, writes, PID, base=0)
        self.assertEqual([(e["row"], e["write_ns"] - e["key_ns"]) for e in joined], [(0, 250 * MS), (1, 10 * MS)])

    def test_rows_that_do_not_fit_the_keys_refuse_the_join(self):
        keys = [0, 150 * MS]
        with self.assertRaises(typing_bench.JoinRefused):  # row 5 is no key of this phase
            typing_bench.join_writes(keys, [write(0, 1 * MS), write(5, 151 * MS)], PID, base=0)
        with self.assertRaises(typing_bench.JoinRefused):  # no base and a key without its write
            typing_bench.join_writes(keys, [write(3, 1 * MS)], PID, base=None)
        with self.assertRaises(typing_bench.JoinRefused):  # a write before its own key
            typing_bench.join_writes(keys, [write(0, 1 * MS), write(1, 100 * MS)], PID, base=0)
        joined = typing_bench.join_writes(keys, [write(0, 1 * MS)], PID, base=0)
        self.assertIsNone(joined[1]["write_ns"])
        _, counts = typing_bench.key_series(typing_bench.place_echoes(joined, {}), [])
        self.assertEqual(counts["missed_write"], 1)
        self.assertEqual(typing_bench.next_row([write(4, 1), write(9, 2), write(30, 3, pid=1)], PID), 10)

    def test_echo_windows_run_write_to_write(self):
        keys = [100, 200, 300]
        joined = typing_bench.join_writes(keys, [write(0, 110), write(1, 210), write(2, 310)], PID, base=0)
        # Key 0's echo (at 250) lands after key 1's write: key 0 has none, key 1's window holds two, key 2's one
        # record follows an unplaced key, so none of them is placed on a guess.
        typing_bench.place_echoes(joined, {TYPED: [250, 260, 320]})
        self.assertEqual([e["echo_ns"] for e in joined], [None, None, None])
        self.assertEqual([e["echo_missed"] for e in joined],
                         ["none", "two or more", "the key before did not place its echo"])
        joined = typing_bench.join_writes(keys, [write(0, 110), write(1, 210), write(2, 310)], PID, base=0)
        typing_bench.place_echoes(joined, {TYPED: [150, 250, 350]})
        self.assertEqual([e["echo_ns"] for e in joined], [150, 250, 350])

    def test_no_terminal_id_refuses_the_echo_series(self):
        keys = [100]
        joined = typing_bench.join_writes(keys, [write(0, 110, terminal="")], PID, base=0)
        typing_bench.place_echoes(joined, {"": [120]})
        echo_refused, app_unscoped = typing_bench.phase_scope(joined, [{"terminal": ""}, {"terminal": ""}])
        self.assertIsNotNone(echo_refused)
        self.assertIsNotNone(app_unscoped)
        series, _ = typing_bench.key_series(joined, [], echo_scoped=False, app_scoped=False)
        self.assertEqual(series["key_to_daemon_echo_ms"], [])

    def test_app_series_are_withheld_when_another_terminal_outputs(self):
        keys = [100]
        joined = typing_bench.join_writes(keys, [write(0, 110)], PID, base=0)
        typing_bench.place_echoes(joined, {TYPED: [120]})
        rows = [{"index": "0", "complete": "1", "output_decoded_ms": "0.00002", "contents_ms": "0.00003"}]
        echo_refused, app_unscoped = typing_bench.phase_scope(joined, [{"terminal": TYPED}, {"terminal": FLOODER}])
        self.assertIsNone(echo_refused)
        self.assertIn("other terminals", app_unscoped)
        series, _ = typing_bench.key_series(joined, rows, app_scoped=app_unscoped is None)
        self.assertEqual(series["key_to_daemon_echo_ms"], [20 / 1e6])
        self.assertEqual((series["key_to_app_echo_ms"], series["key_to_frame_ms"]), ([], []))
        self.assertEqual(typing_bench.phase_scope(joined, [{"terminal": TYPED}]), (None, None))

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

    def test_host_block_never_raises(self):
        def missing(*_args, **_kwargs):
            raise FileNotFoundError(2, "No such file or directory", "sw_vers")
        with mock.patch.object(bench_tagged.bench_launch, "host_facts", missing), \
                mock.patch.object(bench_tagged.bench_launch, "read_host", missing), \
                mock.patch.object(bench_tagged.bench_launch, "main_display_hz", lambda: None):
            block = bench_tagged.host_block()
        self.assertIsNone(block["macos"])
        self.assertIsNone(block["display_hz"])
        self.assertTrue(block["host"])
        self.assertIn("sw_vers", block["host_record_error"])
        with mock.patch.object(bench_tagged.bench_launch, "host_facts",
                               lambda: (_ for _ in ()).throw(subprocess.TimeoutExpired("sw_vers", 10))):
            self.assertIn("host_facts_error", bench_tagged.host_block())

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
