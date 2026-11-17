#!/usr/bin/env python3
"""CHROME PARITY BENCH (cmux-ad m91, 2026-11-10): cmux NEXT against Google Chrome stable, the same Mac, the same
display at 120 Hz, light and under load, for every interaction the person feels. Lawrence: "i want us to match
chrome's smoothness, throughout the entire app, don't stop until it's to chrome's quality".

This is a bench tool, never a CI gate, job, step or perf-gate row (CLAUDE.md). The fleet entry is
scripts/measure/perf-bench.sh suite=parity (README "Chrome parity"). Run it only on a quiet fleet mini, never on a
person's Mac.

  chrome_parity.py run --cmux CMUX.app --out DIR [--chrome "/Applications/Google Chrome.app"] [--rounds 2]
                       [--rows key-field,...] [--loads light,load] [--vdisplay 120x1] [--max-load 2]
                       [--geometry FILE.json]
  chrome_parity.py report --out DIR [--md PARITY.md] [--json parity.json]
  chrome_parity.py rows                          the rows, their mapping and their method

Method (one method for both apps):
  - Input: real HID events from scripts/journeys/hid_inject.swift (CGEventPost at the HID tap at mach deadlines,
    each event stamped on CLOCK_UPTIME_RAW). No socket call, DevTools call or injected NSEvent in a timed span.
  - Frames: framewatch.swift, a ScreenCaptureKit stream of the measured rectangle of the main display at up to
    240 frames/s (cursor hidden), each frame's displayTime on the same clock, and the box of pixels that changed.
    The same capture runs for both apps, so its cost is the same in both arms.
  - Set-up only (outside the timed span): cmux through its control socket (action.run), Chrome through the DevTools
    HTTP endpoints (/json/new); markers (12 x 12 squares of #ff00ff and #00ffff that the bench pages and terminals
    draw) give the measured rectangles on screen.
  - Display: the main display must run at --hz (default 120, measured by vdisplay120.m's check: link interval within
    0.35 ms); --vdisplay 120x1 makes the lease's own virtual display first. Else every row is "not run".
  - Quiet host: before each arm the 1-minute load must fall under --max-load (2), else that arm's run is not run.
  - Arms interleave: each round runs cmux then Chrome, the next round Chrome then cmux, per row and load.
  - Light = the app with the measured surface only. Load: cmux = 5 terminals streaming a line every 20 ms (the
    agents) in another workspace + the CPU page (2 busy web workers) in a background tab of the measured pane;
    Chrome = the same CPU page in a background tab + 5 background tabs streaming a line every 20 ms (fetch stream).
  - Latency rows: for each input event, input stamp -> displayTime of the first frame that shows the response (a
    change of the expected size in the measured rectangle) before the next input. Late refreshes per event =
    max(0, ceil(latency / refresh) - 2): refreshes past the second one after the input. An input with no response
    frame is "lost" and counts 10 late refreshes.
  - Pacing rows (scroll, resize, drag): within each input span, the intervals between frames that changed; an
    interval over 1.5 refreshes misses round(interval / refresh) - 1 refreshes.
  - Each row: p50/p95/p99/max over every sample of every round (n >= 20), the missed refreshes summed, and each
    arm's per-round p95 range (its own spread). Verdict PASS when cmux p95 <= Chrome p95 AND cmux missed <= Chrome
    missed; FAIL otherwise; "not run" when an arm has no samples.
"""
from __future__ import annotations

import argparse
import hashlib
import http.server
import json
import math
import os
import random
import re
import shutil
import socketserver
import subprocess
import sys
import threading
import time
import urllib.parse

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.abspath(os.path.join(HERE, "..", ".."))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "cmux-next"))

import procs  # noqa: E402
import xbench  # noqa: E402

CHROME_DEFAULT = "/Applications/Google Chrome.app"
XTERM_DIR = os.path.join(REPO, "cmux-tui/frontends/web/node_modules/@xterm/xterm")
TL, TR = "ff00ff", "00ffff"
WINDOW = (40, 80, 1280, 800)   # both apps' window (Chrome's --window-position/--window-size; cmux by setframe)
MAX_PIXELS = 320_000           # framewatch output size cap: factor = min(1, sqrt(MAX_PIXELS / points))
LOST_LATE = 10                 # late refreshes an input with no response frame counts

# Screen positions that no marker gives, relative to the window's top-left (points). A run on a new app version
# whose layout moved overrides them with --geometry FILE.json ({"name": [dx, dy], ...}); a probe that hits nothing
# is "not run" (fewer than half of the inputs got a response), never a pass.
GEOMETRY = {
    "chrome_tab_a": [200, 20], "chrome_tab_b": [670, 20],        # Chrome 15x tab strip, tabs 1 and 3 of 6
    "cmux_sidebar_a": [100, 104], "cmux_sidebar_b": [100, 196],  # cmux sidebar workspace rows 1 and 3
    "cmux_tab_a": [60, -16], "cmux_tab_b": [220, -16],           # cmux pane tab bar, from the page marker
}

# key codes (US layout)
K = {"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "x": 7, "i": 34, "j": 38, "k": 40, "l": 37, "p": 35, "t": 17,
     "u": 32, "w": 13, "tab": 48, "esc": 53, "delete": 51}
LETTERS = ["a", "s", "d", "f", "g", "h", "j", "k", "l"]

ROWS = {
    # row id: (metric, kind, cmux surface, Chrome surface)
    "key-field": ("1 key -> frame, text field", "latency", "a cmux Chromium tab, <input> on a local page",
                  "Chrome tab, the same page"),
    "key-native": ("1 key -> frame, native field", "latency", "command palette field (Cmd-Shift-P)",
                   "Chrome omnibox (Cmd-L)"),
    "key-terminal": ("1 key -> frame, terminal", "latency", "cmux terminal at the shell prompt (PTY echo)",
                     "xterm.js 6 page (repo's cmux-tui/frontends/web copy), local echo, no PTY"),
    "scroll-page": ("2 scroll, long page", "pacing", "cmux Chromium tab, 4000 paragraphs, wheel bursts",
                    "Chrome tab, the same page"),
    "scroll-terminal": ("2 scroll, 50k-line terminal", "pacing", "cmux terminal scrollback, 50k lines, wheel bursts",
                        "xterm.js page, 50k lines of scrollback"),
    "cmdt-first": ("3 Cmd-T -> first frame", "latency", "Cmd-T in a browser pane: the new tab's first frame",
                   "Cmd-T: the New Tab page's first frame"),
    "cmdt-interactive": ("3 Cmd-T -> interactive", "latency", "keys every 50 ms after Cmd-T: the first of 3 keys "
                         "in a row that show", "the same in Chrome's omnibox"),
    "tab-switch": ("4 tab switch", "latency", "Ctrl-Tab between 2 page tabs of one pane", "Ctrl-Tab, 2 tabs"),
    "window-resize": ("5 window resize", "pacing", "drag of the window's corner", "drag of the window's corner"),
    "pane-resize": ("5 split resize", "pacing", "drag of the divider between a page pane and a terminal pane",
                    "drag of the DevTools dock divider (DevTools docked)"),
    "hover-sidebar": ("6 sidebar hover", "latency", "pointer jumps between sidebar workspace rows",
                      "pointer jumps between tab strip tabs"),
    "hover-tabs": ("6 tab strip hover", "latency", "pointer jumps between pane tab bar tabs",
                   "pointer jumps between tab strip tabs"),
    "drag-sidebar": ("6 sidebar drag", "pacing", "drag of a sidebar workspace row", "drag of a tab in the strip"),
    "drag-tabs": ("6 tab strip drag", "pacing", "drag of a pane tab bar tab", "drag of a tab in the strip"),
    "launch-first": ("7 launch -> first frame", "latency", "open -> first frame of the window",
                     "open -> first frame of the window"),
    "launch-interactive": ("7 launch -> interactive", "latency", "open -> the first of 3 keys in a row (every 50 ms) "
                           "that show in the restored terminal", "the same in the launch page's <input>"),
}
SCENARIOS = {"cmdt": ("cmdt-first", "cmdt-interactive"), "launch": ("launch-first", "launch-interactive")}

STREAM_CMD = ("while :; do printf 'agent %05d streaming output: the quick brown fox jumps over the lazy dog 0123456789\\n' "
              "$RANDOM; sleep 0.02; done")


class NotRun(Exception):
    pass


def log(message):
    print(f"[parity {time.strftime('%H:%M:%S')}] {message}", flush=True)


def now_ns():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


def pause(seconds):
    time.sleep(seconds)  # bench: a deliberate settle outside every timed span


# ---------------------------------------------------------------- pages


def marker_css(tl=True, tr=False):
    css = "<style>.m{position:fixed;width:12px;height:12px;top:0;z-index:9}</style>"
    if tl:
        css += f"<div class=m style='left:0;background:#{TL}'></div>"
    if tr:
        css += f"<div class=m style='right:0;background:#{TR}'></div>"
    return css


def page(kind, q):
    tr = q.get("tr") == "1"
    head = "<!doctype html><meta charset=utf-8><title>parity</title><body style='margin:0;font:16px -apple-system'>"
    if kind == "field":
        return (head + marker_css(True, tr) + "<input id=f autofocus style='position:absolute;left:24px;top:24px;"
                "width:600px;height:36px;font:16px -apple-system;caret-color:transparent' value=''>")
    if kind == "long":
        p = "cmux parity bench: a long page to scroll, plain text laid out and painted like any article. " * 3
        body = "".join(f"<p style='margin:12px 24px'>{i}. {p}</p>" for i in range(4000))
        return (head + marker_css(True, tr) + body +
                "<script>addEventListener('load',()=>scrollTo(0,document.body.scrollHeight/2))</script>")
    if kind == "color":
        bg = re.sub(r"[^0-9a-f]", "", q.get("bg", "c03030"))[:6]
        return head.replace("margin:0", f"margin:0;background:#{bg}") + marker_css(True, tr) + "<h1 style='margin:60px'>" + bg + "</h1>"
    if kind == "cpu":
        return (head + "<h1>CPU page: 2 busy workers</h1><script>for(let i=0;i<2;i++)new Worker(URL.createObjectURL("
                "new Blob(['for(;;){Math.sqrt(Math.random())}'])))</script>")
    if kind == "stream":
        return (head + "<pre id=o></pre><script>(async()=>{const o=document.getElementById('o');"
                "const r=(await fetch('/lines')).body.getReader();const d=new TextDecoder();"
                "for(;;){const {value,done}=await r.read();if(done)break;o.append(d.decode(value));"
                "while(o.childNodes.length>500)o.firstChild.remove()}})()</script>")
    if kind == "xterm":
        lines = max(0, min(100_000, int(q.get("lines", "0") or 0)))
        return (head + marker_css(True, False) +
                "<link rel=stylesheet href=/xterm/css/xterm.css><script src=/xterm/lib/xterm.js></script>"
                "<div id=t style='position:absolute;left:0;top:16px;right:0;bottom:0'></div><script>"
                f"const t=new Terminal({{fontSize:13,cursorBlink:false,scrollback:{lines + 2000}}});"
                "t.open(document.getElementById('t'));t.focus();"
                f"let s='';for(let i=1;i<={lines};i++){{s+='row '+String(i).padStart(6,'0')+' the quick brown fox jumps "
                "over the lazy dog 0123456789 abcdefghij\\r\\n';if(s.length>65536){t.write(s);s=''}}"
                "t.write(s+'$ ');t.onData(d=>t.write(d==='\\r'?'\\r\\n$ ':d))</script>")
    return None


class Server:
    def __init__(self):
        outer = self

        class Handler(http.server.BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def do_GET(self):  # noqa: N802
                url = urllib.parse.urlparse(self.path)
                q = dict(urllib.parse.parse_qsl(url.query))
                if url.path == "/lines":
                    return outer.lines(self)
                if url.path.startswith("/xterm/"):
                    rel = os.path.normpath(url.path[len("/xterm/"):])
                    path = os.path.join(XTERM_DIR, rel)
                    if rel.startswith("..") or not os.path.isfile(path):
                        return self.reply(404, b"no", "text/plain")
                    kind = "text/css" if path.endswith(".css") else "text/javascript"
                    return self.reply(200, open(path, "rb").read(), kind)
                body = page(url.path.strip("/").removeprefix("p/"), q)
                if body is None:
                    return self.reply(404, b"no", "text/plain")
                self.reply(200, body.encode(), "text/html")

            def reply(self, code, body, kind):
                self.send_response(code)
                self.send_header("Content-Type", kind)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *_args):
                pass

        class Threaded(socketserver.ThreadingMixIn, http.server.HTTPServer):
            daemon_threads = True

        self.httpd = Threaded(("127.0.0.1", 0), Handler)
        self.port = self.httpd.server_address[1]
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    @staticmethod
    def lines(handler):
        handler.send_response(200)
        handler.send_header("Content-Type", "text/plain")
        handler.send_header("Transfer-Encoding", "chunked")
        handler.end_headers()
        i = 0
        try:
            while True:
                line = f"agent {i:06d} streaming output: the quick brown fox jumps over the lazy dog 0123456789\n".encode()
                handler.wfile.write(f"{len(line):x}\r\n".encode() + line + b"\r\n")
                handler.wfile.flush()
                i += 1
                time.sleep(0.02)  # bench: the stream's pace, a line every 20 ms
        except OSError:
            pass

    def url(self, kind, **q):
        return f"http://127.0.0.1:{self.port}/p/{kind}" + ("?" + urllib.parse.urlencode(q) if q else "")


# ---------------------------------------------------------------- tools


class Tools:
    def __init__(self, cache):
        os.makedirs(cache, exist_ok=True)
        self.cache = cache
        self.helper = xbench.Helper(cache)
        self.hid = self.swift(os.path.join(REPO, "scripts/journeys/hid_inject.swift"), "hid_inject", [])
        self.fw = self.swift(os.path.join(HERE, "framewatch.swift"), "framewatch", ["-parse-as-library"])
        self.vd = self.vdisplay_app()

    def swift(self, source, name, flags):
        digest = hashlib.sha256(open(source, "rb").read()).hexdigest()[:16]
        path = os.path.join(self.cache, f"{name}-{digest}")
        if not os.path.exists(path):
            subprocess.run(["xcrun", "swiftc", "-O", *flags, "-o", path + ".tmp", source], check=True, timeout=900)
            os.replace(path + ".tmp", path)
        return path

    def vdisplay_app(self):
        source = os.path.join(REPO, "scripts/journeys/vdisplay120.m")
        digest = hashlib.sha256(open(source, "rb").read()).hexdigest()[:16]
        app = os.path.join(self.cache, f"VD-{digest}.app")
        exe = os.path.join(app, "Contents/MacOS/VD")
        if not os.path.exists(exe):
            os.makedirs(os.path.dirname(exe), exist_ok=True)
            subprocess.run(["xcrun", "clang", "-fobjc-arc", "-O2", "-Wno-deprecated-declarations", "-framework", "AppKit",
                            "-framework", "CoreVideo", source, "-o", exe], check=True, timeout=300)
            with open(os.path.join(app, "Contents/Info.plist"), "w") as f:
                f.write('<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>CFBundleExecutable</key>'
                        '<string>VD</string><key>CFBundleIdentifier</key><string>ai.manaflow.parity.vdisplay</string>'
                        '<key>CFBundlePackageType</key><string>APPL</string><key>LSUIElement</key><true/></dict></plist>')
            subprocess.run(["codesign", "-s", "-", "--force", app], capture_output=True)
        return app

    # display ------------------------------------------------------------------
    def display(self):
        out = subprocess.run([os.path.join(self.vd, "Contents/MacOS/VD"), "check"], capture_output=True, text=True,
                             timeout=30).stdout
        m = re.search(r"main (\d+) mode (\d+)x(\d+) pixels (\d+)x(\d+) refresh (\d+\.\d+) interval (\d+\.\d+) displays (\d+)", out)
        if not m:
            return {"raw": out.strip()[-300:]}
        return {"main": int(m.group(1)), "points": [int(m.group(2)), int(m.group(3))],
                "pixels": [int(m.group(4)), int(m.group(5))], "refresh": float(m.group(6)),
                "interval_ms": float(m.group(7)), "displays": int(m.group(8))}

    def start_vdisplay(self, hz, scale, work):
        out = os.path.join(work, "vd.out")
        subprocess.run(["open", "--stdout", out, "--stderr", os.path.join(work, "vd.err"), self.vd, "--args",
                        str(hz), str(scale), "0", "0", "21600"], check=True, timeout=60)
        for _ in range(25):
            text = open(out).read() if os.path.exists(out) else ""
            if text.startswith(("ready", "error")):
                break
            pause(1)
        pause(1)

    # input and frames ----------------------------------------------------------
    def inject(self, steps, work, name, start_delay_ms=150):
        script = os.path.join(work, f"{name}.hid.json")
        logp = os.path.join(work, f"{name}.hidlog.json")
        with open(script, "w") as f:
            json.dump({"start_delay_ms": start_delay_ms, "rate_floor": 0.9, "steps": steps}, f)
        code = subprocess.run([self.hid, "run", script, logp], capture_output=True, text=True, timeout=900)
        if code.returncode == 3:
            raise NotRun("hid_inject has no PostEvent (Accessibility) grant")
        if code.returncode not in (0, 4):
            raise NotRun(f"hid_inject exit {code.returncode}: {code.stderr.strip()[:200]}")
        data = json.load(open(logp))
        data["rate_ok"] = code.returncode == 0
        return data

    def watch(self, rect, work, name):
        return Watch(self.fw, rect, os.path.join(work, f"{name}.frames.jsonl"))

    def locate(self, color):
        out = subprocess.run([self.fw, "locate", color], capture_output=True, text=True, timeout=60)
        if out.returncode == 3:
            raise NotRun("framewatch has no Screen Recording grant")
        if out.returncode != 0:
            return None
        x, y, w, h = map(int, out.stdout.split())
        return [x, y, w, h]

    def snap(self, rect, path):
        out = subprocess.run([self.fw, "snap", *map(str, rect), "1", path], capture_output=True, text=True, timeout=60)
        if out.returncode != 0:
            raise NotRun(f"framewatch snap: {out.stderr.strip()[:200]}")
        return tuple(map(int, out.stdout.split()))

    def diffbox(self, a, b, size):
        out = subprocess.run([self.fw, "diffbox", a, b, str(size[0]), str(size[1])], capture_output=True, text=True,
                             timeout=60)
        return list(map(int, out.stdout.split()))[:4] if out.returncode == 0 else None

    def windows(self, pid):
        out = self.helper.run("windows", str(pid)).stdout
        wins = [json.loads(line) for line in out.splitlines() if line.strip().startswith("{")]
        wins = [w for w in wins if w.get("layer") == 0 and w["w"] >= 300]
        return max(wins, key=lambda w: w["w"] * w["h"]) if wins else None


def factor_for(rect):
    return round(min(1.0, math.sqrt(MAX_PIXELS / max(1.0, rect[2] * rect[3]))), 3)


class Watch:
    """framewatch over one rectangle: start (waits for its first frame), stop, frames."""

    def __init__(self, exe, rect, path):
        self.rect = [int(v) for v in rect]
        self.factor = factor_for(self.rect)
        self.path = path
        self.proc = subprocess.Popen([exe, "watch", *map(str, self.rect), str(self.factor), "900", path],
                                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        line = self.proc.stdout.readline().strip()
        if line != "READY":
            err = self.proc.stderr.read() if self.proc.poll() is not None else ""
            self.proc.kill()
            if self.proc.returncode == 3 or "Screen Recording" in err:
                raise NotRun("framewatch has no Screen Recording grant")
            raise NotRun(f"framewatch gave no first frame ({line or err.strip()[:200]})")

    def stop(self):
        try:
            self.proc.stdin.write("stop\n")
            self.proc.stdin.close()
        except OSError:
            pass
        self.proc.wait(timeout=60)
        frames, summary = [], {}
        for line in open(self.path):
            d = json.loads(line)
            if "summary" in d:
                summary = d["summary"]
            elif d.get("s") == "complete":
                frames.append(d)
        return frames, summary

    def width_pt(self, frame):
        b = frame.get("b")
        return (b[2] - b[0]) / self.factor if b else 0.0

    def area_share(self, frame):
        return max(0, frame.get("n", 0)) / max(1.0, self.rect[2] * self.rect[3] * self.factor ** 2)


# ---------------------------------------------------------------- analysis


def pct(values, q):
    v = sorted(values)
    return v[min(len(v) - 1, max(0, math.ceil(q / 100 * len(v)) - 1))] if v else None


def stats(values):
    if not values:
        return {"n": 0}
    return {"n": len(values), "p50": round(pct(values, 50), 2), "p95": round(pct(values, 95), 2),
            "p99": round(pct(values, 99), 2), "max": round(max(values), 2)}


def late(latency_ms, refresh_ms):
    return max(0, math.ceil(latency_ms / refresh_ms - 1e-6) - 2)


def latencies(inputs, frames, ok, horizon_ns, refresh_ms):
    """Per input time: ms to the first frame after it (before the next input) that ok(frame) accepts."""
    out, lost, missed = [], 0, 0
    for i, t in enumerate(inputs):
        end = inputs[i + 1] if i + 1 < len(inputs) else t + horizon_ns
        hit = next((f for f in frames if t < f["t"] <= end and ok(f)), None)
        if hit is None:
            lost += 1
            missed += LOST_LATE
            continue
        ms = (hit["t"] - t) / 1e6
        out.append(ms)
        missed += late(ms, refresh_ms)
    return out, lost, missed


def pacing(frames, spans, refresh_ms):
    """Intervals (ms) between changed frames inside each span (start_ns, end_ns), the refreshes they missed, and the
    frozen spans: an input span in which the window gave fewer than 2 changed frames has no interval at all, so it
    counts every refresh of the span as missed (a frozen window must never read as 0 missed)."""
    intervals, missed, frozen = [], 0, 0
    for start, end in spans:
        times = [f["t"] for f in frames if start <= f["t"] <= end and f.get("n", 0) > 0]
        if len(times) < 2:
            frozen += 1
            missed += max(1, round((end - start) / 1e6 / refresh_ms))
            continue
        for a, b in zip(times, times[1:]):
            ms = (b - a) / 1e6
            intervals.append(ms)
            if ms > 1.5 * refresh_ms:
                missed += round(ms / refresh_ms) - 1
    return intervals, missed, frozen


def ready_time(keys, frames, t0, ok, refresh_ms, run=3):
    """ms from t0 to the first frame of `run` keys in a row that each show within 3 refreshes."""
    streak = []
    for i, t in enumerate(keys):
        end = min(t + int(3 * refresh_ms * 1e6), keys[i + 1] if i + 1 < len(keys) else t + int(3 * refresh_ms * 1e6))
        hit = next((f for f in frames if t < f["t"] <= end and ok(f)), None)
        streak = streak + [hit] if hit else []
        if len(streak) >= run:
            return (streak[0]["t"] - t0) / 1e6
    return None


def times_of(hidlog, kind):
    return [e[0] for e in hidlog["events"] if e[1] == kind]


def spans_of(hidlog, kind, tail_ms=0, gap_ms=100):
    """Groups events of `kind` into spans split at gaps over gap_ms; each span ends tail_ms after its last event."""
    spans, cur = [], []
    for t in times_of(hidlog, kind):
        if cur and t - cur[-1] > gap_ms * 1e6:
            spans.append((cur[0], cur[-1] + int(tail_ms * 1e6)))
            cur = []
        cur.append(t)
    if cur:
        spans.append((cur[0], cur[-1] + int(tail_ms * 1e6)))
    return spans


# ---------------------------------------------------------------- the two apps


class Arm:
    name = "?"

    def __init__(self, bundle, tools, server, profiles):
        self.bundle = os.path.abspath(bundle)
        self.tools = tools
        self.server = server
        self.profiles = profiles
        self.pid = None
        self.instance = None

    def profile(self, label):
        path = os.path.join(self.profiles, f"{self.name}-{label}-{time.time_ns()}")
        os.makedirs(path)
        return path

    def window(self):
        w = self.tools.windows(self.pid)
        if not w:
            raise NotRun(f"{self.name}: no window on screen")
        return w

    def front(self):
        """Makes the app take key input: NSRunningApplication activate, then a real click on its top edge."""
        self.tools.helper.run("activate", str(self.pid))
        pause(0.4)
        if self.tools.helper.run("frontmost").stdout.strip() != str(self.pid):
            w = self.window()
            self.tools.inject([{"do": "click", "x": w["x"] + w["w"] / 2, "y": w["y"] + 6}], self.profiles, "front", 50)
            pause(0.4)

    def size_window(self):
        x, y, w, h = WINDOW
        self.tools.helper.run("setframe", str(self.pid), str(x), str(y), str(w), str(h))
        pause(0.5)
        return self.window()

    def quit(self):
        # xbench's own quit: Chrome gets NSRunningApplication terminate first (it saves the session that the
        # launch row restores), cmux its bundle end.
        if self.instance and getattr(self, "b", None):
            self.b.quit()
        elif self.instance:
            self.instance.end(grace=15)
        self.instance = None
        self.pid = None


class ChromeArm(Arm):
    name = "chrome"

    def launch(self, profile, url=None, fg=False, restore=False):
        b = xbench.ChromiumBrowser("chrome", self.bundle, self.tools.helper, None)
        b.port = xbench.free_port()
        home = os.path.join(profile, "home")
        os.makedirs(os.path.join(home, "Library"), exist_ok=True)
        argv = ["open", "-n"] + ([] if fg else ["-g"]) + ["--env", f"HOME={home}", "--env", f"CFFIXED_USER_HOME={home}",
                                                          "-a", self.bundle, "--args",
                                                          f"--user-data-dir={os.path.join(profile, 'data')}",
                                                          f"--remote-debugging-port={b.port}", *b.flags]
        if restore:
            argv.append("--restore-last-session")
        if url:
            argv.append(url)
        subprocess.run(argv, check=True, timeout=60)
        self.b = b
        self.pid = b.wait_main()
        self.instance = b.instance = procs.Instance(self.bundle, self.pid)

    def ready(self):
        self.b.ready()

    def open(self, url):
        return self.b.new_tab(url, "p")

    def setup(self, load, url):
        """The measured tab (last, so it is in front) after the load tabs."""
        self.ready()
        first = [t["id"] for t in self.b.pages()]
        if load:
            self.open(self.server.url("cpu"))
            for _ in range(5):
                self.open(self.server.url("stream"))
        handle = self.open(url)
        for target in first:  # the launch's own New Tab page
            try:
                self.b.cdp(f"/json/close/{target}")
            except OSError:
                pass
        pause(2.5)
        self.size_window()
        self.front()
        return handle

    def tab_strip_point(self, name):
        w = self.window()
        dx, dy = GEOMETRY[name]
        return w["x"] + dx, w["y"] + dy


class CmuxArm(Arm):
    name = "cmux"

    def launch(self, profile, url=None, fg=False, restore=False):
        import bench_memory as bm
        if procs.main_pid(self.bundle):
            bm.end_bundle(self.bundle)
        home = os.path.join(profile, "home")
        tmp = os.path.join(profile, "tmp")
        for d in (os.path.join(home, "Library"), os.path.join(home, ".config/ghostty"), tmp):
            os.makedirs(d, exist_ok=True)
        ghostty = os.path.join(home, ".config/ghostty/config")
        if not os.path.exists(ghostty):
            with open(ghostty, "w") as f:
                f.write("cursor-style-blink = false\n")
        config = os.path.join(profile, "cmux.json")
        if not os.path.exists(config):
            with open(config, "w") as f:
                json.dump({"updates": {"checkAutomatically": False, "downloadAutomatically": False}}, f)
        env = {"HOME": home, "CFFIXED_USER_HOME": home, "USER": os.environ.get("USER", ""), "TMPDIR": tmp + "/",
               "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "CMUX_NEXT_SOCKET_MODE": "automation",
               "CMUX_NEXT_CONFIG_FILE": config, "CMUX_MOCK_KEYCHAIN": "1"}
        if not fg:
            env["CMUX_NEXT_NO_ACTIVATE"] = "1"
        argv = ["open", "-n"] + ([] if fg else ["-g"]) + [x for k, v in env.items() for x in ("--env", f"{k}={v}")]
        subprocess.run(argv + ["-a", self.bundle], check=True, timeout=60)
        self.home, self.tmp = home, tmp
        b = xbench.CmuxBrowser("cmux-chromium", self.bundle, self.tools.helper, None)
        b._tmp, b._state = tmp, os.path.join(home, ".local/state/cmux")
        self.b = b
        self.pid = b.wait_main()
        self.instance = b.instance = procs.Instance(self.bundle, self.pid)

    def ready(self):
        self.b.ready()

    def act(self, action, **args):
        return self.b.act(action, **args)

    def workspace(self):
        reply = self.act("workspace.newAtBottom")
        made = [i for i in reply.get("created", []) if str(i).startswith("ws_")]
        if not made:
            raise NotRun(f"cmux: workspace.newAtBottom made no workspace ({str(reply)[:200]})")
        self.act("goToWorkspace", workspace=made[0])
        return made[0]

    def open(self, url):
        self.act("openBrowser.chromium", url=url)

    def terminal(self, text=None):
        self.act("newSurface")
        if text:
            pause(1.0)
            self.act("terminal.sendText", text=text + "\r")

    def setup(self, load, url=None, terminal=None):
        self.ready()
        measured = self.workspace()
        if load:
            self.workspace()
            for _ in range(5):
                self.terminal(STREAM_CMD)
            self.act("goToWorkspace", workspace=measured)
            self.open(self.server.url("cpu"))
            pause(2.0)
        if url:
            self.open(url)
        if terminal is not None:
            self.terminal(terminal)
        pause(2.5)
        self.size_window()
        self.front()
        return measured


# ---------------------------------------------------------------- rows


class Ctx:
    def __init__(self, tools, server, refresh_ms, work):
        self.tools, self.server, self.refresh_ms, self.work = tools, server, refresh_ms, work


def marker(tools, color=TL, tries=10):
    for _ in range(tries):
        rect = tools.locate(color)
        if rect:
            return rect
        pause(0.5)
    raise NotRun(f"no #{color} marker on screen (the surface did not show)")


def typing_steps(count, rng, mods=None):
    steps = []
    for i in range(count):
        steps.append({"do": "key", "key_code": K[LETTERS[i % len(LETTERS)]], "hold_ms": 30, "modifiers": mods or []})
        steps.append({"do": "wait", "ms": rng.randint(80, 200)})
    return steps


def measure_keys(ctx, arm, rect, name, count, min_width_pt, rng):
    w = ctx.tools.watch(rect, ctx.work, name)
    try:
        hidlog = ctx.tools.inject(typing_steps(count, rng), ctx.work, name)
    finally:
        frames, summary = w.stop()
    keys = times_of(hidlog, "key_down")
    lat, lost, missed = latencies(keys, frames, lambda f: w.width_pt(f) >= min_width_pt, int(300e6), ctx.refresh_ms)
    return {"samples": lat, "lost": lost, "missed": missed, "inputs": len(keys), "sck": summary, "rect": rect,
            "rate_ok": hidlog["rate_ok"]}


def row_key_field(ctx, arm, load, rng):
    url = ctx.server.url("field")
    arm.setup(load, url)
    m = marker(ctx.tools)
    rect = [m[0] + 16, m[1] + 16, 640, 56]
    ctx.tools.inject([{"do": "click", "x": m[0] + 300, "y": m[1] + 42}], ctx.work, "focus")
    pause(0.5)
    return {"key-field": measure_keys(ctx, arm, rect, f"{arm.name}-key-field", 40, 3.0, rng)}


def row_key_native(ctx, arm, load, rng):
    arm.setup(load, ctx.server.url("color", bg="f4f4f4"))
    w = arm.window()
    win = [w["x"], w["y"], w["w"], w["h"]]
    before = os.path.join(ctx.work, "native-before.bgra")
    after = os.path.join(ctx.work, "native-after.bgra")
    size = ctx.tools.snap(win, before)
    opener = [{"do": "key", "key_code": K["p"], "modifiers": ["cmd", "shift"]}] if arm.name == "cmux" else \
        [{"do": "key", "key_code": K["l"], "modifiers": ["cmd"]}]
    ctx.tools.inject(opener, ctx.work, "open-native")
    pause(1.0)
    ctx.tools.snap(win, after)
    box = ctx.tools.diffbox(before, after, size)
    if not box:
        raise NotRun("the native field did not open (no change after its key)")
    rect = [win[0] + box[0], win[1] + box[1], max(200, box[2]), max(40, box[3])]
    result = measure_keys(ctx, arm, rect, f"{arm.name}-key-native", 30, 3.0, rng)
    ctx.tools.inject([{"do": "key", "key_code": K["esc"]}], ctx.work, "close-native")
    return {"key-native": result}


def row_key_terminal(ctx, arm, load, rng):
    if arm.name == "cmux":
        arm.setup(load, terminal="clear; printf '\\033[48;2;255;0;255m  \\033[0m\\n'")
    else:
        if not os.path.isfile(os.path.join(XTERM_DIR, "lib/xterm.js")):
            raise NotRun(f"no xterm.js at {XTERM_DIR} (bun install --frozen-lockfile in cmux-tui/frontends/web)")
        arm.setup(load, ctx.server.url("xterm", lines="0"))
    m = marker(ctx.tools)
    rect = [m[0], m[1] + 14, 640, 120]
    ctx.tools.inject([{"do": "click", "x": m[0] + 200, "y": m[1] + 80}], ctx.work, "focus")
    pause(0.5)
    result = measure_keys(ctx, arm, rect, f"{arm.name}-key-terminal", 40, 10.0, rng)
    ctx.tools.inject([{"do": "key", "key_code": K["u"], "modifiers": ["control"]}], ctx.work, "clear-line")
    return {"key-terminal": result}


def wheel_bursts(x, y, bursts=20, per=60, hz=120, gap_ms=300):
    steps = []
    for i in range(bursts):
        steps.append({"do": "scroll", "x": x, "y": y, "dy": 3 if i % 2 == 0 else -3, "count": per, "hz": hz})
        steps.append({"do": "wait", "ms": gap_ms})
    return steps


def measure_pacing(ctx, rect, name, steps, kind, tail_ms):
    w = ctx.tools.watch(rect, ctx.work, name)
    try:
        hidlog = ctx.tools.inject(steps, ctx.work, name)
    finally:
        frames, summary = w.stop()
    spans = spans_of(hidlog, kind, tail_ms=tail_ms)
    intervals, missed, frozen = pacing(frames, spans, ctx.refresh_ms)
    changed = sum(1 for f in frames if f.get("n", 0) > 0)
    result = {"samples": intervals, "missed": missed, "spans": len(spans), "inputs": len(spans), "lost": frozen,
              "frames": changed, "sck": summary, "rect": rect, "rate_ok": hidlog["rate_ok"]}
    if changed < 10:
        # The inputs were sent and the window showed nothing: no sample and no number. The report makes it a FAIL
        # when the other arm answered the same inputs (a frozen window), "not run" when neither did.
        result.update({"samples": [], "lost": len(spans), "no_frames": f"{name}: the input moved nothing on screen "
                                                                      f"({changed} changed frames)"})
    return result


def row_scroll_page(ctx, arm, load, rng):
    arm.setup(load, ctx.server.url("long"))
    m = marker(ctx.tools)
    rect = [m[0], m[1] + 14, 900, 560]
    steps = wheel_bursts(m[0] + 400, m[1] + 300)
    return {"scroll-page": measure_pacing(ctx, rect, f"{arm.name}-scroll-page", steps, "scroll", 0)}


def row_scroll_terminal(ctx, arm, load, rng):
    seq = "seq -f 'row %06g the quick brown fox jumps over the lazy dog 0123456789 abcdefghij' 1 50000"
    if arm.name == "cmux":
        arm.setup(load, terminal="clear; printf '\\033[48;2;255;0;255m  \\033[0m\\n'")
        m = marker(ctx.tools)
        arm.act("terminal.sendText", text=seq + "\r")
        pause(6)
    else:
        if not os.path.isfile(os.path.join(XTERM_DIR, "lib/xterm.js")):
            raise NotRun(f"no xterm.js at {XTERM_DIR} (bun install --frozen-lockfile in cmux-tui/frontends/web)")
        arm.setup(load, ctx.server.url("xterm", lines="50000"))
        m = marker(ctx.tools)
        pause(4)
    rect = [m[0], m[1] + 14, 800, 480]
    steps = []
    for i in range(20):  # up then down by the same count: the view stays inside the scrollback
        steps.append({"do": "scroll", "x": m[0] + 300, "y": m[1] + 250, "dy": 3 if i % 2 == 0 else -3, "count": 60, "hz": 120})
        steps.append({"do": "wait", "ms": 300})
    return {"scroll-terminal": measure_pacing(ctx, rect, f"{arm.name}-scroll-terminal", steps, "scroll", 0)}


def row_cmdt(ctx, arm, load, rng):
    arm.setup(load, ctx.server.url("color", bg="3050c0"))
    w = arm.window()
    rect = [w["x"], w["y"], w["w"], w["h"]]
    first, ready, lost, missed_first, missed_ready = [], [], 0, 0, 0
    for i in range(20):
        steps = [{"do": "key", "key_code": K["t"], "modifiers": ["cmd"], "hold_ms": 20}]
        for _ in range(30):  # keys every 50 ms for 1.5 s
            steps += [{"do": "wait", "ms": 30}, {"do": "key", "key_code": K["x"], "hold_ms": 20}]
        watch = ctx.tools.watch(rect, ctx.work, f"{arm.name}-cmdt-{i}")
        try:
            hidlog = ctx.tools.inject(steps, ctx.work, f"{arm.name}-cmdt-{i}")
        finally:
            frames, _ = watch.stop()
        downs = times_of(hidlog, "key_down")
        t0, keys = downs[0], downs[1:]
        hit = next((f for f in frames if f["t"] > t0 and watch.area_share(f) >= 0.05), None)
        if hit:
            ms = (hit["t"] - t0) / 1e6
            first.append(ms)
            missed_first += late(ms, ctx.refresh_ms)
        else:
            lost += 1
            missed_first += LOST_LATE
        r = ready_time(keys, frames, t0, lambda f: 3.0 <= watch.width_pt(f) and watch.area_share(f) < 0.05, ctx.refresh_ms)
        if r is None:
            missed_ready += LOST_LATE
        else:
            ready.append(r)
            missed_ready += late(r, ctx.refresh_ms)
        ctx.tools.inject([{"do": "key", "key_code": K["w"], "modifiers": ["cmd"]}], ctx.work, "close")
        pause(1.0)
    return {"cmdt-first": {"samples": first, "lost": lost, "missed": missed_first, "inputs": 20, "rect": rect},
            "cmdt-interactive": {"samples": ready, "lost": 20 - len(ready), "missed": missed_ready, "inputs": 20,
                                 "rect": rect}}


def row_tab_switch(ctx, arm, load, rng):
    if arm.name == "cmux":
        arm.setup(load, ctx.server.url("color", bg="c03030"))
        arm.open(ctx.server.url("color", bg="3050c0"))
    else:
        arm.setup(load, ctx.server.url("color", bg="c03030"))
        arm.open(ctx.server.url("color", bg="3050c0"))
    pause(2)
    arm.front()
    m = marker(ctx.tools)
    rect = [m[0], m[1], 600, 400]
    steps = []
    for _ in range(20):
        steps += [{"do": "key", "key_code": K["tab"], "modifiers": ["control"], "hold_ms": 30}, {"do": "wait", "ms": 500}]
    w = ctx.tools.watch(rect, ctx.work, f"{arm.name}-tab-switch")
    try:
        hidlog = ctx.tools.inject(steps, ctx.work, f"{arm.name}-tab-switch")
    finally:
        frames, summary = w.stop()
    keys = times_of(hidlog, "key_down")
    lat, lost, missed = latencies(keys, frames, lambda f: w.area_share(f) >= 0.3, int(500e6), ctx.refresh_ms)
    return {"tab-switch": {"samples": lat, "lost": lost, "missed": missed, "inputs": len(keys), "sck": summary,
                           "rect": rect}}


def drag_there_and_back(a, b, ms=1000):
    return [{"do": "drag", "from": a, "to": b, "duration_ms": ms, "hz": 120, "hold_ms": 120},
            {"do": "wait", "ms": 300},
            {"do": "drag", "from": b, "to": a, "duration_ms": ms, "hz": 120, "hold_ms": 120}]


def row_window_resize(ctx, arm, load, rng):
    arm.setup(load, ctx.server.url("long"))
    w = arm.window()
    rect = [w["x"], w["y"], w["w"], w["h"]]
    corner = [w["x"] + w["w"] - 3, w["y"] + w["h"] - 3]
    steps = drag_there_and_back(corner, [corner[0] - 240, corner[1] - 160])
    return {"window-resize": measure_pacing(ctx, rect, f"{arm.name}-window-resize", steps, "drag", 0)}


def row_pane_resize(ctx, arm, load, rng):
    arm.setup(load, ctx.server.url("long", tr="1"))
    if arm.name == "cmux":
        arm.act("splitRight")
    else:
        ctx.tools.inject([{"do": "key", "key_code": K["i"], "modifiers": ["cmd", "option"]}], ctx.work, "devtools")
    pause(3)
    arm.front()
    w = arm.window()
    cyan = marker(ctx.tools, TR)
    divider = cyan[0] + cyan[2] + 2
    if divider > w["x"] + w["w"] - 30:
        raise NotRun("no divider: the page still reaches the window's right edge (DevTools undocked or no split)")
    rect = [w["x"], w["y"], w["w"], w["h"]]
    a = [divider, cyan[1] + 200]
    steps = drag_there_and_back(a, [divider - 240, a[1]])
    return {"pane-resize": measure_pacing(ctx, rect, f"{arm.name}-pane-resize", steps, "drag", 0)}


def hover_points(ctx, arm, which):
    w = arm.window()
    if arm.name == "chrome":
        a, b = GEOMETRY["chrome_tab_a"], GEOMETRY["chrome_tab_b"]
        return [w["x"] + a[0], w["y"] + a[1]], [w["x"] + b[0], w["y"] + b[1]], [w["x"], w["y"], w["w"], 44]
    if which == "sidebar":
        a, b = GEOMETRY["cmux_sidebar_a"], GEOMETRY["cmux_sidebar_b"]
        return [w["x"] + a[0], w["y"] + a[1]], [w["x"] + b[0], w["y"] + b[1]], [w["x"], w["y"] + 40, 260, 360]
    m = marker(ctx.tools)
    a, b = GEOMETRY["cmux_tab_a"], GEOMETRY["cmux_tab_b"]
    return [m[0] + a[0], m[1] + a[1]], [m[0] + b[0], m[1] + b[1]], [m[0], m[1] - 36, 600, 36]


def strip_setup(ctx, arm, load):
    if arm.name == "cmux":
        arm.setup(load, ctx.server.url("color", bg="f4f4f4"))
        for _ in range(4):  # sidebar rows and tabs to point at
            arm.open(ctx.server.url("color", bg="e8e8e8"))
        for _ in range(5):
            arm.act("workspace.newAtBottom")
        arm.act("workspace.selectFirst")
        pause(1.5)
        arm.front()
    else:
        arm.setup(load, ctx.server.url("color", bg="f4f4f4"))
        for _ in range(5):
            arm.open(ctx.server.url("color", bg="e8e8e8"))
        pause(1.5)
        arm.front()


def row_hover(ctx, arm, load, rng, which):
    strip_setup(ctx, arm, load)
    a, b, rect = hover_points(ctx, arm, which)
    steps = [{"do": "move", "x": a[0], "y": a[1]}, {"do": "wait", "ms": 400}]
    for i in range(20):
        p = b if i % 2 == 0 else a
        steps += [{"do": "move", "x": p[0], "y": p[1]}, {"do": "wait", "ms": 400}]
    name = f"{arm.name}-hover-{which}"
    w = ctx.tools.watch(rect, ctx.work, name)
    try:
        hidlog = ctx.tools.inject(steps, ctx.work, name)
    finally:
        frames, summary = w.stop()
    moves = times_of(hidlog, "move")[1:]
    lat, lost, missed = latencies(moves, frames, lambda f: f.get("n", 0) > 0, int(400e6), ctx.refresh_ms)
    if lost > len(moves) / 2:
        raise NotRun(f"{name}: {lost} of {len(moves)} pointer moves changed nothing (geometry: --geometry)")
    return {f"hover-{which}": {"samples": lat, "lost": lost, "missed": missed, "inputs": len(moves), "sck": summary,
                               "rect": rect}}


def row_drag(ctx, arm, load, rng, which):
    strip_setup(ctx, arm, load)
    a, b, rect = hover_points(ctx, arm, which)
    w = arm.window()
    if arm.name == "chrome" or which == "tabs":
        to = [a[0] + 400, a[1]]
        rect = [w["x"], rect[1], w["w"], rect[3]]
    else:
        to = [a[0], a[1] + 160]
        rect = [w["x"], w["y"] + 40, 260, 400]
    steps = drag_there_and_back(a, to, 800)
    return {f"drag-{which}": measure_pacing(ctx, rect, f"{arm.name}-drag-{which}", steps, "drag", 0)}


def make_template(ctx, arm, load):
    """A profile with the session a relaunch restores: the launch page (Chrome) or a terminal workspace (cmux), and
    under load the load tabs and streaming terminals."""
    profile = arm.profile(f"template-{'load' if load else 'light'}")
    arm.launch(profile)
    try:
        if arm.name == "cmux":
            arm.setup(load, terminal="")
        else:
            arm.setup(load, ctx.server.url("field"))
        pause(5)
    finally:
        arm.quit()
    pause(3)
    return profile


def row_launch(ctx, arm, load, rng, templates):
    key = (arm.name, load)
    if key not in templates:
        templates[key] = make_template(ctx, arm, load)
    profile = arm.profile("launch")
    shutil.rmtree(profile)
    xbench.clone(templates[key], profile)
    disp = ctx.tools.display()
    rect = [0, 30, disp.get("points", [1920, 1200])[0], disp.get("points", [1920, 1200])[1] - 130]
    steps = [{"do": "wait", "ms": 20}]
    for _ in range(160):  # a key every 50 ms for 8 s
        steps += [{"do": "key", "key_code": K["x"], "hold_ms": 15}, {"do": "wait", "ms": 35}]
    name = f"{arm.name}-launch"
    w = ctx.tools.watch(rect, ctx.work, name)
    result = {}
    holder = {}

    def keys():
        holder["log"] = ctx.tools.inject(steps, ctx.work, name, start_delay_ms=0)

    try:
        t0 = now_ns()
        typer = threading.Thread(target=keys)
        typer.start()
        if arm.name == "chrome":
            arm.launch(profile, ctx.server.url("field"), fg=True, restore=True)
        else:
            arm.launch(profile, fg=True)
        typer.join()
    finally:
        frames, summary = w.stop()
    try:
        hidlog = holder.get("log") or {"events": []}
        hit = next((f for f in frames if f["t"] > t0 and w.area_share(f) >= 0.03), None)
        first = [(hit["t"] - t0) / 1e6] if hit else []
        keys_t = [t for t in times_of(hidlog, "key_down") if hit and t > hit["t"]]
        r = ready_time(keys_t, frames, t0, lambda f: w.width_pt(f) >= 3.0 and w.area_share(f) < 0.03, ctx.refresh_ms)
        result["launch-first"] = {"samples": first, "lost": 0 if hit else 1, "inputs": 1,
                                  "missed": late(first[0], ctx.refresh_ms) if first else LOST_LATE, "rect": rect}
        result["launch-interactive"] = {"samples": [r] if r is not None else [], "lost": 0 if r is not None else 1,
                                        "inputs": 1, "missed": late(r, ctx.refresh_ms) if r is not None else LOST_LATE,
                                        "rect": rect}
    finally:
        arm.quit()
        pause(3)
    return result


RUNNERS = {
    "key-field": row_key_field, "key-native": row_key_native, "key-terminal": row_key_terminal,
    "scroll-page": row_scroll_page, "scroll-terminal": row_scroll_terminal, "cmdt": row_cmdt,
    "tab-switch": row_tab_switch, "window-resize": row_window_resize, "pane-resize": row_pane_resize,
    "hover-sidebar": lambda c, a, l, r: row_hover(c, a, l, r, "sidebar"),
    "hover-tabs": lambda c, a, l, r: row_hover(c, a, l, r, "tabs"),
    "drag-sidebar": lambda c, a, l, r: row_drag(c, a, l, r, "sidebar"),
    "drag-tabs": lambda c, a, l, r: row_drag(c, a, l, r, "tabs"),
}


def scenario_of(row):
    return next((s for s, rows in SCENARIOS.items() if row in rows), row)


# ---------------------------------------------------------------- run


def wait_quiet(max_load, timeout=120):
    deadline = time.monotonic() + timeout
    while os.getloadavg()[0] >= max_load:
        if time.monotonic() > deadline:
            return False
        pause(5)
    return True


def run(args):
    out = os.path.abspath(args.out)
    if os.path.exists(os.path.join(out, "results.jsonl")):
        raise SystemExit(f"{out} holds an earlier run: give a new --out")
    work = os.path.join(out, "work")
    profiles = os.path.join(out, "profiles")
    for d in (work, profiles):
        os.makedirs(d, exist_ok=True)
    if args.geometry:
        GEOMETRY.update(json.load(open(args.geometry)))
    results = open(os.path.join(out, "results.jsonl"), "a")
    rows = [r.strip() for r in args.rows.split(",") if r.strip()]
    unknown = [r for r in rows if r not in ROWS]
    if unknown:
        raise SystemExit(f"unknown rows {unknown}; known: {', '.join(ROWS)}")
    scenarios = []
    for r in rows:
        s = scenario_of(r)
        if s not in scenarios:
            scenarios.append(s)
    loads = [x for x in args.loads.split(",") if x in ("light", "load")]

    def record(entry):
        entry.update({"at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())})
        results.write(json.dumps(entry) + "\n")
        results.flush()

    def all_not_run(reason):
        for r in rows:
            for load in loads:
                record({"row": r, "load": load, "arm": "both", "status": "not run", "reason": reason})
        log(f"not run: {reason}")

    if not os.path.isdir(args.chrome):
        return all_not_run(f"no Google Chrome stable at {args.chrome} on this host (the bench installs nothing)")
    if not os.path.isdir(args.cmux):
        return all_not_run(f"no cmux app at {args.cmux}")
    tools = Tools(os.path.join(os.path.expanduser("~"), ".cache", "chrome-parity"))
    if args.vdisplay:
        hz, scale = (int(v) for v in args.vdisplay.split("x"))
        tools.start_vdisplay(hz, scale, work)
    disp = tools.display()
    refresh_ms = 1000.0 / args.hz
    machine = {"host": subprocess.run(["scutil", "--get", "ComputerName"], capture_output=True, text=True).stdout.strip(),
               "model": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
               "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
               "display": disp, "hz": args.hz, "cmux": xbench.bundle_version(args.cmux),
               "chrome": xbench.bundle_version(args.chrome), "cmux_sha": args.cmux_sha, "note": args.note}
    with open(os.path.join(out, "machine.json"), "w") as f:
        json.dump(machine, f, indent=1)
    log(f"machine {machine}")
    if not disp.get("interval_ms") or abs(disp["interval_ms"] - refresh_ms) > 0.35:
        return all_not_run(f"the main display runs at {disp.get('interval_ms')} ms a frame, not {refresh_ms:.3f} ms "
                           f"({args.hz} Hz); pass --vdisplay {args.hz}x1")
    server = Server()
    ctx = Ctx(tools, server, refresh_ms, work)
    arms = {"cmux": CmuxArm(args.cmux, tools, server, profiles), "chrome": ChromeArm(args.chrome, tools, server, profiles)}
    caffeinate = subprocess.Popen(["caffeinate", "-dimsu"])
    templates = {}
    try:
        for rnd in range(args.rounds):
            order = ["cmux", "chrome"] if rnd % 2 == 0 else ["chrome", "cmux"]
            for scenario in scenarios:
                for load in loads:
                    for name in order:
                        arm = arms[name]
                        rng = random.Random(f"{scenario}-{load}-{rnd}")  # the same typing gaps for both arms
                        wanted = [r for r in rows if scenario_of(r) == scenario]
                        base = {"round": rnd, "load": load, "arm": name, "scenario": scenario}
                        if not wait_quiet(args.max_load):
                            for r in wanted:
                                record({**base, "row": r, "status": "not run",
                                        "reason": f"1-minute load stayed over {args.max_load}"})
                            continue
                        base["load1_before"] = round(os.getloadavg()[0], 1)
                        log(f"round {rnd} {scenario} {load} {name} (1-min load {base['load1_before']})")
                        try:
                            if scenario == "launch":
                                got = row_launch(ctx, arm, load == "load", rng, templates)
                            else:
                                arm.launch(arm.profile(scenario))
                                got = RUNNERS[scenario](ctx, arm, load == "load", rng)
                            for r in wanted:
                                if r in got:
                                    record({**base, "row": r, "status": "measured", **got[r]})
                        except NotRun as error:
                            for r in wanted:
                                record({**base, "row": r, "status": "not run", "reason": str(error)})
                            log(f"not run: {error}")
                        except Exception as error:  # one arm's failure is that run's "not run", never the bench's end
                            for r in wanted:
                                record({**base, "row": r, "status": "not run", "reason": f"{type(error).__name__}: {error}"[:300]})
                            log(f"error: {type(error).__name__}: {error}")
                        finally:
                            arm.quit()
                            pause(2)
                            base["load1_after"] = round(os.getloadavg()[0], 1)
                            record({**base, "row": "_arm", "status": "load"})
    finally:
        caffeinate.terminate()
        results.close()


# ---------------------------------------------------------------- report


def cell_of(runs):
    """One arm's cell of a table row from its measured runs: the samples' distribution, the missed refreshes, the
    inputs sent, the inputs that got no frame (`lost`) and the inputs the capture could not see (`blind`: the
    app-clock method's honesty rule 5; they are no sample and not lost)."""
    samples = [s for e in runs for s in e.get("samples", [])]
    p95s = [stats(e.get("samples", [])).get("p95") for e in runs if e.get("samples")]
    return {**stats(samples), "missed": sum(e.get("missed", 0) for e in runs),
            "lost": sum(e.get("lost", 0) for e in runs), "blind": sum(e.get("blind", 0) for e in runs),
            "inputs": sum(e.get("inputs", 0) for e in runs), "runs": len(runs), "p95_spread": [min(p95s), max(p95s)] if p95s else None}


def verdict_of(c, g):
    """(verdict, reason) of one row from the cmux cell `c` and the Chrome cell `g`.

    An arm with no sample is never a pass and never a number. When cmux got inputs and showed no frame for any of
    them while Chrome answered the same inputs, the cmux window was frozen (or the input never reached it): FAIL.
    When Chrome is the arm with no sample, or neither arm has one, there is nothing to compare: not run."""
    cn, gn = c.get("n", 0), g.get("n", 0)
    if cn == 0 and gn > 0 and c.get("inputs", 0) > 0:
        return "FAIL", f"cmux showed no frame for {c['inputs']} inputs (frozen window or input not delivered); Chrome answered"
    if cn == 0 or gn == 0:
        who = "no arm has" if cn == 0 and gn == 0 else "Chrome has no" if gn == 0 else "cmux has no"
        return "not run", f"{who} sample".replace("no arm has sample", "no arm has a sample")
    if c["p95"] <= g["p95"] and c["missed"] <= g["missed"]:
        return "PASS", ""
    return "FAIL", ""


def selfcheck(_args):
    """Proves the judge on made-up frames, with no app and no display: a frozen cmux window FAILS the frame rows, and
    an input that is not delivered gives no sample (never a fast number). Prints one line per check; exit 1 on a miss."""
    refresh = 1000.0 / 120
    ms = 1_000_000
    checks = []

    def check(name, ok, detail):
        checks.append(ok)
        print(f"PARITY-SELFCHECK {'ok ' if ok else 'BAD'} {name}: {detail}")

    keys = [i * 150 * ms for i in range(1, 21)]
    live = [{"t": t + 12 * ms, "n": 40} for t in keys]
    any_frame = lambda f: f.get("n", 0) > 0  # noqa: E731
    lat, lost, missed = latencies(keys, live, any_frame, 300 * ms, refresh)
    check("keys, live window", len(lat) == 20 and lost == 0 and abs(max(lat) - 12) < 0.01, f"n {len(lat)} lost {lost}")
    # A frozen window: ScreenCaptureKit gives no changed frame at all.
    lat, lost, missed = latencies(keys, [], any_frame, 300 * ms, refresh)
    frozen_keys = {"samples": lat, "lost": lost, "missed": missed, "inputs": len(keys)}
    check("keys, frozen window: no sample", lat == [] and lost == 20 and missed == 20 * LOST_LATE, f"n {len(lat)} lost {lost} missed {missed}")
    # An input that is not delivered: the screen changes only BEFORE the key (an old frame) and long after it
    # (another cause). Neither may count as that key's frame.
    stale = [{"t": keys[0] - 2 * ms, "n": 40}, {"t": keys[0] + 400 * ms, "n": 40}]
    lat, lost, missed = latencies(keys[:1], stale, any_frame, 300 * ms, refresh)
    check("key not delivered: no sample", lat == [] and lost == 1, f"n {len(lat)} lost {lost}")
    # A frame that changes less than the row's response size (a caret, a clock) is not the key's frame.
    small = [{"t": t + 3 * ms, "n": 1} for t in keys]
    lat, lost, missed = latencies(keys, small, lambda f: f.get("n", 0) >= 10, 300 * ms, refresh)
    check("key, only an unrelated small change: no sample", lat == [] and lost == 20, f"n {len(lat)} lost {lost}")
    spans = [(i * 1000 * ms, i * 1000 * ms + 500 * ms) for i in range(1, 6)]
    smooth = [{"t": a + k * int(refresh * ms), "n": 500} for a, b in spans for k in range(60)]
    iv, missed, frozen = pacing(smooth, spans, refresh)
    live_pacing = {"samples": iv, "missed": missed, "lost": frozen, "inputs": len(spans)}
    check("scroll, live window", len(iv) == 5 * 59 and missed == 0 and frozen == 0, f"n {len(iv)} missed {missed} frozen {frozen}")
    iv, missed, frozen = pacing([], spans, refresh)
    frozen_pacing = {"samples": iv, "missed": missed, "lost": frozen, "inputs": len(spans)}
    check("scroll, frozen window: no sample, every refresh missed", iv == [] and frozen == 5 and missed == 5 * 60,
          f"n {len(iv)} missed {missed} frozen {frozen}")
    one = [{"t": a + 10 * ms, "n": 500} for a, b in spans]  # one frame per burst: the picture jumped once and froze
    iv, missed, frozen = pacing(one, spans, refresh)
    check("scroll, one frame per burst: frozen spans", iv == [] and frozen == 5 and missed == 5 * 60, f"missed {missed} frozen {frozen}")
    live_keys = {"samples": [12.0] * 20, "lost": 0, "missed": 0, "inputs": 20}
    for name, cmux, chrome, want in (
            ("verdict, frozen cmux keys vs live Chrome", frozen_keys, live_keys, "FAIL"),
            ("verdict, frozen cmux scroll vs live Chrome", frozen_pacing, live_pacing, "FAIL"),
            ("verdict, live cmux vs frozen Chrome", live_keys, frozen_keys, "not run"),
            ("verdict, both frozen", frozen_keys, frozen_keys, "not run"),
            ("verdict, equal arms", live_keys, live_keys, "PASS"),
            ("verdict, cmux lost 1 key of 20", {**live_keys, "samples": [12.0] * 19, "lost": 1, "missed": LOST_LATE},
             live_keys, "FAIL")):
        got, why = verdict_of(cell_of([{"status": "measured", **cmux}]), cell_of([{"status": "measured", **chrome}]))
        check(name, got == want, f"{got}{' (' + why + ')' if why else ''}, want {want}")
    print(f"PARITY-SELFCHECK {'PASS' if all(checks) else 'FAIL'} {sum(checks)}/{len(checks)}")
    return 0 if all(checks) else 1


def report(args):
    out = os.path.abspath(args.out)
    entries = [json.loads(line) for line in open(os.path.join(out, "results.jsonl"))]
    try:
        machine = json.load(open(os.path.join(out, "machine.json")))
    except OSError:
        machine = {}
    table = []
    hz = machine.get("hz") or 120
    note = machine.get("note") or ""
    for row, (metric, kind, cmux_what, chrome_what) in ROWS.items():
        for load in ("light", "load"):
            mine = [e for e in entries if e.get("row") == row and e.get("load") == load]
            if not mine:
                continue
            arm_loads = [v for e in entries if e.get("load") == load and e.get("scenario") == scenario_of(row)
                         for v in (e.get("load1_before"), e.get("load1_after")) if v is not None]
            cells = {arm: cell_of([e for e in mine if e.get("arm") == arm and e.get("status") == "measured"])
                     for arm in ("cmux", "chrome")}
            reasons = sorted({e.get("reason", "") for e in mine if e.get("status") == "not run"})
            c, g = cells["cmux"], cells["chrome"]
            verdict, why = verdict_of(c, g)
            if why:
                reasons.append(why)
            slower = c["p95"] > g["p95"] if c.get("n") and g.get("n") else None
            table.append({"row": row, "metric": metric, "kind": kind, "load": load, "cmux": c, "chrome": g,
                          "verdict": verdict + (f", {note}" if note and verdict != "not run" else "")
                          + (f", {c['blind']} of {c['inputs']} cmux inputs blind (not measured)"
                             if c.get("blind") and verdict != "not run" else ""),  # a "not run" row keeps its plain name
                          "cmux_p95_over_chrome": slower,
                          "load1": [min(arm_loads), max(arm_loads)] if arm_loads else None,
                          "not_run": reasons, "cmux_surface": cmux_what, "chrome_surface": chrome_what})
    for r in table:
        print("PARITY-ROW " + json.dumps({k: r[k] for k in ("row", "load", "cmux", "chrome", "verdict", "cmux_p95_over_chrome",
                                                            "load1")}))
    if args.json:
        with open(args.json, "w") as f:
            json.dump({"machine": machine, "rows": table}, f, indent=1)
    if args.md:
        def cell(s):
            return "-" if not s.get("n") else f"{s['p50']} / {s['p95']} / {s['p99']} / {s['max']} (n {s['n']})"

        def missed(s):  # an arm that got no input has no missed count: "0" there would read as "none missed"
            return s.get("missed") if s.get("n") or s.get("inputs") else "-"
        lines = [f"# Chrome parity, {time.strftime('%Y-%m-%d %H:%MZ', time.gmtime())}", "",
                 f"Host {machine.get('host')} ({machine.get('model')}), macOS {machine.get('macos')}, "
                 f"judged against {machine.get('hz')} Hz (nominal, not measured here), cmux {machine.get('cmux')} at {machine.get('cmux_sha') or '?'}, "
                 f"Chrome {machine.get('chrome')}. ms, p50 / p95 / p99 / max; missed = late or missed {hz} Hz refreshes."
                 + (f" {note}." if note else ""), "",
                 "| Metric | Load | 1-min load | cmux | Chrome | missed cmux / Chrome | cmux p95 > Chrome p95 | verdict "
                 "| cmux surface / Chrome surface |",
                 "|---|---|---|---|---|---|---|---|---|"]
        for r in table:
            why = "; ".join(r["not_run"])[:160]
            lo = r["load1"]
            slower = {None: "-", True: "yes", False: "no"}[r["cmux_p95_over_chrome"]]
            lines.append(f"| {r['metric']} | {r['load']} | {f'{lo[0]}-{lo[1]}' if lo else '-'} | {cell(r['cmux'])} | "
                         f"{cell(r['chrome'])} | {missed(r['cmux'])} / {missed(r['chrome'])} | {slower} | "
                         f"{r['verdict']}{' (' + why + ')' if why and r['verdict'] == 'not run' else ''} | "
                         f"{r['cmux_surface']} / {r['chrome_surface']} |")
        with open(args.md, "w") as f:
            f.write("\n".join(lines) + "\n")
        print("\n".join(lines))
    return 0  # a bench report, never a gate: FAIL rows are data for the lead, not a red job


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    r = sub.add_parser("run")
    r.add_argument("--cmux", required=True)
    r.add_argument("--chrome", default=CHROME_DEFAULT)
    r.add_argument("--out", required=True)
    r.add_argument("--rounds", type=int, default=2)
    r.add_argument("--rows", default=",".join(ROWS))
    r.add_argument("--loads", default="light,load")
    r.add_argument("--hz", type=int, default=120)
    r.add_argument("--vdisplay", default="")
    r.add_argument("--max-load", type=float, default=2.0)
    r.add_argument("--geometry", default="")
    r.add_argument("--cmux-sha", default="")
    r.add_argument("--note", default="", help="a label for every row, e.g. 'relative only (not 120 Hz quiet)'")
    p = sub.add_parser("report")
    p.add_argument("--out", required=True)
    p.add_argument("--md", default="")
    p.add_argument("--json", default="")
    sub.add_parser("rows")
    sub.add_parser("selfcheck", help="proves the judge on made-up frames: frozen window = FAIL, undelivered input = no sample")
    args = parser.parse_args()
    if args.cmd == "run":
        return run(args) or 0
    if args.cmd == "selfcheck":
        return selfcheck(args)
    if args.cmd == "report":
        return report(args)
    for row, (metric, kind, a, b) in ROWS.items():
        print(f"{row:20} {kind:8} {metric}\n{'':30}cmux:   {a}\n{'':30}Chrome: {b}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
