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
"""

import argparse
import bisect
import csv
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
        self.out = os.path.abspath(args.out or os.path.join(bench_tagged.ROOT, "artifacts", "bench-typing",
                                                             args.tag or os.path.basename(bundle)))
        os.makedirs(self.out, exist_ok=True)
        self.probe = os.path.join(self.out, "typing.csv")
        self.flows = os.path.join(self.out, "flows")
        os.makedirs(self.flows, exist_ok=True)
        for stale in glob.glob(os.path.join(self.flows, "flows-*.jsonl")):
            os.unlink(stale)  # an earlier run's marks would match nothing, but cost the parse
        self.app = BenchApp(bundle, out=self.out, perf_session="stress" if args.stress else "light",
                            env={"CMUX_NEXT_TYPING_PROBE": self.probe, "CMUX_NEXT_TRACE_FLOWS": self.flows},
                            window=(40, 40, 1600, 1000))
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
        story = self.args.story or typing_report.flood_story(self.args.flood, self.args.stress)
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
    args = parser.parse_args(argv)
    launched = bool(args.tag or args.app)
    if launched:
        if args.pid or args.window or args.csv or args.analyze_only:
            parser.error("--tag/--app launches its own app: no --pid, --window, --csv or --analyze-only")
        if args.flood < 0:
            parser.error("--flood takes N >= 0")
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
    if args.launched:
        return Launched(args).run()
    attached_main(args)
    return 0


if __name__ == "__main__":
    sys.exit(main())
