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
          (`owner-hangs-<session>.jsonl`, named in the reply's `hang_log`). The daemon's cmux-hang-watch
          threads (task 073: `mux-control-dispatch`, `mux-terminal-work`, the journal writer, and `mux-conn` and
          `mux-line-out` under the same names) are armed the same way; their record is a `hangs-<pid>.jsonl` line.
  holder  the holder loop (`holder-loop`): armed through the daemon for the holder's pid; the holder sends its
          hang to the daemon, which writes it to the same hang log.
  host, acpmux
          threads registered with cmux-hang-watch in a terminal host or acpmux: armed through the daemon for
          that pid; the record is a line of `hangs-<pid>.jsonl` in `--rust-hang-dir`.

Each lane blocks for at least 3 s, and longer when its hang tier is later (a lane's block is its tier plus
BLOCK_MARGIN), so its tier is always reached while it is busy. A lane PASSES when exactly 1 new record names it,
that record has at least MIN_FRAMES frames (MIN_FRAMES_X86 on x86_64), and the watcher saw it within its tier
plus its watcher's minimum deadline plus 1 s. A lane the build does not register is NOT-REGISTERED, one whose
work did not run within TRIGGER_SECONDS is NOT-TRIGGERED, and one the script cannot tell is registered (a daemon
with no lane registry, or a full registry) is UNKNOWN; all three count as not passed.

Which lanes are registered: the app's `debug.hang_inject` reply lists its HangWatch names; the daemon's
`debug-hang-inject` reply lists its request-watchdog lanes and the registry of the injection page, where every
debug process publishes the lanes it watches with its pid (`registered`). Every registered lane of the app and of
this tag's processes that LANES does not name is added with a default tier (EXTRA_TIER_MS), so no registered lane
goes unblocked.

Fatal case (skipped by --skip-fatal): the app is launched with CMUX_NEXT_SENTRY_RECORDER=<dir> (task 086), the
main thread is kept busy for 5 s, the script SIGKILLs the app it started after FATAL_KILL_AFTER seconds, launches
it again and expects exactly 1 recorded envelope of a fatal app hang (task 110).

Soak (`--soak MINUTES`, done check 7 uses 10): the app is launched again with the STRESS session
(perf-stress-session.py, as bench-typing.py --stress builds it), then typing and tab churn for that long, then 0 new
hang records of any lane. Only hang-tier records count: thread hangs, daemon and cmux-hang-watch hang lines, and
main-thread stalls of at least the main lane's tier (MAIN_HANG_TIER_MS); a shorter stall is a jank, not a hang.
A machine sleep never counts as a hang because the watchers measure on a clock that does not run in sleep and blame
nobody after a late wake; that rule is tested with an injected clock (SLEEP_CLOCK_TESTS). A real
sleep runs only with --exclusive-host: `pmset schedule wake` 90 s ahead, `pmset sleepnow`, then 0 new records.

Writes hang-matrix.json to --out (default $NX_ARTIFACTS or a temp dir). Exit 0 only when every lane run passed
(and the fatal case and the soak, when run). Signals only the app process it started.
"""
import argparse, dataclasses, datetime, glob, importlib.util, json, os, platform, signal, socket, subprocess, sys
import tempfile, threading, time

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
# The main thread's hang tier: a main stall shorter than this is a jank, not a hang record.
MAIN_HANG_TIER_MS = 250
# The tier of a registered lane LANES does not name: its owner's budget is not known here, so its block covers the
# longest lane budget (an app lane's bound does not depend on its budget; a cmux-hang-watch record carries its own).
EXTRA_TIER_MS = 10_000
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
    # False for a registered lane LANES does not name (added by extra_lanes with EXTRA_TIER_MS).
    known: bool = True

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
    Lane("main", "main", MAIN_HANG_TIER_MS, APP_PERIOD_MS, "none"),
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
    # The daemon's cmux-hang-watch threads (task 073), by thread name; `mux-conn` and `mux-line-out` are the lanes
    # above (one arm per name and pid: whichever of the two scopes opens first takes it). A request's deadline is
    # its MethodClass's (1 to 10 s): the block covers 10 s, and the bound is the record's own deadline.
    daemon_lane("mux-control-dispatch", 10_000, "daemon"),
    daemon_lane("mux-terminal-work", 5_000, "activity"),
    daemon_lane("mux-session-journal-writer", 5_000, "activity"),
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
    # The scope's own deadline when the record carries it (cmux-hang-watch); 0 otherwise.
    deadline_ms: float = 0.0


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
                              source="hangs-<pid>.jsonl", deadline_ms=float(row.get("deadline_ms") or 0)))
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
    bound = record_bound_ms(lane, record)
    if seen > bound:
        return "FAIL", f"seen {seen:.0f} ms after the scope opened (bound {bound:.0f} ms)"
    return "PASS", f"thread {record.thread or '?'}, {record.frames} frames, seen at {seen:.0f} ms (bound {bound:.0f})"


def record_bound_ms(lane, record):
    """The lane's bound, from the record's own deadline when it carries one (a cmux-hang-watch scope's deadline is
    its work's, for example a request's MethodClass), else from the lane's tier."""
    if lane.process != "app" and record.deadline_ms:
        return record.deadline_ms + lane.period_ms + 1_000
    return lane.bound_ms


def hang_tier(records):
    """The records that are hangs: every thread hang, daemon hang line and cmux-hang-watch line, and the main
    thread's stalls of at least MAIN_HANG_TIER_MS (MainThreadWatchdog records stalls from 50 ms, which are janks)."""
    return [record for record in records
            if not (record.lane == "main" and record.source == "debug.hangs"
                    and record.seen_after_ms < MAIN_HANG_TIER_MS)]


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


def registry_rows(reply):
    """The (lane, pid) pairs of the daemon reply's lane registry, or None when the daemon has no registry."""
    rows = (reply or {}).get("registered")
    if not isinstance(rows, list):
        return None
    return {(str(row.get("lane")), row.get("pid")) for row in rows if isinstance(row, dict)}


def lane_registered(name, pid, reply, own_lanes=()):
    """True, False or None (cannot tell): whether process `pid` registers `name`, from `own_lanes` (names the
    process lists itself) and the daemon reply's registry. A registry with no free registration may have refused
    the lane, so a missing lane is None then."""
    if name in own_lanes:
        return True
    rows = registry_rows(reply)
    if rows is None or pid is None:
        return None
    if (name, pid) in rows:
        return True
    return None if (reply or {}).get("registrations_free") == 0 else False


def extra_lanes(lanes, app_names, reply, roles):
    """Lanes for every registered name `lanes` does not name: the app's (`app_names`, its debug.hang_inject
    `lanes`) and the registry's lanes of this tag's processes (`roles`: {pid: daemon|holder|host|acpmux})."""
    named = {lane.name for lane in lanes}
    extra = []
    for name in sorted(set(app_names or ()) - named - {"main"}):
        extra.append(dataclasses.replace(app_lane(name, EXTRA_TIER_MS - APP_HANG_AFTER_MS, "activity"), known=False))
        named.add(name)
    periods = {"daemon": DAEMON_PERIOD_MS, "holder": HOLDER_PERIOD_MS}
    for name, pid in sorted(registry_rows(reply) or (), key=lambda row: (str(row[0]), str(row[1]))):
        role = roles.get(pid)
        if role is None or name in named:
            continue
        extra.append(Lane(name, role, EXTRA_TIER_MS, periods.get(role, RUST_WATCH_PERIOD_MS), "activity", known=False))
        named.add(name)
    return tuple(extra)


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


def arm_waits(entries, lane, pid):
    """Whether the page holds an untaken arm of `lane` for `pid` (the page is the user's: other tags' and earlier
    runs' entries for other pids are not this run's arm)."""
    return any(isinstance(entry, dict) and entry.get("lane") == lane and entry.get("pid") == pid
               and not entry.get("taken") for entry in entries or [])


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
        self.arm_pid = None  # the pid the daemon armed the current lane for (its reply's `for_pid`)
        self.results = []

    # The app and its sockets.
    def launch(self, env=None, fresh_state=True, perf_session="light"):
        self.app = self.bench_launch.BenchApp(self.opts.app, out=self.out, env=env or {}, fresh_state=fresh_state,
                                              perf_session=perf_session)
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
    def roles(self):
        """{pid: role} of this tag's daemon, holder, hosts and acpmux."""
        roles = {pid: classify_process(command) for pid, command in self.app.tag_processes()}
        roles = {pid: role for pid, role in roles.items() if role}
        if isinstance(self.daemon_reply.get("pid"), int):
            roles[self.daemon_reply["pid"]] = "daemon"
        return roles

    def pid_of(self, role):
        if role == "daemon":
            return self.daemon_reply.get("pid")
        found = [pid for pid, command in self.app.tag_processes() if classify_process(command) == role]
        return found[0] if found else None

    def arm(self, lane):
        """(armed, detail): arms `lane` in its process. An app arm counts by the reply's `armed_lane`: a busy lane
        may take the arm before the reply reads `armed`."""
        if lane.process == "app":
            reply = self.rpc("debug.hang_inject", {"lane": lane.name, "ms": lane.block_ms}, timeout=10)
            if isinstance(reply, dict) and reply.get("armed_lane") == lane.name:
                return True, ""
            return False, str((reply or {}).get("error"))
        pid = None if lane.process == "daemon" else self.pid_of(lane.process)
        if lane.process != "daemon" and pid is None:
            return False, f"no {lane.process} process of this tag"
        self.arm_pid = None
        request = {"id": 2, "cmd": "debug-hang-inject", "lane": lane.name, "ms": lane.block_ms}
        if pid is not None:
            request["pid"] = pid
        reply = daemon_rpc(self.daemon, request)
        self.arm_pid = (reply.get("data") or {}).get("for_pid") if reply.get("ok") else None
        return bool(reply.get("ok")), str(reply.get("error") or "")

    def armed(self, lane):
        """Whether `lane`'s arm still waits for its scope."""
        if lane.process == "app":
            return (self.rpc("debug.hang_inject", {"action": "list"}, timeout=40) or {}).get("armed") == lane.name
        return arm_waits((self.daemon_list() or {}).get("entries"), lane.name, self.arm_pid)

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

    def app_lanes(self):
        return (self.rpc("debug.hang_inject", {"action": "list"}, timeout=10) or {}).get("lanes") or []

    def registered(self, lane):
        """True, False or None (cannot tell) for `lane` in its process."""
        if lane.process == "app":
            return lane.name in self.app_lanes()
        own = [row.get("name") for row in self.daemon_reply.get("lanes") or []] if lane.process == "daemon" else []
        return lane_registered(lane.name, self.pid_of(lane.process), self.daemon_list(), own)

    def run_lane(self, lane):
        if self.app.process.poll() is not None:
            return "FAIL", "the app is not running"
        if lane.process == "main":
            return self.run_main(lane)
        if lane.process not in ("app", "daemon") and self.pid_of(lane.process) is None:
            return "NOT-MEASURABLE", f"no {lane.process} process of this tag"
        registered = self.registered(lane)
        if registered is not True:
            self.trigger(lane.trigger)  # a thread that registers at its first work
            registered = self.registered(lane)
        if registered is None:
            return "UNKNOWN", (f"cannot tell whether the {lane.process} registers {lane.name} "
                               "(no lane registry, or it is full)")
        if not registered:
            return "NOT-REGISTERED", f"the {lane.process} registers no {lane.name}"
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
        lanes += extra_lanes(lanes, self.app_lanes(), self.daemon_list(), self.roles())
        if self.opts.only:
            lanes = tuple(lane for lane in lanes if lane.name in self.opts.only)
        for lane in lanes:
            status, detail = self.run_lane(lane)
            if not lane.known:
                detail += " (a registered lane the matrix does not name: default tier)"
            print(f"{status:15} {lane.process:7} {lane.name:22} block {lane.block_ms} ms: {detail}", flush=True)
            self.results.append({"lane": lane.name, "process": lane.process, "status": status, "detail": detail,
                                 "block_ms": lane.block_ms, "bound_ms": lane.bound_ms, "in_matrix": lane.known})

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
    def build_stress(self):
        """Launches the app again with the STRESS session and builds it (perf-stress-session.py, as bench-typing.py
        --stress does): (the session's summary, "") or (None, why)."""
        self.stop()
        self.launch(perf_session="stress")
        path = os.path.join(HERE, "perf-stress-session.py")
        spec = importlib.util.spec_from_file_location("perf_stress_session", path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        try:
            summary = module.Stress(self.rpc, log=lambda text: print(text, flush=True)).build()
        except module.StressShapeError as error:
            return None, str(error)
        print("STRESS-SESSION " + json.dumps(summary), flush=True)
        return summary, ""

    def run_soak(self, minutes):
        session, why = self.build_stress()
        if session is None:
            detail = f"the STRESS session was not built: {why}"
            print(f"{'NOT-MEASURABLE':15} soak    {detail}")
            self.results.append({"lane": "soak", "process": "all", "status": "NOT-MEASURABLE", "detail": detail,
                                 "session": "stress"})
            return
        cursor = self.cursor()
        end = time.monotonic() + minutes * 60
        while time.monotonic() < end and self.app.process.poll() is None:
            for _ in range(20):
                self.trigger("typing")
            self.trigger("activity")
            self.rpc("action.run", {"action": "closeTab", "args": {}, "focus": False, "origin": "script"}, timeout=40)
        records = hang_tier(self.new_records(cursor))
        status = "PASS" if not records else "FAIL"
        detail = f"{len(records)} hang records in {minutes:g} min of STRESS typing and tab churn (want 0)"
        print(f"{status:15} soak    {detail}")
        self.results.append({"lane": "soak", "process": "all", "status": status, "detail": detail,
                             "session": "stress", "session_shape": session,
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
        records = hang_tier(self.new_records(cursor))
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

    check(len(hang_tier(stalls + [dataclasses.replace(stalls[0], seen_after_ms=60)])) == 1,
          "a 60 ms main stall is a jank: the soak does not count it")
    check(len(hang_tier(records + daemon + [dataclasses.replace(stalls[0], seen_after_ms=250)])) == 5,
          "thread hangs, daemon lines and a 250 ms main stall are hangs")

    dispatch = next(lane for lane in LANES if lane.name == "mux-control-dispatch")
    query = rust_watch_lines(json.dumps({"schema": 1, "thread": "mux-control-dispatch", "deadline_ms": 1000,
                                         "overdue_ms": 900, "stack": {"frames": [{}] * 6}}))
    check(judge(dispatch, query, "arm64")[0] == "PASS" and "bound 3000" in judge(dispatch, query, "arm64")[1],
          "a hang-watch record's bound is its own deadline's")
    late_query = [dataclasses.replace(query[0], seen_after_ms=3_500)]
    check(judge(dispatch, late_query, "arm64")[0] == "FAIL", "past its own deadline's bound fails")
    check(dispatch.block_ms > 10_000 + DAEMON_PERIOD_MS, "the dispatch block covers a 10 s MethodClass")

    page = [{"lane": "mux-conn", "pid": 11, "taken": False}, {"lane": "mux-conn", "pid": 12, "taken": True}]
    check(not arm_waits(page, "mux-conn", 12), "another pid's untaken arm is not this run's")
    check(arm_waits(page, "mux-conn", 11) and not arm_waits(page, "holder-link", 11), "an untaken arm of the pid waits")
    check(not arm_waits(None, "mux-conn", 11), "no entries")

    reply = {"registered": [{"lane": "host-pty", "pid": 30}, {"lane": "acpmux-sync", "pid": 40},
                            {"lane": "mux-control-dispatch", "pid": 20}, {"lane": "other-tag", "pid": 99}],
             "registrations_free": 3}
    check(lane_registered("host-pty", 30, reply) is True, "a registered host lane")
    check(lane_registered("host-parser", 30, reply) is False, "an unregistered host lane is NOT-REGISTERED")
    check(lane_registered("host-pty", 31, reply) is False, "another host's registration is not this one's")
    check(lane_registered("host-parser", 30, dict(reply, registrations_free=0)) is None, "a full registry: UNKNOWN")
    check(lane_registered("host-parser", 30, {}) is None, "no registry: UNKNOWN")
    check(lane_registered("mux-conn", 20, {}, ["mux-conn"]) is True, "a daemon's own lane")
    check(lane_registered("host-pty", None, reply) is None, "no process: UNKNOWN")

    roles = {20: "daemon", 30: "host", 40: "acpmux"}
    extra = extra_lanes(LANES, ["main", "daemon.line", "terminal-output", "localpty"],
                        dict(reply, registered=reply["registered"] + [{"lane": "mux-journal-x", "pid": 20}]), roles)
    by_name = {lane.name: lane for lane in extra}
    check(set(by_name) == {"terminal-output", "localpty", "mux-journal-x"},
          f"every registered name LANES lacks is a lane ({sorted(by_name)})")
    check(by_name["terminal-output"].process == "app" and not by_name["terminal-output"].known
          and by_name["terminal-output"].block_ms > EXTRA_TIER_MS, "an extra app lane blocks past the default tier")
    check(by_name["mux-journal-x"].process == "daemon", "an extra daemon lane is armed for the daemon")

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
