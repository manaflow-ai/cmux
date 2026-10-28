#!/usr/bin/env python3
"""Request latency of one headless cmux-tui daemon (perf-10x daemon area, p05-ipc).

Starts an isolated headless daemon (durable state on the local disk), grows a
scenario, and measures the client-side round trip (send to reply) of control
requests on JSON-lines connections. Every latency row (LATENCY below) comes
from the raw samples: n, p50_ms, p95_ms, p99_ms (scripts/perf-lab/perf_stats.py
pct, linear interpolation), max_ms, mean_ms as an extra, and samples_ms (left out of the automation rows, which
are too many). No row is a mean alone. A row the daemon does not serve has
`skipped` (a note why) and n 0; a row or section that failed has `error`,
fails the run (exit 1) and keeps every row measured before it.

Scenarios (--scenario, repeatable or comma list):
  small   1 workspace, 1 terminal
  scale   50 workspaces, 200 terminals, 5% of them printing steadily

Keys of result["scenarios"][SCENARIO]:
  ops.OP       LATENCY + wire (v12|v2), kind (read|write|create), per op of
               --ops: base (ping, identify, list-workspaces, send, new-tab),
               create (the ops of kind create: v12 and v2 creates, split,
               browser tab, create-tab-group), all (every op, which covers
               ipc5_ops of plans/cmux-next/ipc-targets.json), or a comma list.
               `skipped`: capability not advertised, or the daemon does not
               know the command (v12 `unknown variant `OP``) or operation (v2,
               once the bench's envelope parses on a served operation). Setup
               and cleanup run untimed on the same connection.
               daemon_methods (when the daemon serves `server-stats
               include=[ipc_methods]`): per method the op timed, the daemon's
               own latency_us of the same requests (warm-ups included) beside
               the bench's nearest-rank client_us, their log-linear buckets
               (the daemon's: four per power of two), bucket_delta (client
               bucket - daemon bucket, for p50, p95, p99, max) and
               within_one_bucket; or `skipped` when the method also ran
               untimed (the histograms cannot be split) or is not served.
  concurrent   c10-ping, c10-identify, c10-list-workspaces: LATENCY of 10
               clients at once; errors (when any).
  cli          cli-ping, cli-workspace-list, cli-terminal-write: LATENCY + argv
               (process start to exit through CMUX_TUI_SOCKET);
               cli-version-no-socket: LATENCY.
  syscalls     method (the counter: macOS proc_pidinfo PROC_PIDTASKINFO unix +
               mach syscalls and csw; Linux context switches only, its /proc
               syscall counters miss sendmsg, recvmsg and poll, so Linux rows
               are not perf evidence), server_stats_ipc (a skip note until the
               daemon serves `server-stats include=[ipc]`, p05-ipc-082), and per
               op ping, send, list-workspaces: messages, burst_s,
               syscalls_per_msg, ctx_per_msg, syscalls_idle_per_s,
               ctx_idle_per_s, server_stats_ipc_per_msg (each numeric ipc
               counter per message, when served), os_counter (a read failure).
               X_per_msg = (delta over the burst - idle rate x burst_s) /
               messages. `send` runs on its own shell with a view attached; its
               idle sample starts and its burst ends when a marker command's
               output reaches the view (window_end), so the daemon's PTY read,
               parse and broadcast of the sends are inside the burst; messages
               counts the marker send.
  bulk_interference  (--bulk-interference [KIB,...], default 16,32,64)
               pty_write_kib (the flood's PTY write size, --flood-write-kib,
               fixed: it does not set the daemon's framing). When identify
               reports `bulk_frame_max` (bytes), frame_max_default_bytes and one
               row set per KIB on a daemon started with
               CMUX_IPC_BULK_FRAME_MAX=KIB*1024 and the same scenario (L = KIBk,
               e.g. 16k). Otherwise frame_max_sweep.skipped and one row set at
               the daemon's own framing (L = default). Row set per L:
                 bulk-L-idle-ping-same  LATENCY: ping on connection A, attached
                                        to the flood terminal, before the flood
                 bulk-L-ping-same       LATENCY: ping on A while A carries the
                                        flood (head of line, IPC-8)
                 bulk-L-ping-other      LATENCY (+ error): ping from another
                                        process on its own connection meanwhile
                 bulk-L-flood           flood_mib, seconds, received_mib,
                                        flood_mib_per_s, output_events,
                                        other_events (count per event name),
                                        ended (marker|detached|timeout),
                                        frame_max_kib (null: daemon default),
                                        pty_write_kib
  streams      (--streams N) N printing terminals and pings on a control
               connection while every view keeps reading. views_per_connection:
               today's shape, one attach connection per view (always runs);
               streams_one_connection: N client-minted streams on one connection
               (attach-streams-v1; `skipped` when not advertised). Keys of
               each: views, attach-ms (LATENCY), ping-ms (LATENCY),
               daemon_threads_before, daemon_threads_after, connections_active.
  automation_storm  (--automation-storm N) the app's key echo (raw `cat` behind
               an attach connection) and split (on its control connection),
               idle, then while N automation processes loop new-tab (closed
               again untimed), rename-workspace, list-workspaces, send and
               identify on their own connections. Both app connections use the
               app's handshake (identify, client-hello role main when
               origin-claim-v1 is advertised, set-client-info kind frontend).
               Keys: clients, seconds (--storm-seconds), mix, app_role
               {control, echo_view} (the hello role, or why none), idle.echo,
               idle.split (LATENCY), alone (automation without the app),
               storm.echo, storm.split (LATENCY), storm.automation. An
               automation row is LATENCY without samples_ms + window_s,
               requests_per_s (requests completed inside the window /
               window_s), clients_cover_window (every client ran for all of
               it), errors. The storm window is the app's work, which repeats
               (5 echoes, 1 split) until at least --storm-seconds and the
               sample counts; the automation clients start with it and stop
               when it ends. ipc16: echo_p95_delta_ms,
               echo_p95_within_idle_plus_1ms, split_p95_under_2ms,
               automation_throughput_ratio, automation_keeps_half (>= 50% of
               alone), windows_match (both automation rows cover their window);
               or error when echo or split samples are missing.

  daemon_locks  read after every other section: `debug-daemon-locks`
               (p06-scheduler-226), cumulative since daemon start (so scale
               includes small). locks.LOCK.CALLER.{wait_us, hold_us}: count,
               p50, p95, p99, max in microseconds, per lock (mux.state,
               workspace.registry) for callers frontend and automation;
               `skipped` on a daemon that does not serve it. frontend counts
               only the signed, verified cmux app: the bench's own app
               handshake is unsigned, so its requests count as automation and
               frontend stays at count 0 unless the app is connected.

Top level: host (hostname, os, os_version, macos, arch, cpu, cores, load,
python), source (sha, dirty: the script checkout), daemon (version, protocol,
build_commit, pid, capabilities, bin, binary {path, sha256, mtime}), args,
scenarios, q16 (the scale scenario's ops with p95 > 2 ms), error (the run
stopped), q16_write_error.

--write-q16 writes runtime.Q16 of ipc-targets.json (p05-ipc queue Q16: items
{file, line, key, p95_ms, wire} for ops with p95 > 2 ms in --ops all --scenario
scale; scripts/cmux-next/ipc-census.py reads it) and runtime.Q16_run (command,
scenario, threshold_ms, sha, sha_source, host, daemon_version, skipped,
failed, and binary when sha_source is `script checkout`). sha is the daemon's
build_commit; a daemon without one is named by the script checkout's HEAD and
the binary's hash; a build_commit other than HEAD is refused. It needs a passed
run on a macOS host: VM timing is not perf evidence.

--out FILE.json writes the report alone. --out DIR (the perf lab's story
runner) writes it to DIR/daemon-latency.json and every latency row's raw
samples to DIR as cmux-perf-result/v1 (perf_result.py) in story daemon-latency
(daemon_bench_lab.py names the build and host): daemon.latency.SCENARIO.ROW
(ms), ROW being the report's row path (ops.ping is `ping`, the storm's echo
`automation_storm.storm.echo`), each part in lower case with `_` for other
characters. The automation rows keep no samples and record nothing. A failed
row records nothing: a failed op or CLI row drops its own row, and any other
section with a failed row or client (a concurrent or automation client, the
storm's window) records none of its rows.

Usage:
  bench-daemon-latency.py --bin target/release/cmux-tui --out result.json
  bench-daemon-latency.py --bin ... --ops all --scenario scale \\
      --bulk-interference --streams 8 --automation-storm 8 --out r.json [--write-q16]
  bench-daemon-latency.py --bin ... --sha SHA --build-config release --out DIR
"""

# Scratch (cp/audit-11-bench, never lands): `--scenarios suite` runs the pro audit 11 daemon suite instead, through
# feat-cmux-next's reviewed scripts/measure/perf-10x-daemon.sh (the fleet runs that script on Linux and macOS).
import os as _os, sys as _sys  # noqa: E401,E402
if "--scenarios" in _sys.argv and _sys.argv[_sys.argv.index("--scenarios") + 1] in ("suite", "suite-quick"):
    _argv = _sys.argv
    _cmd = [_sys.executable, _os.path.join(_os.path.dirname(_os.path.abspath(__file__)), "bench-daemon-suite.py"),
            "--bin", _argv[_argv.index("--bin") + 1], "--out", _argv[_argv.index("--out") + 1]]
    if _argv[_argv.index("--scenarios") + 1] == "suite-quick":
        _cmd.append("--quick")
    _os.execv(_sys.executable, _cmd)

import argparse
import binascii
import ctypes
import hashlib
import importlib.util
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
V2_PROBE_OPERATION = "machine.list"  # a read every v2 daemon serves
SCENARIOS = {"small": (1, 1, 0.0), "scale": (50, 200, 0.05)}
STORY = "daemon-latency"
METRIC_PREFIX = "daemon.latency"
REPORT_NAME = "daemon-latency.json"

_spec = importlib.util.spec_from_file_location("daemon_bench_lab", os.path.join(SCRIPT_DIR, "daemon_bench_lab.py"))
lab = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(lab)


def log(*parts):
    print(time.strftime("%H:%M:%S"), *parts, file=sys.stderr, flush=True)


class DaemonError(RuntimeError):
    """A request the daemon answered with ok:false."""

    def __init__(self, what, msg):
        err = msg.get("error")
        code = msg.get("error_code") or (err.get("code") if isinstance(err, dict) else None)
        text = err.get("message") if isinstance(err, dict) else err
        super().__init__(f"{what}: {code or ''} {text!r}".strip())
        self.what = what
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
        """Handles every line that arrives within `seconds`; replies are kept by id.

        Once the deadline passes it reads the socket one more time without waiting, so
        pump(0) takes what is readable now instead of only what is already buffered."""
        deadline = time.perf_counter() + seconds
        final = False
        while True:
            line = self._buffered_line()
            if line is not None:
                msg = self._dispatch(line)
                if msg is not None and "id" in msg:
                    self.replies[msg["id"]] = msg
                continue
            left = max(0.0, deadline - time.perf_counter())
            if left == 0.0:
                if final:
                    return
                final = True
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
    """Nearest-rank percentile of sorted raw samples: the daemon's own definition (LogLinearHistogram::percentile,
    the sample of rank ceil(n * q)), used only to compare client samples with its ipc_methods buckets."""
    rank = max(1, math.ceil(q * len(sorted_vals) - 1e-9))
    return sorted_vals[min(len(sorted_vals), rank) - 1]


def stats(vals, keep_samples=True):
    """A LATENCY row of raw samples: percentiles from perf_stats.pct (linear interpolation)."""
    if not vals:
        return {"n": 0}
    row = {
        "n": len(vals),
        "p50_ms": round(lab.perf_stats.pct(vals, 0.5), 3),
        "p95_ms": round(lab.perf_stats.pct(vals, 0.95), 3),
        "p99_ms": round(lab.perf_stats.pct(vals, 0.99), 3),
        "max_ms": round(max(vals), 3),
        "mean_ms": round(statistics.fmean(vals), 3),
    }
    if keep_samples:
        row["samples_ms"] = [round(v, 4) for v in vals]
    return row


# The daemon's log-linear latency buckets (cmux-tui-core diagnostics::LogLinearHistogram, and the
# app's DaemonMethodLatency): values under 4 have their own bucket, then four per power of two.
# spec/fixtures/ipc-method-latency/buckets.json is the shared vector all three check.
SUB_BUCKETS_LOG2 = 2
SUB_BUCKETS = 1 << SUB_BUCKETS_LOG2
METHOD_PERCENTILES = (("p50", 0.5), ("p95", 0.95), ("p99", 0.99))


def bucket_index(micros):
    if micros < SUB_BUCKETS:
        return micros
    octave = micros.bit_length() - 1
    return octave * SUB_BUCKETS + ((micros >> (octave - SUB_BUCKETS_LOG2)) & (SUB_BUCKETS - 1))


def bucket_upper_bound(index):
    if index < SUB_BUCKETS:
        return index
    octave, sub = divmod(index, SUB_BUCKETS)
    return ((1 << octave) - 1) + (sub + 1) * (1 << (octave - SUB_BUCKETS_LOG2))


def daemon_agreement(samples_ms, before, after):
    """How the bench's client round trips of one method's requests compare with the daemon's own
    `ipc_methods` row of the same requests. `before` and `after` are the method's row before the
    first and after the last request (None: it had not run). Only a row that counts exactly these
    requests is compared: the daemon reports percentiles, which cannot be split, so a method that
    also ran untimed is skipped."""
    if after is None:
        return {"skipped": "no ipc_methods row for the method after its requests"}
    if before is not None and before["latency_us"]["count"]:
        return {"skipped": f"{before['latency_us']['count']} request(s) of the method ran before the op"}
    daemon = after["latency_us"]
    if daemon["count"] != len(samples_ms):
        return {"skipped": f"the daemon counted {daemon['count']} request(s), the bench timed {len(samples_ms)}"}
    ordered = sorted(samples_ms)
    client = {key: round(pick(ordered, q) * 1000) for key, q in METHOD_PERCENTILES}
    client["max"] = round(ordered[-1] * 1000)
    keys = [key for key, _ in METHOD_PERCENTILES] + ["max"]
    delta = {key: bucket_index(client[key]) - bucket_index(daemon[key]) for key in keys}
    return {"n": len(samples_ms), "id": after.get("id"),
            "client_us": client, "daemon_us": {key: daemon[key] for key in keys},
            "bucket_delta": delta, "within_one_bucket": all(abs(d) <= 1 for d in delta.values())}


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


def binary_info(path):
    """The measured binary's mtime and sha256: what names it when the daemon has no build_commit."""
    digest = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            digest.update(block)
    mtime = os.stat(path).st_mtime
    return {"path": os.path.abspath(path), "sha256": digest.hexdigest(),
            "mtime": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(mtime))}


def measured_commit(result):
    """(sha, sha_source) of the measured daemon: its stamped build_commit, else the script checkout's HEAD."""
    build_commit = (result.get("daemon") or {}).get("build_commit")
    if build_commit:
        return build_commit, "daemon build_commit"
    return (result.get("source") or {}).get("sha"), "script checkout"


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
                           "recvmsg or poll; a thread that exits takes its switches with it, so a rate "
                           "can come out negative")

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
        self.ws_id = None
        self.v2_envelope_ok = False
        # (method, ms) of every timed request, warm-ups included: the daemon counts them all.
        self.timings = []

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
        self.v2_envelope_ok = self.probe_v2_envelope()

    def probe_v2_envelope(self):
        """True when the daemon parses this bench's v2 envelope (with and without an idempotency key)
        on a served operation. Only then does `invalid request envelope` on an op mean that its
        `operation` is unknown to the daemon (the envelope's params are untyped JSON)."""
        for key in (None, self.key()):
            msg = self.c.v2(V2_PROBE_OPERATION, {}, key)
            if not msg.get("ok") and is_envelope_error(DaemonError(V2_PROBE_OPERATION, msg)):
                return False
        return True

    def teardown(self):
        if self.ws_id is None:
            return
        try:
            self.c.call("close-workspace", workspace=self.ws_id, end_terminals=True)
        except (OSError, ConnectionError):
            pass

    def close(self, surface):
        must(self.c.call(self.closer, **close_params(self.closer, surface)), self.closer)

    def timed(self, cmd, **params):
        ms, msg = self.c.timed(cmd, **params)
        self.timings.append((cmd, ms))
        return ms, must(msg, cmd)

    def timed_v2(self, operation, params, mutation=False):
        ms, msg = self.c.timed_v2(operation, params, self.key() if mutation else None)
        self.timings.append((operation, ms))
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


@op("close-tab-group", kind="write", capability="tab-groups-v1")
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


def is_envelope_error(err):
    return err.code == "validation.invalid" and "invalid request envelope" in err.text.lower()


def unserved_reason(err, name, wire, v2_envelope_ok):
    """Why op `name` is not served, or None when `err` is a real failure.

    Only the op's own request counts (`err.what`, set by must()). v12: serde names the unknown
    `cmd` tag (`unknown variant `<cmd>``); the same text about a param's enum value names that
    value, so it stays a failure. v2: the daemon drops serde's detail, so an envelope error means
    an unknown `operation` only when the bench's envelope parses on a served operation
    (OpsFixture.probe_v2_envelope)."""
    if err.what != name:
        return None
    if wire == "v12":
        return "not served by this daemon (unknown command)" if f"unknown variant `{name}`" in err.text else None
    if v2_envelope_ok and is_envelope_error(err):
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


# One agent's loop: a create (registry writer and worker permits, what person-first admission must
# beat; closed again untimed), a rename (a registry write) and the reads an agent polls with.
AUTOMATION_MIX = ("new-tab", "rename-workspace", "list-workspaces", "send", "identify")


def close_params(closer, surface):
    if closer == "close-tabs":
        return {"surfaces": [surface], "end_terminals": True}
    return {"surface": surface}


def automation_main(sock_path, agent, closer, start_at, deadline, stop, queue):
    """Loops AUTOMATION_MIX on its own connection from start_at until `stop` is set (or the
    deadline passes); reports [completion wall time, ms] per timed request."""
    vals = []
    try:
        c = Conn(sock_path)
        must(c.call("set-client-info", name="bench-automation", kind="agent"), "set-client-info")
        while time.time() < start_at:
            time.sleep(0.002)
        for i in itertools.count():
            if stop.is_set() or time.time() >= deadline:
                break
            cmd = AUTOMATION_MIX[i % len(AUTOMATION_MIX)]
            params = {"new-tab": {"pane": agent["pane"], "cols": 80, "rows": 24},
                      "send": {"surface": agent["surface"], "text": ":\r"},
                      "rename-workspace": {"workspace": agent["workspace"], "name": f"bench-agent-{i % 2}"}
                      }.get(cmd, {})
            ms, msg = c.timed(cmd, **params)
            vals.append([time.time(), ms])
            data = must(msg, cmd)
            if cmd == "new-tab":
                must(c.call(closer, **close_params(closer, data["surface"])), closer)
        c.close()
        queue.put({"samples": vals, "ended": time.time()})
    except Exception as e:  # noqa: BLE001
        queue.put({"samples": vals, "ended": time.time(), "error": repr(e)})


def storm_window(results, t0, t1):
    """The automation row of one window [t0, t1] (wall seconds): only requests that completed inside
    it count, and `clients_cover_window` says whether every client ran for all of it."""
    window = t1 - t0
    samples = [ms for r in results for end, ms in r["samples"] if t0 <= end <= t1]
    row = {**stats(samples, keep_samples=False), "window_s": round(window, 3),
           "requests_per_s": round(len(samples) / window, 1) if window > 0 else None,
           "clients_cover_window": bool(results) and all(r.get("ended", 0) >= t1 for r in results)}
    errors = [r["error"] for r in results if "error" in r]
    if errors:
        row["errors"] = errors[:5]
    return row


STORM_ECHO_BATCH = 5  # echoes per split in the storm's interleaved app work


def ipc16_verdict(idle_echo, storm, alone):
    """IPC-16 (p05-ipc.md): echo p95 <= idle + 1 ms, split p95 < 2 ms, automation keeps >= 50% of
    its throughput alone, all over one window (`windows_match`: every automation client ran for
    all of the app's storm work)."""
    storm_echo, storm_split, automation = storm["echo"], storm["split"], storm["automation"]
    alone_rps = alone.get("requests_per_s") or 0
    storm_rps = automation.get("requests_per_s") or 0
    measured = bool(idle_echo.get("n") and storm_echo.get("n") and storm_split.get("n"))
    if not measured:
        return {"error": "missing echo or split samples", "windows_match": automation.get("clients_cover_window", False)}
    return {
        "echo_p95_delta_ms": round(storm_echo["p95_ms"] - idle_echo["p95_ms"], 3),
        "echo_p95_within_idle_plus_1ms": storm_echo["p95_ms"] <= idle_echo["p95_ms"] + 1.0,
        "split_p95_under_2ms": storm_split["p95_ms"] < 2.0,
        "automation_throughput_ratio": round(storm_rps / alone_rps, 3) if alone_rps else None,
        "automation_keeps_half": bool(alone_rps) and storm_rps >= 0.5 * alone_rps,
        "windows_match": bool(automation.get("clients_cover_window") and alone.get("clients_cover_window")),
    }


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


# The daemon's bulk frame cut (p05-ipc.md 3.2): identify with `revisions` reports it in
# bytes and the daemon takes it from this environment variable at start.
BULK_FRAME_MAX_FIELD = "bulk_frame_max"
BULK_FRAME_MAX_ENV = "CMUX_IPC_BULK_FRAME_MAX"
FLOOD_PERL = (
    '$|=1; my ($k, $n, $m) = @ARGV; my $line = ("x" x 79) . "\\n"; '
    'my $chunk = substr($line x (int($k / 80) + 1), 0, $k); my $go = <STDIN>; '
    'for (1..$n) { syswrite(STDOUT, $chunk) } print "\\n$m\\n"; my $end = <STDIN>;'
)
PRINTER_PERL = '$|=1; my $n=0; while (1) { print "stream ", $n++, " ", "y" x 60, "\\n"; select(undef,undef,undef,0.02); }'
BUSY_PERL = '$|=1; my $n=0; while (1) { print "busy ", $n++, " ", "x" x 60, "\\n"; select(undef,undef,undef,0.05); }'
ECHO_ARGV = ["/bin/sh", "-c", "stty raw -echo; exec cat"]


class Bench:
    _serial = itertools.count()

    def __init__(self, args, env_extra=None):
        """`env_extra`: daemon environment on top of the isolated one (a bulk sweep's frame cut)."""
        self.args = args
        self.env_extra = dict(env_extra or {})
        self.root = tempfile.mkdtemp(prefix="pd.", dir="/private/tmp" if sys.platform == "darwin" else None)
        self.sock_path = os.path.join(self.root, "s.sock")
        self.session = f"perfd{os.getpid()}n{next(Bench._serial)}"
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
        env.update(self.env_extra)
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
                    # `revisions` adds the opt-in fields, bulk_frame_max among them; older daemons ignore it.
                    self.ident = must(c.call("identify", revisions=True), "identify")
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
        try:
            if self.daemon:
                self._shutdown()
        finally:
            shutil.rmtree(self.root, ignore_errors=True)

    def _shutdown(self):
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
        self.daemon_log.close()

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

    def identify_as_app(self, c, name):
        """The app's connection handshake (CmuxNextDaemon HandshakeLines.swift): identify, then
        client-hello role main when origin-claim-v1 is advertised (the daemon accepts the hello only
        as the first line or right after one identify), then set-client-info kind frontend.
        Returns the hello role, so a person-first verdict (p05-ipc-143) names the class it measured."""
        must(c.call("identify"), "identify")
        role = "none (origin-claim-v1 not advertised)"
        if self.has("origin-claim-v1"):
            must(c.call("client-hello", role="main"), "client-hello")
            role = "main"
        must(c.call("set-client-info", name=name, kind="frontend"), "set-client-info")
        return role

    def attach(self, c, surface, **extra):
        params = {"surface": surface, **extra}
        if self.has("attach-initial-size"):
            params.update(cols=80, rows=24)
        t = time.perf_counter()
        must(c.call("attach-surface", **params), "attach-surface")
        return (time.perf_counter() - t) * 1000

    # -- ops

    def ops(self, names, n, create_n, out):
        """Fills `out` row by row, so the rows measured before an exception stay in the result."""
        c = Conn(self.sock_path)
        fixture = OpsFixture(self, c)
        caps_of = schema_capabilities()
        try:
            fixture.setup()
            for name in names:
                plan = OPS[name]
                row = {"wire": plan["wire"], "kind": plan["kind"]}
                capability = plan["capability"] or (caps_of.get(name) if plan["wire"] == "v12" else None)
                if capability and not self.has(capability):
                    out[name] = {**row, "n": 0, "skipped": f"capability {capability} not advertised"}
                    continue
                count = create_n if plan["kind"] == "create" else n
                vals = []
                methods_before = self.method_rows(c)
                fixture.timings.clear()
                try:
                    for i in range(-min(3, count), count):
                        ms = plan["fn"](fixture, i)
                        if i >= 0:
                            vals.append(ms)
                except DaemonError as e:
                    reason = unserved_reason(e, name, plan["wire"], fixture.v2_envelope_ok)
                    if reason and not vals:
                        out[name] = {**row, "n": 0, "skipped": reason}
                    else:
                        out[name] = {**stats(vals), **row, "error": str(e)}
                        self.failed = True
                    continue
                out[name] = {**stats(vals), **row,
                             "daemon_methods": self.daemon_methods(c, methods_before, fixture.timings)}
        finally:
            fixture.teardown()
            c.close()

    def method_rows(self, c):
        """server-stats' `ipc_methods` rows by method name, or None when the daemon has no such section."""
        if not self.has("server-stats-v1"):
            return None
        section = must(c.call("server-stats", include=["ipc_methods"]), "server-stats").get("ipc_methods")
        if not isinstance(section, list):
            return None
        return {row["method"]: row for row in section if isinstance(row, dict) and "method" in row}

    def daemon_methods(self, c, before, timings):
        """daemon_agreement for each method the op timed (ops.OP.daemon_methods)."""
        if before is None:
            return {"skipped": "server-stats has no ipc_methods section (p05-ipc-009)"}
        after = self.method_rows(c) or {}
        samples = {}
        for method, ms in timings:
            samples.setdefault(method, []).append(ms)
        return {method: daemon_agreement(vals, before.get(method), after.get(method))
                for method, vals in samples.items()}

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
        """Daemon syscalls, context switches and (when served) server-stats ipc counters per message.

        `send` runs on a shell of its own with a view attached (as the app has), and both its idle
        sample and its burst end only when the shell's output up to a marker has reached the view:
        the daemon's PTY read, parse and broadcast of every send lies inside the burst window, and
        none of the warm-up's lies inside the idle window."""
        c = Conn(self.sock_path)
        ws_id, (surface,) = self.new_terminals(c, f"bench-syscalls-{os.getpid()}", [["/bin/sh"]])
        view = OutputView(self, surface)
        os_counter = self.counters.method is not None
        out = {"method": self.counters.method if os_counter else f"no per-process syscall counter on {sys.platform}"}
        try:
            if self.ipc_stats(c) is None:
                out["server_stats_ipc"] = "skipped: server-stats has no ipc section (p05-ipc-082)"
            plans = {"ping": {}, "send": {"surface": surface, "text": ":\r"}, "list-workspaces": {}}
            for name, params in plans.items():
                drained = name == "send"
                for _ in range(10):
                    c.call(name, **params)
                if drained:
                    view.drain(c, "idle")
                idle_s = 0.5
                a = self.counters.sample()
                time.sleep(idle_s)
                b = self.counters.sample()
                ipc_before = self.ipc_stats(c)
                t = time.perf_counter()
                for _ in range(n):
                    c.call(name, **params)
                if drained:
                    view.drain(c, "burst")
                burst_s = time.perf_counter() - t
                d = self.counters.sample()
                ipc_after = self.ipc_stats(c)
                messages = n + 1 if drained else n  # the marker is a send too
                row = {"messages": messages, "burst_s": round(burst_s, 4)}
                if drained:
                    row["window_end"] = "marker output seen on the attached view"
                if os_counter and None not in (a, b, d):
                    for key in ("syscalls", "ctx"):
                        if d[key] is None:
                            continue
                        idle_rate = (b[key] - a[key]) / idle_s
                        row[f"{key}_per_msg"] = round(((d[key] - b[key]) - idle_rate * burst_s) / messages, 3)
                        row[f"{key}_idle_per_s"] = round(idle_rate, 1)
                elif os_counter:
                    row["os_counter"] = "skipped: counter read failed"
                if ipc_before is not None and ipc_after is not None:
                    # One server-stats request lies inside the window (ipc_after's own); counters are cumulative.
                    row["server_stats_ipc_per_msg"] = {
                        key: round((ipc_after[key] - ipc_before[key]) / messages, 4)
                        for key in sorted(ipc_after) if key in ipc_before}
                out[name] = row
        finally:
            view.close()
            self.close_workspace(c, ws_id)
            c.close()
        return out

    # -- bulk interference (IPC-8)

    def bulk_interference(self, sizes_kib, shape):
        """One flood row per BULK_FRAME_MAX in `sizes_kib`, each on a daemon started with that frame
        cut (p05-ipc.md 3.2: the bulk preemption boundary), when the daemon advertises the cut;
        otherwise one row at the daemon's own framing and the sweep skipped. The PTY write size is
        fixed (--flood-write-kib): it does not set the daemon's framing."""
        a = self.args
        out = {"pty_write_kib": a.flood_write_kib}
        advertised = self.ident.get(BULK_FRAME_MAX_FIELD)
        if not isinstance(advertised, int):
            out["frame_max_sweep"] = {"skipped": f"BULK_FRAME_MAX not advertised (identify `{BULK_FRAME_MAX_FIELD}`)"}
            out.update(self._bulk_row("default", None))
            return out
        out["frame_max_default_bytes"] = advertised
        for k in sizes_kib:
            sub = Bench(a, env_extra={BULK_FRAME_MAX_ENV: str(k * 1024)})
            try:
                sub.start()
                got = sub.ident.get(BULK_FRAME_MAX_FIELD)
                if got != k * 1024:
                    error = f"started with {BULK_FRAME_MAX_ENV}={k * 1024}, identify {BULK_FRAME_MAX_FIELD}={got}"
                    out[f"bulk-{k}k-flood"] = {"n": 0, "error": error}
                    self.failed = True
                    continue
                sub.grow(*shape)
                out.update(sub._bulk_row(f"{k}k", k))
                self.failed = self.failed or sub.failed
            finally:
                sub.stop()
        return out

    def _bulk_row(self, label, frame_max_kib):
        a = self.args
        control = Conn(self.sock_path)
        marker = f"BENCH-FLOOD-DONE-{os.getpid()}-{label}"
        write = a.flood_write_kib * 1024
        argv = ["perl", "-e", FLOOD_PERL, str(write), str(a.flood_mib * 1024 * 1024 // write), marker]
        ws_id, (surface,) = self.new_terminals(control, f"bench-bulk-{os.getpid()}-{label}", [argv])
        try:
            row = self._flood(label, surface, marker, a.flood_timeout)
            row[f"bulk-{label}-flood"].update(frame_max_kib=frame_max_kib, pty_write_kib=a.flood_write_kib)
            return row
        finally:
            self.close_workspace(control, ws_id)
            control.close()

    def _flood(self, label, surface, marker, timeout):
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
            f"bulk-{label}-idle-ping-same": stats(idle),
            f"bulk-{label}-ping-same": stats(same),
            f"bulk-{label}-ping-other": {**stats(other["samples"]),
                                         **({"error": other["error"]} if "error" in other else {})},
            f"bulk-{label}-flood": {
                "flood_mib": self.args.flood_mib, "seconds": round(flood_s, 3),
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
        by_sock = {v.sock: v for v in views}
        socks = [c.sock, *by_sock]
        for _ in range(n):
            rid = c.send("ping")
            t = time.perf_counter()
            while True:
                c.pump(0)
                if rid in c.replies:
                    break
                if time.perf_counter() - t > 10:
                    raise RuntimeError("ping got no reply in 10 s")
                readable, _, _ = select.select(socks, [], [], 0.05)
                for sock in readable:
                    if sock in by_sock:
                        by_sock[sock].pump(0)
            c.replies.pop(rid)
            vals.append((time.perf_counter() - t) * 1000)
            gap_end = time.perf_counter() + 0.002
            while views and (left := gap_end - time.perf_counter()) > 0:
                readable, _, _ = select.select(list(by_sock), [], [], left)
                for sock in readable:
                    by_sock[sock].pump(0)
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
        app_role = self.identify_as_app(control, "bench-app")
        app_ws, (echo_surface,) = self.new_terminals(control, f"bench-app-{os.getpid()}", [ECHO_ARGV])
        _, pane = self.locate(control, echo_surface)
        agents = []
        echo = None
        try:
            for i in range(clients):
                ws_id, (surface,) = self.new_terminals(control, f"bench-agent-{os.getpid()}-{i}", [["/bin/sh"]])
                agents.append({"workspace": ws_id, "pane": self.locate(control, surface)[1]["id"], "surface": surface})
            echo = EchoProbe(self, echo_surface)
            out = {"clients": clients, "seconds": seconds, "mix": list(AUTOMATION_MIX),
                   "app_role": {"control": app_role, "echo_view": echo.role}}
            out["idle"] = {"echo": stats(echo.measure(echo_n)), "split": stats(self._splits(control, pane["id"], split_n))}
            out["alone"] = self._automation(agents, seconds, lambda until: time.sleep(max(0.0, until - time.time())))
            app = {"echo": [], "split": []}

            def app_work(until):
                # Interleaved and repeated until the storm window ends, so every app sample lies inside it.
                while len(app["echo"]) < echo_n or len(app["split"]) < split_n or time.time() < until:
                    app["echo"] += echo.measure(STORM_ECHO_BATCH)
                    app["split"] += self._splits(control, pane["id"], 1)

            storm = self._automation(agents, seconds, app_work)
            out["storm"] = {"echo": stats(app["echo"]), "split": stats(app["split"]), "automation": storm}
            out["ipc16"] = ipc16_verdict(out["idle"]["echo"], out["storm"], out["alone"])
            return out
        finally:
            if echo is not None:
                echo.close()
            for agent in agents:
                self.close_workspace(control, agent["workspace"])
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

    def _automation(self, agents, seconds, app_work):
        """Runs the automation clients for exactly the app's work: `app_work(until)` starts when they
        do and they stop when it returns. The row counts only requests that completed in that window
        (`window_s`, the app work's own time); `clients_cover_window` false (a client ended early, or
        the app work outran the clients' hard deadline) fails the run."""
        start_at = time.time() + 1.0
        deadline = start_at + seconds + max(30.0, 3 * seconds)
        stop = SPAWN.Event()
        closer = "close-tabs" if self.has("batch-close-v1") else "close-surface"
        procs, queue = run_processes([(automation_main, (self.sock_path, agent, closer, start_at, deadline, stop))
                                      for agent in agents])
        while time.time() < start_at:
            time.sleep(0.005)
        t0 = time.time()
        try:
            app_work(t0 + seconds)
        finally:
            t1 = time.time()
            stop.set()
        row = storm_window(collect(procs, queue, 30), t0, t1)
        if "errors" in row or not row["clients_cover_window"]:
            self.failed = True
        return row

    # -- scenario

    def section(self, res, key, fn):
        """Runs one section into res[key]; an exception records {'error': ...} there and fails the run
        instead of losing the scenario's other rows."""
        try:
            value = fn()
            if value is not None:
                res[key] = value
        except Exception as e:  # noqa: BLE001
            log("section failed", key, traceback.format_exc())
            res[key] = {**(res.get(key) or {}), "error": repr(e)}
            self.failed = True

    def daemon_locks(self):
        """`debug-daemon-locks` after the scenario's load: the frontend and automation wait and
        hold percentiles of each daemon lock, or `skipped` when the daemon does not serve it."""
        c = Conn(self.sock_path)
        try:
            resp = c.call("debug-daemon-locks")
        finally:
            c.close()
        if not resp.get("ok"):
            return {"skipped": f"debug-daemon-locks not served: {resp.get('error')}"}
        return {"since": "daemon start", "locks": daemon_lock_rows(must(resp, "debug-daemon-locks"))}

    def scenario(self, name, workspaces, terminals, busy):
        log("scenario", name, workspaces, terminals)
        res = self.result["scenarios"][name] = {}
        self.grow(workspaces, terminals, busy)
        time.sleep(self.args.settle)
        a = self.args
        create_n = a.create_n or max(10, a.n // 10)
        res["ops"] = {}
        self.section(res, "ops", lambda: self.ops(select_ops(a.ops), a.n, create_n, res["ops"]))
        self.section(res, "concurrent", lambda: self.concurrent(10, max(20, a.n // 5)))
        self.section(res, "cli", lambda: self.cli(a.cli_n))
        self.section(res, "syscalls", lambda: self.syscalls(max(100, a.n)))
        if a.bulk_interference:
            self.section(res, "bulk_interference",
                         lambda: self.bulk_interference(a.bulk_interference, (workspaces, terminals, busy)))
        if a.streams:
            self.section(res, "streams", lambda: self.streams(a.streams, a.n))
        if a.automation_storm:
            self.section(res, "automation_storm",
                         lambda: self.automation_storm(a.automation_storm, a.storm_seconds, a.n // 3 or 1, create_n))
        self.section(res, "daemon_locks", self.daemon_locks)
        report(name, res)


class OutputView:
    """A view of one terminal on its own attach connection, with the app's handshake
    (Bench.identify_as_app), collecting the terminal's output bytes."""

    def __init__(self, bench, surface, name="bench-view"):
        self.surface = surface
        self.seen = bytearray()
        self.markers = itertools.count(1)
        self.conn = Conn(bench.sock_path, on_event=self._on_event)
        self.role = bench.identify_as_app(self.conn, name)
        bench.attach(self.conn, surface)
        self.conn.pump(0.3)

    def _on_event(self, line, msg):
        if msg is None:
            self.seen += output_bytes(line)

    def wait_for(self, needle, since, what):
        while needle not in self.seen:
            if time.perf_counter() - since > 10:
                raise RuntimeError(f"no {what} in 10 s")
            self.conn.pump(0.0005)

    def drain(self, control, tag):
        """Returns once the shell has run a marker command sent after everything before it, and its
        output has reached this view: the daemon has read and broadcast all earlier output."""
        suffix = f"{tag}-{next(self.markers)}"
        word = f"BENCH-{suffix}"
        self.seen.clear()
        t = time.perf_counter()
        # The typed line echoes `BENCH-%s`; only the shell's output holds `BENCH-<tag>-<n>`.
        must(control.call("send", surface=self.surface, text=f"printf 'BENCH-%s\\n' {suffix}\r"), "send")
        self.wait_for(word.encode(), t, f"marker {word}")
        self.seen.clear()

    def close(self):
        self.conn.close()


class EchoProbe(OutputView):
    """The app's typing path: a key sent on the attach connection, timed to its echo."""

    def __init__(self, bench, surface):
        super().__init__(bench, surface, name="bench-app-view")
        self.measure(20)

    def measure(self, n):
        vals = []
        for i in range(n):
            ch = chr(ord("a") + i % 26)
            self.seen.clear()
            t = time.perf_counter()
            self.conn.send("send", surface=self.surface, text=ch)
            self.wait_for(ch.encode(), t, f"echo of {ch!r}")
            vals.append((time.perf_counter() - t) * 1000)
            self.conn.pump(0.01)
        return vals


# ---------------------------------------------------------------------------------------------
# Report and Q16


FLAT_SECTIONS = ("ops", "concurrent", "cli", "bulk_interference")


LOCK_CALLERS = ("frontend", "automation")
LOCK_FIELDS = ("count", "p50", "p95", "p99", "max")


def daemon_lock_rows(data):
    """{lock: {caller: {wait_us, hold_us}}} of a `debug-daemon-locks` result for LOCK_CALLERS; a
    caller the daemon did not report has zeros."""
    out = {}
    for table in data.get("locks") or []:
        callers = {row.get("caller"): row for row in table.get("callers") or []}
        out[table["lock"]] = {
            caller: {kind: {field: (callers.get(caller) or {}).get(kind, {}).get(field, 0) for field in LOCK_FIELDS}
                     for kind in ("wait_us", "hold_us")}
            for caller in LOCK_CALLERS
        }
    return out


def rows(res, prefix=""):
    """(metric, row) for every latency row and every skipped mode of a scenario result."""
    for key, value in res.items():
        if not isinstance(value, dict):
            continue
        if "n" in value or "skipped" in value:
            yield prefix + key, value
        else:
            yield from rows(value, prefix if (key in FLAT_SECTIONS and not prefix) else f"{prefix}{key}.")


INDEPENDENT_SECTIONS = ("ops", "cli")  # each row is its own measurement: a failed row drops only itself


def section_failed(value):
    """True when a section or row failed: its own `error`, or a client of it that failed (`errors`) or did not cover
    the window, which also leaves its sibling rows measured under less load than planned."""
    if not isinstance(value, dict):
        return False
    if "error" in value or "errors" in value or value.get("clients_cover_window") is False:
        return True
    return any(section_failed(child) for child in value.values())


def lab_series(result):
    """result-v1 series of a report: every latency row that kept its raw samples, per scenario (module docstring).
    A failed row records nothing; outside INDEPENDENT_SECTIONS its whole section records nothing."""
    series = []
    for scenario, res in sorted((result.get("scenarios") or {}).items()):
        if not isinstance(res, dict) or "error" in res:
            continue
        sections = {}
        for key, value in res.items():
            if key in INDEPENDENT_SECTIONS and isinstance(value, dict) and "error" not in value:
                sections[key] = {name: row for name, row in value.items() if not section_failed(row)}
            elif not section_failed(value):
                sections[key] = value
        for metric, row in rows(sections):
            if row.get("samples_ms"):
                name = ".".join(lab.metric_part(part) for part in metric.split("."))
                series.append(lab.Series(f"{METRIC_PREFIX}.{lab.metric_part(scenario)}.{name}", "ms", "lower",
                                         list(row["samples_ms"])))
    return series


def report(name, res):
    for section, value in res.items():
        if isinstance(value, dict) and isinstance(value.get("error"), str):
            print(f"PERF-DAEMON-ERROR {name} {section} {value['error']}", flush=True)
    for metric, s in rows(res):
        if "error" in s:
            print(f"PERF-DAEMON-ERROR {name} {metric} n={s.get('n', 0)} {s['error']}", flush=True)
        elif s.get("n"):
            print(f"PERF-DAEMON {name} {metric} n={s['n']} p50={s.get('p50_ms')} p95={s.get('p95_ms')} "
                  f"p99={s.get('p99_ms')} max={s.get('max_ms')}" + (f" argv=\"{s['argv']}\"" if "argv" in s else ""),
                  flush=True)
        elif "skipped" in s:
            print(f"PERF-DAEMON-SKIP {name} {metric} {s['skipped']}", flush=True)
    for metric, s in (res.get("syscalls") or {}).items():
        if isinstance(s, dict) and "ctx_per_msg" in s:
            print(f"PERF-DAEMON-SYSCALLS {name} {metric} syscalls/msg={s.get('syscalls_per_msg', 'n/a')} "
                  f"ctx/msg={s['ctx_per_msg']} idle_syscalls/s={s.get('syscalls_idle_per_s', 'n/a')}"
                  + (f" ipc/msg={json.dumps(s['server_stats_ipc_per_msg'])}" if "server_stats_ipc_per_msg" in s else ""),
                  flush=True)
    for op_name, row in (res.get("ops") or {}).items():
        methods = row.get("daemon_methods") if isinstance(row, dict) else None
        for method, agreement in (methods or {}).items():
            if isinstance(agreement, dict) and "bucket_delta" in agreement:
                print(f"PERF-DAEMON-METHOD {name} {op_name} {method} n={agreement['n']} "
                      f"within_one_bucket={agreement['within_one_bucket']} "
                      f"bucket_delta={json.dumps(agreement['bucket_delta'])}", flush=True)
    for lock, callers in ((res.get("daemon_locks") or {}).get("locks") or {}).items():
        for caller, row in callers.items():
            print(f"PERF-DAEMON-LOCKS {name} {lock} {caller} " + " ".join(
                f"{kind}.{field}={row[kind][field]}" for kind in ("wait_us", "hold_us")
                for field in ("count", "p95", "p99", "max")), flush=True)
    storm = res.get("automation_storm")
    if storm and "ipc16" in storm:
        print(f"PERF-DAEMON-IPC16 {name} " + " ".join(f"{k}={v}" for k, v in storm["ipc16"].items()), flush=True)


def slow_ops(result, scenario="scale", threshold_ms=Q16_THRESHOLD_MS):
    """Q16 items: ops of `scenario` whose p95 is above the threshold."""
    ops = ((result.get("scenarios") or {}).get(scenario) or {}).get("ops") or {}
    items = []
    for name, row in sorted(ops.items()):
        if isinstance(row, dict) and row.get("n") and row.get("p95_ms", 0) > threshold_ms:
            items.append({"file": SCRIPT_REL, "line": OPS[name]["line"] if name in OPS else 0, "key": name,
                          "p95_ms": row["p95_ms"], "wire": row.get("wire")})
    return items


def same_commit(a, b):
    """True when two (possibly abbreviated) commit ids name the same commit."""
    return bool(a and b) and (a.startswith(b) or b.startswith(a))


def write_q16(targets_path, result, scenario="scale", threshold_ms=Q16_THRESHOLD_MS):
    """Writes runtime.Q16 (and its run record) into ipc-targets.json; returns the items.

    The record's sha is the measured daemon's build_commit. A daemon with none is named by the
    script checkout's HEAD (`sha_source: script checkout`) plus the binary's sha256 and mtime; a
    build_commit that is not HEAD is refused, since Q16 would credit HEAD with another commit's timings."""
    if scenario not in (result.get("scenarios") or {}):
        raise ValueError(f"Q16 needs the {scenario} scenario in the result")
    ops = result["scenarios"][scenario].get("ops") or {}
    missing = [name for name in OPS if not isinstance(ops.get(name), dict)]
    if missing:
        raise ValueError(f"Q16 needs --ops all; not measured: {', '.join(missing)}")
    sha, sha_source = measured_commit(result)
    head = (result.get("source") or {}).get("sha")
    if sha_source == "daemon build_commit" and not same_commit(sha, head):
        raise ValueError(f"the measured daemon is build_commit {sha}, not this checkout's HEAD {head}: "
                         "Q16 would credit the wrong commit; run from a checkout of the binary's commit")
    items = slow_ops(result, scenario, threshold_ms)
    with open(targets_path, encoding="utf-8") as f:
        targets = json.load(f)
    runtime = targets.setdefault("runtime", {})
    runtime["Q16"] = items
    run = {
        "command": "bench-daemon-latency.py --ops all --scenario scale --write-q16",
        "scenario": scenario, "threshold_ms": threshold_ms,
        "sha": sha, "sha_source": sha_source, "host": result.get("host"),
        "daemon_version": (result.get("daemon") or {}).get("version"),
        "skipped": sorted(name for name, row in ops.items() if isinstance(row, dict) and "skipped" in row),
        "failed": sorted(name for name, row in ops.items() if isinstance(row, dict) and "error" in row),
    }
    if sha_source == "script checkout":
        run["binary"] = (result.get("daemon") or {}).get("binary")
    runtime["Q16_run"] = run
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
    ap.add_argument("--bin", help="the cmux-tui daemon binary (default: the --app bundle's cmux-tui)")
    ap.add_argument("--out", required=True, help=f"the report FILE.json, or a folder for result-v1 and {REPORT_NAME}")
    ap.add_argument("--n", type=int, default=300, help="samples per read/write op (default 300)")
    ap.add_argument("--create-n", type=int, default=0, help="samples per create op (default max(10, n/10))")
    ap.add_argument("--cli-n", type=int, default=40)
    ap.add_argument("--settle", type=float, default=3.0)
    ap.add_argument("--ops", default="base", help="base, create, all, or a comma list of op names")
    ap.add_argument("--scenario", "--scenarios", dest="scenarios", action="append",
                    help="small, scale (repeatable or comma list; default small,scale)")
    ap.add_argument("--bulk-interference", nargs="?", const=[16, 32, 64], type=parse_kib, default=None,
                    metavar="KIB,...", help="BULK_FRAME_MAX values in KiB to sweep when the daemon advertises "
                                            "the frame cut (default 16,32,64)")
    ap.add_argument("--flood-mib", type=int, default=256)
    ap.add_argument("--flood-write-kib", type=int, default=64, help="bytes per PTY write of the flood, in KiB")
    ap.add_argument("--flood-timeout", type=float, default=180.0)
    ap.add_argument("--streams", type=int, default=0, metavar="N", help="attach N printing terminals")
    ap.add_argument("--automation-storm", type=int, default=0, metavar="N", help="N automation clients")
    ap.add_argument("--storm-seconds", type=float, default=8.0)
    ap.add_argument("--write-q16", nargs="?", const=TARGETS, default=None, metavar="TARGETS",
                    help=f"write runtime.Q16 into ipc-targets.json (default {os.path.relpath(TARGETS, REPO_ROOT)})")
    ap.add_argument("--app", help=lab.APP_HELP)
    ap.add_argument("--tag", help=lab.TAG_HELP)
    lab.add_arguments(ap, STORY)
    args = ap.parse_args(argv)
    wanted = [s for value in (args.scenarios or ["small,scale"]) for s in value.split(",") if s]
    unknown = [s for s in wanted if s not in SCENARIOS]
    if unknown:
        ap.error(f"unknown scenario(s) {', '.join(unknown)}; known: {', '.join(SCENARIOS)}")
    args.scenarios = wanted
    if args.flood_write_kib <= 0:
        ap.error("--flood-write-kib must be positive")
    select_ops(args.ops)
    unmeasured = [name for name in ipc5_ops() if name not in OPS]
    if unmeasured:
        ap.error(f"ipc5_ops of {os.path.relpath(TARGETS, REPO_ROOT)} names ops this bench has no plan for: "
                 f"{', '.join(unmeasured)} (add an @op)")
    if args.write_q16 and (args.ops != "all" or "scale" not in wanted):
        ap.error("--write-q16 needs --ops all and --scenario scale (Q16's definition)")
    if args.write_q16 and sys.platform != "darwin":
        ap.error("--write-q16 runs on a macOS fleet host only: VM and Linux timing is not perf evidence")
    args.bin, out, measured = lab.prepare(ap, args, REPORT_NAME)
    return args, out, measured


def write_out(path, result):
    with open(path, "w") as f:
        json.dump(result, f, indent=1)


def main(argv=None):
    """Writes --out whatever happens (a failed section, a failed start, Ctrl-C), then --write-q16
    only when the whole run passed."""
    args, out, measured = parse_args(argv)
    b = Bench(args)
    b.result.update(host=host_info(), source=source_info(),
                    args={k: v for k, v in vars(args).items() if k not in ("bin", "out")})
    status = 1
    try:
        b.start()
        b.result["daemon"]["binary"] = binary_info(args.bin)
        for name in args.scenarios:
            b.scenario(name, *SCENARIOS[name])
        lab.validate_host(out.results, [b.daemon.pid])
        status = 0
    except Exception as e:  # noqa: BLE001
        log("FAILED", traceback.format_exc(), b.tail()[-1500:])
        b.result["error"] = repr(e)
    except KeyboardInterrupt:
        b.result["error"] = "interrupted"
        raise
    finally:
        try:
            b.stop()
        finally:
            if "scale" in b.result["scenarios"]:
                b.result["q16"] = slow_ops(b.result)
                print("PERF-DAEMON-Q16 scale " + json.dumps([f"{i['key']}={i['p95_ms']}" for i in b.result["q16"]]),
                      flush=True)
            if measured:
                path = lab.write(out.results, args.story, lab_series(b.result), measured)
                b.result["results"] = str(path) if path else None
                log("result-v1", path)
            write_out(out.report, b.result)
    if b.failed:
        status = 1
    if args.write_q16 and status == 0:
        try:
            write_q16(args.write_q16, b.result)
            log("wrote runtime.Q16 to", args.write_q16)
        except (OSError, ValueError) as e:
            log("--write-q16 failed:", e)
            b.result["q16_write_error"] = str(e)
            write_out(out.report, b.result)
            status = 1
    return status


if __name__ == "__main__":
    sys.exit(main())
