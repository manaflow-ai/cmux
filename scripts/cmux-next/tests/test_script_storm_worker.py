"""script-storm-bench.py --storm-worker against a fake session daemon (no app): the column load's terminal ledger, the
per-kind connections and the PTY hold.

  python3 -I scripts/cmux-next/tests/test_script_storm_worker.py
"""
import collections
import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path

BENCH = Path(__file__).resolve().parents[1] / "script-storm-bench.py"
# Runs the worker with the host's PTY count fixed, so the result does not depend on the PTYs other agents hold.
BOOT = ("import sys, runpy; sys.path.insert(0, sys.argv[1].rsplit('/', 1)[0]); import bench_cli_storm; "
        "count = int(sys.argv[3]); bench_cli_storm.ptys_in_use = lambda: count; "
        "sys.argv = [sys.argv[1], '--storm-worker', sys.argv[2]]; runpy.run_path(sys.argv[0], run_name='__main__')")
CREATES = ("new-pane-right", "new-row")


class FakeDaemon:
    """Answers each JSON line ok; a create gets `data.surface`; counts commands per connection and live surfaces."""

    def __init__(self, path):
        self.lock = threading.Lock()
        self.connections, self.live, self.peak, self.bad, self.next_surface = [], set(), 0, [], 1000
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
            threading.Thread(target=self.serve, args=(conn, counts), daemon=True).start()

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
                    if cmd in CREATES:
                        reply["data"] = {"surface": self.next_surface}
                        self.live.add(self.next_surface)
                        self.next_surface += 1
                        self.peak = max(self.peak, len(self.live))
                    elif cmd == "close-tabs":
                        for surface in message.get("surfaces") or []:
                            if surface not in self.live or not message.get("end_terminals"):
                                self.bad.append(message)
                            self.live.discard(surface)
                conn.sendall((json.dumps(reply) + "\n").encode())

    def close(self):
        self.server.close()


class StormWorkerTests(unittest.TestCase):
    def storm(self, ptys_in_use, seconds=2.0):
        directory = tempfile.mkdtemp(prefix="storm-", dir="/tmp")  # a short path: AF_UNIX paths stop at 104 bytes
        path = os.path.join(directory, "d.sock")
        daemon = FakeDaemon(path)
        self.addCleanup(daemon.close)
        background = [{"handle": 10 + i, "panes": [100 + 2 * i, 101 + 2 * i], "spare": 500 + i,
                       "tabs": [500 + i, 600 + i], "tab_ids": [f"t{i}a", f"t{i}b"]} for i in range(3)]
        plan = {"daemon": path, "control": path, "rates": {"column": 100.0, "move": 50.0}, "background": background,
                "workspaces": 4, "live_columns": 2, "max_live_terminals": 4, "max_inflight": 512}
        plan_path = os.path.join(directory, "plan.json")
        with open(plan_path, "w") as handle:
            json.dump(plan, handle)
        worker = subprocess.Popen([sys.executable, "-I", "-c", BOOT, str(BENCH), plan_path, str(ptys_in_use)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        first = json.loads(worker.stdout.readline())
        self.assertTrue(first.get("running"), first)
        start = time.clock_gettime(time.CLOCK_UPTIME_RAW)
        time.sleep(seconds)  # the storm's length
        end = time.clock_gettime(time.CLOCK_UPTIME_RAW)
        out, err = worker.communicate(json.dumps({"window": [start, end]}) + "\n", timeout=120)
        self.assertEqual(worker.returncode, 0, err)
        return json.loads(out.strip().splitlines()[-1]), daemon

    def test_column_ledger_closes_every_terminal_it_made(self):
        report, daemon = self.storm(ptys_in_use=10)
        column = report["column"]
        self.assertGreater(column["creates_ok"], 0)
        self.assertEqual(column["creates_ok"], column["closes_ok"])
        self.assertEqual(column["terminals_left_open"], 0)
        self.assertEqual(daemon.live, set())
        self.assertLessEqual(daemon.peak, 4)
        self.assertEqual(daemon.bad, [])

    def test_each_kind_counts_its_own_connection(self):
        report, daemon = self.storm(ptys_in_use=10)
        kinds = [set(counts) - {"ping"} for counts in daemon.connections]
        self.assertEqual(len(kinds), 2)
        moves = next(c for c in daemon.connections if "move-tab" in c)
        columns = next(c for c in daemon.connections if "move-tab" not in c)
        self.assertEqual(set(columns) - {"ping"}, {"new-pane-right", "new-row", "close-tabs"})
        self.assertEqual(report["move"]["ok"], moves["move-tab"])
        self.assertEqual(report["column"]["ok"] + report["column"]["closes_at_end"],
                         sum(n for cmd, n in columns.items() if cmd != "ping"))
        self.assertEqual(report["column"]["creates_ok"], columns["new-pane-right"] + columns["new-row"])
        self.assertGreaterEqual(report["move"]["window"]["applied_per_s"], 45)

    def test_column_creates_take_turns_between_new_column_and_new_row(self):
        _, daemon = self.storm(ptys_in_use=10)
        columns = next(c for c in daemon.connections if "move-tab" not in c)
        self.assertLessEqual(abs(columns["new-pane-right"] - columns["new-row"]), 1, dict(columns))

    def test_no_create_when_the_host_ptys_are_at_the_limit(self):
        sys.path.insert(0, str(BENCH.parent))
        from bench_cli_storm import MAX_PTY_LIMIT
        report, daemon = self.storm(ptys_in_use=MAX_PTY_LIMIT - 1, seconds=1.0)
        column = report["column"]
        self.assertEqual(column["creates_ok"], 0)
        self.assertGreater(column["creates_held_at_pty_limit"], 0)
        self.assertEqual(column["terminals_left_open"], 0)
        self.assertEqual(daemon.peak, 0)


if __name__ == "__main__":
    unittest.main()
