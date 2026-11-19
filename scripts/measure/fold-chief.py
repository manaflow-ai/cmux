#!/usr/bin/env python3
"""Start time and idle memory of the Home Chief, base folder against head folder (fold-chief.sh, CMUX-570).

Each folder holds bin/cmux and bin/optchat-chief (a file, or a link to cmux when cmux carries the Chief). Per round
and side, in turns:
  start_ms   wall time of `optchat-chief settings show` (a short command: what each `chief` shim call costs).
  ready_ms   `optchat-chief mcp` (each turn's MCP server) from spawn to its `initialize` answer.
  idle_*_kb  /proc/PID/smaps_rollup of that MCP server 2 s after its answer, and of `optchat-chief host` 5 s after
             start (no daemon at its socket: the host waits for one), when it is still running.
Every run gets its own HOME and MUX_HOME. Lines: FOLD-SAMPLE {json} per sample, FOLD-SUMMARY {json} per metric.
"""
from __future__ import annotations

import argparse
import json
import os
import signal
import statistics
import subprocess
import tempfile
import time
from pathlib import Path

ROLLUP_KEYS = {"Rss": "idle_rss_kb", "Pss": "idle_pss_kb", "Pss_Anon": "idle_pss_anon_kb",
               "Private_Dirty": "idle_private_dirty_kb"}
INITIALIZE = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
    "protocolVersion": "2024-11-05", "capabilities": {}, "clientInfo": {"name": "fold-chief", "version": "1"}}})


def rollup(pid: int) -> dict[str, int]:
    out: dict[str, int] = {}
    for line in Path(f"/proc/{pid}/smaps_rollup").read_text().splitlines():
        key, _, rest = line.partition(":")
        if key in ROLLUP_KEYS:
            out[ROLLUP_KEYS[key]] = int(rest.split()[0])
    return out


def emit(kind: str, record: dict) -> None:
    print(f"{kind} {json.dumps(record, sort_keys=True)}", flush=True)


def stop(proc: subprocess.Popen) -> None:
    # Only the group this script started (start_new_session).
    if proc.poll() is None:
        os.killpg(proc.pid, signal.SIGTERM)
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait()


def one_round(side: str, chief: Path, samples: list[dict]) -> None:
    with tempfile.TemporaryDirectory(prefix="fold-chief-") as tmp:
        home = Path(tmp)
        mux = home / "mux"
        mux.mkdir()
        # The host refuses to start without the agent token the app hands it (host.rs conversation_source).
        token = home / "agent.token"
        token.write_text("fold-chief-measurement\n")
        env = {**os.environ, "HOME": str(home), "MUX_HOME": str(mux), "XDG_STATE_HOME": str(home / "state"),
               "MUX_AGENT_TOKEN_FILE": str(token)}
        args = [str(chief), "settings", "show", "--mux-home", str(mux)]
        t0 = time.perf_counter()
        done = subprocess.run(args, env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, check=False)
        samples.append({"side": side, "program": "optchat-chief settings", "metric": "start_ms",
                        "value": (time.perf_counter() - t0) * 1000, "exit": done.returncode})

        sock = home / "tools.sock"
        t0 = time.perf_counter()
        mcp = subprocess.Popen([str(chief), "mcp", "--socket", str(sock)], env=env, stdin=subprocess.PIPE,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, start_new_session=True, text=True)
        try:
            mcp.stdin.write(INITIALIZE + "\n")
            mcp.stdin.flush()
            answer = mcp.stdout.readline()
            ready = (time.perf_counter() - t0) * 1000
            if '"result"' in answer:
                samples.append({"side": side, "program": "optchat-chief mcp", "metric": "ready_ms", "value": ready})
                time.sleep(2)
                for metric, value in rollup(mcp.pid).items():
                    samples.append({"side": side, "program": "optchat-chief mcp", "metric": metric, "value": value})
            else:
                emit("FOLD-ERROR", {"side": side, "program": "optchat-chief mcp", "answer": answer[:200]})
        finally:
            stop(mcp)

        host = subprocess.Popen([str(chief), "host", "--daemon-socket", str(home / "daemon.sock"),
                                 "--mux-home", str(mux)], env=env, stdin=subprocess.DEVNULL,
                                stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
        try:
            time.sleep(5)
            if host.poll() is None:
                for metric, value in rollup(host.pid).items():
                    samples.append({"side": side, "program": "optchat-chief host", "metric": metric, "value": value})
            else:
                emit("FOLD-NOTE", {"side": side, "program": "optchat-chief host", "exited": host.returncode,
                                   "stderr": host.stderr.read().decode(errors="replace")[-300:]})
        finally:
            stop(host)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bin", action="append", required=True, help="LABEL=DIR")
    parser.add_argument("--rounds", type=int, default=15)
    opts = parser.parse_args()
    sides = [(label, Path(path) / "optchat-chief") for label, _, path in (b.partition("=") for b in opts.bin)]
    samples: list[dict] = []
    for _ in range(opts.rounds):
        for side, chief in sides:
            before = len(samples)
            one_round(side, chief, samples)
            for record in samples[before:]:
                emit("FOLD-SAMPLE", record)
    groups: dict[tuple[str, str, str], list[float]] = {}
    for s in samples:
        groups.setdefault((s["side"], s["program"], s["metric"]), []).append(float(s["value"]))
    for (side, program, metric), values in sorted(groups.items()):
        values.sort()
        emit("FOLD-SUMMARY", {"side": side, "program": program, "metric": metric, "n": len(values),
                              "median": statistics.median(values),
                              "p90": values[min(len(values) - 1, int(0.9 * len(values)))]})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
