#!/usr/bin/env python3
"""CHROME PARITY BENCH, the Chrome arm by the APP-CLOCK method (no macOS privacy right needed).

chrome_parity.py measures both apps with real HID events and a ScreenCaptureKit stream of the display. That needs
the PostEvent and Screen Recording rights for the process that starts the bench. A host that gives an ssh session
neither (aws-m4pro-8, 2026-11-10: the responsible process is /usr/local/bin/tailscaled, both rights denied) cannot
run it. This tool measures the Chrome arm there with Chrome's own input and frame clock:

  - Input: the DevTools protocol on a local port (Input.dispatchKeyEvent, Input.dispatchMouseEvent mouseWheel,
    Target.createTarget, Target.activateTarget, Browser.setWindowBounds). The event enters Chrome in the browser
    process: the hop from the keyboard through WindowServer to Chrome is NOT in any number here.
  - Frames: Chrome's own trace (Tracing.start on the browser socket; categories input, latency,
    disabled-by-default-devtools.timeline.frame, blink.user_timing): `EventLatency` (the input event's creation in
    Chrome -> the presentation of the frame that holds its result) and `PipelineReporter` (one per compositor frame,
    with its state: presented or dropped; its end is the presentation time). The presentation time is Chrome's own
    stamp on the mach clock (CLOCK_UPTIME_RAW in microseconds). It sits on the display's refresh grid; it is not a
    scan-out stamp, and Chrome writes it also when the console screen is locked. Two frames that share one
    presentation time are ONE refresh on screen: the pacing rows count distinct presentation times.
  - Each latency sample is given two ways: `samples` = EventLatency begin -> presentation (Chrome's own number) and
    `send_ms` = the bench's stamp just before it wrote the command to the socket -> the same presentation.
  - UMA through Browser.getHistogram holds only browser-process histograms on Chrome 156 (EventLatency.* and
    Graphics.Smoothness.* are not there); the one cross-check it gives is Browser.Tabs.TotalSwitchDuration3.

Honesty rules (`selfcheck` proves them on the host):
  - A latency sample exists only when the trace holds that input's EventLatency WITH a display frame
    (`display_trace_id`). Chrome writes an EventLatency also for an event that changed no frame; that one is `lost`
    (10 late refreshes), never a number.
  - Frames count only from the measured page's own renderer process, and only when the page says
    `document.visibilityState == "visible"` and its window is in the "normal" state before and after the run. A
    hidden tab or a minimized window is "not run", whatever frames Chrome wrote.
  - A pacing row with fewer than 10 presented frames inside its input spans is "not run: the input moved nothing".
  - A run with the console screen locked (I/O registry IOConsoleLocked), with no display of --min-hz or more, or
    whose display went away, is "not run". `--allow-locked-screen` keeps its numbers for a look, with status
    "invalid": they are never table numbers.

It is a bench tool, never a CI gate, job, step or perf-gate row. Python 3.9 standard library only; the installed
Google Chrome stable only; no flag that changes rendering, vsync or throttling. It creates no display, changes no
setting and stops only the Chrome it started (Browser.close, then that exact pid).

  parity_chrome_cdp.py run --out DIR [--rows a,b] [--loads light,load] [--runs 2] [--chrome APP] [--root DIR]
                           [--min-hz 100] [--no-lock] [--allow-locked-screen] [--note TEXT]
  parity_chrome_cdp.py selfcheck --out DIR      the honesty proofs; exit 0 only when all hold
  parity_chrome_cdp.py refresh --out DIR        the refresh interval Chrome presents at on the bench display
  parity_chrome_cdp.py explore --out DIR        trace event names of a short typed + scrolled run (for a new Chrome)

From another tool: `ctx = Ctx(chrome, root, out)`, then `with GuiLock(lock_path): run_row(ctx, row, load, i)`.
"""
from __future__ import annotations

import argparse
import base64
import ctypes
import hashlib
import json
import os
import plistlib
import random
import shutil
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import chrome_parity as cp  # noqa: E402  (pages, Server, stats, late, LOST_LATE, WINDOW: one definition for both tools)

CHROME_DEFAULT = cp.CHROME_DEFAULT
# Not one of these changes rendering, vsync, the frame rate or background throttling.
FLAGS = ["--no-first-run", "--no-default-browser-check", "--disable-search-engine-choice-screen",
         "--password-store=basic", "--use-mock-keychain", "--mute-audio", "--hide-crash-restore-bubble"]
# The smallest set that holds what the rows read: EventLatency (input), PipelineReporter (the frame category) and
# TabSwitching::Latency (latency). "benchmark" would add about 5 times the events (viz and cc scheduler spans).
TRACE_CATEGORIES = ["input", "disabled-by-default-devtools.timeline.frame", "latency", "blink.user_timing"]
ROWS = ["key-field", "key-terminal", "scroll-page", "scroll-terminal", "cmdt-first", "tab-switch", "window-resize",
        "launch-first"]
NEEDS_OS_INPUT = {
    "key-native": "the omnibox takes no DevTools key event",
    "cmdt-interactive": "a browser shortcut and omnibox typing need OS key events",
    "pane-resize": "the DevTools dock divider needs a mouse drag",
    "hover-sidebar": "the tab strip hover needs OS mouse moves",
    "hover-tabs": "the tab strip hover needs OS mouse moves",
    "drag-sidebar": "a tab strip drag needs OS mouse events",
    "drag-tabs": "a tab strip drag needs OS mouse events",
    "launch-interactive": "typing while the app launches needs OS key events",
}
OS_INPUT_REASON = ("needs OS input: this tool sends DevTools events only (an OS event needs the PostEvent / "
                   "Accessibility right for the process that starts the bench)")
METHOD = ("app-clock: DevTools input (no OS event), Chrome trace EventLatency / PipelineReporter presentation times "
          "(Chrome's own stamp on the mach uptime clock, on the display's refresh grid); the OS input hop and the "
          "display scan-out are not measured")
SHOWN = "visible/normal"
LETTERS = "asdfghjkl"
FIELD_LEN = "document.getElementById('f').value.length"
SCROLL_COUNT = ("window.__s=0;addEventListener('scroll',()=>window.__s++);1", "window.__s")


class NotRun(Exception):
    pass


def log(message):
    print(f"[chrome-cdp {time.strftime('%H:%M:%S', time.gmtime())}Z] {message}", flush=True)


def now_ns():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


def pause(seconds):
    time.sleep(seconds)  # bench: a deliberate settle outside every timed span


def sleep_until(deadline_ns):
    while True:
        left = deadline_ns - now_ns()
        if left <= 0:
            return
        time.sleep(max(0.0, left / 1e9 - 0.0003) if left > 600_000 else 0)  # bench: the input schedule


def load1():
    return round(os.getloadavg()[0], 2)


# ---------------------------------------------------------------- display (CoreGraphics, no privacy right)


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class CGSize(ctypes.Structure):
    _fields_ = [("w", ctypes.c_double), ("h", ctypes.c_double)]


class CGRect(ctypes.Structure):
    _fields_ = [("o", CGPoint), ("s", CGSize)]


def displays():
    """Every active display: id, bounds in global points (top-left origin), refresh rate, main, asleep."""
    cg = ctypes.CDLL("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics")
    ids = (ctypes.c_uint32 * 16)()
    count = ctypes.c_uint32(0)
    cg.CGGetActiveDisplayList(16, ids, ctypes.byref(count))
    cg.CGDisplayBounds.restype = CGRect
    cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
    cg.CGDisplayCopyDisplayMode.restype = ctypes.c_void_p
    cg.CGDisplayCopyDisplayMode.argtypes = [ctypes.c_uint32]
    cg.CGDisplayModeGetRefreshRate.restype = ctypes.c_double
    cg.CGDisplayModeGetRefreshRate.argtypes = [ctypes.c_void_p]
    cg.CGDisplayModeRelease.argtypes = [ctypes.c_void_p]
    cg.CGMainDisplayID.restype = ctypes.c_uint32
    cg.CGDisplayIsAsleep.argtypes = [ctypes.c_uint32]
    out = []
    for i in range(count.value):
        d = ids[i]
        b = cg.CGDisplayBounds(d)
        mode = cg.CGDisplayCopyDisplayMode(d)
        hz = cg.CGDisplayModeGetRefreshRate(mode) if mode else 0.0
        if mode:
            cg.CGDisplayModeRelease(mode)
        out.append({"id": int(d), "bounds": [int(b.o.x), int(b.o.y), int(b.s.w), int(b.s.h)], "hz": round(hz, 3),
                    "main": d == cg.CGMainDisplayID(), "asleep": bool(cg.CGDisplayIsAsleep(d))})
    return out


def bench_display(want_hz=None, min_hz=100.0):
    """The display the window goes on: the fastest one (the 120 Hz virtual display on a bench mini)."""
    all_displays = displays()
    fast = [d for d in all_displays if d["hz"] >= min_hz and not d["asleep"]]
    if not fast:
        raise NotRun(f"no active display of {min_hz:g} Hz or more (active displays: {all_displays or 'none'})")
    pick = max(fast, key=lambda d: (d["hz"] if want_hz is None else -abs(d["hz"] - want_hz), d["bounds"][2]))
    return pick, all_displays


def console_state():
    """{"locked", "user"} of the console session, from the I/O registry root (needs no right). `locked` is None when
    the registry does not say."""
    try:
        raw = subprocess.run(["ioreg", "-n", "Root", "-d1", "-a"], capture_output=True, timeout=10).stdout
        root = plistlib.loads(raw)
    except Exception as error:  # an unreadable registry is "not known", and the caller treats that as not valid
        return {"locked": None, "error": f"{type(error).__name__}: {error}"[:200]}
    users = root.get("IOConsoleUsers") or []
    console = next((u for u in users if u.get("kCGSSessionOnConsoleKey")), None)
    if console is None:
        return {"locked": None, "error": "no console session in IOConsoleUsers"}
    locked = bool(root.get("IOConsoleLocked")) or bool(console.get("CGSSessionScreenIsLocked"))
    return {"locked": locked, "user": console.get("kCGSSessionUserNameKey")}


# ---------------------------------------------------------------- websocket (RFC 6455, client side)


class WebSocket:
    GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    def __init__(self, url, timeout=30):
        u = urllib.parse.urlparse(url)
        self.sock = socket.create_connection((u.hostname, u.port), timeout=timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        key = base64.b64encode(os.urandom(16)).decode()
        # No Origin header: Chrome refuses a DevTools socket with an Origin it was not told to allow.
        self.sock.sendall((f"GET {u.path} HTTP/1.1\r\nHost: {u.hostname}:{u.port}\r\nUpgrade: websocket\r\n"
                           f"Connection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        self.buf = bytearray()
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(65536)
            if not chunk:
                raise ConnectionError("websocket: closed in the handshake")
            self.buf += chunk
        head, _, rest = bytes(self.buf).partition(b"\r\n\r\n")
        self.buf = bytearray(rest)
        lines = head.decode(errors="replace").split("\r\n")
        want = base64.b64encode(hashlib.sha1((key + self.GUID).encode()).digest()).decode()
        headers = {k.strip().lower(): v.strip() for k, _, v in (line.partition(":") for line in lines[1:])}
        if " 101 " not in lines[0] + " " or headers.get("sec-websocket-accept") != want:
            raise ConnectionError(f"websocket: handshake refused: {lines[0]}")
        self.sock.settimeout(None)
        self.wlock = threading.Lock()

    def _frame(self, opcode, data):
        n = len(data)
        head = bytearray([0x80 | opcode])
        if n < 126:
            head.append(0x80 | n)
        elif n < 65536:
            head.append(0x80 | 126)
            head += struct.pack(">H", n)
        else:
            head.append(0x80 | 127)
            head += struct.pack(">Q", n)
        mask = os.urandom(4)
        head += mask
        if n:
            pad = (mask * (n // 4 + 1))[:n]
            data = (int.from_bytes(data, "big") ^ int.from_bytes(pad, "big")).to_bytes(n, "big")
        with self.wlock:
            self.sock.sendall(bytes(head) + data)

    def send(self, text):
        self._frame(0x1, text.encode())

    def _read(self, n):
        while len(self.buf) < n:
            chunk = self.sock.recv(1 << 20)
            if not chunk:
                raise ConnectionError("websocket: closed")
            self.buf += chunk
        out = bytes(self.buf[:n])
        del self.buf[:n]
        return out

    def recv(self):
        """One whole text message (fragments joined), or None when the peer closed."""
        parts = []
        while True:
            b0, b1 = self._read(2)
            n = b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8))[0]
            mask = self._read(4) if b1 & 0x80 else None
            data = self._read(n)
            if mask and n:
                pad = (mask * (n // 4 + 1))[:n]
                data = (int.from_bytes(data, "big") ^ int.from_bytes(pad, "big")).to_bytes(n, "big")
            op = b0 & 0x0F
            if op == 0x8:
                return None
            if op == 0x9:
                self._frame(0xA, data)
                continue
            if op == 0xA:
                continue
            parts.append(data)
            if b0 & 0x80:
                return b"".join(parts).decode(errors="replace")

    def close(self):
        try:
            self._frame(0x8, b"")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


class CDPError(Exception):
    pass


class CDP:
    """The browser's DevTools socket, flat sessions. A reader thread files replies, events and trace chunks."""

    def __init__(self, ws_url):
        self.ws = WebSocket(ws_url)
        self.next_id = 0
        self.replies = {}
        self.sent = {}
        self.events = []
        self.trace = []
        self.trace_done = threading.Event()
        self.cv = threading.Condition()
        self.closed = False
        threading.Thread(target=self._reader, daemon=True).start()

    def _reader(self):
        try:
            while True:
                text = self.ws.recv()
                if text is None:
                    break
                msg = json.loads(text)
                method = msg.get("method")
                if "id" in msg:
                    with self.cv:
                        self.replies[msg["id"]] = msg
                        self.cv.notify_all()
                elif method == "Tracing.dataCollected":
                    self.trace.extend(msg["params"].get("value") or [])
                elif method == "Tracing.tracingComplete":
                    self.trace_done.set()
                else:
                    with self.cv:
                        self.events.append(msg)
                        if len(self.events) > 5000:
                            del self.events[:2500]
                        self.cv.notify_all()
        except (OSError, ValueError):
            pass
        finally:
            with self.cv:
                self.closed = True
                self.cv.notify_all()

    def send(self, method, params=None, session=None):
        """Writes the command; returns its id. `sent[id]` is the mach time just before the write."""
        with self.cv:
            self.next_id += 1
            ident = self.next_id
        msg = {"id": ident, "method": method, "params": params or {}}
        if session:
            msg["sessionId"] = session
        text = json.dumps(msg)
        self.sent[ident] = now_ns()
        self.ws.send(text)
        return ident

    def wait(self, ident, timeout=30):
        deadline = time.monotonic() + timeout
        with self.cv:
            while ident not in self.replies:
                left = deadline - time.monotonic()
                if self.closed or left <= 0:
                    raise CDPError(f"no reply to command {ident} ({'socket closed' if self.closed else 'timeout'})")
                self.cv.wait(left)
            msg = self.replies.pop(ident)
        if "error" in msg:
            raise CDPError(json.dumps(msg["error"])[:300])
        return msg.get("result") or {}

    def call(self, method, params=None, session=None, timeout=30):
        return self.wait(self.send(method, params, session), timeout)

    def drain(self, idents, timeout=30):
        """Collects the replies within `timeout` s in all; returns how many commands failed or got no reply."""
        deadline = time.monotonic() + timeout
        errors = 0
        for ident in idents:
            try:
                self.wait(ident, max(0.05, deadline - time.monotonic()))
            except CDPError:
                errors += 1
        return errors

    def evaluate(self, session, expression, timeout=30):
        got = self.call("Runtime.evaluate", {"expression": expression, "returnByValue": True, "awaitPromise": True},
                        session, timeout)
        if got.get("exceptionDetails"):
            raise CDPError("evaluate: " + json.dumps(got["exceptionDetails"])[:300])
        return (got.get("result") or {}).get("value")

    def trace_start(self):
        self.trace = []
        self.trace_done.clear()
        self.call("Tracing.start", {"transferMode": "ReportEvents",
                                    "traceConfig": {"recordMode": "recordAsMuchAsPossible",
                                                    "includedCategories": TRACE_CATEGORIES}})

    def mark(self, session, probe=False):
        """A user-timing mark in the measured page while the trace runs; Trace.pid_of_mark finds its process. With
        `probe`, also one Shift key release into the page (it changes nothing): a row with no input of its own can
        then find the page's process by that event's EventLatency when the trace holds no mark."""
        name = f"parity-mark-{time.time_ns()}"
        self.evaluate(session, f"performance.mark('{name}');1")
        if probe:
            self.call("Input.dispatchKeyEvent", {"type": "keyUp", "key": "Shift", "code": "ShiftLeft",
                                                 "windowsVirtualKeyCode": 16, "nativeVirtualKeyCode": 16}, session)
            pause(0.1)
        return name

    def trace_end(self, timeout=120):
        self.call("Tracing.end")
        if not self.trace_done.wait(timeout):
            raise NotRun("Chrome's trace did not complete")
        events, self.trace = self.trace, []
        return Trace(events)

    def close(self):
        self.ws.close()


# ---------------------------------------------------------------- the trace


class Trace:
    """Chrome's JSON trace events. Times are nanoseconds on the mach uptime clock (trace `ts` is microseconds)."""

    def __init__(self, events):
        self.events = events
        self.overlaps = 0
        self.names = {}
        for e in events:
            if e.get("ph") == "M" and e.get("name") == "process_name":
                self.names[e["pid"]] = (e.get("args") or {}).get("name", "")
        self.browser = next((p for p, n in self.names.items() if n == "Browser"), None)
        self.renderers = {p for p, n in self.names.items() if n == "Renderer"}

    @staticmethod
    def _key(e):
        ident = e.get("id")
        if ident is None:
            id2 = e.get("id2") or {}
            ident = "l" + str(id2["local"]) if "local" in id2 else "g" + str(id2.get("global"))
        return (e.get("pid"), e.get("cat"), ident)

    def _spans(self, name):
        """Top-level async spans of `name`: (pid, begin_ns, end_ns, args of begin merged with args of end)."""
        open_spans, out = {}, []
        for e in sorted((e for e in self.events if e.get("name") == name and e.get("ph") in ("b", "e")),
                        key=lambda e: e.get("ts", 0)):
            key = self._key(e)
            if e["ph"] == "b":
                if open_spans.get(key):
                    self.overlaps += 1  # two open spans with one id: the pairing below (last in, first out) may be wrong
                open_spans.setdefault(key, []).append(e)
            elif open_spans.get(key):
                b = open_spans[key].pop()
                args = dict(b.get("args") or {})
                args.update(e.get("args") or {})
                out.append((e.get("pid"), int(b["ts"] * 1000), int(e["ts"] * 1000), args))
        return out

    def event_latency(self):
        """[{pid, type, begin, end, presented}]: one per input event Chrome tracked. Chrome writes an EventLatency span
        also for an event that changed no frame (a key release, a key into nothing, a wheel event that only starts a
        gesture): that span ends when the event is dropped, not at a presentation, and has no `display_trace_id`.
        `presented` is true only when the span names the display frame that showed the event's result; with it the
        span's end is that frame's presentation time."""
        out = []
        for pid, begin, end, args in self._spans("EventLatency"):
            info = args.get("event_latency") or {}
            out.append({"pid": pid, "type": str(info.get("event_type", "?")), "begin": begin, "end": end,
                        "presented": "display_trace_id" in info, "vsync_ms": info.get("vsync_interval_ms")})
        return out

    def frames(self):
        """[{pid, begin, end, state, smooth}]: one per compositor frame (PipelineReporter)."""
        out = []
        for pid, begin, end, args in self._spans("PipelineReporter"):
            info = args.get("frame_reporter") or args.get("chrome_frame_reporter") or {}
            state = str(info.get("state", "?"))
            out.append({"pid": pid, "begin": begin, "end": end, "state": state, "kind": info.get("frame_type"),
                        "presented": "PRESENTED" in state, "dropped": "DROPPED" in state,
                        "smooth": bool(info.get("affects_smoothness"))})
        return out

    def named(self, name):
        return self._spans(name)

    def pid_of_mark(self, mark):
        """The renderer process that ran `performance.mark(mark)`: the measured page's own process."""
        return next((e.get("pid") for e in self.events if e.get("name") == mark), None)

    def page_process(self, mark, input_types):
        """(pid, how) of the measured page's renderer: the process that ran the bench's performance.mark, else the
        one renderer process that holds EventLatency spans of the bench's input."""
        pid = self.pid_of_mark(mark)
        if pid is not None:
            return pid, "performance.mark in the page"
        pids = {e["pid"] for e in self.event_latency()
                if e["pid"] in self.renderers and any(t in e["type"] for t in input_types)}
        if len(pids) == 1:
            return pids.pop(), "the one renderer process with the input's EventLatency"
        raise NotRun(f"the measured page's renderer process is not known: no mark in the trace and {len(pids)} "
                     f"renderer processes hold the input's EventLatency")

    def by_process(self, frames):
        out = {}
        for f in frames:
            key = f"{self.names.get(f['pid'], '?')} {f['pid']}"
            row = out.setdefault(key, {"presented": 0, "dropped": 0, "other": 0})
            row["presented" if f["presented"] else "dropped" if f["dropped"] else "other"] += 1
        return out

    def summary(self):
        counts = {}
        for e in self.events:
            key = f"{e.get('cat')}|{e.get('name')}|{e.get('ph')}"
            counts[key] = counts.get(key, 0) + 1
        return dict(sorted(counts.items(), key=lambda kv: -kv[1]))


def presented_times(frames, pids=None, merge_ms=1.0):
    """Presentation times (ns) of presented frames, sorted; times closer than merge_ms are one refresh."""
    times = sorted(f["end"] for f in frames if f["presented"] and (pids is None or f["pid"] in pids))
    out = []
    for t in times:
        if not out or t - out[-1] > merge_ms * 1e6:
            out.append(t)
    return out


def pacing_of(times, spans, refresh_ms):
    intervals, missed, inside = [], 0, 0
    for start, end in spans:
        ts = [t for t in times if start <= t <= end]
        inside += len(ts)
        for a, b in zip(ts, ts[1:]):
            ms = (b - a) / 1e6
            intervals.append(round(ms, 3))
            if ms > 1.5 * refresh_ms:
                missed += round(ms / refresh_ms) - 1
    return intervals, missed, inside


def grid_ms(intervals):
    """The refresh interval the presentation times sit on: the 5th percentile interval between refreshes with a frame."""
    v = sorted(intervals)
    return round(v[len(v) // 20], 3) if v else None


def median(values):
    v = sorted(values)
    return v[len(v) // 2] if v else None


# ---------------------------------------------------------------- Chrome


def chrome_version(bundle):
    exe = os.path.join(bundle, "Contents/MacOS/Google Chrome")
    try:
        return subprocess.run([exe, "--version"], capture_output=True, text=True, timeout=30).stdout.strip()
    except (OSError, subprocess.TimeoutExpired) as error:
        return f"unknown ({error})"


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def drop_profile(root, profile):
    """Removes a profile folder this tool made: only a `run-...` folder directly under the profiles root."""
    if profile and os.path.dirname(os.path.abspath(profile)) == os.path.abspath(root) \
            and os.path.basename(profile).startswith("run-"):
        shutil.rmtree(profile, ignore_errors=True)


class Chrome:
    """One Chrome instance with a profile and HOME of its own, started in the console session with `open`."""

    def __init__(self, bundle, root, server, display, window=None):
        self.bundle = os.path.abspath(bundle)
        self.root = root
        self.server = server
        self.display = display
        x, y, w, h = cp.WINDOW
        self.window = window or [display["bounds"][0] + x, display["bounds"][1] + y, w, h]
        self.cdp = None
        self.pid = None
        self.port = None
        self.profile = None
        self.window_id = None
        self.t_open_ns = None
        self.t_open_wall = None

    def new_profile(self, label):
        path = os.path.join(self.root, f"run-{label}-{time.time_ns()}")
        os.makedirs(path)
        return path

    def launch(self, profile=None, url=None, restore=False, label="p"):
        self.profile = profile or self.new_profile(label)
        home = os.path.join(self.profile, "home")
        data = os.path.join(self.profile, "data")
        os.makedirs(os.path.join(home, "Library"), exist_ok=True)
        self.port = free_port()
        argv = ["open", "-n", "--env", f"HOME={home}", "--env", f"CFFIXED_USER_HOME={home}", "-a", self.bundle, "--args",
                f"--user-data-dir={data}", f"--remote-debugging-port={self.port}", *FLAGS,
                f"--window-position={self.window[0]},{self.window[1]}", f"--window-size={self.window[2]},{self.window[3]}"]
        if restore:
            argv.append("--restore-last-session")
        if url:
            argv.append(url)
        self.t_open_wall = time.time()
        self.t_open_ns = now_ns()
        done = subprocess.run(argv, capture_output=True, text=True, timeout=60)
        if done.returncode != 0:
            raise NotRun(f"open could not start Chrome in this session: exit {done.returncode} {done.stderr.strip()[:200]}")
        try:
            deadline = time.monotonic() + 45
            version, last = None, None
            while time.monotonic() < deadline:
                try:
                    with urllib.request.urlopen(f"http://127.0.0.1:{self.port}/json/version", timeout=2) as r:
                        version = json.loads(r.read())
                    break
                except (OSError, ValueError) as error:
                    last = error
                    time.sleep(0.1)  # bench: waiting for the DevTools port
            if not version:
                raise NotRun(f"Chrome gave no DevTools endpoint on port {self.port} ({last})")
            self.pid = self.main_pid(data)
            self.cdp = CDP(version["webSocketDebuggerUrl"])
            self.product = version.get("Browser")
        except BaseException:  # the caller has no handle yet: stop the instance this call started, then say why
            self.pid = self.pid or self.main_pid(data)
            self.quit()
            raise
        return self

    @staticmethod
    def main_pid(data):
        out = subprocess.run(["ps", "-axww", "-o", "pid=,command="], capture_output=True, text=True).stdout
        for line in out.splitlines():
            pid, _, cmd = line.strip().partition(" ")
            if f"--user-data-dir={data}" in cmd and "--type=" not in cmd and "Google Chrome" in cmd:
                return int(pid)
        return None

    def pages(self):
        infos = self.cdp.call("Target.getTargets").get("targetInfos") or []
        return [t for t in infos if t.get("type") == "page"]

    def open(self, url, background=False):
        target = self.cdp.call("Target.createTarget", {"url": url, "background": background})["targetId"]
        return target

    def attach(self, target):
        return self.cdp.call("Target.attachToTarget", {"targetId": target, "flatten": True})["sessionId"]

    def place(self, target):
        """The window on the bench display at the bench size; returns what Chrome says it has."""
        got = self.cdp.call("Browser.getWindowForTarget", {"targetId": target})
        self.window_id = got["windowId"]
        x, y, w, h = self.window
        if (got.get("bounds") or {}).get("windowState", "normal") != "normal":
            self.cdp.call("Browser.setWindowBounds", {"windowId": self.window_id, "bounds": {"windowState": "normal"}})
        self.cdp.call("Browser.setWindowBounds", {"windowId": self.window_id,
                                                  "bounds": {"left": x, "top": y, "width": w, "height": h}})
        pause(0.5)
        return self.cdp.call("Browser.getWindowForTarget", {"targetId": target}).get("bounds")

    def setup(self, load, url):
        """As chrome_parity.ChromeArm.setup: the load tabs, then the measured tab last (in front)."""
        first = [t["targetId"] for t in self.pages()]
        if load:
            self.open(self.server.url("cpu"))
            for _ in range(5):
                self.open(self.server.url("stream"))
        target = self.open(url)
        for old in first:  # the launch's own New Tab page
            try:
                self.cdp.call("Target.closeTarget", {"targetId": old})
            except CDPError:
                pass
        pause(2.5)
        bounds = self.place(target)
        self.cdp.call("Target.activateTarget", {"targetId": target})
        session = self.attach(target)
        self.cdp.call("Page.bringToFront", session=session)
        pause(0.5)
        state = self.cdp.evaluate(session, "({vis:document.visibilityState,focus:document.hasFocus(),sx:screenX,sy:screenY,"
                                           "sw:screen.width,sh:screen.height,iw:innerWidth,ih:innerHeight,dpr:devicePixelRatio})")
        if state.get("vis") != "visible":
            raise NotRun(f"the measured tab is not visible ({state})")
        return target, session, {"bounds": bounds, "page": state}

    def shown(self, session):
        """What the page and the window say: "visible/normal" for a shown tab in a normal window."""
        vis = self.cdp.evaluate(session, "document.visibilityState")
        try:
            state = self.cdp.call("Browser.getWindowBounds", {"windowId": self.window_id})["bounds"].get("windowState")
        except (CDPError, KeyError) as error:
            state = f"? {error}"
        return f"{vis}/{state}"

    def histogram(self, name, delta=False):
        try:
            return self.cdp.call("Browser.getHistogram", {"name": name, "delta": delta}).get("histogram")
        except CDPError:
            return None

    def quit(self, keep=False):
        """Browser.close, then the exit of this instance's own main pid (exact pid, never a pattern); then its
        profile folder goes, unless `keep`."""
        try:
            self._quit()
        finally:
            if not keep:
                drop_profile(self.root, self.profile)

    def _quit(self):
        pid, cdp = self.pid, self.cdp
        self.pid = self.cdp = None
        if cdp:
            try:
                cdp.send("Browser.close")
            except OSError:
                pass
        deadline = time.monotonic() + (20 if cdp else 0)  # no DevTools socket: nothing to wait for, stop it
        while pid and time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except OSError:
                break
            time.sleep(0.2)  # bench: waiting for the exit
        else:
            if pid:
                try:
                    os.kill(pid, 15)
                except OSError:
                    pass
        if cdp:
            cdp.close()


# ---------------------------------------------------------------- rows


class Ctx:
    def __init__(self, bundle, root, out, hz=None, min_hz=100.0, allow_locked=False):
        self.bundle = bundle
        self.root = root
        self.out = out
        self.hz = hz
        self.min_hz = min_hz
        self.allow_locked = allow_locked
        self.server = cp.Server()
        self.display, self.all_displays, self.refresh_ms = None, [], 1000.0 / 120
        self.version = chrome_version(bundle)
        self.templates = {}

    def use_display(self):
        """Reads the display list now: a virtual display comes and goes with the process that owns it."""
        self.display, self.all_displays = bench_display(self.hz, self.min_hz)
        self.refresh_ms = 1000.0 / self.display["hz"]
        return self.display

    def screen_fault(self):
        """Why frames on this host are not frames a person can see now, or None."""
        console = console_state()
        if console.get("locked") is None:
            return f"the console lock state is not known ({console.get('error')})"
        if console["locked"]:
            return "the console screen is locked (IOConsoleLocked): Chrome's presentation times are not frames on a screen"
        now = {d["id"]: d for d in displays()}
        if self.display is None or self.display["id"] not in now:
            return f"display {self.display and self.display['id']} went away"
        if now[self.display["id"]]["asleep"]:
            return f"display {self.display['id']} is asleep"
        return None

    def chrome(self):
        if self.display is None:
            self.use_display()
        return Chrome(self.bundle, self.root, self.server, self.display)

    def close(self):
        """Removes the launch row's template profiles."""
        for profile in self.templates.values():
            drop_profile(self.root, profile)
        self.templates = {}


def key_params(kind, letter):
    code = ord(letter.upper())
    params = {"type": kind, "key": letter, "code": "Key" + letter.upper(), "windowsVirtualKeyCode": code,
              "nativeVirtualKeyCode": code}
    if kind == "keyDown":
        params["text"] = letter
        params["unmodifiedText"] = letter
    return params


def type_keys(cdp, session, count, rng):
    """`count` key presses, 30 ms hold, 80-200 ms apart (chrome_parity.typing_steps). Returns the send stamps (ns)."""
    stamps, idents = [], []
    for i in range(count):
        letter = LETTERS[i % len(LETTERS)]
        down = cdp.send("Input.dispatchKeyEvent", key_params("keyDown", letter), session)
        stamps.append(cdp.sent[down])
        pause(0.030)
        up = cdp.send("Input.dispatchKeyEvent", key_params("keyUp", letter), session)
        idents += [down, up]
        pause(rng.randint(80, 200) / 1000)
    errors = cdp.drain(idents, timeout=20)
    return stamps, errors


def key_latency(trace, stamps, refresh_ms, pids, horizon_ms=300):
    """Per key send stamp: the KEY_PRESSED (else CHAR) EventLatency that began after it and before the next key."""
    every = [e for e in trace.event_latency() if e["pid"] in pids and e["type"] in ("KEY_PRESSED", "CHAR")]
    events = [e for e in every if e["presented"]]
    ends = {f["end"] for f in trace.frames() if f["presented"] and f["pid"] in pids}
    samples, send_ms, lost, missed, on_frame = [], [], 0, 0, 0
    for i, t in enumerate(stamps):
        end = stamps[i + 1] if i + 1 < len(stamps) else t + int(horizon_ms * 1e6)
        mine = [e for e in events if t <= e["begin"] < end]
        mine.sort(key=lambda e: (e["type"] != "KEY_PRESSED", e["begin"]))
        if not mine:
            lost += 1
            missed += cp.LOST_LATE
            continue
        hit = mine[0]
        on_frame += hit["end"] in ends
        ms = (hit["end"] - hit["begin"]) / 1e6
        samples.append(round(ms, 3))
        send_ms.append(round((hit["end"] - t) / 1e6, 3))
        missed += cp.late(ms, refresh_ms)
    return {"samples": samples, "send_ms": send_ms, "lost": lost, "missed": missed, "inputs": len(stamps),
            "refresh_ms_seen": median([e["vsync_ms"] for e in events if e["vsync_ms"]]),
            "key_events_tracked": len(every), "key_events_without_a_frame": len(every) - len(events),
            "samples_whose_end_is_a_presented_frame": on_frame}


def not_shown(shown, seen):
    return NotRun(f"the measured page was not shown (page visibility / window state before and after: {shown}); "
                  f"Chrome's trace for that time ({seen}) does not count")


def measure_keys(ctx, chrome, session, count, rng, read_typed):
    before = chrome.cdp.evaluate(session, read_typed)
    shown = [chrome.shown(session)]
    chrome.cdp.trace_start()
    try:
        mark = chrome.cdp.mark(session)
        stamps, errors = type_keys(chrome.cdp, session, count, rng)
        pause(0.4)
    finally:
        trace = chrome.cdp.trace_end()
    shown.append(chrome.shown(session))
    after = chrome.cdp.evaluate(session, read_typed)
    pid, how = trace.page_process(mark, ("KEY_", "CHAR"))
    result = key_latency(trace, stamps, ctx.refresh_ms, {pid})
    result.update({"typed": (after or 0) - (before or 0), "cdp_errors": errors, "trace_events": len(trace.events),
                   "shown_before_after": shown, "page_process": how,
                   "frames_by_process": trace.by_process(trace.frames())})
    if shown != [SHOWN, SHOWN]:
        raise not_shown(shown, f"{len(result['samples'])} key events with a frame, {result['typed']} characters typed")
    if result["typed"] == 0 and result["samples"]:
        raise NotRun(f"no key changed the page's text, but Chrome gave {len(result['samples'])} key events a frame: "
                     f"those frames are not the keys' result")
    if result["typed"] < count:
        result["note"] = f"only {result['typed']} of {count} keys reached the field"
    return result


def row_key_field(ctx, chrome, load, rng):
    target, session, info = chrome.setup(load, ctx.server.url("field"))
    chrome.cdp.evaluate(session, "document.getElementById('f').focus(); document.activeElement.id")
    result = measure_keys(ctx, chrome, session, 40, rng, FIELD_LEN)
    result["window"] = info
    return {"key-field": result}


XTERM_TYPED = "(()=>{const b=t.buffer.active;return b.cursorX + 1000*(b.baseY+b.cursorY)})()"


def row_key_terminal(ctx, chrome, load, rng):
    if not os.path.isfile(os.path.join(cp.XTERM_DIR, "lib/xterm.js")):
        raise NotRun(f"no xterm.js at {cp.XTERM_DIR} (bun install --frozen-lockfile in cmux-tui/frontends/web)")
    target, session, info = chrome.setup(load, ctx.server.url("xterm", lines="0"))
    chrome.cdp.evaluate(session, "t.focus(); 1")
    pause(0.5)
    result = measure_keys(ctx, chrome, session, 40, rng, XTERM_TYPED)
    result["window"] = info
    return {"key-terminal": result}


def wheel_bursts(cdp, session, x, y, bursts=20, per=60, hz=120, gap_ms=300, delta=120):
    """chrome_parity.wheel_bursts through DevTools: `per` wheel events at `hz`, up then down. 3 lines = 120 px."""
    spans, idents = [], []
    for i in range(bursts):
        dy = delta if i % 2 == 0 else -delta
        start = now_ns() + 2_000_000
        first = last = None
        for k in range(per):
            sleep_until(start + int(k * 1e9 / hz))
            ident = cdp.send("Input.dispatchMouseEvent", {"type": "mouseWheel", "x": x, "y": y, "deltaX": 0, "deltaY": dy},
                             session)
            last = cdp.sent[ident]
            first = first or last
            idents.append(ident)
        spans.append((first, last))
        pause(gap_ms / 1000)
    errors = cdp.drain(idents, timeout=30)
    return spans, errors


def measure_scroll(ctx, chrome, session, x, y, moved_js):
    chrome.cdp.evaluate(session, moved_js[0])
    shown = [chrome.shown(session)]
    chrome.cdp.trace_start()
    try:
        mark = chrome.cdp.mark(session)
        spans, errors = wheel_bursts(chrome.cdp, session, x, y)
        pause(0.4)
    finally:
        trace = chrome.cdp.trace_end()
    shown.append(chrome.shown(session))
    moved = chrome.cdp.evaluate(session, moved_js[1])
    pid, how = trace.page_process(mark, ("SCROLL", "MOUSE_WHEEL"))
    frames = [f for f in trace.frames() if f["pid"] == pid]
    times = presented_times(frames)
    intervals, missed, inside = pacing_of(times, spans, ctx.refresh_ms)
    in_span = [f for f in frames if any(a <= f["end"] <= b for a, b in spans)]
    scroll = [round((e["end"] - e["begin"]) / 1e6, 3) for e in trace.event_latency()
              if e["pid"] == pid and e["presented"] and "SCROLL_UPDATE" in e["type"]]
    by_process = trace.by_process(trace.frames())
    if shown != [SHOWN, SHOWN]:
        raise not_shown(shown, f"{inside} refreshes with a frame of the page in the wheel spans, {moved} scroll events "
                               f"in the page, frames by process {by_process}")
    if inside < 10 or not moved:
        raise NotRun(f"the input moved nothing on screen ({inside} refreshes with a frame of the measured page in the "
                     f"wheel spans, {moved} scroll events in the page, frames by process {by_process})")
    return {"samples": intervals, "missed": missed, "spans": len(spans), "frames": inside,
            "frames_chrome_calls_presented": sum(1 for f in in_span if f["presented"]),
            "shown_before_after": shown, "page_process": how, "frames_by_process": by_process,
            "chrome_dropped_smooth": sum(1 for f in in_span if f["dropped"] and f["smooth"]),
            "chrome_dropped": sum(1 for f in in_span if f["dropped"]),
            "scroll_event_latency": cp.stats(scroll), "scroll_events_seen": moved, "cdp_errors": errors,
            "refresh_ms_seen": grid_ms(intervals), "trace_events": len(trace.events)}


def row_scroll_page(ctx, chrome, load, rng):
    target, session, info = chrome.setup(load, ctx.server.url("long"))
    result = measure_scroll(ctx, chrome, session, 400, 300, SCROLL_COUNT)
    result["window"] = info
    return {"scroll-page": result}


def row_scroll_terminal(ctx, chrome, load, rng):
    if not os.path.isfile(os.path.join(cp.XTERM_DIR, "lib/xterm.js")):
        raise NotRun(f"no xterm.js at {cp.XTERM_DIR} (bun install --frozen-lockfile in cmux-tui/frontends/web)")
    target, session, info = chrome.setup(load, ctx.server.url("xterm", lines="50000"))
    pause(4)
    result = measure_scroll(ctx, chrome, session, 300, 250, ("window.__s=0;t.onScroll(()=>window.__s++);1", "window.__s"))
    result["window"] = info
    return {"scroll-terminal": result}


def first_presented(frames, pids, after_ns, horizon_ns, refresh_ms):
    """The first frame of `pids` presented after `after_ns` that can hold the command's result: its begin-frame time
    is not older than one refresh before the command (a compositor that wakes from idle gets the last vsync as its
    frame time, so the frame of a command can begin up to one refresh before it; an older frame was in flight)."""
    floor = after_ns - int(refresh_ms * 1e6)
    hits = [f for f in frames if f["presented"] and f["pid"] in pids and f["begin"] >= floor
            and after_ns < f["end"] <= after_ns + horizon_ns]
    return min(hits, key=lambda f: f["end"]) if hits else None


def quiet_before(frames, pids, t_ns, window_ms=100):
    """Presented frames of `pids` in the window before t: 0 means the first frame after t is the command's."""
    return sum(1 for f in frames if f["presented"] and f["pid"] in pids and t_ns - int(window_ms * 1e6) <= f["end"] <= t_ns)


def row_cmdt(ctx, chrome, load, rng):
    """New tab by Target.createTarget chrome://newtab/, 20 times (DevTools cannot press Cmd-T). Sample: the command's
    send stamp -> the first presented frame of the browser's own UI compositor (the tab strip and the new tab's
    ground) that began after it. `content_ms`: -> the first presented frame of the new tab's own renderer process.
    A command with frames of the UI compositor in the 100 ms before it is counted in `ui_busy_before`: its sample
    can be a frame the UI was to draw anyway (a tab's loading mark turns under `load`), so read `content_ms` then."""
    target, session, info = chrome.setup(load, ctx.server.url("color", bg="3050c0"))
    samples, content, lost, missed, busy = [], [], 0, 0, 0
    shown, by_process, how = [], {}, None
    for i in range(20):
        shown.append(chrome.shown(session))  # the page the new tab covers: in front again after each close
        chrome.cdp.trace_start()
        try:
            pause(0.3)
            ident = chrome.cdp.send("Target.createTarget", {"url": "chrome://newtab/"})
            t0 = chrome.cdp.sent[ident]
            new = chrome.cdp.wait(ident)["targetId"]
            pause(1.5)
            mark = None
            try:
                mark = chrome.cdp.mark(chrome.attach(new))  # after the timed part: only names the new tab's process
            except CDPError:
                pass
        finally:
            trace = chrome.cdp.trace_end()
        frames = trace.frames()
        by_process = trace.by_process(frames)
        busy += 1 if quiet_before(frames, {trace.browser}, t0) else 0
        ui = first_presented(frames, {trace.browser}, t0, int(1.5e9), ctx.refresh_ms)
        pid = trace.pid_of_mark(mark) if mark else None
        if pid is None:  # else: the one process with no frame before the command and frames after it
            fresh = {f["pid"] for f in frames if f["pid"] != trace.browser} - {f["pid"] for f in frames if f["begin"] < t0}
            pid, how = (fresh.pop(), "the one process whose first frame came after the command") if len(fresh) == 1 else (None, how)
        else:
            how = "performance.mark in the new tab"
        page = first_presented(frames, {pid}, t0, int(1.5e9), ctx.refresh_ms) if pid is not None else None
        if ui:
            ms = (ui["end"] - t0) / 1e6
            samples.append(round(ms, 3))
            missed += cp.late(ms, ctx.refresh_ms)
        else:
            lost += 1
            missed += cp.LOST_LATE
        if page:
            content.append(round((page["end"] - t0) / 1e6, 3))
        chrome.cdp.call("Target.closeTarget", {"targetId": new})
        chrome.cdp.call("Target.activateTarget", {"targetId": target})
        pause(1.0)
    shown.append(chrome.shown(session))
    if set(shown) != {SHOWN}:
        raise not_shown(sorted(set(shown)), f"{len(samples)} new tabs with a frame")
    return {"cmdt-first": {"samples": samples, "send_ms": samples, "content_ms": content, "content": cp.stats(content),
                           "lost": lost, "missed": missed, "inputs": 20, "window": info, "ui_busy_before": busy,
                           "new_tab_process": how, "shown_before_each": sorted(set(shown)),
                           "frames_by_process_last": by_process,
                           "note": "Target.createTarget chrome://newtab/, the Cmd-T key is not sent"}}


def row_tab_switch(ctx, chrome, load, rng):
    """Target.activateTarget between two colour pages, 20 times (DevTools cannot press Ctrl-Tab). Sample: Chrome's own
    `TabSwitching::Latency` span of that switch (the switch's start in the browser process -> the presentation of the
    first frame that holds the shown tab), only with RESULT_SUCCESS; a command with no such span is `lost`.
    `send_ms`: the bench's send stamp -> the same presentation."""
    a, session, info = chrome.setup(load, ctx.server.url("color", bg="c03030"))
    b = chrome.open(ctx.server.url("color", bg="3050c0"))
    pause(2)
    session_b = chrome.attach(b)
    shown = [chrome.shown(session_b)]  # b is in front now, and again after the last switch
    before = chrome.histogram("Browser.Tabs.TotalSwitchDuration3")
    stamps = []
    chrome.cdp.trace_start()
    try:
        for i in range(20):
            ident = chrome.cdp.send("Target.activateTarget", {"targetId": a if i % 2 == 0 else b})
            stamps.append(chrome.cdp.sent[ident])
            chrome.cdp.wait(ident)
            pause(0.5)
    finally:
        trace = chrome.cdp.trace_end()
    shown.append(chrome.shown(session_b))
    frames = trace.frames()
    by_process = trace.by_process(frames)
    if shown != [SHOWN, SHOWN]:
        raise not_shown(shown, f"frames by process {by_process}")
    ends = {f["end"] for f in frames if f["presented"]}
    switches = [(begin, end, str((args.get("tab_switch_measurement") or {}).get("result", "?")))
                for _pid, begin, end, args in trace.named("TabSwitching::Latency")]
    results = {}
    for _b, _e, result in switches:
        results[result] = results.get(result, 0) + 1
    samples, send_ms, lost, missed, on_frame = [], [], 0, 0, 0
    for i, t in enumerate(stamps):
        limit = stamps[i + 1] if i + 1 < len(stamps) else t + int(500e6)
        mine = [(begin, end) for begin, end, result in switches if t <= begin < limit and result == "RESULT_SUCCESS"]
        if not mine:
            lost += 1
            missed += cp.LOST_LATE
            continue
        begin, end = mine[0]
        ms = (end - begin) / 1e6
        samples.append(round(ms, 3))
        send_ms.append(round((end - t) / 1e6, 3))
        missed += cp.late(ms, ctx.refresh_ms)
        on_frame += end in ends
    after = chrome.histogram("Browser.Tabs.TotalSwitchDuration3")
    return {"tab-switch": {"samples": samples, "send_ms": send_ms, "lost": lost, "missed": missed,
                           "inputs": len(stamps), "window": info, "shown_before_after": shown,
                           "frames_by_process": by_process, "chrome_tab_switch_results": results,
                           "samples_whose_end_is_a_presented_frame": on_frame,
                           "uma_TotalSwitchDuration3": dict(hist_stats(hist_delta(before, after)),
                                                            unit="ms, upper bucket edge"),
                           "note": "Target.activateTarget, the Ctrl-Tab key is not sent"}}


def hist_delta(before, after):
    """Bucket counts of `after` less `before` (Browser.getHistogram replies): [[low, high, count], ...]."""
    old = {(b.get("low"), b.get("high")): b.get("count", 0) for b in (before or {}).get("buckets") or []}
    out = []
    for b in (after or {}).get("buckets") or []:
        n = b.get("count", 0) - old.get((b.get("low"), b.get("high")), 0)
        if n > 0:
            out.append([b.get("low"), b.get("high"), n])
    return out


def hist_stats(buckets, scale=1.0):
    """n and the upper bucket edge at p50 / p95 / p99 / max (so each number is "at most"), times `scale`."""
    n = sum(b[2] for b in buckets)
    if not n:
        return {"n": 0}
    out = {"n": n}
    for name, q in (("p50", 50), ("p95", 95), ("p99", 99), ("max", 100)):
        need, seen = max(1, -(-q * n // 100)), 0
        for low, high, count in sorted(buckets):
            seen += count
            if seen >= need:
                out[name + "_le"] = round(high * scale, 3)
                break
    return out


def row_window_resize(ctx, chrome, load, rng):
    """Browser.setWindowBounds steps at the display rate, 240 x 160 points in 1 s and back (not a mouse drag: the
    window server's live-resize path is not used). Frames: presented frames of the browser UI and of the page."""
    target, session, info = chrome.setup(load, ctx.server.url("long"))
    x, y, w, h = chrome.window
    hz = round(1000.0 / ctx.refresh_ms)
    steps = hz
    spans, idents = [], []
    shown = [chrome.shown(session)]
    chrome.cdp.trace_start()
    try:
        mark = chrome.cdp.mark(session, probe=True)
        for a, b in (((w, h), (w - 240, h - 160)), ((w - 240, h - 160), (w, h))):
            start = now_ns() + 2_000_000
            first = last = None
            for k in range(steps + 1):
                sleep_until(start + int(k * 1e9 / hz))
                f = k / steps
                ident = chrome.cdp.send("Browser.setWindowBounds", {"windowId": chrome.window_id, "bounds": {
                    "width": round(a[0] + (b[0] - a[0]) * f), "height": round(a[1] + (b[1] - a[1]) * f)}})
                last = chrome.cdp.sent[ident]
                first = first or last
                idents.append(ident)
            spans.append((first, last))
            pause(0.3)
        errors = chrome.cdp.drain(idents, timeout=30)
        pause(0.4)
    finally:
        trace = chrome.cdp.trace_end()
    shown.append(chrome.shown(session))
    frames = trace.frames()
    by_process = trace.by_process(frames)
    if shown != [SHOWN, SHOWN]:
        raise not_shown(shown, f"frames by process {by_process}")
    pid, how = trace.page_process(mark, ("KEY_RELEASED",))
    times = presented_times(frames, {pid, trace.browser})
    intervals, missed, inside = pacing_of(times, spans, ctx.refresh_ms)
    page_intervals, page_missed, page_inside = pacing_of(presented_times(frames, {pid}), spans, ctx.refresh_ms)
    ui_intervals, ui_missed, ui_inside = pacing_of(presented_times(frames, {trace.browser}), spans, ctx.refresh_ms)
    if page_inside < 10:
        raise NotRun(f"the input moved nothing on screen ({page_inside} refreshes with a frame of the measured page in "
                     f"the resize spans, frames by process {by_process})")
    return {"window-resize": {"samples": intervals, "missed": missed, "spans": len(spans), "frames": inside,
                              "page_only": dict(cp.stats(page_intervals), missed=page_missed, frames=page_inside),
                              "browser_ui_only": dict(cp.stats(ui_intervals), missed=ui_missed, frames=ui_inside),
                              "shown_before_after": shown, "page_process": how, "frames_by_process": by_process,
                              "cdp_errors": errors, "refresh_ms_seen": grid_ms(intervals), "window": info,
                              "note": "Browser.setWindowBounds steps, not a mouse drag; frames of the page's renderer "
                                      "and of the browser's own UI compositor"}}


FCP_JS = ("new Promise(done=>{const read=()=>{const p=performance.getEntriesByType('paint').find(e=>e.name=="
          "'first-contentful-paint');if(p)done({origin:performance.timeOrigin,fcp:p.startTime});else setTimeout(read,20)};"
          "read()})")


def make_template(ctx, load):
    """A profile whose session a relaunch restores: the launch page, and under load the load tabs."""
    chrome = ctx.chrome()
    profile = chrome.new_profile(f"template-{'load' if load else 'light'}")
    chrome.launch(profile)
    try:
        chrome.setup(load, ctx.server.url("field"))
        pause(5)
    finally:
        chrome.quit(keep=True)  # Ctx.close removes the template
    pause(3)
    return profile


def row_launch(ctx, chrome_unused, load, rng, launches=10):
    """`open` -> the launch page's first contentful paint (the paint timing entry is the frame's presentation time),
    on the wall clock: performance.timeOrigin + FCP - the time just before `open`. Cross-check: Chrome's own
    Startup.FirstWebContents.NonEmptyPaint3 (process start -> first non-empty paint)."""
    key = bool(load)
    if key not in ctx.templates:
        ctx.templates[key] = make_template(ctx, load)
    samples, uma, lost, missed = [], [], 0, 0
    info = None
    for i in range(launches):
        chrome = ctx.chrome()
        profile = chrome.new_profile("launch")
        shutil.rmtree(profile)
        subprocess.run(["cp", "-c", "-R", ctx.templates[key], profile], check=True, timeout=120)
        try:
            chrome.launch(profile, url=ctx.server.url("field"), restore=True)
            deadline = time.monotonic() + 20
            session = None
            while time.monotonic() < deadline and not session:
                for t in chrome.pages():  # the restored tab and the argv tab: the one in front paints
                    if not t.get("url", "").endswith("/p/field"):
                        continue
                    s = chrome.attach(t["targetId"])
                    if chrome.cdp.evaluate(s, "document.visibilityState") == "visible":
                        session = s
                        break
                if not session:
                    time.sleep(0.05)  # bench: waiting for the launch page's target
            if not session:
                raise NotRun("the launch page did not open in front")
            got = chrome.cdp.evaluate(session, FCP_JS, timeout=20)
            ms = got["origin"] + got["fcp"] - chrome.t_open_wall * 1000
            samples.append(round(ms, 2))
            missed += cp.late(ms, ctx.refresh_ms)
            hist = chrome.histogram("Startup.FirstWebContents.NonEmptyPaint3")
            if hist and hist.get("count"):
                uma.append(round(hist["sum"] / hist["count"], 1))
            if info is None:
                info = chrome.cdp.evaluate(session, "({sx:screenX,sy:screenY,sw:screen.width,sh:screen.height})")
        except (NotRun, CDPError, OSError) as error:
            lost += 1
            missed += cp.LOST_LATE
            log(f"launch {i}: lost: {error}")
        finally:
            chrome.quit()
            pause(2)
    return {"launch-first": {"samples": samples, "send_ms": samples, "lost": lost, "missed": missed, "inputs": launches,
                             "uma_NonEmptyPaint3_ms": uma, "uma_NonEmptyPaint3": cp.stats(uma), "window": info,
                             "note": "open -> first contentful paint of the restored launch page (wall clock); the "
                                     "window is where the saved session put it"}}


RUNNERS = {"key-field": row_key_field, "key-terminal": row_key_terminal, "scroll-page": row_scroll_page,
           "scroll-terminal": row_scroll_terminal, "cmdt-first": row_cmdt, "tab-switch": row_tab_switch,
           "window-resize": row_window_resize}


def stamp():
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def run_row(ctx, row, load, run_index=0, note=""):
    """One (row, load) run of the Chrome arm: launches a clean Chrome, measures, quits it. Returns the result dict.
    `status` is "measured" (the only one that may give a table number), "not run" (with `reason`) or "invalid"
    (numbers kept for a look under --allow-locked-screen, with `reason`). Importable: the caller holds the host's GUI
    lock (GuiLock) and interleaves this with the other arm."""
    base = {"arm": "chrome", "row": row, "load": load, "run": run_index, "method": METHOD, "chrome": ctx.version,
            "trace_categories": list(TRACE_CATEGORIES), "host": socket.gethostname().split(".")[0],
            "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
            "note": note, "at": stamp(), "load1_before": load1()}
    if row in NEEDS_OS_INPUT:
        return {**base, "status": "not run", "reason": f"{OS_INPUT_REASON}: {NEEDS_OS_INPUT[row]}"}
    if row not in ROWS:
        return {**base, "status": "not run", "reason": f"unknown row {row}"}
    rng = random.Random(f"{row}-{load}-{run_index}")
    chrome = None
    try:
        ctx.use_display()
        base.update({"display": ctx.display, "displays": ctx.all_displays, "refresh_ms": round(ctx.refresh_ms, 4)})
        fault = ctx.screen_fault()
        if fault and not ctx.allow_locked:
            raise NotRun(fault)
        if row == "launch-first":
            got = row_launch(ctx, None, load == "load", rng)
        else:
            chrome = ctx.chrome().launch(label=row)
            got = RUNNERS[row](ctx, chrome, load == "load", rng)
        result = got[row]
        result["stats"] = cp.stats(result["samples"])
        if result.get("send_ms"):
            result["send_stats"] = cp.stats(result["send_ms"])
        result["n"] = len(result["samples"])
        fault = fault or ctx.screen_fault()
        seen = result.get("refresh_ms_seen")
        if not fault and seen and abs(seen - ctx.refresh_ms) > 0.15 * ctx.refresh_ms:
            fault = f"Chrome presented on a {seen} ms grid, the bench display refreshes every {ctx.refresh_ms:.3f} ms"
        if not result["n"]:
            return {**base, "status": "not run", **result, "reason": "no sample: no input reached a presented frame",
                    "load1_after": load1()}
        if fault:
            return {**base, "status": "invalid", **result, "reason": fault, "load1_after": load1()}
        return {**base, "status": "measured", **result, "load1_after": load1()}
    except NotRun as error:
        return {**base, "status": "not run", "reason": str(error), "load1_after": load1()}
    except Exception as error:  # one run's failure is that run's "not run", never the bench's end
        return {**base, "status": "not run", "reason": f"{type(error).__name__}: {error}"[:400], "load1_after": load1()}
    finally:
        if chrome:
            chrome.quit()
            pause(2)


# ---------------------------------------------------------------- GUI lock (perf-lead FLEET.md: one GUI run per host)


class GuiLock:
    """~/perf-lead/gui.lock (mkdir = lock) for one GUI run. The lock is this process's only when its own mkdir made
    it: it never takes over or removes a lock that exists."""

    def __init__(self, path, enabled=True, wait_s=1800):
        self.path, self.enabled, self.wait_s = path, enabled, wait_s
        self.held = False

    def __enter__(self):
        if not self.enabled:
            return self
        deadline = time.monotonic() + self.wait_s
        while True:
            try:
                os.mkdir(self.path)
                break
            except FileExistsError:
                if time.monotonic() > deadline:
                    raise NotRun(f"gui.lock stayed taken for {self.wait_s} s")
                time.sleep(10)  # bench: waiting for the host's GUI lock
        self.held = True
        with open(os.path.join(self.path, "owner"), "w") as f:
            f.write(f"parity-films {time.strftime('%a %b %d %H:%M:%S UTC %Y', time.gmtime())} pid {os.getpid()} chrome arm\n")
        return self

    def __exit__(self, *_exc):
        if self.held:
            try:
                os.unlink(os.path.join(self.path, "owner"))
            except OSError:
                pass
            try:
                os.rmdir(self.path)
            except OSError:
                pass
            self.held = False
        return False


def write_result(out, result, tag=""):
    os.makedirs(out, exist_ok=True)
    name = f"{result['row']}-{result['load']}-{result['run']}{tag}.json"
    with open(os.path.join(out, name), "w") as f:
        json.dump(result, f, indent=1)
    brief = result.get("stats") or {}
    log(f"{result['row']} {result['load']} run {result['run']}: {result['status']} "
        f"{result.get('reason', '')} n={brief.get('n')} p50={brief.get('p50')} p95={brief.get('p95')} "
        f"p99={brief.get('p99')} max={brief.get('max')} lost={result.get('lost')} missed={result.get('missed')} "
        f"load {result.get('load1_before')}->{result.get('load1_after')}")


def context(args):
    real_home = os.path.expanduser("~" + (os.environ.get("USER") or ""))
    root = args.root or os.path.join(real_home, "perf-lead/parity-films/chrome-home")
    os.makedirs(root, exist_ok=True)
    if not os.path.isdir(args.chrome):
        raise SystemExit(f"no Google Chrome stable at {args.chrome} on this host (the bench installs nothing)")
    ctx = Ctx(args.chrome, root, os.path.abspath(args.out), args.hz, args.min_hz, args.allow_locked_screen)
    lock = os.path.join(real_home, "perf-lead/gui.lock")
    return ctx, lock


def screen_ready(ctx):
    """For the one-off commands: picks the display; a screen fault ends the command unless it is allowed."""
    ctx.use_display()
    fault = ctx.screen_fault()
    if fault and not ctx.allow_locked:
        raise NotRun(fault)
    return fault


def cmd_run(args):
    ctx, lock = context(args)
    rows = [r.strip() for r in args.rows.split(",") if r.strip()]
    loads = [x for x in args.loads.split(",") if x in ("light", "load")]
    log(f"chrome {ctx.version}; console {console_state()}; displays {displays()}")
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))
    try:
        run_all(ctx, lock, rows, loads, args)
    finally:
        ctx.close()


def run_all(ctx, lock, rows, loads, args):
    for run_index in range(args.runs):
        for row in rows:
            for load in loads:
                try:
                    if row not in ROWS:  # a row this method cannot do: its "not run" needs no screen and no lock
                        write_result(ctx.out, run_row(ctx, row, load, run_index, args.note))
                        continue
                    screen_ready(ctx)  # before the lock: a host with no usable screen is not made to wait for it
                    with GuiLock(lock, not args.no_lock):
                        result = run_row(ctx, row, load, run_index, args.note)
                except NotRun as error:  # no usable screen, or the lock stayed taken
                    result = {"arm": "chrome", "row": row, "load": load, "run": run_index, "status": "not run",
                              "reason": str(error), "chrome": ctx.version, "host": socket.gethostname().split(".")[0],
                              "console": console_state(), "displays": displays(), "note": args.note, "at": stamp(),
                              "load1_before": load1()}
                write_result(ctx.out, result)


RAF_JS = ("new Promise(done=>{const ts=[];const h=document.querySelector('h1');"
          "const f=t=>{ts.push(t);h.style.marginLeft=(60+ts.length%50)+'px';"
          "if(ts.length<360&&t-ts[0]<4000)requestAnimationFrame(f);else done(ts)};requestAnimationFrame(f)})")


def cmd_refresh(args):
    """What Chrome presents at on the bench display: a requestAnimationFrame loop of 360 frames on the colour page
    (the loop is a script the bench injects; it moves the heading each frame), the intervals between refreshes that
    hold a frame of that page (PipelineReporter) and between rAF calls."""
    ctx, lock = context(args)
    fault = screen_ready(ctx)
    with GuiLock(lock, not args.no_lock):
        before = load1()
        chrome = ctx.chrome().launch(label="refresh")
        try:
            target, session, info = chrome.setup(False, ctx.server.url("color", bg="204060"))
            shown = [chrome.shown(session)]
            chrome.cdp.trace_start()
            try:
                mark = chrome.cdp.mark(session, probe=True)
                raf = chrome.cdp.evaluate(session, RAF_JS, timeout=30)
            finally:
                trace = chrome.cdp.trace_end()
            shown.append(chrome.shown(session))
            pid, how = trace.page_process(mark, ("KEY_RELEASED",))
            frames = [f for f in trace.frames() if f["pid"] == pid]
            times = presented_times(frames)
            present = [round((b - a) / 1e6, 3) for a, b in zip(times, times[1:])]
            rafs = [round(b - a, 3) for a, b in zip(raf, raf[1:])]
            grid = [round(((t - times[0]) / 1e6) % ctx.refresh_ms, 2) for t in times[:200]] if times else []
            kinds = {}
            for f in frames:
                key = f"{f['state']} {f['kind'] or 'plain'}"
                kinds[key] = kinds.get(key, 0) + 1
            if shown != [SHOWN, SHOWN]:
                fault = fault or f"the page was not shown ({shown})"
            result = {"arm": "chrome", "row": "_refresh", "load": "light", "run": 0,
                      "status": "invalid" if fault else "measured", "chrome": ctx.version, "method": METHOD,
                      "host": socket.gethostname().split(".")[0], "console": console_state(),
                      "display": ctx.display, "displays": ctx.all_displays, "window": info, "shown_before_after": shown,
                      "page_process": how, "refreshes_with_a_frame": len(times), "interval_between_them_ms": cp.stats(present),
                      "refresh_ms_seen": grid_ms(present),
                      "frames_chrome_calls_presented": sum(1 for f in frames if f["presented"]),
                      "frames_by_state_and_kind": kinds, "frames_by_process": trace.by_process(trace.frames()),
                      "raf_interval_ms": cp.stats(rafs), "raf_frames": len(raf),
                      "presentation_phase_on_nominal_grid_ms": cp.stats(grid),
                      "samples": present, "stats": cp.stats(present), "load1_before": before, "load1_after": load1(),
                      "at": stamp()}
            if fault:
                result["reason"] = fault
        finally:
            chrome.quit()
    write_result(ctx.out, result)
    print(json.dumps({k: v for k, v in result.items() if k != "samples"}, indent=1))
    return 0 if result["status"] == "measured" else 1


def checked_keys(ctx, chrome, session, rng):
    try:
        got = measure_keys(ctx, chrome, session, 10, rng, FIELD_LEN)
    except NotRun as error:
        return {"status": "not run", "reason": str(error), "n": 0}
    keep = ("inputs", "typed", "lost", "shown_before_after", "key_events_tracked", "key_events_without_a_frame")
    return dict({k: got[k] for k in keep}, status="measured" if got["samples"] else "no sample", n=len(got["samples"]))


def checked_scroll(ctx, chrome, session):
    try:
        got = measure_scroll(ctx, chrome, session, 400, 300, SCROLL_COUNT)
    except NotRun as error:
        return {"status": "not run", "reason": str(error)}
    return {"status": "measured", "frames": got["frames"], "missed": got["missed"], "stats": cp.stats(got["samples"]),
            "shown_before_after": got["shown_before_after"]}


def cmd_selfcheck(args):
    """The honesty proofs, on this host and this Chrome. Exit 0 only when all hold:
    1. An input that changes nothing on screen gives no sample: keys with no field in focus are all `lost`.
    2. A page that is not shown gives no number: keys and wheel bursts to a tab behind another tab, and wheel bursts
       to a minimized window, are "not run". Each case first proves that the page was in fact hidden (the page's
       own visibilityState or the window state); a case that could not hide it is a failed check, not a pass."""
    ctx, lock = context(args)
    report = {"chrome": ctx.version, "at": stamp(), "host": socket.gethostname().split(".")[0]}
    rng = random.Random("selfcheck")
    report["screen_fault"] = screen_ready(ctx)
    report["console"], report["display"] = console_state(), ctx.display
    with GuiLock(lock, not args.no_lock):
        chrome = ctx.chrome().launch(label="selfcheck")
        try:
            target, session, info = chrome.setup(False, ctx.server.url("field"))
            chrome.cdp.evaluate(session, "document.getElementById('f').focus();1")
            report["keys_focused"] = checked_keys(ctx, chrome, session, rng)
            chrome.cdp.evaluate(session, "document.activeElement.blur();1")
            report["keys_field_blurred"] = checked_keys(ctx, chrome, session, rng)
            front = chrome.open(ctx.server.url("color", bg="c03030"))
            chrome.cdp.call("Target.activateTarget", {"targetId": front})
            pause(1.5)
            chrome.cdp.evaluate(session, "document.getElementById('f').focus();1")
            hidden = chrome.shown(session)
            report["keys_tab_hidden"] = dict(checked_keys(ctx, chrome, session, rng), state_when_hidden=hidden)
        finally:
            chrome.quit()
            pause(2)
        for label, hide in (("scroll_shown", None), ("scroll_tab_hidden", "tab"), ("scroll_window_minimized", "min")):
            chrome = ctx.chrome().launch(label="selfcheck")
            try:
                target, session, info = chrome.setup(False, ctx.server.url("long"))
                if hide == "tab":
                    front = chrome.open(ctx.server.url("color", bg="c03030"))
                    chrome.cdp.call("Target.activateTarget", {"targetId": front})
                    pause(1.5)
                elif hide == "min":
                    chrome.cdp.call("Browser.setWindowBounds", {"windowId": chrome.window_id,
                                                                "bounds": {"windowState": "minimized"}})
                    pause(2.5)
                hidden = chrome.shown(session)
                report[label] = dict(checked_scroll(ctx, chrome, session), state_when_hidden=hidden if hide else None)
            finally:
                chrome.quit()
                pause(2)
        report["screen_fault_at_end"] = ctx.screen_fault()

    def refused(case):  # the page was in fact hidden, and the bench gave no number
        return report[case]["state_when_hidden"] != SHOWN and report[case]["status"] == "not run"

    checks = {
        "no screen fault": not report["screen_fault"] and not report["screen_fault_at_end"],
        "keys into a focused field give samples": report["keys_focused"]["n"] >= 8,
        "keys with no field in focus give no sample": (report["keys_field_blurred"]["n"] == 0
                                                       and report["keys_field_blurred"].get("lost") == 10),
        "keys to a hidden tab give no number": refused("keys_tab_hidden"),
        "scroll on a shown page is measured": report["scroll_shown"]["status"] == "measured",
        "scroll in a hidden tab gives no number": refused("scroll_tab_hidden"),
        "scroll in a minimized window gives no number": refused("scroll_window_minimized"),
    }
    report["checks"], report["ok"] = checks, all(checks.values())
    os.makedirs(ctx.out, exist_ok=True)
    with open(os.path.join(ctx.out, "selfcheck.json"), "w") as f:
        json.dump(report, f, indent=1)
    print("SELFCHECK " + json.dumps(report, indent=1))
    return 0 if report["ok"] else 1


def cmd_explore(args):
    ctx, lock = context(args)
    rng = random.Random("explore")
    screen_ready(ctx)
    with GuiLock(lock, not args.no_lock):
        chrome = ctx.chrome().launch(label="explore")
        try:
            log(f"launched pid {chrome.pid} port {chrome.port} product {chrome.product}")
            target, session, info = chrome.setup(False, ctx.server.url("field"))
            log(f"window {info}")
            chrome.cdp.evaluate(session, "document.getElementById('f').focus();1")
            chrome.cdp.trace_start()
            stamps, errors = type_keys(chrome.cdp, session, 6, rng)
            other = chrome.open(ctx.server.url("long"))
            pause(1.5)
            s2 = chrome.attach(other)
            spans, _ = wheel_bursts(chrome.cdp, s2, 400, 300, bursts=2, per=30)
            chrome.cdp.call("Target.activateTarget", {"targetId": target})
            pause(0.7)
            trace = chrome.cdp.trace_end()
            os.makedirs(ctx.out, exist_ok=True)
            with open(os.path.join(ctx.out, "explore-trace.json"), "w") as f:
                json.dump(trace.events, f)
            with open(os.path.join(ctx.out, "explore-names.json"), "w") as f:
                json.dump(trace.summary(), f, indent=1)
            hists = {}
            for query in ("EventLatency", "Graphics.Smoothness", "Browser.Tabs.TotalSwitchDuration", "Startup.FirstWebContents",
                          "Browser.MainThreadsCongestion", "Event.Latency.ScrollUpdate"):
                try:
                    got = chrome.cdp.call("Browser.getHistograms", {"query": query}).get("histograms") or []
                except CDPError as error:
                    got = [{"name": f"error {error}"}]
                hists[query] = {h.get("name"): [h.get("count"), h.get("sum")] for h in got}
            with open(os.path.join(ctx.out, "explore-histograms.json"), "w") as f:
                json.dump(hists, f, indent=1)
            lat = trace.event_latency()
            frames = trace.frames()
            print(json.dumps({"events": len(trace.events), "process_names": trace.names,
                              "histograms": {q: len(v) for q, v in hists.items()},

                              "event_latency_types": sorted({e["type"] for e in lat}), "event_latency": len(lat),
                              "frames": len(frames), "states": sorted({f["state"] for f in frames}),
                              "key_latency": key_latency(trace, stamps, ctx.refresh_ms, trace.renderers),
                              "stamp0_vs_first_begin_ms": (min((e["begin"] for e in lat), default=0) - stamps[0]) / 1e6,
                              "top_names": list(trace.summary().items())[:40]}, indent=1))
        finally:
            chrome.quit()


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("run", "selfcheck", "refresh", "explore"):
        p = sub.add_parser(name)
        p.add_argument("--out", required=True)
        p.add_argument("--chrome", default=CHROME_DEFAULT)
        p.add_argument("--root", help="where the clean profiles go (default ~/perf-lead/parity-films/chrome-home)")
        p.add_argument("--hz", type=float, help="pick the display nearest this rate (default: the fastest display)")
        p.add_argument("--no-lock", action="store_true", help="the caller already holds ~/perf-lead/gui.lock")
        p.add_argument("--note", default="")
        p.add_argument("--min-hz", type=float, default=100.0, help="no display at this rate or more = not run")
        p.add_argument("--allow-locked-screen", action="store_true",
                       help="run with a locked console screen too; every result is then `invalid`, never a number")
        p.add_argument("--trace-categories", help="comma list instead of the default (to compare the trace's cost)")
        if name == "run":
            p.add_argument("--rows", default=",".join(ROWS))
            p.add_argument("--loads", default="light,load")
            p.add_argument("--runs", type=int, default=2)
    args = parser.parse_args()
    if args.trace_categories:
        TRACE_CATEGORIES[:] = [c for c in args.trace_categories.split(",") if c]
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(143))  # a stop runs the exits: Chrome quits, the lock goes
    try:
        return {"run": cmd_run, "selfcheck": cmd_selfcheck, "refresh": cmd_refresh, "explore": cmd_explore}[args.cmd](args)
    except NotRun as error:
        print(f"NOT RUN: {error}", flush=True)
        return 2


if __name__ == "__main__":
    sys.exit(main() or 0)
