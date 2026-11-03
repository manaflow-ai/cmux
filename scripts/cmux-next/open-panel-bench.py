#!/usr/bin/env python3
"""Click to file picker: how long the open panel takes to show, and what of it holds the main thread.

Launches a tagged DEV app (bench_launch.py), then times file-picker opens through `debug.open_panel_bench`
(DebugOpenPanelBench.swift) in three modes, each `--rounds` times, light (one window) and STRESS
(perf-stress-session.py):

  made    the panel made ahead (MadeAheadOpenPanel), as Home's "+" and an agent composer's Attach take it
  fresh   a new NSOpenPanel() per open: the on-demand path when none was made ahead
  window  begin(completionHandler:): a separate panel window instead of a sheet

Per open: init_ms (getting the panel), begin_ms (beginSheetModal / begin), sync_ms (their sum: the click's
main-thread time), visible_ms (the first display frame with the panel on screen) and the longest display
frame interval from the click until 300 ms after it showed (frames.max_ms) with the refresh rate.

The first open of each session (right after the launch, right after the STRESS build) may still run during launch or
build work: no app-side signal says that work has ended. It is marked `first_open`, printed on its own OPEN-PANEL-FIRST
row and kept in `first_opens` (the whole run but its frame intervals: times, error, made_ahead_before, prompt_nil,
missed), and left out of the session's percentiles; each OPEN-PANEL row says how many opens it summarizes (`n`). Later opens can still overlap launch work that lasts longer than one open.

Usage: open-panel-bench.py --app APP --out DIR [--json PATH] [--sessions light,stress] [--rounds 5]
Fleet: scripts/measure/split-spring.sh --suite=open-panel [--sessions=...] [--rounds=N]
"""
import argparse, importlib.util, json, os, statistics, sys, threading, time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bench_launch import BenchApp  # noqa: E402


def parse(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--app", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--json")
    parser.add_argument("--tag")  # split-spring passes it; the app's name carries the tag
    parser.add_argument("--sessions", default="light,stress")
    parser.add_argument("--rounds", type=int, default=5)
    parser.add_argument("--modes", default="made,fresh,window")
    opts, _unknown = parser.parse_known_args(argv)
    return opts


def load_stress():
    spec = importlib.util.spec_from_file_location("perf_stress_session", os.path.join(HERE, "perf-stress-session.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def pct(values, q):
    values = sorted(v for v in values if isinstance(v, (int, float)))
    if not values:
        return None
    return round(values[min(len(values) - 1, int(round((len(values) - 1) * q)))], 2)


def summary(runs, key):
    values = [r.get(key) for r in runs]
    return {"p50": pct(values, 0.5), "p95": pct(values, 0.95), "max": pct(values, 1.0)}


TIMES = ("init_ms", "begin_ms", "sync_ms", "visible_ms", "frame_max_ms")


def measure(app, session, report, opts):
    first_open = True  # the session's first open: right after the launch or the STRESS build
    for mode in opts.modes.split(","):
        runs = []
        for index in range(opts.rounds):
            # A call that does not answer in 45 s: the app's main thread as it hangs (the quit-time hang of
            # 2026-10-23, the 4th new-panel open on mac26), before the call's own timeout ends it.
            stuck = threading.Timer(45, lambda: report["hangs"].append(
                {"session": session, "mode": mode, "round": index, "at": "open", "main_thread": app.sample_main_thread(3)}))
            stuck.start()
            reply = app.rpc("debug.open_panel_bench", {"mode": mode}, timeout=90) or {}
            stuck.cancel()
            frames = reply.get("frames") or {}
            run = {k: reply.get(k) for k in ("mode", "made_ahead_before", "init_ms", "begin_ms", "sync_ms", "visible_ms", "error")}
            run.update(frame_max_ms=frames.get("max_ms"), missed=frames.get("missed"), refresh_ms=frames.get("refresh_ms"),
                       intervals_ms=frames.get("intervals_ms"), prompt_nil=reply.get("prompt_nil"),
                       session=session, round=index, first_open=first_open)
            if first_open:
                first_open = False
                # The whole run but its frame intervals (they stay in report["runs"]): this row is the only place the
                # first open shows, so a dead panel's error or a panel not made ahead must show here too.
                first = {k: v for k, v in run.items() if k != "intervals_ms"}
                report.setdefault("first_opens", []).append(first)
                print("OPEN-PANEL-FIRST " + json.dumps(first), flush=True)
            runs.append(run)
            print(f"  {session:<6} {mode:<6} #{index}: init {run['init_ms']} begin {run['begin_ms']} sync {run['sync_ms']} "
                  f"visible {run['visible_ms']} ms, longest frame {run['frame_max_ms']} ms (refresh {run['refresh_ms']} ms) "
                  f"made_before {run['made_ahead_before']} {run['error'] or ''}", flush=True)
        report["runs"].extend(runs)
        later = [run for run in runs if not run["first_open"]]
        row = {"session": session, "mode": mode, "n": len(later), **{k: summary(later, k) for k in TIMES}}
        report["summary"].append(row)
        print("OPEN-PANEL " + json.dumps(row), flush=True)


def quit_probe(app, report):
    """Quits the app as a person does (debug.quit) and times it; one that has not ended in 30 s is sampled."""
    if not app.process or app.process.poll() is not None:
        return
    start = time.monotonic()
    reply = app.rpc("debug.quit", {"fixture_quit": "end-sessions"}, timeout=10)
    try:
        app.process.wait(30)
        report["quit"] = {"seconds": round(time.monotonic() - start, 2), "reply": reply}
    except Exception:  # still running after 30 s: the quit hangs
        report["quit"] = {"seconds": None, "reply": reply, "hung": True, "main_thread": app.sample_main_thread(3)}
        report["hangs"].append({"at": "quit", "main_thread": report["quit"]["main_thread"]})
    print("OPEN-PANEL-QUIT " + json.dumps({k: v for k, v in report["quit"].items() if k != "main_thread"}), flush=True)
    for hang in report["hangs"]:
        print(f"OPEN-PANEL-HANG at {hang.get('at')} {hang.get('mode', '')} #{hang.get('round', '')}:\n{hang.get('main_thread')}", flush=True)


def main(argv=None):
    opts = parse(argv)
    os.makedirs(opts.out, exist_ok=True)
    report = {"runs": [], "summary": [], "first_opens": [], "hangs": []}
    app = BenchApp(opts.app, out=opts.out, window=(40, 40, 1600, 1000))
    try:
        # No settle sleep (it hid launch work behind a fixed 3 s): the first open of each session is reported on its
        # own row and left out of the percentiles (measure).
        app.launch(timeout=180)
        for session in opts.sessions.split(","):
            if session == "stress":
                built = load_stress().Stress(lambda m, p=None, timeout=60: app.rpc(m, p, timeout)).build()
                report["stress_session"] = built
            measure(app, session, report, opts)
    finally:
        quit_probe(app, report)
        app.stop()
        if opts.json:
            with open(opts.json, "w") as f:
                json.dump(report, f, indent=1)
    return 0 if report["summary"] and all(not r.get("error") for r in report["runs"]) else 1


if __name__ == "__main__":
    sys.exit(main())
