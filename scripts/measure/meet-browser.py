#!/usr/bin/env python3
"""The driver half of scripts/measure/meet-browser.sh: what a video-call page needs, per browser.

    meet-browser.py --side SIDE_SH --name NAME --work DIR --out DIR --dmg URL --version V [--call S] [--only a,b]

Runs (each a fresh page on a local test page served here; 127.0.0.1 is a secure context):
  cmux-chromium       the side copy of the NIGHTLY, a Chromium tab, launched with no extra arguments
  cmux-webkit         the same launch, a WebKit tab
  cmux-chromium-fake  the copy relaunched with Chromium's fake-device switches as app arguments (whether
                      they reach its Chromium is part of the result: a release build ignores
                      CMUX_NEXT_CEF_EXTRA_SWITCHES, CEFSwitches.swift)
  chrome-fake         Google Chrome (installed, else Chrome for Testing) with the fake device and fake UI
  chrome-plain        Chrome with the fake device but no fake UI: a permission prompt nobody answers
Each run records: getUserMedia, permissions.query, Notification.requestPermission, Picture-in-Picture,
getDisplayMedia (clicked with a trusted click: both need a user gesture), and in the primary runs a loopback
WebRTC call (two RTCPeerConnections, a 1280x720 30 fps canvas track) with the browser's CPU from ps, timer drift
while the tab is hidden, and meet.google.com load (navigation start to load event) cold and warm.
cmux is driven through the copy's control socket (browser.page.*, action.run), Chrome through DevTools.
Writes OUT/results.json and OUT/table.md; prints MEET_BROWSER {json}.
"""
from __future__ import annotations

import argparse
import base64
import http.server
import json
import os
import re
import socket
import socketserver
import subprocess
import threading
import time
import urllib.request
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
AGENT = "MeetMeasure"
FAKE = ["--use-fake-device-for-media-stream", "--use-fake-ui-for-media-stream"]
GUM_WAIT = 20.0
MEET = "https://meet.google.com/"

PAGE = r"""<!doctype html><html><head><meta charset=utf-8><title>meet-measure</title>
<style>body{font:14px system-ui;margin:16px} button{display:block;margin:6px 0;width:220px;height:36px}</style>
</head><body><h3>meet-measure</h3>
<button id=b-pip onclick="__m.start('pip')">pip</button>
<button id=b-gdm onclick="__m.start('gdm')">gdm</button>
<button id=b-notif onclick="__m.start('notif')">notif</button>
<video id=v muted playsinline width=320></video>
<script>
const R = {}; const LABEL = new URLSearchParams(location.search).get('run') || 'x';
const t = () => performance.now();
function put(k, v) { v.vis = document.visibilityState; v.focus = document.hasFocus(); R[k] = v;
  fetch('/r/' + LABEL + '/' + k, {method: 'POST', body: JSON.stringify(v)}).catch(() => {}); }
function canvasStream(w, h, fps) {
  const c = document.createElement('canvas'); c.width = w; c.height = h; const g = c.getContext('2d'); let n = 0;
  setInterval(() => { n++; g.fillStyle = `hsl(${n * 7 % 360},70%,50%)`; g.fillRect(0, 0, w, h); g.fillStyle = '#fff';
    g.font = '80px sans-serif'; g.fillText(String(n), 40, 120);
    for (let i = 0; i < 40; i++) g.fillRect((n * 13 + i * 61) % w, (i * 37 + n * 3) % h, 48, 48); }, 1000 / fps);
  return c.captureStream(fps);
}
function media(key, call) {
  const t0 = t(); put(key, {state: 'pending'});
  let p; try { p = call(); } catch (e) { return put(key, {ok: false, state: 'threw', error: e.name, message: String(e.message).slice(0, 200)}); }
  p.then(s => { put(key, {ok: true, state: 'resolved', ms: Math.round(t() - t0), tracks: s.getTracks().map(x => x.kind + ':' + x.label)});
                setTimeout(() => s.getTracks().forEach(x => x.stop()), 500); },
         e => put(key, {ok: false, state: 'rejected', ms: Math.round(t() - t0), error: e.name, message: String(e.message).slice(0, 200)}));
}
const pipVideo = document.getElementById('v');
try { pipVideo.srcObject = canvasStream(640, 360, 30); pipVideo.play().catch(() => {}); } catch (e) {}
const steps = {
  info() { put('info', {ua: navigator.userAgent, secure: isSecureContext, mediaDevices: !!navigator.mediaDevices,
    gdm: !!(navigator.mediaDevices && navigator.mediaDevices.getDisplayMedia), pipEnabled: !!document.pictureInPictureEnabled,
    pipFn: typeof pipVideo.requestPictureInPicture, notification: 'Notification' in window ? Notification.permission : 'absent',
    rtc: typeof RTCPeerConnection}); },
  gum() { if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) return put('gum', {ok: false, state: 'absent'});
    media('gum', () => navigator.mediaDevices.getUserMedia({video: true, audio: true})); },
  devices() { if (!navigator.mediaDevices) return put('devices', {ok: false});
    navigator.mediaDevices.enumerateDevices().then(d => put('devices', {ok: true, list: d.map(x => x.kind + ':' + (x.label || '?'))}),
      e => put('devices', {ok: false, error: e.name})); },
  perms() { const q = n => navigator.permissions ? navigator.permissions.query({name: n}).then(p => p.state, e => 'error:' + e.name) : Promise.resolve('no api');
    Promise.all(['camera', 'microphone', 'notifications'].map(q)).then(v => put('perms', {camera: v[0], microphone: v[1], notifications: v[2]})); },
  notif() { if (!('Notification' in window)) return put('notif', {ok: false, state: 'absent'});
    const before = Notification.permission, t0 = t(); put('notif', {state: 'pending', before});
    let p; try { p = Notification.requestPermission(); } catch (e) { return put('notif', {ok: false, state: 'threw', before, error: e.name}); }
    Promise.resolve(p).then(r => put('notif', {ok: true, state: 'resolved', before, result: r, after: Notification.permission, ms: Math.round(t() - t0)}),
      e => put('notif', {ok: false, state: 'rejected', before, error: e.name})); },
  pip() { if (typeof pipVideo.requestPictureInPicture !== 'function')
      return put('pip', {ok: false, state: 'absent', enabled: !!document.pictureInPictureEnabled});
    const t0 = t(); put('pip', {state: 'pending', enabled: document.pictureInPictureEnabled, paused: pipVideo.paused});
    pipVideo.requestPictureInPicture().then(w => { put('pip', {ok: true, state: 'resolved', ms: Math.round(t() - t0), width: w.width, height: w.height,
        enabled: document.pictureInPictureEnabled}); setTimeout(() => document.exitPictureInPicture().catch(() => {}), 1500); },
      e => put('pip', {ok: false, state: 'rejected', error: e.name, message: String(e.message).slice(0, 200), enabled: document.pictureInPictureEnabled})); },
  gdm() { if (!navigator.mediaDevices || !navigator.mediaDevices.getDisplayMedia) return put('gdm', {ok: false, state: 'absent'});
    media('gdm', () => navigator.mediaDevices.getDisplayMedia({video: true})); },
  async loop(secs) {
    put('loop', {state: 'starting'});
    const s = canvasStream(1280, 720, 30), a = new RTCPeerConnection(), b = new RTCPeerConnection();
    a.onicecandidate = e => e.candidate && b.addIceCandidate(e.candidate);
    b.onicecandidate = e => e.candidate && a.addIceCandidate(e.candidate);
    s.getTracks().forEach(tr => a.addTrack(tr, s));
    let got = false;
    b.ontrack = e => { got = true; const v = document.createElement('video'); v.muted = true; v.autoplay = true; v.width = 320; v.srcObject = e.streams[0]; document.body.appendChild(v); };
    const o = await a.createOffer(); await a.setLocalDescription(o); await b.setRemoteDescription(o);
    const an = await b.createAnswer(); await b.setLocalDescription(an); await a.setRemoteDescription(an);
    const samples = []; const t0 = t(); R.loop = {state: 'running'};
    const iv = setInterval(async () => {
      const sa = await a.getStats(), sb = await b.getStats(); const x = {s: Math.round((t() - t0) / 1000)};
      sb.forEach(r => { if (r.type === 'inbound-rtp' && r.kind === 'video') { x.fps = r.framesPerSecond ?? null; x.w = r.frameWidth; x.h = r.frameHeight; x.decoder = r.decoderImplementation; x.dropped = r.framesDropped; } });
      sa.forEach(r => { if (r.type === 'candidate-pair' && r.nominated && r.currentRoundTripTime != null) x.rtt = r.currentRoundTripTime;
        if (r.type === 'outbound-rtp' && r.kind === 'video') { x.encFps = r.framesPerSecond ?? null; x.limit = r.qualityLimitationReason; x.encoder = r.encoderImplementation; x.ew = r.frameWidth; } });
      samples.push(x);
      if (t() - t0 >= secs * 1000) {
        clearInterval(iv); a.close(); b.close(); s.getTracks().forEach(z => z.stop());
        const late = samples.filter(z => z.s >= 5), med = k => { const v = late.map(z => z[k]).filter(z => typeof z === 'number').sort((p, q) => p - q); return v.length ? v[Math.floor(v.length / 2)] : null; };
        const last = samples[samples.length - 1] || {};
        const fps = med('fps');
        put('loop', {ok: got && fps !== null && fps >= 20, state: 'done', secs, gotTrack: got, fpsMedian: fps, encFpsMedian: med('encFps'),
          rttMsMedian: med('rtt') === null ? null : Math.round(med('rtt') * 10000) / 10, size: last.w + 'x' + last.h, sentWidth: last.ew,
          limit: last.limit, encoder: last.encoder, decoder: last.decoder, dropped: last.dropped, samples});
      }
    }, 1000);
  },
  hiddenStart() { const log = []; let last = t(); R.hiddenLog = log;
    R.hiddenIv = setInterval(() => { const n = t(); log.push([n - last, document.visibilityState]); last = n; }, 100); put('hidden', {state: 'running'}); },
  hiddenStop() { clearInterval(R.hiddenIv); const log = R.hiddenLog || [];
    const part = v => { const d = log.filter(z => z[1] === v).map(z => z[0]).sort((p, q) => p - q);
      return d.length ? {ticks: d.length, meanMs: Math.round(d.reduce((p, q) => p + q, 0) / d.length), p50Ms: Math.round(d[Math.floor(d.length / 2)]), maxMs: Math.round(d[d.length - 1])} : {ticks: 0}; };
    const hid = part('hidden'); put('hidden', {ok: hid.ticks > 0, state: 'done', hidden: hid, visible: part('visible')}); },
};
window.__m = {R, start(n, arg) { try { const r = steps[n](arg); if (r && r.catch) r.catch(e => put(n, {ok: false, state: 'threw', error: e.name, message: String(e.message).slice(0, 200)})); return 'started'; }
  catch (e) { put(n, {ok: false, state: 'threw', error: e.name, message: String(e.message).slice(0, 200)}); return 'threw'; } },
  read(k) { const v = R[k]; return v === undefined ? null : JSON.stringify(v); },
  center(id) { const r = document.getElementById(id).getBoundingClientRect(); return JSON.stringify([r.x + r.width / 2, r.y + r.height / 2]); }};
__m.start('info');
</script></body></html>"""

NAV_JS = ("(() => { const e = performance.getEntriesByType('navigation')[0]; return JSON.stringify(e ? {url: location.href,"
          " title: document.title.slice(0, 80), load: Math.round(e.loadEventEnd), dcl: Math.round(e.domContentLoadedEventEnd),"
          " ttfb: Math.round(e.responseStart), type: e.type, transfer: e.transferSize} : {url: location.href}); })()")


# ---- local server ----------------------------------------------------------------------------------------

RESULTS: dict[str, dict] = {}


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = PAGE.encode() if self.path.startswith("/t") else b"<!doctype html><title>blank</title>ok"
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        parts = self.path.split("/")
        data = self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if len(parts) == 4 and parts[1] == "r":
            try:
                RESULTS.setdefault(parts[2], {})[parts[3]] = json.loads(data)
            except ValueError:
                pass
        self.send_response(204)
        self.end_headers()

    def log_message(self, *args):
        pass


def serve() -> int:
    server = socketserver.ThreadingTCPServer(("127.0.0.1", 0), Handler)
    server.daemon_threads = True
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server.server_address[1]


def result(run: str, key: str):
    return (RESULTS.get(run) or {}).get(key)


def wait_result(run: str, key: str, seconds: float, done=lambda v: v.get("state") not in ("pending", "starting", "running")):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = result(run, key)
        if value and done(value):
            return value
        time.sleep(0.25)
    value = result(run, key)
    if value and not done(value):
        value = {**value, "ok": False, "state": f"pending after {seconds:g} s"}
    return value or {"ok": False, "state": f"no answer in {seconds:g} s"}


# ---- process CPU -----------------------------------------------------------------------------------------

def cpu_seconds(text: str) -> float:
    days = 0
    if "-" in text:
        d, text = text.split("-", 1)
        days = int(d)
    total = 0.0
    for part in text.split(":"):
        total = total * 60 + float(part)
    return days * 86400 + total


def processes():
    run = subprocess.run(["ps", "-axww", "-o", "pid=,ppid=,time=,command="], capture_output=True, text=True)
    rows = {}
    for line in run.stdout.splitlines():
        m = re.match(r"\s*(\d+)\s+(\d+)\s+(\S+)\s+(.*)", line)
        if m:
            rows[int(m[1])] = (int(m[2]), cpu_seconds(m[3]), m[4])
    return rows


def select(rows, roots: set[int], path: str | None, extra: re.Pattern | None):
    keep = set()
    for pid, (ppid, _, cmd) in rows.items():
        if pid in roots or (path and cmd.startswith(path)) or (extra and extra.search(cmd)):
            keep.add(pid)
    grew = True
    while grew:
        grew = False
        for pid, (ppid, _, _) in rows.items():
            if pid not in keep and ppid in keep:
                keep.add(pid)
                grew = True
    return keep


def cpu_window(seconds: float, roots: set[int], path: str | None, extra: re.Pattern | None = None) -> dict:
    """CPU % of the browser's processes over `seconds` (cumulative CPU time from ps; 100 = one core)."""
    before = processes()
    time.sleep(seconds)  # sleep-ok: the CPU measurement window
    after = processes()
    keep = select(after, roots, path, extra)
    per = []
    for pid in keep:
        ppid, cpu, cmd = after[pid]
        start = before[pid][1] if pid in before and before[pid][2] == cmd else 0.0
        per.append((cpu - start, cmd))
    total = sum(c for c, _ in per)
    per.sort(reverse=True)
    top = [{"pct": round(100 * c / seconds, 1), "cmd": cmd[-110:]} for c, cmd in per[:6]]
    return {"pct": round(100 * total / seconds, 1), "secs": seconds, "procs": len(keep), "top": top}


# ---- cmux side copy --------------------------------------------------------------------------------------

def rpc_at(path, method, params=None, timeout=60):
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(path)
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
    result_ = reply.get("result") if reply.get("ok") else {"error": reply.get("error")}
    return result_ if result_ is not None else {}


class Cmux:
    def __init__(self, side: str, name: str, log):
        self.side, self.name, self.log = side, name, log
        self.sock = None
        self.pid = None
        self.eval_errors = 0
        self.app = subprocess.run([side, "path", name], capture_output=True, text=True).stdout.strip()

    def launch(self, args: list[str]):
        argv = [self.side, "launch", self.name, "--front"] + (["--"] + args if args else [])
        run = subprocess.run(argv, capture_output=True, text=True, timeout=120)
        self.log(f"launch {args or '(no arguments)'}: rc={run.returncode} {run.stdout.strip()[-200:]} {run.stderr.strip()[-300:]}")
        root = Path(os.environ["CMUX_SIDE_ROOT"]) / self.name
        try:
            self.pid = int((root / "pid").read_text().strip())
        except (OSError, ValueError):
            self.pid = None
        named = subprocess.run([self.side, "socket", self.name], capture_output=True, text=True).stdout.strip()
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            reply = rpc_at(named, "system.identify", timeout=5)
            if isinstance(reply, dict) and not reply.get("error"):
                self.sock = named
                break
            time.sleep(0.5)
        self.log(f"control socket {self.sock} pid {self.pid}")
        # The first window and its restore are done once the snapshot's topology reads the same twice.
        if self.sock:
            deadline, last = time.monotonic() + 30, None
            while time.monotonic() < deadline:
                snap = self.rpc("snapshot.get", timeout=10)
                current = json.dumps((snap or {}).get("topology", snap) if isinstance(snap, dict) else snap, sort_keys=True)
                if current == last and not (isinstance(snap, dict) and snap.get("error")):
                    break
                last = current
                time.sleep(0.5)
            else:
                self.log("snapshot still changing 30 s after launch")
        return self.sock is not None

    def stop(self):
        subprocess.run([self.side, "stop", self.name], capture_output=True, text=True, timeout=120)
        self.sock = None

    def rpc(self, method, params=None, timeout=60):
        return rpc_at(self.sock, method, params, timeout) if self.sock else {"error": "no control socket"}

    def action(self, name, target=None, focus=True, **args):
        params = {"action": name, "origin": "script", "focus": focus, "args": args}
        if target:
            params["target"] = target
        return self.rpc("action.run", params, timeout=90)

    def open(self, engine: str, url: str, near: str | None = None):
        reply = self.action("openBrowser." + engine, target=f"tab:{near}" if near else None, url=url)
        tabs = [c for c in (reply.get("created") or []) if str(c).startswith("tab_")]
        if not tabs:
            self.log(f"open {engine}: {json.dumps(reply)[:400]}")
        return tabs[0] if tabs else None

    def page(self, tab, verb, **params):
        params.update(tab=tab, agent=AGENT)
        return self.rpc("browser.page." + verb, params, timeout=45)

    def js(self, tab, script):
        reply = self.page(tab, "eval", script=script)
        if reply.get("error"):
            self.eval_errors += 1
            if self.eval_errors <= 5:
                self.log(f"eval refused: {json.dumps(reply)[:300]}")
            return None
        return reply.get("value")

    def click(self, tab, element_id):
        """A trusted click (the engine's native mouse), the user gesture pip, gdm and notif need."""
        center = self.js(tab, f"__m.center('{element_id}')")
        try:
            x, y = json.loads(center)
        except (TypeError, ValueError):
            x, y = 110, 80
        reply = self.page(tab, "mouse", kind="click", x=x, y=y)
        if reply.get("error"):
            reply = self.page(tab, "click", selector="#" + element_id)
        return reply

    def focus(self, tab):
        return self.action("tab.focus", target=f"tab:{tab}")

    def close(self, tab):
        return self.action("tab.close", target=f"tab:{tab}")


# ---- Chrome over DevTools --------------------------------------------------------------------------------

class WebSocket:
    def __init__(self, url: str):
        m = re.match(r"ws://([^/:]+):(\d+)(/.*)", url)
        self.conn = socket.create_connection((m[1], int(m[2])), timeout=60)
        key = base64.b64encode(os.urandom(16)).decode()
        self.conn.sendall((f"GET {m[3]} HTTP/1.1\r\nHost: {m[1]}:{m[2]}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
                           f"Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n").encode())
        head = b""
        while b"\r\n\r\n" not in head:
            chunk = self.conn.recv(1)
            if not chunk:
                raise OSError("websocket handshake closed")
            head += chunk
        if b" 101 " not in head.split(b"\r\n", 1)[0]:
            raise OSError("websocket handshake: " + head.split(b"\r\n", 1)[0].decode(errors="replace"))

    def send(self, text: str):
        data = text.encode()
        header = bytearray([0x81])
        if len(data) < 126:
            header.append(0x80 | len(data))
        elif len(data) < 65536:
            header += bytes([0x80 | 126]) + len(data).to_bytes(2, "big")
        else:
            header += bytes([0x80 | 127]) + len(data).to_bytes(8, "big")
        mask = os.urandom(4)
        self.conn.sendall(bytes(header) + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(data)))

    def _exact(self, n):
        buf = b""
        while len(buf) < n:
            chunk = self.conn.recv(n - len(buf))
            if not chunk:
                raise OSError("websocket closed")
            buf += chunk
        return buf

    def recv(self) -> str:
        message = b""
        while True:
            b0, b1 = self._exact(2)
            n = b1 & 0x7F
            if n == 126:
                n = int.from_bytes(self._exact(2), "big")
            elif n == 127:
                n = int.from_bytes(self._exact(8), "big")
            payload = self._exact(n)
            opcode = b0 & 0x0F
            if opcode == 8:
                raise OSError("websocket closed by peer")
            if opcode in (0, 1, 2):
                message += payload
                if b0 & 0x80:
                    return message.decode(errors="replace")


class Chrome:
    def __init__(self, binary: str, label: str, flags: list[str], work: Path, url: str, log):
        self.log = log
        self.dir = work / f"chrome-{label}"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.port = free_port()
        argv = [binary, f"--user-data-dir={self.dir}", f"--remote-debugging-port={self.port}", "--no-first-run",
                "--no-default-browser-check", "--disable-search-engine-choice-screen", "--use-mock-keychain", "--window-size=1280,900", *flags, url]
        self.flags = flags
        self.proc = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=open(self.dir / "stderr.log", "w"))
        self.ws = None
        self.next_id = 0
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and not self.ws:
            try:
                targets = json.load(urllib.request.urlopen(f"http://127.0.0.1:{self.port}/json/list", timeout=3))
                page = next(t for t in targets if t.get("type") == "page" and "/t" in t.get("url", ""))
                self.target = page["id"]
                self.ws = WebSocket(page["webSocketDebuggerUrl"])
            except Exception:  # Chrome is still starting
                time.sleep(0.5)
        if not self.ws:
            raise RuntimeError("Chrome gave no DevTools page in 60 s")
        self.call("Runtime.enable")

    def call(self, method, params=None, timeout=60):
        self.next_id += 1
        ident = self.next_id
        self.ws.conn.settimeout(timeout)
        self.ws.send(json.dumps({"id": ident, "method": method, "params": params or {}}))
        while True:
            reply = json.loads(self.ws.recv())
            if reply.get("id") == ident:
                return reply.get("result") if "result" in reply else {"error": reply.get("error")}

    def browser_call(self, method, params=None):
        info = json.load(urllib.request.urlopen(f"http://127.0.0.1:{self.port}/json/version", timeout=5))
        ws = WebSocket(info["webSocketDebuggerUrl"])
        ws.send(json.dumps({"id": 1, "method": method, "params": params or {}}))
        while True:
            reply = json.loads(ws.recv())
            if reply.get("id") == 1:
                ws.conn.close()
                return reply.get("result") or {"error": reply.get("error")}

    def js(self, script, gesture=False):
        reply = self.call("Runtime.evaluate", {"expression": script, "returnByValue": True, "userGesture": gesture})
        return ((reply or {}).get("result") or {}).get("value")

    def click(self, element_id):
        center = self.js(f"__m.center('{element_id}')")
        try:
            x, y = json.loads(center)
        except (TypeError, ValueError):
            x, y = 110, 80
        for kind in ("mousePressed", "mouseReleased"):
            self.call("Input.dispatchMouseEvent", {"type": kind, "x": x, "y": y, "button": "left", "clickCount": 1})

    def version(self):
        try:
            return json.load(urllib.request.urlopen(f"http://127.0.0.1:{self.port}/json/version", timeout=5)).get("Browser")
        except Exception:
            return None

    def quit(self):
        try:
            self.browser_call("Browser.close")
            self.proc.wait(timeout=20)
        except Exception:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.proc.kill()


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def find_chrome(work: Path, log):
    installed = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
    if os.path.exists(installed):
        return installed, "Google Chrome (installed)"
    try:
        feed = json.load(urllib.request.urlopen(
            "https://googlechromelabs.github.io/chrome-for-testing/last-known-good-versions-with-downloads.json", timeout=30))
        url = next(d["url"] for d in feed["channels"]["Stable"]["downloads"]["chrome"] if d["platform"] == "mac-arm64")
        dest = work / "cft"
        dest.mkdir(exist_ok=True)
        subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(dest / "chrome.zip"), url], check=True, timeout=600)
        subprocess.run(["ditto", "-x", "-k", str(dest / "chrome.zip"), str(dest)], check=True, timeout=300)
        app = next(dest.glob("chrome-mac-arm64/*.app"))
        subprocess.run(["xattr", "-dr", "com.apple.quarantine", str(app)], capture_output=True)
        exe = next((app / "Contents/MacOS").iterdir())
        return str(exe), f"Chrome for Testing {feed['channels']['Stable']['version']}"
    except Exception as error:
        log(f"no Chrome: {error}")
        return None, None


# ---- runs ------------------------------------------------------------------------------------------------

class Driver:
    """The browser-neutral steps over either kind of browser (`js`, `click`, `hide`, `show`, `navigate`)."""

    def __init__(self, run: str, js, click, hide, show, navigate, cpu, log):
        self.run, self.js, self.click, self.hide, self.show, self.navigate, self.cpu, self.log = (
            run, js, click, hide, show, navigate, cpu, log)

    def step(self, name, wait=GUM_WAIT, button=None, arg=None):
        if button:
            self.click(button)
        else:
            self.js(f"__m.start('{name}', {json.dumps(arg)})")
        value = wait_result(self.run, name, wait)
        self.log(f"  {self.run} {name}: {json.dumps(value)[:300]}")
        return value

    def media(self, out: dict, full: bool):
        out["info"] = wait_result(self.run, "info", 15, done=lambda v: True)
        out["gum"] = self.step("gum")
        out["devices"] = self.step("devices", 5)
        out["perms"] = self.step("perms", 5)
        out["notif"] = self.step("notif", button="b-notif")
        out["pip"] = self.step("pip", 10, button="b-pip")
        if full:
            out["loop"] = self.loop()
            out["hidden"] = self.hidden()
        out["gdm"] = self.step("gdm", button="b-gdm")

    def loop(self):
        secs = OPTS.call
        idle = self.cpu(10)
        self.js(f"__m.start('loop', {secs})")
        # The call window starts once both peers are connected (the page sets R.loop running).
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            try:
                state = (json.loads(self.js("__m.read('loop')") or "null") or {}).get("state")
            except (TypeError, ValueError, AttributeError):
                state = None
            if state in ("running", "done", "threw"):
                break
            time.sleep(0.1)
        else:
            self.log(f"  {self.run} loop: call not running 15 s after start")
        busy = self.cpu(max(10, secs - 6))
        value = wait_result(self.run, "loop", secs + 20)
        value = {k: v for k, v in value.items() if k != "samples"} | {"samples": value.get("samples", [])[-5:]}
        value["cpuIdle"], value["cpuCall"] = idle, busy
        self.log(f"  {self.run} loop: fps {value.get('fpsMedian')} rtt {value.get('rttMsMedian')} ms cpu idle {idle['pct']} call {busy['pct']}")
        return value

    def hidden(self):
        self.js("__m.start('hiddenStart')")
        # A visible baseline: 20 visible timer ticks (100 ms each) logged before the tab is covered.
        self.wait_ticks("visible", 20, 15)
        hidden_how = self.hide()
        time.sleep(20)  # sleep-ok: the hidden window, the timer's throttling over 20 s covered is what is measured
        self.show()
        # Uncovered: wait until the page logs visible ticks again (10 of them, after the hidden ones).
        self.wait_ticks("visible", 10, 15, after="hidden")
        self.js("__m.start('hiddenStop')")
        value = wait_result(self.run, "hidden", 10)
        value["how"] = hidden_how
        self.log(f"  {self.run} hidden: {json.dumps(value)[:300]}")
        return value

    def wait_ticks(self, state, count, seconds, after=None):
        """Wait until the page's hidden-test log has `count` ticks in `state` (after the last `after` tick)."""
        expr = (f"(() => {{ const l = __m.R.hiddenLog || []; let i = {json.dumps(after)} ? "
                f"l.map(z => z[1]).lastIndexOf({json.dumps(after)}) : -1; "
                f"return l.slice(i + 1).filter(z => z[1] === {json.dumps(state)}).length; }})()")
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            try:
                if int(self.js(expr) or 0) >= count:
                    return True
            except (TypeError, ValueError):
                pass
            time.sleep(0.1)
        self.log(f"  {self.run} hidden: fewer than {count} {state} ticks in {seconds} s")
        return False

    def meet(self):
        out = {}
        for phase in ("cold", "warm"):
            started = time.monotonic()
            nav = self.navigate(MEET)
            seen = None
            while time.monotonic() - started < 60:
                try:
                    seen = json.loads(self.js(NAV_JS) or "null")
                except ValueError:
                    seen = None
                if seen and (seen.get("load") or 0) > 0 and "google" in (seen.get("url") or ""):
                    break
                time.sleep(0.25)
            ok = bool(seen and (seen.get("load") or 0) > 0)
            out[phase] = {"ok": ok, "loadMs": seen.get("load") if seen else None, "dclMs": seen.get("dcl") if seen else None,
                          "ttfbMs": seen.get("ttfb") if seen else None, "url": seen.get("url") if seen else None,
                          "wallS": round(time.monotonic() - started, 2), "nav": nav}
            self.log(f"  {self.run} meet {phase}: {json.dumps(out[phase])[:300]}")
            if phase == "cold":
                self.navigate(f"{BASE}/blank")
                time.sleep(2)
        return out


def run_cmux(cmux: Cmux, run: str, engine: str, full: bool, meet: bool, log) -> dict:
    out: dict = {"browser": f"cmux {engine}"}
    tab = cmux.open(engine, f"{BASE}/t?run={run}")
    if not tab:
        out["error"] = "tab was not created"
        return out
    out["tab"] = tab
    wait_result(run, "info", 30, done=lambda v: True)
    covers = []

    def hide():
        cover = cmux.open(engine, f"{BASE}/blank", near=tab)
        if cover:
            covers.append(cover)
        return "a newer tab in the same pane covers it" if cover else "no cover tab"

    def show():
        return cmux.focus(tab)

    def navigate(url):
        reply = cmux.page(tab, "navigate", url=url)
        return reply.get("error")

    app_path = cmux.app + "/" if cmux.app else None
    webkit = re.compile(r"com\.apple\.WebKit\.(WebContent|GPU|Networking)") if engine == "webkit" else None
    driver = Driver(run, lambda s: cmux.js(tab, s), lambda b: cmux.click(tab, b), hide, show, navigate,
                    lambda secs: cpu_window(secs, {cmux.pid} if cmux.pid else set(), app_path, webkit), log)
    driver.media(out, full)
    if meet:
        out["meet"] = driver.meet()
    for t in covers + [tab]:
        cmux.close(t)
    return out


def run_chrome(binary: str, label: str, run: str, flags: list[str], full: bool, meet: bool, work: Path, log) -> dict:
    out: dict = {"browser": label, "flags": flags}
    try:
        chrome = Chrome(binary, run, flags, work, f"{BASE}/t?run={run}", log)
    except Exception as error:
        out["error"] = str(error)
        return out
    out["version"] = chrome.version()
    wait_result(run, "info", 30, done=lambda v: True)
    extra: list[str] = []

    def hide():
        reply = chrome.browser_call("Target.createTarget", {"url": f"{BASE}/blank"})
        if reply.get("targetId"):
            extra.append(reply["targetId"])
        return "a new foreground tab in the same window"

    def show():
        chrome.browser_call("Target.activateTarget", {"targetId": chrome.target})
        for target in extra:
            chrome.browser_call("Target.closeTarget", {"targetId": target})
        extra.clear()

    def navigate(url):
        reply = chrome.call("Page.navigate", {"url": url})
        return (reply or {}).get("errorText") or (reply or {}).get("error")

    driver = Driver(run, chrome.js, chrome.click, hide, show, navigate,
                    lambda secs: cpu_window(secs, {chrome.proc.pid}, None), log)
    try:
        driver.media(out, full)
        if meet:
            out["meet"] = driver.meet()
    except Exception as error:
        out["error"] = f"{type(error).__name__}: {error}"
    chrome.quit()
    return out


# ---- table -----------------------------------------------------------------------------------------------

def cell_media(v):
    if not v:
        return "not run"
    state = v.get("state", "?")
    if state == "resolved":
        return f"pass {v.get('ms')} ms"
    if state == "rejected" or state == "threw":
        return f"fail {v.get('error')}"
    return f"fail {state}"


def cell(run: dict, key: str) -> str:
    if run.get("error") and key not in run:
        return "error: " + run["error"][:60]
    v = run.get(key)
    if key in ("gum", "gdm"):
        return cell_media(v)
    if key == "pip":
        if not v:
            return "not run"
        enabled = (run.get("info") or {}).get("pipEnabled")
        base = f"pass {v.get('width')}x{v.get('height')}" if v.get("state") == "resolved" else (
            f"fail {v.get('error') or v.get('state')}")
        return f"{base} (enabled={str(enabled).lower()})"
    if key == "notif":
        if not v:
            return "not run"
        if v.get("state") == "resolved":
            return f"{'pass' if v.get('result') == 'granted' else 'fail'} {v.get('before')} -> {v.get('result')}"
        return f"fail {v.get('error') or v.get('state')} (was {v.get('before')})"
    if key == "loop":
        if not v:
            return "not run"
        return (f"{'pass' if v.get('ok') else 'fail'} {v.get('fpsMedian')} fps, rtt {v.get('rttMsMedian')} ms, "
                f"{v.get('size')}, CPU {v['cpuCall']['pct']}% (idle {v['cpuIdle']['pct']}%)")
    if key == "hidden":
        if not v:
            return "not run"
        h = v.get("hidden") or {}
        return (f"{'pass' if (h.get('meanMs') or 1e9) < 1100 else 'fail'} mean {h.get('meanMs')} ms, max {h.get('maxMs')} ms "
                f"({h.get('ticks')} ticks)" if h.get("ticks") else "fail: never hidden")
    if key.startswith("meet"):
        m = (run.get("meet") or {}).get(key.split("_")[1])
        if not m:
            return "not run"
        return f"{'pass' if m['ok'] else 'fail'} {m.get('loadMs')} ms"
    return "?"


ROWS = [("getUserMedia (camera+mic)", "gum"), ("getDisplayMedia", "gdm"), ("Picture-in-Picture", "pip"),
        ("Notification.requestPermission", "notif"), ("loopback call 720p", "loop"),
        ("hidden-tab 100 ms timer", "hidden"), ("meet.google.com load, cold", "meet_cold"),
        ("meet.google.com load, warm", "meet_warm")]


def table(runs: dict, header: str) -> str:
    names = list(runs)
    lines = [header, "", "| | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]
    for title, key in ROWS:
        lines.append(f"| {title} | " + " | ".join(cell(runs[n], key) for n in names) + " |")
    lines.append("")
    for n in names:
        flags = runs[n].get("flags")
        lines.append(f"- {n}: {runs[n].get('browser')}{' ' + runs[n]['version'] if runs[n].get('version') else ''}; "
                     f"flags: {' '.join(flags) if flags else 'none'}")
    return "\n".join(lines) + "\n"


# ---- main ------------------------------------------------------------------------------------------------

def main():
    global OPTS, BASE
    parser = argparse.ArgumentParser()
    for flag in ("--side", "--name", "--work", "--out", "--dmg", "--version"):
        parser.add_argument(flag, required=True)
    parser.add_argument("--call", type=int, default=60)
    parser.add_argument("--only", default="")
    OPTS = parser.parse_args()
    out_dir, work = Path(OPTS.out), Path(OPTS.work)
    only = set(filter(None, OPTS.only.split(",")))
    want = lambda name: not only or name in only  # noqa: E731

    def log(text):
        print(f"MEET {text}", flush=True)

    BASE = f"http://127.0.0.1:{serve()}"
    log(f"test page {BASE}/t")
    runs: dict[str, dict] = {}
    cmux = Cmux(OPTS.side, OPTS.name, log)

    if want("cmux-chromium") or want("cmux-webkit"):
        if cmux.launch([]):
            if want("cmux-chromium"):
                runs["cmux-chromium"] = run_cmux(cmux, "cmux-chromium", "chromium", True, True, log) | {"flags": []}
            if want("cmux-webkit"):
                runs["cmux-webkit"] = run_cmux(cmux, "cmux-webkit", "webkit", True, True, log) | {"flags": []}
        else:
            for n in ("cmux-chromium", "cmux-webkit"):
                if want(n):
                    runs[n] = {"browser": "cmux", "error": "the side copy gave no control socket"}
        cmux.stop()
    if want("cmux-chromium-fake"):
        if cmux.launch(FAKE):
            runs["cmux-chromium-fake"] = run_cmux(cmux, "cmux-chromium-fake", "chromium", False, False, log) | {
                "flags": FAKE + ["(as app arguments)"]}
        else:
            runs["cmux-chromium-fake"] = {"browser": "cmux chromium", "error": "the side copy gave no control socket"}
        cmux.stop()
    if want("chrome-fake") or want("chrome-plain"):
        binary, label = find_chrome(work, log)
        if not binary:
            for n in ("chrome-fake", "chrome-plain"):
                if want(n):
                    runs[n] = {"browser": "Chrome", "error": "no Chrome on this Mac and Chrome for Testing did not download"}
        else:
            if want("chrome-fake"):
                runs["chrome-fake"] = run_chrome(binary, label, "chrome-fake", FAKE, True, True, work, log)
            if want("chrome-plain"):
                runs["chrome-plain"] = run_chrome(binary, label, "chrome-plain", FAKE[:1], False, False, work, log)

    host = subprocess.run(["hostname", "-s"], capture_output=True, text=True).stdout.strip()
    macos = subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip()
    header = (f"Meet-in-browser measurement: cmux NEXT NIGHTLY {OPTS.version} on {host} (macOS {macos}), "
              f"local test page on 127.0.0.1, loopback call {OPTS.call} s. CPU is the browser's processes from ps "
              "(100% = one core; cmux: every process of the copy, WebKit adds the system WebContent/GPU/Networking).")
    report = {"host": host, "macos": macos, "dmg": OPTS.dmg, "version": OPTS.version, "call": OPTS.call, "runs": runs}
    (out_dir / "results.json").write_text(json.dumps(report, indent=2))
    (out_dir / "table.md").write_text(table(runs, header))
    print("MEET_BROWSER " + json.dumps(report)[:20000], flush=True)
    return 0 if runs and not any(r.get("error") for r in runs.values()) else 1


OPTS = None
BASE = ""
if __name__ == "__main__":
    raise SystemExit(main())
