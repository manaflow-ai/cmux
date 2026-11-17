#!/usr/bin/env python3
"""Launch image capture probe (launch-capture-probe/v1): can the app picture its own window with no Screen Recording
grant, what does the picture hold, and what does each source cost.

Leo, 2026-11-17: "can we really get <300ms startup? 🤔 i know we can at least start up shells of stuff fresh". The
launch image design shows each window's last frame at the next launch: the window server's composite of the app's own
window (NSWindow.screenshotImage(includeChild:), CGWindowListCreateImage) for the chrome and the terminals, plus each
shown Chromium page's own image (CEF Page.captureScreenshot) painted at its frame. This probe checks the three things
the design rests on, on one launch of a NIGHTLY or a built app (scripts/measure/launch-capture-probe.sh):

  (a) grant  No permission prompt and no kTCCServiceScreenCapture row for the app's bundle id: the user and the system
             TCC.db and replayd's ScreenCaptureApprovals.plist read before and after (an unreadable one says why: the
             step's process has no Full Disk Access), tccd's log while the captures run, and a poll every 250 ms of
             the processes and on-screen window owners that show a consent prompt (UserNotificationCenter,
             universalAccessAuthWarn, SecurityAgent, CoreServicesUIAgent).
  (b) pixels One window: a terminal printing red-backed text (left pane) beside a Chromium page that is solid blue
             (right pane). Each of the app's pictures of it against the screen's own pixels of the window (CuaDriver's
             display image, under CuaDriver's grant, never the app's), as shares of red and blue pixels and the mean
             difference from the screen: `window.screenshot` (what `cmux window screenshot` gives a script: masked),
             and on a build with the debug commands (config=bench) `debug.window_snapshot` with `webviews: false`
             (the window server's composite alone, Chromium's child window included) and with the page images.
  (c) cost   Per source, ROUNDS runs: the control round trip (ms, p50/p95/max) and the app's main-thread stall during
             it (`debug.hangs`: the longest main-thread turn and the turns over 8.3 ms, cleared before each run), with
             an idle row of the same wait as the baseline. Sources: window.screenshot, debug.window_snapshot raw and
             with pages (bench builds; pages less raw is the Page.captureScreenshot cost). browser.page.screenshot
             is tried once shown and once hidden behind a terminal tab: the socket refuses it to scripts by design.

Writes OUT/report.json, OUT/report.md and the pictures (OUT/images/*.png: the screen's window, each composite, the
page image). Exit 0 once the report is written (an artifact comes back only from a passing step), 3 when it could
not measure. Kills only what it started: its app copy (its bundle's processes), its marker, its log stream.
"""
from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import pwd
import shutil
import sqlite3
import statistics
import struct
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(os.path.dirname(HERE))
sys.path.insert(0, os.path.join(ROOT, "scripts", "cmux-next"))
import tab_switch_capture as capture  # noqa: E402
import tab_switch_frames as frames  # noqa: E402

SCHEMA = "launch-capture-probe/v1"
PROMPT_PROCESSES = ("UserNotificationCenter", "universalAccessAuthWarn", "SecurityAgent", "CoreServicesUIAgent")
RED = (220, 30, 30)
BLUE = (0x2A, 0x6F, 0xDB)  # tab_switch_frames.page_html's background
TERMINAL_TEXT = ("for i in $(seq 1 24); do printf '\\033[48;2;220;30;30;38;2;255;255;255m  LAUNCH CAPTURE PROBE "
                 "terminal line %02d  \\033[0m\\n' $i; done\r")
WINDOWS_JXA = r"""
ObjC.import('CoreGraphics');
var a = ObjC.castRefToObject($.CGWindowListCopyWindowInfo(1, 0));
var out = [];
for (var i = 0; i < a.count; i++) {
  var d = a.objectAtIndex(i);
  out.push({owner: ObjC.unwrap(d.objectForKey('kCGWindowOwnerName')), pid: ObjC.unwrap(d.objectForKey('kCGWindowOwnerPID')),
            layer: ObjC.unwrap(d.objectForKey('kCGWindowLayer'))});
}
JSON.stringify(out);
"""


def say(*parts):
    print("LCP", *parts, flush=True)


def real_home():
    return pwd.getpwuid(os.getuid()).pw_dir


# ---------------------------------------------------------------------------------------------------------------
# (a) The grant: TCC rows, prompt processes and windows, tccd's log.

def tcc_rows(bundle_id):
    """kTCCServiceScreenCapture rows of the user and the system TCC.db, and replayd's approvals, or why unreadable."""
    found = {}
    for name, path in (("user", os.path.join(real_home(), "Library/Application Support/com.apple.TCC/TCC.db")),
                       ("system", "/Library/Application Support/com.apple.TCC/TCC.db")):
        try:
            conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=5)
            try:
                rows = conn.execute("SELECT service, client, auth_value, auth_reason, last_modified FROM access "
                                    "WHERE service = 'kTCCServiceScreenCapture'").fetchall()
            finally:
                conn.close()
            found[name] = {"readable": True, "screen_capture_rows": [list(r) for r in rows],
                           "app_rows": [list(r) for r in rows if r[1] == bundle_id]}
        except sqlite3.Error as error:
            found[name] = {"readable": False, "error": str(error)}
    approvals = os.path.join(real_home(), "Library/Group Containers/group.com.apple.replayd/ScreenCaptureApprovals.plist")
    try:
        with open(approvals, "rb") as handle:
            data = plistlib.load(handle)
        found["replayd_approvals"] = {"readable": True, "keys": sorted(map(str, data))[:50],
                                      "app_entry": bundle_id in json.dumps(data, default=str)}
    except FileNotFoundError:
        found["replayd_approvals"] = {"readable": True, "missing": True, "app_entry": False}
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        found["replayd_approvals"] = {"readable": False, "error": str(error)}
    return found


class PromptWatch:
    """Polls every 250 ms: consent-prompt processes and the owners of on-screen windows (no grant needed for owners)."""

    def __init__(self):
        self.stop_flag = threading.Event()
        self.paused = threading.Event()  # set while the timing rounds run: the polls would load the Mac they time
        self.ignore = set()
        self.processes = {}  # name -> first seen (s since start), a prompt process not running before
        self.base_processes = set()
        self.windows = {}  # owner -> first seen
        self.window_errors = []
        self.polls = 0
        self.base_owners = None
        self.t0 = time.monotonic()
        self.thread = threading.Thread(target=self.run, daemon=True)

    def owners(self):
        try:
            done = subprocess.run(["osascript", "-l", "JavaScript", "-e", WINDOWS_JXA], capture_output=True, text=True,
                                  timeout=10)
            return {w.get("owner") or "?" for w in json.loads(done.stdout or "[]")}
        except (OSError, subprocess.SubprocessError, ValueError) as error:
            if len(self.window_errors) < 3:
                self.window_errors.append(str(error)[:200])
            return None

    def start(self):
        self.base_owners = self.owners()
        self.base_processes = {n for n in self.process_names() if n in PROMPT_PROCESSES}
        self.thread.start()

    @staticmethod
    def process_names():
        try:
            listing = subprocess.run(["ps", "-axo", "comm="], capture_output=True, text=True, timeout=10).stdout
        except (OSError, subprocess.SubprocessError):
            listing = ""
        return {os.path.basename(line.strip()) for line in listing.splitlines()}

    def run(self):
        while not self.stop_flag.is_set():
            if self.paused.is_set():
                self.stop_flag.wait(0.25)
                continue
            self.polls += 1
            now = round(time.monotonic() - self.t0, 2)
            for name in self.process_names():
                if name in PROMPT_PROCESSES and name not in self.base_processes:
                    self.processes.setdefault(name, now)
            owners = self.owners()
            if owners is not None:
                for owner in owners:
                    if owner in self.ignore:
                        continue
                    if self.base_owners is not None and owner not in self.base_owners:
                        self.windows.setdefault(owner, now)
            self.stop_flag.wait(0.25)

    def stop(self):
        self.stop_flag.set()
        self.thread.join(timeout=15)
        return {"polls": self.polls, "new_prompt_processes_seen": self.processes,
                "prompt_processes_before": sorted(self.base_processes),
                "new_window_owners_seen": self.windows, "base_window_owners": sorted(self.base_owners or []),
                "window_list_errors": self.window_errors}


class TccLog:
    """`log stream` of tccd and the TCC subsystem while the captures run; lines naming ScreenCapture are kept."""

    def __init__(self, folder):
        self.path = os.path.join(folder, "tcc-log.ndjson")
        self.handle = open(self.path, "w")
        try:
            self.process = subprocess.Popen(
                ["log", "stream", "--style", "ndjson", "--level", "debug", "--predicate",
                 'subsystem == "com.apple.TCC" OR process == "tccd"'], stdout=self.handle, stderr=subprocess.STDOUT,
                start_new_session=True)
        except OSError as error:
            self.process, self.error = None, str(error)

    @staticmethod
    def app_requests(lines, bundle_id):
        """tccd's kTCCServiceScreenCapture requests whose requesting process is BUNDLE_ID: per msgID the function,
        preflight, the responsible process and AUTHREQ_RESULT (authValue 0 denied, 1 unknown, 2 allowed)."""
        found = {}
        for line in lines:
            try:
                message = json.loads(line).get("eventMessage") or ""
            except ValueError:
                continue
            match = re.search(r"msgID=([0-9.]+)", message)
            if not match:
                continue
            entry = found.setdefault(match.group(1), {})
            grab = lambda pattern: (re.search(pattern, message) or [None, None])[1]  # noqa: E731
            if message.startswith("AUTHREQ_CTX:"):
                entry.update(service=grab(r"service=(\w+)"), function=grab(r"function=(\w+)"),
                             preflight=grab(r"preflight=(\w+)"))
            elif message.startswith("AUTHREQ_ATTRIBUTION:"):
                entry.update(requesting=grab(r"requesting=\{TCCDProcess: identifier=([^,]+)"),
                             responsible=grab(r"responsible=\{TCCDProcess: identifier=([^,]+)"))
            elif message.startswith("AUTHREQ_RESULT:"):
                entry["result"] = message[len("AUTHREQ_RESULT: "):][:160]
        return [dict(e, msg_id=k) for k, e in found.items()
                if e.get("service") == "kTCCServiceScreenCapture" and e.get("requesting") == bundle_id]

    def stop(self, bundle_id, executable):
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()  # our own child
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
        self.handle.close()
        lines = Path(self.path).read_text(errors="replace").splitlines()
        requests = self.app_requests(lines, bundle_id)
        screen = [line for line in lines if "ScreenCapture" in line]
        app = [line for line in screen if bundle_id in line or (executable and executable in line)]
        return {"app_screen_capture_requests": requests, "lines": len(lines), "screen_capture_lines": len(screen), "screen_capture_lines_naming_app": len(app),
                "app_examples": [line[:600] for line in app[:5]], "screen_examples": [line[:400] for line in screen[:5]],
                "first_line": lines[0][:300] if lines else None}


# ---------------------------------------------------------------------------------------------------------------
# (b) Pixels: a PNG read through sips (BMP, scaled down), shares of the probe's colors, difference from the screen.

def read_image(png, width=560):
    """(w, h, rows of (r, g, b)) of PNG scaled to WIDTH, through sips's BMP: no imaging module on a fleet Mac."""
    bmp = png + ".bmp"
    subprocess.run(["sips", "--resampleWidth", str(width), "-s", "format", "bmp", png, "--out", bmp],
                   capture_output=True, timeout=60)
    data = Path(bmp).read_bytes()
    os.remove(bmp)
    offset = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    step = bpp // 8
    stride = (w * step + 3) & ~3
    rows = []
    for y in range(abs(h)):
        row = y if h < 0 else abs(h) - 1 - y
        base = offset + row * stride
        rows.append([(data[base + x * step + 2], data[base + x * step + 1], data[base + x * step]) for x in range(w)])
    return w, abs(h), rows


def near(pixel, color, tolerance):
    return abs(pixel[0] - color[0]) + abs(pixel[1] - color[1]) + abs(pixel[2] - color[2]) < tolerance


def region(image, x0, x1):
    w, h, rows = image
    return [p for row in rows for p in row[int(w * x0):int(w * x1)]]


def stats(image, screen=None):
    """Shares of red (the terminal text's cells) and blue (the page) in the left and right halves, the right half's
    most common color, and with SCREEN the mean absolute difference per channel from it (same size after scaling)."""
    left, right = region(image, 0.0, 0.5), region(image, 0.5, 1.0)
    share = lambda pixels, color: round(sum(near(p, color, 70) for p in pixels) / max(1, len(pixels)), 4)  # noqa: E731
    counts = {}
    for p in right[::7]:
        key = (p[0] >> 4 << 4, p[1] >> 4 << 4, p[2] >> 4 << 4)
        counts[key] = counts.get(key, 0) + 1
    common = max(counts.items(), key=lambda kv: kv[1]) if counts else ((0, 0, 0), 0)
    out = {"size": [image[0], image[1]], "left_red_share": share(left, RED), "right_blue_share": share(right, BLUE),
           "right_common_color": "#%02x%02x%02x" % common[0],
           "right_common_share": round(common[1] / max(1, len(right[::7])), 3)}
    if screen is not None:
        w, h = min(image[0], screen[0]), min(image[1], screen[1])

        def mad(x0, x1):
            total = n = 0
            for y in range(0, h, 2):
                a, b = image[2][y], screen[2][y]
                for x in range(int(w * x0), int(w * x1), 2):
                    total += abs(a[x][0] - b[x][0]) + abs(a[x][1] - b[x][1]) + abs(a[x][2] - b[x][2])
                    n += 3
            return round(total / max(1, n), 2)
        out["mad_vs_screen"] = {"all": mad(0, 1), "left": mad(0, 0.5), "right": mad(0.5, 1)}
    return out


def cua(tool, args, timeout=60):
    """One CuaDriver call through the host's daemon (its grant, not the app's)."""
    done = subprocess.run([capture.CUA_DRIVER, "call", tool, json.dumps(args)], capture_output=True, text=True,
                          timeout=timeout, env=capture.driver_env())
    try:
        answer = json.loads(done.stdout) if done.stdout.strip() else {}
    except ValueError:
        answer = {}
    if done.returncode != 0 or answer.get("isError"):
        return {"error": f"cua-driver {tool}: exit {done.returncode}: {(done.stderr or done.stdout).strip()[-300:]}"}
    return answer


def screen_window(rect, out):
    """The screen's own pixels of RECT (points, top-left origin) through CuaDriver's display image, cut with sips."""
    full = os.path.join(os.path.realpath(os.path.dirname(out)), "display-full.png")  # CuaDriver refuses /tmp's link
    reply = cua("get_desktop_state", {"screenshot_out_file": full})
    if reply.get("error") or not os.path.exists(full):
        return reply.get("error") or "no display image"
    scale = float(reply.get("screenshot_width") or 0) / float(reply.get("screen_width") or 1)
    if not scale:
        scale = float(cua("get_screen_size", {}).get("scale_factor") or 0) or 2.0
    x, y, w, h = rect
    subprocess.run(["sips", "-c", str(round(h * scale)), str(round(w * scale)), "--cropOffset", str(round(y * scale)),
                    str(round(x * scale)), full, "--out", out], capture_output=True, timeout=60)
    os.remove(full)  # the whole display can show more than the app: only the window is kept
    return None if os.path.exists(out) else "sips cut nothing"


# ---------------------------------------------------------------------------------------------------------------
# The app and the workload.

def tabs_of(control, workspace_id):
    panes = []
    for workspace in control.topology().get("workspaces") or []:
        if workspace.get("id") != workspace_id:
            continue
        for screen in workspace.get("screens") or []:
            panes += screen.get("panes") or []
    return panes


def wait_for(check, limit, what):
    deadline = time.monotonic() + limit
    while time.monotonic() < deadline:
        got = check()
        if got:
            return got
        time.sleep(0.25)  # test script: waiting for the app's model
    raise frames.Unmeasurable(f"no {what} in {limit} s")


def build_workload(control, root):
    """A new workspace: the left pane's terminal prints red-backed text, the right pane shows a blue Chromium page."""
    before = {w.get("id") for w in control.topology().get("workspaces") or []}
    reply = control.action("workspace new")
    if reply.get("error"):
        raise frames.Unmeasurable(f"workspace new: {reply['error']}")
    workspace = wait_for(lambda: next((w.get("id") for w in control.topology().get("workspaces") or []
                                       if w.get("id") not in before), None), 30, "new workspace")
    left = wait_for(lambda: next((p for p in tabs_of(control, workspace) if p.get("tabs")), None), 30, "terminal")
    terminal = left["tabs"][0]["id"]
    time.sleep(1.5)  # test script: the shell starts
    reply = control.action("terminal.sendText", target=f"tab:{terminal}", text=TERMINAL_TEXT)
    if reply.get("error"):
        raise frames.Unmeasurable(f"terminal.sendText: {reply['error']}")
    reply = control.action("splitRight", target=f"pane:{left['id']}")
    if reply.get("error"):
        raise frames.Unmeasurable(f"splitRight: {reply['error']}")
    right = wait_for(lambda: next((p for p in tabs_of(control, workspace) if p.get("id") != left["id"] and p.get("tabs")),
                                  None), 30, "right pane")
    right_terminal = right["tabs"][0]["id"]
    page = os.path.join(root, "page.html")
    Path(page).write_text(frames.page_html())
    reply = control.action("openBrowser.chromium", target=f"tab:{right_terminal}", url="file://" + page)
    if reply.get("error"):
        raise frames.Unmeasurable(f"openBrowser.chromium: {reply['error']}")
    known = {right_terminal, terminal}
    chromium = wait_for(lambda: next((t.get("id") for p in tabs_of(control, workspace) for t in p.get("tabs") or []
                                      if t.get("id") not in known and not str(t.get("id")).startswith("pending_")),
                                     None), 30, "Chromium tab")
    time.sleep(3)  # test script: the page loads and paints
    return {"workspace": workspace, "left_pane": left["id"], "terminal": terminal, "right_pane": right["id"],
            "right_terminal": right_terminal, "chromium": chromium}


def find_key(value, key):
    if isinstance(value, dict):
        if key in value:
            return value[key]
        for item in value.values():
            found = find_key(item, key)
            if found is not None:
                return found
    elif isinstance(value, list):
        for item in value:
            found = find_key(item, key)
            if found is not None:
                return found
    return None


def pct(values, q):
    ordered = sorted(values)
    return round(ordered[min(len(ordered) - 1, int(round(q * (len(ordered) - 1))))], 1) if ordered else None


class Sources:
    def __init__(self, control, ids, scratch, has_debug):
        self.c, self.ids, self.scratch, self.has_debug = control, ids, scratch, has_debug

    def names(self):
        # browser.page.screenshot is tried once, not timed: the socket refuses it unless a person runs it (the app
        # builds BrowserPageService without allowsUnsafeCapture). On a bench build the page image's cost is
        # debug.window_snapshot.pages less .raw (the same composite plus each page's Page.captureScreenshot).
        names = ["idle", "window.screenshot"]
        if self.has_debug:
            names[1:1] = ["debug.window_snapshot.raw", "debug.window_snapshot.pages"]
        return names

    def run(self, name, index):
        path = os.path.join(self.scratch, f"{name}-{index}.png")
        if name == "idle":
            # The baseline: the same debug.hangs reads around a no-op (a step's 150 ms sleep came back as 295 ms).
            return {}, None
        if name == "window.screenshot":
            reply = self.c.action("window.screenshot", focus=False, out=path)
        elif name == "debug.window_snapshot.raw":
            reply = self.c.call("debug.window_snapshot", {"kind": "main", "webviews": False, "path": path}, timeout=60)
        elif name == "debug.window_snapshot.pages":
            reply = self.c.call("debug.window_snapshot", {"kind": "main", "path": path}, timeout=60)
        else:
            reply = self.c.call("browser.page.screenshot", {"tab": self.ids["chromium"]}, timeout=60)
        error = (reply or {}).get("error") if isinstance(reply, dict) else None
        got = find_key(reply, "path") if not error else None
        return reply, (got if got and os.path.exists(got) else None) if not error else None

    def measure(self, name, index):
        self.c.call("debug.hangs", {"clear": True}, timeout=10)
        t0 = time.perf_counter()
        reply, png = self.run(name, index)
        ms = (time.perf_counter() - t0) * 1000
        hangs = self.c.call("debug.hangs", {"limit": 5}, timeout=10) or {}
        error = reply.get("error") if isinstance(reply, dict) else None
        return {"ms": round(ms, 2), "ok": png is not None or name == "idle", "error": str(error)[:300] if error else None,
                "png": png, "main_max_turn_ms": hangs.get("max_gap_ms"), "main_turns_over_8_3ms": hangs.get("frames_over_8_3ms"),
                "main_stalls": hangs.get("count"), "main_stall_max_ms": hangs.get("max_ms"),
                "watchdog": hangs.get("installed"), "extra": self.extra(reply)}

    @staticmethod
    def extra(reply):
        """The capture's own facts: at the top of a debug reply, under `result` of an action.run reply."""
        if not isinstance(reply, dict):
            return {}
        facts = reply.get("result") if isinstance(reply.get("result"), dict) else reply
        return {k: facts[k] for k in ("method", "child_windows", "chromium_pages", "chromium_pages_failed", "masked",
                                      "width", "height", "webviews", "webviews_failed") if k in facts}


def summarize(runs):
    good = [r for r in runs if r["ok"]]
    times = [r["ms"] for r in good]
    stalls = [r["main_max_turn_ms"] for r in good if isinstance(r.get("main_max_turn_ms"), (int, float))]
    return {"runs": len(runs), "ok": len(good), "errors": sorted({r["error"] for r in runs if r["error"]})[:3],
            "ms_p50": pct(times, 0.5), "ms_p95": pct(times, 0.95), "ms_max": round(max(times), 1) if times else None,
            "main_max_turn_ms_p50": pct(stalls, 0.5), "main_max_turn_ms_p95": pct(stalls, 0.95),
            "main_max_turn_ms_max": round(max(stalls), 1) if stalls else None,
            "turns_over_8_3ms_p50": pct([r["main_turns_over_8_3ms"] or 0 for r in good], 0.5),
            "extra": good[-1]["extra"] if good else {}}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app")
    parser.add_argument("--dmg")
    parser.add_argument("--build", default="unknown")
    parser.add_argument("--tools", required=True, help="the compiled scripts/measure/tab-switch-frames/tools.swift")
    parser.add_argument("--rounds", type=int, default=12)
    parser.add_argument("--out", default=os.path.join(os.getcwd(), ".build/launch-capture-probe"))
    args = parser.parse_args(argv)
    if not (args.app or args.dmg):
        parser.error("--app or --dmg")
    images = os.path.join(args.out, "images")
    os.makedirs(images, exist_ok=True)
    smoke = frames.load_smoke()
    fresh_env = smoke.fresh_env
    # One-frame stalls get their own records (the watchdog's default threshold is 50 ms).
    smoke.fresh_env = lambda *a: dict(fresh_env(*a), CMUX_NEXT_HANG_THRESHOLD_MS="8")
    root = tempfile.mkdtemp(prefix="launch-capture-")
    report = {"schema": SCHEMA, "build": args.build, "rounds": args.rounds,
              "host": {"chip": subprocess.run(["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
                       "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
                       "host": os.uname().nodename}}
    app = watch = tcc_log = None
    status = 3
    try:
        bundle = str(smoke.copy_app_from_dmg(Path(args.dmg), Path(root))) if args.dmg else os.path.realpath(args.app)
        bundle_id, executable = smoke.bundle_info(Path(bundle))
        report["bundle_id"], report["executable"] = bundle_id, executable
        report["bundle_version"] = subprocess.run(["defaults", "read", os.path.join(bundle, "Contents/Info"), "CFBundleVersion"],
                                                  capture_output=True, text=True).stdout.strip()
        report["signing"] = subprocess.run(["codesign", "-dv", bundle], capture_output=True, text=True).stderr.strip()[-600:]
        report["tcc_before"] = tcc_rows(bundle_id)
        say("tcc before", json.dumps(report["tcc_before"])[:800])
        watch = PromptWatch()
        watch.start()
        tcc_log = TccLog(args.out)
        watch.ignore = {executable, "cmux", "tab-switch-tools", "CuaDriver", "cua-driver"}
        app = frames.App(bundle, root, smoke)
        app.launch()
        control = app.control
        ids = build_workload(control, root)
        report["workload"] = ids
        probe = control.call("debug.window_list", timeout=10)
        has_debug = not (isinstance(probe, dict) and probe.get("error"))
        report["has_debug_commands"] = has_debug
        marker = capture.Marker(args.tools, app.process.pid)  # its ready line names the app's window, no grant needed
        ready = marker.ready
        marker.quit()
        rect = ready["window"]
        report["window_points"] = rect
        time.sleep(1.0)  # test script: the marker's window leaves the screen
        # (b) The screen's own pixels of the window, then each of the app's pictures of it.
        screen_png = os.path.join(images, "screen-window.png")
        problem = screen_window(rect, screen_png)
        report["screen_error"] = problem
        screen = read_image(screen_png) if not problem else None
        pictures = {"screen": stats(screen) if screen else None}
        sources = Sources(control, ids, root, has_debug)
        for name in sources.names()[1:] + ["browser.page.screenshot"]:
            got = sources.measure(name, "picture")
            if got["png"]:
                kept = os.path.join(images, name.replace(".", "-") + ".png")
                shutil.copy(got["png"], kept)
                pictures[name] = dict(stats(read_image(kept), screen), extra=got["extra"])
            else:
                pictures[name] = {"error": got["error"] or "no image"}
            say("picture", name, json.dumps(pictures[name])[:400])
        report["pictures"] = pictures
        # (c) The cost of each source, interleaved round by round.
        runs = {name: [] for name in sources.names()}
        watch.paused.set()  # the prompt watch covered every capture above; the timing runs alone
        for index in range(args.rounds):
            for name in sources.names():
                got = sources.measure(name, index)
                if got["png"] and got["png"].startswith(root):
                    os.remove(got["png"])
                got.pop("png")
                runs[name].append(got)
                time.sleep(0.4)  # test script: the window settles between captures
        watch.paused.clear()
        report["timing"] = {name: summarize(rows) for name, rows in runs.items()}
        raw, pages = report["timing"].get("debug.window_snapshot.raw"), report["timing"].get("debug.window_snapshot.pages")
        if raw and pages and raw["ms_p50"] is not None and pages["ms_p50"] is not None:
            report["cef_page_image_ms_p50_estimate"] = round(pages["ms_p50"] - raw["ms_p50"], 1)
        report["timing_runs"] = runs
        # The page hidden behind the right pane's terminal: does Page.captureScreenshot still answer, and in how long.
        control.action("tab.focus", target=f"tab:{ids['right_terminal']}")
        time.sleep(1.5)  # test script: the page hides
        hidden = sources.measure("browser.page.screenshot", "hidden")
        if hidden["png"]:
            kept = os.path.join(images, "browser-page-screenshot-hidden.png")
            shutil.copy(hidden["png"], kept)
            hidden["stats"] = stats(read_image(kept))
        hidden.pop("png")
        report["hidden_page_screenshot"] = hidden
        control.action("tab.focus", target=f"tab:{ids['chromium']}")
        status = 0
    except Exception as error:  # noqa: BLE001 - any fault still writes the report, with the TCC reads it has
        report["unmeasurable"] = f"{type(error).__name__}: {error}"
        say("cannot measure:", report["unmeasurable"])
    finally:
        if app is not None:
            try:
                app.end()
            except Exception as error:  # noqa: BLE001 - the report still gets written
                report["end_error"] = str(error)[:300]
            if tcc_log is not None:
                report["tcc_log"] = tcc_log.stop(report.get("bundle_id", "?"), report.get("executable"))
        if watch is not None:
            report["prompt_watch"] = watch.stop()
        if report.get("bundle_id"):
            report["tcc_after"] = tcc_rows(report["bundle_id"])
        shutil.rmtree(root, ignore_errors=True)
    with open(os.path.join(args.out, "report.json"), "w") as handle:
        json.dump(report, handle, indent=2, sort_keys=True, default=str)
    write_markdown(report, os.path.join(args.out, "report.md"))
    for name, row in (report.get("timing") or {}).items():
        say("time", name, json.dumps(row))
    say("report", os.path.join(args.out, "report.json"), "status", status)
    return status


def write_markdown(report, path):
    lines = [f"# launch capture probe: {report.get('build')} ({report.get('bundle_id')}, {report.get('bundle_version')})", "",
             f"Host {report['host']}", ""]
    if report.get("unmeasurable"):
        lines += [f"Could not measure: {report['unmeasurable']}", ""]
    for when in ("tcc_before", "tcc_after"):
        lines.append(f"- {when}: `{json.dumps(report.get(when))[:900]}`")
    lines.append(f"- prompt watch: `{json.dumps(report.get('prompt_watch'))[:900]}`")
    lines.append(f"- tccd log: `{json.dumps(report.get('tcc_log'))[:900]}`")
    lines += ["", "| picture | left red share | right blue share | right common color | MAD vs screen (all/left/right) |",
              "|---|---|---|---|---|"]
    for name, row in (report.get("pictures") or {}).items():
        if not row or row.get("error"):
            lines.append(f"| {name} | {(row or {}).get('error', 'none')} | | | |")
            continue
        mad = row.get("mad_vs_screen") or {}
        lines.append(f"| {name} | {row['left_red_share']} | {row['right_blue_share']} | {row['right_common_color']} "
                     f"({row['right_common_share']}) | {mad.get('all')}/{mad.get('left')}/{mad.get('right')} |")
    lines += ["", "| source | ok/runs | ms p50 | ms p95 | ms max | main max turn p50 | p95 | max | turns >8.3 ms p50 |",
              "|---|---|---|---|---|---|---|---|---|"]
    for name, row in (report.get("timing") or {}).items():
        lines.append(f"| {name} | {row['ok']}/{row['runs']} | {row['ms_p50']} | {row['ms_p95']} | {row['ms_max']} | "
                     f"{row['main_max_turn_ms_p50']} | {row['main_max_turn_ms_p95']} | {row['main_max_turn_ms_max']} | "
                     f"{row['turns_over_8_3ms_p50']} |")
    lines += ["", f"Hidden page screenshot: `{json.dumps(report.get('hidden_page_screenshot'))[:600]}`", ""]
    Path(path).write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    sys.exit(main())
