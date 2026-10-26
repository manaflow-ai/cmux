"""script-storm-bench.py --hidden N (p06-scheduler-150) without an app: the option's parse and --help, the hidden
phase's numbers from fake debug replies, and the counted storm worker (HIDDEN_OPS ops, after `go`) against a fake
session daemon.

  python3 -I tests/test_script_storm_bench.py
"""
import collections
import importlib.util
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parents[1] / "scripts" / "cmux-next" / "script-storm-bench.py"
# Runs the worker with the host's PTY count fixed, and CLOCK_UPTIME_RAW (macOS) standing in on Linux.
BOOT = ("import sys, time, runpy; sys.path.insert(0, sys.argv[1].rsplit('/', 1)[0]); import bench_cli_storm; "
        "time.CLOCK_UPTIME_RAW = getattr(time, 'CLOCK_UPTIME_RAW', time.CLOCK_MONOTONIC); "
        "bench_cli_storm.ptys_in_use = lambda: 10; "
        "sys.argv = [sys.argv[1], '--storm-worker', sys.argv[2]]; runpy.run_path(sys.argv[0], run_name='__main__')")


def load_bench(*args):
    """The bench module parsed with `args` (its module code parses sys.argv; main() runs only as __main__)."""
    out = tempfile.mkdtemp(prefix="storm-bench-")
    saved = sys.argv
    sys.argv = [str(BENCH), "--app", "/nonexistent/cmux.app", "--out", out, *args]
    sys.path.insert(0, str(BENCH.parent))
    try:
        spec = importlib.util.spec_from_file_location("script_storm_bench_under_test", BENCH)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.argv = saved


def parse_exit(*args):
    """The exit status and stderr of a parse that the bench refuses."""
    result = subprocess.run([sys.executable, "-I", str(BENCH), "--app", "/nonexistent", "--out",
                             tempfile.mkdtemp(prefix="storm-bench-"), *args], capture_output=True, text=True, timeout=60)
    return result.returncode, result.stderr


class HiddenOptionTests(unittest.TestCase):
    def test_help_documents_the_hidden_mode(self):
        result = subprocess.run([sys.executable, "-I", str(BENCH), "--help"], capture_output=True, text=True, timeout=60)
        self.assertEqual(result.returncode, 0, result.stderr)
        text = " ".join(result.stdout.split())
        self.assertIn("--hidden [N]", text)
        for words in ("N hidden workspaces", "1000 CLI ops", "main ms/op", "hidden-node tasks by class",
                      "hidden_workspace_layouts", "frontend mailbox events per hidden surface"):
            self.assertIn(words, text)

    def test_hidden_n_sets_the_hidden_workspaces_and_adds_the_phase(self):
        bench = load_bench("--hidden", "12")
        self.assertTrue(bench.HIDDEN)
        self.assertEqual(bench.opts.hidden, 12)
        self.assertEqual(bench.opts.background, 12)
        self.assertEqual(bench.PHASES, ["idle", "script", "hidden"])
        self.assertEqual(set(bench.HIDDEN_RATES), {"reorder", "move", "column", "rename"})

    def test_bare_hidden_is_fifty_and_the_hidden_phase_alone_runs(self):
        bench = load_bench("--hidden", "--phases", "hidden")
        self.assertEqual(bench.opts.hidden, 50)
        self.assertEqual(bench.PHASES, ["hidden"])

    def test_without_hidden_nothing_changes(self):
        bench = load_bench()
        self.assertFalse(bench.HIDDEN)
        self.assertEqual(bench.opts.background, 50)
        self.assertEqual(bench.PHASES, ["idle", "script"])

    def test_refusals(self):
        for args, words in ((["--hidden", "10", "--background", "20"], "differs"),
                            (["--phases", "hidden"], "needs --hidden"),
                            (["--hidden", "0"], "at least 1"),
                            (["--hidden", "5", "--rates", "app-rename=10,batch=1"], "CLI op kind"),
                            (["--phases", "idle,storm"], "unknown phases")):
            status, err = parse_exit(*args)
            self.assertEqual(status, 2, args)
            self.assertIn(words, err, args)


class HiddenNumbersTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.bench = load_bench("--hidden", "50")

    def test_op_shares_split_by_rate_and_sum_to_the_total(self):
        shares = self.bench.op_shares({"reorder": 1000, "move": 200, "column": 100, "rename": 500, "batch": 0}, 1000)
        self.assertEqual(sum(shares.values()), 1000)
        self.assertEqual(shares, {"reorder": 555, "move": 111, "column": 56, "rename": 278})
        self.assertEqual(self.bench.op_shares({"move": 0}, 1000), {})

    def window(self, seconds=2.0):
        budget = {
            "turn_ms": {"scheduled_total": 30.0, "render_total": 12.5, "input_total": 0.5, "unattributed_total": 7.0},
            "owners": [
                {"owner": "DaemonStore.drain", "class": "visible", "nodes": {"none": 40, "hidden": 3}},
                {"owner": "control.request", "class": "automation", "nodes": {"hidden": 5, "occluded": 1}},
                {"owner": "sidebar.rows", "class": "visible", "nodes": {"visible": 9, "hidden": 2}},
                {"owner": "idle.sweep", "class": "background", "nodes": {"none": 4}},
            ],
            "owner_ledger": {"recorded": 64, "dropped": 0, "pending": 0},
        }
        return {"seconds": seconds, "budget": budget,
                "layout_before": {"hidden_workspace_layouts": 4, "hidden_workspace_applies": 10},
                "layout": {"hidden_workspace_layouts": 4, "hidden_workspace_applies": 13},
                "drain": {"batches": 20, "events": 300, "p50_ms": 0.1, "p95_ms": 0.3, "p99_ms": 0.5, "max_ms": 0.9},
                "observations": {"totals": {"hidden_body_evaluations": 0, "body_evaluations": 7}}}

    def test_hidden_numbers(self):
        numbers = self.bench.hidden_numbers(self.window(), ops=1000, surfaces=150)
        self.assertEqual(numbers["main_busy_ms"], 50.0)
        self.assertEqual(numbers["main_ms_per_op"], 0.05)
        tasks = numbers["hidden_node_tasks"]
        self.assertEqual(tasks["hidden_by_class"], {"visible": 5, "automation": 5})
        self.assertEqual(tasks["occluded_by_class"], {"automation": 1})
        self.assertEqual(tasks["hidden_total"], 10)
        self.assertEqual([r["owner"] for r in tasks["hidden_owners"]],
                         ["control.request", "DaemonStore.drain", "sidebar.rows"])
        self.assertEqual(numbers["hidden_workspace_layouts"], 0)
        self.assertEqual(numbers["hidden_workspace_applies"], 3)
        self.assertEqual(numbers["frontend_events"], 300)
        self.assertEqual(numbers["frontend_events_per_hidden_surface_per_s"], 1.0)
        self.assertEqual(numbers["hidden_body_evaluations"], 0)
        self.assertFalse(numbers["drain"]["over_budget"])
        self.assertEqual(numbers["missing"], [])

    def test_a_base_build_reports_what_it_lacks_as_null(self):
        window = {"seconds": 2.0, "budget": {"error": {"code": "method_not_found"}},
                  "layout_before": {"workspace_applies": 1}, "layout": {"workspace_applies": 2},
                  "drain": {"error": {"code": "method_not_found"}}, "observations": {"error": "unreachable"}}
        numbers = self.bench.hidden_numbers(window, ops=1000, surfaces=150)
        for field in ("main_busy_ms", "main_ms_per_op", "hidden_node_tasks", "hidden_workspace_layouts",
                      "hidden_workspace_applies", "frontend_events", "frontend_events_per_hidden_surface_per_s",
                      "hidden_body_evaluations"):
            self.assertIsNone(numbers[field], field)
        self.assertEqual(set(numbers["missing"]), {"main_busy_ms", "hidden_node_tasks", "frontend_events",
                                                    "hidden_body_evaluations", "hidden_workspace_layouts",
                                                    "hidden_workspace_applies"})

    def test_net_subtracts_the_idle_window_scaled_to_the_storm(self):
        storm = self.bench.hidden_numbers(self.window(seconds=2.0), ops=1000, surfaces=150)
        idle_window = self.window(seconds=4.0)
        idle_window["budget"]["turn_ms"] = {"scheduled_total": 10.0, "render_total": 0, "input_total": 0,
                                            "unattributed_total": 0}
        idle_window["drain"]["events"] = 60
        idle = self.bench.hidden_numbers(idle_window, ops=0, surfaces=150)
        net = self.bench.hidden_net(storm, idle)
        self.assertEqual(net["net_main_ms_per_op"], 0.045)  # (50 - 10 * 2/4) / 1000
        self.assertEqual(net["net_frontend_events_per_hidden_surface_per_s"], 0.9)  # 1.0 - 60/150/4

    def test_summary_row(self):
        storm = self.bench.hidden_numbers(self.window(), ops=1000, surfaces=150)
        run = {"phase": "hidden", "shape": "light", "invalid": [], "hidden_workspaces": 50, "hidden_surfaces": 150,
               "storm": storm, "idle": storm, **self.bench.hidden_net(storm, storm)}
        row = self.bench.hidden_summary(run)
        self.assertEqual(row["main_ms_per_op"], 0.05)
        self.assertEqual(row["net_main_ms_per_op"], 0.0)
        self.assertEqual(row["hidden_node_tasks_by_class"], {"visible": 5, "automation": 5})
        self.assertEqual(row["hidden_workspace_layouts"], 0)
        self.assertEqual(row["frontend_events_per_hidden_surface_per_s"], 1.0)
        self.assertIsNone(row["invalid"])
        self.assertIsNone(row["missing"])


class FakeDaemon:
    """Answers each JSON line ok (a create gets `data.surface`) and counts commands per connection."""

    def __init__(self, path):
        self.lock = threading.Lock()
        self.connections, self.next_surface = [], 1000
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen(16)
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            counts = collections.Counter()
            with self.lock:
                self.connections.append(counts)
            threading.Thread(target=self.serve_closing, args=(conn, counts), daemon=True).start()

    def serve_closing(self, conn, counts):
        with conn:
            self.serve(conn, counts)

    def serve(self, conn, counts):
        buffer = b""
        while True:
            try:
                chunk = conn.recv(65536)
            except OSError:
                return
            if not chunk:
                return
            buffer += chunk
            while b"\n" in buffer:
                line, buffer = buffer.split(b"\n", 1)
                message = json.loads(line)
                cmd = message.get("cmd") or message.get("method")
                reply = {"id": message["id"], "ok": True}
                with self.lock:
                    counts[cmd] += 1
                    if cmd in ("new-pane-right", "new-row"):
                        reply["data"] = {"surface": self.next_surface}
                        self.next_surface += 1
                conn.sendall((json.dumps(reply) + "\n").encode())

    def totals(self):
        with self.lock:
            total = collections.Counter()
            for counts in self.connections:
                total.update(counts)
            return total

    def close(self):
        self.server.close()


class CountedWorkerTests(unittest.TestCase):
    def start(self, ops):
        directory = tempfile.mkdtemp(prefix="storm-", dir="/tmp")  # a short path: AF_UNIX paths stop at 104 bytes
        path = os.path.join(directory, "d.sock")
        daemon = FakeDaemon(path)
        self.addCleanup(daemon.close)
        background = [{"handle": 10 + i, "panes": [100 + 2 * i, 101 + 2 * i], "spare": 500 + i,
                       "tabs": [500 + i, 600 + i], "tab_ids": [f"t{i}a", f"t{i}b"]} for i in range(5)]
        plan = {"daemon": path, "control": path, "background": background, "workspaces": 6, "live_columns": 2,
                "max_live_terminals": 8, "max_inflight": 512, "ops": ops,
                "rates": {"reorder": 1000.0, "move": 200.0, "column": 100.0, "rename": 500.0}}
        plan_path = os.path.join(directory, "plan.json")
        with open(plan_path, "w") as handle:
            json.dump(plan, handle)
        worker = subprocess.Popen([sys.executable, "-I", "-c", BOOT, str(BENCH), plan_path],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        self.addCleanup(lambda: worker.poll() is None and worker.kill())
        first = json.loads(worker.stdout.readline())
        self.assertTrue(first.get("running"), first)
        return worker, daemon

    def test_the_counted_storm_makes_its_ops_after_go_and_reports_them_answered(self):
        worker, daemon = self.start(ops=1000)
        self.assertEqual(sum(n for cmd, n in daemon.totals().items() if cmd != "ping"), 0, "nothing before go")
        worker.stdin.write("go\n")
        worker.stdin.flush()
        done = json.loads(worker.stdout.readline())
        self.assertTrue(done.get("paced_done"), done)
        self.assertTrue(done.get("answered"), done)
        out, err = worker.communicate(json.dumps({"window": [0, 1]}) + "\n", timeout=120)
        self.assertEqual(worker.returncode, 0, err)
        report = json.loads(out.strip().splitlines()[-1])
        sent = {kind: report[kind]["sent"] + report[kind].get("held_at_limit", 0) for kind in
                ("reorder", "move", "column", "rename")}
        self.assertEqual(sent, {"reorder": 555, "move": 111, "column": 56, "rename": 278})
        self.assertEqual(sum(report[kind]["ok"] for kind in sent), sum(report[kind]["sent"] for kind in sent))
        totals = daemon.totals()
        self.assertEqual(totals["move-workspace"], 555)
        self.assertEqual(totals["move-tab"], 111)
        self.assertEqual(totals["rename-surface"], 278)
        self.assertEqual(report["column"]["terminals_left_open"], 0)

    def test_a_stop_line_before_go_paces_nothing(self):
        worker, daemon = self.start(ops=1000)
        out, err = worker.communicate("{}\n", timeout=120)
        self.assertEqual(worker.returncode, 0, err)
        report = json.loads(out.strip().splitlines()[-1])
        self.assertEqual(sum(report[kind]["sent"] for kind in ("reorder", "move", "column", "rename")), 0)
        self.assertEqual(sum(n for cmd, n in daemon.totals().items() if cmd != "ping"), 0)


if __name__ == "__main__":
    unittest.main()
