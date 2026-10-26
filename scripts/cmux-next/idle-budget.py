#!/usr/bin/env python3
"""Idle thread and wakeup budget of cmux NEXT (Lawrence's threading list, item 6; plans/cmux-next/idle-wakeups.md).

Idle means no input, no visible change, terminals quiet. At idle every cmux process should sleep: the
app's main thread 0 wakeups a second, the app <= 1/s, the cmux-tui daemon <= 1/s, the holder 0, and
each process's thread count capped. This script launches a tagged app (bench_launch.BenchApp), builds a
session, lets it settle, then measures one window with no input and reports, per process:

  threads, wakeups/s (interrupt wakeups, proc_pid_rusage: what Activity Monitor's Idle Wake Ups and
  Chrome's GetIdleWakeupsPerSecond count; the judged number), package-idle wakeups/s (a subset of them,
  GetPackageIdleWakeupsPerSecond), CPU energy and billed energy (mW: CPU energy plus what other processes
  such as WindowServer spent for this one, less what it spent for them), GPU ms/s (IORegistry), context
  switches/s, CPU %, and the threads that ran in the window (CPU time per thread,
  PROC_PIDTHREADID64INFO: the thread names show which loop woke);
  for the app also main_wakes/s (the main run loop's wakes from sleep, debug.hangs `main_wakes`) and,
  when the build has it, the wakeup ledger's owners (debug.wakeups: DemandTimer, FrameScheduler,
  Backoff by owner and reason).
The app's resource coalition (procs.coalition_of: energy, energy billed to it, GPU time and wakeups of
everything it started, processes gone in the window included) is `coalition` in the report: null when
it cannot be read.

The script reads the app's counters only at the window's two ends (proc_pid_rusage of another process
does not wake it; the two socket reads sit outside the process counters' window), so the bench adds no
wakeup to what it measures. Each end's state reads (debug.energy, pmset, the animated page) sit outside
every counter bracket: the start reads, a quiet gap, then the counters; the counters, then the end reads.

Sessions (--sessions):
  light         the launch window with its terminal (Home's pages run in Chromium by default)
  light-webkit  the same with browser.defaultEngine webkit: no Chromium at all
  light-hidden  the light session with the app hidden (Show/Hide All Windows hidden=true)
  minimized     the light session with its window minimized (minimizeWindow)
  light-hidden and minimized are hidden-wake sessions: they fail unless the app is hidden (no main window visible)
  or every main window is miniaturized at both ends of the window, and they name every main-thread wake source
  above 0.1/s in HIDDEN-WAKE lines (`hidden_wake_sources`): a DTrace count of the main thread's run-loop callouts
  (--wake-trace), the main run loop's repeating timer fires and the wakeup ledger, one list per basis, with the
  owners' frames from 3 x --sample `/usr/bin/sample` runs. A run whose shipping mode is not confirmed prints
  HIDDEN-WAKE-UNCONFIRMED instead.
  Each session starts from an empty saved session (`fresh_session`).
  stress-static  STRESS with its pages served without their rAF spinner (STRESS's own pages animate: not idle)
  stress   STRESS (scripts/cmux-next/perf-stress-session.py: 60 workspaces, a 12-pane grid of 6 tabs each,
           Chromium pages elsewhere); its 10 busy terminals are stopped (Ctrl-C) before the settle, so the
           terminals are quiet
  tabs-static   the launch pane with 5 WebKit and 10 Chromium tabs hidden behind 1 shown static Chromium tab,
                every page tab_pages' static page; the settle lasts past `browser.freezeHiddenTabs`
  minimized     the light session with its window minimized (action minimizeWindow)
  energy-saver  tabs-static with `energy.saver: always`, the shown tab an animated page (/anim, rAF every
                frame, no input) whose rAF count the page server reads at the window's two ends: the page keeps
                one fetch the server holds (no wake while held); the bench answers it and the page POSTs
                its count, page clock and visibilityState (any build, Release + CMUX_BENCH_HOOKS included)
  chrome-static the reference: a Chromium browser (--chrome-app) with tabs-static's 16 static pages as tabs in the
                same order, the last shown, and the uBlock Origin --app bundles (--chrome-ublock), launched as xbench
                launches Chrome (a template profile keyed on the browser build and uBlock Origin, its switches, CDP
                /json/new), every page loaded, settled as long as tabs-static; kinds browser, renderer, extension,
                gpu, utility, crashpad. The bundled uBlock Origin is Manifest V2: branded Google Chrome ignores
                --load-extension from 137 and Chromium runs no MV2 from 139, so --chrome-app must be a Chromium with
                the MV2 patch cmux's CEF carries (ungoogled-chromium of cmux's Chromium major: cmux's
                cmux_extensions_manifestv2.patch comes from it). A browser known not to run it (branded Chrome 137+,
                Chrome for Testing 139+) fails the session before it launches. The report gets a `chrome` block
                and `ratio_to_chrome` rows (the budget's, judged once with the other cross-session rows; a Chrome
                value under the field's noise floor counts as the floor, `:floor` on the field). A row whose two
                sessions did not both run uBlock Origin, or whose Chrome pages are not tabs-static's shape, is
                `unequal`: reported, not judged; --gate refuses a failed or unequal chrome-static run.

Per window the report also has, per session: `energy_mw` (CPU and billed energy, summed per kind and over the
tree), `assertions` (`pmset -g assertions` held by or created for a pid of the set), `saver` (asked by the
session, observed through debug.energy at both ends) and `thermal` (ProcessInfo.thermalState at both ends).
--gate refuses a session whose observed saver state is not the one it asked for, and energy-saver when its page's
rAF rate could not be read; a session whose thermal state reached serious or critical has `thermal_marked` on its
rows.

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

Budget: scripts/cmux-next/idle-budget.json, schema v2 (its _doc): per process kind with per-session overrides,
sums (app+daemon, tree), ratios to another session of the run and to chrome-static (judged once every session
is measured, whatever the --sessions order), xbench rows (--xbench), allowed_periodic (wakeup-audit.py) and
assertions_allowed_when. A missing or unknown value is reported, not judged (IDLE-BUDGET-NOT-JUDGED lines); a sum
with one unknown part is unknown; a v1 file (kinds only) still loads. Every session runs with both keep-awake
settings off. Over budget prints IDLE-BUDGET-OVER lines; the exit code is 0 unless --gate (no CI gate: the perf
cron runs it and reports).

Use (fleet only, a host with a GUI console session; never on a laptop in use):
  python3 scripts/cmux-next/idle-budget.py --app "<...>/cmux DEV <tag>.app" --out DIR \\
      [--sessions light,stress|all] [--settle 60] [--measure 60] [--json DIR/idle-budget.json] [--gate]
  D6 on an xbench.py result (any host): python3 scripts/cmux-next/idle-budget.py --xbench OUT/results.json [--gate]
  On the fleet through the allowlisted entry (STRESS needs the 1920 x 1080 virtual display):
    scripts/measure/split-spring.sh --suite=idle-budget --vdisplay=120 -- --sessions tabs-static,energy-saver

Output: one `IDLE-BUDGET-MACHINE {json}` line, one `IDLE-BUDGET-ROW {json}` line per session and process
kind, IDLE-BUDGET-ENERGY / -STATE / -ASSERTION / -ANIM / -CHROME lines, IDLE-BUDGET-REFUSED for a saver mismatch, an
unread rAF rate, a failed or unequal chrome-static or (exit 2) a Debug build under --gate, IDLE-BUDGET-THERMAL for a
marked session, IDLE-BUDGET-MODE with the shipping fields, for a hidden session `HIDDEN-WAKE {json}` per source and
one `HIDDEN-WAKE-TOTAL {json}` with sha and host, a Markdown table, and --json with every sample.
"""
import argparse, ctypes, fnmatch, glob, hashlib, json, os, platform, plistlib, re, shutil, subprocess, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(0, os.path.join(HERE, "..", "perf-bench"))
import procs  # noqa: E402  (process set of one app: descendants, bundle processes, responsible XPC processes)
import tab_pages  # noqa: E402  (the tab-page server and the Chromium process classifier)

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


def threads(pid):
    """{thread id: (cpu ns, name)} of `pid` now; {} when it is gone."""
    libproc = procs._darwin().libproc
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

# Chromium utility processes by service (content/browser/utility_process_host.cc names them by
# --utility-sub-type, the mojo interface the process serves).
UTILITY_KINDS = {"network.mojom.NetworkService": "cef-network", "storage.mojom.StorageService": "cef-storage",
                 "audio.mojom.AudioService": "cef-audio"}


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
    if "--type=crashpad-handler" in cmd or "chrome_crashpad_handler" in cmd:
        return "crashpad"
    chromium = tab_pages.chromium_kind(cmd)
    if chromium == "cef-utility":
        service = re.search(r"--utility-sub-type=(\S+)", cmd)
        return UTILITY_KINDS.get(service.group(1) if service else "", "cef-utility")
    if chromium:
        return chromium
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


# Seconds between the start's state reads and the first counter read.
QUIET_GAP_S = 1.0


def read_rpc(app, method, params=None):
    reply = app.rpc(method, params or {}, timeout=30)
    return reply if isinstance(reply, dict) and not reply.get("error") else {}


def window_end(app, pids, read_anim=None):
    """What one end of the window records outside the process counters: the app's energy policy (debug.energy:
    the saver state), the Mac's thermal state, the power assertions of the pid set and, with `read_anim`
    (IdlePages.read_anim), the animated page's rAF count."""
    saver, reason = saver_state(read_rpc(app, "debug.energy"))
    end = {"saver": saver, "saver_reason": reason, "thermal": procs.thermal_state(),
           "assertions": procs.power_assertions(pids)}
    if read_anim is not None:
        end["anim"] = read_anim()
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


def measure(app, instance, seconds, read_anim=None, ledger_limit=20):
    """Counters of every process of the app over `seconds` with no input (`ledger_limit` busiest ledger owners,
    None: all). The window's end reads (window_end) sit outside every counter bracket, the app's own counters
    included, so the bench's reads are never counted."""
    pids = process_set(instance)
    start = window_end(app, pids, read_anim)
    time.sleep(QUIET_GAP_S)  # bench: the start reads' aftermath (the page's POST, the RPC's reply) ends before the counters
    hangs0 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger0 = read_rpc(app, "debug.wakeups", {"run_loop": True})
    counters0 = app_counters(app)
    first = snapshot(pids)
    gpu0 = procs.gpu_ns_by_pid()
    coalition0 = procs.coalition_of(instance.pid)
    began = time.monotonic()
    time.sleep(seconds)  # bench: the idle window itself (nothing is sent to the app in it)
    elapsed = time.monotonic() - began
    coalition1 = procs.coalition_of(instance.pid)
    gpu1 = procs.gpu_ns_by_pid()
    last_pids = process_set(instance)
    last = snapshot(last_pids)
    hangs1 = read_rpc(app, "debug.hangs", {"limit": 0})
    ledger1 = read_rpc(app, "debug.wakeups", {"run_loop": True})
    counters1 = app_counters(app)
    end = window_end(app, last_pids, read_anim)
    rows = process_rows(first, last, elapsed, gpu0, gpu1, kind)
    result = {"seconds": round(elapsed, 1), "processes": rows, "ends": {"start": start, "end": end},
              "coalition": procs.coalition_rates(coalition0, coalition1, elapsed)}
    if "main_wakes" in hangs0 and "main_wakes" in hangs1:
        result["main_wakes_per_s"] = round((hangs1["main_wakes"] - hangs0["main_wakes"]) / elapsed, 3)
    owners = ledger_rates(ledger0, ledger1, elapsed, limit=ledger_limit)
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


def snapshot(commands):
    """{pid: (command, procs.Usage, task overhead, threads)} of `commands` ({pid: command}) now."""
    return {pid: (cmd, procs.usage(pid), procs.overhead(pid), threads(pid)) for pid, cmd in commands.items()}


def process_rows(first, last, elapsed, gpu0, gpu1, classify):
    """One row per process alive at the window's end, from two snapshots and two GPU reads `elapsed` seconds
    apart, its kind from `classify`; a process that started inside the window counts from its start (`partial`)."""
    rows = []
    for pid, (cmd, c1, o1, t1) in sorted(last.items()):
        if c1 is None or o1 is None:
            continue
        (_, c0, o0, t0) = first.get(pid, (cmd, None, None, {}))
        partial = c0 is None
        o0 = o0 or (0, 0, 0, 0, 0)
        ran = []
        for tid, (cpu, name) in t1.items():
            before = t0.get(tid, (0, name))[0] if not partial else 0
            if cpu > before:
                ran.append({"tid": tid, "name": name or "", "cpu_us": round((cpu - before) / 1000, 1)})
        ran.sort(key=lambda t: -t["cpu_us"])
        rows.append(process_row(pid, cmd, c0, c1, elapsed, gpu=procs.gpu_ms_per_s(gpu0, gpu1, pid, elapsed),
                                threads_now=o1[1], csw=procs._delta32(o1[4], o0[4]), ran=ran, classify=classify))
    return rows


def process_row(pid, cmd, first, last, elapsed, gpu, threads_now, csw, ran, classify=None):
    """One process's row of the window from two procs.Usage reads (`first` None: it started inside the
    window, `partial`); its kind from `classify` (default: the cmux kinds, `kind`)."""
    got = procs.rates(first, last, elapsed)
    return {
        "pid": pid, "kind": (classify or kind)(cmd), "command": cmd[:160], "partial": first is None,
        "threads": threads_now, "threads_ran": len(ran), "ran": ran[:8],
        "cpu_pct": round(got["cpu_pct"], 4),
        "wakeups_per_s": round(got["wakeups_per_s"], 3),
        "pkg_idle_wakeups_per_s": round(got["pkg_idle_wakeups_per_s"], 3),
        "energy_mw_cpu": round(got["energy_mw_cpu"], 3),
        "energy_mw_billed": round(got["energy_mw_billed"], 3),
        "gpu_ms_per_s": None if gpu is None else round(gpu, 3),
        "csw_per_s": round(csw / elapsed, 3),
        "footprint_mb": round(last.footprint / procs.MB, 1),
    }


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


BLOCKING_SYMBOLS = ("mach_msg", "__psynch_cvwait", "__workq_kernreturn", "kevent", "__semwait", "__select", "__ulock_wait")
WAIT_SYMBOLS = BLOCKING_SYMBOLS + ("start_wqthread", "thread_start", "_pthread_start")
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

# CFRunLoop's callout trampolines (CoreFoundation CFRunLoop.c), the frame below __CFRunLoopRun that says why the main
# thread is awake. A timer, a source, a main-queue drain or a block wakes the run loop; observers run on every wake
# one of those causes, so they are listed but never counted as a cause. Chromium's MessagePumpCFRunLoopBase
# (base/message_loop/message_pump_apple.mm) has the same split: a work source and a delayed-work timer wake it,
# observers only bracket the loop.
RUN_LOOP_CALLOUTS = {
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_TIMER_CALLBACK_FUNCTION__": "timer",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE0_PERFORM_FUNCTION__": "source0",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_SOURCE1_PERFORM_FUNCTION__": "source1",
    "__CFRUNLOOP_IS_SERVICING_THE_MAIN_DISPATCH_QUEUE__": "main-queue",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_A_BLOCK__": "block",
    "__CFRUNLOOP_IS_CALLING_OUT_TO_AN_OBSERVER_CALLBACK_FUNCTION__": "observer",
}
# The callback each callout calls, as a DTrace expression on its entry: its first argument (a timer, source or
# observer function), the block's invoke pointer (Block_layout.invoke, 16 bytes in), or none (the main queue drain
# takes a mach message).
CALLOUT_CALLBACK_ARG = {"timer": "arg0", "source0": "arg0", "source1": "arg0", "observer": "arg0",
                        "block": "*(uint64_t *)copyin(arg0 + 16, 8)", "main-queue": "0"}
WAKE_CAUSES = ("timer", "source0", "source1", "main-queue", "block")
# Where the OS's images live (the dyld shared cache's images have these paths too); every other image (the app
# binary, its frameworks, Sentry, Chromium Embedded Framework) is an owner.
OS_IMAGE_PREFIXES = ("/System/", "/usr/lib/", "/usr/libexec/", "/Library/Apple/")
# Only for an image the report gives no `Binary Images:` path for: the OS images most often on its paths.
FALLBACK_OS_IMAGES = {"CoreFoundation", "Foundation", "AppKit", "HIToolbox", "SkyLight", "QuartzCore", "CoreGraphics",
                      "CoreText", "CFNetwork", "IOKit", "Security", "Metal", "CoreVideo", "CoreDisplay", "ViewBridge",
                      "SwiftUI", "SwiftUICore", "AttributeGraph", "Combine", "Observation", "CoreServices", "Network",
                      "LaunchServices", "AE", "CarbonCore", "RunningBoardServices", "HIServices", "CoreUI", "dyld"}
# Trampolines: a frame in these images with no owner below it passes its samples down to the frame that does the
# work (a run-loop, dispatch, runtime or Swift job frame does none itself).
TRAMPOLINE_IMAGES = {"CoreFoundation", "Foundation", "libdispatch.dylib", "libobjc.A.dylib", "libswift_Concurrency.dylib"}
SWIFT_THUNKS = ("thunk for ", "reabstraction thunk", "partial apply for ", "@objc ", "merged ")
BINARY_IMAGE_RE = re.compile(r"^\s*0x[0-9a-fA-F]+\s+-\s+\S+\s+.*?<[0-9A-Fa-f-]+>\s+(/.+?)\s*$")
ATOS_RE = re.compile(r"(.+?) \(in ([^)]+)\)")


def binary_images(text):
    """{image name: path} from a `/usr/bin/sample` report's `Binary Images:` part (the call graph's `(in NAME)` is
    the image file's name)."""
    images = {}
    for line in text.split("Binary Images:", 1)[1].splitlines() if "Binary Images:" in text else []:
        match = BINARY_IMAGE_RE.match(line)
        if match:
            images.setdefault(os.path.basename(match.group(1)), match.group(1))
    return images


def is_system_image(image, images=None):
    """An OS image (by its path in the report), whose frames do not name an owner."""
    path = (images or {}).get(image)
    if path:
        return path.startswith(OS_IMAGE_PREFIXES)
    return image in FALLBACK_OS_IMAGES or (image.startswith("lib") and image.endswith(".dylib"))


def is_wait(node):
    return any(wait in node["symbol"] for wait in BLOCKING_SYMBOLS)


def names_no_owner(node):
    """True for a frame that can not name an owner: an OS image, or a Swift thunk with a frame below it."""
    return node["system"] or (node["symbol"].startswith(SWIFT_THUNKS) and bool(node["children"]))


def main_thread_tree(text):
    """The main thread's call tree in a `/usr/bin/sample` report, nested {symbol, image, system, count, children}
    (the thread on com.apple.main-thread, else the first thread); None when the report has no thread."""
    images = binary_images(text)
    order = []
    stack = []
    for line in call_graph(text).splitlines():
        head = THREAD_HEAD_RE.match(line)
        if head:
            thread = {"symbol": head.group(2).strip(" :") or "thread", "image": "", "system": True,
                      "count": int(head.group(1)), "children": []}
            order.append(thread)
            stack = [(-1, thread)]
            continue
        frame = FRAME_RE.match(line)
        if not stack or not frame:
            continue
        depth = frame.start(1)
        node = {"symbol": frame.group(2), "image": frame.group(3), "system": is_system_image(frame.group(3), images),
                "count": int(frame.group(1)), "children": []}
        while len(stack) > 1 and stack[-1][0] >= depth:
            stack.pop()
        stack[-1][1]["children"].append(node)
        stack.append((depth, node))
    main = [thread for thread in order if "com.apple.main-thread" in thread["symbol"]]
    return (main or order or [None])[0]


def owner_name(node):
    return f"{node['symbol'][:120]} ({node['image']})"


def busy(node):
    """Samples of `node` that ran: its count less the samples blocked in a wait below it (a nested run loop, a
    condition wait), which are not wake time."""
    def waited(n):
        return n["count"] if is_wait(n) else sum(waited(child) for child in n["children"])
    return node["count"] - waited(node)


def attribute(node, label, add):
    """Gives each sample below a callout to its owner: the first frame in an owner image takes all of its running
    samples; a sample with no owner frame goes to the first non-trampoline frame on its own path (`label`), so two OS
    handlers under one callout stay two owners. Wait frames take nothing."""
    if is_wait(node):
        return
    if not names_no_owner(node):
        add(owner_name(node), busy(node))
        return
    if label is None and node["image"] not in TRAMPOLINE_IMAGES:
        label = owner_name(node)
    own = node["count"] - sum(child["count"] for child in node["children"])
    if own > 0:
        add(label or owner_name(node), own)
    for child in node["children"]:
        attribute(child, label, add)


def callout_owners(tree):
    """{(kind, callback, owner): samples} of the main thread's outermost run-loop callouts. `callback` is the frame
    the callout calls, the key the DTrace count has too (None for the main queue drain, which has no callback)."""
    out = {}

    def adder(kind, callback):
        def add(owner, count):
            if count > 0:
                out[(kind, callback, owner)] = out.get((kind, callback, owner), 0) + count
        return add

    pending = [tree] if tree else []
    while pending:
        node = pending.pop()
        kind = RUN_LOOP_CALLOUTS.get(node["symbol"])
        if not kind:
            pending.extend(node["children"])
            continue
        for child in node["children"]:
            attribute(child, None, adder(kind, None if kind == "main-queue" else owner_name(child)))
        adder(kind, None)(owner_name(node), node["count"] - sum(child["count"] for child in node["children"]))
    return out


def main_callouts_from_samples(texts):
    """[{kind, callback, owner, samples}] of the main thread's run-loop callouts, summed over `/usr/bin/sample`
    reports, most first."""
    total = {}
    for text in texts:
        for key, count in callout_owners(main_thread_tree(text)).items():
            total[key] = total.get(key, 0) + count
    rows = [{"kind": kind, "callback": callback, "owner": owner, "samples": count}
            for (kind, callback, owner), count in total.items()]
    return sorted(rows, key=lambda r: (-r["samples"], r["kind"], r["owner"]))


def wake_trace_script(main_tid, seconds):
    """A DTrace script that counts the main thread's run-loop callouts by kind and callback address for `seconds`
    (each entry is one callout run; one wake runs one or more). Addresses lose their pointer-auth bits."""
    lines = ["#pragma D option quiet"]
    for function, kind in RUN_LOOP_CALLOUTS.items():
        lines.append(f"pid$target:CoreFoundation:{function}:entry /tid == {int(main_tid)}/ "
                     f"{{ @c[\"{kind}\", ({CALLOUT_CALLBACK_ARG[kind]}) & 0x7fffffffffff] = count(); }}")
    lines.append(f"tick-{max(1, int(seconds))}s {{ exit(0); }}")
    lines.append('END { printa("%s %x %@d\\n", @c); }')
    return "\n".join(lines) + "\n"


TRACE_LINE_RE = re.compile(r"^\s*([a-z0-9-]+) ([0-9a-f]+) (\d+)\s*$")


def parse_wake_trace(output):
    """{(kind, address): count} from the trace's printa lines."""
    counts = {}
    for line in output.splitlines():
        match = TRACE_LINE_RE.match(line)
        if match and match.group(1) in RUN_LOOP_CALLOUTS.values():
            key = (match.group(1), int(match.group(2), 16))
            counts[key] = counts.get(key, 0) + int(match.group(3))
    return counts


def callout_rates(counts, symbols, seconds, images=None):
    """[{kind, callback, callback_system, count, per_s}] from the trace counts; `symbols` maps a callback address to
    atos's `symbol (in image)` line."""
    rows = {}
    for (kind, address), count in counts.items():
        callback, system = None, True
        if address:
            match = ATOS_RE.match(symbols.get(address, ""))
            callback = f"{match.group(1)[:120]} ({match.group(2)})" if match else f"0x{address:x}"
            system = is_system_image(match.group(2), images) if match else False
        row = rows.setdefault((kind, callback), {"kind": kind, "callback": callback, "callback_system": system, "count": 0})
        row["count"] += count
    out = list(rows.values())
    for row in out:
        row["per_s"] = round(row["count"] / seconds, 3) if seconds > 0 else None
    return sorted(out, key=lambda r: (-r["count"], r["kind"], r["callback"] or ""))


def dtrace_command():
    """dtrace, through `sudo -n` unless this is root (DTrace's pid provider needs root)."""
    return ["/usr/sbin/dtrace"] if os.geteuid() == 0 else ["sudo", "-n", "/usr/sbin/dtrace"]


def symbolize(pid, addresses):
    """{address: atos line} for the callback addresses in process `pid`."""
    addresses = sorted(a for a in addresses if a)
    if not addresses:
        return {}
    try:
        run = subprocess.run(["/usr/bin/atos", "-p", str(pid), *(f"0x{a:x}" for a in addresses)],
                             capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return {}
    return dict(zip(addresses, run.stdout.splitlines()))


def count_main_callouts(app, seconds, folder, images=None):
    """Counts the main thread's run-loop callouts for `seconds` after the window (DTrace pid provider), with the
    main thread's wakes over the same span (debug.hangs `main_wakes`). {ok, error, seconds, main_wakes_per_s,
    callouts}; ok False with the reason when DTrace can not run (no root, SIP, a restricted process)."""
    pid = app.process.pid
    ids = threads(pid)
    if not ids:
        return {"ok": False, "error": "the app has no threads", "seconds": seconds, "callouts": []}
    script = os.path.join(folder, "wake-trace.d")
    with open(script, "w") as handle:
        handle.write(wake_trace_script(min(ids), seconds))  # the main thread is the first: its id is the lowest
    hangs0 = read_rpc(app, "debug.hangs", {"limit": 0})
    began = time.monotonic()
    try:
        run = subprocess.run([*dtrace_command(), "-p", str(pid), "-s", script], capture_output=True, text=True,
                             timeout=seconds + 120)
    except (OSError, subprocess.TimeoutExpired) as error:
        return {"ok": False, "error": f"dtrace: {error}"[:300], "seconds": seconds, "callouts": []}
    elapsed = time.monotonic() - began
    hangs1 = read_rpc(app, "debug.hangs", {"limit": 0})
    if run.returncode != 0:
        return {"ok": False, "error": f"dtrace exit {run.returncode}: {run.stderr.strip()[-300:]}", "seconds": seconds,
                "callouts": []}
    counts = parse_wake_trace(run.stdout)
    result = {"ok": True, "error": "", "seconds": round(elapsed, 1),
              "callouts": callout_rates(counts, symbolize(pid, {a for _k, a in counts}), elapsed, images)}
    if "main_wakes" in hangs0 and "main_wakes" in hangs1 and elapsed > 0:
        result["main_wakes_per_s"] = round((hangs1["main_wakes"] - hangs0["main_wakes"]) / elapsed, 3)
    return result


TIMER_ENTRY_RE = re.compile(r"<CFRunLoopTimer (0x[0-9a-fA-F]+)[^>]*>\{valid = (\w+), firing = \w+, interval = "
                            r"([0-9.e+-]+),[^}]*?next fire date = ([0-9.e+-]+)[^}]*?callout = (.*?)"
                            r"(?:, context = ([^}]*))?\}")
# Callouts every timer of a kind shares: they name Foundation, not the timer's owner (NSTimer and Swift's Timer).
GENERIC_TIMER_CALLOUTS = ("__NSFireTimer",)


def repeating_timers(description):
    """{timer address: {interval_s, next_fire, callout, context}} of the valid repeating timers of a main run loop
    description (a timer in several modes appears once)."""
    found = {}
    for address, valid, interval, fire, callout, context in TIMER_ENTRY_RE.findall(description or ""):
        if valid == "Yes" and float(interval) > 0:
            found[address] = {"interval_s": float(interval), "next_fire": float(fire), "callout": callout.strip()[:160],
                              "context": (context or "").strip()[:160]}
    return found


def timer_owner(address, timer):
    """(owner, named): the timer's callout, or for a callout every timer shares (__NSFireTimer) the timer itself,
    marked unnamed (the callout count's sample owners name it)."""
    if timer["callout"].startswith(GENERIC_TIMER_CALLOUTS):
        return f"unnamed NSTimer {address} (context {timer['context'] or '?'})", False
    return timer["callout"], True


def timer_fires(before, after, elapsed):
    """Fires per second of each repeating main run-loop timer between two `CFCopyDescription`s of the main run loop
    (debug.wakeups `run_loop`), by timer address: its next fire date advances one interval per fire. A timer at
    only one end, or whose interval changed, is a row with per_s None and its `unpaired` reason. A fire the run
    loop skipped (App Nap) counts as a fire, so the rate is an upper bound."""
    first, last = repeating_timers(before), repeating_timers(after)
    out = []
    for address in sorted(set(first) | set(last)):
        old, new = first.get(address), last.get(address)
        timer = new or old
        owner, named = timer_owner(address, timer)
        row = {"timer": address, "owner": owner, "named": named, "callout": timer["callout"],
               "context": timer["context"], "interval_s": timer["interval_s"], "per_s": None}
        if old is None or new is None or old["interval_s"] != new["interval_s"]:
            row["unpaired"] = ("created in the window" if old is None else "gone at the end" if new is None
                               else "interval changed")
            out.append(row)
            continue
        fired = max(0, round((new["next_fire"] - old["next_fire"]) / new["interval_s"]))
        if fired and elapsed > 0:
            row["per_s"] = round(fired / elapsed, 3)
            out.append(row)
    return sorted(out, key=lambda t: (-(t["per_s"] or 0), t["owner"]))


HIDDEN_WAKE_FLOOR = 0.1  # per second: every main wake source above it is named


def counted_sources(trace, causes, floor):
    """The `callout-count` sources: each traced main-thread callout kind and callback above `floor` per second. The
    owner is the callback when it is in an owner image, else the top sample owner under the same callout and
    callback (`owner_from`)."""
    by_key = {}
    for row in causes:
        by_key.setdefault((row["kind"], row["callback"]), []).append(row)
    out = []
    for row in trace.get("callouts") or []:
        if row["kind"] not in WAKE_CAUSES or row["per_s"] is None or row["per_s"] <= floor:
            continue
        owners = sorted(by_key.get((row["kind"], row["callback"]), []), key=lambda r: -r["samples"])
        key_samples = sum(o["samples"] for o in owners)
        if row["callback"] and not row["callback_system"]:
            owner, owner_from = row["callback"], "callback"
        elif owners:
            owner, owner_from = owners[0]["owner"], "sample"
        else:
            owner, owner_from = f"unnamed {row['kind']} callout ({row['callback'] or 'main queue drain'})", "none"
        out.append({"basis": "callout-count", "kind": row["kind"], "owner": owner, "owner_from": owner_from,
                    "per_s": row["per_s"], "callback": row["callback"],
                    "top": owners[0]["owner"] if owners else row["callback"],
                    "sample_owners": [{"owner": o["owner"], "share": round(o["samples"] / key_samples, 3)}
                                      for o in owners[:3]]})
    return sorted(out, key=lambda s: -s["per_s"])


def hidden_wake_sources(result, floor=HIDDEN_WAKE_FLOOR):
    """The main thread's wake sources of a hidden session, one list per basis. A source can be in more than one
    basis, so the bases are never summed and `sources_by_basis` counts each apart:

    - `callout-count`: the DTrace count of each run-loop callout on the main thread (`wake_trace`), per second
      (`counted_sources`).
    - `unattributed`: the main wakes per second the counted callouts do not cover (without a trace, the window's
      main wakes less the run-loop timer fires).
    - `run-loop-timer`: each repeating main run-loop timer's fires, by timer; unpaired timers with per_s None.
    - `ledger`: wakeup ledger owners (DemandTimer, FrameScheduler, Backoff) on any thread (`thread: any`).
    - `frames` (sample-time): the `/usr/bin/sample` owners' share of the main thread's callout time. Samples measure
      time, not wakes, so per_s is None and no floor applies: they name frames, they do not rank sources.

    Observers are not causes and come back apart."""
    main_wakes = result.get("main_wakes_per_s")
    trace = result.get("wake_trace") or {"ok": False, "error": "not run", "callouts": []}
    callouts = result.get("main_callouts") or []
    causes = [c for c in callouts if c["kind"] in WAKE_CAUSES]
    total = sum(c["samples"] for c in causes)
    timers = [t for t in result.get("main_run_loop_timer_fires") or [] if t.get("unpaired") or (t["per_s"] or 0) > floor]
    if trace.get("ok"):
        base = trace.get("main_wakes_per_s")
        covered = sum(r["per_s"] for r in trace["callouts"] if r["kind"] in WAKE_CAUSES and r["per_s"] is not None)
    else:
        base = main_wakes
        covered = sum(t["per_s"] for t in timers if t["per_s"])
    unattributed = round(max(0.0, base - covered), 3) if isinstance(base, (int, float)) else None
    sources = counted_sources(trace, causes, floor)
    if unattributed is not None and unattributed > floor:
        sources.append({"basis": "unattributed", "kind": "unattributed", "owner": "unattributed", "per_s": unattributed,
                        "top": None, "of": "trace main wakes" if trace.get("ok") else "window main wakes"})
    for timer in timers:
        sources.append({"basis": "run-loop-timer", "kind": "timer", "top": timer["callout"],
                        **{k: v for k, v in timer.items() if k != "next_fire"}})
    ledger = [{"basis": "ledger", "kind": "ledger", "owner": f"{e['owner']}:{e['reason']}", "per_s": e["per_s"],
               "thread": "any", "top": None}
              for e in (result.get("ledger") or {}).get("owners") or [] if e["per_s"] > floor]
    sources += sorted(ledger, key=lambda s: -s["per_s"])
    frames = [{"basis": "sample-time", "kind": c["kind"], "owner": c["owner"], "callback": c["callback"],
               "samples": c["samples"], "share": round(c["samples"] / total, 4), "per_s": None} for c in causes]
    observers = ([{"basis": "callout-count", **r} for r in trace.get("callouts") or [] if r["kind"] == "observer"]
                 + [{"basis": "sample-time", **c} for c in callouts if c["kind"] == "observer"])
    by_basis = {}
    for source in sources:
        by_basis[source["basis"]] = by_basis.get(source["basis"], 0) + 1
    return {"main_wakes_per_s": main_wakes, "trace_main_wakes_per_s": trace.get("main_wakes_per_s"),
            "trace": {k: trace.get(k) for k in ("ok", "error", "seconds")}, "cause_samples": total,
            "unattributed_per_s": unattributed, "sources": sources, "sources_by_basis": by_basis, "frames": frames,
            "observers": observers[:20]}


def hidden_wake_lines(session, report, build_sha, host, problems=()):
    """The `HIDDEN-WAKE {json}` lines of one hidden session for the Q9 slots (one per source and basis), the
    `HIDDEN-WAKE-FRAME` sample-time lines and observers, then one `HIDDEN-WAKE-TOTAL {json}` line with the build sha
    and host. When `problems` says the run was not the shipping app in the session's state, the source lines are
    `HIDDEN-WAKE-UNCONFIRMED` instead, so no Q9 task comes from them."""
    prefix = "HIDDEN-WAKE-UNCONFIRMED" if problems else "HIDDEN-WAKE"
    lines = [f"{prefix} " + json.dumps({"session": session, **source}) for source in report["sources"]]
    lines += ["HIDDEN-WAKE-FRAME " + json.dumps({"session": session, **frame}) for frame in report["frames"]]
    lines += ["HIDDEN-WAKE-OBSERVER " + json.dumps({"session": session, **o}) for o in report["observers"]]
    lines.append("HIDDEN-WAKE-TOTAL " + json.dumps({
        "session": session, "sha": build_sha, "host": host, "main_wakes_per_s": report["main_wakes_per_s"],
        "trace_main_wakes_per_s": report["trace_main_wakes_per_s"], "trace": report["trace"],
        "unattributed_per_s": report["unattributed_per_s"], "sources_by_basis": report["sources_by_basis"],
        "samples_taken": report.get("samples_taken", 0), "cause_samples": report["cause_samples"],
        "confirmed": not problems, "problems": list(problems), "floor_per_s": HIDDEN_WAKE_FLOOR}))
    return lines


class HiddenStateError(RuntimeError):
    """A hidden-wake session's app was not hidden or minimized as the session asked: its wakes are not hidden wakes."""


def hidden_state_problem(spec, state):
    """None when `window_state` shows the session's state (light-hidden: no main window visible; minimized: every
    main window miniaturized), else why not."""
    if not isinstance(state, dict) or "error" in state:
        return f"debug.window_list failed: {(state or {}).get('error')}"
    main = state.get("main") or []
    if not main:
        return "debug.window_list shows no main window"
    if spec.get("hide") and any(w.get("visible") for w in main):
        return "a main window is visible: the app is not hidden"
    if spec.get("minimize") and not all(w.get("miniaturized") for w in main):
        return "a main window is not miniaturized"
    return None


def shipping_problems(entry):
    """Why the session's applied mode (p14-energy-100's fields) is not the shipping app's; [] when it is."""
    problems = []
    activated = entry.get("activated") or {}
    if not activated.get("activated"):
        problems.append(f"not activated: {activated.get('error') or '?'}")
    if entry.get("draws_when_occluded") is not False:
        problems.append("draws when occluded (the automation draw, not the shipping one)")
    if not entry.get("sentry_started"):
        problems.append("Sentry did not start")
    if not (entry.get("hang_reports") or {}).get("watchdog"):
        problems.append("the main-thread watchdog is not installed")
    return problems


def check_action_reply(name, reply):
    """Raises HiddenStateError when an `action.run` reply is an error."""
    if not isinstance(reply, dict) or reply.get("error"):
        raise HiddenStateError(f"action.run {name} failed: {str(reply)[:200]}")


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


def ledger_rates(before, after, elapsed, limit=20):
    """Wakeup ledger owners that fired in the window (debug.wakeups, when the build has it), the `limit` busiest
    (None: all)."""
    if not before.get("ledger") and not after.get("ledger"):
        return None
    counts = {(e["owner"], e["reason"]): e.get("count", 0) for e in before.get("ledger") or []}
    out = []
    for entry in after.get("ledger") or []:
        delta = entry.get("count", 0) - counts.get((entry["owner"], entry["reason"]), 0)
        if delta > 0:
            out.append({"owner": entry["owner"], "reason": entry["reason"], "per_s": round(delta / elapsed, 3)})
    out.sort(key=lambda e: -e["per_s"])
    return {"owners": out[:limit], "active_frame_clients": after.get("active_frame_clients", [])}


# ---------------------------------------------------------------------------------------------------------
# Budget


# Summed per kind (field: digits). A None in any process of the kind (GPU time with no IORegistry read)
# makes the kind's sum None: an unknown is never a 0.
SUMMED = {"wakeups_per_s": 3, "pkg_idle_wakeups_per_s": 3, "energy_mw_cpu": 3, "energy_mw_billed": 3,
          "gpu_ms_per_s": 3, "csw_per_s": 3, "cpu_pct": 4}
# Recorded only by some runs (task 003 records disk and log): a kind whose rows have none has no value, so
# all_kinds judges nothing that was not measured; a kind where some rows have it and others not is None (unknown).
SUMMED_WHEN_PRESENT = {"disk_bytes_per_s": 3, "log_lines": 0}


def aggregate(result):
    """Per kind: count, threads (sum and max per process), interrupt wakeups/s (sum and max per process, and the
    max over the processes of hidden pages), package-idle wakeups/s, CPU and billed energy (mW), GPU ms/s, context
    switches/s, CPU %, disk and log sums when the rows have them; the roles."""
    kinds = {}
    for row in result["processes"]:
        entry = kinds.setdefault(row["kind"], {"n": 0, "threads": 0, "threads_max": 0, "wakeups_max": 0.0,
                                               "threads_ran": 0, **{field: 0.0 for field in SUMMED}})
        entry["n"] += 1
        entry["threads"] += row["threads"]
        entry["threads_max"] = max(entry["threads_max"], row["threads"])
        entry["wakeups_max"] = max(entry["wakeups_max"], row["wakeups_per_s"])
        if row.get("hidden"):
            entry["hidden_wakeups_max"] = max(entry.get("hidden_wakeups_max", 0.0), row["wakeups_per_s"])
        for field, digits in SUMMED.items():
            value = row.get(field, 0.0)
            entry[field] = None if entry[field] is None or value is None else round(entry[field] + value, digits)
        entry["threads_ran"] += row["threads_ran"]
        if row.get("role"):
            entry["roles"] = sorted(set(entry.get("roles", [])) | {row["role"]})
    for name, entry in kinds.items():
        rows = [row for row in result["processes"] if row["kind"] == name]
        for field, digits in SUMMED_WHEN_PRESENT.items():
            values = [row.get(field) for row in rows]
            if all(isinstance(v, (int, float)) for v in values):
                entry[field] = round(sum(values), digits)
            elif any(isinstance(v, (int, float)) for v in values):
                entry[field] = None  # some processes reported it, others did not: unknown, not their sum
    if "main_wakes_per_s" in result and "app" in kinds:
        kinds["app"]["main_wakes_per_s"] = result["main_wakes_per_s"]
    return kinds


def energy_summary(kinds):
    """{"per_kind": {kind: {cpu, billed}}, "tree": {cpu, billed}} in mW: the CPU energy and the billed energy
    (aggregate's energy_mw_cpu and energy_mw_billed) of each kind and of the whole process set."""
    per_kind = {name: {"cpu": entry["energy_mw_cpu"], "billed": entry["energy_mw_billed"]}
                for name, entry in kinds.items()}
    tree = {field: round(sum(e[field] for e in per_kind.values()), 3) for field in ("cpu", "billed")}
    return {"per_kind": per_kind, "tree": tree}


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


def window_assertions(start, end):
    """The power assertions of the window's two reads, one entry per assertion (owning pid and assertion ID; its
    age differs between the reads) in first-seen order, each the latest read of it."""
    by_id = {}
    for item in (start or []) + (end or []):
        by_id[(item["pid"], item["id"])] = item
    return list(by_id.values())


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
    entry = {"result": result, "kinds": kinds, "energy_mw": energy_summary(kinds),
             "assertions": window_assertions(start.get("assertions"), end.get("assertions")),
             "saver": {"asked": spec.get("saver", False), "observed": observed,
                       "reason": end.get("saver_reason") or start.get("saver_reason"),
                       "mismatch": saver_mismatch(spec.get("saver", False), observed)},
             "thermal": {"start": start.get("thermal"), "end": end.get("thermal"), "worst": thermal, "marked": marked}}
    if spec.get("anim"):
        entry["anim"] = anim_rate(start.get("anim"), end.get("anim"))
    entry["over"] = [list(o) for o in over_budget(session, kinds, budget, window_facts(entry))]
    entry["not_judged"] = sum_notes(session, kinds, budget)
    return entry


def window_facts(entry):
    """over_budget's `facts` of one summarized window: the animated page's rAF rate, the saver state and reason
    both ends agree on (none when an end did not report one) and the power assertions held by the pid set."""
    facts = {"assertions": entry["assertions"]}
    observed = entry["saver"]["observed"]
    if observed and isinstance(observed[0], bool) and all(state == observed[0] for state in observed):
        facts["saver"] = observed[0]
        if entry["saver"]["reason"] is not None:
            facts["saver_reason"] = entry["saver"]["reason"]
    rate = (entry.get("anim") or {}).get("raf_per_s")
    if isinstance(rate, (int, float)):
        facts["page_raf_per_s"] = rate
    return facts


def refusals(entry):
    """[(what, why)] that refuse a session's window under --gate: its saver state is not the one it asked for, or
    its animated page's rAF rate (D7's number) could not be read."""
    out = []
    if entry["saver"]["mismatch"]:
        out.append(("saver", entry["saver"]["mismatch"]))
    if "error" in (entry.get("anim") or {}):
        out.append(("anim", f"no page rAF rate: {entry['anim']['error']}"))
    return out


def exit_code(gate, overs, refused):
    """1 under --gate when a value is over its budget or a session was refused (`refusals`), else 0."""
    return 1 if gate and (overs or refused) else 0


def session_budget(budget, session):
    return (budget.get("sessions") or {}).get(session) or {}


def busy_kind(own, name):
    """Whether kind `name` takes only the session's own values: every kind of a reference session (Chrome) or of a
    session with `busy: true` (an agent at work), else a kind that matches one of the session's `busy` patterns
    (STRESS's animating pages: `cef-*`)."""
    busy = own.get("busy")
    if own.get("reference") or busy is True:
        return True
    return any(fnmatch.fnmatchcase(name, pattern) for pattern in busy or [])


def limit_for(budget, session, name, field):
    """The limit of `field` for kind `name` in `session`: the session's own value (an explicit null there means
    not judged), else the kind's default (one number or {session: number}), else all_kinds. A busy kind
    (busy_kind) takes only the session's own values."""
    own = session_budget(budget, session)
    kind_limits = (own.get("kinds") or {}).get(name) or {}
    if field in kind_limits:
        return kind_limits[field]
    if busy_kind(own, name):
        return None
    defaults = (budget.get("kinds") or {}).get(name) or {}
    if field in defaults:
        limit = defaults[field]
        return limit.get(session) if isinstance(limit, dict) else limit
    return (budget.get("all_kinds") or {}).get(field)


def limited_fields(budget, session, name):
    own = session_budget(budget, session)
    fields = set((own.get("kinds") or {}).get(name) or {})
    if not busy_kind(own, name):
        fields |= set((budget.get("kinds") or {}).get(name) or {}) | set(budget.get("all_kinds") or {})
    return sorted(f for f in fields if not f.startswith("_"))


def selected(kinds, selector):
    """The kinds of `selector` that ran ('tree': every kind; 'app+daemon': those of app and daemon that ran)."""
    return list(kinds) if selector == "tree" else [n for n in selector.split("+") if n in kinds]


def selector_value(kinds, selector, field):
    """`field` summed over the selected kinds that ran; None when none ran, or when one of them has the field None
    or lacks it: an unknown is never a 0, so a partial sum is not a value."""
    values = [(kinds[n] or {}).get(field) for n in selected(kinds, selector)]
    if not values or not all(isinstance(v, (int, float)) for v in values):
        return None
    return round(sum(values), 4)


def unknown_sum(kinds, selector, field):
    """Whether `selector` ran but its sum of `field` is unknown."""
    return bool(selected(kinds, selector)) and selector_value(kinds, selector, field) is None


def setting_on(value):
    return value not in (None, False, "off", "never", 0, "")


def over_budget(session, kinds, budget, facts=None):
    """[(subject, field, value, limit)] for every value of one session over its budget (or a role or expected state
    that differs). `facts`: the session's measurements outside the kinds (page_raf_per_s, saver, saver_reason,
    `assertions` held by cmux pids, the effective `settings`). cross_overs judges the rows that compare sessions."""
    facts = facts or {}
    own = session_budget(budget, session)
    out = []
    for name in sorted(kinds):
        entry = kinds[name]
        for field in limited_fields(budget, session, name):
            limit = limit_for(budget, session, name, field)
            if limit is None:
                continue
            if field == "role":
                roles = entry.get("roles") or []
                if roles and roles != [limit]:
                    out.append((name, "role", ",".join(roles), limit))
                continue
            value = entry.get(field)
            if isinstance(value, (int, float)) and value > limit:
                out.append((name, field, value, limit))
    for selector, limits in (own.get("sums") or {}).items():
        for field, limit in limits.items():
            value = selector_value(kinds, selector, field)
            if limit is not None and value is not None and value > limit:
                out.append((selector, field, value, limit))
    for field, limit in (own.get("limits") or {}).items():
        value = facts.get(field)
        if limit is not None and isinstance(value, (int, float)) and value > limit:
            out.append(("session", field, value, limit))
    for field, expected in (own.get("expect") or {}).items():
        if field in facts and facts[field] != expected:
            out.append(("session", field, facts[field], expected))
    return out + assertion_overs(own, budget, facts)


def assertion_overs(own, budget, facts):
    """D11: in an idle session every pmset assertion held by a cmux pid is an over, unless the session itself turns
    on one of `assertions_allowed_when` in its `settings`. Every other session runs with them off (KEEP_AWAKE_OFF;
    their shipping default pluggedIn holds an assertion while an agent works or a phone serves), and an effective
    value in `facts.settings` other than the session's is an over too. Busy sessions (a working agent holds
    keep-awake) and reference sessions are not judged."""
    if own.get("reference") or own.get("busy") is True:
        return []
    keys = budget.get("assertions_allowed_when") or []
    asked, effective = own.get("settings") or {}, facts.get("settings") or {}
    out = [("session", key, effective[key], asked.get(key, "off")) for key in keys
           if key in effective and setting_on(effective[key]) != setting_on(asked.get(key))]
    held = facts.get("assertions") or []
    if held and not any(setting_on(asked.get(key)) for key in keys):
        out.append(("assertions", "held", len(held), 0))
    return out


def cross_overs(budget, measured, unequal=None):
    """The rows that compare sessions of one run, judged once after every session is measured, so the order of
    --sessions does not matter: each session's `relative` rows and the ratio_to_chrome rows (chrome_rows: the
    one judgement of those). `measured`: {session: kinds}; `unequal`: {session: [reason]} why chrome-static is no
    fair reference for that session (chrome_unequal). Returns ([(session, over)], [note]); a note names each row
    not judged and why."""
    overs, notes = [], []

    def judge(session, of, field, vs, to, max_ratio, suffix):
        kinds, reference = measured[session], measured.get(to)
        label = f"{session} {of} {field}{suffix}"
        if reference is None:
            notes.append(f"{label}: not judged: reference session {to} not measured")
            return
        for selector, rows in ((of, kinds), (vs, reference)):
            if unknown_sum(rows, selector, field):
                notes.append(f"{label}: not judged: {selector} {field} unknown")
                return
        overs.extend((session, over) for over in ratio_over(of, field, kinds, vs, reference, max_ratio, suffix))

    for session in measured:
        for rule in session_budget(budget, session).get("relative") or []:
            judge(session, rule["of"], rule["field"], rule["of"], rule["to"], rule["max_ratio"], f"/{rule['to']}")
    for row in chrome_rows(budget, measured, unequal):
        if row["verdict"] == "over":
            overs.append((row["session"], tuple(row["over"])))
        elif row["verdict"] != "ok":
            notes.append(row["note"])
    return overs, notes


def chrome_rows(budget, measured, unequal=None):
    """One row per ratio_to_chrome rule whose session was measured, against chrome-static: cmux and Chrome values,
    the ratio, the noise floor it used, and a verdict: ok, over (`over`: the over tuple), or `not judged` with the
    reason in `note`: chrome-static not measured, a side unknown or not run, Chrome's value 0 with no floor, or
    `unequal` (the reasons, also in `unequal`). cross_overs takes its overs and notes from here, the report its rows."""
    reference = measured.get(CHROME_SESSION)
    rows = []
    for rule in budget.get("ratio_to_chrome") or []:
        session, of, vs, field = rule["session"], rule["of"], rule["vs"], rule["field"]
        if session not in measured or session == CHROME_SESSION:
            continue
        kinds, suffix = measured[session], f"/chrome:{vs}"
        row = {"session": session, "of": of, "vs": vs, "field": field, "max_ratio": rule["max_ratio"],
               "cmux_value": selector_value(kinds, of, field),
               "chrome_value": None if reference is None else selector_value(reference, vs, field),
               "floor": None, "ratio": None, "verdict": "ok"}
        why = None
        if reference is None:
            why = f"reference session {CHROME_SESSION} not measured"
        else:
            for selector, values, side in ((of, kinds, "cmux"), (vs, reference, "Chrome")):
                if unknown_sum(values, selector, field):
                    why = f"{selector} {field} unknown"
                    break
                if not selected(values, selector):
                    why = f"{side} ran no {selector}"
                    break
        if why is None and (unequal or {}).get(session):
            row["unequal"] = list(unequal[session])
            why = "unequal: " + "; ".join(row["unequal"])
        if why is None:
            floor = RATIO_FLOORS.get(field)
            row["ratio"], row["floor"] = ratio_of(row["cmux_value"], row["chrome_value"], floor)
            over = ratio_over(of, field, kinds, vs, reference, rule["max_ratio"], suffix, floor)
            if row["ratio"] is None:
                why = f"Chrome's {vs} {field} is 0 and the field has no noise floor"
            elif over:
                row["verdict"], row["over"] = "over", list(over[0])
        if why is not None:
            row["verdict"], row["note"] = "not judged", f"{session} {of} {field}{suffix}: not judged: {why}"
        rows.append(row)
    return rows


def sum_notes(session, kinds, budget):
    """The session's sum rows not judged because a selected kind's value is unknown."""
    return [f"{session} {selector} {field}: not judged: unknown"
            for selector, limits in (session_budget(budget, session).get("sums") or {}).items()
            for field, limit in limits.items() if limit is not None and unknown_sum(kinds, selector, field)]


def xbench_overs(budget, result):
    """D6 on an xbench.py result (results.json: rows.<row>.<browser>.median). An `xbench` row with `max_ratio`
    compares the browser's median with `vs` (default chrome); one with `max` is absolute. Returns ([over], [note])."""
    rows = (result or {}).get("rows") or {}
    overs, notes = [], []
    for rule in budget.get("xbench") or []:
        per = rows.get(rule["row"]) or {}
        value = (per.get(rule["browser"]) or {}).get("median")
        label = f"xbench {rule['browser']} {rule['row']}"
        if not isinstance(value, (int, float)):
            notes.append(f"{label}: not judged: not measured")
        elif "max" in rule:
            if value > rule["max"]:
                overs.append((rule["browser"], rule["row"], value, rule["max"]))
        else:
            vs = rule.get("vs", "chrome")
            base = (per.get(vs) or {}).get("median")
            if not isinstance(base, (int, float)) or not base:
                notes.append(f"{label}: not judged: {vs} not measured")
            elif round(value / base, 3) > rule["max_ratio"]:
                overs.append((rule["browser"], f"{rule['row']}/{vs}", round(value / base, 3), rule["max_ratio"]))
    return overs, notes


# The noise floors a Chrome reference value is raised to (the cron rows' floors, CRON_FLOORS and CRON_SUM_FLOORS):
# Chrome's GPU process at 0 wakeups against cmux's at 1 in a minute is idle noise, not an infinite ratio, while
# cmux at 3/s against it is 6 times the floor.
RATIO_FLOORS = {"wakeups_per_s": 0.5, "wakeups_max": 0.5, "hidden_wakeups_max": 0.5, "main_wakes_per_s": 0.5,
                "energy_mw_billed": 1.0, "energy_mw_cpu": 1.0, "gpu_ms_per_s": 1.0, "threads": 2, "threads_max": 2}


def ratio_of(value, base, floor=None):
    """(value / reference, the floor used or None). A reference below `floor` counts as the floor; a reference of
    0 with no floor, or a side not measured, gives (None, None): no ratio."""
    if value is None or base is None:
        return None, None
    used = floor if floor and base < floor else None
    base = used or base
    return (round(value / base, 3), used) if base else (None, None)


def ratio_over(of, field, kinds, vs, reference, max_ratio, suffix, floor=None):
    """[(of, field + suffix, ratio, max)] when `of` in `kinds` over `vs` in `reference` is above `max_ratio`; a
    reference of 0 or one that was not measured judges nothing. With `floor`, a reference below it counts as the
    floor and the field says so (`:floor`), so the printed ratio is the one compared."""
    ratio, used = ratio_of(selector_value(kinds, of, field), selector_value(reference, vs, field), floor)
    if ratio is None or ratio <= max_ratio:
        return []
    return [(of, field + suffix + (":floor" if used else ""), ratio, max_ratio)]


def over_line(session, over):
    name, field, value, limit = over
    relation = ">" if isinstance(limit, (int, float)) and not isinstance(limit, bool) else "!="
    return f"IDLE-BUDGET-OVER {session} {name} {field} {value} {relation} {limit}"


def load_budget(path):
    """The budget file; a v1 file (kinds only) is read as v2 with no session overrides."""
    with open(path) as handle:
        budget = json.load(handle)
    budget.setdefault("version", 1)
    for key in ("kinds", "sessions", "all_kinds"):
        budget.setdefault(key, {})
    for key in ("ratio_to_chrome", "xbench", "allowed_periodic", "assertions_allowed_when"):
        budget.setdefault(key, [])
    return budget


# Noise floors of the cron rows: one wakeup a second, two threads (a pool thread parks or exits late).
CRON_FLOORS = {"wakeups_per_s": 0.5, "wakeups_max": 0.5, "main_wakes_per_s": 0.5, "threads_max": 2, "threads": 2,
               "energy_mw_billed": 1.0, "gpu_ms_per_s": 1.0}
CRON_UNITS = {"threads_max": "threads", "threads": "threads", "energy_mw_billed": "mW", "energy_mw_cpu": "mW",
              "gpu_ms_per_s": "ms/s"}
# The sums every session reports, plus the ones its budget names.
CRON_SUMS = ("app+daemon", "tree")
CRON_SUM_FLOORS = {"wakeups_per_s": 0.5, "energy_mw_billed": 1.0, "energy_mw_cpu": 1.0}


def cron_rows(report, budget=None):
    """{row: {p50, p95, unit, budget, floor}} for the perf cron (scripts/cmux-next/perf-cron.py) from one
    idle-budget report: `idle_budget.<session>.<kind>.<field>` and the sums `idle_budget.<session>.<selector>.<field>`,
    one value per run (p50 = p95)."""
    budget = budget if budget is not None else load_budget(BUDGET_FILE)
    out = {}
    for session, entry in ((report or {}).get("sessions") or {}).items():
        kinds = entry.get("kinds") or {}
        for name, values in kinds.items():
            for field, floor in CRON_FLOORS.items():
                value = values.get(field)
                if not isinstance(value, (int, float)):
                    continue
                unit = CRON_UNITS.get(field, "/s")
                out[f"idle_budget.{session}.{name}.{field}"] = {"p50": value, "p95": value, "unit": unit,
                                                                 "budget": limit_for(budget, session, name, field),
                                                                 "floor": floor}
        sums = session_budget(budget, session).get("sums") or {}
        for selector in dict.fromkeys([*CRON_SUMS, *sums]):
            for field, floor in CRON_SUM_FLOORS.items():
                value = selector_value(kinds, selector, field)
                if value is None:
                    continue
                out[f"idle_budget.{session}.{selector}.{field}"] = {
                    "p50": value, "p95": value, "unit": CRON_UNITS.get(field, "/s"),
                    "budget": (sums.get(selector) or {}).get(field), "floor": floor}
    return out


# ---------------------------------------------------------------------------------------------------------
# The Chrome reference (chrome-static): a Chromium with the tabs-static pages and the uBlock Origin cmux bundles

CHROME_SESSION = "chrome-static"
CHROME_APP = "/Applications/Chromium.app"  # where ungoogled-chromium installs (the comment above BRANDED_CHROME_IDS)
UBLOCK_ID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"  # fetch-ublock.sh keeps the Web Store key, so the id is stable
UBLOCK_IN_APP = "Contents/Resources/Extensions/ublock-origin"  # bundle-ublock.sh
# Google Chrome's kinds from tab_pages' --type classifier (the switches cmux's helpers carry too). Chrome's
# helpers are not in a cmux Helper app, so chromium_kind does not apply; any other --type is `other`.
CHROME_KINDS = {"cef-renderer": "renderer", "cef-extension": "extension", "cef-gpu": "gpu", "cef-utility": "utility",
                "cef-helper": "other"}
# Builds that cannot run the bundled uBlock Origin (Manifest V2, loaded with --load-extension): branded Google
# Chrome ignores --load-extension from 137 and has no switch back from 142 (Chromium 04f6233ce5be: the
# GOOGLE_CHROME_BRANDING check in extensions' command-line loader); Chromium runs no MV2 extension from 139, and
# Chrome for Testing carries no patch for it. cmux's CEF runs MV2 through cmux_extensions_manifestv2.patch, from
# ungoogled-chromium (plans/cmux-next/browser.md), so ungoogled-chromium of cmux's Chromium major is the reference.
# A plain Chromium has the same bundle id as ungoogled-chromium, so only the run tells them apart: uBlock Origin
# does not start, the rows are unequal and --gate refuses.
BRANDED_CHROME_IDS = ("com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary")
CHROME_FOR_TESTING_ID = "com.google.chrome.for.testing"
LOAD_EXTENSION_GONE_MAJOR = 137
MANIFEST_V2_GONE_MAJOR = 139


def chrome_kind(cmd):
    """The kind of a Chrome process: browser, renderer, extension, gpu, utility, crashpad, other (Chromium's
    process types, content/public/common/content_switches.cc; an extension's renderer carries
    --extension-process, extensions/common/switches.cc; Crashpad's handler runs with no --type)."""
    typed = tab_pages.process_type_kind(cmd)
    if typed:
        return CHROME_KINDS[typed]
    exe = cmd.split(" --", 1)[0].strip()
    if os.path.basename(exe) == "chrome_crashpad_handler":
        return "crashpad"
    if exe.count(".app/") == 1 and "/Contents/MacOS/" in exe:
        return "browser"
    return "other:" + os.path.basename(exe)[:32]


def read_manifest(folder):
    """The manifest.json of an unpacked extension folder, or None when it has no readable one."""
    try:
        with open(os.path.join(folder, "manifest.json")) as handle:
            manifest = json.load(handle)
    except (OSError, ValueError):
        return None
    return manifest if isinstance(manifest, dict) else None


def manifest_version(folder):
    """The `version` of an unpacked extension folder, or None when it has no readable manifest."""
    return (read_manifest(folder) or {}).get("version")


def major_version(version):
    head = str(version or "").split(".", 1)[0]
    return int(head) if head.isdigit() else None


def reference_refusal(bundle_id, version, manifest):
    """Why the browser `bundle_id` at `version` cannot run the extension of `manifest` loaded with
    --load-extension, or None when it may (whether it did is checked when it runs)."""
    major = major_version(version)
    if major is None:
        return None
    if bundle_id in BRANDED_CHROME_IDS and major >= LOAD_EXTENSION_GONE_MAJOR:
        return f"branded Google Chrome {version} ignores --load-extension (Chrome {LOAD_EXTENSION_GONE_MAJOR}+)"
    if manifest.get("manifest_version") == 2 and bundle_id == CHROME_FOR_TESTING_ID and major >= MANIFEST_V2_GONE_MAJOR:
        return (f"Chrome for Testing {version} runs no Manifest V2 extension (Chromium {MANIFEST_V2_GONE_MAJOR}+); "
                f"uBlock Origin {manifest.get('version')} is MV2")
    return None


def ublock_parity(cmux_version, cmux_running, chrome_version, chrome_running):
    """Whether both sides ran the same uBlock Origin: `*_version` the copy each side has (None: none), `*_running`
    whether it ran in the measured session (chrome_unequal's rule). Without it one side does less work, so the
    reference is unequal and its ratio rows are reported, not judged."""
    unequal = []
    if cmux_version is None:
        unequal.append("the cmux app bundles no uBlock Origin")
    elif not cmux_running:
        unequal.append(f"uBlock Origin {cmux_version} did not run in the cmux session (no cef-extension process)")
    if chrome_version is None:
        unequal.append("no uBlock Origin was loaded into Chrome")
    elif not chrome_running:
        unequal.append(f"uBlock Origin {chrome_version} did not run in Chrome (no extension target or process)")
    if cmux_version and chrome_version and cmux_version != chrome_version:
        unequal.append(f"uBlock Origin {chrome_version} in Chrome, {cmux_version} in cmux")
    return {"id": UBLOCK_ID, "cmux_version": cmux_version, "chrome_version": chrome_version,
            "cmux_running": bool(cmux_running), "chrome_running": bool(chrome_running), "equal": not unequal,
            "unequal": unequal}


def kind_ran(kinds, name):
    return bool((kinds.get(name) or {}).get("n"))


def chrome_unequal(kinds, chrome):
    """(parity, reasons) of chrome-static (its block `chrome`, with its `kinds`) as the reference of a cmux session
    measured as `kinds`. The same rule on both sides: uBlock Origin ran when an extension renderer was measured in
    the window (cmux: cef-extension; Chrome: extension, and DevTools listed uBlock Origin's own target, as Chrome
    may run component extensions). The reasons add chrome's own shape reasons (chrome_shape_unequal)."""
    ublock = chrome.get("ublock") or {}
    parity = ublock_parity(ublock.get("cmux_version"), kind_ran(kinds, "cef-extension"), ublock.get("chrome_version"),
                           bool(ublock.get("running")) and kind_ran(chrome.get("kinds") or {}, "extension"))
    return parity, list(chrome.get("unequal") or []) + parity["unequal"]


def chrome_shape_unequal(page_targets, visibility, keys):
    """Why Chrome's pages at the window's end are not tabs-static's shape: one page target per key of `keys` (the
    tab_plan's loaded keys in opening order, the last one shown), the last visible and every other hidden
    (`visibility`: the static pages' last document.visibilityState reports)."""
    reasons = []
    if page_targets != len(keys):
        reasons.append(f"Chrome had {page_targets} page targets, tabs-static has {len(keys)}")
    want = {key: "visible" if index == len(keys) - 1 else "hidden" for index, key in enumerate(keys)}
    wrong = [f"{key}={visibility.get(key)}" for key in want if visibility.get(key) != want[key]]
    if wrong:
        reasons.append(f"Chrome's tab visibility is not 1 shown, {len(keys) - 1} hidden: " + ", ".join(wrong))
    return reasons


def template_key(bundle, version, ublock, ublock_version):
    """The template profile's key: a profile built by another browser build or with another uBlock Origin (or
    none) is another template."""
    text = json.dumps([os.path.realpath(bundle), version, ublock and os.path.realpath(ublock), ublock_version])
    return hashlib.sha256(text.encode()).hexdigest()[:12]


def chrome_refusals(asked, entry, rows):
    """Why --gate cannot pass on the Chrome ratios: chrome-static was asked (`asked`) and failed (`entry`), or a
    ratio row of a measured session is unequal. A reference that can never judge must not pass in silence."""
    if not asked:
        return []
    if not entry or entry.get("exit") or not entry.get("kinds"):
        return [f"{CHROME_SESSION} not measured: {(entry or {}).get('error', 'no result')}"[:400]]
    return list(dict.fromkeys(f"{row['session']}: {reason}" for row in rows for reason in row.get("unequal") or []))


def judge_across(report, budget, chrome_asked=False):
    """After every session ran: the cross-session rows (cross_overs) with each session's chrome-static parity,
    so the --sessions order does not matter. Puts `not_judged`, and with chrome-static measured the `chrome` block
    (with each session's uBlock Origin parity) and the `ratio_to_chrome` rows into `report`, each over into its
    session's `over`. Returns (overs [(session, over)], notes, refused: chrome_refusals)."""
    sessions = report["sessions"]
    measured = {name: done["kinds"] for name, done in sessions.items() if done.get("kinds")}
    chrome = chrome_reference(report)
    unequal = {}
    if chrome:
        chrome["parity"] = {}
        for name, kinds in measured.items():
            if name != CHROME_SESSION:
                chrome["parity"][name], unequal[name] = chrome_unequal(kinds, chrome)
        report["chrome"] = chrome
    overs, notes = cross_overs(budget, measured, unequal)
    rows = chrome_rows(budget, measured, unequal)
    if chrome:
        report["ratio_to_chrome"] = rows
    for name, over in overs:
        sessions[name].setdefault("over", []).append(list(over))
    report["not_judged"] = notes
    return overs, notes, chrome_refusals(chrome_asked, sessions.get(CHROME_SESSION), rows)


def ratio_table(rows):
    lines = ["\n### ratio to Chrome (chrome-static)\n",
             "| session | cmux | Chrome | field | cmux value | Chrome value | floor | ratio | max | verdict |",
             "|---|---|---|---|---|---|---|---|---|---|"]
    for row in rows:
        verdict = ("**over**" if row["verdict"] == "over" else
                   row["note"].split(": not judged: ", 1)[-1] if row["verdict"] != "ok" else "ok")
        lines.append(f"| {row['session']} | {row['of']} | {row['vs']} | {row['field']} | {row['cmux_value']} | "
                     f"{row['chrome_value']} | {row['floor'] or '-'} | {row['ratio']} | {row['max_ratio']} | {verdict} |")
    return "\n".join(lines)


# ---------------------------------------------------------------------------------------------------------
# Sessions


def load_stress():
    import importlib.util
    spec = importlib.util.spec_from_file_location("perf_stress_session", STRESS_FILE)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The animated page of energy-saver: one box turned on every rAF, the count in window.__rafCount. It reports
# /loaded/anim as the shared static page reports /loaded/<n>, then keeps one GET of ANIM_READ_PATH open: the
# server holds it until the bench reads (IdlePages.read_anim), and the page then POSTs
# ANIM_COUNT_PATH/<count>/<performance.now()>/<visibilityState> and asks again. A held request runs no timer in the
# page, so the read path costs no wake inside the window and needs no DevTools port (Release builds have none).
ANIM_PATH = "/anim"
ANIM_READ_PATH = "/anim-read"
ANIM_COUNT_PATH = "/anim-count"
ANIM_PAGE = ("<!doctype html><meta charset='utf-8'><title>idle anim</title>"
             "<style>body{margin:0;background:#f4f4f6}#b{width:64px;height:64px;margin:40px;border-radius:12px;"
             "background:#20304a}</style><div id='b'></div><script>window.__rafCount=0;"
             "const b=document.getElementById('b');requestAnimationFrame(function f(){window.__rafCount++;"
             "b.style.transform='rotate('+(window.__rafCount*3%360)+'deg)';requestAnimationFrame(f)});"
             f"function ask(){{fetch('{ANIM_READ_PATH}',{{cache:'no-store'}}).then(function(){{"
             f"return fetch('{ANIM_COUNT_PATH}/'+window.__rafCount+'/'+performance.now()+'/'+document.visibilityState,"
             "{method:'POST'})}).then(ask,function(){setTimeout(ask,1000)})}"
             "fetch('/loaded/anim',{method:'POST'}).then(ask)</script>")


def parse_anim_count(path):
    """{count, t_ms, visibility} from the page's ANIM_COUNT_PATH POST, or {"error": ...}."""
    parts = path.split("?", 1)[0].removeprefix(ANIM_COUNT_PATH + "/").split("/")
    try:
        return {"count": int(parts[0]), "t_ms": float(parts[1]), "visibility": parts[2]}
    except (IndexError, ValueError):
        return {"error": f"unreadable rAF count post {path[:80]}"}


class IdlePages(tab_pages.TabPages):
    """The shared tab-page server plus energy-saver's animated page at ANIM_PATH and its read path."""

    def __init__(self, *args, **kwargs):
        self._anim = threading.Condition()
        self._anim_asked = 0  # reads the bench asked for (read_anim)
        self._anim_answered = 0  # reads a held ANIM_READ_PATH GET answered; a GET is held while this equals asked
        self._anim_reads = []  # the page's parsed ANIM_COUNT_PATH posts, in order
        super().__init__(*args, **kwargs)

    def body(self, path):
        path = path.split("?", 1)[0]
        if path == ANIM_PATH:
            return ANIM_PAGE.encode()
        if path == ANIM_READ_PATH:
            with self._anim:
                self._anim.wait_for(lambda: self._anim_asked > self._anim_answered or self.closing.is_set())
                self._anim_answered = self._anim_asked
            return b""
        return super().body(path)

    def report(self, path):
        if path.startswith(ANIM_COUNT_PATH + "/"):
            with self._anim:
                self._anim_reads.append(parse_anim_count(path))
                self._anim.notify_all()
            return
        super().report(path)

    def read_anim(self, seconds=10):
        """The animated page's {count, t_ms, visibility} now: answers the page's held read and waits for the count
        it posts (a read asked before the page's next GET arrives is answered by that GET); {"error": ...} when none
        comes in `seconds`."""
        with self._anim:
            posted = len(self._anim_reads)
            self._anim_asked += 1
            self._anim.notify_all()
            if not self._anim.wait_for(lambda: len(self._anim_reads) > posted, seconds):
                return {"error": f"the page posted no rAF count in {seconds:g} s (no held {ANIM_READ_PATH})"}
            return self._anim_reads[posted]

    def close(self):
        """Ends the held reads with the other held loads."""
        super().close()
        with self._anim:
            self._anim.notify_all()

    def wait_loaded(self, key, seconds):
        """True once the page `key` reported /loaded/<key>, False after `seconds`."""
        deadline = time.monotonic() + seconds
        while key not in self.loaded:
            if time.monotonic() > deadline:
                return False
            time.sleep(0.2)  # bench: bounded wait for the tab's page to load
        return True


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


def tab_plan(pages, tabs):
    """[(engine, url, loaded key)] of a session's tabs in opening order: the hidden WebKit tabs, the hidden Chromium
    tabs, then the shown Chromium tab (`tabs["shown"]`: "static" or "anim")."""
    plan = ([("webkit", pages.url("static", f"w{n}"), f"w{n}") for n in range(tabs["webkit_hidden"])]
            + [("chromium", pages.url("static", f"c{n}"), f"c{n}") for n in range(tabs["chromium_hidden"])])
    if tabs["shown"] == "anim":
        return plan + [("chromium", pages.origin + ANIM_PATH, "anim")]
    return plan + [("chromium", pages.url("static", "shown"), "shown")]


def build_tabs(app, pages, tabs):
    """Opens the session's tabs (tab_plan) in the launch pane; a new tab is selected, so every earlier one is hidden
    behind the last. Waits for each page to load. Returns {engine: count} of the opened tabs."""
    opened = {}
    for engine, url, key in tab_plan(pages, tabs):
        run_action(app, f"openBrowser.{engine}", {"url": url}, focus=True, timeout=90)
        if not pages.wait_loaded(key, 90):
            raise SessionShapeError(f"{engine} tab {url} did not load in 90 s")
        opened[engine] = opened.get(engine, 0) + 1
    return opened


def anim_rate(start, end):
    """{raf_per_s, visibility} of the animated page between two IdlePages.read_anim results (the page's own clock),
    or the first error."""
    for read in (start, end):
        if not isinstance(read, dict) or "error" in read or not isinstance(read.get("count"), (int, float)):
            return {"error": (read or {}).get("error", "no rAF count") if isinstance(read, dict) else "not read"}
    seconds = (end["t_ms"] - start["t_ms"]) / 1000
    if seconds <= 0:
        return {"error": "the page clock did not advance"}
    return {"raf_per_s": round((end["count"] - start["count"]) / seconds, 2), "seconds": round(seconds, 1),
            "visibility": [start.get("visibility"), end.get("visibility")]}


def build_stress(app, static=False):
    """STRESS, then its busy terminals stopped (Ctrl-C), so the terminals are quiet. With `static` its pages
    have no rAF spinner (STRESS's own pages animate, which is not idle)."""
    stress_module = load_stress()
    stress = stress_module.Stress(app.rpc)
    if static:
        stress.pages = tab_pages.TabPages(default_kind="grid")
    summary = stress.build()
    for tab in getattr(stress, "busy", []):
        stress.send(tab, "\x03")
    summary["busy_terminals_stopped"] = len(getattr(stress, "busy", []))
    print("STRESS-SESSION " + json.dumps(summary), flush=True)
    return summary


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
    """The commit the app was built from (bench_launch.build_sha); raises bench_launch.RecordError when neither the
    bundle nor CMUX_CI_SHA names one (a hidden-wake report without its sha can not be cited)."""
    from bench_launch import build_sha
    return build_sha(app_path)


# Both keep-awake settings off (D11): their shipping default is pluggedIn, and a session that asks for keep-awake
# names them in its budget `settings`.
KEEP_AWAKE_OFF = {"sessions": {"keepAwake": "off"}, "phone": {"keepAwake": "off"}}
BASE_CONFIG = {"appearance": {"backgroundOpacity": 1}, **KEEP_AWAKE_OFF}  # BenchApp's default, keep-awake off
# Hidden Chromium tabs freeze this long after they hide (BrowserHibernationSetting's default, set explicitly so the
# settle below is known to outlast it); the tab sessions settle at least FREEZE_GRACE_S past it.
FREEZE_HIDDEN_TABS_S = 30
FREEZE_GRACE_S = 15
TABS_CONFIG = {"browser": {"freezeHiddenTabs": FREEZE_HIDDEN_TABS_S}}
TABS_STATIC = {"webkit_hidden": 5, "chromium_hidden": 10, "shown": "static"}
# The sessions (the docstring describes each). Keys: config (adds to BASE_CONFIG: session_config), hide, minimize,
# stress, static (STRESS without its rAF spinner), tabs (build_tabs's plan), settle_min (seconds), saver (the energy
# saver state the session asks for; --gate refuses a window that shows another), anim (read the animated page's rAF
# count at both ends), hidden_wake (print HIDDEN-WAKE lines: hidden_wake_sources).
SESSIONS = {
    "light": {},
    "light-webkit": {"config": {"browser": {"defaultEngine": "webkit"}}},
    "light-hidden": {"hide": True, "hidden_wake": True},
    "minimized": {"minimize": True, "hidden_wake": True},
    "stress": {"stress": True},
    "stress-static": {"stress": True, "static": True},
    "tabs-static": {"config": TABS_CONFIG, "tabs": TABS_STATIC, "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S},
    "energy-saver": {"config": {**TABS_CONFIG, "energy": {"saver": "always"}}, "tabs": {**TABS_STATIC, "shown": "anim"},
                     "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S, "saver": True, "anim": True},
    # The reference (run_chrome_static): tabs-static's pages in a Chromium, settled as long as tabs-static.
    CHROME_SESSION: {"chrome": True, "settle_min": FREEZE_HIDDEN_TABS_S + FREEZE_GRACE_S},
}


def session_config(session):
    """The cmux-next.json of `session`: BASE_CONFIG with the session's own keys on top."""
    return {**BASE_CONFIG, **(SESSIONS[session].get("config") or {})}


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


def wait_for(check, seconds, what):
    """Waits until `check()` is true; RuntimeError naming `what` after `seconds`."""
    deadline = time.monotonic() + seconds
    while not check():
        if time.monotonic() > deadline:
            raise RuntimeError(f"{CHROME_SESSION}: {what} after {seconds:g} s")
        time.sleep(0.2)  # bench: bounded wait for the reference browser


def build_template(browser, template, settle):
    """The template profile at `template`: built in a sibling folder and renamed into place only after the
    browser ran `settle` seconds (uBlock Origin compiles its filter lists into it), so an interrupted build
    leaves no half-built template behind."""
    if os.path.isdir(template):
        return False
    building = f"{template}.building-{os.getpid()}"
    shutil.rmtree(building, ignore_errors=True)
    os.makedirs(building)
    try:
        browser.launch(building, None)
        try:
            browser.ready()
            time.sleep(settle)  # bench: uBlock Origin compiles its lists into the template profile
        finally:
            browser.quit()
        os.replace(building, template)
    finally:
        shutil.rmtree(building, ignore_errors=True)
    return True


def run_chrome_static(opts, out):
    """The chrome-static entry: the --chrome-app browser through xbench's launcher (an APFS clone of a template
    profile keyed on the browser build and uBlock Origin, --user-data-dir, xbench's switches, tabs over CDP
    /json/new) with tabs-static's tab_plan pages from the shared page server in its order, every page loaded, the
    last shown, and the uBlock Origin the cmux app bundles; settled and measured as the cmux sessions are, its processes
    classified by chrome_kind. Raises before launch when the browser cannot run that uBlock Origin."""
    import xbench  # scripts/perf-bench (on sys.path): the Chrome launcher the cross-browser bench uses
    bundle = os.path.abspath(opts.chrome_app)
    if not os.path.isdir(bundle):
        raise RuntimeError(f"{CHROME_SESSION}: no {bundle}")
    if procs.main_pid(bundle):
        raise RuntimeError(f"{CHROME_SESSION}: {bundle} is already running; its processes would be measured too")
    with open(os.path.join(bundle, "Contents/Info.plist"), "rb") as handle:
        info = plistlib.load(handle)
    bundle_id, version = info.get("CFBundleIdentifier"), xbench.bundle_version(bundle)
    cmux_ublock = os.path.join(os.path.realpath(opts.app), UBLOCK_IN_APP)
    ublock = None if opts.chrome_ublock == "none" else opts.chrome_ublock or cmux_ublock
    manifest = read_manifest(ublock) if ublock else None
    if manifest:
        refusal = reference_refusal(bundle_id, version, manifest)
        if refusal:
            raise RuntimeError(f"{CHROME_SESSION}: {refusal}; pass --chrome-app a Chromium that runs MV2 "
                               "(ungoogled-chromium of cmux's Chromium major)")
    chrome_version = (manifest or {}).get("version")
    work = os.path.join(out, CHROME_SESSION)
    helper = xbench.Helper(opts.chrome_helper_cache)
    pages = IdlePages()
    browser = xbench.ChromiumBrowser("chrome", bundle, helper, None, extensions=[ublock] if manifest else [])
    profile = os.path.join(work, "run")
    try:
        template = os.path.join(work, "template-" + template_key(bundle, version, ublock if manifest else None,
                                                                 chrome_version))
        built = build_template(browser, template, opts.chrome_template_settle)
        xbench.clone(template, profile)
        browser.launch(profile, None)
        browser.ready()
        # DevTools answers before the startup browser opens its first tab (the handler starts in
        # PreMainMessageLoopRun, StartupBrowserCreator opens the window after it): wait for that tab, then every
        # page that is not one of tabs-static's closes, as xbench's adopt_first does.
        wait_for(lambda: browser.pages(), 30, "no startup page target")
        # tabs-static's own plan and pages, in its order; each new tab is selected, so the last one is shown.
        plan = tab_plan(pages, TABS_STATIC)
        urls = [url for _engine, url, _key in plan]
        for _engine, url, key in plan:
            browser.new_tab(url, key)
            if not pages.wait_loaded(key, 90):
                raise SessionShapeError(f"{CHROME_SESSION}: tab {url} did not load in 90 s")
        for target in browser.pages():
            if target.get("url") not in urls:
                browser.close(target["id"])
        browser.activate(browser.tabs[-1])
        settle = settle_seconds(CHROME_SESSION, opts.settle)
        time.sleep(settle)  # bench: the pages settle and hidden tabs pass Chrome's background throttling
        first = snapshot(browser.instance.pids())
        gpu0 = procs.gpu_ns_by_pid()
        began = time.monotonic()
        time.sleep(opts.measure)  # bench: the idle window itself (nothing is sent to Chrome in it)
        elapsed = time.monotonic() - began
        gpu1 = procs.gpu_ns_by_pid()
        last = snapshot(browser.instance.pids())
        targets = browser.extension_targets()
        page_targets = len(browser.pages())
        result = {"seconds": round(elapsed, 1), "processes": process_rows(first, last, elapsed, gpu0, gpu1, chrome_kind)}
        visibility = dict(pages.visibility)
        running = any(t.get("url", "").startswith(f"chrome-extension://{UBLOCK_ID}/") for t in targets)
        chrome = {"app": bundle, "bundle_id": bundle_id, "version": version, "build": info.get("CFBundleVersion"),
                  "switches": browser.switches(), "settle_s": settle, "template_built": built,
                  "pages": {"tabs": len(urls), "page_targets": page_targets, "shown": 1, "set": "tabs-static",
                            "loaded": len(pages.loaded), "visibility": visibility},
                  "ublock": {"cmux_version": manifest_version(cmux_ublock), "chrome_version": chrome_version,
                             "running": running},
                  "unequal": chrome_shape_unequal(page_targets, visibility, [key for _engine, _url, key in plan]),
                  "extension_targets": [target.get("url", "")[:120] for target in targets]}
        return {"chrome": chrome, "result": result}
    finally:
        browser.quit()
        pages.close()
        shutil.rmtree(profile, ignore_errors=True)  # the keyed template stays for a rerun into `out`


def chrome_static_entry(opts, out, session, markdown):
    """Runs chrome-static and prints its rows; a failure is recorded as a cmux session's failure is."""
    try:
        entry = run_chrome_static(opts, out)
        entry["kinds"] = aggregate(entry["result"])
        entry["over"] = []
        entry["exit"] = 0
        for name, values in entry["kinds"].items():
            print("IDLE-BUDGET-ROW " + json.dumps({"session": session, "kind": name, **values}), flush=True)
        print("IDLE-BUDGET-CHROME " + json.dumps({k: v for k, v in entry["chrome"].items() if k != "switches"}), flush=True)
        markdown.append(table(session, entry["kinds"], []))
    except Exception as error:  # noqa: BLE001 - as a cmux session's failure: recorded, the others still run
        entry = {"exit": 1, "error": f"{type(error).__name__}: {error}"[:500]}
        print(f"IDLE-BUDGET-SESSION-FAILED {session} exit=1 {entry['error'][:300]}", flush=True)
        markdown.append(f"\n### {session}\n\nnot measured: {entry['error'][:300]}")
    return entry


def chrome_reference(report):
    """The chrome-static block with its kinds, or None when it was not measured."""
    entry = report["sessions"].get(CHROME_SESSION) or {}
    return {**entry["chrome"], "kinds": entry["kinds"]} if entry.get("kinds") and entry.get("chrome") else None


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
        saver, thermal, energy = entry["saver"], entry["thermal"], entry["energy_mw"]["tree"]
        lines.append(f"energy {energy['cpu']} mW CPU, {energy['billed']} mW billed (tree); saver asked {saver['asked']}, "
                     f"observed {saver['observed']}{' REFUSED' if saver['mismatch'] else ''}; thermal {thermal['worst']}"
                     f"{' (marked)' if thermal['marked'] else ''}; {len(entry['assertions'])} power assertion(s)"
                     + (f"; page rAF {entry['anim']}" if "anim" in entry else "") + "\n")
    lines += ["| process | n | threads (max) | wakeups/s (max) | pkg-idle wakeups/s | main wakes/s | "
              "CPU mW | billed mW | GPU ms/s | csw/s | CPU % | threads that ran |",
              "|---|---|---|---|---|---|---|---|---|---|---|---|"]
    order = ["app", "daemon", "holder", "terminal-host", "acpmux"]
    for name in sorted(kinds, key=lambda k: (order.index(k) if k in order else len(order), k)):
        e = kinds[name]
        mark = lambda f, v: f"**{v}**" if (name, f) in over_keys else f"{v}"  # noqa: E731
        lines.append(f"| {name} | {e['n']} | {e['threads']} ({mark('threads_max', e['threads_max'])}) | "
                     f"{mark('wakeups_per_s', e['wakeups_per_s'])} ({mark('wakeups_max', e['wakeups_max'])}) | "
                     f"{e['pkg_idle_wakeups_per_s']} | {mark('main_wakes_per_s', e.get('main_wakes_per_s', '-'))} | "
                     f"{mark('energy_mw_cpu', e['energy_mw_cpu'])} | {mark('energy_mw_billed', e['energy_mw_billed'])} | "
                     f"{mark('gpu_ms_per_s', '-' if e['gpu_ms_per_s'] is None else e['gpu_ms_per_s'])} | "
                     f"{e['csw_per_s']} | {e['cpu_pct']} | {e['threads_ran']} |")
    return "\n".join(lines)


def coalition_line(coalition):
    """The app's resource coalition under the session's table (None: it could not be read)."""
    if coalition is None:
        return "app coalition: not readable"
    return (f"app coalition: {coalition['wakeups_per_s']} wakeups/s ({coalition['pkg_idle_wakeups_per_s']} pkg-idle), "
            f"{coalition['energy_mw_cpu']} mW CPU, {coalition['energy_mw_billed']} mW billed, "
            f"{coalition['gpu_ms_per_s']} GPU ms/s, {coalition['cpu_pct']} % CPU")


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--app", help='a tagged "cmux DEV <tag>.app" (not running)')
    parser.add_argument("--xbench", metavar="RESULTS_JSON",
                        help="judge an xbench.py results.json against the budget's xbench rows (D6) and exit; no --app")
    parser.add_argument("--tag", help="ignored (split-spring passes it); the tag comes from the app")
    parser.add_argument("--out", default=None)
    parser.add_argument("--json", default=None)
    parser.add_argument("--sessions", default="light,stress")
    parser.add_argument("--settle", type=float, default=60)
    parser.add_argument("--measure", type=float, default=60)
    parser.add_argument("--budget", default=BUDGET_FILE)
    parser.add_argument("--gate", action="store_true",
                        help="exit 1 when a value is over its budget, a session's saver state is not the one it asked "
                        "for, or chrome-static failed or is no equal reference; exit 2 at once on a Debug build")
    parser.add_argument("--shipping-draw", choices=("on", "off"), default="on",
                        help="off: keep the automation draw of occluded windows (Debug), to compare with the shipping draw")
    parser.add_argument("--sample", type=float, default=10,
                        help="seconds of /usr/bin/sample of the app after the window, to name the threads that woke (0: none)")
    parser.add_argument("--samples", type=int, default=None,
                        help="how many --sample runs to take and add (default: 3 in a hidden-wake session, else 1)")
    parser.add_argument("--wake-trace", type=float, default=30,
                        help="seconds of DTrace callout counts of the main thread after the samples, in a hidden-wake "
                             "session (0: none)")
    parser.add_argument("--chrome-app", default=CHROME_APP,
                        help="the chrome-static browser: a Chromium that runs Manifest V2 (ungoogled-chromium of "
                        "cmux's Chromium major); branded Chrome 137+ and Chrome for Testing 139+ are refused")
    parser.add_argument("--chrome-ublock", default=None,
                        help="the unpacked uBlock Origin chrome-static loads (default: the copy in --app; "
                        "`none`: without it, which marks the Chrome ratios unequal)")
    parser.add_argument("--chrome-template-settle", type=float, default=45,
                        help="seconds the reference browser's template profile runs before its first clone")
    parser.add_argument("--chrome-helper-cache", default=os.path.expanduser("~/Library/Caches/cmux-perf-bench"),
                        help="xbench's benchhelper cache")
    opts, _unknown = parser.parse_known_args(argv)
    budget = load_budget(opts.budget)
    if opts.xbench:
        with open(opts.xbench) as handle:
            overs, notes = xbench_overs(budget, json.load(handle))
        for note in notes:
            print(f"IDLE-BUDGET-NOT-JUDGED {note}", flush=True)
        for over in overs:
            print(over_line("xbench", over), flush=True)
        print(f"IDLE-BUDGET over={len(overs)} xbench={opts.xbench}", flush=True)
        sys.exit(1 if opts.gate and overs else 0)
    if not opts.app:
        parser.error("--app is required (or --xbench RESULTS_JSON)")
    sessions = parse_sessions(opts.sessions)
    build_config = bundle_build_config(opts.app)
    refusal = gate_refusal(build_config, opts.gate)
    if refusal:
        print(f"IDLE-BUDGET-REFUSED build_config={build_config}: {refusal}", flush=True)
        sys.exit(2)
    from bench_launch import BenchApp
    env = launch_env(shipping_draw=opts.shipping_draw == "on")
    out = opts.out or os.path.join(os.getcwd(), "artifacts", "idle-budget")
    os.makedirs(out, exist_ok=True)
    machine = host_facts()
    print("IDLE-BUDGET-MACHINE " + json.dumps(machine), flush=True)
    report = {"machine": machine, "app": opts.app, "build_config": build_config, "shipping_draw": opts.shipping_draw,
              "settle_s": opts.settle, "measure_s": opts.measure, "sessions": {}}
    all_overs = []
    refused = []
    markdown = []
    for session in sessions:
        spec = SESSIONS[session]
        if spec.get("chrome"):
            report["sessions"][session] = chrome_static_entry(opts, out, session, markdown)
            continue
        folder = os.path.join(out, session)
        app = BenchApp(opts.app, out=folder, env=env, config=session_config(session))
        pages = IdlePages() if spec.get("tabs") else None
        try:
            sha = build_sha_of(opts.app) if spec.get("hidden_wake") else None  # before the launch: no report without it
            entry = {"fresh_session": fresh_session(app)}
            report["sessions"][session] = entry
            app.launch()
            if spec.get("stress"):
                entry["stress"] = build_stress(app, static=spec.get("static", False))
            if spec.get("tabs"):
                entry["tabs"] = build_tabs(app, pages, spec["tabs"])
            activation = app.activate()  # once, before the settle (and before a hide): users run an active app
            if not activation["activated"]:
                print(f"IDLE-BUDGET-NOT-ACTIVATED {session}: {activation['error']}", flush=True)
            if spec.get("hide"):
                entry["hide"] = app.rpc("action.run", {"action": "showHideAllWindows", "args": {"hidden": True},
                                                       "focus": False, "origin": "script"}, timeout=30)
                check_action_reply("showHideAllWindows", entry["hide"])
            if spec.get("minimize"):
                entry["minimize"] = minimize(app)
            settle = settle_seconds(session, opts.settle)
            entry["settle_s"] = settle
            time.sleep(settle)  # bench: the session settles (page loads, Chromium's post-load work, the hidden-tab freeze)
            instance = procs.Instance(app.app, app.process.pid)
            names = [name for _cpu, name in threads(app.process.pid).values()]
            entry.update(shipping_fields(build_config, app.launched_env or {}, names,
                                         read_rpc(app, "debug.hangs", {"limit": 0}), activation))
            print(f"IDLE-BUDGET-MODE {session} " + json.dumps({k: entry[k] for k in SHIPPING_FIELDS}), flush=True)
            window_before = window_state(app)
            problem = hidden_state_problem(spec, window_before) if spec.get("hidden_wake") else None
            if problem:
                print(f"IDLE-BUDGET-WINDOW {session} " + json.dumps({"start": window_before}), flush=True)
                raise HiddenStateError(f"before the window: {problem}")
            result = measure(app, instance, opts.measure, pages.read_anim if spec.get("anim") else None,
                             ledger_limit=None if spec.get("hidden_wake") else 20)
            result["window_state"] = {"start": window_before, "end": window_state(app)}
            print(f"IDLE-BUDGET-WINDOW {session} " + json.dumps(result["window_state"]), flush=True)
            problem = hidden_state_problem(spec, result["window_state"]["end"]) if spec.get("hidden_wake") else None
            if problem:
                raise HiddenStateError(f"at the end of the window: {problem}")
            texts = []
            if opts.sample:
                os.makedirs(folder, exist_ok=True)
                for index in range(opts.samples or (3 if spec.get("hidden_wake") else 1)):
                    text = run_sample(app.process.pid, opts.sample, os.path.join(folder, f"sample-app-{index + 1}.txt"))
                    if text:
                        texts.append(text)
                result["sample"] = threads_from_sample(texts[0]) if texts else {}
                result["main_callouts"] = main_callouts_from_samples(texts)
            if spec.get("hidden_wake") and opts.wake_trace:
                os.makedirs(folder, exist_ok=True)
                result["wake_trace"] = count_main_callouts(app, opts.wake_trace, folder,
                                                           binary_images(texts[0]) if texts else None)
            entry.update(summarize(session, result, budget))
            kinds, overs, notes = entry["kinds"], [tuple(o) for o in entry["over"]], entry["not_judged"]
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
            if spec.get("hidden_wake"):
                hidden = hidden_wake_sources(result)
                hidden.update({"sha": sha, "host": machine["host"], "samples_taken": len(texts),
                               "problems": shipping_problems(entry)})
                entry["hidden_wake"] = hidden
                for line in hidden_wake_lines(session, hidden, sha, machine["host"], hidden["problems"]):
                    print(line, flush=True)
            for note in notes:
                print(f"IDLE-BUDGET-NOT-JUDGED {note}", flush=True)
            for over in overs:
                print(over_line(session, over), flush=True)
            reasons = refusals(entry)
            if reasons:
                refused.append(session)
            for what, why in reasons:
                print(f"IDLE-BUDGET-REFUSED {session} {what}: {why}", flush=True)
            if entry["thermal"]["marked"]:
                print(f"IDLE-BUDGET-THERMAL {session} rows taken at {entry['thermal']['worst']}: not comparable", flush=True)
            all_overs += [(session, *o) for o in overs]
            markdown.append(table(session, kinds, overs, entry) + "\n\n" + coalition_line(result.get("coalition")))
            print(f"IDLE-BUDGET-COALITION {session} " + json.dumps(result.get("coalition")), flush=True)
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
            if pages is not None:
                pages.close()
    cross, cross_notes, chrome_refused = judge_across(report, budget, CHROME_SESSION in sessions)
    for note in cross_notes:
        print(f"IDLE-BUDGET-NOT-JUDGED {note}", flush=True)
    for session, over in cross:
        print(over_line(session, over), flush=True)
    for why in chrome_refused:
        print(f"IDLE-BUDGET-REFUSED {CHROME_SESSION} reference: {why}", flush=True)
    if chrome_refused:
        refused.append(CHROME_SESSION)
        report["chrome_refused"] = chrome_refused
    all_overs += [(session, *over) for session, over in cross]
    if cross or cross_notes:
        markdown.append("\n### across sessions\n\n" + "\n".join(
            [f"- {over_line(session, over)}" for session, over in cross] + [f"- {note}" for note in cross_notes]))
    if report.get("ratio_to_chrome"):
        markdown.append(ratio_table(report["ratio_to_chrome"]))
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
