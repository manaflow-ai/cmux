#!/usr/bin/env python3
"""CLI storm bench driver. Run through scripts/cmux-next/bench-cli-storm.sh.

Profiles:
  next    cmux-next control socket: snapshot.get, action.run, debug.hangs,
          debug.frames, debug.queue; the stream and sends go to the daemon.
  legacy  the old app's v2 socket (surface.* / workspace.*); it has no
          stall or frame instrumentation, so those criteria are reported
          as unavailable and only latency, answers and RSS are compared.

Teardown: every terminal the bench creates is closed through the app
(close-terminal, which ends its terminal host). The bench records the PTY
holders it can attribute to the app before it starts (cmux-tui terminal
host processes for `next`, /dev/ptmx descriptors for `legacy`), kills any
new host still alive after cleanup, and fails if the count is not back to
the baseline. Then (`next`, unless --keep-daemon) it ends every terminal of
the tag's daemon with `shutdown-daemon end_terminals` (daemon_teardown.py)
and fails if any of its terminal hosts outlives that.
"""
import argparse
import json
import os
import random
import signal
import socket
import subprocess
import sys
import threading
import time
import zlib

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from daemon_teardown import end_terminals  # noqa: E402

DEADLINE_S = 2.0
CLIENT_TIMEOUT_S = DEADLINE_S + 3.0
STREAM_TEXT = "yes 'cmux-next cli storm stream 0123456789abcdefghijklmnopqrstuvwxyz' | head -c {bytes}; echo STREAM-DONE\r"


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
            message = json.loads(self.readline())
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


def run(argv):
    return subprocess.run(argv, capture_output=True, text=True).stdout


def rss_kb(pid):
    out = run(["ps", "-o", "rss=", "-p", str(pid)]).strip()
    return int(out) if out else 0


def footprint_mb(pid):
    """Physical footprint (what Activity Monitor shows as Memory), in MB."""
    for line in run(["footprint", str(pid)]).splitlines():
        if "Footprint:" in line:
            value, unit = line.split("Footprint:")[1].split()[:2]
            return float(value) * (1024 if unit.upper().startswith("G") else 1 / 1024 if unit.upper().startswith("K") else 1)
    return None


def app_bundle(pid):
    out = run(["ps", "-o", "comm=", "-p", str(pid)]).strip()
    marker = ".app/"
    return out[: out.index(marker) + 4] if marker in out else None


def pid_for_tag(tag):
    out = run(["pgrep", "-f", f"cmux DEV {tag}.app/Contents/MacOS/cmux DEV"]).split()
    return int(out[0]) if out else None


def percentile(values, p):
    if not values:
        return 0.0
    ordered = sorted(values)
    return ordered[min(len(ordered) - 1, int(round((len(ordered) - 1) * p)))]


class NextProfile:
    """cmux-next: snapshot reads, action.run mutations, daemon sends."""

    name = "next"
    diagnostics = True

    def __init__(self, socket_path, tag):
        self.socket_path = socket_path
        self.tag = tag
        self.daemon_path = None
        self.tui_binary = None
        self.local = threading.local()

    # Topology helpers
    def topology(self, client):
        return result(client.call("snapshot.get"))["topology"]

    @staticmethod
    def panes(topology):
        for workspace in topology.get("workspaces", []):
            for screen in workspace.get("screens", []):
                yield from screen.get("panes", [])

    def tabs_in(self, topology, pane_id):
        return [tab for pane in self.panes(topology) if pane["id"] == pane_id for tab in pane.get("tabs", [])]

    def left_tabs(self, client):
        return [tab["id"] for tab in self.tabs_in(self.topology(client), self.left)]

    def action(self, client, name, target=None, args=None):
        params = {"action": name}
        if target:
            params["target"] = target
        if args:
            params["args"] = args
        return client.call("action.run", params)

    def daemon(self):
        if getattr(self.local, "daemon", None) is None:
            self.local.daemon = Client(self.daemon_path)
        return self.local.daemon

    # Setup
    def identify(self, control):
        identity = result(control.call("system.identify"))
        pid = identity["pid"]
        self.tui_binary = os.environ.get("CMUX_NEXT_TUI_BIN") or os.path.join(app_bundle(pid), "Contents/Resources/bin/cmux-tui")
        return pid, identity.get("tag") or self.tag

    def pty_holders(self, pid):
        """Terminal host processes of this app's cmux-tui binary (one PTY each)."""
        return {int(p) for p in run(["pgrep", "-f", f"{self.tui_binary} __terminal-host"]).split()}

    def setup(self, control, pid):
        topology = self.topology(control)
        self.left = topology["focus"]["pane"]
        self.keep = {tab["id"] for tab in self.tabs_in(topology, self.left)}
        result(self.action(control, "pane split-right"))
        self.stream_tab = None
        for _ in range(100):
            topology = self.topology(control)
            focus = topology["focus"]
            if focus.get("pane") and focus["pane"] != self.left and focus.get("tab"):
                self.stream_tab = next(tab for tab in self.tabs_in(topology, focus["pane"]) if tab["id"] == focus["tab"])
                break
            time.sleep(0.05)
        if self.stream_tab is None:
            raise SystemExit("bench: split-right did not produce a focused stream pane")
        self.daemon_path = daemon_socket(self.tui_binary, self.tag)
        # The new pane needs a layout pass before it has a left neighbor.
        for _ in range(40):
            if ok(self.action(control, "pane focus-left")):
                return
            time.sleep(0.05)
        raise SystemExit("bench: could not focus the left pane after the split")

    def start_stream(self, control, stream_bytes):
        self.daemon().call("send", {"surface": int(self.stream_tab["surface"]), "text": STREAM_TEXT.format(bytes=stream_bytes)}, cmd_key="cmd")

    def stop_stream(self, control):
        try:
            # A fresh connection: the daemon may have dropped an idle one.
            daemon = Client(self.daemon_path)
            daemon.call("send", {"surface": int(self.stream_tab["surface"]), "text": "\x03"}, cmd_key="cmd")
            daemon.close()
        except (OSError, ConnectionError, ValueError):
            pass
        self.action(control, "tab close", target=f"tab:{self.stream_tab['id']}")

    # Storm operations: each returns (category, method, thunk[, parses_candidates])
    def read(self, client, rng):
        method, params = rng.choice([
            ("system.identify", {}), ("snapshot.get", {}), ("snapshot.get", {}), ("action.list", {"noun": "tab"}),
            ("settings.get", {"path": "appearance"}), ("debug.queue", {}), ("action.describe", {"action": "tab rename"}),
        ])
        return "read", method, lambda: client.call(method, params), method == "snapshot.get"

    def candidates(self, response):
        return [tab for tab in self.tabs_in(response["result"]["topology"], self.left) if tab["id"] not in self.keep]

    def create(self, client):
        return "create", "action.run tab new-terminal", lambda: self.action(client, "tab new-terminal")

    def send(self, client, tab, text):
        surface = int(tab["surface"])
        return "send", "daemon send", lambda: self.daemon().call("send", {"surface": surface, "text": text}, cmd_key="cmd")

    def rename(self, client, tab, name):
        return "rename", "action.run tab rename", lambda: self.action(client, "tab rename", target=f"tab:{tab['id']}", args={"name": name})

    def close(self, client, tab):
        return "close", "action.run tab close", lambda: self.action(client, "tab close", target=f"tab:{tab['id']}")

    def close_tab_id(self, control, tab_id):
        self.action(control, "tab close", target=f"tab:{tab_id}")

    def force_close(self, tab_ids):
        """Backstop: closes leftover storm terminals on the daemon directly."""
        control = Client(self.socket_path)
        wanted = set(tab_ids)
        tabs = [tab for tab in self.tabs_in(self.topology(control), self.left) if tab["id"] in wanted]
        control.close()
        failures = 0
        for tab in tabs:
            commands = ([("close-terminal", {"terminal_id": tab["terminal"]})] if tab.get("terminal") else []) + \
                [("close-surface", {"surface": int(tab["surface"])})]
            for command, params in commands:
                try:
                    daemon = Client(self.daemon_path, timeout=30)
                    daemon.call(command, params, cmd_key="cmd")
                    daemon.close()
                except (OSError, ConnectionError, ValueError):
                    failures += 1
        self.force_close_failures = failures
        return len(tabs)

    # Diagnostics
    def begin_measure(self, control):
        result(control.call("debug.hangs", {"clear": True}))
        result(control.call("debug.queue", {"reset": True}))
        result(control.call("debug.frames", {"action": "start"}))

    def end_measure(self, control):
        frames = result(control.call("debug.frames", {"action": "stop"}))
        return frames, result(control.call("debug.hangs")), result(control.call("debug.queue"))

    def hangs(self, control):
        return result(control.call("debug.hangs"))


class LegacyProfile:
    """The old app's v2 socket: surface.* and workspace.* methods."""

    name = "legacy"
    diagnostics = False

    def __init__(self, socket_path, tag):
        self.socket_path = socket_path
        self.tag = tag

    def surfaces(self, client):
        return result(client.call("surface.list"))["surfaces"]

    def left_tabs(self, client):
        return [s["id"] for s in self.surfaces(client) if s.get("pane_id") == self.left]

    def identify(self, control):
        result(control.call("system.identify"))
        pid = pid_for_tag(self.tag)
        if pid is None:
            raise SystemExit(f"bench: no running cmux DEV {self.tag}.app")
        return pid, self.tag

    def pty_holders(self, pid):
        """/dev/ptmx descriptors the app holds (the old app owns its PTYs)."""
        lines = run(["lsof", "-p", str(pid)]).splitlines()
        return {line.split()[3] for line in lines if "/dev/ptmx" in line}

    def setup(self, control, pid):
        surfaces = self.surfaces(control)
        focused = next((s for s in surfaces if s.get("focused")), surfaces[0])
        self.left = focused["pane_id"]
        self.left_surface = focused["id"]
        self.keep = {s["id"] for s in surfaces if s.get("pane_id") == self.left}
        self.workspace = result(control.call("workspace.current")).get("workspace_id")
        result(control.call("surface.split", {"direction": "right"}))
        self.stream_tab = None
        for _ in range(100):
            others = [s for s in self.surfaces(control) if s.get("pane_id") != self.left]
            if others:
                self.stream_tab = others[0]
                break
            time.sleep(0.05)
        if self.stream_tab is None:
            raise SystemExit("bench: surface.split did not create a stream pane")
        control.call("surface.focus", {"surface_id": self.left_surface})

    def start_stream(self, control, stream_bytes):
        result(control.call("surface.send_text", {"surface_id": self.stream_tab["id"], "text": STREAM_TEXT.format(bytes=stream_bytes)}))

    def stop_stream(self, control):
        control.call("surface.send_text", {"surface_id": self.stream_tab["id"], "text": "\x03"})
        control.call("surface.close", {"surface_id": self.stream_tab["id"]})

    def read(self, client, rng):
        method = rng.choice(["system.identify", "surface.list", "surface.list", "workspace.list", "pane.list",
                             "system.tree", "workspace.current"])
        return "read", method, lambda: client.call(method, {}), method == "surface.list"

    def candidates(self, response):
        return [s for s in (response.get("result") or {}).get("surfaces", []) if s.get("pane_id") == self.left and s["id"] not in self.keep]

    def create(self, client):
        return "create", "surface.create", lambda: client.call("surface.create", {"pane_id": self.left, "type": "terminal"})

    def send(self, client, tab, text):
        return "send", "surface.send_text", lambda: client.call("surface.send_text", {"surface_id": tab["id"], "text": text})

    def rename(self, client, tab, name):
        return "rename", "workspace.rename", lambda: client.call("workspace.rename", {"workspace_id": self.workspace, "title": name})

    def close(self, client, tab):
        return "close", "surface.close", lambda: client.call("surface.close", {"surface_id": tab["id"]})

    def close_tab_id(self, control, tab_id):
        control.call("surface.close", {"surface_id": tab_id})

    def force_close(self, tab_ids):
        return 0

    def begin_measure(self, control):
        pass

    def end_measure(self, control):
        return None, None, None

    def hangs(self, control):
        return None


def daemon_socket(binary, tag):
    state = os.path.expanduser(f"~/Library/Application Support/cmux/tags/{tag}/tui")
    env = {"HOME": os.environ["HOME"], "PATH": "/usr/bin:/bin", "CMUX_TUI_STATE_DIR": state}
    out = run_env([binary, "--session", f"cmux-app-{tag}", "--json", "server", "ensure"], env)
    data = json.loads(out.strip().splitlines()[-1])
    return data.get("socket") or data.get("data", {}).get("socket")


def run_env(argv, env):
    return subprocess.run(argv, capture_output=True, text=True, env=env, timeout=10).stdout


class Storm:
    def __init__(self, args, profile):
        self.args = args
        self.profile = profile
        self.lock = threading.Lock()
        self.samples = []  # (category, method, latency_s, outcome)
        self.error_examples = {}  # "method code" -> first error message
        self.remaining = args.requests
        self.creates_left = args.max_creates

    def take_create(self):
        """Terminals are a shared system resource (kern.tty.ptmx_max is 511
        on macOS): cap how many the storm spawns."""
        with self.lock:
            if self.creates_left <= 0:
                return False
            self.creates_left -= 1
            return True

    def take(self):
        with self.lock:
            if self.remaining <= 0:
                return False
            self.remaining -= 1
            return True

    def mine(self, tabs, worker):
        """Storm tabs this worker owns: partitioned by id so two clients
        never race to close the same tab."""
        return [tab for tab in tabs if zlib.crc32(tab["id"].encode()) % self.args.clients == worker]

    def worker(self, index):
        rng = random.Random(self.args.seed * 1000 + index)
        profile = self.profile
        client = Client(profile.socket_path)
        candidates = []
        try:
            while self.take():
                roll = rng.random()
                tab = rng.choice(candidates) if candidates else None
                lists = False
                if roll < 0.50 or (roll >= 0.62 and tab is None) or (0.50 <= roll < 0.62 and not self.take_create()):
                    category, method, thunk, lists = profile.read(client, rng)
                elif roll < 0.62:
                    category, method, thunk = profile.create(client)
                elif roll < 0.74:
                    category, method, thunk = profile.send(client, tab, f"echo storm {index}\r")
                elif roll < 0.87:
                    category, method, thunk = profile.rename(client, tab, f"storm {rng.randint(0, 999)}")
                else:
                    candidates.remove(tab)
                    category, method, thunk = profile.close(client, tab)
                started = time.monotonic()
                try:
                    response = thunk()
                    error = response.get("error")
                    outcome = "ok" if ok(response) else (error.get("code", "error") if isinstance(error, dict) else "daemon_error")
                    if outcome != "ok":
                        message = error.get("message") if isinstance(error, dict) else str(error)
                        with self.lock:
                            self.error_examples.setdefault(f"{method} {outcome}", message)
                    elif lists:
                        candidates = self.mine(profile.candidates(response), index)
                except (socket.timeout, TimeoutError):
                    outcome = "client_timeout"
                except (ConnectionError, OSError) as error:
                    outcome = f"connection:{error.__class__.__name__}"
                    client.close()
                    client = Client(profile.socket_path)
                self.record(category, method, time.monotonic() - started, outcome)
        finally:
            client.close()

    def record(self, category, method, latency, outcome):
        with self.lock:
            self.samples.append((category, method, latency, outcome))


def settle(profile, control, quiet_s=1.0, limit_s=30.0):
    """Waits until the left pane's tab count stops changing for `quiet_s`."""
    started = time.monotonic()
    last, since = None, time.monotonic()
    while time.monotonic() - started < limit_s:
        count = len(profile.left_tabs(control))
        if count != last:
            last, since = count, time.monotonic()
        elif time.monotonic() - since >= quiet_s:
            return count
        time.sleep(0.1)
    return last


def wait_for_pty_baseline(profile, pid, baseline, limit_s=90.0):
    """Terminal hosts exit asynchronously after close-terminal."""
    started = time.monotonic()
    while time.monotonic() - started < limit_s:
        current = profile.pty_holders(pid)
        if not (current - baseline):
            return current
        time.sleep(0.25)
    return profile.pty_holders(pid)


def summarize(samples):
    by_category = {}
    for category, _, latency, outcome in samples:
        entry = by_category.setdefault(category, {"latencies": [], "outcomes": {}})
        entry["latencies"].append(latency * 1000)
        entry["outcomes"][outcome] = entry["outcomes"].get(outcome, 0) + 1
    report = {}
    for category, entry in sorted(by_category.items()):
        values = entry["latencies"]
        report[category] = {"count": len(values), "p50_ms": percentile(values, 0.5), "p95_ms": percentile(values, 0.95),
                            "p99_ms": percentile(values, 0.99), "max_ms": max(values), "outcomes": entry["outcomes"]}
    values = [latency * 1000 for _, _, latency, _ in samples]
    report["all"] = {"count": len(values), "p50_ms": percentile(values, 0.5), "p95_ms": percentile(values, 0.95),
                     "p99_ms": percentile(values, 0.99), "max_ms": max(values) if values else 0}
    return report


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True)
    parser.add_argument("--sha", required=True)
    parser.add_argument("--tag", required=True)
    parser.add_argument("--socket")
    parser.add_argument("--profile", choices=["next", "legacy"], default="next")
    parser.add_argument("--clients", type=int, default=32)
    parser.add_argument("--requests", type=int, default=2000)
    parser.add_argument("--stream-bytes", type=int, default=50 * 1024 * 1024)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--prewarm-tabs", type=int, default=16)
    parser.add_argument("--max-creates", type=int, default=96)
    parser.add_argument("--measure-seconds", type=float, default=10.0)
    parser.add_argument("--out")
    parser.add_argument("--label", default="cli-storm")
    parser.add_argument("--no-fail", action="store_true")
    parser.add_argument("--keep-daemon", action="store_true",
                        help="skip the final shutdown-daemon end_terminals teardown (next profile)")
    args = parser.parse_args()

    socket_path = args.socket or f"/tmp/cmux-debug-{args.tag}.sock"
    profile = (NextProfile if args.profile == "next" else LegacyProfile)(socket_path, args.tag)
    control = Client(socket_path)
    pid, tag = profile.identify(control)
    profile.tag = tag
    pty_baseline = profile.pty_holders(pid)
    print(f"bench: profile {profile.name} pid {pid} tag {tag} socket {socket_path} pty holders {len(pty_baseline)}")

    profile.setup(control, pid)
    time.sleep(1.0)
    baseline_rss = rss_kb(pid)
    baseline_footprint = footprint_mb(pid)
    # Pre-create tabs so sends, renames and closes have targets from the start.
    for _ in range(args.prewarm_tabs):
        profile.create(control)[2]()
    settle(profile, control)
    profile.begin_measure(control)
    profile.start_stream(control, args.stream_bytes)

    load_start = os.getloadavg()
    storm = Storm(args, profile)
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
    settle(profile, control)
    while time.monotonic() - started < args.measure_seconds:
        time.sleep(0.25)
    measured_seconds = time.monotonic() - started
    frames, hangs, queue = profile.end_measure(control)
    peak_rss = rss_kb(pid)
    load_end = os.getloadavg()

    # Cleanup: close every storm tab and the stream pane through the app
    # (close-terminal ends each terminal host). action.run answers once the
    # handler dispatched and the daemon closes terminals asynchronously, so
    # wait until the storm tabs are gone or stop decreasing, and repeat.
    def extra_tabs():
        return [tab_id for tab_id in profile.left_tabs(control) if tab_id not in profile.keep]

    settle(profile, control, quiet_s=3.0, limit_s=60.0)
    for _ in range(4):
        extra = extra_tabs()
        if not extra:
            break
        for tab_id in extra:
            profile.close_tab_id(control, tab_id)
        # The daemon closes ~10 terminals per second and the mirror may apply
        # them in one batch, so allow a long quiet period before retrying.
        best, since = len(extra), time.monotonic()
        while time.monotonic() - since < 45.0:
            time.sleep(0.5)
            count = len(extra_tabs())
            if count == 0:
                break
            if count < best:
                best, since = count, time.monotonic()
    closed_by_daemon = profile.force_close(extra_tabs()) if extra_tabs() else 0
    profile.stop_stream(control)
    time.sleep(5.0)
    leftover = len([t for t in profile.left_tabs(control) if t not in profile.keep])
    after_rss = rss_kb(pid)
    after_footprint = footprint_mb(pid)
    after_hangs = profile.hangs(control)
    remaining = wait_for_pty_baseline(profile, pid, pty_baseline)
    leaked = remaining - pty_baseline
    if leaked and profile.name == "next":
        for host in leaked:
            try:
                os.kill(host, signal.SIGKILL)
            except ProcessLookupError:
                pass

    teardown = None
    if profile.name == "next" and not args.keep_daemon:
        teardown = end_terminals(profile.tui_binary, tag)
        print(f"bench: teardown {json.dumps(teardown)}")

    report = summarize(storm.samples)
    lost = sum(n for c in report.values() if "outcomes" in c
               for o, n in c["outcomes"].items() if o == "client_timeout" or o.startswith("connection:"))
    failures = []
    criteria = {"max_request_ms": report["all"]["max_ms"], "unanswered": lost,
                "rss_after_vs_baseline": (after_rss / baseline_rss) if baseline_rss else None,
                "pty_holders_baseline": len(pty_baseline), "pty_holders_after": len(remaining), "pty_leaked": len(leaked)}
    if profile.diagnostics:
        records = hangs.get("records", [])
        busy = [r for r in records if r.get("cpu_ms", r["duration_ms"]) >= 0.5 * r["duration_ms"]]
        criteria.update({
            "stalls_over_50ms": hangs.get("count", 0), "stalls_busy_main": len(busy),
            "stalls_blocked_or_descheduled": len(records) - len(busy), "p99_frame_ms": frames.get("p99_ms"),
            "main_long_frames_over_16_7ms": hangs.get("long_frames"), "main_long_frame_max_ms": hangs.get("long_frame_max_ms"),
        })
        if hangs.get("count", 0) > 0:
            failures.append(f"{hangs['count']} main-thread stalls > 50 ms (max {hangs.get('max_ms', 0):.1f} ms)")
        if frames.get("p99_ms", 0) >= 1000 / 60:
            failures.append(f"p99 frame interval {frames['p99_ms']:.2f} ms >= 16.7 ms")
    else:
        criteria.update({"stalls_over_50ms": None, "p99_frame_ms": None})
    if report["all"]["max_ms"] > (DEADLINE_S + 0.25) * 1000:
        failures.append(f"a request waited {report['all']['max_ms']:.0f} ms (> deadline {DEADLINE_S * 1000:.0f} ms)")
    if lost:
        failures.append(f"{lost} requests got no answer (client timeout or dropped connection)")
    if leftover:
        failures.append(f"cleanup left {leftover} storm tabs open")
    if closed_by_daemon:
        failures.append(f"{closed_by_daemon} storm tabs did not close through the app and were closed on the daemon")
    if leaked:
        failures.append(f"{len(leaked)} PTY holders outlived cleanup" + (" (terminal hosts killed)" if profile.name == "next" else ""))
    if teardown is not None:
        criteria["teardown_ended_terminals"] = teardown["ended_terminals"]
        criteria["teardown_hosts_leaked"] = len(teardown["hosts_leaked"])
        if teardown["error"]:
            failures.append(f"teardown: {teardown['error']}")
        if teardown["hosts_leaked"]:
            failures.append(f"{len(teardown['hosts_leaked'])} terminal hosts outlived shutdown-daemon end_terminals")
    if baseline_rss and after_rss > baseline_rss * 1.10:
        failures.append(f"RSS after {after_rss / 1024:.0f} MB > baseline {baseline_rss / 1024:.0f} MB + 10%")

    output = {
        "bench": "cli-storm", "profile": profile.name, "label": args.label, "sha": args.sha, "tag": tag, "pid": pid,
        "clients": args.clients, "requests": args.requests, "stream_bytes": args.stream_bytes, "prewarm_tabs": args.prewarm_tabs,
        "max_creates": args.max_creates, "storm_seconds": storm_seconds, "measured_seconds": measured_seconds,
        "throughput_rps": args.requests / storm_seconds if storm_seconds else 0,
        "latency": report, "error_examples": storm.error_examples, "frames": frames, "hangs": hangs,
        "hangs_after_cleanup": after_hangs, "queue": queue, "leftover_tabs": leftover, "closed_by_daemon": closed_by_daemon,
        "rss_kb": {"baseline": baseline_rss, "peak": peak_rss, "after": after_rss},
        "footprint_mb": {"baseline": baseline_footprint, "after": after_footprint},
        "load_average": {"start": load_start, "end": load_end}, "criteria": criteria,
        "failures": failures, "passed": not failures,
    }
    out_dir = args.out or os.path.join(args.repo_root, "artifacts", "cmux-next-bench")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"{args.sha}-{args.label}.json")
    with open(out_path, "w") as handle:
        json.dump(output, handle, indent=2)
    print(json.dumps({k: output[k] for k in ("storm_seconds", "throughput_rps", "criteria", "failures")}, indent=2))
    print("latency: " + ", ".join(f"{c} p50 {v['p50_ms']:.1f} p99 {v['p99_ms']:.1f} max {v['max_ms']:.1f}" for c, v in report.items()))
    print(f"wrote {out_path}")
    if failures and not args.no_fail:
        sys.exit(1)


if __name__ == "__main__":
    main()
