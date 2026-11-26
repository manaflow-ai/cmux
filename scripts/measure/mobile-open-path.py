#!/usr/bin/env python3
"""The cmux-tui daemon's share of the iPhone app's open and reconnect path.

Starts one isolated `cmux-tui --headless` daemon (private socket, state and config, as
scripts/cmux-next/bench_tui_service.py does) and replays, over its unix socket, what the phone
sends, measuring round trips, bytes read and wall time to the first content. Headless and
Linux-runnable: no app, no phone, no link. The wire between phone and Mac (RTT, bandwidth) is
modeled, not measured: modeled = daemon_ms + round_trips * RTT + bytes * 8 / bandwidth.

Scenarios (each repeated --runs times):

  setup     What WorkspaceSync.prepare sends in ONE write on link up (CmuxMobileLive/
            WorkspaceSync.swift:149-157): set-client-info, identify, subscribe
            {tree_events: deltas}, list-agents, list-workspaces. Complete = all five
            replies. One round trip. Scale: --workspaces (workspaces, one terminal each).
            A daemon whose identify lists list-workspaces-page-v1 is sent the phone's first
            window, list-workspaces {limit: 40} (CmuxMobileLive/ListFirstWindow.swift: the
            phone remembers the capability from its earlier connect); an older daemon gets the
            whole tree. The rest of the tree follows after first content and is not counted.
  reattach  DaemonTerminalSession.attach (CmuxMobileLive/DaemonTerminalSession.swift:690-870):
            (1) resolve-terminal {terminal_id}; (2) set-client-info + identify in one write;
            (3) attach-surface {surface, cols, rows, replay_history_rows: 0}. Complete = the
            first `vt-state` event of the surface. Three round trips (one with attach-terminal-id-v1). The terminal's grid on
            the daemon is Mac-sized (160x50) and filled with --scrollback-lines numbered
            lines before the phone attaches at 46x42. Variants, each on its own fresh terminal:
              attach     the phone's first attach on a fresh connection (steps 1-3);
              reconnect  the same again from a second fresh connection while the first is
                         detached (the dropped-link case);
              same_size  attach at the grid's own size (160x50): no PTY resize, so the daemon's
                         settle_hosted_viewer_size (server/cmd_attach.rs:518-526, up to 1 s)
                         has nothing to wait for. attach minus same_size is the time spent
                         in it (the daemon gives no finer signal).
            A daemon whose identify (the phone remembers the one of its earlier attach) lists
            attach-terminal-id-v1 is sent set-client-info, identify and attach-surface
            {terminal_id, surface, ...} in ONE write, with no resolve-terminal: one round trip.
            The harness learns the capabilities from a probe identify before the runs, as the phone
            does from its earlier attach; an older daemon keeps the three round trips.
            A phone's very first attach of a terminal skips step 1 (it resolves only on a
            reattach or retry, DaemonTerminalSession.swift:704): subtract resolve_ms and one
            round trip.
  chat      Out of scope (acpmux).

Usage:
  mobile-open-path.py --binary target/release/cmux-tui [--runs 10] [--scenarios setup,reattach]
      [--workspaces 10,100,1000] [--scrollback-lines 1000,10000,100000]
      [--out .build/mobile-open-path/report.json]
  mobile-open-path.py --compare BEFORE.json AFTER.json     print a before/after table
"""
import argparse
import json
import os
import shutil
import socket
import subprocess
import sys
import tempfile
import time

# The modeled links: (name, RTT ms, Mbit/s).
LINKS = (("wifi", 20.0, 50.0), ("lte", 70.0, 12.0), ("bad", 300.0, 1.0))
# The Mac pane's grid and the phone's, as in the app (46x42 is an iPhone terminal page).
MAC_COLS, MAC_ROWS = 160, 50
PHONE_COLS, PHONE_ROWS = 46, 42
# What the phone puts in set-client-info (WorkspaceSync.swift:149-153; DaemonTerminalSession.swift:1631).
DEVICE_NAME = "bench iPhone"
DEVICE_ID = "bench-device-0001"
SETUP_CAPABILITIES = ["conversation-tabs-v1", "agent-session-tabs-v1", "page-tabs-v1"]
ATTACH_CAPABILITIES = ["size-lease-v2", "size-lease-v1", "shared-sizing-v1", "host-grid-view-v1"]
REPLAY_HISTORY_ROWS_CAPABILITY = "attach-replay-history-rows-v1"
INITIAL_SIZE_CAPABILITY = "attach-initial-size"
ATTACH_TERMINAL_ID_CAPABILITY = "attach-terminal-id-v1"
FIRST_WINDOW_CAPABILITY = "list-workspaces-page-v1"
FIRST_WINDOW_LIMIT = 40  # ListFirstWindow.limit


def fail(message):
    print(f"mobile-open-path: {message}", file=sys.stderr)
    raise SystemExit(1)


class Connection:
    """Newline-JSON over the daemon's unix socket (bench_tui_service.Connection), counting
    the bytes of every line it hands back."""

    def __init__(self, path, timeout=600.0):
        self.sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buffer = b""
        self.bytes = 0  # bytes of the lines read so far (newline included)

    def write(self, bodies):
        """Every body in one write, as the phone's batch."""
        self.sock.sendall(b"".join((json.dumps(body) + "\n").encode() for body in bodies))

    def read(self):
        while b"\n" not in self.buffer:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                fail("the daemon closed the connection")
            self.buffer += chunk
        line, self.buffer = self.buffer.split(b"\n", 1)
        self.bytes += len(line) + 1
        return json.loads(line), len(line) + 1

    def call(self, body):
        self.write([body])
        while True:
            message, _ = self.read()
            if message.get("id") == body["id"]:
                if not message.get("ok"):
                    fail(f"{body['cmd']} failed: {message.get('error')}")
                return message.get("data")

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass


def children(pid):
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


class Daemon:
    def __init__(self, binary):
        self.binary = os.path.abspath(binary)
        self.dir = tempfile.mkdtemp(prefix="cmux-tui-open-path-", dir="/tmp")
        self.socket = os.path.join(self.dir, "mux.sock")
        self.state = os.path.join(self.dir, "state")
        settings = os.path.join(self.dir, "cmux-next.json")
        with open(settings, "w") as handle:
            handle.write("{}\n")
        env = {"HOME": os.environ.get("HOME", "/tmp"), "PATH": "/usr/bin:/bin", "TMPDIR": "/tmp",
               "CMUX_TUI_CONFIG": os.path.join(self.dir, "config.json"), "CMUX_NEXT_CONFIG_FILE": settings,
               "SHELL": "/bin/sh", "TERM": "xterm-256color"}
        log = open(os.path.join(self.dir, "daemon.log"), "wb")
        self.process = subprocess.Popen(
            [self.binary, "--headless", "--socket", self.socket, "--state", self.state],
            env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=log)
        self.pid = self.process.pid
        deadline = time.monotonic() + 30
        while True:
            if self.process.poll() is not None:
                self.fail_start(f"the daemon exited with {self.process.returncode}")
            try:
                Connection(self.socket).close()
                break
            except OSError:
                if time.monotonic() > deadline:
                    self.fail_start("the daemon did not open its socket in 30 s")
                time.sleep(0.01)  # bench: waiting for a process to listen
        self.control = Connection(self.socket)
        self.next_id = 100

    def fail_start(self, why):
        tail = ""
        try:
            tail = open(os.path.join(self.dir, "daemon.log"), errors="replace").read()[-2000:]
        except OSError:
            pass
        self.stop(graceful=False)
        fail(f"daemon failed to start: {why} ({self.binary})\n{tail}")

    def call(self, cmd, **fields):
        self.next_id += 1
        return self.control.call({"id": self.next_id, "cmd": cmd, **fields})

    def tabs(self):
        found = []
        for workspace in self.call("list-workspaces").get("workspaces", []):
            for screen in workspace.get("screens", []):
                for pane in screen.get("panes", []):
                    for tab in pane.get("tabs", []):
                        if tab.get("surface") is not None:
                            found.append((workspace.get("key"), tab))
        return found

    def stop(self, graceful=True):
        hosts = children(self.pid)
        try:
            self.control.close()
        except AttributeError:
            pass
        self.process.kill()
        self.process.wait()
        for pid in hosts:  # terminal hosts this daemon started
            try:
                os.kill(pid, 9)
            except OSError:
                pass
        shutil.rmtree(self.dir, ignore_errors=True)


def pct(values, q):
    ordered = sorted(values)
    if not ordered:
        return 0.0
    index = min(len(ordered) - 1, max(0, int(round(q * (len(ordered) - 1)))))
    return ordered[index]


def stats(values):
    return {"p50": round(pct(values, 0.5), 3), "p95": round(pct(values, 0.95), 3),
            "max": round(max(values), 3) if values else 0.0}


def modeled(daemon_ms, round_trips, byte_count):
    """daemon_ms + round_trips * RTT + bytes * 8 / bandwidth, per link, in ms."""
    return {name: round(daemon_ms + round_trips * rtt + byte_count * 8 / (mbit * 1e6) * 1000, 1)
            for name, rtt, mbit in LINKS}


# setup -----------------------------------------------------------------------------------------

def grow_workspaces(daemon, have, want):
    for index in range(have, want):
        daemon.call("run", argv=["/bin/cat"], name=f"open-path-{index}", new_workspace=True)


def setup_once(path, first_window=False):
    conn = Connection(path)
    try:
        bodies = [
            {"id": 1, "cmd": "set-client-info", "name": DEVICE_NAME, "kind": "ios", "device_kind": "iphone",
             "device_name": DEVICE_NAME, "device_id": DEVICE_ID, "capabilities": SETUP_CAPABILITIES},
            {"id": 2, "cmd": "identify"},
            {"id": 3, "cmd": "subscribe", "tree_events": "deltas"},
            {"id": 4, "cmd": "list-agents"},
            {"id": 5, "cmd": "list-workspaces", **({"limit": FIRST_WINDOW_LIMIT} if first_window else {})},
        ]
        names = {body["id"]: body["cmd"] for body in bodies}
        started = time.monotonic()
        conn.write(bodies)
        pending = set(names)
        reply_bytes = {}
        while pending:
            message, size = conn.read()
            ident = message.get("id")
            if ident in pending:
                if not message.get("ok"):
                    fail(f"setup: {names[ident]} failed: {message.get('error')}")
                pending.discard(ident)
                reply_bytes[names[ident]] = size
        wall = (time.monotonic() - started) * 1000
        return {"wall_ms": round(wall, 3), "bytes": conn.bytes, "round_trips": 1, "reply_bytes": reply_bytes}
    finally:
        conn.close()


def scenario_setup(binary, runs, scales):
    daemon = Daemon(binary)
    rows = []
    try:
        have = 0
        for scale in scales:
            grow_workspaces(daemon, have, scale)
            have = scale
            first_window = FIRST_WINDOW_CAPABILITY in probe_capabilities(daemon.socket)
            samples = [setup_once(daemon.socket, first_window) for _ in range(runs)]
            rows.append({"scenario": "setup", "variant": "setup", "scale": scale, "scale_unit": "workspaces",
                         "round_trips": 1, "runs": samples})
    finally:
        daemon.stop()
    return rows


# reattach --------------------------------------------------------------------------------------

def make_terminal(daemon, lines, index):
    """A Mac-sized terminal with `lines` numbered lines drawn, then idle. Returns (terminal_id, surface)."""
    script = f"seq 1 {lines}; echo OPENPATH_$((1+1))_{index}; exec sleep 86400"
    created = daemon.call("run", argv=["/bin/sh", "-c", script], name=f"open-path-{index}",
                          new_workspace=True, cols=MAC_COLS, rows=MAC_ROWS)
    surface = terminal_id = None
    for _, tab in daemon.tabs():
        if tab.get("name") == f"open-path-{index}":
            surface, terminal_id = tab["surface"], tab.get("terminal_id")
    if surface is None or terminal_id is None:
        fail(f"could not find the new terminal (surface and terminal_id) in list-workspaces (run reply: {created!r})")
    want = f"OPENPATH_2_{index}"
    deadline = time.monotonic() + 300
    while True:
        text = daemon.call("read-screen", surface=surface).get("text", "")
        if want in text.replace("\n", " ").split():
            break
        if time.monotonic() > deadline:
            fail(f"the terminal never drew its {lines} lines")
        time.sleep(0.05)  # bench: waiting for the shell to draw
    return terminal_id, surface


def attach_params(request_id, surface, size, capabilities):
    """As the phone does: the size only when the daemon lists attach-initial-size, the history
    allowance only when it lists attach-replay-history-rows-v1."""
    params = {"id": request_id, "cmd": "attach-surface", "surface": surface}
    sized = size is not None and INITIAL_SIZE_CAPABILITY in capabilities
    if sized:
        params["cols"], params["rows"] = size
    tail = REPLAY_HISTORY_ROWS_CAPABILITY in capabilities
    if tail:
        params["replay_history_rows"] = 0
    return params, sized, tail


def probe_capabilities(path):
    """The daemon's identify capabilities: what the phone remembers from an earlier attach."""
    conn = Connection(path)
    try:
        return conn.call({"id": 1, "cmd": "identify"}).get("capabilities") or []
    finally:
        conn.close()


def attach_pipelined(conn, terminal_id, surface, size, known, started):
    """attach-terminal-id-v1: set-client-info, identify and attach-surface in one write."""
    params, sized, tail = attach_params(4, surface, size, known)
    params["terminal_id"] = terminal_id
    before = conn.bytes
    conn.write([
        {"id": 2, "cmd": "set-client-info", "name": DEVICE_NAME, "kind": "ios", "device_kind": "iphone",
         "device_name": DEVICE_NAME, "device_id": DEVICE_ID, "capabilities": ATTACH_CAPABILITIES},
        {"id": 3, "cmd": "identify"},
        params,
    ])
    vt_bytes = None
    while vt_bytes is None:
        message, size_of_line = conn.read()
        if message.get("event") == "vt-state" and message.get("surface") == surface:
            vt_bytes = size_of_line
        elif message.get("id") in (2, 3, 4) and not message.get("ok"):
            fail(f"pipelined reattach: request {message['id']} failed: {message.get('error')}")
    total_ms = (time.monotonic() - started) * 1000
    steps = {"resolve_ms": 0.0, "setup_ms": 0.0, "attach_ms": round(total_ms, 3)}
    sample = {"wall_ms": round(total_ms, 3), "bytes": conn.bytes, "round_trips": 1, "steps": steps,
              "attach_bytes": conn.bytes - before, "vt_state_bytes": vt_bytes,
              "sized": sized, "replay_history_rows": 0 if tail else None}
    return sample


def attach_once(path, terminal_id, surface, size, with_resolve=True, known=None):
    """The phone's reattach on a fresh connection; returns the sample and the open connection.
    known: the capabilities of its earlier identify (None: unknown, the serial path)."""
    conn = Connection(path)
    steps = {}
    started = time.monotonic()
    rtts = 0
    if known is not None and ATTACH_TERMINAL_ID_CAPABILITY in known:
        return attach_pipelined(conn, terminal_id, surface, size, known, started), conn
    if with_resolve:
        reply = conn.call({"id": 1, "cmd": "resolve-terminal", "terminal_id": terminal_id})
        if reply.get("surface") != surface:
            fail(f"resolve-terminal named surface {reply.get('surface')}, expected {surface}")
        steps["resolve_ms"] = round((time.monotonic() - started) * 1000, 3)
        rtts += 1
    mark = time.monotonic()
    conn.write([
        {"id": 2, "cmd": "set-client-info", "name": DEVICE_NAME, "kind": "ios", "device_kind": "iphone",
         "device_name": DEVICE_NAME, "device_id": DEVICE_ID, "capabilities": ATTACH_CAPABILITIES},
        {"id": 3, "cmd": "identify"},
    ])
    identify = None
    pending = {2, 3}
    while pending:
        message, _ = conn.read()
        if message.get("id") in pending:
            if not message.get("ok"):
                fail(f"reattach: set-client-info/identify failed: {message.get('error')}")
            pending.discard(message["id"])
            if message["id"] == 3:
                identify = message.get("data") or {}
    steps["setup_ms"] = round((time.monotonic() - mark) * 1000, 3)
    rtts += 1
    capabilities = identify.get("capabilities") or []
    params, sized, tail = attach_params(4, surface, size, capabilities)
    mark = time.monotonic()
    conn.write([params])
    vt_ms = None
    vt_bytes = None
    before_attach = conn.bytes
    while vt_ms is None:
        message, size_of_line = conn.read()
        if message.get("event") == "vt-state" and message.get("surface") == surface:
            vt_ms = (time.monotonic() - mark) * 1000
            vt_bytes = size_of_line
        elif message.get("id") == 4 and not message.get("ok"):
            fail(f"attach-surface failed: {message.get('error')}")
    steps["attach_ms"] = round(vt_ms, 3)
    rtts += 1
    total_ms = (time.monotonic() - started) * 1000
    sample = {"wall_ms": round(total_ms, 3), "bytes": conn.bytes, "round_trips": rtts, "steps": steps,
              "attach_bytes": conn.bytes - before_attach, "vt_state_bytes": vt_bytes,
              "sized": sized, "replay_history_rows": 0 if tail else None}
    return sample, conn


def scenario_reattach(binary, runs, scales):
    daemon = Daemon(binary)
    rows = []
    try:
        index = 0
        known = probe_capabilities(daemon.socket)
        for scale in scales:
            collected = {"attach": [], "reconnect": [], "same_size": []}
            for _ in range(runs):
                # attach, then reconnect from a second connection while the first is detached.
                index += 1
                terminal_id, surface = make_terminal(daemon, scale, index)
                first, conn = attach_once(daemon.socket, terminal_id, surface, (PHONE_COLS, PHONE_ROWS), known=known)
                conn.close()
                second, conn = attach_once(daemon.socket, terminal_id, surface, (PHONE_COLS, PHONE_ROWS), known=known)
                conn.close()
                collected["attach"].append(first)
                collected["reconnect"].append(second)
                # No size change: attach at the grid the terminal already has.
                index += 1
                terminal_id, surface = make_terminal(daemon, scale, index)
                same, conn = attach_once(daemon.socket, terminal_id, surface, (MAC_COLS, MAC_ROWS), known=known)
                conn.close()
                collected["same_size"].append(same)
            for variant, samples in collected.items():
                rows.append({"scenario": "reattach", "variant": variant, "scale": scale,
                             "scale_unit": "scrollback lines",
                             "round_trips": samples[0]["round_trips"], "runs": samples})
    finally:
        daemon.stop()
    return rows


# report ----------------------------------------------------------------------------------------

def summarize(row):
    walls = [sample["wall_ms"] for sample in row["runs"]]
    sizes = [sample["bytes"] for sample in row["runs"]]
    summary = {"daemon_ms": stats(walls), "bytes": stats(sizes), "round_trips": row["round_trips"]}
    summary["modeled_ms"] = modeled(pct(walls, 0.5), row["round_trips"], pct(sizes, 0.5))
    if row["scenario"] == "setup":
        names = sorted({name for sample in row["runs"] for name in sample["reply_bytes"]})
        summary["reply_bytes_p50"] = {
            name: pct([sample["reply_bytes"].get(name, 0) for sample in row["runs"]], 0.5) for name in names}
    else:
        for step in ("resolve_ms", "setup_ms", "attach_ms"):
            summary[step] = stats([sample["steps"][step] for sample in row["runs"]])
        summary["vt_state_bytes"] = stats([sample["vt_state_bytes"] for sample in row["runs"]])
    return summary


def table(rows):
    lines = ["| scenario | scale | round trips | bytes to first content | daemon ms p50/p95 | wifi (20 ms, 50 Mbit) | "
             "LTE (70 ms, 12 Mbit) | bad cellular (300 ms, 1 Mbit) |",
             "|---|---|---|---|---|---|---|---|"]
    for row in rows:
        s = row["summary"]
        name = row["scenario"] if row["variant"] == row["scenario"] else f"{row['scenario']}/{row['variant']}"
        lines.append(f"| {name} | {row['scale']} {row['scale_unit']} | {s['round_trips']} | "
                     f"{int(s['bytes']['p50'])} | {s['daemon_ms']['p50']:.1f}/{s['daemon_ms']['p95']:.1f} | "
                     f"{s['modeled_ms']['wifi']:.0f} ms | {s['modeled_ms']['lte']:.0f} ms | "
                     f"{s['modeled_ms']['bad']:.0f} ms |")
    return "\n".join(lines)


def details(rows):
    out = []
    for row in rows:
        s = row["summary"]
        name = f"{row['scenario']}/{row['variant']} {row['scale']} {row['scale_unit']}"
        if row["scenario"] == "setup":
            parts = ", ".join(f"{k} {int(v)} B" for k, v in s["reply_bytes_p50"].items())
            out.append(f"{name}: reply bytes p50: {parts}")
        else:
            out.append(f"{name}: resolve {s['resolve_ms']['p50']:.1f} ms, set-client-info+identify "
                       f"{s['setup_ms']['p50']:.1f} ms, attach-surface to vt-state {s['attach_ms']['p50']:.1f} ms "
                       f"(p95 {s['attach_ms']['p95']:.1f}), vt-state {int(s['vt_state_bytes']['p50'])} B")
    by_scale = {}
    for row in rows:
        if row["scenario"] == "reattach":
            by_scale.setdefault(row["scale"], {})[row["variant"]] = row["summary"]["attach_ms"]["p50"]
    for scale, variants in by_scale.items():
        if "attach" in variants and "same_size" in variants:
            out.append(f"reattach {scale} lines: settle_hosted_viewer_size estimate "
                       f"(attach - same_size, attach-surface p50) = {variants['attach'] - variants['same_size']:.1f} ms")
    return "\n".join(out)


def git_sha():
    try:
        return subprocess.run(["git", "rev-parse", "HEAD"], capture_output=True, text=True, check=True,
                              cwd=os.path.dirname(os.path.abspath(__file__))).stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return "unknown"


def compare(before_path, after_path):
    def load(path):
        with open(path) as handle:
            report = json.load(handle)
        return report, {(r["scenario"], r["variant"], r["scale"]): r["summary"] for r in report["rows"]}
    before_report, before = load(before_path)
    after_report, after = load(after_path)
    print(f"before {before_report.get('git_sha')} {before_report.get('binary')}")
    print(f"after  {after_report.get('git_sha')} {after_report.get('binary')}")
    print("| scenario | scale | round trips | bytes p50 | daemon ms p50 | LTE modeled ms |")
    print("|---|---|---|---|---|---|")
    for key in after:
        a = after[key]
        b = before.get(key)
        name = key[0] if key[0] == key[1] else f"{key[0]}/{key[1]}"
        if b is None:
            print(f"| {name} | {key[2]} | {a['round_trips']} | {int(a['bytes']['p50'])} | "
                  f"{a['daemon_ms']['p50']:.1f} | {a['modeled_ms']['lte']:.0f} |")
            continue
        print(f"| {name} | {key[2]} | {b['round_trips']} -> {a['round_trips']} | "
              f"{int(b['bytes']['p50'])} -> {int(a['bytes']['p50'])} | "
              f"{b['daemon_ms']['p50']:.1f} -> {a['daemon_ms']['p50']:.1f} | "
              f"{b['modeled_ms']['lte']:.0f} -> {a['modeled_ms']['lte']:.0f} |")


def ints(text):
    try:
        values = [int(part) for part in text.split(",") if part]
    except ValueError:
        fail(f"not a comma list of integers: {text!r}")
    if not values or any(value < 1 for value in values):
        fail(f"need positive integers: {text!r}")
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    default_binary = "cmux-tui/target/release/cmux-tui"
    parser.add_argument("--binary", default=default_binary if os.path.exists(default_binary) else None)
    parser.add_argument("--runs", type=int, default=10)
    parser.add_argument("--scenarios", default="setup,reattach")
    parser.add_argument("--out", default=".build/mobile-open-path/report.json")
    parser.add_argument("--workspaces", default="10,100,1000")
    parser.add_argument("--scrollback-lines", default="1000,10000,100000")
    parser.add_argument("--compare", nargs=2, metavar=("BEFORE", "AFTER"))
    args = parser.parse_args()
    if args.compare:
        compare(*args.compare)
        return
    if not args.binary or not os.path.exists(args.binary):
        fail("--binary PATH is required (default cmux-tui/target/release/cmux-tui does not exist)")
    if args.runs < 1:
        fail("--runs must be at least 1")
    scenarios = [name for name in args.scenarios.split(",") if name]
    for name in scenarios:
        if name not in ("setup", "reattach"):
            fail(f"unknown scenario {name!r} (setup, reattach; chat is out of scope)")
    sha = git_sha()
    binary = os.path.abspath(args.binary)
    print(f"mobile-open-path: git {sha}, binary {binary}, runs {args.runs}")
    rows = []
    if "setup" in scenarios:
        rows += scenario_setup(binary, args.runs, ints(args.workspaces))
    if "reattach" in scenarios:
        rows += scenario_reattach(binary, args.runs, ints(args.scrollback_lines))
    for row in rows:
        row["summary"] = summarize(row)
    report = {"git_sha": sha, "binary": binary, "runs_per_row": args.runs, "links": [
        {"name": n, "rtt_ms": r, "mbit": m} for n, r, m in LINKS], "rows": rows}
    out_dir = os.path.dirname(args.out)
    if out_dir:
        os.makedirs(out_dir, exist_ok=True)
    with open(args.out, "w") as handle:
        json.dump(report, handle, indent=1)
    print(f"\ngit {sha}  binary {binary}\n")
    print(table(rows))
    print()
    print(details(rows))
    print(f"\nreport: {args.out}")


if __name__ == "__main__":
    main()
