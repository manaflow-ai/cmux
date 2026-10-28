#!/usr/bin/env python3
"""Pro audit 11: cmux-next against Ghostty, Rex, WezTerm, Kitty and Alacritty on one perf Mac (never lands).

Binding brief: handoff/benchmark.md. One fleet step measures every app in turn on the same host and the same
(virtual) display: split-spring.sh --suite=competitors (the reload stub fetches the optimized cmux build by its
artifact sha256; this script downloads each competitor at a pinned version and sha256).

Method, the same for every app:
  shell     every terminal runs /bin/zsh with HOME = the bench's home (its .zshrc); its first prompt writes a marker (the live
            prompt) and execs competitor_helper.py, so every app hosts the same child.
  input     no perf host holds the Accessibility grant (real HID keys need it), so keys are injected through each
            app's own automation path where it has one: cmux `debug.key` (the app's key path), Kitty remote control
            `send-text` (its socket), WezTerm `wezterm cli send-text --no-paste`. Ghostty, Alacritty and Rex have
            none without Apple Events consent: their key rows are N/A. The helper stamps each byte it reads, so
            every key row splits into send -> child read and child read -> frame.
  photon    first5s-photon.swift (ScreenCaptureKit, a process of its own): the display time of the first frame of
            the app's window that changed after an event. Needs the Screen Recording grant (`grants` in the report).
  memory    the sum of physical footprint (proc_pid_rusage, Activity Monitor's Memory) of every process whose
            executable is inside the app bundle (cmux: the app, its cmux-tui daemon and terminal hosts, CEF helpers);
            shells and the helper are outside every bundle and never count.
  cpu       CPU time and package-idle + interrupt wakeups of the same processes over an idle window.

Rows: launch (first launch of a fresh copy, then warm: spawn to window on screen, spawn to live prompt), idle CPU /
wakeups / memory at 1 terminal, output-to-photon (the render half of key-to-photon, every app), key-to-photon
(injected), first-5 s typing after a new tab and a split, new tab and split latency (to frame, to live prompt),
throughput (cat 150 MB, yes for 10 s), output scroll smoothness (dropped frames while a line arrives every refresh),
resize/reflow with 10,000 lines (app IPC resize where it has one, else xterm CSI 8 t), memory and idle at 10 and 100
terminals as hidden tabs and as visible splits. Unsupported rows say why.

  competitor-bench.py --app CMUX_APP --out DIR --json FILE [--apps cmux,ghostty,rex,wezterm,kitty,alacritty]
                      [--phase probe|full] [--launches 5] [--samples 50] [--counts 10,100] [--visible 10]
                      [--daemon] [--first5s]
"""
import argparse
import ctypes
import ctypes.util
import glob
import hashlib
import json
import os
import plistlib
import random
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, HERE)

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True, help="the cmux-next app (split-spring.sh passes it)")
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--tag")
parser.add_argument("--apps", default="cmux,ghostty,kitty,wezterm,alacritty,rex")
parser.add_argument("--phase", choices=["probe", "full"], default="full")
parser.add_argument("--launches", type=int, default=5, help="launches per app: the first, then warm ones")
parser.add_argument("--samples", type=int, default=50)
parser.add_argument("--counts", default="10,100", help="hidden tab counts for memory and idle")
parser.add_argument("--visible", default="10", help="visible split counts for memory and idle")
parser.add_argument("--idle", type=float, default=30.0)
parser.add_argument("--settle", type=float, default=10.0)
parser.add_argument("--cat-mb", type=int, default=150)
parser.add_argument("--rounds", type=int, default=8, help="new tab and split rounds")
parser.add_argument("--typing-rounds", type=int, default=3)
parser.add_argument("--daemon", action="store_true", help="also the cmux-tui daemon suite on the app's cmux-tui")
parser.add_argument("--first5s", action="store_true", help="also first-5s-typing.py on cmux with photon on")
opts, _unknown = parser.parse_known_args()

OUT = os.path.abspath(opts.out)
os.makedirs(OUT, exist_ok=True)
JSON = opts.json or os.path.join(OUT, "competitors.json")
CLOCK = getattr(time, "CLOCK_UPTIME_RAW", time.CLOCK_MONOTONIC)
now = lambda: time.clock_gettime_ns(CLOCK)  # noqa: E731

# Pinned 2026-10-28 (handoff/pro-audit-11-result.md "Versions"): latest stable of each, Rex from its Sparkle feed.
COMPETITORS = {
    "ghostty": {"url": "https://release.files.ghostty.org/1.4.0/Ghostty.dmg",
                "sha256": "3a02075dbd24318d778426af41dee5507d53ecc4578ede96912ec9ce6d18d3e8"},
    "rex": {"url": "https://blob.superlogical.com/public/rex-app/preview/Rex-0.1.0-1541.dmg",
            "sha256": "b2e6583d9c6f11954783d4030235b1008bfe56b5d4dac7fd03070cd92207c3f3"},
    "kitty": {"url": "https://github.com/kovidgoyal/kitty/releases/download/v0.49.2/kitty-0.49.2.dmg",
              "sha256": "e524b894145d89cb76b584e3a9691196ae56bfa31d51384a44aa774252b7cef7"},
    "alacritty": {"url": "https://github.com/alacritty/alacritty/releases/download/v0.17.0/Alacritty-v0.17.0.dmg",
                  "sha256": "ad8d7de35fb38e43184776cac6dfee05ca325caa0b6639a06a55e54e4b026620"},
    "wezterm": {"url": "https://github.com/wezterm/wezterm/releases/download/20240203-110809-5046fc22/"
                       "WezTerm-macos-20240203-110809-5046fc22.zip",
                "sha256": "e77388cad55f2e9da95a220a89206a6c58f865874a629b7c3ea3c162f5692224"},
}
COLS, ROWS, FONT = 120, 40, 13

REPORT = {"started": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "phase": opts.phase, "apps": {},
          "method": __doc__.split("\n\n")[2].strip()[:4000]}


def note(text):
    print(f"competitors: {text}", flush=True)


def save():
    tmp = JSON + ".tmp"
    with open(tmp, "w") as f:
        json.dump(REPORT, f, indent=1, default=str)
    os.replace(tmp, JSON)


def pct(values, p):
    values = sorted(v for v in values if v is not None)
    if not values:
        return None
    k = (len(values) - 1) * p / 100
    lo, hi = int(k), min(int(k) + 1, len(values) - 1)
    return round(values[lo] + (values[hi] - values[lo]) * (k - lo), 3)


def dist(values):
    values = [v for v in values if v is not None]
    if not values:
        return {"n": 0}
    return {"n": len(values), "p50": pct(values, 50), "p95": pct(values, 95), "p99": pct(values, 99),
            "max": round(max(values), 3), "mean": round(statistics.fmean(values), 3)}


def run(argv, timeout=60, **kw):
    try:
        r = subprocess.run(argv, capture_output=True, text=True, timeout=timeout, **kw)
        return r.returncode, r.stdout, r.stderr
    except (OSError, subprocess.TimeoutExpired) as error:
        return -1, "", str(error)


# ---------------------------------------------------------------- host tools
def swift_tool(name, source):
    binary = os.path.join(OUT, "bin", name)
    if os.path.exists(binary):
        return binary
    os.makedirs(os.path.dirname(binary), exist_ok=True)
    code, _o, err = run(["xcrun", "swiftc", "-swift-version", "5", "-O", os.path.join(HERE, source), "-o", binary],
                        timeout=900)
    if code != 0:
        raise RuntimeError(f"{source} did not compile: {err[-800:]}")
    return binary


PROBE = None


def probe(*args, timeout=30):
    return run([PROBE, *args], timeout=timeout)


def wait_window(pids, timeout=60):
    """Starts the window poller now; .result() is (uptime_ns, pid) of the first on-screen window, or None."""
    proc = subprocess.Popen([PROBE, "wait-window", "--pid", ",".join(str(p) for p in pids), "--timeout", str(timeout)],
                            stdout=subprocess.PIPE, text=True)

    class Pending:
        def result(self):
            out, _ = proc.communicate(timeout=timeout + 10)
            m = re.match(r"window (\d+) (\d+) (\d+) (\d+)", out or "")
            return (int(m.group(1)), int(m.group(2)), int(m.group(3)), int(m.group(4))) if m else None
    return Pending()


class Procs:
    """proc_pid_rusage of every process whose executable is inside a bundle (bench-scale.py's MacProcs fields)."""

    class RUsageV2(ctypes.Structure):
        _fields_ = [("uuid", ctypes.c_uint8 * 16)] + [
            (name, ctypes.c_uint64) for name in (
                "user_time", "system_time", "pkg_idle_wkups", "interrupt_wkups", "pageins", "wired_size",
                "resident_size", "phys_footprint", "proc_start_abstime", "proc_exit_abstime", "child_user_time",
                "child_system_time", "child_pkg_idle_wkups", "child_interrupt_wkups", "child_pageins",
                "child_elapsed_abstime", "diskio_bytesread", "diskio_byteswritten")]

    class Timebase(ctypes.Structure):
        _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

    def __init__(self):
        self.lib = ctypes.CDLL(ctypes.util.find_library("proc") or "/usr/lib/libproc.dylib", use_errno=True)
        tb = self.Timebase()
        ctypes.CDLL(None).mach_timebase_info(ctypes.byref(tb))
        self.ns_per_tick = tb.numer / tb.denom

    def all_pids(self):
        buf = (ctypes.c_int * 16384)()
        n = self.lib.proc_listallpids(buf, ctypes.sizeof(buf))
        return [buf[i] for i in range(max(0, n)) if buf[i] > 0]

    def path(self, pid):
        buf = ctypes.create_string_buffer(4096)
        return buf.value.decode(errors="replace") if self.lib.proc_pidpath(pid, buf, 4096) > 0 else ""

    def of_bundle(self, bundle):
        root = os.path.realpath(bundle).rstrip("/") + "/"
        return [(pid, p) for pid in self.all_pids() for p in [self.path(pid)] if p.startswith(root)]

    def sample(self, bundle):
        total = {"footprint": 0, "rss": 0, "cpu_ns": 0, "wakeups": 0, "count": 0, "by_name": {}}
        for pid, path in self.of_bundle(bundle):
            ru = self.RUsageV2()
            if self.lib.proc_pid_rusage(pid, 2, ctypes.byref(ru)) != 0:
                continue
            total["footprint"] += ru.phys_footprint
            total["rss"] += ru.resident_size
            total["cpu_ns"] += (ru.user_time + ru.system_time) * self.ns_per_tick
            total["wakeups"] += ru.pkg_idle_wkups + ru.interrupt_wkups
            total["count"] += 1
            name = os.path.basename(path)
            entry = total["by_name"].setdefault(name, {"count": 0, "footprint_mb": 0.0, "cpu_ns": 0, "wakeups": 0})
            entry["count"] += 1
            entry["footprint_mb"] = round(entry["footprint_mb"] + ru.phys_footprint / 2 ** 20, 1)
            entry["cpu_ns"] += (ru.user_time + ru.system_time) * self.ns_per_tick
            entry["wakeups"] += ru.pkg_idle_wkups + ru.interrupt_wkups
        total["footprint_mb"] = round(total["footprint"] / 2 ** 20, 1)
        return total


PROCS = None


def idle_window(bundle, seconds):
    a, t0 = PROCS.sample(bundle), time.monotonic()
    time.sleep(seconds)  # bench: the idle window itself
    b, dt = PROCS.sample(bundle), time.monotonic() - t0
    names = {}
    for name, e in b["by_name"].items():
        e0 = a["by_name"].get(name, {"cpu_ns": e["cpu_ns"], "wakeups": e["wakeups"]})
        names[name] = {"count": e["count"], "footprint_mb": e["footprint_mb"],
                       "cpu_pct": round((e["cpu_ns"] - e0["cpu_ns"]) / 1e9 / dt * 100, 3),
                       "wakeups_per_s": round((e["wakeups"] - e0["wakeups"]) / dt, 1)}
    return {"seconds": round(dt, 1), "cpu_pct": round((b["cpu_ns"] - a["cpu_ns"]) / 1e9 / dt * 100, 3),
            "wakeups_per_s": round((b["wakeups"] - a["wakeups"]) / dt, 1), "footprint_mb": b["footprint_mb"],
            "processes": b["count"], "by_name": dict(sorted(names.items(), key=lambda kv: -kv[1]["footprint_mb"])[:10])}


# ---------------------------------------------------------------- the helpers' hub
class Term:
    def __init__(self, hub, conn, hello):
        self.hub, self.conn, self.hello = hub, conn, hello
        self.events, self.cond, self.next_id = [], threading.Condition(), 1
        self.alive = True

    def push(self, event):
        with self.cond:
            self.events.append(event)
            self.cond.notify_all()

    def call(self, op, timeout=60, **kw):
        rid = self.next_id
        self.next_id += 1
        self.conn.sendall((json.dumps({"op": op, "id": rid, **kw}) + "\n").encode())
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                for e in self.events:
                    if e.get("ev") == "done" and e.get("id") == rid:
                        return e
                left = deadline - time.monotonic()
                if left <= 0 or not self.alive:
                    return None
                self.cond.wait(left)

    def wait_event(self, kind, after_ns, timeout):
        deadline = time.monotonic() + timeout
        with self.cond:
            while True:
                for e in self.events:
                    if e.get("ev") == kind and e.get("t", 0) >= after_ns:
                        return e
                left = deadline - time.monotonic()
                if left <= 0:
                    return None
                self.cond.wait(left)

    def events_of(self, kind, after_ns, before_ns=None):
        with self.cond:
            return [e for e in self.events if e.get("ev") == kind and e.get("t", 0) >= after_ns
                    and (before_ns is None or e.get("t", 0) <= before_ns)]

    def close(self):
        try:
            self.call("exit", timeout=3)
        except OSError:
            pass


class Hub:
    def __init__(self):
        self.path = f"/tmp/a11-{os.getpid()}.sock"
        if os.path.exists(self.path):
            os.unlink(self.path)
        self.server = socket.socket(socket.AF_UNIX)
        self.server.bind(self.path)
        self.server.listen(256)
        self.terms, self.cond = [], threading.Condition()
        threading.Thread(target=self.accept, daemon=True).start()

    def accept(self):
        while True:
            conn, _ = self.server.accept()
            threading.Thread(target=self.read, args=(conn,), daemon=True).start()

    def read(self, conn):
        buf, term = b"", None
        while True:
            try:
                chunk = conn.recv(1 << 16)
            except OSError:
                chunk = b""
            if not chunk:
                if term:
                    term.alive = False
                    with term.cond:
                        term.cond.notify_all()
                return
            buf += chunk
            while b"\n" in buf:
                line, buf = buf.split(b"\n", 1)
                event = json.loads(line)
                if term is None and event.get("ev") == "hello":
                    term = Term(self, conn, event)
                    with self.cond:
                        self.terms.append(term)
                        self.cond.notify_all()
                elif term:
                    term.push(event)

    def wait_new(self, known, timeout):
        """The first terminal that said hello and is not in `known` (a count of terms already seen)."""
        deadline = time.monotonic() + timeout
        with self.cond:
            while len(self.terms) <= known:
                left = deadline - time.monotonic()
                if left <= 0:
                    return None
                self.cond.wait(left)
            return self.terms[known]

    def live(self):
        with self.cond:
            return [t for t in self.terms if t.alive]


HUB = None


# ---------------------------------------------------------------- photon (ScreenCaptureKit)
class Photon:
    def __init__(self, pid, path):
        self.path, self.proc, self.ready, self.error = path, None, None, None
        binary = os.path.join(OUT, "bin", "first5s-photon")
        if not os.path.exists(binary):
            try:
                swift_tool("first5s-photon", "first5s-photon.swift")
            except RuntimeError as error:
                self.error = str(error)[:300]
                return
        self.proc = subprocess.Popen([binary, "--pid", str(pid), "--out", path, "--seconds", "3600", "--fps", "240"],
                                     stdout=subprocess.DEVNULL, stderr=open(path + ".err", "w"))
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline and self.proc.poll() is None:
            head = self.lines(1)
            if head and (head[0].startswith("ready") or head[0].startswith("error")):
                break
            time.sleep(0.1)  # bench: the recorder's ready line
        head = self.lines(1)
        if head and head[0].startswith("ready"):
            self.ready = head[0]
        else:
            self.error = (head[0] if head else "no ready line") + " " + self.err()
            self.stop()

    def err(self):
        try:
            return open(self.path + ".err").read()[-300:]
        except OSError:
            return ""

    def area(self):
        m = re.search(r"(\d+)x(\d+)", self.ready or "")
        return int(m.group(1)) * int(m.group(2)) if m else 10 ** 12

    def lines(self, limit=None):
        try:
            with open(self.path) as f:
                lines = f.read().splitlines()
        except OSError:
            return []
        return lines[:limit] if limit else lines

    def frames(self, start_ns=0, end_ns=1 << 62):
        out = []
        for line in self.lines():
            parts = line.split()
            if len(parts) == 7 and parts[0] == "frame":
                ns = int(parts[1])
                if start_ns <= ns <= end_ns:
                    out.append((ns, int(parts[2]), int(parts[5]) * int(parts[6])))
        return out

    def stop(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()  # the recorder this bench started
            try:
                self.proc.wait(10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def first_frame_after(frames, t_ns, limit_ns, max_area=None):
    for ns, _changed, area in frames:
        if ns > t_ns and (max_area is None or area < max_area):
            return round((ns - t_ns) / 1e6, 3) if ns - t_ns <= limit_ns else None
    return None


# ---------------------------------------------------------------- install
def install(name):
    spec = COMPETITORS[name]
    folder = os.path.join(OUT, "apps", name)
    os.makedirs(folder, exist_ok=True)
    found = glob.glob(os.path.join(folder, "*.app"))
    if found:
        return found[0]
    dl = os.path.join(OUT, "dl", os.path.basename(spec["url"]))
    os.makedirs(os.path.dirname(dl), exist_ok=True)
    code, _o, err = run(["curl", "-fsSL", "--retry", "3", "-o", dl, spec["url"]], timeout=900)
    if code != 0:
        raise RuntimeError(f"download {spec['url']}: {err[-300:]}")
    digest = hashlib.sha256(open(dl, "rb").read()).hexdigest()
    if digest != spec["sha256"]:
        raise RuntimeError(f"{name}: sha256 {digest} is not the pinned {spec['sha256']}")
    if dl.endswith(".zip"):
        tmp = os.path.join(OUT, "dl", name + "-unzip")
        run(["ditto", "-x", "-k", dl, tmp], timeout=600)
        apps = glob.glob(os.path.join(tmp, "*.app")) + glob.glob(os.path.join(tmp, "*", "*.app"))
    else:
        mount = os.path.join(OUT, "dl", name + "-mnt")
        os.makedirs(mount, exist_ok=True)
        r = subprocess.run(["hdiutil", "attach", "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount, dl],
                           input="Y\n" * 4, capture_output=True, text=True, timeout=300)
        if r.returncode != 0:
            raise RuntimeError(f"hdiutil attach {name}: {r.stderr[-300:]}")
        apps = glob.glob(os.path.join(mount, "*.app")) + glob.glob(os.path.join(mount, "*", "*.app"))
        tmp = mount
    if not apps:
        raise RuntimeError(f"{name}: no .app in the image")
    target = os.path.join(folder, os.path.basename(apps[0]))
    run(["ditto", apps[0], target], timeout=600)
    if not dl.endswith(".zip"):
        run(["hdiutil", "detach", tmp, "-force"], timeout=120)
    run(["xattr", "-dr", "com.apple.quarantine", target])
    return target


def info(app):
    try:
        with open(os.path.join(app, "Contents", "Info.plist"), "rb") as f:
            plist = plistlib.load(f)
    except (OSError, plistlib.InvalidFileException):
        return {}
    return {k: plist.get(k) for k in ("CFBundleIdentifier", "CFBundleShortVersionString", "CFBundleVersion",
                                       "CFBundleExecutable", "CMUXBuildConfiguration", "CMUXGitCommit")}


# ---------------------------------------------------------------- shell
def make_home():
    """The HOME every app's shell starts in: zsh reads its .zshrc there whatever the app does to the environment
    (cmux-next captures a login shell's env from HOME and SHELL only, LoginEnvironment.capture, so ZDOTDIR and
    A11_SOCK of the launch never reach its terminals). The first prompt logs its time and execs the helper."""
    home = os.path.join(OUT, "home")
    os.makedirs(home, exist_ok=True)
    with open(os.path.join(home, ".zshrc"), "w") as f:
        f.write(f"""zmodload zsh/datetime
autoload -Uz add-zsh-hook
PROMPT='%~ %# '
a11_first() {{
  add-zsh-hook -d precmd a11_first
  print -r -- "$EPOCHREALTIME $$ $TTY" >> {OUT}/prompt.log
  exec {sys.executable} -I {os.path.join(HERE, 'competitor_helper.py')} {HUB.path}
}}
add-zsh-hook precmd a11_first
""")
    for name in (".zshenv", ".zprofile", ".zlogin"):
        open(os.path.join(home, name), "w").close()
    return home


def prompts_after(wall):
    try:
        lines = open(os.path.join(OUT, "prompt.log")).read().splitlines()
    except OSError:
        return []
    return [float(l.split()[0]) for l in lines if l.split() and float(l.split()[0]) >= wall]


def base_env(home, scratch):
    env = {k: v for k, v in os.environ.items() if not k.startswith(("CMUX", "KITTY", "WEZTERM", "ALACRITTY", "GHOSTTY"))}
    for key in ("ZDOTDIR", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"):
        env.pop(key, None)
    env.update(SHELL="/bin/zsh", HOME=home, XDG_CONFIG_HOME=os.path.join(scratch, "xdg"))
    return env


# ---------------------------------------------------------------- adapters
class Adapter:
    name = "?"
    ipc = "none"
    can_type = False

    def __init__(self, app, zdot):
        self.app, self.zdot = app, zdot
        self.scratch = os.path.join(OUT, "state", self.name)
        os.makedirs(os.path.join(self.scratch, "xdg"), exist_ok=True)
        self.proc = None
        self.log = os.path.join(OUT, f"{self.name}.log")

    def binary(self):
        return os.path.join(self.app, "Contents", "MacOS", info(self.app).get("CFBundleExecutable") or "")

    def argv(self):
        return [self.binary()]

    def env(self):
        return base_env(self.zdot, self.scratch)

    def launch(self):
        """Spawns the app; returns (spawn uptime ns, spawn wall s, window waiter)."""
        self.configure()
        wall, t0 = time.time(), now()
        self.proc = subprocess.Popen(self.argv(), env=self.env(), stdout=open(self.log, "a"), stderr=subprocess.STDOUT,
                                     stdin=subprocess.DEVNULL, start_new_session=True)
        return t0, wall, wait_window([self.proc.pid])

    def pid(self):
        return self.proc.pid if self.proc else None

    def activate(self):
        ident = info(self.app).get("CFBundleIdentifier")
        if ident:
            run(["/usr/bin/osascript", "-e", f'tell application id "{ident}" to activate'], timeout=20)

    def configure(self):
        pass

    def new_tab(self, term):
        return "unsupported"

    def split(self, term):
        return "unsupported"

    def type_key(self, term, ch, opened=None):
        return "unsupported"

    def resize(self, term, cols):
        return "unsupported"

    def quit(self):
        if self.proc and self.proc.poll() is None:
            self.proc.terminate()  # the app this bench started, by its PID
            try:
                self.proc.wait(15)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(10)
        for pid, _path in PROCS.of_bundle(self.app):  # helpers it left (processes of this copy only)
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
        time.sleep(2)  # bench: the window server drops the closed windows


class Ghostty(Adapter):
    name = "ghostty"

    def configure(self):
        d = os.path.join(self.scratch, "xdg", "ghostty")
        os.makedirs(d, exist_ok=True)
        with open(os.path.join(d, "config"), "w") as f:
            f.write(f"command = /bin/zsh -i\nfont-size = {FONT}\nwindow-width = {COLS}\nwindow-height = {ROWS}\n"
                    "cursor-style-blink = false\nconfirm-close-surface = false\nquit-after-last-window-closed = true\n"
                    "window-save-state = never\nauto-update = off\nshell-integration = none\n"
                    "macos-applescript = false\n")


class Kitty(Adapter):
    name = "kitty"
    ipc = "kitty remote control (socket)"
    can_type = True

    def configure(self):
        self.conf = os.path.join(self.scratch, "kitty.conf")
        with open(self.conf, "w") as f:
            f.write(f"font_size {FONT}\ninitial_window_width {COLS}c\ninitial_window_height {ROWS}c\n"
                    "remember_window_size no\ncursor_blink_interval 0\nconfirm_os_window_close 0\n"
                    "update_check_interval 0\nshell_integration disabled\nmacos_quit_when_last_window_closed yes\n"
                    "allow_remote_control socket-only\nenabled_layouts grid\nshell /bin/zsh -i\n")
        self.listen = f"unix:/tmp/a11-kitty-{os.getpid()}"

    def argv(self):
        return [self.binary(), "--config", self.conf, "--listen-on", self.listen, "/bin/zsh", "-i"]

    def env(self):
        env = super().env()
        env["KITTY_CONFIG_DIRECTORY"] = self.scratch
        return env

    def address(self, term):
        return (term.hello.get("env") or {}).get("KITTY_LISTEN_ON") or self.listen

    def kitten(self, term, *args):
        code, out, err = run([os.path.join(self.app, "Contents", "MacOS", "kitten"), "@", "--to", self.address(term),
                              *args], timeout=30)
        return out.strip() if code == 0 else f"error: {err.strip()[:200]}"

    def rc(self, term, cmd, payload, response=False):
        """Kitty's remote control protocol on its socket: one `ESC P @kitty-cmd JSON ESC \\` message."""
        path = self.address(term).removeprefix("unix:")
        msg = {"cmd": cmd, "version": [0, 49, 2], "no_response": not response, "payload": payload}
        s = socket.socket(socket.AF_UNIX)
        s.settimeout(10)
        try:
            s.connect(path)
            s.sendall(b"\x1bP@kitty-cmd" + json.dumps(msg).encode() + b"\x1b\\")
            if response:
                data = b""
                while not data.endswith(b"\x1b\\"):
                    chunk = s.recv(65536)
                    if not chunk:
                        break
                    data += chunk
                return data
            return b""
        finally:
            s.close()

    def new_tab(self, term):
        return self.kitten(term, "launch", "--type=tab", "/bin/zsh", "-i")

    def split(self, term):
        return self.kitten(term, "launch", "--type=window", "/bin/zsh", "-i")

    def type_key(self, term, ch, opened=None):
        try:
            self.rc(term, "send-text", {"data": "text:" + ch})  # no match: the active window (a new tab's)
            return None
        except OSError as error:
            return f"error: {error}"

    def resize(self, term, cols):
        return self.kitten(term, "resize-os-window", "--width", str(cols), "--height", str(ROWS))


class WezTerm(Adapter):
    name = "wezterm"
    ipc = "wezterm cli (mux socket; one `wezterm cli` process per key: its start-up counts in send->read)"
    can_type = True

    def binary(self):
        return os.path.join(self.app, "Contents", "MacOS", "wezterm-gui")

    def configure(self):
        self.conf = os.path.join(self.scratch, "wezterm.lua")
        with open(self.conf, "w") as f:
            f.write(f"return {{ font_size = {FONT}.0, initial_cols = {COLS}, initial_rows = {ROWS},\n"
                    "  default_cursor_style = 'SteadyBlock', check_for_updates = false, show_update_window = false,\n"
                    "  window_close_confirmation = 'NeverPrompt', quit_when_all_windows_are_closed = true,\n"
                    "  default_prog = { '/bin/zsh', '-i' }, automatically_reload_config = false }\n")

    def argv(self):
        return [self.binary(), "start", "--always-new-process"]

    def env(self):
        env = super().env()
        env["WEZTERM_CONFIG_FILE"] = self.conf
        return env

    def cli(self, term, *args):
        env = dict(os.environ)
        sock = (term.hello.get("env") or {}).get("WEZTERM_UNIX_SOCKET")
        if sock:
            env["WEZTERM_UNIX_SOCKET"] = sock
        code, out, err = run([os.path.join(self.app, "Contents", "MacOS", "wezterm"), "cli", "--no-auto-start", *args],
                             timeout=30, env=env)
        return out.strip() if code == 0 else f"error: {err.strip()[:200]}"

    def pane(self, term):
        return (term.hello.get("env") or {}).get("WEZTERM_PANE", "0")

    def new_tab(self, term):
        return self.cli(term, "spawn", "--pane-id", self.pane(term))

    def split(self, term):
        """Splits the largest pane (a split of the same pane again and again halves it to nothing)."""
        pane, horizontal = self.pane(term), True
        try:
            panes = json.loads(self.cli(term, "list", "--format", "json"))
            big = max(panes, key=lambda p: p["size"]["cols"] * p["size"]["rows"])
            pane = str(big["pane_id"])
            horizontal = big["size"]["cols"] >= 2 * big["size"]["rows"]
        except (ValueError, KeyError, TypeError):
            pass
        return self.cli(term, "split-pane", "--right" if horizontal else "--bottom", "--pane-id", pane)

    def type_key(self, term, ch, opened=None):
        pane = opened.strip() if isinstance(opened, str) and opened.strip().isdigit() else self.pane(term)
        out = self.cli(term, "send-text", "--no-paste", "--pane-id", pane, ch)
        return out if out.startswith("error") else None


class Alacritty(Adapter):
    name = "alacritty"
    ipc = "alacritty msg (windows only: no tabs or splits)"

    def configure(self):
        self.conf = os.path.join(self.scratch, "alacritty.toml")
        self.sock = f"/tmp/a11-alacritty-{os.getpid()}.sock"
        with open(self.conf, "w") as f:
            f.write(f"[window]\ndimensions = {{ columns = {COLS}, lines = {ROWS} }}\n[font]\nsize = {FONT}\n"
                    "[cursor.style]\nblinking = \"Never\"\n[terminal.shell]\nprogram = \"/bin/zsh\"\nargs = [\"-i\"]\n"
                    "[general]\nlive_config_reload = false\nipc_socket = true\n")

    def argv(self):
        return [self.binary(), "--config-file", self.conf, "--socket", self.sock]

    def new_tab(self, term):  # a new window: Alacritty has no tabs or splits
        code, out, err = run([self.binary(), "msg", "--socket", self.sock, "create-window"], timeout=30)
        return "window" if code == 0 else f"error: {err.strip()[:200]}"


class Rex(Adapter):
    name = "rex"


class Cmux(Adapter):
    name = "cmux"
    ipc = "cmux control socket (action.run, debug.key)"
    can_type = True

    def __init__(self, app, zdot):
        super().__init__(app, zdot)
        from bench_launch import BenchApp, shipping_env
        import hid_input
        self.BenchApp, self.shipping_env, self.hid = BenchApp, shipping_env, hid_input
        self.bench = None

    def launch(self):
        self.probe_csv = os.path.join(OUT, f"cmux-typing-probe-{len(HUB.terms)}.csv")
        env = {**self.shipping_env(), "SHELL": "/bin/zsh", "HOME": self.zdot, "ZDOTDIR": None,
               "CMUX_NEXT_TYPING_PROBE": self.probe_csv}
        self.bench = self.BenchApp(self.app, out=os.path.join(OUT, "cmux-launch"), window=(40, 40, 1240, 820), env=env,
                                   log_name="app-competitors.log")
        with open(os.path.join(self.bench.scratch, "ghostty"), "w") as f:
            f.write(f"cursor-style-blink = false\nfont-size = {FONT}\n")
        started = {}

        def on_start(process):
            started["t"], started["wall"] = now(), time.time()
            started["waiter"] = wait_window([process.pid])
        self.bench.launch(timeout=180, on_start=on_start)
        self.control = self.hid.Control(self.bench.socket, os.path.join(self.app, "Contents/Resources/bin/cmux"),
                                        os.path.join(self.bench.scratch, "cmux.json"))
        self.socket_ready_ns = now()
        self.bench.activate()
        known = len(HUB.terms)
        reply = self.control.action("newSurface", focus=True)
        self.first_surface = json.dumps(reply)[:200]
        self.known_before_first = known
        return started["t"], started["wall"], started["waiter"]

    def pid(self):
        return self.bench.process.pid if self.bench and self.bench.process else None

    def activate(self):
        self.bench.activate()

    def new_tab(self, term):
        return json.dumps(self.control.action("newSurface", focus=True))[:160]

    def split(self, term):
        reply = json.dumps(self.control.action("splitRight", focus=True))[:160]
        self.control.action("equalizeSplits", focus=True)
        return reply

    def type_key(self, term, ch, opened=None):
        reply = self.control.rpc("debug.key", {"key": ch, "timestamp": now() / 1e9}, timeout=20)
        return None if not self.hid.is_error(reply) else f"error: {json.dumps(reply)[:160]}"

    def resize(self, term, cols):
        width = 1240 if cols >= COLS else 840
        return json.dumps(self.control.rpc("debug.window_frame", {"frame": [40, 40, width, 820]}, timeout=20))[:160]

    def quit(self):
        if self.bench:
            self.bench.stop()
        time.sleep(2)  # bench: the window server drops the closed windows


ADAPTERS = {"cmux": Cmux, "ghostty": Ghostty, "kitty": Kitty, "wezterm": WezTerm, "alacritty": Alacritty, "rex": Rex}


# ---------------------------------------------------------------- measurements
def launches(adapter, count):
    rows = []
    for k in range(count):
        known = len(HUB.terms)
        try:
            t0, wall, waiter = adapter.launch()
        except BaseException as error:  # noqa: BLE001 (LaunchError is a SystemExit)
            rows.append({"launch": k, "error": f"{type(error).__name__}: {error}"[:300]})
            adapter.quit()
            continue
        window = waiter.result()
        term = HUB.wait_new(known, 60)
        prompt = prompts_after(wall)
        row = {"launch": k, "kind": "first" if k == 0 else "warm",
               "window_ms": round((window[0] - t0) / 1e6, 1) if window else None,
               "prompt_ms": round((prompt[0] - wall) * 1000, 1) if prompt else None,
               "helper_ms": round((term.hello["t"] - t0) / 1e6, 1) if term else None}
        if isinstance(adapter, Cmux):
            row["socket_ms"] = round((adapter.socket_ready_ns - t0) / 1e6, 1)
            row["note"] = "cmux opens Home; the bench runs newSurface once the socket answers (prompt includes it)"
        rows.append(row)
        note(f"{adapter.name} launch {k}: {row}")
        adapter.quit()
        time.sleep(3)  # bench: let the host settle between launches
    def col(kind, key):
        return [r.get(key) for r in rows if r.get("kind") == kind]
    return {"rows": rows, "first": {k: (col("first", k) or [None])[0] for k in ("window_ms", "prompt_ms")},
            "warm": {k: dist(col("warm", k)) for k in ("window_ms", "prompt_ms")}}


def output_to_photon(term, photon, samples):
    rows = []
    big = photon.area() * 0.25
    term.call("clear")
    time.sleep(0.3)  # bench: the clear's frame passes
    for k in range(samples):
        if k and k % 40 == 0:
            term.call("clear")
            time.sleep(0.3)
        r = term.call("echo", ch="x", timeout=10)
        rows.append(r["t"] if r else None)
        time.sleep(0.12 + random.random() * 0.03)  # bench: space the samples past one frame
    time.sleep(0.3)
    frames = photon.frames(min(t for t in rows if t) - int(1e9)) if any(rows) else []
    return dist([first_frame_after(frames, t, int(0.1e9), big) if t else None for t in rows])


def key_to_photon(adapter, term, photon, samples):
    big = photon.area() * 0.25 if photon else None
    term.call("clear")
    time.sleep(0.3)
    sends, errors = [], []
    for k in range(samples):
        if k and k % 40 == 0:
            term.call("clear")
            time.sleep(0.3)
        t = now()
        err = adapter.type_key(term, "k")
        if err == "unsupported":
            return {"unsupported": f"{adapter.name} has no key injection path without Accessibility or Apple Events"}
        if err:
            errors.append(err)
        sends.append(t)
        time.sleep(0.12 + random.random() * 0.03)
    time.sleep(0.5)
    keys = term.events_of("key", sends[0] - 1)
    frames = photon.frames(sends[0] - int(1e9)) if photon else []
    send_to_read, read_to_frame, send_to_frame = [], [], []
    for i, t in enumerate(sends):
        nxt = sends[i + 1] if i + 1 < len(sends) else t + int(1e9)
        got = [e for e in keys if t <= e["t"] < nxt]
        read = got[0]["t"] if got else None
        if read:
            send_to_read.append((read - t) / 1e6)
            if photon:
                read_to_frame.append(first_frame_after(frames, read, int(0.1e9), big))
        if photon:
            send_to_frame.append(first_frame_after(frames, t, int(0.15e9), big))
    out = {"send_to_child_read": dist(send_to_read), "child_read_to_frame": dist(read_to_frame),
           "send_to_frame": dist(send_to_frame), "keys_read": len(keys), "sent": len(sends), "errors": errors[:3],
           "path": adapter.ipc}
    if isinstance(adapter, Cmux):
        rows = adapter.hid.probe_rows(adapter.probe_csv)[-len(sends):]

        def col(name):
            vals = []
            for r in rows:
                try:
                    vals.append(float(r.get(name)))
                except (TypeError, ValueError):
                    pass
            return dist(vals)
        # The app's own software probe: key event -> the frame Ghostty hands the layer after the echo's parse.
        out["cmux_typing_probe"] = {"rows": len(rows), "contents_ms": col("contents_ms"),
                                    "output_received_ms": col("output_received_ms"), "io_write_ms": col("io_write_ms"),
                                    "dispatch_end_ms": col("dispatch_end_ms"), "columns": list(rows[0].keys()) if rows else []}
    return out


def open_latency(adapter, term, photon, kind, rounds, typing_rounds):
    """New tab or split: send -> first changed frame, -> live prompt, -> helper; in the first rounds a key every 50 ms
    for 5 s from the open on (first-5 s typing): send -> the new child's read, and send -> the first frame after."""
    rows, typing = [], []
    for k in range(rounds):
        known = len(HUB.terms)
        wall, t0 = time.time(), now()
        reply = adapter.new_tab(term) if kind == "tab" else adapter.split(term)
        if reply == "unsupported":
            return {"unsupported": f"{adapter.name}: no {kind} without input or Apple Events"}
        keys = []
        if k < typing_rounds and adapter.can_type:
            for j in range(1, 101):
                when = t0 + j * int(50e6)
                while now() < when:
                    pass
                at = now()
                adapter.type_key(new_term_or(term, known), "a", opened=reply)
                keys.append((at, (at - when) / 1e6))
        new = HUB.wait_new(known, 30)
        prompt = prompts_after(wall)
        time.sleep(0.6)  # bench: the open's last frames land
        frames = photon.frames(t0) if photon else []
        row = {"round": k, "reply": str(reply)[:120],
               "frame_ms": round((frames[0][0] - t0) / 1e6, 2) if frames else None,
               "prompt_ms": round((prompt[0] - wall) * 1000, 1) if prompt else None,
               "helper_ms": round((new.hello["t"] - t0) / 1e6, 1) if new else None}
        rows.append(row)
        if keys:
            reads = new.events_of("key", t0) if new else []
            big = photon.area() * 0.25 if photon else None
            rec = []
            for i, (at, late) in enumerate(keys):
                nxt = keys[i + 1][0] if i + 1 < len(keys) else at + int(1e9)
                got = [e["t"] for e in reads if at <= e["t"] < nxt]
                # Keys typed before the child ran wait in the PTY: the child's first read gets them all at once.
                first_read = next((e["t"] for e in reads if e["t"] >= at), None)
                rec.append({"at_ms": round((at - t0) / 1e6, 1), "send_late_ms": round(late, 3),
                            "read_ms": round((first_read - at) / 1e6, 2) if first_read else None,
                            "read_in_slot": bool(got),
                            "frame_ms": first_frame_after(frames, at, int(0.5e9), big) if photon else None})
            typing.append(rec)
        if new:
            new.close()
        time.sleep(1.5)  # bench: the closed tab settles
    out = {"rows": rows, "frame_ms": dist([r["frame_ms"] for r in rows]),
           "prompt_ms": dist([r["prompt_ms"] for r in rows]), "helper_ms": dist([r["helper_ms"] for r in rows])}
    if typing:
        buckets = {}
        for rec in typing:
            for key in rec:
                buckets.setdefault(int(key["at_ms"] // 500) * 500, []).append(key)
        out["typing_buckets"] = {str(b): {"read_ms": dist([x["read_ms"] for x in v]),
                                          "frame_ms": dist([x["frame_ms"] for x in v]),
                                          "no_frame": sum(1 for x in v if x["frame_ms"] is None)}
                                 for b, v in sorted(buckets.items())}
        out["sender_late_max_ms"] = max(x["send_late_ms"] for rec in typing for x in rec)
    return out


def new_term_or(term, known):
    """The terminal a key goes to while a new tab opens: the new one once it said hello, else the old one."""
    with HUB.cond:
        return HUB.terms[known] if len(HUB.terms) > known else term


def throughput(adapter, term, path):
    term.call("clear")
    a = PROCS.sample(adapter.app)
    r = term.call("cat", path=path, timeout=900)
    b = PROCS.sample(adapter.app)
    cat = None
    if r:
        seconds = (r["t"] - r["t0"]) / 1e9
        cat = {"seconds": round(seconds, 2), "mb_per_s": round(os.path.getsize(path) / 2 ** 20 / seconds, 1),
               "app_cpu_s": round((b["cpu_ns"] - a["cpu_ns"]) / 1e9, 2)}
    term.call("clear")
    time.sleep(1)
    r = term.call("yes", seconds=10, timeout=120)
    yes = {"mb_per_s": round(r["bytes"] / 2 ** 20 / ((r["t"] - r["t0"]) / 1e9), 1)} if r else None
    term.call("clear")
    time.sleep(1)
    return {"cat": cat, "yes": yes}


def scroll_smoothness(term, photon, refresh_ms, rate):
    term.call("clear")
    time.sleep(0.5)
    r = term.call("stream", rate=rate, seconds=5, timeout=60)
    time.sleep(0.3)
    if not r or not photon:
        return None
    times = r["times"]
    frames = [f for f in photon.frames(times[0], times[-1] + int(0.1e9))]
    intervals = [(b[0] - a[0]) / 1e6 for a, b in zip(frames, frames[1:])]
    dropped = sum(max(0, round(dt / refresh_ms) - 1) for dt in intervals if dt > 1.5 * refresh_ms)
    late = [first_frame_after(frames, t, int(0.2e9)) for t in times]
    expected = (times[-1] - times[0]) / 1e6 / max(refresh_ms, 1000 / rate)
    return {"rate": rate, "lines": len(times), "frames": len(frames), "expected_frames": round(expected),
            "dropped_frames": dropped, "frame_interval_ms": dist(intervals), "line_to_frame_ms": dist(late),
            "lines_no_frame_within_2_refresh": sum(1 for x in late if x is None or x > 2 * refresh_ms)}


def reflow(adapter, term, photon):
    term.call("clear")
    term.call("fill", lines=10000, timeout=300)
    time.sleep(1)
    rows = []
    for k in range(6):
        cols = 80 if k % 2 == 0 else COLS
        t0 = now()
        reply = adapter.resize(term, cols)
        method = adapter.ipc
        if reply == "unsupported":
            term.call("csi8", rows=ROWS, cols=cols)
            method = "xterm CSI 8 t"
        winch = term.wait_event("winch", t0, 3)
        time.sleep(0.8)
        frames = photon.frames(t0, t0 + int(0.8e9)) if photon else []
        rows.append({"cols": cols, "method": method, "winch_ms": round((winch["t"] - t0) / 1e6, 2) if winch else None,
                     "winch_cols": winch.get("cols") if winch else None,
                     "first_frame_ms": round((frames[0][0] - t0) / 1e6, 2) if frames else None,
                     "last_frame_ms": round((frames[-1][0] - t0) / 1e6, 2) if frames else None})
    supported = any(r["winch_ms"] is not None for r in rows)
    return {"rows": rows, "supported": supported, "winch_ms": dist([r["winch_ms"] for r in rows]),
            "settle_ms": dist([r["last_frame_ms"] for r in rows if r["winch_ms"] is not None])}


def scale(adapter, term, counts, kind):
    out = {}
    opened = []
    for n in counts:
        t_start = time.monotonic()
        while 1 + len(opened) < n:
            known = len(HUB.terms)
            reply = adapter.new_tab(term) if kind == "tabs" else adapter.split(term)
            if reply == "unsupported":
                return {"unsupported": f"{adapter.name}: no {kind} without input or Apple Events"}
            new = HUB.wait_new(known, 20)
            if not new:
                out[str(n)] = {"error": f"terminal {1 + len(opened)} never said hello ({str(reply)[:120]})",
                               "reached": 1 + len(opened)}
                break
            opened.append(new)
        if str(n) in out:
            break
        time.sleep(opts.settle)
        out[str(n)] = {**idle_window(adapter.app, opts.idle * 0.67), "open_seconds": round(time.monotonic() - t_start, 1)}
        note(f"{adapter.name} {kind} {n}: {out[str(n)]['footprint_mb']} MB, {out[str(n)]['cpu_pct']} % CPU")
    for t in opened:
        t.close()
    time.sleep(3)
    return out


def measure_app(name, app, zdot, catfile, refresh_ms):
    entry = REPORT["apps"].setdefault(name, {})
    entry["info"] = info(app)
    adapter = ADAPTERS[name](app, zdot)
    entry["ipc"] = adapter.ipc
    entry["launch"] = launches(adapter, 1 if opts.phase == "probe" else opts.launches)
    save()
    known = len(HUB.terms)
    try:
        t0, wall, waiter = adapter.launch()
    except BaseException as error:  # noqa: BLE001
        entry["error"] = f"launch: {error}"[:300]
        adapter.quit()
        return
    waiter.result()
    term = HUB.wait_new(known, 60)
    pid = adapter.pid()
    entry["windows"] = probe("windows", "--pid", str(pid))[1].splitlines()[:6] if pid else None
    if not term:
        entry["helper"] = "no terminal said hello in 60 s (the app ran no shell with the bench's HOME/.zshrc)"
        time.sleep(opts.settle)
        entry["idle_1"] = idle_window(app, opts.idle)
        adapter.quit()
        save()
        return
    entry["hello"] = term.hello
    adapter.activate()
    time.sleep(opts.settle)
    entry["idle_1"] = idle_window(app, opts.idle if opts.phase == "full" else 10)
    if opts.phase == "full":
        time.sleep(max(0.0, 120 - opts.settle - opts.idle))  # bench: 2 min after the launch, past every warm-up
        entry["idle_1_late"] = idle_window(app, opts.idle)
    note(f"{name} idle 1: {entry['idle_1']['footprint_mb']} MB, {entry['idle_1']['cpu_pct']} %, "
         f"{entry['idle_1']['wakeups_per_s']} wakeups/s")
    save()
    photon = Photon(pid, os.path.join(OUT, f"photon-{name}.txt")) if REPORT["grants"].get("screen_capture") else None
    entry["photon"] = (photon.ready or photon.error) if photon else "no Screen Recording grant"
    if photon and not photon.ready:
        photon = None
    samples = 10 if opts.phase == "probe" else opts.samples
    try:
        if photon:
            entry["output_to_photon_ms"] = output_to_photon(term, photon, samples)
        entry["key_to_photon_ms"] = key_to_photon(adapter, term, photon, samples)
        save()
        if photon:
            entry["scroll"] = [scroll_smoothness(term, photon, refresh_ms, rate) for rate in (1000 / refresh_ms, 60)]
        entry["reflow"] = reflow(adapter, term, photon)
        save()
        rounds = 2 if opts.phase == "probe" else opts.rounds
        entry["new_tab"] = open_latency(adapter, term, photon, "tab", rounds, min(rounds, opts.typing_rounds))
        entry["split"] = open_latency(adapter, term, photon, "split", rounds, min(rounds, opts.typing_rounds))
        save()
        if photon:
            photon.stop()
            photon = None
        entry["throughput"] = throughput(adapter, term, catfile)
        save()
        if opts.phase == "full":
            entry["hidden_tabs"] = scale(adapter, term, [int(c) for c in opts.counts.split(",") if c], "tabs")
            save()
            entry["visible_splits"] = scale(adapter, term, [int(c) for c in opts.visible.split(",") if c], "splits")
    finally:
        if photon:
            photon.stop()
        adapter.quit()
        save()


def make_catfile(mb):
    path = os.path.join(OUT, f"cat{mb}.txt")
    if os.path.exists(path):
        return path
    rng = random.Random(11)
    words = ["alpha", "beta", "gamma", "delta", "src/main.rs:42:", "error[E0308]", "\x1b[32mok\x1b[0m", "{\"k\": 1}",
             "\x1b[1;31mFAIL\x1b[0m", "λ", "日本語", "ok", "|", "->", "0x7ffee4", "warning:", "\t"]
    with open(path, "w") as f:
        written, target = 0, mb * 2 ** 20
        while written < target:
            lines = []
            for _ in range(1000):
                line = " ".join(rng.choice(words) for _ in range(rng.randint(2, 18)))
                lines.append(line + "\n")
            block = "".join(lines)
            f.write(block)
            written += len(block.encode())
    return path


def daemon_suite(app):
    binary = os.path.join(app, "Contents", "Resources", "bin", "cmux-tui")
    out = os.path.join(OUT, "daemon-suite.json")
    code, so, se = run([sys.executable, os.path.join(REPO, "cmux-tui", "scripts", "bench-daemon-suite.py"),
                        "--bin", binary, "--out", out], timeout=3600)
    try:
        return json.load(open(out))
    except (OSError, ValueError):
        return {"error": f"exit {code}", "tail": (so + se)[-1500:]}


def first5s(app):
    out = os.path.join(OUT, "first5s")
    js = os.path.join(OUT, "first5s.json")
    code, so, se = run([sys.executable, os.path.join(HERE, "first-5s-typing.py"), "--app", app, "--out", out,
                        "--json", js, "--scenarios", "terminal,split", "--rounds", "3", "--sample-rounds", "0"],
                       timeout=3600)
    try:
        report = json.load(open(js))
    except (OSError, ValueError):
        return {"error": f"exit {code}", "tail": (so + se)[-1500:]}
    return {"exit": code, "summary": {k: report.get(k) for k in list(report)[:12]}}


def table():
    lines = ["| metric | " + " | ".join(REPORT["apps"]) + " |", "|---|" + "---|" * len(REPORT["apps"])]

    def cell(entry, path):
        node = entry
        for part in path:
            node = node.get(part) if isinstance(node, dict) else None
            if node is None:
                return "n/a"
        if isinstance(node, dict) and "unsupported" in node:
            return "N/A"
        return str(node)
    rows = [("version", ["info", "CFBundleShortVersionString"]), ("build", ["info", "CFBundleVersion"]),
            ("launch first: window ms", ["launch", "first", "window_ms"]),
            ("launch first: prompt ms", ["launch", "first", "prompt_ms"]),
            ("launch warm p50: window ms", ["launch", "warm", "window_ms", "p50"]),
            ("launch warm p50: prompt ms", ["launch", "warm", "prompt_ms", "p50"]),
            ("idle 1 terminal: MB", ["idle_1", "footprint_mb"]), ("idle 1: CPU %", ["idle_1", "cpu_pct"]),
            ("idle 1: wakeups/s", ["idle_1", "wakeups_per_s"]),
            ("idle 1 at 2 min: MB", ["idle_1_late", "footprint_mb"]), ("idle 1 at 2 min: CPU %", ["idle_1_late", "cpu_pct"]),
            ("idle 1 at 2 min: wakeups/s", ["idle_1_late", "wakeups_per_s"]),
            ("output->photon p50 ms", ["output_to_photon_ms", "p50"]),
            ("output->photon p95 ms", ["output_to_photon_ms", "p95"]),
            ("key->photon (injected) p50 ms", ["key_to_photon_ms", "send_to_frame", "p50"]),
            ("key->photon (injected) p95 ms", ["key_to_photon_ms", "send_to_frame", "p95"]),
            ("key send->child read p50 ms", ["key_to_photon_ms", "send_to_child_read", "p50"]),
            ("key send->child read p95 ms", ["key_to_photon_ms", "send_to_child_read", "p95"]),
            ("cmux probe key->frame p50 ms", ["key_to_photon_ms", "cmux_typing_probe", "contents_ms", "p50"]),
            ("cmux probe key->frame p95 ms", ["key_to_photon_ms", "cmux_typing_probe", "contents_ms", "p95"]),
            ("new tab -> helper p50 ms", ["new_tab", "helper_ms", "p50"]),
            ("split -> helper p50 ms", ["split", "helper_ms", "p50"]),
            ("new tab -> frame p50 ms", ["new_tab", "frame_ms", "p50"]),
            ("new tab -> prompt p50 ms", ["new_tab", "prompt_ms", "p50"]),
            ("split -> frame p50 ms", ["split", "frame_ms", "p50"]),
            ("split -> prompt p50 ms", ["split", "prompt_ms", "p50"]),
            ("cat 150 MB s", ["throughput", "cat", "seconds"]), ("yes MB/s", ["throughput", "yes", "mb_per_s"]),
            ("reflow 10k: settle p50 ms", ["reflow", "settle_ms", "p50"]),
            ("10 tabs MB", ["hidden_tabs", "10", "footprint_mb"]), ("100 tabs MB", ["hidden_tabs", "100", "footprint_mb"]),
            ("100 tabs CPU %", ["hidden_tabs", "100", "cpu_pct"]),
            ("10 splits MB", ["visible_splits", "10", "footprint_mb"])]
    for label, path in rows:
        lines.append(f"| {label} | " + " | ".join(cell(REPORT["apps"][a], path) for a in REPORT["apps"]) + " |")
    for a, entry in REPORT["apps"].items():
        for s in entry.get("scroll") or []:
            if s:
                lines.append(f"| scroll {a} {s['rate']:.0f} lines/s: dropped/expected | {s['dropped_frames']}/"
                             f"{s['expected_frames']} |")
    return "\n".join(lines)


def main():
    global PROBE, PROCS, HUB
    PROBE = swift_tool("a11-probe", "a11-probe.swift")
    PROCS = Procs()
    HUB = Hub()
    code, grants, err = probe("grants")
    REPORT["grants"] = json.loads(grants) if code == 0 else {"error": err[-300:]}
    note(f"grants {REPORT['grants']}")
    REPORT["host"] = {"name": run(["scutil", "--get", "ComputerName"])[1].strip(),
                      "macos": run(["sw_vers", "-productVersion"])[1].strip(),
                      "model": run(["sysctl", "-n", "hw.model"])[1].strip(),
                      "chip": run(["sysctl", "-n", "machdep.cpu.brand_string"])[1].strip(),
                      "load": os.getloadavg()}
    refresh_ms = 1000 / 120
    try:
        line = open(os.path.join(os.path.dirname(OUT), "split-spring", "display.txt")).read()
    except OSError:
        line = ""
    m = re.match(r"ready \d+ ([\d.]+)", line)
    if m:
        refresh_ms = float(m.group(1))
    REPORT["refresh_ms"] = refresh_ms
    zdot = make_home()
    catfile = make_catfile(opts.cat_mb if opts.phase == "full" else 10)
    for name in [a for a in opts.apps.split(",") if a]:
        try:
            app = opts.app if name == "cmux" else install(name)
            note(f"{name}: {app} {info(app)}")
            measure_app(name, app, zdot, catfile, refresh_ms)
        except Exception as error:  # noqa: BLE001
            REPORT["apps"].setdefault(name, {})["error"] = f"{error!r}"[:500]
            REPORT["apps"][name]["traceback"] = traceback.format_exc()[-2000:]
            note(f"{name} failed: {error!r}")
        save()
    if opts.daemon:
        REPORT["daemon"] = daemon_suite(opts.app)
        save()
    if opts.first5s:
        REPORT["first5s_validation"] = first5s(opts.app)
        save()
    REPORT["table"] = table()
    REPORT["finished"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    save()
    with open(os.path.join(OUT, "COMPETITORS.md"), "w") as f:
        f.write(REPORT["table"] + "\n")
    for line in REPORT["table"].splitlines():
        print("COMPETITOR-TABLE " + line, flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
