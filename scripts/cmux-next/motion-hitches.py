#!/usr/bin/env python3
"""Motion timing from outside the app's main thread: xctrace Animation Hitches plus a Time Profiler of main, and a
ScreenCaptureKit frame timeline from a separate process (plans/cmux-next/chrome-parity/p03-rendering.md, task 007;
done checks DC2t and DC3).

The counting bench (motion-main-work.py, task 002) arms RenderStats and counts frame sets and layouts; its passes
are never timed. This bench times the same motion (motion_scenarios.py) with no probe in the app: a timed pass
sends only the inputs themselves (`debug.key`, `action.run`, `debug.mouse`; motion_scenarios.TIMED_METHODS), and
never `debug.frames`, `debug.window_record`, `debug.wakeups` or RenderStats. The timing comes from three sources:

  hitches      `xctrace record --template 'Animation Hitches' --attach APP` (one recording per scenario, its rounds
               inside it): the `hitches*` tables. The `hitches` rows of the app inside a step's settle window are
               its hitches (count, duration); the `hitches-updates` rows are the app's commits (duration, and how
               many took longer than one refresh period).
  main         the same recording's time-profile table: the app's main-thread samples that are not parked in the
               run loop, summed per refresh period over each step's motion window: main ms per spring frame.
  capture      motion-capture-timeline.swift, compiled here and run as its own process for the whole session: the
               display's frame times from ScreenCaptureKit (`frame UPTIME_NS complete`). Inside each step's motion
               window, the intervals between changed frames; an interval over 1.5 refresh periods is a frame the
               display did not show. In STRESS the busy terminals change pixels every 20 ms, so once a spring rests
               early the intervals show their pace: read `over_limit_at_ms` (offsets from the input) to tell.

Every source is on CLOCK_UPTIME_RAW. xctrace's times (ns from its start) are placed with the recording's start date
(the `--toc` summary) against the wall clock read with the recorder's start, then refined by the app's
`action.perform` signposts (the recording adds the os_signpost instrument): each key or action step makes one, a
few hundred microseconds after its send, so the offset is the largest (send - signpost) over at least 3 matched
steps (a lower bound off by the shortest send-to-perform latency). The report says which way was used.

The recording asks for the Time Profiler and os_signpost instruments on top of the template; when xctrace refuses
that (an instrument the template already has), it records with os_signpost only, then with the template alone, and
`driver.json` names the command used. A table the recording lacks is reported `unavailable`, never as 0.

Checks (exit 1 when one fails, after every number is written): `debug.wakeups` shows no live display link at idle
before the first scenario and after the last (`display_links`, DisplayClock's count, else the frame schedulers that
hold one; a live link means a frame client runs and the timed passes are not probe-free); the session is the shape
asked for (STRESS: perf-stress-session.py's check with Chromium selected; Chromium real); each scenario's pair leaves
the measured workspace's panes and tabs as they were (a refused split followed by Cmd-W closes a tab: that scenario
stops and says so), the band closed and the hover card hidden; each `--tunable` reads back as asked.

Usage (a fleet GUI host with a console session; never Lawrence's Mac):
  motion-hitches.py --app "cmux DEV <tag>.app" --out DIR [--sessions light,stress] [--scenarios a,b] [--rounds 3]
                    [--vdisplay 120] [--tunable motion.renderServer=on] [--no-capture] [--keep-traces] [--json PATH]
  motion-hitches.py analyze DIR      recompute DIR/report.json from DIR's raw files (exports, driver.json, capture)
  motion-hitches.py --self-test      parsers, alignment, windows and the timed-pass discipline on fixtures
Fleet: nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
         python3 scripts/cmux-next/motion-hitches.py --app "$NX_APP" --out "$NX_ARTIFACTS/motion-hitches" --vdisplay 120

Scenarios: motion_scenarios.py (cmd-d, cmd-shift-d, zoom, new-column, workspace-switch, sidebar-toggle,
toggle-omnibar, band-reveal, window-zoom, hover-card, sidebar-reorder: motion-main-work.py's row names, so the two
reports join). The app should be a Debug or bench build (the setup and the inputs use `debug.*`). Not a CI job
(Lawrence 2026-10-23).
"""
import argparse, contextlib, importlib.util, io, json, os, platform, re, shutil, signal, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import LaunchError  # noqa: E402  (a SystemExit subclass: a failed launch ends one session, not the run)

SCHEMA = "motion-hitches/v1"
SIGNPOST_SUBSYSTEM = "com.cmuxterm.app.next"
ALIGN_SIGNPOST = "action.perform"
# Instruments added to the template, tried in this order until xctrace starts.
EXTRA_INSTRUMENTS = (("Time Profiler", "os_signpost"), ("os_signpost",), ())
DROP_FACTOR = 1.5  # DC3: no capture interval over 1.5 refresh periods
IDLE_SETTLE_S = 3.0
RECORDER_ATTACH_S = 2.0  # xctrace printed "Starting recording"; its attach to the app settles before the first input
RECORDING_CAP_S = 600
EXPORT_TIMEOUT_S = 900
CAPTURE_READY_S = 30


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


scenarios_lib = load("motion_scenarios", "motion_scenarios.py")
trace_lib = load("cmux_trace", "trace.py")  # xctrace recorder, table export and row parser, run-loop park classes
stress_lib = trace_lib.stress_lib
main_work = load("motion_main_work", "motion-main-work.py")  # --tunable: its parser, set, read back and reset


def note(text):
    print(f"motion-hitches: {text}", flush=True)


def write_json(path, value):
    with open(path, "w") as f:
        json.dump(value, f, indent=1, default=str)


def read_json(path, default=None):
    try:
        with open(path) as f:
            return json.load(f)
    except (OSError, ValueError):
        return default


def uptime_us():
    return time.clock_gettime_ns(time.CLOCK_UPTIME_RAW) / 1000.0


def pcts(values):
    """{n, p50, p95, p99, max} (nearest rank), or {n: 0} with no values."""
    if not values:
        return {"n": 0}
    s = sorted(values)
    pick = lambda p: s[min(len(s) - 1, int(round((len(s) - 1) * p)))]  # noqa: E731
    return {"n": len(s), "p50": round(pick(0.5), 3), "p95": round(pick(0.95), 3), "p99": round(pick(0.99), 3),
            "max": round(s[-1], 3)}


# ---------------------------------------------------------------- the timed pass

class TimedPassError(RuntimeError):
    """A timed pass tried to send something other than an input."""


class TimedRpc:
    """The rpc a timed pass gets: only motion_scenarios.TIMED_METHODS go through; anything else raises before it
    reaches the app, so no probe can run in a timed window."""

    def __init__(self, rpc):
        self.rpc, self.sent = rpc, []

    def __call__(self, method, params=None, timeout=30):
        if method not in scenarios_lib.TIMED_METHODS:
            raise TimedPassError(f"{method} is not an input; a timed pass sends only {sorted(scenarios_lib.TIMED_METHODS)}")
        self.sent.append(method)
        return self.rpc(method, params, timeout)


def run_steps(rpc, context, scenario, clock=uptime_us, sleep=time.sleep):
    """One timed pair: each step's input, then its settle time. Returns [{name, method, sent_us, settle_s, motion_s,
    error}] with the send times on CLOCK_UPTIME_RAW."""
    timed = TimedRpc(rpc)
    rows = []
    for step in scenario.steps:
        sent = clock()
        method, params = step.request(context, sent / 1e6)
        reply = timed(method, params, timeout=30)
        error = reply.get("error") if isinstance(reply, dict) else None
        rows.append({"name": step.name, "method": method, "sent_us": sent, "settle_s": step.settle_s,
                     "motion_s": step.motion_s, "error": str(error)[:200] if error else None})
        sleep(step.settle_s)  # bench harness: the spring lands before the next input
    return rows


# ---------------------------------------------------------------- recording and export

class HitchRecorder(trace_lib.XcTrace):
    """`xctrace record --template 'Animation Hitches' --attach PID` (trace.py's recorder: one SIGINT, bounded save),
    with `extra` instruments (Time Profiler for main, os_signpost for the clock) and its ktrace intermediates in a
    folder of this recording."""

    def __init__(self, out, pid, tmpdir, extra=EXTRA_INSTRUMENTS[0], cap_s=RECORDING_CAP_S):
        super().__init__(out, cap_s=cap_s)
        self.pid, self.tmpdir, self.extra = pid, tmpdir, tuple(extra)

    def command(self):
        command = ["/usr/bin/env", f"TMPDIR={self.tmpdir}/", "xcrun", "xctrace", "record", "--template",
                   "Animation Hitches", "--attach", str(self.pid), "--output", self.path, "--no-prompt",
                   "--time-limit", f"{int(self.cap_s)}s"]
        for instrument in self.extra:
            command += ["--instrument", instrument]
        return command


def start_recorder(folder, pid, tmpdir, make=HitchRecorder, log=note):
    """Starts the first recording xctrace accepts, trying EXTRA_INSTRUMENTS in order; raises the last error."""
    error = None
    for extra in EXTRA_INSTRUMENTS:
        recorder = make(folder, pid, tmpdir, extra=extra)
        try:
            recorder.start()
            return recorder
        except RuntimeError as failure:
            error = failure
            log(f"the recording with {list(extra)} did not start ({str(failure)[:200]})")
    raise error


def wanted_schema(schema):
    return schema.startswith("hitches") or schema in ("time-profile", "os-signpost")


def export_tables(out, xctrace=("xcrun", "xctrace")):
    """Exports the recording's toc and the hitches, time-profile and os-signpost tables beside it; returns the
    schemas exported."""
    trace = os.path.join(out, "recording.trace")
    toc_path = os.path.join(out, "xctrace-toc.xml")
    trace_lib.export_file([*xctrace, "export", "--input", trace, "--toc"], toc_path, EXPORT_TIMEOUT_S, "toc", to_stdout=True)
    exported = []
    for schema in trace_lib.parse_toc(toc_path)["schemas"]:
        if not wanted_schema(schema):
            continue
        path = os.path.join(out, f"xctrace-{schema}.xml")
        if os.path.exists(path) or trace_lib.export_file(
                [*xctrace, "export", "--input", trace, "--xpath", f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]'],
                path, EXPORT_TIMEOUT_S, schema):
            exported.append(schema)
    return exported


# ---------------------------------------------------------------- parsing

def scalar(value):
    return trace_lib.scalar(value)


def first(row, keys):
    for key in keys:
        if row.get(key) is not None:
            return scalar(row.get(key))
    return None


def row_pid(row):
    for key in ("process", "thread"):
        value = row.get(key)
        if isinstance(value, dict) and value.get("pid") is not None:
            return value.get("pid")
    return None


START_KEYS = ("start", "start-time", "time", "event-time", "timestamp")


def interval_rows(path):
    """[(start_ns, duration_ns, pid or None)] of one exported hitches table, and the columns seen (a table whose
    columns are not the ones read here is named in the report instead of silently matching nothing)."""
    found, columns = [], set()
    for row in trace_lib.xctrace_rows(path):
        if len(columns) < 64:
            columns.update(row)
        start, duration = first(row, START_KEYS), scalar(row.get("duration"))
        if isinstance(start, int) and isinstance(duration, int):
            found.append((start, duration, row_pid(row)))
    return found, sorted(columns)


def signpost_begins(path, name=ALIGN_SIGNPOST):
    """Times (ns from the recording's start) of the cmux begin events named `name` in the os-signpost table."""
    times = []
    for row in trace_lib.xctrace_rows(path):
        if trace_lib.text(row.get("subsystem")) != SIGNPOST_SUBSYSTEM:
            continue
        if str(trace_lib.text(row.get("name") or row.get("signpost-name")) or "") != name:
            continue
        if not str(trace_lib.text(row.get("event-type")) or "").lower().startswith("begin"):
            continue
        t = first(row, ("time", "event-time", "start"))
        if isinstance(t, int):
            times.append(t)
    return sorted(times)


def main_samples(path, pid):
    """[(t_ns, weight_ns, busy)] of `pid`'s main thread: busy is false for a sample parked in the run loop."""
    out = []
    for t, weight, thread, frames in trace_lib.time_profile_samples(path):
        if thread.get("pid") != pid or not str(thread.get("name") or "").startswith("Main Thread"):
            continue
        out.append((t, weight, trace_lib.wait_class(frames) != "idle"))
    return out


def read_capture(path):
    """(ready line or None, error or None, [uptime_us of each changed frame])."""
    ready = error = None
    frames = []
    try:
        lines = open(path).read().splitlines()
    except OSError as failure:
        return None, f"no capture timeline: {failure}", []
    for line in lines:
        parts = line.split()
        if not parts:
            continue
        if parts[0] == "ready" and ready is None:
            ready = line
        elif parts[0] == "error" and error is None:
            error = line[len("error "):]
        elif parts[0] == "frame" and len(parts) >= 3 and parts[2] == "complete" and parts[1].isdigit():
            frames.append(int(parts[1]) / 1000.0)
    return ready, error, frames


# ---------------------------------------------------------------- the clock

def start_date_precision_ms(date):
    match = re.search(r"T\d\d:\d\d:\d\d(?:\.(\d+))?", date or "")
    digits = len(match.group(1)) if match and match.group(1) else 0
    return 10 ** (3 - min(digits, 3))


def align(toc, recorder, begins_ns, sends_us):
    """(offset_us, how): uptime_us = xctrace_ns / 1000 + offset_us. From the start date (with the recorder's
    paired uptime and wall clock reads), refined by the `action.perform` begins: each send (uptime us) of a key or
    action step is matched to the first begin within 50 ms of it on the start-date clock, and the offset is the
    largest (send - begin) over at least 3 matches. Without a start date: the recorder's start (about 100 ms)."""
    started_us, started_wall = recorder.get("started_us"), recorder.get("started_wall")
    base = how = None
    date = toc.get("start_date")
    if date and started_us and started_wall:
        from datetime import datetime
        try:
            start_wall = datetime.fromisoformat(date.replace("Z", "+00:00")).timestamp()
            base = started_us - (started_wall - start_wall) * 1e6
            how = f"start date (about {start_date_precision_ms(date)} ms)"
        except ValueError:
            base = None
    if base is None:
        if not started_us:
            return 0.0, "none"
        base, how = started_us, "recorder start (about 100 ms)"
    if start_date_precision_ms(date) > 10 or not begins_ns or not sends_us:
        return base, how
    begins_us = [b / 1000.0 for b in begins_ns]
    differences = []
    for send in sends_us:
        local = send - base
        match = next((b for b in begins_us if abs(b - local) <= 50_000), None)
        if match is not None:
            differences.append(send - match)
    if len(differences) < 3:
        return base, f"{how}; {len(differences)} of {len(sends_us)} sends matched a signpost"
    offset = max(differences)
    spread = offset - min(differences)
    return offset, f"signposts ({len(differences)} matched; send-to-perform latency spread {spread / 1000:.2f} ms)"


# ---------------------------------------------------------------- analysis

def windows(rounds, field):
    """[(round, step, start_us, end_us)] for every step of every round; the end is start + step[field] seconds."""
    return [(r["round"], s["name"], s["sent_us"], s["sent_us"] + s[field] * 1e6)
            for r in rounds for s in r["steps"] if not s.get("error")]


def inside(t_us, spans):
    return next((span for span in spans if span[2] <= t_us < span[3]), None)


def main_per_frame(samples, offset_us, spans, refresh_ms):
    """Busy main ms per refresh period over each motion window (bins aligned to the input), all windows pooled."""
    period_us = refresh_ms * 1000.0
    per_frame = []
    for _, _, start, end in spans:
        bins = [0.0] * max(1, int(round((end - start) / period_us)))
        for t, weight, busy in samples:
            at = t / 1000.0 + offset_us
            if busy and start <= at < end:
                bins[min(len(bins) - 1, int((at - start) // period_us))] += weight / 1e6
        per_frame += bins
    return per_frame


def capture_intervals(frames_us, spans, refresh_ms):
    """Intervals (ms) between changed frames inside each motion window, and where (ms from its input) each one over
    DROP_FACTOR refresh periods ended."""
    intervals, over = [], []
    for _, step, start, end in spans:
        shown = [t for t in frames_us if start <= t < end]
        for before, after in zip(shown, shown[1:]):
            gap = (after - before) / 1000.0
            intervals.append(gap)
            if gap > DROP_FACTOR * refresh_ms:
                over.append({"step": step, "at_ms": round((after - start) / 1000.0, 1), "ms": round(gap, 2)})
    return intervals, over


def analyze_scenario(folder, capture_frames, refresh_ms):
    driver = read_json(os.path.join(folder, "driver.json"), {}) or {}
    pid, rounds = driver.get("app_pid"), driver.get("rounds") or []
    result = {"rounds": len(rounds), "errors": [f"{s['name']}: {s['error']}" for r in rounds for s in r["steps"] if s.get("error")],
              "stopped": driver.get("stopped")}
    toc = trace_lib.parse_toc(os.path.join(folder, "xctrace-toc.xml"))
    result["schemas"] = toc["schemas"]
    signposts = os.path.join(folder, "xctrace-os-signpost.xml")
    begins = signpost_begins(signposts) if os.path.exists(signposts) else []
    sends = [s["sent_us"] for r in rounds for s in r["steps"] if s["method"] in ("debug.key", "action.run") and not s.get("error")]
    offset, how = align(toc, driver.get("recorder") or {}, begins, sends)
    result["clock"] = how
    settle, motion = windows(rounds, "settle_s"), windows(rounds, "motion_s")

    hitches = os.path.join(folder, "xctrace-hitches.xml")
    if os.path.exists(hitches):
        rows, columns = interval_rows(hitches)
        # The recording attaches to the app: a row with no process column is the app's.
        mine = [(s / 1000.0 + offset, d / 1e6) for s, d, p in rows if p in (pid, None)]
        found = [(at, ms, inside(at, settle)) for at, ms in mine]
        found = [(at, ms, span) for at, ms, span in found if span]
        result["hitches"] = {"count": len(found), "duration_ms": pcts([ms for _, ms, _ in found]),
                             "per_round": {str(r["round"]): sum(1 for _, _, span in found if span[0] == r["round"]) for r in rounds},
                             "by_step": {name: sum(1 for _, _, span in found if span[1] == name) for name in sorted({w[1] for w in settle})},
                             "rows_all_processes": len(rows), "rows_app": len(mine)}
        if not rows:
            result["hitches"]["columns"] = columns
    else:
        result["hitches"] = {"unavailable": "no hitches table in the recording"}

    updates = os.path.join(folder, "xctrace-hitches-updates.xml")
    if os.path.exists(updates):
        rows, _ = interval_rows(updates)
        commits = [d / 1e6 for s, d, p in rows if p in (pid, None) and inside(s / 1000.0 + offset, motion)]
        result["commits"] = {"duration_ms": pcts(commits), "over_refresh": sum(1 for c in commits if c > refresh_ms)}

    profile = os.path.join(folder, "xctrace-time-profile.xml")
    if os.path.exists(profile):
        per_frame = main_per_frame(main_samples(profile, pid), offset, motion, refresh_ms)
        result["main_ms_per_frame"] = pcts(per_frame)
    else:
        result["main_ms_per_frame"] = {"unavailable": "no time-profile table in the recording"}

    if capture_frames is not None:
        intervals, over = capture_intervals(capture_frames, motion, refresh_ms)
        result["capture"] = {"interval_ms": pcts(intervals), "over_limit": len(over), "over_limit_at_ms": over[:20]}
    return result


def analyze(out):
    """Recomputes OUT/report.json from the raw files of every session; returns the report."""
    report = read_json(os.path.join(out, "run.json"), {}) or {}
    refresh_ms = (report.get("refresh") or {}).get("ms") or 1000 / 120
    report["sessions"] = report.get("sessions") or {}
    for session, entry in report["sessions"].items():
        folder = os.path.join(out, session)
        ready, error, frames = read_capture(os.path.join(folder, "capture.txt"))
        entry["capture_source"] = {"ready": ready, "error": error, "frames": len(frames)}
        usable = frames if ready and not error else None
        entry["scenarios"] = {}
        for name in entry.get("scenario_order") or []:
            path = os.path.join(folder, name)
            if os.path.isdir(path):
                entry["scenarios"][name] = analyze_scenario(path, usable, refresh_ms)
    report["checks"] = checks(report)
    write_json(os.path.join(out, "report.json"), report)
    return report


def checks(report):
    rows = []
    for session, entry in (report.get("sessions") or {}).items():
        for when in ("before", "after"):
            idle = (entry.get("idle_links") or {}).get(when) or {}
            observed = idle.get("live_links")
            rows.append({"check": f"{session}: live display links at idle {when}", "expected": 0,
                         "observed": observed if observed is not None else idle.get("error", "unknown"),
                         "detail": idle.get("linked"), "ok": observed == 0})
        shape = entry.get("shape_error")
        rows.append({"check": f"{session}: session shape", "expected": "as asked", "observed": shape or "ok", "ok": not shape})
        for name, scenario in (entry.get("scenarios") or {}).items():
            if scenario.get("stopped"):
                rows.append({"check": f"{session} {name}: pair leaves the workspace as it was", "expected": "unchanged",
                             "observed": scenario["stopped"], "ok": False})
    return rows


def fmt(stats, unit="ms"):
    if not isinstance(stats, dict) or not stats.get("n"):
        return "-"
    return f"p50 {stats['p50']} p95 {stats['p95']} p99 {stats['p99']} max {stats['max']} {unit} (n {stats['n']})"


def print_report(report):
    host, refresh = report.get("host") or {}, report.get("refresh") or {}
    print(f"MOTION-HITCHES host {host.get('host')} ({host.get('chip')}) macOS {host.get('macos')} refresh {refresh.get('hz')} Hz "
          f"({refresh.get('ms')} ms, {refresh.get('source')})", flush=True)
    for session, entry in (report.get("sessions") or {}).items():
        print(f"== {session} (capture: {(entry.get('capture_source') or {}).get('error') or 'ok'}; "
              f"tunables {entry.get('tunables')})")
        for name, s in (entry.get("scenarios") or {}).items():
            h = s.get("hitches") or {}
            print(f"  {name:<17} hitches {h.get('count', h.get('unavailable'))} duration {fmt(h.get('duration_ms'))}")
            print(f"  {'':<17} main per frame {fmt(s.get('main_ms_per_frame'))}")
            if s.get("capture"):
                c = s["capture"]
                print(f"  {'':<17} capture interval {fmt(c.get('interval_ms'))} over {DROP_FACTOR}x: {c.get('over_limit')}")
            print(f"  {'':<17} clock: {s.get('clock')}" + (f"; errors {s['errors'][:2]}" if s.get("errors") else ""))
    for row in report.get("checks") or []:
        print(f"{'PASS' if row['ok'] else 'FAIL'} | {row['check']} | {row['expected']} | {row['observed']}", flush=True)


# ---------------------------------------------------------------- the live run

def idle_links(rpc, sleep=time.sleep):
    """After IDLE_SETTLE_S of no input: the live display links of `debug.wakeups`. `display_links` is DisplayClock's
    count (p03-rendering-010, one link per display); a build without it counts the frame schedulers that hold one.
    `linked` names the schedulers with a link either way."""
    sleep(IDLE_SETTLE_S)  # bench harness: nothing is sent, so anything still linked is idle work
    reply = rpc("debug.wakeups", None, timeout=30)
    if not isinstance(reply, dict) or reply.get("error"):
        return {"error": str((reply or {}).get("error") if isinstance(reply, dict) else reply)[:200]}
    linked = [s.get("name") for s in reply.get("frame_schedulers") or [] if s.get("has_link")]
    clock = reply.get("display_links")
    counted = isinstance(clock, int) and not isinstance(clock, bool)
    return {"live_links": clock if counted else len(linked), "source": "display_links" if counted else "frame_schedulers",
            "linked": linked, "active_frame_clients": reply.get("active_frame_clients")}


def workspace_shape(stress, workspace):
    return sorted((p.get("id"), tuple(sorted(t.get("id") for t in p.get("tabs") or []))) for p in stress.panes(stress.workspace(workspace)))


def compile_capture(out):
    """Compiles motion-capture-timeline once per run; returns (binary, error)."""
    binary = os.path.join(out, "bin", "motion-capture-timeline")
    os.makedirs(os.path.dirname(binary), exist_ok=True)
    try:
        build = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-O", os.path.join(HERE, "motion-capture-timeline.swift"),
                                "-o", binary], capture_output=True, text=True, timeout=600)
    except (OSError, subprocess.TimeoutExpired) as error:
        return None, f"motion-capture-timeline did not compile: {error}"
    if build.returncode:
        return None, f"motion-capture-timeline did not compile: {build.stderr[-400:]}"
    return binary, None


def start_capture(binary, out, display_id, hold_s):
    """Starts the capture recorder for one session (its own process); returns (process, error)."""
    path = os.path.join(out, "capture.txt")
    command = [binary, "--out", path, "--fps", "120", "--seconds", str(int(hold_s))]
    if display_id:
        command += ["--display", str(display_id)]
    with open(os.path.join(out, "capture.err"), "w") as err:
        process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=err)
    line = stress_lib.wait(lambda: next((l for l in open(path) if l.startswith(("ready", "error"))), None)
                           if os.path.exists(path) else None, CAPTURE_READY_S, step=0.25)
    if not line or line.startswith("error"):
        stop_process(process)
        return None, (line or "no ready line").strip()
    return process, None


def stop_process(process, timeout=15):
    if process and process.poll() is None:
        process.terminate()  # a process this script started
        try:
            process.wait(timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


class Session:
    """One app launch, one session shape (light or stress), every scenario timed in it."""

    def __init__(self, opts, name, out, display_id, capture_binary):
        self.opts, self.name, self.out, self.display_id = opts, name, out, display_id
        self.capture_binary = capture_binary  # None: no capture timeline (--no-capture, or it did not compile)
        self.entry = {"scenario_order": []}

    def run(self):
        from bench_launch import BenchApp
        os.makedirs(self.out, exist_ok=True)
        capture = None
        if self.capture_binary:
            capture, error = start_capture(self.capture_binary, self.out, self.display_id, self.opts.capture_hold)
            if error:
                note(f"{self.name}: no capture timeline: {error}")
                with open(os.path.join(self.out, "capture.txt"), "a") as f:
                    f.write(f"error {error}\n")
        app = BenchApp(self.opts.app, out=self.out, env={"CMUX_NEXT_NO_ACTIVATE": None}, window=None, screen=None,
                       perf_session=self.name)
        try:
            app.launch()
            self.pid = app.process.pid
            rpc = lambda m, p=None, timeout=60: app.rpc(m, p, timeout)  # noqa: E731
            # STRESS with Chromium selected in every pane (p03-rendering.md DC2); the light session ignores it.
            stress = stress_lib.Stress(rpc, log=note, selected="chromium")
            try:
                self.entry["tunables"] = main_work.apply_tunables(app, self.opts.tunable)
                context = self.build(stress, rpc)
                self.entry["idle_links"] = {"before": idle_links(rpc)}
                for scenario in scenarios_lib.select(self.opts.scenarios):
                    self.entry["scenario_order"].append(scenario.name)
                    self.time_scenario(scenario, context, stress, rpc)
                self.entry["idle_links"]["after"] = idle_links(rpc)
            finally:
                stress.close()
                main_work.reset_tunables(app, self.opts.tunable)
        finally:
            app.stop()
            stop_process(capture)
        return self.entry

    def build(self, stress, rpc):
        if self.name == "stress":
            summary = stress.build(check=False)
            try:
                stress_lib.Stress.check(summary)
            except stress_lib.StressShapeError as error:
                self.entry["shape_error"] = str(error)[:600]
            self.entry["shape"] = summary
            workspace = stress.measured
            other = (getattr(stress, "background", None) or [None])[-1]
        else:
            reply, problem = stress_lib.place_window(rpc)
            if problem:
                self.entry["shape_error"] = f"window placement: {problem}"
            other = (stress.build_background(count=1, chromium=0) or [None])[0]
            workspace, _ = stress.build_light()
            problems = stress_lib.cef_problems(rpc("debug.cef"), stress_lib.WEB_DEV_CONFIG)
            if problems:
                self.entry["shape_error"] = "; ".join(problems)[:600]
            self.entry["shape"] = {"workspace": workspace, "refusals": stress.refusals[:6]}
        pane = stress.panes(stress.workspace(workspace))[0]
        selected = next((t.get("id") for t in pane.get("tabs") or [] if t.get("selected")), None)
        chromium = next((tab for kind, tab, _ in stress.made.get(pane["id"], []) if kind == "chromium" and tab), None)
        self.entry["context"] = {"workspace": workspace, "pane": pane["id"], "default_tab": selected,
                                 "chromium_tab": chromium, "other_workspace": other}
        return scenarios_lib.Context(rpc, workspace, pane["id"], selected, chromium, other)

    def time_scenario(self, scenario, context, stress, rpc):
        folder = os.path.join(self.out, scenario.name)
        os.makedirs(folder, exist_ok=True)
        driver = {"app_pid": self.pid, "rounds": [], "stopped": None}
        tmp = tempfile.mkdtemp(prefix="motion-hitches-xctrace-")
        recorder = None
        try:
            recorder = start_recorder(folder, self.pid, tmp)
            driver["recorder"] = {"started_us": recorder.started_us, "started_wall": recorder.started_wall,
                                  "command": recorder.command()}
            time.sleep(RECORDER_ATTACH_S)  # bench harness: the recorder's attach settles before the first input
            for index in range(self.opts.rounds):
                driver["stopped"] = run_round(scenario, context, rpc, index + 1, driver["rounds"],
                                              lambda: workspace_shape(stress, context.workspace))
                if driver["stopped"]:
                    break
        finally:
            if recorder:
                recorder.stop()
            shutil.rmtree(tmp, ignore_errors=True)
            write_json(os.path.join(folder, "driver.json"), driver)
        exported = export_tables(folder) if os.path.exists(recorder.path) else []
        note(f"{scenario.name}: {len(driver['rounds'])} rounds, exported {exported}"
             + (f", stopped: {driver['stopped']}" if driver["stopped"] else ""))
        if not self.opts.keep_traces:
            shutil.rmtree(recorder.path, ignore_errors=True)


def run_round(scenario, context, rpc, number, rounds, shape, run=run_steps):
    """One round: the untimed prepare, the timed pair (appended to `rounds`), the untimed check and cleanup. Returns
    why the scenario stops (a prepare or cleanup error, what the pair left behind, a changed workspace), or None.
    The cleanup runs whenever the pair ran, so a stopped scenario leaves the session to the next one as it was."""
    try:
        if scenario.prepare:
            scenario.prepare(context)
    except scenarios_lib.ScenarioError as error:
        return f"prepare: {error}"
    before = shape()
    rounds.append({"round": number, "steps": run(rpc, context, scenario)})
    left = scenario.check(context) if scenario.check else None
    try:
        if scenario.cleanup:
            scenario.cleanup(context)
    except scenarios_lib.ScenarioError as error:
        return f"cleanup: {error}"
    if left:
        return f"round {number}: {left}"
    context.settle()
    if shape() != before:
        return f"round {number} changed the measured workspace's panes or tabs"
    return None


def refresh_of(display_line, hz):
    """{hz, ms, source}: the virtual display's measured interval, else the main display's mode, else the asked rate."""
    match = re.match(r"ready (\d+) ([\d.]+)", display_line or "")
    if match and float(match.group(2)) > 0:
        ms = float(match.group(2))
        return {"hz": round(1000 / ms), "ms": round(ms, 3), "source": "virtual display (measured)", "line": display_line.strip()}
    from bench_launch import main_display_hz
    measured = main_display_hz() or hz or 60
    return {"hz": measured, "ms": round(1000 / measured, 3), "source": "main display mode" if main_display_hz() else "asked"}


def chip():
    try:
        return subprocess.run(["/usr/sbin/sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True,
                              timeout=10).stdout.strip() or platform.machine()
    except (OSError, subprocess.TimeoutExpired):
        return platform.machine()


def record(opts):
    os.makedirs(opts.out, exist_ok=True)
    from bench_launch import host_facts
    display = None
    display_line = None
    display_id = None
    report = {"schema": SCHEMA, "app": os.path.realpath(opts.app), "rounds": opts.rounds,
              "tunables_asked": dict(opts.tunable), "host": {**host_facts(), "chip": chip()}, "sessions": {}}
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda signum, _frame: sys.exit(128 + signum))
    try:
        if opts.vdisplay:
            display = stress_lib.start_vdisplay(opts.vdisplay, opts.out, opts.capture_hold + 600)
            display_line = next((l for l in open(os.path.join(opts.out, "vdisplay", "out")) if l.startswith("ready")), None)
            display_id = display_line.split()[1] if display_line else None
        report["refresh"] = refresh_of(display_line, opts.vdisplay)
        binary = None
        if not opts.no_capture:
            binary, error = compile_capture(opts.out)
            report["capture_build"] = error or "ok"
        write_json(os.path.join(opts.out, "run.json"), report)
        for name in opts.sessions:
            session = Session(opts, name, os.path.join(opts.out, name), display_id, binary)
            try:
                session.run()
            except (stress_lib.StressShapeError, RuntimeError, LaunchError) as error:
                # The scenarios timed before the failure stay in the report; the session's shape check fails.
                session.entry["shape_error"] = f"{type(error).__name__}: {str(error)[:600]}"
            report["sessions"][name] = session.entry
            write_json(os.path.join(opts.out, "run.json"), report)
    finally:
        if display:
            display.terminate()  # the virtual display this script started
    return analyze(opts.out)


# ---------------------------------------------------------------- self-test

def _xml(schema, columns, rows):
    head = "".join(f"<col><mnemonic>{c}</mnemonic></col>" for c in columns)
    return (f'<?xml version="1.0"?><trace-query-result><node><schema name="{schema}">{head}</schema>'
            + "".join(f"<row>{r}</row>" for r in rows) + "</node></trace-query-result>")


PROCESS = '<process id="p{0}" fmt="cmux DEV ({0})"><pid id="q{0}">{0}</pid></process>'


def _fixture(folder, pid=42):
    """A recording of one scenario, 2 rounds of 2 steps: xctrace time 0 is uptime 10 s; sends at 11, 12, 13, 14 s."""
    write_json(os.path.join(folder, "driver.json"), {
        "app_pid": pid, "stopped": None,
        "recorder": {"started_us": 10_000_000.0 + 3_000.0, "started_wall": 1_000_000.003},
        "rounds": [{"round": r + 1, "steps": [{"name": n, "method": "debug.key", "sent_us": 11e6 + (2 * r + i) * 1e6,
                                               "settle_s": 1.0, "motion_s": 0.5, "error": None}
                                              for i, n in enumerate(("open", "close"))]} for r in range(2)]})
    # The start date is 2 ms late against the recorder's reads; the signposts fix it (300 us after each send).
    from datetime import datetime, timezone
    date = datetime.fromtimestamp(1_000_000.002, tz=timezone.utc).isoformat(timespec="milliseconds")
    open(os.path.join(folder, "xctrace-toc.xml"), "w").write(
        f'<?xml version="1.0"?><trace-toc><run number="1"><info><summary><start-date>{date}</start-date></summary></info>'
        '<data><table schema="hitches"/><table schema="hitches-updates"/><table schema="time-profile"/>'
        '<table schema="os-signpost"/></data></run></trace-toc>')
    begins = [f'<event-time>{int((1e6 + k * 1e6) * 1000 + 300_000)}</event-time><event-type fmt="Begin">Begin</event-type>'
              f'<signpost-name fmt="{ALIGN_SIGNPOST}">{ALIGN_SIGNPOST}</signpost-name>'
              f'<subsystem fmt="{SIGNPOST_SUBSYSTEM}">{SIGNPOST_SUBSYSTEM}</subsystem>' for k in range(4)]
    open(os.path.join(folder, "xctrace-os-signpost.xml"), "w").write(
        _xml("os-signpost", ["time", "event-type", "name", "subsystem"], begins))
    # Hitches: round 1 "open" at +100 ms (8 ms), round 2 "close" at +900 ms (25 ms), one outside every window
    # (before the first send), one of another process.
    hitch = lambda t_ms, d_ms, p: f"<start>{int(t_ms * 1e6)}</start><duration>{int(d_ms * 1e6)}</duration>{PROCESS.format(p)}"  # noqa: E731
    open(os.path.join(folder, "xctrace-hitches.xml"), "w").write(_xml("hitches", ["start", "duration", "process"], [
        hitch(1100, 8, pid), hitch(4900, 25, pid), hitch(500, 50, pid), hitch(1200, 30, 7)]))
    open(os.path.join(folder, "xctrace-hitches-updates.xml"), "w").write(_xml("hitches-updates", ["start", "duration", "process"], [
        hitch(1010, 4, pid), hitch(2010, 12, pid)]))
    # Main thread: two busy 1 ms samples in the first frame of the first step, one idle (run loop park) sample.
    thread = f'<thread id="t1" fmt="Main Thread 0x1 (cmux DEV, pid: {pid})"><tid>1</tid>{PROCESS.format(pid)}</thread>'

    def sample(t_ms, leaf, first_row=False):
        return (f"<sample-time>{int(t_ms * 1e6)}</sample-time>" + (thread if first_row else '<thread ref="t1"/>')
                + f'<weight>1000000</weight><backtrace><frame name="{leaf}"/><frame name="main"/></backtrace>')
    open(os.path.join(folder, "xctrace-time-profile.xml"), "w").write(_xml("time-profile", ["time", "thread", "weight", "stack"], [
        sample(1001, "layoutSubtree", first_row=True), sample(1002, "commit"), sample(1003, "__CFRunLoopServiceMachPort")]))


def check_analysis():
    with tempfile.TemporaryDirectory() as folder:
        _fixture(folder)
        frames = [11e6 + k * 8333 for k in range(30)] + [11e6 + 29 * 8333 + 20000]  # one 20 ms gap at the end
        result = analyze_scenario(folder, frames, 1000 / 120)
        assert result["clock"].startswith("signposts (4 matched"), result["clock"]
        h = result["hitches"]
        assert h["count"] == 2 and h["per_round"] == {"1": 1, "2": 1} and h["by_step"] == {"close": 1, "open": 1}, h
        assert h["duration_ms"]["max"] == 25.0 and h["rows_all_processes"] == 4, h
        assert result["commits"]["over_refresh"] == 1, result["commits"]
        main = result["main_ms_per_frame"]
        assert main["max"] == 2.0 and main["n"] == 4 * 60, main  # 4 windows of 0.5 s at 8.33 ms, idle sample not busy
        capture = result["capture"]
        assert capture["over_limit"] == 1 and capture["over_limit_at_ms"][0]["ms"] == 20.0, capture


def check_align_without_signposts():
    toc = {"start_date": "1970-01-12T13:46:40.002+00:00"}
    offset, how = align(toc, {"started_us": 10_003_000.0, "started_wall": 1_000_000.003}, [], [])
    assert abs(offset - 10_002_000.0) < 1 and how.startswith("start date (about 1 ms)"), (offset, how)
    offset, how = align({}, {"started_us": 5.0, "started_wall": 1.0}, [], [])
    assert offset == 5.0 and how.startswith("recorder start"), (offset, how)


def check_timed_pass_sends_only_inputs():
    """Every scenario's pair, run through a fake app, sends only inputs; a probe in a timed pass raises."""
    sent = []

    mouse = []

    def rpc(method, params=None, timeout=30):
        sent.append(method)
        if method == "debug.mouse":
            mouse.append(params)
        if method == "debug.pane_chrome":
            return {"windows": [{"panes": [{"pane": "p1", "strip": [0, 0, 400, 30], "tab_slots": [[0, 100], [100, 100]]}],
                                 "window_controls": {"band_presence": 0}, "titlebar_buttons": {"pointer_inside": False}}]}
        return {"card_showing": "false"} if method == "debug.hover_cards" else {}

    context = scenarios_lib.Context(rpc, "w1", "p1", "t1", "c1", "w2", sleep=lambda _s: None)
    for scenario in scenarios_lib.SCENARIOS:
        if scenario.prepare:
            scenario.prepare(context)
        sent.clear()
        rows = run_steps(rpc, context, scenario, clock=lambda: 1e6, sleep=lambda _s: None)
        assert set(sent) <= scenarios_lib.TIMED_METHODS and len(rows) == 2, (scenario.name, sent)
        assert scenario.check is None or scenario.check(context) is None, scenario.name
        if scenario.cleanup:
            scenario.cleanup(context)
    # Every pointer step is a real move (a `leave` would leave the card and the band up); away is the pane's centre.
    assert mouse and all(m.get("action") == "move" for m in mouse), mouse
    assert {"action": "move", "pane": "p1"} in mouse and {"action": "move", "x": 90.0, "y": 12.0} in mouse, mouse
    try:
        TimedRpc(rpc)("debug.frames", {"action": "start"})
    except TimedPassError:
        pass
    else:
        raise AssertionError("a timed pass sent debug.frames")


def check_scenarios_cover_dc2():
    """The DC2/DC2t scenario list of p03-rendering.md section 5 (strip pan and scroll-to-row are counting-only)."""
    expected = {"cmd-d", "cmd-shift-d", "zoom", "new-column", "workspace-switch", "sidebar-toggle", "toggle-omnibar",
                "band-reveal", "window-zoom", "hover-card", "sidebar-reorder"}
    assert set(scenarios_lib.names()) == expected, scenarios_lib.names()
    assert [s.name for s in scenarios_lib.select("zoom,cmd-d")] == ["cmd-d", "zoom"]
    try:
        scenarios_lib.select("nope")
    except ValueError:
        pass
    else:
        raise AssertionError("an unknown scenario was accepted")
    for scenario in scenarios_lib.SCENARIOS:
        assert len(scenario.steps) == 2 and all(s.method in scenarios_lib.TIMED_METHODS for s in scenario.steps), scenario.name


def check_capture_and_checks():
    with tempfile.TemporaryDirectory() as folder:
        path = os.path.join(folder, "capture.txt")
        open(path, "w").write("ready 7 480x300 120\nframe 1000000 complete\nframe 2000000 idle\nframe 3000000 complete\nend\n")
        ready, error, frames = read_capture(path)
        assert ready.startswith("ready 7") and error is None and frames == [1000.0, 3000.0], (ready, error, frames)
        open(path, "w").write("error ScreenCaptureKit: denied\n")
        assert read_capture(path)[1] == "ScreenCaptureKit: denied"
    rows = checks({"sessions": {"light": {"idle_links": {"before": {"live_links": 0}, "after": {"live_links": 1, "linked": ["w1"]}},
                                          "scenarios": {"zoom": {"stopped": "round 1 changed"}}}}})
    assert [r["ok"] for r in rows] == [True, False, True, False], rows


def check_recorder_command():
    recorder = HitchRecorder("/tmp/x", 42, "/tmp/scratch")
    command = recorder.command()
    assert command[:2] == ["/usr/bin/env", "TMPDIR=/tmp/scratch/"] and "Animation Hitches" in command, command
    assert command[command.index("--attach") + 1] == "42", command
    assert command[-4:] == ["--instrument", "Time Profiler", "--instrument", "os_signpost"], command

    class Refuses(HitchRecorder):
        def start(self, timeout=0, hold=None):
            if "Time Profiler" in self.extra:
                raise RuntimeError("xctrace record exited 2: instrument already in the template")
            self.started_us = 1.0

    logged = []
    started = start_recorder("/tmp/x", 42, "/tmp/scratch", make=Refuses, log=logged.append)
    assert started.extra == ("os_signpost",) and len(logged) == 1, (started.extra, logged)

    class Never(HitchRecorder):
        def start(self, timeout=0, hold=None):
            raise RuntimeError("no attach")

    try:
        start_recorder("/tmp/x", 42, "/tmp/scratch", make=Never, log=lambda _line: None)
    except RuntimeError:
        pass
    else:
        raise AssertionError("a recorder that never starts did not raise")


def check_idle_links():
    reply = {"frame_schedulers": [{"name": "w1", "has_link": True}, {"name": "main-work", "has_link": False}],
             "display_links": 0, "active_frame_clients": []}
    got = idle_links(lambda *_a, **_k: reply, sleep=lambda _s: None)
    assert (got["live_links"], got["source"], got["linked"]) == (0, "display_links", ["w1"]), got
    del reply["display_links"]
    got = idle_links(lambda *_a, **_k: reply, sleep=lambda _s: None)
    assert (got["live_links"], got["source"]) == (1, "frame_schedulers"), got
    got = idle_links(lambda *_a, **_k: {"error": "unknown method"}, sleep=lambda _s: None)
    assert got == {"error": "unknown method"}, got


def check_round():
    """A round runs its cleanup even when the pair left something behind, and names what stops the scenario."""
    calls = []
    context = scenarios_lib.Context(lambda *_a, **_k: {}, "w1", "p1", sleep=lambda _s: None)
    run = lambda _rpc, _context, scenario: [{"name": s.name} for s in scenario.steps]  # noqa: E731

    def make(left=None, cleanup_error=None):
        def cleanup(_context):
            calls.append("cleanup")
            if cleanup_error:
                raise scenarios_lib.ScenarioError(cleanup_error)
        return scenarios_lib.Scenario("band-reveal", scenarios_lib.SCENARIOS[0].steps,
                                      prepare=lambda _c: calls.append("prepare"), check=lambda _c: left, cleanup=cleanup)

    rounds = []
    assert run_round(make(), context, None, 1, rounds, lambda: "same", run=run) is None and len(rounds) == 1
    calls.clear()
    stop = run_round(make(left="the band did not close"), context, None, 2, rounds, lambda: "same", run=run)
    assert stop == "round 2: the band did not close" and calls == ["prepare", "cleanup"], (stop, calls)
    stop = run_round(make(cleanup_error="no sidebar"), context, None, 3, rounds, lambda: "same", run=run)
    assert stop == "cleanup: no sidebar", stop
    shapes = iter(["before", "after"])
    stop = run_round(make(), context, None, 4, rounds, lambda: next(shapes), run=run)
    assert stop == "round 4 changed the measured workspace's panes or tabs", stop

    def refuse(_context):
        raise scenarios_lib.ScenarioError("no Chromium tab")

    count = len(rounds)
    stop = run_round(scenarios_lib.Scenario("x", (), prepare=refuse), context, None, 5, rounds, lambda: "same", run=run)
    assert stop == "prepare: no Chromium tab" and len(rounds) == count, stop


def check_tunable_args():
    assert main_work.tunable_arg("motion.renderServer=on") == ("motion.renderServer", True)
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            main(["--app", "none.app", "--tunable", "noequals"])
        except SystemExit as error:
            assert error.code == 2, error.code
        else:
            raise AssertionError("--tunable without = was accepted")


SELF_TESTS = [check_analysis, check_align_without_signposts, check_timed_pass_sends_only_inputs, check_scenarios_cover_dc2,
              check_capture_and_checks, check_recorder_command, check_idle_links, check_round, check_tunable_args]


def self_test():
    failed = []
    for test in SELF_TESTS:
        try:
            test()
            print(f"ok   {test.__name__}")
        except Exception as error:  # noqa: BLE001 (each check reports its own failure)
            failed.append(test.__name__)
            print(f"FAIL {test.__name__}: {type(error).__name__}: {error}")
    if failed:
        print(f"self-test FAILED: {', '.join(failed)}")
        return 1
    print("self-test passed")
    return 0


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if argv[:1] == ["--self-test"]:
        return self_test()
    if argv[:1] == ["analyze"]:
        if len(argv) != 2:
            raise SystemExit("usage: motion-hitches.py analyze DIR")
        report = analyze(argv[1])
        print_report(report)
        return 0 if all(r["ok"] for r in report["checks"]) else 1
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True, help="a Debug or bench `cmux DEV <tag>.app` (not running)")
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS") or tempfile.mkdtemp(prefix="motion-hitches-"))
    parser.add_argument("--sessions", default="light,stress", type=lambda v: [s for s in v.split(",") if s])
    parser.add_argument("--scenarios", default="", help=f"comma list of {', '.join(scenarios_lib.names())} (default all)")
    parser.add_argument("--rounds", type=int, default=3)
    parser.add_argument("--vdisplay", type=float, default=0, help="a 1920x1200 virtual main display at this rate (Hz)")
    parser.add_argument("--capture-hold", type=float, default=3600, help="the capture recorder's own lifetime (s)")
    parser.add_argument("--no-capture", action="store_true", help="no ScreenCaptureKit timeline")
    parser.add_argument("--keep-traces", action="store_true", help="keep each .trace (about 90 MB per recorded second)")
    parser.add_argument("--tunable", type=main_work.tunable_arg, action="append", default=[], metavar="KEY=VALUE",
                        help="set over debug.tunables after each launch and read back, e.g. motion.renderServer=on")
    parser.add_argument("--json", help="also write the report here")
    opts = parser.parse_args(argv)
    unknown = [s for s in opts.sessions if s not in ("light", "stress")]
    if unknown:
        parser.error(f"unknown sessions {unknown}: light, stress")
    try:
        scenarios_lib.select(opts.scenarios)
    except ValueError as error:
        parser.error(str(error))
    report = record(opts)
    if opts.json:
        write_json(opts.json, report)
    print_report(report)
    return 0 if all(r["ok"] for r in report["checks"]) else 1


if __name__ == "__main__":
    sys.exit(main())
