#!/usr/bin/env python3
"""The typing benches' input mode and key-to-frame summaries (sidebar-churn-typing.py, automation-typing-bench.py;
plans/cmux-next/chrome-parity/p06-scheduler.md, done checks 1 to 3).

Two ways to type a key (`--input`):

  real   a key press at the HID event tap through hid_input.HidPoster, the input benches' one real-input helper. The
         key takes a person's path: the window server, the app's event queue, AppKit dispatch, and the scheduler's
         pending-input check (SessionInputPending) that makes budgeted work yield to it. The app must be frontmost (no
         CMUX_NEXT_NO_ACTIVATE) and the job must own the GUI session with the input (Accessibility) grant:
         `nx-remote --needs input` or a whole mini. The probe's `contents_ms` is the event's HID time to the frame
         that shows the echo. This is the number to quote.
  debug  `debug.key` over the control socket with the client's send time as the event's timestamp
         (CLOCK_UPTIME_RAW). It takes the socket's injected-input lane, not the event queue, so it does not measure
         what a person's key waits for: never quote it as key latency. For hosts without the input grant.

Chromium measures the same span as EventLatency (ui/latency/latency_info.h, cc/metrics/event_latency_tracker.h):
from the OS event's timestamp to the frame that shows its effect, reported as a distribution, never a mean alone.

Percentiles are typing_report.distribution (scripts/perf-lab/perf_stats.py), the one definition the lab judges with.

`budget_summary` reads the `debug.main_budget` report: per-class `yielded_to_input` (MainFrameBudget+Report.swift),
and the fields p06-scheduler-002 and -008 add (`yielded_to_input_response`, `turn_ms`, `unattributed_share`). A field
the app does not report yet is None, never 0.

    python3 -m unittest scripts/cmux-next/tests/test_bench_input.py
"""
from __future__ import annotations

import bench_launch
import hid_input
import typing_report

INPUT_MODES = ("debug", "real")
INPUT_HELP = ("real: key events posted at the HID event tap, through the app's event queue like a person's key (needs the "
              "GUI session and the input grant; the number to quote); debug: debug.key over the control socket (injected, "
              "never quoted as key latency)")


def typed_key(index):
    """The bench's key sequence: the alphabet, a return every 50 keys so the line never grows past the pane."""
    return "return" if index % 50 == 49 else hid_input.LETTERS[index % len(hid_input.LETTERS)]


class KeySender:
    """Types keys the `mode` way. `debug_key(key, timestamp)` is the bench's `debug.key` socket call (the bench names
    the method itself, so its story's `needs` check sees it). `poster` is the real key poster (hid_input.HidPoster,
    made on first use), `front(pid)` makes the app frontmost (hid_input.bring_front) and `clock` is the event clock in
    seconds (hid_input.uptime_raw, which the probe compares the debug key's timestamp with); tests inject them."""

    def __init__(self, mode, debug_key, poster=None, front=hid_input.bring_front, clock=hid_input.uptime_raw):
        if mode not in INPUT_MODES:
            raise ValueError(f"input mode {mode!r} is not one of {INPUT_MODES}")
        self.mode, self.debug_key, self.poster, self.front, self.clock = mode, debug_key, poster, front, clock

    @property
    def real(self):
        return self.mode == "real"

    def launch_env(self, env):
        """The bench's launch environment for this mode: a real key goes to the frontmost app's key window, so the app
        must activate (None removes the variable from BenchApp's defaults). Activation stays an isolated launch
        (bench_launch.ISOLATED_LAUNCH_KEY, paired the same way as bench_launch.shipping_env): the fixed window frame, no
        shim pointer, global hot keys, login item or browser import offer."""
        env = dict(env)
        if self.real:
            env["CMUX_NEXT_NO_ACTIVATE"] = None
            env[bench_launch.ISOLATED_LAUNCH_KEY] = "1"
        return env

    def bring_front(self, pid):
        """Makes the app frontmost for real keys; injected keys need no focus."""
        if self.real:
            self.front(pid)

    def send(self, key):
        """Types one key; returns the socket reply for debug keys, None for real keys (the event queue answers
        nothing)."""
        if self.real:
            if self.poster is None:
                self.poster = hid_input.HidPoster()
            return self.poster.key(key)
        return self.debug_key(key, self.clock())


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
    frames = typing_report.distribution([v for p in phases for v in p.get("key_to_frame_samples_ms") or []])
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
