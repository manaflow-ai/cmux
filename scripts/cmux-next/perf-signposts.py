#!/usr/bin/env python3
"""Read cmux's always-on signpost intervals and print p50/p95/max per name.

The same names exist in Debug and Release builds (Packages/macOS/CmuxNext/Sources/
CmuxNextSignposts/SignpostName.swift, plans/cmux-next/architecture-refactor-DESIGN.md
section 7), so this measures what users run. It streams the unified log
(`log stream --signpost --style ndjson`) for one process while a scenario runs, pairs each
interval's begin and end by signpost id, times them by `machTimestamp` (monotonic; the wall-clock
`timestamp` only when a line has none), and groups the durations by name and by the `id=` or
`kind=` field of the begin message.

What the action rows mean:
  action.perform           the handler's synchronous main-thread time
  action.commit            the synchronous perform plus the next Core Animation commit
                           (CommitBoundary). NOT the time to the frame that shows the action's
                           result: work the handler defers (daemon replies, Chromium
                           CreateBrowser, later SwiftUI updates) commits later. Use the action's
                           own end signal for input-to-result numbers and the 10 ms budget.
  action.commit.missed     commits the boundary missed (end message commit=missed): excluded
                           from action.commit, counted here
  action.*.nested_loop     runs whose handler opened a nested run loop that waited for the person
                           (a menu pop-up, a modal panel; end message loop=nested): they hold the
                           person's dwell time, so they are kept out of action.perform,
                           action.commit and input to commit and counted here; the action picked
                           inside that loop is a sample of its own
  action.input_to_commit   action.commit plus the begin's input_age_ms, for runs a person started
                           (input_age_ms >= 0: the key or click being dispatched, or for a run a
                           confirmation or the palette let through in a later turn, the press
                           that started it); socket, CLI, MCP and page runs record -1 and are
                           left out
  action.gate              a confirmation presenter or the palette opening to ask for an
                           argument: never a run of the action, so never in the action's
                           perform, commit or input_to_commit rows (the run it lets through has
                           its own)

What the scroll rows mean (detail = the end's target=: layout when the layout scrolled, content when the
event went on to the pane):
  key.scroll_frame          a scroll event's dispatch to the end of the turn's Core Animation commit
  key.scroll_frame.missed   commits the boundary missed: kept out of the rows above and below
  key.scroll_input_to_frame key.scroll_frame plus the begin's age_ms (the event's wait in the queue), for
                            events with an age: input to frame, the number Chrome reports for scrolls

What the presentation rows mean (events, not intervals; p03-rendering 004). They are estimates the app makes
without watching frames: no display link starts for them.
  action.presented_estimate            run start to the estimated present: the target timestamp of the first
                                       display-link tick after the commit, on the vsync grid of the newest tick a
                                       frame scheduler delivered (phase=running|recent|unknown says where the grid
                                       came from; unknown is the commit plus 1.5 refresh periods)
  action.input_to_presented_estimate   the same plus the event's input_age_ms, for runs a person started
  action.commit_to_presented_estimate  the commit to the estimate (one to two frames on a known grid)
  action.presented                     run start to a measured present (Ghostty presentedTime, task 080), where
                                       one exists
  motion.late_commits                  one sample per main Core Animation commit made during a Motion animation
                                       that ended after the vsync of the frame its turn began in: the ms past that
                                       vsync (count is the number of late commits; DC14 wants 0)
  action.presented_estimate.error      with --presented: |estimate - the first presented frame after the
                                       commit| per run, from a motion-hitches.py or recorder timeline; the
                                       summary prints its p95 in frames (DC14: <= 1 frame)

Every row has p50, p95, p99 and max.

Categories (SignpostCategory.swift): action, motion, key, switch, create, cef, launch, stall, and
burst (events: scripts/cmux-next/burst-bench.py reads those; this script folds only the events named
above, so --category burst prints no rows).

The stream is drained on a reader thread while the scenario runs (a full pipe would block
`log stream` and logd would drop events). Lost-message reports from `log stream` are counted;
any loss fails the run (exit 2) unless --allow-loss, because the percentiles would then come from
an unfair sample.

Run it on the fleet host that runs the app (never on Lawrence's Mac), and report the display's
refresh rate next to frame numbers.

Usage:
  perf-signposts.py --pid PID [--category action ...] [--seconds N | -- COMMAND ...] [--json]
  perf-signposts.py --from FILE.ndjson [--json]     summarize a saved stream
  perf-signposts.py --save FILE.ndjson ...           also keep the raw stream (with its timebase)
  perf-signposts.py --allow-loss ...                 report instead of failing on lost messages
  perf-signposts.py --presented TIMELINE.json ...    estimate error against measured presents: a JSON object
                                                     {"presented_s": [...], "refresh_hz": 120} (seconds on the
                                                     mach clock, the base of machTimestamp and CACurrentMediaTime)
  perf-signposts.py --self-test                      check the parser on a built-in sample

Without --seconds or a COMMAND it streams until Ctrl-C.
"""

from __future__ import annotations

import argparse
import bisect
import json
import re
import signal
import statistics
import subprocess
import sys
import threading
import time
from datetime import datetime

SUBSYSTEM = "com.cmuxterm.app.next"
TIMESTAMP = re.compile(r"^(\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d+)([+-]\d{4})$")
TIMEBASE_HEADER = re.compile(r"^#timebase (\d+)/(\d+)$")
LOSS_TEXT = re.compile(r"\b(lost|dropped)\b.*\bmessages?\b", re.IGNORECASE)
ATTACH_TIMEOUT_S = 15


def parse_time(text: str) -> float:
    match = TIMESTAMP.match(text)
    if not match:
        raise ValueError(f"unexpected timestamp {text!r}")
    return datetime.strptime(match.group(1) + match.group(2), "%Y-%m-%d %H:%M:%S.%f%z").timestamp()


def local_timebase() -> tuple[int, int] | None:
    """This Mac's mach_timebase_info (numer, denom), or None off macOS."""
    try:
        import ctypes
        import ctypes.util

        class Timebase(ctypes.Structure):
            _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]

        system = ctypes.CDLL(ctypes.util.find_library("System") or "/usr/lib/libSystem.B.dylib")
        info = Timebase()
        if system.mach_timebase_info(ctypes.byref(info)) != 0 or info.denom == 0:
            return None
        return info.numer, info.denom
    except (OSError, AttributeError):
        return None


def fields(message: str) -> dict[str, str]:
    return dict(part.split("=", 1) for part in message.split() if "=" in part)


def is_loss(line: str, event: dict | None) -> bool:
    if event is not None:
        return event.get("eventType") == "lossEvent"
    return bool(LOSS_TEXT.search(line))


# The point events this script folds into rows (the other events, such as burst's, belong to their own scripts).
EVENT_NAMES = {"action.presented_estimate", "action.presented", "motion.late_commits"}


def parse(lines, timebase: tuple[int, int] | None) -> dict:
    """{intervals: [{name, category, ms, at_s, fields, missed, nested_loop}], events: [{name, category, at_s,
    fields}], lost, unpaired}. `at_s` is the begin's (or the event's) time in seconds (machTimestamp with a
    timebase: the clock of NSEvent.timestamp and CACurrentMediaTime)."""
    numer, denom = timebase or (0, 0)
    open_intervals: dict[tuple, tuple[float, dict]] = {}
    done = []
    events = []
    lost = 0
    for raw in lines:
        line = raw.strip()
        header = TIMEBASE_HEADER.match(line)
        if header:
            numer, denom = int(header.group(1)), int(header.group(2))
            continue
        event = None
        if line.startswith("{"):
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                event = None
        if is_loss(line, event):
            lost += 1
            continue
        if event is None or event.get("eventType") != "signpostEvent" or event.get("subsystem") != SUBSYSTEM:
            continue
        key = (event.get("processID"), event.get("category"), event.get("signpostName"), event.get("signpostID"))
        kind = event.get("signpostType")
        mach = event.get("machTimestamp")
        if isinstance(mach, int) and denom:
            at = mach * numer / denom / 1e9
        else:
            at = parse_time(event["timestamp"])
        if kind == "event":
            if key[2] in EVENT_NAMES:
                events.append({"name": key[2], "category": key[1], "at_s": at,
                               "fields": fields(event.get("eventMessage", ""))})
        elif kind == "begin":
            open_intervals[key] = (at, fields(event.get("eventMessage", "")))
        elif kind == "end" and key in open_intervals:
            start, info = open_intervals.pop(key)
            end = fields(event.get("eventMessage", ""))
            done.append({"name": key[2], "category": key[1], "ms": (at - start) * 1000, "at_s": start, "fields": info,
                         "end_fields": end, "missed": end.get("commit") == "missed", "nested_loop": end.get("loop") == "nested"})
    return {"intervals": done, "events": events, "lost": lost, "unpaired": len(open_intervals)}


def percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round(fraction * (len(ordered) - 1))))
    return ordered[index]


def summarize(intervals: list[dict]) -> list[dict]:
    groups: dict[tuple[str, str], list[float]] = {}
    for interval in intervals:
        # key.scroll_frame names who took the event at its end (target=layout|content), not at its begin.
        detail = (interval["fields"].get("id") or interval["fields"].get("kind")
                  or interval.get("end_fields", {}).get("target") or "")
        suffix = ".nested_loop" if interval.get("nested_loop") else ".missed" if interval.get("missed") else ""
        name = interval["name"] + suffix
        groups.setdefault((name, detail), []).append(interval["ms"])
        groups.setdefault((name, "*"), []).append(interval["ms"])
        age = interval["fields"].get("input_age_ms")
        if name == "action.commit" and age and float(age) >= 0:
            groups.setdefault(("action.input_to_commit", detail), []).append(interval["ms"] + float(age))
        scroll_age = interval["fields"].get("age_ms")
        if name == "key.scroll_frame" and scroll_age and float(scroll_age) >= 0:
            groups.setdefault(("key.scroll_input_to_frame", detail), []).append(interval["ms"] + float(scroll_age))
            groups.setdefault(("key.scroll_input_to_frame", "*"), []).append(interval["ms"] + float(scroll_age))
    return rows_of(groups)


def rows_of(groups: dict[tuple[str, str], list[float]]) -> list[dict]:
    """One row per (name, detail): count and the p50/p95/p99/max distribution in ms."""
    rows = []
    for (name, detail), values in sorted(groups.items()):
        rows.append({
            "name": name, "detail": detail, "count": len(values),
            "p50_ms": round(statistics.median(values), 3),
            "p95_ms": round(percentile(values, 0.95), 3),
            "p99_ms": round(percentile(values, 0.99), 3),
            "max_ms": round(max(values), 3),
        })
    return rows


def number(event: dict, field: str) -> float | None:
    try:
        return float(event["fields"][field])
    except (KeyError, ValueError):
        return None


def summarize_events(events: list[dict]) -> list[dict]:
    """The presentation rows (module docstring): estimated and measured presents per action, and late commits."""
    groups: dict[tuple[str, str], list[float]] = {}

    def add(name: str, detail: str, value: float) -> None:
        groups.setdefault((name, detail), []).append(value)
        groups.setdefault((name, "*"), []).append(value)

    for event in events:
        if event["name"] == "motion.late_commits":
            late = number(event, "late_ms")
            if late is not None:
                groups.setdefault(("motion.late_commits", "*"), []).append(late)
            continue
        present = number(event, "present_ms")
        if present is None:
            continue
        detail = event["fields"].get("id", "")
        estimated = event["name"] == "action.presented_estimate"
        add(event["name"], detail, present)
        age = number(event, "input_age_ms")
        if age is not None and age >= 0:
            add("action.input_to_presented_estimate" if estimated else "action.input_to_presented", detail, present + age)
        commit = number(event, "commit_ms")
        if estimated and commit is not None:
            groups.setdefault(("action.commit_to_presented_estimate", "*"), []).append(present - commit)
    return rows_of(groups)


def estimate_phases(events: list[dict]) -> dict[str, int]:
    """How many estimates each vsync phase placed (running, recent, unknown)."""
    phases: dict[str, int] = {}
    for event in events:
        if event["name"] == "action.presented_estimate":
            phase = event["fields"].get("phase", "?")
            phases[phase] = phases.get(phase, 0) + 1
    return phases


def estimate_errors(events: list[dict], presented: list[float]) -> list[dict]:
    """Each estimate against the first measured present after its commit: [{id, error_ms}], the error signed
    (positive: the estimate is later than the present). The event is written at the commit's end, so its time is
    the commit's; an estimate with no present after it is left out."""
    shown = sorted(presented)
    errors = []
    for event in events:
        if event["name"] != "action.presented_estimate":
            continue
        present, commit = number(event, "present_ms"), number(event, "commit_ms")
        if present is None or commit is None:
            continue
        at = bisect.bisect_right(shown, event["at_s"])
        if at == len(shown):
            continue
        estimate = event["at_s"] + (present - commit) / 1000
        errors.append({"id": event["fields"].get("id", ""), "error_ms": (estimate - shown[at]) * 1000})
    return errors


def error_rows(errors: list[dict]) -> list[dict]:
    """``action.presented_estimate.error`` rows: the absolute error per action and overall."""
    groups: dict[tuple[str, str], list[float]] = {}
    for error in errors:
        groups.setdefault(("action.presented_estimate.error", error["id"]), []).append(abs(error["error_ms"]))
        groups.setdefault(("action.presented_estimate.error", "*"), []).append(abs(error["error_ms"]))
    return rows_of(groups)


def load_presented(path: str) -> tuple[list[float], float | None]:
    """A presented-frame timeline: {"presented_s": [seconds, ...], "refresh_hz": hz} (motion-hitches.py or a
    separate-process ScreenCaptureKit recorder, on the mach clock), or a bare list of seconds."""
    with open(path) as handle:
        data = json.load(handle)
    if isinstance(data, list):
        return [float(t) for t in data], None
    hz = data.get("refresh_hz")
    return [float(t) for t in data.get("presented_s", [])], float(hz) if hz else None


class Recording:
    """`log stream` of cmux's signposts for one process, drained on a reader thread (a full pipe would block
    `log stream` and logd would drop events). Use it around a scenario a script runs itself:

        recording = Recording(pid, ["key"])   # returns once the log tool is attached
        ...                                   # the scenario
        lines = recording.stop()              # with the "#timebase" header parse() reads
        rows = summarize(parse(lines, None)["intervals"])
    """

    def __init__(self, pid: int, categories: list[str] | None = None):
        predicate = f'subsystem == "{SUBSYSTEM}"'
        if categories:
            predicate += " AND category IN {" + ", ".join(f'"{c}"' for c in categories) + "}"
        command = ["/usr/bin/log", "stream", "--signpost", "--style", "ndjson", "--predicate", predicate,
                   "--process", str(pid)]
        self.timebase = local_timebase()
        self.lines: list[str] = []
        self._log = subprocess.Popen(command, stdout=subprocess.PIPE, text=True, bufsize=1)
        attached = threading.Event()

        def drain() -> None:
            # Reads for the whole run, so `log stream` never blocks on a full pipe.
            for line in self._log.stdout:
                self.lines.append(line.rstrip("\n"))
                attached.set()
            attached.set()

        self._reader = threading.Thread(target=drain, name="log-stream-drain", daemon=True)
        self._reader.start()
        # The log tool prints its filter line once it is attached; start the scenario after it.
        if not attached.wait(ATTACH_TIMEOUT_S):
            print(f"perf-signposts: log stream printed nothing in {ATTACH_TIMEOUT_S} s; running anyway", file=sys.stderr)

    def stop(self) -> list[str]:
        """Ends the stream; returns its lines, the local timebase first (machTimestamp to seconds)."""
        if self._log.poll() is None:
            self._log.send_signal(signal.SIGINT)
        try:
            self._log.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self._log.kill()
            self._log.wait()
        self._reader.join(timeout=10)
        header = [f"#timebase {self.timebase[0]}/{self.timebase[1]}"] if self.timebase else []
        return header + self.lines


def stream(args) -> list[str]:
    recording = Recording(args.pid, args.category)
    try:
        if args.command:
            subprocess.run(args.command, check=False)
        elif args.seconds:
            time.sleep(args.seconds)  # the measurement window itself, not a wait for a condition
        else:
            signal.pause()
    except KeyboardInterrupt:
        pass
    finally:
        lines = recording.stop()
    return lines


SAMPLE = """#timebase 1/1
Filtering the log data using "subsystem == ..."
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.commit","signpostID":7,"signpostType":"begin","processID":1,"machTimestamp":1000000000,"timestamp":"2026-10-23 04:55:41.243635-0700","eventMessage":"id=tab.new origin=user input_age_ms=1.50"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.perform","signpostID":8,"signpostType":"begin","processID":1,"machTimestamp":1000000000,"timestamp":"2026-10-23 04:55:41.243700-0700","eventMessage":"id=tab.new origin=user input_age_ms=1.50"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.perform","signpostID":8,"signpostType":"end","processID":1,"machTimestamp":1002000000,"timestamp":"2026-10-23 04:55:41.299999-0700","eventMessage":""}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.commit","signpostID":7,"signpostType":"end","processID":1,"machTimestamp":1006000000,"timestamp":"2026-10-23 04:55:41.249635-0700","eventMessage":""}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.commit","signpostID":9,"signpostType":"begin","processID":1,"machTimestamp":2000000000,"timestamp":"2026-10-23 04:55:42.000000-0700","eventMessage":"id=workspace.next origin=cli input_age_ms=-1.00"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.commit","signpostID":9,"signpostType":"end","processID":1,"machTimestamp":2003000000,"timestamp":"2026-10-23 04:55:42.003000-0700","eventMessage":""}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.commit","signpostID":10,"signpostType":"begin","processID":1,"machTimestamp":3000000000,"timestamp":"2026-10-23 04:55:43.000000-0700","eventMessage":"id=tab.new origin=user input_age_ms=0.50"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.commit","signpostID":10,"signpostType":"end","processID":1,"machTimestamp":3900000000,"timestamp":"2026-10-23 04:55:43.900000-0700","eventMessage":"commit=missed"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.commit","signpostID":11,"signpostType":"begin","processID":1,"machTimestamp":4000000000,"timestamp":"2026-10-23 04:55:44.000000-0700","eventMessage":"id=tab.close origin=user input_age_ms=1.00"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.gate","signpostID":12,"signpostType":"begin","processID":1,"machTimestamp":5000000000,"timestamp":"2026-10-23 04:55:45.000000-0700","eventMessage":"id=tabGroup.close origin=user input_age_ms=0.20"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.gate","signpostID":12,"signpostType":"end","processID":1,"machTimestamp":5000500000,"timestamp":"2026-10-23 04:55:45.000500-0700","eventMessage":""}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.perform","signpostID":13,"signpostType":"begin","processID":1,"machTimestamp":6000000000,"timestamp":"2026-10-23 04:55:46.000000-0700","eventMessage":"id=tab.new origin=user input_age_ms=0.20"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.perform","signpostID":13,"signpostType":"end","processID":1,"machTimestamp":8000000000,"timestamp":"2026-10-23 04:55:48.000000-0700","eventMessage":"loop=nested"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"key","signpostName":"key.scroll_frame","signpostID":20,"signpostType":"begin","processID":1,"machTimestamp":10000000000,"timestamp":"2026-10-23 04:55:50.000000-0700","eventMessage":"phase=changed age_ms=2.00"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"key","signpostName":"key.scroll_frame","signpostID":20,"signpostType":"end","processID":1,"machTimestamp":10004000000,"timestamp":"2026-10-23 04:55:50.004000-0700","eventMessage":"target=layout"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"key","signpostName":"key.scroll_frame","signpostID":21,"signpostType":"begin","processID":1,"machTimestamp":10100000000,"timestamp":"2026-10-23 04:55:50.100000-0700","eventMessage":"phase=changed age_ms=1.00"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"key","signpostName":"key.scroll_frame","signpostID":21,"signpostType":"end","processID":1,"machTimestamp":10101000000,"timestamp":"2026-10-23 04:55:50.101000-0700","eventMessage":"target=content"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"key","signpostName":"key.scroll_frame","signpostID":22,"signpostType":"begin","processID":1,"machTimestamp":10200000000,"timestamp":"2026-10-23 04:55:50.200000-0700","eventMessage":"phase=wheel age_ms=-1.00"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"key","signpostName":"key.scroll_frame","signpostID":22,"signpostType":"end","processID":1,"machTimestamp":10203000000,"timestamp":"2026-10-23 04:55:50.203000-0700","eventMessage":"target=layout"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"key","signpostName":"key.scroll_frame","signpostID":23,"signpostType":"begin","processID":1,"machTimestamp":10300000000,"timestamp":"2026-10-23 04:55:50.300000-0700","eventMessage":"phase=began age_ms=0.50"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"key","signpostName":"key.scroll_frame","signpostID":23,"signpostType":"end","processID":1,"machTimestamp":10400000000,"timestamp":"2026-10-23 04:55:50.400000-0700","eventMessage":"commit=missed target=layout"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.presented_estimate","signpostID":30,"signpostType":"event","processID":1,"machTimestamp":1006000000,"timestamp":"2026-10-23 04:55:41.249700-0700","eventMessage":"id=tab.new present_ms=14.000 commit_ms=6.000 input_age_ms=1.50 phase=running"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"action","signpostName":"action.presented_estimate","signpostID":31,"signpostType":"event","processID":1,"machTimestamp":2003000000,"timestamp":"2026-10-23 04:55:42.003100-0700","eventMessage":"id=workspace.next present_ms=13.000 commit_ms=3.000 input_age_ms=-1.00 phase=recent"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"motion","signpostName":"motion.late_commits","signpostID":32,"signpostType":"event","processID":1,"machTimestamp":2500000000,"timestamp":"2026-10-23 04:55:42.500000-0700","eventMessage":"late_ms=1.250 turn_ms=9.500"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"motion","signpostName":"motion.late_commits","signpostID":33,"signpostType":"event","processID":1,"machTimestamp":2600000000,"timestamp":"2026-10-23 04:55:42.600000-0700","eventMessage":"late_ms=3.750 turn_ms=12.000"}
{"eventType":"signpostEvent","subsystem":"com.cmuxterm.app.next","category":"burst","signpostName":"burst.refused","signpostID":34,"signpostType":"event","processID":1,"machTimestamp":2700000000,"timestamp":"2026-10-23 04:55:42.700000-0700","eventMessage":"id=tab.close"}
{"eventType":"lossEvent","eventMessage":"lost 3 unreliable messages","timestamp":"2026-10-23 04:55:44.100000-0700"}
{"eventType":"signpostEvent","subsystem":"other","category":"action","signpostName":"action.commit","signpostID":7,"signpostType":"end","processID":1,"machTimestamp":1009000000,"timestamp":"2026-10-23 04:55:41.259635-0700","eventMessage":""}
"""


def missing_input_age(intervals: list[dict]) -> bool:
    """User action.commit runs exist and none carries an input age: the App's input wiring broke, or the
    runs came from outside a key or click dispatch (input to commit would be empty and look healthy)."""
    user = [i for i in intervals if i["name"] == "action.commit" and i["fields"].get("origin") == "user"]
    return bool(user) and all(float(i["fields"].get("input_age_ms", "-1")) < 0 for i in user)


def self_test() -> int:
    parsed = parse(SAMPLE.splitlines(), None)
    rows = {(r["name"], r["detail"]): r for r in summarize(parsed["intervals"])}
    # Durations come from machTimestamp (the perform end's wall clock is 56 ms after its begin).
    assert abs(rows[("action.perform", "tab.new")]["p50_ms"] - 2.0) < 1e-6, rows
    assert abs(rows[("action.commit", "tab.new")]["p50_ms"] - 6.0) < 1e-6, rows
    assert abs(rows[("action.input_to_commit", "tab.new")]["p50_ms"] - 7.5) < 1e-6, rows
    # A CLI run (input_age_ms=-1) counts in action.commit, never in input to commit.
    assert rows[("action.commit", "workspace.next")]["count"] == 1, rows
    assert ("action.input_to_commit", "workspace.next") not in rows, rows
    # A missed commit is reported apart and kept out of action.commit.
    assert rows[("action.commit.missed", "tab.new")]["count"] == 1, rows
    assert rows[("action.commit", "*")]["count"] == 2, rows
    # A gate is its own row, never one of the action's run rows.
    assert abs(rows[("action.gate", "tabGroup.close")]["p50_ms"] - 0.5) < 1e-6, rows
    assert ("action.commit", "tabGroup.close") not in rows and ("action.input_to_commit", "tabGroup.close") not in rows, rows
    # A run that spanned a nested run loop (2 s of menu dwell) is reported apart, out of action.perform.
    assert rows[("action.perform.nested_loop", "tab.new")]["count"] == 1, rows
    assert rows[("action.perform", "tab.new")]["count"] == 1, rows
    assert missing_input_age([{"name": "action.commit", "fields": {"origin": "user", "input_age_ms": "-1"}}])
    assert not missing_input_age(parsed["intervals"])
    assert parsed["lost"] == 1 and parsed["unpaired"] == 1, parsed
    assert parse(["Dropped 12 messages"], None)["lost"] == 1
    # key.scroll_frame groups by who took the event (the end's target=), and input to frame adds the begin's
    # age_ms for events with an age; a missed commit stays out of both, as for action.commit.
    assert rows[("key.scroll_frame", "layout")]["count"] == 2, rows
    assert rows[("key.scroll_frame", "content")]["count"] == 1, rows
    assert rows[("key.scroll_frame.missed", "layout")]["count"] == 1, rows
    assert abs(rows[("key.scroll_input_to_frame", "layout")]["p50_ms"] - 6.0) < 1e-6, rows
    assert rows[("key.scroll_input_to_frame", "layout")]["count"] == 1, rows
    assert abs(rows[("key.scroll_input_to_frame", "content")]["p50_ms"] - 2.0) < 1e-6, rows
    assert all("p99_ms" in row for row in rows.values()), rows
    # Presentation events: the estimate per action, input to estimate only for a person's run, the commit-to-estimate
    # gap, the late commits' lateness, and no row for an event this script does not fold (burst).
    events = parsed["events"]
    assert [e["name"] for e in events].count("action.presented_estimate") == 2, events
    assert all(e["name"] in EVENT_NAMES for e in events), events
    presented = {(r["name"], r["detail"]): r for r in summarize_events(events)}
    assert abs(presented[("action.presented_estimate", "tab.new")]["p50_ms"] - 14.0) < 1e-6, presented
    assert presented[("action.presented_estimate", "*")]["count"] == 2, presented
    assert abs(presented[("action.input_to_presented_estimate", "tab.new")]["p50_ms"] - 15.5) < 1e-6, presented
    assert ("action.input_to_presented_estimate", "workspace.next") not in presented, presented
    assert abs(presented[("action.commit_to_presented_estimate", "*")]["max_ms"] - 10.0) < 1e-6, presented
    assert presented[("motion.late_commits", "*")]["count"] == 2, presented
    assert abs(presented[("motion.late_commits", "*")]["max_ms"] - 3.75) < 1e-6, presented
    assert all("p99_ms" in row for row in presented.values()), presented
    assert not any(name.startswith("burst") for name, _ in presented), presented
    assert estimate_phases(events) == {"running": 1, "recent": 1}, estimate_phases(events)
    # Error against a measured timeline: tab.new commits at 1.006 s and is estimated at 1.014 s; the first frame
    # shown after the commit is at 1.0125 s (+1.5 ms). workspace.next: commit 2.003 s, estimate 2.013 s, shown
    # 2.0105 s (+2.5 ms). A frame before the commit (1.005 s) is never its present.
    errors = estimate_errors(events, [1.005, 1.0125, 2.0105, 2.0300])
    assert [round(e["error_ms"], 3) for e in errors] == [1.5, 2.5], errors
    error = {(r["name"], r["detail"]): r for r in error_rows(errors)}
    assert abs(error[("action.presented_estimate.error", "*")]["max_ms"] - 2.5) < 1e-6, error
    assert estimate_errors(events, [0.5]) == [], "an estimate with no present after its commit is left out"
    print("self-test ok")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pid", type=int)
    parser.add_argument("--from", dest="source")
    parser.add_argument("--save")
    parser.add_argument("--category", action="append")
    parser.add_argument("--seconds", type=float)
    parser.add_argument("--json", action="store_true")
    parser.add_argument("--allow-loss", action="store_true")
    parser.add_argument("--require-input-age", action="store_true",
                        help="exit 3 when user action.commit runs exist and none has input_age_ms >= 0")
    parser.add_argument("--presented", help="presented-frame timeline JSON: estimate error rows (module docstring)")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if args.self_test:
        return self_test()
    timebase = local_timebase()
    if args.source:
        with open(args.source) as handle:
            lines = handle.read().splitlines()
    elif args.pid:
        lines = stream(args)  # the timebase header first (Recording.stop)
    else:
        parser.error("--pid or --from is required")
    if args.save:
        with open(args.save, "w") as handle:
            handle.write("\n".join(lines) + "\n")
    parsed = parse(lines, timebase)
    rows = summarize(parsed["intervals"]) + summarize_events(parsed["events"])
    late_commits = sum(1 for e in parsed["events"] if e["name"] == "motion.late_commits")
    phases = estimate_phases(parsed["events"])
    error_p95_frames = None
    if args.presented:
        shown, hz = load_presented(args.presented)
        error = error_rows(estimate_errors(parsed["events"], shown))
        rows += error
        overall = next((r for r in error if r["detail"] == "*"), None)
        if overall and hz:
            error_p95_frames = round(overall["p95_ms"] / (1000 / hz), 3)
    status = 2 if parsed["lost"] and not args.allow_loss else 0
    if args.json:
        print(json.dumps({"rows": rows, "lost": parsed["lost"], "unpaired": parsed["unpaired"],
                          "late_commits": late_commits, "estimate_phases": phases,
                          "estimate_error_p95_frames": error_p95_frames}))
    else:
        print(f"lost-message reports: {parsed['lost']}  unpaired begins: {parsed['unpaired']}")
        print(f"motion.late_commits: {late_commits}  estimate phases: {phases or 'none'}")
        if error_p95_frames is not None:
            print(f"action.presented_estimate error p95: {error_p95_frames} frames (DC14: <= 1)")
        print(f"{'name':36} {'detail':36} {'n':>5} {'p50':>9} {'p95':>9} {'p99':>9} {'max':>9}")
        for row in rows:
            print(f"{row['name']:36} {row['detail'][:36]:36} {row['count']:5} {row['p50_ms']:9.3f} {row['p95_ms']:9.3f} "
                  f"{row['p99_ms']:9.3f} {row['max_ms']:9.3f}")
    if missing_input_age(parsed["intervals"]):
        print("perf-signposts: WARNING: user action runs carry no input age (input_age_ms -1 on every one): "
              "input to commit is empty; the App's dispatchingInputEvent wiring or the scenario is wrong", file=sys.stderr)
        if args.require_input_age:
            status = status or 3
    if status == 2:
        print(f"perf-signposts: log stream lost messages {parsed['lost']} time(s); the sample is not complete "
              "(rerun, or pass --allow-loss to keep it)", file=sys.stderr)
    return status


if __name__ == "__main__":
    sys.exit(main())
