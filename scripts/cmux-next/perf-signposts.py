#!/usr/bin/env python3
"""Read cmux's always-on signpost intervals and print p50/p95/p99/max per name.

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

Percentiles come from scripts/perf-lab/perf_stats.py (summary: linear interpolation, the lab's one
definition). With --app and --out, each signpost name's samples (its `*` row: every detail) are also written
as one cmux-perf-result/v1 file through BenchApp.record (story --story, metric = the name, unit ms); the
`.missed` and `.nested_loop` rows count runs kept out of a series, so they are not results.

Categories (SignpostCategory.swift): action, motion, key, switch, create, cef, launch, stall, and
burst (events, not intervals: scripts/cmux-next/burst-bench.py reads those; this script pairs
intervals only, so --category burst prints no rows).

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
  perf-signposts.py --pid PID --app APP --out DIR [--story NAME] [--session S] [--engine E] ...
                                                     also write result-v1 per signpost name (APP: the
                                                     running tagged bundle PID runs; a live stream only,
                                                     never --from)
  perf-signposts.py --self-test                      check the parser on a built-in sample

Without --seconds or a COMMAND it streams until Ctrl-C.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import socket
import subprocess
import sys
import threading
import time
from datetime import datetime

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)  # bench_launch (PERF_LAB, load_by_path, BenchApp) under `python3 -I` too
import bench_launch  # noqa: E402
from bench_launch import PERF_LAB, load_by_path  # noqa: E402

perf_stats = load_by_path("perf_stats", os.path.join(PERF_LAB, "perf_stats.py"))

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


def parse(lines, timebase: tuple[int, int] | None) -> dict:
    """{intervals: [{name, category, ms, at_s, fields, missed, nested_loop}], lost, unpaired}. `at_s` is the
    begin's time in seconds (machTimestamp with a timebase: the clock of NSEvent.timestamp)."""
    numer, denom = timebase or (0, 0)
    open_intervals: dict[tuple, tuple[float, dict]] = {}
    done = []
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
        if kind == "begin":
            open_intervals[key] = (at, fields(event.get("eventMessage", "")))
        elif kind == "end" and key in open_intervals:
            start, info = open_intervals.pop(key)
            end = fields(event.get("eventMessage", ""))
            done.append({"name": key[2], "category": key[1], "ms": (at - start) * 1000, "at_s": start, "fields": info,
                         "end_fields": end, "missed": end.get("commit") == "missed", "nested_loop": end.get("loop") == "nested"})
    return {"intervals": done, "lost": lost, "unpaired": len(open_intervals)}


# Row suffixes of runs kept out of a name's series: counted in the report, never a result.
EXCLUDED_SUFFIXES = (".missed", ".nested_loop")


def groups_of(intervals: list[dict]) -> dict[tuple[str, str], list[float]]:
    """{(name, detail): durations in ms}; the detail `*` holds every detail of the name."""
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
            groups.setdefault(("action.input_to_commit", "*"), []).append(interval["ms"] + float(age))
        scroll_age = interval["fields"].get("age_ms")
        if name == "key.scroll_frame" and scroll_age and float(scroll_age) >= 0:
            groups.setdefault(("key.scroll_input_to_frame", detail), []).append(interval["ms"] + float(scroll_age))
            groups.setdefault(("key.scroll_input_to_frame", "*"), []).append(interval["ms"] + float(scroll_age))
    return groups


def summarize(intervals: list[dict]) -> list[dict]:
    """One row per (name, detail): the count and p50/p95/p99/max ms (perf_stats.summary)."""
    rows = []
    for (name, detail), values in sorted(groups_of(intervals).items()):
        stats = perf_stats.summary(values)
        rows.append({
            "name": name, "detail": detail, "count": stats["n"],
            "p50_ms": round(stats["p50"], 3),
            "p95_ms": round(stats["p95"], 3),
            "p99_ms": round(stats["p99"], 3),
            "max_ms": round(stats["max"], 3),
        })
    return rows


def series(intervals: list[dict]) -> dict[str, list[float]]:
    """{signpost name: every duration of it in ms} (its `*` row), without the excluded-run rows."""
    return {name: values for (name, detail), values in sorted(groups_of(intervals).items())
            if detail == "*" and not name.endswith(EXCLUDED_SUFFIXES)}


def record(app, intervals: list[dict], story: str, engine: str = "none") -> dict[str, str]:
    """Writes one result-v1 per signpost name through `app.record` (a BenchApp holding its launch's features
    snapshot); returns {name: path or "not recorded: <reason>"}. A name it cannot record is reported, not raised."""
    perf_result = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))
    written = {}
    for name, samples in series(intervals).items():
        try:
            written[name] = str(app.record(story, name, "ms", samples, better="lower", engine=engine))
        except (bench_launch.RecordError, perf_result.ResultError) as error:
            written[name] = f"not recorded: {error}"
    return written


def bench_app(path: str, out: str, session: str, pid: int):
    """The running tagged app at `path` as a BenchApp that only records (no launch, no teardown), attached to the
    socket that answers its features.list now (BenchApp.attach). Raises RecordError when `pid`, the process the
    stream read, is not a process of that bundle: its build and features would label another process's samples."""
    app = bench_launch.BenchApp(path, out=out, teardown=False, perf_session=session)
    if pid not in app.running_pids():
        raise bench_launch.RecordError(f"pid {pid} is not a process of {app.app}")
    return app.attach()


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
    check_percentiles()
    check_results(parsed["intervals"])
    check_cli()
    print("self-test ok")
    return 0


def check_percentiles() -> None:
    """Rows carry p99 and use perf_stats' linear interpolation (the old private percentile rounded to the
    nearest rank: p95 of 1..20 was 19, now 19.05)."""
    rows = summarize([{"name": "action.commit", "category": "action", "ms": float(v), "at_s": 0.0,
                       "fields": {"id": "tab.new"}} for v in range(1, 21)])
    row = next(r for r in rows if r["detail"] == "tab.new")
    assert (row["count"], row["p50_ms"], row["p95_ms"], row["p99_ms"], row["max_ms"]) == (20, 10.5, 19.05, 19.81, 20.0), row
    assert all("p99_ms" in r for r in rows), rows


class FakeRecorder:
    """BenchApp.record's shape: builds and writes a real result-v1 (perf_result) with a fixed build and host."""

    def __init__(self, out: str):
        self.out = out
        self.writer = load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py"))
        self.run = self.writer.Run(id="0" * 32, started_at="2026-10-26T00:00:00.000000Z")

    def record(self, story, metric, unit, samples, better, engine, target_ref=None):
        w = self.writer
        host = w.Host(fingerprint="a" * 64, host_class="m6-16gb-120hz", chip="Apple M6", macos="26.1",
                      macos_build="25B78", display_hz=120.0)
        result = w.Result(story=story, metric=metric, unit=unit, better=better, samples=list(samples),
                          build=w.Build(sha="b" * 40, config="bench", measure_version=1), host=host,
                          engine=engine, session="light", run=self.run, target_ref=target_ref)
        return w.write_ndjson(self.out, [result])


def check_results(intervals: list[dict]) -> None:
    """record() writes one valid result-v1 per signpost name (the `*` samples, missed and nested-loop runs out)
    and reports a name it cannot record instead of raising."""
    import tempfile
    names = series(intervals)
    assert set(names) == {"action.commit", "action.gate", "action.input_to_commit", "action.perform",
                          "key.scroll_frame", "key.scroll_input_to_frame"}, names
    assert len(names["action.commit"]) == 2 and len(names["action.perform"]) == 1, names
    with tempfile.TemporaryDirectory() as out:
        written = record(FakeRecorder(out), intervals, "signposts")
        assert set(written) == set(names) and not any(v.startswith("not recorded") for v in written.values()), written
        results = {r.metric: r for r in load_by_path("perf_result", os.path.join(PERF_LAB, "perf_result.py")).read_dir(out)}
        assert set(results) == set(names), results
        assert sorted(results["action.commit"].samples) == sorted(names["action.commit"]), results["action.commit"]
        assert results["action.commit"].unit == "ms" and results["action.commit"].better == "lower"

    class Refuses:
        def record(self, *args, **kwargs):
            raise bench_launch.RecordError("no features.list snapshot")

    refused = record(Refuses(), intervals, "signposts")
    assert all(v == "not recorded: no features.list snapshot" for v in refused.values()), refused


def check_cli() -> None:
    """The command line's recording path: --app pairs with --out and a live --pid stream only; run() puts one
    result-v1 path per name in the JSON report and the text report; a stream that lost messages, or a pid that is
    not a process of --app, writes nothing; bench_app attaches to whichever socket candidate answers."""
    import contextlib
    import io
    import tempfile
    for argv in (["--app", "cmux DEV x.app", "--pid", "1"], ["--out", "/tmp/x", "--pid", "1"],
                 ["--app", "cmux DEV x.app", "--out", "/tmp/x", "--from", "saved.ndjson"], ["--json"]):
        with contextlib.redirect_stderr(io.StringIO()):
            try:
                parse_args(argv)
            except SystemExit as error:
                assert error.code == 2, (argv, error.code)
            else:
                raise AssertionError(f"parse_args accepted {argv}")
    lossless = [line for line in SAMPLE.splitlines() if "lossEvent" not in line]
    assert parse(lossless, None)["lost"] == 0
    names = set(series(parse(lossless, None)["intervals"]))
    with tempfile.TemporaryDirectory() as out:
        args = parse_args(["--app", "cmux DEV x.app", "--out", out, "--pid", "1", "--json", "--allow-loss"])
        made = []

        def factory(given):
            assert (given.app, given.out, given.pid) == ("cmux DEV x.app", out, 1), given
            made.append(FakeRecorder(out))
            return made[-1]

        printed = io.StringIO()
        with contextlib.redirect_stderr(io.StringIO()):
            assert run(args, lossless, None, factory, printed) == 0
        results = json.loads(printed.getvalue())["results"]
        assert set(results) == names and all(os.path.isfile(path) for path in results.values()), results

        printed = io.StringIO()
        with contextlib.redirect_stderr(io.StringIO()):
            run(parse_args(["--app", "cmux DEV x.app", "--out", out, "--pid", "1"]), lossless, None, factory, printed)
        text = printed.getvalue().splitlines()
        assert all(any(line.startswith(f"perf-signposts: result-v1 {name}: {out}") for line in text) for name in names), text

    with tempfile.TemporaryDirectory() as out:
        def never(_):
            raise AssertionError("a lost stream must not reach the app")

        printed = io.StringIO()
        with contextlib.redirect_stderr(io.StringIO()):
            status = run(parse_args(["--app", "cmux DEV x.app", "--out", out, "--pid", "1", "--json", "--allow-loss"]),
                         SAMPLE.splitlines(), None, never, printed)
        results = json.loads(printed.getvalue())["results"]
        assert status == 0 and results and all(v == "not recorded: log stream lost messages 1 time(s)"
                                               for v in results.values()), results
        assert not os.listdir(out), os.listdir(out)
    check_bench_app()


def check_bench_app() -> None:
    """bench_app refuses a pid that is not a process of the bundle, and attach() finds a socket that answers on a
    later candidate (/tmp here, not the state folder)."""
    import tempfile
    tag = f"perf-signposts-selftest-{os.getpid()}"
    with tempfile.TemporaryDirectory() as root, tempfile.TemporaryDirectory() as out:
        bundle = os.path.join(root, f"cmux DEV {tag}.app")
        os.makedirs(bundle)
        try:
            bench_app(bundle, out, "light", os.getpid())
        except bench_launch.RecordError as error:
            assert str(error) == f"pid {os.getpid()} is not a process of {os.path.realpath(bundle)}", error
        else:
            raise AssertionError("bench_app accepted a pid outside the bundle")

        path = f"/tmp/cmux-debug-{tag}.sock"
        assert path in bench_launch.socket_candidates(tag)[1:], bench_launch.socket_candidates(tag)
        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(path)
        try:
            server.listen(1)

            def answer() -> None:
                conn, _ = server.accept()
                with conn:
                    conn.makefile().readline()
                    reply = {"ok": True, "result": {"features": [{"name": "a", "state": "on", "source": "default"}],
                                                    "features_hash": "h", "safe_mode": False}}
                    conn.sendall((json.dumps(reply) + "\n").encode())

            threading.Thread(target=answer, daemon=True).start()
            app = bench_launch.BenchApp(bundle, out=out, teardown=False).attach()
            assert app.socket == path, app.socket
            assert app.features == ({"a": {"state": "on", "source": "default"}}, "h", False), app.features
        finally:
            server.close()
            os.unlink(path)


def parse_args(argv: list[str] | None = None):
    """The command line, checked (parser.error, exit 2, on a bad combination)."""
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
    parser.add_argument("--app", help="the running tagged bundle the stream reads: with --out, write result-v1")
    parser.add_argument("--out", help="the folder result-v1 files go to (with --app)")
    parser.add_argument("--story", default="signposts", help="result-v1 story (default signposts)")
    parser.add_argument("--session", default="light", help="result-v1 session: light, stress or corpus:<id>")
    parser.add_argument("--engine", default="none", choices=["chromium", "webkit", "none"],
                        help="result-v1 engine (default none)")
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args(argv)
    if args.command and args.command[0] == "--":
        args.command = args.command[1:]
    if args.self_test:
        return args
    if bool(args.app) != bool(args.out):
        parser.error("--app and --out go together")
    if args.app and args.source:
        # A saved stream carries no build or features: --app would label it with the bundle and process of now.
        parser.error("--app records only a live stream (--pid), never a saved one (--from)")
    if not args.source and not args.pid:
        parser.error("--pid or --from is required")
    return args


def live_app(args):
    """The BenchApp a live stream's results go through: the bundle --app names, checked to run --pid."""
    return bench_app(args.app, args.out, args.session, args.pid)


def results_of(args, parsed: dict, app_factory) -> dict[str, str] | None:
    """{name: result-v1 path or "not recorded: <reason>"} with --app, else None."""
    if not args.app:
        return None
    names = series(parsed["intervals"])
    if parsed["lost"]:
        # A stream that lost messages is not a fair sample (even with --allow-loss): it goes to no series.
        return {name: f"not recorded: log stream lost messages {parsed['lost']} time(s)" for name in names}
    try:
        app = app_factory(args)
    except bench_launch.RecordError as error:
        return {name: f"not recorded: {error}" for name in names}
    return record(app, parsed["intervals"], args.story, args.engine)


def run(args, lines: list[str], timebase, app_factory=live_app, out=None) -> int:
    """Summarizes `lines` (and with --app writes result-v1 through `app_factory(args)`); prints the report to `out`
    (stdout) and returns the exit status."""
    out = out or sys.stdout
    parsed = parse(lines, timebase)
    rows = summarize(parsed["intervals"])
    status = 2 if parsed["lost"] and not args.allow_loss else 0
    results = results_of(args, parsed, app_factory)
    if args.json:
        report = {"rows": rows, "lost": parsed["lost"], "unpaired": parsed["unpaired"]}
        if results is not None:
            report["results"] = results
        print(json.dumps(report), file=out)
    else:
        print(f"lost-message reports: {parsed['lost']}  unpaired begins: {parsed['unpaired']}", file=out)
        print(f"{'name':28} {'detail':36} {'n':>5} {'p50':>9} {'p95':>9} {'p99':>9} {'max':>9}", file=out)
        for row in rows:
            print(f"{row['name']:28} {row['detail'][:36]:36} {row['count']:5} {row['p50_ms']:9.3f} "
                  f"{row['p95_ms']:9.3f} {row['p99_ms']:9.3f} {row['max_ms']:9.3f}", file=out)
        for name, where in (results or {}).items():
            print(f"perf-signposts: result-v1 {name}: {where}", file=out)
    if missing_input_age(parsed["intervals"]):
        print("perf-signposts: WARNING: user action runs carry no input age (input_age_ms -1 on every one): "
              "input to commit is empty; the App's dispatchingInputEvent wiring or the scenario is wrong", file=sys.stderr)
        if args.require_input_age:
            status = status or 3
    if status == 2:
        print(f"perf-signposts: log stream lost messages {parsed['lost']} time(s); the sample is not complete "
              "(rerun, or pass --allow-loss to keep it)", file=sys.stderr)
    return status


def main() -> int:
    args = parse_args()
    if args.self_test:
        return self_test()
    timebase = local_timebase()
    if args.source:
        with open(args.source) as handle:
            lines = handle.read().splitlines()
    else:
        lines = stream(args)  # the timebase header first (Recording.stop)
    if args.save:
        with open(args.save, "w") as handle:
            handle.write("\n".join(lines) + "\n")
    return run(args, lines, timebase)


if __name__ == "__main__":
    sys.exit(main())
