#!/usr/bin/env python3
"""What keeps Chromium awake in an idle light session (item 6, plans/cmux-next/idle-wakeups.md). A measurement tool.

Launches the tagged app as idle-budget.py's `light` session does (fresh session, Home's pages in Chromium),
with a DevTools port, lets it settle, then with no input:
  1. debug.cef (the pump counters) at the window's two ends: pump requests and work runs per second;
  2. every DevTools target (type, url, attached) and, for each page and iframe target: visibilityState,
     document.hasFocus(), running animations (document.getAnimations(): count, names, play state),
     and the rAF callbacks one second gets (0 when Chromium has the page hidden);
  3. Chromium's own trace for the window (every process): per process and thread, the tasks per second by
     posting location, BeginFrames, BeginMainFrames, and the TracingStartedInBrowser frame list (renderer pid
     to URL).
Writes OUT/cef-idle.json and prints CEF-IDLE lines.

  cef-idle-probe.py --app APP [--out DIR] [--settle 60] [--window 10]
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


def chromium_summary(path, seconds):
    data = json.load(open(path))
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
        if name in ("ThreadControllerImpl::RunTask", "ThreadPool_RunTask"):
            tasks[where + (f"{args.get('src_file')}:{args.get('src_func')}",)] += 1
        elif name in ("Scheduler::BeginImplFrame", "ProxyMain::BeginMainFrame", "DisplayScheduler::BeginFrame",
                      "AnimationHost::TickAnimations", "PageAnimator::serviceScriptedAnimations"):
            frames[where + (name,)] += 1
    rate = lambda c: [{"where": list(k), "per_s": round(v / seconds, 2)} for k, v in c.most_common(40)]  # noqa: E731
    return {"tasks": rate(tasks), "frames": rate(frames), "renderer_urls": {str(k): v for k, v in urls.items()},
            "processes": {str(k): v for k, v in procs.items()}}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", default=os.path.join(os.getcwd(), "artifacts", "cef-idle"))
    parser.add_argument("--settle", type=float, default=60)
    parser.add_argument("--window", type=float, default=10)
    opts, _ = parser.parse_known_args()
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
        report["chromium"] = chromium_summary(os.path.join(opts.out, "chromium-trace.json"), seconds)
        for row in report["chromium"]["tasks"][:25]:
            print("CEF-IDLE-TASK " + json.dumps(row), flush=True)
        for row in report["chromium"]["frames"][:20]:
            print("CEF-IDLE-FRAME " + json.dumps(row), flush=True)
        print("CEF-IDLE-RENDERERS " + json.dumps(report["chromium"]["renderer_urls"]), flush=True)
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
