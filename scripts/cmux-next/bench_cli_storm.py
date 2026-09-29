#!/usr/bin/env python3
"""CLI storm bench driver. Run through scripts/cmux-next/bench-cli-storm.sh."""
import argparse
import base64
import json
import os
import random
import socket
import subprocess
import sys
import threading
import time
import zlib

DEADLINE_S = 2.0
CLIENT_TIMEOUT_S = DEADLINE_S + 3.0


class Client:
    """One JSON Lines connection (like the cmux CLI)."""

    def __init__(self, path, timeout=CLIENT_TIMEOUT_S):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buffer = b""
        self.next_id = 1

    def call(self, method, params=None, cmd_key="method"):
        request_id = self.next_id
        self.next_id += 1
        body = {"id": request_id, cmd_key: method}
        if cmd_key == "method":
            body["params"] = params or {}
        else:
            body.update(params or {})
        self.sock.sendall((json.dumps(body) + "\n").encode())
        while True:
            line = self.readline()
            message = json.loads(line)
            # Daemon connections also carry events; skip them.
            if "event" in message and "id" not in message:
                continue
            return message

    def readline(self):
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("socket closed")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        return line

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def ok(response):
    return bool(response.get("ok"))


def result(response):
    if not ok(response):
        raise RuntimeError(json.dumps(response.get("error")))
    return response.get("result") or response.get("data") or {}


def rss_kb(pid):
    out = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return int(out) if out else 0


def app_bundle(pid):
    out = subprocess.run(["ps", "-o", "comm=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    marker = ".app/"
    return out[: out.index(marker) + 4] if marker in out else None


def percentile(values, p):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))]


class NextProfile:
    """cmux-next control socket (snapshot.get, action.run, debug.*)."""

    name = "next"

    def __init__(self, socket_path):
        self.socket_path = socket_path

    def topology(self, client):
        return result(client.call("snapshot.get"))["topology"]

    @staticmethod
    def focus(topology):
        return topology.get("focus") or {}

    @staticmethod
    def tabs_in(topology, pane_id):
        for workspace in topology.get("workspaces", []):
            for screen in workspace.get("screens", []):
                for pane in screen.get("panes", []):
                    if pane["id"] == pane_id:
                        return [tab["id"] for tab in pane.get("tabs", [])]
        return []

    @staticmethod
    def tab(topology, tab_id):
        for workspace in topology.get("workspaces", []):
            for screen in workspace.get("screens", []):
                for pane in screen.get("panes", []):
                    for tab in pane.get("tabs", []):
                        if tab["id"] == tab_id:
                            return tab
        return None

    def run_action(self, client, action, target=None, args=None):
        params = {"action": action}
        if target:
            params["target"] = target
        if args:
            params["args"] = args
        return client.call("action.run", params)


def daemon_socket(bundle, tag):
    binary = os.path.join(bundle, "Contents/Resources/bin/cmux-tui")
    state = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{tag}/tui")
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "CMUX_TUI_STATE_DIR": state}
    out = subprocess.run([binary, "--session", f"cmux-app-{tag}", "--json", "server", "ensure"],
                         capture_output=True, text=True, env=env, timeout=10)
    data = json.loads(out.stdout.strip().splitlines()[-1])
    return data.get("socket") or data.get("data", {}).get("socket")


class Storm:
    def __init__(self, args, profile, daemon_path, keep_tabs, stream_tab, left_pane):
        self.args = args
        self.profile = profile
        self.daemon_path = daemon_path
        self.keep_tabs = set(keep_tabs)
        self.stream_tab = stream_tab
        self.left_pane = left_pane
        self.lock = threading.Lock()
        self.samples = []  # (category, method, latency_s, outcome)
        self.error_examples = {}  # "method code" -> first error message
        self.remaining = args.requests
        self.created = 0

    def take(self):
        with self.lock:
            if self.remaining <= 0:
                return False
            self.remaining -= 1
            return True

    def record(self, category, method, latency, outcome):
        with self.lock:
            self.samples.append((category, method, latency, outcome))

    def worker(self, index):
        rng = random.Random(self.args.seed * 1000 + index)
        client = Client(self.profile.socket_path)
        daemon = None
        candidates = self.closable(self.profile.topology(client), index)
        try:
            while self.take():
                roll = rng.random()
                if roll < 0.50:
                    category = "read"
                    method, params = rng.choice([
                        ("system.identify", {}), ("snapshot.get", {}), ("snapshot.get", {}), ("action.list", {"noun": "tab"}),
                        ("settings.get", {"path": "appearance"}), ("debug.queue", {}), ("action.describe", {"action": "tab rename"}),
                    ])
                    call = lambda: client.call(method, params)
                elif roll < 0.62:
                    category, method = "create", "action.run tab new-terminal"
                    call = lambda: self.profile.run_action(client, "tab new-terminal")
                elif roll < 0.74:
                    category, method = "send", "daemon send"
                    tab = rng.choice(candidates) if candidates else None
                    if tab is None or tab.get("surface") is None:
                        category, method = "read", "snapshot.get"
                        call = lambda: client.call("snapshot.get")
                    else:
                        if daemon is None:
                            daemon = Client(self.daemon_path)
                        surface = int(tab["surface"])
                        call = lambda: daemon.call("send", {"surface": surface, "text": f"echo storm {index}\r"}, cmd_key="cmd")
                elif roll < 0.87:
                    category = "rename"
                    tab = rng.choice(candidates) if candidates else None
                    if tab is None:
                        method = "action.run workspace rename"
                        call = lambda: self.profile.run_action(client, "workspace rename", args={"name": f"storm {rng.randint(0, 999)}"})
                    else:
                        method = "action.run tab rename"
                        call = lambda: self.profile.run_action(client, "tab rename", target=f"tab:{tab['id']}",
                                                               args={"name": f"storm {rng.randint(0, 999)}"})
                else:
                    category = "close"
                    tab = candidates.pop(rng.randrange(len(candidates))) if candidates else None
                    if tab is None:
                        category, method = "read", "snapshot.get"
                        call = lambda: client.call("snapshot.get")
                    else:
                        method = "action.run tab close"
                        call = lambda: self.profile.run_action(client, "tab close", target=f"tab:{tab['id']}")
                started = time.monotonic()
                try:
                    response = call()
                    error = response.get("error")
                    outcome = "ok" if ok(response) else (error.get("code", "error") if isinstance(error, dict) else "daemon_error")
                    if outcome != "ok":
                        message = error.get("message") if isinstance(error, dict) else str(error)
                        with self.lock:
                            self.error_examples.setdefault(f"{method} {outcome}", message)
                    if method == "snapshot.get" and ok(response):
                        candidates = self.closable(response["result"]["topology"], index)
                except (socket.timeout, TimeoutError):
                    outcome = "client_timeout"
                except (ConnectionError, OSError) as error:
                    outcome = f"connection:{error.__class__.__name__}"
                    client.close()
                    client = Client(self.profile.socket_path)
                self.record(category, method, time.monotonic() - started, outcome)
        finally:
            client.close()
            if daemon:
                daemon.close()

    def closable(self, topology, worker):
        """Storm tabs this worker owns (tabs are partitioned across workers,
        so two clients never race to close the same tab)."""
        tabs = []
        for tab_id in self.profile.tabs_in(topology, self.left_pane):
            if zlib.crc32(tab_id.encode()) % self.args.clients != worker:
                continue
            if tab_id in self.keep_tabs or tab_id == self.stream_tab:
                continue
            tab = self.profile.tab(topology, tab_id)
            if tab:
                tabs.append(tab)
        return tabs


def settle_tabs(profile, control, pane, quiet_s=1.0, limit_s=30.0):
    """Waits until the pane's tab count stops changing for `quiet_s`."""
    started = time.monotonic()
    last, since = None, time.monotonic()
    while time.monotonic() - started < limit_s:
        count = len(profile.tabs_in(profile.topology(control), pane))
        if count != last:
            last, since = count, time.monotonic()
        elif time.monotonic() - since >= quiet_s:
            return count
        time.sleep(0.1)
    return last


def summarize(samples):
    by_category = {}
    for category, method, latency, outcome in samples:
        entry = by_category.setdefault(category, {"latencies": [], "outcomes": {}})
        entry["latencies"].append(latency * 1000)
        entry["outcomes"][outcome] = entry["outcomes"].get(outcome, 0) + 1
    report = {}
    for category, entry in sorted(by_category.items()):
        values = entry["latencies"]
        report[category] = {
            "count": len(values), "p50_ms": percentile(values, 0.5), "p95_ms": percentile(values, 0.95),
            "p99_ms": percentile(values, 0.99), "max_ms": max(values) if values else 0, "outcomes": entry["outcomes"],
        }
    all_latencies = [latency * 1000 for _, _, latency, _ in samples]
    report["all"] = {
        "count": len(all_latencies), "p50_ms": percentile(all_latencies, 0.5), "p95_ms": percentile(all_latencies, 0.95),
        "p99_ms": percentile(all_latencies, 0.99), "max_ms": max(all_latencies) if all_latencies else 0,
    }
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--socket")
    parser.add_argument("--clients", type=int, default=32)
    parser.add_argument("--requests", type=int, default=2000)
    parser.add_argument("--stream-bytes", type=int, default=50 * 1024 * 1024)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--prewarm-tabs", type=int, default=16)
    parser.add_argument("--measure-seconds", type=float, default=10.0)
    parser.add_argument("--out")
    parser.add_argument("--label", default="cli-storm")
    parser.add_argument("--profile", choices=["next"], default="next")
    parser.add_argument("--no-fail", action="store_true")
    args = parser.parse_args()

    socket_path = args.socket or f"/tmp/cmux-debug-{args.tag}.sock"
    profile = NextProfile(socket_path)
    control = Client(socket_path)
    identity = result(control.call("system.identify"))
    pid = identity["pid"]
    bundle = app_bundle(pid)
    print(f"bench: {identity.get('app')} pid {pid} tag {identity.get('tag')} socket {socket_path}")

    # Layout: split so the streaming terminal gets its own visible pane,
    # then focus back so storm creates land in the left pane.
    topology = profile.topology(control)
    focus = profile.focus(topology)
    left_pane = focus.get("pane")
    keep_tabs = profile.tabs_in(topology, left_pane)
    result(profile.run_action(control, "pane split-right"))
    stream_tab = None
    for _ in range(100):
        topology = profile.topology(control)
        focus = profile.focus(topology)
        if focus.get("pane") and focus.get("pane") != left_pane and focus.get("tab"):
            stream_tab = focus["tab"]
            break
        time.sleep(0.05)
    if stream_tab is None:
        raise SystemExit("bench: split-right did not produce a focused stream pane")
    stream_surface = int(profile.tab(topology, stream_tab)["surface"])
    daemon_path = daemon_socket(bundle, identity.get("tag") or args.tag)
    daemon = Client(daemon_path)
    # The new pane needs a layout pass before it has a left neighbor.
    for attempt in range(40):
        if ok(profile.run_action(control, "pane focus-left")):
            break
        time.sleep(0.05)
    else:
        raise SystemExit("bench: could not focus the left pane after the split")

    time.sleep(1.0)
    baseline_rss = rss_kb(pid)
    # Pre-create tabs so sends, renames and closes have targets from the start.
    for _ in range(args.prewarm_tabs):
        profile.run_action(control, "tab new-terminal")
    settle_tabs(profile, control, left_pane)
    result(control.call("debug.hangs", {"clear": True}))
    result(control.call("debug.queue", {"reset": True}))
    result(control.call("debug.frames", {"action": "start"}))
    stream_cmd = f"yes 'cmux-next cli storm stream 0123456789abcdefghijklmnopqrstuvwxyz' | head -c {args.stream_bytes}; echo STREAM-DONE\r"
    daemon.call("send", {"surface": stream_surface, "text": stream_cmd}, cmd_key="cmd")

    load_start = os.getloadavg()
    storm = Storm(args, profile, daemon_path, keep_tabs, stream_tab, left_pane)
    started = time.monotonic()
    threads = [threading.Thread(target=storm.worker, args=(index,)) for index in range(args.clients)]
    for thread in threads:
        thread.start()
    for thread in threads:
        thread.join()
    storm_seconds = time.monotonic() - started
    # The storm's effects (daemon creates, closes, UI updates) and the
    # stream outlast the requests: keep measuring until tabs settle and at
    # least --measure-seconds passed since the storm began.
    settle_tabs(profile, control, left_pane)
    while time.monotonic() - started < args.measure_seconds:
        time.sleep(0.25)
    measured_seconds = time.monotonic() - started

    frames = result(control.call("debug.frames", {"action": "stop"}))
    hangs = result(control.call("debug.hangs"))
    queue = result(control.call("debug.queue"))
    peak_rss = rss_kb(pid)

    # Cleanup: wait for the daemon to finish the storm's creates (action.run
    # answers once the handler dispatched), close every tab the storm made,
    # interrupt the stream and close its pane, then let the app settle.
    daemon.call("send", {"surface": stream_surface, "text": "\x03"}, cmd_key="cmd")
    settle_tabs(profile, control, left_pane)
    for _ in range(3):
        topology = profile.topology(control)
        extra = [tab_id for tab_id in profile.tabs_in(topology, left_pane) if tab_id not in keep_tabs]
        if not extra:
            break
        for tab_id in extra:
            profile.run_action(control, "tab close", target=f"tab:{tab_id}")
        settle_tabs(profile, control, left_pane)
    profile.run_action(control, "tab close", target=f"tab:{stream_tab}")
    time.sleep(5.0)
    topology = profile.topology(control)
    leftover = len([t for t in profile.tabs_in(topology, left_pane) if t not in keep_tabs])
    after_rss = rss_kb(pid)
    after_hangs = result(control.call("debug.hangs"))

    report = summarize(storm.samples)
    records = hangs.get("records", [])
    busy = [r for r in records if r.get("cpu_ms", r["duration_ms"]) >= 0.5 * r["duration_ms"]]
    max_wait_ms = report["all"]["max_ms"]
    failures = []
    if hangs.get("count", 0) > 0:
        failures.append(f"{hangs['count']} main-thread stalls > 50 ms (max {hangs.get('max_ms', 0):.1f} ms)")
    if frames.get("p99_ms", 0) >= 1000 / 60:
        failures.append(f"p99 frame interval {frames['p99_ms']:.2f} ms >= 16.7 ms")
    if max_wait_ms > (DEADLINE_S + 0.25) * 1000:
        failures.append(f"a request waited {max_wait_ms:.0f} ms (> deadline {DEADLINE_S * 1000:.0f} ms)")
    lost = sum(n for c in report.values() if isinstance(c, dict) and "outcomes" in c
               for o, n in c["outcomes"].items() if o == "client_timeout" or o.startswith("connection:"))
    if lost:
        failures.append(f"{lost} requests got no answer (client timeout or dropped connection)")
    if leftover:
        failures.append(f"cleanup left {leftover} storm tabs open")
    if baseline_rss and after_rss > baseline_rss * 1.10:
        failures.append(f"RSS after {after_rss / 1024:.0f} MB > baseline {baseline_rss / 1024:.0f} MB + 10%")

    output = {
        "bench": "cli-storm", "label": args.label, "sha": args.sha, "tag": args.tag, "app": identity.get("app"),
        "pid": pid, "clients": args.clients, "requests": args.requests, "stream_bytes": args.stream_bytes,
        "storm_seconds": storm_seconds, "measured_seconds": measured_seconds, "prewarm_tabs": args.prewarm_tabs, "throughput_rps": args.requests / storm_seconds if storm_seconds else 0,
        "latency": report, "error_examples": storm.error_examples, "frames": frames, "hangs": hangs, "hangs_after_cleanup": after_hangs, "queue": queue,
        "rss_kb": {"baseline": baseline_rss, "peak": peak_rss, "after": after_rss}, "leftover_tabs": leftover,
        "load_average": {"start": load_start, "end": os.getloadavg()},
        "criteria": {"stalls_over_50ms": hangs.get("count", 0),
                     "stalls_busy_main": len(busy), "stalls_blocked_or_descheduled": len(records) - len(busy),
                     "main_long_frames_over_16_7ms": hangs.get("long_frames"), "main_long_frame_max_ms": hangs.get("long_frame_max_ms"), "p99_frame_ms": frames.get("p99_ms"),
                     "max_request_ms": max_wait_ms, "unanswered": lost,
                     "rss_after_vs_baseline": (after_rss / baseline_rss) if baseline_rss else None},
        "failures": failures, "passed": not failures,
    }
    out_dir = args.out or os.path.join(args.repo_root, "artifacts", "cmux-next-bench")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"{args.sha}-{args.label}.json")
    with open(out_path, "w") as handle:
        json.dump(output, handle, indent=2)
    print(json.dumps({k: output[k] for k in ("storm_seconds", "throughput_rps", "criteria", "failures")}, indent=2))
    print(f"latency: " + ", ".join(f"{c} p50 {v['p50_ms']:.1f} p99 {v['p99_ms']:.1f} max {v['max_ms']:.1f}"
                                    for c, v in report.items()))
    print(f"wrote {out_path}")
    if failures and not args.no_fail:
        sys.exit(1)


if __name__ == "__main__":
    main()
