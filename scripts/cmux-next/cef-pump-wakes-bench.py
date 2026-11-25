#!/usr/bin/env python3
"""Why busy HIDDEN terminals wake the main thread through the Chromium message pump (HOT PATH AUDIT browser).

SWITCH FRAMES (STATUS 9946, cmux24) saw the CEF pump wake the main thread about 8, 74 and 104 times/s as busy hidden
terminals went 0, 8 and 24, with no browser tab. Each busy terminal there printed 20 lines/s with `echo ... $(date)`
and `sleep`, so each one also spawned 40 processes/s. This bench separates the causes:

  print   one long-lived process per terminal prints 20 lines/s (no process spawn)
  spawn   a shell loop spawns `/usr/bin/true` and `sleep` 20 times/s and prints nothing
  both    the SWITCH FRAMES loop (prints 20 lines/s and spawns 40 processes/s)

For each kind, one app launch (no browser tab is ever opened): N busy terminals in N workspaces (N = 0, 8, 24), a
quiet workspace shown, then a `--window` s measurement with no calls into the app: the wakeup ledger's CEFMessagePump
rows (`debug.wakeups`; bench and DEBUG builds name the requesting Chromium thread and immediate/delayed) and the pump's
counters (`debug.cef` pump: passes, work ms, requests).

`--trace`: the `both` launch (else the last kind's) also records a Chromium trace (`--trace-startup`, categories toplevel,ipc,mojom) and
prints, per window, the tasks run on Chromium's UI thread (cmux's main thread) by the code location that posted them.

Prints CEF-PUMP-WAKES lines and writes --json; exits 1 when no window was measured. Measures only: no gate. A DEBUG development build (reload.sh), because
extra Chromium switches are accepted only there.

  cef-pump-wakes-bench.py --app "<cmux DEV tag.app>" --out DIR [--kinds print,spawn,both] [--counts 0,8,24] [--trace]
"""
import argparse, collections, json, os, sys, time


def argparse_counts(value):
    try:
        counts = sorted({int(c) for c in value.split(",") if c.strip()})
    except ValueError:
        raise argparse.ArgumentTypeError("counts are whole numbers, comma separated (got %r)" % value)
    if not counts or counts[0] < 0:
        raise argparse.ArgumentTypeError("counts are whole numbers >= 0 (got %r)" % value)
    return counts


def argparse_kinds(value):
    kinds = list(dict.fromkeys(k for k in value.split(",") if k))  # each kind once
    unknown = [k for k in kinds if k not in ("print", "spawn", "both")]
    if unknown or not kinds:
        raise argparse.ArgumentTypeError("kinds are print, spawn, both (got %r)" % value)
    return kinds

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp, LaunchError  # noqa: E402

parser = argparse.ArgumentParser()
parser.add_argument("--app", required=True)
parser.add_argument("--out", required=True)
parser.add_argument("--json")
parser.add_argument("--kinds", default="print,spawn,both", type=lambda v: ",".join(argparse_kinds(v)))
parser.add_argument("--counts", default="0,8,24", type=lambda v: ",".join(str(c) for c in argparse_counts(v)))
parser.add_argument("--hz", type=float, default=20)
parser.add_argument("--window", type=float, default=20)
parser.add_argument("--settle", type=float, default=8)
parser.add_argument("--trace", action="store_true")
opts = parser.parse_args()
os.makedirs(opts.out, exist_ok=True)
PERIOD = 1.0 / opts.hz
LOOPS = {
    "print": "/usr/bin/python3 -I -c 'import time\nn=0\nwhile True:\n n+=1\n print(\"busy line\", n, flush=True)\n time.sleep(%s)'" % PERIOD,
    "spawn": "/bin/sh -c 'while :; do /usr/bin/true; sleep %s; done'" % PERIOD,
    "both": "/bin/sh -c 'i=0; while :; do i=$((i+1)); echo \"busy line $i $(date +%%s)\"; sleep %s; done'" % PERIOD,
}
RESULT = {"hz": opts.hz, "window_s": opts.window, "kinds": {}}


def uptime_us():
    return time.clock_gettime(time.CLOCK_UPTIME_RAW) * 1e6


def pump_rows(ledger):
    """CEFMessagePump ledger rows by reason: the cross-thread requests (each one main wake, by requesting thread) and
    the pump timer's own fires, kept apart (an admitted request is a wake and later also a timer fire)."""
    cross, timer = {}, {}
    for entry in (ledger or {}).get("ledger") or []:
        if isinstance(entry, dict) and entry.get("owner") == "CEFMessagePump":
            reason = entry.get("reason", "?")
            (cross if reason.startswith("cross-thread request") else timer)[reason] = entry.get("count", 0)
    return cross, timer


class ReplyError(RuntimeError):
    """A control call of a measured window failed: its numbers would read as a measurement, so the kind ends."""


def checked(reply, method, key):
    """`reply` when it has `key` and no error (BenchApp.rpc returns {"error": ..., "unreachable": True} on a failure)."""
    if not isinstance(reply, dict) or reply.get("error") or key not in reply:
        raise ReplyError("%s: %s" % (method, reply.get("error") if isinstance(reply, dict) else reply))
    return reply


def pump_counters(app):
    return checked(app.rpc("debug.cef"), "debug.cef", "pump")["pump"]


def new_workspace(app, name, command, focus):
    reply = app.rpc("action.run", {"action": "newTab", "args": {"name": name, "focus": focus, "command": command}})
    if isinstance(reply, dict) and reply.get("error"):
        raise RuntimeError("newTab %s: %s" % (name, reply["error"]))


def run_kind(kind):
    env = {}
    trace_file = None
    if opts.trace and kind == TRACE_KIND:
        trace_file = os.path.join(opts.out, "chromium-trace.json")
        counts = [int(c) for c in opts.counts.split(",")]
        duration = int(30 + len(counts) * (opts.settle + opts.window + 2 + max(counts) * 0.7))
        env["CMUX_NEXT_CEF_EXTRA_SWITCHES"] = ":".join([
            "trace-startup=toplevel,ipc,mojom", "trace-startup-file=" + trace_file, "trace-startup-format=json",
            "trace-startup-duration=%d" % duration, "trace-startup-record-mode=record-until-full",
            "trace-buffer-size-in-kb=400000"])
    app = BenchApp(opts.app, out=os.path.join(opts.out, kind), env=env)
    rows, windows = [], []
    try:
        app.launch()
        deadline = time.time() + 60
        while time.time() < deadline and (app.rpc("debug.cef") or {}).get("state") != "ready":
            time.sleep(0.5)  # test harness: Chromium starts once (its cmux pages)
        cef = app.rpc("debug.cef") or {}
        if cef.get("state") != "ready":
            # Without Chromium there is no pump: every window would read 0 wakes, which is not a finding.
            rows.append({"kind": kind, "error": "Chromium is not running (debug.cef state %r, trigger %r)" % (cef.get("state"), cef.get("trigger"))})
            print("CEF-PUMP-WAKES " + json.dumps(rows[-1]), flush=True)
            return  # the finally keeps this row in the report
        made = 0
        for count in sorted({int(c) for c in opts.counts.split(",")}):
            while made < count:
                made += 1
                new_workspace(app, "busy-%s-%d" % (kind, made), LOOPS[kind], True)
                time.sleep(0.5)  # test harness: the loop starts while its workspace shows
            new_workspace(app, "quiet-%s-%d" % (kind, count), "/bin/sh -c 'exec sleep 3600'", True)
            time.sleep(opts.settle)  # test harness: the switch settles before the window
            start = uptime_us()  # the ledger counts from its reset
            checked(app.rpc("debug.wakeups", {"reset": True}), "debug.wakeups reset", "ledger")
            before = pump_counters(app)
            time.sleep(opts.window)  # the measured window: no calls into the app
            after = pump_counters(app)
            ledger = checked(app.rpc("debug.wakeups", {}), "debug.wakeups", "ledger")
            end = uptime_us()  # the ledger counts from its reset to this read
            span = max((end - start) / 1e6, 1e-3)
            cross, timer = pump_rows(ledger)
            row = {"kind": kind, "busy_hidden": count, "build": "debug", "window_s": round(span, 2),
                   "cross_thread_wakes_per_s": round(sum(cross.values()) / span, 1),
                   "by_thread": {reason: round(n / span, 1) for reason, n in sorted(cross.items(), key=lambda kv: -kv[1])},
                   "timer_fires_per_s": {reason: round(n / span, 1) for reason, n in sorted(timer.items(), key=lambda kv: -kv[1])},
                   "pump_per_s": {k: round(((after.get(k) or 0) - (before.get(k) or 0)) / span, 2)
                                  for k in ("work_runs", "work_ms", "immediate_requests", "delayed_requests")}}
            rows.append(row)
            windows.append((count, start, end))
            print("CEF-PUMP-WAKES " + json.dumps(row), flush=True)
        if trace_file:
            # Chromium writes the trace when its duration ends; take it once its size holds across two looks.
            wait, last = time.time() + 300, -1
            while time.time() < wait:
                size = os.path.getsize(trace_file) if os.path.exists(trace_file) else 0
                if size > 0 and size == last:
                    break
                last = size
                time.sleep(3)  # test harness: waiting for Chromium's file
            try:
                RESULT.setdefault("trace", summarize_trace(trace_file, windows))
            except Exception as error:  # a malformed trace never costs the measured windows their report
                RESULT.setdefault("trace", {"error": "%s: %s" % (type(error).__name__, error)})
    except LaunchError as error:
        rows.append({"kind": kind, "error": error.reason})
        print("CEF-PUMP-WAKES " + json.dumps(rows[-1]), flush=True)
    except (RuntimeError, OSError) as error:  # a refused newTab, a failed control reply: this kind ends, the report is still written
        rows.append({"kind": kind, "error": "%s: %s" % (type(error).__name__, error)})
        print("CEF-PUMP-WAKES " + json.dumps(rows[-1]), flush=True)
    finally:
        RESULT["kinds"][kind] = rows  # every way out of the kind, an early return or a failed stop too
        app.stop()


def summarize_trace(path, windows):
    """Per window: the tasks run on CrBrowserMain (Chromium's UI thread, cmux's main thread), by posting location."""
    try:
        with open(path) as handle:
            doc = json.load(handle)
    except (OSError, ValueError) as error:
        return {"error": "%s: %s" % (type(error).__name__, error)}
    events = doc.get("traceEvents", doc) if isinstance(doc, dict) else doc
    names = {(e.get("pid"), e.get("tid")): (e.get("args") or {}).get("name") for e in events
             if e.get("ph") == "M" and e.get("name") == "thread_name"}
    out = {}
    main_ts = [e.get("ts") for e in events if isinstance(e.get("ts"), (int, float))
               and names.get((e.get("pid"), e.get("tid"))) == "CrBrowserMain"]
    if windows and main_ts and not any(windows[0][1] <= ts <= windows[-1][2] for ts in main_ts):
        # The trace's clock is not CLOCK_UPTIME_RAW microseconds: every window would read empty, which is not a finding.
        return {"error": "clock mismatch: no CrBrowserMain event inside the windows (trace %.0f..%.0f, windows %.0f..%.0f)"
                         % (min(main_ts), max(main_ts), windows[0][1], windows[-1][2])}
    for count, start, end in windows:
        seen = collections.Counter()
        for e in events:
            ts = e.get("ts")
            if e.get("ph") not in ("X", "B") or not isinstance(ts, (int, float)) or not start <= ts <= end:
                continue
            if names.get((e.get("pid"), e.get("tid"))) != "CrBrowserMain":
                continue
            args = e.get("args") or {}
            posted = (args.get("task") or {}).get("posted_from") or {}
            if isinstance(posted, dict):  # Perfetto's JSON export: {file_name, function_name}
                src_file, src = posted.get("file_name") or "", posted.get("function_name") or ""
            else:  # the legacy JSON exporter
                src_file, src = args.get("src_file") or "", args.get("src_func") or args.get("src") or str(posted or "")
            seen["%s %s %s" % (e.get("name"), src_file, src)] += 1
        span = max((end - start) / 1e6, 1e-3)
        out[str(count)] = [{"task": key, "per_s": round(n / span, 2)} for key, n in seen.most_common(15)]
        print("CEF-PUMP-WAKES-TRACE %d %s" % (count, json.dumps(out[str(count)])), flush=True)
    return out


KINDS = [k for k in opts.kinds.split(",") if k]
TRACE_KIND = "both" if "both" in KINDS else (KINDS[-1] if KINDS else None)  # --trace records the SWITCH FRAMES loop's launch
for kind in KINDS:
    run_kind(kind)
for path in filter(None, [os.path.join(opts.out, "cef-pump-wakes.json"), opts.json]):
    with open(path, "w") as handle:
        json.dump(RESULT, handle, indent=1)
print("CEF-PUMP-WAKES-REPORT " + json.dumps({k: [{x: r.get(x) for x in ("busy_hidden", "cross_thread_wakes_per_s", "error")} for r in v]
                                            for k, v in RESULT["kinds"].items()}), flush=True)
measured = [r for v in RESULT["kinds"].values() for r in v if "error" not in r]
sys.exit(0 if measured else 1)  # no window measured at all: a failed step, never a green one with no data
