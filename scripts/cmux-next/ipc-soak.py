#!/usr/bin/env python3
"""Output-ring sizing evidence (p05-ipc-116): ring resyncs per minute in STRESS with N flooding terminals and in a
light session with one terminal fed at 50 MB/s, the number app-daemon-connection-DESIGN.md section 4.2 asks for
before the 1 MiB ring capacity changes.

Two phases, each a fresh launch of the tagged app through bench_launch.py:

  stress  the STRESS session (perf-stress-session.py: 60 workspaces, the 14-pane measured grid, Chromium pages);
          then --flood N of the measured grid's shown terminals (the STRESS busy terminals first) each print at
          --flood-mb MB/s (default 10, the bench-typing --flood rate of p05-ipc-005).
  cat     one shown terminal of a light session prints at --cat-mb MB/s (default 50): a `cat` of a large file,
          paced so the rate is the same on every host.

The printer is this script (`ipc-soak.py flood`), started in the terminal by `terminal.sendText`: it writes 64 KiB
blocks of plain text lines to its tty at the asked rate and writes what it reached to a JSON file when it ends.

Every --sample seconds, for --minutes after a --warmup, it reads:

  * daemon: `server-stats {include:["ipc"]}` on the tag daemon's socket: `ring_resyncs`, `ring_laps` (p05-ipc-082),
    `ring_capacity` when reported; and the daemon's pid (a restart resets the counters and is a failed run);
  * app: `debug.daemon.wire` `outputBytesCopiedApp` (p05-ipc-004): output bytes the app copied. With the ring in use
    the floods copy nothing (IPC-7), so copies of more than 1% of the flood bytes mean the floods did not go
    through the ring, and the run says nothing about its size;
  * health: `system.ping` round trip on the app's control socket and whether the app still runs. A ping over
    --hang-ms (250, IPC-14's hang) is a hang.

A counter is read from the section's top level, else summed over the nested objects that have it (per connection or
per stream), so either layout of 082 and 004 reads the same total.

Verdict (report.json `capacity`), the design's rule "capacity changes only with the number":
  keep          both phases measured, 0 resyncs, the app healthy, every printer within 90% of its rate;
  raise         resyncs > 0 with a healthy app: the per-minute number is the reason to raise the capacity;
  inconclusive  a counter is missing, the floods did not go through the ring, the app hung, crashed or its daemon
                restarted, or (for keep) a printer stayed under 90% of its rate. The capacity does not change.

Writes report.json and prints `IPC-SOAK {json}` and the section 9 row (host, sha, macOS, Hz, command) to paste into
plans/cmux-next/app-daemon-connection-DESIGN.md. Exit 0 for keep or raise, 1 for inconclusive. Not a gate.

Needs a Mac with a GUI session (bench_launch.py) and, for the STRESS shape, a 1920 x 1200 display: --vdisplay 120.

  python3 scripts/cmux-next/ipc-soak.py --app "/path/cmux DEV <tag>.app" --minutes 10 --flood 10 [--vdisplay 120]
      [--phases stress,cat] [--out DIR] [--app-env KEY=VALUE ...]
  nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
      python3 scripts/cmux-next/ipc-soak.py --app "$NX_APP" --out "$NX_ARTIFACTS" --minutes 10 --flood 10 --vdisplay 120
"""
from __future__ import annotations

import argparse
import datetime as dt
import importlib.util
import json
import os
import shlex
import signal
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MB = 1_000_000
BLOCK = 64 * 1024
LINE = 80  # one printed line, newline included

# The counters read, and the task that adds each (plans/cmux-next/chrome-parity/p05-ipc.md).
DAEMON_RESYNCS = "ring_resyncs"    # server-stats --include ipc (p05-ipc-082)
DAEMON_LAPS = "ring_laps"          # server-stats --include ipc (p05-ipc-082)
DAEMON_CAPACITY = "ring_capacity"  # optional; the design's default when absent
APP_COPIED = "outputBytesCopiedApp"  # debug.daemon.wire (p05-ipc-004)
DESIGN_CAPACITY = "1 MiB"  # app-daemon-connection-DESIGN.md 4.2
RATE_FLOOR = 0.9  # a printer under 90% of its rate did not load the ring as asked
COPIED_CEILING = 0.01  # copies above 1% of the flood bytes: the floods did not use the ring
ETX = "\x03"  # Ctrl-C: ends the STRESS busy loop before a printer starts in its terminal


# The printer.

def flood_block():
    """BLOCK bytes of plain text lines (no escape sequences): what a `cat` of a log prints."""
    lines, number = [], 0
    while len(lines) * LINE < BLOCK:
        text = f"ipc-soak {number:08d} "
        lines.append((text + "abcdefghijklmnopqrstuvwxyz0123456789" * 3)[:LINE - 1] + "\n")
        number += 1
    return "".join(lines).encode()[:BLOCK]


def flood(rate, seconds, report, write=None, clock=time.monotonic, sleep=time.sleep, handle_signals=False):
    """Writes BLOCK-byte blocks at `rate` bytes/s for `seconds`, then writes {target, bytes, seconds, rate} as JSON to
    `report`. A blocking write (the terminal reads slower than the rate) delays the next block; the report says
    what was reached. With `handle_signals` (the CLI), SIGINT or SIGTERM ends it early, still reporting."""
    write = write or (lambda data: os.write(1, data))
    block = flood_block()
    stopped = []

    def stop(_signum, _frame):
        stopped.append(True)
    if handle_signals:
        for number in (signal.SIGINT, signal.SIGTERM):
            signal.signal(number, stop)
    start = clock()
    written = 0
    while not stopped:
        now = clock()
        if now - start >= seconds:
            break
        due = start + written / rate  # the time this block is due at the asked rate
        if due > now:
            sleep(min(due - now, start + seconds - now))
            continue
        written += write(block)
    elapsed = max(clock() - start, 1e-9)
    result = {"target_bytes_per_s": rate, "bytes": written, "seconds": round(elapsed, 3),
              "bytes_per_s": round(written / elapsed)}
    with open(report, "w") as handle:
        json.dump(result, handle)
    return result


def flood_command(python, script, rate, seconds, report):
    """The shell line that starts the printer in a terminal (sent with terminal.sendText)."""
    argv = [python, "-I", script, "flood", "--rate", str(int(rate)), "--seconds", str(int(seconds)), "--report", report]
    return " ".join(shlex.quote(part) for part in argv) + "\r"


# Counters.

def read_counter(section, name):
    """`name` at the top of `section`, else the sum over the nested objects (dicts, lists of dicts) that have it;
    None when nothing has it."""
    if isinstance(section, dict):
        value = section.get(name)
        if isinstance(value, (int, float)) and not isinstance(value, bool):
            return value
        children = list(section.values())
    elif isinstance(section, list):
        children = section
    else:
        return None
    found = [v for v in (read_counter(child, name) for child in children if isinstance(child, (dict, list)))
             if v is not None]
    return sum(found) if found else None


def daemon_reader(binary, tag, status=None, request=None):
    """A callable returning {pid, ipc} from the tag daemon (`server-stats {include:[ipc]}`), or {error}. The socket
    is looked up again after a failure (a restarted daemon has a new one)."""
    if status is None or request is None:
        sys.path.insert(0, HERE)
        from daemon_teardown import daemon_status, request as daemon_request
        status, request = status or daemon_status, request or daemon_request
    found = {}

    def read():
        try:
            if "socket" not in found:
                running = status(binary, tag)
                if not running:
                    return {"error": "no running daemon"}
                found["socket"] = running["socket"]
                found["pid"] = (request(found["socket"], {"id": 1, "cmd": "identify"}, 10).get("data") or {}).get("pid")
            reply = request(found["socket"], {"id": 2, "cmd": "server-stats", "include": ["ipc"]}, 10)
        except (OSError, ValueError, ConnectionError) as error:
            found.clear()
            return {"error": str(error)}
        if not reply.get("ok"):
            return {"error": str(reply.get("error"))[:200]}
        return {"pid": found.get("pid"), "ipc": (reply.get("data") or {}).get("ipc")}
    return read


def sample(rpc, daemon, alive, clock=time.monotonic):
    """One sample: the daemon's ring counters, the app's copied bytes, the ping round trip and liveness."""
    started = clock()
    ping = rpc("system.ping", timeout=10)
    ping_ms = None if isinstance(ping, dict) and ping.get("error") else round((clock() - started) * 1000, 2)
    stats = daemon()
    ipc = stats.get("ipc")
    wire = rpc("debug.daemon.wire", timeout=10)
    wire = None if not isinstance(wire, dict) or wire.get("error") else wire
    return {"t": round(clock(), 3), "alive": alive(), "ping_ms": ping_ms, "daemon_pid": stats.get("pid"),
            "daemon_error": stats.get("error"),
            "ring_resyncs": read_counter(ipc, DAEMON_RESYNCS), "ring_laps": read_counter(ipc, DAEMON_LAPS),
            "ring_capacity": read_counter(ipc, DAEMON_CAPACITY), "copied_bytes": read_counter(wire, APP_COPIED)}


def sample_for(seconds, every, take, clock=time.monotonic, sleep=time.sleep):
    """Samples from `take()` every `every` seconds for `seconds`, the first at once and the last at the end."""
    samples = [take()]
    end = samples[0]["t"] + seconds
    while samples[-1]["t"] < end and samples[-1]["alive"]:
        sleep(max(0.0, min(every, end - clock())))
        samples.append(take())
    return samples


# Verdicts.

def delta(samples, key):
    """Last minus first of `key`, or None when either is missing or the counter went back (a reset)."""
    first, last = samples[0].get(key), samples[-1].get(key)
    if first is None or last is None or last < first:
        return None
    return last - first


def per_minute(samples, key):
    """The increase of `key` in each whole minute after the first sample (the last partial minute included)."""
    if not samples or samples[0].get(key) is None:
        return []
    start, base, buckets = samples[0]["t"], samples[0][key], {}
    for row in samples[1:]:
        if row.get(key) is None:
            continue
        minute = int((row["t"] - start - 1e-9) // 60)
        buckets[minute] = row[key]
    out, previous = [], base
    for minute in range(max(buckets, default=-1) + 1):
        value = buckets.get(minute, previous)
        out.append(value - previous)
        previous = value
    return out


def phase_summary(name, samples, printers, hang_ms):
    """One phase's numbers and the reasons it cannot speak for the ring size. `printers` are the printers' reports
    (None for a printer that wrote none)."""
    minutes = (samples[-1]["t"] - samples[0]["t"]) / 60 if len(samples) > 1 else 0.0
    resyncs, laps, copied = delta(samples, "ring_resyncs"), delta(samples, "ring_laps"), delta(samples, "copied_bytes")
    pings = sorted(s["ping_ms"] for s in samples if s.get("ping_ms") is not None)
    hangs = sum(1 for s in samples if s.get("ping_ms") is None or s["ping_ms"] > hang_ms)
    pids = {s.get("daemon_pid") for s in samples if s.get("daemon_pid") is not None}
    flood_bytes = sum(p["bytes"] for p in printers if p)
    rates = [round(p["bytes_per_s"] / p["target_bytes_per_s"], 3) if p else 0.0 for p in printers]
    problems = []
    if resyncs is None:
        problems.append(f"no daemon {DAEMON_RESYNCS} (server-stats ipc, p05-ipc-082) or it went back")
    if copied is None:
        problems.append(f"no app {APP_COPIED} (debug.daemon.wire, p05-ipc-004): ring use not checked")
    elif flood_bytes and copied > COPIED_CEILING * flood_bytes:
        problems.append(f"the app copied {copied} of {flood_bytes} flood bytes: the floods did not go through the ring")
    if not all(s["alive"] for s in samples):
        problems.append("the app exited")
    if len(pids) > 1:
        problems.append(f"the daemon restarted (pids {sorted(pids)})")
    if hangs:
        problems.append(f"{hangs} pings over {hang_ms} ms or unanswered")
    if minutes <= 0:
        problems.append("no measured time")
    if not printers:
        problems.append("no printer ran")
    capacities = {s.get("ring_capacity") for s in samples if s.get("ring_capacity") is not None}
    return {"phase": name, "minutes": round(minutes, 2), "printers": len(printers),
            "ring_resyncs": resyncs, "ring_laps": laps,
            "resyncs_per_min": round(resyncs / minutes, 3) if resyncs is not None and minutes > 0 else None,
            "resyncs_by_minute": per_minute(samples, "ring_resyncs"),
            "ring_capacity": max(capacities) if capacities else None,
            "copied_bytes": copied, "flood_bytes": flood_bytes,
            "rate_reached": rates, "rates_ok": bool(rates) and min(rates) >= RATE_FLOOR,
            "ping_ms_max": pings[-1] if pings else None, "hangs": hangs, "problems": problems}


def capacity_verdict(phases):
    """keep / raise / inconclusive over the phases (module doc), with the reason."""
    problems = [f"{p['phase']}: {problem}" for p in phases for problem in p["problems"]]
    if problems:
        return {"capacity": "inconclusive", "reason": "; ".join(problems)}
    raised = [p for p in phases if p["ring_resyncs"]]
    if raised:
        worst = max(raised, key=lambda p: p["resyncs_per_min"])
        return {"capacity": "raise",
                "reason": f"{worst['resyncs_per_min']} ring resyncs/min in {worst['phase']} with a healthy app"}
    slow = [f"{p['phase']} printers reached {min(p['rate_reached'])} of their rate" for p in phases if not p["rates_ok"]]
    if slow:
        return {"capacity": "inconclusive", "reason": "; ".join(slow)}
    return {"capacity": "keep", "reason": "0 ring resyncs in every phase, app healthy, every printer at its rate"}


def cell(phase, rate_mb, count):
    if phase is None:
        return "not run"
    rate = f"{count} x {rate_mb:g} MB/s" if count > 1 else f"{rate_mb:g} MB/s"
    resyncs = "?" if phase["resyncs_per_min"] is None else phase["resyncs_per_min"]
    reached = min(phase["rate_reached"]) if phase["rate_reached"] else 0
    return (f"{rate}: {resyncs} ring resyncs/min over {phase['minutes']} min, laps {phase['ring_laps']}, "
            f"printers at >= {reached:.0%} of rate, ping max {phase['ping_ms_max']} ms")


def section9_row(date, host, sha, phases, verdict, opts, command):
    """The app-daemon-connection-DESIGN.md section 9 row: Date | Row | Host / sha / Hz | Light | STRESS | Note."""
    by_name = {p["phase"]: p for p in phases}
    capacity = next((p["ring_capacity"] for p in phases if p.get("ring_capacity")), None)
    where = (f"{host.get('chip') or '?'}, macOS {host.get('macos') or '?'} ({host.get('macos_build') or '?'}) / "
             f"{(sha or '?')[:11]} / {host.get('display_hz') or '?'} Hz")
    note = (f"capacity {capacity if capacity else DESIGN_CAPACITY}: {verdict['capacity']} ({verdict['reason']}); "
            f"`{command}`")
    return " | ".join(["", date, "p05-ipc-116 ring sizing", where,
                       cell(by_name.get("cat"), opts.cat_mb, 1),
                       cell(by_name.get("stress"), opts.flood_mb, opts.flood), note, ""]).strip()


# Phases (a Mac with a GUI session).

def load_module(name, file_name):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file_name))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def stress_terminals(stress, count):
    """`count` shown terminals of the measured grid: the STRESS busy terminals first, then the selected terminal of
    each further pane."""
    chosen = list(getattr(stress, "busy", []))[:count]
    for pane in stress.panes(stress.workspace(stress.measured)):
        if len(chosen) >= count:
            break
        tab = next((t for t in pane.get("tabs") or [] if t.get("kind") == "terminal" and t.get("selected")), None)
        if tab and tab["id"] not in chosen:
            chosen.append(tab["id"])
    return chosen


def light_terminal(stress):
    """The selected terminal of the focused workspace's first pane, once the app shows one."""
    def find():
        workspace = stress.workspace(stress.focused_workspace()) or (stress.workspaces() or [None])[0]
        for pane in stress.panes(workspace):
            tab = next((t for t in pane.get("tabs") or [] if t.get("kind") == "terminal" and t.get("selected")), None)
            if tab:
                return tab["id"]
        return None
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:  # bounded wait for the launch's first terminal
        found = find()
        if found:
            return found
        time.sleep(0.5)
    raise SystemExit("ipc-soak: the light session showed no terminal in 60 s")


def wait_reports(paths, seconds):
    """The printers' reports (None for one that wrote none in `seconds`)."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline and not all(os.path.exists(p) for p in paths):
        time.sleep(0.5)  # bounded wait for printers that end on their own
    reports = []
    for path in paths:
        try:
            with open(path) as handle:
                reports.append(json.load(handle))
        except (OSError, ValueError):
            reports.append(None)
    return reports


def run_phase(name, opts, bench, stress_module):
    out = os.path.join(opts.out, name)
    os.makedirs(out, exist_ok=True)
    app = bench.BenchApp(opts.app, out=out, env=dict(opts.app_env), perf_session="stress" if name == "stress" else "light")
    stress = stress_module.Stress(app.rpc)
    try:
        app.launch()
        if name == "stress":
            stress.build()
            terminals, rate = stress_terminals(stress, opts.flood), opts.flood_mb * MB
            if len(terminals) < opts.flood:
                raise SystemExit(f"ipc-soak: STRESS has {len(terminals)} shown terminals, not --flood {opts.flood}")
        else:
            terminals, rate = [light_terminal(stress)], opts.cat_mb * MB
        seconds = opts.warmup + opts.minutes * 60
        reports = []
        for index, tab in enumerate(terminals):
            report = os.path.join(out, f"printer-{index}.json")
            if os.path.exists(report):
                os.unlink(report)
            reports.append(report)
            stress.send(tab, ETX)
            stress.send(tab, flood_command(sys.executable, os.path.abspath(__file__), rate, seconds, report))
        time.sleep(opts.warmup)  # bench pacing: the printers reach their rate before the first sample
        binary = os.path.join(app.app, "Contents/Resources/bin/cmux-tui")
        daemon = daemon_reader(binary, app.tag)
        samples = sample_for(opts.minutes * 60, opts.sample,
                             lambda: sample(app.rpc, daemon, lambda: app.process.poll() is None))
        printers = wait_reports(reports, 60)
        with open(os.path.join(out, "samples.json"), "w") as handle:
            json.dump(samples, handle, indent=1)
        return phase_summary(name, samples, printers, opts.hang_ms)
    finally:
        app.stop()
        stress.close()  # the STRESS pages' local server


def soak(opts):
    sys.path.insert(0, HERE)
    import bench_launch as bench
    stress_module = load_module("perf_stress_session", "perf-stress-session.py")
    os.makedirs(opts.out, exist_ok=True)
    display = stress_module.start_vdisplay(opts.vdisplay, opts.out, opts.minutes * 60 * 3 + 1800) if opts.vdisplay else None
    try:
        try:
            host = bench.read_host()
        except bench.RecordError as error:
            host = {"error": str(error)}
        if opts.vdisplay:
            host["display_hz"] = opts.vdisplay
        try:
            sha = bench.build_sha(opts.app)
        except bench.RecordError:
            sha = None
        phases = [run_phase(name, opts, bench, stress_module) for name in opts.phases]
    finally:
        if display:
            display.terminate()  # the helper this script started, by its process
    verdict = capacity_verdict(phases)
    command = shown_command(opts.argv)
    row = section9_row(dt.datetime.now(dt.timezone.utc).date().isoformat(), host, sha, phases, verdict, opts, command)
    report = {"task": "p05-ipc-116", "host": host, "sha": sha, "phases": phases, **verdict, "section9_row": row}
    with open(os.path.join(opts.out, "report.json"), "w") as handle:
        json.dump(report, handle, indent=1)
    print("IPC-SOAK " + json.dumps(report), flush=True)
    print(row, flush=True)
    return 0 if verdict["capacity"] in ("keep", "raise") else 1


def shown_command(argv):
    """The command for the row: this host's --app and --out paths become $APP and $OUT."""
    shown, hidden = [], {"--app": "$APP", "--out": "$OUT"}
    for index, part in enumerate(argv):
        name = part.split("=", 1)[0]
        if index and argv[index - 1] in hidden:
            shown.append(hidden[argv[index - 1]])
        elif name in hidden and "=" in part:
            shown.append(f"{name}={hidden[name]}")
        else:
            shown.append(shlex.quote(part))
    return "python3 scripts/cmux-next/ipc-soak.py " + " ".join(shown)


def env_pair(text):
    key, sep, value = text.partition("=")
    if not sep or not key:
        raise argparse.ArgumentTypeError(f"expected KEY=VALUE, got {text!r}")
    return key, value


def parse(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True, help="a tagged `cmux DEV <tag>.app` (not running)")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS"), help="default: a new temporary folder")
    parser.add_argument("--minutes", type=float, default=10, help="measured minutes per phase")
    parser.add_argument("--flood", type=int, default=10, help="STRESS terminals that print at --flood-mb")
    parser.add_argument("--flood-mb", type=float, default=10)
    parser.add_argument("--cat-mb", type=float, default=50)
    parser.add_argument("--phases", type=lambda s: [p for p in s.split(",") if p], default=["stress", "cat"])
    parser.add_argument("--sample", type=float, default=5, help="seconds between samples")
    parser.add_argument("--warmup", type=float, default=10, help="seconds the printers run before the first sample")
    parser.add_argument("--hang-ms", type=float, default=250)
    parser.add_argument("--vdisplay", type=float, default=0, help="a 1920 x 1200 virtual main display at this Hz first")
    parser.add_argument("--app-env", type=env_pair, action="append", default=[], help="KEY=VALUE for the app")
    opts = parser.parse_args(argv)
    unknown = [p for p in opts.phases if p not in ("stress", "cat")]
    if unknown or not opts.phases:
        parser.error(f"--phases takes stress and cat, got {opts.phases}")
    if opts.flood < 1 or opts.minutes <= 0:
        parser.error("--flood and --minutes must be positive")
    opts.out = opts.out or tempfile.mkdtemp(prefix="ipc-soak-")
    opts.argv = list(argv)
    return opts


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["flood"]:
        parser = argparse.ArgumentParser(prog="ipc-soak.py flood")
        parser.add_argument("--rate", type=float, required=True, help="bytes per second")
        parser.add_argument("--seconds", type=float, required=True)
        parser.add_argument("--report", required=True)
        args = parser.parse_args(argv[1:])
        flood(args.rate, args.seconds, args.report, handle_signals=True)
        return 0
    return soak(parse(argv))


if __name__ == "__main__":
    raise SystemExit(main())
