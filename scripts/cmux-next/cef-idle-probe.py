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
  4. CEF-IDLE-POSTED {"process","pid","thread","location","per_s"} for every posting location, highest per_s first
     (Q8); `--queue` keeps the ones at or above QUEUE_MIN_PER_S, the Q8 work list. Then
     CEF-IDLE-POSTED-PUMP sets the browser main thread's task rate beside the cmux pump counters.
Writes OUT/cef-idle.json and prints CEF-IDLE lines.

  cef-idle-probe.py --app APP [--out DIR] [--settle 60] [--window 10] [--queue]   (--queue: window 100 s, >= 50 s)
  cef-idle-probe.py --trace OUT/chromium-trace.json --seconds 10 [--queue]   (a recorded trace, no app; --queue: >= 50 s)
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


# A posting location at or above this rate in an idle session is one Q8 item (p14-energy.md, section 6).
QUEUE_MIN_PER_S = 0.02
# One run in the window is 1/window per second, so a window shorter than 1/QUEUE_MIN_PER_S lists any location that ran
# once and cannot tell a location at the threshold from one that did not run. The queue's default window sees two runs.
QUEUE_MIN_WINDOW_S = 1 / QUEUE_MIN_PER_S
QUEUE_WINDOW_S = 2 * QUEUE_MIN_WINDOW_S
IDLE_WINDOW_S = 10.0
TASK_EVENTS = ("ThreadControllerImpl::RunTask", "ThreadPool_RunTask")
# The browser process's UI thread (content/public/browser/browser_thread.h); in-process CEF runs it on the app's
# main thread, driven by the external pump that debug.cef counts.
BROWSER_MAIN_THREAD = "CrBrowserMain"


def posted_from(args):
    """The task's PostTask location: legacy JSON args (src_file, src_func) or the converted typed event
    (task.posted_from, base/trace_event/task_execution_macros.h)."""
    if "src_file" in args or "src_func" in args:
        return f"{args.get('src_file')}:{args.get('src_func')}"
    origin = (args.get("task") or {}).get("posted_from") or {}
    return f"{origin.get('file_name')}:{origin.get('function_name')}"


def posted_rows(tasks, seconds, minimum=0.0):
    """One row per (process, thread, location), highest per_s first; rows under `minimum` are dropped
    (compared before rounding, so 0.0199/s stays out of a 0.02 queue)."""
    rows = [{"process": process, "pid": pid, "thread": thread, "location": location, "per_s": count / seconds}
            for (process, pid, thread, location), count in tasks.items() if count / seconds >= minimum]
    rows.sort(key=lambda row: (-row["per_s"], row["process"], str(row["pid"]), row["thread"], row["location"]))
    for row in rows:
        row["per_s"] = round(row["per_s"], 3)
    return rows


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
    main_tasks = sum(row["per_s"] for row in posted if row["thread"] == BROWSER_MAIN_THREAD)
    report = {"browser_main_tasks_per_s": round(main_tasks, 3), "early_passes": early_passes}
    for key in ("work_runs", "immediate_requests", "delayed_requests", "reentrant_fires"):
        if key in pump_per_s:
            report[f"{key}_per_s"] = pump_per_s[key]
    return report


def print_posted(task_counts, seconds, queue, pump_per_s, early_passes):
    posted = posted_rows(task_counts, seconds)
    for row in (posted_rows(task_counts, seconds, QUEUE_MIN_PER_S) if queue else posted):
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
                        help=f"print only posting locations at or above {QUEUE_MIN_PER_S}/s (the Q8 work list)")
    parser.add_argument("--out", default=os.path.join(os.getcwd(), "artifacts", "cef-idle"))
    parser.add_argument("--settle", type=float, default=60)
    parser.add_argument("--window", type=float,
                        help=f"idle window in seconds (default {IDLE_WINDOW_S:g}, {QUEUE_WINDOW_S:g} with --queue)")
    opts, _ = parser.parse_known_args()
    if opts.trace:
        if not opts.seconds or opts.seconds <= 0:
            parser.error("--trace needs --seconds > 0")
        if opts.queue and (error := queue_window_error(opts.seconds, "--seconds")):
            parser.error(error)
        print_posted(chromium_summary(opts.trace, opts.seconds)["task_counts"], opts.seconds, opts.queue, {}, None)
        return
    if not opts.app:
        parser.error("--app is required unless --trace is given")
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
        # Delayed passes before Chromium's task was due (CEFPumpStats.earlyPasses).
        report["early_passes"] = after.get("early_passes", 0) - before.get("early_passes", 0)
        print("CEF-IDLE-EARLY-PASSES " + json.dumps({"count": report["early_passes"], "seconds": round(seconds, 2)}), flush=True)
        report["chromium"] = chromium_summary(os.path.join(opts.out, "chromium-trace.json"), seconds)
        task_counts = report["chromium"].pop("task_counts")  # tuple keys; `posted` below carries every row
        for row in report["chromium"]["tasks"][:25]:
            print("CEF-IDLE-TASK " + json.dumps(row), flush=True)
        for row in report["chromium"]["frames"][:20]:
            print("CEF-IDLE-FRAME " + json.dumps(row), flush=True)
        print("CEF-IDLE-RENDERERS " + json.dumps(report["chromium"]["renderer_urls"]), flush=True)
        report["chromium"]["posted"] = print_posted(task_counts, seconds, opts.queue,
                                                    report["pump_per_s"], report["early_passes"])
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
