#!/usr/bin/env python3
"""Key input and key-to-frame summaries shared by the typing benches (sidebar-churn-typing.py,
automation-typing-bench.py; plans/cmux-next/chrome-parity/p06-scheduler.md, done checks 1 to 3).

Two ways to type a key (`--input`):

  real   a key-down and key-up posted at the HID event tap (CGEventPost(kCGHIDEventTap)). The key takes a
         person's path: the window server, the app's event queue, AppKit dispatch, and the scheduler's pending-input
         check (SessionInputPending) that makes budgeted work yield to it. The app must be frontmost (no
         CMUX_NEXT_NO_ACTIVATE) and the job must own the GUI session with the input (Accessibility) grant:
         `nx-remote --needs input` or a whole mini. The probe's `contents_ms` is the event's HID time to the frame
         that shows the echo. This is the number to quote.
  debug  `debug.key` over the control socket with the client's send time as the event's timestamp
         (CLOCK_UPTIME_RAW). It takes the socket's injected-input lane, not the event queue, so it does not measure
         what a person's key waits for: never quote it as key latency. For hosts without the input grant.

Chromium measures the same span as EventLatency (ui/latency/latency_info.h, cc/metrics/event_latency_tracker.h):
from the OS event's timestamp to the frame that shows its effect, reported as a distribution, never a mean alone.

`budget_summary` reads the `debug.main_budget` report: per-class `yielded_to_input` (MainFrameBudget+Report.swift),
and the fields p06-scheduler-002 and -008 add (`yielded_to_input_response`, `turn_ms`, `unattributed_share`). A field
the app does not report yet is None, never 0.

    python3 -m unittest scripts/cmux-next/tests/test_bench_input.py
"""
from __future__ import annotations

import ctypes
import ctypes.util
import statistics
import subprocess
import time

INPUT_MODES = ("debug", "real")
INPUT_HELP = ("real: key events posted at the HID event tap, through the app's event queue like a person's key (needs the "
              "GUI session and the input grant; the number to quote); debug: debug.key over the control socket (injected, "
              "never quoted as key latency)")

# ANSI virtual key codes (Carbon kVK_ANSI_*) for the typed keys.
KEYCODES = {"a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13,
            "e": 14, "r": 15, "y": 16, "t": 17, "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45,
            "m": 46, "return": 36}
_LETTERS = "abcdefghijklmnopqrstuvwxyz"
_HID_EVENT_TAP = 0  # kCGHIDEventTap


def typed_key(index):
    """The bench's key sequence: the alphabet, a return every 50 keys so the line never grows past the pane."""
    return "return" if index % 50 == 49 else _LETTERS[index % len(_LETTERS)]


class CoreGraphicsKeys:
    """Posts one real key press (down, then up) at the HID event tap."""

    def __init__(self):
        path = ctypes.util.find_library("CoreGraphics")
        if not path:
            raise OSError("--input real needs macOS CoreGraphics")
        cg = ctypes.cdll.LoadLibrary(path)
        cg.CGEventCreateKeyboardEvent.restype = ctypes.c_void_p
        cg.CGEventCreateKeyboardEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool]
        cg.CGEventPost.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        cg.CFRelease.argtypes = [ctypes.c_void_p]
        self.cg = cg

    def press(self, keycode):
        for down in (True, False):
            event = self.cg.CGEventCreateKeyboardEvent(None, keycode, down)
            self.cg.CGEventPost(_HID_EVENT_TAP, event)
            self.cg.CFRelease(event)


class KeySender:
    """Types keys the `mode` way. `rpc(method, params, timeout=...)` is the bench's socket call; `poster` is the real
    key poster (CoreGraphicsKeys, made on first use), `clock` the event clock in seconds (CLOCK_UPTIME_RAW, which the
    probe compares the debug key's timestamp with); tests inject both."""

    def __init__(self, mode, rpc, poster=None, run=subprocess.run, clock=None):
        if mode not in INPUT_MODES:
            raise ValueError(f"input mode {mode!r} is not one of {INPUT_MODES}")
        self.mode, self.rpc, self.poster, self.run = mode, rpc, poster, run
        self.clock = clock or (lambda: time.clock_gettime(time.CLOCK_UPTIME_RAW))

    @property
    def real(self):
        return self.mode == "real"

    def launch_env(self, env):
        """The bench's launch environment for this mode: a real key goes to the frontmost app's key window, so the app
        must activate (None removes the variable from BenchApp's defaults)."""
        env = dict(env)
        if self.real:
            env["CMUX_NEXT_NO_ACTIVATE"] = None
        return env

    def bring_front(self, pid):
        """Makes the app frontmost for real keys; injected keys need no focus."""
        if not self.real:
            return
        self.run(["osascript", "-e",
                  f'tell application "System Events" to set frontmost of (first process whose unix id is {pid}) to true'],
                 capture_output=True, timeout=30)

    def send(self, key):
        """Types one key; returns the socket reply for debug keys, None for real keys (the event queue answers
        nothing)."""
        if self.real:
            if self.poster is None:
                self.poster = CoreGraphicsKeys()
            self.poster.press(KEYCODES[key])
            return None
        return self.rpc("debug.key", {"key": key, "timestamp": self.clock()}, timeout=10)


def pct(values):
    """n, p50, p95, p99, max and mean of `values` (nearest rank), or None when empty."""
    if not values:
        return None
    s = sorted(values)
    pick = lambda p: s[min(len(s) - 1, int(round((len(s) - 1) * p)))]
    return {"n": len(s), "p50": round(pick(0.5), 2), "p95": round(pick(0.95), 2), "p99": round(pick(0.99), 2),
            "max": round(s[-1], 2), "mean": round(statistics.fmean(s), 2)}


def frame_samples(rows):
    """The probe rows' key-to-frame times (ms) of the keys whose echo reached a frame."""
    return [float(r["contents_ms"]) for r in rows if r.get("complete") == "1" and r.get("contents_ms")]


def _number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) else None


def _quantile(value, name):
    """`name` (p99, max) of a distribution field reported as {p99: ..} or {p99_ms: ..}; a bare number is the max."""
    if isinstance(value, dict):
        return _number(value.get(name, value.get(f"{name}_ms")))
    return _number(value) if name == "max" else None


def _class_counts(budget, key):
    """Per class `key` from `classes`, or None when no class reports it."""
    classes = budget.get("classes") if isinstance(budget.get("classes"), dict) else {}
    counts = {name: _number(row.get(key)) for name, row in classes.items() if isinstance(row, dict)}
    counts = {name: n for name, n in counts.items() if n is not None}
    return counts or None


def budget_summary(budget):
    """The scheduler numbers the done checks read from one phase's `debug.main_budget` report."""
    if not isinstance(budget, dict) or budget.get("error"):
        return {"error": (budget or {}).get("error") if isinstance(budget, dict) else "no debug.main_budget reply"}
    turn = budget.get("turn_ms")
    yielded = _class_counts(budget, "yielded_to_input")
    response = _class_counts(budget, "yielded_to_input_response")
    if response is None and _number(budget.get("yielded_to_input_response")) is not None:
        response = {"all": budget["yielded_to_input_response"]}
    return {"turn_p99_ms": _quantile(turn, "p99"), "turn_max_ms": _quantile(turn, "max"),
            "task_p99_ms": _quantile(budget.get("task_ms"), "p99"),
            "unattributed_share": _number(budget.get("unattributed_share")),
            "yielded_to_input": yielded, "yielded_to_input_total": sum(yielded.values()) if yielded else None,
            "yielded_to_input_response": response,
            "yielded_to_input_response_total": sum(response.values()) if response else None}


def _worst(rows, key):
    values = [row[key] for row in rows if row.get(key) is not None]
    return max(values) if values else None


def _total(rows, key):
    values = [row[key] for row in rows if row.get(key) is not None]
    return sum(values) if values else None


def side_summary(phases):
    """Key to frame over `phases` (their `key_to_frame_samples_ms` pooled across rounds) and the scheduler numbers
    of their `budget` (budget_summary): the worst turn p99, turn max and unattributed share, the summed yields."""
    frames = pct([v for p in phases for v in p.get("key_to_frame_samples_ms") or []])
    budgets = [p["budget"] for p in phases if isinstance(p.get("budget"), dict)]
    return {"key_to_frame_ms": {k: frames[k] for k in ("n", "p50", "p95", "p99", "max")} if frames else None,
            "turn_p99_ms": _worst(budgets, "turn_p99_ms"), "turn_max_ms": _worst(budgets, "turn_max_ms"),
            "unattributed_share": _worst(budgets, "unattributed_share"),
            "yielded_to_input": _total(budgets, "yielded_to_input_total"),
            "yielded_to_input_response": _total(budgets, "yielded_to_input_response_total")}


def mode_summary(mode, idle, storm):
    """One input mode's summary: its idle phases and its storm phases (churn or automation), each a phase entry with
    `key_to_frame_samples_ms` and `budget`, and the storm minus idle key-to-frame p99 (done check 2)."""
    idle_side, storm_side = side_summary(idle), side_summary(storm)
    idle_ms, storm_ms = idle_side["key_to_frame_ms"], storm_side["key_to_frame_ms"]
    return {"input": mode, "quotable": mode == "real", "idle": idle_side, "storm": storm_side,
            "storm_minus_idle_p99_ms": round(storm_ms["p99"] - idle_ms["p99"], 2) if idle_ms and storm_ms else None}
