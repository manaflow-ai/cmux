#!/usr/bin/env python3
"""Real HID input and the probe parsers the cmux input benches share (p04-input.md tasks 070 and 072).

The benches (input-latency-bench.py, typing-frame-bench.py, scroll-jank-bench.py) each had their own key poster,
socket client and CSV reader; old and new rows drifted (p04-input.md risk 11). This module is the one copy:

  Control             the tagged app's control socket: one JSON line per request (`rpc`), `action.run`, the app's
                      own CLI, and a bounded wait for a condition of the live app.
  HidPoster           real input at the HID event tap (CGEventPost(kCGHIDEventTap)): key presses, trackpad-like
                      scroll gestures (began/changed/ended and momentum), clicks and drags at a fixed rate. The
                      window server queues each event for the frontmost app, so it takes a person's path: the event
                      queue, AppKit dispatch, and the scheduler's pending-input check. The app records it as a
                      person's input (`entry=person`).
  DebugKeyPoster      `debug.key` over the control socket with the client's send time as the event timestamp. It
                      goes through the socket's injected-input lane, not the event queue, and the app labels it
                      automation (`entry=automation`): never a person's key latency. `poster_for` hands it out only
                      for an explicit `debug` input mode, and every row it produces says `input: debug`.
  probe_rows          the typing probe's CSV (CMUX_NEXT_TYPING_PROBE).
  latency_events      the `input.latency` signposts of a `log stream --signpost --style ndjson` capture
                      (Signposter.event(_:_: InputLatencySignpostMessage)), decoded to names and milliseconds.
  SignpostRecording   `log stream` of the app's `input` signpost category around a phase (perf-signposts.py's
                      Recording).
  Periodic            a thread that calls a step at a fixed period (storms, stalls, streams).
  window_point        a point of a window (bottom-left or top-left window coordinates) as a global display point,
                      the coordinates CGEvent takes.

The CoreGraphics calls sit behind a backend (`CoreGraphicsBackend`, or `RecordingBackend` for tests), and the
clock and sleep are injected, so `python3 scripts/cmux-next/hid_input.py --self-test` checks the pacing, the event
sequences and the parsers on any OS.
"""
import contextlib
import csv
import json
import os
import re
import socket
import subprocess
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))

# Carbon kVK_ANSI_* virtual key codes of the keys the benches type.
KEYCODES = {
    "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
    "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
    "m": 46, "return": 36, "tab": 48, "space": 49, "delete": 51, "escape": 53,
}
# CGEventFlags (CGEventTypes.h).
FLAGS = {"shift": 0x20000, "control": 0x40000, "option": 0x80000, "command": 0x100000}
# The modifier keys' kVK_* codes: a held modifier is its key down (a flagsChanged event) before the input it modifies.
MODIFIER_KEYCODES = {"shift": 56, "control": 59, "option": 58, "command": 55}
# CGEventType (CGEventTypes.h).
LEFT_MOUSE_DOWN, LEFT_MOUSE_UP, MOUSE_MOVED, LEFT_MOUSE_DRAGGED = 1, 2, 5, 6
# CGScrollPhase and CGMomentumScrollPhase (CGEventTypes.h), and the scroll fields they go in.
SCROLL_BEGAN, SCROLL_CHANGED, SCROLL_ENDED = 1, 2, 4
MOMENTUM_NONE, MOMENTUM_BEGIN, MOMENTUM_CONTINUE, MOMENTUM_END = 0, 1, 2, 3
FIELD_SCROLL_IS_CONTINUOUS, FIELD_SCROLL_PHASE, FIELD_MOMENTUM_PHASE = 88, 99, 123
FIELD_MOUSE_CLICK_STATE = 1

# The typed letters: one key in flight at a time, round robin.
LETTERS = "abcdefghijklmnopqrstuvwxyz"

# The raw values of CmuxNextInputCore's enums, in declaration order (InputEventKind.swift,
# InputPresentationSource.swift): the signpost carries the raw value only.
KINDS = ("keyPress", "keyRelease", "flags", "mousePress", "mouseRelease", "pointerMove", "drag", "scrollBegin",
         "scrollFirstUpdate", "scrollUpdate", "scrollMomentum", "scrollEnd", "magnify")
TARGETS = ("terminal", "textView", "chromiumPage", "webkitPage", "agentPane", "layout", "sidebar", "palette", "other")
ENTRYPOINTS = ("person", "automation")
PRESENTATION_SOURCES = ("estimatedVsync", "metalPresented", "hostFeedback", "pageEstimated", "extrapolatedVsync",
                        "nominalRefresh")
# InputLatencySignpostMessage's stage fields (microseconds after gen_ns, -1 when skipped) and the InputStage names
# the benches report them under, in stage order.
STAGE_FIELDS = (
    ("last_gen_us", "last_generated"), ("arrived_us", "arrived_main"), ("dispatch_start_us", "dispatch_start"),
    ("ti_start_us", "text_input_start"), ("ti_end_us", "text_input_end"), ("dispatch_end_us", "dispatch_end"),
    ("commit_us", "main_commit"), ("content_us", "content_submitted"), ("daemon_us", "daemon_received"),
    ("pty_us", "pty_written"), ("echo_read_us", "echo_read"), ("echo_sent_us", "echo_sent"),
    ("presented_us", "presented"),
)
SIGNPOST_SUBSYSTEM = "com.cmuxterm.app.next"
INPUT_LATENCY = "input.latency"


class InputRefused(Exception):
    """An input mode or a poster a bench must not use (debug.key where real input was asked, a drag over the
    socket)."""


class HidUnavailable(Exception):
    """CoreGraphics is not there (not macOS) or refused a call."""


# ---------------------------------------------------------------- control socket
class Control:
    """The tagged app's control socket and CLI. `socket_path` and `config` may change after a relaunch."""

    def __init__(self, socket_path, cli_path=None, config=None):
        self.socket_path, self.cli_path, self.config = socket_path, cli_path, config

    def rpc(self, method, params=None, timeout=30):
        """The reply's `result`, or {"error": ...} when the call failed or the app answered an error."""
        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.settimeout(timeout)
            conn.connect(self.socket_path)
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

    def action(self, name, args=None, focus=True, timeout=60, target=None):
        params = {"action": name, "args": args or {}, "focus": focus, "origin": "script"}
        if target:
            params["target"] = target
        return self.rpc("action.run", params, timeout=timeout)

    def cli(self, *args, timeout=60):
        env = {k: v for k, v in os.environ.items() if not k.startswith("CMUX_")}
        if self.config:
            env["CMUX_NEXT_CONFIG_FILE"] = self.config
        try:
            return subprocess.run([self.cli_path, "--app-socket", self.socket_path, *args], env=env, capture_output=True,
                                  text=True, timeout=timeout, stdin=subprocess.DEVNULL)
        except subprocess.TimeoutExpired:
            return subprocess.CompletedProcess(args, 124, "", "timeout")
        except OSError as error:
            return subprocess.CompletedProcess(args, 127, "", str(error))


def wait(predicate, seconds, step=0.25, clock=time.monotonic, sleep=time.sleep):
    """The predicate's first truthy value within `seconds`, else None (a bounded wait for the live app)."""
    end = clock() + seconds
    while clock() < end:
        try:
            value = predicate()
        except Exception:  # the app may not answer yet
            value = None
        if value:
            return value
        sleep(step)
    return None


def is_error(reply):
    return isinstance(reply, dict) and bool(reply.get("error"))


# ---------------------------------------------------------------- HID backends
class CoreGraphicsBackend:
    """CGEvent through ctypes. Loads CoreGraphics on first use; HidUnavailable off macOS."""

    def __init__(self):
        self._cg = None

    def _lib(self):
        if self._cg is not None:
            return self._cg
        import ctypes
        import ctypes.util
        path = ctypes.util.find_library("CoreGraphics")
        if not path:
            raise HidUnavailable("CoreGraphics is not on this host (real HID input needs macOS)")
        cg = ctypes.cdll.LoadLibrary(path)

        class CGPoint(ctypes.Structure):
            _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]

        class CGSize(ctypes.Structure):
            _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]

        class CGRect(ctypes.Structure):
            _fields_ = [("origin", CGPoint), ("size", CGSize)]

        self.CGPoint = CGPoint
        ref = ctypes.c_void_p
        cg.CGEventCreateKeyboardEvent.restype = ref
        cg.CGEventCreateKeyboardEvent.argtypes = [ref, ctypes.c_uint16, ctypes.c_bool]
        cg.CGEventCreateMouseEvent.restype = ref
        cg.CGEventCreateMouseEvent.argtypes = [ref, ctypes.c_uint32, CGPoint, ctypes.c_uint32]
        cg.CGEventCreateScrollWheelEvent2.restype = ref
        cg.CGEventCreateScrollWheelEvent2.argtypes = [ref, ctypes.c_uint32, ctypes.c_uint32, ctypes.c_int32,
                                                      ctypes.c_int32, ctypes.c_int32]
        cg.CGEventSetFlags.argtypes = [ref, ctypes.c_uint64]
        cg.CGEventSetIntegerValueField.argtypes = [ref, ctypes.c_uint32, ctypes.c_int64]
        cg.CGEventSetLocation.argtypes = [ref, CGPoint]
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ref]
        cg.CFRelease.argtypes = [ref]
        cg.CGMainDisplayID.restype = ctypes.c_uint32
        cg.CGDisplayBounds.restype = CGRect
        cg.CGDisplayBounds.argtypes = [ctypes.c_uint32]
        self._cg = cg
        return cg

    def _post(self, event):
        cg = self._lib()
        if not event:
            raise HidUnavailable("CoreGraphics made no event")
        cg.CGEventPost(0, event)  # kCGHIDEventTap
        cg.CFRelease(event)

    def key(self, code, down, flags=0):
        cg = self._lib()
        event = cg.CGEventCreateKeyboardEvent(None, code, down)
        if flags and event:
            cg.CGEventSetFlags(event, flags)
        self._post(event)

    def mouse(self, kind, x, y, click_state=1, flags=0):
        cg = self._lib()
        event = cg.CGEventCreateMouseEvent(None, kind, self.CGPoint(x, y), 0)  # kCGMouseButtonLeft
        if event and kind in (LEFT_MOUSE_DOWN, LEFT_MOUSE_UP, LEFT_MOUSE_DRAGGED):
            cg.CGEventSetIntegerValueField(event, FIELD_MOUSE_CLICK_STATE, click_state)
        if event and flags:
            cg.CGEventSetFlags(event, flags)
        self._post(event)

    def scroll(self, x, y, dx, dy, phase, momentum, flags=0):
        cg = self._lib()
        event = cg.CGEventCreateScrollWheelEvent2(None, 0, 2, int(dy), int(dx), 0)  # kCGScrollEventUnitPixel
        if event:
            cg.CGEventSetLocation(event, self.CGPoint(x, y))
            if flags:
                cg.CGEventSetFlags(event, flags)
            cg.CGEventSetIntegerValueField(event, FIELD_SCROLL_IS_CONTINUOUS, 1)
            cg.CGEventSetIntegerValueField(event, FIELD_SCROLL_PHASE, phase)
            cg.CGEventSetIntegerValueField(event, FIELD_MOMENTUM_PHASE, momentum)
        self._post(event)

    def main_display_height(self):
        """The main display's height in points: global display coordinates have their origin at its top left."""
        bounds = self._lib().CGDisplayBounds(self._lib().CGMainDisplayID())
        return float(bounds.size.height)


class RecordingBackend:
    """A backend that records each event instead of posting it (tests, --self-test)."""

    def __init__(self, display_height=1080.0, clock=None):
        self.events, self.display_height, self.clock = [], display_height, clock

    def _add(self, event):
        if self.clock:
            event["t"] = self.clock()
        self.events.append(event)

    def key(self, code, down, flags=0):
        self._add({"type": "key", "code": code, "down": down, "flags": flags})

    def mouse(self, kind, x, y, click_state=1, flags=0):
        self._add({"type": "mouse", "kind": kind, "x": x, "y": y, "flags": flags})

    def scroll(self, x, y, dx, dy, phase, momentum, flags=0):
        self._add({"type": "scroll", "x": x, "y": y, "dx": dx, "dy": dy, "phase": phase, "momentum": momentum,
                   "flags": flags})

    def main_display_height(self):
        return self.display_height


class Pacer:
    """Fixed-rate pacing on an absolute schedule (a late event does not push the next ones back), so a 1000 Hz drag
    stays at 1000 Hz on average. Counts the events posted more than one period late."""

    def __init__(self, rate_hz, clock=time.perf_counter, sleep=time.sleep):
        self.period, self.clock, self.sleep = 1.0 / rate_hz, clock, sleep
        self.start = self.clock()
        self.index, self.late = 0, 0

    def tick(self):
        due = self.start + self.index * self.period
        rest = due - self.clock()
        if rest > 0:
            self.sleep(rest)  # the input's own pace, not a wait for the app
        elif -rest > self.period:
            self.late += 1
        self.index += 1

    def achieved_hz(self):
        spent = self.clock() - self.start
        return round(self.index / spent, 1) if spent > 0 else None


# ---------------------------------------------------------------- posters
class HidPoster:
    """Real input at the HID event tap. Every result it returns is labelled `input: real`."""

    input = "real"

    def __init__(self, backend=None, clock=time.perf_counter, sleep=time.sleep):
        self.backend = backend or CoreGraphicsBackend()
        self.clock, self.sleep = clock, sleep

    def key(self, name, modifiers=()):
        """One key press and release. Returns None (the HID tap gives no reply)."""
        code = KEYCODES[name]
        flags = 0
        for modifier in modifiers:
            flags |= FLAGS[modifier]
        self.backend.key(code, True, flags)
        self.backend.key(code, False, flags)
        return None

    def click(self, point):
        x, y = point
        self.backend.mouse(MOUSE_MOVED, x, y)
        self.backend.mouse(LEFT_MOUSE_DOWN, x, y)
        self.backend.mouse(LEFT_MOUSE_UP, x, y)

    def drag(self, start, end, rate_hz=1000.0, seconds=1.0, back=True, hold=0.05, modifiers=()):
        """A press at `start`, drag events at `rate_hz` to `end` (and back to `start` with `back`) over `seconds`,
        then the release; `modifiers` are held from before the press to after the release, as a person's (their
        keys down, and their flags on every mouse event). Returns {events, rate_hz (achieved), late}."""
        (x0, y0), (x1, y1) = start, end
        flags = 0
        for modifier in modifiers:
            flags |= FLAGS[modifier]
            self.backend.key(MODIFIER_KEYCODES[modifier], True, flags)
        steps = max(2, int(rate_hz * seconds))
        path = [(x0 + (x1 - x0) * i / (steps - 1), y0 + (y1 - y0) * i / (steps - 1)) for i in range(steps)]
        if back:
            path += list(reversed(path[:-1]))
        self.backend.mouse(MOUSE_MOVED, x0, y0, flags=flags)
        self.backend.mouse(LEFT_MOUSE_DOWN, x0, y0, flags=flags)
        if hold:
            self.sleep(hold)  # a press held still before the drag starts, as a person's
        pacer = Pacer(rate_hz, self.clock, self.sleep)
        for x, y in path:
            pacer.tick()
            self.backend.mouse(LEFT_MOUSE_DRAGGED, x, y, flags=flags)
        x, y = path[-1]
        self.backend.mouse(LEFT_MOUSE_UP, x, y, flags=flags)
        for modifier in reversed(modifiers):
            flags &= ~FLAGS[modifier]
            self.backend.key(MODIFIER_KEYCODES[modifier], False, flags)
        return {"events": len(path), "rate_hz": pacer.achieved_hz(), "late": pacer.late}

    def scroll_gesture(self, point, dy=-12.0, dx=0.0, rate_hz=120.0, changes=30, momentum=20, modifiers=()):
        """A trackpad scroll at `point`: began, `changes` changed events, ended, then `momentum` momentum events
        that decay, all at `rate_hz` (the display rate). With `modifiers` (`command` for the layout's
        Command + Scroll) the modifier keys go down before the began event, every scroll event carries their
        flags, and they come up after the last momentum event, as a person holds them. Returns
        {events, rate_hz, late}."""
        x, y = point
        pacer = Pacer(rate_hz, self.clock, self.sleep)
        events = 0
        with self._held(modifiers) as flags:

            def post(ddx, ddy, phase, momentum_phase):
                nonlocal events
                pacer.tick()
                self.backend.scroll(x, y, ddx, ddy, phase, momentum_phase, flags)
                events += 1

            post(0, 0, SCROLL_BEGAN, MOMENTUM_NONE)
            for _ in range(changes):
                post(dx, dy, SCROLL_CHANGED, MOMENTUM_NONE)
            post(0, 0, SCROLL_ENDED, MOMENTUM_NONE)
            for index in range(momentum):
                decay = 0.9 ** (index + 1)
                phase = MOMENTUM_BEGIN if index == 0 else (MOMENTUM_END if index == momentum - 1 else MOMENTUM_CONTINUE)
                post(round(dx * decay), round(dy * decay), 0, phase)
        return {"events": events, "rate_hz": pacer.achieved_hz(), "late": pacer.late}

    def scroll_touch(self, point, modifiers=()):
        """Fingers down and up with no movement: a began and an ended event. The app's ledger starts a scroll at a
        began event and emits the scroll before it only then (Chrome emits a scroll's PerScroll histograms at the
        next OnScrollStarted, cc/metrics/scroll_jank_dropped_frame_tracker.cc), so a bench ends its gestures with
        one to have the last gesture counted. Returns {events}."""
        x, y = point
        with self._held(modifiers) as flags:
            self.backend.scroll(x, y, 0, 0, SCROLL_BEGAN, MOMENTUM_NONE, flags)
            self.backend.scroll(x, y, 0, 0, SCROLL_ENDED, MOMENTUM_NONE, flags)
        return {"events": 2}

    @contextlib.contextmanager
    def _held(self, modifiers):
        """Presses each modifier key, its flags growing as a person's chord does, and yields all their flags. The
        keys it pressed come up in reverse order when the block ends, also when a post raises (HidUnavailable) or the
        run is interrupted, so no modifier stays down at the HID tap for later input."""
        pressed, flags = [], 0
        try:
            for modifier in modifiers:
                self.backend.key(MODIFIER_KEYCODES[modifier], True, flags | FLAGS[modifier])
                flags |= FLAGS[modifier]
                pressed.append(modifier)
            yield flags
        finally:
            for modifier in reversed(pressed):
                flags &= ~FLAGS[modifier]
                self.backend.key(MODIFIER_KEYCODES[modifier], False, flags)


def uptime_raw():
    """CLOCK_UPTIME_RAW seconds, the clock of NSEvent.timestamp (CLOCK_MONOTONIC off macOS, for tests)."""
    return time.clock_gettime(getattr(time, "CLOCK_UPTIME_RAW", time.CLOCK_MONOTONIC))


class DebugKeyPoster:
    """`debug.key` over the control socket, stamped with the client's CLOCK_UPTIME_RAW send time. The app labels
    these keys automation; every result is labelled `input: debug` and is never a person's key latency."""

    input = "debug"

    def __init__(self, control, params=None, clock=None):
        self.control, self.params = control, dict(params or {})
        self.clock = clock or uptime_raw

    def key(self, name, modifiers=()):
        params = dict(self.params, key=name, timestamp=self.clock())
        if modifiers:
            params["modifiers"] = list(modifiers)
        return self.control.rpc("debug.key", params, timeout=10)

    def _refuse(self, *args, **kwargs):
        raise InputRefused("--input debug sends keys over the control socket only; pointer input needs --input real")

    click = drag = scroll_gesture = scroll_touch = _refuse


def poster_for(mode, control=None, backend=None, debug_params=None, clock=time.perf_counter, sleep=time.sleep):
    """The poster of input `mode`: `real` (HID tap) or `debug` (debug.key, only when asked by name)."""
    if mode == "real":
        return HidPoster(backend, clock=clock, sleep=sleep)
    if mode == "debug":
        if control is None:
            raise InputRefused("--input debug needs the app's control socket")
        return DebugKeyPoster(control, debug_params)
    raise InputRefused(f"unknown input mode {mode!r}: real (HID tap) or debug (debug.key, labelled)")


def bring_front(pid):
    """Makes the app frontmost: real keys go to the frontmost app's key window."""
    try:
        subprocess.run(["osascript", "-e",
                        f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'],
                       capture_output=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        pass


def display_refresh():
    """The displays' refresh rates (system_profiler) and their lines, for judging drops in frames."""
    try:
        out = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True, timeout=60).stdout
    except (OSError, subprocess.TimeoutExpired):
        return {"hz": None, "lines": []}
    rates = re.findall(r"@ ?([\d.]+) ?Hz", out) or re.findall(r"Refresh Rate: ?([\d.]+)", out)
    lines = [line.strip() for line in out.splitlines() if "Hz" in line or "Resolution" in line]
    return {"hz": [float(r) for r in rates] or None, "lines": lines[:6]}


def macos_version():
    """This host's macOS version (sw_vers), None off macOS."""
    try:
        return subprocess.run(["sw_vers", "-productVersion"], capture_output=True, text=True, timeout=10).stdout.strip() or None
    except (OSError, subprocess.TimeoutExpired):
        return None


# ---------------------------------------------------------------- geometry
def window_point(frame, point, display_height, top_left=False):
    """`point` of a window whose AppKit frame (bottom-left screen points, [x, y, w, h]) is `frame`, in global display
    coordinates (top left of the main display), which CGEvent takes. `top_left` when `point` is measured from the
    window's top (debug.pane_chrome's rects); else from its bottom (convert(_:to: nil))."""
    fx, fy, _, fh = (float(v) for v in frame)
    x, y = float(point[0]), float(point[1])
    from_bottom = fh - y if top_left else y
    return fx + x, display_height - (fy + from_bottom)


def rect_center(rect):
    """The center of [x, y, w, h] or {x, y, width, height}."""
    if isinstance(rect, dict):
        rect = [rect.get("x"), rect.get("y"), rect.get("width"), rect.get("height")]
    x, y, w, h = (float(v) for v in rect)
    return x + w / 2, y + h / 2


# ---------------------------------------------------------------- parsers
def probe_rows(path):
    """The typing probe's CSV rows (CMUX_NEXT_TYPING_PROBE), [] before the first."""
    try:
        with open(path) as handle:
            return list(csv.DictReader(handle))
    except OSError:
        return []


def _name(table, raw):
    try:
        index = int(raw)
    except (TypeError, ValueError):
        return str(raw)
    return table[index] if 0 <= index < len(table) else f"raw{index}"


def decode_latency_message(message):
    """One `input.latency` message (key=value fields) as {kind, target, entrypoint, presentation_source,
    variable_refresh, coalesced, caused_frame_update, generated_ns, stages_ms: {stage: ms after generated}}.
    Skipped stages (-1) are left out. None when the message is not an input.latency one."""
    values = dict(part.split("=", 1) for part in message.split() if "=" in part)
    if "kind" not in values or "gen_ns" not in values:
        return None
    stages = {}
    for field, stage in STAGE_FIELDS:
        try:
            micros = int(values.get(field, "-1"))
        except ValueError:
            continue
        if micros >= 0:
            stages[stage] = micros / 1000.0
    return {
        "kind": _name(KINDS, values.get("kind")), "target": _name(TARGETS, values.get("target")),
        "entrypoint": _name(ENTRYPOINTS, values.get("entry")),
        "presentation_source": _name(PRESENTATION_SOURCES, values.get("source")),
        "variable_refresh": values.get("vrr") == "1", "coalesced": int(values.get("coalesced", "1") or 1),
        "caused_frame_update": values.get("frame") == "1", "generated_ns": int(values.get("gen_ns", "0") or 0),
        "stages_ms": stages,
    }


def latency_events(lines):
    """The `input.latency` events of a `log stream --signpost --style ndjson` capture, decoded
    (decode_latency_message), and the number of messages the log tool reported lost."""
    events, lost = [], 0
    for raw in lines:
        line = raw.strip()
        if not line.startswith("{"):
            continue
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if event.get("eventType") == "lossEvent":
            lost += 1
            continue
        if event.get("eventType") != "signpostEvent" or event.get("subsystem") != SIGNPOST_SUBSYSTEM:
            continue
        if event.get("signpostName") != INPUT_LATENCY:
            continue
        decoded = decode_latency_message(event.get("eventMessage") or "")
        if decoded:
            events.append(decoded)
    return events, lost


class SignpostRecording:
    """`log stream` of the app's `input` signposts for one process (perf-signposts.py's Recording, which drains the
    pipe on a thread so logd drops nothing). `stop()` returns the decoded input.latency events and the loss count."""

    def __init__(self, pid):
        sys.path.insert(0, HERE)
        from bench_launch import load_by_path
        signposts = load_by_path("perf_signposts", os.path.join(HERE, "perf-signposts.py"))
        self._recording = signposts.Recording(pid, ["input"])

    def stop(self):
        return latency_events(self._recording.stop())


class Periodic(threading.Thread):
    """Calls `step(index)` every `period` seconds until stopped; counts calls and the ones that returned an error."""

    def __init__(self, name, step, period):
        super().__init__(daemon=True, name=name)
        self.step, self.period, self.flag = step, period, threading.Event()
        self.calls, self.errors, self.spent_ms = 0, 0, []

    def run(self):
        while not self.flag.is_set():
            t0 = time.perf_counter()
            try:
                result = self.step(self.calls)
                if is_error(result) or getattr(result, "returncode", 0):
                    self.errors += 1
            except Exception:  # a failing step is counted, the storm goes on
                self.errors += 1
            self.calls += 1
            spent = time.perf_counter() - t0
            self.spent_ms.append(spent * 1000)
            if self.period - spent > 0:
                self.flag.wait(self.period - spent)  # the storm's own pace

    def stop(self):
        self.flag.set()
        self.join(timeout=30)

    def report(self):
        spent = sorted(self.spent_ms)
        return {"name": self.name, "calls": self.calls, "errors": self.errors, "period_s": self.period,
                "step_ms_max": round(spent[-1], 1) if spent else None}


# ---------------------------------------------------------------- self-test
def self_test():
    failures = []

    def check(name, condition, detail=""):
        if not condition:
            failures.append(f"{name}: {detail}")

    # Keys: a press and a release per key, modifiers in both.
    backend = RecordingBackend()
    poster = poster_for("real", backend=backend)
    poster.key("a")
    poster.key("a", modifiers=("command",))
    check("key events", [e["down"] for e in backend.events] == [True, False, True, False], backend.events)
    check("key code", all(e["code"] == 0 for e in backend.events), backend.events)
    check("key flags", backend.events[2]["flags"] == FLAGS["command"] and backend.events[0]["flags"] == 0, backend.events)

    # Drags: a 1000 Hz drag on a fake clock keeps its rate and posts press, drags and release.
    now = [0.0]

    def clock():
        return now[0]

    def sleep(seconds):
        now[0] += seconds

    backend = RecordingBackend(clock=clock)
    poster = HidPoster(backend, clock=clock, sleep=sleep)
    result = poster.drag((100, 100), (200, 100), rate_hz=1000, seconds=0.1, hold=0)
    kinds = [e["kind"] for e in backend.events]
    check("drag sequence", kinds[0] == MOUSE_MOVED and kinds[1] == LEFT_MOUSE_DOWN and kinds[-1] == LEFT_MOUSE_UP, kinds[:3])
    drags = [e for e in backend.events if e["kind"] == LEFT_MOUSE_DRAGGED]
    check("drag count", len(drags) == 199 and result["events"] == 199, (len(drags), result))
    check("drag rate", result["rate_hz"] is not None and 990 <= result["rate_hz"] <= 1010, result)
    check("drag ends where it began", drags[-1]["x"] == 100 and max(e["x"] for e in drags) == 200, drags[-1])
    times = [e["t"] for e in drags]
    check("drag spacing", all(abs((b - a) - 0.001) < 1e-9 for a, b in zip(times, times[1:])), times[:4])
    check("plain drag has no modifier", all(e.get("flags", 0) == 0 for e in backend.events), backend.events[:2])

    # An Option-drag: Option down before the press, its flag on every mouse event, Option up after the release.
    backend = RecordingBackend(clock=clock)
    HidPoster(backend, clock=clock, sleep=sleep).drag((100, 100), (120, 100), rate_hz=1000, seconds=0.01, hold=0,
                                                      back=False, modifiers=("option",))
    first, last = backend.events[0], backend.events[-1]
    check("option down first", first["type"] == "key" and first["code"] == MODIFIER_KEYCODES["option"] and first["down"]
          and first["flags"] == FLAGS["option"], first)
    check("option up last", last["type"] == "key" and last["code"] == MODIFIER_KEYCODES["option"] and not last["down"]
          and last["flags"] == 0, last)
    check("option on every mouse event", all(e["flags"] == FLAGS["option"] for e in backend.events if e["type"] == "mouse"),
          [e for e in backend.events if e["type"] == "mouse"][:2])

    # Scrolls: began, changed, ended, then momentum begin/continue/end.
    backend = RecordingBackend(clock=clock)
    HidPoster(backend, clock=clock, sleep=sleep).scroll_gesture((10, 10), dy=-10, changes=3, momentum=3)
    phases = [(e["phase"], e["momentum"]) for e in backend.events]
    check("scroll phases", phases == [(1, 0), (2, 0), (2, 0), (2, 0), (4, 0), (0, 1), (0, 2), (0, 3)], phases)
    check("scroll without modifiers", all(e["flags"] == 0 for e in backend.events), backend.events)

    # Command + Scroll: Command goes down first, every scroll event carries its flag, and it comes up last.
    backend = RecordingBackend(clock=clock)
    HidPoster(backend, clock=clock, sleep=sleep).scroll_gesture((10, 10), dx=-10, dy=0, changes=2, momentum=2,
                                                                modifiers=("command",))
    first, last, scrolls = backend.events[0], backend.events[-1], backend.events[1:-1]
    check("command down first", first["type"] == "key" and first["code"] == MODIFIER_KEYCODES["command"] and first["down"]
          and first["flags"] == FLAGS["command"], first)
    check("command up last", last["type"] == "key" and last["code"] == MODIFIER_KEYCODES["command"] and not last["down"]
          and last["flags"] == 0, last)
    check("command scroll flags", len(scrolls) == 6 and all(e["type"] == "scroll" and e["flags"] == FLAGS["command"]
                                                            for e in scrolls), scrolls)
    check("sideways deltas", [e["dx"] for e in scrolls] == [0, -10, -10, 0, -9, -8] and all(e["dy"] == 0 for e in scrolls),
          [e["dx"] for e in scrolls])

    # A post that fails mid-gesture still lifts Command: the HID tap is left with no modifier held.
    class FailingBackend(RecordingBackend):
        def __init__(self, fail_at):
            super().__init__(clock=clock)
            self.fail_at = fail_at

        def scroll(self, *args, **kwargs):
            if sum(e["type"] == "scroll" for e in self.events) == self.fail_at:
                raise HidUnavailable("CoreGraphics made no event")
            super().scroll(*args, **kwargs)

    for fail_at, gesture in ((3, lambda p: p.scroll_gesture((10, 10), dx=-10, dy=0, changes=4, momentum=2, modifiers=("command",))),
                             (1, lambda p: p.scroll_touch((10, 10), modifiers=("command",)))):
        backend = FailingBackend(fail_at)
        try:
            gesture(HidPoster(backend, clock=clock, sleep=sleep))
            failures.append(f"a failing post at {fail_at} did not raise")
        except HidUnavailable:
            pass
        keys = [(e["down"], e["flags"]) for e in backend.events if e["type"] == "key"]
        check(f"command released after a failed post at {fail_at}", keys == [(True, FLAGS["command"]), (False, 0)]
              and backend.events[-1]["type"] == "key", backend.events)

    # A touch: began and ended with no movement (the ledger's next OnScrollStarted).
    backend = RecordingBackend()
    HidPoster(backend).scroll_touch((5, 5))
    check("scroll touch", [(e["phase"], e["dx"], e["dy"]) for e in backend.events] == [(1, 0, 0), (4, 0, 0)], backend.events)

    # debug.key only by name, and it refuses pointer input.
    class FakeControl:
        def __init__(self):
            self.calls = []

        def rpc(self, method, params=None, timeout=30):
            self.calls.append((method, params))
            return {"ok": True}

    control = FakeControl()
    debug = poster_for("debug", control=control, debug_params={"probe": "commit"})
    debug.key("b")
    check("debug.key", control.calls and control.calls[0][0] == "debug.key" and control.calls[0][1]["probe"] == "commit"
          and control.calls[0][1]["key"] == "b" and "timestamp" in control.calls[0][1], control.calls)
    check("debug labelled", debug.input == "debug" and HidPoster(RecordingBackend()).input == "real")
    for mode in ("", "hid", None):
        try:
            poster_for(mode, control=control)
            failures.append(f"poster_for({mode!r}) did not refuse")
        except InputRefused:
            pass
    for refused in (lambda: debug.drag((0, 0), (1, 1)), lambda: debug.scroll_touch((0, 0))):
        try:
            refused()
            failures.append("debug pointer input did not refuse")
        except InputRefused:
            pass

    # Geometry: a window at (100, 200) 800 x 600 on a 1080 pt display.
    check("bottom-left point", window_point([100, 200, 800, 600], (10, 20), 1080) == (110, 860),
          window_point([100, 200, 800, 600], (10, 20), 1080))
    check("top-left point", window_point([100, 200, 800, 600], (10, 20), 1080, top_left=True) == (110, 300),
          window_point([100, 200, 800, 600], (10, 20), 1080, top_left=True))
    check("rect center", rect_center({"x": 0, "y": 0, "width": 10, "height": 4}) == (5, 2) and rect_center([2, 2, 2, 2]) == (3, 3))

    # The input.latency signpost: names from raw values, skipped stages left out, loss counted.
    message = ("kind=0 target=4 entry=0 source=2 vrr=0 coalesced=1 frame=1 gen_ns=123456789 last_gen_us=-1 "
               "arrived_us=150 dispatch_start_us=200 ti_start_us=-1 ti_end_us=-1 dispatch_end_us=900 commit_us=1500 "
               "content_us=-1 daemon_us=-1 pty_us=-1 echo_read_us=-1 echo_sent_us=-1 presented_us=7250")
    lines = [
        "Filtering the log data using ...",
        json.dumps({"eventType": "signpostEvent", "subsystem": SIGNPOST_SUBSYSTEM, "category": "input",
                    "signpostName": INPUT_LATENCY, "signpostType": "event", "eventMessage": message}),
        json.dumps({"eventType": "signpostEvent", "subsystem": SIGNPOST_SUBSYSTEM, "category": "input",
                    "signpostName": "input.frame", "signpostType": "event", "eventMessage": "target=view"}),
        json.dumps({"eventType": "lossEvent"}),
    ]
    events, lost = latency_events(lines)
    check("signpost count", len(events) == 1 and lost == 1, (events, lost))
    if events:
        event = events[0]
        check("signpost names", (event["kind"], event["target"], event["entrypoint"], event["presentation_source"])
              == ("keyPress", "agentPane", "person", "hostFeedback"), event)
        check("signpost stages", event["stages_ms"] == {"arrived_main": 0.15, "dispatch_start": 0.2, "dispatch_end": 0.9,
                                                        "main_commit": 1.5, "presented": 7.25}, event["stages_ms"])
        check("signpost frame", event["caused_frame_update"] and event["generated_ns"] == 123456789, event)

    if failures:
        print("hid_input self-test FAILED:\n  " + "\n  ".join(str(f) for f in failures))
        return 1
    print("hid_input self-test: ok")
    return 0


if __name__ == "__main__":
    if "--self-test" in sys.argv[1:]:
        sys.exit(self_test())
    print(__doc__)
