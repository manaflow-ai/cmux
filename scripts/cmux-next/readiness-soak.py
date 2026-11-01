#!/usr/bin/env python3
"""cmux-next readiness soak (hq#1870 gate: "a 24h soak with 10 agents: CPU, memory, no crash").

Runs a cmux-next app copy for --hours with --agents agent sessions, --terminals terminals that
keep printing and --browsers Chromium tabs, and samples every --sample seconds:

  - CPU share, memory footprint and wakeups/s per process kind (app, cmux-tui daemon, terminal
    hosts, acpmux, agents, Chromium helpers or WebKit processes), from proc_pid_rusage
    (bench_idle.usage), and open file descriptors (proc_pidinfo PROC_PIDLISTFDS). Browser tabs are Chromium when the build has it, else WebKit; WebKit's
    processes are launchd's children, so a WebKit process counts when the app is responsible for
    it (responsibility_get_pid_responsible_for_pid), not other apps' or iOS simulators';
  - control-socket round trips (system.ping, snapshot.get): a reply slower than --hang-after
    seconds is a hang; an instant failure (a missing socket file, a refused connect, an error
    reply) is a control-error event that names the error;
  - crashes: a new DiagnosticReports .ips of this app copy (its bundle ID), of a process of it
    the soak saw (every kind but WebKit, launchd's children) or of a child of the app, or the
    app, daemon or acpmux PID changing.
    Other builds crashing on the same host (a capture mini's tagged builds) do not count;
  - agent turns: every agent gets a streaming turn ("slow") every --turn-every seconds; a turn
    still running after 5 minutes is stuck;
  - zombie children: a child of this copy's processes (all but WebKit's) in state Z on two samples in
    a row, so not reaped for a whole --sample interval. report.json counts them per hour (`zombies`);
    any is a WARN line until --zombie-gate fail.

--app-config asan|tsan runs a sanitizer build (scripts/reload.sh --config asan|tsan, its runtime in
Contents/Frameworks) with Chromium off: CEF replaces the default malloc zone with PartitionAlloc, which
the sanitizer does not see (p10-stability.md risk 8). Browser tabs are WebKit, and a Chromium helper or
a PartitionAlloc zone (vmmap, read every ZONES_EVERY_S) makes the run invalid. The sanitizer writes to
--out/sanitizer/<run>/<mode>.* (ASAN_OPTIONS / TSAN_OPTIONS log_path, a new folder each run, kept after it),
and each report there or in app.log is a crash event, found by its header line as ClusterFuzz's stack
analyzer does (clusterfuzz/src/clusterfuzz/stacktraces/constants.py SAN_ADDR_REGEX and friends). The app
quits before the report, so a report written at quit or exit (LeakSanitizer's) counts.

--blocking-checks soaks the Nightly configuration (p02-threads RUN-9 in plans/cmux-next/chrome-parity/p02-threads.md):
a `scripts/reload.sh --config bench-checks` build, Release with -DCMUX_BLOCKING_CHECKS (the flag nightly.yml gives the
nightly-next track) plus the bench hooks that answer `debug.blocking`. The soak refuses another build: the bundle's
CMUXBuildConfiguration stamp must be bench-checks when it has one, `scripts/measure/blocking-checks.sh --app --expect
nightly` must find the detector's symbols, and the first `debug.blocking` must say `compiled_in` and record mode (the app
runs with CMUX_BLOCKING_TRAP=0 and CMUX_BLOCKING_TRAP_POOL=0, as a Nightly does). Every sample then reads `debug.blocking`,
`debug.hangs` (count250, count100, thread_hang_count) and the daemon's `server-blocking` on its own socket; nothing is
cleared, so each read covers the time since launch. Each new blocking site of the app or the daemon, and each call that
overflowed a site table, is one `blocking` event (in a Nightly, each is one hang report or Sentry non-fatal: the
BlockingReportSink of p02-threads-008, the daemon sites through p02-threads-233); each rise of count250 (a main-thread
work gap of 250 ms or more, MainThreadWatchdog StallCounts) is one `stall-250` event with the stall records of 250 ms or
more that `debug.hangs` still holds. Both fail the run, as does a source never read or not read after the loop. The app's
quit (`work.shutdown()` before exit, RUN-7) must end with status 0 within 90 s; without --blocking-checks a quit that
does not is a WARN line. report.json keeps the readout under `nightly`. RUN-9's soak, on a fleet mini:

  scripts/reload.sh --tag soak-nightly --config bench-checks
  scripts/cmux-next/readiness-soak.py --app APP --blocking-checks --stress --hours 1 --warmup 300 --idle 900 --settle 300

--stress builds the STRESS session (perf-stress-session.py, WebKit for its Chromium pages under
--app-config) in the app before the soak's own terminals, tabs and agents. Its busy terminals get a
Ctrl-C when the quiet phase starts.

The last --idle seconds are quiet: no new turns, and the terminals stop printing and wait on input.
Once every turn has ended and --settle seconds have passed, those samples are the idle cost.

The agents are acpmux's test agent (cmux-tui/crates/acpmux/tests/fake_agent.py): no account, no
network, no credential on the host. The app runs with its own ACPMUX_HOME and config in a scratch
folder; the soak never touches the host's ~/.acpmux or settings.

The app starts through bench_launch.BenchApp (the bench env, a scratch cmux.json, the window on the last screen,
the GUI-session check: this account must be the console user, so its display ticks), with the agent switches the
soak needs (real acpmux agent launches, no mock agent pane) and the soak's own ACPMUX_HOME. Percentiles and
medians are scripts/perf-lab/perf_stats.py's. With --story (scripts/perf-lab/stories.d; Chromium tabs, the story's
session) a soak that ran its whole length is also written into --out as cmux-perf-result/v1 (BenchApp.record):
readiness_soak.<app|daemon|acpmux>.{cpu,idle_cpu} (percent), .footprint_growth (bytes), .fd_growth,
readiness_soak.events.<crash|hang|control-error|stuck-turn> and readiness_soak.zombies (count),
readiness_soak.control.{ping,snapshot} (ms). Failed criteria still record; a soak that stopped early writes none.

At the end it writes report.json and report.md to --out and exits 1 when a criterion failed:
no crash, no hang, no control error, no stuck turn, memory growth (median of the last hour of load against an hour mid-load,
or quarters of a shorter load phase) within --max-growth-percent and --max-growth-mb per kind, open fds of the
app, daemon and acpmux growing by at most --max-fd-growth, the mean CPU of the app and the daemon
under --max-app-cpu and --max-daemon-cpu. Idle CPU over --max-idle-*-cpu (app, daemon,
acpmux) is a WARN line until --idle-cpu-gate fail. report.md ends with a memory and fd trend. Teardown goes through
the app's quit path, then TagTeardown (acpmux and cmux-tui shutdown, exact PIDs of this copy).

Host rules: an Aqua GUI session for this user; nothing else answering on the app's control
socket. Use a copy of the app (the nightly runner unpacks cmux-next-dev into the scratch folder).

  scripts/cmux-next/readiness-soak.py --app PATH [--hours 24] [--agents 10] [--terminals 10]
      [--browsers 4] [--sample 60] [--turn-every 300] [--app-config asan|tsan | --blocking-checks] [--stress]
      [--out DIR] [--story readiness-soak]
"""
from __future__ import annotations

import argparse
import ctypes
import datetime as dt
import functools
import glob
import importlib.util
import json
import os
import plistlib
import re
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import launch_journey_report as journey  # noqa: E402
from bench_idle import Client, process_table, usage  # noqa: E402
from bench_launch import BUILD_CONFIG_KEY, BenchApp, bench_env, info_plist, socket_candidates, tag_of  # noqa: E402
from bench_story import story_problem  # noqa: E402
from daemon_teardown import daemon_status, request, terminal_hosts  # noqa: E402
from tag_teardown import TagTeardown  # noqa: E402

FAKE_AGENT = os.path.join(HERE, "../../cmux-tui/crates/acpmux/tests/fake_agent.py")
FAKE_HARNESS = "readiness-soak-agent"
CRASH_NAMES = ("cmux", "acpmux")
STUCK_TURN_S = 300
# Each terminal prints until the quiet phase creates {stop}, then waits on its input (an idle shell).
TERMINAL_WORK = ("i=0; while [ ! -e {stop} ]; do i=$((i+1)); echo \"soak $i $(date +%T)\"; ls -l /usr/bin | head -30; "
                 "sleep 2; done; echo soak quiet; exec cat")
STATIC_PAGE = "<!doctype html><title>soak static</title><h1>static</h1><p>no script</p>"
TICKING_PAGE = ("<!doctype html><title>soak ticking</title><h1 id=t>0</h1>"
                "<script>let n=0;setInterval(()=>{document.getElementById('t').textContent=++n},5000)</script>")
# --app-config: the sanitizer runtime the build embeds and the variable its options come from.
SANITIZER_RUNTIMES = {"asan": "libclang_rt.asan_osx_dynamic.dylib", "tsan": "libclang_rt.tsan_osx_dynamic.dylib"}
SANITIZER_OPTIONS = {"asan": "ASAN_OPTIONS", "tsan": "TSAN_OPTIONS"}
TSAN_SUPPRESSIONS = os.path.join(HERE, "tsan-suppressions.txt")  # the reasoned third-party lines
# With Chromium off, the app's malloc zones are read at least this often while it runs (and when a Chromium helper
# shows), so a PartitionAlloc zone that registers mid-run is seen while the app is still alive to read.
ZONES_EVERY_S = 600
# One report each: ASan and LSan open with "==<pid>==ERROR: <tool>: <what>", TSan with
# "WARNING: ThreadSanitizer: <what> (pid=<pid>)".
# --blocking-checks: the Nightly configuration's reload.sh name, the app's record-mode environment (BlockingMode reads
# both once at launch), the symbol check, and the story module whose debug.blocking and debug.hangs parsers it reuses.
NIGHTLY_CONFIG = "bench-checks"
NIGHTLY_ENV = {"CMUX_BLOCKING_TRAP": "0", "CMUX_BLOCKING_TRAP_POOL": "0"}
BLOCKING_CHECKS = os.path.join(HERE, "../measure/blocking-checks.sh")
BLOCKING_HANGS = os.path.join(HERE, "../perf-lab/stories/blocking_hangs.py")
STALL_MS = 250  # MainThreadWatchdog StallCounts.edge250: the count250 edge
QUIT_WAIT_S = 90  # how long the app's quit (work.shutdown() first) may take before BenchApp.stop ends it
SANITIZER_HEADERS = (
    re.compile(r"^==(?P<pid>\d+)==ERROR: (?P<tool>AddressSanitizer|LeakSanitizer): (?P<what>.*)$", re.M),
    re.compile(r"^WARNING: (?P<tool>ThreadSanitizer): (?P<what>.*?)(?: \(pid=(?P<pid>\d+)\))?$", re.M),
)


PROC_PIDLISTFDS, PROC_FDINFO_SIZE = 1, 8


@functools.cache
def libproc():
    return ctypes.CDLL("/usr/lib/libproc.dylib")  # on first use, so the module imports off macOS (its tests)


def open_fds(pid):
    """Open file descriptors of pid (proc_pidinfo PROC_PIDLISTFDS), or None when it is gone."""
    size = libproc().proc_pidinfo(ctypes.c_int(pid), PROC_PIDLISTFDS, ctypes.c_uint64(0), None, 0)
    if size <= 0:
        return None
    buffer = ctypes.create_string_buffer(size + 64 * PROC_FDINFO_SIZE)
    used = libproc().proc_pidinfo(ctypes.c_int(pid), PROC_PIDLISTFDS, ctypes.c_uint64(0), buffer, len(buffer))
    return used // PROC_FDINFO_SIZE if used > 0 else None


@functools.lru_cache(None)
def responsibility_call():
    """libSystem's responsibility_get_pid_responsible_for_pid, or None where it does not exist."""
    try:
        call = ctypes.CDLL("/usr/lib/libSystem.B.dylib").responsibility_get_pid_responsible_for_pid
    except (OSError, AttributeError):
        return None
    call.argtypes, call.restype = [ctypes.c_int], ctypes.c_int
    return call


def responsible_pid(pid):
    """The process macOS holds responsible for pid (an XPC service's host app); -1 when the call has no
    answer for pid (it exited), None when the call does not exist on this host."""
    call = responsibility_call()
    if call is None:
        return None
    owner = call(pid)
    return owner if owner > 0 else -1


def now_iso():
    return dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds")


def say(line):
    print(f"{now_iso()} {line}", flush=True)


def run(*argv, timeout=60, env=None):
    return subprocess.run(list(argv), capture_output=True, text=True, timeout=timeout, env=env)


def bundle_tag(app):
    with open(os.path.join(app, "Contents/Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    bundle_id, executable = info.get("CFBundleIdentifier", ""), info.get("CFBundleExecutable", "")
    prefix = "com.cmuxterm.app.debug."
    if not bundle_id.startswith(prefix):
        raise SystemExit(f"readiness-soak: {app} is {bundle_id!r}, not a tagged build ({prefix}<tag>)")
    # The app's own tag rule (ControlSocketPath.sanitize): lowercase, [^a-z0-9]+ -> "-".
    return re.sub(r"[^a-z0-9]+", "-", bundle_id[len(prefix):].lower()).strip("-"), executable


def own_copy(app, work):
    """A copy of app in work with its own bundle id (<id>.soak<pid>), ad hoc signed like a capture slot's clone.

    A tagged build's control socket, cmux-tui session and acpmux tag home all follow its bundle id, so any
    other copy of the same build on the host (an installed cmux NEXT DEV) neither blocks the soak's copy nor
    shares its daemons. The copy is named `cmux DEV <tag>-soak<pid>.app`, the tag its bundle id sanitizes to, so
    BenchApp (which reads the tag from the bundle name) finds its socket and state."""
    tag, _ = bundle_tag(app)
    copy = os.path.join(work, f"cmux DEV {tag}-soak{os.getpid()}.app")
    copied = run("ditto", app, copy, timeout=900)
    if copied.returncode:
        raise SystemExit(f"readiness-soak: copying {app} failed: {copied.stderr.strip()[-300:]}")
    plist = os.path.join(copy, "Contents/Info.plist")
    with open(plist, "rb") as handle:
        info = plistlib.load(handle)
    info["CFBundleIdentifier"] = f"{info.get('CFBundleIdentifier', '')}.soak{os.getpid()}"
    with open(plist, "wb") as handle:
        plistlib.dump(info, handle)
    signed = run("codesign", "--force", "--deep", "--sign", "-", copy, timeout=900)
    if signed.returncode:
        raise SystemExit(f"readiness-soak: signing the copy failed: {signed.stderr.strip()[-300:]}")
    return copy


def acpmux_socket(home):
    """acpmux's socket for ACPMUX_HOME (config.rs socket_path): a long home falls back to
    /tmp/acpmux-<uid>/<fnv1a(home)>.sock."""
    preferred = os.path.join(home, "acpmux.sock")
    if len(preferred) < 96:
        return preferred
    value = 0xcbf29ce484222325
    for byte in home.encode():
        value = ((value ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
    return f"/tmp/acpmux-{os.getuid()}/{value:016x}.sock"


class Acpmux:
    """JSON-RPC over the app's acpmux socket, one request per connection."""

    def __init__(self, path):
        self.path = path

    def call(self, method, params=None, timeout=10):
        with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
            sock.settimeout(timeout)
            try:
                sock.connect(self.path)
                init = {"jsonrpc": "2.0", "id": 1, "method": "initialize",
                        "params": {"protocolVersion": 1, "clientInfo": {"name": "readiness-soak", "version": "1"}}}
                req = {"jsonrpc": "2.0", "id": 2, "method": method, "params": params or {}}
                sock.sendall((json.dumps(init) + "\n" + json.dumps(req) + "\n").encode())
                buffer = b""
                while True:
                    chunk = sock.recv(1 << 16)
                    if not chunk:
                        return None
                    buffer += chunk
                    while b"\n" in buffer:
                        line, buffer = buffer.split(b"\n", 1)
                        message = json.loads(line or b"{}")
                        if message.get("id") == 2:
                            return {"error": message["error"]} if "error" in message else message.get("result")
            except (OSError, ValueError) as error:
                return {"error": str(error)}

    def sessions(self):
        reply = self.call("_acpmux/sessions") or {}
        return {s.get("sessionId"): s.get("status") for s in reply.get("sessions", [])} if "error" not in reply else {}


def sanitizer_reports(text):
    """[{"tool", "what", "pid"}] for each sanitizer report header in text, in order."""
    found = []
    for pattern in SANITIZER_HEADERS:
        for match in pattern.finditer(text):
            what = re.split(r" (?:on|at) (?:unknown )?(?:address|pc|0x)", match["what"], maxsplit=1)[0].strip()
            found.append((match.start(), {"tool": match["tool"], "what": what[:120],
                                          "pid": int(match["pid"]) if match["pid"] else None}))
    return [report for _, report in sorted(found, key=lambda item: item[0])]


class SanitizerLogs:
    """New sanitizer reports in a log_path folder and in the other files named (app.log), read on from where the
    last poll stopped. The folder is this run's own (`Soak.begin` makes an empty one), so its files are read from
    their start; what the other files held when this was made is not this run's. A line still being written is
    read on the next poll; a file that got shorter (truncated) is read again from its start."""

    def __init__(self, folder, others=()):
        self.folder, self.others = folder, list(others)
        self.offsets = {path: os.path.getsize(path) for path in self.others if os.path.exists(path)}

    def paths(self):
        return sorted(glob.glob(os.path.join(self.folder, "*"))) + [p for p in self.others if os.path.exists(p)]

    def poll(self):
        reports = []
        for path in self.paths():
            offset = self.offsets.get(path, 0)
            try:
                if os.path.getsize(path) < offset:
                    offset = 0
                with open(path, "rb") as handle:
                    handle.seek(offset)
                    data = handle.read()
            except OSError:
                continue
            complete = data.rfind(b"\n") + 1
            self.offsets[path] = offset + complete
            reports += [dict(report, log=path) for report in sanitizer_reports(data[:complete].decode(errors="replace"))]
        return reports


def sanitizer_runtimes(app):
    """The --app-config modes whose sanitizer runtime app embeds (Contents/Frameworks)."""
    frameworks = os.path.join(app, "Contents/Frameworks")
    return {mode for mode, name in SANITIZER_RUNTIMES.items() if os.path.exists(os.path.join(frameworks, name))}


def sanitizer_path_value(path):
    """`path` quoted for a sanitizer option. compiler-rt's flag parser (sanitizer_flag_parser.cpp, is_space and
    parse_flag) ends a bare value at a space, comma, colon, tab or newline, and reads a quoted one to its closing
    quote; a path holding both quote characters cannot be written, so the soak refuses it."""
    quote = next((q for q in ("'", '"') if q not in path), None)
    if quote is None:
        raise SystemExit(f"readiness-soak: {path!r} has both quote characters; a sanitizer option cannot name it")
    return f"{quote}{path}{quote}"


def sanitizer_env(mode, folder, environ=None):
    """The app's ASAN_OPTIONS or TSAN_OPTIONS: the caller's own options, then the soak's log path (later wins)."""
    key = SANITIZER_OPTIONS[mode]
    own = (os.environ if environ is None else environ).get(key)
    options = ([own] if own else []) + [f"log_path={sanitizer_path_value(os.path.join(folder, mode))}", "log_exe_name=1"]
    if mode == "tsan" and os.path.exists(TSAN_SUPPRESSIONS):
        options.append(f"suppressions={sanitizer_path_value(TSAN_SUPPRESSIONS)}")
    return {key: ":".join(options)}


def malloc_zones(text):
    """The zone names of `vmmap --summary`'s MALLOC ZONE table, without vmmap's _0x<address> suffix."""
    names, inside = [], False
    for line in text.splitlines():
        if line.startswith("MALLOC ZONE"):
            inside = True
        elif inside and line.startswith("="):
            continue
        elif inside and (not line.strip() or line.startswith("TOTAL")):
            break
        elif inside:
            names.append(re.sub(r"_0x[0-9a-fA-F]+$", "", line.split()[0]))
    return names


def zombies_in(ps_text, parents):
    """[(pid, ppid)] of the processes in `ps -axo pid=,ppid=,stat=` output that are zombies (state Z) of a parent
    in parents."""
    found = []
    for line in ps_text.splitlines():
        parts = line.split()
        if len(parts) >= 3 and parts[0].isdigit() and parts[1].isdigit() and parts[2].startswith("Z") \
                and int(parts[1]) in parents:
            found.append((int(parts[0]), int(parts[1])))
    return found


def load_stress():
    """perf-stress-session.py as a module (its file name has dashes)."""
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def soak_stress(module, chromium_off):
    """perf-stress-session's Stress as soak load, not a measured layout: a window the app cannot place (a build
    without debug.window_frame, a small screen) stays where it is and is noted, and with Chromium off each
    Chromium page is a WebKit one. `made` keeps the asked kind, so STRESS's pane mix (2 Chromium, 1 WebKit) still
    checks; a browser tab is the topology kind of both (perf-stress-session topology_kinds)."""
    class SoakStress(module.Stress):
        window_note = None

        def size_window(self):
            try:
                return super().size_window()
            except module.StressShapeError as error:
                self.window_note = str(error)[:300]
                return {}

        def add_tab(self, workspace_id, pane_id, kind):
            engine = "webkit" if chromium_off and kind == "chromium" else kind
            super().add_tab(workspace_id, pane_id, engine)
            if engine != kind:
                made = self.made[pane_id]
                made[-1] = (kind, *made[-1][1:])
    return SoakStress


def stress_shape_problems(module, summary, chromium_off):
    """Why `summary` is not STRESS's shape (perf-stress-session Stress.check), or None. With Chromium off,
    debug.cef's state is not Chromium's (`chromium_unavailable`); every other part of the shape still holds. The
    background pages still count: a WebKit page is a non-terminal tab too."""
    try:
        module.Stress.check(dict(summary, chromium_unavailable=[]) if chromium_off else summary)
    except module.StressShapeError as error:
        return str(error)
    return None


@functools.cache
def blocking_hangs():
    """scripts/perf-lab/stories/blocking_hangs.py as a module: its `debug.blocking` and `debug.hangs` parsers, their
    errors and its daemon socket request."""
    spec = importlib.util.spec_from_file_location("blocking_hangs", BLOCKING_HANGS)
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # its dataclasses look their module up
    spec.loader.exec_module(module)
    return module


def nightly_build_problem(app):
    """Why `app` is not the Nightly configuration, or None: its CMUXBuildConfiguration stamp names another config, or
    blocking-checks.sh --expect nightly finds no detector symbols in it (exit 1) or cannot read it (exit 2)."""
    stamped = info_plist(app).get(BUILD_CONFIG_KEY)
    if stamped is not None and stamped != NIGHTLY_CONFIG:
        return (f"{app} was built with --config {stamped}: the Nightly configuration is --config {NIGHTLY_CONFIG} "
                "(Release with -DCMUX_BLOCKING_CHECKS and the bench hooks)")
    try:
        done = run("bash", BLOCKING_CHECKS, "--app", app, "--expect", "nightly", timeout=600)
    except subprocess.TimeoutExpired:
        return "blocking-checks.sh --expect nightly did not finish within 600 s"
    if done.returncode:
        lines = (done.stderr.strip() or done.stdout.strip()).splitlines()[-2:]
        return f"blocking-checks.sh --expect nightly exited {done.returncode}: {' | '.join(lines)}"
    return None


class NightlyReadout:
    """--blocking-checks: what a Nightly would report, read since launch on the control sockets. `rpc(method, params)`
    is the app's control method (its result, or {"error": ...}), `daemon(command)` the daemon's newline-JSON reply (None
    when its socket does not answer), `event(kind, detail, **extra)` Soak.event. Nothing is cleared, so a failed read
    loses nothing the next read sees; a count that goes back is a new process, counted from 0."""

    def __init__(self, rpc, daemon, event):
        self.rpc, self.daemon, self.event = rpc, daemon, event
        self.bh = blocking_hangs()
        self.errors = (OSError, ValueError, subprocess.SubprocessError, self.bh.NoDetector, self.bh.NotMeasurable,
                       self.bh.LegError)
        self.sites = {"app": {}, "daemon": {}}  # site key -> the site, with when it was first seen
        self.overflow = {"app": 0, "daemon": 0}  # blocking calls no site table kept as a site
        self.stalls = {"count250": 0, "count100": 0, "thread_hangs": 0}
        self.last = {}  # (source, counter) -> the value of the last read
        self.reads = {"app": 0, "daemon": 0}
        self.failed = {"app": 0, "daemon": 0}
        self.last_failure = {"app": None, "daemon": None}
        self.last_read = {"app": None, "daemon": None}
        self.final = None  # {source: read} of the read after the loop

    def start(self):
        """The first app read, at launch: SystemExit unless the app runs the detector, in record mode, and its
        main-thread watchdog."""
        try:
            reply = self.read_app()
        except self.errors as error:
            raise SystemExit(f"readiness-soak: --blocking-checks: {error}")
        modes = (reply.get("mode"), reply.get("pool_mode"))
        if modes != ("record", "record"):
            raise SystemExit(f"readiness-soak: --blocking-checks: the detector runs in mode {modes[0]}, pool mode "
                             f"{modes[1]}: a Nightly records (CMUX_BLOCKING_TRAP=0, CMUX_BLOCKING_TRAP_POOL=0)")
        self.reads["app"], self.last_read["app"] = 1, now_iso()

    def poll(self, final=False):
        """One read of the app and one of the daemon; {source: read}. A failed read is counted with its reason."""
        done = {}
        for source, read in (("app", self.read_app), ("daemon", self.read_daemon)):
            try:
                read()
            except self.errors as error:
                self.failed[source] += 1
                self.last_failure[source] = f"{now_iso()} {type(error).__name__}: {str(error)[:300]}"
                done[source] = False
                continue
            self.reads[source] += 1
            self.last_read[source] = now_iso()
            done[source] = True
        if final:
            self.final = done
        return done

    def grown(self, source, counter, value):
        """How much `counter` grew since the last read: all of it on the first read or after it went back."""
        before = self.last.get((source, counter))
        self.last[(source, counter)] = value
        return value - before if before is not None and value >= before else value

    def note_site(self, source, key, detail, count, **fields):
        known = self.sites[source].get(key)
        if known is not None:
            known["count"] = max(known["count"], count)  # the most calls one process life made
            return
        self.sites[source][key] = {"first_seen": now_iso(), "count": count, **fields}
        self.event("blocking", f"{source} blocking site: {detail} ({count} call(s))", source=source, site=fields)

    def note_overflow(self, source, value):
        grown = self.grown(source, "overflow", value)
        if grown:
            self.overflow[source] += grown
            self.event("blocking", f"{source}: {grown} blocking call(s) at sites its table does not hold (overflow)",
                       source=source)

    def read_app(self):
        """`debug.blocking` and `debug.hangs`; returns the `debug.blocking` reply."""
        bh = self.bh
        reply = self.rpc("debug.blocking", {})
        reading = bh.parse_blocking(reply)
        hangs_reply = self.rpc("debug.hangs", {"limit": 0})
        hangs = bh.parse_hangs(hangs_reply)
        for site in reading.sites.values():
            self.note_site("app", site.key, f"{site.context} {site.kind} at {site.location}", site.count,
                           context=site.context, kind=site.kind, seam_kind=site.seam_kind, location=site.location)
        self.note_overflow("app", bh._count(reply.get("overflow", 0), "debug.blocking overflow"))
        self.stalls["count100"] += self.grown("app", "count100", bh._count(hangs_reply.get("count100", 0), "count100"))
        if hangs.thread_hang_count is not None:
            self.stalls["thread_hangs"] += self.grown("app", "thread_hangs", hangs.thread_hang_count)
        stalls = self.grown("app", "count250", hangs.count250)
        if stalls:
            self.stalls["count250"] += stalls
            self.event("stall-250", f"debug.hangs count250 +{stalls}: main-thread work gap(s) of {STALL_MS} ms or more "
                                    f"({self.stalls['count250']} in the soak)", stalls=self.long_stalls())
        return reply

    def long_stalls(self):
        """The stall records of STALL_MS or more that `debug.hangs` still holds (each with its main-thread stack)."""
        try:
            records = self.bh.parse_hangs(self.rpc("debug.hangs", {"limit": 16})).records
        except self.errors:
            return []
        return [r for r in records
                if r.get("kind", "stall") == "stall" and self.bh._number(r.get("duration_ms")) >= STALL_MS][-4:]

    def read_daemon(self):
        """The daemon's `server-blocking` (cmux-tui-core server_stats.rs): its sites and overflow."""
        bh = self.bh
        reply = self.daemon({"cmd": "server-blocking"})
        if not isinstance(reply, dict) or reply.get("ok") is not True:
            raise ValueError(f"server-blocking answered {json.dumps(reply)[:200]}")
        data = reply.get("data") if isinstance(reply.get("data"), dict) else {}
        if not isinstance(data.get("sites"), list):
            raise ValueError("server-blocking has no sites list")
        for item in data["sites"]:
            if not isinstance(item, dict):
                raise ValueError(f"a server-blocking site is not an object: {json.dumps(item)[:200]}")
            kinds = tuple(str(kind) for kind in item.get("kinds") or ())
            location = f"{item.get('file')}:{item.get('line')}:{item.get('column')}"
            lane_sync = bool(item.get("lane_sync"))
            self.note_site("daemon", (location, kinds, lane_sync),
                           f"{'/'.join(kinds)}{' (lane sync)' if lane_sync else ''} at {location}",
                           bh._count(item.get("count"), "a server-blocking site's count"),
                           kinds=list(kinds), location=location, lane_sync=lane_sync)
        self.note_overflow("daemon", bh._count(data.get("overflow", 0), "server-blocking overflow"))

    def sample_fields(self):
        """The readout's columns of a samples.jsonl row."""
        return {"blocking_sites": sum(len(sites) for sites in self.sites.values()), "count250": self.stalls["count250"]}

    def summary(self):
        by_context = {}
        for site in self.sites["app"].values():
            by_context[site["context"]] = by_context.get(site["context"], 0) + 1

        def source(name):
            return {"sites": len(self.sites[name]), "overflow": self.overflow[name], "reads": self.reads[name],
                    "failed_reads": self.failed[name], "last_read": self.last_read[name],
                    "last_failure": self.last_failure[name], "site_list": list(self.sites[name].values())}
        return {"config": NIGHTLY_CONFIG, "app": dict(source("app"), by_context=by_context), "daemon": source("daemon"),
                **self.stalls, "final_read": self.final}

    def problems(self):
        """The readout's failures besides its events: a source never read, or not read after the loop."""
        found = []
        for name, what in (("app", "debug.blocking and debug.hangs"), ("daemon", "the daemon's server-blocking")):
            why = f" (last failure: {self.last_failure[name]})" if self.last_failure[name] else ""
            if not self.reads[name]:
                found.append(f"--blocking-checks: {what} never read{why}")
            elif self.final is not None and not self.final.get(name):
                found.append(f"--blocking-checks: {what} not read after the last sample, so the end of the soak "
                             f"is not counted{why}")
        return found


def wait(condition, seconds, step=1.0):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        value = condition()
        if value:
            return value
        time.sleep(step)  # soak script: waiting for setup to take effect
    return None


class Soak:
    def __init__(self, args):
        self.args = args
        self.app = os.path.realpath(args.app)
        self.out = args.out
        os.makedirs(self.out, exist_ok=True)
        # Resolved (/var -> /private/var), so the copy and its helpers have one path that TagTeardown matches.
        self.work = os.path.realpath(tempfile.mkdtemp(prefix="cmux-soak-"))
        self.acpmux_home = os.path.join(self.work, "acpmux")
        self.quiet_file = os.path.join(self.work, "quiet")
        self.acp = Acpmux(acpmux_socket(self.acpmux_home))
        self.samples = None  # opened by begin(), after preflight: a refused soak never touches another's files
        self.stage = "setup"
        self.events = []
        self.setup = {}
        self.agents = {}  # session id -> {"started": monotonic or None, "turns": n, "done": n}
        self.started = time.time()
        self.pids = {}
        self.app_pid = None
        self.app_exit = None  # the app process's return code once it has exited (check_app_exit)
        self.seen_pids = set()  # every PID of this copy but WebKit's, for crash reports
        self.webkit_before = set()
        self.chromium_off = bool(args.app_config)
        self.sanitizer = None  # SanitizerLogs, opened by begin() with --app-config
        self.sanitizer_count = 0
        self.zombies = {}  # pid -> {"hour", "parent", "parent_kind"}: zombies seen on two samples in a row
        self.zombies_last = set()
        self.zones_checked = float("-inf")  # monotonic time of the last malloc zone read (check_chromium_off)
        self.stress = None
        self.nightly = None  # NightlyReadout, made by launch() with --blocking-checks
        self.daemon_socket = None  # the daemon's own socket (daemon_status), for its server-blocking

    def event(self, kind, detail, **extra):
        self.events.append({"at": now_iso(), "kind": kind, "detail": detail, **extra})
        say(f"EVENT {kind}: {detail}")

    # ---- setup ---------------------------------------------------------------------------

    def identify(self):
        """Run this soak's own tagged copy of --app (own_copy) unless --same-tag. A sanitizer build runs only with
        its --app-config, and --app-config only on a build with that sanitizer's runtime."""
        runtimes, mode = sanitizer_runtimes(self.app), self.args.app_config
        if mode and mode not in runtimes:
            raise SystemExit(f"readiness-soak: {self.app} has no Contents/Frameworks/{SANITIZER_RUNTIMES[mode]}: "
                             f"not a {mode} build (scripts/reload.sh --config {mode})")
        if not mode and runtimes:
            raise SystemExit(f"readiness-soak: {self.app} is a {'/'.join(sorted(runtimes))} build: "
                             f"run it with --app-config {sorted(runtimes)[0]}")
        self.setup["app_config"] = mode or "plain"
        if self.args.blocking_checks:
            problem = nightly_build_problem(self.app)
            if problem:
                raise SystemExit(f"readiness-soak: --blocking-checks: {problem}")
            self.setup["app_config"] = NIGHTLY_CONFIG
        if not self.args.same_tag:
            self.app = own_copy(self.app, self.work)
        self.tag, executable = bundle_tag(self.app)
        if tag_of(self.app) != self.tag:
            raise SystemExit(f"readiness-soak: {self.app} is named for tag {tag_of(self.app)!r} but its bundle id is "
                             f"tag {self.tag!r}: BenchApp would look for another app's socket")
        with open(os.path.join(self.app, "Contents/Info.plist"), "rb") as handle:
            self.bundle_id = plistlib.load(handle)["CFBundleIdentifier"]
        self.binary = os.path.join(self.app, "Contents/MacOS", executable)
        self.tui = os.path.join(self.app, "Contents/Resources/bin/cmux-tui")
        # The control socket comes from BenchApp (bench_launch.socket_candidates, the app's ControlSocketPath rule):
        # the state folder, or the /tmp name when that path would not fit sun_path. --socket is checked first.
        self.bench = BenchApp(self.app, out=self.out, env=self.launch_env(), config=self.settings("keep"), window=None,
                              screen="last", log_name="app.log", teardown=False, fresh_state=not self.args.same_tag,
                              perf_session=self.perf_session())
        self.config = os.path.join(self.bench.scratch, "cmux.json")  # BenchApp writes it at the launch
        self.sockets = ([self.args.socket] if self.args.socket else []) + [
            path for path in socket_candidates(self.tag) if path != self.args.socket]
        self.socket = self.sockets[0]
        self.setup["tag"] = self.tag

    def preflight(self):
        if run("launchctl", "print", f"gui/{os.getuid()}").returncode != 0:
            raise SystemExit("readiness-soak: no Aqua GUI session for this user")
        for path in self.sockets:
            if os.path.exists(path):
                try:
                    Client(path, timeout=3).call("system.ping")
                    raise SystemExit(f"readiness-soak: something already answers on {path}")
                except OSError:
                    pass
        table = process_table()
        # Two soaks on one host would measure each other.
        parents, mine, pid = {p: pp for p, pp, _ in table}, set(), os.getpid()
        while pid and pid not in mine:  # this soak and the shells that started it
            mine.add(pid)
            pid = parents.get(pid)
        others = [pid for pid, _, cmd in table if "readiness-soak.py" in cmd and pid not in mine]
        if others:
            raise SystemExit(f"readiness-soak: another soak runs on this host (PID {others[0]})")
        if any(cmd.startswith(self.binary) for _, _, cmd in table):
            raise SystemExit(f"readiness-soak: {self.binary} is already running")
        self.webkit_before = {pid for pid, _, cmd in table if "com.apple.WebKit." in cmd}

    def forget(self):
        """Remove the state the app keeps under this run's own bundle id and tag (both carry the soak's PID,
        so no other build shares them). --same-tag runs the build as it is and keeps its state."""
        if self.args.same_tag or not getattr(self, "bundle_id", None):
            return
        bundle, tag = self.bundle_id, self.tag
        support = os.path.expanduser("~/Library/Application Support")
        run("defaults", "delete", bundle)
        for path in (os.path.expanduser(f"~/Library/Preferences/{bundle}.plist"),
                     os.path.join(support, bundle),
                     os.path.join(support, "cmux-next", bundle),
                     os.path.join(support, "cmux", bundle),
                     os.path.join(support, "cmux", f"managed-status.{bundle}.json"),
                     os.path.join(support, "cmux", "tags", tag),
                     os.path.expanduser(f"~/.cmux/chief/isolated/{tag}")):
            if os.path.isdir(path) and not os.path.islink(path):
                shutil.rmtree(path, ignore_errors=True)
            elif os.path.lexists(path):
                os.remove(path)

    def begin(self):
        self.samples = open(os.path.join(self.out, "samples.jsonl"), "w")
        if self.args.app_config:
            # An empty folder of this run's own: a sanitizer log opens with O_TRUNC under <mode>.<exe>.<pid>, so an
            # earlier run's file of the same name would hide the start of this run's report.
            runs = os.path.join(self.out, "sanitizer")
            os.makedirs(runs, exist_ok=True)
            stamp = dt.datetime.now(dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
            self.sanitizer_dir = tempfile.mkdtemp(prefix=f"{stamp}-", dir=runs)
            self.sanitizer = SanitizerLogs(self.sanitizer_dir, [os.path.join(self.out, "app.log")])
            self.setup["sanitizer_logs"] = self.sanitizer_dir
            self.setup["browser_engine"] = "webkit"

    def settings(self, quit_behavior):
        """The soak's cmux.json: the bench defaults (bench_env, the updater off) under the soak's own keys."""
        settings = {"app": {"quitBehavior": quit_behavior}}
        if self.chromium_off:
            settings["browser"] = {"defaultEngine": "webkit"}
        return bench_env.with_config_defaults(settings)

    def write_config(self, quit_behavior):
        with open(self.config, "w") as handle:
            json.dump(self.settings(quit_behavior), handle)

    def perf_session(self):
        """result-v1's session: the STRESS session with --stress, else light."""
        return "stress" if self.args.stress else "light"

    def launch_env(self):
        """What the soak adds to BenchApp's bench env: its own acpmux home, and agents that really start (the fake
        agent through acpmux), so neither the agent launch deny nor the mock agent pane of the bench env. With
        --blocking-checks the detector records, as a Nightly's does, whatever the host's environment says."""
        env = {"ACPMUX_HOME": self.acpmux_home, "ACPMUX_AGENT_LAUNCH": None, "CMUX_NEXT_AGENT_PANE_MOCK": None}
        return {**env, **NIGHTLY_ENV} if self.args.blocking_checks else env

    def launch(self):
        os.makedirs(self.acpmux_home)
        agent = os.path.join(self.work, "fake_agent.py")
        shutil.copy(FAKE_AGENT, agent)
        with open(os.path.join(self.acpmux_home, "config.json"), "w") as handle:
            # The default too: an agent chat opened without a harness (STRESS's) runs the fake agent, not a real one.
            json.dump({"harnesses": {FAKE_HARNESS: {"argv": [sys.executable, agent]}}, "defaultHarness": FAKE_HARNESS}, handle)
        if self.args.app_config:
            self.bench.extra_env.update(sanitizer_env(self.args.app_config, self.sanitizer_dir))
        # system.ping, not debug.windows: a build without the debug methods (a nightly) soaks too. Raises
        # LaunchError (a SystemExit) with the reason when the app does not come up.
        self.bench.launch(timeout=120, ready="system.ping")
        self.sockets = [self.bench.socket]
        self.control = wait(lambda: self.connect(), 120, 1)
        if not self.control:
            raise SystemExit(f"readiness-soak: no control socket at {self.socket}")
        identity = self.control.call("system.identify").get("result", {})
        self.setup["identity"] = {k: identity.get(k) for k in ("pid", "build", "version", "bundle_identifier") if k in identity}
        self.app_pid = self.setup["identity"].get("pid")
        say(f"app up: {self.setup['identity']}")
        if self.args.blocking_checks:
            self.nightly = NightlyReadout(self.control_call, self.daemon_request, self.event)
            self.nightly.start()

    def control_call(self, method, params):
        """One app control call on a connection of its own: the result, or {"error": ...}."""
        reply = Client(self.socket, timeout=10).call(method, params)
        return {"error": reply["error"]} if "error" in reply else reply.get("result")

    def daemon_request(self, command):
        """One request on the daemon's own socket; None when there is no daemon or it does not answer. The socket is
        asked for again after a failure, since a restarted daemon may listen at another path."""
        if not self.daemon_socket:
            status = daemon_status(self.tui, self.tag)
            self.daemon_socket = status.get("socket") if status else None
        reply = blocking_hangs().daemon_request(self.daemon_socket, command) if self.daemon_socket else None
        if reply is None:
            self.daemon_socket = None
        return reply

    def connect(self):
        for path in self.sockets:
            try:
                client = Client(path, timeout=10)
                if "error" not in client.call("system.ping"):
                    self.socket = path
                    return client
            except OSError:
                continue
        return None

    def start_stress(self):
        """The STRESS session (perf-stress-session.py, `soak_stress`). A session not built fails the run; one built
        in another shape than STRESS (`stress_shape_problems`) is a WARN line. A refused agent chat may become the
        New Tab page."""
        module = load_stress()
        self.stress = soak_stress(module, self.chromium_off)(module.socket_rpc(self.socket), log=say,
                                                              allow_chat_fallback=True)
        try:
            summary = self.stress.build(check=False)
        except RuntimeError as error:  # StressShapeError, or a tab that did not appear
            self.setup["stress"] = f"not built: {error}"[:400]
            return
        self.setup["stress"] = {key: summary.get(key) for key in
                                ("workspaces", "measured_panes", "measured_tabs", "busy_terminals", "build_s")}
        shape = [self.stress.window_note] if self.stress.window_note else []
        problems = stress_shape_problems(module, summary, self.chromium_off)
        if problems:
            shape.append(problems)
        if shape:
            self.setup["stress_shape"] = "; ".join(shape)[:600]

    def quiet_stress(self):
        """Ctrl-C to STRESS's busy terminals, so the quiet phase is quiet."""
        for tab in getattr(self.stress, "busy", None) or []:
            self.stress.send(tab, "\x03")

    def start_terminals(self):
        status = wait(lambda: daemon_status(self.tui, self.tag), 60, 2)
        if not status:
            self.setup["terminals"] = "no running daemon"
            return
        self.daemon_socket = status["socket"]
        made = 0
        for index in range(self.args.terminals):
            reply = request(status["socket"], {"id": 10 + index, "cmd": "run", "argv": ["/bin/sh", "-c", TERMINAL_WORK.format(stop=shlex.quote(self.quiet_file))],
                                               "new_workspace": True, "name": f"soak-terminal-{index + 1}"}, 30)
            made += bool(reply.get("ok"))
            if not reply.get("ok"):
                self.setup.setdefault("terminal_errors", []).append(str(reply.get("error"))[:200])
        self.setup["terminals"] = made

    def start_browsers(self):
        made = 0
        for index in range(self.args.browsers):
            page = os.path.join(self.work, f"page-{index}.html")
            with open(page, "w") as handle:
                handle.write(TICKING_PAGE if index % 2 else STATIC_PAGE)
            engine = self.setup.get("browser_engine", "chromium")
            reply = self.control.action(f"openBrowser.{engine}", timeout=90, url="file://" + page)
            if engine == "chromium" and (reply.get("error") or {}).get("code") == "unavailable":
                # A build without CEF (cmux NEXT DEV): WebKit tabs.
                self.setup["browser_engine"] = engine = "webkit"
                reply = self.control.action("openBrowser.webkit", timeout=90, url="file://" + page)
            self.setup.setdefault("browser_engine", engine)
            timed_out = (reply.get("error") or {}).get("code") == "timeout"
            made += timed_out or "error" not in reply
            if "error" in reply and not timed_out:
                self.setup.setdefault("browser_errors", []).append(str(reply.get("error"))[:200])
        self.setup["browsers"] = made

    def start_agents(self):
        if not wait(lambda: "error" not in (self.acp.call("_acpmux/status", timeout=3) or {"error": 1}), 120, 2):
            self.setup["agents"] = "acpmux did not answer"
            return
        self.acp.call("_acpmux/reload_config")
        for index in range(self.args.agents):
            cwd = os.path.join(self.work, f"agent-{index + 1}")
            os.makedirs(cwd)
            self.acp.call("acp.trust.set", {"cwd": cwd, "level": "trusted"})
            created = self.acp.call("session/new", {"cwd": cwd, "mcpServers": [],
                                                    "_meta": {"acpmux": {"harness": FAKE_HARNESS}}}) or {}
            if created.get("sessionId"):
                self.agents[created["sessionId"]] = {"started": None, "turns": 0, "done": 0, "cwd": cwd}
            else:
                self.setup.setdefault("agent_errors", []).append(str(created)[:200])
        self.setup["agents"] = len(self.agents)

    def prompt(self, session):
        entry = self.agents[session]
        entry["started"], entry["turns"] = time.monotonic(), entry["turns"] + 1

        def hold():
            self.acp.call("session/prompt", {"sessionId": session, "prompt": [{"type": "text", "text": "slow"}]},
                          timeout=STUCK_TURN_S + 60)
        threading.Thread(target=hold, daemon=True).start()

    # ---- sampling ------------------------------------------------------------------------

    def kinds(self):
        """{pid: kind} for every process of this app copy and its agents. An app that has exited has no row: its
        PID may be an unreaped zombie's or another process's by now."""
        app_pid = self.setup["identity"].get("pid") if self.app_exit is None else None
        found = {}
        tui = os.path.join(self.app, "Contents/Resources/bin/cmux-tui")
        acpmux = os.path.join(self.app, "Contents/Resources/bin/acpmux")
        for pid, ppid, cmd in process_table():
            # self.app is resolved (/private/var/...); the app names some helpers by /var/... (TagTeardown too).
            cmd = "/private" + cmd if cmd.startswith(("/var/", "/tmp/")) else cmd
            if pid == app_pid:
                found[pid] = "app"
            elif ppid == app_pid and " Helper" in cmd:
                found[pid] = "chromium-helper"
            elif cmd.startswith(tui):
                found[pid] = "terminal-host" if "__terminal-host" in cmd else "daemon"
            elif cmd.startswith(acpmux + " daemon run"):
                found[pid] = "acpmux"
            elif cmd.startswith(acpmux):
                found[pid] = "acpmux-helper"  # its router and per-agent hosts come and go with turns
            elif self.work in cmd and "fake_agent.py" in cmd:
                found[pid] = "agent"
            elif "com.apple.WebKit." in cmd and self.owns_webkit(pid, app_pid):
                found[pid] = "webkit"
        # A host's command line names neither the tag nor the bundle: the daemon's children and
        # the host records in the tag's state folder find them.
        for daemon in [pid for pid, kind in found.items() if kind == "daemon"]:
            for host in terminal_hosts(daemon, self.tag):
                found[host] = "terminal-host"
        return found

    def owns_webkit(self, pid, app_pid):
        """Whether the app is responsible for a WebKit process (launchd's child, so not by parent). Other
        apps' and iOS simulators' WebKit processes on the host do not count. Without the responsibility
        call on the host, every WebKit process started after the app counts (the old rule); a process the
        call has no answer for is not counted."""
        owner = responsible_pid(pid)
        return owner == app_pid if owner is not None else pid not in self.webkit_before

    def round_trip(self, method):
        """(milliseconds, None) on a good reply, else (milliseconds, (kind, text)): kind "slow" when no reply
        came within --hang-after, "error" for an instant failure (connect refused, a missing socket file, an
        error reply, a closed connection), with the error class and message. A good reply that took --hang-after
        or longer is slow too. An app that stops accepting fills its listen backlog, and macOS then refuses
        a connect at once, so that hang shows as an error (ConnectionRefusedError); it still fails the run."""
        started = time.monotonic()
        try:
            reply = Client(self.socket, timeout=self.args.hang_after).call(method)
            failure = ("error", f"{method}: error reply {json.dumps(reply['error'])[:300]}") if "error" in reply else None
        except (socket.timeout, TimeoutError) as error:
            failure = ("slow", f"{method}: no reply within {self.args.hang_after} s ({type(error).__name__})")
        except (OSError, ValueError) as error:
            failure = ("error", f"{method}: {type(error).__name__}: {error}")
        ms = round((time.monotonic() - started) * 1000, 1)
        if failure is None and ms >= self.args.hang_after * 1000:
            failure = ("slow", f"{method}: reply after {ms} ms")
        return ms, failure

    def check_control(self):
        """One system.ping and one snapshot.get. An instant failure is a control-error event with its text;
        only a reply slower than --hang-after (or none within it) is a hang."""
        ping_ms, ping_failure = self.round_trip("system.ping")
        snapshot_ms, snapshot_failure = self.round_trip("snapshot.get")
        failures = [f for f in (ping_failure, snapshot_failure) if f]
        timing = f"ping {ping_ms} ms, snapshot {snapshot_ms} ms"
        errors = [text for kind, text in failures if kind == "error"]
        if errors:
            self.event("control-error", f"control error: {'; '.join(errors)} ({timing})")
        slow = [text for kind, text in failures if kind == "slow"]
        if slow:
            self.event("hang", f"control round trip slow: {'; '.join(slow)} ({timing})")
        return ping_ms, snapshot_ms

    def crash_reports(self):
        """This copy's crash reports since the soak started (other builds' reports do not count)."""
        found = []
        for path in glob.glob(os.path.expanduser("~/Library/Logs/DiagnosticReports/*.ips")):
            name = os.path.basename(path).lower()
            if any(n in name for n in CRASH_NAMES) and os.path.getmtime(path) >= self.started and self.owns_report(path):
                found.append(path)
        return sorted(found)

    def owns_report(self, path):
        """Whether an .ips names this copy's bundle ID, a PID of this copy or a child of its app. A
        report still being written does not parse yet; it counts on a later tick, once it does."""
        try:
            with open(path, errors="replace") as handle:
                header = json.loads(handle.readline())
                if header.get("bundleID") == self.bundle_id:
                    return True
                body = json.loads(handle.read())
        except (OSError, ValueError):
            return False
        # parentPid: a helper that started and crashed between two ticks (acpmux hosts come and go with turns).
        return body.get("pid") in self.seen_pids or body.get("parentPid") in self.seen_pids | {self.app_pid} - {None}

    def check_sanitizer(self):
        """Each new sanitizer report is a crash event."""
        for found in self.sanitizer.poll() if self.sanitizer else []:
            self.sanitizer_count += 1
            pid = f"pid {found['pid']}, " if found["pid"] else ""
            self.event("crash", f"{found['tool']} report: {found['what']} ({pid}{os.path.basename(found['log'])})",
                       sanitizer=found)

    def check_chromium_off(self, kinds):
        """With Chromium off, a Chromium helper or a PartitionAlloc malloc zone in the app makes the run invalid.
        setup's malloc_zones is the last list vmmap read, with its time: a read that fails (the app aborted on a
        sanitizer report) keeps it."""
        if not self.chromium_off or any(e["kind"] == "chromium-loaded" for e in self.events):
            return
        self.zones_checked = time.monotonic()
        helpers = sorted(pid for pid, kind in kinds.items() if kind == "chromium-helper")
        zones = None
        if self.app_pid:
            try:
                listed = run("vmmap", "--summary", str(self.app_pid), timeout=300)
                zones = malloc_zones(listed.stdout) if listed.returncode == 0 else None
            except subprocess.TimeoutExpired:
                pass
        if zones is not None:
            self.setup["malloc_zones"], self.setup["malloc_zones_at"] = zones, now_iso()
        else:
            self.setup["malloc_zones_failed_at"] = now_iso()
        if helpers or "PartitionAlloc" in (zones or []):
            self.event("chromium-loaded", f"Chromium loaded in a {self.args.app_config} run: helpers {helpers}, "
                                          f"malloc zones {zones}")

    def check_zombies(self, kinds, elapsed):
        """Zombie children of this copy's processes (not WebKit's) seen on this sample and the one before; returns
        how many there are now."""
        parents = {pid: kind for pid, kind in kinds.items() if kind != "webkit"}
        now = set(zombies_in(run("ps", "-axo", "pid=,ppid=,stat=").stdout, parents))
        lasting = now & self.zombies_last
        for pid, ppid in sorted(lasting):
            if pid not in self.zombies:
                self.zombies[pid] = {"hour": int(elapsed // 3600), "parent": ppid, "parent_kind": parents.get(ppid)}
                say(f"zombie {pid}, a child of {parents.get(ppid)} {ppid}")
        self.zombies_last = now
        return len(lasting)

    def check_app_exit(self):
        """One crash event when the app this soak started has exited. BenchApp starts it as this process's child,
        so an exit that writes no crash report (a jetsam or other SIGKILL, a plain exit) leaves a zombie with the
        same PID: only the process's own state tells. poll() also reaps it. True when it has exited."""
        if self.app_exit is not None:
            return True
        code = self.bench.process.poll() if self.bench.process is not None else None
        if code is None:
            return False
        self.app_exit = code
        how = f"signal {-code}" if code < 0 else f"status {code}"
        self.event("crash", f"app {self.app_pid} exited ({how})", returncode=code)
        self.pids["app"] = []
        return True

    def track(self, kinds):
        """Remembers the PIDs whose crash reports are this copy's (not WebKit's: any app's)."""
        self.seen_pids.update(pid for pid, kind in kinds.items() if kind != "webkit")

    def sample(self, before, kinds, wall):
        rows = {}
        for pid, kind in kinds.items():
            first, last = before.get(pid), usage(pid)
            if first is None or last is None:
                continue
            row = rows.setdefault(kind, {"count": 0, "cpu_percent": 0.0, "footprint_mb": 0.0, "wakeups_per_s": 0.0, "fds": 0})
            row["count"] += 1
            row["fds"] += open_fds(pid) or 0
            row["cpu_percent"] += 100.0 * (last[0] - first[0]) / (wall * 1e9)
            row["wakeups_per_s"] += (last[1] - first[1]) / wall
            row["footprint_mb"] += last[2] / 1048576
        return {kind: {k: round(v, 2) if isinstance(v, float) else v for k, v in row.items()} for kind, row in rows.items()}

    def loop(self):
        end = time.monotonic() + self.args.hours * 3600
        # The last --idle seconds are quiet: no new turns, terminals stop printing, so what the app,
        # daemon and acpmux use then is their idle cost.
        quiet_at = end - self.args.idle
        quiet = False
        next_turn = {session: time.monotonic() + i * self.args.turn_every / max(len(self.agents), 1)
                     for i, session in enumerate(self.agents)}
        kinds = self.kinds()
        self.track(kinds)
        seen_reports = set(self.crash_reports())
        before = {pid: usage(pid) for pid in kinds}
        for key in ("app", "daemon", "acpmux"):
            self.pids[key] = sorted(pid for pid, kind in kinds.items() if kind == key)
        tick = time.monotonic()
        while time.monotonic() < end:
            time.sleep(self.args.sample)  # soak script: the sampling interval
            if not quiet and time.monotonic() >= quiet_at:
                quiet = True
                open(self.quiet_file, "w").close()
                self.quiet_stress()
                self.event("quiet", "no new turns; terminals stop printing")
            wall = time.monotonic() - tick
            tick = time.monotonic()
            processes = self.sample(before, kinds, wall)
            self.check_app_exit()
            kinds = self.kinds()
            self.track(kinds)
            before = {pid: usage(pid) for pid in kinds}
            for key in ("app", "daemon", "acpmux"):
                pids = sorted(pid for pid, kind in kinds.items() if kind == key)
                if pids != self.pids[key]:
                    self.event("crash" if not pids or key == "app" else "restart", f"{key} pids {self.pids[key]} -> {pids}")
                    self.pids[key] = pids
            reports = set(self.crash_reports())
            for path in sorted(reports - seen_reports):
                self.event("crash", f"crash report {os.path.basename(path)}")
            seen_reports = reports
            self.check_sanitizer()
            if self.chromium_off and (any(kind == "chromium-helper" for kind in kinds.values())
                                      or time.monotonic() - self.zones_checked >= ZONES_EVERY_S):
                self.check_chromium_off(kinds)
            zombies = self.check_zombies(kinds, time.time() - self.started)
            ping_ms, snapshot_ms = self.check_control()
            if self.nightly:
                self.nightly.poll()
            statuses = self.acp.sessions()
            for session, entry in self.agents.items():
                running = statuses.get(session) == "running"
                if entry["started"] is not None and not running:
                    entry["started"], entry["done"] = None, entry["done"] + 1
                if entry["started"] is not None and time.monotonic() - entry["started"] > STUCK_TURN_S:
                    self.event("stuck-turn", f"agent {session} turn {entry['turns']} running for over {STUCK_TURN_S} s")
                    entry["started"] = None
                if not quiet and entry["started"] is None and time.monotonic() >= next_turn[session]:
                    self.prompt(session)
                    next_turn[session] = time.monotonic() + self.args.turn_every
            record = {"at": now_iso(), "elapsed_s": round(time.time() - self.started), "processes": processes,
                      "phase": "quiet" if quiet else "load",
                      "running": sum(e["started"] is not None or statuses.get(session) == "running"
                                     for session, e in self.agents.items()),
                      "ping_ms": ping_ms, "snapshot_ms": snapshot_ms, "zombies": zombies,
                      "turns": sum(e["turns"] for e in self.agents.values()),
                      "turns_done": sum(e["done"] for e in self.agents.values()),
                      **(self.nightly.sample_fields() if self.nightly else {})}
            self.samples.write(json.dumps(record) + "\n")
            self.samples.flush()
        self.check_sanitizer()
        self.check_chromium_off(self.kinds())
        if self.nightly:
            self.nightly.poll(final=True)  # the time since the last sample; the app's table ends with its quit

    # ---- report --------------------------------------------------------------------------

    def report(self):
        stem = "report"
        if self.samples:
            self.samples.close()
            with open(os.path.join(self.out, "samples.jsonl")) as handle:
                samples = [json.loads(line) for line in handle if line.strip()]
        else:
            samples = []
            if os.path.exists(os.path.join(self.out, "samples.jsonl")):
                stem = "refused"  # --out holds another soak's run; keep its report
        warm = [s for s in samples if s["elapsed_s"] >= self.args.warmup]
        # Idle: quiet samples once every turn has ended and --settle seconds have passed.
        quiet_from = min((s["elapsed_s"] for s in samples if s.get("phase") == "quiet"), default=None)
        idle = [s for s in samples if quiet_from is not None and s["elapsed_s"] >= quiet_from + self.args.settle
                and not s.get("running")]
        # Growth is the middle of the load phase against its end: a bounded buffer (terminal scrollback, 50 MB
        # per copy) that fills in the first half passes, and a steady leak still shows half its growth. Each
        # window is an hour, or a quarter of a shorter load phase.
        load = [s for s in warm if s.get("phase", "load") == "load"]
        span = (load[-1]["elapsed_s"] - load[0]["elapsed_s"]) if load else 0
        window = min(3600, span / 4)
        middle = (load[0]["elapsed_s"] + span / 2) if load else 0
        first = [s for s in load if middle - window / 2 <= s["elapsed_s"] < middle + window / 2]
        last = [s for s in load if s["elapsed_s"] >= load[-1]["elapsed_s"] - window] if load else []
        kinds = sorted({k for s in samples for k in s["processes"]})
        summary, failures, warnings = {}, [], []

        def median(rows, kind, key):
            """perf_stats.pct at 0.5: the middle value, or the mean of the two middle ones."""
            return journey.percentile((s["processes"][kind].get(key) for s in rows if kind in s["processes"]), 0.5,
                                      digits=2)

        def mean(rows, kind, key):
            values = [s["processes"][kind][key] for s in rows if kind in s["processes"]]
            return round(sum(values) / len(values), 2) if values else None

        for kind in kinds:
            cpu = [s["processes"][kind]["cpu_percent"] for s in warm if kind in s["processes"]]
            summary[kind] = {
                "mean_cpu_percent": round(sum(cpu) / len(cpu), 2) if cpu else None,
                "max_cpu_percent": round(max(cpu), 2) if cpu else None,
                "footprint_mb_mid": median(first, kind, "footprint_mb"),
                "footprint_mb_end": median(last, kind, "footprint_mb"),
                "wakeups_per_s_median": median(warm, kind, "wakeups_per_s"),
                "fds_mid": median(first, kind, "fds"),
                "fds_end": median(last, kind, "fds"),
                "idle_cpu_percent": mean(idle, kind, "cpu_percent"),
                "idle_wakeups_per_s": mean(idle, kind, "wakeups_per_s"),
            }
            row = summary[kind]
            start_mb, end_mb = row["footprint_mb_mid"], row["footprint_mb_end"]
            if start_mb and end_mb and kind in ("app", "daemon", "acpmux"):
                growth = end_mb - start_mb
                row["growth_mb"], row["growth_percent"] = round(growth, 1), round(100 * growth / start_mb, 1)
                if growth > self.args.max_growth_mb and row["growth_percent"] > self.args.max_growth_percent:
                    failures.append(f"{kind} memory grew {growth:.0f} MB ({row['growth_percent']}%) from mid-run to the end of the load")
            start_fds, end_fds = row["fds_mid"], row["fds_end"]
            if start_fds is not None and end_fds is not None and kind in ("app", "daemon", "acpmux"):
                row["fd_growth"] = round(end_fds - start_fds)
                if row["fd_growth"] > self.args.max_fd_growth:
                    failures.append(f"{kind} open fds grew by {row['fd_growth']} ({start_fds:g} -> {end_fds:g}) from mid-run to the end of the load")
        for kind in ("app", "daemon", "acpmux"):
            if samples and kind not in summary:
                failures.append(f"no {kind} process was found, so its checks did not run")
        for kind, limit in (("app", self.args.max_app_cpu), ("daemon", self.args.max_daemon_cpu)):
            mean = (summary.get(kind) or {}).get("mean_cpu_percent")
            if mean is not None and mean > limit:
                failures.append(f"{kind} mean CPU {mean}% over {limit}%")
        if self.args.idle:
            if not idle:
                failures.append("no idle samples (the quiet phase never settled)")
            for kind, limit in (("app", self.args.max_idle_app_cpu), ("daemon", self.args.max_idle_daemon_cpu),
                                ("acpmux", self.args.max_idle_acpmux_cpu)):
                value = (summary.get(kind) or {}).get("idle_cpu_percent")
                if value is not None and value > limit:
                    (failures if self.args.idle_cpu_gate == "fail" else warnings).append(f"{kind} idle CPU {value}% over {limit}%")
        for kind in ("crash", "hang", "control-error", "stuck-turn", "blocking", "stall-250"):
            count = sum(1 for e in self.events if e["kind"] == kind)
            if count:
                failures.append(f"{count} {kind} event(s)")
        nightly = self.nightly.summary() if self.nightly else None
        if self.nightly:
            failures += self.nightly.problems()
        quit = self.setup.get("quit")
        code = quit["returncode"] if quit else 0
        if code != 0:
            how = (f"did not exit within {QUIT_WAIT_S} s" if code is None
                   else f"exited with signal {-code}" if code < 0 else f"exited with status {code}")
            request = f"; the request itself got no reply: {quit['error']}" if quit.get("error") else ""
            (failures if self.args.blocking_checks else warnings).append(
                f"quit: the app {how} after its quit request (it awaits work.shutdown() before it exits{request})")
        if any(e["kind"] == "chromium-loaded" for e in self.events):
            failures.append(f"invalid {self.args.app_config} run: Chromium loaded (its PartitionAlloc zone hides "
                            "allocations from the sanitizer)")
        elif self.args.app_config and not isinstance(self.setup.get("malloc_zones"), list):
            warnings.append("the app's malloc zones could not be read (vmmap), so Chromium off is not proven")
        if self.setup.get("stress_shape"):
            warnings.append(f"STRESS shape: {self.setup['stress_shape']}")
        if self.args.stress and not isinstance(self.setup.get("stress"), dict):
            failures.append(f"setup: STRESS {self.setup.get('stress', 'not built')}")
        zombies = self.zombie_summary(samples)
        if zombies["total"]:
            (failures if self.args.zombie_gate == "fail" else warnings).append(
                f"{zombies['total']} zombie children not reaped for a sample interval (by parent {zombies['by_parent_kind']})")
        for name in ("terminals", "browsers", "agents"):
            wanted, got = getattr(self.args, name), self.setup.get(name)
            if got != wanted:
                failures.append(f"setup: {got} of {wanted} {name}")
        if self.args.agents and samples and not samples[-1]["turns_done"]:
            failures.append("no agent turn finished")
        if self.setup.get("error"):
            failures = [f"setup stopped: {self.setup['error']}"]  # the rest follow from it
        hours = round((samples[-1]["elapsed_s"] if samples else 0) / 3600, 2)
        if hours < self.args.hours * 0.95:
            failures.append(f"ran {hours} h of {self.args.hours} h")
        pings = [s["snapshot_ms"] for s in samples]
        result = {"ok": not failures, "failures": failures, "warnings": warnings, "hours": hours, "setup": self.setup,
                  "app": self.app, "summary": summary, "events": self.events, "zombies": zombies,
                  "sanitizer": {"mode": self.args.app_config, "logs": self.setup.get("sanitizer_logs"),
                                "reports": self.sanitizer_count} if self.args.app_config else None,
                  "nightly": nightly,
                  "snapshot_ms_p50": journey.percentile(pings, 0.5, digits=1),
                  "snapshot_ms_p95": journey.percentile(pings, 0.95, digits=1),
                  "snapshot_ms_p99": journey.percentile(pings, 0.99, digits=1),
                  "turns": samples[-1]["turns"] if samples else 0, "turns_done": samples[-1]["turns_done"] if samples else 0}
        if getattr(self.args, "story", None):
            result["results"] = self.record(self.args.story, hours, warm, idle, summary, zombies, samples)
            if not journey.any_written(result["results"]):
                result["ok"] = False
                failures.append(f"result-v1: no series was written ({result['results']})")
        with open(os.path.join(self.out, f"{stem}.json"), "w") as handle:
            json.dump(result, handle, indent=1)
        lines = [f"# cmux-next readiness soak: {'PASS' if result['ok'] else 'FAIL'}", "",
                 f"Build {self.setup.get('identity', {}).get('build')} ({self.setup.get('identity', {}).get('version')}), "
                 f"{hours} h, {self.setup.get('agents')} agents ({result['turns_done']}/{result['turns']} turns done), "
                 f"{self.setup.get('terminals')} terminals, {self.setup.get('browsers')} {self.setup.get('browser_engine', '')} browser tabs.", ""]
        lines += [f"- FAIL: {failure}" for failure in failures] or ["- No failures."]
        lines += [f"- WARN: {warning}" for warning in warnings]
        lines += ["", f"Control round trip (snapshot.get): p50 {result['snapshot_ms_p50']} ms, "
                      f"p95 {result['snapshot_ms_p95']} ms, p99 {result['snapshot_ms_p99']} ms.",
                  f"Zombie children: {zombies['total']} in all, per hour {zombies['per_hour']}, at the end {zombies['at_end']}."]
        if self.args.app_config:
            lines.append(f"App config {self.args.app_config} (Chromium off): {self.sanitizer_count} sanitizer report(s) "
                         f"in {self.setup.get('sanitizer_logs')}, malloc zones {self.setup.get('malloc_zones', 'never read')} "
                         f"(read at {self.setup.get('malloc_zones_at')}).")
        if nightly:
            app, daemon = nightly["app"], nightly["daemon"]
            lines.append(f"Nightly config ({nightly['config']}): {app['sites']} app blocking site(s) {app['by_context']}, "
                         f"{daemon['sites']} daemon site(s), overflow app {app['overflow']} / daemon {daemon['overflow']}; "
                         f"debug.hangs count250 {nightly['count250']}, count100 {nightly['count100']}, thread hangs "
                         f"{nightly['thread_hangs']}; reads app {app['reads']} ({app['failed_reads']} failed), daemon "
                         f"{daemon['reads']} ({daemon['failed_reads']} failed).")
        if quit:
            lines.append(f"Quit: return code {quit['returncode']} after {quit['seconds']} s.")
        lines += ["",
                  "| Process | Mean CPU % | Max CPU % | Memory mid-run (MB) | Memory end (MB) | Wakeups/s | fds mid-run | fds end | Idle CPU % | Idle wakeups/s |",
                  "| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |"]
        for kind, row in summary.items():
            lines.append(f"| {kind} | {row['mean_cpu_percent']} | {row['max_cpu_percent']} | {row['footprint_mb_mid']} | "
                         f"{row['footprint_mb_end']} | {row['wakeups_per_s_median']} | {row['fds_mid']} | "
                         f"{row['fds_end']} | {row['idle_cpu_percent']} | {row['idle_wakeups_per_s']} |")
        # Trend: memory and fds of the app, daemon and acpmux at about twelve points, so a slow leak shows its slope.
        if samples:
            step = max(1, len(samples) // 12)
            lines += ["", "Trend (memory MB / open fds):", "",
                      "| Elapsed min | Phase | app | daemon | acpmux |", "| --- | --- | --- | --- | --- |"]
            for s in samples[::step] + ([samples[-1]] if (len(samples) - 1) % step else []):
                cells = [f"{s['processes'][k]['footprint_mb']:g} / {s['processes'][k].get('fds')}" if k in s["processes"] else "-"
                         for k in ("app", "daemon", "acpmux")]
                lines.append(f"| {s['elapsed_s'] // 60} | {s.get('phase', 'load')} | " + " | ".join(cells) + " |")
        if self.events:
            lines += ["", "Events:"] + [f"- {e['at']} {e['kind']}: {e['detail']}" for e in self.events]
        with open(os.path.join(self.out, f"{stem}.md"), "w") as handle:
            handle.write("\n".join(lines) + "\n")
        print("\n".join(lines))
        return result

    def record(self, story, hours, warm, idle, summary, zombies, samples):
        """A soak that ran its whole length, under `story`: {metric: path or `not recorded: why`}, or why none was
        written. Its failed criteria (a crash, a hang, growth) still record: the series show them."""
        if not getattr(self, "completed", False) or self.setup.get("error"):
            return "none: the soak stopped before its end"
        if hours < self.args.hours * 0.95:
            return f"none: ran {hours} h of {self.args.hours} h"
        engine = journey.soak_engine(self.args.app_config, self.args.browsers)
        ran = self.setup.get("browser_engine", engine) if self.args.browsers else "none"
        if ran != engine:
            return f"none: the browser tabs ran on {ran}, the story's engine is {engine}"
        series = journey.soak_series(warm, idle, summary, self.events, zombies["total"], samples)
        return journey.record_all(self.bench, story, engine, series, log=say)

    def zombie_summary(self, samples):
        """Zombie children in all, per elapsed hour (by the hour each was first counted), by parent kind and at the
        last sample."""
        hours = int(samples[-1]["elapsed_s"] // 3600) + 1 if samples else 0
        per_hour = [0] * hours
        by_parent = {}
        for zombie in self.zombies.values():
            if zombie["hour"] < hours:
                per_hour[zombie["hour"]] += 1
            by_parent[str(zombie["parent_kind"])] = by_parent.get(str(zombie["parent_kind"]), 0) + 1
        return {"total": len(self.zombies), "per_hour": per_hour, "by_parent_kind": by_parent,
                "at_end": samples[-1].get("zombies") if samples else None}

    def finish(self):
        """Quits the app (`quit`, which waits for its exit) and reads the sanitizer logs once more: an ASan report
        written during quit (a deinit-order use-after-free) and LeakSanitizer's, which comes only at exit, are this
        run's too."""
        self.quit()
        self.check_sanitizer()

    def quit(self):
        """The app's own quit with end-everything, then BenchApp.stop for an app that is still up (debug.quit, then
        TERM and KILL of the PID it started); the tag's daemons are the soak's TagTeardown's. setup's `quit` is how an
        app still up at the end took its quit request: its return code (None: still running after QUIT_WAIT_S) and
        the seconds it took. The app's exit is the answer to the request: it may close its socket before it replies,
        or reply late at the end of STRESS, so a failed request is kept as context and the exit wait still runs."""
        asked, failed = None, None
        try:
            self.write_config("end-everything")
            time.sleep(2)  # soak script: the app reloads cmux.json from its file watcher
            asked = time.monotonic()
            try:
                # A remembered End Everything no longer deletes workspaces on a
                # scripted quit (it keeps them); the flag asks for it outright.
                Client(self.socket, timeout=10).call("action.run", {"action": "quit", "args": {"endEverything": True}, "wait": False})
            except (OSError, ValueError, KeyError) as error:
                failed = f"{type(error).__name__}: {error}"
                say(f"quit: the request got no reply ({failed}); waiting for the app to exit")
            wait(lambda: self.bench.process.poll() is not None, QUIT_WAIT_S - (time.monotonic() - asked))
        except (OSError, ValueError, KeyError) as error:
            say(f"quit: {error}")
        finally:
            if asked is not None and self.app_exit is None:
                self.setup["quit"] = {"returncode": self.bench.process.poll(),
                                      "seconds": round(time.monotonic() - asked, 1), "error": failed}
            self.bench.stop()


def parse_args(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help="a copy of a tagged cmux-next app (bundle com.cmuxterm.app.debug.<tag>)")
    parser.add_argument("--socket", help="the app's control socket (default ~/.local/state/cmux/cmux-debug-<tag>.sock)")
    parser.add_argument("--same-tag", action="store_true",
                        help="run --app as it is instead of a copy with its own bundle id and tag")
    parser.add_argument("--hours", type=float, default=24)
    parser.add_argument("--agents", type=int, default=10)
    parser.add_argument("--terminals", type=int, default=10)
    parser.add_argument("--browsers", type=int, default=4)
    parser.add_argument("--sample", type=float, default=60)
    parser.add_argument("--turn-every", type=float, default=300)
    parser.add_argument("--warmup", type=float, default=900, help="seconds before the first-hour memory baseline")
    parser.add_argument("--hang-after", type=float, default=10)
    parser.add_argument("--max-growth-mb", type=float, default=300)
    parser.add_argument("--max-growth-percent", type=float, default=25)
    parser.add_argument("--max-app-cpu", type=float, default=10)
    parser.add_argument("--max-daemon-cpu", type=float, default=5)
    parser.add_argument("--max-fd-growth", type=float, default=100,
                        help="open fds the app, daemon or acpmux may gain from mid-run to the end of the load")
    parser.add_argument("--idle", type=float, default=1800,
                        help="seconds at the end with no new turns and quiet terminals (0: none)")
    parser.add_argument("--settle", type=float, default=300, help="seconds into the quiet phase before idle samples count")
    parser.add_argument("--max-idle-app-cpu", type=float, default=1)
    parser.add_argument("--max-idle-daemon-cpu", type=float, default=0.5)
    parser.add_argument("--max-idle-acpmux-cpu", type=float, default=0.5)
    parser.add_argument("--idle-cpu-gate", choices=("warn", "fail"), default="warn",
                        help="an idle CPU over its limit warns (default, until a 24h report shows real idle numbers) or fails")
    parser.add_argument("--zombie-gate", choices=("warn", "fail"), default="warn",
                        help="a zombie child warns (default, until a 24h report shows the real count) or fails")
    parser.add_argument("--app-config", choices=tuple(SANITIZER_RUNTIMES),
                        help="a sanitizer build of the app: Chromium off, its reports are crash events")
    parser.add_argument("--blocking-checks", action="store_true",
                        help="soak the Nightly configuration (a --config bench-checks build): each blocking site, "
                             "count250 stall and unclean quit fails the run (p02-threads RUN-9)")
    parser.add_argument("--stress", action="store_true", help="build the STRESS session (perf-stress-session.py) first")
    parser.add_argument("--out", default=os.path.join(os.getcwd(), "readiness-soak"))
    parser.add_argument("--story", help="write a soak that ran its whole length as cmux-perf-result/v1 under this story")
    parser.add_argument("--tag", help="the story runner's tag of --app (checked against it; the soak runs its own copy)")
    parser.add_argument("--session", choices=["light", "stress"],
                        help="result-v1 session (the story runner's): stress needs --stress, light a soak without it")
    args = parser.parse_args(argv)
    if args.session and (args.session == "stress") != args.stress:
        parser.error(f"--session {args.session} does not match {'--stress' if args.stress else 'a soak without --stress'}")
    if args.blocking_checks and args.app_config:
        parser.error("--blocking-checks does not go with --app-config: a sanitizer build is not the Nightly configuration")
    if args.blocking_checks and args.story:
        parser.error(f"--story does not go with --blocking-checks: the soak story's lab config is bench, not {NIGHTLY_CONFIG}")
    if args.warmup + args.idle >= args.hours * 3600:
        parser.error("--warmup plus --idle must leave a load phase within --hours")  # else every load check is empty
    if args.story:
        if args.app_config:
            parser.error("--story does not go with --app-config: a sanitizer build is not a lab config")
        problem = (story_problem(args.story, journey.soak_engine(args.app_config, args.browsers))
                   or journey.story_session_problem(args.story, "stress" if args.stress else "light"))
        if problem:
            parser.error(problem)
    return args


def main(argv=None):
    args = parse_args(argv)
    if args.tag and tag_of(args.app) != args.tag:
        raise SystemExit(f"readiness-soak: --tag {args.tag} is not the tag of {args.app} ({tag_of(args.app)})")
    soak = Soak(args)
    teardown = None
    result = {"ok": False}
    try:
        soak.identify()
        soak.preflight()
        soak.begin()
        teardown = TagTeardown(soak.app, acpmux_home=soak.acpmux_home, acpmux_socket=soak.acp.path, log=say)
        teardown.install()
        soak.launch()
        if args.stress:
            soak.start_stress()
        soak.start_terminals()
        soak.start_browsers()
        soak.start_agents()
        soak.check_chromium_off(soak.kinds())
        say(f"setup: {json.dumps(soak.setup)}")
        soak.stage = "run"
        soak.loop()
        soak.completed = True
    except SystemExit as stop:
        if soak.stage == "setup":
            # A refused or failed setup still writes report.json and report.md, naming why.
            soak.setup["error"] = str(stop.code)
        else:
            soak.event("stopped", f"the soak was stopped ({stop.code}); the report covers what ran")
        raise
    finally:
        try:
            if "identity" in soak.setup:
                soak.finish()  # before the report, so the reports written at teardown count
        finally:
            try:
                result = soak.report()
            finally:
                if soak.stress:
                    soak.stress.close()
                if teardown:
                    teardown.end()
                    soak.forget()
                shutil.rmtree(soak.work, ignore_errors=True)
    sys.exit(0 if result.get("ok") else 1)


if __name__ == "__main__":
    main()
