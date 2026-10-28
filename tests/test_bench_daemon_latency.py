#!/usr/bin/env python3
"""cmux-tui/scripts/bench-daemon-latency.py: the pure logic behind its rows and runtime.Q16.

Covers nearest-rank percentiles and stats rows, rows() flattening for the report, select_ops,
the unserved/failed classification of daemon errors (an unknown command or v2 operation is a
skip; a bad enum value inside the params is a failure), the automation storm's window and the
IPC-16 verdict, Conn.pump(0) reading what is readable, write_q16 against a temporary targets file
read back through ipc-census.py's Q16 reader, its refusals, and that main writes --out when the
daemon never starts. No daemon and no build.

Not on CI (Lawrence 2026-10-23: no new CI tests; lane = "manual"): run
python3 -I tests/test_bench_daemon_latency.py after changing the bench or the Q16 record.
"""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import select
import socket
import sys
import tempfile
import unittest

SOURCE = Path(__file__).resolve().parents[1]
BENCH = SOURCE / "cmux-tui/scripts/bench-daemon-latency.py"
CENSUS = SOURCE / "scripts/cmux-next/ipc-census.py"


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve annotations through sys.modules
    spec.loader.exec_module(module)
    return module


bench = load("cmux_bench_daemon_latency", BENCH)


def latency(p95, n=10):
    return {"n": n, "p50_ms": p95 / 2, "p95_ms": p95, "p99_ms": p95, "max_ms": p95, "mean_ms": p95 / 2}


def v12_error(text):
    return {"ok": False, "error": text}


def v2_error(code, message):
    return {"protocol": bench.V2_PROTOCOL, "ok": False, "error": {"code": code, "message": message}}


class Percentiles(unittest.TestCase):
    def test_nearest_rank(self):
        vals = list(range(1, 101))
        self.assertEqual(bench.pick(vals, 0.5), 50)
        self.assertEqual(bench.pick(vals, 0.95), 95)
        self.assertEqual(bench.pick(vals, 0.99), 99)
        self.assertEqual(bench.pick(vals, 1.0), 100)
        self.assertEqual(bench.pick([7], 0.95), 7)
        self.assertEqual(bench.pick([1, 2, 3], 0.5), 2)

    def test_stats_rows_come_from_raw_samples(self):
        vals = [float(v) for v in range(100, 0, -1)]
        row = bench.stats(vals)
        # perf_stats.pct (linear interpolation); nearest rank gave 50, 95, 99 on this vector.
        self.assertEqual((row["n"], row["p50_ms"], row["p95_ms"], row["p99_ms"], row["max_ms"]),
                         (100, 50.5, 95.05, 99.01, 100.0))
        for q, key in ((0.5, "p50_ms"), (0.95, "p95_ms"), (0.99, "p99_ms")):
            self.assertEqual(row[key], round(bench.lab.perf_stats.pct(vals, q), 3))
        self.assertEqual(row["mean_ms"], 50.5)
        self.assertEqual(row["samples_ms"], vals)  # in arrival order
        self.assertNotIn("samples_ms", bench.stats(vals, keep_samples=False))
        self.assertEqual(bench.stats([]), {"n": 0})


class Flattening(unittest.TestCase):
    def test_rows_flatten_sections_and_keep_skips(self):
        res = {
            "ops": {"ping": latency(0.1), "close-tabs": {"n": 0, "skipped": "capability batch-close-v1 not advertised"}},
            "concurrent": {"c10-ping": latency(0.5), "errors": ["x"]},
            "syscalls": {"method": "m", "ping": {"messages": 100, "ctx_per_msg": 3.0}},
            "bulk_interference": {
                "pty_write_kib": 64,
                "frame_max_sweep": {"skipped": "BULK_FRAME_MAX not advertised"},
                "bulk-default-ping-same": latency(1.0),
                "bulk-default-flood": {"seconds": 1.0, "other_events": {"vt-state": 1}},
            },
            "streams": {"views_per_connection": {"views": 4, "ping-ms": latency(0.2)},
                        "streams_one_connection": {"skipped": "capability attach-streams-v1 not advertised"}},
            "automation_storm": {"idle": {"echo": latency(1.0)}, "storm": {"automation": latency(5.0)}},
        }
        self.assertEqual([metric for metric, _ in bench.rows(res)], [
            "ping", "close-tabs", "c10-ping", "frame_max_sweep", "bulk-default-ping-same",
            "streams.views_per_connection.ping-ms", "streams.streams_one_connection",
            "automation_storm.idle.echo", "automation_storm.storm.automation",
        ])

    def test_report_prints_section_errors_and_partial_rows(self):
        res = {"ops": {"ping": latency(0.1), "error": "OSError()"}, "cli": {"error": "boom"}}
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            bench.report("small", res)
        lines = out.getvalue().splitlines()
        self.assertIn("PERF-DAEMON-ERROR small ops OSError()", lines)
        self.assertIn("PERF-DAEMON-ERROR small cli boom", lines)
        self.assertTrue(any(line.startswith("PERF-DAEMON small ping n=10") for line in lines))


class DaemonLocks(unittest.TestCase):
    def test_lock_rows_print_frontend_and_automation_percentiles(self):
        histogram = {"count": 4, "mean": 10, "max": 900, "p50": 5, "p95": 600, "p99": 900}
        data = {"schema": 1, "uptime_ms": 1, "locks": [
            {"lock": "mux.state", "ops": [], "callers": [
                {"caller": "frontend", "wait_us": histogram, "hold_us": histogram},
                {"caller": "program", "wait_us": histogram, "hold_us": histogram},
            ]},
        ]}
        locks = bench.daemon_lock_rows(data)
        self.assertEqual(set(locks["mux.state"]), {"frontend", "automation"})
        self.assertEqual(locks["mux.state"]["frontend"]["wait_us"]["p95"], 600)
        self.assertEqual(locks["mux.state"]["automation"]["hold_us"]["count"], 0)
        res = {"daemon_locks": {"since": "daemon start", "locks": locks}}
        self.assertEqual(list(bench.rows(res)), [])
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            bench.report("scale", res)
        self.assertIn("PERF-DAEMON-LOCKS scale mux.state frontend wait_us.count=4 wait_us.p95=600 "
                      "wait_us.p99=900 wait_us.max=900 hold_us.count=4 hold_us.p95=600 "
                      "hold_us.p99=900 hold_us.max=900", out.getvalue().splitlines())


class OpSelection(unittest.TestCase):
    def test_create_is_only_creations(self):
        create = bench.select_ops("create")
        self.assertTrue(create)
        self.assertTrue(all(bench.OPS[name]["kind"] == "create" for name in create))
        self.assertNotIn("close-tab-group", create)
        self.assertEqual(bench.OPS["close-tab-group"]["kind"], "write")
        self.assertIn("workspace.create", create)

    def test_base_all_and_lists(self):
        self.assertEqual(bench.select_ops("base"), bench.BASE_OPS)
        self.assertEqual(bench.select_ops("all"), list(bench.OPS))
        self.assertEqual(bench.select_ops("ping,send"), ["ping", "send"])
        with self.assertRaises(SystemExit):
            bench.select_ops("ping,no-such-op")

    def test_all_covers_ipc5_ops(self):
        self.assertFalse([name for name in bench.ipc5_ops() if name not in bench.OPS])


class Unserved(unittest.TestCase):
    def test_unknown_command_is_a_skip(self):
        err = bench.DaemonError("close-tabs", v12_error(
            "bad request: unknown variant `close-tabs`, expected one of `ping`, `identify`"))
        self.assertEqual(bench.unserved_reason(err, "close-tabs", "v12", True),
                         "not served by this daemon (unknown command)")

    def test_bad_enum_param_is_a_failure(self):
        # Today's daemon: close-tabs with reason="bogus".
        err = bench.DaemonError("close-tabs", v12_error("bad request: unknown variant `bogus`, expected `session_end`"))
        self.assertIsNone(bench.unserved_reason(err, "close-tabs", "v12", True))

    def test_a_setup_request_is_never_the_op(self):
        err = bench.DaemonError("create-tab-group", v12_error("bad request: unknown variant `create-tab-group`"))
        self.assertIsNone(bench.unserved_reason(err, "ungroup-tab-group", "v12", True))

    def test_v2_envelope_error_needs_a_parsing_envelope(self):
        err = bench.DaemonError("pane.create", v2_error("validation.invalid", "invalid request envelope"))
        self.assertEqual(bench.unserved_reason(err, "pane.create", "v2", True),
                         "not served by this daemon (unknown v2 operation)")
        self.assertIsNone(bench.unserved_reason(err, "pane.create", "v2", False))
        other = bench.DaemonError("pane.create", v2_error("validation.invalid", "direction must be left or right"))
        self.assertIsNone(bench.unserved_reason(other, "pane.create", "v2", True))


class Storm(unittest.TestCase):
    def test_window_counts_only_requests_inside_it(self):
        results = [{"samples": [[9.5, 1.0], [10.5, 2.0], [11.5, 3.0], [12.5, 4.0]], "ended": 12.6},
                   {"samples": [[10.1, 5.0], [13.0, 6.0]], "ended": 13.1}]
        row = bench.storm_window(results, 10.0, 12.0)
        self.assertEqual((row["n"], row["window_s"], row["requests_per_s"]), (3, 2.0, 1.5))
        self.assertTrue(row["clients_cover_window"])

    def test_a_client_that_ends_early_does_not_cover(self):
        results = [{"samples": [[10.5, 1.0]], "ended": 11.0, "error": "ConnectionError()"}]
        row = bench.storm_window(results, 10.0, 12.0)
        self.assertFalse(row["clients_cover_window"])
        self.assertEqual(row["errors"], ["ConnectionError()"])
        self.assertFalse(bench.storm_window([], 10.0, 12.0)["clients_cover_window"])

    def test_ipc16_verdict(self):
        cover = {"clients_cover_window": True}
        storm = {"echo": latency(1.5), "split": latency(1.0),
                 "automation": {**latency(3.0), **cover, "requests_per_s": 60.0}}
        verdict = bench.ipc16_verdict(latency(1.0), storm, {**cover, "requests_per_s": 100.0})
        self.assertEqual(verdict, {"echo_p95_delta_ms": 0.5, "echo_p95_within_idle_plus_1ms": True,
                                   "split_p95_under_2ms": True, "automation_throughput_ratio": 0.6,
                                   "automation_keeps_half": True, "windows_match": True})
        verdict = bench.ipc16_verdict(latency(1.0), storm, {"clients_cover_window": False, "requests_per_s": 200.0})
        self.assertFalse(verdict["automation_keeps_half"])
        self.assertFalse(verdict["windows_match"])
        self.assertIn("error", bench.ipc16_verdict(latency(1.0), {**storm, "split": {"n": 0}}, cover))


def method_row(samples_us):
    """An `ipc_methods` row as the daemon builds it: nearest-rank bucket upper bounds, exact max."""
    ordered = sorted(samples_us)
    latency_us = {key: bench.bucket_upper_bound(bench.bucket_index(bench.pick(ordered, q)))
                  for key, q in bench.METHOD_PERCENTILES}
    return {"method": "ping", "id": 257, "latency_us": {"count": len(ordered), **latency_us, "max": ordered[-1]}}


class DaemonMethods(unittest.TestCase):
    """ops.OP.daemon_methods: the bench's client samples against the daemon's ipc_methods row."""

    def test_buckets_are_the_shared_vector(self):
        fixture = json.loads((SOURCE / "cmux-tui/spec/fixtures/ipc-method-latency/buckets.json").read_text())
        for row in fixture["buckets"]:
            self.assertEqual(bench.bucket_index(row["micros"]), row["bucket"], row)
            self.assertEqual(bench.bucket_upper_bound(row["bucket"]), row["upper_bound"], row)

    def test_the_same_requests_agree_within_one_bucket(self):
        samples_us = [20 + (i * i * i) // 12_500 + (i * 37) % 101 for i in range(1000)]
        # The client sees each round trip 30 us later than the daemon queues its reply.
        client_ms = [(us + 30) / 1000 for us in samples_us]
        agreement = bench.daemon_agreement(client_ms, None, method_row(samples_us))
        self.assertTrue(agreement["within_one_bucket"], agreement)
        self.assertEqual(agreement["n"], 1000)
        self.assertEqual(agreement["id"], 257)
        self.assertEqual(set(agreement["bucket_delta"]), {"p50", "p95", "p99", "max"})
        self.assertTrue(all(delta >= 0 for delta in agreement["bucket_delta"].values()), agreement)

    def test_a_far_daemon_row_is_not_within_one_bucket(self):
        samples_us = [100] * 50
        agreement = bench.daemon_agreement([1.0] * 50, None, method_row(samples_us))
        self.assertFalse(agreement["within_one_bucket"], agreement)
        self.assertGreater(agreement["bucket_delta"]["p50"], 1)

    def test_untimed_requests_of_the_method_are_a_skip(self):
        row = method_row([100] * 10)
        self.assertIn("ran before", bench.daemon_agreement([0.1] * 3, method_row([100] * 7), row)["skipped"])
        self.assertIn("counted 10", bench.daemon_agreement([0.1] * 3, None, row)["skipped"])
        self.assertIn("no ipc_methods row", bench.daemon_agreement([0.1], None, None)["skipped"])

    def test_report_prints_each_compared_method(self):
        agreement = bench.daemon_agreement([0.1] * 4, None, method_row([90] * 4))
        res = {"ops": {"ping": {**latency(0.1, n=4), "daemon_methods": {"ping": agreement}},
                       "send": {**latency(0.1, n=4), "daemon_methods": {"skipped": "no section"}}}}
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            bench.report("small", res)
        self.assertIn("PERF-DAEMON-METHOD small ping ping n=4 within_one_bucket=True", out.getvalue())


class Pump(unittest.TestCase):
    def test_pump_zero_reads_what_is_readable(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "s.sock")
            server = socket.socket(socket.AF_UNIX)
            server.bind(path)
            server.listen(1)
            conn = bench.Conn(path, timeout=5)
            peer, _ = server.accept()
            try:
                peer.sendall(b'{"id": 1, "ok": true}\n')
                select.select([conn.sock], [], [], 5)  # readable, nothing buffered yet
                self.assertEqual(conn.buf, bytearray())
                conn.pump(0)
                self.assertEqual(conn.replies, {1: {"id": 1, "ok": True}})
            finally:
                conn.close()
                peer.close()
                server.close()


def result_with_ops(build_commit=None, head="0123456789abcdef"):
    ops = {name: {**latency(1.0), "wire": plan["wire"], "kind": plan["kind"]} for name, plan in bench.OPS.items()}
    ops["new-tab"] = {**latency(3.5), "wire": "v12", "kind": "create"}
    ops["pane.split"] = {**latency(2.5), "wire": "v2", "kind": "create"}
    ops["close-tabs"] = {"n": 0, "wire": "v12", "kind": "write", "skipped": "capability batch-close-v1 not advertised"}
    ops["move-tab"] = {**latency(4.0), "wire": "v12", "kind": "write", "error": "move-tab: boom"}
    return {
        "host": {"hostname": "aws-m4pro-1", "os": "Darwin", "macos": "26.0"},
        "source": {"sha": head, "dirty": False},
        "daemon": {"version": "1.0.0", "build_commit": build_commit,
                   "binary": {"path": "/x/cmux-tui", "sha256": "ab" * 32, "mtime": "2026-10-26T00:00:00Z"}},
        "scenarios": {"scale": {"ops": ops}},
    }


class Q16(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.targets = os.path.join(self.tmp.name, "ipc-targets.json")
        with open(self.targets, "w", encoding="utf-8") as f:
            json.dump({"about": "x", "allowlist": [], "runtime": {"Q9": []}}, f)

    def tearDown(self):
        self.tmp.cleanup()

    def read(self):
        with open(self.targets, encoding="utf-8") as f:
            return json.load(f)

    def test_items_and_run_record_read_back_through_the_census(self):
        items = bench.write_q16(self.targets, result_with_ops())
        targets = self.read()
        self.assertEqual(targets["runtime"]["Q9"], [])
        self.assertEqual(targets["runtime"]["Q16"], items)
        self.assertEqual([item["key"] for item in items], ["move-tab", "new-tab", "pane.split"])
        for item in items:
            self.assertEqual(set(item), {"file", "line", "key", "p95_ms", "wire"})
            self.assertEqual(item["file"], bench.SCRIPT_REL)
            self.assertEqual(item["line"], bench.OPS[item["key"]]["line"])
        run = targets["runtime"]["Q16_run"]
        self.assertEqual((run["sha"], run["sha_source"]), ("0123456789abcdef", "script checkout"))
        self.assertEqual(run["binary"]["sha256"], "ab" * 32)
        self.assertEqual((run["skipped"], run["failed"]), (["close-tabs"], ["move-tab"]))
        self.assertEqual(run["host"]["hostname"], "aws-m4pro-1")
        census = load("cmux_next_ipc_census_for_bench", CENSUS)
        q16 = census.Census(None, targets).q16()
        self.assertEqual([(hit.file, hit.line, hit.key) for hit in q16.hits],
                         [(item["file"], item["line"], item["key"]) for item in items])

    def test_the_daemon_build_commit_names_the_run(self):
        bench.write_q16(self.targets, result_with_ops(build_commit="0123456"))
        run = self.read()["runtime"]["Q16_run"]
        self.assertEqual((run["sha"], run["sha_source"]), ("0123456", "daemon build_commit"))
        self.assertNotIn("binary", run)

    def test_refusals_leave_the_targets_file_alone(self):
        before = self.read()
        with self.assertRaisesRegex(ValueError, "not this checkout's HEAD"):
            bench.write_q16(self.targets, result_with_ops(build_commit="fedcba9"))
        partial = result_with_ops()
        del partial["scenarios"]["scale"]["ops"]["pane.create"]
        with self.assertRaisesRegex(ValueError, "not measured: pane.create"):
            bench.write_q16(self.targets, partial)
        with self.assertRaisesRegex(ValueError, "scale scenario"):
            bench.write_q16(self.targets, {"scenarios": {"small": {}}})
        self.assertEqual(self.read(), before)


class Main(unittest.TestCase):
    def test_out_is_written_when_the_daemon_never_starts(self):
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "r.json")
            with contextlib.redirect_stderr(io.StringIO()):
                status = bench.main(["--bin", os.path.join(tmp, "missing-cmux-tui"), "--scenario", "small",
                                     "--out", out])
            self.assertEqual(status, 1)
            with open(out) as f:
                result = json.load(f)
            self.assertIn("error", result)
            self.assertEqual(result["scenarios"], {})
            self.assertIn("host", result)


if __name__ == "__main__":
    unittest.main()
