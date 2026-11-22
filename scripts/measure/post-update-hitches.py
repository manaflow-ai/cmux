#!/usr/bin/env python3
"""Lag spikes of cmux NEXT's first launch after a real Sparkle update, against a second launch (measurement only).

Lawrence, relayed by Leo 2026-11-16: "there's lag spikes when after updating cmux (opening for first time) can you
try to iron out all the lag spikes". This measures them:

  1. installs published nightly-next build FROM (default: the feed's second item) into a private root
     (/tmp/cmux-puh-*), with the fresh-home environment of scripts/ci/fresh_home_launch_smoke.py (private HOME and
     CFFIXED_USER_HOME, TMPDIR, release control socket, launch marks) and the bundle's defaults set aside for the
     whole run (DefaultsAside; put back at the end);
  2. seeds a home while FROM runs: WORKSPACES terminal workspaces (half print in a loop, each with a second tab),
     one long agent chat on the app's own acpmux (chat_open_agent.py's realistic turns, CHAT_TURNS of them, opened
     as its own workspace), a couple of New Tabs and a typing workspace with scrollback; lets it settle 30 s;
  3. stages the update (downloadAutomatically on in the home's cmux-next.json, palette.checkForUpdates until updates.status is "installing"), quits (action quit: Sparkle
     installs on quit), waits until the bundle's CFBundleVersion is TO, and never lets Sparkle relaunch it;
  4. measures launch A (the first of TO, from the same home) and launch B (TO again after a normal quit) for
     SECONDS each from the launch, with the same script:
       - main-thread probe: `notifications.status` (a @MainActor control method) every 20 ms, one in flight; a
         reply over 50 ms is a stall sample, consecutive ones are one episode (its length ~ the max latency);
       - per-process CPU (ps cumulative time) and disk bytes (proc_pid_rusage ri_diskio_*, n/a when denied) every
         1 s: the app, its Helpers, cmux-tui, acpmux, terminal and app hosts, and amfid, syspolicyd, XProtect*,
         trustd, mds, mds_stores, mdworker_shared, kernel_task;
       - frames: scripts/measure/tab-switch-frames/recorder.swift (ScreenCaptureKit, outside the app) during the
         interaction rounds; skipped with the reason when capture is denied;
       - interaction rounds 5 s after the socket answers and at 30, 90 and 150 s: switch through every workspace
         (goToWorkspace, reply and shown), scroll (terminal.scrollPageUp/Down on the typing workspace: no shipped
         control action scrolls the agent pane), 5 New Tabs opened and closed, 20 typed lines timed to the shell;
       - launch marks, `log stream` of subsystem com.cmuxterm*, hang files under the private home, updates.status.
  Diagnostics (hq#11994): when a control call goes unanswered (a socket timeout, or an action `not_run`) in any
  phase, it keeps `sample PID 3`, a `screencapture`, the app's on-screen windows and the home's Library/Logs under
  OUT/<phase>/diagnostics/, at once and again 60, 300 and 600 s later, and prints a DIAG line with the top of the
  main thread's heaviest stack. FROM's phase (seed, stage) also keeps a `log stream` with Sparkle's processes.

Isolation: the app's daemon (cmux-tui) socket is the account's temp dir by session name (DaemonLauncher
runtimeBase is confstr(_CS_DARWIN_USER_TEMP_DIR), not TMPDIR), and its remembered daemon socket and its other state
are in the account's defaults domain whatever HOME says. So another running copy of the same bundle id (a resident
cmux NEXT, nightly or a DEV built with the nightly-next id) shares both, and this refuses to run (exit 3) before it
changes anything. After each launch it checks that the app's own daemons and acpmux run from the private root and
that no session socket is another copy's, and stops the run if not.

Prints PUH lines (the summary) and writes OUT/report.json, OUT/A and OUT/B (probe, samples, frames, log stream,
marks, app output). Exit 0 measured, 1 a step failed (no update staged, a launch never answered), 2 usage, 3 cannot
run (isolation, no GUI session). Kills only what it started: by its own PIDs and the processes naming its root.

  post-update-hitches.py [--from BUILD] [--to BUILD] [--workspaces 8] [--seconds 180] [--out DIR] [--no-frames]
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
import plistlib
import re
import select
import shlex
import shutil
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
import urllib.request
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "scripts" / "ci"))
import fresh_home_launch_smoke as smoke  # noqa: E402

# The live nightly-next feed (Info.plist's SUFeedURL; next/appcast-arm64.xml stopped at 2026-11-05's builds, before the
# staged-update pre-warm, so FROM there never pre-warms).
FEED = "https://files-next.cmux.com/nightly-next/appcast-arm64.xml"
BUNDLE_ID = "com.cmuxterm.app.nightly.cmux-next"
# The live feed republishes each cmux NEXT build as cmux NIGHTLY (publish-nightly-identity-legacy), the copy people
# run; only the cmux NEXT feed (nightly-next/next/) carries BUNDLE_ID.
NIGHTLY_BUNDLE_ID = "com.cmuxterm.app.nightly"


def feed_bundle_id(feed):
    """The bundle id of the app FEED publishes."""
    return BUNDLE_ID if "/nightly-next/next/" in feed else NIGHTLY_BUNDLE_ID
RECORDER_SRC = REPO / "scripts/measure/tab-switch-frames/recorder.swift"
TURNS_AGENT = ("puh-turns", REPO / "scripts/cmux-next/chat_open_agent.py")
PROBE_METHOD = "notifications.status"
PROBE_EVERY_S, STALL_MS = 0.020, 50.0
PROBE_DIAG_S = 2.0  # a probe unanswered this long takes the diagnostics (Diagnostics) while the stall lasts
ROUNDS_AT_S = (None, 30.0, 90.0, 150.0)  # None: 5 s after the socket answers
SYSTEM = ("amfid", "syspolicyd", "XprotectService", "XProtect", "XProtectPluginService", "XProtectBehaviorService",
          "trustd", "mds", "mds_stores", "mdworker_shared", "mdworker", "kernel_task", "launchservicesd", "lsd",
          "WindowServer", "cfprefsd", "tccd", "fseventsd")
LOOP = "while :; do date; ls -la /usr/bin | tail -n 20; sleep 0.05; done\r"
USER_AGENT = {"User-Agent": "cmux-post-update-hitches/1"}
DIAG_AT_S = (0, 60, 300, 600)  # diagnostics at the first unanswered control call and this long after it


def say(*parts):
    print("PUH", *parts, flush=True)


class CannotRun(Exception):
    pass


class StepFailed(Exception):
    pass


# ---- feed and bundle ------------------------------------------------------------------------------------------

def feed_items(url):
    xml = urllib.request.urlopen(urllib.request.Request(url, headers=USER_AGENT), timeout=30).read().decode()
    items = []
    for item in re.findall(r"<item>.*?</item>", xml, re.S):
        build = re.search(r"<sparkle:version>(.*?)<", item) or re.search(r'sparkle:version="([^"]+)"', item)
        short = re.search(r"<sparkle:shortVersionString>(.*?)<", item) or re.search(r'sparkle:shortVersionString="([^"]+)"', item)
        dmg = re.search(r'<enclosure[^>]*url="([^"]+\.dmg)"', item)
        if build and dmg:
            items.append({"build": build.group(1), "short": short.group(1) if short else None, "url": dmg.group(1),
                          "delta_from": re.findall(r'sparkle:deltaFrom="([^"]+)"', item)})
    return items


def bundle_build(app: Path):
    try:
        with open(app / "Contents/Info.plist", "rb") as handle:
            return plistlib.load(handle).get("CFBundleVersion")
    except OSError:
        return None


def download(url, dest: Path):
    with urllib.request.urlopen(urllib.request.Request(url, headers=USER_AGENT), timeout=900) as response, \
            open(dest, "wb") as out:
        shutil.copyfileobj(response, out, 1 << 20)


# ---- processes ------------------------------------------------------------------------------------------------

def ps_rows():
    """[(pid, ppid, uid, cpu seconds, rss KiB, command)] of every process."""
    out = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,uid=,time=,rss=,command="], capture_output=True,
                         text=True, timeout=30).stdout
    rows = []
    for line in out.splitlines():
        parts = line.split(None, 5)
        if len(parts) == 6 and parts[0].isdigit():
            rows.append((int(parts[0]), int(parts[1]), int(parts[2]), cpu_seconds(parts[3]), int(parts[4]), parts[5]))
    return rows


def cpu_seconds(text):
    """ps `time` ([[dd-]hh:]mm:ss.cc) in seconds."""
    days, _, rest = text.rpartition("-")
    fields = [float(f) for f in rest.split(":")]
    seconds = 0.0
    for f in fields:
        seconds = seconds * 60 + f
    return seconds + (int(days) * 86400 if days else 0)


def bundle_of(command):
    """The .app bundle of a command line's executable, or None."""
    match = re.match(r"(/.+?\.app)/Contents/", command)
    return match.group(1) if match else None


def bundle_id_of(bundle):
    try:
        with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as handle:
            return plistlib.load(handle).get("CFBundleIdentifier")
    except (OSError, ValueError):
        return None


def under(command, root: Path):
    real = os.path.realpath(root)
    return f"{root}/" in command or f"{real}/" in command


def kind(command, root: Path):
    """What a process is, for the CPU and disk tables."""
    exe = command.split(" --", 1)[0]
    base = os.path.basename(exe.split()[0]) if exe else "?"
    if under(command, root):
        if " Helper" in exe:
            for flag, name in (("--type=renderer", "helper-renderer"), ("--type=gpu-process", "helper-gpu"),
                               ("--type=utility", "helper-utility")):
                if flag in command:
                    return name
            return "helper"
        if "/Contents/MacOS/" in exe and " Helper" not in exe:
            return "app"
        if "/bin/cmux-tui" in exe:
            if "__terminal-host" in command:
                return "terminal-host"
            return "cmux-tui-chief" if "--session cmux-chief" in command else "cmux-tui"
        if "/bin/acpmux" in exe:
            return "acpmux-" + ((command.split("/bin/acpmux", 1)[1].split() or ["?"])[0])
        if "/bin/" in exe:
            return command.split("/bin/", 1)[1].split()[0]
        return "own-" + base
    if "__terminal-host" in command:
        return None  # a terminal host names no root; own ones are added by pid (smoke.terminal_host_pids)
    if "com.apple.WebKit." in command:
        return None
    for name in SYSTEM:
        if base == name or base.startswith(name + " "):
            return name
    if base.startswith("XProtect") or base.startswith("Xprotect"):
        return base
    return None


# proc_pid_rusage(RUSAGE_INFO_V4): u64 words; 2,3 user/system mach ticks; 18,19 ri_diskio_bytesread/written.
_libproc = ctypes.CDLL("/usr/lib/libproc.dylib") if sys.platform == "darwin" else None


class _Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_tb = _Timebase()
if sys.platform == "darwin":
    ctypes.CDLL("/usr/lib/libSystem.dylib").mach_timebase_info(ctypes.byref(_tb))


def rusage(pid):
    """(cpu seconds, disk bytes read, disk bytes written), or None when denied or gone."""
    if _libproc is None:
        return None
    buf = (ctypes.c_uint64 * 64)()
    if _libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(4), ctypes.byref(buf)) != 0:
        return None
    return ((buf[2] + buf[3]) * _tb.numer / _tb.denom / 1e9, int(buf[18]), int(buf[19]))


class Sampler(threading.Thread):
    """Every 1 s: CPU (cumulative, ps) and disk bytes (rusage) of the run's processes and the system daemons."""

    def __init__(self, root: Path, t0: float):
        super().__init__(daemon=True)
        self.root, self.t0 = root, t0
        self.rows = []  # [t, pid, kind, cpu_s, read, written | None]
        self.stop = threading.Event()

    def run(self):
        while not self.stop.is_set():
            started = time.monotonic()
            try:
                hosts = set(smoke.terminal_host_pids(self.root))
                for pid, _ppid, _uid, cpu, _rss, command in ps_rows():
                    name = "terminal-host" if pid in hosts else kind(command, self.root)
                    if not name:
                        continue
                    usage = rusage(pid)
                    self.rows.append([round(started - self.t0, 2), pid, name, cpu,
                                      usage[1] if usage else None, usage[2] if usage else None])
            except (OSError, subprocess.SubprocessError, ValueError) as error:
                self.rows.append([round(started - self.t0, 2), 0, f"error {error}", 0, None, None])
            self.stop.wait(max(0.0, 1.0 - (time.monotonic() - started)))


def cpu_windows(rows, seconds, width=30.0):
    """{window: {kind: cpu seconds}} from the cumulative per-pid samples, and {kind: disk MB read, written}."""
    by_pid = {}
    for t, pid, name, cpu, read, written in rows:
        if pid:
            by_pid.setdefault((pid, name), []).append((t, cpu, read, written))
    windows, disk = {}, {}
    for (pid, name), samples in by_pid.items():
        samples.sort()
        first_t = samples[0][0]
        # A process that started during the measurement counts from 0 (its CPU before the first sample is ours).
        previous = (first_t, 0.0 if first_t > 1.5 else samples[0][1])
        for t, cpu, _read, _written in samples:
            spent = max(0.0, cpu - previous[1])
            slot = f"{int(t // width) * int(width)}-{int(t // width) * int(width) + int(width)}s"
            windows.setdefault(slot, {}).setdefault(name, 0.0)
            windows[slot][name] += spent
            previous = (t, cpu)
        reads = [s[2] for s in samples if s[2] is not None]
        writes = [s[3] for s in samples if s[3] is not None]
        entry = disk.setdefault(name, {"read_mb": 0.0, "written_mb": 0.0, "pids": 0, "denied": 0})
        entry["pids"] += 1
        if reads:
            base_r = 0 if first_t > 1.5 else reads[0]
            base_w = 0 if first_t > 1.5 else writes[0]
            entry["read_mb"] += (reads[-1] - base_r) / 1e6
            entry["written_mb"] += (writes[-1] - base_w) / 1e6
        else:
            entry["denied"] += 1
    for slot in windows:
        windows[slot] = dict(sorted(((k, round(v, 2)) for k, v in windows[slot].items() if v >= 0.01),
                                    key=lambda kv: -kv[1]))
    for entry in disk.values():
        readable = entry["pids"] > entry["denied"]
        entry["read_mb"] = round(entry["read_mb"], 1) if readable else None
        entry["written_mb"] = round(entry["written_mb"], 1) if readable else None
    return dict(sorted(windows.items(), key=lambda kv: int(kv[0].split("-")[0]))), disk


# ---- the app --------------------------------------------------------------------------------------------------

def rpc(path, method, params=None, timeout=30.0):
    try:
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as conn:
            conn.settimeout(timeout)
            conn.connect(str(path))
            conn.sendall((json.dumps({"id": 1, "method": method, "params": params or {}}) + "\n").encode())
            buf = b""
            while b"\n" not in buf:
                chunk = conn.recv(1 << 20)
                if not chunk:
                    break
                buf += chunk
        reply = json.loads(buf.split(b"\n", 1)[0] or b"{}")
    except (OSError, ValueError) as error:
        return {"error": str(error)}
    if reply.get("ok") is False or reply.get("error"):
        return {"error": reply.get("error")}
    return reply.get("result") if reply.get("result") is not None else {}


def unanswered(reply):
    """Whether a control reply means the app never got to the call: a socket timeout, or an action its main actor
    did not run within the deadline (`not_run`)."""
    error = reply.get("error") if isinstance(reply, dict) else None
    text = json.dumps(error) if error is not None else ""
    return "timed out" in text or "not_run" in text


class Diagnostics:
    """What the app was doing when a control call went unanswered (hq#11994): `sample PID 3` (a hang is one main-thread
    stack, a modal loop shows -[NSApplication runModal...]), `screencapture` of the console (a window the socket can't
    see), the app's on-screen windows, and the private home's Library/Logs. Taken at the first unanswered call and
    again DIAG_AT_S after it, under OUT/diagnostics/<n>-at<s>s/."""

    def __init__(self, out: Path, home: Path, tools: Path):
        self.out, self.home, self.tools = out / "diagnostics", home, tools
        self.first_at, self.taken = None, []
        self.lock = threading.Lock()

    def on_unanswered(self, app, method, reply):
        if app.pid is None or not app.alive() or not self.lock.acquire(blocking=False):
            return  # another thread is taking them now
        try:
            now = time.monotonic()
            if self.first_at is None:
                self.first_at = now
            due = [at for at in DIAG_AT_S if at not in self.taken and now - self.first_at >= at]
            if due:
                self.taken.append(due[-1])
                self.take(app, f"{len(self.taken)}-at{int(now - self.first_at)}s", method, reply)
        finally:
            self.lock.release()

    def take(self, app, label, method, reply):
        folder = self.out / label
        folder.mkdir(parents=True, exist_ok=True)
        (folder / "reason.txt").write_text(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} pid {app.pid} "
                                           f"{method}: {json.dumps(reply)[:400]}\n")
        results = {}
        for name, args, limit in (("sample", ["/usr/bin/sample", str(app.pid), "3", "-file", str(folder / "sample.txt")], 60),
                                  ("screencapture", ["/usr/sbin/screencapture", "-x", str(folder / "screen.png")], 30)):
            try:
                results[name] = subprocess.run(args, capture_output=True, text=True, timeout=limit).returncode
            except (OSError, subprocess.SubprocessError) as error:
                results[name] = str(error)
        lister = build_window_lister(self.tools)
        if lister:
            try:
                listed = subprocess.run([str(lister), str(app.pid)], capture_output=True, text=True, timeout=30)
                (folder / "windows.txt").write_text(listed.stdout + listed.stderr)
                results["windows"] = listed.stdout.count("\n")
            except (OSError, subprocess.SubprocessError) as error:
                results["windows"] = str(error)
        logs = self.home / "Library/Logs"
        if logs.is_dir():
            shutil.copytree(logs, folder / "Logs", dirs_exist_ok=True, symlinks=True,
                            ignore=lambda _d, names: [n for n in names if n.endswith(".sock")])
        stack = main_thread_stack(folder / "sample.txt")
        (folder / "main-thread.txt").write_text("\n".join(stack) + "\n")
        say(f"DIAG {label} after unanswered {method}: {json.dumps(results)}; main thread (innermost first): "
            + (" < ".join(stack[::-1][:8]) if stack else "no stack read"))


class LogStream:
    """`log stream --style ndjson` of PREDICATE into PATH while the block runs; stopped by its own pid after."""

    def __init__(self, path: Path, predicate: str):
        self.path, self.predicate = path, predicate

    def __enter__(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.file = open(self.path, "wb")
        self.process = subprocess.Popen(["/usr/bin/log", "stream", "--style", "ndjson", "--level", "debug",
                                         "--predicate", self.predicate], stdout=self.file, stderr=subprocess.STDOUT,
                                        start_new_session=True)
        return self

    def __exit__(self, *_exc):
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.file.close()
        return False


def main_thread_stack(sample_file: Path, limit=80):
    """The main thread's heaviest path in a `sample` report, outermost frame first: at each depth, the first (heaviest)
    child. `sample` prints a call graph per thread: `Thread_N  DispatchQueue_1: com.apple.main-thread`, then lines
    like `    + 2345 symbol  (in Image) + 12  [0x...]` indented by depth."""
    try:
        lines = sample_file.read_text(errors="replace").splitlines()
    except OSError:
        return []
    frames, inside, last_depth = [], False, -1
    for line in lines:
        if not inside:
            inside = "Thread_" in line and "com.apple.main-thread" in line
            continue
        if not line.strip() or "Thread_" in line:
            break
        match = re.match(r"^([\s+!:|]*)\d+\s+(.*?)(?:\s{2}\(in |\s+\[0x|$)", line)
        if not match:
            continue
        depth = len(match.group(1))
        if depth <= last_depth:
            continue  # a sibling (lighter branch) of a frame already kept
        frames.append(match.group(2).strip())
        last_depth = depth
        if len(frames) >= limit:
            break
    return frames


WINDOW_LISTER_SRC = r"""
import CoreGraphics
import Foundation
// post-update-hitches window lister: the on-screen windows of PID (every window with no PID): layer, owner, name, bounds.
let pid = CommandLine.arguments.count > 1 ? Int32(CommandLine.arguments[1]) : nil
let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
for w in list {
    let owner = w[kCGWindowOwnerPID as String] as? Int32 ?? -1
    if let pid, owner != pid { continue }
    let b = w[kCGWindowBounds as String] as? [String: Any] ?? [:]
    print("pid \(owner) layer \(w[kCGWindowLayer as String] ?? "?") owner \(w[kCGWindowOwnerName as String] ?? "?") name \(w[kCGWindowName as String] ?? "") bounds \(b["X"] ?? 0),\(b["Y"] ?? 0) \(b["Width"] ?? 0)x\(b["Height"] ?? 0)")
}
"""


def build_window_lister(cache: Path):
    binary = cache / "window-lister"
    if binary.exists():
        return binary
    try:
        cache.mkdir(parents=True, exist_ok=True)
        source = cache / "window-lister.swift"
        source.write_text(WINDOW_LISTER_SRC)
        done = subprocess.run(["swiftc", "-O", "-o", str(binary), str(source)], capture_output=True, text=True,
                              timeout=600)
    except (OSError, subprocess.SubprocessError):
        return None
    return binary if done.returncode == 0 and binary.exists() else None


class Probe(threading.Thread):
    """`notifications.status` every 20 ms, one request in flight, new connection each: [(t_send, ms | None)]."""

    def __init__(self, sock: Path, t0: float, seconds: float):
        super().__init__(daemon=True)
        self.sock, self.t0, self.seconds = sock, t0, seconds
        self.samples, self.socket_at, self.first_reply_at = [], None, None
        self.stop = threading.Event()
        self.app = None  # App: a probe unanswered for PROBE_DIAG_S takes the app's diagnostics, during the stall
        self.in_flight_since = None

    def watch(self):
        """The probe's stall watchdog: one in flight PROBE_DIAG_S or longer takes the diagnostics while it hangs."""
        while not self.stop.wait(0.25):
            since = self.in_flight_since
            if since is not None and self.first_reply_at is not None and time.monotonic() - since >= PROBE_DIAG_S \
                    and self.app is not None and self.app.diagnostics is not None:
                self.app.diagnostics.on_unanswered(self.app, PROBE_METHOD,
                                                   {"error": f"in flight {time.monotonic() - since:.1f} s"})

    def run(self):
        while not self.stop.is_set() and time.monotonic() - self.t0 < self.seconds:
            if self.socket_at is None:
                if self.sock.exists():
                    self.socket_at = time.monotonic() - self.t0
                else:
                    time.sleep(0.005)  # harness: waiting for the socket file
                    continue
            sent = time.monotonic()
            self.in_flight_since = sent
            reply = rpc(self.sock, PROBE_METHOD, timeout=30)
            ms = (time.monotonic() - sent) * 1000
            ok = not (isinstance(reply, dict) and reply.get("error"))
            self.in_flight_since = None
            if ok and self.first_reply_at is None:
                self.first_reply_at = time.monotonic() - self.t0
            if self.first_reply_at is not None:
                self.samples.append((round(sent - self.t0, 3), round(ms, 2) if ok else None))
            else:
                time.sleep(0.01)  # harness: the socket exists but does not answer yet
            self.stop.wait(max(0.0, PROBE_EVERY_S - (time.monotonic() - sent)))


def stall_episodes(samples, threshold=STALL_MS):
    episodes, current = [], None
    for t, ms in samples:
        if ms is None:
            continue  # a failed request (counted apart as errors) neither starts nor ends an episode
        if ms > threshold:
            if current is None:
                current = {"start_s": t, "probes": 0, "max_ms": 0.0}
            current["probes"] += 1
            current["max_ms"] = max(current["max_ms"], ms)
            current["end_s"] = round(t + ms / 1000, 3)
        elif current is not None:
            episodes.append(current)
            current = None
    if current is not None:
        episodes.append(current)
    for e in episodes:
        e["ms"] = round(max(e["max_ms"], (e["end_s"] - e["start_s"]) * 1000), 1)
    return episodes


def pct(values, p):
    if not values:
        return None
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round(p / 100 * (len(ordered) - 1))))], 1)


class Recorder:
    """scripts/measure/tab-switch-frames/recorder.swift on the app's window (as tab_switch_frames.py drives it)."""

    def __init__(self, binary, pid):
        self.process = subprocess.Popen([str(binary), str(pid), "320"], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                        stderr=subprocess.PIPE, text=True, bufsize=1, start_new_session=True)
        self.ready = self.reply(30) or {"error": "no answer in 30 s"}
        if not self.ready.get("ready") or not self.ready.get("first_frame"):
            self.quit()
            raise RuntimeError(f"recorder: {self.ready}")
        self.w, self.h, self.hz = self.ready["w"], self.ready["h"], self.ready["display_hz"]

    def reply(self, timeout):
        ready, _, _ = select.select([self.process.stdout], [], [], timeout)
        if not ready:
            return None
        line = self.process.stdout.readline()
        try:
            return json.loads(line)
        except ValueError:
            return {"error": line.strip()[:300]}

    def send(self, line):
        self.process.stdin.write(line + "\n")
        self.process.stdin.flush()

    def begin(self, path):
        self.send(f"begin {path}")
        return (self.reply(10) or {}).get("begun")

    def mark(self, name):
        self.send(f"mark {name}")

    def end(self):
        self.send("end")
        answer = self.reply(30) or {}
        return answer.get("frames"), [(n, t) for n, t in answer.get("marks") or []]

    def quit(self):
        if self.process.poll() is None:
            try:
                self.send("quit")
                self.process.wait(timeout=10)
            except (OSError, subprocess.TimeoutExpired):
                os.killpg(self.process.pid, signal.SIGKILL)  # this run's own recorder, by its own process group


def frame_times(path, w, h):
    size = 8 + w * h
    times = []
    with open(path, "rb") as handle:
        data = handle.read()
    for offset in range(0, len(data) - size + 1, size):
        times.append(struct.unpack_from("<d", data, offset)[0])
    return sorted(times)


def dropped_frames(times, marks, hz, animated=("switch", "scroll")):
    """Gaps over 2 display periods between frames in the second after each animated action's mark, up to the last
    frame that changed in that second: (dropped frames, gaps)."""
    period = 1.0 / hz
    dropped, gaps = 0, []
    starts = sorted(t for name, t in marks if name.split(":")[0] in animated)
    for start in starts:
        window = [t for t in times if start <= t <= start + 1.0]
        for a, b in zip(window, window[1:]):
            if b - a > 2 * period:
                missed = int(round((b - a) / period)) - 1
                dropped += missed
                gaps.append({"at": round(a - start, 3), "gap_ms": round((b - a) * 1000, 1), "missed": missed})
    return dropped, gaps


class App:
    def __init__(self, path: Path, root: Path, opts):
        self.path, self.root, self.opts = path, root, opts
        self.sock = root / "s.sock"
        self.bundle_id, self.executable = smoke.bundle_info(path)
        self.process = None
        self.pid = None
        self.diagnostics = None  # Diagnostics, set per phase: kept when a control call goes unanswered

    def env(self, marks_path, activate):
        env = smoke.fresh_env(self.root, self.sock, 0)
        env.pop("CMUX_NEXT_LAUNCH_MARKS_FD")
        env["CMUX_NEXT_LAUNCH_MARKS_PATH"] = str(marks_path)
        env["CMUX_NEXT_SKIP_ONBOARDING"] = "1"
        env["CMUX_NEXT_TEST_WINDOW_FRAME"] = "40,40,1400,900"
        if activate:
            env.pop("CMUX_NEXT_NO_ACTIVATE", None)  # the window in front: the frame recorder reads the screen
        return env

    def launch(self, out: Path, activate=False):
        """Starts the app; returns the monotonic launch time. Marks go to OUT/marks.txt through a FIFO."""
        out.mkdir(parents=True, exist_ok=True)
        self.pid, self.process = None, None  # the marks reader waits for this launch's pid, not the last one's
        fifo = self.root / f"marks-{uuid.uuid4().hex[:6]}"
        os.mkfifo(fifo)
        reader_fd = os.open(fifo, os.O_RDONLY | os.O_NONBLOCK)
        self.marks_out = out / "marks.txt"
        threading.Thread(target=self.read_marks, args=(reader_fd,), daemon=True).start()
        env = self.env(fifo, activate)
        log = open(out / "app.log", "ab")
        t0 = time.monotonic()
        self.launched_wall = time.time()
        if self.opts.launch == "exec":
            self.process = subprocess.Popen([str(self.path / "Contents/MacOS" / self.executable),
                                             "-ApplePersistenceIgnoreState", "YES"], env=env, cwd=env["HOME"],
                                            stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                            start_new_session=True)
            self.pid = self.process.pid
        else:
            # LaunchServices starts it in the console's Aqua session from ssh (a plain child would get no window
            # server); its pid is then found by the executable under the private root.
            args = ["open", "-n", "-g", "--stdout", str(out / "app.log"), "--stderr", str(out / "app.log")]
            for key, value in env.items():
                args += ["--env", f"{key}={value}"]
            opened = subprocess.run(args + [str(self.path), "--args", "-ApplePersistenceIgnoreState", "YES"],
                                    capture_output=True, text=True, timeout=60)
            if opened.returncode != 0:
                raise StepFailed(f"open failed: {opened.stderr.strip()}")
            self.pid = None
            deadline = time.monotonic() + 30
            exe = str(self.path / "Contents/MacOS" / self.executable)
            while time.monotonic() < deadline and self.pid is None:
                for pid, _pp, _uid, _cpu, _rss, command in ps_rows():
                    if command.startswith(exe) or command.startswith(os.path.realpath(exe)):
                        self.pid = pid
                time.sleep(0.05)  # harness: waiting for LaunchServices to start the process
            if self.pid is None:
                raise StepFailed("open started no app process within 30 s")
        return t0

    def read_marks(self, fd):
        with open(self.marks_out, "a") as out:
            buf = b""
            while True:
                ready, _, _ = select.select([fd], [], [], 1.0)
                if not ready:
                    if self.pid is not None and not self.alive():
                        break
                    continue
                try:
                    chunk = os.read(fd, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    if self.pid is not None and not self.alive():
                        break
                    time.sleep(0.05)  # harness: no writer yet
                    continue
                buf += chunk
                while b"\n" in buf:
                    line, buf = buf.split(b"\n", 1)
                    out.write(f"{time.time():.3f} {line.decode(errors='replace')}\n")
                    out.flush()
        os.close(fd)

    def alive(self):
        return self.pid is not None and smoke.alive(self.pid)

    def call(self, method, params=None, timeout=30):
        reply = rpc(self.sock, method, params, timeout)
        if self.diagnostics is not None and unanswered(reply):
            self.diagnostics.on_unanswered(self, method, reply)
        return reply

    def action(self, action_id, /, focus=True, timeout=60, **args):
        params = {"action": action_id, "args": args, "origin": "script", "idempotency_key": f"mutation_{uuid.uuid4().hex}"}
        if focus:
            params["focus"] = True
        return self.call("action.run", params, timeout=timeout)

    def wait_ready(self, seconds=120):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            if not self.alive():
                return None
            status = self.call("updates.status", timeout=5) if self.sock.exists() else {}
            if isinstance(status, dict) and status.get("build"):
                return status
            time.sleep(0.25)  # harness: waiting for the socket to answer
        return None

    def quit(self, end_everything=False, seconds=90):
        pid = self.pid
        self.action("quit", focus=False, timeout=30, **({"endEverything": True} if end_everything else {}))
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline and pid and smoke.alive(pid):
            if self.process is not None:
                self.process.poll()
            time.sleep(0.2)  # harness: the app's own quit
        if pid and smoke.alive(pid):
            say(f"note: quit did not end the app (pid {pid}) within {seconds:.0f} s")
            return False
        if self.process is not None:
            self.process.poll()
        return True

    # -- topology ----------------------------------------------------------------------------------------------
    def topology(self):
        snap = self.call("snapshot.get", timeout=15)
        return (snap.get("topology") or {}) if isinstance(snap, dict) else {}

    def shown(self):
        topo = self.topology()
        visible = [w.get("workspace") for w in topo.get("windows") or [] if isinstance(w, dict) and w.get("visible")]
        return (topo.get("focus") or {}).get("workspace"), visible

    def workspace_ids(self):
        return [w.get("id") for w in self.topology().get("workspaces") or [] if isinstance(w, dict) and w.get("id")]

    def wait_shown(self, target, seconds=10.0):
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            focus, visible = self.shown()
            if focus == target and target in visible:
                return True
            time.sleep(0.02)  # harness: polling the live app
        return False


# ---- isolation ------------------------------------------------------------------------------------------------

def account_temp_dir():
    out = subprocess.run(["getconf", "DARWIN_USER_TEMP_DIR"], capture_output=True, text=True, timeout=10).stdout.strip()
    return out or "/tmp/"


def is_socket(path):
    """A socket file is there (never connects: a resident daemon is not touched)."""
    try:
        return stat.S_ISSOCK(os.stat(path).st_mode)
    except OSError:
        return False


def other_copies(bundle_id, root: Path):
    """Processes of another copy of BUNDLE_ID (not under ROOT): its app, daemons and acpmux."""
    found = []
    for pid, _pp, uid, _cpu, _rss, command in ps_rows():
        if uid != os.getuid() or under(command, root):
            continue
        bundle = bundle_of(command)
        if bundle and bundle_id_of(bundle) == bundle_id:
            found.append((pid, command[:200]))
    return found


def preflight(bundle_id, root: Path):
    problems = []
    copies = other_copies(bundle_id, root)
    if copies:
        problems.append("another copy of %s runs (it shares the defaults domain, the daemon session socket in the "
                        "account temp dir and the remembered daemon socket): %s"
                        % (bundle_id, "; ".join(f"pid {p} {c}" for p, c in copies[:6])))
    remembered = subprocess.run(["defaults", "read", bundle_id], capture_output=True, text=True, timeout=30).stdout
    for path in re.findall(r'"?cmuxNext\.daemonSocket\.[^"=]+"?\s*=\s*"?([^";]+)"?;', remembered):
        if is_socket(path.strip()):
            problems.append(f"the {bundle_id} defaults remember daemon socket {path.strip()}, which exists: the app "
                            "would talk to that daemon")
    tui = os.path.join(account_temp_dir(), f"cmux-tui-{os.getuid()}")
    if os.path.isdir(tui):
        for name in sorted(os.listdir(tui)):
            if name.startswith("cmux-app-cmux-next") and name.endswith(".sock") and is_socket(os.path.join(tui, name)):
                problems.append(f"a daemon socket exists at {tui}/{name}: the app's own daemon session would be that one")
    if problems:
        raise CannotRun("not isolated: " + " | ".join(problems))


def check_isolation(app: App, resident_sockets):
    """The app's daemons and acpmux run from the private root and use no socket of another copy."""
    own, seen = [], {}
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        own = [(pid, c) for pid, _pp, _u, _cpu, _r, c in ps_rows() if under(c, app.root)]
        if any("/bin/cmux-tui" in c and "--session cmux-app" in c for _p, c in own):
            break
        time.sleep(0.5)  # harness: the app starts its daemon
    for pid, command in own:
        match = re.search(r"--socket (\S+)", command)
        if match:
            seen[pid] = match.group(1)
    clash = [s for s in seen.values() if s in resident_sockets]
    daemons = [c[:160] for _p, c in own if "/bin/cmux-tui" in c or "/bin/acpmux" in c]
    if clash:
        raise CannotRun(f"the app's daemon socket is another copy's: {clash}")
    if not any("--session cmux-app" in c for c in daemons):
        raise CannotRun("the app started no daemon of its own within 30 s (it may be talking to another copy's)")
    return {"own_daemons": daemons, "sockets": sorted(set(seen.values()))}


def resident_daemon_sockets(root: Path):
    sockets = set()
    for _pid, _pp, uid, _cpu, _r, command in ps_rows():
        if uid == os.getuid() and not under(command, root) and "cmux-tui" in command:
            match = re.search(r"--socket (\S+)", command)
            if match:
                sockets.add(match.group(1))
    return sockets


# ---- seeding --------------------------------------------------------------------------------------------------

def new_workspace(app: App, known):
    before = app.shown()[0]
    reply = app.action("workspace.newAtBottom")
    deadline = time.monotonic() + 15
    current = before
    while time.monotonic() < deadline:
        current = app.shown()[0]
        if current and current != before and current not in known:
            break
        time.sleep(0.05)  # harness: the new workspace takes focus
    if not current or current == before or current in known:
        say(f"SETUP workspace not created: {reply}")
        return None
    time.sleep(1.0)  # harness: let the shell start before typing into it
    return current


def acpmux_socket(app: App, seconds=90):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        for pid, _pp, _u, _cpu, _r, command in ps_rows():
            if under(command, app.root) and "/bin/acpmux daemon run" in command:
                listed = subprocess.run(["lsof", "-a", "-p", str(pid), "-U", "-Fn"], capture_output=True, text=True,
                                        timeout=30).stdout
                paths = [line[1:] for line in listed.splitlines()
                         if line.startswith("n/") and line.endswith(".sock") and "acpmux" in line]
                if paths:
                    return paths[0]
        time.sleep(1)  # harness: waiting for the app's acpmux to listen
    return None


def seed(app: App, opts, report):
    ids, roles = [], {}
    for index in range(opts.workspaces):
        current = new_workspace(app, ids)
        if not current:
            continue
        ids.append(current)
        roles[current] = "print" if index % 2 == 0 else "idle"
        app.action("terminal.sendText", text=LOOP if index % 2 == 0 else "echo ready\r")
        app.action("newSurface")  # the second tab
        time.sleep(0.4)  # harness: the tab opens
        app.action("terminal.sendText", text="echo second tab\r")
    typing = new_workspace(app, ids)
    if typing:
        roles[typing] = "typing"
        # Scrollback for the scroll step, then a quiet prompt.
        app.action("terminal.sendText", text="seq 1 6000; clear -x 2>/dev/null; echo ready\r")
    # A couple of New Tabs (the New Tab page) in the first workspace.
    if ids:
        app.action("goToWorkspace", workspace=ids[0])
        for _ in range(2):
            app.action("newTab")
            time.sleep(0.5)  # harness: the page opens
    chat = seed_chat(app, opts)
    report["seed"] = {"workspaces": ids, "roles": roles, "typing": typing, "chat": chat}
    say(f"SEED {len(ids)} workspaces, typing {typing}, chat {json.dumps(chat)}")
    return report["seed"]


def seed_chat(app: App, opts):
    """A long chat on the app's own acpmux: chat_open_agent.py's answered turns, opened as its own workspace."""
    cli = app.path / "Contents/Resources/bin/acpmux"
    started = time.monotonic()
    for _ in range(6):
        added = app.action("agent.harness.add", focus=False, id=TURNS_AGENT[0], name=TURNS_AGENT[0],
                           command=sys.executable, args=shlex.quote(str(TURNS_AGENT[1])), protocol="acp",
                           replace=True)
        if "timeout" not in json.dumps(added):
            break
        time.sleep(5)  # harness: the app is still starting; the add goes on, try again
    sock = acpmux_socket(app)
    if not sock or not os.access(cli, os.X_OK):
        return {"error": f"no acpmux socket ({sock}) or CLI"}
    env = dict(os.environ, ACPMUX_SOCKET=sock, HOME=str(app.root / "h"))
    made = subprocess.run([str(cli), "new", "--json", "-d", "-m", TURNS_AGENT[0], "turn: 0"],
                          capture_output=True, text=True, timeout=180, env=env)
    try:
        session = json.loads(made.stdout)["sessionId"]
    except (ValueError, KeyError):
        return {"error": f"acp new: {(made.stdout + made.stderr).strip()[-400:]}"}
    failed = 0
    for i in range(1, opts.chat_turns):
        sent = subprocess.run([str(cli), "send", session, f"turn: {i}"], capture_output=True, text=True, timeout=180,
                              env=env)
        failed += sent.returncode != 0
        if failed > 5:
            break
    before = set(app.workspace_ids())
    opened = app.action("agent.openSessionWorkspace", focus=False, session=session)
    appeared = []
    deadline = time.monotonic() + 20  # the workspace opens as a task (AgentSessionWorkspace.open)
    while not appeared and time.monotonic() < deadline:
        time.sleep(0.5)  # harness: wait for the new workspace to reach the snapshot
        appeared = [w for w in app.workspace_ids() if w and w not in before]
    return {"session": session, "workspace": appeared[0] if appeared else None, "turns": opts.chat_turns, "failed_sends": failed,
            "seconds": round(time.monotonic() - started, 1), "open": "error" if opened.get("error") else "ok",
            "open_error": opened.get("error")}


# ---- one measured launch --------------------------------------------------------------------------------------

def interaction_round(app: App, label, seed_info, rec, t0, mark_root: Path, index):
    """One round of the script: switch through every workspace, scroll, 5 New Tabs, 20 typed lines."""
    rows = {"label": label, "at_s": round(time.monotonic() - t0, 2), "switch": [], "scroll": [], "newtab": [],
            "type": []}

    def mark(name):
        if rec:
            rec.mark(name)

    ids = [w for w in app.workspace_ids() if w]
    for target in ids:
        mark(f"switch:{target}")
        started = time.monotonic()
        reply = app.action("goToWorkspace", workspace=target)
        reply_ms = (time.monotonic() - started) * 1000
        shown = app.wait_shown(target)
        rows["switch"].append({"target": target, "reply_ms": round(reply_ms, 1),
                               "shown_ms": round((time.monotonic() - started) * 1000, 1), "shown": shown,
                               "error": str(reply.get("error")) if reply.get("error") else None})
    typing = seed_info.get("typing") if seed_info.get("typing") in ids else (ids[-1] if ids else None)
    chat_ws = (seed_info.get("chat") or {}).get("workspace")
    scroll_ws = chat_ws if chat_ws in ids else typing
    window = (rec.ready or {}).get("window") if rec is not None else None
    if scroll_ws and SCROLLER and window:
        app.action("goToWorkspace", workspace=scroll_ws)
        app.wait_shown(scroll_ws)
        x, y = window[0] + window[2] * 0.6, window[1] + window[3] * 0.5
        for direction in ("up",) * 6 + ("down",) * 6:
            mark(f"scroll:{direction}")
            started = time.monotonic()
            done = subprocess.run([str(SCROLLER), f"{x:.0f}", f"{y:.0f}", "-1" if direction == "down" else "1", "8"],
                                  capture_output=True, text=True, timeout=10)
            rows["scroll"].append({"verb": f"wheel-{direction}", "where": "chat" if scroll_ws == chat_ws else "terminal",
                                   "post_ms": round((time.monotonic() - started) * 1000, 1),
                                   "error": (done.stderr.strip()[-200:] or "failed") if done.returncode else None})
            time.sleep(0.15)  # harness: a person's pace
    else:
        rows["scroll"].append({"skipped": "no scroller, window or workspace", "scroller": bool(SCROLLER),
                               "window": bool(window), "workspace": scroll_ws})
    for verb in ("newTab",) * 5 + ("closeTab",) * 5:
        mark(f"newtab:{verb}")
        started = time.monotonic()
        reply = app.action(verb)
        rows["newtab"].append({"verb": verb, "reply_ms": round((time.monotonic() - started) * 1000, 1),
                               "error": str(reply.get("error")) if reply.get("error") else None})
        time.sleep(0.2)  # harness: a person's pace
    if typing:
        app.action("goToWorkspace", workspace=typing)
        app.wait_shown(typing)
        for i in range(20):
            target = mark_root / f"r{index}-{i}"
            mark(f"type:{i}")
            started = time.monotonic()
            reply = app.action("terminal.sendText", text=f": > {target}\r")
            reply_ms = (time.monotonic() - started) * 1000
            deadline = started + 10
            while time.monotonic() < deadline and not target.exists():
                time.sleep(0.002)  # harness: wait for the shell to run the line
            rows["type"].append({"reply_ms": round(reply_ms, 1),
                                 "ran_ms": round((time.monotonic() - started) * 1000, 1), "ok": target.exists(),
                                 "error": str(reply.get("error")) if reply.get("error") else None})
            time.sleep(0.1)
    return rows


def measure(app: App, name, opts, seed_info, recorder_bin, out: Path, resident_sockets):
    out.mkdir(parents=True, exist_ok=True)
    result = {"name": name}
    logs = open(out / "log-stream.ndjson", "wb")
    logger = subprocess.Popen(["/usr/bin/log", "stream", "--style", "ndjson", "--level", "debug", "--predicate",
                               'subsystem BEGINSWITH "com.cmuxterm"'], stdout=logs, stderr=subprocess.STDOUT,
                              start_new_session=True)
    time.sleep(1.0)  # harness: log stream attaches
    t0 = time.monotonic()
    sampler = Sampler(app.root, t0)
    sampler.start()
    probe = Probe(app.sock, t0, opts.seconds)
    if app.sock.exists():
        app.sock.unlink()  # a socket file left by the quit would count as "socket exists"
    app.diagnostics = Diagnostics(out, app.root / "h", Path(opts.tools))
    probe.app = app
    t0 = app.launch(out, activate=recorder_bin is not None)
    sampler.t0 = probe.t0 = t0
    probe.start()
    threading.Thread(target=probe.watch, daemon=True).start()
    result["pid"] = app.pid
    ready = app.wait_ready(120)
    result["ready_s"] = round(time.monotonic() - t0, 2) if ready else None
    result["build"] = (ready or {}).get("build")
    rec, frames_note = None, None
    rounds = []
    try:
        if not ready:
            raise StepFailed(f"{name}: the control socket never answered")
        result["isolation"] = check_isolation(app, resident_sockets)
        if recorder_bin is not None:
            try:
                rec = Recorder(recorder_bin, app.pid)
                result["capture"] = rec.ready
            except (RuntimeError, OSError) as error:
                frames_note = str(error)
        mark_root = app.root / "marks" / name
        mark_root.mkdir(parents=True, exist_ok=True)
        socket_at = probe.first_reply_at or (time.monotonic() - t0)
        for index, at in enumerate(ROUNDS_AT_S):
            when = (socket_at + 5.0) if at is None else at
            wait = when - (time.monotonic() - t0)
            if wait > 0:
                time.sleep(wait)  # harness: the round's start time
            if time.monotonic() - t0 > opts.seconds - 5:
                break
            segment = out / f"frames-{index}.bin"
            begun = rec.begin(str(segment)) if rec else False
            row = interaction_round(app, f"round{index}", seed_info, rec if begun else None, t0, mark_root, index)
            if rec and begun:
                count, marks = rec.end()
                times = frame_times(segment, rec.w, rec.h)
                dropped, gaps = dropped_frames(times, marks, rec.hz)
                row["frames"] = {"frames": count, "dropped": dropped, "gaps": gaps[:40], "hz": rec.hz}
                segment.unlink(missing_ok=True)
            rounds.append(row)
            say(f"{name} round{index} at {row['at_s']}s: {round_line(row)}")
        rest = opts.seconds - (time.monotonic() - t0)
        if rest > 0:
            time.sleep(rest)  # harness: the rest of the measured window
    finally:
        probe.stop.set()
        probe.join(timeout=40)
        sampler.stop.set()
        sampler.join(timeout=10)
        if rec:
            rec.quit()
        result["status"] = app.call("updates.status", timeout=10)
        if logger.poll() is None:
            logger.terminate()  # this run's own log stream, by its pid
            try:
                logger.wait(timeout=10)
            except subprocess.TimeoutExpired:
                logger.kill()
        logs.close()
    result.update(socket_s=round(probe.socket_at, 3) if probe.socket_at is not None else None,
                  first_reply_s=round(probe.first_reply_at, 3) if probe.first_reply_at is not None else None,
                  frames_note=frames_note, rounds=rounds)
    result["marks"] = read_marks(out / "marks.txt")
    result["probe"] = summarize_probe(probe.samples)
    with open(out / "probe.json", "w") as handle:
        json.dump(probe.samples, handle)
    with open(out / "samples.json", "w") as handle:
        json.dump(sampler.rows, handle)
    result["cpu_windows"], result["disk"] = cpu_windows(sampler.rows, opts.seconds)
    result["logs"] = log_digest(out / "log-stream.ndjson")
    result["diagnostics"] = list(app.diagnostics.taken)
    return result


def read_marks(path: Path):
    marks = {}
    try:
        for line in path.read_text().splitlines():
            parts = line.split()
            if len(parts) >= 3:
                try:
                    marks.setdefault(parts[1], float(parts[2]))
                except ValueError:
                    pass
    except OSError:
        pass
    return marks


def summarize_probe(samples):
    lat = [ms for _t, ms in samples if ms is not None]
    episodes = stall_episodes(samples)
    first30 = [e for e in episodes if e["start_s"] < 30]
    return {"probes": len(samples), "errors": sum(1 for _t, ms in samples if ms is None),
            "p50_ms": pct(lat, 50), "p99_ms": pct(lat, 99), "max_ms": max(lat, default=None),
            "stalls": len(episodes), "stall_max_ms": max((e["ms"] for e in episodes), default=0),
            "stalled_ms": round(sum(e["ms"] for e in episodes), 1),
            "stalls_first30": len(first30), "stalled_ms_first30": round(sum(e["ms"] for e in first30), 1),
            "stalls_rest": len(episodes) - len(first30),
            "stalled_ms_rest": round(sum(e["ms"] for e in episodes if e["start_s"] >= 30), 1),
            "worst": sorted(episodes, key=lambda e: -e["ms"])[:15]}


LOG_KEYS = re.compile(r"(version|handoff|hand.?off|premigrat|prewarm|migrat|re-?copy|reattach|replace|upgrade|"
                      r"helper|generation|restor|hang|stall|slow|launch)", re.I)


def log_digest(path: Path, limit=400):
    """Counts of com.cmuxterm log lines by subsystem/category, and the lines that name the update's work."""
    counts, notable = {}, []
    try:
        with open(path, errors="replace") as handle:
            for line in handle:
                try:
                    entry = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(entry, dict):
                    continue
                key = f"{entry.get('subsystem')}/{entry.get('category')}"
                counts[key] = counts.get(key, 0) + 1
                message = entry.get("eventMessage") or ""
                if LOG_KEYS.search(message) and len(notable) < limit:
                    notable.append({"t": entry.get("timestamp"), "cat": key, "proc": entry.get("processImagePath", "").rsplit("/", 1)[-1],
                                    "msg": message[:300]})
    except OSError:
        pass
    return {"counts": dict(sorted(counts.items(), key=lambda kv: -kv[1])[:40]), "notable": notable}


def round_line(row):
    def stat(values):
        return f"{pct(values, 50)}/{max(values) if values else None}"
    parts = [f"switch shown p50/max {stat([s['shown_ms'] for s in row['switch']])} ms",
             f"scroll post {stat([s['post_ms'] for s in row['scroll'] if 'post_ms' in s])}",
             f"newtab {stat([s['reply_ms'] for s in row['newtab']])}",
             f"type ran {stat([t['ran_ms'] for t in row['type']])}"]
    if "frames" in row:
        parts.append(f"frames {row['frames']['frames']} dropped {row['frames']['dropped']}")
    return ", ".join(parts)


def interaction_summary(rounds):
    out = {}
    for key, field in (("switch", "shown_ms"), ("switch_reply", "reply_ms"), ("scroll", "post_ms"),
                       ("newtab", "reply_ms"), ("type", "ran_ms")):
        src = "switch" if key.startswith("switch") else key
        per_round = []
        for row in rounds:
            values = [r[field] for r in row[src] if field in r]
            per_round.append({"round": row["label"], "at_s": row["at_s"], "median": pct(values, 50),
                              "max": max(values) if values else None, "n": len(values),
                              "failed": sum(1 for r in row[src] if r.get("error") or r.get("shown") is False or r.get("ok") is False)})
        out[key] = per_round
    out["dropped_frames"] = [{"round": r["label"], **{k: v for k, v in (r.get("frames") or {}).items() if k != "gaps"}}
                             for r in rounds]
    return out


def hang_files(home: Path, out: Path, since: float):
    kept = []
    for folder in (home / "Library/Logs").glob("*"):
        for path in folder.rglob("*"):
            if path.is_file() and ("hang" in str(path).lower()) and path.stat().st_mtime >= since - 5:
                dest = out / "hangs" / path.name
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, dest)
                kept.append(str(path.relative_to(home)))
    return kept


SCROLLER = None
SCROLLER_SRC = r"""
import CoreGraphics
import Foundation
// post-update-hitches scroller: STEPS wheel events of LINES lines each at X,Y (global points), 16 ms apart.
let a = CommandLine.arguments
guard a.count == 5, let x = Double(a[1]), let y = Double(a[2]), let lines = Int32(a[3]), let steps = Int(a[4]) else {
    FileHandle.standardError.write("usage: scroller X Y LINES STEPS\n".data(using: .utf8)!)
    exit(2)
}
CGWarpMouseCursorPosition(CGPoint(x: x, y: y))
for _ in 0..<steps {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: lines, wheel2: 0, wheel3: 0) else {
        FileHandle.standardError.write("no scroll event\n".data(using: .utf8)!)
        exit(1)
    }
    e.location = CGPoint(x: x, y: y)
    e.post(tap: .cghidEventTap)
    usleep(16_000)
}
"""


def build_scroller(cache: Path):
    """The wheel-event poster (a person's scroll, from outside the app); None when it cannot be built."""
    cache.mkdir(parents=True, exist_ok=True)
    source, binary = cache / "puh-scroller.swift", cache / "puh-scroller"
    source.write_text(SCROLLER_SRC)
    done = subprocess.run(["swiftc", "-O", "-o", str(binary), str(source)], capture_output=True, text=True, timeout=600)
    if done.returncode != 0:
        print(f"PUH scroller not built: {done.stderr.strip()[-300:]}", flush=True)
        return None
    return binary


def build_recorder(cache: Path):
    cache.mkdir(parents=True, exist_ok=True)
    binary = cache / "puh-recorder"
    if binary.exists() and binary.stat().st_mtime >= RECORDER_SRC.stat().st_mtime:
        return binary
    done = subprocess.run(["swiftc", "-O", "-o", str(binary), str(RECORDER_SRC)], capture_output=True, text=True,
                          timeout=600)
    if done.returncode != 0:
        raise RuntimeError(f"swiftc recorder: {done.stderr.strip()[-400:]}")
    return binary


# ---- main -----------------------------------------------------------------------------------------------------

def run(opts, root: Path, report):
    out = Path(opts.out)
    if smoke.gui_session_problem() and opts.launch == "exec":
        say("note: this process is not in the console's Aqua session; launching through LaunchServices (open)")
        opts.launch = "open"
    items = feed_items(opts.feed)
    by_build = {i["build"]: i for i in items}
    to_item = by_build[opts.to_build] if opts.to_build else items[0]
    from_item = by_build[opts.from_build] if opts.from_build else items[1]
    report.update(feed=opts.feed, from_build=from_item, to_build=to_item, workspaces=opts.workspaces,
                  seconds=opts.seconds, host=os.uname().nodename, launch=opts.launch)
    say(f"FROM {from_item['build']} ({from_item['short']}) TO {to_item['build']} ({to_item['short']}); "
        f"delta from FROM in feed: {from_item['build'] in to_item['delta_from']}")
    bundle_id = feed_bundle_id(opts.feed)
    report["bundle_id"] = bundle_id
    preflight(bundle_id, root)
    if opts.preflight_only:
        say("preflight ok: no other copy of the bundle id, no remembered or session daemon socket")
        return 0
    recorder_bin = None
    if not opts.no_frames:
        try:
            recorder_bin = build_recorder(Path(opts.tools))
            global SCROLLER
            SCROLLER = build_scroller(Path(opts.tools))
        except (RuntimeError, OSError, subprocess.SubprocessError) as error:
            report["frames_note"] = str(error)
            say(f"note: frames skipped: {error}")
    dmg = root / "from.dmg"
    say(f"downloading {from_item['url']}")
    download(from_item["url"], dmg)
    path = smoke.copy_app_from_dmg(dmg, root)
    dmg.unlink()
    if bundle_build(path) != from_item["build"]:
        raise StepFailed(f"installed {bundle_build(path)}, want {from_item['build']}")
    app = App(path, root, opts)
    if app.bundle_id != bundle_id:
        raise CannotRun(f"the feed's app is {app.bundle_id}, not {bundle_id}")
    resident = resident_daemon_sockets(root)
    with smoke.DefaultsAside(bundle_id, root):
        subprocess.run(["defaults", "write", bundle_id, "home.firstRun.historyImportShown", "-bool", "YES"],
                       capture_output=True, timeout=30)
        home = root / "h"
        # A login keychain, as a person's home has: without one every quit held in CefShutdown behind Chromium's
        # "cmux Safe Storage" Keychain dialog (12 of 12 hang files, cmuxterm-hq#11994). Not CMUX_MOCK_KEYCHAIN:
        # the app strips it from an inherited environment (smoke.login_keychain).
        smoke.login_keychain(smoke.fresh_env(root, app.sock, 0))
        (home / ".config/cmux").mkdir(parents=True, exist_ok=True)
        (home / ".config/cmux/cmux-next.json").write_text(json.dumps(
            # downloadAutomatically: a person who keeps automatic updates; it is user-only over the socket
            # (setting_user_only), so it goes in the person's own file, before the launch.
            {"app": {"quitBehavior": "keep"}, "updates": {"installOnQuit": True, "automatic": "download"}},
            indent=1))
        # A file that already went through the one-time "forget stored defaults" pass
        # (SettingsController+StoredDefaults.swift, record `cmux-next.json.defaults-forgotten.json`), as a person's
        # file has: without the record, FROM's first launch drops installOnQuit (true was a former default) and
        # quit cancels the staged update instead of installing it (cmux9s, 2026-11-16, builds 438256712380x).
        (home / ".config/cmux/cmux-next.json.defaults-forgotten.json").write_text(json.dumps(
            {"note": "post-update-hitches: this home's settings are a person's picks, not copies of defaults",
             "dropped": {}, "kept": {}}, indent=1))
        (home / ".zshrc").touch()
        # Sparkle's installer runs from launchd with the account's own home, so it stages under the account's
        # Library/Caches, while the app (CFFIXED_USER_HOME = the private home) looks for the staged bundle under the
        # private one: its pre-warm found nothing (cmux9s, 2026-11-16: "no staged bundle ... (scan 0 ms)"), which a
        # person's app never sees. The private folder points at the account's, so the app and Sparkle share it.
        sparkle = Path("Library/Caches") / bundle_id / "org.sparkle-project.Sparkle"
        account_sparkle = Path(os.path.expanduser("~")) / sparkle
        account_sparkle.mkdir(parents=True, exist_ok=True)
        (home / sparkle).parent.mkdir(parents=True, exist_ok=True)
        if not (home / sparkle).exists():
            (home / sparkle).symlink_to(account_sparkle, target_is_directory=True)
        # N: seed, settle, stage, quit -> install. Its own log stream (with Sparkle's processes) and diagnostics.
        app.diagnostics = Diagnostics(out / "N", home, Path(opts.tools))
        report["N_diagnostics"] = app.diagnostics.taken  # the list itself: filled as they are taken
        with LogStream(out / "N" / "log-stream.ndjson", 'subsystem BEGINSWITH "com.cmuxterm" OR '
                       'process == "Autoupdate" OR process == "Updater"'):
            app.launch(out / "N")
            if not app.wait_ready(120):
                raise StepFailed("FROM: the control socket never answered")
            report["N_isolation"] = check_isolation(app, resident)
            seed_info = seed(app, opts, report)
            time.sleep(opts.settle)  # the asked settle before staging
            app.action("palette.checkForUpdates", focus=False)
            staged, deadline = None, time.monotonic() + 900
            while time.monotonic() < deadline and not staged:
                status = app.call("updates.status", timeout=10)
                staged = status if isinstance(status, dict) and status.get("phase") == "installing" else None
                time.sleep(2)  # harness: Sparkle downloads and verifies
            report["staged_status"] = app.call("updates.status", timeout=10)
            if not staged:
                raise StepFailed(f"no update staged in 900 s: {json.dumps(report['staged_status'])[:400]}")
            say(f"STAGED {staged.get('detected_version')}")
            app.quit()
        deadline = time.monotonic() + 300
        while time.monotonic() < deadline and bundle_build(path) != to_item["build"]:
            time.sleep(1)  # harness: Sparkle's installer replaces the bundle
        report["installed_build"] = bundle_build(path)
        report["install_s"] = round(300 - (deadline - time.monotonic()), 1)
        if bundle_build(path) != to_item["build"]:
            raise StepFailed(f"install on quit left build {bundle_build(path)}, want {to_item['build']}")
        say(f"INSTALLED {bundle_build(path)} in {report['install_s']} s")
        # Sparkle relaunches only when asked; a relaunch would be a process of the root we did not start.
        time.sleep(3)  # harness: a relaunch would show by now
        for pid, _pp, _u, _c, _r, command in ps_rows():
            if command.startswith(str(path / "Contents/MacOS/")):
                raise StepFailed(f"something relaunched the app (pid {pid}); the measurement would lose its env")
        app = App(path, root, opts)
        report["A"] = measure(app, "A", opts, seed_info, recorder_bin, out / "A", resident)
        app.quit()
        time.sleep(5)  # harness: the quit's daemons hand over
        report["B"] = measure(app, "B", opts, seed_info, recorder_bin, out / "B", resident)
        report["hangs"] = hang_files(home, out, report.get("started_wall", 0))
        app.quit(end_everything=True)
    for name in ("A", "B"):
        summary_lines(name, report[name])
    return 0


def summary_lines(name, result):
    p = result["probe"]
    say(f"{name} build {result.get('build')} socket {result.get('socket_s')} s first-reply {result.get('first_reply_s')} s "
        f"first_window_frame {result['marks'].get('first_window_frame_committed')} ms")
    say(f"{name} probe p50 {p['p50_ms']} ms p99 {p['p99_ms']} ms; stalls>50ms {p['stalls']} max {p['stall_max_ms']} ms "
        f"total {p['stalled_ms']} ms; first30 {p['stalls_first30']} ({p['stalled_ms_first30']} ms) rest "
        f"{p['stalls_rest']} ({p['stalled_ms_rest']} ms)")
    for key, rows in interaction_summary(result["rounds"]).items():
        say(f"{name} {key} " + " | ".join(json.dumps(r, separators=(',', ':')) for r in rows))
    for slot, kinds in result["cpu_windows"].items():
        say(f"{name} cpu {slot} " + ", ".join(f"{k} {v}" for k, v in list(kinds.items())[:10]))
    say(f"{name} disk " + ", ".join(f"{k} r{v['read_mb']}/w{v['written_mb']}MB" + (" n/a" if v["denied"] else "")
                                    for k, v in sorted(result["disk"].items(), key=lambda kv: -(kv[1]["read_mb"] or 0))[:14]))
    if result.get("frames_note"):
        say(f"{name} frames skipped: {result['frames_note']}")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--feed", default=FEED)
    parser.add_argument("--from", dest="from_build")
    parser.add_argument("--to", dest="to_build")
    parser.add_argument("--workspaces", type=int, default=8)
    parser.add_argument("--chat-turns", type=int, default=120, help="answered turns in the long chat (2 messages each)")
    parser.add_argument("--seconds", type=float, default=180.0)
    parser.add_argument("--settle", type=float, default=30.0)
    parser.add_argument("--out", default=str(REPO / ".build/post-update-hitches"))
    parser.add_argument("--tools", default=os.path.expanduser("~/.cache/post-update-hitches"),
                        help="where the compiled frame recorder is kept")
    parser.add_argument("--no-frames", action="store_true")
    parser.add_argument("--preflight-only", action="store_true", help="only check the host is isolated (changes nothing)")
    parser.add_argument("--launch", choices=("exec", "open"), default="exec",
                        help="exec (in the console session) or open (LaunchServices, from ssh); exec falls back to open")
    opts = parser.parse_args(argv)
    os.makedirs(opts.out, exist_ok=True)
    root = Path(tempfile.mkdtemp(prefix="cmux-puh-", dir="/tmp"))
    report = {"root": str(root), "started_wall": time.time()}

    def interrupted(signum, _frame):
        raise SystemExit(128 + signum)

    signal.signal(signal.SIGTERM, interrupted)
    signal.signal(signal.SIGINT, interrupted)
    status = 3
    try:
        status = run(opts, root, report)
    except (CannotRun, smoke.CannotRun) as error:
        say(f"CANNOT RUN: {error}")
        report["verdict"] = f"cannot-run: {error}"
        status = 3
    except StepFailed as error:
        say(f"FAILED: {error}")
        report["verdict"] = f"failed: {error}"
        status = 1
    finally:
        left = smoke.own_pids(root)
        if left:
            say(f"stopping this run's processes under {root}: {left}")
            smoke.stop(left)
        with open(Path(opts.out) / "report.json", "w") as handle:
            json.dump(report, handle, indent=1, sort_keys=True, default=str)
        say(f"report {Path(opts.out) / 'report.json'}")
        smoke.detach(root / "mnt")
        shutil.rmtree(root, ignore_errors=True)
    return status


if __name__ == "__main__":
    sys.exit(main())
