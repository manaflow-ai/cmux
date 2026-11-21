#!/usr/bin/env python3
"""The app under extreme stress, from several angles (the `stress` cmux-bench; Leo, 2026-11-21: "i think being able
to test our app under extreme stress from various angles would be a good bench to be able to run through").

Run through the allowlisted fleet entry: scripts/measure/split-spring.sh --suite=stress [--angles=cpu,chats,...]
(split-spring-terminal.py execs this script with --tag/--app/--out/--json). One fresh app launch per angle. Each
angle measures a baseline window on the quiet app, then applies its stressor and measures the same window again:

  cpu      CPU and thread starvation: --cpu-procs processes x --cpu-threads threads hashing beside the app
           (stress_load.py cpu), more runnable threads than cores, as on a Mac at load 45-93.
  chats    Many agent chats at once, no model calls: --chats mock chats, each seeded with --transcript-rows rows
           (debug.agent_pane seed_rows), all streaming (debug.agent_pane stream) through the window.
  scale    Many workspaces, terminals and tabs, with output floods: --workspaces workspaces (--panes terminals each),
           --flood-terminals of them printing as fast as the terminal takes it.
  cli      CLI and socket API flood: scripts/stress-cli-socket-api.py against the app's own CLI and socket, plus
           --cli-clients threads calling snapshot.get / debug.windows / workspace list as fast as answered.
  memory   Memory pressure: --memory-fraction x RAM of incompressible dirty pages (stress_load.py memory) until
           the machine compresses and swaps.

Each window records: frame time p50/p95 and dropped frames % (debug.frames, a display-link probe), input latency
p50/p95 (debug.key round trips into a focused `zsh -f` terminal: the key waits on the main thread), daemon round
trip p50/p95 (debug.daemon_requests, the window's delta of the app's own histogram), app CPU % (ps cputime delta
over wall), footprint MB, main-thread hangs over --hang-ms (debug.hangs), and the machine's load average and swap.

The report (--json): {"stress": {"version", "angles": {ANGLE: {"baseline": {...}, "stress": {...}, "load": {...},
"notes": [...]}}, "failures": [...]}}. Every load is a child of this script, by handle, with its own deadline.
"""
from __future__ import annotations

import argparse
import importlib.util
import json
import os
import re
import socket
import statistics
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError  # noqa: E402
import stress_load  # noqa: E402

VERSION = 1
ANGLES = ("cpu", "chats", "scale", "cli", "memory")
FLOOD = "while :; do printf '%s flood line %s %s %s\\n' $RANDOM $RANDOM $RANDOM $RANDOM; done"

parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
parser.add_argument("--app", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--angles", default=",".join(ANGLES), help=f"comma list of {','.join(ANGLES)}")
parser.add_argument("--window", type=float, default=20.0, help="seconds per measured window (baseline and stress)")
parser.add_argument("--key-interval", type=float, default=0.1, help="seconds between measured keys (one in flight)")
parser.add_argument("--hang-ms", type=int, default=100, help="main-thread stall that counts as a hang")
parser.add_argument("--cpu-procs", type=int, default=0, help="cpu angle: load processes (default: this host's cores)")
parser.add_argument("--cpu-threads", type=int, default=8, help="cpu angle: threads per load process")
parser.add_argument("--chats", type=int, default=12, help="chats angle: mock agent chats open and streaming")
parser.add_argument("--transcript-rows", type=int, default=20000, help="chats angle: rows seeded in each chat")
parser.add_argument("--long-chats", type=int, default=2,
                    help="chats angle: of the chats, this many get --long-rows rows instead (very long transcripts)")
parser.add_argument("--long-rows", type=int, default=100000)
parser.add_argument("--workspaces", type=int, default=40, help="scale angle: workspaces made")
parser.add_argument("--panes", type=int, default=4, help="scale angle: terminal panes per workspace")
parser.add_argument("--flood-terminals", type=int, default=16, help="scale angle: terminals printing as fast as they can")
parser.add_argument("--cli-clients", type=int, default=16, help="cli angle: socket threads beside the API stress script")
parser.add_argument("--cli-burst-workers", type=int, default=16, help="cli angle: stress-cli-socket-api.py --burst-workers")
parser.add_argument("--memory-fraction", type=float, default=1.1, help="memory angle: allocate this share of RAM")
parser.add_argument("--memory-cap-mb", type=int, default=0, help="memory angle: never more than this (0: free disk bound)")
opts = parser.parse_args()

OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
APP = os.path.abspath(opts.app.rstrip("/"))
CLI = os.path.join(APP, "Contents/Resources/bin/cmux")
WINDOW = (40, 40, 1600, 1000)
report = {"stress": {"version": VERSION, "opts": vars(opts), "host": os.uname().nodename, "cores": os.cpu_count(),
                     "angles": {}, "failures": [], "log": []}}
STATE = {"socket": f"/tmp/cmux-debug-{opts.tag}.sock", "config": None}


def note(text):
    print(f"stress: {text}", flush=True)
    report["stress"]["log"].append(text)


def save():
    if opts.json:
        with open(opts.json, "w") as f:
            json.dump(report, f, indent=1)


# ---------------------------------------------------------------- app access
def rpc(method, params=None, timeout=30):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(STATE["socket"])
        conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 22)
            if not chunk:
                break
            buf += chunk
        conn.close()
        reply = json.loads(buf)
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    return reply.get("result") if reply.get("ok") else {"error": reply.get("error")}


def action(name, args=None, settle=0.0, target=None, timeout=60):
    params = {"action": name, "args": args or {}, "focus": True, "origin": "script"}
    if target:
        params["target"] = target
    reply = rpc("action.run", params, timeout=timeout)
    if settle:
        time.sleep(settle)  # test harness: the layout settles before the next step
    return reply


def cli(*args, timeout=60):
    env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
    if STATE["config"]:
        env["CMUX_NEXT_CONFIG_FILE"] = STATE["config"]
    try:
        return subprocess.run([CLI, "--app-socket", STATE["socket"], *args], env=env, capture_output=True, text=True,
                              timeout=timeout, stdin=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        return subprocess.CompletedProcess(args, 124, "", "timeout")


def wait(predicate, seconds, step=0.25):
    end = time.monotonic() + seconds
    while time.monotonic() < end:  # bounded wait for the live app
        try:
            value = predicate()
        except Exception:  # noqa: BLE001  the app may not answer yet
            value = None
        if value:
            return value
        time.sleep(step)
    return None


def workspaces():
    snap = rpc("snapshot.get") or {}
    return [w for w in (snap.get("workspaces") or []) if isinstance(w, dict)] if isinstance(snap, dict) else []


def named_workspace(name):
    for w in workspaces():
        if (w.get("name") or w.get("title")) == name:
            panes = [p for sc in w.get("screens") or [] for p in sc.get("panes") or [] if not p.get("dock")]
            return w.get("id"), panes
    return None, []


# ---------------------------------------------------------------- measurement
def pct(values):
    if not values:
        return None
    s = sorted(values)
    pick = lambda p: s[min(len(s) - 1, int(round((len(s) - 1) * p)))]  # noqa: E731
    return {"n": len(s), "p50": round(pick(0.5), 3), "p95": round(pick(0.95), 3), "p99": round(pick(0.99), 3),
            "max": round(s[-1], 3), "mean": round(statistics.fmean(s), 3)}


def cpu_seconds(pid):
    out = subprocess.run(["ps", "-o", "cputime=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    if not out:
        return None
    total = 0.0
    for x in out.replace("-", ":").split(":"):
        total = total * 60 + float(x)
    return total


def footprint_mb(pid):
    """The app process's physical footprint (`footprint`), else its resident size (`ps -o rss`)."""
    try:
        out = subprocess.run(["footprint", str(pid)], capture_output=True, text=True, timeout=30).stdout
    except (OSError, subprocess.TimeoutExpired):
        out = ""
    m = re.search(r"(?:phys_footprint|Footprint):\s*([\d.]+)\s*([KMG])B", out)
    if m:
        return round(float(m.group(1)) * {"K": 1 / 1024, "M": 1, "G": 1024}[m.group(2)], 1), "footprint"
    rss = subprocess.run(["ps", "-o", "rss=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()
    return (round(int(rss) / 1024, 1), "rss") if rss.isdigit() else (None, None)


def swap_used_mb():
    out = subprocess.run(["sysctl", "-n", "vm.swapusage"], capture_output=True, text=True).stdout
    m = re.search(r"used = ([\d.]+)M", out)
    return float(m.group(1)) if m else None


def memory_pressure_level():
    out = subprocess.run(["sysctl", "-n", "kern.memorystatus_vm_pressure_level"], capture_output=True, text=True).stdout
    return int(out) if out.strip().isdigit() else None


def ram_mb():
    out = subprocess.run(["sysctl", "-n", "hw.memsize"], capture_output=True, text=True).stdout.strip()
    return int(out) // (1 << 20) if out.isdigit() else None


def histogram_delta(before, after):
    """The window's share of debug.daemon_requests: counts after minus before per bucket, its p50/p95 in ms (the
    bucket's upper bound), or None with no request in the window."""
    if not isinstance(after, dict) or after.get("error"):
        return None
    bounds = after.get("bounds_us") or []
    now = after.get("counts") or []
    then = (before or {}).get("counts") or [0] * len(now)
    if not bounds or len(then) != len(now):
        return {"count": None, "p50_ms": (after.get("p50_us") or 0) / 1000 or None,
                "p95_ms": (after.get("p95_us") or 0) / 1000 or None, "cumulative": True}
    delta = [max(0, a - b) for a, b in zip(now, then)]
    total = sum(delta)
    out = {"count": total, "errors": (after.get("errors") or 0) - ((before or {}).get("errors") or 0),
           "timeouts": (after.get("timeouts") or 0) - ((before or {}).get("timeouts") or 0)}
    if not total:
        return dict(out, p50_ms=None, p95_ms=None)
    for name, share in (("p50_ms", 0.5), ("p95_ms", 0.95)):
        seen = 0
        for index, n in enumerate(delta):
            seen += n
            if seen >= share * total:
                bound = bounds[index] if index < len(bounds) else after.get("max_us") or bounds[-1]
                out[name] = round(float(bound) / 1000, 3)
                break
    return out


def frame_summary(frames):
    if not isinstance(frames, dict) or frames.get("error"):
        return {"error": (frames or {}).get("error") if isinstance(frames, dict) else str(frames)}
    count, missed = frames.get("frames") or 0, frames.get("missed") or 0
    return {"frames": count, "missed": missed, "refresh_ms": frames.get("refresh_ms"),
            "p50_ms": frames.get("p50_ms"), "p95_ms": frames.get("p95_ms"), "p99_ms": frames.get("p99_ms"),
            "max_ms": frames.get("max_ms"), "main_ms_p95": frames.get("main_ms_p95"),
            "dropped_pct": round(100.0 * missed / (count + missed), 2) if count + missed else None}


def focus_typing(ws, pane):
    for _ in range(4):
        action("goToWorkspace", {"workspace": ws})
        if pane:
            action("pane.focus", target=f"pane:{pane}")
        time.sleep(0.4)  # focus settles
        report_ = rpc("debug.focus") or {}
        responders = [((w.get("appkit") or {}).get("first_responder")) for w in report_.get("windows") or []
                      if isinstance(w, dict)]
        if any("TerminalSurfaceView" in str(r) for r in responders):
            return True
    return False


def measure(pid, typing, seconds):
    """One window: frames, keys, hangs, daemon requests, CPU, footprint, load and swap."""
    focused = focus_typing(*typing)
    rpc("debug.hangs", {"clear": True})
    daemon_before = rpc("debug.daemon_requests", timeout=10)
    swap_before = swap_used_mb()
    rpc("debug.frames", {"action": "start"})
    t0, c0 = time.monotonic(), cpu_seconds(pid)
    trips, errors = [], 0
    letters = "abcdefghijklmnopqrstuvwxyz"
    index = 0
    while time.monotonic() - t0 < seconds:  # bounded by the window
        k0 = time.perf_counter()
        reply = rpc("debug.key", {"key": letters[index % 26], "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)},
                    timeout=10)
        if isinstance(reply, dict) and reply.get("error"):
            errors += 1
        else:
            trips.append((time.perf_counter() - k0) * 1000)
        index += 1
        if index % 40 == 0:
            action("terminal.sendText", {"text": "\x15"})  # Ctrl-U: the typed line stays short
        rest = opts.key_interval - (time.perf_counter() - k0)
        if rest > 0:
            time.sleep(rest)  # one key in flight
    t1, c1 = time.monotonic(), cpu_seconds(pid)
    frames = frame_summary(rpc("debug.frames", {"action": "stop"}, timeout=30))
    hangs = rpc("debug.hangs", {"limit": 12}, timeout=20) or {}
    daemon = histogram_delta(daemon_before, rpc("debug.daemon_requests", timeout=10))
    action("terminal.sendText", {"text": "\x15"})
    foot, foot_kind = footprint_mb(pid)
    keys = pct(trips)
    return {
        "seconds": round(t1 - t0, 2), "terminal_focused": focused,
        "frames": frames, "frame_p50_ms": frames.get("p50_ms"), "frame_p95_ms": frames.get("p95_ms"),
        "dropped_frames_pct": frames.get("dropped_pct"),
        "input": keys, "input_errors": errors,
        "input_p50_ms": (keys or {}).get("p50"), "input_p95_ms": (keys or {}).get("p95"),
        "daemon": daemon, "daemon_rtt_p50_ms": (daemon or {}).get("p50_ms"),
        "daemon_rtt_p95_ms": (daemon or {}).get("p95_ms"),
        "app_cpu_pct": round(100.0 * (c1 - c0) / (t1 - t0), 1) if c0 is not None and c1 is not None and t1 > t0 else None,
        "footprint_mb": foot, "footprint_source": foot_kind,
        "hangs": hangs.get("count") if isinstance(hangs, dict) and not hangs.get("error") else None,
        "hang_max_ms": hangs.get("max_ms") if isinstance(hangs, dict) else None,
        "load_avg_1m": round(os.getloadavg()[0], 2),
        "swap_used_mb": swap_used_mb(), "swap_grew_mb": (lambda a: round(a - swap_before, 1) if a is not None
                                                          and swap_before is not None else None)(swap_used_mb()),
        "vm_pressure_level": memory_pressure_level(),
    }


# ---------------------------------------------------------------- stressors
class Pump(threading.Thread):
    """Calls `step()` until stopped, at most every `period` seconds."""

    def __init__(self, step, period=0.0):
        super().__init__(daemon=True)
        self.step, self.period, self.flag, self.calls, self.errors = step, period, threading.Event(), 0, 0

    def run(self):
        while not self.flag.is_set():
            t0 = time.perf_counter()
            try:
                reply = self.step(self.calls)
                if isinstance(reply, dict) and reply.get("error"):
                    self.errors += 1
            except Exception:  # noqa: BLE001  one failed call must not end the load
                self.errors += 1
            self.calls += 1
            rest = self.period - (time.perf_counter() - t0)
            if rest > 0:
                self.flag.wait(rest)

    def stop(self):
        self.flag.set()
        self.join(timeout=30)


class Angle:
    """A stressor: setup() once after the baseline, start() before the stress window, stop() after."""

    def __init__(self):
        self.load, self.notes, self.pumps, self.children = {}, [], [], []

    def setup(self):
        pass

    def start(self):
        pass

    def stop(self):
        for pump in self.pumps:
            pump.stop()
        self.load.update({"pump_calls": sum(p.calls for p in self.pumps), "pump_errors": sum(p.errors for p in self.pumps)})
        for child in self.children:
            stress_load.stop(child)


class Cpu(Angle):
    def start(self):
        procs = opts.cpu_procs or os.cpu_count() or 8
        seconds = opts.window + 60
        self.children.append(stress_load.start_cpu(procs, opts.cpu_threads, seconds))
        self.load.update(procs=procs, threads_each=opts.cpu_threads, runnable_threads=procs * opts.cpu_threads,
                         cores=os.cpu_count())
        time.sleep(3)  # the load ramps before the window
        self.load["load_avg_at_start"] = round(os.getloadavg()[0], 2)


def open_agent_chat():
    action("palette.newAgentChat", settle=1.0, timeout=120)
    wait(lambda: (rpc("debug.agent_pane", {"action": "readiness"}, timeout=5) or {}).get("document_ready"), 30, 0.5)
    engine = rpc("debug.agent_pane", {"action": "engine"}, timeout=10) or {}
    pane = engine.get("pane") if isinstance(engine, dict) else None
    if pane:
        rpc("debug.agent_pane", {"action": "select_session", "pane": pane, "session": "mock-session"}, timeout=30)
    return pane


class Chats(Angle):
    def setup(self):
        self.panes = []
        t0 = time.monotonic()
        for index in range(opts.chats):
            pane = open_agent_chat()
            if not pane:
                self.notes.append(f"chat {index} did not open")
                continue
            self.panes.append(pane)
            rows = opts.long_rows if index < opts.long_chats else opts.transcript_rows
            seeded = rpc("debug.agent_pane", {"action": "seed_rows", "pane": pane, "count": rows}, timeout=300)
            if isinstance(seeded, dict) and seeded.get("error"):
                self.notes.append(f"chat {pane}: seed_rows {rows}: {seeded.get('error')}")
        self.load.update(chats=len(self.panes), transcript_rows=opts.transcript_rows, long_chats=opts.long_chats,
                         long_rows=opts.long_rows, setup_s=round(time.monotonic() - t0, 1))

    def start(self):
        for pane in self.panes:
            self.pumps.append(Pump(lambda _, p=pane: rpc("debug.agent_pane", {
                "action": "stream", "pane": p, "rows": 60, "seconds": 3, "chunk_ms": 16, "chunk_chars": 48}, timeout=15),
                period=3.0))
        for pump in self.pumps:
            pump.start()
        time.sleep(1)  # the streams run before the window


class Scale(Angle):
    def setup(self):
        t0 = time.monotonic()
        made = floods = terminals = 0
        for index in range(opts.workspaces):
            flood = floods < opts.flood_terminals
            ref = cli("workspace", "create", "--name", f"stress {index}", "--shell",
                      FLOOD if flood else "exec /bin/zsh -f").stdout.strip()
            if not ref:
                self.notes.append(f"workspace {index} was not made")
                continue
            made += 1
            terminals += 1
            floods += flood
            if opts.panes > 1:
                cli("workspace", ref, "focus")
                for split in range(opts.panes - 1):
                    action("splitDown" if split % 2 else "splitRight", settle=0.15)
                    terminals += 1
                    if floods < opts.flood_terminals:
                        action("terminal.sendText", {"text": FLOOD + "\r"})
                        floods += 1
        self.load.update(workspaces=made, panes_each=opts.panes, terminals=terminals, flood_terminals=floods,
                         setup_s=round(time.monotonic() - t0, 1), workspaces_listed=len(workspaces()))


class CliFlood(Angle):
    def start(self):
        calls = ("snapshot.get", "debug.windows", "debug.focus")
        for index in range(opts.cli_clients):
            method = calls[index % len(calls)]
            self.pumps.append(Pump(lambda _, m=method: rpc(m, timeout=15)))
        for pump in self.pumps:
            pump.start()
        script = os.path.join(REPO, "scripts/stress-cli-socket-api.py")
        artifacts = os.path.join(OUT, "cli-socket-api")
        self.artifacts = artifacts
        if os.path.exists(script):
            self.children.append(subprocess.Popen(
                [sys.executable, script, "--cli", CLI, "--socket", STATE["socket"], "--tag", opts.tag,
                 "--duration", f"{int(opts.window + 5)}s", "--artifacts", artifacts,
                 "--burst-workers", str(opts.cli_burst_workers)],
                stdout=open(os.path.join(OUT, "cli-socket-api.log"), "w"), stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL))
        else:
            self.notes.append("scripts/stress-cli-socket-api.py is not in this checkout: socket threads only")
        self.load.update(socket_clients=opts.cli_clients, api_script=os.path.exists(script))
        time.sleep(1)

    def stop(self):
        child = self.children[0] if self.children else None
        if child is not None:
            try:
                child.wait(timeout=30)  # its --duration ends it
            except subprocess.TimeoutExpired:
                pass
        super().stop()
        summary = os.path.join(getattr(self, "artifacts", ""), "summary.json")
        if os.path.exists(summary):
            try:
                data = json.load(open(summary))
                self.load["api_summary"] = {k: data.get(k) for k in ("ok", "elapsed_seconds", "cycles", "counts")}
                failures = data.get("failures") or []
                self.load["api_failures"] = len(failures)
                if failures:
                    self.notes.append(f"stress-cli-socket-api: {len(failures)} failures, first {json.dumps(failures[0])[:240]}")
            except (OSError, ValueError) as error:
                self.notes.append(f"stress-cli-socket-api summary unreadable: {error}")
        elif child is not None:
            self.notes.append(f"stress-cli-socket-api left no summary (exit {child.returncode})")


class Memory(Angle):
    def start(self):
        ram = ram_mb() or 16384
        want = int(ram * opts.memory_fraction)
        stat = os.statvfs("/")
        free_disk = stat.f_bavail * stat.f_frsize // (1 << 20)
        cap = opts.memory_cap_mb or max(1024, free_disk - 8192)  # swap needs disk: keep 8 GB free
        mb = min(want, cap)
        if mb < ram:
            self.notes.append(f"memory: {mb} MB of {ram} MB RAM (free disk {free_disk} MB bounds it); may not reach swap")
        seconds = opts.window + 240
        child = stress_load.start_memory(mb, seconds)
        self.children.append(child)
        t0 = time.monotonic()
        allocated = 0
        while time.monotonic() - t0 < 180:  # bounded ramp: until allocated or 3 minutes
            line = child.stdout.readline()
            if not line:
                break
            try:
                step = json.loads(line)
            except ValueError:
                continue
            allocated = step.get("allocated_mb", allocated)
            if step.get("done"):
                break
        self.load.update(ram_mb=ram, free_disk_mb=free_disk, requested_mb=mb, allocated_mb=allocated, ramp_s=round(time.monotonic() - t0, 1),
                         swap_used_mb_at_start=swap_used_mb(), vm_pressure_level_at_start=memory_pressure_level())
        threading.Thread(target=lambda: [None for _ in child.stdout], daemon=True).start()  # drain its progress


STRESSORS = {"cpu": Cpu, "chats": Chats, "scale": Scale, "cli": CliFlood, "memory": Memory}


# ---------------------------------------------------------------- one angle
def run_angle(name):
    entry = {"angle": name, "load": {}, "notes": []}
    report["stress"]["angles"][name] = entry
    bench = BenchApp(APP, out=OUT, config={"browser": {"defaultEngine": "chromium"}}, window=WINDOW,
                     log_name=f"app-stress-{name}.log",
                     env={"CMUX_NEXT_HANG_THRESHOLD_MS": str(opts.hang_ms)})
    stressor = STRESSORS[name]()
    try:
        try:
            bench.launch(timeout=180)
        except LaunchError as error:
            note(f"{name}: the app did not come up: {error.reason}")
            report["stress"]["failures"].append({"angle": name, "reason": error.reason,
                                                 "detail": (error.report or {}).get("detail")})
            return
        STATE["socket"], STATE["config"] = bench.socket, os.path.join(bench.scratch, "cmux.json")
        pid = bench.process.pid
        cli("workspace", "create", "--name", "typing", "--focus", "--shell", "exec /bin/zsh -f")
        ws, panes = wait(lambda: (lambda r: r if r[0] else None)(named_workspace("typing")), 20) or (None, [])
        typing = (ws, panes[0].get("id") if panes else None)
        time.sleep(2)  # the prompt draws
        entry["baseline"] = measure(pid, typing, opts.window)
        note(f"{name} baseline: {summary_line(entry['baseline'])}")
        stressor.setup()
        stressor.start()
        entry["stress"] = measure(pid, typing, opts.window)
        note(f"{name} stress: {summary_line(entry['stress'])}")
    except Exception as error:  # noqa: BLE001  one angle failing must not hide the others
        note(f"{name}: failed: {error!r}")
        report["stress"]["failures"].append({"angle": name, "reason": "exception", "detail": repr(error)})
    finally:
        try:
            stressor.stop()
        finally:
            entry["load"], entry["notes"] = stressor.load, stressor.notes
            bench.stop()
            save()


def summary_line(m):
    keys = ("frame_p50_ms", "frame_p95_ms", "dropped_frames_pct", "input_p95_ms", "daemon_rtt_p95_ms", "app_cpu_pct",
            "footprint_mb", "hangs", "load_avg_1m", "swap_used_mb")
    return " ".join(f"{k}={m.get(k)}" for k in keys)


def main():
    angles = [a.strip() for a in opts.angles.split(",") if a.strip()]
    unknown = [a for a in angles if a not in STRESSORS]
    if unknown:
        sys.exit(f"stress: unknown angles {unknown}; known: {','.join(ANGLES)}")
    report["stress"]["macos"] = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    report["stress"]["ram_mb"] = ram_mb()
    try:
        for name in angles:
            run_angle(name)
    finally:
        save()
    measured = [a for a, e in report["stress"]["angles"].items() if e.get("stress")]
    print(f"STRESS measured {measured} of {angles}; report {opts.json}", flush=True)
    sys.exit(0 if measured else 1)


if __name__ == "__main__":
    main()
