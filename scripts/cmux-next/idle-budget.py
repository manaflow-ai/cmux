#!/usr/bin/env python3
"""Idle thread and wakeup budget of cmux NEXT (Lawrence's threading list, item 6; plans/cmux-next/idle-wakeups.md).

Idle means no input, no visible change, terminals quiet. At idle every cmux process should sleep: the
app's main thread 0 wakeups a second, the app <= 1/s, the cmux-tui daemon <= 1/s, the holder 0, and
each process's thread count capped. This script launches a tagged app (bench_launch.BenchApp), builds a
session, lets it settle, then measures one window with no input and reports, per process:

  threads, wakeups/s (package idle + interrupt wakeups, proc_pid_rusage, what `top -stats idlew` and
  Activity Monitor show), context switches/s, CPU %, and the threads that ran in the window (CPU time
  per thread, PROC_PIDTHREADID64INFO: the thread names show which loop woke);
  for the app also main_wakes/s (the main run loop's wakes from sleep, debug.hangs `main_wakes`) and,
  when the build has it, the wakeup ledger's owners (debug.wakeups: DemandTimer, FrameScheduler,
  Backoff by owner and reason);
  D15 (plans/cmux-next/chrome-parity/p14-energy.md): disk bytes written (ri_diskio_byteswritten delta),
  network bytes, the lo0 part and connections open at the end (nettop over the window), unified-log
  lines and their subsystem:category owners (`log show` of the pid set after the window), and
  WindowServer's wakeups/s against a reference window with cmux hidden (reported, never judged).
  A reader that fails leaves its values null ("not measured") and prints IDLE-BUDGET-READER-FAILED.

The script reads the app's counters only at the window's two ends (proc_pid_rusage of another process
does not wake it; the two socket reads sit outside the process counters' window; nettop and `log show`
ask the kernel and logd), so the bench adds no wakeup to what it measures.

Sessions (--sessions):
  light         the launch window with its terminal (Home's pages run in Chromium by default)
  light-webkit  the same with browser.defaultEngine webkit: no Chromium at all
  light-hidden  the light session with the app hidden (Show/Hide All Windows hidden=true)
  Each session starts from an empty saved session (`fresh_session`).
  stress-static  STRESS with its pages served without their rAF spinner (STRESS's own pages animate: not idle)
  stress   STRESS (scripts/cmux-next/perf-stress-session.py: 60 workspaces, a 12-pane grid of 6 tabs each,
           Chromium pages elsewhere); its 10 busy terminals are stopped (Ctrl-C) before the settle, so the
           terminals are quiet

A session that fails (STRESS refuses a window under the Dock, a launch fails) is recorded with its exit
code (`session_exits` in the report) and the others still run; the script exits 0 unless --gate.

Budget: scripts/cmux-next/idle-budget.json (per process kind; a missing value is reported, not judged;
`all_kinds` limits judge every measured kind, `allowed_periodic` entries excuse a named kind's metric).
Over budget prints IDLE-BUDGET-OVER lines (a disk, network or log over names its pids, remote ends or log
owners); the exit code is 0 unless --gate (no CI gate: the perf cron runs it and reports).

Use (fleet only, a host with a GUI console session; never on a laptop in use):
  python3 scripts/cmux-next/idle-budget.py --app "<...>/cmux DEV <tag>.app" --out DIR \\
      [--sessions light,stress] [--settle 60] [--measure 60] [--json DIR/idle-budget.json]
  On the fleet through the allowlisted entry (STRESS needs the 1920 x 1080 virtual display):
    scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 [...]

Output: one `IDLE-BUDGET-MACHINE {json}` line, one `IDLE-BUDGET-ROW {json}` line per session and process
kind, a Markdown table, and --json with every sample.
"""
import argparse, ctypes, json, os, platform, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "perf-bench"))
import procs  # noqa: E402  (process set of one app: descendants, bundle processes, responsible XPC processes)

BUDGET_FILE = os.path.join(HERE, "idle-budget.json")
STRESS_FILE = os.path.join(HERE, "perf-stress-session.py")

# ---------------------------------------------------------------------------------------------------------
# Per-thread counters (libproc, same user, no root)

_libproc = procs.dylib("/usr/lib/libproc.dylib")
PROC_PIDLISTTHREADIDS = 28
PROC_PIDTHREADID64INFO = 15


class _ThreadInfo(ctypes.Structure):
    _fields_ = [("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64), ("cpu_usage", ctypes.c_int32),
                ("policy", ctypes.c_int32), ("run_state", ctypes.c_int32), ("flags", ctypes.c_int32),
                ("sleep_time", ctypes.c_int32), ("curpri", ctypes.c_int32), ("priority", ctypes.c_int32),
                ("maxpriority", ctypes.c_int32), ("name", ctypes.c_char * 64)]


def threads(pid):
    """{thread id: (cpu ns, name)} of `pid` now; {} when it is gone."""
    ids = (ctypes.c_uint64 * 8192)()
    size = _libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDLISTTHREADIDS), ctypes.c_uint64(0),
                                 ctypes.byref(ids), ctypes.c_int(ctypes.sizeof(ids)))
    out = {}
    for index in range(max(0, size) // 8):
        info = _ThreadInfo()
        got = _libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDTHREADID64INFO), ctypes.c_uint64(ids[index]),
                                    ctypes.byref(info), ctypes.c_int(ctypes.sizeof(info)))
        if got == ctypes.sizeof(info):
            out[ids[index]] = (info.user_time + info.system_time, info.name.decode(errors="replace"))
    return out


# ---------------------------------------------------------------------------------------------------------
# Process kinds (the budget's keys)

def kind(cmd):
    """The budget kind of a process of the app's set."""
    if "__holder" in cmd:
        return "holder"
    if "__terminal-host" in cmd:
        return "terminal-host"
    if re.search(r"/bin/cmux-tui(\s|$)", cmd):
        return "daemon"
    if re.search(r"/bin/acpmux(\s|$)", cmd):
        return "acpmux"
    if "--type=renderer" in cmd:
        return "cef-renderer"
    if "--type=gpu-process" in cmd:
        return "cef-gpu"
    if "--type=utility" in cmd:
        return "cef-utility"
    if " Helper" in cmd.split(" --", 1)[0]:
        return "cef-helper"
    if "com.apple.WebKit." in cmd:
        return "webkit-" + cmd.split("com.apple.WebKit.", 1)[1].split()[0].split(".")[0].lower()
    exe = cmd.split(" --", 1)[0]
    if exe.count(".app/") == 1 and "/Contents/MacOS/" in exe:
        return "app"
    return "other:" + os.path.basename(exe.split()[0])[:32]


def process_set(instance):
    """{pid: command} of the app's processes plus their descendants (shells of the terminals are `other:`)."""
    found = dict(instance.pids())
    table = procs.process_table()
    children = {}
    commands = {}
    for pid, ppid, cmd in table:
        children.setdefault(ppid, []).append(pid)
        commands[pid] = cmd
    stack = list(found)
    while stack:
        pid = stack.pop()
        for child in children.get(pid, []):
            if child not in found and child in commands:
                found[child] = commands[child]
                stack.append(child)
    return found


# ---------------------------------------------------------------------------------------------------------
# One window


def read_rpc(app, method, params=None):
    reply = app.rpc(method, params or {}, timeout=30)
    return reply if isinstance(reply, dict) and not reply.get("error") else {}


def process_row(pid, cmd, first, last, elapsed, network=None, logs=None):
    """One process's row over the window from its (rusage counters, overhead, threads) at the two ends; None once
    it is gone. `network` ({pid: parse_nettop entry}) and `logs` ({pid: parse_log entry}) are None when their
    reader failed: the row's network or log values are then None (not measured), never 0."""
    (c1, o1, t1) = last
    if c1 is None or o1 is None:
        return None
    (c0, o0, t0) = first or (None, None, {})
    partial = c0 is None
    c0 = c0 or (0, 0, 0, 0)
    o0 = o0 or (0, 0, 0, 0, 0)
    ran = []
    for tid, (cpu, name) in t1.items():
        before = t0.get(tid, (0, name))[0] if not partial else 0
        if cpu > before:
            ran.append({"tid": tid, "name": name or "", "cpu_us": round((cpu - before) / 1000, 1)})
    ran.sort(key=lambda t: -t["cpu_us"])
    disk = max(0, o1[0] - o0[0])
    net = (network or {}).get(pid, {})
    log = (logs or {}).get(pid, {})
    return {
        "pid": pid, "kind": kind(cmd), "command": cmd[:160], "partial": partial,
        "threads": o1[1], "threads_ran": len(ran), "ran": ran[:8],
        "cpu_pct": round(100 * (c1[1] - c0[1]) / 1e9 / elapsed, 4),
        "wakeups_per_s": round((c1[2] - c0[2]) / elapsed, 3),
        "csw_per_s": round(procs._delta32(o1[4], o0[4]) / elapsed, 3),
        "footprint_mb": round(c1[3] / procs.MB, 1),
        "disk_bytes": disk, "disk_bytes_per_s": round(disk / elapsed, 3),
        "network_bytes": None if network is None else net.get("bytes", 0),
        "network_loopback_bytes": None if network is None else net.get("loopback_bytes", 0),
        "connections": None if network is None else net.get("connections", 0),
        "remotes": net.get("remotes", []),
        "log_lines": None if logs is None else log.get("lines", 0),
        "log_owners": log.get("owners", {}),
    }


def start_nettop(seconds, workdir):
    """nettop over the coming window, writing its CSV to workdir/nettop.csv; (process, path), or None."""
    path = os.path.join(workdir, "nettop.csv")
    try:
        os.makedirs(workdir, exist_ok=True)
        handle = open(path, "w")
        process = subprocess.Popen(procs.nettop_command(seconds), stdout=handle, stderr=subprocess.DEVNULL,
                                   stdin=subprocess.DEVNULL)
    except OSError:
        return None
    handle.close()  # the child holds its own descriptor
    return process, path


def finish_nettop(started, seconds):
    """parse_nettop of a start_nettop run once it has printed its last sample, or None when it failed."""
    if started is None:
        return None
    process, path = started
    try:
        process.wait(timeout=seconds + 30)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        return None
    if process.returncode != 0:
        return None
    with open(path, errors="replace") as handle:
        return procs.parse_nettop(handle.read())


def windowserver_reading():
    """(pid, cumulative wakeups, source, monotonic time) of WindowServer now."""
    pid = procs.windowserver_pid()
    if pid is None:
        return None, None, "not-found", time.monotonic()
    value, source = procs.windowserver_wakeups(pid)
    return pid, value, source, time.monotonic()


def windowserver_rate(before, after):
    """WindowServer wakeups/s between two windowserver_reading()s, or None (another pid, another source,
    unreadable)."""
    pid0, value0, source0, at0 = before
    pid1, value1, source1, at1 = after
    if pid0 != pid1 or source0 != source1 or value0 is None or value1 is None or at1 <= at0:
        return None
    return round((value1 - value0) / (at1 - at0), 3)


def windowserver_report(window_rate, reference_rate, source):
    """WindowServer's wakeups/s in the window, in the reference window with cmux hidden, and the delta cmux
    adds (reported, never judged: WindowServer serves every app on the host)."""
    delta = None
    if window_rate is not None and reference_rate is not None:
        delta = round(window_rate - reference_rate, 3)
    return {"source": source, "wakeups_per_s": window_rate, "hidden_reference_per_s": reference_rate,
            "delta_per_s": delta}


def measure(app, instance, seconds, workdir):
    """Counters of every process of the app over `seconds` with no input: rusage, threads, disk bytes written,
    network (nettop over the window), unified-log lines (`log show` of the pid set after the window) and
    WindowServer's wakeups. The readers run before the first and after the last process counters, or outside
    the processes (nettop, logd), so none of them lands in the window."""
    hangs0 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger0 = read_rpc(app, "debug.wakeups")
    counters0 = app_counters(app)
    server0 = windowserver_reading()
    pids = process_set(instance)
    first = {pid: (procs.counters(pid), procs.overhead(pid), threads(pid)) for pid in pids}
    nettop = start_nettop(seconds, workdir)
    began = time.monotonic()
    wall_began = time.time()
    time.sleep(seconds)  # bench: the idle window itself (nothing is sent to the app in it)
    elapsed = time.monotonic() - began
    wall_ended = time.time()
    last_pids = process_set(instance)
    last = {pid: (procs.counters(pid), procs.overhead(pid), threads(pid)) for pid in last_pids}
    server1 = windowserver_reading()
    hangs1 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger1 = read_rpc(app, "debug.wakeups", {"run_loop": True})
    counters1 = app_counters(app)
    network = finish_nettop(nettop, seconds)
    logs = procs.read_log(set(pids) | set(last_pids), wall_began, wall_ended)
    rows = []
    for pid, cmd in sorted(last_pids.items()):
        row = process_row(pid, cmd, first.get(pid), last[pid], elapsed, network, logs)
        if row is not None:
            rows.append(row)
    result = {"seconds": round(elapsed, 1), "processes": rows,
              "readers": {"network": network is not None, "log": logs is not None},
              "windowserver": windowserver_report(windowserver_rate(server0, server1), None, server1[2])}
    if "main_wakes" in hangs0 and "main_wakes" in hangs1:
        result["main_wakes_per_s"] = round((hangs1["main_wakes"] - hangs0["main_wakes"]) / elapsed, 3)
    owners = ledger_rates(ledger0, ledger1, elapsed)
    if owners is not None:
        result["ledger"] = owners
    rates = {key: round((counters1[key] - counters0[key]) / elapsed, 3) for key in counters1
             if key in counters0 and counters1[key] != counters0[key]}
    if rates:
        result["app_counter_rates"] = rates
    if ledger1.get("main_run_loop"):
        result["main_run_loop_timers"] = run_loop_timers(ledger1["main_run_loop"])
    return result


TIMER_RE = re.compile(r"<CFRunLoopTimer [^>]*>\{valid = (\w+), firing = \w+, interval = ([0-9.e+-]+),[^}]*?"
                      r"next fire date = ([0-9.e+-]+)[^}]*?callout = ([^,}]+)")


def run_loop_timers(description):
    """The main run loop's timers from its CFCopyDescription: callout, interval (0: one-shot) and next fire
    date, one entry per timer (a timer in several common modes appears once). Repeating timers wake the main
    thread outside the wakeup ledger."""
    seen = {}
    for valid, interval, fire, callout in TIMER_RE.findall(description):
        key = (callout.strip(), interval, fire)
        if valid == "Yes":
            seen[key] = {"callout": callout.strip()[:160], "interval_s": float(interval), "next_fire": float(fire)}
    return sorted(seen.values(), key=lambda t: (t["interval_s"] == 0, t["interval_s"]))


def window_state(app):
    """The app's main windows from its control socket (`debug.window_list`, no AX): key, visible, occluded,
    miniaturized; and whether the app is active. A system prompt over the window shows as not key or occluded."""
    reply = app.rpc("debug.window_list", timeout=10)
    windows = reply.get("windows") if isinstance(reply, dict) else None
    if not isinstance(windows, list):
        return {"error": str(reply)[:200]}
    main = [{k: w.get(k) for k in ("key", "visible", "occluded", "miniaturized", "alpha")} for w in windows if w.get("kind") == "main"]
    return {"main": main, "any_key": any(w.get("key") for w in windows)}


def sample_threads(pid, seconds, path):
    """`/usr/bin/sample` of `pid` for `seconds` after the window (it suspends the process to sample, so it
    never runs inside the measured window); per thread, the frames with the most samples outside the wait."""
    try:
        subprocess.run(["/usr/bin/sample", str(pid), str(seconds), "-mayDie", "-file", path], capture_output=True,
                       timeout=seconds + 60)
        text = open(path, errors="replace").read()
    except (OSError, subprocess.TimeoutExpired):
        return {}
    graph = text.split("Call graph:", 1)[-1].split("Total number in stack", 1)[0]
    threads_out = {}
    current = None
    for line in graph.splitlines():
        head = re.match(r"\s{4}(\d+) Thread_\d+(.*)", line)
        if head:
            name = head.group(2).strip(" :") or "thread"
            current = {"samples": int(head.group(1)), "frames": {}}
            threads_out[f"{name} ({head.group(1)})"] = current
            continue
        frame = re.match(r"[\s+!:|]*(\d+) (.+?)\s+\(in ([^)]+)\)", line)
        if current is not None and frame:
            count, symbol, image = int(frame.group(1)), frame.group(2), frame.group(3)
            if any(wait in symbol for wait in ("mach_msg", "__psynch_cvwait", "__workq_kernreturn", "kevent", "__semwait",
                                                "__select", "__ulock_wait", "start_wqthread", "thread_start", "_pthread_start")):
                continue
            key = f"{symbol} ({image})"
            current["frames"][key] = max(current["frames"].get(key, 0), count)
    for entry in threads_out.values():
        entry["frames"] = sorted(entry["frames"].items(), key=lambda kv: -kv[1])[:12]
    return threads_out


def app_counters(app):
    """The app's own cumulative counters that can wake its main thread outside the ledger (the bench diffs two
    reads): the CEF pump (`debug.cef` pump: work runs, immediate and delayed requests from any thread), the
    Chromium page trackers (geometry posts and skips) and each window's child-window reorders (`debug.layers`)."""
    out = {}
    cef = read_rpc(app, "debug.cef")
    for group in ("pump", "tracker"):
        for key, value in (cef.get(group) or {}).items():
            if isinstance(value, (int, float)) and not key.endswith("_ms"):
                out[f"cef.{group}.{key}"] = value
    layers = read_rpc(app, "debug.layers")
    out["layers.reorders"] = sum(w.get("reorders", 0) for w in layers.get("windows") or [] if isinstance(w, dict))
    return out


def ledger_rates(before, after, elapsed):
    """Wakeup ledger owners that fired in the window (debug.wakeups, when the build has it)."""
    if not before.get("ledger") and not after.get("ledger"):
        return None
    counts = {(e["owner"], e["reason"]): e.get("count", 0) for e in before.get("ledger") or []}
    out = []
    for entry in after.get("ledger") or []:
        delta = entry.get("count", 0) - counts.get((entry["owner"], entry["reason"]), 0)
        if delta > 0:
            out.append({"owner": entry["owner"], "reason": entry["reason"], "per_s": round(delta / elapsed, 3)})
    out.sort(key=lambda e: -e["per_s"])
    return {"owners": out[:20], "active_frame_clients": after.get("active_frame_clients", [])}


# ---------------------------------------------------------------------------------------------------------
# Budget


# D15 sums per kind: None when every process's value is None (its reader failed), so a failed reader is
# "not measured", never a pass.
D15_SUMS = ("disk_bytes", "disk_bytes_per_s", "network_bytes", "network_loopback_bytes", "connections", "log_lines")


def aggregate(result):
    """Per kind: count, threads (sum and max per process), wakeups/s (sum and max per process), CPU %, and the D15
    sums (disk bytes written and per s, network bytes, loopback part, open connections, log lines) with their
    owners: the pids that wrote, the remote ends and the log subsystem:category counts."""
    kinds = {}
    for row in result["processes"]:
        entry = kinds.setdefault(row["kind"], {"n": 0, "threads": 0, "threads_max": 0, "wakeups_per_s": 0.0,
                                               "wakeups_max": 0.0, "csw_per_s": 0.0, "cpu_pct": 0.0, "threads_ran": 0,
                                               **{field: None for field in D15_SUMS},
                                               "disk_writers": [], "remotes": [], "log_owners": {}})
        entry["n"] += 1
        entry["threads"] += row["threads"]
        entry["threads_max"] = max(entry["threads_max"], row["threads"])
        entry["wakeups_per_s"] = round(entry["wakeups_per_s"] + row["wakeups_per_s"], 3)
        entry["wakeups_max"] = max(entry["wakeups_max"], row["wakeups_per_s"])
        entry["csw_per_s"] = round(entry["csw_per_s"] + row["csw_per_s"], 3)
        entry["cpu_pct"] = round(entry["cpu_pct"] + row["cpu_pct"], 4)
        entry["threads_ran"] += row["threads_ran"]
        for field in D15_SUMS:
            value = row.get(field)
            if isinstance(value, (int, float)):
                entry[field] = round((entry[field] or 0) + value, 3)
        if row.get("disk_bytes"):
            entry["disk_writers"].append(row["pid"])
        entry["remotes"] += [remote for remote in row.get("remotes") or [] if remote not in entry["remotes"]]
        for owner, count in (row.get("log_owners") or {}).items():
            entry["log_owners"][owner] = entry["log_owners"].get(owner, 0) + count
    if "main_wakes_per_s" in result and "app" in kinds:
        kinds["app"]["main_wakes_per_s"] = result["main_wakes_per_s"]
    return kinds


def kind_limits(budget, name, session):
    """{field: limit} of kind `name` in `session`: the kind's own limit (one number, or {session: number}), else
    `all_kinds` (D15's zeros, which judge every measured kind). An explicit null in the kind is "reported, not
    judged" and stays null; a {session: number} without this session falls back to `all_kinds`."""
    own = (budget.get("kinds") or {}).get(name) or {}
    shared = budget.get("all_kinds") or {}
    out = {}
    for field in list(own) + [field for field in shared if field not in own]:
        if field.startswith("_"):
            continue
        limit = own.get(field, shared.get(field))
        if isinstance(limit, dict):
            limit = limit.get(session, shared.get(field))
        out[field] = limit
    return out


def allowed_periodic(budget, name, field, entry):
    """Whether an `allowed_periodic` entry ({owner, period_s, why, kind, metrics, remote}) excuses `field` of kind
    `name`: the entry names the kind and the metric, and, when it names a remote, every remote end of the kind
    contains it."""
    for rule in budget.get("allowed_periodic") or []:
        if rule.get("kind") != name or field not in (rule.get("metrics") or []):
            continue
        remote = rule.get("remote")
        if remote is None or (entry.get("remotes") and all(remote in end for end in entry["remotes"])):
            return True
    return False


def over_budget(session, kinds, budget):
    """[(kind, field, value, limit)] for every value over its budget. Limits are per process for
    `wakeups_max` and `threads_max`, and per kind for the rest. The budget's kinds come first, in file order,
    then any other measured kind that `all_kinds` judges."""
    names = list(budget.get("kinds") or {})
    if budget.get("all_kinds"):
        names += [name for name in kinds if name not in names]
    out = []
    for name in names:
        entry = kinds.get(name)
        if not entry:
            continue
        for field, limit in kind_limits(budget, name, session).items():
            if limit is None:
                continue
            value = entry.get(field)
            if isinstance(value, (int, float)) and value > limit and not allowed_periodic(budget, name, field, entry):
                out.append((name, field, value, limit))
    return out


def over_owner(field, entry):
    """Who an over belongs to, for the D15 fields: the pids that wrote, the remote ends, the top log owners."""
    if field.startswith("disk_"):
        return "pids=" + ",".join(str(pid) for pid in entry.get("disk_writers") or []) if entry.get("disk_writers") else ""
    if field in ("network_bytes", "connections"):
        return "remotes=" + ";".join(entry["remotes"][:6]) if entry.get("remotes") else ""
    if field == "log_lines":
        top = sorted((entry.get("log_owners") or {}).items(), key=lambda kv: -kv[1])[:4]
        return "owners=" + ",".join(f"{owner}={count}" for owner, count in top) if top else ""
    return ""


def over_lines(session, overs, kinds):
    """The IDLE-BUDGET-OVER lines of one session (with the owner of a disk, network or log over)."""
    lines = []
    for name, field, value, limit in overs:
        owner = over_owner(field, kinds.get(name) or {})
        lines.append(f"IDLE-BUDGET-OVER {session} {name} {field} {value} > {limit}" + (f" {owner}" if owner else ""))
    return lines


# Noise floors of the cron rows: one wakeup a second, two threads (a pool thread parks or exits late). D15's rows
# are 0 at idle: any byte or line is a change.
CRON_FLOORS = {"wakeups_per_s": 0.5, "wakeups_max": 0.5, "main_wakes_per_s": 0.5, "threads_max": 2, "threads": 2,
               "disk_bytes_per_s": 0.5, "network_bytes": 0.5, "log_lines": 0.5}
CRON_UNITS = {"disk_bytes_per_s": "B/s", "network_bytes": "bytes", "log_lines": "lines"}


def cron_rows(report, budget=None):
    """{row: {p50, p95, unit, budget, floor}} for the perf cron (scripts/cmux-next/perf-cron.py) from one
    idle-budget report: `idle_budget.<session>.<kind>.<field>`, one value per run (p50 = p95)."""
    budget = budget if budget is not None else json.load(open(BUDGET_FILE))
    out = {}
    for session, entry in ((report or {}).get("sessions") or {}).items():
        for name, values in (entry.get("kinds") or {}).items():
            limits = kind_limits(budget, name, session)
            for field, floor in CRON_FLOORS.items():
                value = values.get(field)
                if not isinstance(value, (int, float)):
                    continue
                limit = limits.get(field)
                unit = CRON_UNITS.get(field) or ("threads" if field.startswith("threads") else "/s")
                out[f"idle_budget.{session}.{name}.{field}"] = {"p50": value, "p95": value, "unit": unit,
                                                                 "budget": limit, "floor": floor}
    return out


# ---------------------------------------------------------------------------------------------------------
# Sessions


def load_stress():
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", STRESS_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


STATIC_PAGE = ("<!doctype html><meta charset='utf-8'><title>idle %d</title>"
               "<style>body{margin:0;font:16px -apple-system,sans-serif;background:#f4f4f6}"
               ".g{display:grid;grid-template-columns:repeat(auto-fill,minmax(140px,1fr));gap:10px;padding:16px}"
               ".g div{height:80px;border-radius:10px;background:#c9d4e8}</style>"
               "<h1>idle page %d</h1><div class='g'>%s</div><p>%s</p>")


def static_pages(stress_module):
    """STRESS's local pages without their rAF spinner (no script, no timer, no animation): an idle page."""
    import http.server

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            try:
                index = int(self.path.strip("/").split("/")[-1] or 0)
            except ValueError:
                index = 0
            data = (STATIC_PAGE % (index, index, "<div></div>" * 120, "lorem ipsum dolor sit amet " * 200)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def log_message(self, *args):
            pass

    pages = stress_module.Pages()
    pages.handler = Handler
    return pages


def build_stress(app, static=False):
    """STRESS, then its busy terminals stopped (Ctrl-C), so the terminals are quiet. With `static` its pages
    have no rAF spinner (STRESS's own pages animate, which is not idle)."""
    stress_module = load_stress()
    stress = stress_module.Stress(app.rpc)
    if static:
        stress.pages = static_pages(stress_module)
    summary = stress.build()
    for tab in getattr(stress, "busy", []):
        stress.send(tab, "\x03")
    summary["busy_terminals_stopped"] = len(getattr(stress, "busy", []))
    print("STRESS-SESSION " + json.dumps(summary), flush=True)
    return summary


BASE_CONFIG = {"appearance": {"backgroundOpacity": 1}}  # BenchApp's default config
# The sessions: light (the launch window: one terminal, Home's pages in Chromium by default), light-webkit (the
# same with `browser.defaultEngine: webkit`, so no Chromium runs at all), light-hidden (the app hidden: no window
# can be seen), stress (STRESS, its busy terminals stopped).
SESSIONS = {
    "light": {},
    "light-webkit": {"config": {**BASE_CONFIG, "browser": {"defaultEngine": "webkit"}}},
    "light-hidden": {"hide": True},
    "stress": {},
    "stress-static": {},
}


def fresh_session(app):
    """Starts the session from empty: ends the tag's leftover daemons (TagTeardown: exact PIDs of this app
    bundle) and removes the tag's saved terminal session, as bench_pane_scale.py does. A bench host's tag
    (split-spring) is shared, and its saved session restored 509 terminals into a "light" run (cmux20,
    2026-10-24). Returns what it removed."""
    if app.teardown:
        app.teardown.end()
        app.teardown.done = False
    state = os.path.join(os.path.expanduser("~"), "Library/Application Support/cmux/tags", app.tag, "tui")
    existed = os.path.isdir(state)
    shutil.rmtree(state, ignore_errors=True)
    return {"tui_state_removed": existed}


def host_facts():
    display = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True).stdout
    return {"host": platform.node(), "macos": platform.mac_ver()[0], "chip": subprocess.run(
        ["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
        "load": os.getloadavg(), "display": [l.strip() for l in display.splitlines() if "Refresh" in l or "Resolution" in l][:4]}


def table(session, kinds, overs, windowserver=None):
    over_keys = {(k, f) for k, f, _, _ in overs}
    lines = [f"\n### {session}\n", "| process | n | threads (max) | wakeups/s (max) | main wakes/s | csw/s | CPU % | threads that ran "
             "| disk B/s | net bytes (conns) | log lines |",
             "|---|---|---|---|---|---|---|---|---|---|---|"]
    order = ["app", "daemon", "holder", "terminal-host", "acpmux"]
    for name in sorted(kinds, key=lambda k: (order.index(k) if k in order else len(order), k)):
        e = kinds[name]
        mark = lambda f, v: f"**{v}**" if (name, f) in over_keys else ("-" if v is None else f"{v}")  # noqa: E731
        lines.append(f"| {name} | {e['n']} | {e['threads']} ({mark('threads_max', e['threads_max'])}) | "
                     f"{mark('wakeups_per_s', e['wakeups_per_s'])} ({mark('wakeups_max', e['wakeups_max'])}) | "
                     f"{mark('main_wakes_per_s', e.get('main_wakes_per_s', '-'))} | {e['csw_per_s']} | {e['cpu_pct']} | {e['threads_ran']} | "
                     f"{mark('disk_bytes_per_s', e.get('disk_bytes_per_s'))} | "
                     f"{mark('network_bytes', e.get('network_bytes'))} ({mark('connections', e.get('connections'))}) | "
                     f"{mark('log_lines', e.get('log_lines'))} |")
    if windowserver:
        lines.append(f"\nWindowServer ({windowserver.get('source')}, reported): {windowserver.get('wakeups_per_s')}/s, "
                     f"{windowserver.get('hidden_reference_per_s')}/s with cmux hidden, delta {windowserver.get('delta_per_s')}/s")
    return "\n".join(lines)


REFERENCE_SETTLE_S = 5  # the hide finishes before the WindowServer reference window opens


def hide_app(app):
    return app.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": True}, "focus": False,
                                  "origin": "script"}, timeout=30)


def windowserver_reference(app, seconds):
    """WindowServer wakeups/s over `seconds` with cmux hidden (the reference the window's delta is taken
    against), and the hide action's reply."""
    reply = hide_app(app)
    time.sleep(REFERENCE_SETTLE_S)  # bench: the hide lands before the reference window opens
    before = windowserver_reading()
    time.sleep(seconds)  # bench: the reference window
    return windowserver_rate(before, windowserver_reading()), reply


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", required=True, help='a tagged "cmux DEV <tag>.app" (not running)')
    parser.add_argument("--tag", help="ignored (split-spring passes it); the tag comes from the app")
    parser.add_argument("--out", default=None)
    parser.add_argument("--json", default=None)
    parser.add_argument("--sessions", default="light,stress")
    parser.add_argument("--settle", type=float, default=60)
    parser.add_argument("--measure", type=float, default=60)
    parser.add_argument("--budget", default=BUDGET_FILE)
    parser.add_argument("--gate", action="store_true", help="exit 1 when a value is over its budget")
    parser.add_argument("--sample", type=float, default=10,
                        help="seconds of /usr/bin/sample of the app after the window, to name the threads that woke (0: none)")
    parser.add_argument("--windowserver-reference", type=float, default=None,
                        help="seconds of the WindowServer reference window with cmux hidden, after the sample "
                             "(default: --measure; 0: none; a hidden session is its own reference)")
    opts, _unknown = parser.parse_known_args()
    from bench_launch import BenchApp
    budget = json.load(open(opts.budget))
    reference_s = opts.measure if opts.windowserver_reference is None else opts.windowserver_reference
    out = opts.out or os.path.join(os.getcwd(), "artifacts", "idle-budget")
    os.makedirs(out, exist_ok=True)
    machine = host_facts()
    print("IDLE-BUDGET-MACHINE " + json.dumps(machine), flush=True)
    report = {"machine": machine, "app": opts.app, "settle_s": opts.settle, "measure_s": opts.measure, "sessions": {}}
    all_overs = []
    markdown = []
    for session in [s for s in opts.sessions.split(",") if s]:
        if session not in SESSIONS:
            raise SystemExit(f"idle-budget: unknown session {session} (one of {', '.join(SESSIONS)})")
        app = BenchApp(opts.app, out=os.path.join(out, session), config=SESSIONS[session].get("config"))
        try:
            entry = {"fresh_session": fresh_session(app)}
            app.launch()
            if session in ("stress", "stress-static"):
                entry["stress"] = build_stress(app, static=session == "stress-static")
            if SESSIONS[session].get("hide"):
                entry["hide"] = hide_app(app)
            time.sleep(opts.settle)  # bench: the session settles (page loads, Chromium's post-load work) before the window
            instance = procs.Instance(app.app, app.process.pid)
            window_before = window_state(app)
            result = measure(app, instance, opts.measure, os.path.join(out, session))
            result["window_state"] = {"start": window_before, "end": window_state(app)}
            print(f"IDLE-BUDGET-WINDOW {session} " + json.dumps(result["window_state"]), flush=True)
            if opts.sample:
                result["sample"] = sample_threads(app.process.pid, opts.sample, os.path.join(out, session, "sample-app.txt"))
            server = result["windowserver"]
            if SESSIONS[session].get("hide"):
                server = windowserver_report(server["wakeups_per_s"], server["wakeups_per_s"], server["source"])
            elif reference_s > 0:
                rate, result["windowserver_reference_hide"] = windowserver_reference(app, reference_s)
                server = windowserver_report(server["wakeups_per_s"], rate, server["source"])
            result["windowserver"] = server
            print(f"IDLE-BUDGET-WINDOWSERVER {session} " + json.dumps(server), flush=True)
            for reader, ok in result["readers"].items():
                if not ok:
                    print(f"IDLE-BUDGET-READER-FAILED {session} {reader}: not measured", flush=True)
            kinds = aggregate(result)
            overs = over_budget(session, kinds, budget)
            entry.update({"result": result, "kinds": kinds, "over": [list(o) for o in overs]})
            report["sessions"][session] = entry
            for name, values in kinds.items():
                print("IDLE-BUDGET-ROW " + json.dumps({"session": session, "kind": name, **values}), flush=True)
            for row in result["processes"]:
                if row["kind"] in ("app", "daemon", "holder", "acpmux") and row["ran"]:
                    names = ", ".join(f"{t['name'] or t['tid']}={t['cpu_us']}us" for t in row["ran"])
                    print(f"IDLE-BUDGET-THREADS {session} {row['kind']} pid {row['pid']}: {names}", flush=True)
            if result.get("ledger"):
                print(f"IDLE-BUDGET-LEDGER {session} " + json.dumps(result["ledger"]), flush=True)
            if result.get("app_counter_rates"):
                print(f"IDLE-BUDGET-APP-COUNTERS {session} per s " + json.dumps(result["app_counter_rates"]), flush=True)
            for timer in result.get("main_run_loop_timers") or []:
                if timer["interval_s"] > 0:
                    print(f"IDLE-BUDGET-MAIN-TIMER {session} every {timer['interval_s']:g} s: {timer['callout']}", flush=True)
            for name, sampled in (result.get("sample") or {}).items():
                top = "; ".join(f"{frame} x{count}" for frame, count in sampled["frames"][:6])
                if top:
                    print(f"IDLE-BUDGET-SAMPLE {session} {name}: {top}", flush=True)
            for line in over_lines(session, overs, kinds):
                print(line, flush=True)
            all_overs += [(session, *o) for o in overs]
            markdown.append(table(session, kinds, overs, server))
            entry["exit"] = 0
        except BaseException as error:  # noqa: BLE001 - one session's failure (a STRESS shape refusal, a launch
            # failure) is recorded with its exit code; the other sessions still measure and report.
            code = error.code if isinstance(error, SystemExit) and isinstance(error.code, int) else 1
            report["sessions"].setdefault(session, {}).update({"exit": code or 1, "error": f"{type(error).__name__}: {error}"[:500]})
            print(f"IDLE-BUDGET-SESSION-FAILED {session} exit={code or 1} {type(error).__name__}: {str(error)[:300]}", flush=True)
            markdown.append(f"\n### {session}\n\nnot measured: {type(error).__name__}: {str(error)[:300]}")
            if isinstance(error, KeyboardInterrupt):
                raise
        finally:
            app.stop()
    report["over"] = [list(o) for o in all_overs]
    report["session_exits"] = {name: entry.get("exit") for name, entry in report["sessions"].items()}
    text = f"# cmux idle budget, {machine['host']} (macOS {machine['macos']}), settle {opts.settle:g} s, window {opts.measure:g} s\n" + "\n".join(markdown)
    print(text, flush=True)
    with open(os.path.join(out, "idle-budget.md"), "w") as handle:
        handle.write(text + "\n")
    path = opts.json or os.path.join(out, "idle-budget.json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(report, handle, indent=1)
    print(f"IDLE-BUDGET over={len(all_overs)} sessions={json.dumps(report['session_exits'])} json={path}", flush=True)
    sys.exit(1 if opts.gate and all_overs else 0)


if __name__ == "__main__":
    main()
