#!/usr/bin/env python3
"""What one more idle agent chat costs in acpmux, on Linux (CMUX-571 memory-per-chat; Leo, 2026-11-12: "Infinite
everything feels like nothing").

The perf cron's memory-agents part (memory-agents-cron.py) measures the whole Mac app with N idle chats on the acpmux
test agent; this measures acpmux's share of it with nothing else: one isolated daemon (its own ACPMUX_HOME, socket and
config) running tests/fake_agent.py, COUNTS chats each made, answered once and attached the way the app keeps an open
chat, and at each count, after --settle seconds:
  daemon MB        the daemon's proportional set size (/proc/PID/smaps_rollup Pss) and RSS;
  ours MB          every process the daemon started from the acpmux binary (agent hosts, tool servers) besides it;
  agent MB         the harnesses (fake_agent.py under python3): the agent's own, not ours, reported apart;
  per chat         (count's MB - first count's MB) / (count - first count), for the daemon and for ours.
Then it waits until the idle harnesses hibernate (ACPMUX_IDLE_CHILD_SECS, --idle-child) and samples again
(`hibernated`): what an idle chat costs once its agent is gone, the steady state of a chat left open.

  bench_acpmux_chat_memory.py --binary PATH/acpmux [--counts 1,10] [--settle 20] [--idle-child 30] [--out FILE]

Linux only (it reads /proc). Prints PERF_ROW lines (acpmux_chat_memory.*).
"""
from __future__ import annotations

import argparse
import itertools
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
FAKE_AGENT = os.path.join(ROOT, "cmux-tui/crates/acpmux/tests/fake_agent.py")
ATTACH_KINDS = ["transcript", "available_commands_update", "usage_update", "config_option_update", "bookmarks",
                "queue_order", "queue_updated", "prompt_refused"]
MB = 1048576.0


class Rpc:
    """One newline-delimited JSON-RPC connection to the daemon."""

    def __init__(self, path: str):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(120)
        self.sock.connect(path)
        self.buffer = b""
        self.ids = itertools.count(1)

    def call(self, method: str, params: dict):
        ident = next(self.ids)
        self.sock.sendall((json.dumps({"jsonrpc": "2.0", "id": ident, "method": method, "params": params}) + "\n").encode())
        while True:
            while b"\n" not in self.buffer:
                chunk = self.sock.recv(1 << 20)
                if not chunk:
                    raise ConnectionError(f"the daemon closed the socket during {method}")
                self.buffer += chunk
            line, self.buffer = self.buffer.split(b"\n", 1)
            try:
                value = json.loads(line)
            except ValueError:
                continue
            if value.get("id") == ident:
                if value.get("error"):
                    raise RuntimeError(f"{method} failed: {value['error']}")
                return value.get("result")

    def drain(self):
        """Keep the connection open and drop what the daemon pushes, as the app's open chat does."""
        def run():
            self.sock.settimeout(None)
            try:
                while self.sock.recv(1 << 20):
                    pass
            except OSError:
                pass
        thread = threading.Thread(target=run, daemon=True)
        thread.start()
        return thread


def proc_table() -> list[tuple[int, int, str]]:
    rows = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open(f"/proc/{name}/stat") as f:
                stat = f.read()
            with open(f"/proc/{name}/cmdline", "rb") as f:
                cmd = f.read().replace(b"\0", b" ").decode(errors="replace").strip()
        except OSError:
            continue
        ppid = int(stat.rsplit(")", 1)[1].split()[1])
        rows.append((int(name), ppid, cmd))
    return rows


def descendants(root: int, table: list[tuple[int, int, str]]) -> dict[int, str]:
    found = {root}
    while True:
        more = {pid for pid, ppid, _ in table if ppid in found} - found
        if not more:
            break
        found |= more
    return {pid: cmd for pid, _, cmd in table if pid in found}


def memory(pid: int) -> tuple[float, float] | None:
    """(Pss MB, Rss MB) from /proc/PID/smaps_rollup, or None once the process is gone."""
    try:
        with open(f"/proc/{pid}/smaps_rollup") as f:
            text = f.read()
    except OSError:
        return None
    values = {}
    for line in text.splitlines():
        parts = line.split()
        if len(parts) >= 2 and parts[0] in ("Pss:", "Rss:"):
            values[parts[0]] = int(parts[1]) * 1024 / MB
    return values.get("Pss:", 0.0), values.get("Rss:", 0.0)


def classify(pid: int, cmd: str, daemon: int, binary: str) -> str:
    """daemon, ours (any other process of the acpmux binary) or agent (the harness and what it runs)."""
    if pid == daemon:
        return "daemon"
    if cmd.startswith(binary) or os.path.basename(cmd.split(" ", 1)[0]) == "acpmux":
        return "ours"
    return "agent"


def sample(daemon: int, binary: str, label: str, chats: int) -> dict:
    groups: dict[str, dict] = {}
    processes = []
    for pid, cmd in descendants(daemon, proc_table()).items():
        got = memory(pid)
        if got is None:
            continue
        kind = classify(pid, cmd, daemon, binary)
        entry = groups.setdefault(kind, {"count": 0, "pss_mb": 0.0, "rss_mb": 0.0})
        entry["count"] += 1
        entry["pss_mb"] = round(entry["pss_mb"] + got[0], 2)
        entry["rss_mb"] = round(entry["rss_mb"] + got[1], 2)
        processes.append({"pid": pid, "kind": kind, "pss_mb": round(got[0], 2), "rss_mb": round(got[1], 2),
                          "command": cmd[:160]})
    for kind in ("daemon", "ours", "agent"):
        groups.setdefault(kind, {"count": 0, "pss_mb": 0.0, "rss_mb": 0.0})
    return {"label": label, "chats": chats, "time": round(time.time(), 1), "groups": groups,
            "processes": sorted(processes, key=lambda p: -p["pss_mb"])}


def per_chat(samples: list[dict], prefix: str) -> dict:
    """Each group's Pss growth per chat from the first to the last sample of `prefix` (pure)."""
    picked = [s for s in samples if s["label"].startswith(prefix)]
    if len(picked) < 2 or picked[-1]["chats"] == picked[0]["chats"]:
        return {}
    first, last = picked[0], picked[-1]
    span = last["chats"] - first["chats"]
    return {kind: round((last["groups"][kind]["pss_mb"] - first["groups"][kind]["pss_mb"]) / span, 2)
            for kind in ("daemon", "ours", "agent")}


def wait_ready(proc: subprocess.Popen, timeout: float = 60) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        line = proc.stdout.readline()
        if not line:
            break
        try:
            if json.loads(line).get("ready") is True:
                return
        except ValueError:
            continue
    raise SystemExit("bench-acpmux-chat-memory: the daemon gave no readiness line")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", required=True, help="the acpmux binary")
    parser.add_argument("--counts", default="1,10")
    parser.add_argument("--settle", type=float, default=20)
    parser.add_argument("--idle-child", type=int, default=30,
                        help="ACPMUX_IDLE_CHILD_SECS: when an idle chat's harness hibernates (the app's is 120)")
    parser.add_argument("--out")
    args = parser.parse_args(argv)
    if not sys.platform.startswith("linux"):
        raise SystemExit("bench-acpmux-chat-memory: Linux only (it reads /proc)")
    binary = os.path.realpath(args.binary)
    counts = sorted({int(n) for n in args.counts.split(",") if n.strip()})
    scratch = tempfile.mkdtemp(prefix="acpmux-chat-mem-")
    home, work = os.path.join(scratch, "home"), os.path.join(scratch, "work")
    os.makedirs(home, mode=0o700)
    os.makedirs(work)
    with open(os.path.join(home, "config.json"), "w") as f:
        json.dump({"harnesses": {"fake": {"argv": [sys.executable, FAKE_AGENT]}}, "defaultHarness": "fake",
                   "permissionPolicy": "approve-all"}, f)
    sock_path = os.path.join(scratch, "s.sock")
    env = {k: v for k, v in os.environ.items() if not k.startswith("ACPMUX_")}
    env.update(ACPMUX_HOME=home, ACPMUX_SOCKET=sock_path, ACPMUX_IDLE_CHILD_SECS=str(args.idle_child))
    daemon = subprocess.Popen([binary, "daemon", "run", "--ready-fd", "1", "--log", "warn"], env=env,
                              stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True,
                              start_new_session=True)
    report = {"binary": binary, "counts": counts, "settle_s": args.settle, "idle_child_s": args.idle_child, "samples": []}
    keep = []
    try:
        wait_ready(daemon)
        app = Rpc(sock_path)
        app.call("initialize", {"protocolVersion": 1})
        app.call("_acpmux/watch", {"enabled": True})
        app.call("_acpmux/chats_watch", {"enabled": True})
        keep.append(app.drain())
        made = 0
        last_turn = time.monotonic()
        for count in counts:
            while made < count:
                rpc = Rpc(sock_path)
                rpc.call("initialize", {"protocolVersion": 1})
                session = rpc.call("session/new", {"cwd": work, "mcpServers": []})["sessionId"]
                ended = rpc.call("session/prompt", {"sessionId": session,
                                                    "prompt": [{"type": "text", "text": f"memory bench chat {made}"}]})
                if not isinstance(ended, dict) or "stopReason" not in ended:
                    raise SystemExit(f"bench-acpmux-chat-memory: chat {made}'s turn did not end: {ended}")
                rpc.call("_acpmux/attach", {"sessionId": session, "limit": 400, "maxBytes": 128 * 1024,
                                            "kinds": ATTACH_KINDS, "eventStream": True, "visible": made == 0})
                keep.append(rpc.drain())
                made += 1
                last_turn = time.monotonic()
            time.sleep(args.settle)  # bench: let the daemon settle after the count's last turn
            report["samples"].append(sample(daemon.pid, binary, f"open-{count}", count))
        # Every harness hibernates once it has been idle --idle-child seconds; give it that and a margin.
        time.sleep(max(0.0, last_turn + args.idle_child + 15 - time.monotonic()))  # bench: the hibernation deadline
        report["samples"].append(sample(daemon.pid, binary, f"hibernated-{made}", made))
    finally:
        try:
            os.killpg(daemon.pid, 15)
        except ProcessLookupError:
            pass
        try:
            daemon.wait(timeout=20)
        except subprocess.TimeoutExpired:
            os.killpg(daemon.pid, 9)
            daemon.wait(timeout=10)
        shutil.rmtree(scratch, ignore_errors=True)
    report["per_chat_open"] = per_chat(report["samples"], "open-")
    # Hibernated chats against the first open count: an upper bound of a hibernated chat's cost (the base still had
    # its first chat's harness and host up).
    opened = [s for s in report["samples"] if s["label"].startswith("open-")]
    slept = [s for s in report["samples"] if s["label"].startswith("hibernated-")]
    if opened and slept and slept[-1]["chats"] > opened[0]["chats"]:
        span = slept[-1]["chats"] - opened[0]["chats"]
        report["per_chat_hibernated"] = {
            kind: round((slept[-1]["groups"][kind]["pss_mb"] - opened[0]["groups"][kind]["pss_mb"]) / span, 2)
            for kind in ("daemon", "ours", "agent")}
    rows = []
    for s in report["samples"]:
        for kind, entry in s["groups"].items():
            rows.append({"name": f"acpmux_chat_memory.{s['label']}.{kind}_pss_mb", "p50": entry["pss_mb"],
                         "p95": entry["pss_mb"], "unit": "MB"})
    for kind, value in report["per_chat_open"].items():
        rows.append({"name": f"acpmux_chat_memory.per_chat_open.{kind}_pss_mb", "p50": value, "p95": value, "unit": "MB"})
    for kind, value in (report.get("per_chat_hibernated") or {}).items():
        rows.append({"name": f"acpmux_chat_memory.per_chat_hibernated.{kind}_pss_mb", "p50": value, "p95": value,
                     "unit": "MB"})
    report["rows"] = rows
    for s in report["samples"]:
        g = s["groups"]
        print(f"acpmux-chat-memory {s['label']}: daemon {g['daemon']['pss_mb']} MB, ours {g['ours']['pss_mb']} MB "
              f"({g['ours']['count']} procs), agent {g['agent']['pss_mb']} MB ({g['agent']['count']} procs)")
        for p in s["processes"][:6]:
            print(f"    {p['pss_mb']:>8.2f} MB  {p['kind']:<6} {p['command'][:100]}")
    print(f"acpmux-chat-memory per chat (open): {json.dumps(report['per_chat_open'])}; "
          f"hibernated: {json.dumps(report.get('per_chat_hibernated'))}")
    for row in rows:
        print("PERF_ROW " + json.dumps(row))
    if args.out:
        with open(args.out, "w") as f:
            json.dump(report, f, indent=1)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
