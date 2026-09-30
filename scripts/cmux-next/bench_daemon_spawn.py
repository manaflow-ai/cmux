#!/usr/bin/env python3
"""Daemon spawn and reap bench for one cmux-tui binary (no app needed).

Starts an isolated daemon (private state dir and session), then:
  1. fires --creates concurrent `new-tab` requests into one pane, pipelined
     on ONE connection (how the app sends them) while a second connection
     measures `list-workspaces` latency (head-of-line blocking), and reports
     create latency p50/p99/max from each request's send to its reply;
  2. closes every new tab with `close-surface` (detach, as the app does) and
     measures how long until no terminal host of the storm is left: the
     daemon reaps unplaced terminals after --reap-grace seconds;
  3. ends everything with `server stop --end-terminals` and checks that no
     terminal host of this binary outlives it.

PTYs are a shared system resource (kern.tty.ptmx_max is 511 on macOS, and
every agent on the machine uses them): the bench refuses to start when the
PTYs in use plus --creates would reach --pty-limit (default 300).

Usage:
  scripts/cmux-next/bench_daemon_spawn.py --binary <cmux-tui> [--creates 96]
      [--reap-grace 30] [--label NAME] [--out FILE] [--rounds 1]
"""
import argparse
import glob
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time


def percentile(values, p):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))]


def ptys_in_use():
    """Allocated pseudo-terminals on this Mac (devfs creates /dev/ttysNNN
    while a PTY is open)."""
    return len(glob.glob("/dev/ttys[0-9]*"))


class Connection:
    def __init__(self, path, timeout=120.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buffer = b""

    def send(self, body):
        self.sock.sendall((json.dumps(body) + "\n").encode())

    def read(self):
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("daemon closed the connection")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return json.loads(line)

    def call(self, body):
        self.send(body)
        while True:
            message = self.read()
            if message.get("id") == body["id"]:
                return message

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Daemon:
    def __init__(self, binary, reap_grace):
        self.binary = os.path.abspath(binary)
        self.state = tempfile.mkdtemp(prefix="cmux-spawn-bench-")
        self.session = f"spawn-bench-{os.getpid()}"
        tmpdir = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True).stdout.strip()
        self.env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "TMPDIR": tmpdir or "/tmp",
                    "CMUX_TUI_STATE_DIR": self.state}
        self.reap_grace = reap_grace

    def cli(self, *args, timeout=120, check=True):
        out = subprocess.run([self.binary, "--session", self.session, *args], capture_output=True, text=True,
                             env=self.env, timeout=timeout)
        lines = out.stdout.strip().splitlines()
        if not lines and not check:
            return {}
        if not lines:
            raise SystemExit(f"bench: {' '.join(args)} failed: {out.stderr.strip()}")
        return json.loads(lines[-1])

    def start(self):
        # `server start` runs the owner in the foreground.
        self.process = subprocess.Popen(
            [self.binary, "--session", self.session, "server", "start",
             "--terminal-reap-grace-seconds", str(self.reap_grace)],
            env=self.env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            status = self.cli("--json", "server", "status", check=False)
            if status.get("status") == "running":
                self.socket, self.pid = status["socket"], int(status["pid"])
                return
            time.sleep(0.1)
        raise SystemExit("bench: the daemon did not start")

    def hosts(self):
        """Terminal hosts of this daemon (they run the same binary)."""
        out = subprocess.run(["pgrep", "-f", f"{self.binary} __terminal-host"], capture_output=True, text=True).stdout
        return {int(pid) for pid in out.split()}

    def stop(self):
        try:
            self.cli("--json", "server", "stop", "--end-terminals")
            self.process.wait(timeout=30)
        finally:
            shutil.rmtree(self.state, ignore_errors=True)


def first_pane(conn):
    tree = conn.call({"id": 1, "cmd": "list-workspaces"})["data"]
    if not tree.get("workspaces"):
        created = conn.call({"id": 3, "cmd": "new-workspace", "name": "bench"})
        if not created.get("ok"):
            raise SystemExit(f"bench: new-workspace failed: {created.get('error')}")
        tree = conn.call({"id": 4, "cmd": "list-workspaces"})["data"]
    for workspace in tree.get("workspaces", []):
        for screen in workspace.get("screens", []):
            for pane in screen.get("panes", []):
                return pane["id"]
    raise SystemExit("bench: the daemon has no pane")


def storm(daemon, creates):
    """Pipelined creates on one connection plus concurrent reads on another."""
    control = Connection(daemon.socket)
    pane = first_pane(control)
    reads, stop = [], threading.Event()

    def reader():
        conn = Connection(daemon.socket)
        request_id = 1000
        while not stop.is_set():
            request_id += 1
            started = time.monotonic()
            conn.call({"id": request_id, "cmd": "list-workspaces"})
            reads.append((time.monotonic() - started) * 1000)
            time.sleep(0.02)
        conn.close()

    read_thread = threading.Thread(target=reader)
    read_thread.start()
    conn = Connection(daemon.socket)
    sent = {}
    started = time.monotonic()
    for index in range(creates):
        request_id = 10 + index
        sent[request_id] = time.monotonic()
        conn.send({"id": request_id, "cmd": "new-tab", "pane": pane})
    send_seconds = time.monotonic() - started
    latencies, surfaces, errors, order = [], [], {}, []
    while len(latencies) + sum(errors.values()) < creates:
        message = conn.read()
        request_id = message.get("id")
        if request_id not in sent:
            continue
        order.append(request_id)
        if message.get("ok"):
            latencies.append((time.monotonic() - sent[request_id]) * 1000)
            surfaces.append(message["data"]["surface"])
        else:
            error = str(message.get("error"))[:120]
            errors[error] = errors.get(error, 0) + 1
    total_seconds = time.monotonic() - started
    stop.set()
    read_thread.join()
    # Tabs of one pane must land in request order.
    tab_order = []
    tree = control.call({"id": 2, "cmd": "list-workspaces"})["data"]
    for workspace in tree.get("workspaces", []):
        for screen in workspace.get("screens", []):
            for p in screen.get("panes", []):
                if p["id"] == pane:
                    tab_order = [tab.get("surface", tab.get("id")) for tab in p.get("tabs", [])]
    created_in_order = [surface for surface in tab_order if surface in set(surfaces)]
    conn.close()
    control.close()
    return {
        "creates": creates, "ok": len(latencies), "errors": errors, "send_seconds": send_seconds,
        "total_seconds": total_seconds,
        "create_ms": {"p50": percentile(latencies, 0.5), "p99": percentile(latencies, 0.99),
                      "max": max(latencies) if latencies else 0, "over_5s": sum(1 for v in latencies if v > 5000)},
        "read_ms": {"count": len(reads), "p50": percentile(reads, 0.5), "p99": percentile(reads, 0.99),
                    "max": max(reads) if reads else 0},
        "tabs_in_request_order": created_in_order == sorted(created_in_order, key=surfaces.index) if surfaces else True,
    }, surfaces


def close_and_reap(daemon, surfaces, baseline_hosts):
    conn = Connection(daemon.socket)
    started = time.monotonic()
    for index, surface in enumerate(surfaces):
        conn.send({"id": 5000 + index, "cmd": "close-surface", "surface": surface})
    replies = 0
    while replies < len(surfaces):
        if conn.read().get("id", 0) >= 5000:
            replies += 1
    close_seconds = time.monotonic() - started
    conn.close()
    limit = daemon.reap_grace + 90
    first_reap = None
    while time.monotonic() - started < limit:
        left = daemon.hosts() - baseline_hosts
        if first_reap is None and len(left) < len(surfaces):
            first_reap = time.monotonic() - started
        if not left:
            break
        time.sleep(0.1)
    left = daemon.hosts() - baseline_hosts
    return {"close_seconds": close_seconds, "grace_seconds": daemon.reap_grace,
            "first_reap_seconds": first_reap, "all_reaped_seconds": None if left else time.monotonic() - started,
            "hosts_left": len(left)}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--binary", required=True)
    parser.add_argument("--creates", type=int, default=96)
    parser.add_argument("--reap-grace", type=int, default=30)
    parser.add_argument("--rounds", type=int, default=1)
    parser.add_argument("--pty-limit", type=int, default=300)
    parser.add_argument("--label", default="spawn")
    parser.add_argument("--out")
    args = parser.parse_args()

    in_use = ptys_in_use()
    if in_use + args.creates + 2 >= args.pty_limit:
        raise SystemExit(f"bench: {in_use} PTYs in use; {args.creates} more would reach {args.pty_limit}. Refusing.")
    daemon = Daemon(args.binary, args.reap_grace)
    daemon.start()
    results = []
    try:
        first_pane(Connection(daemon.socket))
        baseline_hosts = daemon.hosts()
        print(f"bench: daemon pid {daemon.pid}, {len(baseline_hosts)} hosts, {in_use} PTYs in use", flush=True)
        for round_index in range(args.rounds):
            created, surfaces = storm(daemon, args.creates)
            print(f"round {round_index + 1} create: {json.dumps(created)}", flush=True)
            reaped = close_and_reap(daemon, surfaces, baseline_hosts)
            print(f"round {round_index + 1} reap: {json.dumps(reaped)}", flush=True)
            results.append({"create": created, "reap": reaped})
    finally:
        before_stop = daemon.hosts()
        daemon.stop()
        deadline = time.monotonic() + 10
        while daemon.hosts() & before_stop and time.monotonic() < deadline:
            time.sleep(0.1)
        leaked = sorted(daemon.hosts() & before_stop)
    version = subprocess.run([daemon.binary, "--version"], capture_output=True, text=True).stdout.strip()
    output = {"bench": "daemon-spawn", "label": args.label, "binary": daemon.binary, "version": version,
              "creates": args.creates, "rounds": results, "hosts_leaked_after_stop": leaked}
    if args.out:
        os.makedirs(os.path.dirname(os.path.abspath(args.out)), exist_ok=True)
        with open(args.out, "w") as handle:
            json.dump(output, handle, indent=2)
        print(f"wrote {args.out}")
    failed = leaked or any(r["reap"]["hosts_left"] or r["create"]["errors"] for r in results)
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
