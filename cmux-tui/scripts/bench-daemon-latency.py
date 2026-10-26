#!/usr/bin/env python3
"""Request latency of one headless cmux-tui daemon (perf-10x daemon area, p05-ipc).

Starts an isolated headless daemon (durable state on the local disk), grows a
scenario, and measures the client-side round trip (send to reply) of control
requests on JSON-lines connections. Every latency row comes from the raw
samples: n, p50, p95, p99, max (nearest rank), the mean as an extra, and the
samples themselves. No row is a mean alone.

Scenarios (--scenario, repeatable or comma list):
  small   1 workspace, 1 terminal
  scale   50 workspaces, 200 terminals, 5% of them printing steadily

Sections per scenario (keys of result["scenarios"][NAME]):
  ops          one row per op of --ops: base (ping, identify, list-workspaces,
               send, new-tab), create (every creation: v12 and v2 creates,
               split, browser tab, tab groups), all (every op of OPS, which
               covers ipc5_ops of plans/cmux-next/ipc-targets.json), or a
               comma list of op names. Row keys: n, p50_ms, p95_ms, p99_ms,
               max_ms, mean_ms, samples_ms, wire (v12|v2), kind (read|write|
               create). A row the daemon does not serve has `skipped`
               (capability not advertised, or command unknown); a row that
               failed has `error`. Setup and cleanup of each sample run
               outside the timed window on the same connection.
  concurrent   c10-ping, c10-identify, c10-list-workspaces: 10 clients at once
  cli          cli-ping, cli-workspace-list, cli-terminal-write (process start
               to exit through CMUX_TUI_SOCKET), cli-version-no-socket
  syscalls     daemon syscalls and context switches per message for ping,
               send and list-workspaces: (delta over a burst - idle rate x
               burst time) / messages. `method` names the counter: macOS
               proc_pidinfo(PROC_PIDTASKINFO) unix + mach syscalls; Linux
               context switches only (its /proc syscall counters miss
               sendmsg, recvmsg and poll; Linux rows are not perf evidence). Keys per
               op: messages, burst_s, syscalls_per_msg, ctx_per_msg,
               syscalls_idle_per_s, ctx_idle_per_s, and server_stats_ipc_per_msg
               (each numeric counter of `server-stats include=[ipc]`, such as
               write syscalls and wakeups, per message) once the daemon serves
               that section (p05-ipc-082); before, `server_stats_ipc` says so.
  bulk_interference  (--bulk-interference [KiB,...], default 16,32,64) per
               chunk size K: a terminal writes --flood-mib MiB in K-byte
               writes while it is attached on connection A. bulkK-ping-same:
               ping on A while A carries the flood (head of line, IPC-8);
               bulkK-ping-other: ping from another process on its own
               connection; idle-ping-same: A before the flood. Also
               flood_mib_per_s, output_events, ended (marker|detached|timeout).
  streams      (--streams N) N printing terminals attached and a ping on the
               control connection meanwhile. views_per_connection: today's
               shape, one attach connection per view (always runs);
               streams_one_connection: N client-minted streams on the control
               connection (attach-streams-v1; skipped when not advertised).
               Keys: attach-ms, ping-ms, daemon_threads_before/after,
               connections_active.
  automation_storm  (--automation-storm N) the app's key echo (raw `cat`
               behind the attach connection) and split on its control
               connection, idle and while N automation processes loop
               list-workspaces / send / rename-workspace / identify on their
               own connections. Keys: idle.echo, idle.split, alone (automation
               throughput without the app), storm.echo, storm.split,
               storm.automation, ipc16 (echo p95 <= idle + 1 ms, split p95 <
               2 ms, automation >= 50% of alone).

Top level: host (hostname, os, os_version, macos, cpu, cores, load, python),
source (sha, dirty), daemon (version, protocol, build_commit, capabilities),
args, scenarios, q16.

--write-q16 writes runtime.Q16 of ipc-targets.json (p05-ipc queue Q16: ops
with p95 > 2 ms in --ops all --scenario scale; scripts/cmux-next/ipc-census.py
reads it). It needs a macOS host: VM timing is not perf evidence.

Usage:
  bench-daemon-latency.py --bin target/release/cmux-tui --out result.json
  bench-daemon-latency.py --bin ... --ops all --scenario scale \\
      --bulk-interference --streams 8 --automation-storm 8 --out r.json [--write-q16]
"""

import argparse
import binascii
import ctypes
import itertools
import json
import math
import multiprocessing
import os
import platform
import select
import shutil
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time
import traceback

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(SCRIPT_DIR))
SDK_SCHEMA = os.path.join(SCRIPT_DIR, "..", "spec", "sdk-schema.json")
TARGETS = os.path.join(REPO_ROOT, "plans", "cmux-next", "ipc-targets.json")
SCRIPT_REL = "cmux-tui/scripts/bench-daemon-latency.py"
Q16_THRESHOLD_MS = 2.0
V2_PROTOCOL = "cmux.protocol/2"
SCENARIOS = {"small": (1, 1, 0.0), "scale": (50, 200, 0.05)}


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


class DaemonError(RuntimeError):
    """A request the daemon answered with ok:false."""

    def __init__(self, what, msg):
        err = msg.get("error")
        code = msg.get("error_code") or (err.get("code") if isinstance(err, dict) else None)
        text = err.get("message") if isinstance(err, dict) else err
        super().__init__(f"{what}: {code or ''} {text!r}".strip())
        self.code = code
        self.text = str(text or "")


# ---------------------------------------------------------------------------------------------
# Connection


class Conn:
    """One JSON-lines connection. Events go to `on_event`; replies are matched by id.

    The line reader keeps one buffer and an offset, so a flood of large output lines
    costs one copy per byte, not one per line."""

    def __init__(self, path, timeout=60, on_event=None):
        self.sock = socket.socket(socket.AF_UNIX)
        self.sock.settimeout(timeout)
        self.sock.connect(path)
        self.buf = bytearray()
        self.pos = 0
        self.next_id = 1
        self.on_event = on_event
        self.replies = {}

    def close(self):
        try:
            self.sock.close()
        except OSError:
            pass

    def _fill(self):
        chunk = self.sock.recv(1 << 20)
        if not chunk:
            raise ConnectionError("control socket closed")
        if self.pos and self.pos * 2 >= len(self.buf):
            del self.buf[: self.pos]
            self.pos = 0
        self.buf += chunk

    def _next_line(self):
        while True:
            i = self.buf.find(b"\n", self.pos)
            if i >= 0:
                line = bytes(self.buf[self.pos : i])
                self.pos = i + 1
                return line
            self._fill()

    def _buffered_line(self):
        i = self.buf.find(b"\n", self.pos)
        if i < 0:
            return None
        line = bytes(self.buf[self.pos : i])
        self.pos = i + 1
        return line

    def _dispatch(self, line):
        """Routes one line; returns the message when it is a reply."""
        if line.startswith(b'{"event":"output"'):
            if self.on_event:
                self.on_event(line, None)
            return None
        msg = json.loads(line)
        if "event" in msg or msg.get("type") in ("stream_item", "stream_end"):
            if self.on_event:
                self.on_event(line, msg)
            return None
        return msg

    def read_line(self):
        """The next reply (events go to on_event)."""
        while True:
            msg = self._dispatch(self._next_line())
            if msg is not None:
                return msg

    def wait_reply(self, rid):
        if rid in self.replies:
            return self.replies.pop(rid)
        while True:
            msg = self.read_line()
            if msg.get("id") == rid:
                return msg
            if "id" in msg:
                self.replies[msg["id"]] = msg

    def send(self, cmd, **params):
        rid = self.next_id
        self.next_id += 1
        self.sock.sendall((json.dumps({"id": rid, "cmd": cmd, **params}) + "\n").encode())
        return rid

    def call(self, cmd, **params):
        return self.wait_reply(self.send(cmd, **params))

    def timed(self, cmd, **params):
        t = time.perf_counter()
        msg = self.call(cmd, **params)
        return (time.perf_counter() - t) * 1000, msg

    def v2(self, operation, params, key=None):
        rid = f"b{self.next_id}"
        self.next_id += 1
        env = {"protocol": V2_PROTOCOL, "type": "request", "id": rid, "operation": operation,
               "params": {"machine": "current", "session": "current", **params}}
        if key is not None:
            env["idempotency_key"] = key
        self.sock.sendall((json.dumps(env) + "\n").encode())
        return self.wait_reply(rid)

    def timed_v2(self, operation, params, key=None):
        t = time.perf_counter()
        msg = self.v2(operation, params, key)
        return (time.perf_counter() - t) * 1000, msg

    def pump(self, seconds):
        """Handles every line that arrives within `seconds`; replies are kept by id."""
        deadline = time.perf_counter() + seconds
        while True:
            line = self._buffered_line()
            if line is not None:
                msg = self._dispatch(line)
                if msg is not None and "id" in msg:
                    self.replies[msg["id"]] = msg
                continue
            left = deadline - time.perf_counter()
            if left <= 0:
                return
            readable, _, _ = select.select([self.sock], [], [], left)
            if readable:
                self._fill()


def must(resp, what):
    if not resp.get("ok"):
        raise DaemonError(what, resp)
    if resp.get("protocol") == V2_PROTOCOL:
        return resp.get("result")
    return resp.get("data") or {}


def output_bytes(line):
    """Decoded bytes of an `output` event line, without parsing the JSON."""
    start = line.find(b'"data":"')
    if start < 0:
        return b""
    start += 8
    end = line.find(b'"', start)
    try:
        return binascii.a2b_base64(line[start:end])
    except binascii.Error:
        return b""


# ---------------------------------------------------------------------------------------------
# Statistics and host record


def pick(sorted_vals, q):
    """Nearest-rank percentile of sorted raw samples."""
    rank = max(1, math.ceil(q * len(sorted_vals) - 1e-9))
    return sorted_vals[min(len(sorted_vals), rank) - 1]


def stats(vals, keep_samples=True):
    if not vals:
        return {"n": 0}
    s = sorted(vals)
    row = {
        "n": len(s),
        "p50_ms": round(pick(s, 0.5), 3),
        "p95_ms": round(pick(s, 0.95), 3),
        "p99_ms": round(pick(s, 0.99), 3),
        "max_ms": round(s[-1], 3),
        "mean_ms": round(statistics.fmean(s), 3),
    }
    if keep_samples:
        row["samples_ms"] = [round(v, 4) for v in vals]
    return row


def _run(argv):
    try:
        return subprocess.run(argv, capture_output=True, text=True, timeout=10).stdout.strip()
    except (OSError, subprocess.SubprocessError):
        return ""


def host_info():
    system = platform.system()
    cpu = ""
    if system == "Darwin":
        cpu = _run(["sysctl", "-n", "machdep.cpu.brand_string"])
        name = _run(["scutil", "--get", "ComputerName"]) or socket.gethostname()
    else:
        name = socket.gethostname()
        try:
            with open("/proc/cpuinfo") as f:
                cpu = next((ln.split(":", 1)[1].strip() for ln in f if ln.startswith("model name")), "")
        except OSError:
            pass
    return {
        "hostname": name,
        "os": system,
        "os_version": platform.mac_ver()[0] if system == "Darwin" else platform.release(),
        "macos": platform.mac_ver()[0] or None,
        "arch": platform.machine(),
        "cpu": cpu,
        "cores": os.cpu_count(),
        "load": [round(v, 2) for v in os.getloadavg()],
        "python": platform.python_version(),
    }


def source_info():
    sha = _run(["git", "-C", REPO_ROOT, "rev-parse", "HEAD"])
    dirty = _run(["git", "-C", REPO_ROOT, "status", "--porcelain", "--untracked-files=no"])
    return {"sha": sha or None, "dirty": bool(dirty)}


# ---------------------------------------------------------------------------------------------
# Daemon process counters (syscalls, context switches, threads)


class _ProcTaskInfo(ctypes.Structure):
    _fields_ = [(n, ctypes.c_uint64) for n in ("virtual_size", "resident_size", "total_user", "total_system",
                                                "threads_user", "threads_system")] + \
               [(n, ctypes.c_int32) for n in ("policy", "faults", "pageins", "cow_faults", "messages_sent",
                                               "messages_received", "syscalls_mach", "syscalls_unix", "csw",
                                               "threadnum", "numrunning", "priority")]


class ProcCounters:
    """Cumulative syscall and context-switch counts of one process, or None when unsupported."""

    def __init__(self, pid):
        self.pid = pid
        self.method = None
        if sys.platform == "darwin":
            try:
                self.libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
                self.method = "macos proc_pidinfo PROC_PIDTASKINFO: syscalls_unix + syscalls_mach, csw"
            except OSError:
                pass
        elif os.path.exists(f"/proc/{pid}/io"):
            self.method = ("linux: context switches summed over live threads (/proc/PID/task/TID/status); no "
                           "syscall count: /proc io syscr/syscw see only read/write-class calls, not sendmsg, "
                           "recvmsg or poll")

    def sample(self):
        if self.method is None:
            return None
        if sys.platform == "darwin":
            info = _ProcTaskInfo()
            size = self.libproc.proc_pidinfo(self.pid, 4, ctypes.c_uint64(0), ctypes.byref(info), ctypes.sizeof(info))
            if size != ctypes.sizeof(info):
                return None
            return {"syscalls": info.syscalls_unix + info.syscalls_mach, "ctx": info.csw, "threads": info.threadnum}
        try:
            tasks = os.listdir(f"/proc/{self.pid}/task")
        except OSError:
            return None
        ctx = 0
        for tid in tasks:
            try:
                with open(f"/proc/{self.pid}/task/{tid}/status") as f:
                    for ln in f:
                        if ln.startswith(("voluntary_ctxt_switches", "nonvoluntary_ctxt_switches")):
                            ctx += int(ln.split(":", 1)[1])
            except (OSError, ValueError):
                pass  # the thread ended between listdir and open
        return {"syscalls": None, "ctx": ctx, "threads": len(tasks)}

    def threads(self):
        s = self.sample()
        return s["threads"] if s else None


# ---------------------------------------------------------------------------------------------
# Ops: one plan per op. A plan does its setup and cleanup untimed and returns the timed ms.

OPS = {}


def op(name, wire="v12", kind="read", capability=None):
    def register(fn):
        OPS[name] = {"fn": fn, "wire": wire, "kind": kind, "capability": capability,
                     "line": fn.__code__.co_firstlineno}
        return fn
    return register


BASE_OPS = ["ping", "identify", "list-workspaces", "send", "new-tab"]


def select_ops(spec):
    if spec == "base":
        return list(BASE_OPS)
    if spec == "all":
        return list(OPS)
    if spec == "create":
        return [name for name, plan in OPS.items() if plan["kind"] == "create"]
    names = [n for n in spec.split(",") if n]
    unknown = [n for n in names if n not in OPS]
    if unknown:
        raise SystemExit(f"--ops: unknown op(s) {', '.join(unknown)}; known: {', '.join(OPS)}")
    return names


def ipc5_ops():
    """The IPC-5 op list of ipc-targets.json; `--ops all` must cover it."""
    try:
        with open(TARGETS, encoding="utf-8") as f:
            return json.load(f).get("ipc5_ops") or []
    except (OSError, ValueError):
        return []


def schema_capabilities():
    try:
        with open(SDK_SCHEMA) as f:
            schema = json.load(f)
    except (OSError, ValueError):
        return {}
    commands = schema.get("commands") or {}
    if isinstance(commands, dict):
        return {name: (c or {}).get("capability") for name, c in commands.items()}
    return {c["name"]: c.get("capability") for c in commands}


class OpsFixture:
    """A workspace of its own: one pane with tabs T1..T5 and tab group G (holding T1)."""

    def __init__(self, bench, conn):
        self.b = bench
        self.c = conn
        self.keys = itertools.count(1)
        self.closer = "close-tabs" if bench.has("batch-close-v1") else "close-surface"

    def key(self):
        return f"bench-{os.getpid()}-{next(self.keys)}"

    def setup(self):
        c = self.c
        first = must(c.call("new-workspace", name=f"bench-ops-{os.getpid()}", cols=80, rows=24), "new-workspace")
        s0 = first["surface"]
        ws, pane = self.b.locate(c, s0)
        self.ws_id, self.ws_rid = ws["id"], ws.get("resource_id")
        self.pane, self.pane_rid = pane["id"], pane.get("resource_id")
        self.tabs = [s0] + [must(c.call("new-tab", pane=self.pane, cols=80, rows=24), "new-tab")["surface"]
                            for _ in range(5)]
        self.send_surface = self.b.first_surface(c)
        self.group = None
        if self.b.has("tab-groups-v1"):
            self.group = must(c.call("create-tab-group", surfaces=[self.tabs[1]], name="bench-g"),
                              "create-tab-group")["group"]["id"]

    def teardown(self):
        try:
            self.c.call("close-workspace", workspace=self.ws_id, end_terminals=True)
        except (OSError, ConnectionError):
            pass

    def close(self, surface):
        if self.closer == "close-tabs":
            must(self.c.call("close-tabs", surfaces=[surface], end_terminals=True), "close-tabs")
        else:
            must(self.c.call("close-surface", surface=surface), "close-surface")

    def timed(self, cmd, **params):
        ms, msg = self.c.timed(cmd, **params)
        return ms, must(msg, cmd)

    def timed_v2(self, operation, params, mutation=False):
        ms, msg = self.c.timed_v2(operation, params, self.key() if mutation else None)
        return ms, must(msg, operation)

    def new_tab(self):
        return must(self.c.call("new-tab", pane=self.pane, cols=80, rows=24), "new-tab")["surface"]


@op("ping")
def _op_ping(f, i):
    return f.timed("ping")[0]


@op("identify")
def _op_identify(f, i):
    return f.timed("identify")[0]


@op("list-workspaces")
def _op_list_workspaces(f, i):
    return f.timed("list-workspaces")[0]


@op("send", kind="write")
def _op_send(f, i):
    return f.timed("send", surface=f.send_surface, text=":\r")[0]


@op("new-tab", kind="create")
def _op_new_tab(f, i):
    ms, data = f.timed("new-tab", pane=f.pane, cols=80, rows=24)
    f.close(data["surface"])
    return ms


@op("create-terminal", kind="create", capability="workspace-registry-v1")
def _op_create_terminal(f, i):
    ms, data = f.timed("create-terminal", workspace=f.ws_id, argv=["/bin/sh"], cols=80, rows=24)
    f.close(data["surface"])
    return ms


@op("split", kind="create")
def _op_split(f, i):
    ms, data = f.timed("split", pane=f.pane, dir="right", cols=80, rows=24)
    f.close(data["surface"])
    return ms


@op("close-surface", kind="write")
def _op_close_surface(f, i):
    return f.timed("close-surface", surface=f.new_tab())[0]


@op("close-tabs", kind="write", capability="batch-close-v1")
def _op_close_tabs(f, i):
    return f.timed("close-tabs", surfaces=[f.new_tab()], end_terminals=True)[0]


@op("rename-workspace", kind="write")
def _op_rename_workspace(f, i):
    return f.timed("rename-workspace", workspace=f.ws_id, name=f"bench-ops-{i % 2}")[0]


@op("select-tab", kind="write")
def _op_select_tab(f, i):
    return f.timed("select-tab", pane=f.pane, index=i % 2)[0]


@op("select-workspace", kind="write")
def _op_select_workspace(f, i):
    return f.timed("select-workspace", index=i % 2)[0]


@op("move-tab", kind="write")
def _op_move_tab(f, i):
    return f.timed("move-tab", surface=f.tabs[5], pane=f.pane, index=0 if i % 2 else 99)[0]


@op("new-frontend-browser-tab", kind="create", capability="frontend-browser-tabs-v1")
def _op_new_frontend_browser_tab(f, i):
    ms, data = f.timed("new-frontend-browser-tab", url="about:blank", engine="webkit", pane=f.pane)
    f.close(data["surface"])
    return ms


@op("create-tab-group", kind="create", capability="tab-groups-v1")
def _op_create_tab_group(f, i):
    ms, data = f.timed("create-tab-group", surfaces=[f.tabs[3], f.tabs[4]], name="bench-new")
    must(f.c.call("ungroup-tab-group", group=data["group"]["id"]), "ungroup-tab-group")
    return ms


@op("update-tab-group", kind="write", capability="tab-groups-v1")
def _op_update_tab_group(f, i):
    return f.timed("update-tab-group", group=f.group, name=f"bench-g{i % 2}")[0]


@op("add-tabs-to-tab-group", kind="write", capability="tab-groups-v1")
def _op_add_tabs_to_tab_group(f, i):
    ms, _ = f.timed("add-tabs-to-tab-group", group=f.group, surfaces=[f.tabs[2]])
    must(f.c.call("remove-tabs-from-tab-group", surfaces=[f.tabs[2]]), "remove-tabs-from-tab-group")
    return ms


@op("remove-tabs-from-tab-group", kind="write", capability="tab-groups-v1")
def _op_remove_tabs_from_tab_group(f, i):
    must(f.c.call("add-tabs-to-tab-group", group=f.group, surfaces=[f.tabs[2]]), "add-tabs-to-tab-group")
    return f.timed("remove-tabs-from-tab-group", surfaces=[f.tabs[2]])[0]


@op("move-tab-group", kind="write", capability="tab-groups-v1")
def _op_move_tab_group(f, i):
    return f.timed("move-tab-group", group=f.group, index=99 if i % 2 else 0)[0]


@op("ungroup-tab-group", kind="write", capability="tab-groups-v1")
def _op_ungroup_tab_group(f, i):
    data = must(f.c.call("create-tab-group", surfaces=[f.tabs[3], f.tabs[4]], name="bench-new"), "create-tab-group")
    return f.timed("ungroup-tab-group", group=data["group"]["id"])[0]


@op("close-tab-group", kind="create", capability="tab-groups-v1")
def _op_close_tab_group(f, i):
    tabs = [f.new_tab(), f.new_tab()]
    data = must(f.c.call("create-tab-group", surfaces=tabs, name="bench-close"), "create-tab-group")
    return f.timed("close-tab-group", group=data["group"]["id"], end_terminals=True)[0]


@op("workspace.create", wire="v2", kind="create")
def _op_workspace_create(f, i):
    ms, res = f.timed_v2("workspace.create", {"initial_content": "terminal", "name": f"bench-v2-{i}"}, mutation=True)
    must(f.c.v2("workspace.close", {"workspace": res["value"]["workspace_id"]}, f.key()), "workspace.close")
    return ms


@op("tab.create_terminal", wire="v2", kind="create")
def _op_tab_create_terminal(f, i):
    ms, res = f.timed_v2("tab.create_terminal", {"workspace": f.ws_rid, "pane": f.pane_rid, "cols": 80, "rows": 24},
                         mutation=True)
    must(f.c.v2("tab.close", {"tab": res["value"]["tab_id"]}, f.key()), "tab.close")
    return ms


@op("pane.split", wire="v2", kind="create")
def _op_pane_split(f, i):
    ms, res = f.timed_v2("pane.split", {"workspace": f.ws_rid, "pane": f.pane_rid, "direction": "right",
                                        "cols": 80, "rows": 24}, mutation=True)
    must(f.c.v2("pane.close", {"pane": res["value"]["pane_id"]}, f.key()), "pane.close")
    return ms


@op("pane.create", wire="v2", kind="create")
def _op_pane_create(f, i):
    ms, res = f.timed_v2("pane.create", {"workspace": f.ws_rid, "cols": 80, "rows": 24}, mutation=True)
    must(f.c.v2("pane.close", {"pane": res["value"]["pane_id"]}, f.key()), "pane.close")
    return ms


@op("workspace.ensure_home", wire="v2", kind="write", capability="workspace-kind-v1")
def _op_workspace_ensure_home(f, i):
    return f.timed_v2("workspace.ensure_home", {}, mutation=True)[0]


def unserved_reason(err):
    """Why an op is not served, or None when the error is a real failure."""
    text = err.text.lower()
    if text.startswith("bad request: unknown variant"):
        return "not served by this daemon (unknown command)"
    if err.code == "validation.invalid" and "invalid request envelope" in text:
        return "not served by this daemon (unknown v2 operation)"
    return None


# ---------------------------------------------------------------------------------------------
# Out-of-process clients (no GIL contention with the measuring thread)


def pinger_main(sock_path, start_at, stop_at, stop, interval, queue):
    """Pings on its own connection from start_at until `stop` is set or stop_at passes."""
    vals = []
    try:
        c = Conn(sock_path)
        while time.time() < start_at:
            time.sleep(0.005)
        while time.time() < stop_at and not stop.is_set():
            ms, msg = c.timed("ping")
            if msg.get("ok"):
                vals.append(ms)
            time.sleep(interval)
        c.close()
        queue.put({"samples": vals})
    except Exception as e:  # noqa: BLE001
        queue.put({"samples": vals, "error": repr(e)})


AUTOMATION_MIX = ("list-workspaces", "send", "rename-workspace", "identify")


def automation_main(sock_path, workspace, surface, start_at, stop_at, queue):
    vals = []
    try:
        c = Conn(sock_path)
        c.call("set-client-info", name="bench-automation", kind="agent")
        while time.time() < start_at:
            time.sleep(0.002)
        for i in itertools.count():
            if time.time() >= stop_at:
                break
            cmd = AUTOMATION_MIX[i % len(AUTOMATION_MIX)]
            params = {"send": {"surface": surface, "text": ":\r"},
                      "rename-workspace": {"workspace": workspace, "name": f"bench-agent-{i % 2}"}}.get(cmd, {})
            ms, msg = c.timed(cmd, **params)
            if not msg.get("ok"):
                raise DaemonError(cmd, msg)
            vals.append(ms)
        c.close()
        queue.put({"samples": vals, "seconds": stop_at - start_at})
    except Exception as e:  # noqa: BLE001
        queue.put({"samples": vals, "seconds": stop_at - start_at, "error": repr(e)})


SPAWN = multiprocessing.get_context("spawn")


def run_processes(targets):
    """Starts one spawn process per (fn, args) and returns (processes, result queue)."""
    ctx = SPAWN
    queue = ctx.Queue()
    procs = [ctx.Process(target=fn, args=(*args, queue), daemon=True) for fn, args in targets]
    for p in procs:
        p.start()
    return procs, queue


def collect(procs, queue, timeout):
    results = []
    deadline = time.time() + timeout
    for _ in procs:
        try:
            results.append(queue.get(timeout=max(1, deadline - time.time())))
        except Exception:  # noqa: BLE001
            results.append({"samples": [], "error": "client process did not report"})
    for p in procs:
        p.join(timeout=5)
        if p.is_alive():
            p.kill()
    return results


# ---------------------------------------------------------------------------------------------
# Bench


FLOOD_PERL = (
    '$|=1; my ($k, $n, $m) = @ARGV; my $line = ("x" x 79) . "\\n"; '
    'my $chunk = substr($line x (int($k / 80) + 1), 0, $k); my $go = <STDIN>; '
    'for (1..$n) { syswrite(STDOUT, $chunk) } print "\\n$m\\n"; my $end = <STDIN>;'
)
PRINTER_PERL = '$|=1; my $n=0; while (1) { print "stream ", $n++, " ", "y" x 60, "\\n"; select(undef,undef,undef,0.02); }'
BUSY_PERL = '$|=1; my $n=0; while (1) { print "busy ", $n++, " ", "x" x 60, "\\n"; select(undef,undef,undef,0.05); }'
ECHO_ARGV = ["/bin/sh", "-c", "stty raw -echo; exec cat"]


class Bench:
    def __init__(self, args):
        self.args = args
        self.root = tempfile.mkdtemp(prefix="pd.", dir="/private/tmp" if sys.platform == "darwin" else None)
        self.sock_path = os.path.join(self.root, "s.sock")
        self.session = f"perfd{os.getpid()}"
        self.daemon = None
        self.env = None
        self.caps = set()
        self.failed = False
        self.result = {"scenarios": {}}

    def has(self, capability):
        return capability in self.caps

    def start(self):
        home = os.path.join(self.root, "home")
        os.makedirs(home, exist_ok=True)
        env = dict(os.environ)
        for k in [k for k in env if k.startswith("CMUX")]:
            del env[k]
        env.update(
            HOME=home,
            XDG_CONFIG_HOME=os.path.join(home, ".config"),
            XDG_STATE_HOME=os.path.join(home, ".local/state"),
            XDG_DATA_HOME=os.path.join(home, ".local/share"),
            XDG_CACHE_HOME=os.path.join(home, ".cache"),
            CMUX_TUI_CONFIG=os.path.join(self.root, "config.json"),
            SHELL="/bin/sh",
        )
        self.env = env
        argv = [self.args.bin, "--headless", "--session", self.session, "--socket", self.sock_path,
                "--state", os.path.join(self.root, "state")]
        self.daemon_log = open(os.path.join(self.root, "daemon.log"), "a")
        self.daemon = subprocess.Popen(argv, stdout=self.daemon_log, stderr=subprocess.STDOUT, env=env,
                                       start_new_session=True)
        deadline = time.time() + 60
        while time.time() < deadline:
            if self.daemon.poll() is not None:
                raise RuntimeError(f"daemon exited {self.daemon.returncode}: {self.tail()}")
            if os.path.exists(self.sock_path):
                try:
                    c = Conn(self.sock_path)
                    self.ident = must(c.call("identify"), "identify")
                    c.close()
                    break
                except OSError:
                    pass
            time.sleep(0.1)
        else:
            raise RuntimeError("daemon socket never appeared: " + self.tail())
        self.caps = set(self.ident.get("capabilities") or [])
        self.counters = ProcCounters(self.ident.get("pid") or self.daemon.pid)
        self.result["daemon"] = {
            "version": self.ident.get("version"), "protocol": self.ident.get("protocol"),
            "build_commit": self.ident.get("build_commit"), "pid": self.ident.get("pid"),
            "capabilities": sorted(self.caps), "bin": os.path.abspath(self.args.bin),
        }
        log("daemon up", self.daemon.pid, self.ident.get("version"))

    def tail(self):
        try:
            with open(os.path.join(self.root, "daemon.log")) as f:
                return f.read()[-3000:]
        except OSError:
            return ""

    def stop(self):
        if not self.daemon:
            return
        try:
            c = Conn(self.sock_path, timeout=300)
            ident = must(c.call("identify"), "identify")
            c.call("shutdown-daemon", pid=ident["pid"],
                   generation=ident.get("generation") or ident.get("boot_generation") or "",
                   end_terminals=True)
            c.close()
        except Exception as e:  # noqa: BLE001
            log("shutdown failed", repr(e))
        try:
            self.daemon.wait(timeout=180)
        except subprocess.TimeoutExpired:
            self.daemon.kill()
        shutil.rmtree(self.root, ignore_errors=True)

    # -- topology

    def grow(self, workspaces, terminals, busy_fraction):
        c = Conn(self.sock_path, timeout=120)
        tree = must(c.call("list-workspaces"), "list-workspaces")
        have = len(tree.get("workspaces") or [])
        for i in range(have, workspaces):
            must(c.call("new-workspace", name=f"w{i}", cols=80, rows=24), "new-workspace")
        tree = must(c.call("list-workspaces"), "list-workspaces")
        ws_ids = [w["id"] for w in tree["workspaces"]]
        count = sum(1 for _ in self.surfaces(tree))
        busy_every = int(1 / busy_fraction) if busy_fraction > 0 else 0
        i = 0
        while count < terminals:
            busy = busy_every and i % busy_every == 0
            argv = ["perl", "-e", BUSY_PERL] if busy else ["/bin/sh"]
            must(c.call("create-terminal", workspace=ws_ids[i % len(ws_ids)], argv=argv, cols=80, rows=24),
                 "create-terminal")
            count += 1
            i += 1
        c.close()

    def surfaces(self, tree):
        def walk(node):
            if isinstance(node, dict):
                for k, v in node.items():
                    if k in ("surface", "surface_id") and isinstance(v, (int, str)):
                        yield v
                    else:
                        yield from walk(v)
            elif isinstance(node, list):
                for v in node:
                    yield from walk(v)
        seen = set()
        for s in walk(tree):
            if s not in seen:
                seen.add(s)
                yield s

    def first_terminal_resource_id(self, node):
        """The first `terminal_resource_id` (term_...) of a list-workspaces tree, or None."""
        if isinstance(node, dict):
            if isinstance(node.get("terminal_resource_id"), str):
                return node["terminal_resource_id"]
            node = list(node.values())
        if isinstance(node, list):
            for value in node:
                found = self.first_terminal_resource_id(value)
                if found:
                    return found
        return None

    def first_surface(self, c):
        tree = must(c.call("list-workspaces"), "list-workspaces")
        return next(iter(self.surfaces(tree)))

    def locate(self, c, surface):
        """(workspace, pane) records of the list-workspaces tree that hold `surface`."""
        tree = must(c.call("list-workspaces"), "list-workspaces")
        for ws in tree["workspaces"]:
            for screen in ws.get("screens") or []:
                for pane in screen.get("panes") or []:
                    if surface in set(self.surfaces(pane)):
                        return ws, pane
        raise RuntimeError(f"surface {surface} is in no pane of list-workspaces")

    def new_terminals(self, c, name, argvs):
        """A workspace of its own with one terminal per argv: (workspace id, [surface])."""
        first = must(c.call("new-workspace", name=name, cols=80, rows=24), "new-workspace")
        ws, _ = self.locate(c, first["surface"])
        surfaces = [must(c.call("create-terminal", workspace=ws["id"], argv=argv, cols=80, rows=24),
                         "create-terminal")["surface"] for argv in argvs]
        return ws["id"], surfaces

    def close_workspace(self, c, ws_id):
        try:
            c.call("close-workspace", workspace=ws_id, end_terminals=True)
        except (OSError, ConnectionError):
            pass

    def attach(self, c, surface, **extra):
        params = {"surface": surface, **extra}
        if self.has("attach-initial-size"):
            params.update(cols=80, rows=24)
        t = time.perf_counter()
        must(c.call("attach-surface", **params), "attach-surface")
        return (time.perf_counter() - t) * 1000

    # -- ops

    def ops(self, names, n, create_n):
        out = {}
        c = Conn(self.sock_path)
        fixture = OpsFixture(self, c)
        fixture.setup()
        caps_of = schema_capabilities()
        try:
            for name in names:
                plan = OPS[name]
                row = {"wire": plan["wire"], "kind": plan["kind"]}
                capability = plan["capability"] or (caps_of.get(name) if plan["wire"] == "v12" else None)
                if capability and not self.has(capability):
                    out[name] = {**row, "n": 0, "skipped": f"capability {capability} not advertised"}
                    continue
                count = create_n if plan["kind"] == "create" else n
                vals = []
                try:
                    for i in range(-min(3, count), count):
                        ms = plan["fn"](fixture, i)
                        if i >= 0:
                            vals.append(ms)
                except DaemonError as e:
                    reason = unserved_reason(e)
                    if reason and not vals:
                        out[name] = {**row, "n": 0, "skipped": reason}
                    else:
                        out[name] = {**stats(vals), **row, "error": str(e)}
                        self.failed = True
                    continue
                out[name] = {**stats(vals), **row}
        finally:
            fixture.teardown()
            c.close()
        return out

    def concurrent(self, clients, n):
        vals = {"ping": [], "identify": [], "list-workspaces": []}
        errors = []
        lock = threading.Lock()
        barrier = threading.Barrier(clients)

        def worker():
            try:
                c = Conn(self.sock_path)
                local = {k: [] for k in vals}
                barrier.wait()
                for _ in range(n):
                    for name in vals:
                        ms, r = c.timed(name)
                        local[name].append(ms)
                        if not r.get("ok"):
                            raise DaemonError(name, r)
                c.close()
                with lock:
                    for k in vals:
                        vals[k].extend(local[k])
            except Exception as e:  # noqa: BLE001
                errors.append(repr(e))

        ts = [threading.Thread(target=worker) for _ in range(clients)]
        for t in ts:
            t.start()
        for t in ts:
            t.join()
        out = {f"c{clients}-{k}": stats(v) for k, v in vals.items()}
        if errors:
            out["errors"] = errors[:5]
            self.failed = True
        return out

    def cli(self, n):
        env = dict(self.env)
        env["CMUX_TUI_SOCKET"] = self.sock_path
        c = Conn(self.sock_path)
        tree = must(c.call("list-workspaces"), "list-workspaces")
        c.close()
        surface = next(iter(self.surfaces(tree)))
        # The CLI names a terminal by its public id (term_...); older daemons have only the surface id.
        selectors = [s for s in (self.first_terminal_resource_id(tree), str(surface)) if s]
        cmds = {
            "cli-ping": [["session", "current", "ping"], ["ping"]],
            "cli-workspace-list": [["workspace", "list"]],
            "cli-terminal-write": [["terminal", selector, "write", "--text", ":\r"] for selector in selectors],
        }
        out = {}
        for name, candidates in cmds.items():
            chosen = None
            for argv in candidates:
                p = subprocess.run([self.args.bin, *argv], env=env, capture_output=True, timeout=30)
                if p.returncode == 0:
                    chosen = argv
                    break
                log(name, argv, "exit", p.returncode, p.stderr.decode(errors="replace")[-300:])
            if not chosen:
                out[name] = {"n": 0, "error": "no working CLI form"}
                continue
            vals = []
            for _ in range(n):
                t = time.perf_counter()
                subprocess.run([self.args.bin, *chosen], env=env, stdout=subprocess.DEVNULL,
                               stderr=subprocess.DEVNULL, timeout=30)
                vals.append((time.perf_counter() - t) * 1000)
            out[name] = {**stats(vals), "argv": " ".join(chosen)}
        vals = []
        for _ in range(n):
            t = time.perf_counter()
            subprocess.run([self.args.bin, "--version"], env=env, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=30)
            vals.append((time.perf_counter() - t) * 1000)
        out["cli-version-no-socket"] = stats(vals)
        return out

    # -- syscalls per message

    def ipc_stats(self, c):
        """The numeric leaves of server-stats' `ipc` section (p05-ipc-082), or None before it exists.
        Older daemons ignore the unknown `include` name and answer without the section."""
        if not self.has("server-stats-v1"):
            return None
        section = must(c.call("server-stats", include=["ipc"]), "server-stats").get("ipc")
        if not isinstance(section, dict):
            return None
        flat = {}

        def walk(node, prefix):
            for key, value in node.items():
                if isinstance(value, dict):
                    walk(value, f"{prefix}{key}.")
                elif isinstance(value, (int, float)) and not isinstance(value, bool):
                    flat[prefix + key] = value

        walk(section, "")
        return flat

    def syscalls(self, n):
        """Daemon syscalls, context switches and (when served) server-stats ipc counters per message."""
        c = Conn(self.sock_path)
        surface = self.first_surface(c)
        os_counter = self.counters.method is not None
        out = {"method": self.counters.method if os_counter else f"no per-process syscall counter on {sys.platform}"}
        if self.ipc_stats(c) is None:
            out["server_stats_ipc"] = "skipped: server-stats has no ipc section (p05-ipc-082)"
        plans = {"ping": {}, "send": {"surface": surface, "text": ":\r"}, "list-workspaces": {}}
        for name, params in plans.items():
            for _ in range(10):
                c.call(name, **params)
            idle_s = 0.5
            a = self.counters.sample()
            time.sleep(idle_s)
            b = self.counters.sample()
            ipc_before = self.ipc_stats(c)
            t = time.perf_counter()
            for _ in range(n):
                c.call(name, **params)
            burst_s = time.perf_counter() - t
            d = self.counters.sample()
            ipc_after = self.ipc_stats(c)
            row = {"messages": n, "burst_s": round(burst_s, 4)}
            if os_counter and None not in (a, b, d):
                for key in ("syscalls", "ctx"):
                    if d[key] is None:
                        continue
                    idle_rate = (b[key] - a[key]) / idle_s
                    row[f"{key}_per_msg"] = round(((d[key] - b[key]) - idle_rate * burst_s) / n, 3)
                    row[f"{key}_idle_per_s"] = round(idle_rate, 1)
            elif os_counter:
                row["os_counter"] = "skipped: counter read failed"
            if ipc_before is not None and ipc_after is not None:
                # One server-stats request lies inside the window (ipc_after's own); counters are cumulative.
                row["server_stats_ipc_per_msg"] = {
                    key: round((ipc_after[key] - ipc_before[key]) / n, 4)
                    for key in sorted(ipc_after) if key in ipc_before}
            out[name] = row
        c.close()
        return out

    # -- bulk interference (IPC-8)

    def bulk_interference(self, sizes_kib, flood_mib, timeout):
        out = {}
        control = Conn(self.sock_path)
        argvs = []
        markers = {}
        for k in sizes_kib:
            markers[k] = f"BENCH-FLOOD-DONE-{os.getpid()}-{k}"
            argvs.append(["perl", "-e", FLOOD_PERL, str(k * 1024), str(flood_mib * 1024 // k), markers[k]])
        ws_id, surfaces = self.new_terminals(control, f"bench-bulk-{os.getpid()}", argvs)
        try:
            for k, surface in zip(sizes_kib, surfaces):
                out.update(self._flood(k, surface, markers[k], flood_mib, timeout))
        finally:
            self.close_workspace(control, ws_id)
            control.close()
        return out

    def _flood(self, k, surface, marker, flood_mib, timeout):
        state = {"bytes": 0, "events": 0, "other_events": {}, "tail": b"", "ended": None}
        marker_b = marker.encode()

        def on_event(line, msg):
            if msg is None:
                data = output_bytes(line)
                state["bytes"] += len(data)
                state["events"] += 1
                window = state["tail"] + data
                if marker_b in window:
                    state["ended"] = state["ended"] or "marker"
                state["tail"] = window[-len(marker_b):]
                return
            name = msg.get("event") or msg.get("type")
            state["other_events"][name] = state["other_events"].get(name, 0) + 1
            if name == "detached":
                state["ended"] = state["ended"] or "detached"

        a = Conn(self.sock_path, on_event=on_event)
        self.attach(a, surface)
        a.pump(0.3)
        interval = 0.002
        idle = []
        for _ in range(200):
            ms, msg = a.timed("ping")
            idle.append(ms)
            a.pump(interval)
        start_at = time.time() + 0.5
        stop = SPAWN.Event()
        procs, queue = run_processes([(pinger_main, (self.sock_path, start_at, start_at + timeout, stop, interval))])
        while time.time() < start_at:
            a.pump(0.01)
        must(a.call("send", surface=surface, text="\r"), "send")
        t0 = time.perf_counter()
        same = []
        while state["ended"] is None and time.perf_counter() - t0 < timeout:
            ms, msg = a.timed("ping")
            same.append(ms)
            a.pump(interval)
        flood_s = time.perf_counter() - t0
        stop.set()
        other = collect(procs, queue, 10)[0]
        a.close()
        if "error" in other:
            self.failed = True
        row = {
            f"idle-ping-same-{k}k": stats(idle),
            f"bulk{k}k-ping-same": stats(same),
            f"bulk{k}k-ping-other": {**stats(other["samples"]), **({"error": other["error"]} if "error" in other else {})},
            f"bulk{k}k-flood": {
                "chunk_kib": k, "flood_mib": flood_mib, "seconds": round(flood_s, 3),
                "received_mib": round(state["bytes"] / (1 << 20), 2),
                "flood_mib_per_s": round(state["bytes"] / (1 << 20) / flood_s, 1) if flood_s else None,
                "output_events": state["events"], "other_events": state["other_events"],
                "ended": state["ended"] or "timeout",
            },
        }
        if state["ended"] is None:
            self.failed = True
        return row

    # -- streams (IPC-1, IPC-2, IPC-10)

    def streams(self, count, n):
        out = {}
        control = Conn(self.sock_path)
        ws_id, surfaces = self.new_terminals(control, f"bench-streams-{os.getpid()}",
                                             [["perl", "-e", PRINTER_PERL]] * count)
        try:
            out["views_per_connection"] = self._streams_per_connection(control, surfaces, n)
            if self.has("attach-streams-v1"):
                out["streams_one_connection"] = self._streams_one_connection(surfaces, n)
            else:
                out["streams_one_connection"] = {"skipped": "capability attach-streams-v1 not advertised"}
        finally:
            self.close_workspace(control, ws_id)
            control.close()
        return out

    def _connections_active(self, c):
        if not self.has("server-stats-v1"):
            return None
        data = must(c.call("server-stats"), "server-stats")
        return (data.get("connections") or {}).get("active")

    def _ping_while_draining(self, c, views, n):
        """n pings on `c` while every view connection keeps reading its stream, as the app does."""
        vals = []
        for _ in range(n):
            rid = c.send("ping")
            t = time.perf_counter()
            while rid not in c.replies:
                if time.perf_counter() - t > 10:
                    raise RuntimeError("ping got no reply in 10 s")
                for v in views:
                    v.pump(0)
                c.pump(0.0005)
            c.replies.pop(rid)
            vals.append((time.perf_counter() - t) * 1000)
            for v in views:
                v.pump(0.002 / max(1, len(views)))
        return vals

    def _streams_per_connection(self, control, surfaces, n):
        threads_before = self.counters.threads()
        views, attach_ms = [], []
        for surface in surfaces:
            v = Conn(self.sock_path)
            attach_ms.append(self.attach(v, surface))
            views.append(v)
        threads_after = self.counters.threads()
        active = self._connections_active(control)
        ping = self._ping_while_draining(control, views, n)
        for v in views:
            v.close()
        return {"views": len(surfaces), "attach-ms": stats(attach_ms), "ping-ms": stats(ping),
                "daemon_threads_before": threads_before, "daemon_threads_after": threads_after,
                "connections_active": active}

    def _streams_one_connection(self, surfaces, n):
        c = Conn(self.sock_path, on_event=lambda line, msg: None)
        must(c.call("set-client-info", name="bench-streams", capabilities=["attach-streams-v1"]), "set-client-info")
        threads_before = self.counters.threads()
        attach_ms = [self.attach(c, surface, stream=index + 1) for index, surface in enumerate(surfaces)]
        threads_after = self.counters.threads()
        active = self._connections_active(c)
        ping = self._ping_while_draining(c, [], n)
        for index in range(len(surfaces)):
            c.call("cancel-stream", stream=index + 1)
        c.close()
        return {"views": len(surfaces), "attach-ms": stats(attach_ms), "ping-ms": stats(ping),
                "daemon_threads_before": threads_before, "daemon_threads_after": threads_after,
                "connections_active": active}

    # -- automation storm (IPC-16)

    def automation_storm(self, clients, seconds, echo_n, split_n):
        control = Conn(self.sock_path)
        if self.has("origin-claim-v1"):
            must(control.call("client-hello", role="main"), "client-hello")
        control.call("set-client-info", name="bench-app", kind="app")
        app_ws, (echo_surface,) = self.new_terminals(control, f"bench-app-{os.getpid()}", [ECHO_ARGV])
        _, pane = self.locate(control, echo_surface)
        agent_ws = []
        for i in range(clients):
            agent_ws.append(self.new_terminals(control, f"bench-agent-{os.getpid()}-{i}", [["/bin/sh"]]))
        echo = EchoProbe(self, echo_surface)
        try:
            out = {"clients": clients, "seconds": seconds}
            out["idle"] = {"echo": stats(echo.measure(echo_n)), "split": stats(self._splits(control, pane["id"], split_n))}
            out["alone"] = self._automation(agent_ws, seconds, lambda: None)
            app = {}

            def app_work():
                app["echo"] = echo.measure(echo_n)
                app["split"] = self._splits(control, pane["id"], split_n)

            storm = self._automation(agent_ws, seconds, app_work)
            out["storm"] = {"echo": stats(app["echo"]), "split": stats(app["split"]), "automation": storm}
            idle_echo, storm_echo = out["idle"]["echo"], out["storm"]["echo"]
            alone_rps = out["alone"].get("requests_per_s") or 0
            out["ipc16"] = {
                "echo_p95_delta_ms": round(storm_echo["p95_ms"] - idle_echo["p95_ms"], 3),
                "echo_p95_within_idle_plus_1ms": storm_echo["p95_ms"] <= idle_echo["p95_ms"] + 1.0,
                "split_p95_under_2ms": out["storm"]["split"]["p95_ms"] < 2.0,
                "automation_throughput_ratio": round(storm["requests_per_s"] / alone_rps, 3) if alone_rps else None,
                "automation_keeps_half": bool(alone_rps) and storm["requests_per_s"] >= 0.5 * alone_rps,
            }
            return out
        finally:
            echo.close()
            for ws_id, _ in agent_ws:
                self.close_workspace(control, ws_id)
            self.close_workspace(control, app_ws)
            control.close()

    def _splits(self, control, pane, n):
        vals = []
        for _ in range(n):
            ms, msg = control.timed("split", pane=pane, dir="right", cols=80, rows=24)
            surface = must(msg, "split")["surface"]
            vals.append(ms)
            must(control.call("close-surface", surface=surface), "close-surface")
        return vals

    def _automation(self, agent_ws, seconds, app_work):
        start_at = time.time() + 1.0
        stop_at = start_at + seconds
        procs, queue = run_processes([(automation_main, (self.sock_path, ws, surfaces[0], start_at, stop_at))
                                      for ws, surfaces in agent_ws])
        while time.time() < start_at:
            time.sleep(0.005)
        app_work()
        results = collect(procs, queue, seconds + 30)
        samples = [v for r in results for v in r["samples"]]
        row = {**stats(samples, keep_samples=False), "requests_per_s": round(len(samples) / seconds, 1)}
        errors = [r["error"] for r in results if "error" in r]
        if errors:
            row["errors"] = errors[:5]
            self.failed = True
        return row

    # -- scenario

    def scenario(self, name, workspaces, terminals, busy):
        log("scenario", name, workspaces, terminals)
        self.grow(workspaces, terminals, busy)
        time.sleep(self.args.settle)
        a = self.args
        res = {}
        res["ops"] = self.ops(select_ops(a.ops), a.n, a.create_n or max(10, a.n // 10))
        res["concurrent"] = self.concurrent(10, max(20, a.n // 5))
        res["cli"] = self.cli(a.cli_n)
        res["syscalls"] = self.syscalls(max(100, a.n))
        if a.bulk_interference:
            res["bulk_interference"] = self.bulk_interference(a.bulk_interference, a.flood_mib, a.flood_timeout)
        if a.streams:
            res["streams"] = self.streams(a.streams, a.n)
        if a.automation_storm:
            res["automation_storm"] = self.automation_storm(a.automation_storm, a.storm_seconds, a.n // 3 or 1,
                                                            a.create_n or max(10, a.n // 10))
        self.result["scenarios"][name] = res
        report(name, res)


class EchoProbe:
    """The app's typing path: a key sent on the attach connection, timed to its echo."""

    def __init__(self, bench, surface):
        self.surface = surface
        self.seen = bytearray()
        self.conn = Conn(bench.sock_path, on_event=self._on_event)
        bench.attach(self.conn, surface)
        self.conn.pump(0.3)
        self.measure(20)

    def _on_event(self, line, msg):
        if msg is None:
            self.seen += output_bytes(line)

    def measure(self, n):
        vals = []
        for i in range(n):
            ch = chr(ord("a") + i % 26)
            self.seen.clear()
            t = time.perf_counter()
            self.conn.send("send", surface=self.surface, text=ch)
            while ch.encode() not in self.seen:
                if time.perf_counter() - t > 10:
                    raise RuntimeError(f"no echo of {ch!r} in 10 s")
                self.conn.pump(0.0005)
            vals.append((time.perf_counter() - t) * 1000)
            self.conn.pump(0.01)
        return vals

    def close(self):
        self.conn.close()


# ---------------------------------------------------------------------------------------------
# Report and Q16


FLAT_SECTIONS = ("ops", "concurrent", "cli", "bulk_interference")


def rows(res, prefix=""):
    """(metric, row) for every latency row and every skipped mode of a scenario result."""
    for key, value in res.items():
        if not isinstance(value, dict):
            continue
        if "n" in value or "skipped" in value:
            yield prefix + key, value
        else:
            yield from rows(value, prefix if (key in FLAT_SECTIONS and not prefix) else f"{prefix}{key}.")


def report(name, res):
    for metric, s in rows(res):
        if s.get("n"):
            print(f"PERF-DAEMON {name} {metric} n={s['n']} p50={s.get('p50_ms')} p95={s.get('p95_ms')} "
                  f"p99={s.get('p99_ms')} max={s.get('max_ms')}" + (f" argv=\"{s['argv']}\"" if "argv" in s else ""),
                  flush=True)
        elif "skipped" in s:
            print(f"PERF-DAEMON-SKIP {name} {metric} {s['skipped']}", flush=True)
        elif "error" in s:
            print(f"PERF-DAEMON-ERROR {name} {metric} {s['error']}", flush=True)
    for metric, s in (res.get("syscalls") or {}).items():
        if isinstance(s, dict) and "ctx_per_msg" in s:
            print(f"PERF-DAEMON-SYSCALLS {name} {metric} syscalls/msg={s.get('syscalls_per_msg', 'n/a')} "
                  f"ctx/msg={s['ctx_per_msg']} idle_syscalls/s={s.get('syscalls_idle_per_s', 'n/a')}"
                  + (f" ipc/msg={json.dumps(s['server_stats_ipc_per_msg'])}" if "server_stats_ipc_per_msg" in s else ""),
                  flush=True)
    storm = res.get("automation_storm")
    if storm and "ipc16" in storm:
        print(f"PERF-DAEMON-IPC16 {name} " + " ".join(f"{k}={v}" for k, v in storm["ipc16"].items()), flush=True)


def slow_ops(result, scenario="scale", threshold_ms=Q16_THRESHOLD_MS):
    """Q16 items: ops of `scenario` whose p95 is above the threshold."""
    ops = ((result.get("scenarios") or {}).get(scenario) or {}).get("ops") or {}
    items = []
    for name, row in sorted(ops.items()):
        if row.get("n") and row.get("p95_ms", 0) > threshold_ms:
            items.append({"file": SCRIPT_REL, "line": OPS[name]["line"] if name in OPS else 0, "key": name,
                          "p95_ms": row["p95_ms"], "wire": row.get("wire")})
    return items


def write_q16(targets_path, result, scenario="scale", threshold_ms=Q16_THRESHOLD_MS):
    """Writes runtime.Q16 (and its run record) into ipc-targets.json; returns the items."""
    if scenario not in (result.get("scenarios") or {}):
        raise ValueError(f"Q16 needs the {scenario} scenario in the result")
    ops = result["scenarios"][scenario].get("ops") or {}
    missing = [name for name in OPS if name not in ops]
    if missing:
        raise ValueError(f"Q16 needs --ops all; not measured: {', '.join(missing)}")
    items = slow_ops(result, scenario, threshold_ms)
    with open(targets_path, encoding="utf-8") as f:
        targets = json.load(f)
    runtime = targets.setdefault("runtime", {})
    runtime["Q16"] = items
    runtime["Q16_run"] = {
        "command": "bench-daemon-latency.py --ops all --scenario scale --write-q16",
        "scenario": scenario, "threshold_ms": threshold_ms,
        "sha": (result.get("source") or {}).get("sha"), "host": result.get("host"),
        "daemon_version": (result.get("daemon") or {}).get("version"),
        "skipped": sorted(name for name, row in ops.items() if "skipped" in row),
        "failed": sorted(name for name, row in ops.items() if "error" in row),
    }
    with open(targets_path, "w", encoding="utf-8") as f:
        f.write(json.dumps(targets, indent=2, ensure_ascii=False) + "\n")
    return items


def parse_kib(value):
    sizes = [int(v) for v in value.split(",") if v]
    if not sizes or any(v <= 0 for v in sizes):
        raise argparse.ArgumentTypeError("sizes are positive KiB counts, e.g. 16,32,64")
    return sizes


def parse_args(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0],
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--bin", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--n", type=int, default=300, help="samples per read/write op (default 300)")
    ap.add_argument("--create-n", type=int, default=0, help="samples per create op (default max(10, n/10))")
    ap.add_argument("--cli-n", type=int, default=40)
    ap.add_argument("--settle", type=float, default=3.0)
    ap.add_argument("--ops", default="base", help="base, create, all, or a comma list of op names")
    ap.add_argument("--scenario", "--scenarios", dest="scenarios", action="append",
                    help="small, scale (repeatable or comma list; default small,scale)")
    ap.add_argument("--bulk-interference", nargs="?", const=[16, 32, 64], type=parse_kib, default=None,
                    metavar="KIB,...", help="flood chunk sizes in KiB (default 16,32,64)")
    ap.add_argument("--flood-mib", type=int, default=256)
    ap.add_argument("--flood-timeout", type=float, default=180.0)
    ap.add_argument("--streams", type=int, default=0, metavar="N", help="attach N printing terminals")
    ap.add_argument("--automation-storm", type=int, default=0, metavar="N", help="N automation clients")
    ap.add_argument("--storm-seconds", type=float, default=8.0)
    ap.add_argument("--write-q16", nargs="?", const=TARGETS, default=None, metavar="TARGETS",
                    help=f"write runtime.Q16 into ipc-targets.json (default {os.path.relpath(TARGETS, REPO_ROOT)})")
    args = ap.parse_args(argv)
    wanted = [s for value in (args.scenarios or ["small,scale"]) for s in value.split(",") if s]
    unknown = [s for s in wanted if s not in SCENARIOS]
    if unknown:
        ap.error(f"unknown scenario(s) {', '.join(unknown)}; known: {', '.join(SCENARIOS)}")
    args.scenarios = wanted
    select_ops(args.ops)
    unmeasured = [name for name in ipc5_ops() if name not in OPS]
    if unmeasured:
        ap.error(f"ipc5_ops of {os.path.relpath(TARGETS, REPO_ROOT)} names ops this bench has no plan for: "
                 f"{', '.join(unmeasured)} (add an @op)")
    if args.write_q16 and (args.ops != "all" or "scale" not in wanted):
        ap.error("--write-q16 needs --ops all and --scenario scale (Q16's definition)")
    if args.write_q16 and sys.platform != "darwin":
        ap.error("--write-q16 runs on a macOS fleet host only: VM and Linux timing is not perf evidence")
    return args


def main(argv=None):
    args = parse_args(argv)
    b = Bench(args)
    b.result.update(host=host_info(), source=source_info(),
                    args={k: v for k, v in vars(args).items() if k not in ("bin", "out")})
    status = 0
    try:
        b.start()
        for name in args.scenarios:
            b.scenario(name, *SCENARIOS[name])
    except Exception as e:  # noqa: BLE001
        log("FAILED", traceback.format_exc(), b.tail()[-1500:])
        b.result["error"] = repr(e)
        status = 1
    finally:
        b.stop()
    if b.failed:
        status = 1
    if "scale" in b.result["scenarios"]:
        b.result["q16"] = slow_ops(b.result)
        print("PERF-DAEMON-Q16 scale " + json.dumps([f"{i['key']}={i['p95_ms']}" for i in b.result["q16"]]), flush=True)
    if args.write_q16 and status == 0:
        write_q16(args.write_q16, b.result)
        log("wrote runtime.Q16 to", args.write_q16)
    with open(args.out, "w") as f:
        json.dump(b.result, f, indent=1)
    return status


if __name__ == "__main__":
    sys.exit(main())
