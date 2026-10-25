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
  tabs-static   the launch pane with 5 WebKit and 10 Chromium tabs hidden behind 1 shown static Chromium tab,
                every page static (TabPages); the settle lasts past `browser.freezeHiddenTabs`
  minimized     the light session with its window minimized (action minimizeWindow)
  energy-saver  tabs-static with `energy.saver: always`, the shown tab an animated page (/anim.html, rAF every
                frame, no input) whose rAF rate is read over DevTools at the window's two ends

Per window the report also has, per session: `energy_mw` (ri_energy_nj per process, summed per kind and over the
tree), `assertions` (`pmset -g assertions` held by or created for a pid of the set), `saver` (asked by the
session, observed through debug.energy at both ends) and `thermal` (ProcessInfo.thermalState at both ends).
--gate refuses a session whose observed saver state is not the one it asked for; a session whose thermal state
reached serious or critical has `thermal_marked` on its rows.

A session that fails (STRESS refuses a window under the Dock, a launch fails) is recorded with its exit
code (`session_exits` in the report) and the others still run; the script exits 0 unless --gate.

Budget: scripts/cmux-next/idle-budget.json (per process kind; a missing value is reported, not judged).
Over budget prints IDLE-BUDGET-OVER lines; the exit code is 0 unless --gate (no CI gate: the perf cron
runs it and reports).

Use (fleet only, a host with a GUI console session; never on a laptop in use):
  python3 scripts/cmux-next/idle-budget.py --app "<...>/cmux DEV <tag>.app" --out DIR \\
      [--sessions light,stress|all] [--settle 60] [--measure 60] [--json DIR/idle-budget.json] [--gate]
  On the fleet through the allowlisted entry (STRESS needs the 1920 x 1080 virtual display):
    scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 -- --sessions tabs-static,energy-saver
  energy-saver reads its page over DevTools (CMUX_NEXT_CEF_EXTRA_SWITCHES remote-debugging-port, which only
  development bundles honor); without it the session's `anim` block holds the error.

Output: one `IDLE-BUDGET-MACHINE {json}` line, one `IDLE-BUDGET-ROW {json}` line per session and process
kind, IDLE-BUDGET-ENERGY / -STATE / -ASSERTION / -ANIM lines, IDLE-BUDGET-REFUSED for a saver mismatch and
IDLE-BUDGET-THERMAL for a marked session, a Markdown table, and --json with every sample.
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

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
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


def process_row(pid, cmd, first, last, elapsed):
    """One process's row over the window from its (counters, overhead, threads) reads at the two ends; `first`
    is None for a process that started inside the window (it counts from its start). counters are procs.counters
    (energy nJ, CPU ns, wakeups, footprint bytes): nJ per s / 1e6 is mW."""
    (c1, o1, t1) = last
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
    return {
        "pid": pid, "kind": kind(cmd), "command": cmd[:160], "partial": partial,
        "threads": o1[1], "threads_ran": len(ran), "ran": ran[:8],
        "cpu_pct": round(100 * (c1[1] - c0[1]) / 1e9 / elapsed, 4),
        "energy_mw": round((c1[0] - c0[0]) / 1e6 / elapsed, 3),
        "wakeups_per_s": round((c1[2] - c0[2]) / elapsed, 3),
        "csw_per_s": round(procs._delta32(o1[4], o0[4]) / elapsed, 3),
        "footprint_mb": round(c1[3] / procs.MB, 1),
    }


def window_end(app, pids, anim_port):
    """What one end of the window records outside the process counters: the app's energy policy (debug.energy:
    the saver state), the Mac's thermal state, the power assertions of the pid set and, with a DevTools port, the
    animated page's rAF count."""
    saver, reason = saver_state(read_rpc(app, "debug.energy"))
    end = {"saver": saver, "saver_reason": reason, "thermal": procs.thermal_state(),
           "assertions": procs.power_assertions(pids)}
    if anim_port is not None:
        end["anim"] = read_anim(anim_port)
    return end


def saver_state(reply):
    """(isSaver, reason) from a debug.energy reply (`policy`: EnergyPolicy, `inputs.reason`); (None, None) when the
    build has no debug.energy or the reply has no boolean isSaver."""
    policy = reply.get("policy") if isinstance(reply.get("policy"), dict) else {}
    inputs = reply.get("inputs") if isinstance(reply.get("inputs"), dict) else {}
    saver = policy.get("isSaver")
    if not isinstance(saver, bool):
        return None, None
    return saver, policy.get("reason") or inputs.get("reason")


def measure(app, instance, seconds, anim_port=None):
    """Counters of every process of the app over `seconds` with no input."""
    hangs0 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger0 = read_rpc(app, "debug.wakeups")
    counters0 = app_counters(app)
    pids = process_set(instance)
    start = window_end(app, pids, anim_port)
    first = {pid: (procs.counters(pid), procs.overhead(pid), threads(pid)) for pid in pids}
    began = time.monotonic()
    time.sleep(seconds)  # bench: the idle window itself (nothing is sent to the app in it)
    elapsed = time.monotonic() - began
    last_pids = process_set(instance)
    last = {pid: (procs.counters(pid), procs.overhead(pid), threads(pid)) for pid in last_pids}
    end = window_end(app, last_pids, anim_port)
    hangs1 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger1 = read_rpc(app, "debug.wakeups", {"run_loop": True})
    counters1 = app_counters(app)
    rows = [process_row(pid, cmd, first.get(pid), last[pid], elapsed) for pid, cmd in sorted(last_pids.items())
            if last[pid][0] is not None and last[pid][1] is not None]
    result = {"seconds": round(elapsed, 1), "processes": rows, "ends": {"start": start, "end": end}}
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
    """Per kind: count, threads (sum and max per process), wakeups/s (sum and max per process), CPU %, CPU
    energy (mW, summed)."""
    kinds = {}
    for row in result["processes"]:
        entry = kinds.setdefault(row["kind"], {"n": 0, "threads": 0, "threads_max": 0, "wakeups_per_s": 0.0,
                                               "wakeups_max": 0.0, "csw_per_s": 0.0, "cpu_pct": 0.0, "energy_mw": 0.0,
                                               "threads_ran": 0})
        entry["n"] += 1
        entry["threads"] += row["threads"]
        entry["threads_max"] = max(entry["threads_max"], row["threads"])
        entry["wakeups_per_s"] = round(entry["wakeups_per_s"] + row["wakeups_per_s"], 3)
        entry["wakeups_max"] = max(entry["wakeups_max"], row["wakeups_per_s"])
        entry["csw_per_s"] = round(entry["csw_per_s"] + row["csw_per_s"], 3)
        entry["cpu_pct"] = round(entry["cpu_pct"] + row["cpu_pct"], 4)
        entry["energy_mw"] = round(entry["energy_mw"] + row.get("energy_mw", 0.0), 3)
        entry["threads_ran"] += row["threads_ran"]
    if "main_wakes_per_s" in result and "app" in kinds:
        kinds["app"]["main_wakes_per_s"] = result["main_wakes_per_s"]
    return kinds


def energy_summary(kinds):
    """{"per_kind": {kind: mW}, "tree": mW}: the CPU energy of each kind and of the whole process set."""
    per_kind = {name: entry.get("energy_mw", 0.0) for name, entry in kinds.items()}
    return {"per_kind": per_kind, "tree": round(sum(per_kind.values()), 3)}


def saver_mismatch(asked, observed):
    """Why the window's saver state is not the one the session asked for, or None. `observed` is the saver state
    debug.energy reported at each end (None: the build has no debug.energy). A session that asks for the saver
    needs both ends to show it; a session that asks for normal mode fails only on an end that shows the saver."""
    if asked and not all(state is True for state in observed):
        return f"asked energy saver on, debug.energy reported {observed}"
    if not asked and any(state is True for state in observed):
        return f"asked energy saver off, debug.energy reported {observed}"
    return None


def worst_thermal(states):
    """The hottest of `states` (ProcessInfo.thermalState names; None is unknown), or None when none is known."""
    known = [s for s in states if s in procs.THERMAL_STATES]
    return max(known, key=procs.THERMAL_STATES.index) if known else None


def thermal_marked(state):
    """Rows taken at serious or critical are marked: the Mac throttles, so the numbers are not comparable."""
    return state in ("serious", "critical")


def summarize(session, result, budget):
    """The report entry of one measured window: kinds, overs, energy_mw, assertions, saver, thermal (and the
    animated page's rAF rate when the session has one)."""
    spec = SESSIONS[session]
    ends = result.get("ends") or {}
    start, end = ends.get("start") or {}, ends.get("end") or {}
    kinds = aggregate(result)
    thermal = worst_thermal([start.get("thermal"), end.get("thermal")])
    marked = thermal_marked(thermal)
    if marked:
        for entry in kinds.values():
            entry["thermal_marked"] = True
    observed = [start.get("saver"), end.get("saver")]
    seen, assertions = set(), []
    for item in (start.get("assertions") or []) + (end.get("assertions") or []):
        if item["line"] not in seen:
            seen.add(item["line"])
            assertions.append(item)
    entry = {"result": result, "kinds": kinds, "over": [list(o) for o in over_budget(session, kinds, budget)],
             "energy_mw": energy_summary(kinds), "assertions": assertions,
             "saver": {"asked": spec.get("saver", False), "observed": observed,
                       "reason": end.get("saver_reason") or start.get("saver_reason"),
                       "mismatch": saver_mismatch(spec.get("saver", False), observed)},
             "thermal": {"start": start.get("thermal"), "end": end.get("thermal"), "worst": thermal, "marked": marked}}
    if spec.get("anim"):
        entry["anim"] = anim_rate(start.get("anim"), end.get("anim"))
    return entry


def exit_code(gate, overs, refused):
    """1 under --gate when a value is over its budget or a session was refused (saver mismatch), else 0."""
    return 1 if gate and (overs or refused) else 0


def over_budget(session, kinds, budget):
    """[(kind, field, value, limit)] for every value over its budget. Limits are per process for
    `wakeups_max` and `threads_max`, and per kind for the rest."""
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
    return out


# Noise floors of the cron rows: one wakeup a second, two threads (a pool thread parks or exits late), half a mW.
CRON_FLOORS = {"wakeups_per_s": 0.5, "wakeups_max": 0.5, "main_wakes_per_s": 0.5, "threads_max": 2, "threads": 2,
               "energy_mw": 0.5}


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
                unit = "threads" if field.startswith("threads") else "mW" if field == "energy_mw" else "/s"
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


# The animated page of energy-saver: one box turned on every rAF, the count in window.__rafCount (read over DevTools).
ANIM_PAGE = ("<!doctype html><meta charset='utf-8'><title>idle anim</title>"
             "<style>body{margin:0;background:#f4f4f6}#b{width:64px;height:64px;margin:40px;border-radius:12px;"
             "background:#20304a}</style><div id='b'></div><script>window.__rafCount=0;"
             "const b=document.getElementById('b');requestAnimationFrame(function f(){window.__rafCount++;"
             "b.style.transform='rotate('+(window.__rafCount*3%360)+'deg)';requestAnimationFrame(f)})</script>")
ANIM_PATH = "/anim.html"


def page_handler(requested):
    """The HTTP handler of the idle pages: ANIM_PATH is the animated page, any other path a static page (no
    script, no timer, no animation) numbered by the digits that end its path. Each served path is added to `requested`."""
    import http.server

    class Handler(http.server.BaseHTTPRequestHandler):
        def do_GET(self):  # noqa: N802
            path = self.path.split("?", 1)[0]
            if path == "/favicon.ico":
                self.send_error(404)
                return
            if path == ANIM_PATH:
                data = ANIM_PAGE.encode()
            else:
                number = re.search(r"(\d+)$", path.rstrip("/"))
                index = int(number.group(1)) if number else 0
                data = (STATIC_PAGE % (index, index, "<div></div>" * 120, "lorem ipsum dolor sit amet " * 200)).encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/html")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            requested.add(path)

        def log_message(self, *args):
            pass

    return Handler


class TabPages:
    """The local server of the tab sessions' pages (page_handler), on 127.0.0.1, started by the first url()."""

    def __init__(self):
        self.requested = set()
        self.server = None

    def url(self, path):
        if self.server is None:
            import http.server
            import threading
            self.server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), page_handler(self.requested))
            threading.Thread(target=self.server.serve_forever, daemon=True).start()
        return f"http://127.0.0.1:{self.server.server_address[1]}{path}"

    def wait_requested(self, path, seconds):
        deadline = time.monotonic() + seconds
        while path not in self.requested:
            if time.monotonic() > deadline:
                return False
            time.sleep(0.2)  # bench: bounded wait for the tab to request its page
        return True

    def close(self):
        if self.server is not None:
            self.server.shutdown()
            self.server.server_close()
            self.server = None


def static_pages(stress_module):
    """STRESS's local pages without their rAF spinner (page_handler's static pages)."""
    pages = stress_module.Pages()
    pages.handler = page_handler(set())
    return pages


class SessionShapeError(RuntimeError):
    """The session could not be built as its table entry says (a tab that never opened, a window not minimized)."""


def run_action(app, action, args=None, focus=False, timeout=30):
    """action.run from a script; raises SessionShapeError on the app's refusal. A reply that times out is no
    refusal (a cold CefInitialize can outlast the reply while the tab still opens): the caller checks the result.
    `focus` selects what the action opens, as STRESS and browser-idle-cost-live open their tabs."""
    reply = app.rpc("action.run", {"action": action, "args": args or {}, "focus": focus, "origin": "script"},
                    timeout=timeout)
    error = reply.get("error") if isinstance(reply, dict) else None
    code = error.get("code") if isinstance(error, dict) else None
    if error and code != "timeout" and not (isinstance(reply, dict) and reply.get("unreachable")):
        raise SessionShapeError(f"{action} refused: {str(error)[:200]}")
    return reply


def build_tabs(app, pages, tabs):
    """Opens the session's tabs in the launch pane: the hidden WebKit tabs, the hidden Chromium tabs, then the shown
    Chromium tab last (a new tab is selected, so every earlier one is hidden behind it). Waits for each tab's page
    request. Returns {engine: count} of the opened tabs."""
    plan = ([("webkit", f"/static/w{n}") for n in range(tabs["webkit_hidden"])]
            + [("chromium", f"/static/c{n}") for n in range(tabs["chromium_hidden"])]
            + [("chromium", tabs["shown"])])
    opened = {}
    for engine, path in plan:
        run_action(app, f"openBrowser.{engine}", {"url": pages.url(path)}, focus=True, timeout=90)
        if not pages.wait_requested(path, 90):
            raise SessionShapeError(f"{engine} tab {path} never requested its page in 90 s")
        opened[engine] = opened.get(engine, 0) + 1
    return opened


def read_anim(port):
    """The animated page's {count, t_ms, visibility} over DevTools, or {"error": ...}."""
    from ext_e2e import cdp
    try:
        target = next((t for t in cdp.targets(port) if t.get("type") == "page"
                       and (t.get("url") or "").split("?", 1)[0].endswith(ANIM_PATH)), None)
        if target is None:
            return {"error": "no DevTools page target for " + ANIM_PATH}
        session = cdp.page_session(port, target["id"])
        try:
            return session.evaluate("({count: window.__rafCount, t_ms: performance.now(),"
                                    " visibility: document.visibilityState})", timeout=10)
        finally:
            session.close()
    except Exception as error:  # noqa: BLE001 - the report keeps why the page could not be read
        return {"error": f"{type(error).__name__}: {error}"[:200]}


def anim_rate(start, end):
    """{raf_per_s, visibility} of the animated page between two read_anim results (the page's own clock), or the
    first error."""
    for read in (start, end):
        if not isinstance(read, dict) or "error" in read or not isinstance(read.get("count"), (int, float)):
            return {"error": (read or {}).get("error", "no rAF count") if isinstance(read, dict) else "not read"}
    seconds = (end["t_ms"] - start["t_ms"]) / 1000
    if seconds <= 0:
        return {"error": "the page clock did not advance"}
    return {"raf_per_s": round((end["count"] - start["count"]) / seconds, 2), "seconds": round(seconds, 1),
            "visibility": [start.get("visibility"), end.get("visibility")]}


def free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


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
# Hidden Chromium tabs freeze this long after they hide (BrowserHibernationSetting's default, set explicitly so the
# settle below is known to outlast it); the tab sessions settle at least FREEZE_GRACE_S past it.
FREEZE_HIDDEN_TABS_S = 30
FREEZE_GRACE_S = 15
TABS_CONFIG = {**BASE_CONFIG, "browser": {"freezeHiddenTabs": FREEZE_HIDDEN_TABS_S}}
TABS_STATIC = {"webkit_hidden": 5, "chromium_hidden": 10, "shown": "/static/shown"}
# The sessions (the docstring describes each). Keys: config (the app's cmux.json), hide, minimize, stress, static
# (STRESS without its rAF spinner), tabs (build_tabs's plan), settle_min (seconds), saver (the energy saver state the
# session asks for; --gate refuses a window that shows another), anim (read the animated page over DevTools).
SESSIONS = {
    "light": {},
    "light-webkit": {"config": {**BASE_CONFIG, "browser": {"defaultEngine": "webkit"}}},
    "light-hidden": {"hide": True},
    "minimized": {"minimize": True},
    "stress": {"stress": True},
    "stress-static": {"stress": True, "static": True},
    "tabs-static": {"config": TABS_CONFIG, "tabs": TABS_STATIC, "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S},
    "energy-saver": {"config": {**TABS_CONFIG, "energy": {"saver": "always"}}, "tabs": {**TABS_STATIC, "shown": ANIM_PATH},
                     "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S, "saver": True, "anim": True},
}


def parse_sessions(text):
    """The --sessions list (`all`: every session); SystemExit naming the first unknown one, before any launch."""
    names = list(SESSIONS) if text == "all" else [s for s in text.split(",") if s]
    for name in names:
        if name not in SESSIONS:
            raise SystemExit(f"idle-budget: unknown session {name} (one of {', '.join(SESSIONS)})")
    return names


def settle_seconds(session, asked):
    """The settle of `session`: the asked one, at least the session's settle_min (past the hidden-tab freeze)."""
    return max(asked, SESSIONS[session].get("settle_min", 0))


def minimize(app):
    """Minimizes the launch window (action minimizeWindow) and waits until debug.window_list reports it so."""
    run_action(app, "minimizeWindow")
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        main = window_state(app).get("main") or []
        if main and all(w.get("miniaturized") for w in main):
            return {"miniaturized": len(main)}
        time.sleep(0.2)  # bench: bounded wait for the window to reach the Dock
    raise SessionShapeError(f"the window is not minimized after 10 s: {window_state(app)}")


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


def table(session, kinds, overs, entry=None):
    over_keys = {(k, f) for k, f, _, _ in overs}
    lines = [f"\n### {session}\n"]
    if entry:
        saver, thermal = entry["saver"], entry["thermal"]
        lines.append(f"energy {entry['energy_mw']['tree']} mW (tree); saver asked {saver['asked']}, observed "
                     f"{saver['observed']}{' REFUSED' if saver['mismatch'] else ''}; thermal {thermal['worst']}"
                     f"{' (marked)' if thermal['marked'] else ''}; {len(entry['assertions'])} power assertion(s)"
                     + (f"; page rAF {entry['anim']}" if "anim" in entry else "") + "\n")
    lines += ["| process | n | threads (max) | wakeups/s (max) | main wakes/s | csw/s | CPU % | mW | threads that ran |",
              "|---|---|---|---|---|---|---|---|---|"]
    order = ["app", "daemon", "holder", "terminal-host", "acpmux"]
    for name in sorted(kinds, key=lambda k: (order.index(k) if k in order else len(order), k)):
        e = kinds[name]
        mark = lambda f, v: f"**{v}**" if (name, f) in over_keys else f"{v}"  # noqa: E731
        lines.append(f"| {name} | {e['n']} | {e['threads']} ({mark('threads_max', e['threads_max'])}) | "
                     f"{mark('wakeups_per_s', e['wakeups_per_s'])} ({mark('wakeups_max', e['wakeups_max'])}) | "
                     f"{mark('main_wakes_per_s', e.get('main_wakes_per_s', '-'))} | {e['csw_per_s']} | {e['cpu_pct']} | "
                     f"{mark('energy_mw', e.get('energy_mw', '-'))} | {e['threads_ran']} |")
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
    parser.add_argument("--gate", action="store_true",
                        help="exit 1 when a value is over its budget or a session's saver state is not the one it asked for")
    parser.add_argument("--sample", type=float, default=10,
                        help="seconds of /usr/bin/sample of the app after the window, to name the threads that woke (0: none)")
    opts, _unknown = parser.parse_known_args()
    sessions = parse_sessions(opts.sessions)
    from bench_launch import BenchApp
    budget = json.load(open(opts.budget))
    out = opts.out or os.path.join(os.getcwd(), "artifacts", "idle-budget")
    os.makedirs(out, exist_ok=True)
    machine = host_facts()
    print("IDLE-BUDGET-MACHINE " + json.dumps(machine), flush=True)
    report = {"machine": machine, "app": opts.app, "settle_s": opts.settle, "measure_s": opts.measure, "sessions": {}}
    all_overs = []
    refused = []
    markdown = []
    for session in sessions:
        spec = SESSIONS[session]
        anim_port = free_port() if spec.get("anim") else None
        env = {"CMUX_NEXT_CEF_EXTRA_SWITCHES": f"remote-debugging-port={anim_port}:remote-allow-origins=*"} if anim_port else None
        app = BenchApp(opts.app, out=os.path.join(out, session), config=spec.get("config"), env=env)
        pages = TabPages()
        try:
            entry = {"fresh_session": fresh_session(app)}
            report["sessions"][session] = entry
            app.launch()
            if spec.get("stress"):
                entry["stress"] = build_stress(app, static=spec.get("static", False))
            if spec.get("tabs"):
                entry["tabs"] = build_tabs(app, pages, spec["tabs"])
            if spec.get("hide"):
                entry["hide"] = app.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": True},
                                                       "focus": False, "origin": "script"}, timeout=30)
            if spec.get("minimize"):
                entry["minimize"] = minimize(app)
            settle = settle_seconds(session, opts.settle)
            entry["settle_s"] = settle
            time.sleep(settle)  # bench: the session settles (page loads, Chromium's post-load work, the hidden-tab freeze)
            instance = procs.Instance(app.app, app.process.pid)
            window_before = window_state(app)
            result = measure(app, instance, opts.measure, anim_port)
            result["window_state"] = {"start": window_before, "end": window_state(app)}
            print(f"IDLE-BUDGET-WINDOW {session} " + json.dumps(result["window_state"]), flush=True)
            if opts.sample:
                result["sample"] = sample_threads(app.process.pid, opts.sample, os.path.join(out, session, "sample-app.txt"))
            entry.update(summarize(session, result, budget))
            kinds, overs = entry["kinds"], [tuple(o) for o in entry["over"]]
            for name, values in kinds.items():
                print("IDLE-BUDGET-ROW " + json.dumps({"session": session, "kind": name, **values}), flush=True)
            print(f"IDLE-BUDGET-ENERGY {session} " + json.dumps(entry["energy_mw"]), flush=True)
            print(f"IDLE-BUDGET-STATE {session} " + json.dumps({"saver": entry["saver"], "thermal": entry["thermal"]}), flush=True)
            for item in entry["assertions"]:
                print(f"IDLE-BUDGET-ASSERTION {session} {item['line']}", flush=True)
            if "anim" in entry:
                print(f"IDLE-BUDGET-ANIM {session} " + json.dumps(entry["anim"]), flush=True)
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
            for name, field, value, limit in overs:
                print(f"IDLE-BUDGET-OVER {session} {name} {field} {value} > {limit}", flush=True)
            if entry["saver"]["mismatch"]:
                refused.append(session)
                print(f"IDLE-BUDGET-REFUSED {session} saver: {entry['saver']['mismatch']}", flush=True)
            if entry["thermal"]["marked"]:
                print(f"IDLE-BUDGET-THERMAL {session} rows taken at {entry['thermal']['worst']}: not comparable", flush=True)
            all_overs += [(session, *o) for o in overs]
            markdown.append(table(session, kinds, overs, entry))
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
            pages.close()
    report["over"] = [list(o) for o in all_overs]
    report["refused"] = refused
    report["session_exits"] = {name: entry.get("exit") for name, entry in report["sessions"].items()}
    text = f"# cmux idle budget, {machine['host']} (macOS {machine['macos']}), settle {opts.settle:g} s, window {opts.measure:g} s\n" + "\n".join(markdown)
    print(text, flush=True)
    with open(os.path.join(out, "idle-budget.md"), "w") as handle:
        handle.write(text + "\n")
    path = opts.json or os.path.join(out, "idle-budget.json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(report, handle, indent=1)
    print(f"IDLE-BUDGET over={len(all_overs)} refused={json.dumps(refused)} sessions={json.dumps(report['session_exits'])} "
          f"json={path}", flush=True)
    sys.exit(exit_code(opts.gate, all_overs, refused))


if __name__ == "__main__":
    main()
