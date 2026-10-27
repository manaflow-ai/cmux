#!/usr/bin/env python3
"""Hang matrix: one hang record per watched lane, and the fatal hang (p09-observability done check 7, task 088).

  hang-matrix.py --app "cmux DEV <tag>.app" [--out DIR] [--only LANE,...] [--skip-fatal] [--soak MINUTES]
                 [--exclusive-host] [--rust-hang-dir DIR]
  hang-matrix.py --self-test

`--app` defaults to $NX_APP. The app is a tagged Debug or bench build: `debug.hang_inject` and the daemon's
`debug-hang-inject` are compiled out of Release, so a Release build answers neither and every lane is
NOT-MEASURABLE.

Lanes (LANES, by process):

  app     a lane of the app's hang watch (HangWatch, CmuxNextTrace): `debug.hang_inject {lane, ms}` arms it and
          its next scope stays busy for `ms` inside the scope. The record is a `debug.hangs` `thread_hangs` entry
          (a scope still open `hangAfterBudget`, 2 s, past its budget), with the thread's sampled frames.
  main    the main thread: `debug.hang_inject {lane: "main", ms}` keeps it busy in the request's own turn; the
          record is a `debug.hangs` stall record.
  daemon  a scope of the daemon's request watchdog (`mux-conn`, `journal-writer`, ...): the daemon's
          `debug-hang-inject {lane, ms}` arms it; the record is a line of the daemon's hang log
          (`owner-hangs-<session>.jsonl`, named in the reply's `hang_log`).
  holder  the holder loop (`holder-loop`): armed through the daemon for the holder's pid; the holder sends its
          hang to the daemon, which writes it to the same hang log.
  host, acpmux
          threads registered with cmux-hang-watch in a terminal host or acpmux: armed through the daemon for
          that pid; the record is a line of `hangs-<pid>.jsonl` in `--rust-hang-dir`.

Each lane blocks for at least 3 s, and longer when its hang tier is later (a lane's block is its tier plus
BLOCK_MARGIN), so its tier is always reached while it is busy. A lane PASSES when exactly 1 new record names it,
that record has at least MIN_FRAMES frames (MIN_FRAMES_X86 on x86_64), and the watcher saw it within its tier
plus its watcher's minimum deadline plus 1 s. A lane the build does not register is NOT-REGISTERED, one whose
work did not run within TRIGGER_SECONDS is NOT-TRIGGERED; both count as not passed.

Fatal case (skipped by --skip-fatal): the app is launched with CMUX_NEXT_SENTRY_RECORDER=<dir> (task 086), the
main thread is kept busy for 5 s, the script SIGKILLs the app it started after FATAL_KILL_AFTER seconds, launches
it again and expects exactly 1 recorded envelope of a fatal app hang (task 110).

Soak (`--soak MINUTES`, done check 7 uses 10): STRESS typing and tab churn for that long, then 0 new hang records
of any lane. A machine sleep never counts as a hang because the watchers measure on a clock that does not run in
sleep and blame nobody after a late wake; that rule is tested with an injected clock (SLEEP_CLOCK_TESTS). A real
sleep runs only with --exclusive-host: `pmset schedule wake` 90 s ahead, `pmset sleepnow`, then 0 new records.

Writes hang-matrix.json to --out (default $NX_ARTIFACTS or a temp dir). Exit 0 only when every lane run passed
(and the fatal case and the soak, when run). Signals only the app process it started.
"""
import argparse, dataclasses, datetime, glob, json, os, platform, signal, socket, subprocess, sys, tempfile, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))

# The shortest block (done check 7: "blocks each registered lane for 3 s").
MIN_BLOCK_MS = 3_000
# A lane's block past its hang tier, so the watcher reaches the tier while the lane is still busy.
BLOCK_MARGIN_MS = 1_500
# The longest block an arm may ask for (HangWatch.maxInjectedHang, cmux_threads::hang_inject::MAX_BLOCK).
MAX_BLOCK_MS = 30_000
# Frames a record must carry (done check 7).
MIN_FRAMES, MIN_FRAMES_X86 = 5, 3
# How long a lane's work is triggered before the lane counts as NOT-TRIGGERED.
TRIGGER_SECONDS = 20
TRIGGER_EVERY = 0.5
# The app's hang tier past a scope's budget (HangWatch.hangAfterBudget) and its monitor period.
APP_HANG_AFTER_MS, APP_PERIOD_MS = 2_000, 100
# The daemon request watchdog's period (REQUEST_WATCHDOG_THRESHOLD) and the holder watcher's.
DAEMON_PERIOD_MS, HOLDER_PERIOD_MS = 1_000, 100
# cmux-hang-watch's default minimum deadline (Config::min_deadline).
RUST_WATCH_PERIOD_MS = 1_000
# The fatal case: how long main is busy, and when the script kills the app.
FATAL_HANG_MS, FATAL_KILL_AFTER = 5_000, 3.0
FATAL_RELAUNCH_WAIT = 30
FATAL_MARKERS = ("fatal app hang",)
# The tests that prove a sleep is not a hang, on an injected clock.
SLEEP_CLOCK_TESTS = (
    "swift test --filter HangWatchMonitorDriftTests",
    "cargo test -p cmux-hang-watch a_late_watcher_blames_nobody",
    "cargo test -p cmux-threads a_late_watcher_blames_nobody_and_does_not_record_the_scope_later",
)
SLEEP_WAKE_AFTER = 90


@dataclasses.dataclass(frozen=True)
class Lane:
    """One watched lane: its name as registered, the process that runs it, its hang tier (ms from the moment the
    lane's scope opens to its hang record's tier), its watcher's period, and how the script makes it run work."""
    name: str
    process: str
    tier_ms: int
    period_ms: int
    trigger: str

    @property
    def block_ms(self):
        return min(MAX_BLOCK_MS, max(MIN_BLOCK_MS, self.tier_ms + self.period_ms + BLOCK_MARGIN_MS))

    @property
    def bound_ms(self):
        """The latest the watcher may see the hang, from the scope's open (done check 7)."""
        return self.tier_ms + self.period_ms + 1_000


def app_lane(name, budget_ms, trigger):
    return Lane(name, "app", budget_ms + APP_HANG_AFTER_MS, APP_PERIOD_MS, trigger)


def daemon_lane(name, hang_ms, trigger):
    return Lane(name, "daemon", hang_ms, DAEMON_PERIOD_MS, trigger)


# Every lane done check 7 names. The app lanes' budgets are their owners' deadlines (LineTransport, SocketWriter,
# LocalPTYTerminalIO, TerminalOutputLane, ControlSocketServer, ControlConnection, BackgroundWork, BlockingDetector);
# the daemon lanes' tiers are read from the daemon's own reply when it answers (`lanes`), these are the defaults.
# The last app lanes belong to later tasks: until their owners register them, they are NOT-REGISTERED.
LANES = (
    Lane("main", "main", 250, APP_PERIOD_MS, "none"),
    app_lane("daemon.line", 100, "typing"),
    app_lane("daemon.write", 2_000, "typing"),
    app_lane("terminal.feed", 100, "typing"),
    app_lane("localpty.read", 1_000, "typing"),
    app_lane("localpty.write", 2_000, "typing"),
    app_lane("control.accept", 1_000, "control"),
    app_lane("control.connection", 1_000, "control"),
    app_lane("lane.files", 5_000, "activity"),
    app_lane("lane.system", 10_000, "activity"),
    app_lane("lane.cpu", 10_000, "activity"),
    app_lane("blocking.drain", 10_000, "activity"),
    app_lane("ghostty.renderer", 100, "typing"),
    app_lane("chromium.io", 1_000, "activity"),
    app_lane("remote.view", 100, "activity"),
    app_lane("acpmux.pane", 1_000, "activity"),
    daemon_lane("mux-conn", 2_000, "daemon"),
    daemon_lane("journal-writer", 2_000, "activity"),
    daemon_lane("holder-link", 1_000, "typing"),
    daemon_lane("mux-line-out", 100, "daemon"),
    daemon_lane("mux-pty-input", 100, "typing"),
    daemon_lane("mux-attach-out", 100, "typing"),
    daemon_lane("mux-render-attach-out", 100, "typing"),
    Lane("holder-loop", "holder", 100, HOLDER_PERIOD_MS, "typing"),
    Lane("host-pty", "host", 1_000, RUST_WATCH_PERIOD_MS, "typing"),
    Lane("host-parser", "host", 1_000, RUST_WATCH_PERIOD_MS, "typing"),
    Lane("acpmux-sync", "acpmux", 1_000, RUST_WATCH_PERIOD_MS, "activity"),
    Lane("acpmux-runtime", "acpmux", 1_000, RUST_WATCH_PERIOD_MS, "activity"),
)


@dataclasses.dataclass
class Record:
    """One hang record, as the script judges it."""
    lane: str
    thread: str
    frames: int
    seen_after_ms: float
    source: str


# ----------------------------------------------------------------------------------------------- record parsers

def app_thread_hangs(reply):
    """`debug.hangs` `thread_hangs` entries as Records: the scope's name, the thread, the frames, and when the
    monitor saw it from the scope's open (its budget plus the overrun at the sample)."""
    records = []
    for entry in (reply or {}).get("thread_hangs") or []:
        records.append(Record(lane=str(entry.get("scope") or ""), thread=str(entry.get("thread") or ""),
                              frames=len(entry.get("frames") or []),
                              seen_after_ms=float(entry.get("duration_ms") or 0.0), source="debug.hangs"))
    return records


def app_stalls(reply):
    """`debug.hangs` stall records (the main thread's) as Records of lane `main`."""
    return [Record(lane="main", thread="main", frames=len(entry.get("frames") or []),
                   seen_after_ms=float(entry.get("duration_ms") or 0.0), source="debug.hangs")
            for entry in (reply or {}).get("records") or [] if entry.get("kind") in ("stall", "busy")]


def last_sequence(entries):
    """The highest `sequence` of `debug.hangs` entries (0 for none): the cursor its `*_after` inputs take."""
    return max((int(entry.get("sequence") or 0) for entry in entries or [] if isinstance(entry, dict)), default=0)


def daemon_hang_lines(text):
    """Lines of a daemon hang log (`{"event": "hang", "scope", "busy_ms", "hang_ms", "stack": [...]}`) as Records;
    a line that does not parse is skipped."""
    records = []
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict) or row.get("event") != "hang":
            continue
        busy, hang = float(row.get("busy_ms") or 0), float(row.get("hang_ms") or 0)
        records.append(Record(lane=str(row.get("scope") or ""), thread=str(row.get("method") or ""),
                              frames=len(row.get("stack") or []), seen_after_ms=busy if busy else hang,
                              source="daemon hang log"))
    return records


def rust_watch_lines(text):
    """Lines of cmux-hang-watch's `hangs-<pid>.jsonl` (schema 1) as Records: the registered thread name is the
    lane, and the watcher saw it `deadline_ms + overdue_ms` after the scope opened."""
    records = []
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            continue
        if not isinstance(row, dict) or row.get("schema") != 1:
            continue
        frames = (row.get("stack") or {}).get("frames") or [] if isinstance(row.get("stack"), dict) else row.get("stack") or []
        records.append(Record(lane=str(row.get("thread") or ""), thread=str(row.get("thread") or ""),
                              frames=len(frames),
                              seen_after_ms=float(row.get("deadline_ms") or 0) + float(row.get("overdue_ms") or 0),
                              source="hangs-<pid>.jsonl"))
    return records


def envelope_is_fatal_hang(raw):
    """Whether a recorded Sentry envelope (newline-separated JSON: header, then item headers and payloads) holds a
    fatal app hang event (task 110's message), in its message or an exception's value."""
    for line in raw.splitlines():
        try:
            item = json.loads(line)
        except ValueError:
            continue
        if not isinstance(item, dict):
            continue
        texts = []
        message = item.get("message")
        texts.append(message.get("formatted") or message.get("message") or "" if isinstance(message, dict) else message or "")
        for exception in ((item.get("exception") or {}).get("values") or []):
            texts.extend([exception.get("value") or "", exception.get("type") or ""])
        if any(marker in str(text).lower() for text in texts for marker in FATAL_MARKERS):
            return True
    return False


# ----------------------------------------------------------------------------------------------- judging

def min_frames(machine=None):
    return MIN_FRAMES_X86 if (machine or platform.machine()) == "x86_64" else MIN_FRAMES


def judge(lane, records, machine=None):
    """(status, detail) of one lane from the new records: PASS when exactly one names the lane, with enough frames,
    within its bound. The main thread's record is a stall the watchdog writes when the turn ends: it counts when it
    lasted most of the block (other short stalls may come and go), and its time is its length, not a bound."""
    mine = [record for record in records if record.lane == lane.name]
    if lane.process == "main":
        mine = [record for record in mine if record.seen_after_ms >= 0.9 * lane.block_ms]
    if len(mine) != 1:
        return "FAIL", f"{len(mine)} records name {lane.name} (want exactly 1)"
    record, need = mine[0], min_frames(machine)
    if record.frames < need:
        return "FAIL", f"{record.frames} frames (want >= {need}) in {record.source}"
    seen = lane_seen_ms(lane, record)
    if lane.process == "main":
        return "PASS", f"a {seen:.0f} ms stall with {record.frames} frames"
    if seen > lane.bound_ms:
        return "FAIL", f"seen {seen:.0f} ms after the scope opened (bound {lane.bound_ms} ms)"
    return "PASS", f"thread {record.thread or '?'}, {record.frames} frames, seen at {seen:.0f} ms (bound {lane.bound_ms})"


def lane_seen_ms(lane, record):
    """When the watcher saw the record, from the scope's open: an app thread hang reports its overrun past the
    budget (so the budget is added back); the other sources report from the open already."""
    if lane.process == "app":
        return lane.tier_ms - APP_HANG_AFTER_MS + record.seen_after_ms
    return record.seen_after_ms


def lanes_with_daemon_tiers(lanes, reply):
    """`lanes` with the daemon lanes' tiers the daemon reported (`lanes: [{name, hang_ms}]`)."""
    tiers = {row.get("name"): row.get("hang_ms") for row in (reply or {}).get("lanes") or [] if isinstance(row, dict)}
    return tuple(dataclasses.replace(lane, tier_ms=int(tiers[lane.name]))
                 if lane.process == "daemon" and isinstance(tiers.get(lane.name), int) else lane for lane in lanes)


def classify_process(command):
    """The role of one of the tag's processes for the matrix: holder, host, acpmux or None."""
    words = command.split()
    if not words:
        return None
    if os.path.basename(words[0]) == "cmux-holder" or " __holder " in f" {command} ":
        return "holder"
    if "acpmux" in os.path.basename(words[0]) and " daemon run" in f" {command}":
        return "acpmux"
    if "--owner" in words:
        return "host"
    return None


def pmset_wake_time(now):
    """`pmset schedule wake`'s date for SLEEP_WAKE_AFTER seconds after `now` (MM/dd/yy HH:mm:ss)."""
    return (now + datetime.timedelta(seconds=SLEEP_WAKE_AFTER)).strftime("%m/%d/%y %H:%M:%S")


# ----------------------------------------------------------------------------------------------- the daemon socket

def daemon_rpc(path, request, timeout=10):
    """One newline-JSON request on the daemon's socket; the reply object, or {"ok": false, "error": ...}."""
    try:
        conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        conn.settimeout(timeout)
        conn.connect(path)
        conn.sendall((json.dumps(request) + "\n").encode())
        buf = b""
        while not buf.endswith(b"\n"):
            chunk = conn.recv(1 << 20)
            if not chunk:
                break
            buf += chunk
        conn.close()
        return json.loads(buf.splitlines()[0]) if buf else {"ok": False, "error": "no reply"}
    except (OSError, ValueError, IndexError) as error:
        return {"ok": False, "error": str(error)}


# ----------------------------------------------------------------------------------------------- the run

class Matrix:
    def __init__(self, opts):
        import bench_launch
        import bench_tagged
        self.bench_launch, self.bench_tagged = bench_launch, bench_tagged
        self.opts = opts
        self.out = opts.out
        self.app = None
        self.daemon = None
        self.daemon_reply = {}
        self.results = []

    # The app and its sockets.
    def launch(self, env=None, fresh_state=True):
        self.app = self.bench_launch.BenchApp(self.opts.app, out=self.out, env=env or {}, fresh_state=fresh_state)
        self.app.launch()
        self.daemon = self.bench_tagged.daemon_socket(self.app.tag)
        self.daemon_reply = self.daemon_list()

    def stop(self):
        if self.app is not None:
            self.app.stop()
            self.app = None

    def rpc(self, method, params=None, timeout=60):
        return self.app.rpc(method, params, timeout)

    def daemon_list(self):
        reply = daemon_rpc(self.daemon, {"id": 1, "cmd": "debug-hang-inject", "action": "list"})
        return reply.get("data") if reply.get("ok") else {"error": reply.get("error")}

    # Records of every source, as cursors to read only what is new.
    def cursor(self):
        hangs = self.rpc("debug.hangs", {}) or {}
        log = self.daemon_reply.get("hang_log")
        rust = {path: os.path.getsize(path) for path in self.rust_logs()}
        return {"thread_hangs": last_sequence(hangs.get("thread_hangs")), "stalls": last_sequence(hangs.get("records")),
                "daemon_log": os.path.getsize(log) if log and os.path.exists(log) else 0, "rust": rust}

    def rust_logs(self):
        return glob.glob(os.path.join(self.opts.rust_hang_dir, "hangs-*.jsonl")) if self.opts.rust_hang_dir else []

    def new_records(self, cursor):
        records = []
        hangs = self.rpc("debug.hangs", {"thread_hangs_after": cursor["thread_hangs"], "after": cursor["stalls"]}) or {}
        records += app_thread_hangs(hangs) + app_stalls(hangs)
        log = self.daemon_reply.get("hang_log")
        if log and os.path.exists(log):
            with open(log, encoding="utf-8", errors="replace") as handle:
                handle.seek(cursor["daemon_log"])
                records += daemon_hang_lines(handle.read())
        for path in self.rust_logs():
            with open(path, encoding="utf-8", errors="replace") as handle:
                handle.seek(cursor["rust"].get(path, 0))
                records += rust_watch_lines(handle.read())
        return records

    # Arming and triggering.
    def pid_of(self, role):
        found = [pid for pid, command in self.app.tag_processes() if classify_process(command) == role]
        return found[0] if found else None

    def arm(self, lane):
        """(armed, detail): arms `lane` in its process."""
        if lane.process == "app":
            reply = self.rpc("debug.hang_inject", {"lane": lane.name, "ms": lane.block_ms}, timeout=10)
            if isinstance(reply, dict) and reply.get("armed") == lane.name:
                return True, ""
            return False, str((reply or {}).get("error"))
        pid = None if lane.process == "daemon" else self.pid_of(lane.process)
        if lane.process != "daemon" and pid is None:
            return False, f"no {lane.process} process of this tag"
        request = {"id": 2, "cmd": "debug-hang-inject", "lane": lane.name, "ms": lane.block_ms}
        if pid is not None:
            request["pid"] = pid
        reply = daemon_rpc(self.daemon, request)
        return bool(reply.get("ok")), str(reply.get("error") or "")

    def armed(self, lane):
        """Whether `lane`'s arm still waits for its scope."""
        if lane.process == "app":
            return (self.rpc("debug.hang_inject", {"action": "list"}, timeout=40) or {}).get("armed") == lane.name
        entries = (self.daemon_list() or {}).get("entries") or []
        return any(entry.get("lane") == lane.name and not entry.get("taken") for entry in entries)

    def disarm(self, lane):
        if lane.process == "app":
            self.rpc("debug.hang_inject", {"action": "disarm"}, timeout=10)
            return
        pid = None if lane.process == "daemon" else self.pid_of(lane.process)
        request = {"id": 3, "cmd": "debug-hang-inject", "action": "disarm", "lane": lane.name}
        if pid is not None:
            request["pid"] = pid
        daemon_rpc(self.daemon, request)

    def trigger(self, kind):
        """One round of work for a lane of trigger `kind`."""
        if kind in ("typing", "activity"):
            self.rpc("debug.key", {"key": "a"}, timeout=40)
            self.rpc("debug.key", {"key": "delete"}, timeout=40)
        if kind in ("control", "activity"):
            self.rpc("system.ping", timeout=40)
        if kind == "activity":
            self.rpc("action.run", {"action": "newTab", "args": {}, "focus": False, "origin": "script"}, timeout=40)
            self.rpc("debug.work", {}, timeout=40)
        if kind == "daemon":
            daemon_rpc(self.daemon, {"id": 4, "cmd": "identify"}, timeout=40)

    def registered(self, lane):
        if lane.process == "app":
            lanes = (self.rpc("debug.hang_inject", {"action": "list"}, timeout=10) or {}).get("lanes") or []
            return lane.name in lanes
        if lane.process == "daemon":
            return any(row.get("name") == lane.name for row in self.daemon_reply.get("lanes") or [])
        return True  # another process: its arm is taken only by a thread that registered the name

    def run_lane(self, lane):
        if self.app.process.poll() is not None:
            return "FAIL", "the app is not running"
        if lane.process == "main":
            return self.run_main(lane)
        if not self.registered(lane):
            return "NOT-REGISTERED", f"this build registers no {lane.name}"
        cursor = self.cursor()
        armed, why = self.arm(lane)
        if not armed:
            return "NOT-MEASURABLE", f"arm refused: {why}"
        deadline = time.monotonic() + TRIGGER_SECONDS
        while self.armed(lane):
            if time.monotonic() > deadline:
                self.disarm(lane)
                return "NOT-TRIGGERED", f"no {lane.name} scope opened within {TRIGGER_SECONDS} s"
            self.trigger(lane.trigger)
            time.sleep(TRIGGER_EVERY)  # harness: trigger pacing until the lane takes its arm
        time.sleep((lane.block_ms + lane.period_ms + 1_500) / 1000)  # harness: the block and its report
        return judge(lane, self.new_records(cursor))

    def run_main(self, lane):
        cursor = self.cursor()
        reply = self.rpc("debug.hang_inject", {"lane": "main", "ms": lane.block_ms}, timeout=lane.block_ms / 1000 + 30)
        if not isinstance(reply, dict) or "hung_main_ms" not in reply:
            return "NOT-MEASURABLE", f"debug.hang_inject main: {reply}"
        time.sleep(1.0)  # harness: the watchdog writes the stall after the turn ends
        return judge(lane, self.new_records(cursor))

    def run_lanes(self):
        lanes = lanes_with_daemon_tiers(LANES, self.daemon_reply)
        if self.opts.only:
            lanes = tuple(lane for lane in lanes if lane.name in self.opts.only)
        for lane in lanes:
            status, detail = self.run_lane(lane)
            print(f"{status:15} {lane.process:7} {lane.name:22} block {lane.block_ms} ms: {detail}", flush=True)
            self.results.append({"lane": lane.name, "process": lane.process, "status": status, "detail": detail,
                                 "block_ms": lane.block_ms, "bound_ms": lane.bound_ms})

    # The fatal case.
    def run_fatal(self):
        recorder = tempfile.mkdtemp(prefix="hang-matrix-recorder-", dir=self.out)
        env = {"CMUX_NEXT_SENTRY_RECORDER": recorder}
        self.launch(env)
        hung = threading.Thread(target=lambda: self.rpc("debug.hang_inject", {"lane": "main", "ms": FATAL_HANG_MS},
                                                        timeout=FATAL_HANG_MS / 1000 + 10), daemon=True)
        hung.start()
        time.sleep(FATAL_KILL_AFTER)  # harness: kill while the main thread is past the 2 s fatal-hang mark
        pid = self.app.process.pid
        os.kill(pid, signal.SIGKILL)  # the app process this script started
        self.app.process.wait(10)
        self.stop()
        self.launch(env, fresh_state=False)  # the run marker and the hang page of the killed launch stay
        deadline = time.monotonic() + FATAL_RELAUNCH_WAIT
        fatal = []
        while time.monotonic() < deadline:
            fatal = [path for path in glob.glob(os.path.join(recorder, "**", "*"), recursive=True)
                     if os.path.isfile(path) and envelope_is_fatal_hang(open(path, encoding="utf-8", errors="replace").read())]
            if fatal:
                time.sleep(2)  # harness: a duplicate would land right after the first
                break
            time.sleep(0.5)  # harness: the relaunch sends the report off main
        fatal = [path for path in glob.glob(os.path.join(recorder, "**", "*"), recursive=True)
                 if os.path.isfile(path) and envelope_is_fatal_hang(open(path, encoding="utf-8", errors="replace").read())]
        status = "PASS" if len(fatal) == 1 else "FAIL"
        detail = f"{len(fatal)} fatal-hang envelopes in {recorder} (want exactly 1)"
        print(f"{status:15} fatal   main blocked {FATAL_HANG_MS} ms, SIGKILL at {FATAL_KILL_AFTER:g} s: {detail}")
        self.results.append({"lane": "fatal", "process": "app", "status": status, "detail": detail})
        self.stop()

    # The soak.
    def run_soak(self, minutes):
        cursor = self.cursor()
        end = time.monotonic() + minutes * 60
        while time.monotonic() < end and self.app.process.poll() is None:
            for _ in range(20):
                self.trigger("typing")
            self.trigger("activity")
            self.rpc("action.run", {"action": "closeTab", "args": {}, "focus": False, "origin": "script"}, timeout=40)
        records = self.new_records(cursor)
        status = "PASS" if not records else "FAIL"
        detail = f"{len(records)} hang records in {minutes:g} min of STRESS typing and tab churn (want 0)"
        print(f"{status:15} soak    {detail}")
        self.results.append({"lane": "soak", "process": "all", "status": status, "detail": detail,
                             "records": [dataclasses.asdict(record) for record in records]})
        self.run_sleep()

    def run_sleep(self):
        if not self.opts.exclusive_host:
            detail = "no real sleep without --exclusive-host; covered by " + "; ".join(SLEEP_CLOCK_TESTS)
            print(f"{'SKIPPED':15} sleep   {detail}")
            self.results.append({"lane": "sleep", "process": "all", "status": "SKIPPED", "detail": detail})
            return
        cursor = self.cursor()
        when = pmset_wake_time(datetime.datetime.now())
        scheduled = subprocess.run(["sudo", "-n", "pmset", "schedule", "wake", when], capture_output=True, text=True)
        if scheduled.returncode != 0:
            detail = f"pmset schedule wake refused: {scheduled.stderr.strip()[:200]}"
            print(f"{'NOT-MEASURABLE':15} sleep   {detail}")
            self.results.append({"lane": "sleep", "process": "all", "status": "NOT-MEASURABLE", "detail": detail})
            return
        subprocess.run(["pmset", "sleepnow"], capture_output=True)
        time.sleep(SLEEP_WAKE_AFTER + 30)  # harness: the scheduled wake and the watchers' first pass after it
        records = self.new_records(cursor)
        status = "PASS" if not records else "FAIL"
        detail = f"{len(records)} hang records across a real sleep woken by pmset at {when} (want 0)"
        print(f"{status:15} sleep   {detail}")
        self.results.append({"lane": "sleep", "process": "all", "status": status, "detail": detail})

    def run(self):
        try:
            self.launch()
            if not self.daemon_reply or "error" in self.daemon_reply:
                print(f"hang-matrix: the daemon answers no debug-hang-inject ({self.daemon_reply}); a Release build?")
            self.run_lanes()
            if self.opts.soak:
                self.run_soak(self.opts.soak)
            self.stop()
            if not self.opts.skip_fatal:
                self.run_fatal()
        finally:
            self.stop()
        summary = {"schema": 1, "app": self.opts.app, "machine": platform.machine(), "results": self.results}
        path = os.path.join(self.out, "hang-matrix.json")
        with open(path, "w") as handle:
            json.dump(summary, handle, indent=2)
        passed = all(row["status"] in ("PASS", "SKIPPED") for row in self.results)
        print(f"hang-matrix: {sum(row['status'] == 'PASS' for row in self.results)}/{len(self.results)} passed; {path}")
        return 0 if passed and self.results else 1


# ----------------------------------------------------------------------------------------------- self-test

def self_test():
    """Checks the lane table, the parsers, the judge and the helpers on fixtures; no app."""
    failures = []

    def check(condition, what):
        if not condition:
            failures.append(what)

    names = [lane.name for lane in LANES]
    check(len(names) == len(set(names)), "lane names are unique")
    for lane in LANES:
        check(lane.block_ms >= MIN_BLOCK_MS, f"{lane.name}: block at least 3 s")
        check(lane.block_ms <= MAX_BLOCK_MS, f"{lane.name}: block at most the injector's maximum")
        check(lane.block_ms > lane.tier_ms + lane.period_ms, f"{lane.name}: the block outlasts the tier")
        check(lane.trigger in ("none", "typing", "control", "activity", "daemon"), f"{lane.name}: known trigger")
        check(lane.process in ("main", "app", "daemon", "holder", "host", "acpmux"), f"{lane.name}: known process")
        check(len(lane.name) <= 32 and all(c.islower() or c.isdigit() or c in "._-" for c in lane.name),
              f"{lane.name}: an injectable name")
    check(app_lane("lane.system", 10_000, "activity").block_ms == 13_600, "a 10 s lane blocks past its 12 s tier")

    hangs = {"thread_hangs": [
        {"kind": "hang", "scope": "daemon.line", "thread": "com.cmuxterm.daemon.reader", "duration_ms": 2050.5,
         "start_uptime_ns": 5e9, "frames": ["a", "b", "c", "d", "e", "f"]},
        {"kind": "hang", "scope": "terminal.feed", "thread": "t", "duration_ms": 9000, "frames": ["a"]},
    ], "records": [{"kind": "stall", "duration_ms": 3010, "frames": ["m"] * 7}, {"kind": "over_budget"}]}
    records = app_thread_hangs(hangs)
    check([r.lane for r in records] == ["daemon.line", "terminal.feed"], "thread hangs parse their scopes")
    check(records[0].frames == 6 and records[0].thread.endswith("reader"), "thread hangs keep frames and thread")
    check(last_sequence([{"sequence": 4}, {"sequence": 9}, {}]) == 9 and last_sequence(None) == 0, "cursors")
    stalls = app_stalls(hangs)
    check(len(stalls) == 1 and stalls[0].lane == "main" and stalls[0].frames == 7, "stall records become main")

    line = app_lane("daemon.line", 100, "typing")
    check(judge(line, records, "arm64")[0] == "PASS", "one daemon.line record with 6 frames within its bound passes")
    check(judge(line, records + records[:1], "arm64")[0] == "FAIL", "two records fail")
    check(judge(line, [], "arm64")[0] == "FAIL", "no record fails")
    feed = app_lane("terminal.feed", 100, "typing")
    check("frames" in judge(feed, records, "arm64")[1], "one frame fails on arm64")
    late = [dataclasses.replace(records[0], seen_after_ms=APP_HANG_AFTER_MS + APP_PERIOD_MS + 1_001)]
    check("bound" in judge(line, late, "arm64")[1], "a record seen past the bound fails")
    three = [dataclasses.replace(records[0], frames=3)]
    check(judge(line, three, "x86_64")[0] == "PASS" and judge(line, three, "arm64")[0] == "FAIL",
          "x86_64 needs 3 frames, arm64 5")

    log = "\n".join([
        json.dumps({"event": "hang", "scope": "mux-conn", "method": "identify", "hang_ms": 2000, "busy_ms": 2400,
                    "stack": [{"image": "cmux-tui", "offset": 1}] * 9}),
        "not json",
        json.dumps({"event": "hang", "scope": "holder-loop", "method": "pass", "hang_ms": 100, "busy_ms": 150,
                    "stack": [], "stack_error": "other-process"}),
        json.dumps({"event": "slow"}),
    ])
    daemon = daemon_hang_lines(log)
    check([r.lane for r in daemon] == ["mux-conn", "holder-loop"], "the daemon log parses its hang lines")
    check(judge(daemon_lane("mux-conn", 2000, "daemon"), daemon, "arm64")[0] == "PASS", "a daemon hang passes")
    holder = Lane("holder-loop", "holder", 100, HOLDER_PERIOD_MS, "typing")
    check(judge(holder, daemon, "arm64")[0] == "FAIL", "a holder hang with no stack fails the frame rule")
    main_lane = LANES[0]
    check(judge(main_lane, stalls, "arm64")[0] == "PASS", "the main block's stall passes")
    short = [dataclasses.replace(stalls[0], seen_after_ms=400)]
    check(judge(main_lane, stalls + short, "arm64")[0] == "PASS", "a short unrelated stall is not the block")
    check(judge(main_lane, short, "arm64")[0] == "FAIL", "no stall of the block's length fails")

    rust = rust_watch_lines(json.dumps({"schema": 1, "pid": 4, "thread": "host-pty", "kind": "io", "deadline_ms": 1000,
                                        "overdue_ms": 250, "stack": {"frames": [{"image_id": "x", "offset": 1}] * 5}}))
    check(len(rust) == 1 and rust[0].lane == "host-pty" and rust[0].seen_after_ms == 1250 and rust[0].frames == 5,
          "cmux-hang-watch lines parse")

    tiers = lanes_with_daemon_tiers(LANES, {"lanes": [{"name": "mux-conn", "hang_ms": 4000}, {"name": "x"}]})
    check(next(l for l in tiers if l.name == "mux-conn").tier_ms == 4000, "the daemon's own tiers win")
    check(next(l for l in tiers if l.name == "journal-writer").tier_ms == 2000, "a tier the daemon omits stays")

    header = json.dumps({"event_id": "0" * 32})
    fatal = "\n".join([header, json.dumps({"type": "event"}),
                       json.dumps({"level": "fatal", "exception": {"values": [{"type": "AppHang",
                                                                                "value": "Fatal app hang: main busy 5 s"}]}})])
    check(envelope_is_fatal_hang(fatal), "a fatal app hang envelope is found by its exception")
    check(envelope_is_fatal_hang(json.dumps({"message": {"formatted": "fatal app hang"}})), "or by its message")
    check(not envelope_is_fatal_hang("\n".join([header, json.dumps({"message": "app hang"})])),
          "a plain app hang is not a fatal one")
    check(not envelope_is_fatal_hang("garbage\n\x00"), "garbage is not an envelope")

    check(classify_process("/x/cmux-holder --socket /tmp/cmux-hd-501/ab.sock") == "holder", "the standalone holder")
    check(classify_process("/x/cmux-tui __holder --socket s --owner b:t@1") == "holder", "the built-in holder")
    check(classify_process("/cache/cmux-tui-host-abc --owner com.cmuxterm.next:t@12 --terminal 3") == "host",
          "a terminal host")
    check(classify_process("/x/Resources/bin/acpmux daemon run --socket s") == "acpmux", "acpmux")
    check(classify_process("/bin/zsh -l") is None, "a shell is none of them")

    when = pmset_wake_time(datetime.datetime(2026, 10, 27, 23, 59, 0))
    check(when == "10/28/26 00:00:30", f"pmset wake date ({when})")

    parsed = parse_args(["--app", "/A.app", "--only", "mux-conn,main", "--soak", "10"])
    check(parsed.only == {"mux-conn", "main"} and parsed.soak == 10.0, "the arguments parse")

    for failure in failures:
        print(f"FAIL {failure}")
    print(f"hang-matrix self-test: {'ok' if not failures else f'{len(failures)} failed'}")
    return 1 if failures else 0


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", default=os.environ.get("NX_APP"))
    parser.add_argument("--out", default=os.environ.get("NX_ARTIFACTS"))
    parser.add_argument("--only", type=lambda text: {name for name in text.split(",") if name})
    parser.add_argument("--skip-fatal", action="store_true")
    parser.add_argument("--soak", type=float, default=0.0, help="minutes of STRESS soak (done check 7: 10)")
    parser.add_argument("--exclusive-host", action="store_true", help="allow a real sleep (pmset schedule wake)")
    parser.add_argument("--rust-hang-dir", help="where cmux-hang-watch writes hangs-<pid>.jsonl")
    parser.add_argument("--self-test", action="store_true")
    return parser.parse_args(argv)


def main(argv=None):
    opts = parse_args(sys.argv[1:] if argv is None else argv)
    if opts.self_test:
        return self_test()
    if not opts.app:
        print("hang-matrix: give --app or set NX_APP", file=sys.stderr)
        return 2
    opts.out = os.path.abspath(opts.out or tempfile.mkdtemp(prefix="hang-matrix-"))
    os.makedirs(opts.out, exist_ok=True)
    sys.path.insert(0, HERE)
    return Matrix(opts).run()


if __name__ == "__main__":
    sys.exit(main())
