#!/usr/bin/env python3
"""Motion timing from outside the app's main thread: xctrace Animation Hitches plus a Time Profiler of main, and a
ScreenCaptureKit frame timeline from a separate process (plans/cmux-next/chrome-parity/p03-rendering.md, task 007;
done checks DC2t and DC3).

The counting bench (motion-main-work.py, task 002) arms RenderStats and counts frame sets and layouts; its passes
are never timed. This bench times the same motion with no probe in the app: the same light session
(motion-main-work.build_light) and STRESS, and the same rows (motion_scenarios.py: each row's input and setup, each
timed step named for the row's phase, so the reports join by (scenario, step)). A timed pass sends only the inputs
themselves (`action.run`, `debug.mouse`; motion_scenarios.TIMED_METHODS), and never `debug.frames`,
`debug.window_record`, `debug.wakeups` or RenderStats. The timing comes from three sources:

  hitches      `xctrace record --template 'Animation Hitches' --attach APP` (one recording per scenario, its rounds
               inside it): the `hitches*` tables. The `hitches` rows of the app inside a step's settle window are
               its hitches (count, duration); the `hitches-updates` rows are the app's commits (duration, and how
               many took longer than one refresh period).
  main         the same recording's time-profile table: the app's main-thread samples that are not parked in the
               run loop, summed per refresh period over each step's motion window: main ms per spring frame. The
               numbers are whole samples: the report names the sample interval (the samples' weight), and DC2t
               (p99 <= 0.5 ms) is `not resolvable` when the interval is not under 0.5 ms. The default Time Profiler
               samples every 1 ms; `--template` takes a saved template with Animation Hitches and a high-frequency
               Time Profiler.
  capture      motion-capture-timeline.swift, compiled here and run as its own process for the whole session: the
               display's frame times from ScreenCaptureKit (`frame UPTIME_NS complete`, one per changed frame).

Dropped frames, Chrome's way: cc/metrics/frame_sequence_tracker.cc counts, per animation sequence, the frames
expected from the begin-frames against the frames presented, and cc/metrics/dropped_frame_counter.cc reports the
share dropped. Outside the app there are no begin-frames and no sequence end, only changed frames, so per motion
window `capture.dropped` is the refresh periods from its first changed frame to its last (the expected frames of
the span the motion drew) minus the changed frames delivered; a spring that rests before its nominal motion_s
then expects no frame after it rests. `capture.over_limit` is DC3's own form, the intervals between changed frames
over 1.5 refresh periods, with where they ended (`over_limit_at_ms`, from the motion's start). In STRESS the busy
terminals change pixels every 20 ms, so after a spring rests early the intervals show their pace: read the offsets
to tell. A step's motion window starts after its delay (the hover card's open delay, the band's close delay), when
nothing moves.

Every source is on CLOCK_UPTIME_RAW. xctrace's times (ns from its start) are first placed with the recording's
start date (the `--toc` summary) against the wall clock read with the recorder's start (as coarse as the date's
digits, up to 1 s), else with the recorder's start, then fixed by the app's `action.perform` signposts (the
recording adds the os_signpost instrument): every `action.run` sent while it records (untimed ones too) makes one
a little after its send. The coarse offset only bounds the search (2 s); the offset is the one that the most sends
agree on (each send's begin within 100 ms after it), the largest (send - begin) of those (a lower bound off by the
shortest send-to-perform latency). Fewer than 3 agreeing sends is a failing check (`clock aligned`): the windowed
numbers of that scenario are then not trusted.

The recording asks for the Time Profiler and os_signpost instruments on top of the template; when xctrace refuses
that (an instrument the template already has), it records with os_signpost only, then with the template alone, and
`driver.json` names the command used. A table the recording lacks is reported `unavailable`, never as 0; a table
with rows of which none parse (columns this script does not read) is `unavailable` with its columns and a failing
check, never 0.

Checks (exit 1 when one fails, after every number is written): `debug.wakeups` shows no live display link at idle
before the first scenario and after the last (`display_links`, DisplayClock's count, else the frame schedulers that
hold one; a live link means a frame client runs and the timed passes are not probe-free); the session is the shape
asked for (light: motion-main-work.build_light's check; STRESS: perf-stress-session.py's check with Chromium
selected; Chromium real); the virtual display is still up before each scenario (else the session stops: its frames
would come from another display); each scenario's steps leave the measured workspace's panes and tabs as they were,
the band closed and the hover card hidden; each scenario's clock is aligned; every exported table parses; each
`--tunable` reads back as asked.

Usage (a fleet GUI host with a console session; never Lawrence's Mac):
  motion-hitches.py --app "cmux DEV <tag>.app" --out DIR [--sessions light,stress] [--scenarios a,b] [--rounds 3]
                    [--vdisplay 120] [--vdisplay-hold S] [--template T] [--tunable motion.renderServer=on]
                    [--no-capture] [--keep-traces] [--json PATH]
  motion-hitches.py analyze DIR      recompute DIR/report.json from DIR's raw files (exports, driver.json, capture)
  motion-hitches.py --self-test      parsers, alignment, windows and the timed-pass discipline on fixtures
Fleet: nx-remote --needs gui --app-from-fleet cmux --tag T --ref SHA -- \\
         python3 scripts/cmux-next/motion-hitches.py --app "$NX_APP" --out "$NX_ARTIFACTS/motion-hitches" --vdisplay 120

Scenarios: motion_scenarios.py, the 13 DC2 rows (cmd-d, cmd-shift-d, cmd-w, zoom, new-column, close-last-column,
workspace-switch, sidebar-toggle, toggle-omnibar, band-reveal, window-zoom, hover-card, sidebar-reorder). The app
should be a Debug or bench build (the setup and the inputs use `debug.*`). Not a CI job (Lawrence 2026-10-23).
"""
import argparse, contextlib, importlib.util, io, json, os, platform, re, shutil, signal, statistics, subprocess, sys, tempfile, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import LaunchError  # noqa: E402  (a SystemExit subclass: a failed launch ends one session, not the run)

SCHEMA = "motion-hitches/v2"
SIGNPOST_SUBSYSTEM = "com.cmuxterm.app.next"
ALIGN_SIGNPOST = "action.perform"
TEMPLATE = "Animation Hitches"
# Instruments added to the template, tried in this order until xctrace starts.
EXTRA_INSTRUMENTS = (("Time Profiler", "os_signpost"), ("os_signpost",), ())
DROP_FACTOR = 1.5  # DC3: no capture interval over 1.5 refresh periods
DC2T_LIMIT_MS = 0.5  # DC2t: main ms per spring frame p99 <= 0.5 ms
ALIGN_BOUND_US = 2_000_000  # the coarse clock is within this of the true offset (a whole-second start date)
ALIGN_LATENCY_US = 100_000  # a send's action.perform begins within this after it
ALIGN_MIN = 3
IDLE_SETTLE_S = 3.0
RECORDER_ATTACH_S = 2.0  # xctrace printed "Starting recording"; its attach to the app settles before the first input
RECORDING_CAP_S = 600
EXPORT_TIMEOUT_S = 900
CAPTURE_READY_S = 30
VDISPLAY_MARGIN_S = 600


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


scenarios_lib = load("motion_scenarios", "motion_scenarios.py")
trace_lib = load("cmux_trace", "trace.py")  # xctrace recorder, table export and row parser, run-loop park classes
stress_lib = trace_lib.stress_lib
main_work = load("motion_main_work", "motion-main-work.py")  # the light session, --tunable, the switch target


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


class SendLog:
    """The session's rpc, logging each `action.run` (timed or not) with its send time on CLOCK_UPTIME_RAW: each one
    the app ran makes an `action.perform` signpost, which places the recording's clock (`align`)."""

    def __init__(self, rpc, clock=uptime_us):
        self.rpc, self.clock, self.rows = rpc, clock, []

    def __call__(self, method, params=None, timeout=60):
        sent = self.clock()
        reply = self.rpc(method, params, timeout)
        if method == "action.run":
            refused = isinstance(reply, dict) and bool(reply.get("error"))
            self.rows.append({"sent_us": sent, "action": (params or {}).get("action"), "ok": not refused})
        return reply

    def take(self):
        rows, self.rows = self.rows, []
        return rows


def run_steps(rpc, context, scenario, rows, clock=uptime_us, sleep=time.sleep):
    """One timed pass: each step's input, then its settle time. Appends {name, method, sent_us, delay_s, motion_s,
    settle_s, error} to `rows` as each step is sent (a raise leaves the steps sent so far), times on
    CLOCK_UPTIME_RAW."""
    timed = TimedRpc(rpc)
    for step in scenario.steps:
        delay, motion, settle = step.timing(context)
        method, params = step.request(context)
        sent = clock()
        row = {"name": step.name, "method": method, "sent_us": sent, "delay_s": delay, "motion_s": motion,
               "settle_s": settle, "error": None}
        rows.append(row)
        reply = timed(method, params, timeout=30)
        error = reply.get("error") if isinstance(reply, dict) else None
        row["error"] = str(error)[:200] if error else None
        sleep(settle)  # bench harness: the motion lands before the next input
    return rows


# ---------------------------------------------------------------- recording and export

class HitchRecorder(trace_lib.XcTrace):
    """`xctrace record --template T --attach PID` (trace.py's recorder: one SIGINT, bounded save), with `extra`
    instruments (Time Profiler for main, os_signpost for the clock) and its ktrace intermediates in a folder of
    this recording."""

    def __init__(self, out, pid, tmpdir, extra=EXTRA_INSTRUMENTS[0], cap_s=RECORDING_CAP_S, template=TEMPLATE):
        super().__init__(out, cap_s=cap_s)
        self.pid, self.tmpdir, self.extra, self.template = pid, tmpdir, tuple(extra), template

    def command(self):
        command = ["/usr/bin/env", f"TMPDIR={self.tmpdir}/", "xcrun", "xctrace", "record", "--template",
                   self.template, "--attach", str(self.pid), "--output", self.path, "--no-prompt",
                   "--time-limit", f"{int(self.cap_s)}s"]
        for instrument in self.extra:
            command += ["--instrument", instrument]
        return command


def start_recorder(folder, pid, tmpdir, template=TEMPLATE, make=HitchRecorder, log=note):
    """Starts the first recording xctrace accepts, trying EXTRA_INSTRUMENTS in order; raises the last error."""
    error = None
    for extra in EXTRA_INSTRUMENTS:
        recorder = make(folder, pid, tmpdir, extra=extra, template=template)
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
    """([(start_ns, duration_ns, pid or None)], columns seen, rows read) of one exported hitches table. Rows read
    with none parsed means columns this script does not read: the caller reports them, never a 0."""
    found, columns, read = [], set(), 0
    for row in trace_lib.xctrace_rows(path):
        read += 1
        if len(columns) < 64:
            columns.update(row)
        start, duration = first(row, START_KEYS), scalar(row.get("duration"))
        if isinstance(start, int) and isinstance(duration, int):
            found.append((start, duration, row_pid(row)))
    return found, sorted(columns), read


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


def coarse_offset(toc, recorder):
    """(offset_us, how) from the start date and the recorder's paired uptime and wall clock reads, else from the
    recorder's start; (None, "none") without either."""
    started_us, started_wall = recorder.get("started_us"), recorder.get("started_wall")
    date = toc.get("start_date")
    if date and started_us and started_wall:
        from datetime import datetime
        try:
            start_wall = datetime.fromisoformat(date.replace("Z", "+00:00")).timestamp()
            return started_us - (started_wall - start_wall) * 1e6, f"start date (about {start_date_precision_ms(date)} ms)"
        except ValueError:
            pass
    if started_us:
        return started_us, "recorder start (about 100 ms)"
    return None, "none"


def align(toc, recorder, begins_ns, sends_us):
    """(offset_us, how, aligned): uptime_us = xctrace_ns / 1000 + offset_us.

    Each send of `sends_us` (uptime us, every action.run the app ran during the recording) makes one
    `action.perform` begin a little after it, so (send - begin) is the offset less that send's latency. The
    coarse offset only bounds the pairs looked at (ALIGN_BOUND_US); the offset is the (send - begin) value that the
    most sends agree with (a pair within ALIGN_LATENCY_US below it), the largest one. Sends that follow another
    within ALIGN_LATENCY_US are left out: the begin of the one before could pair with them. `aligned` is false
    with fewer than ALIGN_MIN agreeing sends, and the offset is then the coarse one."""
    base, how = coarse_offset(toc, recorder)
    if base is None:
        return 0.0, "none", False
    ordered = sorted(sends_us)
    isolated = [s for i, s in enumerate(ordered) if i == 0 or s - ordered[i - 1] > ALIGN_LATENCY_US]
    begins_us = [b / 1000.0 for b in begins_ns]
    pairs = [[s - b for b in begins_us if abs(s - b - base) <= ALIGN_BOUND_US] for s in isolated]
    best = None
    for candidate in sorted({d for differences in pairs for d in differences}):
        agreeing = [max(d for d in differences if candidate - ALIGN_LATENCY_US <= d <= candidate)
                    for differences in pairs if any(candidate - ALIGN_LATENCY_US <= d <= candidate for d in differences)]
        if best is None or len(agreeing) >= len(best[1]):
            best = (candidate, agreeing)
    matched = len(best[1]) if best else 0
    if matched < ALIGN_MIN:
        return base, (f"{how}; clock not aligned: {matched} of {len(isolated)} sends matched an "
                      f"{ALIGN_SIGNPOST} begin ({len(begins_us)} begins)"), False
    offset, agreeing = best
    spread = offset - min(agreeing)
    return offset, (f"signposts ({matched} of {len(isolated)} sends matched; send-to-perform latency spread "
                    f"{spread / 1000:.2f} ms; coarse {how} off by {(offset - base) / 1000:.1f} ms)"), True


# ---------------------------------------------------------------- analysis

def windows(rounds, kind):
    """[(round, step, start_us, end_us)] for every step of every round that was sent. `settle`: [input, input +
    settle_s]; `motion`: [input + delay_s, input + delay_s + motion_s]."""
    spans = []
    for r in rounds:
        for s in r["steps"]:
            if s.get("error"):
                continue
            if kind == "settle":
                spans.append((r["round"], s["name"], s["sent_us"], s["sent_us"] + s["settle_s"] * 1e6))
            else:
                start = s["sent_us"] + (s.get("delay_s") or 0) * 1e6
                spans.append((r["round"], s["name"], start, start + s["motion_s"] * 1e6))
    return spans


def inside(t_us, spans):
    return next((span for span in spans if span[2] <= t_us < span[3]), None)


def main_per_frame(samples, offset_us, spans, refresh_ms):
    """Busy main ms per refresh period over each motion window (bins aligned to the motion's start), all windows
    pooled."""
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
    """Per motion window, the changed frames shown in it: the intervals (ms) between them, where (ms from the
    motion's start) each one over DROP_FACTOR refresh periods ended, and the dropped frames (Chrome's
    expected - presented over the span from the first changed frame to the last)."""
    intervals, over, dropped, expected = [], [], 0, 0
    period_us = refresh_ms * 1000.0
    for _, step, start, end in spans:
        shown = [t for t in frames_us if start <= t < end]
        if shown:
            wanted = int(round((shown[-1] - shown[0]) / period_us)) + 1
            expected += wanted
            dropped += max(0, wanted - len(shown))
        for before, after in zip(shown, shown[1:]):
            gap = (after - before) / 1000.0
            intervals.append(gap)
            if gap > DROP_FACTOR * refresh_ms:
                over.append({"step": step, "at_ms": round((after - start) / 1000.0, 1), "ms": round(gap, 2)})
    return intervals, over, dropped, expected


def unread(result, key, table, detail):
    """The table has rows and none parse: `unavailable` with why, never a 0, and a failing check."""
    result[key] = {"unavailable": f"the {table} table: {detail}"}
    result["unread"].append(table)


def analyze_scenario(folder, capture_frames, refresh_ms):
    driver = read_json(os.path.join(folder, "driver.json"), {}) or {}
    pid, rounds = driver.get("app_pid"), driver.get("rounds") or []
    result = {"rounds": len(rounds), "errors": [f"{s['name']}: {s['error']}" for r in rounds for s in r["steps"] if s.get("error")],
              "stopped": driver.get("stopped"), "unread": []}
    toc = trace_lib.parse_toc(os.path.join(folder, "xctrace-toc.xml"))
    result["schemas"] = toc["schemas"]
    signposts = os.path.join(folder, "xctrace-os-signpost.xml")
    begins = signpost_begins(signposts) if os.path.exists(signposts) else []
    sends = [s["sent_us"] for s in driver.get("sends") or [] if s.get("ok")]
    offset, how, aligned = align(toc, driver.get("recorder") or {}, begins, sends)
    result["clock"], result["clock_aligned"] = how, aligned
    settle, motion = windows(rounds, "settle"), windows(rounds, "motion")
    steps = sorted({w[1] for w in settle})

    hitches = os.path.join(folder, "xctrace-hitches.xml")
    if os.path.exists(hitches):
        rows, columns, read = interval_rows(hitches)
        if read and not rows:
            unread(result, "hitches", "hitches", f"{read} rows, none parsed; columns {columns}")
        else:
            # The recording attaches to the app: a row with no process column is the app's.
            mine = [(s / 1000.0 + offset, d / 1e6) for s, d, p in rows if p in (pid, None)]
            found = [(at, ms, inside(at, settle)) for at, ms in mine]
            found = [(at, ms, span) for at, ms, span in found if span]
            result["hitches"] = {"count": len(found), "duration_ms": pcts([ms for _, ms, _ in found]),
                                 "per_round": {str(r["round"]): sum(1 for _, _, span in found if span[0] == r["round"]) for r in rounds},
                                 "by_step": {name: sum(1 for _, _, span in found if span[1] == name) for name in steps},
                                 "rows_all_processes": len(rows), "rows_app": len(mine)}
    else:
        result["hitches"] = {"unavailable": "no hitches table in the recording"}

    updates = os.path.join(folder, "xctrace-hitches-updates.xml")
    if os.path.exists(updates):
        rows, columns, read = interval_rows(updates)
        if read and not rows:
            unread(result, "commits", "hitches-updates", f"{read} rows, none parsed; columns {columns}")
        else:
            commits = [d / 1e6 for s, d, p in rows if p in (pid, None) and inside(s / 1000.0 + offset, motion)]
            result["commits"] = {"duration_ms": pcts(commits), "over_refresh": sum(1 for c in commits if c > refresh_ms)}

    profile = os.path.join(folder, "xctrace-time-profile.xml")
    if os.path.exists(profile):
        samples = main_samples(profile, pid)
        if not samples:
            unread(result, "main_ms_per_frame", "time-profile", f"no main-thread sample of pid {pid}")
        else:
            interval_ms = statistics.median(w for _, w, _ in samples) / 1e6
            result["main_ms_per_frame"] = {**pcts(main_per_frame(samples, offset, motion, refresh_ms)),
                                           "sample_interval_ms": round(interval_ms, 3),
                                           "dc2t_resolvable": interval_ms < DC2T_LIMIT_MS}
    else:
        result["main_ms_per_frame"] = {"unavailable": "no time-profile table in the recording"}

    if driver.get("capture_alive") is False:
        result["capture"] = {"unavailable": "the capture recorder had ended before this scenario"}
    elif capture_frames is not None:
        intervals, over, dropped, expected = capture_intervals(capture_frames, motion, refresh_ms)
        result["capture"] = {"interval_ms": pcts(intervals), "over_limit": len(over), "over_limit_at_ms": over[:20],
                             "dropped": dropped, "expected": expected}
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
        display = entry.get("display_error")
        rows.append({"check": f"{session}: virtual display up for every scenario", "expected": "up",
                     "observed": display or "up", "ok": not display})
        for name, scenario in (entry.get("scenarios") or {}).items():
            if scenario.get("stopped"):
                rows.append({"check": f"{session} {name}: steps leave the workspace as it was", "expected": "unchanged",
                             "observed": scenario["stopped"], "ok": False})
            if scenario.get("rounds") and not scenario.get("clock_aligned"):
                rows.append({"check": f"{session} {name}: clock aligned", "expected": f">= {ALIGN_MIN} signposts",
                             "observed": scenario.get("clock"), "ok": False})
            for table in scenario.get("unread") or []:
                rows.append({"check": f"{session} {name}: {table} table read", "expected": "rows parsed",
                             "observed": "none parsed (columns in the report)", "ok": False})
    return rows


def fmt(stats, unit="ms"):
    if not isinstance(stats, dict) or not stats.get("n"):
        return (stats or {}).get("unavailable", "-") if isinstance(stats, dict) else "-"
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
            if "count" in h:
                steps = ", ".join(f"{step} {count}" for step, count in (h.get("by_step") or {}).items())
                print(f"  {name:<17} hitches {h['count']} ({steps}) duration {fmt(h.get('duration_ms'))}")
            else:
                print(f"  {name:<17} hitches unavailable: {h.get('unavailable')}")
            main = s.get("main_ms_per_frame") or {}
            resolution = ""
            if "sample_interval_ms" in main:
                resolution = f" (sample interval {main['sample_interval_ms']} ms" + (
                    ")" if main.get("dc2t_resolvable") else f": DC2t {DC2T_LIMIT_MS} ms not resolvable)")
            print(f"  {'':<17} main per frame {fmt(main)}{resolution}")
            c = s.get("capture")
            if c and "unavailable" in c:
                print(f"  {'':<17} capture unavailable: {c['unavailable']}")
            elif c:
                print(f"  {'':<17} capture interval {fmt(c.get('interval_ms'))} over {DROP_FACTOR}x: {c.get('over_limit')}; "
                      f"dropped {c.get('dropped')} of {c.get('expected')}")
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


def alive(process):
    return process is not None and process.poll() is None


def session_context(name, stress, rpc, entry, chromium_problems):
    """Builds the session `name` and returns its motion_scenarios.Context. The light session is
    motion-main-work.build_light (raises ShapeError on another shape); STRESS records a shape error in `entry` and
    is still timed. The switch target is motion-main-work's `neighbor`, as in the counting rows."""
    if name == "stress":
        summary = stress.build(check=False)
        try:
            stress_lib.Stress.check(summary)
        except stress_lib.StressShapeError as error:
            entry["shape_error"] = str(error)[:600]
        entry["shape"] = summary
        workspace = stress.measured
    else:
        _reply, problem = stress_lib.place_window(rpc)
        if problem:
            entry["shape_error"] = f"window placement: {problem}"
        entry["shape"] = main_work.build_light(stress, chromium_problems)
        workspace = entry["shape"]["measured"]
    pane = stress.panes(stress.workspace(workspace))[0]
    selected = next((t.get("id") for t in pane.get("tabs") or [] if t.get("selected")), None)
    chromium = next((tab for kind, tab, _ in stress.made.get(pane["id"], []) if kind == "chromium" and tab), None)
    other = main_work.neighbor([w.get("id") for w in stress.workspaces()], workspace)
    entry["context"] = {"workspace": workspace, "pane": pane["id"], "default_tab": selected, "chromium_tab": chromium,
                        "other_workspace": other}
    return scenarios_lib.Context(rpc, workspace, pane["id"], selected, chromium, other,
                                 panes=lambda: stress.panes(stress.workspace(workspace)))


class Session:
    """One app launch, one session shape (light or stress), every scenario timed in it. `display_alive()` says
    whether the virtual display this run made is still up (always true without one)."""

    def __init__(self, opts, name, out, display_id, capture_binary, display_alive=lambda: True):
        self.opts, self.name, self.out, self.display_id = opts, name, out, display_id
        self.capture_binary = capture_binary  # None: no capture timeline (--no-capture, or it did not compile)
        self.display_alive = display_alive
        self.entry = {"scenario_order": []}
        self.capture = None

    def run(self):
        from bench_launch import BenchApp
        os.makedirs(self.out, exist_ok=True)
        if self.capture_binary:
            self.capture, error = start_capture(self.capture_binary, self.out, self.display_id, self.opts.capture_hold)
            if error:
                note(f"{self.name}: no capture timeline: {error}")
                with open(os.path.join(self.out, "capture.txt"), "a") as f:
                    f.write(f"error {error}\n")
        app = BenchApp(self.opts.app, out=self.out, env={"CMUX_NEXT_NO_ACTIVATE": None}, window=None, screen=None,
                       perf_session=self.name)
        try:
            app.launch()
            self.pid = app.process.pid
            self.sends = SendLog(lambda m, p=None, timeout=60: app.rpc(m, p, timeout))
            rpc = self.sends
            # STRESS with Chromium selected in every pane (p03-rendering.md DC2); the light session ignores it.
            stress = stress_lib.Stress(rpc, log=note, selected="chromium")
            try:
                self.entry["tunables"] = main_work.apply_tunables(app, self.opts.tunable)
                context = session_context(self.name, stress, rpc, self.entry,
                                          lambda: stress_lib.cef_problems(rpc("debug.cef"), stress_lib.WEB_DEV_CONFIG))
                self.entry["idle_links"] = {"before": idle_links(rpc)}
                self.time_all(context, stress, rpc)
                self.entry["idle_links"]["after"] = idle_links(rpc)
            finally:
                stress.close()
                main_work.reset_tunables(app, self.opts.tunable)
        finally:
            app.stop()
            stop_process(self.capture)
        return self.entry

    def time_all(self, context, stress, rpc):
        for scenario in scenarios_lib.select(self.opts.scenarios):
            if not self.display_alive():
                self.entry["display_error"] = f"the virtual display ended before {scenario.name}; the session stopped"
                note(f"{self.name}: {self.entry['display_error']}")
                return
            self.entry["scenario_order"].append(scenario.name)
            self.time_scenario(scenario, context, stress, rpc)

    def time_scenario(self, scenario, context, stress, rpc):
        """One recording of every round of `scenario`. A recorder or round failure stops this scenario only (it is
        its `stopped`); the next one runs."""
        folder = os.path.join(self.out, scenario.name)
        os.makedirs(folder, exist_ok=True)
        driver = {"app_pid": self.pid, "rounds": [], "stopped": None,
                  "capture_alive": alive(self.capture) if self.capture else None}
        tmp = tempfile.mkdtemp(prefix="motion-hitches-xctrace-")
        recorder = None
        try:
            recorder = start_recorder(folder, self.pid, tmp, template=self.opts.template)
            driver["recorder"] = {"started_us": recorder.started_us, "started_wall": recorder.started_wall,
                                  "command": recorder.command()}
            self.sends.take()
            time.sleep(RECORDER_ATTACH_S)  # bench harness: the recorder's attach settles before the first input
            for index in range(self.opts.rounds):
                driver["stopped"] = run_round(scenario, context, rpc, index + 1, driver["rounds"],
                                              lambda: workspace_shape(stress, context.workspace))
                if driver["stopped"]:
                    break
        except RuntimeError as error:  # the recorder did not start, or a stage of trace.py's recorder failed
            driver["stopped"] = f"{type(error).__name__}: {str(error)[:300]}"
        finally:
            driver["sends"] = self.sends.take()
            if recorder:
                recorder.stop()
            shutil.rmtree(tmp, ignore_errors=True)
            write_json(os.path.join(folder, "driver.json"), driver)
        exported = export_tables(folder) if recorder and os.path.exists(recorder.path) else []
        note(f"{scenario.name}: {len(driver['rounds'])} rounds, exported {exported}"
             + (f", stopped: {driver['stopped']}" if driver["stopped"] else ""))
        if recorder and not self.opts.keep_traces:
            shutil.rmtree(recorder.path, ignore_errors=True)


def run_round(scenario, context, rpc, number, rounds, shape, run=run_steps):
    """One round: the untimed prepare, the timed steps (appended to `rounds`), the untimed check, and the cleanup,
    which runs whenever the prepare started (a failed prepare, a raise in the steps, or a failed check too), so a
    stopped scenario leaves the session to the next one as it was. Returns why the scenario stops (a prepare,
    step, check or cleanup failure, a changed workspace), or None."""
    before = shape()
    stop = None
    try:
        if scenario.prepare:
            scenario.prepare(context)
        record = {"round": number, "steps": []}
        rounds.append(record)
        run(rpc, context, scenario, record["steps"])
        left = scenario.check(context) if scenario.check else None
        if left:
            stop = f"round {number}: {left}"
    except scenarios_lib.ScenarioError as error:
        stop = f"{'round ' + str(number) if rounds and rounds[-1]['round'] == number else 'prepare'}: {error}"
    except (TimedPassError, RuntimeError, OSError) as error:
        stop = f"round {number}: {type(error).__name__}: {str(error)[:200]}"
    finally:
        try:
            if scenario.cleanup:
                scenario.cleanup(context)
        except (RuntimeError, OSError) as error:
            stop = stop or f"cleanup: {error}"
    if stop:
        return stop
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


def vdisplay_hold(opts):
    """The virtual display's lifetime: --vdisplay-hold, else every session's capture hold and a margin."""
    return opts.vdisplay_hold or len(opts.sessions) * opts.capture_hold + VDISPLAY_MARGIN_S


def record(opts):
    os.makedirs(opts.out, exist_ok=True)
    from bench_launch import host_facts
    display = None
    display_line = None
    display_id = None
    report = {"schema": SCHEMA, "app": os.path.realpath(opts.app), "rounds": opts.rounds, "template": opts.template,
              "tunables_asked": dict(opts.tunable), "host": {**host_facts(), "chip": chip()}, "sessions": {}}
    for number in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(number, lambda signum, _frame: sys.exit(128 + signum))
    try:
        if opts.vdisplay:
            report["vdisplay_hold_s"] = vdisplay_hold(opts)
            display = stress_lib.start_vdisplay(opts.vdisplay, opts.out, report["vdisplay_hold_s"])
            display_line = next((l for l in open(os.path.join(opts.out, "vdisplay", "out")) if l.startswith("ready")), None)
            display_id = display_line.split()[1] if display_line else None
        report["refresh"] = refresh_of(display_line, opts.vdisplay)
        binary = None
        if not opts.no_capture:
            binary, error = compile_capture(opts.out)
            report["capture_build"] = error or "ok"
        write_json(os.path.join(opts.out, "run.json"), report)
        for name in opts.sessions:
            if display and not alive(display):
                report["sessions"][name] = {"scenario_order": [], "display_error": "the virtual display ended before the session"}
                continue
            session = Session(opts, name, os.path.join(opts.out, name), display_id, binary,
                              display_alive=(lambda: alive(display)) if display else (lambda: True))
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


def _begins(times_ns):
    return _xml("os-signpost", ["time", "event-type", "name", "subsystem"], [
        f'<event-time>{t}</event-time><event-type fmt="Begin">Begin</event-type>'
        f'<signpost-name fmt="{ALIGN_SIGNPOST}">{ALIGN_SIGNPOST}</signpost-name>'
        f'<subsystem fmt="{SIGNPOST_SUBSYSTEM}">{SIGNPOST_SUBSYSTEM}</subsystem>' for t in times_ns])


def _fixture(folder, pid=42, start_date_late_s=0.002, hitch_columns=("start", "duration", "process"), delay_s=0.0):
    """A recording of one scenario, 2 rounds of 2 steps: xctrace time 0 is uptime 10 s; sends at 11, 12, 13, 14 s,
    each with an untimed action 300 ms before it (the prepare). The start date is `start_date_late_s` late against
    the recorder's reads (with whole seconds when it is 1 s or more); the signposts fix it (300 us after each
    send)."""
    sends = [11e6 + k * 1e6 for k in range(4)]
    untimed = [s - 300_000 for s in sends]
    write_json(os.path.join(folder, "driver.json"), {
        "app_pid": pid, "stopped": None,
        "recorder": {"started_us": 10_000_000.0 + 3_000.0, "started_wall": 1_000_000.003},
        "sends": [{"sent_us": s, "action": "x", "ok": True} for s in sorted(sends + untimed)],
        "rounds": [{"round": r + 1, "steps": [{"name": n, "method": "action.run", "sent_us": sends[2 * r + i],
                                               "delay_s": delay_s, "settle_s": 1.0, "motion_s": 0.5, "error": None}
                                              for i, n in enumerate(("do", "undo"))]} for r in range(2)]})
    from datetime import datetime, timezone
    late = datetime.fromtimestamp(1_000_000.0 + start_date_late_s, tz=timezone.utc)
    date = late.isoformat(timespec="seconds" if start_date_late_s >= 1 else "milliseconds")
    open(os.path.join(folder, "xctrace-toc.xml"), "w").write(
        f'<?xml version="1.0"?><trace-toc><run number="1"><info><summary><start-date>{date}</start-date></summary></info>'
        '<data><table schema="hitches"/><table schema="hitches-updates"/><table schema="time-profile"/>'
        '<table schema="os-signpost"/></data></run></trace-toc>')
    open(os.path.join(folder, "xctrace-os-signpost.xml"), "w").write(
        _begins(sorted(int((s - 10e6) * 1000 + 300_000) for s in sends + untimed)))
    # Hitches: round 1 "do" at +100 ms (8 ms), round 2 "undo" at +900 ms (25 ms), one outside every window
    # (before the first send), one of another process.
    a, b, c = hitch_columns
    hitch = lambda t_ms, d_ms, p: f"<{a}>{int(t_ms * 1e6)}</{a}><{b}>{int(d_ms * 1e6)}</{b}>{PROCESS.format(p)}"  # noqa: E731
    open(os.path.join(folder, "xctrace-hitches.xml"), "w").write(_xml("hitches", hitch_columns, [
        hitch(1100, 8, pid), hitch(4900, 25, pid), hitch(500, 50, pid), hitch(1200, 30, 7)]))
    open(os.path.join(folder, "xctrace-hitches-updates.xml"), "w").write(_xml("hitches-updates", hitch_columns, [
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
        assert result["clock_aligned"] and result["clock"].startswith("signposts (8 of 8 sends matched"), result["clock"]
        h = result["hitches"]
        assert h["count"] == 2 and h["per_round"] == {"1": 1, "2": 1} and h["by_step"] == {"do": 1, "undo": 1}, h
        assert h["duration_ms"]["max"] == 25.0 and h["rows_all_processes"] == 4, h
        assert result["commits"]["over_refresh"] == 1, result["commits"]
        main = result["main_ms_per_frame"]
        assert main["max"] == 2.0 and main["n"] == 4 * 60, main  # 4 windows of 0.5 s at 8.33 ms, idle sample not busy
        assert main["sample_interval_ms"] == 1.0 and main["dc2t_resolvable"] is False, main
        capture = result["capture"]
        assert capture["over_limit"] == 1 and capture["over_limit_at_ms"][0]["ms"] == 20.0, capture
        assert (capture["dropped"], capture["expected"]) == (1, 32), capture  # 20 ms is 2.4 periods: one not shown
        assert result["unread"] == [] and not checks({"sessions": {"light": {"scenarios": {"x": result}}}})[4:], result


def check_unread_columns():
    """A hitches table whose columns are not read is unavailable with its columns and a failing check, never 0."""
    with tempfile.TemporaryDirectory() as folder:
        _fixture(folder, hitch_columns=("begin", "length", "process"))
        result = analyze_scenario(folder, None, 1000 / 120)
        assert "count" not in result["hitches"] and "begin" in result["hitches"]["unavailable"], result["hitches"]
        assert "unavailable" in result["commits"] and result["unread"] == ["hitches", "hitches-updates"], result
        rows = checks({"sessions": {"light": {"scenarios": {"x": result}}}})
        failing = [r["check"] for r in rows if not r["ok"] and " x: " in r["check"]]
        assert failing == ["light x: hitches table read", "light x: hitches-updates table read"], rows
        report = {"sessions": {"light": {"scenarios": {"x": result}}}, "checks": rows}
        printed = io.StringIO()
        with contextlib.redirect_stdout(printed):
            print_report(report)
        assert "hitches unavailable" in printed.getvalue() and "hitches 0" not in printed.getvalue(), printed.getvalue()


def check_align():
    """The signposts fix a whole-second start date; untimed sends right after another are left out; too few
    matches is not aligned."""
    with tempfile.TemporaryDirectory() as folder:
        _fixture(folder, start_date_late_s=1.0)
        result = analyze_scenario(folder, None, 1000 / 120)
        assert result["clock_aligned"], result["clock"]
        assert result["hitches"]["count"] == 2 and result["hitches"]["by_step"] == {"do": 1, "undo": 1}, result["hitches"]
    recorder = {"started_us": 10_003_000.0, "started_wall": 1_000_000.003}
    toc = {"start_date": "1970-01-12T13:46:40+00:00"}  # whole seconds: about 3 ms off here
    sends = [11e6, 11e6 + 2_000, 12e6, 13e6]  # the second follows the first by 2 ms
    begins = [int((s - 10e6) * 1000 + 400_000) for s in sends] + [int(2.5e9)]  # one begin of no send
    offset, how, aligned = align(toc, recorder, begins, sends)
    assert aligned and abs(offset - (10e6 - 400)) < 1 and how.startswith("signposts (3 of 3"), (offset, how)
    offset, how, aligned = align(toc, recorder, begins[:2], sends)
    assert not aligned and "clock not aligned: 1 of 3" in how and abs(offset - 10_000_000.0) < 1, (offset, how)
    offset, how, aligned = align({}, {"started_us": 5.0, "started_wall": 1.0}, [], [])
    assert offset == 5.0 and not aligned and how.startswith("recorder start"), (offset, how)
    assert align({}, {}, [], [])[2] is False
    rows = checks({"sessions": {"light": {"scenarios": {"zoom": {"rounds": 3, "clock_aligned": False, "clock": how}}}}})
    assert [r["check"] for r in rows if not r["ok"]][-1] == "light zoom: clock aligned", rows


def check_delay_window():
    """A delayed step's motion window starts after its delay: the pause before the fade is no dropped frame."""
    with tempfile.TemporaryDirectory() as folder:
        _fixture(folder, delay_s=0.5)
        hover = 11e6 + 5_000  # the tab's hover highlight at once
        fade = [11.5e6 + 1_000 + k * 8333 for k in range(20)]  # the card's fade after the 500 ms delay
        result = analyze_scenario(folder, [hover, *fade], 1000 / 120)
        assert result["capture"]["over_limit"] == 0 and result["capture"]["dropped"] == 0, result["capture"]
        spans = windows(read_json(os.path.join(folder, "driver.json"))["rounds"], "motion")
        assert spans[0][2] == 11.5e6 and spans[0][3] == 12e6, spans[0]
    step = scenarios_lib.SCENARIOS[[s.name for s in scenarios_lib.SCENARIOS].index("hover-card")].steps[0]
    context = scenarios_lib.Context(lambda *_a, **_k: {}, "w1", "p1", sleep=lambda _s: None)
    context.state["card_delay_s"] = 0.8
    assert step.timing(context) == (0.8, scenarios_lib.SPRING_MOTION_S, 0.8 + scenarios_lib.SPRING_SETTLE_S), step.timing(context)


class _FakeApp:
    """The app's topology for the timed-pass test: splits, new columns, closes."""

    def __init__(self):
        self.panes = [{"id": "p1", "column": 0, "tabs": [{"id": "t1", "kind": "browser", "selected": True}]},
                      {"id": "p2", "column": 1, "tabs": [{"id": "t2", "kind": "terminal", "selected": True}]}]
        self.made, self.sent, self.mouse = 0, [], []

    def rpc(self, method, params=None, timeout=30):
        self.sent.append(method)
        params = params or {}
        if method == "debug.mouse":
            self.mouse.append(params)
        if method == "debug.pane_chrome":
            return {"windows": [{"panes": [{"pane": "p1", "strip": [0, 0, 400, 30], "tab_slots": [[0, 100], [100, 100]]}],
                                 "window_controls": {"band_presence": 0}, "titlebar_buttons": {"pointer_inside": False}}]}
        if method == "debug.hover_cards":
            return {"card_showing": "false", "delay_ms": "500"}
        if method == "action.run":
            assert params.get("origin") == "script", params
            name, target = params["action"], params.get("target") or ""
            if name in ("splitRight", "splitDown", "newColumn"):
                self.made += 1
                column = max(p["column"] for p in self.panes) + 1
                self.panes.append({"id": f"n{self.made}", "column": column, "tabs": [{"id": f"nt{self.made}", "kind": "terminal"}]})
            elif name == "closePane":
                self.panes = [p for p in self.panes if f"pane:{p['id']}" != target]
            elif name == "closeTab":
                self.panes = [p for p in self.panes if not any(f"tab:{t['id']}" == target for t in p["tabs"])]
        return {}


def check_timed_pass_sends_only_inputs():
    """Every scenario's steps, run through a fake app, send only inputs and leave the panes as they were; a probe in
    a timed pass raises."""
    app = _FakeApp()
    context = scenarios_lib.Context(app.rpc, "w1", "p1", "t1", "c1", "w2", panes=lambda: app.panes, sleep=lambda _s: None)
    shape = lambda: sorted(p["id"] for p in app.panes)  # noqa: E731
    for scenario in scenarios_lib.SCENARIOS:
        rounds = []
        sent_before = len(app.sent)

        def run(rpc, ctx, sc, rows):
            mark = len(app.sent)
            run_steps(rpc, ctx, sc, rows, clock=lambda: 1e6, sleep=lambda _s: None)
            timed = set(app.sent[mark:])
            assert timed <= scenarios_lib.TIMED_METHODS and len(rows) == len(sc.steps), (sc.name, timed)
        stop = run_round(scenario, context, app.rpc, 1, rounds, shape, run=run)
        assert stop is None and len(rounds) == 1, (scenario.name, stop)
        assert len(app.sent) > sent_before
    assert app.made == 2 + 1 + 1 + scenarios_lib.STRIP_COLUMNS, app.made  # cmd-d, cmd-shift-d, cmd-w, new-column, columns
    # Every pointer step is a real move (a `leave` would leave the card and the band up); away is the pane's centre.
    assert app.mouse and all(m.get("action") == "move" for m in app.mouse), app.mouse
    assert {"action": "move", "pane": "p1"} in app.mouse and {"action": "move", "x": 90.0, "y": 12.0} in app.mouse, app.mouse
    try:
        TimedRpc(app.rpc)("debug.frames", {"action": "start"})
    except TimedPassError:
        pass
    else:
        raise AssertionError("a timed pass sent debug.frames")


def check_scenarios_cover_dc2():
    """The DC2/DC2t scenario list of p03-rendering.md section 5 (strip pan and scroll-to-row are counting-only)."""
    expected = {"cmd-d", "cmd-shift-d", "cmd-w", "zoom", "new-column", "close-last-column", "workspace-switch",
                "sidebar-toggle", "toggle-omnibar", "band-reveal", "window-zoom", "hover-card", "sidebar-reorder"}
    assert set(scenarios_lib.names()) == expected, scenarios_lib.names()
    assert [s.name for s in scenarios_lib.select("zoom,cmd-d")] == ["cmd-d", "zoom"]
    try:
        scenarios_lib.select("nope")
    except ValueError:
        pass
    else:
        raise AssertionError("an unknown scenario was accepted")
    for scenario in scenarios_lib.SCENARIOS:
        assert [s.name for s in scenario.steps] in (["do"], ["do", "undo"]), scenario.name
        assert all(s.method in scenarios_lib.TIMED_METHODS for s in scenario.steps), scenario.name


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
    assert [r["ok"] for r in rows] == [True, False, True, True, False], rows
    rows = checks({"sessions": {"stress": {"display_error": "the virtual display ended before zoom"}}})
    assert [r["check"] for r in rows if not r["ok"]][-1] == "stress: virtual display up for every scenario", rows


def check_recorder_command():
    recorder = HitchRecorder("/tmp/x", 42, "/tmp/scratch")
    command = recorder.command()
    assert command[:2] == ["/usr/bin/env", "TMPDIR=/tmp/scratch/"] and "Animation Hitches" in command, command
    assert command[command.index("--attach") + 1] == "42", command
    assert command[-4:] == ["--instrument", "Time Profiler", "--instrument", "os_signpost"], command
    custom = HitchRecorder("/tmp/x", 42, "/tmp/scratch", template="/t/high-frequency.tracetemplate").command()
    assert custom[custom.index("--template") + 1] == "/t/high-frequency.tracetemplate", custom

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
    """A round runs its cleanup even when the steps raise, the check fails or the prepare fails, and names what
    stops the scenario."""
    calls = []
    context = scenarios_lib.Context(lambda *_a, **_k: {}, "w1", "p1", sleep=lambda _s: None)
    run = lambda _rpc, _context, scenario, rows: rows.extend({"name": s.name} for s in scenario.steps)  # noqa: E731

    def make(left=None, cleanup_error=None, prepare=None):
        def cleanup(_context):
            calls.append("cleanup")
            if cleanup_error:
                raise scenarios_lib.ScenarioError(cleanup_error)
        return scenarios_lib.Scenario("band-reveal", scenarios_lib.SCENARIOS[3].steps,
                                      prepare=prepare or (lambda _c: calls.append("prepare")), check=lambda _c: left,
                                      cleanup=cleanup)

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
    calls.clear()
    stop = run_round(make(prepare=refuse), context, None, 5, rounds, lambda: "same", run=run)
    assert stop == "prepare: no Chromium tab" and len(rounds) == count and calls == ["cleanup"], (stop, calls)

    def raises(_rpc, _context, _scenario, rows):
        rows.append({"name": "do"})
        raise TimedPassError("debug.frames is not an input")

    calls.clear()
    stop = run_round(make(), context, None, 6, rounds, lambda: "same", run=raises)
    assert stop.startswith("round 6: TimedPassError") and calls == ["prepare", "cleanup"], (stop, calls)
    assert rounds[-1] == {"round": 6, "steps": [{"name": "do"}]}, rounds[-1]


def check_session_stops_without_display():
    """The session stops with a failing check when the virtual display ends; the scenarios before it stay."""
    up = iter([True, False])
    session = Session(argparse.Namespace(scenarios="zoom,sidebar-toggle"), "light", "/tmp/none", None, None,
                      display_alive=lambda: next(up))
    timed = []
    session.time_scenario = lambda scenario, *_a: timed.append(scenario.name)
    session.time_all(None, None, None)
    assert timed == ["zoom"] and session.entry["scenario_order"] == ["zoom"], timed
    assert "before sidebar-toggle" in session.entry["display_error"], session.entry
    opts = argparse.Namespace(vdisplay_hold=0, sessions=["light", "stress"], capture_hold=3600)
    assert vdisplay_hold(opts) == 2 * 3600 + VDISPLAY_MARGIN_S
    opts.vdisplay_hold = 900
    assert vdisplay_hold(opts) == 900


def check_send_log():
    replies = iter([{}, {"error": "refused"}, {}])
    log = SendLog(lambda *_a: next(replies), clock=iter([1.0, 2.0, 3.0]).__next__)
    log("action.run", {"action": "zoom"})
    log("action.run", {"action": "nope"})
    log("debug.mouse", {"action": "move"})
    assert log.take() == [{"sent_us": 1.0, "action": "zoom", "ok": True}, {"sent_us": 2.0, "action": "nope", "ok": False}]
    assert log.take() == []


def check_tunable_args():
    assert main_work.tunable_arg("motion.renderServer=on") == ("motion.renderServer", True)
    with contextlib.redirect_stderr(io.StringIO()):
        try:
            main(["--app", "none.app", "--tunable", "noequals"])
        except SystemExit as error:
            assert error.code == 2, error.code
        else:
            raise AssertionError("--tunable without = was accepted")


SELF_TESTS = [check_analysis, check_unread_columns, check_align, check_delay_window, check_timed_pass_sends_only_inputs,
              check_scenarios_cover_dc2, check_capture_and_checks, check_recorder_command, check_idle_links, check_round,
              check_session_stops_without_display, check_send_log, check_tunable_args]


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
    print(f"self-test passed ({len(SELF_TESTS)} of {len(SELF_TESTS)})")
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
    parser.add_argument("--vdisplay-hold", type=float, default=0,
                        help="the virtual display's lifetime (s; default: sessions x --capture-hold + 600)")
    parser.add_argument("--capture-hold", type=float, default=3600, help="the capture recorder's own lifetime per session (s)")
    parser.add_argument("--template", default=TEMPLATE,
                        help="the xctrace template: a name or a saved .tracetemplate (Animation Hitches with a "
                             "high-frequency Time Profiler resolves DC2t)")
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
