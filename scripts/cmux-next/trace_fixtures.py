#!/usr/bin/env python3
"""Records the small real xctrace exports that trace.py's self-test parses (`check_real_xctrace_exports`).

Run it on a fleet Mac with Xcode (never on Lawrence's laptop). It compiles a tiny emitter, records it with
`xctrace record --launch` twice (Time Profiler with os_signpost; System Trace), exports the TOC and the three
tables trace.py reads (time-profile, os-signpost, syscall), strips personal data and writes them to
OUT/xcode-<major>/ with a fixture.json that says what the emitter did. Copy that folder into
scripts/cmux-next/tests/trace-fixtures/ to check it in.

The emitter is the shape trace.py must parse: 20 rounds of a `action.perform` interval (subsystem
com.cmuxterm.app.next, category action, the always-on message format) around 20 ms of main-thread CPU in a
function named `fixtureSpin`, then a 5 ms `usleep` (a system call of 1 ms or more, off CPU).

Scrubbing: user folders (`/Users/<name>` becomes `/Users/user`), the device name, the host name and the
user name are replaced; the file must then hold none of them, or the run fails. Each file must be under
MAX_BYTES (a fixture that grows means the recording caught more than the emitter).

  python3 scripts/cmux-next/trace_fixtures.py OUT
  python3 scripts/cmux-next/trace_fixtures.py --launch OUT

`--launch` (and ``write_launch_fixture``, which tests/test_trace_launch.py and trace.py's self-test call) writes
the raw files of a hand-written launch-warm recording instead, on any OS: the app's launch.mark signposts, its
StartupTrace file (milestones, main-thread startup tasks, one nested in another, a lane job on a background thread,
main-thread turns), a daemon startup trace on a clock 2 s off (its marks are the app's `daemon.*` marks, emitted
DAEMON_MARK_DELAY_MS after the daemon reached them, as an identify reply hands them over), a Chromium `--trace-startup` file cut inside an event (a crash or a kill),
main-thread time profile samples, and watchdog records. `trace.py export OUT` then builds its trace and summary.

It also holds the hand-written `input.latency` recording that trace.py's self-test case 'input latency slices'
builds (`input_latency_ndjson`): InputLatencyTracker's closed slots as `log stream --signpost` lines.
"""
import json, os, pwd, re, shutil, socket, subprocess, sys, tempfile

MAX_BYTES = 4_000_000
EMITTER = r'''
import Foundation
import os

let signposter = OSSignposter(subsystem: "com.cmuxterm.app.next", category: "action")
var sink = 0.0

@inline(never) func fixtureSpin(_ milliseconds: Double) {
    let end = Date().addingTimeInterval(milliseconds / 1000)
    var x = 1.0
    while Date() < end { x = sin(x) + 1.0001 }
    sink += x
}

// System Trace starts its kernel tracing after the launch: a 2 s run recorded no syscall row (Xcode 26.6).
Thread.sleep(forTimeInterval: 3)
for _ in 0..<20 {
    let state = signposter.beginInterval("action.perform", id: signposter.makeSignpostID(),
                                         "id=fixture.spin origin=user input_age_ms=1.00")
    fixtureSpin(20)
    signposter.endInterval("action.perform", state)
    usleep(5_000)
}
print(sink > 0 ? "done" : "?")
'''
TABLES = {"profile": ["time-profile", "os-signpost"], "system": ["syscall"]}


INPUT_PID = 42
MS = 1_000_000
# InputLatencySignpostMessage's fields in the order Signposter.event(_:_:) writes them, each stage microseconds after
# gen_ns (-1: skipped); trace.py's self-test 'input latency tables' compares them with the Swift. Raw values:
# kind keyPress 0, mousePress 3, scrollUpdate 9; target terminal 0, textView 1, chromiumPage 2, layout 5, other 8;
# entry person 0, automation 1; source estimatedVsync 0, metalPresented 1, pageEstimated 3, nominalRefresh 5.
INPUT_FIELDS = ("kind", "target", "entry", "source", "vrr", "coalesced", "frame", "gen_ns", "last_gen_us", "arrived_us",
                "dispatch_start_us", "ti_start_us", "ti_end_us", "dispatch_end_us", "commit_us", "content_us",
                "daemon_us", "pty_us", "echo_read_us", "echo_sent_us", "presented_us")
INPUT_SLOTS = [
    # 0: a terminal key with every stage, the cross-process ones included, linked to its key.flow chain.
    {"kind": 0, "target": 0, "entry": 0, "source": 0, "frame": 1, "gen_ns": 5_000 * MS, "arrived_us": 300,
     "dispatch_start_us": 400, "ti_start_us": 450, "ti_end_us": 600, "dispatch_end_us": 700, "daemon_us": 900,
     "pty_us": 1_000, "echo_read_us": 2_000, "echo_sent_us": 2_100, "commit_us": 3_000, "content_us": 3_500,
     "presented_us": 12_000},
    # 1: a text view key typed before key 0 presented (its own lane): no text input, no cross-process stages, and
    # a content_us after presented (left out, counted).
    {"kind": 0, "target": 1, "entry": 0, "source": 1, "frame": 1, "gen_ns": 5_004 * MS, "arrived_us": 200,
     "dispatch_start_us": 250, "dispatch_end_us": 1_250, "commit_us": 2_000, "presented_us": 8_000,
     "content_us": 9_000},
    # 2: three coalesced clicks on a variable-refresh display that skipped dispatch_start (a stage in the middle).
    {"kind": 3, "target": 2, "entry": 0, "source": 3, "vrr": 1, "coalesced": 3, "frame": 1, "gen_ns": 5_020 * MS,
     "last_gen_us": 2_000, "arrived_us": 3_000, "dispatch_end_us": 4_000, "commit_us": 5_000, "presented_us": 20_000},
    # 3: a click held inside click 2's span: it goes to another lane, never nested in it.
    {"kind": 3, "target": 2, "entry": 0, "source": 3, "frame": 1, "gen_ns": 5_025 * MS, "arrived_us": 500,
     "dispatch_start_us": 600, "dispatch_end_us": 1_000, "presented_us": 5_000},
    # 4: a scroll that changed nothing on screen: drawn, not folded (Chrome's caused_frame_update).
    {"kind": 9, "target": 5, "entry": 0, "source": 0, "frame": 0, "gen_ns": 5_050 * MS, "arrived_us": 1_000,
     "dispatch_start_us": 1_100, "dispatch_end_us": 2_000, "presented_us": 9_000},
    # 5: a scripted key: drawn, not folded into the person's rows.
    {"kind": 0, "target": 0, "entry": 1, "source": 0, "frame": 1, "gen_ns": 5_070 * MS, "arrived_us": 100,
     "dispatch_start_us": 200, "dispatch_end_us": 500, "presented_us": 5_000},
    # 6: a terminal key whose echo never came: no presented, its slice ends at its last stage. A stray key.flow
    # chain 1.5 ms after it is not this key's.
    {"kind": 0, "target": 0, "entry": 0, "source": 0, "frame": 1, "gen_ns": 5_090 * MS, "arrived_us": 200,
     "dispatch_start_us": 300, "dispatch_end_us": 900},
    # 7: a second text view key, so its row has two samples.
    {"kind": 0, "target": 1, "entry": 0, "source": 1, "frame": 1, "gen_ns": 5_100 * MS, "arrived_us": 200,
     "dispatch_start_us": 300, "dispatch_end_us": 1_000, "commit_us": 1_500, "presented_us": 10_000},
    # 8: a kind this script does not know yet (a case added after it), presented from a nominal refresh.
    {"kind": 200, "target": 8, "entry": 0, "source": 5, "frame": 1, "gen_ns": 5_150 * MS, "arrived_us": 100,
     "presented_us": 4_000},
    # 9: no generated time: it cannot be placed.
    {"kind": 0, "target": 0, "entry": 0, "source": 0, "frame": 1, "gen_ns": 0, "presented_us": 5_000},
]
INPUT_FLOW = (INPUT_PID << 32) | 1  # TypingLatencyProbe's flow id: pid << 32 | the press's index
INPUT_STRAY_FLOW = (INPUT_PID << 32) | 2
# (flow, hop, written at ns, age_us): each chain's app.key.dispatch hop is written a few us after the probe took its
# age, so its time minus its age is the key's OS timestamp plus that write.
INPUT_FLOW_HOPS = [(INPUT_FLOW, "app.key.dispatch", 5_000 * MS + 403_000, 400),
                   (INPUT_FLOW, "app.key.terminal", 5_000 * MS + 500_000, 500),
                   (INPUT_STRAY_FLOW, "app.key.dispatch", 5_091 * MS + 800_000, 300),
                   (INPUT_STRAY_FLOW, "app.key.terminal", 5_091 * MS + 900_000, 400)]


def input_latency_message(slot):
    """One slot's `input.latency` message, as Signposter.event(_:_:) formats an InputLatencySignpostMessage."""
    defaults = {"vrr": 0, "coalesced": 1}
    return " ".join(f"{name}={slot.get(name, defaults.get(name, -1))}" for name in INPUT_FIELDS)


def input_latency_ndjson():
    """The input latency recording as `log stream --signpost --style ndjson` writes it (timebase 1/1: the
    machTimestamp is ns; no sleep since boot): each slot one `input.latency` event when it closed and the two
    key.flow chains' app hops."""
    lines = ["#timebase 1/1", "#continuous-minus-uptime-us 0"]

    def event(signpost_id, name, category, at_ns, message):
        lines.append(json.dumps({"eventType": "signpostEvent", "subsystem": "com.cmuxterm.app.next",
                                 "category": category, "signpostName": name, "signpostID": signpost_id,
                                 "signpostType": "event", "processID": INPUT_PID, "threadID": 259,
                                 "machTimestamp": int(at_ns), "eventMessage": message}))

    for index, slot in enumerate(INPUT_SLOTS):
        closed = slot["gen_ns"] + max(slot.get(f, -1) for f in INPUT_FIELDS if f.endswith("_us")) * 1000
        event(100 + index, "input.latency", "input", closed, input_latency_message(slot))
    for index, (flow, hop, at_ns, age_us) in enumerate(INPUT_FLOW_HOPS):
        event(200 + index, "key.flow", "keyFlow", at_ns, f"hop={hop} flow={flow} age_us={age_us}")
    return "\n".join(lines) + "\n"


# The launch fixture (``write_launch_fixture``): pid 42 starts at CLOCK_UPTIME_RAW 10 s; marks in ms since then.
LAUNCH_PID, LAUNCH_MAIN_TID, LAUNCH_START_US = 42, 26, 10_000_000.0
LAUNCH_MARKS = [("main_start", 30.0), ("main.run", 45.0), ("did_finish_launching_start", 50.0),
                ("daemon.socket_bound", 120.0), ("did_finish_launching_end", 180.0),
                ("first_window_frame_committed", 240.0), ("startup_complete", 900.0)]
DAEMON_PID, DAEMON_SKEW_US, CEF_PID = 77, 2_000_000.0, 88
DAEMON_MARK_DELAY_MS = 35.0  # the app emits a `daemon.*` mark when the identify reply that carries it arrives
# A cold launch's marks of the daemon it spawned and of Chromium's start (``write_launch_fixture``'s `cold_marks`):
# `daemon.spawned`, the daemon's own start as the app records it from identify's `startup_marks` (p08-startup 093:
# DAEMON_START_MARKS in trace.py), and `cef.initialize_started`.
COLD_START_MARKS = [("daemon.spawned", 62.0), ("daemon.main_start", 64.0), ("daemon.config_loaded", 70.0),
                    ("daemon.mux_restored", 122.0), ("daemon.lifecycle_ready", 125.0),
                    ("daemon.first_identify_served", 130.0), ("cef.initialize_started", 390.0)]
LANE_TID = 27  # a StartupTrace lane job's background thread in the app process
# Main-thread samples (ms since process start, frames leaf first): three before the first frame, one after.
LAUNCH_SAMPLES = [(60.0, ("SessionStore.restore()", "AppDelegate.applicationDidFinishLaunching", "main")),
                  (61.0, ("SessionStore.restore()", "AppDelegate.applicationDidFinishLaunching", "main")),
                  (200.0, ("WindowBuilder.build()", "AppDelegate.applicationDidFinishLaunching", "main")),
                  (500.0, ("LateWork.run()", "main"))]


def write_launch_fixture(out, scenario="launch-warm", daemon_skew_us=DAEMON_SKEW_US, hangs_dropped=0, cold_marks=False):
    """The raw files of a small launch recording in `out` (the shapes trace.py reads), returns `out`. `daemon_skew_us`:
    how far the daemon's file clock is off CLOCK_UPTIME_RAW; `hangs_dropped`: the watchdog records the drain lost.
    `cold_marks`: the launch also marks COLD_START_MARKS, the daemon's start reaches the trace only through them (no
    daemon startup file, as a real daemon writes none) and the end ps snapshot names the daemon it spawned."""
    os.makedirs(os.path.join(out, "startup"), exist_ok=True)
    at = lambda ms: LAUNCH_START_US + ms * 1000  # CLOCK_UPTIME_RAW us of a time since process start
    marks = sorted(LAUNCH_MARKS + (COLD_START_MARKS if cold_marks else []), key=lambda mark: mark[1])
    lines = ["#timebase 1/1", "#continuous-minus-uptime-us 0"]
    for name, ms in marks:
        lines.append(json.dumps({"eventType": "signpostEvent", "subsystem": "com.cmuxterm.app.next",
                                 "category": "launch", "signpostName": "launch.mark", "signpostID": 1,
                                 "signpostType": "event", "processID": LAUNCH_PID, "threadID": LAUNCH_MAIN_TID,
                                 "machTimestamp": int(at(ms + (DAEMON_MARK_DELAY_MS if name.startswith("daemon.") else 0))
                                                      * 1000), "eventMessage": f"{name} ms={ms:.1f}"}))
    for name, begin, end in (("launch.main", 30.0, 45.0), ("launch.did_finish_launching", 50.0, 180.0)):
        for kind, ms in (("begin", begin), ("end", end)):
            lines.append(json.dumps({"eventType": "signpostEvent", "subsystem": "com.cmuxterm.app.next",
                                     "category": "launch", "signpostName": name, "signpostID": 7,
                                     "signpostType": kind, "processID": LAUNCH_PID, "threadID": LAUNCH_MAIN_TID,
                                     "machTimestamp": int(at(ms) * 1000), "eventMessage": ""}))
    with open(os.path.join(out, "signposts.ndjson"), "w") as f:
        f.write("\n".join(lines) + "\n#continuous-minus-uptime-us-end 0\n")
    app = [{"ph": "M", "pid": LAUNCH_PID, "tid": LAUNCH_MAIN_TID, "name": "thread_name", "args": {"name": "main"}},
           {"ph": "M", "pid": LAUNCH_PID, "tid": LANE_TID, "name": "thread_name", "args": {"name": "lane.utility"}},
           {"ph": "i", "s": "t", "pid": LAUNCH_PID, "tid": LAUNCH_MAIN_TID, "name": "process_start", "ts": at(0)}]
    app += [{"ph": "i", "s": "t", "pid": LAUNCH_PID, "tid": LAUNCH_MAIN_TID, "name": "mark", "ts": at(ms),
             "args": {"mark": name}} for name, ms in marks]
    app += [{"ph": "B", "pid": LAUNCH_PID, "tid": LAUNCH_MAIN_TID, "cat": "startup", "name": "SessionRestore", "ts": at(55)},
            {"ph": "E", "pid": LAUNCH_PID, "tid": LAUNCH_MAIN_TID, "ts": at(170)},
            {"ph": "X", "pid": LAUNCH_PID, "tid": LAUNCH_MAIN_TID, "cat": "startup", "name": "SessionRestore.decode",
             "ts": at(60), "dur": 40_000.0},  # inside SessionRestore: its time is SessionRestore's already
            {"ph": "X", "pid": LAUNCH_PID, "tid": LANE_TID, "cat": "lane", "name": "LaneJob.prewarm", "ts": at(52),
             "dur": 120_000.0},  # a background thread's job: never main-thread work
            {"ph": "X", "pid": LAUNCH_PID, "tid": LAUNCH_MAIN_TID, "cat": "main_turn", "name": "main.turn",
             "ts": at(100), "dur": 12_000.0},
            {"ph": "X", "pid": LAUNCH_PID, "tid": LAUNCH_MAIN_TID, "cat": "main_turn", "name": "main.turn",
             "ts": at(300), "dur": 2_000.0}]
    with open(os.path.join(out, "startup", "startup-app.json"), "w") as f:
        json.dump({"traceEvents": app}, f)
    daemon = [{"ph": "M", "pid": DAEMON_PID, "tid": 1, "name": "thread_name", "args": {"name": "cmux-tui main"}},
              {"ph": "i", "s": "t", "pid": DAEMON_PID, "tid": 1, "name": "socket_bound", "ts": at(120) - daemon_skew_us},
              {"ph": "X", "pid": DAEMON_PID, "tid": 1, "name": "mux_restored", "ts": at(80) - daemon_skew_us,
               "dur": 30_000.0}]
    if not cold_marks:
        with open(os.path.join(out, "startup", "startup-daemon.json"), "w") as f:
            json.dump({"traceEvents": daemon}, f)
    cef = json.dumps({"traceEvents": [
        {"ph": "M", "pid": CEF_PID, "tid": 5, "name": "thread_name", "args": {"name": "CrBrowserMain"}},
        {"ph": "X", "pid": CEF_PID, "tid": 5, "name": "BrowserMainLoop::CreateThreads", "ts": at(400), "dur": 8_000.0},
        {"ph": "X", "pid": CEF_PID, "tid": 5, "name": "BrowserMainLoop::PreMainMessageLoopRun", "ts": at(420),
         "dur": 9_000.0}]})
    with open(os.path.join(out, "startup", "startup-cef.json"), "w") as f:
        f.write(cef[:cef.rindex("PreMainMessageLoopRun")])  # cut inside the last event, as a kill leaves it
    rows = []
    for index, (ms, frames) in enumerate(LAUNCH_SAMPLES):
        thread = (f'<thread id="t" fmt="Main Thread 0x1a (cmux DEV, pid: {LAUNCH_PID})"><tid id="tt" fmt="0x1a">'
                  f'{LAUNCH_MAIN_TID}</tid><process id="p" fmt="cmux DEV ({LAUNCH_PID})"><pid id="pp" fmt="{LAUNCH_PID}">'
                  f'{LAUNCH_PID}</pid></process></thread>') if index == 0 else '<thread ref="t"/>'
        backtrace = "".join(f'<frame id="f{index}-{n}" name="{name}"/>' for n, name in enumerate(frames))
        rows.append(f'<row><sample-time id="s{index}" fmt="x">{int(at(ms) * 1000)}</sample-time>{thread}'
                    f'<weight id="w{index}" fmt="1.00 ms">1000000</weight><backtrace id="b{index}">{backtrace}</backtrace></row>')
    with open(os.path.join(out, "xctrace-time-profile.xml"), "w") as f:
        f.write('<?xml version="1.0"?><trace-query-result><node xpath="x"><schema name="time-profile"/>'
                + "".join(rows) + "</node></trace-query-result>")
    with open(os.path.join(out, "hangs.json"), "w") as f:
        json.dump({"records": [{"sequence": 1, "kind": "stall", "start_uptime_ns": int(at(200) * 1000),
                                "duration_ms": 6, "cpu_ms": 5,
                                "frames": ["CmuxNextApp WindowBuilder.build() + 10", "CmuxNextApp main + 4"]}],
                   "dropped": hangs_dropped}, f)
    with open(os.path.join(out, "meta.json"), "w") as f:
        json.dump({"scenario": scenario, "app_pid": LAUNCH_PID, "tag": "fixture", "host": "fixture",
                   "window_start_us": at(-10), "window_end_us": at(2900),
                   "launch": {"temperature": "cold" if scenario == "launch-cold" else "warm"}}, f)
    spawned = {str(DAEMON_PID): {"role": "daemon", "command": "/fixture/cmux-tui server --session cmux-app"}}
    with open(os.path.join(out, "processes.json"), "w") as f:
        json.dump({"start": {}, "end": spawned if cold_marks else {}}, f)
    return out


def run(command, **kwargs):
    done = subprocess.run(command, capture_output=True, text=True, **kwargs)
    if done.returncode != 0:
        raise SystemExit(f"trace_fixtures: {' '.join(command[:4])} exited {done.returncode}: {(done.stdout + done.stderr)[-800:]}")
    return done.stdout


def scrub(text, secrets):
    """Replaces user folders, the step's temp folder and each secret as a whole word only: the fleet account is
    `cmux`, and a plain replace turned the subsystem com.cmuxterm.app.next into com.userterm.app.next."""
    text = re.sub(r"/Users/[^/\"'<>\s]+", "/Users/user", text)
    text = re.sub(r"/tmp/[^/\"'<>\s]+/trace-fixtures-[A-Za-z0-9_]+/", "/tmp/trace-fixtures/", text)
    for secret, replacement in secrets:
        if secret:
            text = re.sub(rf"(?<![A-Za-z0-9_.-]){re.escape(secret)}(?![A-Za-z0-9_-])", replacement, text)
    return text


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--launch":
        print(f"trace_fixtures: wrote the launch fixture to {write_launch_fixture(os.path.abspath(sys.argv[2]))}")
        return 0
    if len(sys.argv) != 2:
        raise SystemExit(__doc__)
    out = os.path.abspath(sys.argv[1])
    version = run(["xcrun", "xctrace", "version"]).strip()
    # The folder is named by Xcode's major: xctrace's own version number is not Xcode's (Xcode 26.5 ships
    # "xctrace version 16.0 (17F113)", Xcode 26.0 "26.0 (17C529)").
    xcode = run(["xcrun", "xcodebuild", "-version"]).splitlines()[0].strip()
    major = re.search(r"Xcode (\d+)", xcode).group(1)
    macos = run(["sw_vers", "-productVersion"]).strip()
    target = os.path.join(out, f"xcode-{major}")
    os.makedirs(target, exist_ok=True)
    work = tempfile.mkdtemp(prefix="trace-fixtures-")
    source = os.path.join(work, "emitter.swift")
    binary = os.path.join(work, "fixture-emitter")
    with open(source, "w") as f:
        f.write(EMITTER)
    run(["xcrun", "swiftc", "-O", source, "-o", binary], timeout=600)
    device = None
    user = pwd.getpwuid(os.getuid()).pw_name
    host = socket.gethostname()
    exported = {}
    for name, template in (("profile", "Time Profiler"), ("system", "System Trace")):
        trace = os.path.join(work, f"{name}.trace")
        command = ["xcrun", "xctrace", "record", "--template", template, "--output", trace, "--no-prompt",
                   "--time-limit", "30s"]
        if name == "profile":
            command += ["--instrument", "os_signpost"]
        run(command + ["--launch", "--", binary], timeout=600)
        toc_xml = run(["xcrun", "xctrace", "export", "--input", trace, "--toc"], timeout=300)
        match = re.search(r'<device [^>]*name="([^"]*)"', toc_xml)
        device = device or (match.group(1) if match else None)
        exported[f"{name}-toc"] = toc_xml
        for schema in TABLES[name]:
            path = os.path.join(work, f"{schema}.xml")
            run(["xcrun", "xctrace", "export", "--input", trace, "--xpath",
                 f'/trace-toc/run[@number="1"]/data/table[@schema="{schema}"]', "--output", path], timeout=600)
            exported[schema] = open(path, errors="replace").read()
    secrets = [(device, "Fleet Mac"), (host, "fleet-host"), (user, "user")]
    for name, text in exported.items():
        text = scrub(text, secrets)
        leaked = [s for s, _ in secrets
                  if s and len(s) > 2 and re.search(rf"(?<![A-Za-z0-9_.-]){re.escape(s)}(?![A-Za-z0-9_-])", text)]
        if leaked:
            raise SystemExit(f"trace_fixtures: {name} still holds {leaked} after scrubbing")
        if len(text.encode()) > MAX_BYTES:
            raise SystemExit(f"trace_fixtures: {name} is {len(text.encode())} bytes, over {MAX_BYTES}")
        with open(os.path.join(target, f"{name}.xml"), "w") as f:
            f.write(text)
    with open(os.path.join(target, "fixture.json"), "w") as f:
        json.dump({"xcode": xcode, "xctrace": version, "macos": macos, "emitter": {
            "subsystem": "com.cmuxterm.app.next", "category": "action", "signpost": "action.perform",
            "message": "id=fixture.spin origin=user input_age_ms=1.00", "rounds": 20, "spin_ms": 20,
            "spin_function": "fixtureSpin", "usleep_ms": 5}}, f, indent=1)
    shutil.rmtree(work, ignore_errors=True)
    print(f"trace_fixtures: wrote {target} ({version}, macOS {macos}): " +
          ", ".join(f"{n} {os.path.getsize(os.path.join(target, n + '.xml')) // 1000} kB" for n in exported))
    return 0


if __name__ == "__main__":
    sys.exit(main())
