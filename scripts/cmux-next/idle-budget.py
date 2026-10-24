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
  light    the launch window with its terminal
  stress   STRESS (scripts/cmux-next/perf-stress-session.py: 60 workspaces, a 12-pane grid of 6 tabs each,
           Chromium pages elsewhere); its 10 busy terminals are stopped (Ctrl-C) before the settle, so the
           terminals are quiet

Budget: scripts/cmux-next/idle-budget.json (per process kind; a missing value is reported, not judged).
Over budget prints IDLE-BUDGET-OVER lines; the exit code is 0 unless --gate (no CI gate: the perf cron
runs it and reports).

Use (fleet only, a host with a GUI console session; never on a laptop in use):
  python3 scripts/cmux-next/idle-budget.py --app "<...>/cmux DEV <tag>.app" --out DIR \\
      [--sessions light,stress] [--settle 60] [--measure 60] [--json DIR/idle-budget.json]
  On the fleet through the allowlisted entry: scripts/measure/split-spring.sh --suite=idle-budget [...]

Output: one `IDLE-BUDGET-MACHINE {json}` line, one `IDLE-BUDGET-ROW {json}` line per session and process
kind, a Markdown table, and --json with every sample.
"""
import argparse, ctypes, json, os, platform, re, subprocess, sys, time

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


def measure(app, instance, seconds):
    """Counters of every process of the app over `seconds` with no input."""
    hangs0 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger0 = read_rpc(app, "debug.wakeups")
    pids = process_set(instance)
    first = {pid: (procs.counters(pid), procs.overhead(pid), threads(pid)) for pid in pids}
    began = time.monotonic()
    time.sleep(seconds)  # bench: the idle window itself (nothing is sent to the app in it)
    elapsed = time.monotonic() - began
    last_pids = process_set(instance)
    last = {pid: (procs.counters(pid), procs.overhead(pid), threads(pid)) for pid in last_pids}
    hangs1 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger1 = read_rpc(app, "debug.wakeups")
    rows = []
    for pid, cmd in sorted(last_pids.items()):
        (c1, o1, t1) = last[pid]
        if c1 is None or o1 is None:
            continue
        (c0, o0, t0) = first.get(pid, (None, None, {}))
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
            "pid": pid, "kind": kind(cmd), "command": cmd[:160], "partial": partial,
            "threads": o1[1], "threads_ran": len(ran), "ran": ran[:8],
            "cpu_pct": round(100 * (c1[1] - c0[1]) / 1e9 / elapsed, 4),
            "wakeups_per_s": round((c1[2] - c0[2]) / elapsed, 3),
            "csw_per_s": round(procs._delta32(o1[4], o0[4]) / elapsed, 3),
            "footprint_mb": round(c1[3] / procs.MB, 1),
        })
    result = {"seconds": round(elapsed, 1), "processes": rows}
    if "main_wakes" in hangs0 and "main_wakes" in hangs1:
        result["main_wakes_per_s"] = round((hangs1["main_wakes"] - hangs0["main_wakes"]) / elapsed, 3)
    owners = ledger_rates(ledger0, ledger1, elapsed)
    if owners is not None:
        result["ledger"] = owners
    return result


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
    """Per kind: count, threads (sum and max per process), wakeups/s (sum and max per process), CPU %."""
    kinds = {}
    for row in result["processes"]:
        entry = kinds.setdefault(row["kind"], {"n": 0, "threads": 0, "threads_max": 0, "wakeups_per_s": 0.0,
                                               "wakeups_max": 0.0, "csw_per_s": 0.0, "cpu_pct": 0.0, "threads_ran": 0})
        entry["n"] += 1
        entry["threads"] += row["threads"]
        entry["threads_max"] = max(entry["threads_max"], row["threads"])
        entry["wakeups_per_s"] = round(entry["wakeups_per_s"] + row["wakeups_per_s"], 3)
        entry["wakeups_max"] = max(entry["wakeups_max"], row["wakeups_per_s"])
        entry["csw_per_s"] = round(entry["csw_per_s"] + row["csw_per_s"], 3)
        entry["cpu_pct"] = round(entry["cpu_pct"] + row["cpu_pct"], 4)
        entry["threads_ran"] += row["threads_ran"]
    if "main_wakes_per_s" in result and "app" in kinds:
        kinds["app"]["main_wakes_per_s"] = result["main_wakes_per_s"]
    return kinds


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


# ---------------------------------------------------------------------------------------------------------
# Sessions


def load_stress():
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", STRESS_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def build_stress(app):
    """STRESS, then its busy terminals stopped (Ctrl-C), so the terminals are quiet."""
    stress_module = load_stress()
    stress = stress_module.Stress(app.rpc)
    summary = stress.build()
    for tab in getattr(stress, "busy", []):
        stress.send(tab, "\x03")
    summary["busy_terminals_stopped"] = len(getattr(stress, "busy", []))
    print("STRESS-SESSION " + json.dumps(summary), flush=True)
    return summary


def host_facts():
    display = subprocess.run(["system_profiler", "SPDisplaysDataType"], capture_output=True, text=True).stdout
    return {"host": platform.node(), "macos": platform.mac_ver()[0], "chip": subprocess.run(
        ["sysctl", "-n", "machdep.cpu.brand_string"], capture_output=True, text=True).stdout.strip(),
        "load": os.getloadavg(), "display": [l.strip() for l in display.splitlines() if "Refresh" in l or "Resolution" in l][:4]}


def table(session, kinds, overs):
    over_keys = {(k, f) for k, f, _, _ in overs}
    lines = [f"\n### {session}\n", "| process | n | threads (max) | wakeups/s (max) | main wakes/s | csw/s | CPU % | threads that ran |",
             "|---|---|---|---|---|---|---|---|"]
    order = ["app", "daemon", "holder", "terminal-host", "acpmux"]
    for name in sorted(kinds, key=lambda k: (order.index(k) if k in order else len(order), k)):
        e = kinds[name]
        mark = lambda f, v: f"**{v}**" if (name, f) in over_keys else f"{v}"  # noqa: E731
        lines.append(f"| {name} | {e['n']} | {e['threads']} ({mark('threads_max', e['threads_max'])}) | "
                     f"{mark('wakeups_per_s', e['wakeups_per_s'])} ({mark('wakeups_max', e['wakeups_max'])}) | "
                     f"{mark('main_wakes_per_s', e.get('main_wakes_per_s', '-'))} | {e['csw_per_s']} | {e['cpu_pct']} | {e['threads_ran']} |")
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
        app = BenchApp(opts.app, out=os.path.join(out, session))
        try:
            app.launch()
            entry = {}
            if session == "stress":
                entry["stress"] = build_stress(app)
            elif session != "light":
                raise SystemExit(f"idle-budget: unknown session {session}")
            time.sleep(opts.settle)  # bench: the session settles (page loads, Chromium's post-load work) before the window
            instance = procs.Instance(app.app, app.process.pid)
            result = measure(app, instance, opts.measure)
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
            for name, field, value, limit in overs:
                print(f"IDLE-BUDGET-OVER {session} {name} {field} {value} > {limit}", flush=True)
            all_overs += [(session, *o) for o in overs]
            markdown.append(table(session, kinds, overs))
        finally:
            app.stop()
    report["over"] = [list(o) for o in all_overs]
    text = f"# cmux idle budget, {machine['host']} (macOS {machine['macos']}), settle {opts.settle:g} s, window {opts.measure:g} s\n" + "\n".join(markdown)
    print(text, flush=True)
    with open(os.path.join(out, "idle-budget.md"), "w") as handle:
        handle.write(text + "\n")
    path = opts.json or os.path.join(out, "idle-budget.json")
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as handle:
        json.dump(report, handle, indent=1)
    print(f"IDLE-BUDGET over={len(all_overs)} json={path}", flush=True)
    sys.exit(1 if opts.gate and all_overs else 0)


if __name__ == "__main__":
    main()
