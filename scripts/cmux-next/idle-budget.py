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
  Backoff by owner and reason).

The script reads the app's counters only at the window's two ends (proc_pid_rusage of another process
does not wake it; the two socket reads sit outside the process counters' window), so the bench adds no
wakeup to what it measures.

Sessions (--sessions):
  light         the launch window with its terminal (Home's pages run in Chromium by default)
  light-webkit  the same with browser.defaultEngine webkit: no Chromium at all
  light-hidden  the light session with the app hidden (Show/Hide All Windows hidden=true)
  Each session starts from an empty saved session (`fresh_session`).
  stress-static  STRESS with its pages served without their rAF spinner (STRESS's own pages animate: not idle)
  stress   STRESS (scripts/cmux-next/perf-stress-session.py: 60 workspaces, a 12-pane grid of 6 tabs each,
           Chromium pages elsewhere); its 10 busy terminals are stopped (Ctrl-C) before the settle, so the
           terminals are quiet
  chrome-static  the reference: Google Chrome (--chrome-app) with tabs-static's 16 pages as tabs, the first
           shown, and the uBlock Origin --app bundles (--chrome-ublock), launched as xbench launches Chrome
           (cloned template profile, its switches, CDP /json/new); kinds browser, renderer, extension, gpu,
           utility, crashpad. With it the report has a `chrome` block and `ratio_to_chrome` rows (budget
           `ratio_to_chrome`, else DEFAULT_RATIO_ROWS: D4 and D6), judged like any budget value; without the
           same uBlock Origin running in Chrome every ratio row is `unequal`: reported, not judged.

A session that fails (STRESS refuses a window under the Dock, a launch fails) is recorded with its exit
code (`session_exits` in the report) and the others still run; the script exits 0 unless --gate.

Budget: scripts/cmux-next/idle-budget.json (per process kind; a missing value is reported, not judged).
Over budget prints IDLE-BUDGET-OVER lines; the exit code is 0 unless --gate (no CI gate: the perf cron
runs it and reports).

Use (fleet only, a host with a GUI console session; never on a laptop in use):
  python3 scripts/cmux-next/idle-budget.py --app "<...>/cmux DEV <tag>.app" --out DIR \\
      [--sessions light,stress] [--settle 60] [--measure 60] [--json DIR/idle-budget.json]
  On the fleet through the allowlisted entry (STRESS needs the 1920 x 1080 virtual display):
    scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 [...]

Output: one `IDLE-BUDGET-MACHINE {json}` line, one `IDLE-BUDGET-ROW {json}` line per session and process
kind, a Markdown table, and --json with every sample.
"""
import argparse, ctypes, functools, json, os, platform, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "perf-bench"))
import procs  # noqa: E402  (process set of one app: descendants, bundle processes, responsible XPC processes)

BUDGET_FILE = os.path.join(HERE, "idle-budget.json")
STRESS_FILE = os.path.join(HERE, "perf-stress-session.py")

# ---------------------------------------------------------------------------------------------------------
# Per-thread counters (libproc, same user, no root)

PROC_PIDLISTTHREADIDS = 28
PROC_PIDTHREADID64INFO = 15


class _ThreadInfo(ctypes.Structure):
    _fields_ = [("user_time", ctypes.c_uint64), ("system_time", ctypes.c_uint64), ("cpu_usage", ctypes.c_int32),
                ("policy", ctypes.c_int32), ("run_state", ctypes.c_int32), ("flags", ctypes.c_int32),
                ("sleep_time", ctypes.c_int32), ("curpri", ctypes.c_int32), ("priority", ctypes.c_int32),
                ("maxpriority", ctypes.c_int32), ("name", ctypes.c_char * 64)]


@functools.cache
def _libproc():
    return ctypes.CDLL("/usr/lib/libproc.dylib")


def threads(pid):
    """{thread id: (cpu ns, name)} of `pid` now; {} when it is gone."""
    libproc = _libproc()
    ids = (ctypes.c_uint64 * 8192)()
    size = libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDLISTTHREADIDS), ctypes.c_uint64(0),
                                 ctypes.byref(ids), ctypes.c_int(ctypes.sizeof(ids)))
    out = {}
    for index in range(max(0, size) // 8):
        info = _ThreadInfo()
        got = libproc.proc_pidinfo(ctypes.c_int(pid), ctypes.c_int(PROC_PIDTHREADID64INFO), ctypes.c_uint64(ids[index]),
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


def snapshot(commands):
    """{pid: (command, rusage counters, task overhead, threads)} of `commands` ({pid: command}) now."""
    return {pid: (cmd, procs.counters(pid), procs.overhead(pid), threads(pid)) for pid, cmd in commands.items()}


def process_rows(first, last, elapsed, classify):
    """One row per process alive at the window's end, from two snapshots `elapsed` seconds apart; a process
    that started inside the window counts from its start (`partial`)."""
    rows = []
    for pid, (cmd, c1, o1, t1) in sorted(last.items()):
        if c1 is None or o1 is None:
            continue
        (_, c0, o0, t0) = first.get(pid, (cmd, None, None, {}))
        partial = c0 is None
        c0 = c0 or (0, 0, 0, 0)
        o0 = o0 or (0, 0, 0, 0, 0)
        ran = []
        for tid, (cpu, name) in t1.items():
            before = t0.get(tid, (0, name))[0] if not partial else 0
            if cpu > before:
                ran.append({"tid": tid, "name": name or "", "cpu_us": round((cpu - before) / 1000, 1)})
        ran.sort(key=lambda t: -t["cpu_us"])
        rows.append({
            "pid": pid, "kind": classify(cmd), "command": cmd[:160], "partial": partial,
            "threads": o1[1], "threads_ran": len(ran), "ran": ran[:8],
            "cpu_pct": round(100 * (c1[1] - c0[1]) / 1e9 / elapsed, 4),
            "wakeups_per_s": round((c1[2] - c0[2]) / elapsed, 3),
            "energy_mw": round((c1[0] - c0[0]) / 1e6 / elapsed, 3),
            "csw_per_s": round(procs._delta32(o1[4], o0[4]) / elapsed, 3),
            "footprint_mb": round(c1[3] / procs.MB, 1),
        })
    return rows


def measure(app, instance, seconds):
    """Counters of every process of the app over `seconds` with no input."""
    hangs0 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger0 = read_rpc(app, "debug.wakeups")
    counters0 = app_counters(app)
    first = snapshot(process_set(instance))
    began = time.monotonic()
    time.sleep(seconds)  # bench: the idle window itself (nothing is sent to the app in it)
    elapsed = time.monotonic() - began
    last = snapshot(process_set(instance))
    hangs1 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger1 = read_rpc(app, "debug.wakeups", {"run_loop": True})
    counters1 = app_counters(app)
    result = {"seconds": round(elapsed, 1), "processes": process_rows(first, last, elapsed, kind)}
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


def aggregate(result):
    """Per kind: count, threads (sum and max per process), wakeups/s (sum and max per process), CPU energy
    (mW, ri_energy_nj), CPU %."""
    kinds = {}
    for row in result["processes"]:
        entry = kinds.setdefault(row["kind"], {"n": 0, "threads": 0, "threads_max": 0, "wakeups_per_s": 0.0,
                                               "wakeups_max": 0.0, "energy_mw": 0.0, "csw_per_s": 0.0, "cpu_pct": 0.0,
                                               "threads_ran": 0})
        entry["n"] += 1
        entry["threads"] += row["threads"]
        entry["threads_max"] = max(entry["threads_max"], row["threads"])
        entry["wakeups_per_s"] = round(entry["wakeups_per_s"] + row["wakeups_per_s"], 3)
        entry["wakeups_max"] = max(entry["wakeups_max"], row["wakeups_per_s"])
        entry["energy_mw"] = round(entry["energy_mw"] + row.get("energy_mw", 0.0), 3)
        entry["csw_per_s"] = round(entry["csw_per_s"] + row["csw_per_s"], 3)
        entry["cpu_pct"] = round(entry["cpu_pct"] + row["cpu_pct"], 4)
        entry["threads_ran"] += row["threads_ran"]
    if "main_wakes_per_s" in result and "app" in kinds:
        kinds["app"]["main_wakes_per_s"] = result["main_wakes_per_s"]
    return kinds


def over_budget(session, kinds, budget, chrome=None):
    """[(kind, field, value, limit)] for every value over its budget. Limits are per process for
    `wakeups_max` and `threads_max`, and per kind for the rest. With `chrome` (the chrome-static block), the
    session's ratio rows are judged too (ratio_overs)."""
    out = []
    for name, limits in (budget.get("kinds") or {}).items():
        entry = kinds.get(name)
        if not entry:
            continue
        for field, limit in limits.items():
            if field.startswith("_") or limit is None:
                continue
            if isinstance(limit, dict):
                limit = limit.get(session)
                if limit is None:
                    continue
            value = entry.get(field)
            if isinstance(value, (int, float)) and value > limit:
                out.append((name, field, value, limit))
    return out + (ratio_overs(ratio_to_chrome(session, kinds, chrome, budget)) if chrome else [])


# ---------------------------------------------------------------------------------------------------------
# The Chrome reference (chrome-static): Google Chrome with the tabs-static pages and the uBlock Origin cmux bundles

CHROME_SESSION = "chrome-static"
CHROME_APP = "/Applications/Google Chrome.app"
UBLOCK_ID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"  # fetch-ublock.sh keeps the Web Store key, so the id is stable
UBLOCK_IN_APP = "Contents/Resources/Extensions/ublock-origin"  # bundle-ublock.sh
# The ratio rows of p14-energy.md D4 and D6 (cmux kind or `tree`, Chrome kind or `tree`, field, limit on
# cmux / Chrome), used while the budget file has no `ratio_to_chrome` list (p14-energy-002 adds it).
DEFAULT_RATIO_ROWS = [
    {"session": "tabs-static", "cmux": "tree", "chrome": "tree", "field": "wakeups_per_s", "limit": 0.5},
    {"session": "tabs-static", "cmux": "tree", "chrome": "tree", "field": "energy_mw", "limit": 1.0},
    {"session": "tabs-static", "cmux": "cef-host", "chrome": "browser", "field": "wakeups_per_s", "limit": 1.0},
    {"session": "tabs-static", "cmux": "cef-gpu", "chrome": "gpu", "field": "wakeups_per_s", "limit": 1.0},
]


def chrome_kind(cmd):
    """The kind of a Google Chrome process: browser, renderer, extension, gpu, utility, crashpad (Chromium's
    process types, content/public/common/content_switches.cc; an extension's renderer carries
    --extension-process, extensions/common/switches.cc)."""
    if "--type=renderer" in cmd:
        return "extension" if "--extension-process" in cmd else "renderer"
    if "--type=gpu-process" in cmd:
        return "gpu"
    if "--type=utility" in cmd:
        return "utility"
    if "chrome_crashpad_handler" in cmd:
        return "crashpad"
    exe = cmd.split(" --", 1)[0]
    if exe.count(".app/") == 1 and "/Contents/MacOS/" in exe:
        return "browser"
    return "other:" + os.path.basename(exe.split()[0])[:32]


def manifest_version(folder):
    """The `version` of an unpacked extension folder, or None when it has no readable manifest."""
    try:
        with open(os.path.join(folder, "manifest.json")) as handle:
            return json.load(handle).get("version")
    except (OSError, ValueError, AttributeError):
        return None


def ublock_parity(cmux_version, chrome_version, targets):
    """Whether Chrome ran the uBlock Origin cmux bundles. `cmux_version`: the app's bundled copy (None: none);
    `chrome_version`: the copy loaded into Chrome (None: none); `targets`: Chrome's extension targets at the
    window's end (xbench ChromiumBrowser.extension_targets). Without it Chrome does less work than cmux, so
    the reference is unequal and its ratio rows are reported, not judged."""
    running = any(t.get("url", "").startswith(f"chrome-extension://{UBLOCK_ID}/") for t in targets)
    unequal = []
    if cmux_version is None:
        unequal.append("the cmux app bundles no uBlock Origin")
    if chrome_version is None:
        unequal.append("no uBlock Origin was loaded into Chrome")
    elif not running:
        unequal.append(f"uBlock Origin {chrome_version} did not start in Chrome (no extension target)")
    if cmux_version and chrome_version and cmux_version != chrome_version:
        unequal.append(f"uBlock Origin {chrome_version} in Chrome, {cmux_version} in cmux")
    return {"id": UBLOCK_ID, "cmux_version": cmux_version, "chrome_version": chrome_version, "running": running,
            "equal": not unequal, "unequal": unequal}


def kind_value(kinds, name, field):
    """`field` of kind `name`, or summed over every kind for `tree`; None when not measured."""
    if name == "tree":
        values = [entry[field] for entry in kinds.values() if isinstance(entry.get(field), (int, float))]
        return round(sum(values), 3) if values else None
    value = (kinds.get(name) or {}).get(field)
    return value if isinstance(value, (int, float)) else None


def ratio_to_chrome(session, kinds, chrome, budget):
    """The ratio rows of `session` against the chrome-static block `chrome` ({kinds, ublock}): cmux value,
    Chrome value, ratio, limit, over; `unequal` (the reasons) when Chrome ran without the same uBlock Origin,
    `missing` when a side was not measured."""
    rows = []
    ublock = chrome.get("ublock") or {}
    for spec in budget.get("ratio_to_chrome") or DEFAULT_RATIO_ROWS:
        if spec.get("session", "tabs-static") != session:
            continue
        mine = kind_value(kinds, spec["cmux"], spec["field"])
        theirs = kind_value(chrome.get("kinds") or {}, spec["chrome"], spec["field"])
        row = {"session": session, "cmux": spec["cmux"], "chrome": spec["chrome"], "field": spec["field"],
               "limit": spec["limit"], "cmux_value": mine, "chrome_value": theirs, "ratio": None, "over": False}
        if mine is None or theirs is None:
            row["missing"] = [side for side, value in (("cmux", mine), ("chrome", theirs)) if value is None]
        elif theirs > 0:
            row["ratio"] = round(mine / theirs, 3)
            row["over"] = row["ratio"] > spec["limit"]
        else:
            row["over"] = mine > 0  # Chrome at 0: any cmux value is over every ratio
        if not ublock.get("equal"):
            row["unequal"] = ublock.get("unequal") or ["no uBlock Origin check ran"]
        rows.append(row)
    return rows


def ratio_overs(rows):
    """[(kind, field, value, limit)] of the ratio rows over their limit; an unequal row is reported, not judged.
    The value is the ratio, or the cmux value when Chrome measured 0."""
    return [(f"{row['cmux']}:chrome-{row['chrome']}", f"ratio_to_chrome.{row['field']}",
             row["ratio"] if row["ratio"] is not None else row["cmux_value"], row["limit"])
            for row in rows if row["over"] and not row.get("unequal")]


def judge_against_chrome(report, budget):
    """After every session ran: with a measured chrome-static session, puts the `chrome` block and every
    session's `ratio_to_chrome` rows into `report` and returns the ratio overs [(session, kind, field, value,
    limit)] (each also in its session's `over`)."""
    entry = report["sessions"].get(CHROME_SESSION) or {}
    if not entry.get("kinds"):
        return []
    chrome = {**(entry.get("chrome") or {}), "kinds": entry["kinds"]}
    report["chrome"] = chrome
    report["ratio_to_chrome"] = []
    overs = []
    for session, values in report["sessions"].items():
        if session == CHROME_SESSION or not values.get("kinds"):
            continue
        rows = ratio_to_chrome(session, values["kinds"], chrome, budget)
        values["ratio_to_chrome"] = rows
        report["ratio_to_chrome"] += rows
        found = ratio_overs(rows)
        values.setdefault("over", []).extend(list(o) for o in found)
        overs += [(session, *o) for o in found]
    return overs


def ratio_table(rows):
    lines = ["\n### ratio to Chrome (chrome-static)\n", "| session | cmux | Chrome | field | cmux value | Chrome value | ratio | limit | verdict |",
             "|---|---|---|---|---|---|---|---|---|"]
    for row in rows:
        verdict = ("unequal: " + "; ".join(row["unequal"]) if row.get("unequal") else
                   "missing " + ", ".join(row["missing"]) if row.get("missing") else "**over**" if row["over"] else "ok")
        lines.append(f"| {row['session']} | {row['cmux']} | {row['chrome']} | {row['field']} | {row['cmux_value']} | "
                     f"{row['chrome_value']} | {row['ratio']} | {row['limit']} | {verdict} |")
    return "\n".join(lines)


# Noise floors of the cron rows: one wakeup a second, two threads (a pool thread parks or exits late).
CRON_FLOORS = {"wakeups_per_s": 0.5, "wakeups_max": 0.5, "main_wakes_per_s": 0.5, "threads_max": 2, "threads": 2}


def cron_rows(report, budget=None):
    """{row: {p50, p95, unit, budget, floor}} for the perf cron (scripts/cmux-next/perf-cron.py) from one
    idle-budget report: `idle_budget.<session>.<kind>.<field>`, one value per run (p50 = p95)."""
    budget = budget if budget is not None else json.load(open(BUDGET_FILE))
    out = {}
    for session, entry in ((report or {}).get("sessions") or {}).items():
        for name, values in (entry.get("kinds") or {}).items():
            limits = (budget.get("kinds") or {}).get(name) or {}
            for field, floor in CRON_FLOORS.items():
                value = values.get(field)
                if not isinstance(value, (int, float)):
                    continue
                limit = limits.get(field)
                if isinstance(limit, dict):
                    limit = limit.get(session)
                unit = "threads" if field.startswith("threads") else "/s"
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
    CHROME_SESSION: {"chrome": True},
}


# tabs-static's page set (1 visible Chromium tab, 10 hidden Chromium, 5 hidden WebKit, p14-energy-003): in Chrome
# every page is a tab, the first one shown.
TABS_STATIC_PAGES = 1 + 10 + 5


def run_chrome_static(opts, out):
    """The chrome-static entry: Google Chrome (xbench's launcher: an APFS clone of a template profile,
    --user-data-dir, xbench's switches, tabs over CDP /json/new) with tabs-static's pages from this file's static
    page server and the uBlock Origin the cmux app bundles, measured over the same settle and window as the cmux
    sessions, its processes classified by chrome_kind."""
    import xbench  # scripts/perf-bench (on sys.path): the Chrome launcher the cross-browser bench uses
    bundle = os.path.abspath(opts.chrome_app)
    if not os.path.isdir(bundle):
        raise RuntimeError(f"chrome-static: no {bundle}")
    if procs.main_pid(bundle):
        raise RuntimeError(f"chrome-static: {bundle} is already running; its processes would be measured too")
    cmux_ublock = os.path.join(os.path.realpath(opts.app), UBLOCK_IN_APP)
    ublock = None if opts.chrome_ublock == "none" else opts.chrome_ublock or cmux_ublock
    chrome_version = manifest_version(ublock) if ublock else None
    work = os.path.join(out, CHROME_SESSION)
    helper = xbench.Helper(opts.chrome_helper_cache)
    pages = static_pages(load_stress())
    browser = xbench.ChromiumBrowser("chrome", bundle, helper, None, extensions=[ublock] if chrome_version else [])
    try:
        template = os.path.join(work, "template")
        if not os.path.isdir(template):
            os.makedirs(template)
            browser.launch(template, None)
            try:
                browser.ready()
                xbench.sleep(opts.chrome_template_settle)  # bench: uBlock Origin compiles its lists into the template
            finally:
                browser.quit()
        profile = os.path.join(work, "run")
        xbench.clone(template, profile)
        browser.launch(profile, None)
        browser.ready()
        launched = [target["id"] for target in browser.pages()]
        urls = [pages.url() for _ in range(TABS_STATIC_PAGES)]
        for index, url in enumerate(urls):
            browser.new_tab(url, str(index))
        for handle in launched:
            browser.close(handle)
        browser.activate(browser.tabs[0])
        time.sleep(opts.settle)  # bench: the pages settle and hidden tabs pass Chrome's background throttling
        first = snapshot(browser.instance.pids())
        began = time.monotonic()
        time.sleep(opts.measure)  # bench: the idle window itself (nothing is sent to Chrome in it)
        elapsed = time.monotonic() - began
        last = snapshot(browser.instance.pids())
        targets = browser.extension_targets()
        result = {"seconds": round(elapsed, 1), "processes": process_rows(first, last, elapsed, chrome_kind)}
        chrome = {"app": bundle, "version": xbench.bundle_version(bundle), "switches": browser.switches(),
                  "pages": {"tabs": len(urls), "shown": 1, "set": "tabs-static"},
                  "ublock": ublock_parity(manifest_version(cmux_ublock), chrome_version, targets),
                  "extension_targets": [target.get("url", "")[:120] for target in targets]}
        return {"chrome": chrome, "result": result}
    finally:
        browser.quit()
        pages.close()
        shutil.rmtree(os.path.join(work, "run"), ignore_errors=True)  # the template stays for a rerun into `out`


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


def table(session, kinds, overs):
    over_keys = {(k, f) for k, f, _, _ in overs}
    lines = [f"\n### {session}\n", "| process | n | threads (max) | wakeups/s (max) | main wakes/s | csw/s | CPU % | mW | threads that ran |",
             "|---|---|---|---|---|---|---|---|---|"]
    order = ["app", "daemon", "holder", "terminal-host", "acpmux"]
    for name in sorted(kinds, key=lambda k: (order.index(k) if k in order else len(order), k)):
        e = kinds[name]
        mark = lambda f, v: f"**{v}**" if (name, f) in over_keys else f"{v}"  # noqa: E731
        lines.append(f"| {name} | {e['n']} | {e['threads']} ({mark('threads_max', e['threads_max'])}) | "
                     f"{mark('wakeups_per_s', e['wakeups_per_s'])} ({mark('wakeups_max', e['wakeups_max'])}) | "
                     f"{mark('main_wakes_per_s', e.get('main_wakes_per_s', '-'))} | {e['csw_per_s']} | {e['cpu_pct']} | "
                     f"{e.get('energy_mw', '-')} | {e['threads_ran']} |")
    return "\n".join(lines)


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
    parser.add_argument("--chrome-app", default=CHROME_APP, help="the chrome-static browser")
    parser.add_argument("--chrome-ublock", default=None,
                        help="the unpacked uBlock Origin Chrome loads in chrome-static (default: the copy in --app; "
                        "`none`: without it, which marks the Chrome ratios unequal)")
    parser.add_argument("--chrome-template-settle", type=float, default=45,
                        help="seconds Chrome's template profile runs before its first clone")
    parser.add_argument("--chrome-helper-cache", default=os.path.expanduser("~/Library/Caches/cmux-perf-bench"),
                        help="xbench's benchhelper cache")
    opts, _unknown = parser.parse_known_args()
    from bench_launch import BenchApp
    budget = json.load(open(opts.budget))
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
        if SESSIONS[session].get("chrome"):
            try:
                entry = run_chrome_static(opts, out)
                entry["kinds"] = aggregate(entry["result"])
                entry["exit"] = 0
                for name, values in entry["kinds"].items():
                    print("IDLE-BUDGET-ROW " + json.dumps({"session": session, "kind": name, **values}), flush=True)
                print(f"IDLE-BUDGET-CHROME {json.dumps({k: v for k, v in entry['chrome'].items() if k != 'switches'})}", flush=True)
                for reason in entry["chrome"]["ublock"]["unequal"]:
                    print(f"IDLE-BUDGET-UNEQUAL {session} {reason}: its ratio rows are reported, not judged", flush=True)
                markdown.append(table(session, entry["kinds"], []))
            except Exception as error:  # noqa: BLE001 - as a cmux session's failure: recorded, the others run
                entry = {"exit": 1, "error": f"{type(error).__name__}: {error}"[:500]}
                print(f"IDLE-BUDGET-SESSION-FAILED {session} exit=1 {entry['error'][:300]}", flush=True)
                markdown.append(f"\n### {session}\n\nnot measured: {entry['error'][:300]}")
            report["sessions"][session] = entry
            continue
        app = BenchApp(opts.app, out=os.path.join(out, session), config=SESSIONS[session].get("config"))
        try:
            entry = {"fresh_session": fresh_session(app)}
            app.launch()
            if session in ("stress", "stress-static"):
                entry["stress"] = build_stress(app, static=session == "stress-static")
            if SESSIONS[session].get("hide"):
                entry["hide"] = app.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": True},
                                                       "focus": False, "origin": "script"}, timeout=30)
            time.sleep(opts.settle)  # bench: the session settles (page loads, Chromium's post-load work) before the window
            instance = procs.Instance(app.app, app.process.pid)
            window_before = window_state(app)
            result = measure(app, instance, opts.measure)
            result["window_state"] = {"start": window_before, "end": window_state(app)}
            print(f"IDLE-BUDGET-WINDOW {session} " + json.dumps(result["window_state"]), flush=True)
            if opts.sample:
                result["sample"] = sample_threads(app.process.pid, opts.sample, os.path.join(out, session, "sample-app.txt"))
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
            for name, entry in (result.get("sample") or {}).items():
                top = "; ".join(f"{frame} x{count}" for frame, count in entry["frames"][:6])
                if top:
                    print(f"IDLE-BUDGET-SAMPLE {session} {name}: {top}", flush=True)
            for name, field, value, limit in overs:
                print(f"IDLE-BUDGET-OVER {session} {name} {field} {value} > {limit}", flush=True)
            all_overs += [(session, *o) for o in overs]
            markdown.append(table(session, kinds, overs))
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
    ratio_found = judge_against_chrome(report, budget)
    for session, name, field, value, limit in ratio_found:
        print(f"IDLE-BUDGET-OVER {session} {name} {field} {value} > {limit}", flush=True)
    all_overs += ratio_found
    if "ratio_to_chrome" in report:
        markdown.append(ratio_table(report["ratio_to_chrome"]))
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
