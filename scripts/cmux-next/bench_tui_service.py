#!/usr/bin/env python3
"""Cost of the cmux-tui service (`cmux-tui --headless`) per terminal (perf100 tui lane).

Starts one isolated headless daemon (private socket, state and config) and runs
the perf100 scenarios that need no app and no browser:

  S0  idle:  --terminals idle `cat` terminals (default 10), --attach of them
             attached the way the app attaches a visible terminal, plus one
             event subscription. Measures threads, RSS, CPU and context
             switches of the daemon and of every terminal host over --idle
             seconds.
  S1  flood: one terminal, then --flood-many at once, each writing
             --flood-bytes (default 200 MB) with `yes | head -c N`, one
             attach per flooding terminal draining its stream. Measures
             wall time, CPU seconds of the daemon and the hosts, and bytes the
             daemon wrote to the attach sockets.
  S3  scale: --scale-terminals terminals in --scale-workspaces workspaces;
             threads and RSS per terminal.

Thread and memory numbers come from /proc on Linux and from ps/proc_pidinfo
(through `ps -M` and `ps -o rss`) on macOS. Run it on rbx or a fleet host,
never on a laptop.

Usage:
  bench_tui_service.py --binary target/release/cmux-tui [--label NAME]
      [--scenarios S0,S1,S3] [--out FILE.json]
"""
import argparse
import json
import os
import platform
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

LINUX = platform.system() == "Linux"
HZ = os.sysconf("SC_CLK_TCK") if LINUX else 100


class Connection:
    def __init__(self, path, timeout=600.0):
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
                if not message.get("ok"):
                    raise SystemExit(f"bench: {body['cmd']} failed: {message.get('error')}")
                return message.get("data")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


class Drain:
    """A long-lived stream (attach or subscribe): the reply, then a thread
    that counts every byte the daemon sends until the socket closes."""

    def __init__(self, path, body):
        self.conn = Connection(path)
        self.conn.call(body)
        self.bytes = len(self.conn.buffer)
        self.lines = []
        self.keep_lines = body["cmd"] == "subscribe"
        self.cond = threading.Condition()
        self.thread = threading.Thread(target=self.run, daemon=True)
        self.thread.start()

    def run(self):
        pending = self.conn.buffer
        while True:
            try:
                chunk = self.conn.sock.recv(1 << 20)
            except OSError:
                return
            if not chunk:
                return
            with self.cond:
                self.bytes += len(chunk)
                if self.keep_lines:
                    pending += chunk
                    *lines, pending = pending.split(b"\n")
                    for line in lines:
                        try:
                            self.lines.append(json.loads(line))
                        except ValueError:
                            pass
                    self.cond.notify_all()

    def wait_for(self, predicate, timeout):
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                found = [event for event in self.lines if predicate(event)]
                if found:
                    return found
                left = deadline - time.monotonic()
                if left <= 0:
                    return []
                self.cond.wait(left)

    def close(self):
        self.conn.close()


def ps_threads(pid):
    if LINUX:
        try:
            return len(os.listdir(f"/proc/{pid}/task"))
        except OSError:
            return 0
    out = subprocess.run(["ps", "-M", "-p", str(pid)], capture_output=True, text=True).stdout
    return max(0, len(out.strip().splitlines()) - 1)


def ps_rss_kb(pid):
    if LINUX:
        try:
            for line in open(f"/proc/{pid}/status"):
                if line.startswith("VmRSS:"):
                    return int(line.split()[1])
        except OSError:
            return 0
        return 0
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out or 0)


def ps_pss_kb(pid):
    """Proportional set size (shared pages split among sharers); Linux only."""
    if not LINUX:
        return None
    try:
        for line in open(f"/proc/{pid}/smaps_rollup"):
            if line.startswith("Pss:"):
                return int(line.split()[1])
    except OSError:
        return None
    return None


def reaped_children_cpu(pid):
    """CPU seconds of a process's children it has waited for (Linux):
    terminal hosts that exited during a scenario count here."""
    if not LINUX:
        return 0.0
    try:
        stat = open(f"/proc/{pid}/stat").read()
    except OSError:
        return 0.0
    fields = stat[stat.rfind(")") + 2:].split(" ")
    return (int(fields[13]) + int(fields[14])) / HZ


def cpu_and_switches(pid):
    """(cpu seconds, context switches) of a process, all threads."""
    if LINUX:
        try:
            stat = open(f"/proc/{pid}/stat").read()
        except OSError:
            return 0.0, 0
        fields = stat[stat.rfind(")") + 2:].split(" ")
        cpu = (int(fields[11]) + int(fields[12])) / HZ
        switches = 0
        try:
            for task in os.listdir(f"/proc/{pid}/task"):
                try:
                    for line in open(f"/proc/{pid}/task/{task}/status"):
                        if "ctxt_switches:" in line:
                            switches += int(line.split()[1])
                except OSError:
                    pass
        except OSError:
            pass
        return cpu, switches
    out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    cpu = 0.0
    if out:
        parts = out.replace("-", ":").split(":")
        for part in parts:
            cpu = cpu * 60 + float(part)
    return cpu, 0


def children(pid):
    if LINUX:
        found = []
        for entry in os.listdir("/proc"):
            if not entry.isdigit():
                continue
            try:
                stat = open(f"/proc/{entry}/stat").read()
            except OSError:
                continue
            if int(stat[stat.rfind(")") + 2:].split(" ")[1]) == pid:
                found.append(int(entry))
        return found
    out = subprocess.run(["pgrep", "-P", str(pid)], capture_output=True, text=True).stdout.split()
    return [int(value) for value in out]


class Daemon:
    def __init__(self, binary):
        self.binary = os.path.abspath(binary)
        self.dir = tempfile.mkdtemp(prefix="cmux-tui-bench-", dir="/tmp")
        self.socket = os.path.join(self.dir, "mux.sock")
        self.state = os.path.join(self.dir, "state")
        settings = os.path.join(self.dir, "cmux-next.json")
        with open(settings, "w") as handle:
            handle.write("{}\n")
        env = {"HOME": os.environ.get("HOME", "/tmp"), "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp",
               "CMUX_TUI_CONFIG": os.path.join(self.dir, "config.json"), "CMUX_NEXT_CONFIG_FILE": settings,
               "SHELL": "/bin/sh", "TERM": "xterm-256color"}
        started = time.monotonic()
        self.process = subprocess.Popen(
            [self.binary, "--headless", "--socket", self.socket, "--state", self.state],
            env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        deadline = started + 30
        while True:
            try:
                Connection(self.socket).close()
                break
            except OSError:
                if time.monotonic() > deadline:
                    raise SystemExit("bench: the daemon did not open its socket")
                time.sleep(0.01)
        self.startup_s = time.monotonic() - started
        self.pid = self.process.pid
        self.control = Connection(self.socket)
        self.next_id = 100

    def call(self, cmd, **fields):
        self.next_id += 1
        return self.control.call({"id": self.next_id, "cmd": cmd, **fields})

    def run_terminal(self, argv, name, workspace=None):
        fields = {"argv": argv, "name": name}
        if workspace is None:
            fields["new_workspace"] = True
        else:
            fields["workspace"] = workspace
        return self.call("run", **fields)

    def surfaces(self):
        tree = self.call("list-workspaces")
        found = []
        for workspace in tree.get("workspaces", []):
            for screen in workspace.get("screens", []):
                for pane in screen.get("panes", []):
                    for tab in pane.get("tabs", []):
                        if tab.get("surface") is not None:
                            found.append((workspace.get("key"), tab["surface"], tab.get("name")))
        return found

    def hosts(self):
        return children(self.pid)

    def snapshot(self):
        hosts = self.hosts()
        return {
            "daemon_threads": ps_threads(self.pid),
            "daemon_rss_kb": ps_rss_kb(self.pid),
            "daemon_pss_kb": ps_pss_kb(self.pid),
            "hosts": len(hosts),
            "host_threads": sum(ps_threads(pid) for pid in hosts),
            "host_rss_kb": sum(ps_rss_kb(pid) for pid in hosts),
            "host_pss_kb": sum((ps_pss_kb(pid) or 0) for pid in hosts) if LINUX else None,
        }

    def usage(self):
        hosts = self.hosts()
        daemon = cpu_and_switches(self.pid)
        host = [cpu_and_switches(pid) for pid in hosts]
        # Live hosts plus hosts that exited and were reaped by the daemon.
        return {"daemon_cpu": daemon[0], "daemon_switches": daemon[1],
                "host_cpu": sum(value[0] for value in host) + reaped_children_cpu(self.pid),
                "host_switches": sum(value[1] for value in host)}

    def stop(self):
        try:
            for key in {key for key, _, _ in self.surfaces()}:
                try:
                    self.call("close-workspace", key=key, end_terminals=True)
                except (SystemExit, OSError):
                    pass
        except (SystemExit, OSError):
            pass
        hosts = self.hosts()
        deadline = time.monotonic() + 20
        while any(os.path.exists(f"/proc/{pid}") if LINUX else subprocess.run(
                ["kill", "-0", str(pid)], capture_output=True).returncode == 0 for pid in hosts):
            if time.monotonic() > deadline:
                break
            time.sleep(0.05)
        for pid in hosts:
            try:
                os.kill(pid, 9)
            except OSError:
                pass
        self.control.close()
        self.process.kill()
        self.process.wait()
        shutil.rmtree(self.dir, ignore_errors=True)


def delta(before, after):
    return {key: round(after[key] - before[key], 3) for key in before}


def scenario_s0(binary, terminals, attach, idle):
    daemon = Daemon(binary)
    try:
        empty = daemon.snapshot()
        for index in range(terminals):
            daemon.run_terminal(["/bin/cat"], f"idle-{index}")
        surfaces = [surface for _, surface, _ in daemon.surfaces()]
        events = Drain(daemon.socket, {"id": 1, "cmd": "subscribe"})
        streams = [Drain(daemon.socket, {"id": 2, "cmd": "attach-surface", "surface": surface,
                                         "cols": 120, "rows": 40}) for surface in surfaces[:attach]]
        time.sleep(3)  # bench settle; not product synchronization
        loaded = daemon.snapshot()
        before = daemon.usage()
        time.sleep(idle)
        after = daemon.usage()
        result = {"startup_s": round(daemon.startup_s, 3), "empty": empty, "loaded": loaded,
                  "idle_window_s": idle, "idle": delta(before, after),
                  "per_terminal": {
                      "daemon_threads": (loaded["daemon_threads"] - empty["daemon_threads"]) / max(1, terminals),
                      "daemon_rss_kb": (loaded["daemon_rss_kb"] - empty["daemon_rss_kb"]) / max(1, terminals),
                      "host_threads": loaded["host_threads"] / max(1, loaded["hosts"]),
                      "host_rss_kb": loaded["host_rss_kb"] / max(1, loaded["hosts"]),
                  }}
        for stream in streams:
            stream.close()
        events.close()
        return result
    finally:
        daemon.stop()


def flood(daemon, count, flood_bytes, timeout):
    events = Drain(daemon.socket, {"id": 1, "cmd": "subscribe"})
    # Start each flood gated on a fifo so every attach is in place first.
    gates = []
    surfaces = []
    for index in range(count):
        gate = os.path.join(daemon.dir, f"gate-{index}")
        os.mkfifo(gate)
        gates.append(gate)
        daemon.run_terminal(["/bin/sh", "-c", f"read _ < {gate}; yes | head -c {flood_bytes}"], f"flood-{index}")
    for _, surface, name in daemon.surfaces():
        if name and name.startswith("flood-"):
            surfaces.append(surface)
    streams = [Drain(daemon.socket, {"id": 2, "cmd": "attach-surface", "surface": surface, "cols": 120,
                                     "rows": 40}) for surface in surfaces]
    time.sleep(1)  # bench settle
    before = daemon.usage()
    sent_before = sum(stream.bytes for stream in streams)
    started = time.monotonic()
    for gate in gates:
        with open(gate, "w") as handle:
            handle.write("go\n")
    ended = events.wait_for(lambda event: event.get("event") == "surface-exited" and event.get("surface") in surfaces,
                            timeout)
    deadline = time.monotonic() + timeout
    while len({event["surface"] for event in ended}) < len(surfaces) and time.monotonic() < deadline:
        ended = events.wait_for(
            lambda event: event.get("event") == "surface-exited" and event.get("surface") in surfaces, 1)
        if len({event["surface"] for event in ended}) >= len(surfaces):
            break
    wall = time.monotonic() - started
    after = daemon.usage()
    attach_bytes = sum(stream.bytes for stream in streams) - sent_before
    peak = daemon.snapshot()
    for stream in streams:
        stream.close()
    events.close()
    used = delta(before, after)
    total = flood_bytes * count
    return {"terminals": count, "bytes": total, "wall_s": round(wall, 3),
            "exited": len({event["surface"] for event in ended}), "usage": used,
            "daemon_cpu_ns_per_byte": round(used["daemon_cpu"] * 1e9 / total, 3),
            "host_cpu_ns_per_byte": round(used["host_cpu"] * 1e9 / total, 3),
            "attach_bytes": attach_bytes, "after": peak}


def scenario_s1(binary, flood_bytes, many, timeout):
    results = {}
    for label, count in (("one", 1), ("many", many)):
        daemon = Daemon(binary)
        try:
            results[label] = flood(daemon, count, flood_bytes, timeout)
        finally:
            daemon.stop()
    return results


def scenario_s3(binary, terminals, workspaces):
    daemon = Daemon(binary)
    try:
        empty = daemon.snapshot()
        started = time.monotonic()
        keys = []
        for index in range(terminals):
            if index < workspaces:
                created = daemon.run_terminal(["/bin/cat"], f"scale-{index}")
                keys.append(created.get("workspace_key") or created.get("workspace"))
            else:
                target = keys[index % workspaces]
                if target is None:
                    daemon.run_terminal(["/bin/cat"], f"scale-{index}")
                else:
                    daemon.run_terminal(["/bin/cat"], f"scale-{index}", workspace=target)
        create_s = time.monotonic() - started
        time.sleep(3)  # bench settle
        loaded = daemon.snapshot()
        before = daemon.usage()
        time.sleep(10)
        after = daemon.usage()
        return {"terminals": terminals, "workspaces": workspaces, "create_s": round(create_s, 3),
                "empty": empty, "loaded": loaded, "idle_10s": delta(before, after),
                "per_terminal": {
                    "daemon_threads": (loaded["daemon_threads"] - empty["daemon_threads"]) / terminals,
                    "daemon_rss_kb": (loaded["daemon_rss_kb"] - empty["daemon_rss_kb"]) / terminals,
                    "host_threads": loaded["host_threads"] / max(1, loaded["hosts"]),
                    "host_rss_kb": loaded["host_rss_kb"] / max(1, loaded["hosts"]),
                }}
    finally:
        daemon.stop()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True)
    parser.add_argument("--label", default="run")
    parser.add_argument("--scenarios", default="S0,S1,S3")
    parser.add_argument("--terminals", type=int, default=10)
    parser.add_argument("--attach", type=int, default=10)
    parser.add_argument("--idle", type=float, default=60)
    parser.add_argument("--flood-bytes", type=int, default=200_000_000)
    parser.add_argument("--flood-many", type=int, default=10)
    parser.add_argument("--flood-timeout", type=float, default=600)
    parser.add_argument("--scale-terminals", type=int, default=1000)
    parser.add_argument("--scale-workspaces", type=int, default=200)
    parser.add_argument("--out")
    args = parser.parse_args()
    wanted = {name.strip().upper() for name in args.scenarios.split(",")}
    report = {"label": args.label, "binary": args.binary, "host": platform.node(), "os": platform.platform()}
    if "S0" in wanted:
        report["S0"] = scenario_s0(args.binary, args.terminals, args.attach, args.idle)
        print(json.dumps({"S0": report["S0"]}), flush=True)
    if "S1" in wanted:
        report["S1"] = scenario_s1(args.binary, args.flood_bytes, args.flood_many, args.flood_timeout)
        print(json.dumps({"S1": report["S1"]}), flush=True)
    if "S3" in wanted:
        report["S3"] = scenario_s3(args.binary, args.scale_terminals, args.scale_workspaces)
        print(json.dumps({"S3": report["S3"]}), flush=True)
    text = json.dumps(report, indent=2)
    if args.out:
        with open(args.out, "w") as handle:
            handle.write(text + "\n")
    print(text)


if __name__ == "__main__":
    sys.exit(main())
