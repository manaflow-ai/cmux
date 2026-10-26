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
  minimized     the light session with its window minimized (minimizeWindow)
  light-hidden and minimized run in shipping mode (as every session) and name every main-thread wake source above
  0.1/s in HIDDEN-WAKE lines (owner, per_s, top frame; `hidden_wake_sources`), from the wakeup ledger, the main
  run loop's repeating timer fires and the run-loop callouts of a `/usr/bin/sample` of the main thread.
  Each session starts from an empty saved session (`fresh_session`).
  stress-static  STRESS with its pages served without their rAF spinner (STRESS's own pages animate: not idle)
  stress   STRESS (scripts/cmux-next/perf-stress-session.py: 60 workspaces, a 12-pane grid of 6 tabs each,
           Chromium pages elsewhere); its 10 busy terminals are stopped (Ctrl-C) before the settle, so the
           terminals are quiet

A session that fails (STRESS refuses a window under the Dock, a launch fails) is recorded with its exit
code (`session_exits` in the report) and the others still run; the script exits 0 unless --gate.

Shipping measurement mode (always on; plans/cmux-next/chrome-parity/p14-energy.md, task 100): every session
launches with bench_launch.shipping_env (CMUX_NEXT_BENCH_SHIPPING_DRAW=1: occluded windows stop drawing as in a
user's launch; CMUX_NEXT_DEV_SENTRY=1 and CMUX_NEXT_DEV_HANG_REPORTS=1: Sentry and hang reports run; no
CMUX_NEXT_NO_ACTIVATE) and activates the app once before the settle. `--shipping-draw off` keeps the automation draw
of occluded windows (a Debug build's), for an on/off comparison. The bundle's build config (debug, bench-hooks,
release) is read first, and `--gate` refuses a Debug build: its code and its draw are not what users run. Each
session records build_config, sentry_started (a SentryCrash thread runs in the app), hang_reports (the launch's opt-in
and the main-thread watchdog), draws_when_occluded (WindowDrawPolicy's rule for this build and launch env) and
activated.

Budget: scripts/cmux-next/idle-budget.json (per process kind; a missing value is reported, not judged).
Over budget prints IDLE-BUDGET-OVER lines; the exit code is 0 unless --gate (no CI gate: the perf cron
runs it and reports).

Use (fleet only, a host with a GUI console session; never on a laptop in use):
  python3 scripts/cmux-next/idle-budget.py --app "<...>/cmux DEV <tag>.app" --out DIR \\
      [--sessions light,stress] [--settle 60] [--measure 60] [--json DIR/idle-budget.json]
  On the fleet through the allowlisted entry (STRESS needs the 1920 x 1080 virtual display):
    scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 [...]

Output: one `IDLE-BUDGET-MACHINE {json}` line, one `IDLE-BUDGET-ROW {json}` line per session and process
kind, for a hidden session `HIDDEN-WAKE {json}` per source and one `HIDDEN-WAKE-TOTAL {json}` with sha and host,
a Markdown table, and --json with every sample.
"""
import argparse, ctypes, glob, json, os, platform, re, shutil, subprocess, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "perf-bench"))
import procs  # noqa: E402  (process set of one app: descendants, bundle processes, responsible XPC processes)

BUDGET_FILE = os.path.join(HERE, "idle-budget.json")
STRESS_FILE = os.path.join(HERE, "perf-stress-session.py")

# ---------------------------------------------------------------------------------------------------------
# Per-thread counters (libproc, same user, no root)

_libproc = ctypes.CDLL("/usr/lib/libproc.dylib") if sys.platform == "darwin" else None  # the pure parts load anywhere (tests)
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
    ledger0 = read_rpc(app, "debug.wakeups", {"run_loop": True})
    counters0 = app_counters(app)
    pids = process_set(instance)
    first = {pid: (procs.counters(pid), procs.overhead(pid), threads(pid)) for pid in pids}
    began = time.monotonic()
    time.sleep(seconds)  # bench: the idle window itself (nothing is sent to the app in it)
    elapsed = time.monotonic() - began
    last_pids = process_set(instance)
    last = {pid: (procs.counters(pid), procs.overhead(pid), threads(pid)) for pid in last_pids}
    hangs1 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger1 = read_rpc(app, "debug.wakeups", {"run_loop": True})
    counters1 = app_counters(app)
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
    rates = {key: round((counters1[key] - counters0[key]) / elapsed, 3) for key in counters1
             if key in counters0 and counters1[key] != counters0[key]}
    if rates:
        result["app_counter_rates"] = rates
    if ledger1.get("main_run_loop"):
        result["main_run_loop_timers"] = run_loop_timers(ledger1["main_run_loop"])
        if ledger0.get("main_run_loop"):
            result["main_run_loop_timer_fires"] = timer_fires(ledger0["main_run_loop"], ledger1["main_run_loop"], elapsed)
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


def run_sample(pid, seconds, path):
    """`/usr/bin/sample` of `pid` for `seconds` after the window (it suspends the process to sample, so it never runs
    inside the measured window); its text, "" when it failed."""
    try:
        subprocess.run(["/usr/bin/sample", str(pid), str(seconds), "-mayDie", "-file", path], capture_output=True,
                       timeout=seconds + 60)
        return open(path, errors="replace").read()
    except (OSError, subprocess.TimeoutExpired):
        return ""


WAIT_SYMBOLS = ("mach_msg", "__psynch_cvwait", "__workq_kernreturn", "kevent", "__semwait", "__select", "__ulock_wait",
                "start_wqthread", "thread_start", "_pthread_start")
THREAD_HEAD_RE = re.compile(r"\s{4}(\d+) Thread_\d+(.*)")
FRAME_RE = re.compile(r"[\s+!:|]*(\d+) (.+?)\s+\(in ([^)]+)\)")


def call_graph(text):
    """The `Call graph:` part of a `/usr/bin/sample` report."""
    return text.split("Call graph:", 1)[-1].split("Total number in stack", 1)[0]


def threads_from_sample(text):
    """Per thread of a `/usr/bin/sample` report, the frames with the most samples outside the wait."""
    threads_out = {}
    current = None
    for line in call_graph(text).splitlines():
        head = THREAD_HEAD_RE.match(line)
        if head:
            name = head.group(2).strip(" :") or "thread"
            current = {"samples": int(head.group(1)), "frames": {}}
            threads_out[f"{name} ({head.group(1)})"] = current
            continue
        frame = FRAME_RE.match(line)
        if current is not None and frame:
            count, symbol, image = int(frame.group(1)), frame.group(2), frame.group(3)
            if any(wait in symbol for wait in WAIT_SYMBOLS):
                continue
            key = f"{symbol} ({image})"
            current["frames"][key] = max(current["frames"].get(key, 0), count)
    for entry in threads_out.values():
        entry["frames"] = sorted(entry["frames"].items(), key=lambda kv: -kv[1])[:12]
    return threads_out


# ---------------------------------------------------------------------------------------------------------
# Hidden main wakes (p14-energy-095): who wakes the main thread while no window can be seen

# CFRunLoop's callout trampolines (CoreFoundation CFRunLoop.c: __CFRunLoopDoTimer, __CFRunLoopDoSources0,
# __CFRunLoopDoSource1, _dispatch_main_queue_callback_4CF, __CFRunLoopDoBlocks, __CFRunLoopDoObservers), the frame
# below __CFRunLoopRun that says why the main thread is awake. A timer, a source, a main-queue item or a block wakes
# the run loop; observers run on every wake one of those causes, so they are listed but never counted as a cause.
# Chromium's MessagePumpCFRunLoopBase (base/message_loop/message_pump_apple.mm) has the same split: a timer and a
# work source wake it, observers only bracket the loop.
RUN_LOOP_CALLOUTS = {
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__": "timer",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__": "source0",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE1_PERFORM_FUNCTION__": "source1",
    "__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__": "main-queue",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__": "block",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__": "observer",
}
WAKE_CAUSES = ("timer", "source0", "source1", "main-queue", "block")
# Images whose frames do not name an owner: the OS frameworks and the runtime. The first frame below a callout in
# any other image (the app binary, its frameworks, Sentry, Chromium, WebKit) names the owner.
SYSTEM_IMAGES = {"CoreFoundation", "Foundation", "AppKit", "HIToolbox", "SkyLight", "QuartzCore", "CoreGraphics",
                 "CoreText", "CFNetwork", "IOKit", "Security", "Metal", "CoreVideo", "CoreDisplay", "ViewBridge",
                 "SwiftUI", "SwiftUICore", "AttributeGraph", "Combine", "Observation", "CoreServices",
                 "LaunchServices", "AE", "CarbonCore", "RunningBoardServices", "BackBoardServices",
                 "UIFoundation", "IOSurface", "ColorSync", "ImageIO", "CoreImage", "dyld"}
# Trampolines skipped when a callout has no owner frame: its owner is then the first OS frame that does the work.
TRAMPOLINE_IMAGES = {"CoreFoundation", "Foundation", "libdispatch.dylib", "libobjc.A.dylib"}


SWIFT_THUNKS = ("thunk for ", "reabstraction thunk", "partial apply for ", "@objc ", "merged ")


def is_system_image(image):
    return image in SYSTEM_IMAGES or image.startswith("lib")


def names_no_owner(node):
    """True for a frame that can not name an owner: an OS image, or a Swift thunk with a frame below it."""
    return is_system_image(node["image"]) or (node["symbol"].startswith(SWIFT_THUNKS) and bool(node["children"]))


def main_thread_tree(text):
    """The main thread's call tree in a `/usr/bin/sample` report, nested {symbol, image, count, children} (the thread
    on com.apple.main-thread, else the first thread); None when the report has no thread."""
    order = []
    stack = []
    for line in call_graph(text).splitlines():
        head = THREAD_HEAD_RE.match(line)
        if head:
            thread = {"symbol": head.group(2).strip(" :") or "thread", "image": "", "count": int(head.group(1)),
                      "children": []}
            order.append(thread)
            stack = [(-1, thread)]
            continue
        frame = FRAME_RE.match(line)
        if not stack or not frame:
            continue
        depth = frame.start(1)
        node = {"symbol": frame.group(2), "image": frame.group(3), "count": int(frame.group(1)), "children": []}
        while len(stack) > 1 and stack[-1][0] >= depth:
            stack.pop()
        stack[-1][1]["children"].append(node)
        stack.append((depth, node))
    main = [thread for thread in order if "com.apple.main-thread" in thread["symbol"]]
    return (main or order or [None])[0]


def owner_name(node):
    return f"{node['symbol'][:120]} ({node['image']})"


def unowned(node):
    """Samples of `node` that no owner frame below it takes (an owner frame takes all of its own samples)."""
    if not names_no_owner(node):
        return 0
    return node["count"] - sum(child["count"] - unowned(child) for child in node["children"])


def system_owner(callout):
    """The owner of a callout's samples that have no owner frame: the first frame on their heaviest path that is not
    a run-loop, dispatch or runtime trampoline (a WebKit timer, an AppKit event handler)."""
    node = callout
    while node["children"]:
        heaviest = max(node["children"], key=unowned)
        if unowned(heaviest) == 0:
            break
        node = heaviest
        if node["image"] not in TRAMPOLINE_IMAGES:
            break
    return owner_name(node)


def callout_owners(tree):
    """{(kind, owner): samples} of the main thread: for each outermost run-loop callout, every first frame below it
    in a non-system image is an owner with its samples; the callout's other samples go to its system owner."""
    out = {}

    def add(key, count):
        out[key] = out.get(key, 0) + count

    pending = [tree] if tree else []
    while pending:
        node = pending.pop()
        kind = RUN_LOOP_CALLOUTS.get(node["symbol"])
        if not kind:
            pending.extend(node["children"])
            continue
        below = list(node["children"])
        while below:
            child = below.pop()
            if names_no_owner(child):
                below.extend(child["children"])
            else:
                add((kind, owner_name(child)), child["count"])
        rest = unowned(node)
        if rest > 0:
            add((kind, system_owner(node)), rest)
    return out


def main_callouts_from_sample(text):
    """[{kind, owner, samples}] of the main thread's run-loop callouts in a `/usr/bin/sample` report, most first."""
    rows = [{"kind": kind, "owner": owner, "samples": count}
            for (kind, owner), count in callout_owners(main_thread_tree(text)).items()]
    return sorted(rows, key=lambda r: (-r["samples"], r["kind"], r["owner"]))


def timer_fires(before, after, elapsed):
    """Fires per second of each repeating main run-loop timer between two `CFCopyDescription`s of the main run loop
    (debug.wakeups `run_loop`): its next fire date advances one interval per fire. One-shot timers (interval 0) have
    no count here; the sample's timer callouts name them. A fire the run loop skipped (App Nap) counts as a fire, so
    the rate is an upper bound."""
    def repeating(description):
        found = {}
        for valid, interval, fire, callout in TIMER_RE.findall(description or ""):
            if valid == "Yes" and float(interval) > 0:
                found.setdefault((callout.strip()[:160], float(interval)), set()).add(float(fire))
        return {key: sorted(fires) for key, fires in found.items()}

    first, last = repeating(before), repeating(after)
    out = []
    for (callout, interval), fires1 in last.items():
        fires0 = first.get((callout, interval))
        if not fires0 or len(fires0) != len(fires1) or elapsed <= 0:
            continue
        fired = sum(max(0, round((f1 - f0) / interval)) for f0, f1 in zip(fires0, fires1))
        if fired:
            out.append({"callout": callout, "interval_s": interval, "timers": len(fires1),
                        "per_s": round(fired / elapsed, 3)})
    return sorted(out, key=lambda t: (-t["per_s"], t["callout"]))


HIDDEN_WAKE_FLOOR = 0.1  # per second: every main wake source above it is named


def hidden_wake_sources(result, floor=HIDDEN_WAKE_FLOOR):
    """The main thread's wake sources of a hidden session, each {owner, kind, per_s, top, basis}:

    - basis `ledger`: a wakeup ledger owner (DemandTimer, FrameScheduler, Backoff; any thread), its count in the
      window;
    - basis `run-loop-timer`: a repeating main run-loop timer, its fires in the window (`timer_fires`);
    - basis `sample-share`: a run-loop callout's owner in the `/usr/bin/sample` of the main thread after the window.
      per_s is the window's main wakes/s times the owner's share of the wake-cause samples. Samples measure time,
      so a long callout reads high and a short one low; the other two bases are counts.

    The same source can show under two bases (a ledger DemandTimer is also a main run-loop timer callout). Sources
    at or below `floor` per second are dropped; sample owners are kept when the window has no main wake count
    (per_s None). Observers are not causes and come back apart, with their samples."""
    sources = []
    for entry in (result.get("ledger") or {}).get("owners") or []:
        sources.append({"owner": f"{entry['owner']}:{entry['reason']}", "kind": "ledger", "per_s": entry["per_s"],
                        "top": None, "basis": "ledger"})
    for timer in result.get("main_run_loop_timer_fires") or []:
        sources.append({"owner": timer["callout"], "kind": "timer", "per_s": timer["per_s"], "top": timer["callout"],
                        "basis": "run-loop-timer", "interval_s": timer["interval_s"]})
    callouts = result.get("main_callouts") or []
    causes = [c for c in callouts if c["kind"] in WAKE_CAUSES]
    total = sum(c["samples"] for c in causes)
    main_wakes = result.get("main_wakes_per_s")
    for entry in causes:
        share = entry["samples"] / total
        per_s = round(main_wakes * share, 3) if isinstance(main_wakes, (int, float)) else None
        sources.append({"owner": entry["owner"], "kind": entry["kind"], "per_s": per_s, "top": entry["owner"],
                        "basis": "sample-share", "samples": entry["samples"], "share": round(share, 4)})
    kept = sorted((s for s in sources if s["per_s"] is None or s["per_s"] > floor), key=lambda s: -(s["per_s"] or 0))
    observers = [c for c in callouts if c["kind"] == "observer"][:10]
    return {"main_wakes_per_s": main_wakes, "cause_samples": total, "sources": kept, "observers": observers}


def hidden_wake_lines(session, report, build_sha, host):
    """The `HIDDEN-WAKE {json}` lines of one hidden session for the Q9 slots (one per source, most first), then one
    `HIDDEN-WAKE-TOTAL {json}` line with the build sha and host."""
    lines = []
    for source in report["sources"]:
        lines.append("HIDDEN-WAKE " + json.dumps({"session": session, **source}))
    for observer in report["observers"]:
        lines.append("HIDDEN-WAKE-OBSERVER " + json.dumps({"session": session, **observer}))
    lines.append("HIDDEN-WAKE-TOTAL " + json.dumps({
        "session": session, "sha": build_sha, "host": host, "main_wakes_per_s": report["main_wakes_per_s"],
        "cause_samples": report["cause_samples"], "sources": len(report["sources"]), "floor_per_s": HIDDEN_WAKE_FLOOR}))
    return lines


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
# can be seen), minimized (the light session with its window minimized), stress (STRESS, its busy terminals
# stopped). `hidden_wake` sessions run in shipping mode and print HIDDEN-WAKE lines (`hidden_wake_sources`).
SESSIONS = {
    "light": {},
    "light-webkit": {"config": {**BASE_CONFIG, "browser": {"defaultEngine": "webkit"}}},
    "light-hidden": {"hide": True, "hidden_wake": True},
    "minimized": {"minimize": True, "hidden_wake": True},
    "stress": {},
    "stress-static": {},
}


def bundle_build_config(app):
    """The bundle's build config as bench_launch reads it: `debug`, `bench-hooks` or `release`."""
    import bench_launch
    app = os.path.realpath(app).rstrip("/")
    binary = os.path.join(app, "Contents/MacOS/cmux DEV")
    if not os.path.exists(binary):
        found = [p for p in sorted(glob.glob(os.path.join(app, "Contents/MacOS/*"))) if not p.endswith(".dylib")]
        if not found:
            raise SystemExit(f"idle-budget: no executable in {app}/Contents/MacOS")
        binary = found[0]
    return bench_launch.bundle_kind(app, binary)


def gate_refusal(build_config, gate):
    """Why `--gate` refuses this bundle, or None: a Debug build is not the code or the draw users run."""
    if gate and build_config == "debug":
        return ("--gate refuses a Debug build: measure a Release build with CMUX_BENCH_HOOKS "
                "(its code, occlusion draw and Sentry are what users run)")
    return None


def launch_env(shipping_draw=True):
    """BenchApp's `env` of every session: the shipping measurement mode (bench_launch.shipping_env)."""
    import bench_launch
    return bench_launch.shipping_env(draw=shipping_draw)


def draws_when_occluded(build_config, env):
    """WindowDrawPolicy.isAutomationLaunch for this build and launch env (PageWebView.rendersWhenCovered follows
    it): only a Debug build draws occluded windows, in an automation launch without CMUX_NEXT_BENCH_SHIPPING_DRAW=1."""
    if build_config != "debug" or env.get("CMUX_NEXT_BENCH_SHIPPING_DRAW") == "1":
        return False
    return env.get("CMUX_NEXT_NO_ACTIVATE") == "1" or env.get("CMUX_NEXT_SOCKET_MODE") == "automation"


SENTRY_THREAD_PREFIX = "SentryCrash"  # Sentry's Mach exception handler threads (crash-ends-app-gate.py PRIMARY)
SHIPPING_FIELDS = ("build_config", "sentry_started", "hang_reports", "draws_when_occluded", "activated")


def shipping_fields(build_config, env, thread_names, hangs, activation):
    """The five shipping-mode fields of a session: what ran, not only what the launch asked for."""
    return {
        "build_config": build_config,
        "sentry_started": any(name.startswith(SENTRY_THREAD_PREFIX) for name in thread_names),
        "hang_reports": {"dev_opt_in": env.get("CMUX_NEXT_DEV_HANG_REPORTS") == "1",
                         "watchdog": bool((hangs or {}).get("installed"))},
        "draws_when_occluded": draws_when_occluded(build_config, env),
        "activated": dict(activation),
    }


def build_sha_of(app_path):
    """The commit the app was built from (bench_launch.build_sha), None when the bundle names none."""
    from bench_launch import RecordError, build_sha
    try:
        return build_sha(app_path)
    except RecordError:
        return None


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


def main(argv=None):
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
                        help="exit 1 when a value is over its budget; exit 2 at once on a Debug build")
    parser.add_argument("--shipping-draw", choices=("on", "off"), default="on",
                        help="off: keep the automation draw of occluded windows (Debug), to compare with the shipping draw")
    parser.add_argument("--sample", type=float, default=10,
                        help="seconds of /usr/bin/sample of the app after the window, to name the threads that woke (0: none)")
    opts, _unknown = parser.parse_known_args(argv)
    build_config = bundle_build_config(opts.app)
    refusal = gate_refusal(build_config, opts.gate)
    if refusal:
        print(f"IDLE-BUDGET-REFUSED build_config={build_config}: {refusal}", flush=True)
        sys.exit(2)
    from bench_launch import BenchApp
    env = launch_env(shipping_draw=opts.shipping_draw == "on")
    budget = json.load(open(opts.budget))
    out = opts.out or os.path.join(os.getcwd(), "artifacts", "idle-budget")
    os.makedirs(out, exist_ok=True)
    machine = host_facts()
    print("IDLE-BUDGET-MACHINE " + json.dumps(machine), flush=True)
    report = {"machine": machine, "app": opts.app, "build_config": build_config, "shipping_draw": opts.shipping_draw,
              "settle_s": opts.settle, "measure_s": opts.measure, "sessions": {}}
    all_overs = []
    markdown = []
    for session in [s for s in opts.sessions.split(",") if s]:
        if session not in SESSIONS:
            raise SystemExit(f"idle-budget: unknown session {session} (one of {', '.join(SESSIONS)})")
        app = BenchApp(opts.app, out=os.path.join(out, session), env=env, config=SESSIONS[session].get("config"))
        try:
            entry = {"fresh_session": fresh_session(app)}
            app.launch()
            if session in ("stress", "stress-static"):
                entry["stress"] = build_stress(app, static=session == "stress-static")
            activation = app.activate()  # once, before the settle (and before a hide): users run an active app
            if not activation["activated"]:
                print(f"IDLE-BUDGET-NOT-ACTIVATED {session}: {activation['error']}", flush=True)
            if SESSIONS[session].get("hide"):
                entry["hide"] = app.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": True},
                                                       "focus": False, "origin": "script"}, timeout=30)
            if SESSIONS[session].get("minimize"):
                entry["minimize"] = app.rpc("action.run", {"action": "minimizeWindow", "focus": False,
                                                           "origin": "script"}, timeout=30)
            time.sleep(opts.settle)  # bench: the session settles (page loads, Chromium's post-load work) before the window
            instance = procs.Instance(app.app, app.process.pid)
            names = [name for _cpu, name in threads(app.process.pid).values()]
            entry.update(shipping_fields(build_config, app.launched_env or {}, names,
                                         read_rpc(app, "debug.hangs", {"limit": 0}), activation))
            print(f"IDLE-BUDGET-MODE {session} " + json.dumps({k: entry[k] for k in SHIPPING_FIELDS}), flush=True)
            window_before = window_state(app)
            result = measure(app, instance, opts.measure)
            result["window_state"] = {"start": window_before, "end": window_state(app)}
            print(f"IDLE-BUDGET-WINDOW {session} " + json.dumps(result["window_state"]), flush=True)
            if opts.sample:
                text = run_sample(app.process.pid, opts.sample, os.path.join(out, session, "sample-app.txt"))
                result["sample"] = threads_from_sample(text)
                result["main_callouts"] = main_callouts_from_sample(text)
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
            if SESSIONS[session].get("hidden_wake"):
                hidden = hidden_wake_sources(result)
                hidden.update({"sha": build_sha_of(opts.app), "host": machine["host"]})
                entry["hidden_wake"] = hidden
                for line in hidden_wake_lines(session, hidden, hidden["sha"], hidden["host"]):
                    print(line, flush=True)
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
