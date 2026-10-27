#!/usr/bin/env python3
"""Keystroke-to-frame latency for one cmux-next terminal, hop by hop.

Two ways to run it.

1. Launched (p05-ipc-005): today's tagged build through bench_launch.py, keys through `debug.key`:

  scripts/cmux-next/bench-typing.py --tag TAG [--app APP] [--flood N] [--stress] [--samples 120] [--out DIR] [--story ID]

   The app gets CMUX_NEXT_TYPING_PROBE (the CSV below) and CMUX_NEXT_TRACE_FLOWS (key-press flow marks of
   the daemon, its terminal hosts and the holder, cmux_flow_trace: `flows-<pid>.jsonl` in DIR/flows). The
   typed terminal runs `cat` (the tty echoes each key). --flood N puts N more terminals in the measured
   workspace, each writing 10 MB/s (--flood-mbps) of plain lines; the light layout is the typed pane and a
   column of N flood panes beside it, --stress builds the STRESS session (perf-stress-session.py, its busy
   terminals in the background workspaces) and types into the measured workspace's first pane while the
   next N panes' terminals flood. Phases: `single` (no flood output: the baseline) then `flood`.

   Keys are joined to the daemon by flow id, never by time. The app mints one flow per key-down (pid << 32 |
   probe row index, rows numbered in key order), and the daemon's `daemon.send.write` hop carries it. The
   phase's i-th key is row base + i, where base follows the last row the daemon wrote before the phase; a
   write whose row is outside the phase's keys, a write before its own key, or a key that failed refuses the
   phase's join (`join_refused`) instead of guessing. A key with no write is counted (`missed_write`).
   Per key, from its own timestamp (CLOCK_UPTIME_RAW, as every hop):
     key_to_daemon_write_ms   the daemon writes the key to the PTY
     key_to_daemon_echo_ms    the daemon hands the typed terminal's echo to its attach taps: the
                              `daemon.output.attach` record of that terminal in the key's window, from its
                              write to the next key's write (plans/cmux-next/trace.md, key-press flows). It is
                              taken only when the window holds exactly one record and the key before took its
                              own; otherwise the key is counted in `echo_missed` (none, two or more, or the key
                              before is unplaced). A write with no terminal id (a surface without a host
                              identity) cannot tell the typed terminal from a flooder: the phase's echo series
                              is refused (`echo_refused`).
     key_to_app_echo_ms       the app decoded output (probe `output_decoded_ms`)
     key_to_frame_ms          the first frame contents after that output was parsed (probe `contents_ms`)
   Each key's timestamp is its send time, so every series includes the wait before the app injects the key:
   the control socket's utility lane and the main-thread queue (threading-model.md). That wait is reported
   apart as `key_to_injection_ms` (the reply's `injected_at`, read on the main thread at injection, minus the
   key's timestamp; empty against a build whose debug.key does not return it).
   The probe's output and frame marks are not tied to a surface: the first output of any terminal after the
   key takes them. So the two app series are reported only for a phase in which no other terminal output
   anything (the daemon marks every terminal's output); otherwise they are withheld as unscoped
   (`app_series`), which under --flood and under --stress (its busy terminals) is every phase but a light
   single, and IPC-8 is then measured daemon-side only.
   Every series is p50/p95/p99/max; `ipc8` is the flood p95 minus the single p95 of each series both phases
   report (IPC-8: <= 0.5 ms for the echo). report.json has the host, macOS and display Hz, the flooders'
   achieved MB/s, and each series is also a cmux-perf-result/v1 file (BenchApp.record): story --story (default
   `bench-typing-flood-<N>`, `bench-typing-flood-<N>-stress` with --stress), metric `<phase>.<series>`.
   Percentiles come from scripts/perf-lab/perf_stats.py (typing_report.distribution), in both modes.

2. Attached (the original mode): launch a tagged cmux-next with CMUX_NEXT_TYPING_PROBE=<csv> (see
TypingLatencyProbe.swift), focus a terminal at a shell prompt, then run:

  scripts/cmux-next/bench-typing.py --pid PID --window WINDOW_ID --csv PATH [--samples 60]

Each sample is one real key-down posted to the app by CuaDriver
(`press_key`, background delivery), paced wider than a round trip so one
key is in flight at a time. The app's probe writes one CSV row per key:
milliseconds after the event's timestamp at which AppKit dispatch began
and ended, Ghostty called io_write, the attach socket took the input, the
echo was decoded, reached the main actor, was parsed, and the first frame
after that parse was handed to Core Animation (`contents_ms`). The photon
follows at the compositor's next vsync, at most one refresh later.

Prints p50, p95, p99 and max per hop and per segment, and writes the same
as JSON next to the CSV.

3. Chromium surfaces and the energy saver (p14-energy-135: D8 of plans/cmux-next/chrome-parity/p14-energy.md, the
saver adds no visible latency). Launched, like mode 1:

  scripts/cmux-next/bench-typing.py --app APP --surface agent-composer-chromium,chromium-page-scroll \\
      --energy-saver off,on [--samples 120] [--scrolls 3] [--out DIR] [--dry-run]

   --surface terminal                 mode 1 (the default)
   --surface agent-composer-chromium  the agent chat's composer in a Chromium page (`browser.defaultEngine: chromium`,
                                      the mock agent host). Keys go to the page through `debug.key {target: page}`,
                                      stamped at their send. Key->frame is the page's own typingStats (webviews acpmux
                                      perf.ts): from the keydown's event time to the next requestAnimationFrame
                                      (`key_to_frame_ms`, the frame that draws the key, as Chrome's EventLatency ends a
                                      key at its frame) and to after that frame (`key_to_paint_ms`), p50/p95/max.
   --surface chromium-page-scroll     idle-budget's scroll page (SCROLL_PAGE) in a Chromium tab, scrolled by --scrolls
                                      trackpad gestures of --scroll-seconds (2 s) each: one `debug.mouse {target: page,
                                      action: scroll}` event per display refresh (--hz, default the main display's;
                                      `hover: false` after `began`, so no event pays a layout hover recompute). The
                                      page keeps a rAF loop running while wheel events come and records each main
                                      frame's rAF time and the time after its main-thread work, one run per loop; a
                                      pause in the input longer than the page's quiet time starts a new run and is no
                                      interval. Reported: frames, rAF intervals p50/p95/p99/max, after-frame intervals,
                                      fps, wheel events sent and received, pixels scrolled, and dropped frames:
                                      refreshes that passed with no main frame inside a run, sum of
                                      round(interval / refresh) - 1 (acpmux perf.ts droppedFrames). This is the
                                      page's main-frame (rAF) cadence while scrolled, not presented frames: a frame
                                      that viz or the display compositor drops after its main frame is not seen, and
                                      the loop asks for a main frame every refresh. A scroll is an error (and D8
                                      unscored) when a wheel event failed, two sends were further apart than the quiet
                                      time, the page got under half the events, or it moved under half the sent delta;
                                      the page scrolls back to the top between gestures.
   --energy-saver on|off   `energy.saver: always` or `off`, with the default-off `energySaver` feature on in both
                           (idle-budget.saver_launch), on any surface. debug.energy is read before and after the
                           measurement; a run whose saver state is not the asked one has `saver.mismatch` and D8 does
                           not judge it.
   A comma list in --surface or --energy-saver runs every combination, one launch each, in DIR/<surface>-saver-<state>.
   With both saver states of a surface, `BENCH-TYPING-D8 {json}` lines judge D8: key->frame p95 with the saver at most
   +0.5 ms over off (terminal: the single phase), and with the saver on no dropped main frame of the scroll and fps at
   least 0.97 x 120. A typing pair is unscored when a key failed or under 90% of the sent keys were timed in either
   run; a scroll pair when either run has an error or its refresh rate is under 120 Hz or not measured (--hz or the
   main display's). DIR/d8.json holds every run and the verdicts. Reported, never an exit status.
   --dry-run prints one `BENCH-TYPING-PLAN {json}` line per combination (the single-run command, the cmux-next.json
   keys and environment it adds) and launches nothing.
"""

import argparse
import bisect
import csv
import functools
import glob
import importlib.util
import json
import os
import shlex
import subprocess
import sys
import time
from pathlib import Path

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import bench_tagged  # noqa: E402
import typing_report  # noqa: E402

HOPS = [
    "dispatch_start_ms", "dispatch_end_ms", "io_write_ms", "socket_submit_ms",
    "output_decoded_ms", "output_received_ms", "output_parsed_ms", "contents_ms",
]
SEGMENTS = [
    ("event to dispatch", None, "dispatch_start_ms"),
    ("dispatch to io_write", "dispatch_start_ms", "io_write_ms"),
    ("io_write to socket", "io_write_ms", "socket_submit_ms"),
    ("socket to echo decoded (daemon, host, shell)", "socket_submit_ms", "output_decoded_ms"),
    ("decoded to taken by the session", "output_decoded_ms", "output_received_ms"),
    ("taken to parsed", "output_received_ms", "output_parsed_ms"),
    ("parsed to frame contents", "output_parsed_ms", "contents_ms"),
]
KEY_SERIES = ["key_to_daemon_write_ms", "key_to_daemon_echo_ms", "key_to_app_echo_ms", "key_to_frame_ms"]
ECHO_HOP = "daemon.output.attach"
WRITE_HOP = "daemon.send.write"

# The flood load: plain lines at a fixed byte rate, paced on the monotonic clock (no burst after a stall: a writer
# that falls behind restarts its schedule), its achieved rate written to STATS once a second and at Ctrl-C.
FLOODER = r'''
import json, os, sys, time
rate = float(sys.argv[1]) * 1e6
stats = sys.argv[2]
line = b"flood 0123456789 abcdefghijklmnopqrstuvwxyz ABCDEFGHIJKLMNOPQRSTUVWXYZ 0123456789 flood\r\n"
block = line * (16384 // len(line))
period = len(block) / rate
start = deadline = time.monotonic()
written, reported = 0, start

def report():
    with open(stats + ".tmp", "w") as f:
        json.dump({"bytes": written, "seconds": time.monotonic() - start}, f)
    os.replace(stats + ".tmp", stats)

try:
    while True:
        written += os.write(1, block)
        deadline += period
        now = time.monotonic()
        if now - reported >= 1:
            report()
            reported = now
        if deadline > now:
            time.sleep(deadline - now)
        elif now - deadline > 1:
            deadline = now
except KeyboardInterrupt:
    report()
'''


def summarize(values):
    """n/p50/p95/p99/max of `values` (typing_report.distribution); the original keys `median` and `min` stay for old
    readers."""
    stats = typing_report.distribution(values, digits=3, mean=False)
    if not stats:
        return None
    return {**stats, "median": stats["p50"], "min": round(min(v for v in values if v is not None), 2)}


def press(driver, pid, window, key):
    payload = json.dumps({"pid": pid, "window_id": window, "key": key})
    result = subprocess.run([driver, "call", "press_key", payload], check=True, capture_output=True, text=True, timeout=10)
    # Without an exact window CuaDriver answers with candidates and posts nothing.
    if '"candidates"' in result.stdout:
        sys.exit(f"press_key did not post: {result.stdout[:300]}")


def analyze_rows(rows):
    complete = [row for row in rows if row["complete"] == "1"]
    result = {
        "rows": len(rows), "complete": len(complete), "measured": len(complete),
        "io_write_on_main": sum(row["io_write_on_main"] == "1" for row in complete),
        "hops": {hop: summarize([float(row[hop]) for row in complete if row.get(hop)]) for hop in HOPS},
        "segments": {},
    }
    for name, start, end in SEGMENTS:
        values = [float(row[end]) - (float(row[start]) if start else 0.0)
                  for row in complete if row.get(end) and (start is None or row.get(start))]
        result["segments"][name] = summarize(values)
    return result


def print_analysis(result):
    print(f"rows={result['rows']} complete={result['complete']} measured={result['measured']} "
          f"io_write_on_main={result['io_write_on_main']}")
    print(f"{'from key event (ms)':<46} {'p50':>8} {'p95':>8} {'p99':>8} {'max':>8}")
    for hop, stats in result["hops"].items():
        if stats:
            print(f"{hop:<46} {stats['p50']:>8} {stats['p95']:>8} {stats['p99']:>8} {stats['max']:>8}")
    print(f"\n{'segment (ms)':<46} {'p50':>8} {'p95':>8} {'p99':>8} {'max':>8}")
    for name, stats in result["segments"].items():
        if stats:
            print(f"{name:<46} {stats['p50']:>8} {stats['p95']:>8} {stats['p99']:>8} {stats['max']:>8}")


def attached_main(args):
    if not args.analyze_only:
        rows_before = len(args.csv.read_text().splitlines()) - 1 if args.csv.exists() else -1
        if rows_before < 0:
            sys.exit(f"{args.csv} has no header: was the app launched with CMUX_NEXT_TYPING_PROBE?")
        for index in range(args.warmup + args.samples):
            press(args.driver, args.pid, args.window, args.keys[index % len(args.keys)])
            time.sleep(args.interval)
            if (index + 1) % 40 == 0:
                press(args.driver, args.pid, args.window, "return")
                time.sleep(args.interval)
        time.sleep(1)

    with args.csv.open() as handle:
        rows = list(csv.DictReader(handle))
    if not args.analyze_only:
        # Only this run's rows, past its warm-up keys.
        rows = rows[rows_before + args.warmup:]
    result = analyze_rows(rows)
    print_analysis(result)
    args.csv.with_suffix(".summary.json").write_text(json.dumps(result, indent=2) + "\n")


# ---------------------------------------------------------------- flow traces

def read_flows(folder, keep):
    """Flow records under `folder` (flows-*.jsonl) for which `keep(record)` is true; {"dropped": N} lines summed."""
    records, dropped = [], 0
    for path in sorted(glob.glob(os.path.join(folder, "flows-*.jsonl"))):
        with open(path, errors="replace") as f:
            for raw in f:
                try:
                    record = json.loads(raw)
                except ValueError:
                    continue  # the writer's last line may be cut at the read
                if "dropped" in record:
                    dropped += int(record.get("dropped") or 0)
                elif keep(record):
                    records.append(record)
    return records, dropped


def flow_row(record, app_pid):
    """The probe row index of a record whose flow this app minted, else None."""
    flow = int(record.get("flow") or 0)
    return flow & 0xFFFFFFFF if flow and flow >> 32 == (app_pid & 0xFFFFFFFF) else None


def next_row(writes, app_pid):
    """The probe row after the last one of this app the daemon wrote (`writes` before a phase), or None."""
    rows = [r for r in (flow_row(w, app_pid) for w in writes) if r is not None]
    return max(rows) + 1 if rows else None


class JoinRefused(Exception):
    """The phase's writes cannot be joined to its keys by flow id without a guess."""


def join_writes(key_times_ns, writes, app_pid, base=None):
    """One entry per typed key, in typing order: its timestamp, its probe row and its daemon write (the first write
    of its flow: a return can be two), or no write. The keys of a phase are typed one at a time and every key-down
    opens one probe row, so the i-th key is row `base + i`. `base` is ``next_row`` of the writes before the phase;
    None takes the phase's lowest row, which needs every key to have reached the daemon. Raises JoinRefused when the
    rows do not fit the keys."""
    first = {}
    for write in sorted(writes, key=lambda r: r["t_ns"]):
        row = flow_row(write, app_pid)
        if row is not None:
            first.setdefault(row, write)
    count = len(key_times_ns)
    if base is None:
        if not first:
            return [{"key_ns": key, "row": None, "write_ns": None, "terminal": None} for key in key_times_ns]
        base = min(first)
        if len(first) != count or max(first) - base + 1 != count:
            raise JoinRefused(f"{len(first)} written rows ({base}..{max(first)}) for {count} keys and no row before "
                              "the phase to count from")
    outside = sorted(row for row in first if not base <= row < base + count)
    if outside:
        raise JoinRefused(f"{len(outside)} written rows outside the phase's keys (rows {base}..{base + count - 1}): "
                          f"{outside[:5]}; another key-down opened a probe row")
    joined = []
    for index, key in enumerate(key_times_ns):
        write = first.get(base + index)
        if write is not None and write["t_ns"] < key:
            raise JoinRefused(f"row {base + index} was written before its key: the rows are not this phase's keys")
        joined.append({"key_ns": key, "row": base + index, "write_ns": write["t_ns"] if write else None,
                       "terminal": (write.get("terminal") or "") if write else None})
    return joined


def place_echoes(joined, echoes):
    """Sets each joined key's `echo_ns` (or `echo_missed` with why) from `echoes` (terminal id -> sorted
    daemon.output.attach times). A key's window on its terminal runs from its write to the next key's write there;
    the key takes the window's record only when there is exactly one and the key before on that terminal took its
    own (else that one may be the key before's late echo), as trace.py's assemble_flows places flow-0 hops."""
    by_terminal = {}
    for entry in joined:
        entry["echo_ns"] = None
        if entry["write_ns"] is None:
            entry["echo_missed"] = "no write"
        else:
            by_terminal.setdefault(entry["terminal"], []).append(entry)
    for terminal, sent in by_terminal.items():
        times = echoes.get(terminal, [])
        previous_placed = True
        for index, entry in enumerate(sent):
            until = sent[index + 1]["write_ns"] if index + 1 < len(sent) else float("inf")
            window = times[bisect.bisect_left(times, entry["write_ns"]):bisect.bisect_left(times, until)]
            if len(window) == 1 and previous_placed:
                entry["echo_ns"] = window[0]
            else:
                entry["echo_missed"] = ("none" if not window else "two or more" if len(window) > 1
                                        else "the key before did not place its echo")
            previous_placed = entry["echo_ns"] is not None
    return joined


def key_series(joined, probe_rows, echo_scoped=True, app_scoped=True):
    """The KEY_SERIES from joined keys (``place_echoes`` run) and the probe's rows by index. `echo_scoped` False
    leaves the daemon echo series empty, `app_scoped` False the app series (the caller says why). Returns
    (series, counts)."""
    by_index = {int(r["index"]): r for r in probe_rows if r.get("index", "").isdigit()}
    series = {name: [] for name in KEY_SERIES}
    counts = {"missed_write": 0, "echo_missed": {}, "app_row_missing": 0}
    for entry in joined:
        key = entry["key_ns"]
        if entry["write_ns"] is None:
            counts["missed_write"] += 1
            continue
        series["key_to_daemon_write_ms"].append((entry["write_ns"] - key) / 1e6)
        if echo_scoped:
            if entry.get("echo_ns") is None:
                why = entry.get("echo_missed", "none")
                counts["echo_missed"][why] = counts["echo_missed"].get(why, 0) + 1
            else:
                series["key_to_daemon_echo_ms"].append((entry["echo_ns"] - key) / 1e6)
        if not app_scoped:
            continue
        row = by_index.get(entry["row"])
        if not row or row.get("complete") != "1" or not row.get("output_decoded_ms"):
            counts["app_row_missing"] += 1
            continue
        series["key_to_app_echo_ms"].append(float(row["output_decoded_ms"]))
        if row.get("contents_ms"):
            series["key_to_frame_ms"].append(float(row["contents_ms"]))
    return series, counts


def phase_scope(joined, echo_records):
    """(echo_refused, app_unscoped): why the phase's daemon echo series and its app series cannot be scoped to the
    typed terminal, or None. `echo_records` are every terminal's daemon.output.attach records in the phase."""
    typed = {entry["terminal"] for entry in joined if entry["write_ns"] is not None}
    echo_refused = app_unscoped = None
    if "" in typed:
        echo_refused = ("a write of this app has no terminal id (a surface without a host identity): its echo "
                        "cannot be told from another terminal's output")
        app_unscoped = echo_refused
    others = [r for r in echo_records if r.get("terminal") not in typed]
    if others and app_unscoped is None:
        app_unscoped = (f"{len(others)} outputs of {len({r.get('terminal') for r in others})} other terminals in the "
                        "phase: the probe's output and frame marks are not tied to a surface, so another terminal's "
                        "output can take them (IPC-8 is measured daemon-side only)")
    return echo_refused, app_unscoped


# ---------------------------------------------------------------- launched mode

def load_stress():
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def flood_rate(stats_path):
    try:
        with open(stats_path) as f:
            data = json.load(f)
        return round(data["bytes"] / max(data["seconds"], 1e-6) / 1e6, 2)
    except (OSError, ValueError, KeyError):
        return None


class Launched:
    def __init__(self, args):
        from bench_launch import BenchApp
        self.args = args
        bundle = bench_tagged.resolve_app(args.tag, args.app)
        self.out = default_out(args, bundle)
        os.makedirs(self.out, exist_ok=True)
        self.probe = os.path.join(self.out, "typing.csv")
        self.flows = os.path.join(self.out, "flows")
        os.makedirs(self.flows, exist_ok=True)
        for stale in glob.glob(os.path.join(self.flows, "flows-*.jsonl")):
            os.unlink(stale)  # an earlier run's marks would match nothing, but cost the parse
        config, env = launch_config("terminal", args.energy_saver)
        self.app = BenchApp(bundle, out=self.out, perf_session="stress" if args.stress else "light",
                            env={"CMUX_NEXT_TYPING_PROBE": self.probe, "CMUX_NEXT_TRACE_FLOWS": self.flows, **env},
                            config=config, window=WINDOW)
        self.saver = SaverCheck(args.energy_saver)
        self.stress_module = load_stress()
        self.stress = None
        self.report = {"opts": {k: str(v) for k, v in vars(args).items()}, "phases": {}, "log": []}

    def note(self, text):
        print(text, flush=True)
        self.report["log"].append(text)

    def rpc(self, method, params=None, timeout=60):
        return self.app.rpc(method, params, timeout=timeout)

    def terminal_tab(self, workspace, pane):
        tabs = self.stress.tabs(workspace, pane)
        selected = next((t for t in tabs if t.get("kind") == "terminal" and t.get("selected")), None)
        return (selected or next((t for t in tabs if t.get("kind") == "terminal"), {})).get("id")

    def build_light(self):
        stress = self.stress
        try:
            stress.size_window()  # the bench minimum pane size; the window at STRESS's size when the screen holds it
        except self.stress_module.StressShapeError as error:
            self.note(f"light layout: {error} (the light layout does not need the STRESS grid)")
        workspace = stress.new_workspace()
        if not workspace:
            raise SystemExit("bench-typing: the typing workspace did not appear")
        stress.show(workspace)
        typed = stress.panes(stress.workspace(workspace))[0]["id"]
        flood = []
        if self.args.flood:
            column = stress.split(workspace, typed, "splitRight")
            if not column:
                raise SystemExit(f"bench-typing: no flood column ({stress.refusals[-1:]})")
            flood, share = [column], {column: 1.0}
            while len(flood) < self.args.flood:
                # Split the tallest flood pane: halves, then quarters, never one pane halved again and again.
                tallest = max(flood, key=share.get)
                new = stress.split(workspace, tallest, "splitDown")
                if not new:
                    raise SystemExit(f"bench-typing: flood pane {len(flood) + 1} refused ({stress.refusals[-1:]})")
                share[tallest] /= 2
                share[new] = share[tallest]
                flood.insert(flood.index(tallest) + 1, new)
            stress.action("equalizeSplits", target=f"pane:{column}", settle=0.8)
        return workspace, typed, flood

    def build_stress(self):
        summary = self.stress.build()
        print("STRESS-SESSION " + json.dumps(summary), flush=True)
        self.report["stress_session"] = summary
        workspace = summary.get("measured")
        panes = [p["id"] for p in self.stress.panes(self.stress.workspace(workspace))]
        if len(panes) < 1 + self.args.flood:
            raise SystemExit(f"bench-typing: STRESS's measured workspace has {len(panes)} panes, "
                             f"--flood {self.args.flood} needs {1 + self.args.flood}")
        return workspace, panes[0], panes[1:1 + self.args.flood]

    def type_keys(self, count, label):
        """`count` keys through debug.key, each stamped with its send time; returns the stamps in ns, the rpc
        round trips, each key's wait from its send to its injection on the main thread (ms) and how many keys
        failed."""
        keys = "abcdefghijklmnopqrstuvwxyz"
        stamps, trips, waits, failed = [], [], [], 0
        for index in range(count):
            t0 = time.perf_counter()
            key = "return" if index % 40 == 39 else keys[index % len(keys)]
            stamp = time.clock_gettime(time.CLOCK_UPTIME_RAW)
            reply = self.rpc("debug.key", {"key": key, "timestamp": stamp}, timeout=10)
            stamps.append(int(stamp * 1e9))
            trips.append((time.perf_counter() - t0) * 1000)
            injected = reply.get("injected_at") if isinstance(reply, dict) else None
            if isinstance(injected, (int, float)):
                waits.append((injected - stamp) * 1000)
            if isinstance(reply, dict) and reply.get("error"):
                failed += 1
                self.note(f"{label}: key {index}: {json.dumps(reply)[:160]}")
                if failed >= 10:
                    break
            rest = self.args.interval - (time.perf_counter() - t0)
            if rest > 0:
                time.sleep(rest)  # one key in flight at a time
        time.sleep(0.5)  # the last echo and frame land
        return stamps, trips, waits, failed

    def probe_rows(self):
        try:
            with open(self.probe) as handle:
                return list(csv.DictReader(handle))
        except OSError:
            return []

    def phase(self, name, pid):
        stamps, trips, waits, failed = self.type_keys(self.args.samples, name)
        time.sleep(0.3)  # the flow writer drains every 50 ms
        lo, hi = stamps[0], stamps[-1] + 2_000_000_000
        all_writes, dropped_a = read_flows(self.flows, lambda r: r.get("hop") == WRITE_HOP and r.get("t_ns", 0) <= hi)
        before = [w for w in all_writes if w.get("t_ns", 0) < lo]
        writes = [w for w in all_writes if w.get("t_ns", 0) >= lo]
        echo_records, dropped_b = read_flows(self.flows, lambda r: r.get("hop") == ECHO_HOP and lo <= r.get("t_ns", 0) <= hi)
        entry = {"keys": len(stamps), "failed_keys": failed, "flow_records_dropped": dropped_a + dropped_b,
                 "key_rpc_ms": summarize(trips), "key_to_injection_ms": summarize(waits)}
        self.note(bench_tagged.summary_line(f"{name} key_to_injection_ms", entry["key_to_injection_ms"], width=36))
        try:
            if failed:
                raise JoinRefused(f"{failed} keys failed: a failed key may not have opened its probe row")
            joined = join_writes(stamps, writes, pid, base=next_row(before, pid))
        except JoinRefused as error:
            entry.update(join_refused=str(error), series={k: [] for k in KEY_SERIES}, stats={k: None for k in KEY_SERIES})
            self.note(f"== {name}: keys {len(stamps)}, join refused: {error}")
            return entry
        echoes = {}
        for record in echo_records:
            echoes.setdefault(record.get("terminal"), []).append(record["t_ns"])
        for times in echoes.values():
            times.sort()
        place_echoes(joined, echoes)
        echo_refused, app_unscoped = phase_scope(joined, echo_records)
        series, counts = key_series(joined, self.probe_rows(), echo_scoped=echo_refused is None,
                                    app_scoped=app_unscoped is None)
        typed = sorted({e["terminal"] for e in joined if e["write_ns"] is not None})
        entry.update(matched=sum(e["write_ns"] is not None for e in joined), typed_terminals=typed, **counts,
                     echo_refused=echo_refused, app_series=f"withheld: {app_unscoped}" if app_unscoped else "scoped",
                     series=series, stats={k: summarize(v) for k, v in series.items()})
        self.note(f"== {name}: keys {entry['keys']} written {entry['matched']} missed write {counts['missed_write']} "
                  f"echo missed {counts['echo_missed']} terminals {typed}")
        if echo_refused:
            self.note(f"{name}: daemon echo series refused: {echo_refused}")
        if app_unscoped:
            self.note(f"{name}: app echo and frame series withheld: {app_unscoped}")
        for key, stats in entry["stats"].items():
            self.note(bench_tagged.summary_line(f"{name} {key}", stats, width=36))
        if not entry["matched"]:
            self.note(f"{name}: no key reached the daemon with a flow id: is the typed terminal focused, and does this "
                      "build pass CMUX_NEXT_TRACE_FLOWS to its daemon?")
        return entry

    def run(self):
        args = self.args
        self.app.launch()  # LaunchError (a SystemExit) with the reason
        pid = self.app.process.pid
        self.report.update(tag=self.app.tag, app=self.app.app, pid=pid, host=bench_tagged.host_block())
        flooders = []
        try:
            self.stress = self.stress_module.Stress(self.rpc, log=self.note, busy_where="elsewhere")
            workspace, typed, flood = self.build_stress() if args.stress else self.build_light()
            self.report["layout"] = {"workspace": workspace, "typed_pane": typed, "flood_panes": flood,
                                     "session": "stress" if args.stress else "light"}
            typed_tab = self.terminal_tab(workspace, typed)
            flood_tabs = [t for t in (self.terminal_tab(workspace, p) for p in flood) if t]
            if len(flood_tabs) < args.flood:
                raise SystemExit(f"bench-typing: {len(flood_tabs)} flood terminals of {args.flood}")
            flooder = os.path.join(self.out, "flooder.py")
            with open(flooder, "w") as f:
                f.write(FLOODER)
            self.stress.send(typed_tab, "exec /bin/cat\r")
            time.sleep(1.5)  # every shell is at its prompt and cat runs
            self.stress.show(workspace)
            self.stress.focus_pane(typed)
            self.stress.action("tab.focus", target=f"tab:{typed_tab}")
            self.saver.read(self.app)
            self.type_keys(args.warmup, "warmup")
            self.report["phases"]["single"] = self.phase("single", pid)
            if flood_tabs:
                for index, tab in enumerate(flood_tabs):
                    stats = os.path.join(self.out, f"flood-{index}.json")
                    command = " ".join(shlex.quote(p) for p in (sys.executable, "-I", flooder, str(args.flood_mbps), stats))
                    self.stress.send(tab, command + "\r")
                    flooders.append((tab, stats))
                time.sleep(2.0)  # the flood runs before the first key
                self.stress.focus_pane(typed)
                self.report["phases"]["flood"] = self.phase("flood", pid)
            self.saver.read(self.app)
        finally:
            for tab, _ in flooders:
                self.stress.send(tab, "\x03")  # Ctrl-C: the flooder writes its achieved rate and the shell returns
            if flooders:
                time.sleep(1.0)  # the flooders' last stats land
            self.report["flood_mbps"] = [flood_rate(stats) for _, stats in flooders]
            self.finish()
            self.app.stop()
        return 0

    def finish(self):
        self.report["saver"] = self.saver.report()
        if self.report["saver"] and self.report["saver"]["mismatch"]:
            self.note(f"saver: {self.report['saver']['mismatch']}")
        phases = self.report["phases"]
        single, flood = phases.get("single"), phases.get("flood")
        if single and flood:
            self.report["ipc8"] = {
                key: round(flood["stats"][key]["p95"] - single["stats"][key]["p95"], 3)
                for key in KEY_SERIES if flood["stats"].get(key) and single["stats"].get(key)}
            self.note(f"ipc8 (flood p95 - single p95, ms): {json.dumps(self.report['ipc8'])}")
            withheld = [n for n, p in (("single", single), ("flood", flood)) if p.get("app_series", "").startswith("withheld")]
            if withheld:
                self.report["ipc8_scope"] = f"daemon-side only: the app series are withheld in {', '.join(withheld)}"
                self.note(f"ipc8: {self.report['ipc8_scope']}")
        story = ((self.args.story or typing_report.flood_story(self.args.flood, self.args.stress))
                 + saver_suffix(self.args.energy_saver))
        recorded = {}
        for name, entry in phases.items():
            recorded.update(bench_tagged.record_series(
                self.app, story, {f"{name}.{k}": v for k, v in entry["series"].items()}, log=self.note))
        self.report["recorded"] = recorded
        h = self.report.get("host") or {}
        self.note(f"host {h.get('host')} macOS {h.get('macos')} {h.get('chip') or ''} {h.get('display_hz')} Hz; "
                  f"flood MB/s {self.report.get('flood_mbps')}")
        with open(os.path.join(self.out, "report.json"), "w") as f:
            json.dump(self.report, f, indent=1, default=str)
        print(f"== report {os.path.join(self.out, 'report.json')}", flush=True)


# ---------------------------------------------------------------- Chromium surfaces and the energy saver (mode 3)

SCRIPT = "scripts/cmux-next/bench-typing.py"
TERMINAL, COMPOSER, SCROLL = "terminal", "agent-composer-chromium", "chromium-page-scroll"
SURFACES = (TERMINAL, COMPOSER, SCROLL)
SAVER_STATES = ("on", "off")
WINDOW = (40, 40, 1600, 1000)
BASE_CONFIG = {"appearance": {"backgroundOpacity": 1}}  # BenchApp's default config
CHROMIUM_CONFIG = {"browser": {"defaultEngine": "chromium"}}
AGENT_MOCK_ENV = {"CMUX_NEXT_AGENT_PANE_MOCK": "1"}  # the mock agent host (AgentPaneMockHost): no agent account
MOCK_SESSION = "mock-session"  # the mock host's session, which shows the composer
COMPOSER_KEYS = "abcdefghijklmnopqrstuvwxyz"  # no return (it sends the prompt), no `/` or `@` (they open menus)
D8_TYPING_MS = 0.5  # D8: key->frame p95 with the saver on at most this much over off
D8_TIMED_SHARE = 0.9  # a typing run scores only when this share of its sent keys was timed
D8_HZ = 120.0  # D8: a page scroll in saver keeps 120 Hz
D8_FPS_SHARE = 0.97  # ... with fps over the scroll's runs at least this share of D8_HZ
DEFAULT_HZ = 120.0  # the fleet's measure display (split-spring --vdisplay=120) when the main display's rate is unknown
HZ_FROM_FLAG, HZ_FROM_DISPLAY, HZ_ASSUMED = "--hz", "main display", "assumed: the display rate is unknown"
SCROLL_MIN_WHEELS = 0.5  # Chromium aligns wheel events to its frames and may coalesce two into one, but not most
SCROLL_MIN_MOVED = 0.5  # a scroll that moved under this share of its sent delta did not really scroll


@functools.lru_cache(maxsize=None)
def idle_budget():
    """idle-budget.py (saver_launch, saver_state and saver_mismatch, the scroll page server), loaded by path once."""
    spec = importlib.util.spec_from_file_location("idle_budget", os.path.join(HERE, "idle-budget.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def launch_config(surface, saver):
    """(cmux-next.json, added environment) of one run: BenchApp's default config, Chromium as the engine of the
    Chromium surfaces, the mock agent host for the composer, and --energy-saver's setting and feature (None: none)."""
    config, env = dict(BASE_CONFIG), {}
    if surface in (COMPOSER, SCROLL):
        config.update(CHROMIUM_CONFIG)
    if surface == COMPOSER:
        env.update(AGENT_MOCK_ENV)
    if saver is not None:
        saver_config, saver_env = idle_budget().saver_launch(saver == "on")
        config.update(saver_config)
        env.update(saver_env)
    return config, env


def saver_suffix(saver):
    return f"-saver-{saver}" if saver else ""


def saver_block(asked, observed, reason):
    """The report's `saver`: the asked state, debug.energy's isSaver before and after the measurement and why, and the
    mismatch (idle-budget.saver_mismatch: an end with no debug.energy proves no saver); None when nothing was asked."""
    if asked is None:
        return None
    return {"asked": asked, "observed": list(observed), "reason": reason,
            "mismatch": idle_budget().saver_mismatch(asked == "on", list(observed) or [None])}


class SaverCheck:
    """--energy-saver as the app reports it (debug.energy), read before and after the measurement."""

    def __init__(self, asked):
        self.asked, self.observed, self.reason = asked, [], None

    def read(self, app):
        if self.asked is None:
            return
        ib = idle_budget()
        saver, reason = ib.saver_state(ib.read_rpc(app, "debug.energy"))
        self.observed.append(saver)
        self.reason = reason or self.reason

    def report(self):
        return saver_block(self.asked, self.observed, self.reason)


def default_out(args, bundle=None):
    """The run's artifacts folder: --out, else artifacts/bench-typing/<tag or bundle name>."""
    name = args.tag or os.path.basename(os.path.normpath(bundle or args.app))
    return os.path.abspath(args.out or os.path.join(bench_tagged.ROOT, "artifacts", "bench-typing", name))


def combinations(args):
    """[(surface, saver state or None)] of the --surface and --energy-saver lists, in their order."""
    return [(surface, saver) for surface in args.surfaces for saver in (args.savers or [None])]


def single_argv(args, surface, saver, out):
    """The command of one combination: what the multi-run executes in this process, as one launch."""
    argv = ["python3", SCRIPT, *(["--app", args.app] if args.app else ["--tag", args.tag]), "--surface", surface]
    if saver:
        argv += ["--energy-saver", saver]
    if surface == SCROLL:
        argv += ["--scrolls", str(args.scrolls), "--scroll-seconds", f"{args.scroll_seconds:g}",
                 "--scroll-px", f"{args.scroll_px:g}", *(["--hz", f"{args.hz:g}"] if args.hz else [])]
    else:
        argv += ["--samples", str(args.samples), "--warmup", str(args.warmup), "--interval", f"{args.interval:g}"]
    if surface == TERMINAL:
        argv += [*(["--flood", str(args.flood), "--flood-mbps", f"{args.flood_mbps:g}"] if args.flood else []),
                 *(["--stress"] if args.stress else [])]
    return argv + ["--out", out]


def plan(args):
    """One row per combination: its surface, saver state, artifacts folder, single-run command, and the cmux-next.json
    and environment its launch adds (``launch_config``)."""
    base, combos = default_out(args), combinations(args)
    rows = []
    for surface, saver in combos:
        out = base if len(combos) == 1 else os.path.join(base, surface + saver_suffix(saver))
        config, env = launch_config(surface, saver)
        rows.append({"surface": surface, "energy_saver": saver, "out": out,
                     "command": shlex.join(single_argv(args, surface, saver, out)), "config": config, "env": env})
    return rows


def composer_result(stats, sent, failed=0):
    """The composer run's numbers from the page's typingStats ({keys, to_frame: {p50_ms, p95_ms, max_ms}, to_paint}):
    key_to_frame_ms and key_to_paint_ms as {n, p50, p95, max} (None with no timed key), and `untimed`, the sent keys
    that reached no timing (focus left the composer, or the key never arrived); {"error": ...} with no typingStats."""
    if not isinstance(stats, dict) or stats.get("error") or not isinstance(stats.get("keys"), int):
        return {"sent": sent, "failed_keys": failed, "error": f"no typingStats: {json.dumps(stats)[:200]}"}
    keys = stats["keys"]

    def dist(block):
        if not keys or not isinstance(block, dict):
            return None
        return {"n": keys, "p50": block.get("p50_ms"), "p95": block.get("p95_ms"), "max": block.get("max_ms")}
    return {"sent": sent, "failed_keys": failed, "timed": keys, "untimed": max(0, sent - failed - keys),
            "key_to_frame_ms": dist(stats.get("to_frame")), "key_to_paint_ms": dist(stats.get("to_paint"))}


def composer_series(stats):
    """{key_to_frame_ms, key_to_paint_ms: [ms per key]} of typingStats {raw: true} (its per-key `samples` rows of
    `to_frame_ms`, `to_paint_ms`); empty lists when the page sent none (a page from before `raw`)."""
    rows = stats.get("samples") if isinstance(stats, dict) else None
    rows = [row for row in rows if isinstance(row, dict)] if isinstance(rows, list) else []
    return {name: [row[field] for row in rows if isinstance(row.get(field), (int, float))]
            for name, field in (("key_to_frame_ms", "to_frame_ms"), ("key_to_paint_ms", "to_paint_ms"))}


def frame_drops(intervals, nominal_ms):
    """Refreshes that passed with no frame: sum of max(0, round(interval / nominal) - 1) (webviews acpmux perf.ts
    droppedFrames)."""
    return sum(max(0, round(interval / nominal_ms) - 1) for interval in intervals)


def gesture_events(seconds, hz):
    """The wheel events of one gesture of `seconds` at `hz`: began, the changed ones, ended."""
    return max(2, round(seconds * hz))


def run_intervals(runs):
    """The intervals between consecutive times inside each run; none across two runs (a pause in the input)."""
    return [b - a for times in runs for a, b in zip(times, times[1:])]


def scroll_refusals(read, gesture):
    """Why one scroll does not measure a steady scroll (empty when it does): a wheel event failed, two sends were
    further apart than the page's quiet time (the input paused and the page started a new run: gesture's
    `max_gap_ms`), the page received under SCROLL_MIN_WHEELS of the events sent, or it moved under SCROLL_MIN_MOVED
    of the delta sent (at its end, or the events went elsewhere). With no `gesture` (its counts unknown) only a page
    that did not move is refused."""
    why = []
    events = gesture.get("events") or 0
    if gesture.get("failed"):
        why.append(f"{gesture['failed']} of {events} wheel events failed")
    gap, quiet = gesture.get("max_gap_ms") or 0, idle_budget().SCROLL_QUIET_MS
    if gap > quiet:
        why.append(f"two wheel events were sent {gap:g} ms apart: the input paused past the page's {quiet} ms quiet "
                   "time (the bench, not the page)")
    if events and read["wheels"] < SCROLL_MIN_WHEELS * events:
        why.append(f"the page received {read['wheels']} of {events} wheel events")
    moved, sent = abs(read["scrolled_px"]), gesture.get("delta_px") or 0
    if not moved:
        why.append("the page did not move")
    elif sent and moved < SCROLL_MIN_MOVED * sent:
        why.append(f"the page moved {moved} px of {sent:g} px sent")
    return why


def scroll_result(reads, hz, gestures=()):
    """The scroll run's numbers from the page's reads (IdlePages.read_scroll: {wheels, scrolled_px, runs_ms,
    post_runs_ms}, one per gesture) at `hz`: frames, rAF intervals (p50/p95/p99/max) and after-frame intervals inside
    the runs, fps over the runs' spans, dropped frames, wheel events sent (``gestures``) and received, pixels scrolled,
    per scroll and in total. `error` when a read failed, a scroll is refused (``scroll_refusals``), or the page
    recorded no frame interval (no wheel event reached it)."""
    nominal, gestures = 1000.0 / hz, list(gestures)
    intervals, post_intervals, scrolls, errors, span = [], [], [], [], 0.0
    for index, read in enumerate(reads):
        label = f"scroll {index + 1}"
        if not isinstance(read, dict) or "error" in read:
            errors.append(f"{label}: " + (read.get("error", "no read") if isinstance(read, dict) else "no read"))
            continue
        runs = read["runs_ms"]
        gaps = run_intervals(runs)
        intervals += gaps
        post_intervals += run_intervals(read["post_runs_ms"])
        span += sum(times[-1] - times[0] for times in runs if len(times) > 1)
        scrolls.append({"frames": sum(len(times) for times in runs), "runs": len(runs),
                        "dropped_frames": frame_drops(gaps, nominal), "wheels": read["wheels"],
                        "scrolled_px": read["scrolled_px"]})
        gesture = gestures[index] if index < len(gestures) else {}
        errors += [f"{label}: {why}" for why in scroll_refusals(read, gesture)]
    result = {"hz": hz, "nominal_ms": round(nominal, 3), "scrolls": scrolls,
              "frames": sum(s["frames"] for s in scrolls),
              "wheels_sent": sum(g.get("events", 0) for g in gestures),
              "wheels_received": sum(s["wheels"] for s in scrolls),
              "scrolled_px": sum(abs(s["scrolled_px"]) for s in scrolls),
              "frame_interval_ms": bench_tagged.distribution(intervals),
              "after_frame_interval_ms": bench_tagged.distribution(post_intervals),
              "dropped_frames": frame_drops(intervals, nominal) if intervals else None,
              "fps": round(len(intervals) / (span / 1000), 1) if span > 0 else None,
              "intervals_ms": [round(interval, 2) for interval in intervals],
              "after_intervals_ms": [round(interval, 2) for interval in post_intervals]}
    if not intervals and not errors:
        errors.append("the page recorded no frames while scrolled: no wheel event reached it")
    if errors:
        result["error"] = "; ".join(errors)
    return result


def typing_p95(surface, report):
    """D8's key->frame p95 (ms) of one run's report, or None: the terminal's single phase, the composer's page."""
    if surface == TERMINAL:
        stats = (((report.get("phases") or {}).get("single") or {}).get("stats") or {}).get("key_to_frame_ms")
    else:
        stats = report.get("key_to_frame_ms")
    return (stats or {}).get("p95")


def typing_counts(surface, report):
    """(keys sent, keys timed, keys failed) of one typing run's report: the terminal's single phase (timed: its
    key->frame samples), the composer's page (timed: its typingStats keys)."""
    if surface == TERMINAL:
        single = (report.get("phases") or {}).get("single") or {}
        timed = ((single.get("stats") or {}).get("key_to_frame_ms") or {}).get("n") or 0
        return single.get("keys") or 0, timed, single.get("failed_keys") or 0
    return report.get("sent") or 0, report.get("timed") or 0, report.get("failed_keys") or 0


def typing_refusals(surface, state, report):
    """Why one typing run cannot be compared (empty when it can): a key failed, or under D8_TIMED_SHARE of the sent
    keys reached a timing, so its p95 comes from another sample than the other run's."""
    sent, timed, failed = typing_counts(surface, report)
    why = [f"saver {state}: {failed} keys failed"] if failed else []
    if timed < D8_TIMED_SHARE * sent or not sent:
        why.append(f"saver {state}: {timed} of {sent} keys timed (under {D8_TIMED_SHARE:.0%})")
    return why


def scroll_rate_refusals(state, report):
    """Why one scroll run cannot judge D8's 120 Hz (empty when it can): its refresh rate is under D8_HZ, or it was
    assumed rather than measured (--hz or the main display's)."""
    hz, source = report.get("hz"), report.get("hz_source")
    if hz is None:
        return []  # no scroll result: the run's error says why
    why = [] if hz >= D8_HZ else [f"saver {state}: measured at {hz:g} Hz, D8 needs {D8_HZ:g} Hz"]
    if source not in (HZ_FROM_FLAG, HZ_FROM_DISPLAY):
        why.append(f"saver {state}: the refresh rate was {source or 'not given'}")
    return why


def d8_verdicts(reports):
    """{surface: {check, on, off, [delta_ms], [fps_on], verdict, [why]}} of each surface that ran with both saver
    states, from {(surface, state): report}. Verdicts: pass, fail, or unscored (a run failed, its saver state was not
    the asked one, it has no number, a typing run lost keys, or a scroll was not at a measured 120 Hz)."""
    verdicts = {}
    for surface in SURFACES:
        on, off = reports.get((surface, "on")), reports.get((surface, "off"))
        if on is None or off is None:
            continue
        both = (("on", on), ("off", off))
        why = [f"saver {state}: {r['error']}" for state, r in both if r.get("error")]
        why += [f"saver {state}: {r['saver']['mismatch']}" for state, r in both if (r.get("saver") or {}).get("mismatch")]
        if surface == SCROLL:
            fps_floor = round(D8_FPS_SHARE * D8_HZ, 1)
            entry = {"check": f"dropped main frames while scrolled with the saver on == 0 and fps >= {fps_floor:g}",
                     "on": on.get("dropped_frames"), "off": off.get("dropped_frames"), "fps_on": on.get("fps")}
            why += [reason for state, r in both for reason in scroll_rate_refusals(state, r)]
            passed = entry["on"] == 0 and entry["fps_on"] is not None and entry["fps_on"] >= fps_floor
        else:
            why += [reason for state, r in both if not r.get("error") for reason in typing_refusals(surface, state, r)]
            entry = {"check": f"key->frame p95 with the saver on <= off + {D8_TYPING_MS:g} ms",
                     "on": typing_p95(surface, on), "off": typing_p95(surface, off)}
            passed = None
            if entry["on"] is not None and entry["off"] is not None:
                entry["delta_ms"] = round(entry["on"] - entry["off"], 3)
                passed = entry["delta_ms"] <= D8_TYPING_MS
        if entry["on"] is None or entry["off"] is None:
            why.append("no number in both runs")
        verdicts[surface] = {**entry, "verdict": "unscored" if why else "pass" if passed else "fail",
                             **({"why": why} if why else {})}
    return verdicts


def chat_opening(error):
    """True when action.run's error only says the action is still running (the reply came before the page)."""
    if not isinstance(error, dict):
        return False
    return (error.get("data") or {}).get("state") == "in_progress" or error.get("code") == "timeout"


def wait_until(check, seconds, step=0.1):
    """check()'s first truthy value within `seconds`, else None."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = check()
        if value:
            return value
        time.sleep(step)  # bench: bounded wait for the page
    return None


class SurfaceRun:
    """One launch of a Chromium surface with its saver state: the app, its report.json and its saver reads."""

    surface = None

    def __init__(self, args):
        from bench_launch import BenchApp
        self.args = args
        bundle = bench_tagged.resolve_app(args.tag, args.app)
        self.out = default_out(args, bundle)
        os.makedirs(self.out, exist_ok=True)
        config, env = launch_config(self.surface, args.energy_saver)
        self.app = BenchApp(bundle, out=self.out, env=env, config=config, window=WINDOW)
        self.saver = SaverCheck(args.energy_saver)
        self.report = {"surface": self.surface, "energy_saver": args.energy_saver,
                       "opts": {k: str(v) for k, v in vars(args).items()}, "log": []}

    def note(self, text):
        print(text, flush=True)
        self.report["log"].append(text)

    def run(self):
        self.app.launch()  # LaunchError (a SystemExit) with the reason
        self.report.update(tag=self.app.tag, app=self.app.app, pid=self.app.process.pid, host=bench_tagged.host_block())
        try:
            self.measure()
        except BaseException as error:
            self.report["error"] = f"{type(error).__name__}: {getattr(error, 'code', None) or error}"[:500]
            raise
        finally:
            self.report["saver"] = self.saver.report()
            if self.report["saver"] and self.report["saver"]["mismatch"]:
                self.note(f"saver: {self.report['saver']['mismatch']}")
            with open(os.path.join(self.out, "report.json"), "w") as f:
                json.dump(self.report, f, indent=1, default=str)
            print(f"== report {os.path.join(self.out, 'report.json')}", flush=True)
            self.app.stop()
        return 0

    def measure(self):
        raise NotImplementedError


class ComposerRun(SurfaceRun):
    """--surface agent-composer-chromium (module docstring, mode 3)."""

    surface = COMPOSER

    def pane(self, action, timeout=30, **params):
        reply = self.app.rpc("debug.agent_pane", {**params, "action": action}, timeout=timeout)
        return reply if isinstance(reply, dict) else {}

    def open_chat(self):
        """A new agent chat on the mock session, its composer shown in Chromium; returns its pane."""
        reply = self.app.rpc("action.run", {"action": "palette.newAgentChat", "args": {}, "focus": True,
                                            "origin": "script"}, timeout=60)
        error = reply.get("error") if isinstance(reply, dict) else None
        if error and not chat_opening(error):
            raise SystemExit(f"bench-typing: palette.newAgentChat refused: {json.dumps(error)[:200]}")
        if not wait_until(lambda: self.pane("readiness", timeout=5).get("document_ready"), 60):
            raise SystemExit("bench-typing: the agent chat page did not load in 60 s")
        self.pane("select_session", session=MOCK_SESSION)
        if not wait_until(lambda: self.pane("readiness", timeout=5).get("composer_visible"), 30):
            raise SystemExit("bench-typing: the agent chat never showed its composer")
        engine = self.pane("engine")
        self.report["engine"] = engine
        if engine.get("engine") != "cef":
            raise SystemExit(f"bench-typing: the agent chat is not in Chromium: {json.dumps(engine)[:200]}")
        return engine.get("pane")

    def type_keys(self, pane, count):
        """`count` keys into the composer through debug.key, one in flight at a time; (failed keys, rpc round trips)."""
        failed, trips = 0, []
        for index in range(count):
            t0 = time.perf_counter()
            reply = self.app.rpc("debug.key", {"target": "page", "pane": pane, "key": COMPOSER_KEYS[index % len(COMPOSER_KEYS)],
                                               "timestamp": time.clock_gettime(time.CLOCK_UPTIME_RAW)}, timeout=10)
            trips.append((time.perf_counter() - t0) * 1000)
            if isinstance(reply, dict) and reply.get("error"):
                failed += 1
                self.note(f"key {index}: {json.dumps(reply)[:160]}")
            rest = self.args.interval - (time.perf_counter() - t0)
            if rest > 0:
                time.sleep(rest)  # bench: one key in flight at a time
        time.sleep(0.5)  # bench: the last key's frame lands
        return failed, trips

    def measure(self):
        pane = self.open_chat()
        if not self.pane("focus_composer").get("focused"):
            raise SystemExit("bench-typing: the composer did not take focus")
        self.saver.read(self.app)
        self.type_keys(pane, self.args.warmup)
        self.pane("reset_typing")
        failed, trips = self.type_keys(pane, self.args.samples)
        typing = self.pane("typing_stats", raw=True)
        self.saver.read(self.app)
        self.report.update(composer_result(typing, self.args.samples, failed), key_rpc_ms=summarize(trips),
                           composer_text_length=self.pane("readiness").get("composer_text_length"))
        for key in ("key_to_frame_ms", "key_to_paint_ms"):
            stats = self.report.get(key)
            self.note(f"{COMPOSER} {key}: " + (f"p50 {stats['p50']} p95 {stats['p95']} max {stats['max']} n={stats['n']}"
                                               if stats else "(no samples)"))
        if self.report.get("error"):
            self.note(f"{COMPOSER}: {self.report['error']}")
        self.report["recorded"] = bench_tagged.record_series(
            self.app, f"bench-typing-{COMPOSER}" + saver_suffix(self.args.energy_saver), composer_series(typing),
            engine="chromium", log=self.note)


class ScrollRun(SurfaceRun):
    """--surface chromium-page-scroll (module docstring, mode 3)."""

    surface = SCROLL

    def __init__(self, args):
        super().__init__(args)
        self.pages = idle_budget().IdlePages()

    def gesture(self, hz):
        """One trackpad gesture on the shown page: began, changed at `hz` for --scroll-seconds, ended. Only `began`
        moves the synthesized pointer (DebugMouse: `hover: false` after it, so no event pays a layout hover
        recompute a real trackpad scroll does not). Returns the events sent, failed and late (sent after their slot),
        the latest one's lateness and the longest gap between two sends in ms, the delta sent in px, its seconds and
        achieved rate."""
        count = gesture_events(self.args.scroll_seconds, hz)
        period, failed, late, max_late, max_gap = 1.0 / hz, 0, 0, 0.0, 0.0
        start = deadline = previous = time.monotonic()
        for index in range(count):
            phase = "began" if index == 0 else "ended" if index == count - 1 else "changed"
            sent = time.monotonic()
            max_gap = max(max_gap, sent - previous)
            previous = sent
            params = {"target": "page", "action": "scroll", "phase": phase,
                      "dy": 0 if phase == "ended" else -self.args.scroll_px}
            if phase != "began":
                params["hover"] = False
            reply = self.app.rpc("debug.mouse", params, timeout=5)
            if isinstance(reply, dict) and reply.get("error"):
                failed += 1
            deadline += period
            rest = deadline - time.monotonic()
            if rest > 0:
                time.sleep(rest)  # bench: one wheel event per display refresh
            elif index < count - 1:
                late += 1
                max_late = max(max_late, -rest)
        seconds = time.monotonic() - start
        return {"events": count, "failed": failed, "late": late, "max_late_ms": round(max_late * 1000, 2),
                "max_gap_ms": round(max_gap * 1000, 2), "delta_px": (count - 1) * self.args.scroll_px,
                "seconds": round(seconds, 3), "hz": round(count / seconds, 1) if seconds > 0 else None}

    def display_hz(self):
        """(rate, its source): --hz, the main display's, else DEFAULT_HZ assumed (D8 then leaves the scroll unscored)."""
        if self.args.hz:
            return self.args.hz, HZ_FROM_FLAG
        measured = (self.report.get("host") or {}).get("display_hz")
        return (float(measured), HZ_FROM_DISPLAY) if measured else (DEFAULT_HZ, HZ_ASSUMED)

    def measure(self):
        ib = idle_budget()
        hz, source = self.display_hz()
        self.report["hz_source"] = source
        room = ib.SCROLL_PAGE_PX - WINDOW[3]
        if gesture_events(self.args.scroll_seconds, hz) * self.args.scroll_px > room:
            raise SystemExit(f"bench-typing: a gesture of {self.args.scroll_seconds:g} s at {hz:g} Hz and "
                             f"{self.args.scroll_px:g} px per event scrolls past the page's {room} px: lower "
                             "--scroll-seconds or --scroll-px")
        try:
            ib.run_action(self.app, "openBrowser.chromium", {"url": self.pages.origin + ib.SCROLL_PATH}, focus=True,
                          timeout=90)
        except ib.SessionShapeError as error:
            raise SystemExit(f"bench-typing: {error}") from error
        if not self.pages.wait_loaded("scroll", 90):
            raise SystemExit("bench-typing: the scroll page did not load in 90 s")
        time.sleep(1.0)  # bench: the page's first frames land before the record starts
        self.saver.read(self.app)
        first = self.pages.read_scroll(10)  # the page starts a clean record at the top
        if "error" in first:
            raise SystemExit(f"bench-typing: the scroll page does not answer: {first['error']}")
        gestures, reads = [], []
        for _ in range(self.args.scrolls):
            gestures.append(self.gesture(hz))
            time.sleep(ib.SCROLL_QUIET_MS / 1000 + 0.15)  # bench: the page's record ends after its quiet time
            reads.append(self.pages.read_scroll(10))  # and the page scrolls back to the top for the next gesture
        self.saver.read(self.app)
        result = scroll_result(reads, hz, gestures)
        self.report.update(result, gestures=gestures)
        self.note(bench_tagged.summary_line(f"{SCROLL} frame_interval_ms", result["frame_interval_ms"], width=36))
        self.note(f"{SCROLL}: {result['frames']} frames at {hz:g} Hz ({source}), fps {result['fps']}, dropped "
                  f"{result['dropped_frames']}, wheel events {result['wheels_received']}/{result['wheels_sent']}"
                  + (f"; {result['error']}" if result.get("error") else ""))
        self.report["recorded"] = bench_tagged.record_series(
            self.app, f"bench-typing-{SCROLL}" + saver_suffix(self.args.energy_saver),
            {"frame_interval_ms": result["intervals_ms"], "after_frame_interval_ms": result["after_intervals_ms"]},
            engine="chromium", log=self.note)

    def run(self):
        try:
            return super().run()
        finally:
            self.pages.close()


def runner(args):
    """The run of args.surface (one combination)."""
    return {COMPOSER: ComposerRun, SCROLL: ScrollRun}.get(args.surface, Launched)(args)


def run_all(args, rows):
    """Every combination of `rows` (``plan``), one launch each; a failed one is recorded and the rest still run. Prints
    and writes (DIR/d8.json) the D8 verdicts."""
    reports = {}
    for row in rows:
        print(f"== {row['surface']} energy saver {row['energy_saver']}: {row['command']}", flush=True)
        one = argparse.Namespace(**{**vars(args), "surface": row["surface"], "energy_saver": row["energy_saver"],
                                    "out": row["out"]})
        run = None
        try:
            run = runner(one)
            run.run()
            report = run.report
        except SystemExit as error:  # LaunchError included: one combination's failure; the others still run
            report = {**(run.report if run else {}), "error": str(error.code)[:500]}
            print(f"== {row['surface']} energy saver {row['energy_saver']} failed: {error.code}", flush=True)
        reports[(row["surface"], row["energy_saver"])] = report
    verdicts = d8_verdicts(reports)
    for surface, verdict in verdicts.items():
        print("BENCH-TYPING-D8 " + json.dumps({"surface": surface, **verdict}), flush=True)
    path = os.path.join(default_out(args), "d8.json")
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump({"runs": {f"{s}{saver_suffix(v)}": r for (s, v), r in reports.items()}, "d8": verdicts}, f,
                  indent=1, default=str)
    print(f"== d8 {path}", flush=True)
    return 0


def parse_list(parser, text, choices, flag):
    """The comma list `text` of --`flag` (each one of `choices`, repeats dropped), or a parser error."""
    values = list(dict.fromkeys(v.strip() for v in text.split(",") if v.strip()))
    unknown = [v for v in values if v not in choices]
    if unknown or not values:
        parser.error(f"--{flag} takes a comma list of {', '.join(choices)}; got {text!r}")
    return values


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--tag", help="launch today's tagged build (bench_launch.py) and type through debug.key")
    parser.add_argument("--app", help="the tag's bundle (default $NX_APP, else its DerivedData build)")
    parser.add_argument("--out", help="launched mode: artifacts folder (default artifacts/bench-typing/TAG)")
    parser.add_argument("--flood", type=int, default=0, help="launched mode: N flooding terminals in the measured workspace")
    parser.add_argument("--flood-mbps", type=float, default=10.0, help="each flooder's rate in MB/s")
    parser.add_argument("--stress", action="store_true", help="launched mode: build the STRESS session first")
    parser.add_argument("--story", help="launched mode: result-v1 story (default bench-typing-flood-N, -stress with --stress)")
    parser.add_argument("--pid", type=int)
    parser.add_argument("--window", type=int, help="CuaDriver window_id of the cmux window")
    parser.add_argument("--csv", type=Path)
    parser.add_argument("--samples", type=int, default=None)
    parser.add_argument("--warmup", type=int, default=None)
    parser.add_argument("--interval", type=float, default=None, help="seconds between keys")
    parser.add_argument("--keys", default="abcdefghijklmnopqrstuvwxyz")
    parser.add_argument("--driver", default=str(Path.home() / ".local/bin/cua-driver"))
    parser.add_argument("--analyze-only", action="store_true", help="summarize an existing CSV")
    parser.add_argument("--surface", default=TERMINAL,
                        help=f"launched mode: what is typed into or scrolled, a comma list of {', '.join(SURFACES)}")
    parser.add_argument("--energy-saver", default=None,
                        help="launched mode: on, off or on,off (energy.saver always/off, the energySaver feature on)")
    parser.add_argument("--scrolls", type=int, default=3, help=f"{SCROLL}: gestures, one record each")
    parser.add_argument("--scroll-seconds", type=float, default=2.0, help=f"{SCROLL}: seconds of each gesture")
    parser.add_argument("--scroll-px", type=float, default=24.0, help=f"{SCROLL}: pixels per wheel event")
    parser.add_argument("--hz", type=float, default=None,
                        help=f"{SCROLL}: the rate of the wheel events and of dropped frames (default the main display's)")
    parser.add_argument("--dry-run", action="store_true",
                        help="launched mode: print each combination's plan and launch nothing")
    args = parser.parse_args(argv)
    launched = bool(args.tag or args.app)
    args.surfaces = parse_list(parser, args.surface, SURFACES, "surface")
    args.savers = parse_list(parser, args.energy_saver, SAVER_STATES, "energy-saver") if args.energy_saver else []
    args.surface, args.energy_saver = args.surfaces[0], (args.savers or [None])[0]
    if not launched and (args.surfaces != [TERMINAL] or args.savers or args.dry_run):
        parser.error("--surface, --energy-saver and --dry-run need --tag or --app (launched mode)")
    if launched:
        if args.pid or args.window or args.csv or args.analyze_only:
            parser.error("--tag/--app launches its own app: no --pid, --window, --csv or --analyze-only")
        if args.flood < 0:
            parser.error("--flood takes N >= 0")
        if (args.flood or args.stress) and args.surfaces != [TERMINAL]:
            parser.error("--flood and --stress are terminal-only: --surface terminal")
        if args.scrolls < 1 or args.scroll_seconds <= 0 or args.scroll_px <= 0 or (args.hz is not None and args.hz <= 0):
            parser.error("--scrolls, --scroll-seconds, --scroll-px and --hz take positive values")
        args.samples = 120 if args.samples is None else args.samples
        args.warmup = 10 if args.warmup is None else args.warmup
        args.interval = 0.15 if args.interval is None else args.interval
    else:
        if args.flood or args.stress or args.story:
            parser.error("--flood, --stress and --story need --tag or --app (launched mode)")
        if args.csv is None or (not args.analyze_only and (args.pid is None or args.window is None)):
            parser.error("attached mode needs --csv, and --pid and --window unless --analyze-only")
        args.samples = 60 if args.samples is None else args.samples
        args.warmup = 5 if args.warmup is None else args.warmup
        args.interval = 0.3 if args.interval is None else args.interval
    args.launched = launched
    return args


def main(argv=None):
    args = parse_args(argv)
    if not args.launched:
        attached_main(args)
        return 0
    rows = plan(args)
    if args.dry_run:
        for row in rows:
            print("BENCH-TYPING-PLAN " + json.dumps(row), flush=True)
        return 0
    if len(rows) == 1:
        args.out = rows[0]["out"]
        return runner(args).run()
    return run_all(args, rows)


if __name__ == "__main__":
    sys.exit(main())
