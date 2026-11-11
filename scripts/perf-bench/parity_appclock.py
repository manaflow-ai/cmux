#!/usr/bin/env python3
"""CHROME PARITY BENCH by the APP-CLOCK method: both arms, interleaved, with no macOS privacy right.

chrome_parity.py (real HID events + a ScreenCaptureKit stream of the display) needs the PostEvent and Screen
Recording rights for the process that starts it. Where an ssh session has neither (the AWS minis: the responsible
process is /usr/local/bin/tailscaled), this tool measures the rows that need no such right:

  cmux arm    input: the app's debug socket (`debug.key` with the bench's send time as the event's timestamp,
              `debug.mouse` scroll, `debug.window_frame`). Frames: the app's own recorder (`debug.motion` record_*:
              ScreenCaptureKit of the app's own windows, in the app's process), which stamps each frame with its
              display time and keeps exact pixel rows and columns of it. A response frame is a frame whose kept
              pixels changed INSIDE the row's response region; a change elsewhere (sidebar, tab titles) is not one.
  Chrome arm  parity_chrome_cdp.py: DevTools input, Chrome's own trace (EventLatency / presented frames).

Every latency sample is "the bench's send stamp -> the frame's time" in both arms (Chrome: `send_ms`). The hop from
the keyboard through WindowServer to the app is in NO number, and the two frame clocks differ (cmux: the display
time ScreenCaptureKit gives; Chrome: its presentation feedback): a difference under one refresh between the arms is
inside the method's error. The report labels every row "app-clock" and lists each run's display, measured refresh
interval, screen lock state and load.

Honesty rules (the `selfcheck` command proves 2-4 on the host, with the real app):
  1. A run is "measured" only when the console screen is unlocked, the window's display is awake, and the app's
     display link ticked at --hz in that run (`refresh_ms_measured`: p50 of 1 s of display-link intervals, read
     before the inputs). Otherwise its numbers are kept as "invalid" with the reason and never reach the table.
  2. No frame from the recorder (a window that is not shown) is "not run: the app got no frame", never a number.
  3. An input that is not delivered gives no sample: a key press counts only when the page or terminal also
     reports it (the field's length, the terminal's text), a chord only when the app says it ran an action, and a
     time at which nothing was sent has no response frame.
  4. A frozen window (`debug.stall`: the main thread blocked) loses its inputs: `lost`, 10 late refreshes each,
     and the report gives FAIL when the other arm answered (chrome_parity.verdict_of).
  5. An input that the capture could not see is `blind`: no sample, not `lost`, counted apart and shown in the
     report's verdict and run list. The recorder's stream sometimes stops right after a change on the display:
     it gives no callback of any kind (not a complete frame, not an idle one) until the next change, and the
     frame of that change never comes. Measured on aws-m4pro-7 and -8 (macOS 26.7, 120 Hz): 56 of 1840 typed
     keys in 16 runs on 3 builds; the ones looked at were on the display in their own frame in a film by another
     process, and the renderer drew a frame for each. So an input is blind only when the stream called back
     after the input, not later than BLIND_START_REFRESHES after it, and was then silent (longer than
     CAPTURE_SILENT_REFRESHES with no callback) up to the response frame or the end of the input's span.
     A window that changes nothing keeps its idle callbacks: of 60 keys sent into a blocked main thread
     (`debug.stall`), 58 were lost and 0 blind, so rules 3 and 4 hold (selfcheck proves both on the host). A
     silence can follow any change, also one outside the row's region (a tab title): in the same runs 165 of
     108841 times with no input (one each 5 ms) read as blind, 0.15%, the worst run 0.56%. That is the chance
     that a frame the app really holds is excused, and it is the limit of this rule: the last callback before a
     silence says only "not shown yet". A run with more than BLIND_MAX_SHARE of its inputs blind (and more
     than 2) is "not run".

A bench tool: never a CI gate, job, step or perf-gate row. Python 3.9 standard library only.

  parity_appclock.py run --cmux APP --out DIR [--rows a,b] [--loads light,load] [--rounds 2] [--screen last]
                         [--hz 120] [--chrome APP] [--note TEXT] [--no-lock] [--arms cmux,chrome]
  parity_appclock.py selfcheck --cmux APP --out DIR [--screen last]
  parity_appclock.py report --out DIR [--md FILE] [--json FILE]      (chrome_parity.py's table + the runs' labels)
"""
from __future__ import annotations

import argparse
import bisect
import json
import os
import random
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "cmux-next"))

import chrome_parity as cp  # noqa: E402
import parity_chrome_cdp as chrome_arm  # noqa: E402
from bench_launch import BenchApp, LaunchError, account_home  # noqa: E402

METHOD = ("app-clock: socket input (no OS event), frames from the app's own ScreenCaptureKit recorder (display "
          "time); the OS input hop is not measured")
ROWS = ["key-field", "key-terminal", "scroll-page", "scroll-terminal", "cmdt-first", "tab-switch", "window-resize"]
NOT_BY_APP_CLOCK = {
    "key-native": "Chrome's omnibox takes no DevTools key event",
    "cmdt-interactive": "omnibox typing after Cmd-T needs OS key events in Chrome",
    "pane-resize": "Chrome's DevTools dock divider needs a mouse drag",
    "hover-sidebar": "Chrome's tab strip hover needs OS mouse moves",
    "hover-tabs": "Chrome's tab strip hover needs OS mouse moves",
    "drag-sidebar": "a Chrome tab strip drag needs OS mouse events",
    "drag-tabs": "a Chrome tab strip drag needs OS mouse events",
    "launch-first": "the cmux recorder runs inside the app: it cannot see the first frame of its own launch",
    "launch-interactive": "typing while the app launches needs OS key events",
}
NEEDS_OS = ("not run by the app-clock method (needs OS input and a screen capture: PostEvent + Screen Recording for "
            "the process that starts the bench)")
LETTERS = "asdfghjkl"
TOP_CHROME_PT = 34      # the window's title and tab bar rows: left out of a content region (titles change by themselves)
QUIET_MS = 400          # no change in the response region for this long before the first input
SCAN_BUDGET = 200e6     # bytes of kept pixels per recording (the recorder's cap is 256 MB)
RAN = ("app", "menu", "window")  # debug.key's `handled_by` for a chord that ran an action
# No callback of any kind for longer than this = the stream stopped. Off the refresh grid on purpose: the stream's
# normal gaps are whole refreshes (up to 5 measured; a gap of 6 is 50 ms at 120 Hz, the limit of video_judge).
CAPTURE_SILENT_REFRESHES = 6.5
BLIND_START_REFRESHES = 4  # a silence that starts later than this after an input is not the cause of its missing frame
BLIND_MAX_SHARE = 0.10  # more blind inputs than this share of a run: "not run" (the worst run measured had 8 of 120)


NotRun = chrome_arm.NotRun  # one class in both arms: the GUI lock and the display pick raise it too


class CaptureBlind(NotRun):
    """The capture stream was silent at too many inputs of a run (honesty rule 5): the run has no number."""


def log(message):
    print(f"[appclock {time.strftime('%H:%M:%SZ', time.gmtime())}] {message}", file=sys.stderr, flush=True)


def now_ns():
    """The clock of NSEvent timestamps, CACurrentMediaTime and ScreenCaptureKit display times."""
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW)


def pause(seconds):
    time.sleep(seconds)  # bench: pacing of synthetic input, never a wait for app state


def sleep_until(deadline_ns):
    while True:
        left = deadline_ns - now_ns()
        if left <= 0:
            return
        time.sleep(min(left / 1e9, 0.002) if left > 300_000 else 0)  # bench: input pacing at the display rate


# ---------------------------------------------------------------- the recorder's files and the judge of its frames


def read_scan(path):
    """(header, [(time_ns, bytes of the kept rows then columns)]) of a recording's PATH.scan (complete frames only)."""
    with open(path, "rb") as f:
        data = f.read()
    nl = data.index(b"\n")
    head = json.loads(data[:nl])
    size = 8 + 4 * (len(head["rows"]) * head["width"] + len(head["columns"]) * head["height"])
    frames, off = [], nl + 1
    while off + size <= len(data):
        frames.append((int(struct.unpack_from("<d", data, off)[0] * 1e9), data[off + 8:off + size]))
        off += size
    return head, frames


def changed_frames(head, frames, x0, x1, y0, y1):
    """Frames whose kept pixels differ from the frame before them inside the device-pixel box x0..x1, y0..y1:
    [{"t": ns, "n": changed lines}]. A kept row is compared between x0 and x1, a kept column between y0 and y1.
    The first frame has nothing before it and is never a response."""
    width, height, rows, columns = head["width"], head["height"], head["rows"], head["columns"]
    x0, x1 = max(0, int(x0)), min(width, int(x1))
    y0, y1 = max(0, int(y0)), min(height, int(y1))
    column_base = 4 * len(rows) * width
    spans = [(4 * (i * width + x0), 4 * (i * width + x1)) for i in range(len(rows))]
    spans += [(column_base + 4 * (i * height + y0), column_base + 4 * (i * height + y1)) for i in range(len(columns))]
    out, before = [], None
    for t, blob in frames:
        if before is not None:
            out.append({"t": t, "n": sum(1 for a, b in spans if blob[a:b] != before[a:b])})
        before = blob
    return out


def read_callbacks(path):
    """Sorted times (ns) of every callback the capture stream gave, complete and idle, from a recording's
    PATH.frames.json. [] when the recorder wrote no list (then no input can be blind)."""
    try:
        with open(path) as f:
            entries = json.load(f).get("frames") or []
        return sorted(int(entry[0] * 1e9) for entry in entries)
    except (OSError, ValueError, TypeError, IndexError, AttributeError):
        return []


def capture_blind(t, stop, callbacks, refresh_ms):
    """Whether the capture could not see what the window showed for the input at `t` (honesty rule 5): the stream
    called back after `t`, not later than BLIND_START_REFRESHES after it, and then gave no callback of any kind up
    to `stop` (the response frame's time, or the end of the input's span) for longer than CAPTURE_SILENT_REFRESHES.
    `callbacks`: sorted ns. A stream that was silent before the input already, or that never called back, is not
    blind for it: such an input stays lost."""
    limit = t + int(BLIND_START_REFRESHES * refresh_ms * 1e6)
    after = bisect.bisect_right(callbacks, limit)
    if after == 0 or callbacks[after - 1] <= t:
        return False  # no callback between the input and the start limit: the silence is not this input's
    if after < len(callbacks) and callbacks[after] < stop:
        return False  # the stream called back inside the span after the start limit: it was awake
    return stop - callbacks[after - 1] > CAPTURE_SILENT_REFRESHES * refresh_ms * 1e6


def latencies(stamps, changed, horizon_ms, refresh_ms, callbacks=()):
    """Per input stamp: ms to the first changed frame after it, before the next input and within the horizon.
    An input with no such frame is lost (chrome_parity.LOST_LATE late refreshes), never a sample. With the
    stream's callback times, an input that the capture could not see (capture_blind) is blind: no sample, not
    lost, no late refresh. Returns (samples, lost, missed, blind)."""
    samples, lost, missed, blind = [], 0, 0, 0
    for i, t in enumerate(stamps):
        end = t + int(horizon_ms * 1e6)
        if i + 1 < len(stamps):
            end = min(end, stamps[i + 1])
        hit = next((f for f in changed if t < f["t"] <= end), None)
        if callbacks and capture_blind(t, hit["t"] if hit else end, callbacks, refresh_ms):
            blind += 1  # also a frame that ends the silence: its time is the stream's restart, not the app's frame
            continue
        if hit is None:
            lost += 1
            missed += cp.LOST_LATE
            continue
        ms = (hit["t"] - t) / 1e6
        samples.append(round(ms, 3))
        missed += cp.late(ms, refresh_ms)
    return samples, lost, missed, blind


# ---------------------------------------------------------------- the cmux arm


class Cmux:
    """One launched cmux bench app (clean state, clean config) and its debug socket."""

    def __init__(self, bundle, out, server, screen):
        self.server = server
        self.out = out
        config = {"appearance": {"backgroundOpacity": 1},
                  "updates": {"checkAutomatically": False, "downloadAutomatically": False}}
        self.app = BenchApp(bundle, out=out, config=config, window=cp.WINDOW, screen=screen)
        with open(os.path.join(self.app.scratch, "ghostty"), "w") as f:
            f.write("cursor-style-blink = false\n")
        self.window, self.pages, self.recording = None, [], None
        self.callbacks = []  # the times of every callback of the last recording's stream (stop_recording)
        self.scale = 1.0

    def launch(self):
        try:
            self.app.launch(timeout=180)
        except LaunchError as error:
            raise NotRun(f"cmux did not launch: {error.reason}") from error
        pause(3.0)
        return self

    def rpc(self, method, params=None, timeout=60):
        reply = self.app.rpc(method, params or {}, timeout)
        if isinstance(reply, dict) and reply.get("error"):
            raise NotRun(f"cmux {method}: {str(reply['error'])[:200]}")
        return reply

    def act(self, action, **args):
        return self.rpc("action.run", {"action": action, "args": args, "wait": True, "origin": "script", "focus": True,
                                       "idempotency_key": f"mutation_{uuid.uuid4().hex}"}, timeout=120)

    def workspace(self):
        reply = self.act("workspace.newAtBottom") or {}
        made = [i for i in reply.get("created", []) if str(i).startswith("ws_")]
        if not made:
            raise NotRun(f"cmux: workspace.newAtBottom made no workspace ({str(reply)[:200]})")
        self.act("goToWorkspace", workspace=made[0])
        return made[0]

    def terminal(self, text=None):
        self.act("newSurface")
        if text:
            pause(1.0)
            self.act("terminal.sendText", text=text + "\r")

    def setup(self, load, url=None, terminal=None):
        """As chrome_parity.CmuxArm.setup: the load (5 streaming terminals in another workspace, a CPU page), then the
        measured surface in front."""
        measured = self.workspace()
        if load:
            self.workspace()
            for _ in range(5):
                self.terminal(cp.STREAM_CMD)
            self.act("goToWorkspace", workspace=measured)
            self.act("openBrowser.chromium", url=self.server.url("cpu"))
            pause(2.0)
        if url:
            self.act("openBrowser.chromium", url=url)
        if terminal is not None:
            self.terminal(terminal)
        pause(2.5)
        self.geometry()
        return measured

    def geometry(self):
        """The window's frame and its content (Chromium page) child windows: screen points, AppKit bottom-left origin."""
        layers = self.rpc("debug.layers") or {}
        windows = layers.get("windows") or []
        if not windows:
            raise NotRun("cmux: debug.layers lists no window")
        self.window = windows[0]
        # A page that is not shown stays a "visible" child window parked far off screen (-100000, -100000): only a
        # page whose frame is inside the window's frame is a page the person sees.
        x0, y0, w, h = self.window.get("frame") or (0, 0, 0, 0)

        def shown(c):
            f = c.get("frame") or (0, 0, 0, 0)
            return f[0] < x0 + w and f[0] + f[2] > x0 and f[1] < y0 + h and f[1] + f[3] > y0
        self.pages = [c for c in self.window.get("child_windows", [])
                      if c.get("visible") and c.get("role") == "content" and shown(c)]
        return self.window

    def page_box(self):
        """(left, top, width, height) of the largest visible Chromium page, in window points from the window's top-left."""
        frame = self.window.get("frame")
        if not self.pages or not frame:
            roles = [(c.get("role"), c.get("visible")) for c in self.window.get("child_windows", [])]
            raise NotRun(f"cmux: no visible Chromium page window (child windows: {roles})")
        x, y, w, h = max(self.pages, key=lambda c: c["frame"][2] * c["frame"][3])["frame"]
        return x - frame[0], (frame[1] + frame[3]) - (y + h), w, h

    def content_box(self):
        """(left, top, width, height) of the window's content right of the sidebar, in window points."""
        frame = self.window["frame"]
        listed = (self.rpc("debug.windows") or {}).get("windows") or [{}]
        sidebar = 0 if listed[0].get("sidebar_hidden") else float(listed[0].get("sidebar_width") or 0)
        return sidebar + 2, TOP_CHROME_PT, frame[2] - sidebar - 4, frame[3] - TOP_CHROME_PT - 4

    def terminal_box(self, lines=None):
        """(left, top, width, height) of the largest shown terminal's cell grid in window points, from debug.surfaces
        (the first `lines` text lines, or all of it); the content box when no terminal reports its grid."""
        grids = []

        def walk(value):
            if isinstance(value, dict):
                if "cell_height" in value and "frame_width" in value:
                    grids.append(value)
                for item in value.values():
                    walk(item)
            elif isinstance(value, list):
                for item in value:
                    walk(item)

        walk(self.rpc("debug.surfaces"))
        if not grids:
            left, top, width, height = self.content_box()
            return (left, top, min(width, 620), 68 if lines else height), "content box (no terminal grid reported)"
        g = max(grids, key=lambda g: g["frame_width"] * g["frame_height"])
        bottom = g["frame_y"] + g["frame_height"]
        height = min(lines * g["cell_height"] + 2, bottom - g["origin_y"]) if lines else bottom - g["origin_y"]
        return (g["origin_x"], g["origin_y"], min(620, g["frame_x"] + g["frame_width"] - g["origin_x"]), height), "terminal grid"

    def terminal_text(self):
        """Everything debug.surfaces reports with the terminals' viewport text, as one string."""
        return json.dumps(self.rpc("debug.surfaces", {"text": True}))

    def link_refresh(self):
        """1 s of the app's display link: the p50 of its tick intervals (ms), what the display runs at for this app."""
        self.rpc("debug.frames", {"action": "start"})
        pause(1.0)
        got = self.rpc("debug.frames", {"action": "stop"}) or {}
        return {"refresh_ms_measured": round(got["p50_ms"], 3) if got.get("p50_ms") else None,
                "link_ticks_1s": got.get("frames"), "link_refresh_ms": got.get("refresh_ms")}

    # recording ---------------------------------------------------------------

    def record(self, name, seconds, box, row_step=None, column_step=None, worst_frames=1200):
        """Starts the app's recorder with pixel rows every `row_step` points and columns every `column_step` points
        across `box` (left, top, width, height in window points). The capture starts at the window's top-left."""
        path = os.path.join(self.out, f"{name}.mov")
        left, top, width, height = box
        link = self.link_refresh()
        reply, rows, columns, frame_bytes, wider = {}, [], [], 0, 1.0
        for _attempt in range(5):
            s = self.scale
            rows = [int((top + k) * s) for k in range(0, int(height), max(1, round(row_step * wider)))] if row_step else []
            columns = [int((left + k) * s) for k in range(0, int(width), max(1, round(column_step * wider)))] if column_step else []
            reply = self.rpc("debug.motion", {"action": "record_start", "path": path, "seconds": seconds, "rows": rows,
                                              "columns": columns, "filter": "display"})
            got = float(reply.get("scale") or 1)
            frame_bytes = 8 + 4 * (len(rows) * int(reply.get("width") or 1) + len(columns) * int(reply.get("height") or 1))
            if abs(got - s) < 0.01 and frame_bytes * worst_frames <= SCAN_BUDGET:
                break
            # A 2x display (device-pixel lines), or lines that would fill the recorder's scan file: stop, start again.
            if abs(got - s) < 0.01:
                wider *= 1.5
            self.scale = got
            self.app.rpc("debug.motion", {"action": "record_stop"})
            self.wait_written()
        else:
            raise NotRun(f"{name}: {frame_bytes} bytes a frame x {worst_frames} frames is over the recorder's scan budget")
        deadline = time.monotonic() + 10
        state = {}
        while time.monotonic() < deadline:
            state = self.rpc("debug.motion", {"action": "record_read"}) or {}
            if state.get("capturing"):
                break
            pause(0.1)
        if not state.get("capturing"):
            raise NotRun(f"{name}: the app's recorder did not start ({str(state)[:200]})")
        self.recording = {"path": path, "start": reply, "box": box, "link": link,
                          "lines": {"rows": len(rows), "columns": len(columns), "step_factor": wider}}
        pause(0.3 + QUIET_MS / 1000)
        return path

    def wait_written(self):
        deadline = time.monotonic() + 30
        state = {}
        while time.monotonic() < deadline:
            state = self.app.rpc("debug.motion", {"action": "record_read"}) or {}
            if state.get("written") or state.get("unreachable"):
                break
            pause(0.2)
        return state

    def stop_recording(self, first_input_ns):
        """Ends the recording. Returns (changed frames in the response box, facts). Raises NotRun when the app got no
        frame (honesty rule 2) or when the box changed with no input right before the first input."""
        self.app.rpc("debug.motion", {"action": "record_stop"})
        state = self.wait_written()
        path, start = self.recording["path"], self.recording["start"]
        self.callbacks = read_callbacks(path + ".frames.json")  # before the files go: the judge of blind inputs
        facts = {"recorder": {k: state.get(k) for k in ("callbacks", "frames", "complete", "idle", "scan_dropped",
                                                        "movie_status", "filter", "write_error")},
                 "display_id": start.get("display"), "scale": start.get("scale"),
                 "capture_px": [start.get("width"), start.get("height")], "region_pt": [round(v, 1) for v in self.recording["box"]],
                 "lines": self.recording["lines"], **self.recording["link"]}
        try:
            if not state.get("callbacks"):
                raise NotRun(f"the app got no frame from ScreenCaptureKit (0 callbacks, {state.get('movie_status')}): "
                             "the screen is locked, the display is asleep or the window is not shown")
            if state.get("scan_dropped"):
                raise NotRun(f"the recorder dropped {state['scan_dropped']} frames from its scan (over its 256 MB cap)")
            if not state.get("complete") or not os.path.exists(path + ".scan"):
                return [], facts  # the screen gave frames and the window changed nothing: every input is lost
            head, frames = read_scan(path + ".scan")
            left, top, width, height = self.recording["box"]
            s = float(facts["scale"] or 1)
            changed = [f for f in changed_frames(head, frames, left * s, (left + width) * s, top * s, (top + height) * s)
                       if f["n"] > 0]
            noise = [f for f in changed if first_input_ns - QUIET_MS * 1e6 <= f["t"] < first_input_ns]
            if noise:
                raise NotRun(f"the response region changed {len(noise)} times in the {QUIET_MS} ms before the first "
                             "input: a frame there cannot be told from a response")
            return changed, facts
        finally:
            for name in (path, path + ".scan", path + ".frames.json"):
                try:
                    os.unlink(name)  # up to hundreds of MB a run; the numbers are in the result
                except OSError:
                    pass

    def quit(self):
        try:
            self.app.stop()
        except Exception as error:  # noqa: BLE001  the teardown reports; a failed quit is not this row's result
            log(f"cmux stop: {type(error).__name__}: {error}")


def key(cmux, letter, target=None, modifiers=None, must_run=False):
    """One key-down through the app's event path; its NSEvent timestamp is the bench's send time. Returns that time
    (ns). `must_run`: a chord that ran no action was not delivered (honesty rule 3)."""
    t = now_ns()
    params = {"key": letter, "timestamp": t / 1e9}
    if target:
        params["target"] = target
    if modifiers:
        params["modifiers"] = modifiers
    reply = cmux.rpc("debug.key", params) or {}
    if must_run and reply.get("handled_by") not in RAN:
        raise NotRun(f"cmux: {'+'.join(modifiers or [])}+{letter} ran no action (handled_by {reply.get('handled_by')})")
    return t


def type_keys(cmux, count, rng, target=None):
    stamps = []
    for i in range(count):
        stamps.append(key(cmux, LETTERS[i % len(LETTERS)], target))
        pause(0.030 + rng.randint(80, 200) / 1000)
    pause(0.4)
    return stamps


def latency_result(cmux, hz, stamps, horizon_ms=300):
    changed, facts = cmux.stop_recording(stamps[0])
    samples, lost, missed, blind = latencies(stamps, changed, horizon_ms, 1000.0 / hz, cmux.callbacks)
    if blind > max(2, BLIND_MAX_SHARE * len(stamps)):
        raise CaptureBlind(f"the capture stream was silent at {blind} of {len(stamps)} inputs (no callback of any kind "
                           f"for more than {CAPTURE_SILENT_REFRESHES} refreshes): the capture did not see this run")
    return {"samples": samples, "lost": lost, "missed": missed, "blind": blind, "inputs": len(stamps),
            "frames": len(changed), **facts}


def pacing_result(cmux, hz, spans):
    changed, facts = cmux.stop_recording(spans[0][0])
    intervals, missed, frozen = cp.pacing(changed, spans, 1000.0 / hz)
    return {"samples": [round(s, 3) for s in intervals], "missed": missed, "lost": frozen, "inputs": len(spans),
            "spans": len(spans), "frames": len(changed), **facts}


CUA_DRIVER = "/Applications/CuaDriver.app/Contents/MacOS/cua-driver"


def activate_once(cmux):
    """One CuaDriver `bring_to_front` call for the bench app, and its answer. A bench app is started from ssh, and with
    no such call it gives no key to a Chromium page: 0 of 40 `debug.key` keys typed before this step, 40 of 40 after
    it (aws-m4pro-7, 2026-11-10). `debug.focus` still said "not the active app" 0.8 s after the call and at the row's
    end: the proven fact is that the keys arrive after the call, not a state of the app. A person's app was in front
    before its first key, so the step adds nothing a person does not have. The bench shell itself gets no right.
    The call runs with the ACCOUNT's home and temp folder, never with the bench's own HOME: with another HOME the
    client finds no daemon and makes a new `.cua-driver` config there."""
    if not os.path.exists(CUA_DRIVER):
        raise NotRun(f"cmux: the key-field row needs CuaDriver to bring the app to the front one time ({CUA_DRIVER} is not on this host)")
    env = dict(os.environ, HOME=account_home())
    env.pop("TMPDIR", None)  # no bench temp folder either: the client then takes the account's own
    try:
        done = subprocess.run([CUA_DRIVER, "call", "bring_to_front", json.dumps({"pid": int(cmux.app.process.pid)})],
                              stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=25, check=False, env=env)
    except subprocess.TimeoutExpired as error:
        raise NotRun("cmux: CuaDriver bring_to_front did not return in 25 s") from error
    try:
        answer = json.loads(done.stdout) if done.stdout.strip() else None
    except ValueError:
        answer = None
    if done.returncode != 0 or not isinstance(answer, dict) or answer.get("isError") or answer.get("error") or not answer.get("activated"):
        raise NotRun(f"cmux: CuaDriver bring_to_front failed (exit {done.returncode}): {(done.stderr.strip() or done.stdout.strip())[:160]}")
    pause(0.8)
    return {"tool": "bring_to_front", "activated": True}


def row_key_field(cmux, server, hz, load, rng):
    cmux.setup(load, server.url("field", report="1"))
    front = activate_once(cmux)
    left, top, width, height = cmux.page_box()
    cmux.rpc("debug.mouse", {"target": "page", "x": 300, "y": 42})  # a click in the field (page points): focus
    pause(0.6)
    # The field's text line: pixel rows every 3 points through it (a typed glyph crosses one of them).
    cmux.record("key-field", 20, (left + 28, top + 28, 440, 28), row_step=3, worst_frames=1100)
    before = server.typed
    stamps = type_keys(cmux, 40, rng, target="page")
    result = latency_result(cmux, hz, stamps)
    result["typed"] = server.typed - before
    result["front_step"] = front  # says in results.jsonl that this run had the step (a run from before it has no such field)
    if result["typed"] < len(stamps):
        raise NotRun(f"only {result['typed']} of {len(stamps)} keys reached the field: no sample from keys that were not delivered")
    return result


def row_key_terminal(cmux, server, hz, load, rng):
    cmux.setup(load, terminal="clear")
    box, source = cmux.terminal_box(lines=3)  # the prompt's line after `clear`, and two more
    cmux.record("key-terminal", 20, box, row_step=4, worst_frames=1100)
    stamps = type_keys(cmux, 40, rng)
    result = latency_result(cmux, hz, stamps)
    result["region_from"] = source
    typed = "".join(LETTERS[i % len(LETTERS)] for i in range(40))
    result["typed"] = typed[:24] in cmux.terminal_text()
    cmux.rpc("debug.key", {"key": "u", "modifiers": ["ctrl"]})
    if not result["typed"]:
        raise NotRun("the typed text is not in the terminal: no sample from keys that were not delivered")
    return result


def bursts(send, count=20, per=60, hz=120, gap_ms=300):
    """`count` bursts of `per` inputs at `hz`, direction +1 then -1; send(direction). Returns the spans (ns)."""
    spans = []
    for i in range(count):
        start = now_ns() + 2_000_000
        first = last = None
        for k in range(per):
            sleep_until(start + int(k * 1e9 / hz))
            last = now_ns()
            first = first or last
            send(1 if i % 2 == 0 else -1)
        spans.append((first, last))
        pause(gap_ms / 1000)
    pause(0.4)
    return spans


def row_scroll_page(cmux, server, hz, load, rng):
    cmux.setup(load, server.url("long"))
    left, top, width, height = cmux.page_box()
    box = (left + 20, top + 20, min(width, 900) - 40, min(height, 560) - 40)
    cmux.record("scroll-page", 40, box, column_step=110, worst_frames=2600)
    point = {"target": "page", "action": "scroll", "x": left + 400, "y": top + 300, "dx": 0, "hover": False}
    spans = bursts(lambda sign: cmux.rpc("debug.mouse", {**point, "dy": 120 * sign}), hz=hz)
    return pacing_result(cmux, hz, spans)


def row_scroll_terminal(cmux, server, hz, load, rng):
    seq = "seq -f 'row %06g the quick brown fox jumps over the lazy dog 0123456789 abcdefghij' 1 50000"
    cmux.setup(load, terminal="clear")
    cmux.act("terminal.sendText", text=seq + "\r")
    pause(6)
    (left, top, width, height), source = cmux.terminal_box()
    box = (left, top, width, min(height, 480))
    cmux.record("scroll-terminal", 40, box, column_step=75, worst_frames=2600)
    point = {"action": "scroll", "x": left + width / 2, "y": top + min(height, 480) / 2, "dx": 0, "hover": False}
    spans = bursts(lambda sign: cmux.rpc("debug.mouse", {**point, "dy": 120 * sign}), hz=hz)
    result = pacing_result(cmux, hz, spans)
    result["region_from"] = source
    return result


def row_cmdt(cmux, server, hz, load, rng):
    cmux.setup(load, server.url("color", bg="3050c0"))
    left, top, width, height = cmux.content_box()
    cmux.record("cmdt-first", 60, (left, 0, width, height + top), column_step=120, worst_frames=3000)
    stamps = []
    for _ in range(20):
        stamps.append(key(cmux, "t", modifiers=["cmd"], must_run=True))
        pause(1.5)
        key(cmux, "w", modifiers=["cmd"], must_run=True)
        pause(1.0)
    # The close's own frames come 1.5 s after each Cmd-T: a response must come within 1 s of it.
    return latency_result(cmux, hz, stamps, horizon_ms=1000)


def row_tab_switch(cmux, server, hz, load, rng):
    """20 switches between the 2 colour pages, as the Chrome arm. The pane also holds the workspace's terminal tab (and
    the CPU page under load), so Ctrl-Tab alone goes round 3 or 4 tabs and mixes page -> page, page -> terminal and
    terminal -> page switches in one row. The colour pages are the last 2 tabs and the blue one is in front:
    Ctrl-Shift-Tab (previous) and Ctrl-Tab (next) in turn stay on these 2 tabs."""
    cmux.setup(load, server.url("color", bg="c03030"))
    cmux.act("openBrowser.chromium", url=server.url("color", bg="3050c0"))
    pause(2.0)
    cmux.geometry()
    left, top, width, height = cmux.page_box()
    cmux.record("tab-switch", 30, (left + 20, top + 20, width - 40, height - 40), column_step=150, worst_frames=3000)
    stamps = []
    for i in range(20):
        stamps.append(key(cmux, "tab", modifiers=["ctrl", "shift"] if i % 2 == 0 else ["ctrl"], must_run=True))
        pause(0.5)
    result = latency_result(cmux, hz, stamps, horizon_ms=500)
    cmux.geometry()
    if not cmux.pages:  # an even count of switches ends on the blue page: no page shown = the keys left the 2 pages
        raise NotRun("cmux: no Chromium page is shown after the 20 switches (the keys did not stay on the 2 colour pages)")
    return result


def row_window_resize(cmux, server, hz, load, rng):
    cmux.setup(load, server.url("long"))
    x, y, w, h = cmux.window["frame"]
    left, top, width, height = cmux.content_box()
    cmux.record("window-resize", 20, (left, top, width - 240, height - 160), column_step=60, worst_frames=700)
    spans = []
    for a, b in (((w, h), (w - 240, h - 160)), ((w - 240, h - 160), (w, h))):
        start = now_ns() + 2_000_000
        first = last = None
        for k in range(hz + 1):
            sleep_until(start + int(k * 1e9 / hz))
            f = k / hz
            nw, nh = round(a[0] + (b[0] - a[0]) * f), round(a[1] + (b[1] - a[1]) * f)
            last = now_ns()
            first = first or last
            cmux.rpc("debug.window_frame", {"frame": [x, y + h - nh, nw, nh]})  # the top-left corner stays
        spans.append((first, last))
        pause(0.3)
    pause(0.4)
    result = pacing_result(cmux, hz, spans)
    result["note"] = "debug.window_frame steps (one setFrame each), not a mouse drag: the live-resize path is not used"
    return result


RUNNERS = {"key-field": row_key_field, "key-terminal": row_key_terminal, "scroll-page": row_scroll_page,
           "scroll-terminal": row_scroll_terminal, "cmdt-first": row_cmdt, "tab-switch": row_tab_switch,
           "window-resize": row_window_resize}


def screen_fault(result, hz, display_wanted=None):
    """Why this run's frames are not frames a person can see at `hz` (honesty rule 1), or None."""
    console = chrome_arm.console_state()
    if console.get("locked") is None:
        return f"the console lock state is not known ({console.get('error')})"
    if console["locked"]:
        return "the console screen is locked (IOConsoleLocked): frame times are not frames on a screen"
    shown = {d["id"]: d for d in chrome_arm.displays()}
    display = result.get("display_id")
    if display not in shown:
        return f"display {display} of the cmux window is not in the display list"
    if shown[display]["asleep"]:
        return f"display {display} is asleep"
    if display_wanted is not None and display != display_wanted:
        return f"the cmux window is on display {display}, the Chrome arm uses display {display_wanted}"
    refresh = result.get("refresh_ms_measured")
    if not refresh or abs(refresh - 1000.0 / hz) > 0.06 * 1000.0 / hz:
        return (f"the app's display link ticked every {refresh} ms ({result.get('link_ticks_1s')} ticks in 1 s), "
                f"not every {1000.0 / hz:.2f} ms: not a {hz} Hz number")
    return None


def cmux_row(bundle, out, server, screen, hz, row, load, run_index, note="", display_wanted=None):
    """One (row, load) run of the cmux arm: a clean launch, the measure, the quit. Never raises: a failure is that
    run's "not run" with its reason; numbers from a screen that fails honesty rule 1 are "invalid"."""
    base = {"arm": "cmux", "row": row, "load": load, "round": run_index, "scenario": cp.scenario_of(row), "method": METHOD,
            "note": note, "host": socket.gethostname().split(".")[0], "load1_before": chrome_arm.load1()}
    cmux = None
    try:
        cmux = Cmux(bundle, os.path.join(out, "work", f"cmux-{row}-{load}-{run_index}"), server, screen).launch()
        base["gui_session"] = cmux.app.gui_session
        result = RUNNERS[row](cmux, server, hz, load == "load", random.Random(f"{row}-{load}-{run_index}"))
        fault = screen_fault(result, hz, display_wanted)
        if fault:
            return {**base, "status": "invalid", **result, "reason": fault}
        return {**base, "status": "measured", **result}
    except NotRun as error:
        return {**base, "status": "not run", "reason": str(error)}
    except Exception as error:  # noqa: BLE001  one run's failure is that run's "not run", never the bench's end
        return {**base, "status": "not run", "reason": f"{type(error).__name__}: {error}"[:300]}
    finally:
        if cmux:
            cmux.quit()
        pause(2)


# ---------------------------------------------------------------- the bench page's own report of delivered keys


class Server(cp.Server):
    """chrome_parity's page server, plus `/typed?n=`: the field page (with `report=1`) tells the bench how many
    characters its <input> holds after every input event. The count is the proof that a key was delivered."""

    def __init__(self):
        super().__init__()
        self.typed = 0
        outer = self
        handler = self.httpd.RequestHandlerClass
        plain_get = handler.do_GET

        def do_get(request):
            if request.path.startswith("/typed"):
                try:
                    outer.typed = max(outer.typed, int(request.path.split("n=", 1)[1].split("&")[0]))
                except (IndexError, ValueError):
                    pass
                return request.reply(200, b"ok", "text/plain")
            if request.path.startswith("/p/field") and "report=1" in request.path:
                outer.typed = 0
                body = cp.page("field", {}) + ("<script>document.getElementById('f').addEventListener('input',e=>"
                                               "fetch('/typed?n='+e.target.value.length))</script>")
                return request.reply(200, body.encode(), "text/html")
            return plain_get(request)

        handler.do_GET = do_get


# ---------------------------------------------------------------- run


def gui_lock(enabled):
    """The perf-lead hosts' one-GUI-run lock (parity_chrome_cdp.GuiLock: this process's only when its own mkdir made
    it). Off where the host has no ~/perf-lead folder."""
    home = os.path.expanduser("~" + (os.environ.get("USER") or ""))
    return chrome_arm.GuiLock(os.path.join(home, "perf-lead/gui.lock"), enabled and os.path.isdir(os.path.join(home, "perf-lead")))


def chrome_row(ctx, row, load, run_index, note):
    result = chrome_arm.run_row(ctx, row, load, run_index, note)
    result.update({"round": run_index, "scenario": cp.scenario_of(row)})
    if result.get("send_ms"):  # the same span as the cmux arm: the bench's send stamp -> the frame
        result["event_latency_ms"] = result.get("samples")
        result["samples"] = result["send_ms"]
    return result


def run(args):
    out = os.path.abspath(args.out)
    os.makedirs(os.path.join(out, "work"), exist_ok=True)
    if os.path.exists(os.path.join(out, "results.jsonl")):
        raise SystemExit(f"{out} holds an earlier run: give a new --out")
    rows = [r.strip() for r in args.rows.split(",") if r.strip()]
    loads = [x for x in args.loads.split(",") if x in ("light", "load")]
    arms = [a for a in args.arms.split(",") if a in ("cmux", "chrome")]
    server = Server()
    ctx = chrome_arm.Ctx(args.chrome, os.path.join(out, "chrome-home"), os.path.join(out, "work"), args.hz) if "chrome" in arms else None
    machine = {"host": socket.gethostname().split(".")[0],
               "model": subprocess.run(["sysctl", "-n", "hw.model"], capture_output=True, text=True).stdout.strip(),
               "macos": subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True).stdout.strip(),
               "hz": args.hz, "cmux": args.cmux, "cmux_sha": args.cmux_sha, "chrome": ctx.version if ctx else None,
               "method": METHOD, "console": chrome_arm.console_state(), "displays": chrome_arm.displays(),
               "note": "app-clock method (socket / DevTools input, each app's own frame clock)" + (", " + args.note if args.note else "")}
    with open(os.path.join(out, "machine.json"), "w") as f:
        json.dump(machine, f, indent=1)
    log(f"console {machine['console']}; displays {machine['displays']}")
    results = open(os.path.join(out, "results.jsonl"), "a")

    def record(entry):
        entry.setdefault("at", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
        entry.setdefault("load1_after", chrome_arm.load1())
        # The lead's labels for every number: the display (id, size, rate) and the console's lock state at this run.
        shown = {d["id"]: d for d in chrome_arm.displays()}
        ident = entry.get("display_id") if entry.get("arm") == "cmux" else (entry.get("display") or {}).get("id")
        d = shown.get(ident)
        entry["display_label"] = (f"id {ident} {d['bounds'][2]}x{d['bounds'][3]} {d['hz']:g} Hz" + (" asleep" if d["asleep"] else "")
                                  if d else f"id {ident}")
        entry["console_locked"] = chrome_arm.console_state().get("locked")
        results.write(json.dumps(entry) + "\n")
        results.flush()
        brief = cp.stats(entry.get("samples") or [])
        log(f"{entry.get('arm')} {entry.get('row')} {entry.get('load')} round {entry.get('round')}: {entry.get('status')} "
            f"{entry.get('reason', '')} n={brief.get('n')} p50={brief.get('p50')} p95={brief.get('p95')} p99={brief.get('p99')} "
            f"max={brief.get('max')} lost={entry.get('lost')} blind={entry.get('blind')} missed={entry.get('missed')} "
            f"refresh={entry.get('refresh_ms_measured') or entry.get('refresh_ms_seen')} load {entry.get('load1_before')}")

    try:
        for rnd in range(args.rounds):
            for row in rows:
                for load in loads:
                    if row not in ROWS:
                        if rnd == 0:
                            record({"row": row, "load": load, "arm": "both", "status": "not run", "round": rnd,
                                    "reason": f"{NEEDS_OS}: {NOT_BY_APP_CLOCK.get(row, 'unknown row')}"})
                        continue
                    order = arms if rnd % 2 == 0 else list(reversed(arms))
                    wanted = None
                    if ctx:
                        try:
                            wanted = ctx.use_display()["id"]
                        except Exception as error:  # noqa: BLE001  no display at --hz: each arm's run says so itself
                            log(f"no bench display: {error}")
                    try:
                        with gui_lock(not args.no_lock):  # both arms of one row in one hold: the same minutes, the same load
                            for arm in order:
                                busy = chrome_arm.load1()
                                if busy >= args.max_host_load:
                                    # Measured on aws-m4pro-8: at a 1-min load of 37 the capture had no callback for 13% of
                                    # the refreshes, and the app's own frame clock did not show it. No number from such a run.
                                    record({"row": row, "load": load, "arm": arm, "status": "invalid", "round": rnd,
                                            "load1_before": busy, "method": METHOD,
                                            "reason": f"host 1-min load {busy:g} >= {args.max_host_load:g} before the run: "
                                                      "the screen capture loses frames on a loaded host"})
                                    continue
                                if arm == "cmux":
                                    record(cmux_row(args.cmux, out, server, args.screen, args.hz, row, load, rnd, args.note, wanted))
                                else:
                                    record(chrome_row(ctx, row, load, rnd, args.note))
                    except NotRun as error:  # the host's GUI lock stayed taken
                        record({"row": row, "load": load, "arm": "both", "status": "not run", "round": rnd, "reason": str(error)})
    finally:
        results.close()
        if ctx:
            ctx.close()
    return 0


def report(args):
    """chrome_parity.py's table (only "measured" runs give numbers), then each run's labels: the display, the
    measured refresh interval, the screen's lock state and the load. The lead's rule for every number."""
    code = cp.report(args)
    out = os.path.abspath(args.out)
    entries = [json.loads(line) for line in open(os.path.join(out, "results.jsonl"))]
    lines = ["", "Runs (method app-clock: socket input for cmux, DevTools input for Chrome, each app's own frame clock; "
             "not the HID + screen method). The cmux window is put on its display at launch by "
             "CMUX_NEXT_TEST_WINDOW_SCREEN, Chrome's by --window-position. `refresh ms` is measured in the run: cmux = "
             "p50 of 1 s of its display link, Chrome = the grid of its presented frames. A run that is not `measured` "
             "gives the table no number. `blind` (cmux latency rows): inputs at which the capture stream went silent, "
             "so the capture could not see the window; they are no sample and not `lost` (honesty rule 5). A verdict "
             "with blind inputs says so: those inputs are not measured.", "",
             "| arm | row | load | round | status | display | screen locked | refresh ms | 1-min load | n / lost / blind / inputs | reason |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    for e in entries:
        if e.get("arm") == "both":
            continue
        refresh = e.get("refresh_ms_measured") if e.get("arm") == "cmux" else e.get("refresh_ms_seen")
        lines.append(f"| {e.get('arm')} | {e.get('row')} | {e.get('load')} | {e.get('round')} | {e.get('status')} | "
                     f"{e.get('display_label')} | {e.get('console_locked')} | {refresh} | "
                     f"{e.get('load1_before')}-{e.get('load1_after')} | {len(e.get('samples') or [])} / "
                     f"{e.get('lost')} / {e.get('blind', '-')} / {e.get('inputs')} | {str(e.get('reason', ''))[:140]} |")
    print("\n".join(lines))
    if args.md:
        with open(args.md, "a") as f:
            f.write("\n".join(lines) + "\n")
    return code


def judge_check(check):
    """Honesty rule 5 on made-up callback lists, with no app: which inputs are blind and which stay lost. Each
    case gives (samples, lost, blind, late refreshes); a blind input counts no late refresh, a lost one LOST_LATE."""
    ms, refresh = 1_000_000, 1000.0 / 120
    t0, t1 = 1000 * ms, 1250 * ms
    start_limit = t0 + int(BLIND_START_REFRESHES * refresh * 1e6)
    silent_ms = CAPTURE_SILENT_REFRESHES * refresh
    awake = list(range(0, 2000 * ms, 16 * ms))  # the stream calls back all the time (992, 1008, 1024 ... ms)
    next_frame = [{"t": t1 + 17 * ms}]

    def until(last_ms, again_ms=None):
        """The stream stops `last_ms` after the first input and calls back again from `again_ms` after it."""
        return [c for c in awake if c <= t0 + last_ms * ms or (again_ms is not None and c >= t0 + again_ms * ms)]

    def judged(stamps, changed, callbacks):
        samples, lost, missed, blind = latencies(stamps, changed, 300, refresh, callbacks)
        return len(samples), lost, blind, missed

    lost_one, on_time = cp.LOST_LATE, cp.late(17.0, refresh)  # on_time: the second input's frame, 17 ms after it
    cases = [
        ("the stream stops after the input, no frame: blind", ([t0, t1], next_frame, until(12, 267)), (1, 0, 1, on_time)),
        ("the stream stays awake, no frame: lost", ([t0, t1], next_frame, awake), (1, 1, 0, lost_one + on_time)),
        ("no callback list: lost", ([t0, t1], next_frame, []), (1, 1, 0, lost_one + on_time)),
        ("a frame that ends the silence 200 ms late: blind, no sample",
         ([t0], [{"t": t0 + 200 * ms}], until(12, 200)), (0, 0, 1, 0)),
        ("the stream stops 24 ms after the input (inside the start limit), no frame: blind",
         ([t0], [], until(25)), (0, 0, 1, 0)),
        ("the last callback is exactly at the start limit, no frame: blind",
         ([t0], [], until(12) + [start_limit]), (0, 0, 1, 0)),
        ("the stream stops 40 ms after the input (past the start limit), no frame: lost",
         ([t0], [], until(41)), (0, 1, 0, lost_one)),
        ("the stream stops 100 ms after the input, no frame: lost", ([t0], [], until(100)), (0, 1, 0, lost_one)),
        ("the stream was silent before the input already, no frame: lost", ([t0], [], until(-200)), (0, 1, 0, lost_one)),
        ("the last callback is exactly at the input, no frame: lost",
         ([t0], [], until(-8) + [t0]), (0, 1, 0, lost_one)),
        ("a late frame while the stream is awake: a sample",
         ([t0], [{"t": t0 + 200 * ms}], awake), (1, 0, 0, cp.late(200.0, refresh))),
        ("a frame after a gap of 5 refreshes (not a silence): a sample",
         ([t0], [{"t": t0 + 50 * ms}], until(9) + [t0 + 50 * ms]), (1, 0, 0, cp.late(50.0, refresh))),
        ("a frame after a gap just over the silence limit: blind",
         ([t0], [{"t": t0 + int((9 + silent_ms + 1) * ms)}], until(9) + [t0 + int((9 + silent_ms + 1) * ms)]), (0, 0, 1, 0)),
    ]
    for name, given, want in cases:
        got = judged(*given)
        check(f"rule 5 (made-up frames): {name}", got == want,
              f"samples, lost, blind, late refreshes = {got}, want {want}")


def selfcheck(args):
    """The honesty proofs on this host, with the real app (docstring rules 2-5). Prints one line per check."""
    out = os.path.abspath(args.out)
    os.makedirs(out, exist_ok=True)
    server = Server()
    hz, checks, facts = args.hz, [], {"console": chrome_arm.console_state(), "displays": chrome_arm.displays()}

    def check(name, ok, detail):
        checks.append(bool(ok))
        print(f"APPCLOCK-SELFCHECK {'ok ' if ok else 'BAD'} {name}: {detail}", flush=True)

    judge_check(check)
    with gui_lock(not args.no_lock):
        cmux = None
        try:
            cmux = Cmux(args.cmux, os.path.join(out, "selfcheck"), server, args.screen).launch()
            cmux.setup(False, terminal="clear")
            region, facts["region_from"] = cmux.terminal_box(lines=3)
            # Delivered keys: each has a response frame, and the terminal holds the text.
            cmux.record("live", 20, region, row_step=4, worst_frames=600)
            stamps = type_keys(cmux, 10, random.Random(1))
            typed = "asdfghjkla" in cmux.terminal_text()
            check("the keys reached the terminal (its text holds them)", typed, f"typed text seen: {typed}")
            cmux.rpc("debug.key", {"key": "u", "modifiers": ["ctrl"]})
            try:
                live = latency_result(cmux, hz, stamps)
            except CaptureBlind as error:  # not rule 2: the app got frames, the stream stopped at too many keys
                check("rule 5: the capture saw the delivered keys", False, str(error))
                print(f"APPCLOCK-SELFCHECK FAIL {sum(checks)}/{len(checks)}", flush=True)
                return 1
            except NotRun as error:
                facts["no_frames"] = str(error)
                check("rule 2: no frame from the recorder is 'not run', never a number", True, str(error))
                print("APPCLOCK-SELFCHECK STOP: this host shows no cmux frame now; rules 3 and 4 need frames", flush=True)
                print("APPCLOCK-SELFCHECK " + json.dumps(facts), flush=True)
                return 0 if all(checks) else 1
            facts["live"] = {k: live.get(k) for k in ("refresh_ms_measured", "link_ticks_1s", "recorder", "display_id", "lost",
                                                      "blind")}
            facts["screen_fault"] = screen_fault(live, hz)
            # A key at which the capture stream stopped is blind (rule 5): no sample, and not a key with no frame.
            check("delivered keys have frames", len(live["samples"]) + live["blind"] == 10 and live["lost"] == 0,
                  f"n {len(live['samples'])} lost {live['lost']} blind {live['blind']} {cp.stats(live['samples'])} "
                  f"refresh {live.get('refresh_ms_measured')} ms")
            check("rule 1: the screen's state is read", True, f"screen fault: {facts['screen_fault']}")
            pause(1.0)
            # Rule 3: times at which no key was sent have no sample.
            cmux.record("phantom", 20, region, row_step=4, worst_frames=600)
            phantom = []
            for _ in range(10):
                phantom.append(now_ns())
                pause(0.15)
            pause(0.4)
            none = latency_result(cmux, hz, phantom)
            check("rule 3: an input that is not sent has no sample", none["samples"] == [] and none["lost"] == 10,
                  f"n {len(none['samples'])} lost {none['lost']} blind {none['blind']} missed {none['missed']}")
            # Rule 4: a frozen window. Keys sent while the main thread is blocked have no frame in time.
            cmux.record("frozen", 20, region, row_step=4, worst_frames=600)
            frozen = []
            for i in range(5):
                # debug.stall's reply comes when the stall ends, and so does the key's: each on its own connection.
                stall = threading.Thread(target=lambda: cmux.app.rpc("debug.stall", {"ms": 900}))
                stall.start()
                pause(0.15)
                t = now_ns()
                sender = threading.Thread(target=lambda t=t, i=i: cmux.app.rpc("debug.key", {"key": LETTERS[i], "timestamp": t / 1e9}))
                sender.start()
                frozen.append(t)
                stall.join()
                sender.join()
                pause(0.6)
            ice = latency_result(cmux, hz, frozen, horizon_ms=300)
            check("rule 4: a frozen window loses its inputs (lost, not blind)", ice["lost"] == 5 and ice["missed"] >= 5 * cp.LOST_LATE,
                  f"n {len(ice['samples'])} lost {ice['lost']} blind {ice['blind']} missed {ice['missed']} frames {ice['frames']}")
            verdict, why = cp.verdict_of(cp.cell_of([ice]), cp.cell_of([{"samples": [12.0] * 5, "lost": 0, "missed": 0, "inputs": 5}]))
            check("rule 4: the report's verdict for it is FAIL", verdict == "FAIL", f"{verdict} ({why})")
        except NotRun as error:
            check("the app launched and was set up", False, str(error))
        finally:
            if cmux:
                cmux.quit()
    print("APPCLOCK-SELFCHECK " + json.dumps(facts), flush=True)
    print(f"APPCLOCK-SELFCHECK {'PASS' if all(checks) else 'FAIL'} {sum(checks)}/{len(checks)}", flush=True)
    return 0 if all(checks) else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    sub = parser.add_subparsers(dest="cmd", required=True)
    for name in ("run", "selfcheck"):
        p = sub.add_parser(name)
        p.add_argument("--cmux", required=True, help="a bench build (reload.sh --config bench): Release + the debug socket")
        p.add_argument("--out", required=True)
        p.add_argument("--screen", default="last", help="NSScreen index or 'last' for the app's window")
        p.add_argument("--hz", type=int, default=120)
        p.add_argument("--no-lock", action="store_true")
        if name == "run":
            p.add_argument("--chrome", default=cp.CHROME_DEFAULT)
            p.add_argument("--rows", default=",".join(cp.ROWS))
            p.add_argument("--loads", default="light,load")
            p.add_argument("--rounds", type=int, default=2)
            p.add_argument("--arms", default="cmux,chrome")
            p.add_argument("--cmux-sha", default="")
            p.add_argument("--max-host-load", type=float, default=15.0,
                           help="a run that starts at this 1-min load average or more is 'invalid' (no number)")
            p.add_argument("--note", default="")
    r = sub.add_parser("report")
    r.add_argument("--out", required=True)
    r.add_argument("--md", default="")
    r.add_argument("--json", default="")
    args = parser.parse_args()
    if args.cmd == "run":
        return run(args)
    if args.cmd == "selfcheck":
        return selfcheck(args)
    return report(args)


if __name__ == "__main__":
    sys.exit(main())
