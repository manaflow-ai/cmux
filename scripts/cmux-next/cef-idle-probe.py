#!/usr/bin/env python3
"""What keeps Chromium awake in an idle light session (item 6, plans/cmux-next/idle-wakeups.md). A measurement tool.

Launches the tagged app as idle-budget.py's `light` session does (fresh session, Home's pages in Chromium),
with a DevTools port, lets it settle, then with no input:
  1. debug.cef (the pump counters) at the window's two ends: pump requests and work runs per second, and the
     early passes (a delayed pass CEF re-asked for under 2 ms);
  2. every DevTools target (type, url, attached) and, for each page and iframe target: visibilityState,
     document.hasFocus(), running animations (document.getAnimations(): count, names, play state),
     and the rAF callbacks one second gets (0 when Chromium has the page hidden);
  3. Chromium's own trace for the window (every process): per process and thread, the tasks per second by
     posting location, BeginFrames, BeginMainFrames, and the TracingStartedInBrowser frame list (renderer pid
     to URL).
  4. CEF-IDLE-POSTED {"kind","process","thread","location","per_s","pids"} for every posting location, highest
     per_s first (Q8, p14-energy-041, -109), with `seed` and `switch` when it is on the seed list (IDLE_SEEDS) or
     `stays` (Safe Browsing, the CRLSet, the probe's own trace). `--queue` prints the Q8 work list: locations at
     or above QUEUE_MIN_PER_S in the browser process (every thread) or a renderer, GPU, network, storage, audio
     or other utility process, that do not stay; then CEF-IDLE-POSTED-STAYS for the ones above it that stay.
     Then CEF-IDLE-POSTED-PUMP sets the browser main thread's task rate beside the cmux pump counters.
  5. With --extension-timers [ID] (default the built-in uBlock Origin), INSTEAD of steps 1 to 4: the extension's
     background page (extension_timers.py, p14-energy-108): CEF-IDLE-EXT-TIMER {"kind","event","where","count","per_s"}
     per timer fire (`where` = the callback), arm (`where` = the stack that armed it) and alarm, then CEF-IDLE-EXT
     with the totals and the alarm list. The profiler's debugger pauses and DevTools traffic run on the browser main
     thread and in the extension renderer, so a window with it attached is never a trace or pump window.
Writes OUT/cef-idle.json (OUT/cef-idle-extension.json for step 5) and prints CEF-IDLE lines.

  cef-idle-probe.py --app APP [--out DIR] [--settle 60] [--window 10] [--queue]   (--queue: window 100 s, >= 50 s)
  cef-idle-probe.py --app APP --extension-timers [ID] [--settle 60] [--window 120]   (step 5 only; window >= 60 s)
  cef-idle-probe.py --trace OUT/chromium-trace.json --seconds 10 [--queue]   (a recorded trace, no app; --queue: >= 50 s)
  cef-idle-probe.py --cdp-port PORT [--extension-timers ID] [--window 120]   (a running browser's DevTools port, as
                    Chrome in chrome-static: step 5 only, no app; window >= 60 s)
"""
import argparse, collections, json, os, sys, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def free_port():
    import socket
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


PAGE_PROBE = r"""(async () => {
  const anims = (document.getAnimations ? document.getAnimations() : []).map(a => ({
    name: a.animationName || a.id || (a.effect && a.effect.target && a.effect.target.tagName) || '?',
    state: a.playState, kind: a.constructor.name, iterations: a.effect && a.effect.getTiming ? String(a.effect.getTiming().iterations) : '?'}));
  let raf = 0; const t0 = performance.now();
  await new Promise(done => { const tick = () => { raf++; if (performance.now() - t0 < 1000) requestAnimationFrame(tick); else done(); };
    requestAnimationFrame(tick); setTimeout(done, 1500); });
  return {visibility: document.visibilityState, hidden: document.hidden, focus: document.hasFocus(),
          url: location.href, animations: anims.slice(0, 20), animation_count: anims.length, raf_per_s: raf};
})()"""


# The built-in uBlock Origin (fetch-ublock.sh keeps its Web Store key, so the id is stable; idle-budget.py UBLOCK_ID).
UBLOCK_ID = "cjpalhdlnbpafiamejdnhcphjbkeiagm"
# uBlock Origin 1.75's shortest idle owner runs every 30 s (traffic.js gc; plans/cmux-next/idle-wakeups.md 9.9). The
# extension window sees it four times by default and at least twice, so a short window can not read as "no timers".
EXTENSION_OWNER_PERIOD_S = 30.0
EXTENSION_WINDOW_S = 4 * EXTENSION_OWNER_PERIOD_S
EXTENSION_MIN_WINDOW_S = 2 * EXTENSION_OWNER_PERIOD_S


def extension_window_error(seconds):
    """Why `seconds` can not be an --extension-timers window, or None."""
    if seconds < EXTENSION_MIN_WINDOW_S:
        return (f"--extension-timers needs --window >= {EXTENSION_MIN_WINDOW_S:g} s (two runs of the "
                f"{EXTENSION_OWNER_PERIOD_S:g} s owner; default {EXTENSION_WINDOW_S:g} s), got {seconds:g}")
    return None


def extension_profile(port, extension_id):
    """A started ExtensionTimerProfile on the extension's background target and the target, or (None, None) when the
    extension runs no background page or service worker."""
    from ext_e2e import cdp
    import extension_timers
    target = extension_timers.background_target(cdp.targets(port), extension_id)
    if target is None:
        return None, None
    profile = extension_timers.ExtensionTimerProfile(cdp.Session(target["webSocketDebuggerUrl"]), extension_id)
    profile.start()
    return profile, target


def finish_extension(profile, target, t0):
    """Stops the profile and prints its rows; returns the report."""
    seconds = time.monotonic() - t0
    profile.stop()
    report = {"target": target.get("type"), **profile.report(seconds)}
    for row in report["rows"]:
        print("CEF-IDLE-EXT-TIMER " + json.dumps(row), flush=True)
    print("CEF-IDLE-EXT " + json.dumps({k: v for k, v in report.items() if k != "rows"}), flush=True)
    return report


def extension_options(opts, parser):
    """The step-5 window and extension id; refuses the steps a profiler window can not measure."""
    if opts.queue:
        parser.error("--queue reads the trace, which --extension-timers does not record (its debugger pauses would be Q8 rows)")
    if opts.trace:
        parser.error("--trace and --extension-timers are separate runs")
    seconds = opts.window if opts.window is not None else EXTENSION_WINDOW_S
    if error := extension_window_error(seconds):
        parser.error(error)
    return seconds, opts.extension_timers or UBLOCK_ID


def profile_extension(port, extension_id, seconds, out):
    """Step 5 alone: profiles the extension for `seconds`, writes OUT/cef-idle-extension.json; returns the report, or
    None after a CEF-IDLE-ERROR line when the extension has no background target."""
    profile, target = extension_profile(port, extension_id)
    if profile is None:
        print("CEF-IDLE-ERROR " + json.dumps({"extension": extension_id, "error": "no background target"}), flush=True)
        return None
    t0 = time.monotonic()
    try:
        profile.run_until(t0 + seconds)
    finally:
        report = finish_extension(profile, target, t0)
    os.makedirs(out, exist_ok=True)
    with open(os.path.join(out, "cef-idle-extension.json"), "w") as f:
        json.dump(report, f, indent=1)
    return report


# A posting location at or above this rate in an idle session is one Q8 item (p14-energy.md, section 6).
QUEUE_MIN_PER_S = 0.02
# One run in the window is 1/window per second, so a window shorter than 1/QUEUE_MIN_PER_S lists any location that ran
# once and cannot tell a location at the threshold from one that did not run. The queue's default window sees two runs.
QUEUE_MIN_WINDOW_S = 1 / QUEUE_MIN_PER_S
QUEUE_WINDOW_S = 2 * QUEUE_MIN_WINDOW_S
IDLE_WINDOW_S = 10.0
TASK_EVENTS = ("ThreadControllerImpl::RunTask", "ThreadPool_RunTask")
# The browser process's UI thread (content/browser/browser_main_loop.cc names it); in-process CEF runs it on the app's
# main thread, driven by the external pump that debug.cef counts.
BROWSER_MAIN_THREAD = "CrBrowserMain"

# The trace's process names (base/process/current_process.cc, GetProcessName) and the kind of each.
PROCESS_KINDS = {
    "Browser": "browser",
    "Renderer": "renderer",
    "GPU Process": "gpu",
    "Service: network.mojom.NetworkService": "network",
    "Service: storage.mojom.StorageService": "storage",
    "Service: audio.mojom.AudioService": "audio",
    "Service: tracing.mojom.TracingService": "tracing",
}
# Q8 covers every thread of the browser process (the app: CrBrowserMain, ThreadPool*Worker, Chrome_IOThread), the
# renderers (CrRendererMain, Compositor), the GPU process (CrGpuMain, VizCompositorThread), the network, storage and
# audio services, and any other utility service. Out: the probe's own tracing service, extension renderers (the
# built-in uBlock Origin is measured as its own kind, p14-energy-108) and processes the trace does not name.
QUEUE_KINDS = frozenset({"browser", "renderer", "gpu", "network", "storage", "audio", "utility"})

# Q8's seed list, checked against Chromium main: where each candidate posts from, the source that shows it, and the
# existing switch that turns it off (None: a fork patch into p14-energy-136). The first matching entry wins.
IDLE_SEEDS = (
    {"seed": "Media Router discovery", "paths": ("chrome/browser/media/router/", "components/media_router/"),
     "source": "chrome/browser/media/router/media_router_feature.cc (kMediaRouter, enabled by default)",
     "switch": "disable-features=MediaRouter"},
    {"seed": "component updater",
     "paths": ("components/component_updater/", "components/update_client/", "chrome/browser/component_updater/"),
     "source": "chrome/browser/chrome_browser_main.cc (RegisterComponentsForUpdate)",
     # disable-component-update would also drop the CRLSet (registration.cc, RegisterCRLSetComponent).
     "switch": None},
    {"seed": "GCM", "paths": ("google_apis/gcm/", "components/gcm_driver/"),
     "source": "google_apis/gcm/engine/heartbeat_manager.cc", "switch": None},
    {"seed": "Optimization Guide", "paths": ("components/optimization_guide/", "chrome/browser/optimization_guide/"),
     "source": "components/optimization_guide/core/optimization_guide_features.cc (kOptimizationHints, "
               "kOptimizationTargetPrediction, enabled by default)",
     "switch": "disable-features=OptimizationHints,OptimizationTargetPrediction"},
    {"seed": "NetworkQualityEstimator", "paths": ("net/nqe/",),
     "source": "net/base/features.cc (EffectiveConnectionTypeRecomputationInterval, 10 s)", "switch": None},
    {"seed": "spare renderer", "paths": ("content/browser/renderer_host/spare_render_process_host_manager",),
     "source": "content/browser/renderer_host/spare_render_process_host_manager_impl.cc (PrepareForFutureRequests)",
     "switch": "cmux-spare-renderer-after-first-tab"},
)
# Locations that are never Q8 items. Safe Browsing and the CRLSet stay on (p14-energy.md, section E); the trace and
# DevTools work is the probe's own measurement. Checked before IDLE_SEEDS: the CRLSet installer is under
# chrome/browser/component_updater/.
STAYS = (
    {"stays": "CRLSet", "paths": ("chrome/browser/component_updater/crl_set_component_installer", "net/cert/crl_set")},
    {"stays": "Safe Browsing", "paths": ("components/safe_browsing/", "chrome/browser/safe_browsing/")},
    {"stays": "probe", "paths": ("services/tracing/", "components/tracing/", "base/trace_event/",
                                 "content/browser/tracing/", "content/browser/devtools/", "third_party/perfetto/")},
)


def posted_from(args):
    """The task's PostTask location: legacy JSON args (src_file, src_func) or the converted typed event
    (task.posted_from, base/trace_event/task_execution_macros.h)."""
    if "src_file" in args or "src_func" in args:
        return f"{args.get('src_file')}:{args.get('src_func')}"
    origin = (args.get("task") or {}).get("posted_from") or {}
    return f"{origin.get('file_name')}:{origin.get('function_name')}"


def process_kind(process, url=""):
    """The Q8 kind of a trace process; a renderer whose frame is a chrome-extension:// page is `extension`."""
    if process in PROCESS_KINDS:
        kind = PROCESS_KINDS[process]
    elif process.startswith("browser "):  # chromium_summary's name for a pid with no process_name metadata
        kind = "browser"
    elif process == "Utility" or process.startswith("Service: "):
        kind = "utility"
    else:
        kind = "other"
    return "extension" if kind == "renderer" and url.startswith("chrome-extension://") else kind


def source_file(location):
    """The location's path in the Chromium checkout (base/location.cc strips the build directory; a build that
    keeps it writes ../../)."""
    path = location.split(":", 1)[0]
    while path.startswith("../"):
        path = path[3:]
    return path


def classify(location):
    """The `stays` or `seed` fields of a location, or none."""
    path = source_file(location)
    for entry in STAYS:
        if path.startswith(entry["paths"]):
            return {"stays": entry["stays"]}
    for entry in IDLE_SEEDS:
        if path.startswith(entry["paths"]):
            return {"seed": entry["seed"], "switch": entry["switch"]}
    return {}


def posted_rows(tasks, seconds, renderer_urls=None, minimum=0.0):
    """One row per (kind, process, thread, location), highest per_s first, each naming its process and thread.
    The processes of one kind add up (one timer in each of 20 renderers is one location at 20 times the rate) and
    `pids` lists them; threads of one name add up (every ThreadPoolBackgroundWorker). Rows under `minimum` are
    dropped, compared before rounding, so 0.0199/s stays out of a 0.02 queue."""
    urls = renderer_urls or {}
    merged = {}
    for (process, pid, thread, location), count in tasks.items():
        kind = process_kind(process, urls.get(str(pid), ""))
        key = (kind, "Browser" if kind == "browser" else process, thread, location)
        total, pids = merged.get(key, (0, frozenset()))
        merged[key] = (total + count, pids | {pid})
    rows = []
    for (kind, process, thread, location), (count, pids) in merged.items():
        if count / seconds < minimum:
            continue
        rows.append({"kind": kind, "process": process, "thread": thread, "location": location,
                     "per_s": count / seconds, "pids": sorted(pids, key=str), **classify(location)})
    rows.sort(key=lambda row: (-row["per_s"], row["kind"], row["process"], row["thread"], row["location"]))
    for row in rows:
        row["per_s"] = round(row["per_s"], 3)
    return rows


def queue_rows(tasks, seconds, renderer_urls=None):
    """The Q8 work list: locations at or above QUEUE_MIN_PER_S in a QUEUE_KINDS process that do not stay."""
    return [row for row in posted_rows(tasks, seconds, renderer_urls, QUEUE_MIN_PER_S)
            if row["kind"] in QUEUE_KINDS and "stays" not in row]


def window_seconds(window, queue):
    """The app-mode window: --window if given, else 100 s with --queue and 10 s without."""
    if window is not None:
        return window
    return QUEUE_WINDOW_S if queue else IDLE_WINDOW_S


def queue_window_error(seconds, flag):
    """The parser error for a --queue window too short to resolve QUEUE_MIN_PER_S, or None."""
    if seconds >= QUEUE_MIN_WINDOW_S:
        return None
    return (f"--queue needs {flag} >= {QUEUE_MIN_WINDOW_S:g} (1/{QUEUE_MIN_PER_S}/s): one run in {seconds:g} s "
            f"is {1 / seconds:.3g}/s, so the queue cannot tell a {QUEUE_MIN_PER_S}/s location from one that did not run")


def pump_comparison(posted, pump_per_s, early_passes):
    """The browser main thread's posted tasks per second beside the pump's work runs and requests per second."""
    main_tasks = sum(row["per_s"] for row in posted if row["kind"] == "browser" and row["thread"] == BROWSER_MAIN_THREAD)
    report = {"browser_main_tasks_per_s": round(main_tasks, 3), "early_passes": early_passes}
    for key in ("work_runs", "immediate_requests", "delayed_requests", "reentrant_fires"):
        if key in pump_per_s:
            report[f"{key}_per_s"] = pump_per_s[key]
    return report


def print_posted(task_counts, seconds, queue, pump_per_s, early_passes, renderer_urls=None):
    """CEF-IDLE-POSTED lines: every location, or with `queue` the Q8 work list and then the locations at or above
    the threshold that stay (CEF-IDLE-POSTED-STAYS); last CEF-IDLE-POSTED-PUMP."""
    posted = posted_rows(task_counts, seconds, renderer_urls)
    if queue:
        for row in queue_rows(task_counts, seconds, renderer_urls):
            print("CEF-IDLE-POSTED " + json.dumps(row), flush=True)
        for row in posted_rows(task_counts, seconds, renderer_urls, QUEUE_MIN_PER_S):
            if "stays" in row:
                print("CEF-IDLE-POSTED-STAYS " + json.dumps(row), flush=True)
    else:
        for row in posted:
            print("CEF-IDLE-POSTED " + json.dumps(row), flush=True)
    print("CEF-IDLE-POSTED-PUMP " + json.dumps(pump_comparison(posted, pump_per_s, early_passes)), flush=True)
    return posted


def chromium_summary(path, seconds):
    with open(path) as f:
        data = json.load(f)
    events = data["traceEvents"] if isinstance(data, dict) else data
    names = {(e["pid"], e["tid"]): e["args"]["name"] for e in events if e.get("ph") == "M" and e.get("name") == "thread_name"}
    procs = {e["pid"]: e["args"]["name"] for e in events if e.get("ph") == "M" and e.get("name") == "process_name"}
    tasks, frames, urls = collections.Counter(), collections.Counter(), {}
    for e in events:
        name, args = e.get("name", ""), e.get("args") or {}
        if name == "TracingStartedInBrowser":
            for frame in ((args.get("data") or {}).get("frames") or []):
                urls[frame.get("processId")] = (frame.get("url") or "")[:120]
        if e.get("ph") != "X":
            continue
        where = (procs.get(e["pid"], f"browser {e['pid']}"), e["pid"], names.get((e["pid"], e["tid"]), str(e["tid"])))
        if name in TASK_EVENTS:
            tasks[where + (posted_from(args),)] += 1
        elif name in ("Scheduler::BeginImplFrame", "ProxyMain::BeginMainFrame", "DisplayScheduler::BeginFrame",
                      "AnimationHost::TickAnimations", "PageAnimator::serviceScriptedAnimations"):
            frames[where + (name,)] += 1
    rate = lambda c: [{"where": list(k), "per_s": round(v / seconds, 2)} for k, v in c.most_common(40)]  # noqa: E731
    return {"tasks": rate(tasks), "task_counts": tasks, "frames": rate(frames), "renderer_urls": {str(k): v for k, v in urls.items()},
            "processes": {str(k): v for k, v in procs.items()}}


def main():
    parser = argparse.ArgumentParser(description="What keeps Chromium awake in an idle session; prints CEF-IDLE lines.")
    parser.add_argument("--app", help="the tagged app to launch (required unless --trace)")
    parser.add_argument("--trace", help="summarize this recorded chromium-trace.json instead of launching the app")
    parser.add_argument("--seconds", type=float, help="the recorded trace's window in seconds (with --trace)")
    parser.add_argument("--queue", action="store_true",
                        help=f"print the Q8 work list: posting locations at or above {QUEUE_MIN_PER_S}/s on any "
                             "browser-process thread or in a renderer, GPU, network, storage, audio or utility process")
    parser.add_argument("--out", default=os.path.join(os.getcwd(), "artifacts", "cef-idle"))
    parser.add_argument("--settle", type=float, default=60)
    parser.add_argument("--window", type=float,
                        help=f"idle window in seconds (default {IDLE_WINDOW_S:g}, {QUEUE_WINDOW_S:g} with --queue)")
    parser.add_argument("--extension-timers", nargs="?", const=UBLOCK_ID, metavar="ID",
                        help="profile this extension's background timers instead of the trace and pump window "
                             f"(default {UBLOCK_ID}, the built-in uBlock Origin; --window default "
                             f"{EXTENSION_WINDOW_S:g} s, >= {EXTENSION_MIN_WINDOW_S:g} s)")
    parser.add_argument("--cdp-port", type=int,
                        help="profile --extension-timers in the browser on this DevTools port (no app, no trace)")
    opts, _ = parser.parse_known_args()
    extension = opts.extension_timers or opts.cdp_port
    if extension:
        extension_window, extension_id = extension_options(opts, parser)
    if opts.cdp_port:
        sys.exit(0 if profile_extension(opts.cdp_port, extension_id, extension_window, opts.out) else 1)
    if opts.trace:
        if not opts.seconds or opts.seconds <= 0:
            parser.error("--trace needs --seconds > 0")
        if opts.queue and (error := queue_window_error(opts.seconds, "--seconds")):
            parser.error(error)
        summary = chromium_summary(opts.trace, opts.seconds)
        print_posted(summary["task_counts"], opts.seconds, opts.queue, {}, None, summary["renderer_urls"])
        return
    if not opts.app:
        parser.error("--app is required unless --trace is given")
    if not extension:
        opts.window = window_seconds(opts.window, opts.queue)
        if opts.window <= 0:
            parser.error("--window needs a value > 0")
        if opts.queue and (error := queue_window_error(opts.window, "--window")):
            parser.error(error)
    os.makedirs(opts.out, exist_ok=True)
    from bench_launch import BenchApp
    from ext_e2e import cdp
    import importlib.util
    spec = importlib.util.spec_from_file_location("cmux_trace", os.path.join(HERE, "trace.py"))
    trace = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(trace)
    port = free_port()
    app = BenchApp(opts.app, out=opts.out,
                   env={"CMUX_NEXT_CEF_EXTRA_SWITCHES": f"remote-debugging-port={port}:remote-allow-origins=*"})
    report = {"port": port}
    try:
        state = os.path.join(os.path.expanduser("~"), "Library/Application Support/cmux/tags", app.tag, "tui")
        import shutil
        shutil.rmtree(state, ignore_errors=True)
        app.launch()
        time.sleep(opts.settle)
        if extension:
            report["extension"] = profile_extension(port, extension_id, extension_window, opts.out)
            return
        report["targets"] = cdp.target_infos(port)
        pages = []
        for target in report["targets"]:
            if target.get("type") not in ("page", "iframe", "other", "webview"):
                continue
            entry = {"type": target.get("type"), "url": (target.get("url") or "")[:160], "id": target.get("targetId")}
            try:
                session = cdp.page_session(port, target["targetId"])
                try:
                    entry["probe"] = session.evaluate(PAGE_PROBE, timeout=10)
                finally:
                    session.close()
            except Exception as error:  # noqa: BLE001 - reported per target
                entry["error"] = f"{type(error).__name__}: {error}"[:200]
            pages.append(entry)
            print("CEF-IDLE-PAGE " + json.dumps(entry), flush=True)
        report["pages"] = pages
        time.sleep(3)  # the probes' own rAF and evaluation work ends before the window
        tracer = trace.ChromiumTracer(port, opts.out)
        tracer.start()
        windows = app.rpc("debug.window_list", timeout=10).get("windows") or []
        report["window_start"] = [{k: w.get(k) for k in ("kind", "key", "visible", "occluded", "miniaturized", "alpha")} for w in windows if w.get("kind") == "main"]
        before = app.rpc("debug.cef", timeout=10).get("pump") or {}
        t0 = time.monotonic()
        time.sleep(opts.window)
        after = app.rpc("debug.cef", timeout=10).get("pump") or {}
        windows = app.rpc("debug.window_list", timeout=10).get("windows") or []
        report["window_end"] = [{k: w.get(k) for k in ("kind", "key", "visible", "occluded", "miniaturized", "alpha")} for w in windows if w.get("kind") == "main"]
        print("CEF-IDLE-WINDOW " + json.dumps({"start": report["window_start"], "end": report["window_end"]}), flush=True)
        seconds = time.monotonic() - t0
        tracer.stop()
        report["pump_per_s"] = {k: round((after.get(k, 0) - before.get(k, 0)) / seconds, 2)
                                for k in after if isinstance(after.get(k), (int, float))}
        print("CEF-IDLE-PUMP " + json.dumps(report["pump_per_s"]), flush=True)
        # Delayed passes before Chromium's task was due (CEFPumpStats.earlyPasses, p14-energy-018, -046).
        report["early_passes"] = after.get("early_passes", 0) - before.get("early_passes", 0)
        print("CEF-IDLE-EARLY-PASSES " + json.dumps({"count": report["early_passes"], "seconds": round(seconds, 2)}), flush=True)
        report["chromium"] = chromium_summary(os.path.join(opts.out, "chromium-trace.json"), seconds)
        task_counts = report["chromium"].pop("task_counts")  # tuple keys; `posted` below carries every row
        for row in report["chromium"]["tasks"][:25]:
            print("CEF-IDLE-TASK " + json.dumps(row), flush=True)
        for row in report["chromium"]["frames"][:20]:
            print("CEF-IDLE-FRAME " + json.dumps(row), flush=True)
        print("CEF-IDLE-RENDERERS " + json.dumps(report["chromium"]["renderer_urls"]), flush=True)
        report["chromium"]["posted"] = print_posted(task_counts, seconds, opts.queue, report["pump_per_s"],
                                                    report["early_passes"], report["chromium"]["renderer_urls"])
    except BaseException as error:  # noqa: BLE001 - the report keeps what was read
        report["error"] = f"{type(error).__name__}: {error}"[:500]
        print("CEF-IDLE-ERROR " + report["error"], flush=True)
    finally:
        app.stop()
        with open(os.path.join(opts.out, "cef-idle.json"), "w") as f:
            json.dump(report, f, indent=1)
    sys.exit(0)


if __name__ == "__main__":
    main()
