#!/usr/bin/env python3
"""Keystroke-to-frame latency for one cmux-next terminal, hop by hop.

Two ways to run it.

1. Launched (p05-ipc-005): today's tagged build through bench_launch.py, keys through `debug.key`:

  scripts/cmux-next/bench-typing.py --tag TAG [--app APP] [--flood N] [--stress] [--samples 120] [--out DIR]

   The app gets CMUX_NEXT_TYPING_PROBE (the CSV below) and CMUX_NEXT_TRACE_FLOWS (key-press flow marks of
   the daemon, its terminal hosts and the holder, cmux_flow_trace: `flows-<pid>.jsonl` in DIR/flows). The
   typed terminal runs `cat` (the tty echoes each key). --flood N puts N more terminals in the measured
   workspace, each writing 10 MB/s (--flood-mbps) of plain lines; the light layout is the typed pane and a
   column of N flood panes beside it, --stress builds the STRESS session (perf-stress-session.py, its busy
   terminals in the background workspaces) and types into the measured workspace's first pane while the
   next N panes' terminals flood. Phases: `single` (no flood output: the baseline) then `flood`.

   Per key, matched by the flow id the app minted (pid << 32 | probe row index) on the daemon's
   `daemon.send.write` hop, and the key's own timestamp (CLOCK_UPTIME_RAW, as every hop):
     key_to_daemon_write_ms   the daemon writes the key to the PTY
     key_to_daemon_echo_ms    the daemon hands the typed terminal's echo to its attach taps
                              (`daemon.output.attach` of that terminal: the echo, never a flooder's output)
     key_to_app_echo_ms       the app decoded output (probe `output_decoded_ms`)
     key_to_frame_ms          the first frame contents after that output was parsed (probe `contents_ms`)
   The probe's output and frame marks are not tied to a surface: under flood another terminal's output can
   take them. A key whose app decode is earlier than its daemon echo is therefore dropped from the app
   series and counted (`unscoped_dropped`); the daemon series are terminal-scoped by construction.
   Every series is p50/p95/p99/max; `ipc8` is the flood p95 minus the single p95 (IPC-8: <= 0.5 ms for the
   echo). report.json has the host, macOS and display Hz, the flooders' achieved MB/s, and each series is
   also a cmux-perf-result/v1 file (BenchApp.record).

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
    """p50/p95/p99/max of `values` (nearest rank); the original keys `median` and `min` stay for old readers."""
    stats = bench_tagged.distribution(values)
    if not stats:
        return None
    values = sorted(values)
    return {**stats, "median": stats["p50"], "min": round(values[0], 2)}


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


def match_keys(key_times_ns, writes, echoes, app_pid):
    """One entry per typed key that reached the daemon: its timestamp, the probe row index (from the flow id), the
    daemon write and the first echo of the same terminal before the next key. `key_times_ns` is sorted;
    `writes` are this app's `daemon.send.write` hops; `echoes` maps a terminal id to its sorted echo times."""
    matched = []
    for write in sorted(writes, key=lambda r: r["t_ns"]):
        flow = int(write.get("flow") or 0)
        if flow >> 32 != (app_pid & 0xFFFFFFFF):
            continue
        at = bisect.bisect_right(key_times_ns, write["t_ns"]) - 1
        if at < 0:
            continue
        key = key_times_ns[at]
        until = key_times_ns[at + 1] if at + 1 < len(key_times_ns) else float("inf")
        times = echoes.get(write.get("terminal"), [])
        i = bisect.bisect_right(times, write["t_ns"])
        echo = times[i] if i < len(times) and times[i] < until else None
        matched.append({"key_ns": key, "row": flow & 0xFFFFFFFF, "write_ns": write["t_ns"], "echo_ns": echo,
                        "terminal": write.get("terminal")})
    # A key is one write: keep the first write after each key (a return can be two).
    seen, out = set(), []
    for entry in matched:
        if entry["key_ns"] not in seen:
            seen.add(entry["key_ns"])
            out.append(entry)
    return out


def key_series(matched, probe_rows):
    """The four KEY_SERIES from matched keys and the probe's rows by index; and how many app samples were dropped
    because another terminal's output took the probe's output mark."""
    by_index = {int(r["index"]): r for r in probe_rows if r.get("index", "").isdigit()}
    series = {name: [] for name in KEY_SERIES}
    dropped = 0
    for entry in matched:
        key = entry["key_ns"]
        series["key_to_daemon_write_ms"].append((entry["write_ns"] - key) / 1e6)
        if entry["echo_ns"] is None:
            continue
        series["key_to_daemon_echo_ms"].append((entry["echo_ns"] - key) / 1e6)
        row = by_index.get(entry["row"])
        if not row or row.get("complete") != "1" or not row.get("output_decoded_ms"):
            continue
        decoded_ns = key + float(row["output_decoded_ms"]) * 1e6
        if decoded_ns < entry["echo_ns"]:
            dropped += 1  # the app marked output before the daemon sent this terminal's echo: another terminal's
            continue
        series["key_to_app_echo_ms"].append(float(row["output_decoded_ms"]))
        if row.get("contents_ms"):
            series["key_to_frame_ms"].append(float(row["contents_ms"]))
    return series, dropped


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
        """`count` keys through debug.key, each stamped with its send time; returns the stamps in ns."""
        keys = "abcdefghijklmnopqrstuvwxyz"
        stamps, trips, failed = [], [], 0
        for index in range(count):
            t0 = time.perf_counter()
            key = "return" if index % 40 == 39 else keys[index % len(keys)]
            stamp = time.clock_gettime(time.CLOCK_UPTIME_RAW)
            reply = self.rpc("debug.key", {"key": key, "timestamp": stamp}, timeout=10)
            stamps.append(int(stamp * 1e9))
            trips.append((time.perf_counter() - t0) * 1000)
            if isinstance(reply, dict) and reply.get("error"):
                failed += 1
                self.note(f"{label}: key {index}: {json.dumps(reply)[:160]}")
                if failed >= 10:
                    break
            rest = self.args.interval - (time.perf_counter() - t0)
            if rest > 0:
                time.sleep(rest)  # one key in flight at a time
        time.sleep(0.5)  # the last echo and frame land
        return stamps, trips

    def probe_rows(self):
        try:
            with open(self.probe) as handle:
                return list(csv.DictReader(handle))
        except OSError:
            return []

    def phase(self, name, pid):
        stamps, trips = self.type_keys(self.args.samples, name)
        time.sleep(0.3)  # the flow writer drains every 50 ms
        stamps_sorted = sorted(stamps)
        lo, hi = stamps_sorted[0], stamps_sorted[-1] + 2_000_000_000
        writes, dropped_a = read_flows(self.flows, lambda r: r.get("hop") == WRITE_HOP and lo <= r.get("t_ns", 0) <= hi)
        typed_terminals = {w.get("terminal") for w in writes if int(w.get("flow") or 0) >> 32 == (pid & 0xFFFFFFFF)}
        echo_records, _ = read_flows(self.flows, lambda r: r.get("hop") == ECHO_HOP and r.get("terminal") in typed_terminals
                                     and lo <= r.get("t_ns", 0) <= hi)
        echoes = {}
        for record in echo_records:
            echoes.setdefault(record.get("terminal"), []).append(record["t_ns"])
        for times in echoes.values():
            times.sort()
        matched = match_keys(stamps_sorted, writes, echoes, pid)
        series, unscoped = key_series(matched, self.probe_rows())
        entry = {"keys": len(stamps), "matched": len(matched), "typed_terminals": sorted(t for t in typed_terminals if t),
                 "unscoped_dropped": unscoped, "flow_records_dropped": dropped_a, "key_rpc_ms": summarize(trips),
                 "series": series, "stats": {k: summarize(v) for k, v in series.items()}}
        self.note(f"== {name}: keys {entry['keys']} matched {entry['matched']} unscoped dropped {unscoped}")
        for key, stats in entry["stats"].items():
            self.note(bench_tagged.summary_line(f"{name} {key}", stats, width=36))
        if not matched:
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
        story = f"bench-typing-flood-{self.args.flood}"
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
        if args.flood or args.stress:
            parser.error("--flood and --stress need --tag or --app (launched mode)")
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
