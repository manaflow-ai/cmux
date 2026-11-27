#!/usr/bin/env python3
"""The frame pacing bench reads its numbers from the app's debug socket.

bench.sh asked `bin/cmux rpc debug.agent_pane ...` for the fling and perf
stats. On cmux-next bin/cmux is the cmux-tui binary, which has no such
command: every answer was "cmux: connect accepts one route", each result file
held that text instead of JSON, and summarize.py found no flings (cx-v9hdp).

So the bench talks to the tagged app's JSON-lines socket itself
(scripts/ci/frame-pacing/app-rpc.py). This test stands in for the app with a
socket that answers as DebugAgentPane does, then checks that what app-rpc.py
prints makes a result file summarize.py reports.
"""

from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BENCH_DIR = ROOT / "scripts" / "ci" / "frame-pacing"
APP_RPC = BENCH_DIR / "app-rpc.py"
SUMMARIZE = BENCH_DIR / "summarize.py"

FLING = {"running": False, "rows": 5000, "frames": 360, "nominal_ms": 8.33, "p50_ms": 8.33, "p95_ms": 9.1,
         "p99_ms": 12.0, "max_ms": 16.6, "dropped_frames": 2}
PERF = {"running": False, "frames": 360, "blank_frames": 0, "spans": {"row.renders": {"p50_ms": 4, "p95_ms": 9, "max_ms": 12}}}


class FakeApp:
    """A JSON-lines socket answering debug.agent_pane and action.run as the tagged app does."""

    def __init__(self, path: str) -> None:
        self.calls: list[dict] = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(path)
        self.server.listen()
        threading.Thread(target=self.serve, daemon=True).start()

    def serve(self) -> None:
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            with conn:
                line = b""
                while not line.endswith(b"\n"):
                    chunk = conn.recv(65536)
                    if not chunk:
                        break
                    line += chunk
                request = json.loads(line)
                self.calls.append(request)
                params = request.get("params", {})
                if request["method"] == "debug.agent_pane" and params.get("action") == "fling_stats":
                    result = dict(FLING, pane="agent-1")
                elif request["method"] == "debug.agent_pane" and params.get("action") == "perf_stats":
                    result = dict(PERF, pane="agent-1")
                elif request["method"] == "action.run":
                    result = {"ok": True}
                else:
                    # ControlWire's failure reply.
                    failure = {"id": request["id"], "ok": False, "error": {"code": "not_found", "message": "no agent pane"}}
                    conn.sendall((json.dumps(failure) + "\n").encode())
                    continue
                conn.sendall((json.dumps({"id": request["id"], "result": result}) + "\n").encode())

    def close(self) -> None:
        self.server.close()


def app_rpc(sock: str, method: str, params: dict) -> subprocess.CompletedProcess[str]:
    return subprocess.run([sys.executable, str(APP_RPC), sock, method, json.dumps(params)],
                          capture_output=True, text=True, check=False, timeout=30)


def test_the_bench_result_file_summarizes() -> None:
    with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
        sock = os.path.join(tmp, "app.sock")
        app = FakeApp(sock)
        try:
            fling = app_rpc(sock, "debug.agent_pane", {"action": "fling_stats"})
            perf = app_rpc(sock, "debug.agent_pane", {"action": "perf_stats"})
        finally:
            app.close()
        assert fling.returncode == 0, fling.stderr
        out = Path(tmp) / "out"
        out.mkdir()
        (out / "display.txt").write_text("ready 13 8.32 main=13\n")
        # bench.sh writes each measured fling as {"fling":<fling_stats>,"perf":<perf_stats>}.
        (out / "1-1.json").write_text('{"fling":%s,"perf":%s}\n' % (fling.stdout.strip(), perf.stdout.strip()))
        assert json.loads((out / "1-1.json").read_text())["fling"]["frames"] == 360
        summary = subprocess.run([sys.executable, str(SUMMARIZE), str(out)], capture_output=True, text=True, check=True)
        assert "360" in summary.stdout, summary.stdout


def test_a_new_chat_opens_through_the_app_action() -> None:
    with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
        sock = os.path.join(tmp, "app.sock")
        app = FakeApp(sock)
        try:
            done = app_rpc(sock, "action.run", {"action": "palette.newAgentChat"})
        finally:
            app.close()
        assert done.returncode == 0, done.stderr
        assert app.calls == [{"id": 1, "method": "action.run", "params": {"action": "palette.newAgentChat"}}]


def test_an_app_error_fails_with_its_reason() -> None:
    with tempfile.TemporaryDirectory(dir="/tmp") as tmp:
        sock = os.path.join(tmp, "app.sock")
        app = FakeApp(sock)
        try:
            failed = app_rpc(sock, "debug.agent_pane", {"action": "seed_rows"})
        finally:
            app.close()
        assert failed.returncode == 1, failed
        assert json.loads(failed.stdout)["error"]["message"] == "no agent pane"


def test_bench_sh_uses_the_app_socket_for_every_request() -> None:
    bench = (BENCH_DIR / "bench.sh").read_text(encoding="utf-8")
    assert '"$cli" rpc' not in bench and "agent new-chat" not in bench, "bench.sh still calls bin/cmux commands cmux-tui lacks"
    assert "app-rpc.py" in bench


if __name__ == "__main__":
    failures = 0
    for name, test in list(globals().items()):
        if name.startswith("test_") and callable(test):
            try:
                test()
                print(f"ok {name}")
            except Exception as error:
                failures += 1
                print(f"FAIL {name}: {type(error).__name__}: {error}")
    sys.exit(1 if failures else 0)
